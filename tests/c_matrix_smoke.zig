const std = @import("std");
const saasm = @import("saasm");
const builtin = @import("builtin");
const sio = @import("sio");

// C backend equivalence matrix: `sa build-c` output compiled with cc
// must match the expected stdout of each demo (verified against native
// `sa run` during development). Pure Zig backend: no LLVM required.

fn runExe(allocator: std.mem.Allocator, exe_path: []const u8) !sio.Child.RunResult {
    return try sio.Child.run(.{
        .allocator = allocator,
        .argv = &.{exe_path},
    });
}

fn elapsedMs(start_ns: i128) i128 {
    return @divTrunc(sio.nanoTimestamp() - start_ns, std.time.ns_per_ms);
}

var c_matrix_seq: usize = 0;

/// Shard selector for the C demo matrix: SA_C_MATRIX_SHARD="i/n" runs
/// only demos whose sequence number satisfies seq % n == i (0-based).
fn cMatrixShardSelected() bool {
    const seq = c_matrix_seq;
    c_matrix_seq += 1;
    const value = sio.getEnvVarOwned(std.testing.allocator, "SA_C_MATRIX_SHARD") catch return true;
    defer std.testing.allocator.free(value);
    var parts = std.mem.splitScalar(u8, value, '/');
    const i_text = parts.next() orelse return true;
    const n_text = parts.next() orelse return true;
    const i = std.fmt.parseUnsigned(usize, i_text, 10) catch return true;
    const n = std.fmt.parseUnsigned(usize, n_text, 10) catch return true;
    if (n == 0 or i >= n) return true;
    return seq % n == i;
}

fn assertCMatrixStdout(path: []const u8, expected_stdout: []const u8) !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (!cMatrixShardSelected()) {
        std.debug.print("[c-matrix] SKIP  demo={s} reason=shard\n", .{path});
        return;
    }
    const cc_probe = sio.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "cc", "--version" },
    }) catch return error.SkipZigTest;
    defer std.testing.allocator.free(cc_probe.stdout);
    defer std.testing.allocator.free(cc_probe.stderr);
    switch (cc_probe.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const repo_root = try original_cwd.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(repo_root);
    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(source_path);

    const demo_start = sio.nanoTimestamp();
    std.debug.print("[c-matrix] START demo={s}\n", .{path});
    var demo_ended = false;
    errdefer {
        if (!demo_ended) std.debug.print("[c-matrix] FAIL demo={s}\n", .{path});
    }

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const base = std.fs.path.basename(path);
    const stem = std.fs.path.stem(base);
    const parent = std.fs.path.dirname(path) orelse ".";
    const tag = std.fs.path.basename(parent);
    const c_name = try std.fmt.allocPrint(std.testing.allocator, "{s}_{s}.c", .{ tag, stem });
    defer std.testing.allocator.free(c_name);
    const exe_name = try std.fmt.allocPrint(std.testing.allocator, "{s}_{s}_c", .{ tag, stem });
    defer std.testing.allocator.free(exe_name);

    const build_c_argv = [_][]const u8{"sars", "build-c", source_path, "-o", c_name, "--project-root", repo_root };
    const build_c_code = saasm.cli.execute(std.testing.allocator, build_c_argv[0..]) catch |err| {
        std.debug.print("build-c errored: {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    if (build_c_code != 0) std.debug.print("build-c failed: {s}\n", .{path});
    try std.testing.expectEqual(@as(u8, 0), build_c_code);

    const cc_argv = [_][]const u8{ "cc", c_name, "-o", exe_name };
    const cc_res = try sio.Child.run(.{ .allocator = std.testing.allocator, .argv = cc_argv[0..] });
    defer std.testing.allocator.free(cc_res.stdout);
    defer std.testing.allocator.free(cc_res.stderr);
    switch (cc_res.term) {
        .exited => |code| {
            if (code != 0) std.debug.print("cc failed: {s}\nstdout:\n{s}\nstderr:\n{s}\n", .{ path, cc_res.stdout, cc_res.stderr });
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => return error.TestUnexpectedResult,
    }

    const exe_path = try std.fmt.allocPrint(std.testing.allocator, "./{s}", .{exe_name});
    defer std.testing.allocator.free(exe_path);
    const c_result = try sio.Child.run(.{ .allocator = std.testing.allocator, .argv = &.{exe_path} });
    defer std.testing.allocator.free(c_result.stdout);
    defer std.testing.allocator.free(c_result.stderr);
    switch (c_result.term) {
        .exited => |code| {
            if (code != 0 or !std.mem.eql(u8, c_result.stdout, expected_stdout) or c_result.stderr.len != 0) {
                std.debug.print("c demo failed: {s}\nstdout:\n{s}\nstderr:\n{s}\n", .{ path, c_result.stdout, c_result.stderr });
            }
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings(expected_stdout, c_result.stdout);
    try std.testing.expectEqual(@as(usize, 0), c_result.stderr.len);

    std.debug.print("[c-matrix] END   demo={s} elapsed={}ms\n", .{ path, elapsedMs(demo_start) });
    demo_ended = true;
}

test "c backend rosetta demos match expected output under cc" {
    try assertCMatrixStdout("demos/c/01_hello_world/main.sa", "hello, saasm\n");
    try assertCMatrixStdout("demos/rosetta/02_mutability/main.sa", "20\n");
    try assertCMatrixStdout("demos/rosetta/03_if_else/main.sa", "20\n");
    try assertCMatrixStdout("demos/rosetta/04_loop/main.sa", "[0,0,0,0]\n");
    try assertCMatrixStdout("demos/rosetta/05_struct/main.sa", "(10,20)\n");
    try assertCMatrixStdout("demos/rosetta/24_factorial/main.sa", "120\n");
    try assertCMatrixStdout("demos/rosetta/25_fibonacci/main.sa", "21\n");
    try assertCMatrixStdout("demos/rosetta/21_while_loop/main.sa", "15\n");
    try assertCMatrixStdout("demos/rosetta/23_nested_loops/main.sa", "18\n");
    try assertCMatrixStdout("demos/rosetta/13_array_sum/main.sa", "10\n");
}

test "c backend emits sane C for hello world" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const repo_root = try original_cwd.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(repo_root);
    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "demos/c/01_hello_world/main.sa");
    defer std.testing.allocator.free(source_path);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const build_c_argv = [_][]const u8{"sars", "build-c", source_path, "-o", "hello.c", "--project-root", repo_root };
    const code = saasm.cli.execute(std.testing.allocator, build_c_argv[0..]) catch |err| return err;
    try std.testing.expectEqual(@as(u8, 0), code);

    const c_file = try tmp.dir.openFile(std.testing.io, "hello.c", .{});
    defer c_file.close(std.testing.io);
    var rbuf: [8192]u8 = undefined;
    var reader = c_file.reader(std.testing.io, &rbuf);
    const bytes = try reader.interface.allocRemaining(std.testing.allocator, .limited(1 << 24));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len > 512);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "sa_fn_main") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "sa_print_bytes") != null);
}

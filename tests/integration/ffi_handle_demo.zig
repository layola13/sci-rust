const std = @import("std");
const builtin = @import("builtin");
const saasm = @import("saasm");
const sio = @import("sio");

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try sio.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) return error.TestUnexpectedResult;
        },
        else => return error.TestUnexpectedResult,
    }

    return result.stdout;
}

test "ffi handle demo exposes an exported C ABI symbol" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const sa_source = try original_cwd.realpathAlloc(std.testing.allocator, "tests/integration/ffi_handle/handle.sars");
    defer std.testing.allocator.free(sa_source);
    const c_source = try original_cwd.realpathAlloc(std.testing.allocator, "tests/integration/ffi_handle/handle_host.c");
    defer std.testing.allocator.free(c_source);
    const include_dir = try original_cwd.realpathAlloc(std.testing.allocator, "src");
    defer std.testing.allocator.free(include_dir);

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const build_obj_argv = [_][]const u8{ "sa", "build-obj", sa_source, "-o", "handle.o" };
    try std.testing.expectEqual(@as(u8, 0), try saasm.cli.execute(std.testing.allocator, build_obj_argv[0..]));

    const artifact_file = try sio.cwd().openFile("handle.o.sa.bc", .{});
    defer artifact_file.close();
    const artifact_bytes = try artifact_file.readToEndAlloc(std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(artifact_bytes);
    try std.testing.expect(artifact_bytes.len > 0);

    const cc_argv = [_][]const u8{
        "zig",
        "cc",
        "-I",
        include_dir,
        c_source,
        "handle.o",
        "-o",
        "handle_demo",
    };
    const cc_result = try sio.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = cc_argv[0..],
    });
    defer std.testing.allocator.free(cc_result.stdout);
    defer std.testing.allocator.free(cc_result.stderr);
    switch (cc_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }

    const output = try runCommand(std.testing.allocator, &[_][]const u8{"./handle_demo"});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        if (builtin.os.tag == .windows) "42\r\n" else "42\n",
        output,
    );
}

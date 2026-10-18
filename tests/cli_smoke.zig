const std = @import("std");
const saasm = @import("saasm");
const builtin = @import("builtin");
const sio = @import("sio");

fn parseJsonValue(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
}

fn jsonObjectGet(parsed: *const std.json.Parsed(std.json.Value), key: []const u8) !std.json.Value {
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.TestUnexpectedResult,
    };
    return root.get(key) orelse return error.TestUnexpectedResult;
}

fn jsonObjectGetValue(value: std.json.Value, key: []const u8) !std.json.Value {
    const object = switch (value) {
        .object => |object| object,
        else => return error.TestUnexpectedResult,
    };
    return object.get(key) orelse return error.TestUnexpectedResult;
}

fn jsonBoolValue(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |v| v,
        else => error.TestUnexpectedResult,
    };
}

fn jsonArrayCount(value: std.json.Value) !usize {
    return switch (value) {
        .array => |array| array.items.len,
        else => error.TestUnexpectedResult,
    };
}

fn jsonStringValue(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.TestUnexpectedResult,
    };
}

fn writeSource(dir: std.Io.Dir, path: []const u8, source: []const u8) !void {
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    var wbuf: [8192]u8 = undefined;
    var w = file.writer(std.testing.io, &wbuf);
    try w.interface.writeAll(source);
    try w.interface.flush();
}

fn writeBytes(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    var wbuf: [8192]u8 = undefined;
    var w = file.writer(std.testing.io, &wbuf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn containsPortablePath(allocator: std.mem.Allocator, text: []const u8, slash_path: []const u8) !bool {
    const normalized_text = try allocator.dupe(u8, text);
    defer allocator.free(normalized_text);
    for (normalized_text) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    const normalized_path = try allocator.dupe(u8, slash_path);
    defer allocator.free(normalized_path);
    return std.mem.containsAtLeast(u8, normalized_text, 1, normalized_path);
}

fn bytesHashHex(bytes: []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn writeCacheManifest(dir: std.Io.Dir, cache_dir: []const u8, kind: []const u8, key: []const u8, artifact: []const u8, output: []const u8) !void {
    const artifact_hash = bytesHashHex(artifact);
    const output_hash = bytesHashHex(output);
    const manifest = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"version\":1,\"kind\":\"{s}\",\"key\":\"{s}\",\"artifact\":{{\"size\":{d},\"sha256\":\"{s}\"}},\"output\":{{\"size\":{d},\"sha256\":\"{s}\"}}}}\n",
        .{ kind, key, artifact.len, artifact_hash[0..], output.len, output_hash[0..] },
    );
    defer std.testing.allocator.free(manifest);
    const manifest_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/manifest.json", .{cache_dir});
    defer std.testing.allocator.free(manifest_path);
    try writeBytes(dir, manifest_path, manifest);
}

fn freeStringMtimeMap(allocator: std.mem.Allocator, map: *std.StringHashMap(i128)) void {
    var iter = map.iterator();
    while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
    map.deinit();
}

fn cachedFunctionObjectMtimes(allocator: std.mem.Allocator, dir: std.Io.Dir) !std.StringHashMap(i128) {
    var result = std.StringHashMap(i128).init(allocator);
    errdefer freeStringMtimeMap(allocator, &result);

    var cache_root = try dir.openDir(std.testing.io, ".sa_cache/build-obj-incremental", .{ .iterate = true });
    defer cache_root.close(std.testing.io);
    var cache_iter = cache_root.iterate();
    while (try cache_iter.next(std.testing.io)) |cache_entry| {
        if (cache_entry.kind != .directory) continue;
        var functions_dir = cache_root.openDir(std.testing.io, cache_entry.name, .{ .iterate = true }) catch continue;
        defer functions_dir.close(std.testing.io);
        var object_dir = functions_dir.openDir(std.testing.io, "functions", .{ .iterate = true }) catch continue;
        defer object_dir.close(std.testing.io);

        var object_iter = object_dir.iterate();
        while (try object_iter.next(std.testing.io)) |object_entry| {
            if (object_entry.kind != .file or !std.mem.endsWith(u8, object_entry.name, ".o")) continue;
            const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_entry.name, object_entry.name });
            errdefer allocator.free(key);
            const stat = try object_dir.statFile(std.testing.io, object_entry.name, .{});
            try result.put(key, @as(i128, stat.mtime.toNanoseconds()));
        }
    }
    return result;
}

fn cachedFunctionManifestCount(dir: std.Io.Dir) !usize {
    var count: usize = 0;
    var cache_root = try dir.openDir(std.testing.io, ".sa_cache/build-obj-incremental", .{ .iterate = true });
    defer cache_root.close(std.testing.io);
    var cache_iter = cache_root.iterate();
    while (try cache_iter.next(std.testing.io)) |cache_entry| {
        if (cache_entry.kind != .directory) continue;
        var entry_dir = cache_root.openDir(std.testing.io, cache_entry.name, .{ .iterate = true }) catch continue;
        defer entry_dir.close(std.testing.io);
        const manifest = entry_dir.openFile(std.testing.io, "manifest.json", .{}) catch continue;
        manifest.close(std.testing.io);
        count += 1;
    }
    return count;
}

fn singleCacheEntryName(allocator: std.mem.Allocator, dir: std.Io.Dir, rel_path: []const u8) ![]u8 {
    var cache_root = try dir.openDir(std.testing.io, rel_path, .{ .iterate = true });
    defer cache_root.close(std.testing.io);
    var cache_iter = cache_root.iterate();
    var found: ?[]u8 = null;
    errdefer if (found) |name| allocator.free(name);
    while (try cache_iter.next(std.testing.io)) |entry| {
        if (entry.kind != .directory) continue;
        if (found != null) return error.TestUnexpectedResult;
        found = try allocator.dupe(u8, entry.name);
    }
    return found orelse error.FileNotFound;
}

fn cacheEntryCount(dir: std.Io.Dir, rel_path: []const u8) !usize {
    var cache_root = try dir.openDir(std.testing.io, rel_path, .{ .iterate = true });
    defer cache_root.close(std.testing.io);
    var cache_iter = cache_root.iterate();
    var count: usize = 0;
    while (try cache_iter.next(std.testing.io)) |entry| {
        if (entry.kind == .directory) count += 1;
    }
    return count;
}

fn writeManifestForPackage(
    dir: std.Io.Dir,
    project_root: []const u8,
    package_url: []const u8,
    package_root: []const u8,
    grants_clause: []const u8,
) !void {
    var report = try saasm.pkg.audit.auditPackage(std.testing.allocator, package_url, "HEAD", package_root, &.{});
    defer report.deinit(std.testing.allocator);
    const hash_hex = std.fmt.bytesToHex(report.source_sha256, .lower);
    const manifest_source = try std.fmt.allocPrint(
        std.testing.allocator,
        "require {s} @HEAD sha256:{s}{s}\n",
        .{ package_url, hash_hex[0..], grants_clause },
    );
    defer std.testing.allocator.free(manifest_source);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ project_root, "sa.mod" });
    defer std.testing.allocator.free(manifest_path);
    try writeSource(dir, manifest_path, manifest_source);
}

fn writeProjectSum(dir: std.Io.Dir, project_root: []const u8) !void {
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ project_root, "sa.mod" });
    defer std.testing.allocator.free(manifest_path);
    const manifest_source = try dir.readFileAlloc(std.testing.io, manifest_path, std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(manifest_source);
    var project_manifest = try saasm.pkg.manifest.parseManifestWithFile(std.testing.allocator, manifest_source, manifest_path);
    defer project_manifest.deinit(std.testing.allocator);
    const root_abs = try dir.realPathFileAlloc(std.testing.io, project_root, std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    var update = try saasm.pkg.sum.updateProjectSum(std.testing.allocator, root_abs, project_manifest);
    defer update.deinit(std.testing.allocator);
}

fn expectNoTextLlvmArtifacts(dir: std.Io.Dir, out_name: []const u8) !void {
    const ll_name = try std.fmt.allocPrint(std.testing.allocator, "{s}.ll", .{out_name});
    defer std.testing.allocator.free(ll_name);
    const sa_ll_name = try std.fmt.allocPrint(std.testing.allocator, "{s}.sa.ll", .{out_name});
    defer std.testing.allocator.free(sa_ll_name);

    try std.testing.expectError(error.FileNotFound, dir.openFile(std.testing.io, ll_name, .{}));
    try std.testing.expectError(error.FileNotFound, dir.openFile(std.testing.io, sa_ll_name, .{}));
}

fn extractLineValue(output: []const u8, prefix: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, output, prefix) orelse return error.NotFound;
    const value_start = start + prefix.len;
    const value_end = std.mem.indexOfScalarPos(u8, output, value_start, '\n') orelse output.len;
    return std.mem.trim(u8, output[value_start..value_end], " \t\r");
}

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

fn runCommandAnyExit(allocator: std.mem.Allocator, argv: []const []const u8) !sio.Child.RunResult {
    return try sio.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
}

fn runCommandAnyExitWithEnvMap(allocator: std.mem.Allocator, argv: []const []const u8, env_map: *const sio.EnvMap) !sio.Child.RunResult {
    return try sio.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .env_map = env_map,
    });
}
fn llvmDisAvailable() bool {
    // bc2sa invokes llvm-dis to disassemble bitcode; skip the test when the tool is absent.
    const probes = [_][]const u8{ "llvm-dis-14", "llvm-dis" };
    for (probes) |probe| {
        const result = sio.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &[_][]const u8{ probe, "--version" },
        }) catch continue;
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return true,
            else => {},
        }
    }
    return false;
}

fn clangAvailable() bool {
    const probes = [_][]const u8{ "clang", "clang.exe" };
    for (probes) |probe| {
        const result = sio.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &[_][]const u8{ probe, "--version" },
        }) catch continue;
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return true,
            else => {},
        }
    }
    return false;
}

fn runWasmWithNode(allocator: std.mem.Allocator, wasm_path: []const u8, args: []const []const u8) !sio.Child.RunResult {
    const args_json = try std.json.Stringify.valueAlloc(allocator, args, .{});
    defer allocator.free(args_json);
    const wasm_json = try std.json.Stringify.valueAlloc(allocator, wasm_path, .{});
    defer allocator.free(wasm_json);

    const script = try std.fmt.allocPrint(allocator,
        \\const fs = require('node:fs');
        \\const {{ WASI }} = require('node:wasi');
        \\const wasi = new WASI({{
        \\  version: 'preview1',
        \\  args: {s},
        \\  env: {{}},
        \\  preopens: {{ '/': '.' }},
        \\}});
        \\const wasm = fs.readFileSync({s});
        \\WebAssembly.instantiate(wasm, wasi.getImportObject()).then(({{ instance }}) => {{
        \\  process.exitCode = wasi.start(instance);
        \\}}).catch((err) => {{
        \\  console.error(err);
        \\  process.exit(1);
        \\}});
    , .{ args_json, wasm_json });
    defer allocator.free(script);

    const script_path = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(wasm_path) orelse ".", "run_wasm.js" });
    defer allocator.free(script_path);
    try writeSource(std.Io.Dir.cwd(), script_path, script);
    return try sio.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "node", "--no-warnings", script_path },
    });
}

fn assertRunStdout(path: []const u8, expected_stdout: []const u8) !void {
    var stdout_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const run_argv = [_][]const u8{"sars", "run", path };
    const run_code = try saasm.cli.executeWithWriters(std.testing.allocator, run_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    if (run_code != 0 or stderr_buf.items.len != 0 or !std.mem.eql(u8, stdout_buf.items, expected_stdout)) {
        std.debug.print("demo run failed: {s}\nstdout:\n{s}\nstderr:\n{s}\n", .{ path, stdout_buf.items, stderr_buf.items });
    }
    try std.testing.expectEqual(@as(u8, 0), run_code);
    try std.testing.expectEqualStrings(expected_stdout, stdout_buf.items);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

fn assertBuildExeStdout(path: []const u8, expected_stdout: []const u8) !void {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const print_iface = try original_cwd.realpathAlloc(std.testing.allocator, "sa_std/io/print.sai");
    defer std.testing.allocator.free(print_iface);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(source_path);

    try tmp.dir.createDirPath(std.testing.io, "bin");

    const demo_dir = std.fs.path.basename(std.fs.path.dirname(path).?);
    const out_path = try std.fmt.allocPrint(std.testing.allocator, "bin/{s}.out", .{demo_dir});
    defer std.testing.allocator.free(out_path);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", out_path, "--no-incremental" };
    const build_exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    if (build_exe_code != 0) {
        std.debug.print("build-exe failed: {s}\n", .{path});
    }
    try std.testing.expectEqual(@as(u8, 0), build_exe_code);

    const exe_path = try std.fmt.allocPrint(std.testing.allocator, "./{s}", .{out_path});
    defer std.testing.allocator.free(exe_path);

    const exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{exe_path});
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| {
            if (code != 0 or !std.mem.eql(u8, exe_result.stdout, expected_stdout) or exe_result.stderr.len != 0) {
                std.debug.print("native demo failed: {s}\nstdout:\n{s}\nstderr:\n{s}\n", .{ path, exe_result.stdout, exe_result.stderr });
            }
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => |term| {
            std.debug.print("native demo terminated unexpectedly: {s}\nterm: {any}\nstdout:\n{s}\nstderr:\n{s}\n", .{ path, term, exe_result.stdout, exe_result.stderr });
            return error.TestUnexpectedResult;
        },
    }
    try std.testing.expectEqualStrings(expected_stdout, exe_result.stdout);
    try std.testing.expectEqual(@as(usize, 0), exe_result.stderr.len);
}

fn assertBuildExeStdoutPureBc(path: []const u8, expected_stdout: []const u8) !void {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const print_iface = try original_cwd.realpathAlloc(std.testing.allocator, "sa_std/io/print.sai");
    defer std.testing.allocator.free(print_iface);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(source_path);

    try tmp.dir.createDirPath(std.testing.io, "bin");

    const demo_dir = std.fs.path.basename(std.fs.path.dirname(path).?);
    const out_path = try std.fmt.allocPrint(std.testing.allocator, "bin/{s}.out", .{demo_dir});
    defer std.testing.allocator.free(out_path);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", out_path };
    const build_exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    if (build_exe_code != 0) {
        std.debug.print("build-exe failed: {s}\n", .{path});
    }
    try std.testing.expectEqual(@as(u8, 0), build_exe_code);

    const exe_path = try std.fmt.allocPrint(std.testing.allocator, "./{s}", .{out_path});
    defer std.testing.allocator.free(exe_path);

    const exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{exe_path});
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| {
            if (code != 0 or !std.mem.eql(u8, exe_result.stdout, expected_stdout) or exe_result.stderr.len != 0) {
                std.debug.print("native demo failed: {s}\nstdout:\n{s}\nstderr:\n{s}\n", .{ path, exe_result.stdout, exe_result.stderr });
            }
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings(expected_stdout, exe_result.stdout);
    try std.testing.expectEqual(@as(usize, 0), exe_result.stderr.len);
}

fn assertBuildExeTrap(path: []const u8, out_name: []const u8, expected_trap: []const u8, expected_trap_code: u32, expected_message: []const u8) !void {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(source_path);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", out_name };
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        build_exe_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, out_name, .{}));
    const bc_name = try std.fmt.allocPrint(std.testing.allocator, "{s}.sa.bc", .{out_name});
    defer std.testing.allocator.free(bc_name);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, bc_name, .{}));
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);

    var trap_buf: [64]u8 = undefined;
    const trap_text = try std.fmt.bufPrint(&trap_buf, "\"trap\":\"{s}\"", .{expected_trap});
    var code_buf: [32]u8 = undefined;
    const code_text = try std.fmt.bufPrint(&code_buf, "\"trap_code\":{d}", .{expected_trap_code});
    var summary_buf: [256]u8 = undefined;
    const summary_text = try std.fmt.bufPrint(&summary_buf, "error[{s}]: {s}\n", .{ expected_trap, expected_message });
    try std.testing.expect(std.mem.startsWith(u8, stderr_buffer.items, summary_text));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, trap_text));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, code_text));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, expected_message));
}

fn assertBuildExeLinkFailure(source_name: []const u8, source: []const u8, out_name: []const u8, expected_fragment: []const u8) !void {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, source_name, source);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_name, "-o", out_name };
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        build_exe_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, out_name, .{}));
    try std.testing.expect(std.mem.startsWith(u8, stderr_buffer.items, "error[ExternalCompiler]: zig cc exited with code 1 while linking "));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "  command: zig cc "));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, expected_fragment));
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "error: ChildProcessFailed") == null);
}

fn assertRunStdoutWithArg(path: []const u8, arg: []const u8, expected_stdout: []const u8) !void {
    var stdout_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const run_argv = [_][]const u8{"sars", "run", path, arg };
    const run_code = try saasm.cli.executeWithWriters(std.testing.allocator, run_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    if (run_code != 0 or stderr_buf.items.len != 0 or !std.mem.eql(u8, stdout_buf.items, expected_stdout)) {
        std.debug.print("demo run failed: {s}\nstdout:\n{s}\nstderr:\n{s}\n", .{ path, stdout_buf.items, stderr_buf.items });
    }
    try std.testing.expectEqual(@as(u8, 0), run_code);
    try std.testing.expectEqualStrings(expected_stdout, stdout_buf.items);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

fn containsImportName(import_names: []const []const u8, expected: []const u8) bool {
    for (import_names) |name| {
        if (std.mem.eql(u8, name, expected)) return true;
    }
    return false;
}

fn skipLimits(reader: anytype) !void {
    const flags = try std.leb.readUleb128(u32, reader);
    _ = try std.leb.readUleb128(u32, reader);
    if ((flags & 1) != 0) {
        _ = try std.leb.readUleb128(u32, reader);
    }
}

fn wasmImportNames(bytes: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    if (bytes.len < 8) return error.InvalidWasm;
    if (!std.mem.eql(u8, bytes[0..4], &std.wasm.magic)) return error.InvalidWasm;
    if (!std.mem.eql(u8, bytes[4..8], &std.wasm.version)) return error.InvalidWasm;

    var names = std.array_list.Managed([]const u8).init(allocator);
    errdefer names.deinit();

    var fbs = std.io.fixedBufferStream(bytes[8..]);
    const reader = fbs.reader();
    while (fbs.pos < bytes.len - 8) {
        const section_id = reader.readByte() catch break;
        const section = std.meta.intToEnum(std.wasm.Section, section_id) catch return error.InvalidWasm;
        const section_len = try std.leb.readUleb128(u32, reader);
        const section_end = fbs.pos + @as(usize, @intCast(section_len));
        if (section_end > fbs.buffer.len) return error.InvalidWasm;
        const section_bytes = fbs.buffer[fbs.pos..section_end];
        if (section == .import) {
            var import_fbs = std.io.fixedBufferStream(section_bytes);
            const import_reader = import_fbs.reader();
            const import_count = try std.leb.readUleb128(u32, import_reader);
            var i: u32 = 0;
            while (i < import_count) : (i += 1) {
                const module_len = try std.leb.readUleb128(u32, import_reader);
                const module_end = import_fbs.pos + @as(usize, @intCast(module_len));
                if (module_end > section_bytes.len) return error.InvalidWasm;
                const module_name = section_bytes[import_fbs.pos..module_end];
                import_fbs.pos = module_end;
                const name_len = try std.leb.readUleb128(u32, import_reader);
                const name_end = import_fbs.pos + @as(usize, @intCast(name_len));
                if (name_end > section_bytes.len) return error.InvalidWasm;
                const import_name = section_bytes[import_fbs.pos..name_end];
                import_fbs.pos = name_end;
                _ = module_name;

                const kind_byte = try import_reader.readByte();
                const kind = std.meta.intToEnum(std.wasm.ExternalKind, kind_byte) catch return error.InvalidWasm;
                switch (kind) {
                    .function => {
                        _ = try std.leb.readUleb128(u32, import_reader);
                    },
                    .table => {
                        _ = try import_reader.readByte();
                        try skipLimits(import_reader);
                    },
                    .memory => {
                        try skipLimits(import_reader);
                    },
                    .global => {
                        _ = try import_reader.readByte();
                        _ = try std.leb.readUleb128(u1, import_reader);
                    },
                }
                try names.append(import_name);
            }
        }
        fbs.pos += section_len;
    }
    return try names.toOwnedSlice();
}

test "cli run/build-exe/build-wasm produce real artifacts" {
    const source =
        \\#loc "hello.rs":10:4
        \\@ffi_wrapper probe_fallible_i32_wire() -> i32:
        \\node = alloc 8
        \\!node
        \\return 7
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, "sample.sars", source);

    const run_argv = [_][]const u8{"sars", "run", "sample.sars" };
    const run_code = try saasm.cli.execute(std.testing.allocator, run_argv[0..]);
    try std.testing.expectEqual(@as(u8, 7), run_code);

    const exe_path = "sample.out";
    const build_exe_argv = [_][]const u8{"sars", "build-exe", "sample.sars", "-o", exe_path, "-g" };
    const exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), exe_code);

    const exe = try tmp.dir.openFile(std.testing.io, exe_path, .{});
    const exe_bytes = try sio.readToEndAlloc(exe, std.testing.allocator, 1 << 20);
    exe.close(std.testing.io);
    defer std.testing.allocator.free(exe_bytes);
    try std.testing.expect(exe_bytes.len > 0);

    const artifact_path = "sample.out.sa.bc";
    const artifact = try tmp.dir.openFile(std.testing.io, artifact_path, .{});
    const artifact_bytes = try sio.readToEndAlloc(artifact, std.testing.allocator, 1 << 20);
    artifact.close(std.testing.io);
    defer std.testing.allocator.free(artifact_bytes);
    try std.testing.expect(artifact_bytes.len > 0);

    try tmp.dir.deleteFile(std.testing.io, exe_path);
    try tmp.dir.deleteFile(std.testing.io, artifact_path);
    const cached_exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), cached_exe_code);
    const cached_artifact = try tmp.dir.openFile(std.testing.io, artifact_path, .{});
    cached_artifact.close(std.testing.io);
    if (builtin.os.tag != .windows) {
        const cached_exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./sample.out"});
        defer std.testing.allocator.free(cached_exe_result.stdout);
        defer std.testing.allocator.free(cached_exe_result.stderr);
        switch (cached_exe_result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 7), code),
            else => return error.TestUnexpectedResult,
        }
    }

    const obj_path = "sample.o";
    const build_obj_argv = [_][]const u8{"sars", "build-obj", "sample.sars", "--jobs", "auto", "-o", obj_path };
    const obj_code = try saasm.cli.execute(std.testing.allocator, build_obj_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), obj_code);

    const obj = try tmp.dir.openFile(std.testing.io, obj_path, .{});
    defer obj.close(std.testing.io);
    const obj_bytes = try sio.readToEndAlloc(obj, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(obj_bytes);
    try std.testing.expect(obj_bytes.len > 0);

    const wasm_path = "sample.wasm";
    const build_wasm_argv = [_][]const u8{"sars", "build-wasm", "sample.sars", "--jobs", "auto", "-o", wasm_path, "--target", "wasm32" };
    const wasm_code = try saasm.cli.execute(std.testing.allocator, build_wasm_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), wasm_code);

    const wasm = try tmp.dir.openFile(std.testing.io, wasm_path, .{});
    defer wasm.close(std.testing.io);
    const wasm_bytes = try sio.readToEndAlloc(wasm, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(wasm_bytes);
    try std.testing.expect(wasm_bytes.len > 8);
    try std.testing.expectEqualSlices(u8, &std.wasm.magic, wasm_bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &std.wasm.version, wasm_bytes[4..8]);
}

test "cli default executable suffix is target aware" {
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings(".exe", saasm.cli.defaultExecutableSuffix());
    } else {
        try std.testing.expectEqualStrings("", saasm.cli.defaultExecutableSuffix());
    }
}

test "llvm disabled build-exe reports backend diagnostic" {
    if (saasm.build_options.llvm_enabled) return error.SkipZigTest;

    const source =
        \\@main() -> i32:
        \\return 0
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, "minimal.sars", source);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "minimal.sars" };
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        build_exe_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "error[LLVMBackend]: llvmc backend: LLVM-C backend is disabled in this build"));

    const default_out = try std.fmt.allocPrint(std.testing.allocator, "minimal{s}", .{saasm.cli.defaultExecutableSuffix()});
    defer std.testing.allocator.free(default_out);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, default_out, .{}));
}

test "cli build-obj incremental reuses local cache layout" {
    const source =
        \\@helper(value: i32) -> i32:
        \\return value + 1
        \\
        \\@main() -> i32:
        \\value = call @helper(6)
        \\return value
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, "incremental.sars", source);

    const build_argv = [_][]const u8{"sars", "build-obj", "incremental.sars", "--incremental", "-o", "incremental.o" };
    const first_code = try saasm.cli.execute(std.testing.allocator, build_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), first_code);
    const second_code = try saasm.cli.execute(std.testing.allocator, build_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), second_code);

    var before_mtimes = try cachedFunctionObjectMtimes(std.testing.allocator, tmp.dir);
    defer freeStringMtimeMap(std.testing.allocator, &before_mtimes);
    try std.testing.expectEqual(@as(u32, 2), before_mtimes.count());

    const modified_source =
        \\@helper(value: i32) -> i32:
        \\return value + 2
        \\
        \\@main() -> i32:
        \\value = call @helper(6)
        \\return value
    ;
    try writeSource(tmp.dir, "incremental.sars", modified_source);
    const modified_code = try saasm.cli.execute(std.testing.allocator, build_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), modified_code);

    var after_mtimes = try cachedFunctionObjectMtimes(std.testing.allocator, tmp.dir);
    defer freeStringMtimeMap(std.testing.allocator, &after_mtimes);
    try std.testing.expect(after_mtimes.count() >= 3);

    var reused_count: usize = 0;
    var before_iter = before_mtimes.iterator();
    while (before_iter.next()) |entry| {
        if (after_mtimes.get(entry.key_ptr.*)) |mtime| {
            if (mtime == entry.value_ptr.*) reused_count += 1;
        }
    }
    try std.testing.expect(reused_count >= 1);

    const obj_file = try tmp.dir.openFile(std.testing.io, "incremental.o", .{});
    defer obj_file.close(std.testing.io);
    const obj_bytes = try sio.readToEndAlloc(obj_file, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(obj_bytes);
    try std.testing.expect(obj_bytes.len > 0);

    const bc_file = try tmp.dir.openFile(std.testing.io, "incremental.o.sa.bc", .{});
    defer bc_file.close(std.testing.io);
    const bc_bytes = try sio.readToEndAlloc(bc_file, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(bc_bytes);
    try std.testing.expect(bc_bytes.len > 0);

    var cache_dir = try tmp.dir.openDir(std.testing.io, ".sa_cache/build-obj-incremental", .{ .iterate = true });
    defer cache_dir.close();
    var cache_iter = cache_dir.iterate();
    try std.testing.expect((try cache_iter.next()) != null);
    try std.testing.expect(try cachedFunctionManifestCount(tmp.dir) >= 1);

    var stdout_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const help_argv = [_][]const u8{"sars", "build-obj", "--help" };
    const help_code = try saasm.cli.executeWithWriters(std.testing.allocator, help_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 0), help_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "--incremental") != null);
}

test "cli build project cache is default and can be disabled" {
    const source =
        \\@main() -> i32:
        \\return 9
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, "cached.sars", source);

    var stdout_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const build_argv = [_][]const u8{"sars", "build-exe", "cached.sars", "-o", "cached.out", "--json", "--profile" };
    const first_code = try saasm.cli.executeWithWriters(std.testing.allocator, build_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 0), first_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
    var first_json = try parseJsonValue(std.testing.allocator, stderr_buf.items);
    defer first_json.deinit();
    const first_metrics = try jsonObjectGet(&first_json, "metrics");
    const first_cache = try jsonObjectGetValue(first_metrics, "cache");
    try std.testing.expectEqualStrings("build-exe", try jsonStringValue(try jsonObjectGetValue(first_cache, "kind")));
    try std.testing.expectEqual(false, try jsonBoolValue(try jsonObjectGetValue(first_cache, "hit")));

    try tmp.dir.deleteFile(std.testing.io, "cached.out");
    try tmp.dir.deleteFile(std.testing.io, "cached.out.sa.bc");
    stderr_buf.clearRetainingCapacity();
    const second_code = try saasm.cli.executeWithWriters(std.testing.allocator, build_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 0), second_code);
    var second_json = try parseJsonValue(std.testing.allocator, stderr_buf.items);
    defer second_json.deinit();
    const second_metrics = try jsonObjectGet(&second_json, "metrics");
    const second_cache = try jsonObjectGetValue(second_metrics, "cache");
    try std.testing.expectEqual(true, try jsonBoolValue(try jsonObjectGetValue(second_cache, "hit")));

    stderr_buf.clearRetainingCapacity();
    const no_cache_argv = [_][]const u8{"sars", "build-exe", "cached.sars", "-o", "cached_no_cache.out", "--json", "--profile", "--no-incremental" };
    const no_cache_code = try saasm.cli.executeWithWriters(std.testing.allocator, no_cache_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 0), no_cache_code);
    var no_cache_json = try parseJsonValue(std.testing.allocator, stderr_buf.items);
    defer no_cache_json.deinit();
    const no_cache_metrics = try jsonObjectGet(&no_cache_json, "metrics");
    try std.testing.expectError(error.TestUnexpectedResult, jsonObjectGetValue(no_cache_metrics, "cache"));

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const help_argv = [_][]const u8{"sars", "build-exe", "--help" };
    const help_code = try saasm.cli.executeWithWriters(std.testing.allocator, help_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 0), help_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "--no-incremental") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "--mem-report") != null);
}

test "cli cache clean removes invalid project cache entries" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const good_key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const incomplete_key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const corrupt_manifest_key = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    try tmp.dir.createDirPath(std.testing.io, ".sa_cache/build-exe/" ++ good_key);
    try writeBytes(tmp.dir, ".sa_cache/build-exe/" ++ good_key ++ "/artifact.sa.bc", "bc");
    try writeBytes(tmp.dir, ".sa_cache/build-exe/" ++ good_key ++ "/output.bin", "exe");
    try writeCacheManifest(tmp.dir, ".sa_cache/build-exe/" ++ good_key, "build-exe", good_key, "bc", "exe");
    try tmp.dir.createDirPath(std.testing.io, ".sa_cache/build-exe/" ++ incomplete_key);
    try writeBytes(tmp.dir, ".sa_cache/build-exe/" ++ incomplete_key ++ "/artifact.sa.bc", "bc");
    try tmp.dir.createDirPath(std.testing.io, ".sa_cache/build-exe/" ++ corrupt_manifest_key);
    try writeBytes(tmp.dir, ".sa_cache/build-exe/" ++ corrupt_manifest_key ++ "/artifact.sa.bc", "bc");
    try writeBytes(tmp.dir, ".sa_cache/build-exe/" ++ corrupt_manifest_key ++ "/output.bin", "exe");
    try writeCacheManifest(tmp.dir, ".sa_cache/build-exe/" ++ corrupt_manifest_key, "build-exe", corrupt_manifest_key, "bc", "wrong-output");
    try tmp.dir.createDirPath(std.testing.io, ".sa_cache/test/not-a-hex-key");

    var stdout_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const clean_argv = [_][]const u8{"sars", "cache", "clean", "--max-age-days", "0" };
    const clean_code = try saasm.cli.executeWithWriters(std.testing.allocator, clean_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 0), clean_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "cache clean: scanned=4 removed=3 kept=1"));

    try tmp.dir.access(std.testing.io, ".sa_cache/build-exe/" ++ good_key ++ "/output.bin", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, ".sa_cache/build-exe/" ++ incomplete_key, .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, ".sa_cache/build-exe/" ++ corrupt_manifest_key, .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, ".sa_cache/test/not-a-hex-key", .{}));

    stdout_buf.clearRetainingCapacity();
    const help_argv = [_][]const u8{"sars", "cache", "clean", "--help" };
    const help_code = try saasm.cli.executeWithWriters(std.testing.allocator, help_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 0), help_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "--max-age-days") != null);
}

test "sa test compile-only reuses and repairs project test cache" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const source =
        \\@test "cached test compile"():
        \\L_ENTRY:
        \\    return
    ;
    try writeSource(tmp.dir, "cached_test.sars", source);

    var stdout_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const test_argv = [_][]const u8{"sars", "test", "cached_test.sars", "--compile-only", "--jobs", "1" };
    const first_code = try saasm.cli.executeWithWriters(std.testing.allocator, test_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 0), first_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "compiled 1 selected tests (1 discovered)"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
    try std.testing.expectEqual(@as(usize, 1), try cacheEntryCount(tmp.dir, ".sa_cache/test"));

    const cache_key = try singleCacheEntryName(std.testing.allocator, tmp.dir, ".sa_cache/test");
    defer std.testing.allocator.free(cache_key);
    const cached_output = try std.fmt.allocPrint(std.testing.allocator, ".sa_cache/test/{s}/output.bin", .{cache_key});
    defer std.testing.allocator.free(cached_output);
    const cached_manifest = try std.fmt.allocPrint(std.testing.allocator, ".sa_cache/test/{s}/manifest.json", .{cache_key});
    defer std.testing.allocator.free(cached_manifest);
    const cached_metadata = try std.fmt.allocPrint(std.testing.allocator, ".sa_cache/test/{s}/test-metadata.json", .{cache_key});
    defer std.testing.allocator.free(cached_metadata);
    try tmp.dir.access(std.testing.io, cached_manifest, .{});
    const metadata_bytes = try tmp.dir.readFileAlloc(std.testing.io, cached_metadata, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(metadata_bytes);
    try std.testing.expect(std.mem.indexOf(u8, metadata_bytes, "cached test compile") != null);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const cached_code = try saasm.cli.executeWithWriters(std.testing.allocator, test_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 0), cached_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "compiled 1 selected tests (1 discovered)"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
    try std.testing.expectEqual(@as(usize, 1), try cacheEntryCount(tmp.dir, ".sa_cache/test"));

    try tmp.dir.deleteFile(std.testing.io, cached_output);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const second_code = try saasm.cli.executeWithWriters(std.testing.allocator, test_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 0), second_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "compiled 1 selected tests (1 discovered)"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
    try std.testing.expectEqual(@as(usize, 1), try cacheEntryCount(tmp.dir, ".sa_cache/test"));
    try tmp.dir.access(std.testing.io, cached_output, .{});

    try writeBytes(tmp.dir, cached_manifest, "{\"version\":1,\"kind\":\"test\",\"key\":\"bad\"}\n");
    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const third_code = try saasm.cli.executeWithWriters(std.testing.allocator, test_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 0), third_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "compiled 1 selected tests (1 discovered)"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
    try std.testing.expectEqual(@as(usize, 1), try cacheEntryCount(tmp.dir, ".sa_cache/test"));
    const repaired_manifest = try tmp.dir.readFileAlloc(std.testing.io, cached_manifest, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(repaired_manifest);
    try std.testing.expect(std.mem.indexOf(u8, repaired_manifest, cache_key) != null);
}

test "cli build-exe with jobs 1 and auto produce bitcode artifacts" {
    const source =
        \\@helper(value: i32) -> i32:
        \\return value
        \\
        \\@main() -> i32!:
        \\value = call @helper(7)
        \\return value
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_root);

    try writeSource(tmp.dir, "jobs_ok.sars", source);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "jobs_ok.sars" });
    defer std.testing.allocator.free(source_path);
    const serial_out_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "serial.out" });
    defer std.testing.allocator.free(serial_out_path);
    const auto_out_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "auto.out" });
    defer std.testing.allocator.free(auto_out_path);

    const serial_build_argv = [_][]const u8{"sars", "build-exe", source_path, "--jobs", "1", "-o", serial_out_path };
    const serial_code = try saasm.cli.execute(std.testing.allocator, serial_build_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), serial_code);

    const auto_build_argv = [_][]const u8{"sars", "build-exe", source_path, "--jobs", "auto", "-o", auto_out_path };
    const auto_code = try saasm.cli.execute(std.testing.allocator, auto_build_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), auto_code);

    const serial_artifact_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.sa.bc", .{serial_out_path});
    defer std.testing.allocator.free(serial_artifact_path);
    const auto_artifact_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.sa.bc", .{auto_out_path});
    defer std.testing.allocator.free(auto_artifact_path);
    const serial_artifact = try tmp.dir.openFile(std.testing.io, serial_artifact_path, .{});
    defer serial_artifact.close(std.testing.io);
    const serial_artifact_bytes = try sio.readToEndAlloc(serial_artifact, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(serial_artifact_bytes);

    const auto_artifact = try tmp.dir.openFile(std.testing.io, auto_artifact_path, .{});
    defer auto_artifact.close(std.testing.io);
    const auto_artifact_bytes = try sio.readToEndAlloc(auto_artifact, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(auto_artifact_bytes);

    try std.testing.expect(serial_artifact_bytes.len > 0);
    try std.testing.expect(auto_artifact_bytes.len > 0);
    try expectNoTextLlvmArtifacts(tmp.dir, "serial.out");
    try expectNoTextLlvmArtifacts(tmp.dir, "auto.out");
}

test "cli build-exe prunes unused imported functions before llvm emission" {
    const source =
        \\@import "sa_std/sort.sars"
        \\
        \\@main() -> i32:
        \\return 0
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, "unused_sort_import.sars", source);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "unused_sort_import.sars", "-o", "unused_sort_import.out" };
    const build_exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), build_exe_code);

    const artifact_file = try tmp.dir.openFile(std.testing.io, "unused_sort_import.out.sa.bc", .{});
    defer artifact_file.close(std.testing.io);
    const artifact_bytes = try sio.readToEndAlloc(artifact_file, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(artifact_bytes);
    try std.testing.expect(artifact_bytes.len > 0);
}

test "json extern build-exe does not inject debug prints" {
    const source =
        \\@import "sa_std/encoding/json.sars"
        \\
        \\@const DOC = utf8:"{\"name\":\"sci\"}"
        \\#def DOC_LEN = 14
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    root = call @sa_json_parse(&DOC, DOC_LEN)
        \\    parse_ok = ne root, 0
        \\    br parse_ok -> L_KIND, L_FAIL_PARSE
        \\
        \\L_FAIL_PARSE:
        \\    !root
        \\    !parse_ok
        \\    return 10
        \\
        \\L_KIND:
        \\    kind = call @sa_json_kind(root)
        \\    kind_ok = eq kind, SA_JSON_KIND_OBJECT
        \\    !kind
        \\    br kind_ok -> L_FREE, L_FAIL_KIND
        \\
        \\L_FAIL_KIND:
        \\    free_res = call @sa_json_free(^root)
        \\    !free_res
        \\    !parse_ok
        \\    !kind_ok
        \\    return 11
        \\
        \\L_FREE:
        \\    free_res = call @sa_json_free(^root)
        \\    !free_res
        \\    !parse_ok
        \\    !kind_ok
        \\    return 0
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, "json_debug_clean.sars", source);

    var build_stdout = std.array_list.Managed(u8).init(std.testing.allocator);
    defer build_stdout.deinit();
    var build_stderr = std.array_list.Managed(u8).init(std.testing.allocator);
    defer build_stderr.deinit();

    const build_exe_argv = [_][]const u8{
        "sa",
        "build-exe",
        "json_debug_clean.sars",
        "-o",
        "json_debug_clean.out",
        "--jobs",
        "1",
        "--no-incremental",
    };
    const build_exe_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        build_exe_argv[0..],
        sio.managedWriter(&build_stdout),
        sio.managedWriter(&build_stderr),
    );
    if (build_exe_code != 0) {
        std.debug.print("json debug-clean build failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ build_stdout.items, build_stderr.items });
    }
    try std.testing.expectEqual(@as(u8, 0), build_exe_code);
    try std.testing.expectEqual(@as(usize, 0), build_stdout.items.len);
    try std.testing.expectEqual(@as(usize, 0), build_stderr.items.len);

    const native_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./json_debug_clean.out"});
    defer std.testing.allocator.free(native_result.stdout);
    defer std.testing.allocator.free(native_result.stderr);
    switch (native_result.term) {
        .exited => |code| {
            if (code != 0 or native_result.stdout.len != 0 or native_result.stderr.len != 0) {
                std.debug.print("json debug-clean native failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ native_result.stdout, native_result.stderr });
            }
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => |term| {
            std.debug.print("json debug-clean native terminated unexpectedly: {any}\nstdout:\n{s}\nstderr:\n{s}\n", .{ term, native_result.stdout, native_result.stderr });
            return error.TestUnexpectedResult;
        },
    }
    try std.testing.expectEqual(@as(usize, 0), native_result.stdout.len);
    try std.testing.expectEqual(@as(usize, 0), native_result.stderr.len);
    try std.testing.expect(std.mem.indexOf(u8, native_result.stderr, "DBG parse") == null);
    try std.testing.expect(std.mem.indexOf(u8, native_result.stderr, "DBG object_get") == null);
    try std.testing.expect(std.mem.indexOf(u8, native_result.stderr, "DBG kind") == null);
    try std.testing.expect(std.mem.indexOf(u8, native_result.stderr, "DBG string_") == null);
}

test "cli run with jobs 2 keeps the earliest source-order trap" {
    const source =
        \\@first() -> i32:
        \\a = alloc 8
        \\b = alloc 8
        \\c = alloc 8
        \\d = alloc 8
        \\e = alloc 8
        \\f = alloc 8
        \\g = alloc 8
        \\h = alloc 8
        \\return first_missing
        \\
        \\@second() -> i32:
        \\return second_missing
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, "parallel_trap.sars", source);

    var stdout_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const run_argv = [_][]const u8{"sars", "run", "parallel_trap.sars", "--jobs", "2" };
    const code = try saasm.cli.executeWithWriters(std.testing.allocator, run_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, "\"trap\":\"UnknownRegister\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, "return first_missing"));
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "return second_missing") == null);
}

test "hello world demo prints through sa run" {
    var stdout_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const run_argv = [_][]const u8{"sars", "run", "demos/rosetta/01_hello_world/main.sars" };
    const run_code = try saasm.cli.executeWithWriters(std.testing.allocator, run_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 0), run_code);
    try std.testing.expectEqualStrings("hello, saasm\n", stdout_buf.items);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sa run reports unsupported extern symbol names" {
    const source =
        \\@extern sa_missing_plugin() -> i32
        \\
        \\@main() -> i32:
        \\value = call @sa_missing_plugin()
        \\return value
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};
    try writeSource(tmp.dir, "extern_run.sars", source);

    var stdout_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const run_argv = [_][]const u8{"sars", "run", "extern_run.sars" };
    const run_code = try saasm.cli.executeWithWriters(std.testing.allocator, run_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 1), run_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, "sa run unsupported extern: sa_missing_plugin"));
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "UnsupportedExtern") == null);
}

test "hello world demo prints through build-wasm and node wasi" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const node_probe = sio.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "node", "--version" },
    }) catch return error.SkipZigTest;
    defer std.testing.allocator.free(node_probe.stdout);
    defer std.testing.allocator.free(node_probe.stderr);
    switch (node_probe.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "demos/rosetta/01_hello_world/main.sars");
    defer std.testing.allocator.free(source_path);

    const build_wasm_argv = [_][]const u8{"sars", "build-wasm", source_path, "-o", "hello.wasm", "--target", "wasm32" };
    const build_wasm_code = try saasm.cli.execute(std.testing.allocator, build_wasm_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), build_wasm_code);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", "hello.out" };
    const build_exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), build_exe_code);

    const native_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./hello.out"});
    defer std.testing.allocator.free(native_result.stdout);
    defer std.testing.allocator.free(native_result.stderr);
    switch (native_result.term) {
        .exited => |code| {
            if (code != 0 or !std.mem.eql(u8, native_result.stdout, "hello, saasm\n") or native_result.stderr.len != 0) {
                std.debug.print("native hello demo failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ native_result.stdout, native_result.stderr });
            }
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("hello, saasm\n", native_result.stdout);
    try std.testing.expectEqual(@as(usize, 0), native_result.stderr.len);

    const node_result = try runWasmWithNode(std.testing.allocator, "hello.wasm", &.{ "sa", "hello.wasm" });
    defer std.testing.allocator.free(node_result.stdout);
    defer std.testing.allocator.free(node_result.stderr);
    switch (node_result.term) {
        .exited => |code| {
            if (code != 0 or !std.mem.containsAtLeast(u8, node_result.stdout, 1, "hello, saasm\n")) {
                std.debug.print("wasm hello demo failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ node_result.stdout, node_result.stderr });
            }
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("hello, saasm\n", node_result.stdout);
    try std.testing.expectEqual(@as(usize, 0), node_result.stderr.len);
}

test "windows llvm builds and runs hello world executable" {
    if (builtin.os.tag != .windows or !saasm.build_options.llvm_enabled) return error.SkipZigTest;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "demos/rosetta/01_hello_world/main.sars");
    defer std.testing.allocator.free(source_path);
    const build_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", "hello.exe", "--no-incremental" };
    try std.testing.expectEqual(@as(u8, 0), try saasm.cli.execute(std.testing.allocator, &build_argv));

    const file = try tmp.dir.openFile(std.testing.io, "hello.exe", .{});
    defer file.close(std.testing.io);
    var magic: [2]u8 = undefined;
    try file.reader().readNoEof(&magic);
    try std.testing.expectEqualStrings("MZ", &magic);

    const result = try runCommandAnyExit(std.testing.allocator, &.{".\\hello.exe"});
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("hello, saasm\n", result.stdout);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
}

test "hello world upstream line can break in gdb" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gdb_probe = sio.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "gdb", "--version" },
    }) catch return error.SkipZigTest;
    defer std.testing.allocator.free(gdb_probe.stdout);
    defer std.testing.allocator.free(gdb_probe.stderr);
    switch (gdb_probe.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const source =
        \\#loc "hello.rs":10:4
        \\@main() -> i32:
        \\node = alloc 8
        \\!node
        \\return 7
    ;
    const upstream_source =
        \\// 1
        \\// 2
        \\// 3
        \\// 4
        \\// 5
        \\// 6
        \\// 7
        \\// 8
        \\// 9
        \\// 10
    ;
    try writeSource(tmp.dir, "hello.sars", source);
    try writeSource(tmp.dir, "hello.rs", upstream_source);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "hello.sars", "-o", "hello.out", "-g" };
    const build_exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), build_exe_code);

    const gdb_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(gdb_dir);
    const directory_cmd = try std.fmt.allocPrint(std.testing.allocator, "directory {s}", .{gdb_dir});
    defer std.testing.allocator.free(directory_cmd);

    const gdb_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{
        "gdb",
        "-q",
        "--nh",
        "--nx",
        "--batch",
        "-ex",
        "file ./hello.out",
        "-ex",
        directory_cmd,
        "-ex",
        "set pagination off",
        "-ex",
        "break hello.rs:10",
        "-ex",
        "run",
        "-ex",
        "frame",
    });
    defer std.testing.allocator.free(gdb_result.stdout);
    defer std.testing.allocator.free(gdb_result.stderr);
    switch (gdb_result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("gdb returned nonzero exit code {d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ code, gdb_result.stdout, gdb_result.stderr });
            }
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => return error.TestUnexpectedResult,
    }
    const hit_in_stdout = std.mem.containsAtLeast(u8, gdb_result.stdout, 1, "Breakpoint 1,") and std.mem.containsAtLeast(u8, gdb_result.stdout, 1, "at hello.rs:10");
    const hit_in_stderr = std.mem.containsAtLeast(u8, gdb_result.stderr, 1, "Breakpoint 1,") and std.mem.containsAtLeast(u8, gdb_result.stderr, 1, "at hello.rs:10");
    if (!hit_in_stdout and !hit_in_stderr) {
        std.debug.print("gdb breakpoint was not hit:\nstdout:\n{s}\nstderr:\n{s}\n", .{ gdb_result.stdout, gdb_result.stderr });
    }
    try std.testing.expect(hit_in_stdout or hit_in_stderr);
}

test "hello compute demo prints through build-exe and build-wasm" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const node_probe = sio.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "node", "--version" },
    }) catch return error.SkipZigTest;
    defer std.testing.allocator.free(node_probe.stdout);
    defer std.testing.allocator.free(node_probe.stderr);
    switch (node_probe.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "demos/rosetta/98_build_pipeline/main.sars");
    defer std.testing.allocator.free(source_path);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", "hello_compute.out" };
    const build_exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), build_exe_code);

    const native_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./hello_compute.out"});
    defer std.testing.allocator.free(native_result.stdout);
    defer std.testing.allocator.free(native_result.stderr);
    switch (native_result.term) {
        .exited => |code| {
            if (code != 0 or !std.mem.eql(u8, native_result.stdout, "6\n") or native_result.stderr.len != 0) {
                std.debug.print("native hello-compute failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ native_result.stdout, native_result.stderr });
            }
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("6\n", native_result.stdout);
    try std.testing.expectEqual(@as(usize, 0), native_result.stderr.len);

    const build_wasm_argv = [_][]const u8{"sars", "build-wasm", source_path, "-o", "hello_compute.wasm", "--target", "wasm32" };
    const build_wasm_code = try saasm.cli.execute(std.testing.allocator, build_wasm_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), build_wasm_code);

    const node_result = try runWasmWithNode(std.testing.allocator, "hello_compute.wasm", &.{ "sa", "hello_compute.wasm" });
    defer std.testing.allocator.free(node_result.stdout);
    defer std.testing.allocator.free(node_result.stderr);
    switch (node_result.term) {
        .exited => |code| {
            if (code != 0 or !std.mem.eql(u8, node_result.stdout, "6\n") or node_result.stderr.len != 0) {
                std.debug.print("wasm hello-compute failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ node_result.stdout, node_result.stderr });
            }
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("6\n", node_result.stdout);
    try std.testing.expectEqual(@as(usize, 0), node_result.stderr.len);
}

test "trait vtable demo runs through sa run" {
    var stdout_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const run_argv = [_][]const u8{"sars", "run", "demos/rosetta/07_trait_vtable/main.sars" };
    const run_code = try saasm.cli.executeWithWriters(std.testing.allocator, run_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 0), run_code);
    try std.testing.expectEqualStrings("77\n", stdout_buf.items);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "callback registration demo compiles and prints through build-exe" {
    try assertBuildExeStdout("demos/rosetta/253_contract_callback_registration/main.sars", "253\n");
}

test "indirect calls shadowed by an early import resolve to valued callees" {
    try assertBuildExeStdout("demos/rosetta/334_indirect_import_shadow/main.sars", "334\n");
}

test "pkg lib dynamic demo compiles via object archive and prints through native link" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const main_source = try original_cwd.realpathAlloc(std.testing.allocator, "demos/rosetta/220_pkg_lib_dynamic/main.sars");
    defer std.testing.allocator.free(main_source);
    const lib_source = try original_cwd.realpathAlloc(std.testing.allocator, "demos/rosetta/220_pkg_lib_dynamic/lib/index.sars");
    defer std.testing.allocator.free(lib_source);
    const sa_std_archive_path = try original_cwd.realpathAlloc(std.testing.allocator, "artifacts/sa_std/libsa_std.a");
    defer std.testing.allocator.free(sa_std_archive_path);

    const main_obj = "220_pkg_lib_dynamic_main.o";
    const lib_obj = "220_pkg_lib_dynamic_lib.o";
    const lib_archive = "220_pkg_lib_dynamic_lib.a";
    const out_path = "220_pkg_lib_dynamic.out";

    const build_main_argv = [_][]const u8{"sars", "build-obj", main_source, "-o", main_obj };
    const build_main_code = try saasm.cli.execute(std.testing.allocator, build_main_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), build_main_code);

    const build_lib_argv = [_][]const u8{"sars", "build-obj", lib_source, "-o", lib_obj };
    const build_lib_code = try saasm.cli.execute(std.testing.allocator, build_lib_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), build_lib_code);

    _ = try runCommand(std.testing.allocator, &[_][]const u8{ "ar", "rcs", lib_archive, lib_obj });

    const link_argv = [_][]const u8{ "zig", "cc", main_obj, lib_archive, sa_std_archive_path, "-o", out_path };
    const link_stdout = try runCommand(std.testing.allocator, link_argv[0..]);
    defer std.testing.allocator.free(link_stdout);

    const exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./220_pkg_lib_dynamic.out"});
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("220\n", exe_result.stdout);
    try std.testing.expectEqual(@as(usize, 0), exe_result.stderr.len);
}

test "comparison alias demos run through sa run" {
    try assertRunStdout("demos/rosetta/03_if_else/main.sars", "20\n");
    try assertRunStdout("demos/rosetta/04_loop/main.sars", "[0,0,0,0]\n");
    try assertRunStdout("demos/rosetta/21_while_loop/main.sars", "15\n");
    try assertRunStdout("demos/rosetta/24_factorial/main.sars", "120\n");
    try assertRunStdout("demos/rosetta/25_fibonacci/main.sars", "21\n");
}

test "ownership and borrow demos compile and print through build-exe" {
    try assertBuildExeStdout("demos/rosetta/02_mutability/main.sars", "20\n");
    try assertBuildExeStdout("demos/rosetta/20_boxed_value/main.sars", "9\n");
    try assertBuildExeStdout("demos/rosetta/26_reference_return/main.sars", "9\n");
    try assertBuildExeStdout("demos/rosetta/27_move_semantics/main.sars", "11\n");
    try assertBuildExeStdout("demos/rosetta/28_borrow_chains/main.sars", "12\n");
    try assertBuildExeStdout("demos/rosetta/51_refcount/main.sars", "10\n");
    try assertBuildExeStdout("demos/rosetta/58_borrow_update/main.sars", "10\n");
    try assertBuildExeStdout("demos/rosetta/61_thread_pool/main.sars", "5\n");
    try assertBuildExeStdout("demos/rosetta/67_resource_pool/main.sars", "20\n");
    try assertBuildExeStdout("demos/rosetta/52_queue_rotate/main.sars", "2,3,1\n");
}

test "core control-flow and data demos compile and print through build-exe" {
    try assertBuildExeStdout("demos/rosetta/03_if_else/main.sars", "20\n");
    try assertBuildExeStdout("demos/rosetta/05_struct/main.sars", "(10,20)\n");
    try assertBuildExeStdout("demos/rosetta/06_enum_and_match/main.sars", "30\n");
    try assertBuildExeStdout("demos/rosetta/11_tuples/main.sars", "(3, 4)\n");
    try assertBuildExeStdout("demos/rosetta/13_array_sum/main.sars", "10\n");
    try assertBuildExeStdout("demos/rosetta/15_string_bytes/main.sars", "4\n");
    try assertBuildExeStdout("demos/rosetta/18_option_map/main.sars", "8\n");
    try assertBuildExeStdout("demos/rosetta/16_methods/main.sars", "25\n");
    try assertBuildExeStdout("demos/rosetta/24_factorial/main.sars", "120\n");
    try assertBuildExeStdout("demos/rosetta/25_fibonacci/main.sars", "21\n");
    try assertBuildExeStdout("demos/rosetta/29_const_data/main.sars", "6\n");
    try assertBuildExeStdout("demos/rosetta/31_trait_static_dispatch/main.sars", "16\n");
}

test "additional rosetta demos compile and print through build-exe" {
    try assertBuildExeStdout("demos/rosetta/12_destructuring/main.sars", "7\n");
    try assertBuildExeStdout("demos/rosetta/34_iterator_filter/main.sars", "6\n");
    try assertBuildExeStdout("demos/rosetta/35_iterator_fold/main.sars", "7\n");
    try assertBuildExeStdout("demos/rosetta/36_tuple_struct/main.sars", "14\n");
    try assertBuildExeStdout("demos/rosetta/40_impl_block_state/main.sars", "15\n");
    try assertBuildExeStdout("demos/rosetta/41_module_imports/main.sars", "42\n");
    try assertBuildExeStdout("demos/rosetta/42_export_visibility/main.sars", "12\n");
    try assertBuildExeStdout("demos/rosetta/45_config_merge/main.sars", "4 3\n");
    try assertBuildExeStdout("demos/rosetta/46_option_default/main.sars", "9\n");
    try assertBuildExeStdout("demos/rosetta/48_generic_pair/main.sars", "11,31\n");
    try assertBuildExeStdout("demos/rosetta/63_router_table/main.sars", "2\n");
}

test "fallible rosetta demos compile and print through build-exe" {
    try assertBuildExeStdout("demos/rosetta/19_result_question/main.sars", "21\n");
    try assertBuildExeStdout("demos/rosetta/50_error_chain/main.sars", "12\n");
    try assertBuildExeStdout("demos/rosetta/176_result_flattening/main.sars", "2\n");
}

test "slice and cache rosetta demos compile and print through build-exe" {
    try assertBuildExeStdout("demos/rosetta/44_slice_iteration/main.sars", "10\n");
    try assertBuildExeStdout("demos/rosetta/54_mem_fill/main.sars", "7,7,7,7\n");
    try assertBuildExeStdout("demos/rosetta/86_cache_eviction/main.sars", "20\n");
}

test "baseline rosetta demos compile and print through build-exe" {
    try assertBuildExeStdout("demos/rosetta/01_hello_world/main.sars", "hello, saasm\n");
    try assertBuildExeStdout("demos/rosetta/04_loop/main.sars", "[0,0,0,0]\n");
    try assertBuildExeStdout("demos/rosetta/07_trait_vtable/main.sars", "77\n");
    try assertBuildExeStdout("demos/rosetta/21_while_loop/main.sars", "15\n");
}

test "break and nested loop rosetta demos compile and print through build-exe" {
    try assertBuildExeStdout("demos/rosetta/22_break_continue/main.sars", "9\n");
    try assertBuildExeStdout("demos/rosetta/23_nested_loops/main.sars", "18\n");
}

test "more baseline rosetta demos compile and print through build-exe" {
    try assertBuildExeStdout("demos/rosetta/29_const_data/main.sars", "6\n");
    try assertBuildExeStdout("demos/rosetta/31_trait_static_dispatch/main.sars", "16\n");
    try assertBuildExeStdout("demos/rosetta/37_newtype/main.sars", "42\n");
    try assertBuildExeStdout("demos/rosetta/38_generic_struct_i32/main.sars", "31\n");
    try assertBuildExeStdout("demos/rosetta/39_generic_enum_i32/main.sars", "7\n");
    try assertBuildExeStdout("demos/rosetta/40_impl_block_state/main.sars", "15\n");
}

test "more rosetta demos compile and print through build-exe" {
    try assertBuildExeStdout("demos/rosetta/08_closures/main.sars", "15\n");
    try assertBuildExeStdout("demos/rosetta/10_generics_monomorph/main.sars", "42\n");
    try assertBuildExeStdout("demos/rosetta/17_associated_fn/main.sars", "42\n");
    try assertBuildExeStdout("demos/rosetta/30_manual_guard_branch/main.sars", "5\n");
    try assertBuildExeStdout("demos/rosetta/33_iterator_map/main.sars", "12\n");
    try assertBuildExeStdout("demos/rosetta/37_newtype/main.sars", "42\n");
    try assertBuildExeStdout("demos/rosetta/38_generic_struct_i32/main.sars", "31\n");
    try assertBuildExeStdout("demos/rosetta/39_generic_enum_i32/main.sars", "7\n");
    try assertBuildExeStdout("demos/rosetta/59_method_counter/main.sars", "4\n");
    try assertBuildExeStdout("demos/rosetta/60_enum_branch/main.sars", "2\n");
}

test "even more rosetta demos compile and print through build-exe" {
    try assertBuildExeStdout("demos/rosetta/64_file_manifest/main.sars", "3\n");
    try assertBuildExeStdout("demos/rosetta/68_parser_tokens/main.sars", "4\n");
    try assertBuildExeStdout("demos/rosetta/69_serializer/main.sars", "{\"id\":7}\n");
    try assertBuildExeStdout("demos/rosetta/70_integration_service/main.sars", "6\n");
    try assertBuildExeStdout("demos/rosetta/71_pipeline_stage/main.sars", "6\n");
    try assertBuildExeStdout("demos/rosetta/72_graph_walk/main.sars", "3\n");
    try assertBuildExeStdout("demos/rosetta/73_scene_nodes/main.sars", "15\n");
    try assertBuildExeStdout("demos/rosetta/74_component_store/main.sars", "2\n");
    try assertBuildExeStdout("demos/rosetta/77_http_route/main.sars", "/health\n");
    try assertBuildExeStdout("demos/rosetta/78_cli_args/main.sars", "2\n");
}

test "final rosetta batch compile and print through build-exe" {
    try assertBuildExeStdout("demos/rosetta/79_metrics/main.sars", "4\n");
    try assertBuildExeStdout("demos/rosetta/80_workflow/main.sars", "10\n");
    try assertBuildExeStdout("demos/rosetta/81_kv_store/main.sars", "5\n");
    try assertBuildExeStdout("demos/rosetta/82_sql_scan/main.sars", "2\n");
    try assertBuildExeStdout("demos/rosetta/83_blob_chunk/main.sars", "4\n");
    try assertBuildExeStdout("demos/rosetta/84_sync_gate/main.sars", "1\n");
    try assertBuildExeStdout("demos/rosetta/85_scheduler_tree/main.sars", "6\n");
    try assertBuildExeStdout("demos/rosetta/89_job_queue/main.sars", "12\n");
    try assertBuildExeStdout("demos/rosetta/90_app_shell/main.sars", "app --mode demo\n");
    try assertBuildExeStdout("demos/rosetta/91_db_session/main.sars", "2\n");
    try assertBuildExeStdout("demos/rosetta/87_protocol_frame/main.sars", "3\n");
    try assertBuildExeStdout("demos/rosetta/88_text_index/main.sars", "3\n");
    try assertBuildExeStdout("demos/rosetta/92_query_plan/main.sars", "10\n");
    try assertBuildExeStdout("demos/rosetta/93_log_aggregator/main.sars", "10\n");
    try assertBuildExeStdout("demos/rosetta/94_graphql_router/main.sars", "query user\n");
    try assertBuildExeStdout("demos/rosetta/95_repl_shell/main.sars", "sa> \n");
    try assertBuildExeStdout("demos/rosetta/96_task_orchestrator/main.sars", "4\n");
    try assertBuildExeStdout("demos/rosetta/97_sync_service/main.sars", "1\n");
    try assertBuildExeStdout("demos/rosetta/98_build_pipeline/main.sars", "6\n");
    try assertBuildExeStdout("demos/rosetta/99_release_bundle/main.sars", "3\n");
    try assertBuildExeStdout("demos/rosetta/100_full_app/main.sars", "12\n");
    try assertBuildExeStdout("demos/rosetta/178_panic_hook_override/main.sars", "1\n");
}

test "service and concurrency rosetta demos compile and print through build-exe" {
    try assertBuildExeStdout("demos/rosetta/55_builder_pattern/main.sars", "POST /api\n");
    try assertBuildExeStdout("demos/rosetta/56_state_machine/main.sars", "2\n");
    try assertBuildExeStdout("demos/rosetta/57_event_loop/main.sars", "6\n");
    try assertBuildExeStdout("demos/rosetta/62_channel_pingpong/main.sars", "8\n");
    try assertBuildExeStdout("demos/rosetta/65_job_scheduler/main.sars", "10\n");
    try assertBuildExeStdout("demos/rosetta/66_actor_mailbox/main.sars", "6\n");
    try assertBuildExeStdout("demos/rosetta/75_async_bridge/main.sars", "5\n");
    try assertBuildExeStdout("demos/rosetta/76_lockfree_counter/main.sars", "3\n");
}

test "remaining rosetta demos compile and print through build-exe" {
    try assertBuildExeStdout("demos/rosetta/14_slice_window/main.sars", "5\n");
    try assertBuildExeStdout("demos/rosetta/32_trait_object_vector/main.sars", "12\n");
    try assertBuildExeStdout("demos/rosetta/09_async_await/main.sars", "2\n");
    try assertBuildExeStdout("demos/rosetta/47_tuple_swap/main.sars", "8,3\n");
    try assertBuildExeStdout("demos/rosetta/53_cache_hits/main.sars", "3\n");
    try assertBuildExeStdout("demos/rosetta/43_tagged_union/main.sars", "36\n");
    try assertBuildExeStdout("demos/rosetta/49_pipeline_map/main.sars", "12\n");
    try assertBuildExeStdout("demos/rosetta/94_graphql_router/main.sars", "query user\n");
    try assertBuildExeStdout("demos/rosetta/95_repl_shell/main.sars", "sa> \n");
    try assertBuildExeStdout("demos/rosetta/100_full_app/main.sars", "12\n");
}

test "async await demo runs through sa run" {
    try assertRunStdout("demos/rosetta/09_async_await/main.sars", "2\n");
}

test "macro demo compiles and prints through build-exe" {
    try assertBuildExeStdout("demos/support/macro_print.sars", "macro ok\n");
}

test "sa_core macros compile and print through imported standard library macros" {
    try assertBuildExeStdout("demos/support/macro_core.sars", "macro core ok\n");
}

test "time demo compiles and prints through build-exe" {
    try assertBuildExeStdout("demos/support/time_probe.sars", "time ok\n");
}

test "time demo runs through sa run" {
    try assertRunStdout("demos/support/time_probe.sars", "time ok\n");
}

test "pthread vtable worker stores survive native join" {
    try assertBuildExeStdout("demos/support/pthread_vtable_store/main.sars", "ok\n");
}

test "mutex demo compiles and prints through build-exe" {
    try assertBuildExeStdout("demos/support/mutex_probe.sars", "mutex ok\n");
}

test "mutex demo runs through sa run" {
    try assertRunStdout("demos/support/mutex_probe.sars", "mutex ok\n");
}

test "once demo compiles and prints through build-exe" {
    try assertBuildExeStdout("demos/support/once_probe.sars", "once ok\n");
}

test "once demo runs through sa run" {
    try assertRunStdout("demos/support/once_probe.sars", "once ok\n");
}

test "mpsc demo compiles and prints through build-exe" {
    try assertBuildExeStdout("demos/support/mpsc_probe.sars", "mpsc ok\n");
}

test "mpsc demo runs through sa run" {
    try assertRunStdout("demos/support/mpsc_probe.sars", "mpsc ok\n");
}

test "io demo compiles and prints through build-exe" {
    try assertBuildExeStdout("demos/support/io_probe.sars", "alpha\n5\n");
}

test "hashmap demo compiles and prints through build-exe" {
    try assertBuildExeStdout("demos/support/hashmap_probe.sars", "alpha\nbravo\nmap ok\n");
}

test "hashset demo compiles and prints through build-exe" {
    try assertBuildExeStdout("demos/support/hashset_probe.sars", "set ok\n");
}

test "hashset demo runs through sa run" {
    try assertRunStdout("demos/support/hashset_probe.sars", "set ok\n");
}

test "sort demo compiles and prints through build-exe" {
    try assertBuildExeStdout("demos/support/sort_probe.sars", "sort ok\n");
}

test "use after move demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/use_after_move.sars", "use_after_move.out", "UseAfterMove", 1009, "moved value is no longer usable");
}

test "return after move demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/return_after_move.sars", "return_after_move.out", "UseAfterMove", 1009, "moved value is no longer usable");
}

test "borrow conflict demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/borrow_conflict.sars", "borrow_conflict.out", "BorrowConflict", 1008, "borrow rules reject this access");
}

test "read write conflict demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/read_write_conflict.sars", "read_write_conflict.out", "ReadWriteConflict", 1011, "cannot write through a shared borrow");
}

test "illegal unsafe context demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/illegal_unsafe_context.sars", "illegal_unsafe_context.out", "IllegalUnsafeContext", 1019, "raw pointer and assume_* instructions are only legal inside @ffi_wrapper");
}

test "stack escape demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/stack_escape.sars", "stack_escape.out", "StackEscape", 1025, "stack allocation cannot be moved out of its function");
}

test "const mutation demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/const_mutation.sars", "const_mutation.out", "ConstMutation", 1023, "immutable registers cannot be released");
}

test "early return leak demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/early_return_leak.sars", "early_return_leak.out", "EarlyReturnLeak", 1026, "early return would leak live registers");
}

test "macro recursion demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/macro_recursion.sars", "macro_recursion.out", "MacroRecursionLimit", 1005, "macro recursion limit exceeded");
}

test "forbidden syntax demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/forbidden_syntax.sars", "forbidden_syntax.out", "ForbiddenSyntax", 1001, "forbidden syntax detected during flattening");
}

test "forbidden if demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/forbidden_if.sars", "forbidden_if.out", "ForbiddenSyntax", 1001, "forbidden syntax detected during flattening");
}

test "forbidden while demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/forbidden_while.sars", "forbidden_while.out", "ForbiddenSyntax", 1001, "forbidden syntax detected during flattening");
}

test "forbidden for demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/forbidden_for.sars", "forbidden_for.out", "ForbiddenSyntax", 1001, "forbidden syntax detected during flattening");
}

test "forbidden brace demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/forbidden_brace.sars", "forbidden_brace.out", "ForbiddenSyntax", 1001, "forbidden syntax detected during flattening");
}

test "forbidden property chain demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/forbidden_property_chain.sars", "forbidden_property_chain.out", "ForbiddenSyntax", 1001, "forbidden syntax detected during flattening");
}

test "memory leak after borrow demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/memory_leak_after_borrow.sars", "memory_leak_after_borrow.out", "MemoryLeak", 1012, "live registers remain at function exit");
}

test "memory leak partial release demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/memory_leak_partial_release.sars", "memory_leak_partial_release.out", "MemoryLeak", 1012, "live registers remain at function exit");
}

test "atomic ordering mismatch demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/atomic_ordering_mismatch.sars", "atomic_ordering_mismatch.out", "AtomicOrderingMismatch", 1029, "same-address RMW ordering combination is not allowed");
}

test "invalid atomic ordering demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/invalid_atomic_ordering.sars", "invalid_atomic_ordering.out", "InvalidAtomicOrdering", 1028, "invalid atomic ordering");
}

test "unknown register return demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/unknown_register_return.sars", "unknown_register_return.out", "UnknownRegister", 1007, "register is not declared in the current scope");
}

test "capability mismatch demo is rejected with structured trap output" {
    try assertBuildExeTrap("demos/support/capability_mismatch.sars", "capability_mismatch.out", "CapabilityMismatch", 1013, "call-site capability prefix does not match the callee contract");
}

test "package and module roadmap demos are rejected with structured trap output" {
    try assertBuildExeTrap("demos/rosetta/205_pkg_cyclic_dependency_reject/main.sars", "205_pkg_cyclic_dependency_reject.out", "ForbiddenSyntax", 1001, "import cycle detected during flattening");
    try assertBuildExeTrap("demos/rosetta/207_pkg_multiple_versions_conflict/main.sars", "207_pkg_multiple_versions_conflict.out", "DuplicateDef", 1002, "duplicate definition detected during flattening");
    try assertBuildExeTrap("demos/rosetta/226_mod_cyclic_import_detect/main.sars", "226_mod_cyclic_import_detect.out", "ForbiddenSyntax", 1001, "import cycle detected during flattening");
    try assertBuildExeTrap("demos/rosetta/227_mod_shadowing_prevention/main.sars", "227_mod_shadowing_prevention.out", "DuplicateDef", 1002, "duplicate definition detected during flattening");
    try assertBuildExeTrap("demos/rosetta/243_contract_sig_mismatch_link/main.sars", "243_contract_sig_mismatch_link.out", "CapabilityMismatch", 1013, "call-site capability prefix does not match the callee contract");
}

test "struct demo runs through sa run" {
    try assertRunStdout("demos/rosetta/05_struct/main.sars", "(10,20)\n");
}

test "sys runtime demo prints and round-trips file contents" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "demos/support/sys_runtime_probe.sars");
    defer std.testing.allocator.free(source_path);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try assertRunStdoutWithArg(source_path, "marker", "ok\n");

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", "sys_runtime_probe.out" };
    const build_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), build_code);

    const exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{ "./sys_runtime_probe.out", "marker" });
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| {
            if (code != 0 or !std.mem.eql(u8, exe_result.stdout, "ok\n") or exe_result.stderr.len != 0) {
                std.debug.print("native demo failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ exe_result.stdout, exe_result.stderr });
            }
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("ok\n", exe_result.stdout);
    try std.testing.expectEqual(@as(usize, 0), exe_result.stderr.len);

    const file = try tmp.dir.openFile(std.testing.io, "sys_io.txt", .{});
    defer file.close(std.testing.io);
    const contents = try sio.readToEndAlloc(file, std.testing.allocator, 1024);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("saasm", contents);

    try tmp.dir.deleteFile(std.testing.io, "sys_io.txt");

    const build_wasm_argv = [_][]const u8{"sars", "build-wasm", source_path, "-o", "sys_runtime_probe.wasm", "--target", "wasm32" };
    const wasm_code = try saasm.cli.execute(std.testing.allocator, build_wasm_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), wasm_code);

    const wasm_artifact = try tmp.dir.openFile(std.testing.io, "sys_runtime_probe.wasm.sa.bc", .{});
    defer wasm_artifact.close(std.testing.io);
    const wasm_artifact_bytes = try sio.readToEndAlloc(wasm_artifact, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(wasm_artifact_bytes);
    try std.testing.expect(wasm_artifact_bytes.len > 0);
    try expectNoTextLlvmArtifacts(tmp.dir, "sys_runtime_probe.wasm");

    const wasm_file = try tmp.dir.openFile(std.testing.io, "sys_runtime_probe.wasm", .{});
    defer wasm_file.close(std.testing.io);
    const wasm_bytes = try sio.readToEndAlloc(wasm_file, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(wasm_bytes);
    try std.testing.expect(wasm_bytes.len > 8);
    try std.testing.expectEqualSlices(u8, &std.wasm.magic, wasm_bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &std.wasm.version, wasm_bytes[4..8]);

    const node_probe = sio.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "node", "--version" },
    }) catch return error.SkipZigTest;
    defer std.testing.allocator.free(node_probe.stdout);
    defer std.testing.allocator.free(node_probe.stderr);
    switch (node_probe.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    const wasm_result = try runWasmWithNode(std.testing.allocator, "sys_runtime_probe.wasm", &.{ "sa", "sys_runtime_probe.wasm", "marker" });
    defer std.testing.allocator.free(wasm_result.stdout);
    defer std.testing.allocator.free(wasm_result.stderr);
    switch (wasm_result.term) {
        .exited => |code| {
            if (code != 0 or !std.mem.eql(u8, wasm_result.stdout, "ok\n") or wasm_result.stderr.len != 0) {
                std.debug.print("wasm sys runtime demo failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ wasm_result.stdout, wasm_result.stderr });
            }
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("ok\n", wasm_result.stdout);
    try std.testing.expectEqual(@as(usize, 0), wasm_result.stderr.len);

    const wasm_written_file = try tmp.dir.openFile(std.testing.io, "sys_io.txt", .{});
    defer wasm_written_file.close(std.testing.io);
    const wasm_written = try sio.readToEndAlloc(wasm_written_file, std.testing.allocator, 1024);
    defer std.testing.allocator.free(wasm_written);
    try std.testing.expectEqualStrings("saasm", wasm_written);
}

test "ffi airlock demo preserves pointer values through assume_* in sa run" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "demos/support/airlock_probe.sars");
    defer std.testing.allocator.free(source_path);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try assertRunStdout(source_path, "ok\n");

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", "airlock_probe.out" };
    const build_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), build_code);

    const exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./airlock_probe.out"});
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| {
            if (code != 0 or !std.mem.eql(u8, exe_result.stdout, "ok\n") or exe_result.stderr.len != 0) {
                std.debug.print("airlock demo failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ exe_result.stdout, exe_result.stderr });
            }
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("ok\n", exe_result.stdout);
    try std.testing.expectEqual(@as(usize, 0), exe_result.stderr.len);
}

test "http client saasm demo builds through native exe" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "demos/rosetta/301_http_client_saasm/main.sars");
    defer std.testing.allocator.free(source_path);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18090);
    const server = try std.testing.allocator.create(std.Io.net.Server);
    server.* = try address.listen(sio.io(), .{ .reuse_address = true });
    defer std.testing.allocator.destroy(server);

    const body_seen = try std.testing.allocator.create(bool);
    body_seen.* = false;
    defer std.testing.allocator.destroy(body_seen);
    const server_ready = try std.testing.allocator.create(std.atomic.Value(bool));
    server_ready.* = std.atomic.Value(bool).init(false);
    defer std.testing.allocator.destroy(server_ready);

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(listen_server: *std.Io.net.Server, seen: *bool, ready: *std.atomic.Value(bool)) void {
            defer listen_server.deinit(sio.io());
            ready.store(true, .release);
            var stream = listen_server.accept(sio.io()) catch return;
            defer stream.close(sio.io());

            var rbuf: [4096]u8 = undefined;
            var wbuf: [4096]u8 = undefined;
            var sreader = stream.reader(sio.io(), &rbuf);
            var swriter = stream.writer(sio.io(), &wbuf);
            var http_server = std.http.Server.init(&sreader.interface, &swriter.interface);
            var request = http_server.receiveHead() catch return;
            var body_tmp: [4096]u8 = undefined;
            var body_reader = request.readerExpectNone(&body_tmp);
            const content = body_reader.interface.allocRemaining(std.testing.allocator, .limited(1024 * 1024)) catch return;
            defer std.testing.allocator.free(content);
            seen.* = std.mem.eql(u8, content, "hello from saasm");
            request.respond(content, .{ .status = .ok }) catch return;
        }
    }.run, .{ server, body_seen, server_ready });
    while (!server_ready.load(.acquire)) std.Io.sleep(sio.io(), .fromMilliseconds(1), .awake) catch {};

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", "http_client_saasm.out" };
    const build_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), build_code);

    const exe_result = try runCommandAnyExitWithEnvMap(std.testing.allocator, &[_][]const u8{"./http_client_saasm.out"}, null);
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("http client demo failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ exe_result.stdout, exe_result.stderr });
            }
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("ok\n", exe_result.stdout);
    try std.testing.expectEqual(@as(usize, 0), exe_result.stderr.len);

    server_thread.join();
    try std.testing.expect(body_seen.*);
}

test "http server saasm demo builds through native exe" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "demos/rosetta/302_http_server_saasm/main.sars");
    defer std.testing.allocator.free(source_path);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", "http_server_saasm.out" };
    const build_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), build_code);

    const response_seen = try std.testing.allocator.create(bool);
    response_seen.* = false;
    defer std.testing.allocator.destroy(response_seen);

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(seen: *bool) void {
            var attempt: usize = 0;
            while (attempt < 50) : (attempt += 1) {
                const dial_addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 18091) catch return;
                var conn = dial_addr.connect(sio.io(), .{ .mode = .stream }) catch |err| switch (err) {
                    error.ConnectionRefused => {
                        std.Io.sleep(sio.io(), .fromMilliseconds(20), .awake) catch {};
                        continue;
                    },
                    else => return,
                };
                defer conn.close(sio.io());

                var wbuf: [4096]u8 = undefined;
                var w = conn.writer(sio.io(), &wbuf);
                w.interface.writeAll(
                    "GET /stream HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n",
                ) catch return;
                w.interface.flush() catch return;

                var buf: [256]u8 = undefined;
                var response = std.array_list.Managed(u8).init(std.testing.allocator);
                defer response.deinit();
                while (true) {
                    const n = std.posix.read(conn.socket.handle, &buf) catch return;
                    if (n == 0) break;
                    response.appendSlice(buf[0..n]) catch return;
                }
                seen.* = std.mem.containsAtLeast(u8, response.items, 1, "data: first") and
                    std.mem.containsAtLeast(u8, response.items, 1, "data: second");
                return;
            }
        }
    }.run, .{response_seen});
    const exe_result = try runCommandAnyExitWithEnvMap(std.testing.allocator, &[_][]const u8{"./http_server_saasm.out"}, null);
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("http server demo failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ exe_result.stdout, exe_result.stderr });
            }
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("ok\n", exe_result.stdout);
    try std.testing.expectEqual(@as(usize, 0), exe_result.stderr.len);

    server_thread.join();
    try std.testing.expect(response_seen.*);
}

test "panic builtins terminate through the interpreter" {
    const plain_source =
        \\@main() -> i32:
        \\panic(17)
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, "panic.sars", plain_source);

    const plain_argv = [_][]const u8{"sars", "run", "panic.sars" };
    const plain_code = try saasm.cli.execute(std.testing.allocator, plain_argv[0..]);
    try std.testing.expectEqual(@as(u8, 145), plain_code);

    const msg_source =
        \\@main() -> i32:
        \\buf = alloc 3
        \\store buf+0, 104 as i8
        \\store buf+1, 105 as i8
        \\store buf+2, 0 as i8
        \\panic_msg(23, *buf, 2)
    ;

    try writeSource(tmp.dir, "panic_msg.sars", msg_source);

    const msg_argv = [_][]const u8{"sars", "run", "panic_msg.sars" };
    const msg_code = try saasm.cli.execute(std.testing.allocator, msg_argv[0..]);
    try std.testing.expectEqual(@as(u8, 151), msg_code);

    const result_layout_path = try original_cwd.realpathAlloc(std.testing.allocator, "sa_std/core/result.sal");
    defer std.testing.allocator.free(result_layout_path);
    const option_layout_path = try original_cwd.realpathAlloc(std.testing.allocator, "sa_std/core/option.sal");
    defer std.testing.allocator.free(option_layout_path);
    const result_src_path = try original_cwd.realpathAlloc(std.testing.allocator, "sa_std/core/result.sars");
    defer std.testing.allocator.free(result_src_path);
    const option_src_path = try original_cwd.realpathAlloc(std.testing.allocator, "sa_std/core/option.sars");
    defer std.testing.allocator.free(option_src_path);
    const panic_src_path = try original_cwd.realpathAlloc(std.testing.allocator, "sa_std/core/panic.sars");
    defer std.testing.allocator.free(panic_src_path);

    const result_unwrap_source = try std.fmt.allocPrint(std.testing.allocator,
        \\@import "{s}"
        \\@import "{s}"
        \\@import "{s}"
        \\
        \\@main() -> i32:
        \\res = alloc Result_SIZE
        \\EXPAND RESULT_SET_ERR res, 7
        \\EXPAND RESULT_UNWRAP value, res
        \\!res
        \\return value
    , .{ result_layout_path, result_src_path, panic_src_path });
    defer std.testing.allocator.free(result_unwrap_source);

    try writeSource(tmp.dir, "result_unwrap.sars", result_unwrap_source);

    const result_unwrap_argv = [_][]const u8{"sars", "run", "result_unwrap.sars" };
    const result_unwrap_code = try saasm.cli.execute(std.testing.allocator, result_unwrap_argv[0..]);
    try std.testing.expectEqual(@as(u8, 145), result_unwrap_code);

    const option_unwrap_source = try std.fmt.allocPrint(std.testing.allocator,
        \\@import "{s}"
        \\@import "{s}"
        \\@import "{s}"
        \\
        \\@main() -> i32:
        \\opt = alloc Option_SIZE
        \\EXPAND OPTION_SET_NONE opt
        \\EXPAND OPTION_UNWRAP value, opt
        \\!opt
        \\return value
    , .{ option_layout_path, option_src_path, panic_src_path });
    defer std.testing.allocator.free(option_unwrap_source);

    try writeSource(tmp.dir, "option_unwrap.sars", option_unwrap_source);

    const option_unwrap_argv = [_][]const u8{"sars", "run", "option_unwrap.sars" };
    const option_unwrap_code = try saasm.cli.execute(std.testing.allocator, option_unwrap_argv[0..]);
    try std.testing.expectEqual(@as(u8, 145), option_unwrap_code);

    const result_unwrap_err_source = try std.fmt.allocPrint(std.testing.allocator,
        \\@import "{s}"
        \\@import "{s}"
        \\@import "{s}"
        \\
        \\@main() -> i32:
        \\res = alloc Result_SIZE
        \\EXPAND RESULT_SET_OK res, 7
        \\EXPAND RESULT_UNWRAP_ERR value, res
        \\!res
        \\return value
    , .{ result_layout_path, result_src_path, panic_src_path });
    defer std.testing.allocator.free(result_unwrap_err_source);

    try writeSource(tmp.dir, "result_unwrap_err.sars", result_unwrap_err_source);

    const result_unwrap_err_argv = [_][]const u8{"sars", "run", "result_unwrap_err.sars" };
    const result_unwrap_err_code = try saasm.cli.execute(std.testing.allocator, result_unwrap_err_argv[0..]);
    try std.testing.expectEqual(@as(u8, 145), result_unwrap_err_code);
}

test "sa test covers include macro expansion fixture" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "tests/include_macro_expand_unit.sars");
    defer std.testing.allocator.free(source_path);

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const test_argv = [_][]const u8{"sars", "test", source_path, "--jobs", "1" };
    const test_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        test_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    if (test_code != 0 or stderr_buffer.items.len != 0) {
        std.debug.print("sa test failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ stdout_buffer.items, stderr_buffer.items });
    }
    try std.testing.expectEqual(@as(u8, 0), test_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] include macro expands source into current file"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "test result: ok. 1 passed; 0 failed; 0 skipped"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
}

test "sa test covers module_path macro expansion fixture" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "tests/module_path_macro_unit.sars");
    defer std.testing.allocator.free(source_path);

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const test_argv = [_][]const u8{"sars", "test", source_path, "--jobs", "1" };
    const test_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        test_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    if (test_code != 0 or stderr_buffer.items.len != 0) {
        std.debug.print("sa test failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ stdout_buffer.items, stderr_buffer.items });
    }
    try std.testing.expectEqual(@as(u8, 0), test_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] module_path macro reports the current source path suffix"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "test result: ok. 1 passed; 0 failed; 0 skipped"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
}

test "sa test runs isolated native tests with filterable names" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "tests/unit_test_basic.sars");
    defer std.testing.allocator.free(source_path);

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const test_argv = [_][]const u8{"sars", "test", source_path, "--jobs", "1" };
    const test_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        test_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    if (test_code != 0 or stderr_buffer.items.len != 0) {
        std.debug.print("sa test failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ stdout_buffer.items, stderr_buffer.items });
    }
    try std.testing.expectEqual(@as(u8, 0), test_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] simple pass"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] another test"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "test result: ok. 2 passed; 0 failed; 0 skipped"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const list_argv = [_][]const u8{"sars", "test", source_path, "--list", "--filter", "simple" };
    const list_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        list_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), list_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "tests:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "- simple pass"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "test count: 1"));
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "[PASS]") == null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "another test") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const list_only_source =
        \\@extern missing_runtime_probe() -> void
        \\
        \\@test "list avoids backend link"():
        \\L_ENTRY:
        \\    call @missing_runtime_probe()
        \\    return
    ;
    try writeSource(tmp.dir, "list_only.sars", list_only_source);
    const list_only_argv = [_][]const u8{"sars", "test", "list_only.sars", "--list" };
    const list_only_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        list_only_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), list_only_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "list avoids backend link"));
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "[PASS]") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const filter_argv = [_][]const u8{"sars", "test", source_path, "--filter", "another" };
    const filter_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        filter_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), filter_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] another test"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "test result: ok. 1 passed; 0 failed; 1 skipped"));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const exact_argv = [_][]const u8{"sars", "test", source_path, "--exact", "--filter", "simple pass" };
    const exact_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        exact_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), exact_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] simple pass"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "test result: ok. 1 passed; 0 failed; 1 skipped"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const should_panic_path = try original_cwd.realpathAlloc(std.testing.allocator, "tests/unit_test_should_panic.sars");
    defer std.testing.allocator.free(should_panic_path);

    const should_panic_argv = [_][]const u8{"sars", "test", should_panic_path };
    const should_panic_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        should_panic_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), should_panic_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] panic path"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "test result: ok. 1 passed; 0 failed; 0 skipped"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const assert_source =
        \\@extern sa_assert_eq_i64(actual: i64, expected: i64, code: i32) -> void
        \\@extern sa_assert_eq_i64_at(actual: i64, expected: i64, code: i32, &file: ptr, file_len: u64, line: u32, col: u32) -> void
        \\@extern sa_test_debug_i64(&name: ptr, name_len: u64, value: i64) -> void
        \\@const ACTUAL_NAME = utf8:"actual"
        \\@const ASSERT_FILE = utf8:"assert_values.sars"
        \\
        \\@test "assert equal reports values"():
        \\L_FAIL:
        \\    actual = add 40, 1
        \\    call @sa_test_debug_i64(*ACTUAL_NAME, 6, actual)
        \\    call @sa_assert_eq_i64_at(actual, 42, 103, *ASSERT_FILE, 16, 9, 5)
        \\    !actual
        \\    return
        \\
    ;
    try writeSource(tmp.dir, "assert_values.sars", assert_source);

    const compile_only_argv = [_][]const u8{"sars", "test", "assert_values.sars", "--compile-only" };
    const compile_only_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        compile_only_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), compile_only_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "compiled 1 selected tests (1 discovered)"));
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "[FAIL]") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const assert_argv = [_][]const u8{"sars", "test", "assert_values.sars", "--jobs", "1", "--trace-panic" };
    const assert_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        assert_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 1), assert_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[FAIL] assert equal reports values"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "test result: FAILED. 0 passed; 1 failed; 0 skipped"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "test location: assert_values.sa:6:1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "code path: assert_values.sa::_saasm_test_"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "panic: code=103"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "panic location: assert_values.sa:9:5"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "trace-panic: enabled"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "recent scalars:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "actual=41"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "assertion failed:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "expected: 42"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "actual: 41"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "PANIC[103]: assert_values.sa:9:5: expected=42 actual=41"));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const skip_argv = [_][]const u8{"sars", "test", source_path, "--skip", "another" };
    const skip_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        skip_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), skip_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] simple pass"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "test result: ok. 1 passed; 0 failed; 1 skipped"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const ignored_path = try original_cwd.realpathAlloc(std.testing.allocator, "tests/unit_test_ignored.sars");
    defer std.testing.allocator.free(ignored_path);

    const ignored_default_argv = [_][]const u8{"sars", "test", ignored_path };
    const ignored_default_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        ignored_default_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), ignored_default_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] active case"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "test result: ok. 1 passed; 0 failed; 0 skipped; 1 ignored"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const ignored_only_argv = [_][]const u8{"sars", "test", ignored_path, "--ignored" };
    const ignored_only_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        ignored_only_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), ignored_only_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] ignored case"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "test result: ok. 1 passed; 0 failed; 1 skipped"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const include_ignored_argv = [_][]const u8{"sars", "test", ignored_path, "--include-ignored" };
    const include_ignored_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        include_ignored_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), include_ignored_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] active case"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] ignored case"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "test result: ok. 2 passed; 0 failed; 0 skipped"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    const source_text = try sio.cwd().readFileAlloc(std.testing.allocator, source_path, 1024 * 1024);
    defer std.testing.allocator.free(source_text);
    var flat = try saasm.flattener.flatten(std.testing.allocator, source_text);
    defer flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), flat.test_sigs.len);
    try std.testing.expect(std.mem.eql(u8, flat.test_sigs[0].llvm_name.?, "_saasm_test_0"));
    try std.testing.expect(std.mem.eql(u8, flat.test_sigs[1].llvm_name.?, "_saasm_test_1"));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const signal_source =
        \\// Native test fixture that terminates via a real POSIX signal.
        \\
        \\@extern raise(sig: i32) -> i32
        \\
        \\@test "signal abort"():
        \\L_SIGNAL:
        \\    call @raise(6)
        \\    panic(99)
        \\
    ;
    try writeSource(tmp.dir, "signal.sars", signal_source);
    const signal_path = "signal.sars";

    const signal_argv = [_][]const u8{"sars", "test", signal_path };
    const signal_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        signal_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 1), signal_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "terminated by signal"));
}

test "sa test schedules native tests in parallel when jobs are higher" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "tests/unit_test_jobs_parallel.sars");
    defer std.testing.allocator.free(source_path);

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const serial_start = sio.nanoTimestamp();
    const serial_argv = [_][]const u8{"sars", "test", source_path, "--jobs", "1" };
    const serial_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        serial_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    const serial_elapsed: i128 = sio.nanoTimestamp() - serial_start;
    if (serial_code != 0 or stderr_buffer.items.len != 0) {
        std.debug.print(
            "parallel jobs serial run failed:\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ stdout_buffer.items, stderr_buffer.items },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), serial_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] slow one"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] slow two"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] slow three"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] slow four"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "test result: ok. 4 passed; 0 failed; 0 skipped"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const parallel_start = sio.nanoTimestamp();
    const parallel_argv = [_][]const u8{"sars", "test", source_path, "--jobs", "4" };
    const parallel_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        parallel_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    const parallel_elapsed: i128 = sio.nanoTimestamp() - parallel_start;
    if (parallel_code != 0 or stderr_buffer.items.len != 0) {
        std.debug.print(
            "parallel jobs parallel run failed:\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ stdout_buffer.items, stderr_buffer.items },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), parallel_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] slow one"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] slow two"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] slow three"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "[PASS] slow four"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "test result: ok. 4 passed; 0 failed; 0 skipped"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    const min_gap_ns: i128 = 400 * std.time.ns_per_ms;
    try std.testing.expect(serial_elapsed > parallel_elapsed + min_gap_ns);
}

test "fallible ABI and ? propagation work end to end" {
    const source =
        \\@helper() -> i32!:
        \\return 7
        \\@main() -> i32!:
        \\tmp = call @helper()
        \\value = ? tmp
        \\return value
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};
    try writeSource(tmp.dir, "fallible.sars", source);

    const run_argv = [_][]const u8{"sars", "run", "fallible.sars" };
    const run_code = try saasm.cli.execute(std.testing.allocator, run_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), run_code);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "fallible.sars", "-o", "fallible.out" };
    const exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), exe_code);

    const artifact_file = try tmp.dir.openFile(std.testing.io, "fallible.out.sa.bc", .{});
    defer artifact_file.close(std.testing.io);
    const artifact_bytes = try sio.readToEndAlloc(artifact_file, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(artifact_bytes);
    try std.testing.expect(artifact_bytes.len > 0);

    const exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./fallible.out"});
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
}

test "extern u64 fallible return can be loaded from ABI payload offset" {
    const source =
        \\@extern sa_fs_read_file(&path: ptr, path_len: u64, max_bytes: u64) -> u64!
        \\@extern sa_fs_read_buffer_data(buffer: u64) -> &ptr
        \\@extern sa_fs_read_buffer_len(buffer: u64) -> u64
        \\@extern sa_fs_read_buffer_free(^buffer: u64) -> i32
        \\
        \\@const PROBE_PATH = utf8:"probe.env"
        \\
        \\@main() -> i32!:
        \\L_ENTRY:
        \\    path_tmp = *PROBE_PATH
        \\    read_res = call @sa_fs_read_file(&path_tmp, 9, 1024)
        \\    !path_tmp
        \\    read_status = load read_res+0 as i32
        \\    handle = load read_res+8 as u64
        \\    !read_res
        \\    read_ok = eq read_status, 0
        \\    !read_status
        \\    br read_ok -> L_CHECK_LEN, L_FAIL_READ
        \\
        \\L_CHECK_LEN:
        \\    !read_ok
        \\    len = call @sa_fs_read_buffer_len(handle)
        \\    len_ok = eq len, 11
        \\    !len
        \\    br len_ok -> L_CHECK_CONTENT, L_FAIL_LEN
        \\
        \\L_CHECK_CONTENT:
        \\    !len_ok
        \\    data = call @sa_fs_read_buffer_data(handle)
        \\    first = load data+0 as u8
        \\    sixth = load data+5 as u8
        \\    first_ok = eq first, 80
        \\    sixth_ok = eq sixth, 50
        \\    content_ok = and first_ok, sixth_ok
        \\    !first
        \\    !sixth
        \\    !first_ok
        \\    !sixth_ok
        \\    !data
        \\    br content_ok -> L_FREE, L_FAIL_CONTENT
        \\
        \\L_FREE:
        \\    !content_ok
        \\    free_status = call @sa_fs_read_buffer_free(^handle)
        \\    free_ok = eq free_status, 0
        \\    !free_status
        \\    br free_ok -> L_PASS, L_FAIL_FREE
        \\
        \\L_PASS:
        \\    !free_ok
        \\    return 0
        \\
        \\L_FAIL_READ:
        \\    !read_ok
        \\    !handle
        \\    panic(121)
        \\
        \\L_FAIL_LEN:
        \\    !len_ok
        \\    !handle
        \\    panic(122)
        \\
        \\L_FAIL_CONTENT:
        \\    !content_ok
        \\    !handle
        \\    panic(123)
        \\
        \\L_FAIL_FREE:
        \\    !free_ok
        \\    panic(124)
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};
    try writeSource(tmp.dir, "fallible_u64_file.sars", source);
    try writeBytes(tmp.dir, "probe.env", "PORT=28080\n");

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "fallible_u64_file.sars", "-o", "fallible_u64_file.out" };
    const exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), exe_code);

    const exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./fallible_u64_file.out"});
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("fallible u64 ABI probe failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ exe_result.stdout, exe_result.stderr });
            }
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "extern i32 fallible return uses ABI-aligned payload offset" {
    const source =
        \\@extern sa_fs_metadata(&path: ptr, path_len: u64) -> u64!
        \\@extern sa_fs_metadata_free(metadata: u64) -> i32!
        \\@extern sa_test_fallible_i32_value(value: i32) -> i32!
        \\
        \\@const PROBE_PATH = utf8:"probe.env"
        \\
        \\@ffi_wrapper probe_fallible_i32_wire() -> i32:
        \\L_ENTRY:
        \\    sentinel_res = call @sa_test_fallible_i32_value(77)
        \\    sentinel_status = load sentinel_res+0 as i32
        \\    sentinel_value = load sentinel_res+4 as i32
        \\    !sentinel_res
        \\    sentinel_status_ok = eq sentinel_status, 0
        \\    !sentinel_status
        \\    br sentinel_status_ok -> L_CHECK_SENTINEL_VALUE, L_FAIL_SENTINEL_STATUS
        \\
        \\L_CHECK_SENTINEL_VALUE:
        \\    !sentinel_status_ok
        \\    sentinel_value_ok = eq sentinel_value, 77
        \\    !sentinel_value
        \\    br sentinel_value_ok -> L_METADATA, L_FAIL_SENTINEL_VALUE
        \\
        \\L_METADATA:
        \\    !sentinel_value_ok
        \\    path_tmp = *PROBE_PATH
        \\    metadata_res = call @sa_fs_metadata(&path_tmp, 9)
        \\    !path_tmp
        \\    metadata_status = load metadata_res+0 as i32
        \\    metadata = load metadata_res+8 as u64
        \\    !metadata_res
        \\    metadata_ok = eq metadata_status, 0
        \\    !metadata_status
        \\    br metadata_ok -> L_FREE, L_FAIL_METADATA
        \\
        \\L_FREE:
        \\    !metadata_ok
        \\    free_res = call @sa_fs_metadata_free(metadata)
        \\    !metadata
        \\    free_status = load free_res+0 as i32
        \\    free_value = load free_res+4 as i32
        \\    !free_res
        \\    status_ok = eq free_status, 0
        \\    !free_status
        \\    br status_ok -> L_CHECK_VALUE, L_FAIL_STATUS
        \\
        \\L_CHECK_VALUE:
        \\    !status_ok
        \\    value_ok = eq free_value, 0
        \\    !free_value
        \\    br value_ok -> L_TAIL_SENTINEL, L_FAIL_VALUE
        \\
        \\L_TAIL_SENTINEL:
        \\    !value_ok
        \\    tail = alloc 35
        \\    store tail+31, 1 as u8
        \\    resolved = load tail+31 as u8
        \\    !tail
        \\    resolved_ok = eq resolved, 1
        \\    !resolved
        \\    br resolved_ok -> L_PASS, L_FAIL_TAIL
        \\
        \\L_PASS:
        \\    !resolved_ok
        \\    return 0
        \\
        \\L_FAIL_METADATA:
        \\    !metadata_ok
        \\    !metadata
        \\    panic(125)
        \\
        \\L_FAIL_STATUS:
        \\    !status_ok
        \\    !free_value
        \\    panic(126)
        \\
        \\L_FAIL_VALUE:
        \\    !value_ok
        \\    panic(128)
        \\
        \\L_FAIL_TAIL:
        \\    !resolved_ok
        \\    panic(127)
        \\
        \\L_FAIL_SENTINEL_STATUS:
        \\    !sentinel_status_ok
        \\    !sentinel_value
        \\    panic(129)
        \\
        \\L_FAIL_SENTINEL_VALUE:
        \\    !sentinel_value_ok
        \\    panic(130)
        \\
        \\@main() -> i32!:
        \\L_MAIN:
        \\    status = call @probe_fallible_i32_wire()
        \\    return status
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};
    try writeSource(tmp.dir, "fallible_i32_file.sars", source);
    try writeBytes(tmp.dir, "probe.env", "PORT=28080\n");

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "fallible_i32_file.sars", "-o", "fallible_i32_file.out" };
    const exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), exe_code);

    const exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./fallible_i32_file.out"});
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("fallible i32 ABI probe failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ exe_result.stdout, exe_result.stderr });
            }
            try std.testing.expectEqual(@as(u8, 0), code);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "result unwrap_or and map_or helpers branch on tags correctly" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const result_layout_path = try original_cwd.realpathAlloc(std.testing.allocator, "sa_std/core/result.sal");
    defer std.testing.allocator.free(result_layout_path);
    const result_src_path = try original_cwd.realpathAlloc(std.testing.allocator, "sa_std/core/result.sars");
    defer std.testing.allocator.free(result_src_path);
    const panic_src_path = try original_cwd.realpathAlloc(std.testing.allocator, "sa_std/core/panic.sars");
    defer std.testing.allocator.free(panic_src_path);

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\@import "{s}"
        \\@import "{s}"
        \\@import "{s}"
        \\
        \\@double(x: u64) -> u64:
        \\L_ENTRY:
        \\    y = mul x, 2
        \\    return y
        \\@fallback() -> u64:
        \\L_ENTRY:
        \\    return 99
        \\@main() -> i32:
        \\L_ENTRY:
        \\    ok_res = alloc Result_SIZE
        \\    EXPAND RESULT_SET_OK ok_res, 7
        \\    err_res = alloc Result_SIZE
        \\    EXPAND RESULT_SET_ERR err_res, 3
        \\    EXPAND RESULT_UNWRAP_OR ok_unwrap, ok_res, 1
        \\    EXPAND RESULT_UNWRAP_OR err_unwrap, err_res, 5
        \\    EXPAND RESULT_MAP_OR ok_map, ok_res, @double, 1
        \\    EXPAND RESULT_MAP_OR err_map, err_res, @double, 3
        \\    EXPAND RESULT_MAP_OR_ELSE ok_map_else, ok_res, @double, @fallback
        \\    EXPAND RESULT_MAP_OR_ELSE err_map_else, err_res, @double, @fallback
        \\    sum1 = add ok_unwrap, err_unwrap
        \\    sum2 = add ok_map, err_map
        \\    sum3 = add ok_map_else, err_map_else
        \\    sum12 = add sum1, sum2
        \\    total = add sum12, sum3
        \\    !sum1
        \\    !sum2
        \\    !sum3
        \\    !sum12
        \\    !ok_unwrap
        \\    !err_unwrap
        \\    !ok_map
        \\    !err_map
        \\    !ok_map_else
        \\    !err_map_else
        \\    !ok_res
        \\    !err_res
        \\    return total
    , .{ result_layout_path, result_src_path, panic_src_path });
    defer std.testing.allocator.free(source);

    try writeSource(tmp.dir, "result_helpers.sars", source);

    const run_argv = [_][]const u8{"sars", "run", "result_helpers.sars" };
    const run_code = try saasm.cli.execute(std.testing.allocator, run_argv[0..]);
    try std.testing.expectEqual(@as(u8, 142), run_code);
}

test "const pointer stores survive load and print end to end" {
    const source =
        \\@import "sa_std/io/print.sai"
        \\@const RESULT_OK = utf8:"OK\n"
        \\#def Box_SIZE = 8
        \\#def Box_ptr = +0
        \\@main() -> i32:
        \\box = alloc Box_SIZE
        \\store box+Box_ptr, &RESULT_OK as ptr
        \\loaded = load box+Box_ptr as ptr
        \\call @sa_print_bytes(&loaded, 3)
        \\!loaded
        \\!box
        \\return 0
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};
    try writeSource(tmp.dir, "const_ptr_store.sars", source);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "const_ptr_store.sars", "-o", "const_ptr_store.out" };
    const exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), exe_code);

    const exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./const_ptr_store.out"});
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("OK\n", exe_result.stdout);
}

test "vtable loads preserve indirect call provenance end to end" {
    const source =
        \\@import "sa_std/io/print.sai"
        \\@const RESULT_OK = utf8:"OK\n"
        \\@const VTABLE = vtable { run = @slot_run }
        \\#def Obj_SIZE = 16
        \\#def Obj_DATA = +0
        \\#def Obj_VTABLE = +8
        \\#def VTable_run = +0
        \\@slot_run(&self: ptr) -> i32:
        \\L_ENTRY:
        \\    value = load self+Obj_DATA as i32
        \\    return value
        \\@invoke(&obj: ptr) -> i32:
        \\L_ENTRY:
        \\    vt = load obj+Obj_VTABLE as ptr
        \\    fn = load vt+VTable_run as ptr
        \\    value = call_indirect fn(&obj)
        \\    !fn
        \\    !vt
        \\    return value
        \\@main() -> i32:
        \\L_ENTRY:
        \\    obj = alloc Obj_SIZE
        \\    store obj+Obj_DATA, 77 as i32
        \\    store obj+Obj_VTABLE, &VTABLE as ptr
        \\    result = call @invoke(&obj)
        \\    ok = eq result, 77
        \\    !result
        \\    !obj
        \\    br ok -> L_OK, L_ERR
        \\L_OK:
        \\    !ok
        \\    call @sa_print_bytes(&RESULT_OK, 3)
        \\    return 0
        \\L_ERR:
        \\    !ok
        \\    return 1
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};
    try writeSource(tmp.dir, "vtable_indirect.sars", source);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "vtable_indirect.sars", "-o", "vtable_indirect.out" };
    const exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), exe_code);

    const exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./vtable_indirect.out"});
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("OK\n", exe_result.stdout);
}

test "bc2sa translates real llvm bitcode" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, "sample.ll",
        \\define i32 @main(i32 %lhs, i32 %rhs) {
        \\entry:
        \\  %0 = add i32 %lhs, %rhs
        \\  %1 = icmp sgt i32 %0, 2
        \\  br i1 %1, label %ok, label %err
        \\ok:
        \\  ret i32 %0
        \\err:
        \\  ret i32 0
        \\}
        \\
    );

    const as_result = sio.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &[_][]const u8{ "llvm-as-14", "sample.ll", "-o", "sample.bc" },
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(as_result.stdout);
    defer std.testing.allocator.free(as_result.stderr);
    switch (as_result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    var stdout_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const bc2sa_argv = [_][]const u8{"sars", "bc2sa", "sample.bc" };
    const bc2sa_code = try saasm.cli.executeWithWriters(std.testing.allocator, bc2sa_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 0), bc2sa_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "@export main(lhs: i32, rhs: i32) -> i32:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "r0 = add lhs, rhs") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "br r1 -> L_ok, L_err") != null);
}

test "bc2sa translates clang cmake bitcode demo" {
    if (!llvmDisAvailable()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const demo_root = try sio.cwd().realpathAlloc(std.testing.allocator, "demos/bc2sa_cmake");
    defer std.testing.allocator.free(demo_root);

    const build_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(build_dir);

    const cmake_result = try sio.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &[_][]const u8{ "cmake", "-S", demo_root, "-B", build_dir },
    });
    defer std.testing.allocator.free(cmake_result.stdout);
    defer std.testing.allocator.free(cmake_result.stderr);
    switch (cmake_result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    const build_result = try sio.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &[_][]const u8{ "cmake", "--build", build_dir, "--target", "bc" },
    });
    defer std.testing.allocator.free(build_result.stdout);
    defer std.testing.allocator.free(build_result.stderr);
    switch (build_result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    var stdout_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const bc_path = try std.fs.path.join(std.testing.allocator, &.{ build_dir, "main.bc" });
    defer std.testing.allocator.free(bc_path);

    const bc2sa_argv = [_][]const u8{"sars", "bc2sa", bc_path };
    const bc2sa_code = try saasm.cli.executeWithWriters(std.testing.allocator, bc2sa_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 0), bc2sa_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "@export demo(arg0: i32, arg1: i32) -> i32:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "@export scale(arg0: i32) -> i32:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "sgt r10, 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "call @scale(r13)") != null);
}

test "bc2sa translates sqlite3 api probe bitcode" {
    if (!clangAvailable()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const demo_root = sio.cwd().realpathAlloc(std.testing.allocator, "demos/bc2sa_sqlite3") catch |err| switch (err) {
        // Fixture not vendored on this branch (missing on main too); skip
        // instead of failing with FileNotFound.
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(demo_root);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ demo_root, "sqlite3_probe.c" });
    defer std.testing.allocator.free(source_path);
    const build_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(build_dir);
    const bc_path = try std.fs.path.join(std.testing.allocator, &.{ build_dir, "sqlite3_probe.bc" });
    defer std.testing.allocator.free(bc_path);

    const clang_result = try sio.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &[_][]const u8{ "clang", "-std=c11", "-O0", "-emit-llvm", "-c", source_path, "-o", bc_path },
    });
    defer std.testing.allocator.free(clang_result.stdout);
    defer std.testing.allocator.free(clang_result.stderr);
    switch (clang_result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    var stdout_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const bc2sa_argv = [_][]const u8{"sars", "bc2sa", bc_path };
    const bc2sa_code = try saasm.cli.executeWithWriters(std.testing.allocator, bc2sa_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 0), bc2sa_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "@extern sqlite3_open(") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "@export sqlite3_bc2sa_chain_probe(arg0: ptr) -> i32:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "@const ") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "file:memdb1?mode=memory&cache=shared") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "select 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "call @sqlite3_open(") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "call @sqlite3_prepare_v2(") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "call @sqlite3_step(") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "call @sqlite3_finalize(") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "call @sqlite3_close(") != null);
}

test "bc2sa rejects static stack buffer overflow in clang cmake demo" {
    if (!llvmDisAvailable()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const demo_root = try sio.cwd().realpathAlloc(std.testing.allocator, "demos/bc2sa_cmake");
    defer std.testing.allocator.free(demo_root);

    const build_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(build_dir);

    const cmake_result = try sio.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &[_][]const u8{ "cmake", "-S", demo_root, "-B", build_dir },
    });
    defer std.testing.allocator.free(cmake_result.stdout);
    defer std.testing.allocator.free(cmake_result.stderr);
    switch (cmake_result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    const build_result = try sio.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &[_][]const u8{ "cmake", "--build", build_dir, "--target", "bc" },
    });
    defer std.testing.allocator.free(build_result.stdout);
    defer std.testing.allocator.free(build_result.stderr);
    switch (build_result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    try writeSource(tmp.dir, "vulnerable.c",
        \\void hack_me(void) {
        \\    char buffer[8];
        \\    buffer[10] = 'A';
        \\}
    );

    const clang_result = try sio.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &[_][]const u8{ "clang", "-std=c11", "-O0", "-emit-llvm", "-c", "vulnerable.c", "-o", "vulnerable.bc" },
    });
    defer std.testing.allocator.free(clang_result.stdout);
    defer std.testing.allocator.free(clang_result.stderr);
    switch (clang_result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    var stdout_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const bc2sa_argv = [_][]const u8{"sars", "bc2sa", "vulnerable.bc" };
    const bc2sa_code = try saasm.cli.executeWithWriters(std.testing.allocator, bc2sa_argv[0..], sio.managedWriter(&stdout_buf), sio.managedWriter(&stderr_buf));
    try std.testing.expectEqual(@as(u8, 1), bc2sa_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, "SA-CLI-019"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, "static memory overflow detected"));
}

test "import expansion keeps source paths alive end to end" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "demos/rosetta/40_impl_block_state/main.sars");
    defer std.testing.allocator.free(source_path);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", "impl_block_state.out" };
    const exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), exe_code);

    const exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./impl_block_state.out"});
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("15\n", exe_result.stdout);
}

test "atomic instructions work end to end and emit real LLVM" {
    const source =
        \\@main() -> i32:
        \\node = alloc 8
        \\atomic_store node+0, 5 seq_cst
        \\fence release
        \\x = atomic_load node+0 seq_cst
        \\old = atomic_rmw_add node+0, 3 seq_cst
        \\cmp_old, ok = cmpxchg node+0, 8, 11 acq_rel acquire
        \\y = atomic_load node+0 seq_cst
        \\^x
        \\^old
        \\^cmp_old
        \\^ok
        \\!node
        \\return y
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, "atomic.sars", source);

    const run_argv = [_][]const u8{"sars", "run", "atomic.sars" };
    const run_code = try saasm.cli.execute(std.testing.allocator, run_argv[0..]);
    try std.testing.expectEqual(@as(u8, 11), run_code);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "atomic.sars", "-o", "atomic.out" };
    const exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), exe_code);

    const artifact_file = try tmp.dir.openFile(std.testing.io, "atomic.out.sa.bc", .{});
    defer artifact_file.close(std.testing.io);
    const artifact_bytes = try sio.readToEndAlloc(artifact_file, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(artifact_bytes);
    try std.testing.expect(artifact_bytes.len > 0);

    const exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./atomic.out"});
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 11), code),
        else => return error.TestUnexpectedResult,
    }

    const build_wasm_argv = [_][]const u8{"sars", "build-wasm", "atomic.sars", "-o", "atomic.wasm", "--target", "wasm32" };
    const wasm_code = try saasm.cli.execute(std.testing.allocator, build_wasm_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), wasm_code);

    const wasm_file = try tmp.dir.openFile(std.testing.io, "atomic.wasm", .{});
    defer wasm_file.close(std.testing.io);
    const wasm_bytes = try sio.readToEndAlloc(wasm_file, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(wasm_bytes);
    try std.testing.expect(wasm_bytes.len > 8);
    try std.testing.expectEqualSlices(u8, &std.wasm.magic, wasm_bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &std.wasm.version, wasm_bytes[4..8]);

    const build_obj_argv = [_][]const u8{"sars", "build-obj", "atomic.sars", "-o", "atomic.o" };
    const obj_code = try saasm.cli.execute(std.testing.allocator, build_obj_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), obj_code);

    const obj_file = try tmp.dir.openFile(std.testing.io, "atomic.o", .{});
    defer obj_file.close(std.testing.io);
    const obj_bytes = try sio.readToEndAlloc(obj_file, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(obj_bytes);
    try std.testing.expect(obj_bytes.len > 0);
}

test "ptr arithmetic lowers to gep and runs through the interpreter" {
    const source =
        \\@main() -> i32:
        \\node = alloc 8
        \\one_buf = alloc 8
        \\store one_buf+0, 1 as i64
        \\one = load one_buf+0 as i64
        \\p = ptr_add node, one
        \\store p+0, 65 as i32
        \\value = load p+0 as i32
        \\!p
        \\!one
        \\!one_buf
        \\!node
        \\return value
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, "ptr_add.sars", source);

    const run_argv = [_][]const u8{"sars", "run", "ptr_add.sars" };
    const run_code = try saasm.cli.execute(std.testing.allocator, run_argv[0..]);
    try std.testing.expectEqual(@as(u8, 65), run_code);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "ptr_add.sars", "-o", "ptr_add.out" };
    const exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), exe_code);

    const artifact_file = try tmp.dir.openFile(std.testing.io, "ptr_add.out.sa.bc", .{});
    defer artifact_file.close(std.testing.io);
    const artifact_bytes = try sio.readToEndAlloc(artifact_file, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(artifact_bytes);
    try std.testing.expect(artifact_bytes.len > 0);

    const exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./ptr_add.out"});
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 65), code),
        else => return error.TestUnexpectedResult,
    }
}

test "invalid cmpxchg ordering is rejected by the flattener" {
    const source =
        \\@main() -> i32:
        \\node = alloc 8
        \\old, ok = cmpxchg node+0, 0, 1 acquire seq_cst
        \\return 0
    ;

    try std.testing.expectError(error.InvalidAtomicOrdering, saasm.flattener.flatten(std.testing.allocator, source));
}

test "atomic ordering mismatch is rejected by the verifier" {
    const source =
        \\@main() -> i32:
        \\node = alloc 8
        \\old = atomic_rmw_add node+0, 1 acquire
        \\old2 = atomic_rmw_sub node+0, 1 release
        \\return 0
    ;

    var flat = try saasm.flattener.flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try saasm.referee.verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .ok => return error.TestUnexpectedResult,
        .trap => |report| {
            try std.testing.expectEqual(saasm.common.trap.Trap.atomic_ordering_mismatch, report.trap);
            try std.testing.expect(std.mem.containsAtLeast(u8, report.message, 1, "same-address RMW ordering combination"));
        },
    }
}

test "panic lowers to native executable failure code" {
    const source =
        \\@helper() -> i32:
        \\panic(13)
        \\@main() -> i32:
        \\buf = alloc 3
        \\store buf+0, 104 as i8
        \\store buf+1, 105 as i8
        \\store buf+2, 0 as i8
        \\panic_msg(77, *buf, 2)
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, "panic_native.sars", source);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "panic_native.sars", "-o", "panic_native.out" };
    const exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), exe_code);

    const artifact_file = try tmp.dir.openFile(std.testing.io, "panic_native.out.sa.bc", .{});
    defer artifact_file.close(std.testing.io);
    const artifact_bytes = try sio.readToEndAlloc(artifact_file, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(artifact_bytes);
    try std.testing.expect(artifact_bytes.len > 0);

    const exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./panic_native.out"});
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 205), code),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(std.mem.containsAtLeast(u8, exe_result.stderr, 1, "PANIC[77]: hi"));

    const build_wasm_argv = [_][]const u8{"sars", "build-wasm", "panic_native.sars", "-o", "panic_native.wasm", "--target", "wasm32" };
    const wasm_code = try saasm.cli.execute(std.testing.allocator, build_wasm_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), wasm_code);

    const wasm = try tmp.dir.openFile(std.testing.io, "panic_native.wasm", .{});
    defer wasm.close(std.testing.io);
    const wasm_bytes = try sio.readToEndAlloc(wasm, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(wasm_bytes);
    try std.testing.expect(wasm_bytes.len > 8);
    try std.testing.expectEqualSlices(u8, &std.wasm.magic, wasm_bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &std.wasm.version, wasm_bytes[4..8]);
}

test "raw pointer escape is rejected outside ffi wrapper" {
    const source =
        \\@main() -> i32:
        \\node = alloc 8
        \\raw = *node
        \\return 0
    ;

    var flat = try saasm.flattener.flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try saasm.referee.verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .ok => return error.TestUnexpectedResult,
        .trap => |report| {
            try std.testing.expectEqual(saasm.common.trap.Trap.illegal_unsafe_context, report.trap);
            try std.testing.expectEqual(@as(?bool, false), report.is_ffi_wrapper);
        },
    }
}

test "extern export ffi wrapper map to real declarations and symbols" {
    const source =
        \\@extern ext_add(lhs: i32, rhs: i32) -> i32
        \\@ffi_wrapper wrap(*raw: ptr) -> ptr:
        \\safe = assume_safe raw
        \\return safe
        \\@export exported() -> i32:
        \\jmp L_ENTRY
        \\L_ENTRY:
        \\value = call @ext_add(1, 2)
        \\return value
        \\@main() -> i32:
        \\return 7
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};
    try writeSource(tmp.dir, "contracts.sars", source);

    const build_obj_argv = [_][]const u8{"sars", "build-obj", "contracts.sars", "-o", "contracts.o" };
    const code = try saasm.cli.execute(std.testing.allocator, build_obj_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), code);

    const artifact_file = try tmp.dir.openFile(std.testing.io, "contracts.o.sa.bc", .{});
    defer artifact_file.close(std.testing.io);
    const artifact_bytes = try sio.readToEndAlloc(artifact_file, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(artifact_bytes);
    try std.testing.expect(artifact_bytes.len > 0);

    const nm_output = try runCommand(std.testing.allocator, &[_][]const u8{ "nm", "-g", "--defined-only", "contracts.o" });
    defer std.testing.allocator.free(nm_output);

    try std.testing.expect(std.mem.containsAtLeast(u8, nm_output, 1, " exported"));
    try std.testing.expect(std.mem.containsAtLeast(u8, nm_output, 1, " wrap"));
    try std.testing.expect(std.mem.containsAtLeast(u8, nm_output, 1, " saasm_main"));
    try std.testing.expect(std.mem.containsAtLeast(u8, nm_output, 1, " main"));
}

test "unknown sys intrinsic is rejected before emission" {
    const source =
        \\@main() -> i32:
        \\value = call @sys_not_supported()
        \\return value
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};
    try writeSource(tmp.dir, "unsupported_sys.sars", source);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "unsupported_sys.sars", "-o", "unsupported_sys.out" };
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();
    const code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        build_exe_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "unsupported_sys.out", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "unsupported_sys.out.sa.bc", .{}));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"trap\":\"UnsupportedSysIntrinsic\""));
}

test "external compiler failures report linker context instead of child process noise" {
    const source =
        \\@extern missing_symbol() -> i32
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\value = call @missing_symbol()
        \\return value
    ;

    try assertBuildExeLinkFailure("link_fail.sars", source, "link_fail.out", "ld.lld: error: undefined symbol: missing_symbol");
}

test "unknown register demo is rejected with structured trap output" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "demos/support/unknown_register.sars");
    defer std.testing.allocator.free(source_path);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", "unknown_register.out" };
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        build_exe_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "unknown_register.out", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "unknown_register.out.sa.bc", .{}));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"trap\":\"UnknownRegister\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"trap_code\":1007"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"register\":\"ghost\""));
}

test "memory leak demo is rejected with structured trap output" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "demos/support/memory_leak.sars");
    defer std.testing.allocator.free(source_path);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", "memory_leak.out" };
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        build_exe_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "memory_leak.out", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "memory_leak.out.sa.bc", .{}));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"trap\":\"MemoryLeak\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"trap_code\":1012"));
}

test "fallthrough demo is rejected without a terminator" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "demos/support/fallthrough.sars");
    defer std.testing.allocator.free(source_path);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", "fallthrough.out" };
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        build_exe_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "fallthrough.out", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "fallthrough.out.sa.bc", .{}));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"trap\":\"FallthroughForbidden\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"trap_code\":1014"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "function body ended without a terminator"));
}

test "duplicate label demo is rejected with structured trap output" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "demos/support/duplicate_label.sars");
    defer std.testing.allocator.free(source_path);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", "duplicate_label.out" };
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        build_exe_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "duplicate_label.out", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "duplicate_label.out.sa.bc", .{}));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"trap\":\"DuplicateLabel\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"trap_code\":1003"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "label is already defined"));
}

test "phi conflict demo is rejected on mismatched join states" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "demos/support/phi_conflict.sars");
    defer std.testing.allocator.free(source_path);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", "phi_conflict.out" };
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        build_exe_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "phi_conflict.out", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "phi_conflict.out.sa.bc", .{}));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"trap\":\"PhiStateConflict\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"trap_code\":1015"));
}

test "phi join AND demo runs through the join point" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, "demos/support/phi_join_and.sars");
    defer std.testing.allocator.free(source_path);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", "phi_join_and.out" };
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        build_exe_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    const run_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./phi_join_and.out"});
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    switch (run_result.term) {
        .exited => |exit_code| try std.testing.expectEqual(@as(u8, 0), exit_code),
        else => return error.TestUnexpectedResult,
    }
}

test "build-wasm supports wasm64 freestanding no-entry" {
    const source =
        \\@main() -> i32:
        \\return 0
    ;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};
    try writeSource(tmp.dir, "wasm64.sars", source);

    const build_wasm_argv = [_][]const u8{"sars", "build-wasm", "wasm64.sars", "-o", "wasm64.wasm", "--target", "wasm64" };
    const build_wasm_code = try saasm.cli.execute(std.testing.allocator, build_wasm_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), build_wasm_code);

    const wasm_file = try tmp.dir.openFile(std.testing.io, "wasm64.wasm", .{});
    defer wasm_file.close(std.testing.io);
    const wasm_bytes = try sio.readToEndAlloc(wasm_file, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(wasm_bytes);
    try std.testing.expect(wasm_bytes.len > 8);
    try std.testing.expectEqualSlices(u8, &std.wasm.magic, wasm_bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &std.wasm.version, wasm_bytes[4..8]);
    const import_names = try wasmImportNames(wasm_bytes, std.testing.allocator);
    defer std.testing.allocator.free(import_names);
    try std.testing.expectEqual(@as(usize, 0), import_names.len);
}

test "db cli init writes iface and table lifecycle commands update storage" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, "flash_sale.sadb-schema",
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_PRICE_STRIDE = 4 // f32
    );
    try writeSource(tmp.dir, "rows.csv",
        \\ID,PRICE
        \\1,9.5
        \\2,10.25
    );
    try writeSource(tmp.dir, "more.jsonl",
        \\{"ID":3,"PRICE":11.75}
    );

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const init_argv = [_][]const u8{ "sars", "db", "init", "flash_sale.sadb-schema" };
    const init_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        init_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), init_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "flash_sale.iface"));

    const iface_file = try tmp.dir.openFile(std.testing.io, "flash_sale.iface", .{});
    defer iface_file.close(std.testing.io);
    const iface_bytes = try sio.readToEndAlloc(iface_file, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(iface_bytes);
    try std.testing.expect(std.mem.containsAtLeast(u8, iface_bytes, 1, "#def MAX_ROWS = 10"));
    try std.testing.expect(std.mem.containsAtLeast(u8, iface_bytes, 1, "#def TABLE_ROW_BYTES = 12"));
    try std.testing.expect(std.mem.containsAtLeast(u8, iface_bytes, 1, "#def flash_sale_ROW_BYTES = 12"));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const ingest_argv = [_][]const u8{ "sars", "db", "ingest", "flash_sale", "rows.csv" };
    const ingest_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        ingest_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), ingest_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "row_count: 2"));

    const meta_file = try tmp.dir.openFile(std.testing.io, "flash_sale.meta", .{});
    defer meta_file.close(std.testing.io);
    const meta_bytes = try sio.readToEndAlloc(meta_file, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(meta_bytes);
    try std.testing.expect(std.mem.containsAtLeast(u8, meta_bytes, 1, "\"row_count\":2"));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const snapshot_argv = [_][]const u8{ "sars", "db", "snapshot", "flash_sale" };
    const snapshot_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        snapshot_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), snapshot_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "epoch: 1"));
    const snapshot_meta = try tmp.dir.openFile(std.testing.io, ".sa/db/snapshots/flash_sale/1/flash_sale.meta", .{});
    defer snapshot_meta.close();

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const second_ingest_argv = [_][]const u8{ "sars", "db", "ingest", "flash_sale", "more.jsonl" };
    const second_ingest_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        second_ingest_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), second_ingest_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "row_count: 3"));

    const updated_meta_file = try tmp.dir.openFile(std.testing.io, "flash_sale.meta", .{});
    defer updated_meta_file.close(std.testing.io);
    const updated_meta_bytes = try sio.readToEndAlloc(updated_meta_file, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(updated_meta_bytes);
    try std.testing.expect(std.mem.containsAtLeast(u8, updated_meta_bytes, 1, "\"row_count\":3"));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const verify_argv = [_][]const u8{ "sars", "db", "verify", "flash_sale" };
    const verify_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        verify_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), verify_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "row_count: 3"));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const compact_argv = [_][]const u8{ "sars", "db", "compact", "flash_sale" };
    const compact_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        compact_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), compact_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "segment_count: 1"));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const restore_argv = [_][]const u8{ "sars", "db", "restore", "flash_sale", "1" };
    const restore_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        restore_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), restore_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "row_count: 2"));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const lock_argv = [_][]const u8{ "sars", "db", "lock", "flash_sale" };
    const lock_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        lock_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), lock_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "locked: true"));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const locked_compact_argv = [_][]const u8{ "sars", "db", "compact", "flash_sale" };
    const locked_compact_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        locked_compact_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 1), locked_compact_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "error: Locked"));
}

test "db cli register inspect exec round trip through registry" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, "simple.sadb-schema",
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_FACTOR_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 16
    );
    try writeSource(tmp.dir, "simple.query.sars",
        \\@import "simple.sadb-schema"
        \\grants [db_read:simple]
        \\@main(id: u64, factor: u64) -> u64:
        \\L_ENTRY:
        \\total = add id, factor
        \\!id
        \\!factor
        \\return total
    );

    var params = std.array_list.Managed(u8).init(std.testing.allocator);
    defer params.deinit();
    try sio.managedWriter(&params).writeInt(u64, 7, .little);
    try sio.managedWriter(&params).writeInt(u64, 5, .little);
    try writeBytes(tmp.dir, "params.bin", params.items);

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const register_argv = [_][]const u8{ "sars", "db", "register", "simple.query.sars" };
    const register_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        register_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), register_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "Compiled: simple.query.sars"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "Registered:"));

    const hash_hex = try std.testing.allocator.dupe(u8, try extractLineValue(stdout_buffer.items, "Hash: "));
    defer std.testing.allocator.free(hash_hex);
    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const inspect_argv = [_][]const u8{ "sars", "db", "inspect", hash_hex };
    const inspect_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        inspect_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), inspect_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "imports: 1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "grants: 1"));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const exec_argv = [_][]const u8{ "sars", "db", "exec", hash_hex, "--params", "params.bin" };
    const exec_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        exec_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 12), exec_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
}

test "layout cli prints text, json, and debug macro outputs" {
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const text_argv = [_][]const u8{"sars", "layout", "--name", "Entity", "--fields", "id:u32, pos_x:f64, pos_y:f64, hp:i32" };
    const text_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        text_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), text_code);
    try std.testing.expectEqualStrings(
        "#def Entity_SIZE  = 32\n#def Entity_id = +0\n// 4 bytes padding\n#def Entity_pos_x = +8\n#def Entity_pos_y = +16\n#def Entity_hp = +24\n// 4 bytes tail padding\n",
        stdout_buffer.items,
    );
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const json_argv = [_][]const u8{"sars", "layout", "--name", "Pair", "--fields", "head:ptr, count:u32", "--format", "json", "--target", "32" };
    const json_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        json_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), json_code);
    try std.testing.expectEqualStrings(
        "{\"name\":\"Pair\",\"size\":8,\"fields\":[{\"name\":\"head\",\"offset\":0,\"size\":4,\"ty\":\"ptr\"},{\"name\":\"count\",\"offset\":4,\"size\":4,\"ty\":\"u32\"}]}\n",
        stdout_buffer.items,
    );
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const debug_argv = [_][]const u8{"sars", "layout", "--name", "Entity", "--fields", "id:u64, pos:f64, active:i1", "--format", "debug" };
    const debug_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        debug_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), debug_code);
    try std.testing.expectEqualStrings(
        \\#def Entity_SIZE  = 24
        \\#def Entity_id = +0
        \\#def Entity_pos = +8
        \\#def Entity_active = +16
        \\// 7 bytes tail padding
        \\
        \\[MACRO] DEBUG_PRINT_Entity %ptr
        \\    EXPAND PRINT! "Entity { "
        \\    __dbg_Entity_id = load %ptr+Entity_id as u64
        \\    EXPAND PRINT! "id: {:u}, ", __dbg_Entity_id
        \\    !__dbg_Entity_id
        \\    __dbg_Entity_pos = load %ptr+Entity_pos as f64
        \\    EXPAND PRINT! "pos: {:f}, ", __dbg_Entity_pos
        \\    !__dbg_Entity_pos
        \\    EXPAND PRINT! "active: <unsupported:i1>"
        \\    EXPAND PRINT! " }\n"
        \\[END_MACRO]
        \\
    , stdout_buffer.items);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const dict_argv = [_][]const u8{"sars", "layout", "--name", "Entity", "--fields", "id:u64, pos:f64", "--format", "dict" };
    const dict_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        dict_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), dict_code);
    try std.testing.expectEqualStrings(
        \\#def LAYOUT_Entity_SIZE = 16
        \\#def LAYOUT_Entity_ALIGN = 8
        \\#def LAYOUT_Entity_id_OFFSET = +0
        \\#def LAYOUT_Entity_id_SIZE = 8
        \\#def LAYOUT_Entity_id_ALIGN = 8
        \\// LAYOUT_Entity_id_TYPE = u64
        \\#def LAYOUT_Entity_pos_OFFSET = +8
        \\#def LAYOUT_Entity_pos_SIZE = 8
        \\#def LAYOUT_Entity_pos_ALIGN = 8
        \\// LAYOUT_Entity_pos_TYPE = f64
        \\
    , stdout_buffer.items);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
}

test "agent-first cli commands print explain fix and skills outputs" {
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const explain_argv = [_][]const u8{"sars", "explain", "SA-CLI-001" };
    const explain_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        explain_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), explain_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "code: SA-CLI-001"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "title: Missing required operand"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "fix: Pass the required file, path, or operand after the command."));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const explain_json_argv = [_][]const u8{"sars", "explain", "SA-CLI-001", "--json" };
    const explain_json_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        explain_json_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), explain_json_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"status\":\"ok\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"codes\":[\"SA-CLI-001\"]"));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const fix_argv = [_][]const u8{"sars", "fix", "--plan", "SA-CLI-001", "--json" };
    const fix_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        fix_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), fix_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"action\":\"add\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"plan\""));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const skills_argv = [_][]const u8{"sars", "skills", "--json" };
    const skills_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        skills_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), skills_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"status\":\"ok\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"core diagnostics\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"std runtime\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"init [path]\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"pkg install [identity]\""));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const skills_help_argv = [_][]const u8{"sars", "skills", "--help" };
    const skills_help_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        skills_help_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), skills_help_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "usage: sars skills [--json]"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "scans the current sa_std root"));
}

test "sa skills writes Codex and Claude skill files for current project" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sa_plugins/sa_plugin_deno");
    try writeSource(tmp.dir, "sa_plugins/sa_plugin_deno/sap.json",
        \\{
        \\  "schema": "sa.plugin/1",
        \\  "name": "deno",
        \\  "version": "0.1.0",
        \\  "source": { "type": "local", "path": "." },
        \\  "abi": { "plugin": 1, "saasm": ">=0.4.0" },
        \\  "artifacts": { "linux-x86_64": { "path": "zig-out/lib/libdeno.so" } },
        \\  "interfaces": { "sai": { "path": "deno.sai" }, "sal": { "path": "deno.sal" } },
        \\  "skills": ["deno.sys", "deno.env"],
        \\  "permissions": {
        \\    "fs": [{ "op": "read", "path": "$PROJECT/**" }],
        \\    "net": [{ "url": "https://*", "methods": ["GET"] }],
        \\    "env": ["HOME", "SA_*"],
        \\    "process": { "spawn": false, "exec": [] }
        \\  },
        \\  "dependencies": {}
        \\}
        \\
    );
    try writeSource(tmp.dir, "sa_plugins/sa_plugin_deno/README.md",
        \\Deno compatibility facade for env, fs, process, and HTTP bridge workflows.
        \\
    );
    try writeSource(tmp.dir, "sa_plugins/sa_plugin_deno/deno.sai",
        \\@extern sa_deno_plugin_hostname(&out_ptr: ptr, &out_len: ptr) -> u32
        \\
    );
    try writeSource(tmp.dir, "sa_plugins/sa_plugin_deno/deno.sal",
        \\[MACRO] DENO_HOSTNAME %out_ptr, %out_len
        \\    %out_status = call @sa_deno_plugin_hostname(&%out_ptr, &%out_len)
        \\[END_MACRO]
        \\
    );
    try tmp.dir.createDirPath(std.testing.io, "sa_plugins/sa_plugin_3dengines");
    try writeSource(tmp.dir, "sa_plugins/sa_plugin_3dengines/README.md",
        \\Experimental 3D engine plugin should not be included in the common catalog.
        \\
    );

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        &.{"sars", "skills" },
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "generated agent skills:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, ".codex/skills/sa/SKILL.md"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, ".claude/skills/sa/SKILL.md"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, ".codex/skills/sa_plugins/SKILL.md"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, ".claude/skills/sa_plugins/SKILL.md"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "std surface:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "official plugin catalog:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "Rust-style string/vec/slice/option/result/core helper macros"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "optional deno/http/node/db/plugin APIs stay outside compiler std"));

    const codex_skill = try tmp.dir.readFileAlloc(std.testing.io, ".codex/skills/sa/SKILL.md", std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(codex_skill);
    const claude_skill = try tmp.dir.readFileAlloc(std.testing.io, ".claude/skills/sa/SKILL.md", std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(claude_skill);
    const codex_plugins_skill = try tmp.dir.readFileAlloc(std.testing.io, ".codex/skills/sa_plugins/SKILL.md", std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(codex_plugins_skill);
    const claude_plugins_skill = try tmp.dir.readFileAlloc(std.testing.io, ".claude/skills/sa_plugins/SKILL.md", std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(claude_plugins_skill);

    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "name: \"sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "# SA Toolchain"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "`sa build <file>`"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "`sa test <file> --list`"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "Treat the `sa_std Surface` section below as authoritative"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "## Std Coverage Guide"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "Core macro families include string, vec, slice"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "Rust-style fs coverage includes create_dir"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "Rust-style net coverage includes owned address handles"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "Rust's full std::future/std::task poll"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "## sa_std Surface"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "sa.mod"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "core/slice.sa: [MACRO] SLICE_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "fs.sa: [MACRO] FS_CREATE_DIR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "fs.sa: [MACRO] FS_READ_TO_STRING"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "fs.sa: [MACRO] FS_TRY_EXISTS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "net.sa: [MACRO] NET_TO_SOCKET_ADDR_FIRST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "env.sa: [MACRO] ENV_ARGS_JSON"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "process.sa: [MACRO] PROCESS_CHILD_ID"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "string.sa: [MACRO] STR_CHAR_COUNT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "string.sa: [MACRO] STR_TRY_CHAR_AT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "string.sa: [MACRO] STR_IS_UTF8"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "string.sai: @extern sa_str_utf8_char_at"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "string.sai: @extern sa_str_utf8_validate"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "ffi.sa: [MACRO] CSTR_TO_STR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "io.sa: [MACRO] IO_CURSOR_READ_TO_END"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "io.sa: [MACRO] IO_CURSOR_READ_TO_STRING"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "io.sa: [MACRO] IO_TAKE_READ_TO_END"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "io.sa: [MACRO] IO_TAKE_READ_TO_STRING"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "path.sa: [MACRO] PATH_TRY_FILE_PREFIX"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "path.sa: [MACRO] PATH_TRY_TO_STR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "mem.sa: [MACRO] MAYBE_UNINIT_U64_AS_BYTES"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "mem.sa: [MACRO] MANUALLY_DROP_U64_DEREF_MUT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "ptr.sa: [MACRO] PTR_NULL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "ptr.sa: [MACRO] PTR_EXPOSE_PROVENANCE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "ptr.sa: [MACRO] NONNULL_OFFSET_FROM_UNSIGNED_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "num.sa: [MACRO] NUM_U64_CHECKED_ADD"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "num.sa: [MACRO] NUM_U64_BIT_WIDTH"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "num.sa: [MACRO] NUM_I64_HIGHEST_ONE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "any.sa: [MACRO] ANY_REF_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "io.sai: @extern"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_skill, 1, "../sa_plugins/SKILL.md"));
    try std.testing.expect(std.mem.containsAtLeast(u8, claude_skill, 1, "Use the installed SA compiler"));
    try std.testing.expect(std.mem.containsAtLeast(u8, claude_skill, 1, "## CLI Skill Sections"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_plugins_skill, 1, "name: \"sa_plugins\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_plugins_skill, 1, "# SA Optional Plugins"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_plugins_skill, 1, "not proof that any plugin is installed"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_plugins_skill, 1, "sa plugin list"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_plugins_skill, 1, "deno (0.1.0)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_plugins_skill, 1, "Optional plugin: install before use"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_plugins_skill, 1, "deno/sa_plugin_deno/deno.sai: @extern sa_deno_plugin_hostname"));
    try std.testing.expect(std.mem.containsAtLeast(u8, codex_plugins_skill, 1, "deno/sa_plugin_deno/deno.sal: [MACRO] DENO_HOSTNAME"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, codex_plugins_skill, 1, "3dengines"));
    try std.testing.expect(std.mem.containsAtLeast(u8, claude_plugins_skill, 1, "Use the optional official SA plugin catalog"));
}

test "cli audit dispatches through runtime package plugin" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "pkg");
    try writeSource(tmp.dir, "pkg/index.sars",
        \\call @sys_print(*MSG, 2)
        \\
    );
    const pkg_root = try tmp.dir.realPathFileAlloc(std.testing.io, "pkg", std.testing.allocator);
    defer std.testing.allocator.free(pkg_root);

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const audit_argv = [_][]const u8{"sars", "audit", "--format", "json", pkg_root };
    const audit_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        audit_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), audit_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.startsWith(u8, stdout_buffer.items, "{\"package\":"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"trust_score\":50"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"capability\":\"io_write\""));
    try std.testing.expect(!std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "audit: "));
}

test "cli audit update-lock writes project lock through package flow" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "zig-out");
    try tmp.dir.createDirPath(std.testing.io, "pkg");
    try writeSource(tmp.dir, "pkg/index.sars",
        \\@main() -> i32:
        \\return 0
        \\
    );

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const audit_argv = [_][]const u8{"sars", "audit", "--update-lock", "--format", "json", "pkg" };
    const audit_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        audit_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), audit_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.startsWith(u8, stdout_buffer.items, "{\"package\":\"pkg\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"machine_code_sha256\":\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"created_entry\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"changed\":true"));

    const lock_source = try tmp.dir.readFileAlloc(std.testing.io, "sa.lock", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(lock_source);
    var lock_file = try saasm.pkg.manifest.parseLock(std.testing.allocator, lock_source);
    defer lock_file.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), lock_file.entries.len);
    try std.testing.expectEqualStrings("pkg", lock_file.entries[0].url);
    try std.testing.expectEqualStrings("HEAD", lock_file.entries[0].ref);
    try std.testing.expectEqual(@as(usize, 1), lock_file.entries[0].approved_machine_code_hashes.count());

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();
    const second_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        audit_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), second_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"created_entry\":false"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"changed\":false"));
}

test "cli init creates a binary project and install syncs manifest dependencies" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const init_argv = [_][]const u8{"sars", "init", "app" };
    const init_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        init_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), init_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "Initialized SA binary project: app"));
    try tmp.dir.access(std.testing.io, "app/sa.mod", .{ .read = true });
    try tmp.dir.access(std.testing.io, "app/src/main.sars", .{ .read = true });
    try tmp.dir.access(std.testing.io, "app/.gitignore", .{ .read = true });

    var app_dir = try tmp.dir.openDir(std.testing.io, "app", .{});
    defer app_dir.close();
    try app_dir.setAsCwd();
    const run_argv = [_][]const u8{"sars", "run", "src/main.sars" };
    const run_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        run_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), run_code);

    try original_cwd.setAsCwd();
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    try tmp.dir.createDirPath(std.testing.io, "app/deps/example/pkg");
    try writeSource(tmp.dir, "app/deps/example/pkg/index.sars",
        \\@pkg_value() -> i32:
        \\return 42
    );
    const pkg_root = try tmp.dir.realPathFileAlloc(std.testing.io, "app/deps/example/pkg", std.testing.allocator);
    defer std.testing.allocator.free(pkg_root);
    var pkg_report = try saasm.pkg.audit.auditPackage(std.testing.allocator, "deps/example/pkg", "HEAD", pkg_root, &.{});
    defer pkg_report.deinit(std.testing.allocator);
    const pkg_hash_hex = std.fmt.bytesToHex(pkg_report.source_sha256, .lower);
    const manifest_source = try std.fmt.allocPrint(
        std.testing.allocator,
        "require deps/example/pkg @HEAD sha256:{s}\n",
        .{pkg_hash_hex[0..]},
    );
    defer std.testing.allocator.free(manifest_source);
    try writeSource(tmp.dir, "app/sa.mod", manifest_source);
    try app_dir.setAsCwd();
    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();
    const install_argv = [_][]const u8{"sars", "install" };
    const install_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        install_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), install_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(try containsPortablePath(std.testing.allocator, stdout_buffer.items, "sa_vendor/deps/example/pkg"));
    try tmp.dir.access(std.testing.io, "app/sa_vendor/deps/example/pkg/index.sars", .{ .read = true });
    try tmp.dir.access(std.testing.io, "app/sa.sum", .{ .read = true });
}

test "workspace install aggregates member manifests at root and pkg install falls back to builtin workspace flow" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try tmp.dir.createDirPath(std.testing.io, "members/app/src");
    try tmp.dir.createDirPath(std.testing.io, "members/tool/src");
    try tmp.dir.createDirPath(std.testing.io, "deps/example/shared");
    try tmp.dir.createDirPath(std.testing.io, "deps/example/app");
    try tmp.dir.createDirPath(std.testing.io, "deps/example/tool");

    try writeSource(tmp.dir, "members/app/src/main.sars",
        \\@main() -> i32:
        \\return 1
    );
    try writeSource(tmp.dir, "members/tool/src/main.sars",
        \\@main() -> i32:
        \\return 2
    );
    try writeSource(tmp.dir, "deps/example/shared/index.sars",
        \\@shared_value() -> i32:
        \\return 10
    );
    try writeSource(tmp.dir, "deps/example/app/index.sars",
        \\@app_value() -> i32:
        \\return 20
    );
    try writeSource(tmp.dir, "deps/example/tool/index.sars",
        \\@tool_value() -> i32:
        \\return 30
    );

    const shared_root = try tmp.dir.realPathFileAlloc(std.testing.io, "deps/example/shared", std.testing.allocator);
    defer std.testing.allocator.free(shared_root);
    const app_root = try tmp.dir.realPathFileAlloc(std.testing.io, "deps/example/app", std.testing.allocator);
    defer std.testing.allocator.free(app_root);
    const tool_root = try tmp.dir.realPathFileAlloc(std.testing.io, "deps/example/tool", std.testing.allocator);
    defer std.testing.allocator.free(tool_root);

    var shared_report = try saasm.pkg.audit.auditPackage(std.testing.allocator, "deps/example/shared", "HEAD", shared_root, &.{});
    defer shared_report.deinit(std.testing.allocator);
    var app_report = try saasm.pkg.audit.auditPackage(std.testing.allocator, "deps/example/app", "HEAD", app_root, &.{});
    defer app_report.deinit(std.testing.allocator);
    var tool_report = try saasm.pkg.audit.auditPackage(std.testing.allocator, "deps/example/tool", "HEAD", tool_root, &.{});
    defer tool_report.deinit(std.testing.allocator);

    const shared_hash = std.fmt.bytesToHex(shared_report.source_sha256, .lower);
    const app_hash = std.fmt.bytesToHex(app_report.source_sha256, .lower);
    const tool_hash = std.fmt.bytesToHex(tool_report.source_sha256, .lower);

    const root_manifest_source = try std.fmt.allocPrint(std.testing.allocator,
        \\workspace {{
        \\  members ["members/app", "members/tool"]
        \\  default_member "app"
        \\}}
        \\
        \\require deps/example/shared @HEAD sha256:{s}
    , .{shared_hash[0..]});
    defer std.testing.allocator.free(root_manifest_source);
    try writeSource(tmp.dir, "sa.mod", root_manifest_source);

    const app_manifest_source = try std.fmt.allocPrint(std.testing.allocator,
        \\package "app"
        \\
        \\require deps/example/shared @HEAD sha256:{s}
        \\require deps/example/app @HEAD sha256:{s}
    , .{ shared_hash[0..], app_hash[0..] });
    defer std.testing.allocator.free(app_manifest_source);
    try writeSource(tmp.dir, "members/app/sa.mod", app_manifest_source);

    const tool_manifest_source = try std.fmt.allocPrint(std.testing.allocator,
        \\package "tool"
        \\
        \\require deps/example/shared @HEAD sha256:{s}
        \\require deps/example/tool @HEAD sha256:{s}
    , .{ shared_hash[0..], tool_hash[0..] });
    defer std.testing.allocator.free(tool_manifest_source);
    try writeSource(tmp.dir, "members/tool/sa.mod", tool_manifest_source);

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const install_argv = [_][]const u8{"sars", "install" };
    const install_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        install_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), install_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(try containsPortablePath(std.testing.allocator, stdout_buffer.items, "sa_vendor/deps/example/shared"));
    try std.testing.expect(try containsPortablePath(std.testing.allocator, stdout_buffer.items, "sa_vendor/deps/example/app"));
    try std.testing.expect(try containsPortablePath(std.testing.allocator, stdout_buffer.items, "sa_vendor/deps/example/tool"));
    try tmp.dir.access(std.testing.io, "sa_vendor/deps/example/shared/index.sars", .{ .read = true });
    try tmp.dir.access(std.testing.io, "sa_vendor/deps/example/app/index.sars", .{ .read = true });
    try tmp.dir.access(std.testing.io, "sa_vendor/deps/example/tool/index.sars", .{ .read = true });
    try tmp.dir.access(std.testing.io, "sa.sum", .{ .read = true });

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();
    const pkg_install_argv = [_][]const u8{"sars", "pkg", "install", "-p", "tool" };
    const pkg_install_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        pkg_install_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), pkg_install_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(try containsPortablePath(std.testing.allocator, stdout_buffer.items, "sa_vendor/deps/example/tool"));
}

test "package preflight rejects tampered project sum as structured trap" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try tmp.dir.createDirPath(std.testing.io, "app/src");
    try tmp.dir.createDirPath(std.testing.io, "app/deps/example/pkg");
    try writeSource(tmp.dir, "app/src/main.sars",
        \\@main() -> i32:
        \\return 0
    );
    try writeSource(tmp.dir, "app/deps/example/pkg/index.sars",
        \\@pkg_value() -> i32:
        \\return 42
    );

    const pkg_root = try tmp.dir.realPathFileAlloc(std.testing.io, "app/deps/example/pkg", std.testing.allocator);
    defer std.testing.allocator.free(pkg_root);
    var pkg_report = try saasm.pkg.audit.auditPackage(std.testing.allocator, "deps/example/pkg", "HEAD", pkg_root, &.{});
    defer pkg_report.deinit(std.testing.allocator);
    const pkg_hash_hex = std.fmt.bytesToHex(pkg_report.source_sha256, .lower);
    const manifest_source = try std.fmt.allocPrint(
        std.testing.allocator,
        "require deps/example/pkg @HEAD sha256:{s}\n",
        .{pkg_hash_hex[0..]},
    );
    defer std.testing.allocator.free(manifest_source);
    try writeSource(tmp.dir, "app/sa.mod", manifest_source);

    var app_dir = try tmp.dir.openDir(std.testing.io, "app", .{});
    defer app_dir.close();
    try app_dir.setAsCwd();

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const install_argv = [_][]const u8{"sars", "install" };
    const install_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        install_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), install_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    const bad_sum =
        \\deps/example/pkg @HEAD sha256:0000000000000000000000000000000000000000000000000000000000000000
        \\
    ;
    try writeSource(std.Io.Dir.cwd(), "sa.sum", bad_sum);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();
    const run_argv = [_][]const u8{"sars", "run", "src/main.sars", "--json" };
    const run_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        run_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 1), run_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"trap\":\"SumHashMismatch\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"status\":\"error\""));
}

test "PkgMgr-Confirm-NonTty rejects risky package preflight before build output" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try tmp.dir.createDirPath(std.testing.io, "app/src");
    try tmp.dir.createDirPath(std.testing.io, "app/sa_vendor/risky/pkg");
    try writeSource(tmp.dir, "app/src/main.sars",
        \\@main() -> i32:
        \\return 0
    );
    try writeSource(tmp.dir, "app/sa_vendor/risky/pkg/index.sars",
        \\call @sys_net_tx(*BUF, 4)
        \\
    );
    const pkg_root = try tmp.dir.realPathFileAlloc(std.testing.io, "app/sa_vendor/risky/pkg", std.testing.allocator);
    defer std.testing.allocator.free(pkg_root);
    try writeManifestForPackage(tmp.dir, "app", "risky/pkg", pkg_root, "");
    try writeProjectSum(tmp.dir, "app");

    var app_dir = try tmp.dir.openDir(std.testing.io, "app", .{});
    defer app_dir.close();
    try app_dir.setAsCwd();

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    var input = std.io.fixedBufferStream("");
    const build_argv = [_][]const u8{"sars", "build-exe", "src/main.sars", "-o", "blocked.out", "--json" };
    const code = try saasm.cli.executeWithWritersAndOptions(
        std.testing.allocator,
        build_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
        .{ .stdin_reader = input.reader().any(), .stdin_is_tty = false },
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"trap\":\"MissingTtyForConfirmation\""));
    try std.testing.expectError(error.FileNotFound, sio.cwd().access("blocked.out", .{ .read = true }));
}

test "PkgMgr-Confirm-Tty accepts exact URL through compile preflight" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try tmp.dir.createDirPath(std.testing.io, "app/src");
    try tmp.dir.createDirPath(std.testing.io, "app/sa_vendor/risky/pkg");
    try writeSource(tmp.dir, "app/src/main.sars",
        \\@main() -> i32:
        \\return 0
    );
    try writeSource(tmp.dir, "app/sa_vendor/risky/pkg/index.sars",
        \\call @sys_net_tx(*BUF, 4)
        \\
    );
    const pkg_root = try tmp.dir.realPathFileAlloc(std.testing.io, "app/sa_vendor/risky/pkg", std.testing.allocator);
    defer std.testing.allocator.free(pkg_root);
    try writeManifestForPackage(tmp.dir, "app", "risky/pkg", pkg_root, "");
    try writeProjectSum(tmp.dir, "app");

    var app_dir = try tmp.dir.openDir(std.testing.io, "app", .{});
    defer app_dir.close();
    try app_dir.setAsCwd();

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    var input = std.io.fixedBufferStream("risky/pkg\n");
    const run_argv = [_][]const u8{"sars", "run", "src/main.sars" };
    const code = try saasm.cli.executeWithWritersAndOptions(
        std.testing.allocator,
        run_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
        .{ .stdin_reader = input.reader().any(), .stdin_is_tty = true },
    );
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "SA ZERO-TRUST PACKAGE REVIEW REQUIRED"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "type the exact package URL to continue: risky/pkg"));
}

test "PkgMgr-CI-DualTrack rejects mismatched source and unauthorized primitives" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try tmp.dir.createDirPath(std.testing.io, "app/src");
    try tmp.dir.createDirPath(std.testing.io, "app/sa_vendor/ci/pkg");
    try writeSource(tmp.dir, "app/src/main.sars",
        \\@main() -> i32:
        \\return 0
    );
    try writeSource(tmp.dir, "app/sa_vendor/ci/pkg/index.sars",
        \\call @sys_net_tx(*BUF, 4)
        \\
    );
    const pkg_root = try tmp.dir.realPathFileAlloc(std.testing.io, "app/sa_vendor/ci/pkg", std.testing.allocator);
    defer std.testing.allocator.free(pkg_root);

    const bad_manifest =
        \\require ci/pkg @HEAD sha256:0000000000000000000000000000000000000000000000000000000000000000
        \\
    ;
    try writeSource(tmp.dir, "app/sa.mod", bad_manifest);

    var app_dir = try tmp.dir.openDir(std.testing.io, "app", .{});
    defer app_dir.close();
    try app_dir.setAsCwd();

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const run_ci_argv = [_][]const u8{"sars", "run", "src/main.sars", "--ci", "--json" };
    var code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        run_ci_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"trap\":\"UpstreamShaMismatch\""));

    try original_cwd.setAsCwd();
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    try writeManifestForPackage(tmp.dir, "app", "ci/pkg", pkg_root, "");
    try app_dir.setAsCwd();

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();
    code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        run_ci_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"trap\":\"UnauthorizedPrimitive\""));
}

test "PkgMgr-Offline-Build uses vendored sources and project sum" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try tmp.dir.createDirPath(std.testing.io, "app/src");
    try tmp.dir.createDirPath(std.testing.io, "app/sa_vendor/safe/pkg");
    try writeSource(tmp.dir, "app/src/main.sars",
        \\@main() -> i32:
        \\return 0
    );
    try writeSource(tmp.dir, "app/sa_vendor/safe/pkg/index.sars",
        \\@pkg_value() -> i32:
        \\return 42
    );
    const pkg_root = try tmp.dir.realPathFileAlloc(std.testing.io, "app/sa_vendor/safe/pkg", std.testing.allocator);
    defer std.testing.allocator.free(pkg_root);
    try writeManifestForPackage(tmp.dir, "app", "safe/pkg", pkg_root, "");
    try writeProjectSum(tmp.dir, "app");

    var app_dir = try tmp.dir.openDir(std.testing.io, "app", .{});
    defer app_dir.close();
    try app_dir.setAsCwd();

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const run_argv = [_][]const u8{"sars", "run", "src/main.sars", "--offline" };
    const code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        run_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
}

test "build and run json diagnostics emit structured success metrics on stderr" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, "json_success.sars",
        \\@main() -> i32:
        \\return 7
    );

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const run_argv = [_][]const u8{"sars", "run", "json_success.sars", "--json" };
    const run_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        run_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 7), run_code);
    try std.testing.expectEqualStrings("{\"status\":\"ok\",\"metrics\":{\"compile_tokens\":5,\"instruction_count\":2}}\n", stderr_buffer.items);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "json_success.sars", "-o", "json_success.out", "--json" };
    const build_exe_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        build_exe_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), build_exe_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"status\":\"ok\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "\"compile_tokens\":5"));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const build_mem_argv = [_][]const u8{"sars", "build-exe", "json_success.sars", "-o", "json_success_mem.out", "--json", "--mem-report", "--no-incremental" };
    const build_mem_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        build_mem_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), build_mem_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
    var mem_json = try parseJsonValue(std.testing.allocator, stderr_buffer.items);
    defer mem_json.deinit();
    const mem_metrics = try jsonObjectGet(&mem_json, "metrics");
    const memory = try jsonObjectGetValue(mem_metrics, "memory");
    const rss = try jsonObjectGetValue(memory, "rss_bytes");
    _ = try jsonObjectGetValue(rss, "start");
    _ = try jsonObjectGetValue(rss, "after_load");
    _ = try jsonObjectGetValue(rss, "after_setup");
    _ = try jsonObjectGetValue(rss, "after_flatten");
    _ = try jsonObjectGetValue(rss, "after_verify");
    _ = try jsonObjectGetValue(rss, "after_emit");
    _ = try jsonObjectGetValue(rss, "after_link");
    _ = try jsonObjectGetValue(rss, "end");
    const verifier_rss = try jsonObjectGetValue(memory, "verifier_rss_bytes");
    _ = try jsonObjectGetValue(verifier_rss, "start");
    _ = try jsonObjectGetValue(verifier_rss, "after_classify");
    _ = try jsonObjectGetValue(verifier_rss, "after_metadata");
    _ = try jsonObjectGetValue(verifier_rss, "after_chunks");
    _ = try jsonObjectGetValue(verifier_rss, "after_finalize");
    _ = try jsonObjectGetValue(memory, "peak_rss_bytes");

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const build_mem_text_argv = [_][]const u8{"sars", "build-exe", "json_success.sars", "-o", "json_success_mem_text.out", "--mem-report", "--no-incremental" };
    const build_mem_text_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        build_mem_text_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), build_mem_text_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "memory stage start"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "memory stage verifier.after_classify"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "memory report (RSS)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "after_flatten"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "peak"));
}

test "graph and size cli emit structured reports for a tiny project" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try tmp.dir.createDirPath(std.testing.io, "src");
    try writeSource(tmp.dir, "src/main.sars",
        \\@helper(value: i32) -> i32:
        \\    return value
        \\@main() -> i32:
        \\    value = call @helper(7)
        \\    return value
    );

    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const graph_argv = [_][]const u8{"sars", "graph", "--json" };
    const graph_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        graph_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), graph_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    const graph_parsed = try parseJsonValue(std.testing.allocator, stdout_buffer.items);
    defer graph_parsed.deinit();
    const graph_root = try jsonObjectGet(&graph_parsed, "graph");

    const graph_value = switch (graph_root) {
        .object => |object| object,
        else => return error.TestUnexpectedResult,
    };
    const nodes_value = graph_value.get("nodes") orelse return error.TestUnexpectedResult;
    const edges_value = graph_value.get("edges") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), try jsonArrayCount(nodes_value));
    try std.testing.expectEqual(@as(usize, 1), try jsonArrayCount(edges_value));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"kind\":\"source_file\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"kind\":\"function\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"kind\":\"calls\""));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const size_argv = [_][]const u8{"sars", "size", "--json" };
    const size_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        size_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), size_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);

    const size_parsed = try parseJsonValue(std.testing.allocator, stdout_buffer.items);
    defer size_parsed.deinit();
    const size_graph = try jsonObjectGet(&size_parsed, "functions");
    try std.testing.expectEqual(@as(usize, 2), try jsonArrayCount(size_graph));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"name\":\"helper\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"name\":\"main\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"instruction_count\":"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"byte_count\":"));
}

test "llvmc backend compilation and verification on rosetta demos" {
    try assertBuildExeStdoutPureBc("demos/rosetta/01_hello_world/main.sars", "hello, saasm\n");
    try assertBuildExeStdoutPureBc("demos/rosetta/04_loop/main.sars", "[0,0,0,0]\n");
    try assertBuildExeStdout("demos/rosetta/21_while_loop/main.sars", "15\n");
}

test "agent capability: check verdict cache and affected help" {
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const help_argv = [_][]const u8{ "sars", "--help" };
    const help_code = try saasm.cli.executeWithWriters(std.testing.allocator, help_argv[0..], sio.managedWriter(&stdout_buffer), sio.managedWriter(&stderr_buffer));
    try std.testing.expectEqual(@as(u8, 0), help_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "check"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "daemon"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "--affected"));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    // In-process check hit: same process reuses verdict cache.
    const check1 = [_][]const u8{"sars", "check", "tests/agent_fixtures/check_ok.sars", "--json" };
    const c1 = try saasm.cli.executeWithWriters(std.testing.allocator, check1[0..], sio.managedWriter(&stdout_buffer), sio.managedWriter(&stderr_buffer));
    try std.testing.expectEqual(@as(u8, 0), c1);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"hit\":false") or std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"status\":\"ok\""));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();
    const c2 = try saasm.cli.executeWithWriters(std.testing.allocator, check1[0..], sio.managedWriter(&stdout_buffer), sio.managedWriter(&stderr_buffer));
    try std.testing.expectEqual(@as(u8, 0), c2);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "\"hit\":true"));

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();
    const test_help = [_][]const u8{"sars", "test", "--help" };
    const th = try saasm.cli.executeWithWriters(std.testing.allocator, test_help[0..], sio.managedWriter(&stdout_buffer), sio.managedWriter(&stderr_buffer));
    try std.testing.expectEqual(@as(u8, 0), th);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "--affected"));
}

test "agent capability: affected selects impacted tests" {
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    // First run establishes baseline (no prior function hashes in this process).
    const first = [_][]const u8{"sars", "test", "tests/agent_fixtures/affected_graph.sars", "--affected" };
    const code1 = try saasm.cli.executeWithWriters(std.testing.allocator, first[0..], sio.managedWriter(&stdout_buffer), sio.managedWriter(&stderr_buffer));
    try std.testing.expectEqual(@as(u8, 0), code1);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "affected:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "baseline=no") or std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "selected_tests"));

    // Second identical run: source-pass-cache or no impacted tests.
    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();
    const code2 = try saasm.cli.executeWithWriters(std.testing.allocator, first[0..], sio.managedWriter(&stdout_buffer), sio.managedWriter(&stderr_buffer));
    try std.testing.expectEqual(@as(u8, 0), code2);
    try std.testing.expect(
        std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "skipped") or
            std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "selected_tests=0"),
    );
}

test "sab with corrupted param_ids traps CorruptedSignature without panic or text fallback" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    // The program needs a function with parameters so param_ids is populated
    // in the encoded SAB.
    const sa_source =
        \\@add2(a: u64, b: u64) -> u64:
        \\L_ENTRY:
        \\    c = add a, b
        \\    return c
        \\@main() -> i32:
        \\L_MAIN:
        \\    call @add2(20, 22)
        \\    return 0
    ;
    try writeSource(tmp.dir, "params.sars", sa_source);

    // Produce a valid SAB through the real `check --emit-sab` CLI path.
    // NOTE: use executeWithWriters (not execute): execute writes to the real
    // process stdout, which corrupts the `zig build` --listen test protocol
    // and hangs the run.
    const emit_argv = [_][]const u8{"sars", "check", "params.sars", "--emit-sab", "params.sab" };
    var emit_stdout = std.array_list.Managed(u8).init(std.testing.allocator);
    defer emit_stdout.deinit();
    var emit_stderr = std.array_list.Managed(u8).init(std.testing.allocator);
    defer emit_stderr.deinit();
    const emit_code = try saasm.cli.executeWithWriters(std.testing.allocator, emit_argv[0..], sio.managedWriter(&emit_stdout), sio.managedWriter(&emit_stderr));
    try std.testing.expectEqual(@as(u8, 0), emit_code);

    const sab_file = try tmp.dir.openFile(std.testing.io, "params.sab", .{});
    const sab_bytes = try sio.readToEndAlloc(sab_file, std.testing.allocator, 1 << 20);
    sab_file.close(std.testing.io);
    defer std.testing.allocator.free(sab_bytes);
    try std.testing.expect(sab_bytes.len > 0);

    // Sanity: the encoded @add2 signature really carries params/param_ids.
    {
        var module = try saasm.sab.decodeModule(std.testing.allocator, sab_bytes);
        defer module.deinit(std.testing.allocator);
        const sig = for (module.function_sigs) |*fsig| {
            if (std.mem.eql(u8, fsig.name, "add2")) break fsig;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 2), sig.params.len);
        try std.testing.expectEqual(@as(usize, 2), sig.param_ids.len);
    }

    // Corrupt param_ids through decode/mutate/re-encode. The corrupted file
    // stays a structurally valid SAB (magic and complete sections intact), so
    // the failure must surface as a verifier trap -- never a decode error and
    // never a silent text fallback. Before the fix, the bad param_id hit
    // `orelse unreachable` (panic) and the short param_ids indexed OOB.
    //
    // Each case runs the real CLI (`sa check <file>.sab`) and asserts:
    //   - explicit non-zero exit (1),
    //   - stderr names the CorruptedSignature trap with numeric code 1058
    //     and the "corrupted function signature" message,
    //   - stderr never contains "panic".
    const Case = enum { bad_reg_id, short_param_ids };
    for ([_]Case{ .bad_reg_id, .short_param_ids }) |case| {
        const bad_name = switch (case) {
            .bad_reg_id => "bad_param_id.sab",
            .short_param_ids => "short_param_ids.sab",
        };
        {
            var module = try saasm.sab.decodeModule(std.testing.allocator, sab_bytes);
            defer module.deinit(std.testing.allocator);
            const sig = for (module.function_sigs) |*fsig| {
                if (std.mem.eql(u8, fsig.name, "add2")) break fsig;
            } else return error.TestUnexpectedResult;
            switch (case) {
                .bad_reg_id => {
                    // param_id references a register id not declared in this
                    // function scope.
                    try std.testing.expectEqual(@as(usize, 2), sig.param_ids.len);
                    const mutable_ids: []u32 = @constCast(sig.param_ids);
                    mutable_ids[0] = std.math.maxInt(u32);
                },
                .short_param_ids => {
                    // param_ids shorter than params.
                    try std.testing.expect(sig.params.len == 2);
                    std.testing.allocator.free(sig.param_ids);
                    sig.param_ids = &.{};
                },
            }
            const bad_bytes = try saasm.sab.encodeProgramWithConsts(
                std.testing.allocator,
                module.symbols,
                module.const_decls,
                module.function_sigs,
                module.instructions,
            );
            defer std.testing.allocator.free(bad_bytes);
            try writeBytes(tmp.dir, bad_name, bad_bytes);
        }

        var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
        defer stdout_buffer.deinit();
        var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
        defer stderr_buffer.deinit();
        const argv = [_][]const u8{"sars", "check", bad_name };
        const code = try saasm.cli.executeWithWriters(std.testing.allocator, argv[0..], sio.managedWriter(&stdout_buffer), sio.managedWriter(&stderr_buffer));
        try std.testing.expectEqual(@as(u8, 1), code);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "CorruptedSignature") != null);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "corrupted function signature") != null);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "\"trap_code\":1058") != null);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "panic") == null);
    }
}

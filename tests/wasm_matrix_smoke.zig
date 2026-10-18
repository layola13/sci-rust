const std = @import("std");
const saasm = @import("saasm");
const builtin = @import("builtin");
const sio = @import("sio");

fn writeSource(dir: std.Io.Dir, path: []const u8, source: []const u8) !void {
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    var wbuf: [8192]u8 = undefined;
    var w = file.writer(std.testing.io, &wbuf);
    try w.interface.writeAll(source);
    try w.interface.flush();
}

fn runCommandAnyExit(allocator: std.mem.Allocator, argv: []const []const u8) !sio.Child.RunResult {
    return try sio.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
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

fn elapsedMs(start_ns: i128) i128 {
    return @divTrunc(sio.nanoTimestamp() - start_ns, std.time.ns_per_ms);
}

fn startTimedPhase(path: []const u8, phase: []const u8) i128 {
    std.debug.print("[wasm-matrix] START demo={s} phase={s}\n", .{ path, phase });
    return sio.nanoTimestamp();
}

fn endTimedPhase(path: []const u8, phase: []const u8, start_ns: i128) i128 {
    const elapsed = elapsedMs(start_ns);
    std.debug.print("[wasm-matrix] END   demo={s} phase={s} elapsed={}ms\n", .{ path, phase, elapsed });
    return elapsed;
}

const DemoTiming = struct {
    path: []const u8,
    native_checked: bool = false,
    demo_ms: i128 = 0,
    build_exe_ms: i128 = 0,
    native_run_ms: i128 = 0,
    build_wasm_ms: i128 = 0,
    wasm_run_ms: i128 = 0,
};

const WasmMatrixStats = struct {
    timings: std.array_list.Managed(DemoTiming),

    fn init(allocator: std.mem.Allocator) WasmMatrixStats {
        return .{ .timings = std.array_list.Managed(DemoTiming).init(allocator) };
    }

    fn deinit(self: *WasmMatrixStats) void {
        self.timings.deinit();
    }

    fn append(self: *WasmMatrixStats, timing: DemoTiming) !void {
        try self.timings.append(timing);
    }

    fn phaseName(index: usize) []const u8 {
        return switch (index) {
            0 => "build-exe",
            1 => "native-run",
            2 => "build-wasm",
            3 => "wasm-run",
            else => "unknown",
        };
    }

    fn phaseMs(timing: DemoTiming, index: usize) i128 {
        return switch (index) {
            0 => timing.build_exe_ms,
            1 => timing.native_run_ms,
            2 => timing.build_wasm_ms,
            3 => timing.wasm_run_ms,
            else => 0,
        };
    }

    fn hasSelectedIndex(selected: []const usize, index: usize) bool {
        for (selected) |item| {
            if (item == index) return true;
        }
        return false;
    }

    fn hasSelectedPhase(selected_demo: []const usize, selected_phase: []const usize, demo_index: usize, phase_index: usize) bool {
        for (selected_demo, selected_phase) |demo, phase| {
            if (demo == demo_index and phase == phase_index) return true;
        }
        return false;
    }

    fn printSummary(self: *const WasmMatrixStats) void {
        var total_demo_ms: i128 = 0;
        var total_build_exe_ms: i128 = 0;
        var total_native_run_ms: i128 = 0;
        var total_build_wasm_ms: i128 = 0;
        var total_wasm_run_ms: i128 = 0;
        var native_checked: usize = 0;
        for (self.timings.items) |timing| {
            if (timing.native_checked) native_checked += 1;
            total_demo_ms += timing.demo_ms;
            total_build_exe_ms += timing.build_exe_ms;
            total_native_run_ms += timing.native_run_ms;
            total_build_wasm_ms += timing.build_wasm_ms;
            total_wasm_run_ms += timing.wasm_run_ms;
        }

        std.debug.print(
            "[wasm-matrix] SUMMARY demos={} native_checked={} total_demo_ms={} build_exe_ms={} native_run_ms={} build_wasm_ms={} wasm_run_ms={}\n",
            .{ self.timings.items.len, native_checked, total_demo_ms, total_build_exe_ms, total_native_run_ms, total_build_wasm_ms, total_wasm_run_ms },
        );
        self.printSlowestDemos();
        self.printSlowestPhases();
    }

    fn printSlowestDemos(self: *const WasmMatrixStats) void {
        const limit = 10;
        var selected: [limit]usize = @splat(std.math.maxInt(usize));
        var printed: usize = 0;
        std.debug.print("[wasm-matrix] SUMMARY slowest_demos:\n", .{});
        while (printed < limit and printed < self.timings.items.len) : (printed += 1) {
            var best_index: ?usize = null;
            var best_ms: i128 = -1;
            for (self.timings.items, 0..) |timing, index| {
                if (hasSelectedIndex(selected[0..printed], index)) continue;
                if (timing.demo_ms > best_ms) {
                    best_ms = timing.demo_ms;
                    best_index = index;
                }
            }
            const index = best_index orelse break;
            selected[printed] = index;
            const timing = self.timings.items[index];
            std.debug.print(
                "[wasm-matrix] SUMMARY demo_rank={} elapsed={}ms native_checked={} build_exe={}ms native_run={}ms build_wasm={}ms wasm_run={}ms path={s}\n",
                .{ printed + 1, timing.demo_ms, timing.native_checked, timing.build_exe_ms, timing.native_run_ms, timing.build_wasm_ms, timing.wasm_run_ms, timing.path },
            );
        }
    }

    fn printSlowestPhases(self: *const WasmMatrixStats) void {
        const limit = 10;
        const phase_count = 4;
        var selected_demo: [limit]usize = @splat(std.math.maxInt(usize));
        var selected_phase: [limit]usize = @splat(std.math.maxInt(usize));
        var printed: usize = 0;
        std.debug.print("[wasm-matrix] SUMMARY slowest_phases:\n", .{});
        while (printed < limit and printed < self.timings.items.len * phase_count) : (printed += 1) {
            var best_demo_index: ?usize = null;
            var best_phase_index: usize = 0;
            var best_ms: i128 = -1;
            for (self.timings.items, 0..) |timing, demo_index| {
                for (0..phase_count) |phase_index| {
                    if (hasSelectedPhase(selected_demo[0..printed], selected_phase[0..printed], demo_index, phase_index)) continue;
                    const candidate_ms = phaseMs(timing, phase_index);
                    if (candidate_ms > best_ms) {
                        best_ms = candidate_ms;
                        best_demo_index = demo_index;
                        best_phase_index = phase_index;
                    }
                }
            }
            const demo_index = best_demo_index orelse break;
            selected_demo[printed] = demo_index;
            selected_phase[printed] = best_phase_index;
            const timing = self.timings.items[demo_index];
            std.debug.print(
                "[wasm-matrix] SUMMARY phase_rank={} elapsed={}ms phase={s} path={s}\n",
                .{ printed + 1, best_ms, phaseName(best_phase_index), timing.path },
            );
        }
    }
};

fn boolEnv(name: []const u8) bool {
    const value = sio.getEnvVarOwned(std.testing.allocator, name) catch return false;
    defer std.testing.allocator.free(value);
    return value.len != 0 and
        !std.mem.eql(u8, value, "0") and
        !std.mem.eql(u8, value, "false") and
        !std.mem.eql(u8, value, "False");
}

fn shouldRunNativeReference(path: []const u8) bool {
    if (boolEnv("SA_WASM_MATRIX_NATIVE_ALL")) return true;

    const native_sanity_paths = [_][]const u8{
        "demos/rosetta/01_hello_world/main.sars",
        "demos/rosetta/10_generics_monomorph/main.sars",
        "demos/rosetta/41_module_imports/main.sars",
        "demos/rosetta/19_result_question/main.sars",
        "demos/rosetta/32_trait_object_vector/main.sars",
        "demos/support/hashmap_probe.sars",
    };
    for (native_sanity_paths) |sanity_path| {
        if (std.mem.eql(u8, path, sanity_path)) return true;
    }
    return false;
}

fn artifactStem(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const base = std.fs.path.basename(path);
    const stem = std.fs.path.stem(base);
    if (!std.mem.eql(u8, stem, "main")) return try allocator.dupe(u8, stem);
    const parent = std.fs.path.dirname(path) orelse return try allocator.dupe(u8, stem);
    return try allocator.dupe(u8, std.fs.path.basename(parent));
}

var matrix_seq: usize = 0;

/// Shard selector for long demo matrices: SA_WASM_MATRIX_SHARD="i/n" runs
/// only demos whose sequence number satisfies seq % n == i (0-based).
/// Absent or malformed values run every demo (default behavior unchanged).
fn matrixShardSelected() bool {
    const seq = matrix_seq;
    matrix_seq += 1;
    const value = sio.getEnvVarOwned(std.testing.allocator, "SA_WASM_MATRIX_SHARD") catch return true;
    defer std.testing.allocator.free(value);
    var parts = std.mem.splitScalar(u8, value, '/');
    const i_text = parts.next() orelse return true;
    const n_text = parts.next() orelse return true;
    const i = std.fmt.parseUnsigned(usize, i_text, 10) catch return true;
    const n = std.fmt.parseUnsigned(usize, n_text, 10) catch return true;
    if (n == 0 or i >= n) return true;
    return seq % n == i;
}

fn assertWasmMatrixStdout(stats: *WasmMatrixStats, path: []const u8, expected_stdout: []const u8) !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (!matrixShardSelected()) {
        std.debug.print("[wasm-matrix] SKIP  demo={s} reason=shard\n", .{path});
        return;
    }
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
    const repo_root = try original_cwd.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(repo_root);
    const source_path = try original_cwd.realpathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(source_path);

    var timing = DemoTiming{ .path = path };
    const demo_start = startTimedPhase(path, "demo");
    var demo_ended = false;
    errdefer {
        if (!demo_ended) _ = endTimedPhase(path, "demo", demo_start);
    }

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const stem = try artifactStem(std.testing.allocator, path);
    defer std.testing.allocator.free(stem);
    const exe_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.out", .{stem});
    defer std.testing.allocator.free(exe_path);
    const wasm_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.wasm", .{stem});
    defer std.testing.allocator.free(wasm_path);

    if (shouldRunNativeReference(path)) {
        timing.native_checked = true;
        const build_exe_argv = [_][]const u8{"sars", "build-exe", source_path, "-o", exe_path, "--project-root", repo_root };
        {
            const phase_start = startTimedPhase(path, "build-exe");
            var phase_ended = false;
            errdefer {
                if (!phase_ended) _ = endTimedPhase(path, "build-exe", phase_start);
            }
            const build_exe_code = saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]) catch |err| {
                std.debug.print("build-exe errored: {s}: {s}\n", .{ path, @errorName(err) });
                return err;
            };
            if (build_exe_code != 0) std.debug.print("build-exe failed: {s}\n", .{path});
            try std.testing.expectEqual(@as(u8, 0), build_exe_code);
            timing.build_exe_ms = endTimedPhase(path, "build-exe", phase_start);
            phase_ended = true;
        }

        const exe_run_path = try std.fmt.allocPrint(std.testing.allocator, "./{s}", .{exe_path});
        defer std.testing.allocator.free(exe_run_path);
        {
            const phase_start = startTimedPhase(path, "native-run");
            var phase_ended = false;
            errdefer {
                if (!phase_ended) _ = endTimedPhase(path, "native-run", phase_start);
            }
            const exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{exe_run_path});
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
            timing.native_run_ms = endTimedPhase(path, "native-run", phase_start);
            phase_ended = true;
        }
    } else {
        std.debug.print("[wasm-matrix] SKIP  demo={s} phase=build-exe reason=wasm-fast-default\n", .{path});
        std.debug.print("[wasm-matrix] SKIP  demo={s} phase=native-run reason=wasm-fast-default\n", .{path});
    }

    const build_wasm_argv = [_][]const u8{"sars", "build-wasm", source_path, "-o", wasm_path, "--target", "wasm32", "--project-root", repo_root };
    {
        const phase_start = startTimedPhase(path, "build-wasm");
        var phase_ended = false;
        errdefer {
            if (!phase_ended) _ = endTimedPhase(path, "build-wasm", phase_start);
        }
        const build_wasm_code = saasm.cli.execute(std.testing.allocator, build_wasm_argv[0..]) catch |err| {
            std.debug.print("build-wasm errored: {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        if (build_wasm_code != 0) std.debug.print("build-wasm failed: {s}\n", .{path});
        try std.testing.expectEqual(@as(u8, 0), build_wasm_code);
        timing.build_wasm_ms = endTimedPhase(path, "build-wasm", phase_start);
        phase_ended = true;
    }

    const bc_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.sa.bc", .{wasm_path});
    defer std.testing.allocator.free(bc_path);
    const bc_file = try tmp.dir.openFile(std.testing.io, bc_path, .{});
    defer bc_file.close(std.testing.io);
    var bc_rbuf: [8192]u8 = undefined;
    var bc_reader = bc_file.readerStreaming(std.testing.io, &bc_rbuf);
    const bc_bytes = try bc_reader.interface.allocRemaining(std.testing.allocator, .limited(4 << 20));
    defer std.testing.allocator.free(bc_bytes);
    try std.testing.expect(bc_bytes.len > 0);

    const wasm_file = try tmp.dir.openFile(std.testing.io, wasm_path, .{});
    defer wasm_file.close(std.testing.io);
    var wasm_rbuf: [8192]u8 = undefined;
    var wasm_reader = wasm_file.readerStreaming(std.testing.io, &wasm_rbuf);
    const wasm_bytes = try wasm_reader.interface.allocRemaining(std.testing.allocator, .limited(16 << 20));
    defer std.testing.allocator.free(wasm_bytes);
    try std.testing.expect(wasm_bytes.len > 8);
    try std.testing.expectEqualSlices(u8, &std.wasm.magic, wasm_bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &std.wasm.version, wasm_bytes[4..8]);

    {
        const phase_start = startTimedPhase(path, "wasm-run");
        var phase_ended = false;
        errdefer {
            if (!phase_ended) _ = endTimedPhase(path, "wasm-run", phase_start);
        }
        const wasm_result = try runWasmWithNode(std.testing.allocator, wasm_path, &.{ "sa", wasm_path });
        defer std.testing.allocator.free(wasm_result.stdout);
        defer std.testing.allocator.free(wasm_result.stderr);
        switch (wasm_result.term) {
            .exited => |code| {
                if (code != 0 or !std.mem.eql(u8, wasm_result.stdout, expected_stdout) or wasm_result.stderr.len != 0) {
                    std.debug.print("wasm demo failed: {s}\nstdout:\n{s}\nstderr:\n{s}\n", .{ path, wasm_result.stdout, wasm_result.stderr });
                }
                try std.testing.expectEqual(@as(u8, 0), code);
            },
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqualStrings(expected_stdout, wasm_result.stdout);
        try std.testing.expectEqual(@as(usize, 0), wasm_result.stderr.len);
        timing.wasm_run_ms = endTimedPhase(path, "wasm-run", phase_start);
        phase_ended = true;
    }
    timing.demo_ms = endTimedPhase(path, "demo", demo_start);
    demo_ended = true;
    try stats.append(timing);
}

test "llvmc wasm rosetta and support demos match expected output with native sanity subset" {
    // Requires the LLVM-C native backend (unavailable with -Dllvm=false).
    if (!saasm.build_options.llvm_enabled) return error.SkipZigTest;
    var stats = WasmMatrixStats.init(std.testing.allocator);
    defer stats.deinit();
    defer stats.printSummary();

    try assertWasmMatrixStdout(&stats, "demos/rosetta/01_hello_world/main.sars", "hello, saasm\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/02_mutability/main.sars", "20\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/03_if_else/main.sars", "20\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/04_loop/main.sars", "[0,0,0,0]\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/05_struct/main.sars", "(10,20)\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/06_enum_and_match/main.sars", "30\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/08_closures/main.sars", "15\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/09_async_await/main.sars", "2\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/10_generics_monomorph/main.sars", "42\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/11_tuples/main.sars", "(3, 4)\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/12_destructuring/main.sars", "7\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/13_array_sum/main.sars", "10\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/14_slice_window/main.sars", "5\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/15_string_bytes/main.sars", "4\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/16_methods/main.sars", "25\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/17_associated_fn/main.sars", "42\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/18_option_map/main.sars", "8\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/21_while_loop/main.sars", "15\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/20_boxed_value/main.sars", "9\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/22_break_continue/main.sars", "9\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/23_nested_loops/main.sars", "18\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/24_factorial/main.sars", "120\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/25_fibonacci/main.sars", "21\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/26_reference_return/main.sars", "9\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/27_move_semantics/main.sars", "11\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/28_borrow_chains/main.sars", "12\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/29_const_data/main.sars", "6\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/30_manual_guard_branch/main.sars", "5\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/31_trait_static_dispatch/main.sars", "16\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/33_iterator_map/main.sars", "12\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/34_iterator_filter/main.sars", "6\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/35_iterator_fold/main.sars", "7\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/36_tuple_struct/main.sars", "14\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/37_newtype/main.sars", "42\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/38_generic_struct_i32/main.sars", "31\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/39_generic_enum_i32/main.sars", "7\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/40_impl_block_state/main.sars", "15\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/41_module_imports/main.sars", "42\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/42_export_visibility/main.sars", "12\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/44_slice_iteration/main.sars", "10\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/45_config_merge/main.sars", "4 3\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/46_option_default/main.sars", "9\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/47_tuple_swap/main.sars", "8,3\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/48_generic_pair/main.sars", "11,31\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/49_pipeline_map/main.sars", "12\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/51_refcount/main.sars", "10\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/52_queue_rotate/main.sars", "2,3,1\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/43_tagged_union/main.sars", "36\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/53_cache_hits/main.sars", "3\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/54_mem_fill/main.sars", "7,7,7,7\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/55_builder_pattern/main.sars", "POST /api\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/56_state_machine/main.sars", "2\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/57_event_loop/main.sars", "6\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/58_borrow_update/main.sars", "10\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/59_method_counter/main.sars", "4\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/60_enum_branch/main.sars", "2\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/61_thread_pool/main.sars", "5\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/62_channel_pingpong/main.sars", "8\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/63_router_table/main.sars", "2\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/64_file_manifest/main.sars", "3\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/65_job_scheduler/main.sars", "10\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/66_actor_mailbox/main.sars", "6\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/67_resource_pool/main.sars", "20\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/68_parser_tokens/main.sars", "4\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/69_serializer/main.sars", "{\"id\":7}\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/70_integration_service/main.sars", "6\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/71_pipeline_stage/main.sars", "6\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/72_graph_walk/main.sars", "3\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/73_scene_nodes/main.sars", "15\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/74_component_store/main.sars", "2\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/75_async_bridge/main.sars", "5\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/76_lockfree_counter/main.sars", "3\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/77_http_route/main.sars", "/health\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/78_cli_args/main.sars", "2\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/79_metrics/main.sars", "4\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/80_workflow/main.sars", "10\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/81_kv_store/main.sars", "5\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/82_sql_scan/main.sars", "2\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/83_blob_chunk/main.sars", "4\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/84_sync_gate/main.sars", "1\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/85_scheduler_tree/main.sars", "6\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/86_cache_eviction/main.sars", "20\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/87_protocol_frame/main.sars", "3\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/88_text_index/main.sars", "3\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/89_job_queue/main.sars", "12\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/90_app_shell/main.sars", "app --mode demo\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/91_db_session/main.sars", "2\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/92_query_plan/main.sars", "10\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/93_log_aggregator/main.sars", "10\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/94_graphql_router/main.sars", "query user\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/95_repl_shell/main.sars", "sa> \n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/96_task_orchestrator/main.sars", "4\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/97_sync_service/main.sars", "1\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/98_build_pipeline/main.sars", "6\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/99_release_bundle/main.sars", "3\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/100_full_app/main.sars", "12\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/176_result_flattening/main.sars", "2\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/178_panic_hook_override/main.sars", "1\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/180_try_trait_v2/main.sars", "7\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/253_contract_callback_registration/main.sars", "253\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/19_result_question/main.sars", "21\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/50_error_chain/main.sars", "12\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/07_trait_vtable/main.sars", "77\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/110_trait_super_vtable/main.sars", "15\n");
    try assertWasmMatrixStdout(&stats, "demos/rosetta/32_trait_object_vector/main.sars", "12\n");
    try assertWasmMatrixStdout(&stats, "demos/support/sort_probe.sars", "sort ok\n");
    try assertWasmMatrixStdout(&stats, "demos/support/hashmap_probe.sars", "alpha\nbravo\nmap ok\n");
    try assertWasmMatrixStdout(&stats, "demos/support/hashset_probe.sars", "set ok\n");
    try assertWasmMatrixStdout(&stats, "demos/support/once_probe.sars", "once ok\n");
    try assertWasmMatrixStdout(&stats, "demos/support/mpsc_probe.sars", "mpsc ok\n");
}

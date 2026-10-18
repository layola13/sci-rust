const std = @import("std");
const builtin = @import("builtin");

const saasm = @import("saasm");
const sio = @import("sio");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;

fn expectContains(text: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, text, needle) != null);
}

fn expectNotContains(text: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, text, needle) == null);
}

/// Probe whether the host permits IPv6 multicast joins. Some containers
/// lack a multicast-capable interface (join returns ENODEV) while IPv4
/// multicast works; the v6-only macro surface suite is then skipped
/// instead of reporting environment incapability as product failure.
/// Precedent: udpSendtoPermitted / udpMulticastV6JoinPermitted in
/// tests/sa_std_runtime.zig (sci@71e02f12).
fn udpMulticastV6JoinPermitted() bool {
    if (builtin.os.tag != .linux) return false;
    const os = std.os.linux;
    const fd = os.socket(os.AF.INET6, os.SOCK.DGRAM, 0);
    if (@as(isize, @bitCast(fd)) < 0) return false;
    const sock: os.fd_t = @intCast(fd);
    defer _ = os.close(sock);
    var mreq = [_]u8{ 0xFF, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x14, 0, 0, 0, 0 };
    const rc = os.setsockopt(sock, 41, 20, &mreq, mreq.len);
    return rc == 0;
}

fn writeSource(dir: std.Io.Dir, path: []const u8, source: []const u8) !void {
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    var wbuf: [8192]u8 = undefined;
    var w = file.writer(std.testing.io, &wbuf);
    try w.interface.writeAll(source);
    try w.interface.flush();
}

fn setEnvVarZ(name: [:0]const u8, value: [:0]const u8) !void {
    const rc = if (builtin.os.tag == .windows)
        _putenv_s(name.ptr, value.ptr)
    else
        setenv(name.ptr, value.ptr, 1);
    if (rc != 0) return error.SetEnvFailed;
}

fn unsetEnvVarZ(name: [:0]const u8) void {
    if (builtin.os.tag == .windows) {
        _ = _putenv_s(name.ptr, "");
    } else {
        _ = unsetenv(name.ptr);
    }
}

fn saveEnvVarZ(allocator: std.mem.Allocator, name: []const u8) !?[:0]u8 {
    const value = sio.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    defer allocator.free(value);
    return try allocator.dupeSentinel(u8, value, 0);
}

fn restoreEnvVarZ(name: [:0]const u8, value: ?[:0]const u8) !void {
    if (value) |saved| {
        try setEnvVarZ(name, saved);
    } else {
        unsetEnvVarZ(name);
    }
}

fn saTestJobsArg(allocator: std.mem.Allocator) ![]const u8 {
    const env_names = [_][]const u8{ "SA_TEST_JOBS", "SA_ZIG_JOBS", "ZIG_BUILD_JOBS" };
    for (env_names) |name| {
        if (sio.getEnvVarOwned(allocator, name)) |value| {
            if (value.len != 0) return value;
            allocator.free(value);
        } else |_| {}
    }
    return allocator.dupe(u8, "auto");
}

fn saTestJobsArgForPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    _ = path;
    if (saUnitFileJobs() > 1 and !hasEnvVar(allocator, "SA_TEST_JOBS")) {
        return allocator.dupe(u8, "1");
    }
    return saTestJobsArg(allocator);
}

fn hasEnvVar(allocator: std.mem.Allocator, name: []const u8) bool {
    const value = sio.getEnvVarOwned(allocator, name) catch return false;
    allocator.free(value);
    return true;
}

fn parsePositiveUsize(text: []const u8) ?usize {
    if (text.len == 0 or std.mem.eql(u8, text, "auto")) return null;
    const parsed = std.fmt.parseUnsigned(usize, text, 10) catch return null;
    return if (parsed == 0) null else parsed;
}

fn saUnitFileJobs() usize {
    const value = sio.getEnvVarOwned(std.heap.page_allocator, "SA_UNIT_FILE_JOBS") catch return 1;
    defer std.heap.page_allocator.free(value);
    if (parsePositiveUsize(value)) |requested| {
        const cpu_count = std.Thread.getCpuCount() catch 1;
        return @min(requested, @max(cpu_count, @as(usize, 1)));
    }
    return 1;
}

fn saBinaryPath(allocator: std.mem.Allocator) ?[]u8 {
    const value = sio.getEnvVarOwned(allocator, "SA_BIN") catch return null;
    if (value.len == 0) {
        allocator.free(value);
        return null;
    }
    return value;
}

fn elapsedMs(start_ns: i128) i128 {
    return @divTrunc(sio.nanoTimestamp() - start_ns, std.time.ns_per_ms);
}

fn startSaFileLog(path: []const u8, mode: []const u8, jobs_arg: []const u8, index: usize, total: usize) i128 {
    if (total == 0) {
        std.debug.print("[unit-framework] START file={s} mode={s} jobs={s}\n", .{ path, mode, jobs_arg });
    } else {
        std.debug.print("[unit-framework] START index={}/{} file={s} mode={s} jobs={s}\n", .{ index, total, path, mode, jobs_arg });
    }
    return sio.nanoTimestamp();
}

fn endSaFileLog(
    path: []const u8,
    mode: []const u8,
    jobs_arg: []const u8,
    index: usize,
    total: usize,
    start_ns: i128,
    stdout_len: usize,
    stderr_len: usize,
) void {
    if (total == 0) {
        std.debug.print(
            "[unit-framework] END   file={s} mode={s} elapsed={}ms jobs={s} stdout_bytes={} stderr_bytes={}\n",
            .{ path, mode, elapsedMs(start_ns), jobs_arg, stdout_len, stderr_len },
        );
    } else {
        std.debug.print(
            "[unit-framework] END   index={}/{} file={s} mode={s} elapsed={}ms jobs={s} stdout_bytes={} stderr_bytes={}\n",
            .{ index, total, path, mode, elapsedMs(start_ns), jobs_arg, stdout_len, stderr_len },
        );
    }
}

fn errorSaFileLog(path: []const u8, mode: []const u8, index: usize, total: usize, err: anyerror) void {
    if (total == 0) {
        std.debug.print("[unit-framework] END   file={s} mode={s} status=error err={s}\n", .{ path, mode, @errorName(err) });
    } else {
        std.debug.print("[unit-framework] END   index={}/{} file={s} mode={s} status=error err={s}\n", .{ index, total, path, mode, @errorName(err) });
    }
}

const SaTestExpectations = struct {
    expected_passes: []const []const u8,
    expected_absent_passes: []const []const u8 = &.{},
    expected_summary: []const u8,
    owned: bool = false,

    fn deinit(self: SaTestExpectations, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        freeStringList(allocator, self.expected_passes);
        freeStringList(allocator, self.expected_absent_passes);
        allocator.free(self.expected_passes);
        allocator.free(self.expected_absent_passes);
        allocator.free(self.expected_summary);
    }
};

const SaTestTask = struct {
    path: []const u8,
    expectations: SaTestExpectations,
    jobs_arg: []const u8,
};

var queued_sa_tests: std.ArrayListUnmanaged(SaTestTask) = .empty;

fn shouldQueueSaTestFile(allocator: std.mem.Allocator) bool {
    if (saUnitFileJobs() <= 1) return false;
    const sa_bin = saBinaryPath(allocator) orelse return false;
    allocator.free(sa_bin);
    return true;
}

fn freeStringList(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
}

fn isSaTestSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

fn trimSaTestSpace(text: []const u8) []const u8 {
    return std.mem.trimStart(u8, text, " \t\r");
}

fn consumeSaTestKeyword(rest: *[]const u8, keyword: []const u8) bool {
    const text = rest.*;
    if (!std.mem.startsWith(u8, text, keyword)) return false;
    if (text.len > keyword.len and !isSaTestSpace(text[keyword.len])) return false;
    rest.* = trimSaTestSpace(text[keyword.len..]);
    return true;
}

const ParsedSaTestDecl = struct {
    name: []const u8,
    ignored: bool,
};

fn parseSaTestDecl(line: []const u8) ?ParsedSaTestDecl {
    var rest = trimSaTestSpace(line);
    if (!std.mem.startsWith(u8, rest, "@test")) return null;
    if (rest.len > "@test".len and !isSaTestSpace(rest["@test".len])) return null;
    rest = trimSaTestSpace(rest["@test".len..]);

    var ignored = false;
    while (true) {
        if (consumeSaTestKeyword(&rest, "ignored")) {
            ignored = true;
            continue;
        }
        if (consumeSaTestKeyword(&rest, "should_panic")) continue;
        break;
    }

    if (rest.len == 0 or rest[0] != '"') return null;
    var i: usize = 1;
    var escaped = false;
    while (i < rest.len) : (i += 1) {
        const c = rest[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') return .{ .name = rest[1..i], .ignored = ignored };
    }
    return null;
}

fn appendPassMarker(allocator: std.mem.Allocator, list: *std.array_list.Managed([]const u8), name: []const u8) !void {
    const marker = try std.fmt.allocPrint(allocator, "[PASS] {s}", .{name});
    errdefer allocator.free(marker);
    try list.append(marker);
}

fn buildSaTestExpectations(allocator: std.mem.Allocator, path: []const u8) !SaTestExpectations {
    const source = try sio.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(source);

    var expected_passes = std.array_list.Managed([]const u8).init(allocator);
    defer expected_passes.deinit();
    errdefer freeStringList(allocator, expected_passes.items);

    var expected_absent_passes = std.array_list.Managed([]const u8).init(allocator);
    defer expected_absent_passes.deinit();
    errdefer freeStringList(allocator, expected_absent_passes.items);

    var passed_count: usize = 0;
    var ignored_count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const parsed = parseSaTestDecl(line) orelse continue;
        if (parsed.ignored) {
            ignored_count += 1;
            try appendPassMarker(allocator, &expected_absent_passes, parsed.name);
        } else {
            passed_count += 1;
            try appendPassMarker(allocator, &expected_passes, parsed.name);
        }
    }

    const summary = if (ignored_count == 0)
        try std.fmt.allocPrint(allocator, "test result: ok. {} passed; 0 failed; 0 skipped", .{passed_count})
    else
        try std.fmt.allocPrint(allocator, "test result: ok. {} passed; 0 failed; 0 skipped; {} ignored", .{ passed_count, ignored_count });
    errdefer allocator.free(summary);

    return .{
        .expected_passes = try expected_passes.toOwnedSlice(),
        .expected_absent_passes = try expected_absent_passes.toOwnedSlice(),
        .expected_summary = summary,
        .owned = true,
    };
}

fn enqueueSaTestFile(path: []const u8, expectations: SaTestExpectations) !void {
    const jobs_arg = try saTestJobsArgForPath(std.testing.allocator, path);
    errdefer std.testing.allocator.free(jobs_arg);
    errdefer expectations.deinit(std.testing.allocator);
    try queued_sa_tests.append(std.testing.allocator, .{
        .path = path,
        .expectations = expectations,
        .jobs_arg = jobs_arg,
    });
}

fn runSaTestFile(path: []const u8, expected_passes: []const []const u8, expected_summary: []const u8) !void {
    return runSaTestFileWithExpectations(path, .{ .expected_passes = expected_passes, .expected_summary = expected_summary });
}

fn runSaTestFileAuto(path: []const u8) !void {
    const expectations = try buildSaTestExpectations(std.testing.allocator, path);
    return runSaTestFileWithExpectations(path, expectations);
}

fn runSaTestFileWithExpectations(path: []const u8, expectations: SaTestExpectations) !void {
    if (shouldQueueSaTestFile(std.testing.allocator)) {
        return enqueueSaTestFile(path, expectations);
    }
    defer expectations.deinit(std.testing.allocator);
    return runSaTestFileInProcess(path, expectations);
}

fn runSaTestFileInProcess(path: []const u8, expectations: SaTestExpectations) !void {
    const suite_path = try sio.cwd().realpathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(suite_path);
    const jobs_arg = try saTestJobsArgForPath(std.testing.allocator, path);
    defer std.testing.allocator.free(jobs_arg);
    const start_ns = startSaFileLog(path, "in-process", jobs_arg, 0, 0);
    // NOTE(Zig 0.17): `errdefer |err|` payload capture was removed after 0.14,
    // so the fallible tail runs in an inner function with an explicit catch
    // that preserves the structured `status=error err=<name>` log marker.
    runSaTestFileInProcessInner(path, expectations, suite_path, jobs_arg, start_ns) catch |err| {
        errorSaFileLog(path, "in-process", 0, 0, err);
        return err;
    };
}

fn runSaTestFileInProcessInner(path: []const u8, expectations: SaTestExpectations, suite_path: []const u8, jobs_arg: []const u8, start_ns: i128) !void {
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const argv = [_][]const u8{ "sa", "test", suite_path, "--jobs", jobs_arg, "--trace-panic" };
    const code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    if (code != 0) {
        std.debug.print("stdout: {s}\n", .{stdout_buffer.items});
        std.debug.print("stderr: {s}\n", .{stderr_buffer.items});
    }
    try std.testing.expectEqual(@as(u8, 0), code);
    for (expectations.expected_passes) |expected_pass| {
        try expectContains(stdout_buffer.items, expected_pass);
    }
    for (expectations.expected_absent_passes) |absent_pass| {
        try expectNotContains(stdout_buffer.items, absent_pass);
    }
    try expectContains(stdout_buffer.items, expectations.expected_summary);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    endSaFileLog(path, "in-process", jobs_arg, 0, 0, start_ns, stdout_buffer.items.len, stderr_buffer.items.len);
}

const SaTestWorkerContext = struct {
    sa_bin: []const u8,
    tasks: []const SaTestTask,
    next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // NOTE(Zig 0.17): `std.atomic.Mutex` is now an enum lock (`.unlocked`)
    // with tryLock/unlock only; spin instead of the removed blocking lock().
    output_mutex: std.atomic.Mutex = .unlocked,
};

fn externalSaTestCode(term: sio.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 255,
    };
}

fn runSaTestFileExternal(sa_bin: []const u8, task: SaTestTask, index: usize, total: usize) !void {
    const suite_path = try sio.cwd().realpathAlloc(std.heap.page_allocator, task.path);
    defer std.heap.page_allocator.free(suite_path);
    const start_ns = startSaFileLog(task.path, "process", task.jobs_arg, index, total);
    // NOTE(Zig 0.17): `errdefer |err|` payload capture was removed after 0.14;
    // inner function + explicit catch preserves the structured error log marker.
    runSaTestFileExternalInner(sa_bin, task, index, total, suite_path, start_ns) catch |err| {
        errorSaFileLog(task.path, "process", index, total, err);
        return err;
    };
}

fn runSaTestFileExternalInner(sa_bin: []const u8, task: SaTestTask, index: usize, total: usize, suite_path: []const u8, start_ns: i128) !void {
    const argv = [_][]const u8{ sa_bin, "test", suite_path, "--jobs", task.jobs_arg, "--trace-panic" };

    const result = try sio.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = argv[0..],
        .max_output_bytes = 2 * 1024 * 1024,
    });
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    if (externalSaTestCode(result.term) != 0) {
        std.debug.print("stdout: {s}\n", .{result.stdout});
        std.debug.print("stderr: {s}\n", .{result.stderr});
        return error.SaTestFailed;
    }
    for (task.expectations.expected_passes) |expected_pass| {
        if (std.mem.indexOf(u8, result.stdout, expected_pass) == null) {
            std.debug.print("stdout missing expected marker for {s}: {s}\nstdout: {s}\n", .{ task.path, expected_pass, result.stdout });
            return error.SaTestMissingExpectedPass;
        }
    }
    for (task.expectations.expected_absent_passes) |absent_pass| {
        if (std.mem.indexOf(u8, result.stdout, absent_pass) != null) {
            std.debug.print("stdout contains unexpected marker for {s}: {s}\nstdout: {s}\n", .{ task.path, absent_pass, result.stdout });
            return error.SaTestUnexpectedPass;
        }
    }
    if (std.mem.indexOf(u8, result.stdout, task.expectations.expected_summary) == null) {
        std.debug.print("stdout missing expected summary for {s}: {s}\nstdout: {s}\n", .{ task.path, task.expectations.expected_summary, result.stdout });
        return error.SaTestMissingSummary;
    }
    if (result.stderr.len != 0) {
        std.debug.print("unexpected stderr for {s}: {s}\n", .{ task.path, result.stderr });
        return error.SaTestUnexpectedStderr;
    }
    endSaFileLog(task.path, "process", task.jobs_arg, index, total, start_ns, result.stdout.len, result.stderr.len);
}

fn saTestWorkerMain(context: *SaTestWorkerContext) void {
    while (true) {
        const index = context.next_index.fetchAdd(1, .monotonic);
        if (index >= context.tasks.len) return;
        runSaTestFileExternal(context.sa_bin, context.tasks[index], index + 1, context.tasks.len) catch |err| {
            context.failed.store(true, .release);
            while (!context.output_mutex.tryLock()) std.atomic.spinLoopHint();
            defer context.output_mutex.unlock();
            std.debug.print("[unit-framework] worker observed error file={s} err={s}\n", .{ context.tasks[index].path, @errorName(err) });
        };
    }
}

fn runQueuedSaTestFiles() !void {
    const tasks = queued_sa_tests.items;
    if (tasks.len == 0) return;
    defer {
        clearQueuedSaTestFiles();
    }

    const sa_bin = saBinaryPath(std.testing.allocator) orelse {
        for (tasks) |task| try runSaTestFileInProcess(task.path, task.expectations);
        return;
    };
    defer std.testing.allocator.free(sa_bin);

    const worker_count = @min(saUnitFileJobs(), tasks.len);
    if (worker_count <= 1) {
        for (tasks, 0..) |task, index| try runSaTestFileExternal(sa_bin, task, index + 1, tasks.len);
        return;
    }

    const start_ns = sio.nanoTimestamp();
    defer std.debug.print("[unit-framework] macro surface files elapsed={}ms file_jobs={} files={} mode=process\n", .{ elapsedMs(start_ns), worker_count, tasks.len });

    var context = SaTestWorkerContext{ .sa_bin = sa_bin, .tasks = tasks };
    var threads = try std.testing.allocator.alloc(std.Thread, worker_count);
    defer std.testing.allocator.free(threads);

    var started: usize = 0;
    var joined: usize = 0;
    errdefer {
        for (threads[joined..started]) |thread| thread.join();
    }
    while (started < worker_count) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, saTestWorkerMain, .{&context});
    }
    while (joined < started) : (joined += 1) {
        threads[joined].join();
    }

    try std.testing.expect(!context.failed.load(.acquire));
}

fn clearQueuedSaTestFiles() void {
    for (queued_sa_tests.items) |task| {
        task.expectations.deinit(std.testing.allocator);
        std.testing.allocator.free(task.jobs_arg);
    }
    queued_sa_tests.deinit(std.testing.allocator);
    queued_sa_tests = .empty;
}

test "native unit framework suite covers the demo-derived feature matrix" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const suite_path = try sio.cwd().realpathAlloc(std.testing.allocator, "tests/unit_framework/feature_suite.sars");
    defer std.testing.allocator.free(suite_path);
    const jobs_arg = try saTestJobsArg(std.testing.allocator);
    defer std.testing.allocator.free(jobs_arg);
    const start_ns = startSaFileLog("tests/unit_framework/feature_suite.sars", "all-modes", jobs_arg, 0, 0);
    // NOTE(Zig 0.17): `errdefer |err|` payload capture was removed after 0.14;
    // inner function + explicit catch preserves the structured error log marker.
    featureSuiteAllModesInner(suite_path, jobs_arg, start_ns) catch |err| {
        errorSaFileLog("tests/unit_framework/feature_suite.sars", "all-modes", 0, 0, err);
        return err;
    };
}

fn featureSuiteAllModesInner(suite_path: []const u8, jobs_arg: []const u8, start_ns: i128) !void {
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();
    var total_stdout_bytes: usize = 0;
    var total_stderr_bytes: usize = 0;

    const default_argv = [_][]const u8{ "sa", "test", suite_path, "--jobs", jobs_arg };
    const default_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        default_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    if (default_code != 0) {
        std.debug.print("stdout: {s}\n", .{stdout_buffer.items});
        std.debug.print("stderr: {s}\n", .{stderr_buffer.items});
    }
    try std.testing.expectEqual(@as(u8, 0), default_code);
    const default_expectations = try buildSaTestExpectations(std.testing.allocator, "tests/unit_framework/feature_suite.sars");
    defer default_expectations.deinit(std.testing.allocator);
    for (default_expectations.expected_passes) |expected_pass| {
        try expectContains(stdout_buffer.items, expected_pass);
    }
    for (default_expectations.expected_absent_passes) |absent_pass| {
        try expectNotContains(stdout_buffer.items, absent_pass);
    }
    try expectContains(stdout_buffer.items, default_expectations.expected_summary);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    total_stdout_bytes += stdout_buffer.items.len;
    total_stderr_bytes += stderr_buffer.items.len;

    var ignored_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer ignored_tmp.cleanup();
    try writeSource(ignored_tmp.dir, "ignored_modes.sars",
        \\@test "small normal case"():
        \\L_ENTRY:
        \\    return
        \\
        \\@test ignored "small ignored case"():
        \\L_ENTRY:
        \\    return
        \\
    );
    const ignored_path = try ignored_tmp.dir.realPathFileAlloc(std.testing.io, "ignored_modes.sars", std.testing.allocator);
    defer std.testing.allocator.free(ignored_path);

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const ignored_argv = [_][]const u8{ "sa", "test", ignored_path, "--jobs", jobs_arg, "--ignored" };
    const ignored_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        ignored_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), ignored_code);
    try expectContains(stdout_buffer.items, "[PASS] small ignored case");
    try expectNotContains(stdout_buffer.items, "[PASS] small normal case");
    try expectContains(stdout_buffer.items, "test result: ok. 1 passed; 0 failed; 1 skipped");
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    total_stdout_bytes += stdout_buffer.items.len;
    total_stderr_bytes += stderr_buffer.items.len;

    stdout_buffer.clearRetainingCapacity();
    stderr_buffer.clearRetainingCapacity();

    const include_ignored_argv = [_][]const u8{ "sa", "test", ignored_path, "--jobs", jobs_arg, "--include-ignored" };
    const include_ignored_code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        include_ignored_argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    try std.testing.expectEqual(@as(u8, 0), include_ignored_code);
    try expectContains(stdout_buffer.items, "[PASS] small normal case");
    try expectContains(stdout_buffer.items, "[PASS] small ignored case");
    try expectContains(stdout_buffer.items, "test result: ok. 2 passed; 0 failed; 0 skipped");
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    total_stdout_bytes += stdout_buffer.items.len;
    total_stderr_bytes += stderr_buffer.items.len;
    endSaFileLog("tests/unit_framework/feature_suite.sars", "all-modes", jobs_arg, 0, 0, start_ns, total_stdout_bytes, total_stderr_bytes);
}

test "native unit assertions surface file line expected and got details" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const core_path = try original_cwd.realpathAlloc(std.testing.allocator, "sa_std/core/sa_core.sars");
    defer std.testing.allocator.free(core_path);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\@import "{s}"
        \\
        \\@const ASSERT_FAIL_MSG = utf8:"tests/assert_diag.sa:7: expected 7, got 3"
        \\#def ASSERT_FAIL_MSG_LEN = 43
        \\
        \\@test "assert eq diagnostic"():
        \\L_ENTRY:
        \\    value = add 1, 2
        \\    EXPAND ASSERT_EQ_MSG assert_cond, value, 7, ASSERT_FAIL_MSG, ASSERT_FAIL_MSG_LEN
        \\    !value
        \\    !assert_cond
        \\    return
        \\
    , .{core_path});
    defer std.testing.allocator.free(source);
    try writeSource(tmp.dir, "assert_diag.sars", source);

    const jobs_arg = try saTestJobsArg(std.testing.allocator);
    defer std.testing.allocator.free(jobs_arg);
    const start_ns = startSaFileLog("assert_diag.sars", "negative-diagnostic", jobs_arg, 0, 0);
    // NOTE(Zig 0.17): `errdefer |err|` payload capture was removed after 0.14;
    // inner function + explicit catch preserves the structured error log marker.
    assertDiagNegativeInner(jobs_arg, start_ns) catch |err| {
        errorSaFileLog("assert_diag.sars", "negative-diagnostic", 0, 0, err);
        return err;
    };
}

fn assertDiagNegativeInner(jobs_arg: []const u8, start_ns: i128) !void {
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const argv = [_][]const u8{ "sa", "test", "assert_diag.sars", "--jobs", jobs_arg };
    const code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );

    try std.testing.expectEqual(@as(u8, 1), code);
    try expectContains(stdout_buffer.items, "[FAIL] assert eq diagnostic");
    try expectContains(stdout_buffer.items, "test result: FAILED. 0 passed; 1 failed; 0 skipped");
    try expectContains(stderr_buffer.items, "tests/assert_diag.sa:");
    try expectContains(stderr_buffer.items, "expected 7");
    try expectContains(stderr_buffer.items, "got 3");
    endSaFileLog("assert_diag.sars", "negative-diagnostic", jobs_arg, 0, 0, start_ns, stdout_buffer.items.len, stderr_buffer.items.len);
}

test "native unit framework covers sa_std macro surface suites" {
    defer clearQueuedSaTestFiles();

    const macro_surface_suites = [_][]const u8{
        "tests/unit_framework/std_ascii_macro_surface.sars",
        "tests/unit_framework/std_ascii_char_is_ascii_macro_surface.sars",
        "tests/unit_framework/std_cmp_macro_surface.sars",
        "tests/unit_framework/std_cmp_min_max_macro_surface.sars",
        "tests/unit_framework/std_cmp_reverse_macro_surface.sars",
        "tests/unit_framework/std_cow_clone_eq_macro_surface.sars",
        "tests/unit_framework/std_cow_is_owned_macro_surface.sars",
        "tests/unit_framework/std_named_aliases_macro_surface.sars",
        "tests/unit_framework/std_env_named_aliases_macro_surface.sars",
        "tests/unit_framework/std_prelude_import_surface.sars",
        "tests/unit_framework/std_bufio_alias_surface.sars",
        "tests/unit_framework/std_io_bytes_alias_surface.sars",
        "tests/unit_framework/std_io_named_alias_surface.sars",
        "tests/unit_framework/std_fs_bytes_alias_surface.sars",
        "tests/unit_framework/std_net_bytes_alias_surface.sars",
        "tests/unit_framework/std_path_process_bytes_alias_surface.sars",
        "tests/unit_framework/std_cmp_reverse_hash_one_macro_surface.sars",
        "tests/unit_framework/std_cmp_reverse_clone_default_macro_surface.sars",
        "tests/unit_framework/std_default_convert_macro_surface.sars",
        "tests/unit_framework/std_default_convert_identity_macro_surface.sars",
        "tests/unit_framework/std_phantom_data_default_macro_surface.sars",
        "tests/unit_framework/std_any_type_id_eq_macro_surface.sars",
        "tests/unit_framework/std_from_into_default_macro_surface.sars",
        "tests/unit_framework/std_into_naming_macro_surface.sars",
        "tests/unit_framework/std_default_types_macro_surface.sars",
        "tests/unit_framework/std_convert_nonzero_macro_surface.sars",
        "tests/unit_framework/std_convert_identity_macro_surface.sars",
        "tests/unit_framework/std_option_zip_macro_surface.sars",
        "tests/unit_framework/std_float_wrapping_macro_surface.sars",
        "tests/unit_framework/std_wrapping_range_macro_surface.sars",
        "tests/unit_framework/std_mem_size_macro_surface.sars",
        "tests/unit_framework/std_manually_drop_bare_alias_macro_surface.sars",
        "tests/unit_framework/std_mem_size_of_align_macro_surface.sars",
        "tests/unit_framework/std_ptr_null_is_null_macro_surface.sars",
        "tests/unit_framework/std_mem_copy_macro_surface.sars",
        "tests/unit_framework/std_io_copy_slice_macro_surface.sars",
        "tests/unit_framework/std_float_constants_macro_surface.sars",
        "tests/unit_framework/std_wrapping_arith_macro_surface.sars",
        "tests/unit_framework/std_num_wrapping_saturating_hash_one_macro_surface.sars",
        "tests/unit_framework/std_num_wrapping_add_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_wrapping_saturating_macro_surface.sars",
        "tests/unit_framework/std_num_wrapping_saturating_clone_default_macro_surface.sars",
        "tests/unit_framework/std_atomic_ordering_macro_surface.sars",
        "tests/unit_framework/std_atomic_u64_load_store_macro_surface.sars",
        "tests/unit_framework/std_atomic_ordering_layout_macro_surface.sars",
        "tests/unit_framework/std_float_bitmask_macro_surface.sars",
        "tests/unit_framework/std_path_layout_macro_surface.sars",
        "tests/unit_framework/std_ffi_osstr_layout_macro_surface.sars",
        "tests/unit_framework/std_os_string_with_capacity_macro_surface.sars",
        "tests/unit_framework/std_time_duration_layout_macro_surface.sars",
        "tests/unit_framework/std_time_duration_hash_one_macro_surface.sars",
        "tests/unit_framework/std_time_instant_now_alias_macro_surface.sars",
        "tests/unit_framework/std_instant_duration_since_macro_surface.sars",
        "tests/unit_framework/std_time_duration_zero_is_zero_macro_surface.sars",
        "tests/unit_framework/std_duration_max_macro_surface.sars",
        "tests/unit_framework/std_duration_abs_diff_macro_surface.sars",
        "tests/unit_framework/std_duration_saturating_add_macro_surface.sars",
        "tests/unit_framework/std_time_instant_system_hash_one_macro_surface.sars",
        "tests/unit_framework/std_time_error_layout_macro_surface.sars",
        "tests/unit_framework/std_int_error_kind_macro_surface.sars",
        "tests/unit_framework/std_float_error_layout_macro_surface.sars",
        "tests/unit_framework/std_alloc_layout_macro_surface.sars",
        "tests/unit_framework/std_collections_try_reserve_error_layout_macro_surface.sars",
        "tests/unit_framework/std_try_from_error_macro_surface.sars",
        "tests/unit_framework/std_nonzero_bits_macro_surface.sars",
        "tests/unit_framework/std_once_lock_layout_macro_surface.sars",
        "tests/unit_framework/std_joinhandle_layout_macro_surface.sars",
        "tests/unit_framework/std_char_constants_macro_surface.sars",
        "tests/unit_framework/std_char_error_layout_macro_surface.sars",
        "tests/unit_framework/std_fmt_layout_macro_surface.sars",
        "tests/unit_framework/std_ffi_error_layout_macro_surface.sars",
        "tests/unit_framework/std_panic_layout_macro_surface.sars",
        "tests/unit_framework/std_string_error_layout_macro_surface.sars",
        "tests/unit_framework/std_net_error_layout_macro_surface.sars",
        "tests/unit_framework/std_option_result_macro_surface.sars",
        "tests/unit_framework/std_option_result_bare_alias_macro_surface.sars",
        "tests/unit_framework/std_result_is_ok_and_macro_surface.sars",
        "tests/unit_framework/std_option_some_none_macro_surface.sars",
        "tests/unit_framework/std_option_filter_macro_surface.sars",
        "tests/unit_framework/std_result_ok_err_macro_surface.sars",
        "tests/unit_framework/std_cell_macro_surface.sars",
        "tests/unit_framework/std_cell_update_swap_macro_surface.sars",
        "tests/unit_framework/std_cell_u64_update_swap_macro_surface.sars",
        "tests/unit_framework/std_refcell_u64_get_set_macro_surface.sars",
        "tests/unit_framework/std_box_into_inner_leak_macro_surface.sars",
        "tests/unit_framework/std_rc_arc_new_get_macro_surface.sars",
        "tests/unit_framework/std_refcell_macro_surface.sars",
        "tests/unit_framework/std_refcell_error_layout_macro_surface.sars",
        "tests/unit_framework/std_rc_weak_macro_surface.sars",
        "tests/unit_framework/std_arc_weak_macro_surface.sars",
        "tests/unit_framework/std_box_macro_surface.sars",
        "tests/unit_framework/std_mem_macro_surface.sars",
        "tests/unit_framework/std_mem_manually_drop_hash_one_macro_surface.sars",
        "tests/unit_framework/std_mem_manually_drop_cmp_macro_surface.sars",
        "tests/unit_framework/std_mem_manually_drop_clone_default_macro_surface.sars",
        "tests/unit_framework/std_ptr_macro_surface.sars",
        "tests/unit_framework/std_array_macro_surface.sars",
        "tests/unit_framework/std_array_bare_access_alias_macro_surface.sars",
        "tests/unit_framework/std_array_bare_iter_alias_macro_surface.sars",
        "tests/unit_framework/std_array_bare_map_from_fn_alias_macro_surface.sars",
        "tests/unit_framework/std_array_from_fn_get_macro_surface.sars",
        "tests/unit_framework/std_array_len_macro_surface.sars",
        "tests/unit_framework/std_array_rsplit_macro_surface.sars",

        "tests/unit_framework/std_array_ref_borrow_macro_surface.sars",
        "tests/unit_framework/std_array_try_from_slice_macro_surface.sars",
        "tests/unit_framework/std_array_ref_try_from_slice_macro_surface.sars",
        "tests/unit_framework/std_array_default_macro_surface.sars",
        "tests/unit_framework/std_array_clone_macro_surface.sars",
        "tests/unit_framework/std_array_eq_macro_surface.sars",
        "tests/unit_framework/std_array_cmp_macro_surface.sars",
        "tests/unit_framework/std_array_index_macro_surface.sars",
        "tests/unit_framework/std_array_iter_macro_surface.sars",
        "tests/unit_framework/std_array_iter_trait_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_cursor_ops_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_fold_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_aggregate_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_min_max_by_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_search_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_for_each_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_sorted_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_comparison_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_collect_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_adapter_collect_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_transform_collect_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_sequence_collect_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_pair_collect_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_adapter_state_collect_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_partition_macro_surface.sars",
        "tests/unit_framework/std_array_into_iter_array_window_collect_macro_surface.sars",
        "tests/unit_framework/std_array_hash_macro_surface.sars",
        "tests/unit_framework/std_array_hash_one_macro_surface.sars",
        "tests/unit_framework/std_num_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_clone_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_cmp_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_min_max_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_bit_position_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_reverse_bits_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_rotate_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_isolate_one_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_checked_next_power_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_ilog_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_midpoint_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_div_ceil_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_pow_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_count_ones_nz_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_bit_width_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_sign_cast_macro_surface.sars",
        "tests/unit_framework/std_num_isqrt_macro_surface.sars",
        "tests/unit_framework/std_num_signed_checked_isqrt_macro_surface.sars",
        "tests/unit_framework/std_num_signed_isqrt_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_bit_counts_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_bit_position_macro_surface.sars",
        "tests/unit_framework/std_num_isize_bit_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_signed_bit_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_rotate_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_reverse_bits_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_multiples_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_ilog_macro_surface.sars",
        "tests/unit_framework/std_num_next_power_primitive_macro_surface.sars",
        "tests/unit_framework/std_num_wrapping_next_power_primitive_macro_surface.sars",
        "tests/unit_framework/std_num_primitive_sign_cast_macro_surface.sars",
        "tests/unit_framework/std_num_checked_saturating_sign_cast_macro_surface.sars",
        "tests/unit_framework/std_num_strict_sign_cast_macro_surface.sars",
        "tests/unit_framework/std_num_checked_strict_pow_macro_surface.sars",
        "tests/unit_framework/std_num_strict_arithmetic_macro_surface.sars",
        "tests/unit_framework/std_num_strict_div_rem_macro_surface.sars",
        "tests/unit_framework/std_num_checked_strict_euclid_macro_surface.sars",
        "tests/unit_framework/std_num_strict_shift_macro_surface.sars",
        "tests/unit_framework/std_num_unbounded_shift_macro_surface.sars",
        "tests/unit_framework/std_num_exact_shift_macro_surface.sars",
        "tests/unit_framework/std_num_exact_division_macro_surface.sars",
        "tests/unit_framework/std_num_div_floor_macro_surface.sars",
        "tests/unit_framework/std_num_funnel_shift_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_unchecked_macro_surface.sars",
        "tests/unit_framework/std_num_carryless_mul_macro_surface.sars",
        "tests/unit_framework/std_num_gather_scatter_bits_macro_surface.sars",
        "tests/unit_framework/std_num_unchecked_disjoint_bitor_macro_surface.sars",
        "tests/unit_framework/std_num_carrying_mul_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_carry_borrow_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_overflowing_macro_surface.sars",
        "tests/unit_framework/std_num_unsigned_overflowing_div_neg_macro_surface.sars",
        "tests/unit_framework/std_num_unsigned_wrapping_div_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_signed_euclid_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_signed_midpoint_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_signed_div_ceil_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_signed_next_multiple_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_signed_ilog_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_signed_pow_macro_surface.sars",
        "tests/unit_framework/std_num_narrow_unsigned_saturating_div_macro_surface.sars",
        "tests/unit_framework/std_num_usize_saturating_div_macro_surface.sars",
        "tests/unit_framework/std_num_overflowing_pow_macro_surface.sars",
        "tests/unit_framework/std_num_signed_wide_overflowing_macro_surface.sars",
        "tests/unit_framework/std_num_signed_overflowing_neg_shift_macro_surface.sars",
        "tests/unit_framework/std_num_signed_overflowing_abs_pow_macro_surface.sars",
        "tests/unit_framework/std_num_signed_overflowing_div_rem_macro_surface.sars",
        "tests/unit_framework/std_num_checked_strict_neg_abs_macro_surface.sars",
        "tests/unit_framework/std_num_mixed_sign_add_sub_macro_surface.sars",
        "tests/unit_framework/std_num_checked_signed_diff_macro_surface.sars",
        "tests/unit_framework/std_num_nonzero_hash_one_macro_surface.sars",
        "tests/unit_framework/std_num_wrapping_saturating_bit_count_macro_surface.sars",
        "tests/unit_framework/std_num_wrapping_saturating_bit_transform_macro_surface.sars",
        "tests/unit_framework/std_num_wrapping_saturating_cmp_macro_surface.sars",
        "tests/unit_framework/std_num_wrapping_saturating_ops_macro_surface.sars",
        "tests/unit_framework/std_num_wrapping_u32_arithmetic_macro_surface.sars",
        "tests/unit_framework/std_num_wrapping_i64_arithmetic_macro_surface.sars",
        "tests/unit_framework/std_num_saturating_i64_arithmetic_macro_surface.sars",
        "tests/unit_framework/std_num_saturating_operator_macro_surface.sars",
        "tests/unit_framework/std_num_wrapping_saturating_pow_bits_macro_surface.sars",
        "tests/unit_framework/std_num_wrapping_next_power_macro_surface.sars",
        "tests/unit_framework/std_ops_range_macro_surface.sars",
        "tests/unit_framework/std_ops_range_usize_macro_surface.sars",
        "tests/unit_framework/std_ops_range_inclusive_inner_macro_surface.sars",
        "tests/unit_framework/std_ops_range_bounds_macro_surface.sars",
        "tests/unit_framework/std_ops_range_contains_macro_surface.sars",
        "tests/unit_framework/std_ops_bound_map_macro_surface.sars",
        "tests/unit_framework/std_ops_bound_ref_macro_surface.sars",
        "tests/unit_framework/std_ops_bound_range_empty_macro_surface.sars",
        "tests/unit_framework/std_ops_bound_intersect_macro_surface.sars",
        "tests/unit_framework/std_ops_control_flow_macro_surface.sars",
        "tests/unit_framework/std_control_flow_break_continue_macro_surface.sars",
        "tests/unit_framework/std_ops_control_flow_methods_macro_surface.sars",
        "tests/unit_framework/std_ops_bound_usize_macro_surface.sars",
        "tests/unit_framework/std_char_macro_surface.sars",
        "tests/unit_framework/std_ffi_cstr_macro_surface.sars",
        "tests/unit_framework/std_cstring_into_string_alias_macro_surface.sars",
        "tests/unit_framework/std_cstring_is_empty_macro_surface.sars",
        "tests/unit_framework/std_ffi_cstr_hash_one_macro_surface.sars",
        "tests/unit_framework/std_error_macro_surface.sars",
        "tests/unit_framework/std_error_ref_new_macro_surface.sars",
        "tests/unit_framework/std_io_error_kinds_macro_surface.sars",
        "tests/unit_framework/std_atomic_macro_surface.sars",
        "tests/unit_framework/std_once_macro_surface.sars",
        "tests/unit_framework/std_once_take_behavior.sars",
        "tests/unit_framework/std_once_call_once_alias_macro_surface.sars",
        "tests/unit_framework/std_once_is_completed_alias_macro_surface.sars",
        "tests/unit_framework/std_once_lazy_default_macro_surface.sars",
        "tests/unit_framework/std_once_lock_set_get_macro_surface.sars",
        "tests/unit_framework/std_mutex_macro_surface.sars",
        "tests/unit_framework/std_mutex_timeout_macro_surface.sars",
        "tests/unit_framework/std_mutex_default_macro_surface.sars",
        "tests/unit_framework/std_sync_defaults_macro_surface.sars",
        "tests/unit_framework/std_barrier_macro_surface.sars",
        "tests/unit_framework/std_condvar_macro_surface.sars",
        "tests/unit_framework/std_condvar_timeout_macro_surface.sars",
        "tests/unit_framework/std_condvar_timeout_ms_macro_surface.sars",
        "tests/unit_framework/std_condvar_waiters_macro_surface.sars",
        "tests/unit_framework/std_linked_list_macro_surface.sars",
        "tests/unit_framework/std_linked_list_remove_split_macro_surface.sars",
        "tests/unit_framework/std_linked_list_collect_macro_surface.sars",
        "tests/unit_framework/std_linked_list_retain_macro_surface.sars",
        "tests/unit_framework/std_linked_list_get_macro_surface.sars",
        "tests/unit_framework/std_linked_list_set_macro_surface.sars",
        "tests/unit_framework/std_linked_list_reverse_macro_surface.sars",
        "tests/unit_framework/std_linked_list_drain_macro_surface.sars",
        "tests/unit_framework/std_linked_list_pop_if_macro_surface.sars",
        "tests/unit_framework/std_linked_list_cursor_macro_surface.sars",
        "tests/unit_framework/std_linked_list_extract_if_macro_surface.sars",
        "tests/unit_framework/std_linked_list_from_array_macro_surface.sars",
        "tests/unit_framework/std_linked_list_insert_cursor_macro_surface.sars",
        "tests/unit_framework/std_linked_list_clone_eq_macro_surface.sars",
        "tests/unit_framework/std_linked_list_clear_is_empty_macro_surface.sars",
        "tests/unit_framework/std_linked_list_default_macro_surface.sars",
        "tests/unit_framework/std_rwlock_macro_surface.sars",
        "tests/unit_framework/std_rwlock_lock_spin_macro_surface.sars",
        "tests/unit_framework/std_sync_checked_behavior.sars",
        "tests/unit_framework/std_join_handle_state_macro_surface.sars",
        "tests/unit_framework/std_sync_poison_error_layout_macro_surface.sars",
        "tests/unit_framework/std_sync_poison_error_behavior.sars",
        "tests/unit_framework/std_once_state_layout_macro_surface.sars",
        "tests/unit_framework/std_mpsc_error_layout_macro_surface.sars",
        "tests/unit_framework/std_mpsc_error_behavior.sars",
        "tests/unit_framework/std_mpsc_timeout_error_behavior.sars",
        "tests/unit_framework/std_mpsc_macro_surface.sars",
        "tests/unit_framework/std_mpsc_channel_split_macro_surface.sars",
        "tests/unit_framework/std_mpsc_endpoint_drop_behavior.sars",
        "tests/unit_framework/std_mpsc_recv_timeout_macro_surface.sars",
        "tests/unit_framework/std_mpsc_timeout_ms_macro_surface.sars",
        "tests/unit_framework/std_mpsc_unbounded_macro_surface.sars",
        "tests/unit_framework/std_mpsc_send_timeout_macro_surface.sars",
        "tests/unit_framework/std_mpsc_list_unbounded_macro_surface.sars",
        "tests/unit_framework/std_mpsc_list_len_macro_surface.sars",
        "tests/unit_framework/std_mpsc_is_empty_full_macro_surface.sars",
        "tests/unit_framework/std_process_macro_surface.sars",
        "tests/unit_framework/std_process_id_macro_surface.sars",
        "tests/unit_framework/std_process_exit_status_success_macro_surface.sars",
        "tests/unit_framework/std_process_stdio_macro_surface.sars",
        "tests/unit_framework/std_process_as_fd_macro_surface.sars",
        "tests/unit_framework/std_process_command_builder_pidfd_macro_surface.sars",
        "tests/unit_framework/std_process_command_builder_uid_gid_macro_surface.sars",
        "tests/unit_framework/std_process_command_builder_groups_macro_surface.sars",
        "tests/unit_framework/std_process_command_builder_chroot_macro_surface.sars",
        "tests/unit_framework/std_process_command_builder_exec_macro_surface.sars",
        "tests/unit_framework/std_process_command_builder_stream_pidfd_macro_surface.sars",
        "tests/unit_framework/std_process_command_builder_stream_uid_gid_macro_surface.sars",
        "tests/unit_framework/std_process_command_builder_stream_groups_macro_surface.sars",
        "tests/unit_framework/std_process_command_builder_stream_chroot_macro_surface.sars",
        "tests/unit_framework/std_env_macro_surface.sars",
        "tests/unit_framework/std_env_var_alias_macro_surface.sars",
        "tests/unit_framework/std_env_temp_dir_macro_surface.sars",
        "tests/unit_framework/std_env_current_dir_macro_surface.sars",
        "tests/unit_framework/std_thread_macro_surface.sars",
        "tests/unit_framework/std_thread_current_id_macro_surface.sars",
        "tests/unit_framework/std_thread_yield_macro_surface.sars",
        "tests/unit_framework/std_marker_macro_surface.sars",
        "tests/unit_framework/std_marker_traits_extended_macro_surface.sars",
        "tests/unit_framework/std_marker_hash_one_macro_surface.sars",
        "tests/unit_framework/std_pin_macro_surface.sars",
        "tests/unit_framework/std_any_borrow_macro_surface.sars",
        "tests/unit_framework/std_cow_slice_hash_one_macro_surface.sars",
        "tests/unit_framework/std_hash_macro_surface.sars",
        "tests/unit_framework/std_hash_default_hasher_clone_macro_surface.sars",
        "tests/unit_framework/std_hash_default_hasher_write_macro_surface.sars",
        "tests/unit_framework/std_hash_char_macro_surface.sars",
        "tests/unit_framework/std_hash_bool_macro_surface.sars",
        "tests/unit_framework/std_hash_usize_macro_surface.sars",
        "tests/unit_framework/std_hash_integer_primitives_macro_surface.sars",
        "tests/unit_framework/std_hash_builder_integer_hash_one_macro_surface.sars",
        "tests/unit_framework/std_hash_bool_char_hash_one_macro_surface.sars",
        "tests/unit_framework/std_hash_unit_macro_surface.sars",
        "tests/unit_framework/std_hash_ptr_hash_one_macro_surface.sars",
        "tests/unit_framework/std_hash_const_ptr_macro_surface.sars",
        "tests/unit_framework/std_hash_mut_ptr_macro_surface.sars",
        "tests/unit_framework/std_hash_ref_u64_macro_surface.sars",
        "tests/unit_framework/std_hash_box_u64_macro_surface.sars",
        "tests/unit_framework/std_hash_rc_arc_u64_macro_surface.sars",
        "tests/unit_framework/std_string_buf_hash_one_macro_surface.sars",
        "tests/unit_framework/std_vec_hash_one_macro_surface.sars",
        "tests/unit_framework/std_container_hash_bare_alias_macro_surface.sars",
        "tests/unit_framework/std_hash_default_finish_macro_surface.sars",
        "tests/unit_framework/std_hash_tuple2_u64_macro_surface.sars",
        "tests/unit_framework/std_hash_tuple3_u64_macro_surface.sars",
        "tests/unit_framework/std_hash_tuple4_u64_macro_surface.sars",
        "tests/unit_framework/std_hash_tuple5_u64_macro_surface.sars",
        "tests/unit_framework/std_hash_tuple6_u64_macro_surface.sars",
        "tests/unit_framework/std_hash_tuple7_u64_macro_surface.sars",
        "tests/unit_framework/std_hash_tuple8_u64_macro_surface.sars",
        "tests/unit_framework/std_hash_tuple9_u64_macro_surface.sars",
        "tests/unit_framework/std_hash_tuple10_u64_macro_surface.sars",
        "tests/unit_framework/std_hash_tuple11_u64_macro_surface.sars",
        "tests/unit_framework/std_hash_tuple12_u64_macro_surface.sars",
        "tests/unit_framework/std_hash_build_hasher_hash_one_macro_surface.sars",
        "tests/unit_framework/std_hash_random_state_macro_surface.sars",
        "tests/unit_framework/std_hash_signed_write_macro_surface.sars",
        "tests/unit_framework/std_hash_build_hasher_default_traits_macro_surface.sars",
        "tests/unit_framework/std_string_macro_surface.sars",
        "tests/unit_framework/std_string_format_concrete_macro_surface.sars",
        "tests/unit_framework/std_string_chars_bare_alias_macro_surface.sars",
        "tests/unit_framework/std_str_byte_at_alias_macro_surface.sars",
        "tests/unit_framework/std_str_char_at_alias_macro_surface.sars",
        "tests/unit_framework/std_str_char_count_macro_surface.sars",
        "tests/unit_framework/std_string_buf_byte_at_alias_macro_surface.sars",
        "tests/unit_framework/std_string_buf_push_len_macro_surface.sars",
        "tests/unit_framework/std_string_buf_capacity_macro_surface.sars",
        "tests/unit_framework/std_string_buf_clear_macro_surface.sars",
        "tests/unit_framework/std_string_is_empty_macro_surface.sars",
        "tests/unit_framework/std_string_starts_ends_with_macro_surface.sars",
        "tests/unit_framework/std_string_contains_macro_surface.sars",
        "tests/unit_framework/std_string_buf_lit_macro_surface.sars",
        "tests/unit_framework/std_slice_macro_surface.sars",
        "tests/unit_framework/std_slice_bare_alias_macro_surface.sars",
        "tests/unit_framework/std_slice_get_contains_macro_surface.sars",
        "tests/unit_framework/std_slice_is_empty_macro_surface.sars",
        "tests/unit_framework/std_slice_vec_macro_surface.sars",
        "tests/unit_framework/std_vec_macro_surface.sars",
        "tests/unit_framework/std_vec_retain_alias_macro_surface.sars",
        "tests/unit_framework/std_vec_push_pop_macro_surface.sars",
        "tests/unit_framework/std_vec_with_capacity_macro_surface.sars",
        "tests/unit_framework/std_vec_clear_macro_surface.sars",
        "tests/unit_framework/std_vec_contains_macro_surface.sars",
        "tests/unit_framework/std_vec_drain_resize_alias_macro_surface.sars",
        "tests/unit_framework/std_vec_search_dedup_alias_macro_surface.sars",
        "tests/unit_framework/std_vec_extract_if_pop_if_alias_macro_surface.sars",
        "tests/unit_framework/std_vec_leak_spare_try_remove_alias_macro_surface.sars",
        "tests/unit_framework/std_vec_iter_macro_surface.sars",
        "tests/unit_framework/std_vec_iter_trait_clone_macro_surface.sars",
        "tests/unit_framework/std_vec_iter_mut_trait_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_bare_alias_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_default_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_slice_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_clone_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_trait_alias_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_cursor_ops_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_fold_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_aggregate_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_search_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_for_each_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_min_max_by_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_sorted_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_comparison_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_collect_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_adapter_collect_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_transform_collect_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_sequence_collect_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_pair_collect_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_adapter_state_collect_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_partition_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_array_window_collect_macro_surface.sars",
        "tests/unit_framework/std_vec_into_iter_next_chunk_macro_surface.sars",
        "tests/unit_framework/std_path_hash_one_macro_surface.sars",
        "tests/unit_framework/std_path_buf_method_alias_macro_surface.sars",
        "tests/unit_framework/std_path_to_str_alias_macro_surface.sars",
        "tests/unit_framework/std_path_component_at_alias_macro_surface.sars",
        "tests/unit_framework/std_path_component_count_macro_surface.sars",
        "tests/unit_framework/std_path_ancestor_at_alias_macro_surface.sars",
        "tests/unit_framework/std_path_strip_prefix_alias_macro_surface.sars",
        "tests/unit_framework/std_path_file_stem_alias_macro_surface.sars",
        "tests/unit_framework/std_path_parent_join_macro_surface.sars",
        "tests/unit_framework/std_path_is_absolute_macro_surface.sars",
        "tests/unit_framework/std_path_exists_macro_surface.sars",
        "tests/unit_framework/std_path_is_dir_file_macro_surface.sars",
        "tests/unit_framework/std_path_buf_with_capacity_macro_surface.sars",
        "tests/unit_framework/std_path_buf_clear_macro_surface.sars",
        "tests/unit_framework/std_path_buf_push_pop_macro_surface.sars",
        "tests/unit_framework/std_path_macro_surface.sars",
        "tests/unit_framework/std_time_macro_surface.sars",
        "tests/unit_framework/std_hashset_bit_ops_macro_surface.sars",
        "tests/unit_framework/std_map_set_bitops_alias_macro_surface.sars",
        "tests/unit_framework/std_hashset_into_iter_alias_macro_surface.sars",
        "tests/unit_framework/std_hashset_iter_alias_macro_surface.sars",
        "tests/unit_framework/std_hashset_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_hash_one_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_mut_alias_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_front_back_mut_alias_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_contains_pop_if_alias_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_push_mut_alias_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_retain_alias_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_truncate_front_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_push_pop_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_with_capacity_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_is_empty_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_clear_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_binary_search_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_split_off_alias_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_extract_if_alias_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_extract_if_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_splice_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_drain_range_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_drain_bare_alias_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_bare_alias_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_cursor_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_search_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_fold_aggregate_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_comparison_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_sorted_partition_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_adapter_collect_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_transform_collect_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_sequence_collect_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_pair_collect_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_adapter_state_collect_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_array_window_collect_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_collect_ext_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_for_each_chunk_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_view_clone_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_iter_mut_macro_surface.sars",
        "tests/unit_framework/std_vec_deque_macro_surface.sars",
        "tests/unit_framework/std_hashmap_get_disjoint_mut_alias_macro_surface.sars",
        "tests/unit_framework/std_hashmap_iter_alias_macro_surface.sars",
        "tests/unit_framework/std_hashmap_iter_mut_alias_macro_surface.sars",
        "tests/unit_framework/std_hashmap_entry_or_insert_alias_macro_surface.sars",
        "tests/unit_framework/std_hashmap_with_capacity_macro_surface.sars",
        "tests/unit_framework/std_hashmap_is_empty_macro_surface.sars",
        "tests/unit_framework/std_hashmap_remove_macro_surface.sars",
        "tests/unit_framework/std_hashset_insert_contains_macro_surface.sars",
        "tests/unit_framework/std_hashset_with_capacity_macro_surface.sars",
        "tests/unit_framework/std_hashset_remove_macro_surface.sars",
        "tests/unit_framework/std_container_is_empty_macro_surface.sars",
        "tests/unit_framework/std_hashmap_into_iter_alias_macro_surface.sars",
        "tests/unit_framework/std_hashmap_values_mut_alias_macro_surface.sars",
        "tests/unit_framework/std_hashmap_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_peek_mut_alias_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_retain_alias_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_extract_if_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_push_peek_pop_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_with_capacity_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_is_empty_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_clear_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_contains_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_pop_if_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_pop_if_clear_drain_alias_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_iter_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_iter_alias_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_iter_bare_alias_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_iter_trait_clone_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_iter_cursor_ops_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_iter_advance_chunk_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_iter_search_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_iter_any_all_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_iter_for_each_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_iter_aggregate_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_iter_fold_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_iter_collect_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_bare_alias_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_trait_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_clone_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_cursor_ops_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_advance_chunk_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_search_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_any_all_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_for_each_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_collect_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_fold_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_aggregate_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_comparison_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_trait_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_cursor_ops_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_advance_chunk_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_search_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_any_all_for_each_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_fold_aggregate_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_comparison_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_sortedness_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_partition_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_adapter_collect_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_transform_collect_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_state_collect_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_array_window_collect_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_sequence_collect_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_pair_collect_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_transform_adapter_collect_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_clone_macro_surface.sars",
        "tests/unit_framework/std_binary_heap_into_iter_sorted_collect_macro_surface.sars",
        "tests/unit_framework/std_btree_macro_surface.sars",
        "tests/unit_framework/std_btree_map_entry_mut_alias_macro_surface.sars",
        "tests/unit_framework/std_btree_map_extract_if_macro_surface.sars",
        "tests/unit_framework/std_btree_map_extract_if_range_macro_surface.sars",
        "tests/unit_framework/std_btree_map_get_disjoint_mut_alias_macro_surface.sars",
        "tests/unit_framework/std_btree_map_into_iter_alias_macro_surface.sars",
        "tests/unit_framework/std_btree_map_iter_alias_macro_surface.sars",
        "tests/unit_framework/std_btree_map_iter_mut_alias_macro_surface.sars",
        "tests/unit_framework/std_btree_map_put_get_macro_surface.sars",
        "tests/unit_framework/std_btree_map_is_empty_macro_surface.sars",
        "tests/unit_framework/std_btree_map_remove_macro_surface.sars",
        "tests/unit_framework/std_btree_set_insert_contains_macro_surface.sars",
        "tests/unit_framework/std_btree_set_remove_macro_surface.sars",
        "tests/unit_framework/std_btree_map_range_mut_alias_macro_surface.sars",
        "tests/unit_framework/std_btree_map_range_mut_macro_surface.sars",
        "tests/unit_framework/std_btree_map_values_mut_alias_macro_surface.sars",
        "tests/unit_framework/std_btree_set_bit_ops_macro_surface.sars",
        "tests/unit_framework/std_btree_set_extract_if_macro_surface.sars",
        "tests/unit_framework/std_btree_set_extract_if_range_macro_surface.sars",
        "tests/unit_framework/std_btree_set_into_iter_alias_macro_surface.sars",
        "tests/unit_framework/std_btree_set_iter_alias_macro_surface.sars",
        "tests/unit_framework/std_btree_hash_one_macro_surface.sars",
        "tests/unit_framework/std_btree_hash_one_bare_alias_macro_surface.sars",
        "tests/unit_framework/std_hashmap_mutable_predicate_macro_surface.sars",
        "tests/unit_framework/std_future_task_macro_surface.sars",
        "tests/unit_framework/std_pin_new_get_macro_surface.sars",
        "tests/unit_framework/std_future_poll_ready_macro_surface.sars",
        "tests/unit_framework/std_io_utility_macro_surface.sars",
        "tests/unit_framework/std_io_stdio_as_fd_macro_surface.sars",
        "tests/unit_framework/std_iter_macro_surface.sars",
        "tests/unit_framework/std_iter_alias_macro_surface.sars",
        "tests/unit_framework/std_iter_sorted_macro_surface.sars",
        "tests/unit_framework/std_iter_rfold_macro_surface.sars",
        "tests/unit_framework/std_iter_is_partitioned_macro_surface.sars",
        "tests/unit_framework/std_iter_partition_in_place_macro_surface.sars",
        "tests/unit_framework/std_iter_collect_into_macro_surface.sars",
        "tests/unit_framework/std_iter_try_collect_macro_surface.sars",
        "tests/unit_framework/std_iter_map_while_macro_surface.sars",
        "tests/unit_framework/std_iter_step_by_macro_surface.sars",
        "tests/unit_framework/std_iter_inspect_macro_surface.sars",
        "tests/unit_framework/std_iter_scan_macro_surface.sars",
        "tests/unit_framework/std_iter_copied_cloned_macro_surface.sars",
        "tests/unit_framework/std_iter_cycle_take_macro_surface.sars",
        "tests/unit_framework/std_iter_intersperse_macro_surface.sars",
        "tests/unit_framework/std_iter_try_reduce_macro_surface.sars",
        "tests/unit_framework/std_iter_compare_by_macro_surface.sars",
        "tests/unit_framework/std_iter_try_find_macro_surface.sars",
        "tests/unit_framework/std_iter_by_ref_collect_macro_surface.sars",
        "tests/unit_framework/std_iter_fuse_collect_macro_surface.sars",
        "tests/unit_framework/std_iter_peekable_macro_surface.sars",
        "tests/unit_framework/std_iter_array_chunks_macro_surface.sars",
        "tests/unit_framework/std_iter_map_windows_macro_surface.sars",
        "tests/unit_framework/std_iter_bare_adapter_alias_macro_surface.sars",
        "tests/unit_framework/std_iter_from_slice_next_macro_surface.sars",
        "tests/unit_framework/std_fs_macro_surface.sars",
        "tests/unit_framework/std_fs_path_join_env_alias_macro_surface.sars",
        "tests/unit_framework/std_fs_metadata_ext_macro_surface.sars",
        "tests/unit_framework/std_fs_dir_entry_ext_macro_surface.sars",
        "tests/unit_framework/std_fs_unix_ext_macro_surface.sars",
        "tests/unit_framework/std_fs_file_as_fd_macro_surface.sars",
        "tests/unit_framework/std_net_macro_surface.sars",
        "tests/unit_framework/std_net_option_alias_surface.sars",
        "tests/unit_framework/std_net_linger_macro_surface.sars",
        "tests/unit_framework/std_net_multicast_v6_macro_surface.sars",
        "tests/unit_framework/std_net_multicast_if_macro_surface.sars",
        "tests/unit_framework/std_net_error_kind_macro_surface.sars",
        "tests/unit_framework/std_net_error_record_macro_surface.sars",
        "tests/unit_framework/std_net_last_error_macro_surface.sars",
        "tests/unit_framework/std_net_connect_timeout_macro_surface.sars",
        "tests/unit_framework/std_net_connect_timeout_all_macro_surface.sars",
        "tests/unit_framework/std_net_addr_list_behavior.sars",
        "tests/unit_framework/std_net_addr_list_cursor_behavior.sars",
        "tests/unit_framework/std_net_addr_list_exhaustion_behavior.sars",
        "tests/unit_framework/std_net_format_edge_behavior.sars",
        "tests/unit_framework/std_net_conversion_behavior.sars",
        "tests/unit_framework/std_net_clone_behavior.sars",
        "tests/unit_framework/std_net_tcp_stream_clone_behavior.sars",
        "tests/unit_framework/std_net_buffer_size_behavior.sars",
        "tests/unit_framework/std_net_vectored_io_behavior.sars",
        "tests/unit_framework/std_net_read_exact_behavior.sars",
        "tests/unit_framework/std_net_shutdown_behavior.sars",
        "tests/unit_framework/std_net_shutdown_both_behavior.sars",
        "tests/unit_framework/std_net_ipv4_new_octets_macro_surface.sars",
        "tests/unit_framework/std_net_as_fd_macro_surface.sars",
        "tests/unit_framework/std_net_addr_macro_surface.sars",
        "tests/unit_framework/std_net_typed_address_macro_surface.sars",
        "tests/unit_framework/std_net_ip_hash_one_macro_surface.sars",
                "tests/unit_framework/std_net_multicast_macro_surface.sars",
                "tests/unit_framework/std_net_multicast_v6_join_macro_surface.sars",
                "tests/unit_framework/std_net_multicast_v6_macro_surface.sars",
        "tests/unit_framework/std_net_wsurl_macro_surface.sars",
        "tests/unit_framework/std_netx_macro_surface.sars",
        "tests/unit_framework/std_net_unix_macro_surface.sars",
        "tests/unit_framework/std_net_unix_as_fd_macro_surface.sars",
        "tests/unit_framework/std_net_dns_macro_surface.sars",
        "tests/unit_framework/std_os_fd_macro_surface.sars",
        "tests/unit_framework/std_os_fd_as_fd_macro_surface.sars",
        "tests/unit_framework/std_os_unix_ffi_hash_one_macro_surface.sars",
        "tests/unit_framework/std_os_unix_ffi_macro_surface.sars",
    };

    for (macro_surface_suites) |path| {
        if (builtin.os.tag == .windows) {
            const base = std.fs.path.basename(path);
            const unix_only_tests = [_][]const u8{
                "std_process_macro_surface.sars",
                "std_process_as_fd_macro_surface.sars",
                "std_process_command_builder_pidfd_macro_surface.sars",
                "std_process_command_builder_uid_gid_macro_surface.sars",
                "std_process_command_builder_groups_macro_surface.sars",
                "std_process_command_builder_chroot_macro_surface.sars",
                "std_process_command_builder_exec_macro_surface.sars",
                "std_process_command_builder_stream_pidfd_macro_surface.sars",
                "std_process_command_builder_stream_uid_gid_macro_surface.sars",
                "std_process_command_builder_stream_groups_macro_surface.sars",
                "std_process_command_builder_stream_chroot_macro_surface.sars",
                "std_env_macro_surface.sars",
                "std_path_exists_macro_surface.sars",
                "std_path_is_dir_file_macro_surface.sars",
                "std_fs_unix_ext_macro_surface.sars",
                "std_fs_file_as_fd_macro_surface.sars",
                "std_net_as_fd_macro_surface.sars",
                "std_net_unix_macro_surface.sars",
                "std_net_unix_as_fd_macro_surface.sars",
                "std_os_fd_macro_surface.sars",
                "std_os_fd_as_fd_macro_surface.sars",
                "std_os_unix_ffi_hash_one_macro_surface.sars",
                "std_os_unix_ffi_macro_surface.sars",
                "std_path_macro_surface.sars",
                "std_path_ancestors_macro_surface.sars",
                "std_path_canonicalize_macro_surface.sars",
                "std_path_parent_macro_surface.sars",
                "std_path_relative_macro_surface.sars",
                "std_path_strip_prefix_macro_surface.sars",
                "std_path_join_macro_surface.sars",
                "std_path_file_stem_macro_surface.sars",
                "std_path_file_name_macro_surface.sars",
                "std_path_extension_macro_surface.sars",
                "std_path_buf_with_extension_macro_surface.sars",
                "std_path_buf_set_extension_macro_surface.sars",
                "std_path_buf_set_file_name_macro_surface.sars",
                "std_path_buf_macro_surface.sars",
                "std_path_with_capacity_macro_surface.sars",
                "std_path_ends_with_macro_surface.sars",
                "std_path_starts_with_macro_surface.sars",
                "std_path_components_macro_surface.sars",
                "std_path_has_root_macro_surface.sars",
                "std_path_is_absolute_macro_surface.sars",
                "std_path_is_relative_macro_surface.sars",
                "std_path_buf_pop_macro_surface.sars",
                "std_path_buf_push_macro_surface.sars",
                "std_binary_heap_contains_macro_surface.sars",
                "std_io_utility_macro_surface.sars",
                "std_fs_file_as_fd_macro_surface.sars",
                "std_fs_unix_ext_macro_surface.sars",
                "std_io_stdio_as_fd_macro_surface.sars",
                "std_net_as_fd_macro_surface.sars",
                "std_net_unix_macro_surface.sars",
                "std_net_unix_as_fd_macro_surface.sars",
                "std_os_fd_macro_surface.sars",
                "std_os_fd_as_fd_macro_surface.sars",
                "std_os_unix_ffi_hash_one_macro_surface.sars",
                "std_os_unix_ffi_macro_surface.sars",
                "std_process_as_fd_macro_surface.sars",
                "std_process_command_builder_chroot_macro_surface.sars",
                "std_process_command_builder_exec_macro_surface.sars",
                "std_process_command_builder_groups_macro_surface.sars",
                "std_process_command_builder_pidfd_macro_surface.sars",
                "std_process_command_builder_stream_chroot_macro_surface.sars",
                "std_process_command_builder_stream_groups_macro_surface.sars",
                "std_process_command_builder_stream_pidfd_macro_surface.sars",
                "std_process_command_builder_stream_uid_gid_macro_surface.sars",
                "std_process_command_builder_uid_gid_macro_surface.sars",
                "std_process_macro_surface.sars",
                "std_fs_macro_surface.sars",
                "std_fs_metadata_ext_macro_surface.sars",
                "std_net_macro_surface.sars",
                "std_process_windows_macro_surface.sars",
                "std_fs_dir_entry_ext_macro_surface.sars",
                "std_net_wsurl_macro_surface.sars",
                "std_netx_macro_surface.sars",
            };
            var skip = false;
            for (unix_only_tests) |skip_name| {
                if (std.mem.eql(u8, base, skip_name)) {
                    skip = true;
                    break;
                }
            }
            if (skip) continue;
        }
        // IPv6 multicast needs a multicast-capable interface; without it the
        // v6 join fails with ENODEV (environment, not product). The v4 suite
        // above still verifies unconditionally.
        if (std.mem.eql(u8, path, "tests/unit_framework/std_net_multicast_v6_join_macro_surface.sars") and
            !udpMulticastV6JoinPermitted()) continue;
        try runSaTestFileAuto(path);
    }

    if (builtin.os.tag == .windows) {
        try runSaTestFileAuto("tests/unit_framework/std_process_windows_macro_surface.sars");
        try runSaTestFileAuto("tests/unit_framework/std_env_windows_macro_surface.sars");
    }

    try runQueuedSaTestFiles();
}

test "queued sa test worker failure returns test error without crashing" {
    defer clearQueuedSaTestFiles();

    const sa_bin_name: [:0]const u8 = "SA_BIN";
    const file_jobs_name: [:0]const u8 = "SA_UNIT_FILE_JOBS";
    const file_jobs_value: [:0]const u8 = "2";

    const saved_sa_bin = try saveEnvVarZ(std.testing.allocator, "SA_BIN");
    defer if (saved_sa_bin) |value| std.testing.allocator.free(value);
    const sa_bin_value: [:0]const u8 = if (saved_sa_bin) |value| value else if (builtin.os.tag == .windows) "sa.exe" else "sa";
    const saved_file_jobs = try saveEnvVarZ(std.testing.allocator, "SA_UNIT_FILE_JOBS");
    defer if (saved_file_jobs) |value| std.testing.allocator.free(value);

    try setEnvVarZ(sa_bin_name, sa_bin_value);
    defer restoreEnvVarZ(sa_bin_name, saved_sa_bin) catch unreachable;
    try setEnvVarZ(file_jobs_name, file_jobs_value);
    defer restoreEnvVarZ(file_jobs_name, saved_file_jobs) catch unreachable;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeSource(tmp.dir, "queued_pass.sars",
        \\@test "queued pass"():
        \\L_ENTRY:
        \\    return
        \\
    );
    try writeSource(tmp.dir, "queued_fail.sars",
        \\@test "queued fail"():
        \\L_ENTRY:
        \\    panic(991)
        \\
    );

    const pass_path = try tmp.dir.realPathFileAlloc(std.testing.io, "queued_pass.sars", std.testing.allocator);
    defer std.testing.allocator.free(pass_path);
    const fail_path = try tmp.dir.realPathFileAlloc(std.testing.io, "queued_fail.sars", std.testing.allocator);
    defer std.testing.allocator.free(fail_path);

    try enqueueSaTestFile(pass_path, .{
        .expected_passes = &.{"[PASS] queued pass"},
        .expected_summary = "test result: ok. 1 passed; 0 failed; 0 skipped",
    });
    try enqueueSaTestFile(fail_path, .{
        .expected_passes = &.{"[PASS] queued fail"},
        .expected_summary = "test result: ok. 1 passed; 0 failed; 0 skipped",
    });

    try std.testing.expectError(error.TestUnexpectedResult, runQueuedSaTestFiles());
    try std.testing.expectEqual(@as(usize, 0), queued_sa_tests.items.len);
}

test "native unit framework exposes standard mock io buffer" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    const mock_io_path = try original_cwd.realpathAlloc(std.testing.allocator, "sa_std/testing/mock_io.sars");
    defer std.testing.allocator.free(mock_io_path);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\@import "{s}"
        \\
        \\@const INPUT = utf8:"abcde"
        \\#def INPUT_LEN = 5
        \\
        \\@test "mock io buffer read write rewind"():
        \\L_ENTRY:
        \\    mock = alloc MockIo_SIZE
        \\    backing = alloc 4
        \\    EXPAND MOCK_IO_INIT mock, backing, 4
        \\    EXPAND MOCK_IO_WRITE written, mock, INPUT, INPUT_LEN
        \\    EXPAND MOCK_IO_LEN len0, mock
        \\    EXPAND MOCK_IO_REWIND mock
        \\    first = alloc 3
        \\    EXPAND MOCK_IO_READ read0, mock, first, 3
        \\    EXPAND MOCK_IO_POS pos0, mock
        \\    second = alloc 2
        \\    EXPAND MOCK_IO_READ read1, mock, second, 2
        \\    EXPAND MOCK_IO_POS pos1, mock
        \\    b0 = load first+0 as u8
        \\    b1 = load first+1 as u8
        \\    b2 = load first+2 as u8
        \\    b3 = load second+0 as u8
        \\    ok_written = eq written, 4
        \\    ok_len = eq len0, 4
        \\    ok_read0 = eq read0, 3
        \\    ok_pos0 = eq pos0, 3
        \\    ok_read1 = eq read1, 1
        \\    ok_pos1 = eq pos1, 4
        \\    ok_b0 = eq b0, 97
        \\    ok_b1 = eq b1, 98
        \\    ok_b2 = eq b2, 99
        \\    ok_b3 = eq b3, 100
        \\    ok01 = and ok_written, ok_len
        \\    ok02 = and ok01, ok_read0
        \\    ok03 = and ok02, ok_pos0
        \\    ok04 = and ok03, ok_read1
        \\    ok05 = and ok04, ok_pos1
        \\    ok06 = and ok05, ok_b0
        \\    ok07 = and ok06, ok_b1
        \\    ok08 = and ok07, ok_b2
        \\    ok = and ok08, ok_b3
        \\    !written
        \\    !len0
        \\    !read0
        \\    !pos0
        \\    !read1
        \\    !pos1
        \\    !b0
        \\    !b1
        \\    !b2
        \\    !b3
        \\    !ok_written
        \\    !ok_len
        \\    !ok_read0
        \\    !ok_pos0
        \\    !ok_read1
        \\    !ok_pos1
        \\    !ok_b0
        \\    !ok_b1
        \\    !ok_b2
        \\    !ok_b3
        \\    !ok01
        \\    !ok02
        \\    !ok03
        \\    !ok04
        \\    !ok05
        \\    !ok06
        \\    !ok07
        \\    !ok08
        \\    !mock
        \\    !backing
        \\    !first
        \\    !second
        \\    br ok -> L_OK, L_FAIL
        \\
        \\L_OK:
        \\    !ok
        \\    return
        \\
        \\L_FAIL:
        \\    !ok
        \\    panic(901)
        \\
    , .{mock_io_path});
    defer std.testing.allocator.free(source);
    try writeSource(tmp.dir, "mock_io_test.sars", source);

    const jobs_arg = try saTestJobsArg(std.testing.allocator);
    defer std.testing.allocator.free(jobs_arg);
    const start_ns = startSaFileLog("mock_io_test.sars", "in-process", jobs_arg, 0, 0);
    // NOTE(Zig 0.17): `errdefer |err|` payload capture was removed after 0.14;
    // inner function + explicit catch preserves the structured error log marker.
    mockIoInProcessInner(jobs_arg, start_ns) catch |err| {
        errorSaFileLog("mock_io_test.sars", "in-process", 0, 0, err);
        return err;
    };
}

fn mockIoInProcessInner(jobs_arg: []const u8, start_ns: i128) !void {
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const argv = [_][]const u8{ "sa", "test", "mock_io_test.sars", "--jobs", jobs_arg };
    const code = try saasm.cli.executeWithWriters(
        std.testing.allocator,
        argv[0..],
        sio.managedWriter(&stdout_buffer),
        sio.managedWriter(&stderr_buffer),
    );
    if (code != 0) {
        std.debug.print("stdout: {s}\n", .{stdout_buffer.items});
        std.debug.print("stderr: {s}\n", .{stderr_buffer.items});
    }
    try std.testing.expectEqual(@as(u8, 0), code);
    try expectContains(stdout_buffer.items, "[PASS] mock io buffer read write rewind");
    try expectContains(stdout_buffer.items, "test result: ok. 1 passed; 0 failed; 0 skipped");
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    endSaFileLog("mock_io_test.sars", "in-process", jobs_arg, 0, 0, start_ns, stdout_buffer.items.len, stderr_buffer.items.len);
}

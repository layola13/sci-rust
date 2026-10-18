const std = @import("std");

const test_meta = @import("test_meta.zig");
const test_result = @import("test_result.zig");

pub const RunSummary = struct {
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    ignored: usize = 0,

    pub fn record(self: *RunSummary, outcome: test_result.TestOutcome) void {
        switch (outcome) {
            .passed => self.passed += 1,
            .failed => self.failed += 1,
            .skipped => self.skipped += 1,
            .ignored => self.ignored += 1,
        }
    }

    pub fn executedCount(self: RunSummary) usize {
        return self.passed + self.failed + self.ignored;
    }
};

pub fn writeOutcome(
    stdout: anytype,
    stderr: anytype,
    test_case: test_meta.TestDescAndFn,
    outcome: test_result.TestOutcome,
) !void {
    switch (outcome) {
        .passed => try stdout.print("[PASS] {s}\n", .{test_case.displayName()}),
        .failed => |failure| {
            try stdout.print("[FAIL] {s}\n", .{failure.display_name});
            try test_result.writeFailure(stderr, failure);
        },
        .skipped, .ignored => {},
    }
}

pub fn writeSummary(stdout: anytype, summary: RunSummary) !void {
    try stdout.print("----\n", .{});
    try stdout.print("test result: ", .{});
    if (summary.failed == 0) {
        try stdout.print("ok. ", .{});
    } else {
        try stdout.print("FAILED. ", .{});
    }
    if (summary.ignored == 0) {
        try stdout.print(
            "{d} passed; {d} failed; {d} skipped\n",
            .{ summary.passed, summary.failed, summary.skipped },
        );
    } else {
        try stdout.print(
            "{d} passed; {d} failed; {d} skipped; {d} ignored\n",
            .{ summary.passed, summary.failed, summary.skipped, summary.ignored },
        );
    }
}

pub fn writeList(stdout: anytype, tests: []const test_meta.TestDescAndFn, selection: test_meta.TestSelection) !void {
    try stdout.writeAll("tests:\n");
    var count: usize = 0;
    for (tests) |test_case| {
        if (!selection.shouldRun(test_case)) continue;
        count += 1;

        try stdout.print("- {s}", .{test_case.displayName()});
        if (test_case.desc.ignored) try stdout.writeAll(" [ignored]");
        if (test_case.desc.should_panic) try stdout.writeAll(" [should_panic]");
        if (test_case.desc.source_file) |source_file| {
            try stdout.print(" ({s}", .{source_file});
            if (test_case.desc.line != 0) {
                try stdout.print(":{d}", .{test_case.desc.line});
                if (test_case.desc.col != 0) try stdout.print(":{d}", .{test_case.desc.col});
            }
            try stdout.writeByte(')');
        }
        try stdout.writeByte('\n');
    }
    try stdout.print("test count: {d}\n", .{count});
}

test "formatter writes stable summary text" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeSummary(&aw.writer, .{
        .passed = 2,
        .failed = 0,
        .skipped = 1,
        .ignored = 0,
    });

    try std.testing.expectEqualStrings("----\ntest result: ok. 2 passed; 0 failed; 1 skipped\n", aw.writer.buffered());
}

test "formatter lists selected tests with flags and locations" {
    const tests = [_]test_meta.TestDescAndFn{
        .{
            .desc = .{
                .id = 1,
                .name = "simple pass",
                .source_file = "tests/basic.sars",
                .line = 3,
                .col = 1,
                .ignored = false,
                .should_panic = false,
            },
            .testfn = .{ .selector_name = "_saasm_test_1" },
        },
        .{
            .desc = .{
                .id = 2,
                .name = "ignored panic",
                .source_file = "tests/basic.sars",
                .line = 9,
                .col = 1,
                .ignored = true,
                .should_panic = true,
            },
            .testfn = .{ .selector_name = "_saasm_test_2" },
        },
    };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeList(&aw.writer, tests[0..], .{ .ignored = .include });

    try std.testing.expect(std.mem.containsAtLeast(u8, aw.writer.buffered(), 1, "- simple pass (tests/basic.sa:3:1)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, aw.writer.buffered(), 1, "- ignored panic [ignored] [should_panic] (tests/basic.sa:9:1)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, aw.writer.buffered(), 1, "test count: 2"));
}

test "formatter writes failure output through test_result" {
    var out_aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out_aw.deinit();
    var err_aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_aw.deinit();

    try writeOutcome(&out_aw.writer, &err_aw.writer, .{
        .desc = .{
            .id = 1,
            .name = "panic path",
            .ignored = false,
            .should_panic = false,
        },
        .testfn = .{ .selector_name = "_saasm_test_1" },
    }, .{
        .failed = .{
            .display_name = "panic path",
            .reason = .{ .launch_failed = "ChildProcessFailed" },
            .stderr = "panic text",
        },
    });

    try std.testing.expect(std.mem.containsAtLeast(u8, out_aw.writer.buffered(), 1, "[FAIL] panic path"));
    try std.testing.expect(std.mem.containsAtLeast(u8, err_aw.writer.buffered(), 1, "failed to launch test panic path: ChildProcessFailed"));
    try std.testing.expect(std.mem.containsAtLeast(u8, err_aw.writer.buffered(), 1, "panic text"));
}

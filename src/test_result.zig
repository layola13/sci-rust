const std = @import("std");
const sio = @import("sio");

pub const Termination = union(enum) {
    exited: u32,
    signal: u32,
    stopped: u32,
    unknown: u32,
};

pub const FailureReason = union(enum) {
    exited: u32,
    signal: u32,
    stopped: u32,
    unknown: u32,
    did_not_panic,
    launch_failed: []const u8,
};

pub const AssertionFailure = struct {
    expected: []const u8,
    actual: []const u8,
};

pub const SourceLocation = struct {
    file: []const u8,
    line: u32 = 0,
    col: u32 = 0,
};

pub const PanicInfo = struct {
    code: u32,
    location: ?SourceLocation = null,
};

pub const TestFailure = struct {
    display_name: []const u8,
    reason: FailureReason,
    stderr: []const u8,
    assertion: ?AssertionFailure = null,
    location: ?SourceLocation = null,
    panic: ?PanicInfo = null,
    selector_name: ?[]const u8 = null,
    trace_panic: bool = false,
};

pub const TestOutcome = union(enum) {
    passed,
    failed: TestFailure,
    skipped,
    ignored,
};

pub fn terminationFrom(term: sio.Child.Term) Termination {
    return switch (term) {
        .exited => |code| .{ .exited = code },
        .signal => |sig| .{ .signal = @intFromEnum(sig) },
        .stopped => |sig| .{ .stopped = @intFromEnum(sig) },
        .unknown => |status| .{ .unknown = status },
    };
}

fn stderrHasPanic(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "PANIC:") != null or std.mem.indexOf(u8, stderr, "PANIC[") != null;
}

fn isAssertionValueSeparator(byte: u8) bool {
    return switch (byte) {
        ':', '=', ' ', '\t' => true,
        else => false,
    };
}

fn isAssertionValueTerminator(byte: u8) bool {
    return switch (byte) {
        ',', ';', '\n', '\r', ' ', '\t' => true,
        else => false,
    };
}

fn isAssertionLabelByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn valueAfterLabel(text: []const u8, comptime labels: []const []const u8) ?[]const u8 {
    for (labels) |label| {
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, text, search_start, label)) |label_index| {
            search_start = label_index + label.len;
            if (label_index != 0 and isAssertionLabelByte(text[label_index - 1])) continue;
            if (search_start < text.len and !isAssertionValueSeparator(text[search_start])) continue;

            var start = label_index + label.len;
            while (start < text.len and isAssertionValueSeparator(text[start])) : (start += 1) {}
            if (start >= text.len) continue;

            var end = start;
            while (end < text.len and !isAssertionValueTerminator(text[end])) : (end += 1) {}
            const value = std.mem.trim(u8, text[start..end], " \t\r\n,;.");
            if (value.len != 0) return value;
        }
    }
    return null;
}

pub fn parseAssertionFailure(stderr: []const u8) ?AssertionFailure {
    const expected = valueAfterLabel(stderr, &.{ "expected", "Expected" }) orelse return null;
    const actual = valueAfterLabel(stderr, &.{ "actual", "Actual", "got", "Got" }) orelse return null;
    return .{
        .expected = expected,
        .actual = actual,
    };
}

fn parseUnsignedPrefix(text: []const u8) ?u32 {
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(u32, text[0..end], 10) catch null;
}

fn parseSourceLocationPrefix(text: []const u8) ?SourceLocation {
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = text[0..line_end];
    const first_colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    if (first_colon == 0) return null;
    const line_start = first_colon + 1;
    const line_value = parseUnsignedPrefix(line[line_start..]) orelse return null;
    var after_line = line_start;
    while (after_line < line.len and std.ascii.isDigit(line[after_line])) : (after_line += 1) {}
    var col_value: u32 = 0;
    if (after_line < line.len and line[after_line] == ':') {
        const col_start = after_line + 1;
        if (parseUnsignedPrefix(line[col_start..])) |parsed_col| {
            col_value = parsed_col;
        }
    }
    return .{
        .file = line[0..first_colon],
        .line = line_value,
        .col = col_value,
    };
}

pub fn parsePanicInfo(stderr: []const u8) ?PanicInfo {
    if (std.mem.indexOf(u8, stderr, "PANIC[")) |start| {
        const code_start = start + "PANIC[".len;
        if (parseUnsignedPrefix(stderr[code_start..])) |code| {
            var location: ?SourceLocation = null;
            if (std.mem.indexOfPos(u8, stderr, code_start, "]: ")) |message_start| {
                location = parseSourceLocationPrefix(stderr[message_start + "]: ".len ..]);
            }
            return .{ .code = code, .location = location };
        }
    }
    if (std.mem.indexOf(u8, stderr, "PANIC: code=")) |start| {
        const code_start = start + "PANIC: code=".len;
        if (parseUnsignedPrefix(stderr[code_start..])) |code| return .{ .code = code };
    }
    return null;
}

pub fn toOutcome(display_name: []const u8, term: sio.Child.Term, stderr: []const u8, should_panic: bool) TestOutcome {
    const termination = terminationFrom(term);
    if (should_panic) {
        if (stderrHasPanic(stderr)) return .passed;
        return .{
            .failed = .{
                .display_name = display_name,
                .reason = .did_not_panic,
                .stderr = stderr,
                .assertion = parseAssertionFailure(stderr),
            },
        };
    }
    return switch (termination) {
        .exited => |code| if (code == 0) .passed else .{
            .failed = .{
                .display_name = display_name,
                .reason = .{ .exited = code },
                .stderr = stderr,
                .assertion = parseAssertionFailure(stderr),
            },
        },
        else => .{
            .failed = .{
                .display_name = display_name,
                .reason = switch (termination) {
                    .signal => |sig_num| .{ .signal = sig_num },
                    .stopped => |sig_num| .{ .stopped = sig_num },
                    .unknown => |status| .{ .unknown = status },
                    else => unreachable,
                },
                .stderr = stderr,
                .assertion = parseAssertionFailure(stderr),
            },
        },
    };
}

pub fn writeFailure(writer: anytype, failure: TestFailure) !void {
    switch (failure.reason) {
        .did_not_panic => try writer.print("error: test {s} did not panic as expected\n", .{failure.display_name}),
        .launch_failed => |err_name| try writer.print("error: failed to launch test {s}: {s}\n", .{ failure.display_name, err_name }),
        .exited => |code| try writer.print("error: test {s} exited with code {d}\n", .{ failure.display_name, code }),
        .signal => |sig_num| try writer.print("error: test {s} terminated by signal {d}\n", .{ failure.display_name, sig_num }),
        .stopped => |sig_num| try writer.print("error: test {s} stopped by signal {d}\n", .{ failure.display_name, sig_num }),
        .unknown => |status| try writer.print("error: test {s} terminated with status {d}\n", .{ failure.display_name, status }),
    }
    if (failure.location) |loc| {
        try writer.print("  test location: {s}", .{loc.file});
        if (loc.line != 0) {
            try writer.print(":{d}", .{loc.line});
            if (loc.col != 0) try writer.print(":{d}", .{loc.col});
        }
        try writer.writeByte('\n');
        if (failure.selector_name) |selector_name| {
            try writer.print("  code path: {s}::{s}\n", .{ loc.file, selector_name });
        }
    } else if (failure.selector_name) |selector_name| {
        try writer.print("  code path: {s}\n", .{selector_name});
    }
    if (failure.panic) |panic| {
        try writer.print("  panic: code={d}\n", .{panic.code});
        if (panic.location) |loc| {
            try writer.print("  panic location: {s}", .{loc.file});
            if (loc.line != 0) {
                try writer.print(":{d}", .{loc.line});
                if (loc.col != 0) try writer.print(":{d}", .{loc.col});
            }
            try writer.writeByte('\n');
        }
    }
    if (failure.trace_panic) {
        try writer.writeAll("  trace-panic: enabled\n");
    }
    if (failure.assertion) |assertion| {
        try writer.print(
            "assertion failed:\n  expected: {s}\n  actual: {s}\n",
            .{ assertion.expected, assertion.actual },
        );
    }
    if (failure.stderr.len != 0) {
        try writer.writeAll(failure.stderr);
        if (failure.stderr[failure.stderr.len - 1] != '\n') try writer.writeByte('\n');
    }
}

test "termination classification preserves process details" {
    const exited = terminationFrom(.{ .exited = 7 });
    try std.testing.expectEqual(@as(u32, 7), exited.exited);

    const signaled = terminationFrom(.{ .signal = @enumFromInt(6) });
    try std.testing.expectEqual(@as(u32, 6), signaled.signal);

    const stopped = terminationFrom(.{ .stopped = @enumFromInt(19) });
    try std.testing.expectEqual(@as(u32, 19), stopped.stopped);
}

test "failure formatting keeps the visible process reason" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeFailure(&aw.writer, .{
        .display_name = "signal abort",
        .reason = .{ .signal = 6 },
        .stderr = "panic text",
    });

    try std.testing.expect(std.mem.containsAtLeast(u8, aw.writer.buffered(), 1, "terminated by signal 6"));
    try std.testing.expect(std.mem.containsAtLeast(u8, aw.writer.buffered(), 1, "panic text"));
}

test "assertion panic text extracts expected and actual values" {
    const parsed = parseAssertionFailure("PANIC[103]: tests/assert_diag.sa:7: expected 7, got 3\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("7", parsed.expected);
    try std.testing.expectEqualStrings("3", parsed.actual);

    const keyed = parseAssertionFailure("PANIC[103]: expected=42 actual=41\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("42", keyed.expected);
    try std.testing.expectEqualStrings("41", keyed.actual);
}

test "panic text extracts numeric panic code" {
    const simple = parsePanicInfo("PANIC: code=99\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 99), simple.code);

    const message = parsePanicInfo("PANIC[103]: assert_values.sa:8:5: expected=42 actual=41\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 103), message.code);
    try std.testing.expectEqualStrings("assert_values.sars", message.location.?.file);
    try std.testing.expectEqual(@as(u32, 8), message.location.?.line);
    try std.testing.expectEqual(@as(u32, 5), message.location.?.col);
}

test "failure formatting surfaces assertion values before raw stderr" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeFailure(&aw.writer, .{
        .display_name = "assert eq diagnostic",
        .reason = .{ .exited = 231 },
        .stderr = "PANIC[103]: assert_values.sa:8:5: expected=42 actual=41",
        .assertion = .{
            .expected = "42",
            .actual = "41",
        },
        .location = .{ .file = "tests/assert_values.sars", .line = 4, .col = 1 },
        .panic = .{ .code = 103, .location = .{ .file = "assert_values.sars", .line = 8, .col = 5 } },
        .selector_name = "_saasm_test_1",
    });

    try std.testing.expect(std.mem.containsAtLeast(u8, aw.writer.buffered(), 1, "test location: tests/assert_values.sa:4:1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, aw.writer.buffered(), 1, "code path: tests/assert_values.sa::_saasm_test_1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, aw.writer.buffered(), 1, "panic: code=103"));
    try std.testing.expect(std.mem.containsAtLeast(u8, aw.writer.buffered(), 1, "panic location: assert_values.sa:8:5"));
    try std.testing.expect(std.mem.containsAtLeast(u8, aw.writer.buffered(), 1, "assertion failed:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, aw.writer.buffered(), 1, "expected: 42"));
    try std.testing.expect(std.mem.containsAtLeast(u8, aw.writer.buffered(), 1, "actual: 41"));
    try std.testing.expect(std.mem.containsAtLeast(u8, aw.writer.buffered(), 1, "PANIC[103]: assert_values.sa:8:5: expected=42 actual=41"));
}

test "should panic classification treats PANIC output as success" {
    const outcome = toOutcome("panic path", .{ .exited = 128 }, "PANIC: code=99\n", true);
    try std.testing.expect(outcome == .passed);
}

test "should panic classification fails if panic is missing" {
    const outcome = toOutcome("panic path", .{ .exited = 0 }, "", true);
    try std.testing.expect(outcome == .failed);
    switch (outcome) {
        .failed => |failure| {
            try std.testing.expect(failure.reason == .did_not_panic);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "launch failure formatting stays explicit" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeFailure(&aw.writer, .{
        .display_name = "panic path",
        .reason = .{ .launch_failed = "ChildProcessFailed" },
        .stderr = "",
    });

    try std.testing.expect(std.mem.containsAtLeast(u8, aw.writer.buffered(), 1, "failed to launch test panic path: ChildProcessFailed"));
}

const std = @import("std");

const sig = @import("common/signature.zig");

pub const TestDesc = struct {
    id: u32,
    name: []const u8,
    source_file: ?[]const u8 = null,
    line: u32 = 0,
    col: u32 = 0,
    ignored: bool = false,
    should_panic: bool = false,
};

pub const TestFn = struct {
    selector_name: []const u8,
};

pub const TestDescAndFn = struct {
    desc: TestDesc,
    testfn: TestFn,

    pub fn displayName(self: TestDescAndFn) []const u8 {
        return self.desc.name;
    }

    pub fn selectorName(self: TestDescAndFn) []const u8 {
        return self.testfn.selector_name;
    }

    pub fn deinit(self: *TestDescAndFn, allocator: std.mem.Allocator) void {
        if (self.desc.source_file) |file| allocator.free(file);
        allocator.free(self.desc.name);
        allocator.free(self.testfn.selector_name);
        self.* = undefined;
    }
};

pub const TestListOrder = enum {
    Sorted,
    Unsorted,
};

pub const TestList = struct {
    tests: []TestDescAndFn,
    order: TestListOrder,

    pub fn deinit(self: *TestList, allocator: std.mem.Allocator) void {
        for (self.tests) |*test_case| test_case.deinit(allocator);
        allocator.free(self.tests);
        self.* = undefined;
    }
};

pub const RunIgnored = enum {
    normal,
    only,
    include,
};

pub const TestSelection = struct {
    include_filters: []const []const u8 = &.{},
    skip_filters: []const []const u8 = &.{},
    exact: bool = false,
    ignored: RunIgnored = .normal,

    pub fn shouldRun(self: TestSelection, test_case: TestDescAndFn) bool {
        if (!self.matchesIgnored(test_case.desc.ignored)) return false;
        if (self.include_filters.len != 0 and !matchesAny(test_case.displayName(), self.include_filters, self.exact)) {
            return false;
        }
        if (self.skip_filters.len != 0 and matchesAny(test_case.displayName(), self.skip_filters, self.exact)) {
            return false;
        }
        return true;
    }

    pub fn countsTowardSummary(self: TestSelection, test_case: TestDescAndFn) bool {
        if (self.include_filters.len != 0 and !matchesAny(test_case.displayName(), self.include_filters, self.exact)) {
            return false;
        }
        if (self.skip_filters.len != 0 and matchesAny(test_case.displayName(), self.skip_filters, self.exact)) {
            return false;
        }
        return switch (self.ignored) {
            .normal, .include => true,
            .only => test_case.desc.ignored,
        };
    }

    pub fn countSelected(self: TestSelection, tests: []const TestDescAndFn) usize {
        var count: usize = 0;
        for (tests) |test_case| {
            if (self.shouldRun(test_case)) count += 1;
        }
        return count;
    }

    pub fn countTowardSummary(self: TestSelection, tests: []const TestDescAndFn) usize {
        var count: usize = 0;
        for (tests) |test_case| {
            if (self.countsTowardSummary(test_case)) count += 1;
        }
        return count;
    }

    fn matchesIgnored(self: TestSelection, ignored: bool) bool {
        return switch (self.ignored) {
            .normal => !ignored,
            .only => ignored,
            .include => true,
        };
    }
};

fn matchesPattern(text: []const u8, pattern: []const u8, exact: bool) bool {
    return if (exact) std.mem.eql(u8, text, pattern) else std.mem.indexOf(u8, text, pattern) != null;
}

fn matchesAny(text: []const u8, patterns: []const []const u8, exact: bool) bool {
    for (patterns) |pattern| {
        if (matchesPattern(text, pattern, exact)) return true;
    }
    return false;
}

fn freeTestItems(allocator: std.mem.Allocator, tests: []TestDescAndFn) void {
    for (tests) |test_case| {
        if (test_case.desc.source_file) |file| allocator.free(file);
        allocator.free(test_case.desc.name);
        allocator.free(test_case.testfn.selector_name);
    }
}

pub fn collect(allocator: std.mem.Allocator, function_sigs: []const sig.FunctionSig) !TestList {
    var tests = std.array_list.Managed(TestDescAndFn).init(allocator);
    errdefer {
        freeTestItems(allocator, tests.items);
        tests.deinit();
    }

    for (function_sigs) |function_sig| {
        if (function_sig.kind != .test_func) continue;

        const display_name = try allocator.dupe(u8, sig.displayName(function_sig.kind, function_sig.name));
        errdefer allocator.free(display_name);

        const selector_name = try allocator.dupe(u8, function_sig.llvm_name orelse function_sig.name);
        errdefer allocator.free(selector_name);

        var source_file: ?[]const u8 = null;
        var line: u32 = 0;
        var col: u32 = 0;
        if (function_sig.upstream_loc) |loc| {
            source_file = try allocator.dupe(u8, loc.file);
            errdefer if (source_file) |file| allocator.free(file);
            line = loc.line;
            col = loc.col;
        } else if (function_sig.upstream_file) |file| {
            source_file = try allocator.dupe(u8, file);
            errdefer if (source_file) |dup| allocator.free(dup);
        }

        try tests.append(.{
            .desc = .{
                .id = function_sig.id,
                .name = display_name,
                .source_file = source_file,
                .line = line,
                .col = col,
                .ignored = function_sig.ignored,
                .should_panic = function_sig.should_panic,
            },
            .testfn = .{ .selector_name = selector_name },
        });
    }

    return .{
        .tests = try tests.toOwnedSlice(),
        .order = .Unsorted,
    };
}

test "test selection applies exact and skip filters" {
    const tests = [_]TestDescAndFn{
        .{
            .desc = .{
                .id = 0,
                .name = "simple pass",
                .ignored = false,
                .should_panic = false,
            },
            .testfn = .{ .selector_name = "_saasm_test_0" },
        },
        .{
            .desc = .{
                .id = 1,
                .name = "another test",
                .ignored = false,
                .should_panic = false,
            },
            .testfn = .{ .selector_name = "_saasm_test_1" },
        },
        .{
            .desc = .{
                .id = 2,
                .name = "ignored case",
                .ignored = true,
                .should_panic = false,
            },
            .testfn = .{ .selector_name = "_saasm_test_2" },
        },
    };

    const exact = TestSelection{
        .include_filters = &.{ "simple pass" },
        .exact = true,
    };
    try std.testing.expect(exact.shouldRun(tests[0]));
    try std.testing.expect(!exact.shouldRun(tests[1]));

    const skip = TestSelection{
        .skip_filters = &.{ "another" },
    };
    try std.testing.expect(skip.shouldRun(tests[0]));
    try std.testing.expect(!skip.shouldRun(tests[1]));

    const ignored = TestSelection{
        .ignored = .only,
    };
    try std.testing.expect(!ignored.shouldRun(tests[0]));
    try std.testing.expect(ignored.shouldRun(tests[2]));
    try std.testing.expect(!ignored.countsTowardSummary(tests[0]));
    try std.testing.expect(ignored.countsTowardSummary(tests[2]));

    const include_ignored = TestSelection{
        .ignored = .include,
    };
    try std.testing.expect(include_ignored.shouldRun(tests[2]));
    try std.testing.expect(include_ignored.countsTowardSummary(tests[2]));
}

test "collect builds a standalone test list" {
    var sigs = [_]sig.FunctionSig{
        .{
            .id = 7,
            .name = try std.testing.allocator.dupe(u8, "\"simple pass\""),
            .params = try std.testing.allocator.alloc(sig.ParamSpec, 0),
            .kind = .test_func,
            .return_cap = null,
            .return_ty = .void,
            .return_fallible = false,
            .entry_inst_idx = 0,
            .is_ffi_wrapper = false,
            .upstream_file = try std.testing.allocator.dupe(u8, "tests/demo.sars"),
            .upstream_loc = null,
            .param_ids = &.{},
            .llvm_name = try std.testing.allocator.dupe(u8, "_saasm_test_7"),
        },
    };
    defer sigs[0].deinit(std.testing.allocator);

    var list = try collect(std.testing.allocator, sigs[0..]);
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), list.tests.len);
    try std.testing.expectEqualStrings("simple pass", list.tests[0].displayName());
    try std.testing.expectEqualStrings("_saasm_test_7", list.tests[0].selectorName());
    try std.testing.expectEqualStrings("tests/demo.sars", list.tests[0].desc.source_file.?);
}

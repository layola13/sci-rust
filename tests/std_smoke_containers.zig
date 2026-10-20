const std = @import("std");
const common = @import("std_smoke_common.zig");
const saasm = common.saasm;

fn flattenFixture(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !saasm.flattener.FlattenResult {
    return try saasm.flattener.flattenFile(allocator, path, source);
}

test "sa_std alloc helpers are concrete and verifiable" {
    const vec_layout = try common.readFileAlloc(std.testing.allocator, "sa_std/alloc/vec.sal");
    defer std.testing.allocator.free(vec_layout);
    try std.testing.expectEqualStrings(
        "#def Vec_SIZE = 24\n#def Vec_ptr  = +0\n#def Vec_cap  = +8\n#def Vec_len  = +16",
        vec_layout,
    );

    const vec_src = try common.readFileAlloc(std.testing.allocator, "sa_std/alloc/vec.sars");
    defer std.testing.allocator.free(vec_src);
    try std.testing.expect(!std.mem.containsAtLeast(u8, vec_src, 1, "inttoptr"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, vec_src, 1, "假定"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, vec_src, 1, "示例"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, vec_src, 1, "[DEBUG]"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, vec_src, 1, "sa_print_bytes"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_src, 1, "@import \"../num.sars\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_src, 1, "EXPAND NUM_U64_CHECKED_MUL bytes_ok, bytes, cap, elem_size"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_src, 1, "EXPAND NUM_U64_CHECKED_ADD next_cap_ok, next_cap, cap, cap"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_src, 1, "EXPAND NUM_U64_CHECKED_MUL shrink_new_bytes_ok, new_bytes, target_cap, elem_size"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_src, 1, "panic(1201)"));
    var vec_flat = try flattenFixture(std.testing.allocator, "sa_std/alloc/vec.sars", vec_src);
    defer vec_flat.deinit(std.testing.allocator);
    const vec_verified = try saasm.referee.verify(std.testing.allocator, vec_flat.instructions, vec_flat.const_decls);
    switch (vec_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 11);
        },
        .trap => |report| {
            std.debug.print("vec smoke verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }

    const vec_macro_layout = try common.readFileAlloc(std.testing.allocator, "sa_std/vec.sal");
    defer std.testing.allocator.free(vec_macro_layout);
    try std.testing.expectEqualStrings("#def Vec_data = +0\n", vec_macro_layout);

    const vec_macro_src = try common.readFileAlloc(std.testing.allocator, "sa_std/vec.sars");
    defer std.testing.allocator.free(vec_macro_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "@import \"alloc/vec.sars\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_AS_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_AS_SLICE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_GET_UNCHECKED"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_GET_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "EXPAND VEC_TRY_GET __vec_get_ok_%out_ptr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_GET_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_FRONT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_BACK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_FRONT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_FRONT_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_BACK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_BACK_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_PUSH"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_PUSH_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_FREE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_RESERVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_RESERVE_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_RESERVE_EXACT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_RESERVE_EXACT_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_IS_EMPTY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_CLEAR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRUNCATE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_POP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_POP_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_POP_IF_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_POP_IF_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_POP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_POP_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_WITH_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_WITH_CAPACITY_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_CONTAINS_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_STARTS_WITH_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_ENDS_WITH_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_STRIP_PREFIX_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_STRIP_SUFFIX_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRIM_PREFIX_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRIM_SUFFIX_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_SPLIT_AT_U64"));

    var vec_macro_error_ctx = saasm.flattener.ErrorContext{};
    var vec_macro_flat = saasm.flattener.flattenFileWithContext(std.testing.allocator, "sa_std/vec.sars", vec_macro_src, &vec_macro_error_ctx) catch |err| {
        const source_line = saasm.flattener.takeErrorSourceLine(&vec_macro_error_ctx) orelse 0;
        std.debug.print("vec macro flatten failed on line {d}: {s}\n", .{ source_line, @errorName(err) });
        return err;
    };
    defer vec_macro_flat.deinit(std.testing.allocator);
    try std.testing.expect(vec_macro_flat.instructions.len > 0);
    try std.testing.expect(vec_macro_flat.function_sigs.len >= 11);

    const vec_macro_verified = try saasm.referee.verify(std.testing.allocator, vec_macro_flat.instructions, vec_macro_flat.const_decls);
    switch (vec_macro_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 11);
            try std.testing.expect(owned.annotated.len > 0);
        },
        .trap => |report| {
            std.debug.print("vec macro verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }

    const vec_fixture = try common.readFileAlloc(std.testing.allocator, "tests/vec_fixture.sars");
    defer std.testing.allocator.free(vec_fixture);
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_fixture, 1, "EXPAND VEC_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_fixture, 1, "EXPAND VEC_TRY_POP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_fixture, 1, "EXPAND VEC_TRY_FRONT_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_fixture, 1, "EXPAND VEC_TRY_BACK_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_fixture, 1, "EXPAND VEC_RESERVE_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_fixture, 1, "EXPAND VEC_RESERVE_EXACT_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_fixture, 1, "EXPAND VEC_CONTAINS_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_fixture, 1, "EXPAND VEC_STARTS_WITH_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_fixture, 1, "EXPAND VEC_ENDS_WITH_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_fixture, 1, "EXPAND VEC_TRY_STRIP_PREFIX_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_fixture, 1, "EXPAND VEC_TRY_STRIP_SUFFIX_U64"));

    var vec_fixture_error_ctx = saasm.flattener.ErrorContext{};
    var vec_fixture_flat = saasm.flattener.flattenFileWithContext(std.testing.allocator, "tests/vec_fixture.sars", vec_fixture, &vec_fixture_error_ctx) catch |err| {
        const source_line = saasm.flattener.takeErrorSourceLine(&vec_fixture_error_ctx) orelse 0;
        std.debug.print("vec fixture flatten failed on line {d}: {s}\n", .{ source_line, @errorName(err) });
        return err;
    };
    defer vec_fixture_flat.deinit(std.testing.allocator);
    try std.testing.expect(vec_fixture_flat.instructions.len > 0);
    const vec_fixture_verified = try saasm.referee.verify(std.testing.allocator, vec_fixture_flat.instructions, vec_fixture_flat.const_decls);
    switch (vec_fixture_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 11);
        },
        .trap => |report| {
            std.debug.print("vec fixture verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }

    const string_src = try common.readFileAlloc(std.testing.allocator, "sa_std/alloc/string.sars");
    defer std.testing.allocator.free(string_src);
    try std.testing.expect(!std.mem.containsAtLeast(u8, string_src, 1, "inttoptr"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, string_src, 1, "假定"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, string_src, 1, "示例"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_src, 1, "[MACRO] STR_FROM_CONST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_src, 1, "EXPAND SLICE_NEW"));

    const string_macro_src = try common.readFileAlloc(std.testing.allocator, "sa_std/string.sars");
    defer std.testing.allocator.free(string_macro_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "@import \"fmt.sai\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_AS_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_AS_BYTES"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_IS_EMPTY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_CONTAINS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_CONTAINS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_STARTS_WITH"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_STARTS_WITH"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_ENDS_WITH"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_ENDS_WITH"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_TRY_STRIP_PREFIX"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_TRY_STRIP_PREFIX"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_TRY_STRIP_SUFFIX"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_TRY_STRIP_SUFFIX"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_TRIM_PREFIX"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_TRIM_PREFIX"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_TRIM_SUFFIX"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_TRIM_SUFFIX"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_TRY_SPLIT_AT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_TRY_SPLIT_AT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_CONCAT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "sa_fmt_buffer_data"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "sa_fmt_buffer_len"));

    const string_fixture =
        \\@import "sa_std/core/slice.sal"
        \\@import "sa_std/core/slice.sars"
        \\@import "sa_std/alloc/string.sars"
        \\
        \\@const WORD = utf8:"rust"
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    word = alloc Slice_SIZE
        \\    EXPAND STR_FROM_CONST word, WORD, 4
        \\    EXPAND SLICE_GET_LEN len, word
        \\    ok = eq len, 4
        \\    !len
        \\    !word
        \\    br ok -> L_OK, L_ERR
        \\
        \\L_OK:
        \\    !ok
        \\    return 0
        \\
        \\L_ERR:
        \\    !ok
        \\    return 1
    ;
    var string_flat = try flattenFixture(std.testing.allocator, "demos/rosetta/15_string_bytes/main.sars", string_fixture);
    defer string_flat.deinit(std.testing.allocator);
    const string_verified = try saasm.referee.verify(std.testing.allocator, string_flat.instructions, string_flat.const_decls);
    switch (string_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), owned.function_sigs.len);
        },
        .trap => |report| {
            std.debug.print("string smoke verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }

    const string_macro_fixture =
        \\@import "sa_std/string.sars"
        \\
        \\@const WORD = utf8:"rust"
        \\@const PREFIX = utf8:"ru"
        \\@const SUFFIX = utf8:"st"
        \\@const INFIX = utf8:"us"
        \\@const MISS = utf8:"zz"
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    EXPAND STR_FROM_PARTS word, &WORD, 4
        \\    EXPAND STR_FROM_PARTS prefix, &PREFIX, 2
        \\    EXPAND STR_FROM_PARTS suffix, &SUFFIX, 2
        \\    EXPAND STR_FROM_PARTS infix, &INFIX, 2
        \\    EXPAND STR_FROM_PARTS miss, &MISS, 2
        \\    EXPAND STR_EMPTY empty
        \\    EXPAND STRING_LEN len, word
        \\    EXPAND STR_CONTAINS contains_ok, word, infix
        \\    EXPAND STRING_CONTAINS contains_empty_ok, word, empty
        \\    EXPAND STRING_CONTAINS contains_miss, word, miss
        \\    EXPAND STR_STARTS_WITH starts_ok, word, prefix
        \\    EXPAND STRING_STARTS_WITH starts_miss, word, miss
        \\    EXPAND STR_ENDS_WITH ends_ok, word, suffix
        \\    EXPAND STRING_ENDS_WITH ends_miss, word, miss
        \\    EXPAND STR_TRY_STRIP_PREFIX strip_prefix_ok, strip_prefix_tail, word, prefix
        \\    EXPAND STRING_TRY_STRIP_SUFFIX strip_suffix_ok, strip_suffix_head, word, suffix
        \\    EXPAND STR_TRY_STRIP_PREFIX strip_prefix_miss_ok, strip_prefix_miss, word, miss
        \\    EXPAND STRING_TRY_STRIP_SUFFIX strip_suffix_miss_ok, strip_suffix_miss, word, miss
        \\    EXPAND STR_EQ strip_prefix_tail_eq, strip_prefix_tail, suffix
        \\    EXPAND STR_EQ strip_suffix_head_eq, strip_suffix_head, prefix
        \\    EXPAND STR_IS_EMPTY strip_prefix_miss_empty, strip_prefix_miss
        \\    EXPAND STR_IS_EMPTY strip_suffix_miss_empty, strip_suffix_miss
        \\    len_ok = eq len, 4
        \\    contains_match_ok = eq contains_ok, 1
        \\    contains_empty_match_ok = eq contains_empty_ok, 1
        \\    contains_miss_ok = eq contains_miss, 0
        \\    starts_match_ok = eq starts_ok, 1
        \\    starts_miss_ok = eq starts_miss, 0
        \\    ends_match_ok = eq ends_ok, 1
        \\    ends_miss_ok = eq ends_miss, 0
        \\    strip_prefix_flag_ok = eq strip_prefix_ok, 1
        \\    strip_suffix_flag_ok = eq strip_suffix_ok, 1
        \\    strip_prefix_miss_flag_ok = eq strip_prefix_miss_ok, 0
        \\    strip_suffix_miss_flag_ok = eq strip_suffix_miss_ok, 0
        \\    strip_prefix_tail_ok = eq strip_prefix_tail_eq, 1
        \\    strip_suffix_head_ok = eq strip_suffix_head_eq, 1
        \\    strip_prefix_miss_empty_ok = eq strip_prefix_miss_empty, 1
        \\    strip_suffix_miss_empty_ok = eq strip_suffix_miss_empty, 1
        \\    ok01 = and len_ok, contains_match_ok
        \\    ok02 = and ok01, contains_empty_match_ok
        \\    ok03 = and ok02, contains_miss_ok
        \\    ok04 = and ok03, starts_match_ok
        \\    ok05 = and ok04, starts_miss_ok
        \\    ok06 = and ok05, ends_match_ok
        \\    ok07 = and ok06, ends_miss_ok
        \\    ok08 = and ok07, strip_prefix_flag_ok
        \\    ok09 = and ok08, strip_suffix_flag_ok
        \\    ok10 = and ok09, strip_prefix_miss_flag_ok
        \\    ok11 = and ok10, strip_suffix_miss_flag_ok
        \\    ok12 = and ok11, strip_prefix_tail_ok
        \\    ok13 = and ok12, strip_suffix_head_ok
        \\    ok14 = and ok13, strip_prefix_miss_empty_ok
        \\    ok = and ok14, strip_suffix_miss_empty_ok
        \\    !len
        \\    !contains_ok
        \\    !contains_empty_ok
        \\    !contains_miss
        \\    !starts_ok
        \\    !starts_miss
        \\    !ends_ok
        \\    !ends_miss
        \\    !strip_prefix_ok
        \\    !strip_prefix_tail
        \\    !strip_suffix_ok
        \\    !strip_suffix_head
        \\    !strip_prefix_miss_ok
        \\    !strip_prefix_miss
        \\    !strip_suffix_miss_ok
        \\    !strip_suffix_miss
        \\    !strip_prefix_tail_eq
        \\    !strip_suffix_head_eq
        \\    !strip_prefix_miss_empty
        \\    !strip_suffix_miss_empty
        \\    !len_ok
        \\    !contains_match_ok
        \\    !contains_empty_match_ok
        \\    !contains_miss_ok
        \\    !starts_match_ok
        \\    !starts_miss_ok
        \\    !ends_match_ok
        \\    !ends_miss_ok
        \\    !strip_prefix_flag_ok
        \\    !strip_suffix_flag_ok
        \\    !strip_prefix_miss_flag_ok
        \\    !strip_suffix_miss_flag_ok
        \\    !strip_prefix_tail_ok
        \\    !strip_suffix_head_ok
        \\    !strip_prefix_miss_empty_ok
        \\    !strip_suffix_miss_empty_ok
        \\    !ok01
        \\    !ok02
        \\    !ok03
        \\    !ok04
        \\    !ok05
        \\    !ok06
        \\    !ok07
        \\    !ok08
        \\    !ok09
        \\    !ok10
        \\    !ok11
        \\    !ok12
        \\    !ok13
        \\    !ok14
        \\    !word
        \\    !prefix
        \\    !suffix
        \\    !infix
        \\    !miss
        \\    !empty
        \\    br ok -> L_OK, L_ERR
        \\
        \\L_OK:
        \\    !ok
        \\    return 0
        \\
        \\L_ERR:
        \\    !ok
        \\    return 1
    ;
    var string_macro_flat = try flattenFixture(std.testing.allocator, "tests/string_macro_fixture.sars", string_macro_fixture);
    defer string_macro_flat.deinit(std.testing.allocator);
    const string_macro_verified = try saasm.referee.verify(std.testing.allocator, string_macro_flat.instructions, string_macro_flat.const_decls);
    switch (string_macro_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 1);
            var saw_concat = false;
            for (owned.function_sigs) |sig| {
                if (std.mem.eql(u8, sig.name, "sa_string_concat")) saw_concat = true;
            }
            try std.testing.expect(saw_concat);
        },
        .trap => |report| {
            std.debug.print("string macro verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }
}

test "sa_std hashset helpers are concrete and verifiable" {
    const hashset_layout = try common.readFileAlloc(std.testing.allocator, "sa_std/hashset.sal");
    defer std.testing.allocator.free(hashset_layout);
    try std.testing.expectEqualStrings(
        "#def HashSet_SIZE = 32\n#def HashSet_slots = +0\n#def HashSet_cap = +8\n#def HashSet_len = +16\n#def HashSet_tombs = +24\n\n#def HashSetSlot_SIZE = 32\n#def HashSetSlot_hash = +0\n#def HashSetSlot_key = +8\n#def HashSetSlot_value = +16\n#def HashSetSlot_state = +24\n\n#def HashSet_INITIAL_CAP = 8\n#def HashSet_STATE_EMPTY = 0\n#def HashSet_STATE_FILLED = 1\n#def HashSet_STATE_TOMB = 2\n\n#def HashSet_VALUE_SENTINEL = 1\n",
        hashset_layout,
    );

    const collections_hashset = try common.readFileAlloc(std.testing.allocator, "sa_std/collections/hashset.sars");
    defer std.testing.allocator.free(collections_hashset);
    try std.testing.expect(std.mem.containsAtLeast(u8, collections_hashset, 1, "@import \"../hashset.sars\""));

    const hashset_src = try common.readFileAlloc(std.testing.allocator, "sa_std/hashset.sars");
    defer std.testing.allocator.free(hashset_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@import \"hashset.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@import \"hashmap.sars\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@import \"core/slice.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@import \"alloc/vec.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@import \"vec.sars\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@import \"num.sars\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "EXPAND NUM_U64_CHECKED_MUL __set_drain_bytes_ok_%out_vec"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_new"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_with_capacity"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_free"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_insert"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_contains"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_remove"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_len"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_capacity"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_reserve"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_shrink_to_fit"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_is_empty"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_clear"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_WITH_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_RESERVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_SHRINK_TO_FIT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_IS_EMPTY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_CLEAR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_INSERT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_CONTAINS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_REMOVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_DRAIN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_EXTRACT_IF"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_FREE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_LIT2"));

    var hashset_error_ctx = saasm.flattener.ErrorContext{};
    var hashset_flat = saasm.flattener.flattenFileWithContext(std.testing.allocator, "sa_std/hashset.sars", hashset_src, &hashset_error_ctx) catch |err| {
        const source_line = saasm.flattener.takeErrorSourceLine(&hashset_error_ctx) orelse 0;
        std.debug.print("hashset flatten failed on line {d}: {s}\n", .{ source_line, @errorName(err) });
        return err;
    };
    defer hashset_flat.deinit(std.testing.allocator);
    try std.testing.expect(hashset_flat.instructions.len > 0);
    try std.testing.expect(hashset_flat.function_sigs.len >= 20);

    const hashset_verified = try saasm.referee.verify(std.testing.allocator, hashset_flat.instructions, hashset_flat.const_decls);
    switch (hashset_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 20);
            try std.testing.expect(owned.annotated.len > 0);
        },
        .trap => |report| {
            std.debug.print("hashset smoke verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }

    const hashset_fixture = try common.readFileAlloc(std.testing.allocator, "tests/hashset_fixture.sars");
    defer std.testing.allocator.free(hashset_fixture);
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_fixture, 1, "EXPAND SET_WITH_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_fixture, 1, "EXPAND SET_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_fixture, 1, "EXPAND SET_RESERVE"));

    var hashset_fixture_error_ctx = saasm.flattener.ErrorContext{};
    var hashset_fixture_flat = saasm.flattener.flattenFileWithContext(std.testing.allocator, "tests/hashset_fixture.sars", hashset_fixture, &hashset_fixture_error_ctx) catch |err| {
        const source_line = saasm.flattener.takeErrorSourceLine(&hashset_fixture_error_ctx) orelse 0;
        std.debug.print("hashset fixture flatten failed on line {d}: {s}\n", .{ source_line, @errorName(err) });
        return err;
    };
    defer hashset_fixture_flat.deinit(std.testing.allocator);
    const hashset_fixture_verified = try saasm.referee.verify(std.testing.allocator, hashset_fixture_flat.instructions, hashset_fixture_flat.const_decls);
    switch (hashset_fixture_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 20);
        },
        .trap => |report| {
            std.debug.print("hashset fixture verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }
}

test "sa_std btree_set helpers are concrete and verifiable" {
    const btree_set_layout = try common.readFileAlloc(std.testing.allocator, "sa_std/btree_set.sal");
    defer std.testing.allocator.free(btree_set_layout);
    try std.testing.expectEqualStrings(
        "#def BTreeSet_SIZE = 24\n#def BTreeSet_entries = +0\n#def BTreeSet_cap = +8\n#def BTreeSet_len = +16\n\n#def BTreeSet_INITIAL_CAP = 8\n",
        btree_set_layout,
    );

    const collections_btree_set = try common.readFileAlloc(std.testing.allocator, "sa_std/collections/btree_set.sars");
    defer std.testing.allocator.free(collections_btree_set);
    try std.testing.expectEqualStrings("@import \"../btree_set.sars\"\n", collections_btree_set);

    const btree_set_src = try common.readFileAlloc(std.testing.allocator, "sa_std/btree_set.sars");
    defer std.testing.allocator.free(btree_set_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@import \"btree_set.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@import \"btree_map.sars\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_new"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_free"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_len"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_is_empty"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_contains"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_get"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_first"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_last"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_take"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_replace"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_pop_first"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_pop_last"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_is_subset"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_is_superset"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_is_disjoint"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_append"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_split_off"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_clear"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_insert"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_remove"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_FREE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_IS_EMPTY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_CONTAINS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_FIRST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_LAST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_CLEAR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_INSERT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_REMOVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_TAKE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_REPLACE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_POP_FIRST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_POP_LAST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_IS_DISJOINT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_IS_SUBSET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_IS_SUPERSET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_APPEND"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_SPLIT_OFF"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_LIT2"));

    const btree_map_src = try common.readFileAlloc(std.testing.allocator, "sa_std/btree_map.sars");
    defer std.testing.allocator.free(btree_map_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_map_src, 1, "@import \"num.sars\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_map_src, 1, "EXPAND NUM_U64_CHECKED_ADD next_cap_ok, next_cap, old_cap, old_cap"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_map_src, 1, "EXPAND NUM_U64_CHECKED_MUL new_bytes_ok, new_bytes, next_cap, BTreeMapEntry_SIZE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_map_src, 1, "EXPAND NUM_U64_CHECKED_MUL clear_bytes_ok, bytes, cap, BTreeMapEntry_SIZE"));

    const hashmap_src = try common.readFileAlloc(std.testing.allocator, "sa_std/hashmap.sars");
    defer std.testing.allocator.free(hashmap_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@import \"core/slice.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@import \"alloc/vec.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@import \"vec.sars\""));

    var btree_set_error_ctx = saasm.flattener.ErrorContext{};
    var btree_set_flat = saasm.flattener.flattenFileWithContext(std.testing.allocator, "sa_std/btree_set.sars", btree_set_src, &btree_set_error_ctx) catch |err| {
        const source_line = saasm.flattener.takeErrorSourceLine(&btree_set_error_ctx) orelse 0;
        std.debug.print("btree_set flatten failed on line {d}: {s}\n", .{ source_line, @errorName(err) });
        return err;
    };
    defer btree_set_flat.deinit(std.testing.allocator);
    try std.testing.expect(btree_set_flat.instructions.len > 0);
    try std.testing.expect(btree_set_flat.function_sigs.len >= 47);

    const btree_set_verified = try saasm.referee.verify(std.testing.allocator, btree_set_flat.instructions, btree_set_flat.const_decls);
    switch (btree_set_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 47);
            try std.testing.expect(owned.annotated.len > 0);
        },
        .trap => |report| {
            std.debug.print("btree_set smoke verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }

    const btree_set_fixture =
        \\@import "sa_std/core/slice.sal"
        \\@import "sa_std/core/slice.sars"
        \\@import "sa_std/collections/btree_set.sars"
        \\
        \\@const KEY_ALPHA = utf8:"alpha"
        \\@const KEY_BRAVO = utf8:"bravo"
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    set = 0 as ptr
        \\    alpha = alloc Slice_SIZE
        \\    bravo = alloc Slice_SIZE
        \\    lookup = alloc Slice_SIZE
        \\    EXPAND SLICE_NEW alpha, &KEY_ALPHA, 5
        \\    EXPAND SLICE_NEW bravo, &KEY_BRAVO, 5
        \\    EXPAND SLICE_NEW lookup, &KEY_ALPHA, 5
        \\    EXPAND BTREE_SET_NEW set
        \\    EXPAND BTREE_SET_IS_EMPTY empty0, set
        \\    EXPAND BTREE_SET_INSERT insert_alpha, set, alpha
        \\    EXPAND BTREE_SET_INSERT insert_alpha_again, set, lookup
        \\    EXPAND BTREE_SET_INSERT insert_bravo, set, bravo
        \\    EXPAND BTREE_SET_CONTAINS has_alpha, set, alpha
        \\    EXPAND BTREE_SET_CONTAINS has_lookup, set, lookup
        \\    EXPAND BTREE_SET_REMOVE removed_alpha, set, alpha
        \\    EXPAND BTREE_SET_CONTAINS has_alpha_after, set, alpha
        \\    EXPAND BTREE_SET_LEN len, set
        \\    EXPAND BTREE_SET_CLEAR set
        \\    EXPAND BTREE_SET_IS_EMPTY empty1, set
        \\    ok_empty0 = eq empty0, 1
        \\    ok_insert_alpha = eq insert_alpha, 1
        \\    ok_insert_alpha_again = eq insert_alpha_again, 0
        \\    ok_insert_bravo = eq insert_bravo, 1
        \\    ok_has_alpha = eq has_alpha, 1
        \\    ok_has_lookup = eq has_lookup, 1
        \\    ok_removed_alpha = eq removed_alpha, 1
        \\    ok_has_alpha_after = eq has_alpha_after, 0
        \\    ok_len = eq len, 1
        \\    ok_empty1 = eq empty1, 1
        \\    ok01 = and ok_empty0, ok_insert_alpha
        \\    ok02 = and ok01, ok_insert_alpha_again
        \\    ok03 = and ok02, ok_insert_bravo
        \\    ok04 = and ok03, ok_has_alpha
        \\    ok05 = and ok04, ok_has_lookup
        \\    ok06 = and ok05, ok_removed_alpha
        \\    ok07 = and ok06, ok_has_alpha_after
        \\    ok08 = and ok07, ok_len
        \\    ok = and ok08, ok_empty1
        \\    !empty0
        \\    !insert_alpha
        \\    !insert_alpha_again
        \\    !insert_bravo
        \\    !has_alpha
        \\    !has_lookup
        \\    !removed_alpha
        \\    !has_alpha_after
        \\    !len
        \\    !empty1
        \\    !ok_empty0
        \\    !ok_insert_alpha
        \\    !ok_insert_alpha_again
        \\    !ok_insert_bravo
        \\    !ok_has_alpha
        \\    !ok_has_lookup
        \\    !ok_removed_alpha
        \\    !ok_has_alpha_after
        \\    !ok_len
        \\    !ok_empty1
        \\    !ok01
        \\    !ok02
        \\    !ok03
        \\    !ok04
        \\    !ok05
        \\    !ok06
        \\    !ok07
        \\    !ok08
        \\    !lookup
        \\    !bravo
        \\    !alpha
        \\    EXPAND BTREE_SET_FREE set
        \\    br ok -> L_OK, L_ERR
        \\
        \\L_OK:
        \\    !ok
        \\    return 0
        \\
        \\L_ERR:
        \\    !ok
        \\    return 1
    ;
    var btree_set_fixture_flat = try flattenFixture(std.testing.allocator, "tests/btree_set_fixture.sars", btree_set_fixture);
    defer btree_set_fixture_flat.deinit(std.testing.allocator);
    const btree_set_fixture_verified = try saasm.referee.verify(std.testing.allocator, btree_set_fixture_flat.instructions, btree_set_fixture_flat.const_decls);
    switch (btree_set_fixture_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 48);
        },
        .trap => |report| {
            std.debug.print("btree_set fixture verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }
}

test "sa_std deque and binary heap capacity arithmetic is checked" {
    const deque_src = try common.readFileAlloc(std.testing.allocator, "sa_std/vec_deque.sars");
    defer std.testing.allocator.free(deque_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@import \"alloc/vec.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@import \"num.sars\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "EXPAND NUM_U64_CHECKED_MUL with_cap_bytes_ok, bytes, capacity, VecDeque_SLOT_SIZE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "EXPAND NUM_U64_CHECKED_ADD next_cap_ok, next_cap, cap, cap"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "EXPAND NUM_U64_CHECKED_ADD reserve_needed_ok, needed, len, additional"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "EXPAND NUM_U64_CHECKED_MUL clear_bytes_ok, bytes, cap, VecDeque_SLOT_SIZE"));

    var deque_flat = try flattenFixture(std.testing.allocator, "sa_std/vec_deque.sars", deque_src);
    defer deque_flat.deinit(std.testing.allocator);
    try std.testing.expect(deque_flat.instructions.len > 0);
    const deque_verified = try saasm.referee.verify(std.testing.allocator, deque_flat.instructions, deque_flat.const_decls);
    switch (deque_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 20);
        },
        .trap => |report| {
            std.debug.print("vec_deque smoke verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }

    const heap_src = try common.readFileAlloc(std.testing.allocator, "sa_std/binary_heap.sars");
    defer std.testing.allocator.free(heap_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@import \"num.sars\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "EXPAND NUM_U64_CHECKED_ADD next_cap_ok, next_cap, cap, cap"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "EXPAND NUM_U64_CHECKED_MUL bytes_ok, bytes, target_cap, BinaryHeap_SLOT_SIZE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "EXPAND NUM_U64_CHECKED_ADD reserve_needed_ok, needed, len, additional"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "EXPAND NUM_U64_CHECKED_MUL new_bytes_ok, new_bytes, next_cap, BinaryHeap_SLOT_SIZE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "EXPAND NUM_U64_CHECKED_MUL clear_bytes_ok, bytes, cap, BinaryHeap_SLOT_SIZE"));

    var heap_flat = try flattenFixture(std.testing.allocator, "sa_std/binary_heap.sars", heap_src);
    defer heap_flat.deinit(std.testing.allocator);
    try std.testing.expect(heap_flat.instructions.len > 0);
    const heap_verified = try saasm.referee.verify(std.testing.allocator, heap_flat.instructions, heap_flat.const_decls);
    switch (heap_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 20);
        },
        .trap => |report| {
            std.debug.print("binary_heap smoke verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }
}

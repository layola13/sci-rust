const std = @import("std");
const saasm = @import("saasm");
const sio = @import("sio");

fn repoRoot(allocator: std.mem.Allocator) ![]u8 {
    return sio.cwd().realpathAlloc(allocator, ".");
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try sio.cwd().openFile(path, .{});
    defer file.close(std.testing.io);
    return try sio.readToEndAlloc(file, allocator, 1 << 20);
}

fn writeSource(dir: std.Io.Dir, path: []const u8, source: []const u8) !void {
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    var wbuf: [8192]u8 = undefined;
    var w = file.writer(std.testing.io, &wbuf);
    try w.interface.writeAll(source);
    try w.interface.flush();
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !sio.Child.RunResult {
    return try sio.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
}

fn runCommandWithEnvMap(allocator: std.mem.Allocator, argv: []const []const u8, env_map: *const sio.EnvMap) !sio.Child.RunResult {
    return try sio.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .env_map = env_map,
    });
}

fn runCommandAnyExit(allocator: std.mem.Allocator, argv: []const []const u8) !sio.Child.RunResult {
    return try sio.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
}

const NormalizedInstruction = struct {
    kind: saasm.common.instruction.InstKind,
    op_kind: ?saasm.common.instruction.OpKind,
    operands: [4]saasm.common.instruction.Operand,
    raw_text: []const u8,
    atomic_value_ty: ?u32,
    atomic_ordering: ?saasm.common.instruction.AtomicOrdering,
    atomic_second_ordering: ?saasm.common.instruction.AtomicOrdering,
    atomic_rmw_op: ?saasm.common.instruction.AtomicRmwOp,
    atomic_expected_text: ?[]const u8,
    atomic_new_text: ?[]const u8,
    native_reg_names: []const []const u8,
};

fn normalizeInstruction(inst: saasm.flattener.Instruction) NormalizedInstruction {
    return .{
        .kind = inst.kind,
        .op_kind = inst.op_kind,
        .operands = inst.operands,
        .raw_text = inst.raw_text,
        .atomic_value_ty = inst.atomic_value_ty,
        .atomic_ordering = inst.atomic_ordering,
        .atomic_second_ordering = inst.atomic_second_ordering,
        .atomic_rmw_op = inst.atomic_rmw_op,
        .atomic_expected_text = inst.atomic_expected_text,
        .atomic_new_text = inst.atomic_new_text,
        .native_reg_names = inst.native_reg_names,
    };
}

fn expectFlattenEquivalent(lhs: saasm.flattener.FlattenResult, rhs: saasm.flattener.FlattenResult) !void {
    try std.testing.expectEqual(lhs.instructions.len, rhs.instructions.len);
    try std.testing.expectEqual(lhs.function_sigs.len, rhs.function_sigs.len);
    try std.testing.expectEqual(lhs.const_decls.len, rhs.const_decls.len);
    try std.testing.expectEqual(lhs.loc_table.len, rhs.loc_table.len);
    for (lhs.instructions, rhs.instructions, 0..) |l, r, idx| {
        const ln = normalizeInstruction(l);
        const rn = normalizeInstruction(r);
        try std.testing.expectEqual(ln.kind, rn.kind);
        try std.testing.expectEqual(ln.op_kind, rn.op_kind);
        try std.testing.expectEqualDeep(ln.operands, rn.operands);
        try std.testing.expectEqualStrings(ln.raw_text, rn.raw_text);
        try std.testing.expectEqual(ln.atomic_value_ty, rn.atomic_value_ty);
        try std.testing.expectEqual(ln.atomic_ordering, rn.atomic_ordering);
        try std.testing.expectEqual(ln.atomic_second_ordering, rn.atomic_second_ordering);
        try std.testing.expectEqual(ln.atomic_rmw_op, rn.atomic_rmw_op);
        try std.testing.expectEqual(ln.atomic_expected_text, rn.atomic_expected_text);
        try std.testing.expectEqual(ln.atomic_new_text, rn.atomic_new_text);
        try std.testing.expectEqualDeep(ln.native_reg_names, rn.native_reg_names);
        _ = idx;
    }
}

fn dumpInstructionTexts(prefix: []const u8, flat: saasm.flattener.FlattenResult) void {
    std.debug.print("{s} ({d} instructions)\n", .{ prefix, flat.instructions.len });
    for (flat.instructions, 0..) |item, idx| {
        std.debug.print("  [{d}] {s}\n", .{ idx, item.raw_text });
    }
}

test "sa_std core primitives are concrete and verifiable" {
    const slice_layout = try readFileAlloc(std.testing.allocator, "sa_std/core/slice.sal");
    defer std.testing.allocator.free(slice_layout);
    try std.testing.expectEqualStrings(
        "#def Slice_SIZE = 16\n#def Slice_ptr  = +0\n#def Slice_len  = +8\n",
        slice_layout,
    );

    const slice_src = try readFileAlloc(std.testing.allocator, "sa_std/core/slice.sa");
    defer std.testing.allocator.free(slice_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_GET_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_AS_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_GET_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_IS_EMPTY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_GET_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_GET_MUT_PTR_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_FIRST_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_FIRST_MUT_PTR_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_FIRST_MUT_PTR_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_LAST_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_LAST_MUT_PTR_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_LAST_MUT_PTR_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_SPLIT_FIRST_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_SPLIT_LAST_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_GET_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_GET_MUT_PTR_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRIM_PREFIX_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRIM_SUFFIX_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_SPLIT_AT_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_SPLIT_AT_MUT_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_RANGE_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_GET_RANGE_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_SWAP_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_SWAP_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_CLONE_FROM_SLICE_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_COPY_WITHIN_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_BINARY_SEARCH_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_PARTITION_POINT_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_LOWER_BOUND_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_UPPER_BOUND_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_EQUAL_RANGE_U64"));

    var slice_flat = try saasm.flattener.flatten(std.testing.allocator, slice_src);
    defer slice_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), slice_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), slice_flat.function_sigs.len);

    const slice_fixture =
        \\@import "sa_std/core/slice.sal"
        \\@import "sa_std/core/slice.sa"
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    data = alloc 24
        \\    store data+0, 11 as u64
        \\    store data+8, 22 as u64
        \\    store data+16, 33 as u64
        \\    slice = alloc Slice_SIZE
        \\    EXPAND SLICE_NEW slice, data, 3
        \\    EXPAND SLICE_AS_PTR ptr, slice
        \\    EXPAND SLICE_IS_EMPTY empty, slice
        \\    EXPAND SLICE_FIRST_U64 first, slice
        \\    EXPAND SLICE_LAST_U64 last, slice
        \\    EXPAND SLICE_TRY_GET_U64 hit_ok, hit, slice, 1
        \\    EXPAND SLICE_TRY_GET_U64 miss_ok, miss, slice, 9
        \\    ptr_ok = ne ptr, 0
        \\    empty_ok = eq empty, 0
        \\    first_ok = eq first, 11
        \\    last_ok = eq last, 33
        \\    hit_flag_ok = eq hit_ok, 1
        \\    hit_value_ok = eq hit, 22
        \\    miss_flag_ok = eq miss_ok, 0
        \\    miss_value_ok = eq miss, 0
        \\    ok01 = and ptr_ok, empty_ok
        \\    ok02 = and ok01, first_ok
        \\    ok03 = and ok02, last_ok
        \\    ok04 = and ok03, hit_flag_ok
        \\    ok05 = and ok04, hit_value_ok
        \\    ok06 = and ok05, miss_flag_ok
        \\    ok = and ok06, miss_value_ok
        \\    !ptr
        \\    !empty
        \\    !first
        \\    !last
        \\    !hit_ok
        \\    !hit
        \\    !miss_ok
        \\    !miss
        \\    !ptr_ok
        \\    !empty_ok
        \\    !first_ok
        \\    !last_ok
        \\    !hit_flag_ok
        \\    !hit_value_ok
        \\    !miss_flag_ok
        \\    !miss_value_ok
        \\    !ok01
        \\    !ok02
        \\    !ok03
        \\    !ok04
        \\    !ok05
        \\    !ok06
        \\    !slice
        \\    !data
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
    var slice_fixture_flat = try flattenFixture(std.testing.allocator, "tests/slice_fixture.sa", slice_fixture);
    defer slice_fixture_flat.deinit(std.testing.allocator);
    const slice_fixture_verified = try saasm.referee.verify(std.testing.allocator, slice_fixture_flat.instructions, slice_fixture_flat.const_decls);
    switch (slice_fixture_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), owned.function_sigs.len);
        },
        .trap => |report| {
            std.debug.print("slice fixture verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }

    const mem_src = try readFileAlloc(std.testing.allocator, "sa_std/core/mem.sa");
    defer std.testing.allocator.free(mem_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, mem_src, 1, "@export sa_mem_copy"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mem_src, 1, "@export sa_mem_set"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mem_src, 1, "panic(1701)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mem_src, 1, "panic(1702)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mem_src, 1, "panic(1703)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mem_src, 1, "[MACRO] BOX_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mem_src, 1, "[MACRO] BOX_FREE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mem_src, 1, "ptr_add"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mem_src, 1, "br done -> L_END, L_BODY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mem_src, 1, "stack_alloc 8"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mem_src, 1, "store offset_slot+0, 0 as u64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mem_src, 1, "store remaining_slot+0, count as u64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mem_src, 1, "next_remaining = sub remaining, one"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, mem_src, 1, "inttoptr"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, mem_src, 1, "i = 0"));

    var mem_flat = try saasm.flattener.flatten(std.testing.allocator, mem_src);
    defer mem_flat.deinit(std.testing.allocator);
    const verified = try saasm.referee.verify(std.testing.allocator, mem_flat.instructions, mem_flat.const_decls);
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 2), owned.function_sigs.len);
            try std.testing.expect(owned.annotated.len > 0);
        },
        .trap => |report| {
            std.debug.print("std smoke verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }
}

test "sa_std rust core helpers are concrete and verifiable" {
    const option_layout = try readFileAlloc(std.testing.allocator, "sa_std/core/option.sal");
    defer std.testing.allocator.free(option_layout);
    try std.testing.expectEqualStrings(
        "#def Option_SIZE = 16\n#def Option_tag = +0\n#def Option_value = +8\n#def Option_NONE = 0\n#def Option_SOME = 1\n",
        option_layout,
    );

    const result_layout = try readFileAlloc(std.testing.allocator, "sa_std/core/result.sal");
    defer std.testing.allocator.free(result_layout);
    try std.testing.expectEqualStrings(
        "#def Result_SIZE = 24\n#def Result_tag = +0\n#def Result_ok = +8\n#def Result_err = +16\n#def Result_OK = 0\n#def Result_ERR = 1\n",
        result_layout,
    );

    const iter_layout = try readFileAlloc(std.testing.allocator, "sa_std/core/iter.sal");
    defer std.testing.allocator.free(iter_layout);
    try std.testing.expectEqualStrings(
        "#def Iter_SIZE = 24\n#def Iter_ptr = +0\n#def Iter_len = +8\n#def Iter_index = +16\n",
        iter_layout,
    );

    const option_src = try readFileAlloc(std.testing.allocator, "sa_std/core/option.sa");
    defer std.testing.allocator.free(option_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_NEW_NONE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_NEW_SOME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_IS_SOME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_IS_NONE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_UNWRAP_OR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_UNWRAP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_MAP_OR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_MAP_OR_ELSE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_SET_NONE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_SET_SOME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_BRANCH"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] MATCHES_OPTION"));

    const result_src = try readFileAlloc(std.testing.allocator, "sa_std/core/result.sa");
    defer std.testing.allocator.free(result_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_NEW_OK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_NEW_ERR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_IS_OK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_IS_ERR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_GET_OK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_GET_ERR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_UNWRAP_OR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_UNWRAP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_UNWRAP_ERR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_MAP_OR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_MAP_OR_ELSE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_SET_OK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_SET_ERR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_BRANCH"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] MATCH_RESULT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] MATCHES_RESULT"));

    const stringify_src = try readFileAlloc(std.testing.allocator, "src/flattener.zig");
    defer std.testing.allocator.free(stringify_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, stringify_src, 1, "STRINGIFY!"));

    const panic_src = try readFileAlloc(std.testing.allocator, "sa_std/core/panic.sa");
    defer std.testing.allocator.free(panic_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, panic_src, 1, "[MACRO] PANIC "));
    try std.testing.expect(std.mem.containsAtLeast(u8, panic_src, 1, "[MACRO] PANIC_MSG"));
    try std.testing.expect(std.mem.containsAtLeast(u8, panic_src, 1, "[MACRO] TODO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, panic_src, 1, "[MACRO] UNIMPLEMENTED"));
    try std.testing.expect(std.mem.containsAtLeast(u8, panic_src, 1, "[MACRO] UNREACHABLE"));

    const iter_src = try readFileAlloc(std.testing.allocator, "sa_std/core/iter.sa");
    defer std.testing.allocator.free(iter_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, iter_src, 1, "[MACRO] ITER_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, iter_src, 1, "[MACRO] ITER_FROM_SLICE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, iter_src, 1, "[MACRO] ITER_IS_EMPTY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, iter_src, 1, "[MACRO] ITER_HAS_NEXT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, iter_src, 1, "[MACRO] ITER_REMAINING"));
    try std.testing.expect(std.mem.containsAtLeast(u8, iter_src, 1, "[MACRO] ITER_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, iter_src, 1, "[MACRO] ITER_PEEK_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, iter_src, 1, "[MACRO] ITER_NEXT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, iter_src, 1, "[MACRO] ITER_NEXT_U64"));

    const rust_core_src = try readFileAlloc(std.testing.allocator, "sa_std/rust_core.sa");
    defer std.testing.allocator.free(rust_core_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/option.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/result.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/panic.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/iter.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/cell.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/refcell.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/rc.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/weak.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/derive.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "[MACRO] DROP_AND_RETURN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/box.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/dispatch.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/arc.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/future.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/task.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/ascii.sa\""));

    const arc_src = try readFileAlloc(std.testing.allocator, "sa_std/core/arc.sa");
    defer std.testing.allocator.free(arc_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, arc_src, 1, "@import \"../num.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, arc_src, 1, "NUM_U64_MAX"));
    try std.testing.expect(std.mem.containsAtLeast(u8, arc_src, 1, "panic(1501)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, arc_src, 1, "panic(1505)"));

    const ascii_layout = try readFileAlloc(std.testing.allocator, "sa_std/core/ascii.sal");
    defer std.testing.allocator.free(ascii_layout);
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_layout, 1, "#def ASCII_CASE_MASK = 32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_layout, 1, "#def ASCII_MAX = 127"));

    const ascii_src = try readFileAlloc(std.testing.allocator, "sa_std/core/ascii.sa");
    defer std.testing.allocator.free(ascii_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_src, 1, "[MACRO] ASCII_IS_ASCII"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_src, 1, "[MACRO] ASCII_IS_ALPHABETIC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_src, 1, "[MACRO] ASCII_IS_ALPHANUMERIC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_src, 1, "[MACRO] ASCII_IS_DIGIT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_src, 1, "[MACRO] ASCII_IS_OCTDIGIT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_src, 1, "[MACRO] ASCII_IS_HEXDIGIT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_src, 1, "[MACRO] ASCII_IS_PUNCTUATION"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_src, 1, "[MACRO] ASCII_IS_GRAPHIC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_src, 1, "[MACRO] ASCII_IS_WHITESPACE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_src, 1, "[MACRO] ASCII_IS_CONTROL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_src, 1, "[MACRO] ASCII_TO_UPPERCASE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_src, 1, "[MACRO] ASCII_TO_LOWERCASE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_src, 1, "[MACRO] ASCII_EQ_IGNORE_CASE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_src, 1, "[MACRO] ASCII_SLICE_MAKE_UPPERCASE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_src, 1, "[MACRO] ASCII_SLICE_MAKE_LOWERCASE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_src, 1, "[MACRO] ASCII_SLICE_EQ_IGNORE_CASE"));

    const ascii_facade_src = try readFileAlloc(std.testing.allocator, "sa_std/ascii.sa");
    defer std.testing.allocator.free(ascii_facade_src);
    try std.testing.expectEqualStrings("@import \"core/ascii.sal\"\n@import \"core/ascii.sa\"\n", ascii_facade_src);

    const cell_layout = try readFileAlloc(std.testing.allocator, "sa_std/core/cell.sal");
    defer std.testing.allocator.free(cell_layout);
    try std.testing.expectEqualStrings("#def Cell_SIZE = 4\n#def Cell_value = +0\n", cell_layout);

    const refcell_layout = try readFileAlloc(std.testing.allocator, "sa_std/core/refcell.sal");
    defer std.testing.allocator.free(refcell_layout);
    try std.testing.expectEqualStrings("#def RefCell_SIZE = 8\n#def RefCell_value = +0\n#def RefCell_borrows = +4\n", refcell_layout);

    const future_layout = try readFileAlloc(std.testing.allocator, "sa_std/core/future.sal");
    defer std.testing.allocator.free(future_layout);
    try std.testing.expect(std.mem.containsAtLeast(u8, future_layout, 1, "#def Poll_SIZE = 16"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_layout, 1, "#def Context_SIZE = 16"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_layout, 1, "#def Future_SIZE = 16"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_layout, 1, "#def FuturePollSlot = +0"));

    const task_layout = try readFileAlloc(std.testing.allocator, "sa_std/core/task.sal");
    defer std.testing.allocator.free(task_layout);
    try std.testing.expect(std.mem.containsAtLeast(u8, task_layout, 1, "#def Task_SIZE = 32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, task_layout, 1, "#def Executor_SIZE = 16"));

    const rc_layout = try readFileAlloc(std.testing.allocator, "sa_std/core/rc.sal");
    defer std.testing.allocator.free(rc_layout);
    try std.testing.expectEqualStrings("#def RcBox_SIZE = 24\n#def RcBox_strong = +0\n#def RcBox_weak = +8\n#def RcBox_data = +16\n", rc_layout);

    const weak_layout = try readFileAlloc(std.testing.allocator, "sa_std/core/weak.sal");
    defer std.testing.allocator.free(weak_layout);
    try std.testing.expectEqualStrings("#def WeakBox_SIZE = 24\n#def WeakBox_strong = +0\n#def WeakBox_weak = +8\n#def WeakBox_data = +16\n", weak_layout);

    const cell_src = try readFileAlloc(std.testing.allocator, "sa_std/core/cell.sa");
    defer std.testing.allocator.free(cell_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, cell_src, 1, "[MACRO] CELL_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, cell_src, 1, "[MACRO] CELL_SET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, cell_src, 1, "[MACRO] CELL_REPLACE"));

    const refcell_src = try readFileAlloc(std.testing.allocator, "sa_std/core/refcell.sa");
    defer std.testing.allocator.free(refcell_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, refcell_src, 1, "[MACRO] REFCELL_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, refcell_src, 1, "[MACRO] REFCELL_BORROW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, refcell_src, 1, "[MACRO] REFCELL_BORROW_MUT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, refcell_src, 1, "[MACRO] REFCELL_RELEASE"));

    const derive_src = try readFileAlloc(std.testing.allocator, "sa_std/core/derive.sa");
    defer std.testing.allocator.free(derive_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, derive_src, 1, "[MACRO] STRUCT_COPY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, derive_src, 1, "[MACRO] STRUCT_EQ_FIELD"));
    try std.testing.expect(std.mem.containsAtLeast(u8, derive_src, 1, "[MACRO] STRUCT_EQ4"));

    const rc_src = try readFileAlloc(std.testing.allocator, "sa_std/core/rc.sa");
    defer std.testing.allocator.free(rc_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, rc_src, 1, "[MACRO] RC_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rc_src, 1, "[MACRO] RC_CLONE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rc_src, 1, "[MACRO] RC_DROP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rc_src, 1, "[MACRO] RC_DOWNGRADE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rc_src, 1, "[MACRO] WEAK_CLONE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rc_src, 1, "[MACRO] WEAK_DROP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rc_src, 1, "[MACRO] WEAK_UPGRADE"));

    const weak_src = try readFileAlloc(std.testing.allocator, "sa_std/core/weak.sa");
    defer std.testing.allocator.free(weak_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, weak_src, 1, "@import \"weak.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, weak_src, 1, "@import \"rc.sa\""));

    const box_src = try readFileAlloc(std.testing.allocator, "sa_std/core/box.sa");
    defer std.testing.allocator.free(box_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, box_src, 1, "@import \"mem.sa\""));
    var box_flat = try saasm.flattener.flatten(std.testing.allocator, box_src);
    defer box_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), box_flat.instructions.len);

    const future_src = try readFileAlloc(std.testing.allocator, "sa_std/core/future.sa");
    defer std.testing.allocator.free(future_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] POLL_PENDING"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] POLL_READY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] POLL_MAP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] POLL_RESULT_MAP_OK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] POLL_RESULT_MAP_ERR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] POLL_OPTION_RESULT_MAP_OK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] CONTEXT_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] CONTEXT_FROM_WAKER"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] CONTEXT_BUILDER_BUILD"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] FUTURE_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] FUTURE_POLL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] FUTURE_READY_STATE_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] FUTURE_PENDING_STATE_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] FUTURE_JOIN2_POLL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] FUTURE_SELECT2_POLL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] FUTURE_JOIN2_STATE_POLL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, future_src, 1, "[MACRO] FUTURE_SELECT2_STATE_POLL"));

    const waker_src = try readFileAlloc(std.testing.allocator, "sa_std/core/waker.sa");
    defer std.testing.allocator.free(waker_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, waker_src, 1, "[MACRO] RAW_WAKER_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, waker_src, 1, "[MACRO] RAW_WAKER_CLONE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, waker_src, 1, "[MACRO] WAKER_FROM_RAW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, waker_src, 1, "[MACRO] WAKER_CLONE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, waker_src, 1, "[MACRO] WAKER_WILL_WAKE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, waker_src, 1, "[MACRO] LOCAL_WAKER_FROM_RAW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, waker_src, 1, "[MACRO] LOCAL_WAKER_WILL_WAKE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, waker_src, 1, "[MACRO] WAKE_NEW"));

    const task_src = try readFileAlloc(std.testing.allocator, "sa_std/core/task.sa");
    defer std.testing.allocator.free(task_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, task_src, 1, "[MACRO] TASK_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, task_src, 1, "[MACRO] TASK_POLL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, task_src, 1, "[MACRO] EXECUTOR_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, task_src, 1, "[MACRO] EXECUTOR_POLL_ONE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, task_src, 1, "[MACRO] EXECUTOR_POLL_READY_COUNT"));

    const future_facade_src = try readFileAlloc(std.testing.allocator, "sa_std/future.sa");
    defer std.testing.allocator.free(future_facade_src);
    try std.testing.expectEqualStrings("@import \"core/future.sal\"\n@import \"core/future.sa\"\n", future_facade_src);

    const future_facade_layout = try readFileAlloc(std.testing.allocator, "sa_std/future.sal");
    defer std.testing.allocator.free(future_facade_layout);
    try std.testing.expectEqualStrings("@import \"core/future.sal\"\n", future_facade_layout);

    const task_facade_src = try readFileAlloc(std.testing.allocator, "sa_std/task.sa");
    defer std.testing.allocator.free(task_facade_src);
    try std.testing.expectEqualStrings("@import \"core/task.sal\"\n@import \"core/task.sa\"\n", task_facade_src);

    const task_facade_layout = try readFileAlloc(std.testing.allocator, "sa_std/task.sal");
    defer std.testing.allocator.free(task_facade_layout);
    try std.testing.expectEqualStrings("@import \"core/task.sal\"\n", task_facade_layout);

    var option_flat = try flattenFixture(std.testing.allocator, "sa_std/core/option.sa", option_src);
    defer option_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), option_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), option_flat.function_sigs.len);

    var result_flat = try flattenFixture(std.testing.allocator, "sa_std/core/result.sa", result_src);
    defer result_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), result_flat.function_sigs.len);

    var panic_flat = try flattenFixture(std.testing.allocator, "sa_std/core/panic.sa", panic_src);
    defer panic_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), panic_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), panic_flat.function_sigs.len);

    var iter_flat = try flattenFixture(std.testing.allocator, "sa_std/core/iter.sa", iter_src);
    defer iter_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), iter_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), iter_flat.function_sigs.len);

    var ascii_flat = try flattenFixture(std.testing.allocator, "sa_std/core/ascii.sa", ascii_src);
    defer ascii_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), ascii_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), ascii_flat.function_sigs.len);

    var future_flat = try flattenFixture(std.testing.allocator, "sa_std/core/future.sa", future_src);
    defer future_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), future_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), future_flat.function_sigs.len);

    var task_flat = try flattenFixture(std.testing.allocator, "sa_std/core/task.sa", task_src);
    defer task_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), task_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), task_flat.function_sigs.len);

    var rust_core_flat = try flattenFixture(std.testing.allocator, "sa_std/rust_core.sa", rust_core_src);
    defer rust_core_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), rust_core_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), rust_core_flat.function_sigs.len);

    const rust_core_fixture = try readFileAlloc(std.testing.allocator, "tests/rust_core_fixture.sa");
    defer std.testing.allocator.free(rust_core_fixture);
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_fixture, 1, "EXPAND OPTION_IS_SOME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_fixture, 1, "EXPAND OPTION_UNWRAP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_fixture, 1, "EXPAND OPTION_MAP_OR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_fixture, 1, "EXPAND RESULT_NEW_OK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_fixture, 1, "EXPAND RESULT_UNWRAP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_fixture, 1, "EXPAND RESULT_MAP_OR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_fixture, 1, "EXPAND ITER_FROM_SLICE"));

    var rust_core_fixture_flat = try flattenFixture(std.testing.allocator, "tests/rust_core_fixture.sa", rust_core_fixture);
    defer rust_core_fixture_flat.deinit(std.testing.allocator);
    try std.testing.expect(rust_core_fixture_flat.instructions.len > 0);
    try std.testing.expect(rust_core_fixture_flat.function_sigs.len >= 1);

    const option_default_demo = try readFileAlloc(std.testing.allocator, "demos/rosetta/46_option_default/main.sa");
    defer std.testing.allocator.free(option_default_demo);
    try std.testing.expect(std.mem.containsAtLeast(u8, option_default_demo, 1, "@import \"sa_std/core/option.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_default_demo, 1, "Option_SOME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_default_demo, 1, "call @choose(&opt, 1)"));
    var option_default_flat = try flattenFixture(std.testing.allocator, "demos/rosetta/46_option_default/main.sa", option_default_demo);
    defer option_default_flat.deinit(std.testing.allocator);
    try std.testing.expect(option_default_flat.instructions.len > 0);

    const result_question_demo = try readFileAlloc(std.testing.allocator, "demos/rosetta/19_result_question/main.sa");
    defer std.testing.allocator.free(result_question_demo);
    try std.testing.expect(std.mem.containsAtLeast(u8, result_question_demo, 1, "@import \"sa_std/core/result.sa\""));
    var result_question_flat = try flattenFixture(std.testing.allocator, "demos/rosetta/19_result_question/main.sa", result_question_demo);
    defer result_question_flat.deinit(std.testing.allocator);
    try std.testing.expect(result_question_flat.instructions.len > 0);

    const result_unwrap_demo = try readFileAlloc(std.testing.allocator, "demos/rosetta/177_unwrap_unwrap_err/main.sa");
    defer std.testing.allocator.free(result_unwrap_demo);
    try std.testing.expect(std.mem.containsAtLeast(u8, result_unwrap_demo, 1, "@import \"sa_std/core/result.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_unwrap_demo, 1, "EXPAND RESULT_UNWRAP_ERR"));
    var result_unwrap_flat = try flattenFixture(std.testing.allocator, "demos/rosetta/177_unwrap_unwrap_err/main.sa", result_unwrap_demo);
    defer result_unwrap_flat.deinit(std.testing.allocator);
    try std.testing.expect(result_unwrap_flat.instructions.len > 0);

    const iterator_fold_demo = try readFileAlloc(std.testing.allocator, "demos/rosetta/35_iterator_fold/main.sa");
    defer std.testing.allocator.free(iterator_fold_demo);
    try std.testing.expect(std.mem.containsAtLeast(u8, iterator_fold_demo, 1, "@import \"sa_std/core/iter.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, iterator_fold_demo, 1, "ITER_FROM_SLICE"));
    var iterator_fold_flat = try flattenFixture(std.testing.allocator, "demos/rosetta/35_iterator_fold/main.sa", iterator_fold_demo);
    defer iterator_fold_flat.deinit(std.testing.allocator);
    try std.testing.expect(iterator_fold_flat.instructions.len > 0);

    const option_map_demo = try readFileAlloc(std.testing.allocator, "demos/rosetta/18_option_map/main.sa");
    defer std.testing.allocator.free(option_map_demo);
    try std.testing.expect(std.mem.containsAtLeast(u8, option_map_demo, 1, "@import \"sa_std/core/option.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_map_demo, 1, "!opt"));
    var option_map_flat = try flattenFixture(std.testing.allocator, "demos/rosetta/18_option_map/main.sa", option_map_demo);
    defer option_map_flat.deinit(std.testing.allocator);
    try std.testing.expect(option_map_flat.instructions.len > 0);

    const manual_guard_demo = try readFileAlloc(std.testing.allocator, "demos/rosetta/30_manual_guard_branch/main.sa");
    defer std.testing.allocator.free(manual_guard_demo);
    try std.testing.expect(std.mem.containsAtLeast(u8, manual_guard_demo, 1, "@import \"sa_std/core/option.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, manual_guard_demo, 1, "OPTION_SET_SOME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, manual_guard_demo, 1, "OPTION_IS_SOME"));
    var manual_guard_flat = try flattenFixture(std.testing.allocator, "demos/rosetta/30_manual_guard_branch/main.sa", manual_guard_demo);
    defer manual_guard_flat.deinit(std.testing.allocator);
    try std.testing.expect(manual_guard_flat.instructions.len > 0);

    const never_type_demo = try readFileAlloc(std.testing.allocator, "demos/rosetta/146_never_type_fallback/main.sa");
    defer std.testing.allocator.free(never_type_demo);
    try std.testing.expect(std.mem.containsAtLeast(u8, never_type_demo, 1, "@import \"sa_std/core/option.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, never_type_demo, 1, "OPTION_SET_SOME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, never_type_demo, 1, "OPTION_IS_SOME"));
    var never_type_flat = try flattenFixture(std.testing.allocator, "demos/rosetta/146_never_type_fallback/main.sa", never_type_demo);
    defer never_type_flat.deinit(std.testing.allocator);
    try std.testing.expect(never_type_flat.instructions.len > 0);

    const if_let_demo = try readFileAlloc(std.testing.allocator, "demos/rosetta/104_if_let_chains/main.sa");
    defer std.testing.allocator.free(if_let_demo);
    try std.testing.expect(std.mem.containsAtLeast(u8, if_let_demo, 1, "@import \"sa_std/core/option.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, if_let_demo, 1, "OPTION_SET_SOME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, if_let_demo, 1, "OPTION_GET"));
    var if_let_flat = try flattenFixture(std.testing.allocator, "demos/rosetta/104_if_let_chains/main.sa", if_let_demo);
    defer if_let_flat.deinit(std.testing.allocator);
    try std.testing.expect(if_let_flat.instructions.len > 0);

    const let_else_demo = try readFileAlloc(std.testing.allocator, "demos/rosetta/105_let_else/main.sa");
    defer std.testing.allocator.free(let_else_demo);
    try std.testing.expect(std.mem.containsAtLeast(u8, let_else_demo, 1, "@import \"sa_std/core/option.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, let_else_demo, 1, "OPTION_SET_SOME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, let_else_demo, 1, "OPTION_GET"));
    var let_else_flat = try flattenFixture(std.testing.allocator, "demos/rosetta/105_let_else/main.sa", let_else_demo);
    defer let_else_flat.deinit(std.testing.allocator);
    try std.testing.expect(let_else_flat.instructions.len > 0);

    const generics_monomorph_demo = try readFileAlloc(std.testing.allocator, "demos/rosetta/10_generics_monomorph/main.sa");
    defer std.testing.allocator.free(generics_monomorph_demo);
    try std.testing.expect(std.mem.containsAtLeast(u8, generics_monomorph_demo, 1, "@import \"sa_std/core/option.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, generics_monomorph_demo, 1, "OPTION_SET_SOME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, generics_monomorph_demo, 1, "OPTION_IS_SOME"));
    var generics_monomorph_flat = try flattenFixture(std.testing.allocator, "demos/rosetta/10_generics_monomorph/main.sa", generics_monomorph_demo);
    defer generics_monomorph_flat.deinit(std.testing.allocator);
    try std.testing.expect(generics_monomorph_flat.instructions.len > 0);

    const result_flatten_demo = try readFileAlloc(std.testing.allocator, "demos/rosetta/176_result_flattening/main.sa");
    defer std.testing.allocator.free(result_flatten_demo);
    try std.testing.expect(std.mem.containsAtLeast(u8, result_flatten_demo, 1, "@import \"sa_std/core/result.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_flatten_demo, 1, "RESULT_SET_OK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_flatten_demo, 1, "RESULT_GET_OK"));
    var result_flatten_flat = try flattenFixture(std.testing.allocator, "demos/rosetta/176_result_flattening/main.sa", result_flatten_demo);
    defer result_flatten_flat.deinit(std.testing.allocator);
    try std.testing.expect(result_flatten_flat.instructions.len > 0);

    const assert_macro_demo = try readFileAlloc(std.testing.allocator, "demos/rosetta/179_assert_macro_expansion/main.sa");
    defer std.testing.allocator.free(assert_macro_demo);
    try std.testing.expect(std.mem.containsAtLeast(u8, assert_macro_demo, 1, "@import \"sa_std/core/panic.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, assert_macro_demo, 1, "EXPAND PANIC_MSG"));
    var assert_macro_flat = try flattenFixture(std.testing.allocator, "demos/rosetta/179_assert_macro_expansion/main.sa", assert_macro_demo);
    defer assert_macro_flat.deinit(std.testing.allocator);
    try std.testing.expect(assert_macro_flat.instructions.len > 0);
}

test "sa_std alloc helpers are concrete and verifiable" {
    const vec_layout = try readFileAlloc(std.testing.allocator, "sa_std/alloc/vec.sal");
    defer std.testing.allocator.free(vec_layout);
    try std.testing.expectEqualStrings(
        "#def Vec_SIZE = 24\n#def Vec_ptr  = +0\n#def Vec_cap  = +8\n#def Vec_len  = +16",
        vec_layout,
    );

    const vec_src = try readFileAlloc(std.testing.allocator, "sa_std/alloc/vec.sa");
    defer std.testing.allocator.free(vec_src);
    try std.testing.expect(!std.mem.containsAtLeast(u8, vec_src, 1, "inttoptr"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, vec_src, 1, "假定"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, vec_src, 1, "示例"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_src, 1, "@import \"../num.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_src, 1, "EXPAND NUM_U64_CHECKED_MUL bytes_ok, bytes, cap, elem_size"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_src, 1, "EXPAND NUM_U64_CHECKED_ADD next_cap_ok, next_cap, cap, cap"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_src, 1, "EXPAND NUM_U64_CHECKED_MUL shrink_new_bytes_ok, new_bytes, target_cap, elem_size"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_src, 1, "panic(1201)"));
    var vec_flat = try flattenFixture(std.testing.allocator, "sa_std/alloc/vec.sa", vec_src);
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

    const vec_macro_layout = try readFileAlloc(std.testing.allocator, "sa_std/vec.sal");
    defer std.testing.allocator.free(vec_macro_layout);
    try std.testing.expectEqualStrings("#def Vec_data = +0\n", vec_macro_layout);

    const vec_macro_src = try readFileAlloc(std.testing.allocator, "sa_std/vec.sa");
    defer std.testing.allocator.free(vec_macro_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "@import \"alloc/vec.sa\""));
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
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_EXTEND_FROM_SLICE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_EXTEND_FROM_SLICE_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_EXTEND_FROM_WITHIN_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_EXTEND_FROM_WITHIN_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_APPEND"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_APPEND_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_SWAP_REMOVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_SWAP_REMOVE_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_REMOVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_SPLIT_OFF"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_RESIZE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_AS_MUT_SLICE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_SET_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_SHRINK_TO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_SHRINK_TO_FIT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_SHRINK_TO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_SHRINK_TO_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_SHRINK_TO_FIT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_SHRINK_TO_FIT_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_FRONT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_BACK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_FIRST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_LAST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_FIRST_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_LAST_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_SPLIT_FIRST_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_TRY_SPLIT_LAST_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_PUSH"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_PUSH_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_LIT1_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_LIT2_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_LIT3_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_FREE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_macro_src, 1, "[MACRO] VEC_CAPACITY"));
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

    var vec_macro_error_ctx = saasm.flattener.ErrorContext{};
    var vec_macro_flat = saasm.flattener.flattenFileWithContext(std.testing.allocator, "sa_std/vec.sa", vec_macro_src, &vec_macro_error_ctx) catch |err| {
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

    const vec_fixture = try readFileAlloc(std.testing.allocator, "tests/vec_fixture.sa");
    defer std.testing.allocator.free(vec_fixture);
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_fixture, 1, "EXPAND VEC_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, vec_fixture, 1, "EXPAND VEC_TRY_POP"));

    var vec_fixture_error_ctx = saasm.flattener.ErrorContext{};
    var vec_fixture_flat = saasm.flattener.flattenFileWithContext(std.testing.allocator, "tests/vec_fixture.sa", vec_fixture, &vec_fixture_error_ctx) catch |err| {
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

    const string_src = try readFileAlloc(std.testing.allocator, "sa_std/alloc/string.sa");
    defer std.testing.allocator.free(string_src);
    try std.testing.expect(!std.mem.containsAtLeast(u8, string_src, 1, "inttoptr"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, string_src, 1, "假定"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, string_src, 1, "示例"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_src, 1, "[MACRO] STR_FROM_CONST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_src, 1, "EXPAND SLICE_NEW"));

    const string_macro_src = try readFileAlloc(std.testing.allocator, "sa_std/string.sa");
    defer std.testing.allocator.free(string_macro_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "@import \"fmt.sai\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_AS_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_AS_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_AS_BYTES"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_AS_BYTES"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_AS_STR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_IS_EMPTY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_IS_EMPTY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_FROM_PARTS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_FROM_PARTS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_EMPTY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_TRY_FIND"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_TRY_RFIND"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_CONCAT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "sa_fmt_buffer_data"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "sa_fmt_buffer_len"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_TRIM_PREFIX"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_TRIM_SUFFIX"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STR_TRY_SPLIT_AT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_BUF_TRY_PUSH_CHAR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_BUF_PUSH_CHAR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_BUF_TRY_INSERT_CHAR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_BUF_INSERT_CHAR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_BUF_LIT1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_BUF_LIT2"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_macro_src, 1, "[MACRO] STRING_BUF_LIT3"));

    const string_fixture =
        \\@import "sa_std/core/slice.sal"
        \\@import "sa_std/core/slice.sa"
        \\@import "sa_std/alloc/string.sa"
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
    var string_flat = try flattenFixture(std.testing.allocator, "demos/rosetta/15_string_bytes/main.sa", string_fixture);
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
        \\@import "sa_std/string.sa"
        \\
        \\@const WORD = utf8:"rust"
        \\@const EMPTY = utf8:""
        \\@const INFIX = utf8:"us"
        \\@const MISS = utf8:"zz"
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    EXPAND STR_FROM_PARTS word, &WORD, 4
        \\    EXPAND STRING_LEN len, word
        \\    EXPAND STR_PTR ptr, word
        \\    EXPAND STR_AS_PTR as_ptr, word
        \\    EXPAND STRING_AS_BYTES bytes, word
        \\    EXPAND STRING_AS_STR str_view, word
        \\    EXPAND STR_LEN bytes_len, bytes
        \\    EXPAND STRING_LEN str_len, str_view
        \\    EXPAND STRING_FROM_PARTS empty, &EMPTY, 0
        \\    EXPAND STR_FROM_PARTS infix, &INFIX, 2
        \\    EXPAND STR_FROM_PARTS miss, &MISS, 2
        \\    EXPAND STRING_NEW new_empty
        \\    EXPAND STR_EMPTY str_empty
        \\    EXPAND STR_IS_EMPTY word_empty, word
        \\    EXPAND STRING_IS_EMPTY empty_ok, empty
        \\    EXPAND STRING_IS_EMPTY new_empty_ok, new_empty
        \\    EXPAND STR_IS_EMPTY str_empty_ok, str_empty
        \\    EXPAND STR_TRY_FIND find_ok, find_idx, word, infix
        \\    EXPAND STRING_TRY_RFIND rfind_ok, rfind_idx, word, infix
        \\    EXPAND STR_TRY_FIND find_miss_ok, find_miss_idx, word, miss
        \\    EXPAND STRING_TRY_RFIND rfind_miss_ok, rfind_miss_idx, word, miss
        \\    len_ok = eq len, 4
        \\    ptr_ok = ne ptr, 0
        \\    as_ptr_ok = ne as_ptr, 0
        \\    bytes_len_ok = eq bytes_len, 4
        \\    str_len_ok = eq str_len, 4
        \\    word_not_empty = eq word_empty, 0
        \\    find_flag_ok = eq find_ok, 1
        \\    find_idx_ok = eq find_idx, 1
        \\    rfind_flag_ok = eq rfind_ok, 1
        \\    rfind_idx_ok = eq rfind_idx, 1
        \\    find_miss_flag_ok = eq find_miss_ok, 0
        \\    find_miss_idx_ok = eq find_miss_idx, 0
        \\    rfind_miss_flag_ok = eq rfind_miss_ok, 0
        \\    rfind_miss_idx_ok = eq rfind_miss_idx, 0
        \\    ok01 = and len_ok, ptr_ok
        \\    ok02 = and ok01, as_ptr_ok
        \\    ok03 = and ok02, bytes_len_ok
        \\    ok04 = and ok03, str_len_ok
        \\    ok05 = and ok04, word_not_empty
        \\    ok06 = and ok05, empty_ok
        \\    ok07 = and ok06, new_empty_ok
        \\    ok08 = and ok07, str_empty_ok
        \\    ok09 = and ok08, find_flag_ok
        \\    ok10 = and ok09, find_idx_ok
        \\    ok11 = and ok10, rfind_flag_ok
        \\    ok12 = and ok11, rfind_idx_ok
        \\    ok13 = and ok12, find_miss_flag_ok
        \\    ok14 = and ok13, find_miss_idx_ok
        \\    ok15 = and ok14, rfind_miss_flag_ok
        \\    ok = and ok15, rfind_miss_idx_ok
        \\    !len
        \\    !ptr
        \\    !as_ptr
        \\    !bytes
        \\    !str_view
        \\    !bytes_len
        \\    !str_len
        \\    !word_empty
        \\    !empty_ok
        \\    !new_empty_ok
        \\    !str_empty_ok
        \\    !find_ok
        \\    !find_idx
        \\    !rfind_ok
        \\    !rfind_idx
        \\    !find_miss_ok
        \\    !find_miss_idx
        \\    !rfind_miss_ok
        \\    !rfind_miss_idx
        \\    !len_ok
        \\    !ptr_ok
        \\    !as_ptr_ok
        \\    !bytes_len_ok
        \\    !str_len_ok
        \\    !word_not_empty
        \\    !find_flag_ok
        \\    !find_idx_ok
        \\    !rfind_flag_ok
        \\    !rfind_idx_ok
        \\    !find_miss_flag_ok
        \\    !find_miss_idx_ok
        \\    !rfind_miss_flag_ok
        \\    !rfind_miss_idx_ok
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
        \\    !ok15
        \\    !word
        \\    !empty
        \\    !infix
        \\    !miss
        \\    !new_empty
        \\    !str_empty
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
    var string_macro_flat = try flattenFixture(std.testing.allocator, "tests/string_macro_fixture.sa", string_macro_fixture);
    defer string_macro_flat.deinit(std.testing.allocator);
    const string_macro_verified = try saasm.referee.verify(std.testing.allocator, string_macro_flat.instructions, string_macro_flat.const_decls);
    switch (string_macro_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), owned.function_sigs.len);
        },
        .trap => |report| {
            std.debug.print("string macro verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }
}

test "sa_std json helpers are concrete and verifiable" {
    const json_layout = try readFileAlloc(std.testing.allocator, "sa_std/encoding/json.sal");
    defer std.testing.allocator.free(json_layout);
    try std.testing.expect(std.mem.containsAtLeast(u8, json_layout, 1, "SA_JSON_KIND_OBJECT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_layout, 1, "SA_JSON_KIND_NULL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_layout, 1, "SA_JSON_TOKEN_OBJECT_BEGIN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_layout, 1, "SA_JSON_WHITESPACE_MINIFIED"));

    const json_iface = try readFileAlloc(std.testing.allocator, "sa_std/encoding/json.sai");
    defer std.testing.allocator.free(json_iface);
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_parse"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_object_get"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_array_get"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_object_key_at"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_object_get_string"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_object_get_bool"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_object_get_i64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_object_get_f64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "@extern sa_json_string_ptr(node: ptr) -> &ptr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "@extern sa_json_buffer_data(&buffer: ptr) -> &ptr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "@extern sa_json_stream_get_slice_ptr(stream: ptr) -> &ptr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_stringify"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_buffer_free"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_scanner_next"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_stream_new"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_stream_next"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_stream_get_slice_ptr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_stream_get_slice_len"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_stream_free"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_writer_write_node"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_iface, 1, "sa_json_writer_finish"));

    const json_src = try readFileAlloc(std.testing.allocator, "sa_std/encoding/json.sa");
    defer std.testing.allocator.free(json_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, json_src, 1, "@import \"json.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_src, 1, "@import \"json.sai\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_src, 1, "[MACRO] JSON_OBJECT_GET_STRING"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_src, 1, "[MACRO] JSON_OBJECT_GET_BOOL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_src, 1, "[MACRO] JSON_OBJECT_GET_I64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_src, 1, "[MACRO] JSON_AS_I64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_src, 1, "[MACRO] JSON_IS_OBJECT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_src, 1, "[MACRO] JSON_ARRAY_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_src, 1, "[MACRO] JSON_STRING_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_src, 1, "[MACRO] JSON_ARRAY_LOOP_INIT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_src, 1, "[MACRO] JSON_OBJECT_LOOP_INIT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_src, 1, "[MACRO] JSON_WRITER_BEGIN_OBJECT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_src, 1, "[MACRO] JSON_WRITER_FIELD_STRING"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_src, 1, "[MACRO] JSON_WRITER_FIELD_NODE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_src, 1, "[MACRO] JSON_WRITER_WRITE_STRING"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_src, 1, "[MACRO] JSON_WRITER_WRITE_NODE"));

    const json_macro_fixture =
        \\@import "sa_std/encoding/json.sa"
        \\
        \\@const JSON_DOC = utf8:"{\"name\":\"sci\",\"active\":true,\"count\":7,\"ratio\":1.5,\"items\":[{\"type\":\"object\"}]}"
        \\@const K_NAME = utf8:"name"
        \\@const K_ACTIVE = utf8:"active"
        \\@const K_COUNT = utf8:"count"
        \\@const K_RATIO = utf8:"ratio"
        \\@const K_ITEMS = utf8:"items"
        \\@const K_FIRST = utf8:"first"
        \\@const K_NONE = utf8:"none"
        \\@const V_NAME = utf8:"sci"
        \\
        \\#def JSON_DOC_LEN = 78
        \\#def K_NAME_LEN = 4
        \\#def K_ACTIVE_LEN = 6
        \\#def K_COUNT_LEN = 5
        \\#def K_RATIO_LEN = 5
        \\#def K_ITEMS_LEN = 5
        \\#def K_FIRST_LEN = 5
        \\#def K_NONE_LEN = 4
        \\#def V_NAME_LEN = 3
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    EXPAND JSON_PARSE root, JSON_DOC, JSON_DOC_LEN
        \\    EXPAND JSON_OBJECT_GET items_status, items, root, K_ITEMS, K_ITEMS_LEN
        \\    EXPAND JSON_ARRAY_LOOP_INIT array_status, idx, item_count, items
        \\    EXPAND JSON_ARRAY_LOOP_HAS_NEXT has_item, idx, item_count
        \\    EXPAND JSON_ARRAY_GET item_status, item0, items, idx
        \\    EXPAND JSON_ARRAY_LOOP_NEXT next_idx, idx
        \\    EXPAND JSON_OBJECT_LOOP_INIT object_status, object_idx, object_count, root
        \\    EXPAND JSON_OBJECT_LOOP_HAS_NEXT has_key, object_idx, object_count
        \\    EXPAND JSON_OBJECT_KEY_AT key_status, key_ptr, key_len, root, object_idx
        \\    EXPAND JSON_OBJECT_LOOP_NEXT next_object_idx, object_idx
        \\    EXPAND JSON_OBJECT_GET_STRING name_status, name_ptr, name_len, root, K_NAME, K_NAME_LEN
        \\    EXPAND JSON_OBJECT_GET_BOOL active_status, active, root, K_ACTIVE, K_ACTIVE_LEN
        \\    EXPAND JSON_OBJECT_GET_I64 count_status, count_value, root, K_COUNT, K_COUNT_LEN
        \\    EXPAND JSON_OBJECT_GET_F64 ratio_status, ratio_value, root, K_RATIO, K_RATIO_LEN
        \\    EXPAND JSON_WRITER_NEW_MINIFIED writer_status, writer
        \\    EXPAND JSON_WRITER_BEGIN_OBJECT begin_status, writer
        \\    EXPAND JSON_WRITER_FIELD_STRING field_name_status, writer, K_NAME, K_NAME_LEN, V_NAME, V_NAME_LEN
        \\    EXPAND JSON_WRITER_FIELD_BOOL field_active_status, writer, K_ACTIVE, K_ACTIVE_LEN, active
        \\    EXPAND JSON_WRITER_FIELD_I64 field_count_status, writer, K_COUNT, K_COUNT_LEN, count_value
        \\    EXPAND JSON_WRITER_FIELD_F64 field_ratio_status, writer, K_RATIO, K_RATIO_LEN, ratio_value
        \\    EXPAND JSON_WRITER_FIELD_NULL field_none_status, writer, K_NONE, K_NONE_LEN
        \\    EXPAND JSON_WRITER_FIELD_NODE field_first_status, writer, K_FIRST, K_FIRST_LEN, item0
        \\    EXPAND JSON_WRITER_END_OBJECT end_status, writer
        \\    EXPAND JSON_WRITER_FINISH finish_status, buffer, writer
        \\    EXPAND JSON_BUFFER_SLICE buffer_ptr, buffer_len, buffer
        \\    EXPAND JSON_BUFFER_FREE buffer
        \\    EXPAND JSON_WRITER_FREE writer
        \\    EXPAND JSON_FREE item0
        \\    EXPAND JSON_FREE items
        \\    EXPAND JSON_FREE root
        \\
        \\    !items_status
        \\    !array_status
        \\    !idx
        \\    !item_count
        \\    !has_item
        \\    !item_status
        \\    !next_idx
        \\    !object_status
        \\    !object_idx
        \\    !object_count
        \\    !has_key
        \\    !key_status
        \\    !key_ptr
        \\    !key_len
        \\    !next_object_idx
        \\    !name_status
        \\    !name_ptr
        \\    !name_len
        \\    !active_status
        \\    !active
        \\    !count_status
        \\    !count_value
        \\    !ratio_status
        \\    !ratio_value
        \\    !writer_status
        \\    !begin_status
        \\    !field_name_status
        \\    !field_active_status
        \\    !field_count_status
        \\    !field_ratio_status
        \\    !field_none_status
        \\    !field_first_status
        \\    !end_status
        \\    !finish_status
        \\    !buffer_ptr
        \\    !buffer_len
        \\    return 0
    ;
    var json_macro_flat = try flattenFixture(std.testing.allocator, "tests/json_macro_fixture.sa", json_macro_fixture);
    defer json_macro_flat.deinit(std.testing.allocator);
    const json_macro_verified = try saasm.referee.verify(std.testing.allocator, json_macro_flat.instructions, json_macro_flat.const_decls);
    switch (json_macro_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
        },
        .trap => |report| {
            std.debug.print("json macro verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }

    const regex_layout = try readFileAlloc(std.testing.allocator, "sa_std/text/regex.sal");
    defer std.testing.allocator.free(regex_layout);
    try std.testing.expect(std.mem.containsAtLeast(u8, regex_layout, 1, "SA_REGEX_REG_NOERROR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, regex_layout, 1, "SA_REGEX_REG_OK"));

    const regex_iface = try readFileAlloc(std.testing.allocator, "sa_std/text/regex.sai");
    defer std.testing.allocator.free(regex_iface);
    try std.testing.expect(std.mem.containsAtLeast(u8, regex_iface, 1, "sa_regex_compile"));
    try std.testing.expect(std.mem.containsAtLeast(u8, regex_iface, 1, "sa_regex_match"));
    try std.testing.expect(std.mem.containsAtLeast(u8, regex_iface, 1, "sa_regex_group_count"));
    try std.testing.expect(std.mem.containsAtLeast(u8, regex_iface, 1, "sa_regex_free"));
    try std.testing.expect(std.mem.containsAtLeast(u8, regex_iface, 1, "sa_regex_match_free"));

    const regex_src = try readFileAlloc(std.testing.allocator, "sa_std/text/regex.sa");
    defer std.testing.allocator.free(regex_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, regex_src, 1, "@import \"regex.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, regex_src, 1, "@import \"regex.sai\""));
}

test "sa_std time helpers are concrete and verifiable" {
    const time_layout = try readFileAlloc(std.testing.allocator, "sa_std/time.sal");
    defer std.testing.allocator.free(time_layout);
    try std.testing.expectEqualStrings(
        "#def Time_NS_PER_US = 1000\n#def Time_NS_PER_MS = 1000000\n#def Time_NS_PER_S  = 1000000000\n#def Time_MS_PER_S  = 1000\n#def TimeDate_SIZE = 32\n#def TimeDate_unix_ms = +0\n#def TimeDate_unix_ns = +8\n#def TimeDate_year = +16\n#def TimeDate_month = +18\n#def TimeDate_day = +19\n#def TimeDate_hour = +20\n#def TimeDate_minute = +21\n#def TimeDate_second = +22\n#def TimeDate_millisecond = +24\n",
        time_layout,
    );

    const time_iface = try readFileAlloc(std.testing.allocator, "sa_std/time.sai");
    defer std.testing.allocator.free(time_iface);
    try std.testing.expect(std.mem.containsAtLeast(u8, time_iface, 1, "sa_time_instant_ns"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_iface, 1, "sa_time_unix_ms"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_iface, 1, "sa_time_utc_now"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_iface, 1, "sa_time_sleep_ms"));

    const time_src = try readFileAlloc(std.testing.allocator, "sa_std/time.sa");
    defer std.testing.allocator.free(time_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_NOW_NS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_NOW_UNIX_MS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_UTC_NOW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_SLEEP_MS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_DURATION_FROM_MS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_DURATION_FROM_US"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_DURATION_FROM_NS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_DURATION_ZERO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_DURATION_MAX"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_DURATION_IS_ZERO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_DURATION_SUBSEC_NANOS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_CHECKED_ADD_NS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_CHECKED_SUB_NS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_SATURATING_MUL_NS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_SATURATING_DIV_NS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_DURATION_CHECKED_ADD_NS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_DURATION_SATURATING_MUL_NS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_DURATION_ABS_DIFF_NS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_CHECKED_DURATION_SINCE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, time_src, 1, "[MACRO] TIME_INSTANT_ELAPSED"));

    var time_flat = try flattenFixture(std.testing.allocator, "sa_std/time.sa", time_src);
    defer time_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 7), time_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 7), time_flat.function_sigs.len);
}

test "sa_std net helpers are concrete and verifiable" {
    const net_layout = try readFileAlloc(std.testing.allocator, "sa_std/net.sal");
    defer std.testing.allocator.free(net_layout);
    try std.testing.expect(std.mem.containsAtLeast(u8, net_layout, 1, "SA_NET_OK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_layout, 1, "SA_NET_AF_INET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_layout, 1, "SA_NET_SOCKET_OPTION_ENABLE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_layout, 1, "NetTcpIncoming_SIZE"));

    const net_iface = try readFileAlloc(std.testing.allocator, "sa_std/net.sai");
    defer std.testing.allocator.free(net_iface);
    const c_header = try readFileAlloc(std.testing.allocator, "src/runtime/sa_std.h");
    defer std.testing.allocator.free(c_header);
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_tcp_stream_peek"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_tcp_stream_peer_addr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_tcp_stream_local_addr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_tcp_stream_read_timeout"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_tcp_stream_take_error"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_tcp_listener_ttl"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_udp_local_addr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_udp_peer_addr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_udp_peek"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_udp_peek_from"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_udp_take_error"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_udp_recv_from"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_udp_set_multicast_loop_v4"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_udp_set_multicast_ttl_v4"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_udp_multicast_loop_v4"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_udp_multicast_ttl_v4"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_udp_join_multicast_v4"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_udp_leave_multicast_v4"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_udp_join_multicast_v6"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_udp_leave_multicast_v6"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_to_socket_addr_first"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_std_net_addr_format"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_iface, 1, "sa_net_addr_scope_id"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "sa_std_net_to_socket_addr_first"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "sa_std_net_addr_format"));

    const net_src = try readFileAlloc(std.testing.allocator, "sa_std/net.sa");
    defer std.testing.allocator.free(net_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_TCP_CONNECT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_TCP_LISTENER_BIND_PORT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_TCP_STREAM_PEEK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_TCP_STREAM_LOCAL_ADDR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_TCP_STREAM_SET_NODELAY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_TCP_STREAM_NODELAY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_TCP_STREAM_TAKE_ERROR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_TCP_LISTENER_SET_NONBLOCKING"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_TCP_LISTENER_TAKE_ERROR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_TCP_INCOMING_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_TCP_INCOMING_LISTENER"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_TCP_INCOMING_NEXT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_TCP_LISTENER_INCOMING"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_UDP_BIND"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_UDP_PEER_ADDR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_UDP_PEEK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_UDP_PEEK_FROM"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_UDP_TAKE_ERROR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_UDP_RECV_FROM"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_UDP_SET_MULTICAST_LOOP_V4"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_UDP_SET_MULTICAST_TTL_V4"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_UDP_MULTICAST_LOOP_V4"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_UDP_MULTICAST_TTL_V4"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_UDP_JOIN_MULTICAST_V4"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_UDP_LEAVE_MULTICAST_V4"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_UDP_JOIN_MULTICAST_V6"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_UDP_LEAVE_MULTICAST_V6"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_TO_SOCKET_ADDR_FIRST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_ADDR_FORMAT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_ADDR_SCOPE_ID"));
    try std.testing.expect(std.mem.containsAtLeast(u8, net_src, 1, "[MACRO] NET_ADDR_IS_IPV4"));

    var net_flat = try flattenFixture(std.testing.allocator, "sa_std/net.sa", net_src);
    defer net_flat.deinit(std.testing.allocator);
    try std.testing.expect(net_flat.function_sigs.len >= 60);
}

test "sa_std mutex helpers are concrete and verifiable" {
    const mutex_layout = try readFileAlloc(std.testing.allocator, "sa_std/sync/mutex.sal");
    defer std.testing.allocator.free(mutex_layout);
    try std.testing.expectEqualStrings(
        "#def Mutex_SIZE = 8\n#def Mutex_lock = +0\n#def Mutex_data = +8\n",
        mutex_layout,
    );

    const mutex_src = try readFileAlloc(std.testing.allocator, "sa_std/sync/mutex.sa");
    defer std.testing.allocator.free(mutex_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, mutex_src, 1, "@import \"../time.sai\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, mutex_src, 1, "[MACRO] MUTEX_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mutex_src, 1, "[MACRO] MUTEX_LOCK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mutex_src, 1, "[MACRO] MUTEX_UNLOCK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mutex_src, 1, "atomic_rmw_xchg lock+Mutex_lock, 1 as u64 seq_cst"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mutex_src, 1, "atomic_store %lock_ptr+Mutex_lock, 0 as u64 release"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mutex_src, 1, "@__mutex_lock_spin"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mutex_src, 1, "call @sa_time_sleep_ns(backoff_ns)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mutex_src, 1, "next_backoff = shl backoff_ns, 1"));

    var mutex_flat = try flattenFixture(std.testing.allocator, "sa_std/sync/mutex.sa", mutex_src);
    defer mutex_flat.deinit(std.testing.allocator);
    try std.testing.expect(mutex_flat.instructions.len > 0);
    try std.testing.expectEqual(@as(usize, 8), mutex_flat.function_sigs.len);
}

test "sa_std once helpers are concrete and verifiable" {
    const once_layout = try readFileAlloc(std.testing.allocator, "sa_std/sync/once.sal");
    defer std.testing.allocator.free(once_layout);
    try std.testing.expectEqualStrings(
        "#def Once_SIZE = 16\n#def Once_state = +0\n#def Once_value = +8\n#def Once_STATE_UNINIT = 0\n#def Once_STATE_RUNNING = 1\n#def Once_STATE_READY = 2\n",
        once_layout,
    );

    const once_src = try readFileAlloc(std.testing.allocator, "sa_std/sync/once.sa");
    defer std.testing.allocator.free(once_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, once_src, 1, "@import \"../time.sai\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, once_src, 1, "[MACRO] ONCE_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, once_src, 1, "[MACRO] ONCE_IS_READY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, once_src, 1, "[MACRO] ONCE_TRY_CLAIM"));
    try std.testing.expect(std.mem.containsAtLeast(u8, once_src, 1, "[MACRO] ONCE_WAIT_READY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, once_src, 1, "[MACRO] ONCE_PUBLISH"));
    try std.testing.expect(std.mem.containsAtLeast(u8, once_src, 1, "[MACRO] ONCE_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, once_src, 1, "[MACRO] ONCE_GET_OR_INIT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, once_src, 1, "[MACRO] LAZY_LOCK_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, once_src, 1, "[MACRO] LAZY_LOCK_FORCE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, once_src, 1, "[MACRO] LAZY_LOCK_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, once_src, 1, "[MACRO] LAZY_LOCK_IS_READY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, once_src, 1, "[MACRO] LAZY_LOCK_INTO_INNER"));
    try std.testing.expect(std.mem.containsAtLeast(u8, once_src, 1, "atomic_load once+Once_state as u32 acquire"));
    try std.testing.expect(std.mem.containsAtLeast(u8, once_src, 1, "cmpxchg once+Once_state, Once_STATE_UNINIT, Once_STATE_RUNNING as u32 acq_rel acquire"));
    try std.testing.expect(std.mem.containsAtLeast(u8, once_src, 1, "atomic_store %once_reg+Once_state, Once_STATE_READY as u32 release"));

    var once_flat = try flattenFixture(std.testing.allocator, "sa_std/sync/once.sa", once_src);
    defer once_flat.deinit(std.testing.allocator);
    try std.testing.expect(once_flat.instructions.len > 0);
    try std.testing.expectEqual(@as(usize, 9), once_flat.function_sigs.len);
}

test "sa_std rwlock helpers are concrete and verifiable" {
    const rwlock_layout = try readFileAlloc(std.testing.allocator, "sa_std/sync/rwlock.sal");
    defer std.testing.allocator.free(rwlock_layout);
    try std.testing.expectEqualStrings(
        "#def RwLock_SIZE = 8\n#def RwLock_readers = +0\n#def RwLock_writing = +4\n",
        rwlock_layout,
    );

    const rwlock_src = try readFileAlloc(std.testing.allocator, "sa_std/sync/rwlock.sa");
    defer std.testing.allocator.free(rwlock_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, rwlock_src, 1, "[MACRO] RWLOCK_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rwlock_src, 1, "[MACRO] RWLOCK_TRY_READ"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rwlock_src, 1, "[MACRO] RWLOCK_TRY_WRITE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rwlock_src, 1, "[MACRO] RWLOCK_RELEASE_READ"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rwlock_src, 1, "[MACRO] RWLOCK_RELEASE_WRITE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rwlock_src, 1, "cmpxchg %lock_reg+RwLock_writing, 0, 1 as i32 acq_rel acquire"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rwlock_src, 1, "atomic_rmw_add %lock_reg+RwLock_readers, 1 as i32 acq_rel"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rwlock_src, 1, "@__rwlock_release_read"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rwlock_src, 1, "panic(1601)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rwlock_src, 1, "atomic_store %lock_reg+RwLock_writing, 0 as i32 release"));

    var rwlock_flat = try flattenFixture(std.testing.allocator, "sa_std/sync/rwlock.sa", rwlock_src);
    defer rwlock_flat.deinit(std.testing.allocator);
    try std.testing.expect(rwlock_flat.instructions.len > 0);
    try std.testing.expectEqual(@as(usize, 6), rwlock_flat.function_sigs.len);
}

test "sa_std mpsc helpers are concrete and verifiable" {
    const mpsc_layout = try readFileAlloc(std.testing.allocator, "sa_std/sync/mpsc.sal");
    defer std.testing.allocator.free(mpsc_layout);
    try std.testing.expectEqualStrings(
        "#def Mpsc_SIZE = 32\n#def Mpsc_cap = +0\n#def Mpsc_head = +8\n#def Mpsc_tail = +16\n#def Mpsc_data = +32\n\n#def Mpsc_SLOT_SIZE = 16\n#def Mpsc_SLOT_value = +0\n#def Mpsc_SLOT_ready = +8\n#def Mpsc_SLOT_EMPTY = 0\n#def Mpsc_SLOT_READY = 1\n",
        mpsc_layout,
    );

    const mpsc_src = try readFileAlloc(std.testing.allocator, "sa_std/sync/mpsc.sa");
    defer std.testing.allocator.free(mpsc_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, mpsc_src, 1, "@import \"../core/mem.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, mpsc_src, 1, "@import \"../num.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, mpsc_src, 1, "@import \"../time.sai\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, mpsc_src, 1, "[MACRO] MPSC_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mpsc_src, 1, "[MACRO] MPSC_FREE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mpsc_src, 1, "[MACRO] MPSC_TRY_SEND"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mpsc_src, 1, "[MACRO] MPSC_SEND"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mpsc_src, 1, "[MACRO] MPSC_TRY_RECV"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mpsc_src, 1, "[MACRO] MPSC_RECV"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mpsc_src, 1, "@__mpsc_try_send"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mpsc_src, 1, "@__mpsc_try_recv"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mpsc_src, 1, "EXPAND NUM_U64_CHECKED_MUL __mpsc_data_ok_%out_chan"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mpsc_src, 1, "EXPAND NUM_U64_CHECKED_ADD __mpsc_total_ok_%out_chan"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mpsc_src, 1, "__mpsc_len_order_ok_%out_len = uge __mpsc_len_tail_%out_len, __mpsc_len_head_%out_len"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mpsc_src, 1, "tail_ok = uge tail, head"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mpsc_src, 1, "L_MPSC_TRY_RECV_CORRUPT:"));

    var mpsc_flat = try flattenFixture(std.testing.allocator, "sa_std/sync/mpsc.sa", mpsc_src);
    defer mpsc_flat.deinit(std.testing.allocator);
    try std.testing.expect(mpsc_flat.instructions.len > 0);
    try std.testing.expectEqual(@as(usize, 11), mpsc_flat.function_sigs.len);
}

test "sa_std async helpers are concrete and verifiable" {
    const async_src = try readFileAlloc(std.testing.allocator, "sa_std/libsa_async.sa");
    defer std.testing.allocator.free(async_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, async_src, 1, "[MACRO] ASYNC_CTX_DEF"));
    try std.testing.expect(std.mem.containsAtLeast(u8, async_src, 1, "[MACRO] ASYNC_POLL_PROLOGUE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, async_src, 1, "[MACRO] ASYNC_AWAIT_POINT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, async_src, 1, "[MACRO] ASYNC_AWAIT_POINT_FINAL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, async_src, 1, "[MACRO] ASYNC_RETURN_PENDING"));
    try std.testing.expect(std.mem.containsAtLeast(u8, async_src, 1, "[MACRO] ASYNC_READY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, async_src, 1, "[MACRO] ASYNC_INVALID_STATE"));

    var async_flat = try flattenFixture(std.testing.allocator, "sa_std/libsa_async.sa", async_src);
    defer async_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), async_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), async_flat.function_sigs.len);
}

test "libsa_async macro expansion stays equivalent to the manual state machine" {
    const macro_source = try readFileAlloc(std.testing.allocator, "demos/rosetta/09_async_await/main.sa");
    defer std.testing.allocator.free(macro_source);

    const print_iface_path = try sio.cwd().realpathAlloc(std.testing.allocator, "sa_std/io/print.sai");
    defer std.testing.allocator.free(print_iface_path);

    const manual_source = try std.fmt.allocPrint(std.testing.allocator,
        \\@import "{s}"
        \\
        \\@const RESULT_OK = utf8:"2\n"
        \\@const RESULT_ERR = utf8:"error\n"
        \\
        \\#def Run_SIZE = 32
        \\#def Run_state = +0
        \\#def Run_stage = +4
        \\#def Run_status = +8
        \\#def Run_value = +16
        \\#def Run_resume = +24
        \\#def Run_PENDING = 0
        \\#def Run_READY = 1
        \\#def Run_INVALID = 102
        \\
        \\@poll_step(state: ptr) -> i32:
        \\L_ENTRY:
        \\    stage = load state+Run_stage as u32
        \\    ready = eq stage, 1
        \\    !stage
        \\    return ready
        \\
        \\@take_step(state: ptr) -> void:
        \\L_ENTRY:
        \\    store state+Run_value, 1 as i32
        \\    return
        \\
        \\@poll_run(state: ptr) -> i32:
        \\L_ENTRY:
        \\    state_id = load state+Run_state as u32
        \\    is_state0 = eq state_id, 0
        \\    br is_state0 -> L_STATE_0, L_STATE_1
        \\
        \\L_STATE_0:
        \\    store state+Run_stage, 1 as u32
        \\    store state+Run_state, 1 as u32
        \\    !state_id
        \\    !is_state0
        \\    return 0
        \\
        \\L_STATE_1:
        \\    !state_id
        \\    !is_state0
        \\    async_poll_status_1_Run_state = call @poll_step(state)
        \\    async_is_ready_1_Run_state = eq async_poll_status_1_Run_state, 1
        \\    br async_is_ready_1_Run_state -> L_ASYNC_AWAIT_READY_1_Run_state, L_ASYNC_AWAIT_PENDING_1_Run_state
        \\L_ASYNC_AWAIT_PENDING_1_Run_state:
        \\    store state+Run_state, 1 as u32
        \\    !async_poll_status_1_Run_state
        \\    !async_is_ready_1_Run_state
        \\    return 0
        \\L_ASYNC_AWAIT_READY_1_Run_state:
        \\    call @take_step(state)
        \\    async_result_1_Run_state = load state+Run_value as i32
        \\    async_next_state_1_Run_state = add 1, 1
        \\    store state+Run_state, async_next_state_1_Run_state as u32
        \\    !async_poll_status_1_Run_state
        \\    !async_is_ready_1_Run_state
        \\    !async_next_state_1_Run_state
        \\    next = add async_result_1_Run_state, 1
        \\    store state+Run_value, next as i32
        \\    store state+Run_stage, 2 as u32
        \\    !async_result_1_Run_state
        \\    !next
        \\    return 1
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    state = alloc Run_SIZE
        \\    store state+Run_state, 0 as u32
        \\    store state+Run_stage, 0 as u32
        \\    store state+Run_status, 0 as u32
        \\    store state+Run_value, 0 as i32
        \\    store state+Run_resume, 0 as u32
        \\
        \\    ready0 = call @poll_run(state)
        \\    ready1 = call @poll_run(state)
        \\    value = load state+Run_value as i32
        \\    ok_ready0 = eq ready0, 0
        \\    ok_ready1 = eq ready1, 1
        \\    ok_value = eq value, 2
        \\    ok0 = and ok_ready0, ok_ready1
        \\    ok = and ok0, ok_value
        \\
        \\    !ready0
        \\    !ready1
        \\    !value
        \\    !ok_ready0
        \\    !ok_ready1
        \\    !ok_value
        \\    !ok0
        \\    !state
        \\
        \\    br ok -> L_OK, L_ERR
        \\
        \\L_OK:
        \\    !ok
        \\    call @sa_print_bytes(&RESULT_OK, 2)
        \\    return 0
        \\
        \\L_ERR:
        \\    !ok
        \\    call @sa_print_bytes(&RESULT_ERR, 6)
        \\    return 1
    , .{print_iface_path});
    defer std.testing.allocator.free(manual_source);

    for (0..100) |_| {
        var macro_flat = try flattenFixture(
            std.testing.allocator,
            "demos/rosetta/09_async_await/main.sa",
            macro_source,
        );
        defer macro_flat.deinit(std.testing.allocator);
        var manual_flat = try saasm.flattener.flatten(std.testing.allocator, manual_source);
        defer manual_flat.deinit(std.testing.allocator);

        if (macro_flat.instructions.len != manual_flat.instructions.len) {
            dumpInstructionTexts("macro", macro_flat);
            dumpInstructionTexts("manual", manual_flat);
        }
        try expectFlattenEquivalent(macro_flat, manual_flat);

        const macro_verified = try saasm.referee.verify(std.testing.allocator, macro_flat.instructions, macro_flat.const_decls);
        switch (macro_verified) {
            .ok => |ok| {
                var owned = ok;
                defer owned.deinit(std.testing.allocator);
            },
            .trap => |report| {
                std.debug.print("macro async verifier trap: {s}\n", .{report.message});
                return error.TestUnexpectedResult;
            },
        }
        const manual_verified = try saasm.referee.verify(std.testing.allocator, manual_flat.instructions, manual_flat.const_decls);
        switch (manual_verified) {
            .ok => |ok| {
                var owned = ok;
                defer owned.deinit(std.testing.allocator);
            },
            .trap => |report| {
                std.debug.print("manual async verifier trap: {s}\n", .{report.message});
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "sa_std io helpers are concrete and verifiable" {
    const io_iface = try readFileAlloc(std.testing.allocator, "sa_std/io.sai");
    defer std.testing.allocator.free(io_iface);
    try std.testing.expect(std.mem.containsAtLeast(u8, io_iface, 1, "sa_std_println"));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_iface, 1, "sa_io_read_line"));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_iface, 1, "sa_io_buffer_data"));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_iface, 1, "sa_io_buffer_free"));

    const io_src = try readFileAlloc(std.testing.allocator, "sa_std/io.sa");
    defer std.testing.allocator.free(io_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, io_src, 1, "@import \"fmt.sai\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_src, 1, "[MACRO] PRINTLN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_src, 1, "[MACRO] READ_LINE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_src, 1, "[MACRO] FORMAT_INT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_src, 1, "[MACRO] IO_CURSOR_READ_EXACT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_src, 1, "[MACRO] IO_CURSOR_FILL_BUF"));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_src, 1, "[MACRO] IO_CURSOR_CONSUME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_src, 1, "[MACRO] IO_CURSOR_WRITE_ALL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_src, 1, "[MACRO] IO_EMPTY_READ_EXACT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_src, 1, "[MACRO] IO_REPEAT_READ_EXACT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_src, 1, "[MACRO] IO_SINK_WRITE_ALL"));

    var io_flat = try flattenFixture(std.testing.allocator, "sa_std/io.sa", io_src);
    defer io_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 24), io_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 24), io_flat.function_sigs.len);
}

test "sa_std buffered io helpers are concrete and verifiable" {
    const buf_reader_src = try readFileAlloc(std.testing.allocator, "sa_std/io/buf_reader.sa");
    defer std.testing.allocator.free(buf_reader_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, buf_reader_src, 1, "@import \"../io.sai\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, buf_reader_src, 1, "[MACRO] BUF_READER_READ_LINE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, buf_reader_src, 1, "[MACRO] BUF_READER_READ"));
    try std.testing.expect(std.mem.containsAtLeast(u8, buf_reader_src, 1, "[MACRO] BUF_READER_READ_EXACT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, buf_reader_src, 1, "[MACRO] BUF_READER_FREE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, buf_reader_src, 1, "[MACRO] BUF_READER_CLOSE"));

    var buf_reader_flat = try flattenFixture(std.testing.allocator, "sa_std/io/buf_reader.sa", buf_reader_src);
    defer buf_reader_flat.deinit(std.testing.allocator);
    try std.testing.expect(buf_reader_flat.function_sigs.len > 0);

    const buf_writer_src = try readFileAlloc(std.testing.allocator, "sa_std/io/buf_writer.sa");
    defer std.testing.allocator.free(buf_writer_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, buf_writer_src, 1, "@import \"../io.sai\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, buf_writer_src, 1, "[MACRO] BUF_WRITER_WRITE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, buf_writer_src, 1, "[MACRO] BUF_WRITER_WRITE_ALL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, buf_writer_src, 1, "[MACRO] BUF_WRITER_FLUSH"));
    try std.testing.expect(std.mem.containsAtLeast(u8, buf_writer_src, 1, "[MACRO] BUF_WRITER_CLOSE"));

    var buf_writer_flat = try flattenFixture(std.testing.allocator, "sa_std/io/buf_writer.sa", buf_writer_src);
    defer buf_writer_flat.deinit(std.testing.allocator);
    try std.testing.expect(buf_writer_flat.function_sigs.len > 0);
}

test "sa_std math helpers are concrete and verifiable" {
    const math_src = try readFileAlloc(std.testing.allocator, "sa_std/math.sa");
    defer std.testing.allocator.free(math_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, math_src, 1, "[MACRO] MATH_ABS_I64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, math_src, 1, "[MACRO] MATH_MIN_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, math_src, 1, "[MACRO] MATH_MAX_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, math_src, 1, "[MACRO] MATH_CLAMP_U64"));

    var math_flat = try saasm.flattener.flatten(std.testing.allocator, math_src);
    defer math_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), math_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), math_flat.function_sigs.len);
}

test "sa_std string_format helpers are concrete and verifiable" {
    const string_format_src = try readFileAlloc(std.testing.allocator, "sa_std/string_format.sa");
    defer std.testing.allocator.free(string_format_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, string_format_src, 1, "@import \"fmt.sai\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_format_src, 1, "[MACRO] STRFMT_I64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_format_src, 1, "[MACRO] STRFMT_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_format_src, 1, "[MACRO] STRFMT_F64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_format_src, 1, "[MACRO] STRFMT_BOOL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_format_src, 1, "[MACRO] STRFMT_BYTES"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_format_src, 1, "[MACRO] STRFMT_I64_INTO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_format_src, 1, "[MACRO] STRFMT_U64_INTO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_format_src, 1, "[MACRO] STRFMT_F64_INTO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_format_src, 1, "[MACRO] STRFMT_BOOL_INTO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_format_src, 1, "[MACRO] STRFMT_BYTES_INTO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_format_src, 1, "[MACRO] STRFMT_DATA"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_format_src, 1, "[MACRO] STRFMT_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_format_src, 1, "[MACRO] STRFMT_WRITE_TO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string_format_src, 1, "[MACRO] STRFMT_FREE"));

    var string_format_flat = try flattenFixture(std.testing.allocator, "sa_std/string_format.sa", string_format_src);
    defer string_format_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 14), string_format_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 14), string_format_flat.function_sigs.len);
}

test "sa_std path helpers are concrete and verifiable" {
    const path_src = try readFileAlloc(std.testing.allocator, "sa_std/path.sa");
    defer std.testing.allocator.free(path_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "@import \"core/slice.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "@import \"core/slice.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "@import \"string.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_BASENAME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_DIRNAME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_STEM"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_EXT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_IS_ABSOLUTE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_HAS_ROOT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_IS_RELATIVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_IS_EMPTY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_STARTS_WITH"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_TRY_STRIP_PREFIX"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_ENDS_WITH"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_JOIN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_PARENT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_FILE_PREFIX"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_FILE_STEM"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_EXTENSION"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_WITH_FILE_NAME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_ANCESTOR_COUNT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_TRY_ANCESTOR_AT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_TRY_EXISTS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_METADATA"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_CANONICALIZE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_READ_LINK"));

    var path_flat = try flattenFixture(std.testing.allocator, "sa_std/path.sa", path_src);
    defer path_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), path_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), path_flat.function_sigs.len);
}

test "sa_std path module exercises real string macros" {
    const path_src = try readFileAlloc(std.testing.allocator, "sa_std/path.sa");
    defer std.testing.allocator.free(path_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_BASENAME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_DIRNAME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_STEM"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_EXT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "[MACRO] PATH_JOIN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path_src, 1, "EXPAND STR_CONCAT"));

    var path_flat = try flattenFixture(std.testing.allocator, "sa_std/path.sa", path_src);
    defer path_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), path_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), path_flat.function_sigs.len);
}

test "sa_std string concat runtime helper is usable from C" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const runtime_source = try original_cwd.realpathAlloc(std.testing.allocator, "src/runtime/sa_std.zig");
    defer std.testing.allocator.free(runtime_source);
    const pthread_host_source = try original_cwd.realpathAlloc(std.testing.allocator, "src/runtime/sa_pthread_host.c");
    defer std.testing.allocator.free(pthread_host_source);
    const include_dir = try original_cwd.realpathAlloc(std.testing.allocator, "src/runtime");
    defer std.testing.allocator.free(include_dir);

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const c_source =
        \\#include "sa_std.h"
        \\#include <stdint.h>
        \\#include <stdio.h>
        \\#include <string.h>
        \\
        \\int main(void) {
        \\    const uint8_t *left = (const uint8_t *)"hello, ";
        \\    const uint8_t *right = (const uint8_t *)"world";
        \\    uint64_t handle = sa_string_concat(left, 7, right, 5);
        \\    uint64_t len = 0;
        \\    uint8_t *bytes = NULL;
        \\    if (handle == 0) return 2;
        \\    len = sa_fmt_buffer_len(handle);
        \\    if (len != 12) return 3;
        \\    bytes = sa_fmt_buffer_data(handle);
        \\    if (bytes == NULL) return 4;
        \\    if (memcmp(bytes, "hello, world", 12) != 0) return 5;
        \\    if (sa_fmt_buffer_free(handle) != SA_STD_OK) return 6;
        \\    puts("sa_std string concat ok");
        \\    return 0;
        \\}
        \\
    ;
    try writeSource(tmp.dir, "main.c", c_source);

    const build_lib_argv = [_][]const u8{
        "zig",
        "build-lib",
        runtime_source,
        pthread_host_source,
        "-O",
        "Debug",
        "-lc",
        "-femit-bin=libsa_std.a",
    };
    const build_lib_result = try runCommand(std.testing.allocator, build_lib_argv[0..]);
    defer std.testing.allocator.free(build_lib_result.stdout);
    defer std.testing.allocator.free(build_lib_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_lib_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const build_demo_argv = [_][]const u8{
        "zig",
        "cc",
        "-I",
        include_dir,
        "main.c",
        "libsa_std.a",
        "-lc",
        "-o",
        "sa_std_string_concat_demo",
    };
    const build_demo_result = try runCommand(std.testing.allocator, build_demo_argv[0..]);
    defer std.testing.allocator.free(build_demo_result.stdout);
    defer std.testing.allocator.free(build_demo_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_demo_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const run_result = try runCommand(std.testing.allocator, &.{"./sa_std_string_concat_demo"});
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (run_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });
    try std.testing.expectEqualStrings("sa_std string concat ok\n", run_result.stdout);
}

test "sa_std no-alloc format helpers write into caller buffers" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const runtime_source = try original_cwd.realpathAlloc(std.testing.allocator, "src/runtime/sa_std.zig");
    defer std.testing.allocator.free(runtime_source);
    const pthread_host_source = try original_cwd.realpathAlloc(std.testing.allocator, "src/runtime/sa_pthread_host.c");
    defer std.testing.allocator.free(pthread_host_source);
    const include_dir = try original_cwd.realpathAlloc(std.testing.allocator, "src/runtime");
    defer std.testing.allocator.free(include_dir);

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const c_source =
        \\#include "sa_std.h"
        \\#include <stdint.h>
        \\#include <stdio.h>
        \\#include <string.h>
        \\
        \\int main(void) {
        \\    uint8_t buf[32] = {0};
        \\    uint64_t len = 0;
        \\    if (sa_fmt_i64_into(-42, 10, buf, sizeof(buf), &len) != SA_STD_OK) return 2;
        \\    if (len != 3 || memcmp(buf, "-42", 3) != 0) return 3;
        \\    memset(buf, 0, sizeof(buf));
        \\    if (sa_fmt_u64_into(255, 16, buf, sizeof(buf), &len) != SA_STD_OK) return 4;
        \\    if (len != 2 || memcmp(buf, "ff", 2) != 0) return 5;
        \\    memset(buf, 0, sizeof(buf));
        \\    if (sa_fmt_bool_into(1, buf, sizeof(buf), &len) != SA_STD_OK) return 6;
        \\    if (len != 4 || memcmp(buf, "true", 4) != 0) return 7;
        \\    memset(buf, 0, sizeof(buf));
        \\    if (sa_fmt_bytes_into((const uint8_t *)"abc", 3, buf, sizeof(buf), &len) != SA_STD_OK) return 8;
        \\    if (len != 3 || memcmp(buf, "abc", 3) != 0) return 9;
        \\    if (sa_fmt_i64_into(12345, 10, buf, 2, &len) != SA_STD_ERR_TRUNCATED) return 10;
        \\    if (len != 5) return 11;
        \\    puts("sa_std fmt into ok");
        \\    return 0;
        \\}
        \\
    ;
    try writeSource(tmp.dir, "main.c", c_source);

    const build_lib_argv = [_][]const u8{
        "zig",
        "build-lib",
        runtime_source,
        pthread_host_source,
        "-O",
        "Debug",
        "-lc",
        "-femit-bin=libsa_std.a",
    };
    const build_lib_result = try runCommand(std.testing.allocator, build_lib_argv[0..]);
    defer std.testing.allocator.free(build_lib_result.stdout);
    defer std.testing.allocator.free(build_lib_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_lib_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const build_demo_argv = [_][]const u8{
        "zig",
        "cc",
        "-I",
        include_dir,
        "main.c",
        "libsa_std.a",
        "-lc",
        "-o",
        "sa_std_fmt_into_demo",
    };
    const build_demo_result = try runCommand(std.testing.allocator, build_demo_argv[0..]);
    defer std.testing.allocator.free(build_demo_result.stdout);
    defer std.testing.allocator.free(build_demo_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_demo_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const run_result = try runCommand(std.testing.allocator, &.{"./sa_std_fmt_into_demo"});
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (run_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });
    try std.testing.expectEqualStrings("sa_std fmt into ok\n", run_result.stdout);
}

test "sa_std env helpers are concrete and verifiable" {
    const env_src = try readFileAlloc(std.testing.allocator, "sa_std/env.sa");
    defer std.testing.allocator.free(env_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, env_src, 1, "@import \"env.sai\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, env_src, 1, "[MACRO] ENV_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, env_src, 1, "[MACRO] ENV_CURRENT_DIR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, env_src, 1, "[MACRO] ENV_TEMP_DIR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, env_src, 1, "[MACRO] ENV_CURRENT_EXE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, env_src, 1, "[MACRO] ENV_ARGS_JSON"));
    try std.testing.expect(std.mem.containsAtLeast(u8, env_src, 1, "[MACRO] ENV_VARS_JSON"));
    try std.testing.expect(std.mem.containsAtLeast(u8, env_src, 1, "[MACRO] ENV_SPLIT_PATHS_JSON"));
    try std.testing.expect(std.mem.containsAtLeast(u8, env_src, 1, "[MACRO] ENV_SPLIT_PATHS_JSON_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, env_src, 1, "[MACRO] ENV_JOIN_PATHS_JSON"));
    try std.testing.expect(std.mem.containsAtLeast(u8, env_src, 1, "[MACRO] ENV_JOIN_PATHS_JSON_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, env_src, 1, "[MACRO] ENV_HAS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, env_src, 1, "[MACRO] ENV_BUFFER_FREE"));

    var env_flat = try flattenFixture(std.testing.allocator, "sa_std/env.sa", env_src);
    defer env_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 11), env_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 9), env_flat.function_sigs.len);
}

test "sa_std env runtime helper is usable from C" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const runtime_source = try original_cwd.realpathAlloc(std.testing.allocator, "src/runtime/sa_std.zig");
    defer std.testing.allocator.free(runtime_source);
    const pthread_host_source = try original_cwd.realpathAlloc(std.testing.allocator, "src/runtime/sa_pthread_host.c");
    defer std.testing.allocator.free(pthread_host_source);
    const include_dir = try original_cwd.realpathAlloc(std.testing.allocator, "src/runtime");
    defer std.testing.allocator.free(include_dir);

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const c_source =
        \\#include "sa_std.h"
        \\#include <stdint.h>
        \\#include <stdio.h>
        \\#include <string.h>
        \\
        \\static int has_bytes(const uint8_t *data, uint64_t len, const uint8_t *needle, uint64_t needle_len) {
        \\    uint64_t i = 0;
        \\    if (needle_len == 0) return 1;
        \\    if (len < needle_len) return 0;
        \\    while (i + needle_len <= len) {
        \\        if (memcmp(data + i, needle, needle_len) == 0) return 1;
        \\        i++;
        \\    }
        \\    return 0;
        \\}
        \\
        \\int main(void) {
        \\    const uint8_t key[] = "PATH";
        \\    const uint8_t mutation_key[] = "__SA_STD_ENV_C_MUTATION_TEST__";
        \\    const uint8_t mutation_value[] = "sa-env-c-value";
        \\    const uint8_t expected_arg[] = "sa-env-arg-probe";
        \\    const uint8_t expected_env_key[] = "PATH";
        \\    const uint8_t path_list[] = "alpha:beta:gamma";
        \\    const uint8_t expected_path_segment[] = "beta";
        \\    const uint8_t paths_json[] = "[\"alpha\",\"beta\",\"gamma\"]";
        \\    const uint8_t expected_joined[] = "alpha:beta:gamma";
        \\    uint64_t handle = 0;
        \\    uint8_t *data = NULL;
        \\    uint64_t len = 0;
        \\
        \\    handle = sa_env_current_dir();
        \\    if (handle == 0) return 1;
        \\    if (sa_env_buffer_len(handle) == 0) return 11;
        \\    if (sa_env_buffer_free(handle) != SA_STD_OK) return 12;
        \\    handle = sa_env_temp_dir();
        \\    if (handle == 0) return 13;
        \\    if (sa_env_buffer_len(handle) == 0) return 14;
        \\    if (sa_env_buffer_free(handle) != SA_STD_OK) return 15;
        \\    handle = sa_env_current_exe();
        \\    if (handle == 0) return 16;
        \\    if (sa_env_buffer_len(handle) == 0) return 17;
        \\    if (sa_env_buffer_free(handle) != SA_STD_OK) return 18;
        \\    handle = sa_env_args_json();
        \\    if (handle == 0) return 27;
        \\    len = sa_env_buffer_len(handle);
        \\    data = sa_env_buffer_data(handle);
        \\    if (len < 2 || data == NULL || data[0] != '[' || data[len - 1] != ']') return 28;
        \\    if (!has_bytes(data, len, expected_arg, sizeof(expected_arg) - 1)) return 29;
        \\    if (sa_env_buffer_free(handle) != SA_STD_OK) return 30;
        \\    handle = sa_env_vars_json();
        \\    if (handle == 0) return 31;
        \\    len = sa_env_buffer_len(handle);
        \\    data = sa_env_buffer_data(handle);
        \\    if (len < 2 || data == NULL || data[0] != '[' || data[len - 1] != ']') return 32;
        \\    if (!has_bytes(data, len, expected_env_key, sizeof(expected_env_key) - 1)) return 33;
        \\    if (sa_env_buffer_free(handle) != SA_STD_OK) return 34;
        \\    handle = sa_env_split_paths_json(path_list, sizeof(path_list) - 1);
        \\    if (handle == 0) return 35;
        \\    len = sa_env_buffer_len(handle);
        \\    data = sa_env_buffer_data(handle);
        \\    if (len < 2 || data == NULL || data[0] != '[' || data[len - 1] != ']') return 36;
        \\    if (!has_bytes(data, len, expected_path_segment, sizeof(expected_path_segment) - 1)) return 37;
        \\    if (sa_env_buffer_free(handle) != SA_STD_OK) return 38;
        \\    handle = sa_env_join_paths_json(paths_json, sizeof(paths_json) - 1);
        \\    if (handle == 0) return 39;
        \\    len = sa_env_buffer_len(handle);
        \\    data = sa_env_buffer_data(handle);
        \\    if (len != sizeof(expected_joined) - 1 || data == NULL || memcmp(data, expected_joined, sizeof(expected_joined) - 1) != 0) return 40;
        \\    if (sa_env_buffer_free(handle) != SA_STD_OK) return 41;
        \\
        \\    if (sa_env_has(key, sizeof(key) - 1) != SA_STD_OK) return 2;
        \\    handle = sa_env_get(key, sizeof(key) - 1);
        \\    if (handle == 0) return 3;
        \\    len = sa_env_buffer_len(handle);
        \\    if (len == 0) return 4;
        \\    data = sa_env_buffer_data(handle);
        \\    if (data == NULL) return 5;
        \\    if (memchr(data, ':', len) == NULL) return 6;
        \\    if (sa_env_buffer_free(handle) != SA_STD_OK) return 7;
        \\    if (sa_env_remove_var(mutation_key, sizeof(mutation_key) - 1) != SA_STD_OK) return 19;
        \\    if (sa_env_set_var(mutation_key, sizeof(mutation_key) - 1, mutation_value, sizeof(mutation_value) - 1) != SA_STD_OK) return 20;
        \\    if (sa_env_has(mutation_key, sizeof(mutation_key) - 1) != SA_STD_OK) return 21;
        \\    handle = sa_env_get(mutation_key, sizeof(mutation_key) - 1);
        \\    if (handle == 0) return 22;
        \\    len = sa_env_buffer_len(handle);
        \\    data = sa_env_buffer_data(handle);
        \\    if (len != sizeof(mutation_value) - 1 || data == NULL || memcmp(data, mutation_value, sizeof(mutation_value) - 1) != 0) return 23;
        \\    if (sa_env_buffer_free(handle) != SA_STD_OK) return 24;
        \\    if (sa_env_remove_var(mutation_key, sizeof(mutation_key) - 1) != SA_STD_OK) return 25;
        \\    if (sa_env_has(mutation_key, sizeof(mutation_key) - 1) == SA_STD_OK) return 26;
        \\    puts("sa_std env ok");
        \\    return 0;
        \\}
        \\
    ;
    try writeSource(tmp.dir, "main.c", c_source);
    const build_lib_argv = [_][]const u8{
        "zig",
        "build-lib",
        runtime_source,
        pthread_host_source,
        "-O",
        "Debug",
        "-lc",
        "-femit-bin=libsa_std.a",
    };
    const build_lib_result = try runCommand(std.testing.allocator, build_lib_argv[0..]);
    defer std.testing.allocator.free(build_lib_result.stdout);
    defer std.testing.allocator.free(build_lib_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_lib_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const build_demo_argv = [_][]const u8{
        "zig",
        "cc",
        "-I",
        include_dir,
        "main.c",
        "libsa_std.a",
        "-lc",
        "-o",
        "sa_std_env_demo",
    };
    const build_demo_result = try runCommand(std.testing.allocator, build_demo_argv[0..]);
    defer std.testing.allocator.free(build_demo_result.stdout);
    defer std.testing.allocator.free(build_demo_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_demo_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const run_result = try runCommand(std.testing.allocator, &.{ "./sa_std_env_demo", "sa-env-arg-probe" });
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (run_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });
    try std.testing.expectEqualStrings("sa_std env ok\n", run_result.stdout);
}

test "sa_std fs helper declarations stay aligned" {
    const fs_iface = try readFileAlloc(std.testing.allocator, "sa_std/fs.sai");
    defer std.testing.allocator.free(fs_iface);
    const fs_src = try readFileAlloc(std.testing.allocator, "sa_std/fs.sa");
    defer std.testing.allocator.free(fs_src);
    const c_header = try readFileAlloc(std.testing.allocator, "src/runtime/sa_std.h");
    defer std.testing.allocator.free(c_header);

    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_std_fs_open_read(&path: ptr, path_len: u64, &out_handle: ptr) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_std_fs_file_read(file: u64, &buf: ptr, cap: u64, &out_read: ptr) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_std_fs_file_seek(file: u64, whence: u32, offset: i64, &out_pos: ptr) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_std_fs_try_exists(&path: ptr, path_len: u64, &out_exists: ptr) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_std_fs_read_file(&path: ptr, path_len: u64, max_bytes: u64, &out_handle: ptr) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_std_fs_read_to_string(&path: ptr, path_len: u64, max_bytes: u64, &out_handle: ptr) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_std_fs_metadata(&path: ptr, path_len: u64, &out_handle: ptr) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_fs_file_sync_data(file: u64) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_std_fs_canonicalize(&path: ptr, path_len: u64, &out_handle: ptr) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_fs_read_file_base64(&path: ptr, path_len: u64, max_bytes: u64) -> u64!"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_fs_write_file_base64(&path: ptr, path_len: u64, &data_base64: ptr, data_base64_len: u64) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_fs_read_dir_json(&path: ptr, path_len: u64, max_entries: u64) -> u64!"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_fs_metadata(&path: ptr, path_len: u64) -> u64!"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_fs_metadata_json(&path: ptr, path_len: u64) -> u64!"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_fs_make_dir(&path: ptr, path_len: u64) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_fs_create_dir(&path: ptr, path_len: u64) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_fs_remove_dir_all(&path: ptr, path_len: u64) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_fs_remove_path(&path: ptr, path_len: u64) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_fs_copy_file(&from_path: ptr, from_len: u64, &to_path: ptr, to_len: u64) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_fs_set_permissions(&path: ptr, path_len: u64, mode: u32) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_fs_set_times_ms(&path: ptr, path_len: u64, accessed_ms: i64, modified_ms: i64) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_fs_hard_link(&from_path: ptr, from_len: u64, &to_path: ptr, to_len: u64) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_fs_symlink(&target_path: ptr, target_len: u64, &link_path: ptr, link_len: u64) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_iface, 1, "@extern sa_std_fs_read_link(&path: ptr, path_len: u64, &out_handle: ptr) -> i32"));

    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_OPEN_READ"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_READ"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_SYNC_DATA"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_SYNC_ALL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_SET_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_TRY_EXISTS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_METADATA_IS_DIR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_READ_TO_STRING"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_READ_DIR_JSON"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_CANONICALIZE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_CREATE_DIR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_REMOVE_DIR_ALL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_COPY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_SET_PERMISSIONS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_SET_TIMES_MS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_HARD_LINK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_SYMLINK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fs_src, 1, "[MACRO] FS_READ_LINK"));

    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_std_fs_read_file(const uint8_t *path, uint64_t path_len, uint64_t max_bytes, uint64_t *out_handle);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_std_fs_read_to_string(const uint8_t *path, uint64_t path_len, uint64_t max_bytes, uint64_t *out_handle);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_fs_file_sync_data(uint64_t handle);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_std_fs_canonicalize(const uint8_t *path, uint64_t path_len, uint64_t *out_handle);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_fs_set_permissions(const uint8_t *path, uint64_t path_len, uint32_t mode);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_fs_set_times_ms(const uint8_t *path, uint64_t path_len, int64_t accessed_ms, int64_t modified_ms);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_fs_hard_link(const uint8_t *from_path, uint64_t from_len, const uint8_t *to_path, uint64_t to_len);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_fs_symlink(const uint8_t *target_path, uint64_t target_len, const uint8_t *link_path, uint64_t link_len);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_std_fs_read_link(const uint8_t *path, uint64_t path_len, uint64_t *out_handle);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_std_fs_file_seek(uint64_t handle, uint32_t whence, int64_t offset, uint64_t *out_pos);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_std_fs_try_exists(const uint8_t *path, uint64_t path_len, uint8_t *out_exists);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_std_fs_metadata(const uint8_t *path, uint64_t path_len, uint64_t *out_handle);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "sa_std_fallible_u64 sa_fs_read_file_base64(const uint8_t *path, uint64_t path_len, uint64_t max_bytes);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "sa_std_fallible_u64 sa_fs_read_to_string(const uint8_t *path, uint64_t path_len, uint64_t max_bytes);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_fs_write_file_base64(const uint8_t *path, uint64_t path_len, const uint8_t *data_base64, uint64_t data_base64_len);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "sa_std_fallible_u64 sa_fs_read_dir_json(const uint8_t *path, uint64_t path_len, uint64_t max_entries);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "sa_std_fallible_u64 sa_fs_metadata(const uint8_t *path, uint64_t path_len);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "sa_std_fallible_u64 sa_fs_metadata_json(const uint8_t *path, uint64_t path_len);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_fs_make_dir(const uint8_t *path, uint64_t path_len);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_fs_create_dir(const uint8_t *path, uint64_t path_len);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_fs_remove_dir_all(const uint8_t *path, uint64_t path_len);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_fs_remove_path(const uint8_t *path, uint64_t path_len);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, c_header, 1, "int32_t sa_fs_copy_file(const uint8_t *from_path, uint64_t from_len, const uint8_t *to_path, uint64_t to_len);"));
}

test "sa_std fs base64 and directory helpers are usable from C" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const runtime_source = try original_cwd.realpathAlloc(std.testing.allocator, "src/runtime/sa_std.zig");
    defer std.testing.allocator.free(runtime_source);
    const pthread_host_source = try original_cwd.realpathAlloc(std.testing.allocator, "src/runtime/sa_pthread_host.c");
    defer std.testing.allocator.free(pthread_host_source);
    const include_dir = try original_cwd.realpathAlloc(std.testing.allocator, "src/runtime");
    defer std.testing.allocator.free(include_dir);

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const c_source =
        \\#include "sa_std.h"
        \\#include <stdint.h>
        \\#include <stdio.h>
        \\#include <string.h>
        \\
        \\int main(void) {
        \\    const uint8_t dir[] = "fs_demo_dir/nested";
        \\    const uint8_t root_dir[] = "fs_demo_dir";
        \\    const uint8_t single_dir[] = "fs_single_dir";
        \\    const uint8_t remove_all_dir[] = "fs_remove_all_dir";
        \\    const uint8_t remove_all_nested[] = "fs_remove_all_dir/nested";
        \\    const uint8_t path[] = "fs_demo_dir/nested/hello.txt";
        \\    const uint8_t copy_path[] = "fs_demo_dir/nested/copy.txt";
        \\    const uint8_t encoded[] = "aGVsbG8=";
        \\    sa_std_fallible_u64 read_result = {0};
        \\    sa_std_fallible_u64 string_result = {0};
        \\    sa_std_fallible_u64 dir_result = {0};
        \\    sa_std_fallible_u64 metadata_json_result = {0};
        \\    sa_std_fallible_u64 metadata_result = {0};
        \\    sa_std_fallible_i32 metadata_free_result = {0};
        \\    uint8_t *read_data = NULL;
        \\    uint64_t read_len = 0;
        \\    uint8_t *string_data = NULL;
        \\    uint64_t string_len = 0;
        \\    uint8_t *dir_data = NULL;
        \\    uint64_t dir_len = 0;
        \\    uint8_t *metadata_data = NULL;
        \\    uint64_t metadata_len = 0;
        \\    uint8_t try_exists_value = 255;
        \\
        \\    if (sa_std_fs_try_exists(path, sizeof(path) - 1, &try_exists_value) != SA_STD_OK) return 35;
        \\    if (try_exists_value != 0) return 36;
        \\    if (sa_fs_make_dir(dir, sizeof(dir) - 1) != SA_STD_OK) return 2;
        \\    if (sa_fs_make_dir(dir, sizeof(dir) - 1) != SA_STD_OK) return 12;
        \\    if (sa_fs_create_dir(single_dir, sizeof(single_dir) - 1) != SA_STD_OK) return 26;
        \\    if (sa_fs_create_dir(single_dir, sizeof(single_dir) - 1) == SA_STD_OK) return 27;
        \\    if (sa_fs_remove_dir(single_dir, sizeof(single_dir) - 1) != SA_STD_OK) return 28;
        \\    if (sa_fs_make_dir(remove_all_nested, sizeof(remove_all_nested) - 1) != SA_STD_OK) return 29;
        \\    if (sa_fs_remove_dir(remove_all_dir, sizeof(remove_all_dir) - 1) == SA_STD_OK) return 30;
        \\    if (sa_fs_remove_dir_all(remove_all_dir, sizeof(remove_all_dir) - 1) != SA_STD_OK) return 31;
        \\    if (sa_fs_write_file_base64(path, sizeof(path) - 1, encoded, sizeof(encoded) - 1) != SA_STD_OK) return 3;
        \\    try_exists_value = 0;
        \\    if (sa_std_fs_try_exists(path, sizeof(path) - 1, &try_exists_value) != SA_STD_OK) return 37;
        \\    if (try_exists_value != 1) return 38;
        \\    string_result = sa_fs_read_to_string(path, sizeof(path) - 1, 1024);
        \\    if (string_result.status != SA_STD_OK || string_result.value == 0) return 32;
        \\    string_data = sa_fs_read_buffer_data(string_result.value);
        \\    string_len = sa_fs_read_buffer_len(string_result.value);
        \\    if (string_len != 5 || memcmp(string_data, "hello", 5) != 0) return 33;
        \\    if (sa_fs_read_buffer_free(string_result.value) != SA_STD_OK) return 34;
        \\    read_result = sa_fs_read_file_base64(path, sizeof(path) - 1, 1024);
        \\    if (read_result.status != SA_STD_OK || read_result.value == 0) return 4;
        \\    read_data = sa_fs_read_buffer_data(read_result.value);
        \\    read_len = sa_fs_read_buffer_len(read_result.value);
        \\    if (read_len != sizeof(encoded) - 1 || memcmp(read_data, encoded, sizeof(encoded) - 1) != 0) return 5;
        \\    if (sa_fs_read_buffer_free(read_result.value) != SA_STD_OK) return 6;
        \\
        \\    dir_result = sa_fs_read_dir_json(dir, sizeof(dir) - 1, 32);
        \\    if (dir_result.status != SA_STD_OK || dir_result.value == 0) return 7;
        \\    dir_data = sa_fs_dir_buffer_data(dir_result.value);
        \\    dir_len = sa_fs_dir_buffer_len(dir_result.value);
        \\    if (dir_len == 0) return 8;
        \\    if (memmem(dir_data, dir_len, "hello.txt", 9) == NULL) return 9;
        \\    if (memmem(dir_data, dir_len, "\"isFile\":true", 13) == NULL) return 10;
        \\    if (sa_fs_dir_buffer_free(dir_result.value) != SA_STD_OK) return 11;
        \\
        \\    if (sa_fs_copy_file(path, sizeof(path) - 1, copy_path, sizeof(copy_path) - 1) != SA_STD_OK) return 13;
        \\    if (sa_fs_set_times_ms(copy_path, sizeof(copy_path) - 1, 1700000000000LL, 1700000000000LL) != SA_STD_OK) return 25;
        \\    metadata_json_result = sa_fs_metadata_json(copy_path, sizeof(copy_path) - 1);
        \\    if (metadata_json_result.status != SA_STD_OK || metadata_json_result.value == 0) return 14;
        \\    metadata_data = sa_fs_read_buffer_data(metadata_json_result.value);
        \\    metadata_len = sa_fs_read_buffer_len(metadata_json_result.value);
        \\    if (metadata_len == 0) return 15;
        \\    if (memmem(metadata_data, metadata_len, "\"isFile\":true", 13) == NULL) return 16;
        \\    if (memmem(metadata_data, metadata_len, "\"isDirectory\":false", 19) == NULL) return 17;
        \\    if (sa_fs_read_buffer_free(metadata_json_result.value) != SA_STD_OK) return 18;
        \\
        \\    metadata_result = sa_fs_metadata(copy_path, sizeof(copy_path) - 1);
        \\    if (metadata_result.status != SA_STD_OK || metadata_result.value == 0) return 19;
        \\    if (sa_fs_metadata_is_file(metadata_result.value) != 1) return 20;
        \\    if (sa_fs_metadata_is_directory(metadata_result.value) != 0) return 21;
        \\    metadata_free_result = sa_fs_metadata_free(metadata_result.value);
        \\    if (metadata_free_result.status != SA_STD_OK) return 22;
        \\
        \\    if (sa_fs_remove_path(root_dir, sizeof(root_dir) - 1) != SA_STD_OK) return 23;
        \\    dir_result = sa_fs_read_dir_json(dir, sizeof(dir) - 1, 32);
        \\    if (dir_result.status == SA_STD_OK) return 24;
        \\    puts("sa_std fs base64 dir metadata copy remove ok");
        \\    return 0;
        \\}
        \\
    ;
    try writeSource(tmp.dir, "main.c", c_source);
    const build_lib_argv = [_][]const u8{
        "zig",
        "build-lib",
        runtime_source,
        pthread_host_source,
        "-O",
        "Debug",
        "-lc",
        "-femit-bin=libsa_std.a",
    };
    const build_lib_result = try runCommand(std.testing.allocator, build_lib_argv[0..]);
    defer std.testing.allocator.free(build_lib_result.stdout);
    defer std.testing.allocator.free(build_lib_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_lib_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const build_demo_argv = [_][]const u8{
        "zig",
        "cc",
        "-I",
        include_dir,
        "main.c",
        "libsa_std.a",
        "-lc",
        "-o",
        "sa_std_fs_base64_demo",
    };
    const build_demo_result = try runCommand(std.testing.allocator, build_demo_argv[0..]);
    defer std.testing.allocator.free(build_demo_result.stdout);
    defer std.testing.allocator.free(build_demo_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_demo_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const run_result = try runCommand(std.testing.allocator, &.{"./sa_std_fs_base64_demo"});
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (run_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });
    try std.testing.expectEqualStrings("sa_std fs base64 dir metadata copy remove ok\n", run_result.stdout);
}

test "sa_std Deno chat SSE fallback splits thought tags across chunks" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const runtime_source = try original_cwd.realpathAlloc(std.testing.allocator, "src/runtime/sa_std.zig");
    defer std.testing.allocator.free(runtime_source);
    const pthread_host_source = try original_cwd.realpathAlloc(std.testing.allocator, "src/runtime/sa_pthread_host.c");
    defer std.testing.allocator.free(pthread_host_source);
    const include_dir = try original_cwd.realpathAlloc(std.testing.allocator, "src/runtime");
    defer std.testing.allocator.free(include_dir);

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const c_source =
        \\#include "sa_std.h"
        \\#include <stdint.h>
        \\#include <stdio.h>
        \\#include <string.h>
        \\
        \\int main(void) {
        \\    const uint8_t chat[] =
        \\        "data: {\"choices\":[{\"delta\":{\"content\":\"<thou\"},\"finish_reason\":null}]}\n\n"
        \\        "data: {\"choices\":[{\"delta\":{\"content\":\"ght>split thought</th\"},\"finish_reason\":null}]}\n\n"
        \\        "data: {\"choices\":[{\"delta\":{\"content\":\"ought>Hello\"},\"finish_reason\":null}]}\n\n"
        \\        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        \\        "data: [DONE]\n\n";
        \\    const uint8_t req[] = "{\"tools\":[{\"type\":\"function\",\"name\":\"exec_command\"}],\"input\":[{\"role\":\"user\",\"content\":\"hello\"}]}";
        \\    const uint8_t goal_req[] = "{\"tools\":[{\"type\":\"function\",\"name\":\"exec_command\"}],\"input\":[{\"role\":\"developer\",\"content\":\"<goal_context>Continue working.</goal_context>\"}]}";
        \\    const uint8_t default_mode_req[] = "{\"tools\":[{\"type\":\"function\",\"name\":\"exec_command\"}],\"input\":[{\"role\":\"developer\",\"content\":\"<collaboration_mode># Collaboration Mode: Default</collaboration_mode>\"}]}";
        \\    const uint8_t namespace_req[] = "{\"tools\":[{\"type\":\"namespace\",\"name\":\"mcp__code_index__\",\"tools\":[{\"type\":\"function\",\"name\":\"describe_index\"}]}]}";
        \\    const uint8_t tool_chat[] =
        \\        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_read\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"filePath\\\":\"},\"index\":0},{\"id\":\"call_cmd\",\"type\":\"function\",\"function\":{\"name\":\"exec_command\",\"arguments\":\"{\\\"command\\\":\"},\"index\":1}]},\"finish_reason\":null}]}\n\n"
        \\        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"type\":\"function\",\"function\":{\"arguments\":\"\\\"/tmp/demo.txt\\\"}\"},\"index\":0},{\"type\":\"function\",\"function\":{\"arguments\":\"\\\"deno check src/main.ts\\\"}\"},\"index\":1}]},\"finish_reason\":null}]}\n\n"
        \\        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n"
        \\        "data: [DONE]\n\n";
        \\    const uint8_t env_chat[] =
        \\        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_read_env\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"filePath\\\":\\\"/tmp/demo/.env.local\\\"}\"},\"index\":0}]},\"finish_reason\":null}]}\n\n"
        \\        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n"
        \\        "data: [DONE]\n\n";
        \\    const uint8_t namespace_chat[] =
        \\        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_mcp\",\"type\":\"function\",\"function\":{\"name\":\"mcp__code_index__describe_index\",\"arguments\":\"{}\"},\"index\":0}]},\"finish_reason\":null}]}\n\n"
        \\        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n"
        \\        "data: [DONE]\n\n";
        \\    const uint8_t progress_chat[] =
        \\        "data: {\"choices\":[{\"delta\":{\"content\":\"Let me check the test failure details and the permission issue.\"},\"finish_reason\":null}]}\n\n"
        \\        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        \\        "data: [DONE]\n\n";
        \\    const uint8_t final_chat[] =
        \\        "data: {\"choices\":[{\"delta\":{\"content\":\"我已完成评估，下面是结论。\"},\"finish_reason\":null}]}\n\n"
        \\        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        \\        "data: [DONE]\n\n";
        \\    uint64_t handle = sa_deno_chat_sse_to_responses(chat, sizeof(chat) - 1, req, sizeof(req) - 1);
        \\    uint64_t tool_handle = 0;
        \\    uint64_t env_handle = 0;
        \\    uint64_t namespace_handle = 0;
        \\    uint64_t progress_handle = 0;
        \\    uint64_t final_handle = 0;
        \\    uint64_t default_mode_handle = 0;
        \\    uint8_t *data = NULL;
        \\    uint64_t len = 0;
        \\    if (handle == 0) return 2;
        \\    data = sa_fs_read_buffer_data(handle);
        \\    len = sa_fs_read_buffer_len(handle);
        \\    if (data == NULL || len == 0) return 3;
        \\    if (memmem(data, len, "response.reasoning_summary_text.delta", 37) == NULL) return 4;
        \\    if (memmem(data, len, "split thought", 13) == NULL) return 5;
        \\    if (memmem(data, len, "\"delta\":\"Hello\"", 15) == NULL) return 6;
        \\    if (memmem(data, len, "<thought>", 9) != NULL) return 7;
        \\    if (memmem(data, len, "</thought>", 10) != NULL) return 8;
        \\    if (memmem(data, len, "\"choices\"", 9) != NULL) return 9;
        \\    if (memmem(data, len, "[DONE]", 6) != NULL) return 10;
        \\    if (sa_fs_read_buffer_free(handle) != SA_STD_OK) return 11;
        \\
        \\    tool_handle = sa_deno_chat_sse_to_responses(tool_chat, sizeof(tool_chat) - 1, req, sizeof(req) - 1);
        \\    if (tool_handle == 0) return 12;
        \\    data = sa_fs_read_buffer_data(tool_handle);
        \\    len = sa_fs_read_buffer_len(tool_handle);
        \\    if (data == NULL || len == 0) return 13;
        \\    if (memmem(data, len, "\"name\":\"exec_command\"", 21) == NULL) return 14;
        \\    if (memmem(data, len, "cat '/tmp/demo.txt'", 19) == NULL) return 15;
        \\    if (memmem(data, len, "deno check src/main.ts", 22) == NULL) return 16;
        \\    if (memmem(data, len, "\"name\":\"read\"", 13) != NULL) return 17;
        \\    if (memmem(data, len, "\"command\"", 9) != NULL) return 18;
        \\    if (memmem(data, len, "\"choices\"", 9) != NULL) return 19;
        \\    if (sa_fs_read_buffer_free(tool_handle) != SA_STD_OK) return 20;
        \\
        \\    env_handle = sa_deno_chat_sse_to_responses(env_chat, sizeof(env_chat) - 1, req, sizeof(req) - 1);
        \\    if (env_handle == 0) return 21;
        \\    data = sa_fs_read_buffer_data(env_handle);
        \\    len = sa_fs_read_buffer_len(env_handle);
        \\    if (data == NULL || len == 0) return 22;
        \\    if (memmem(data, len, "sed -E", 6) == NULL) return 23;
        \\    if (memmem(data, len, "<redacted>", 10) == NULL) return 24;
        \\    if (memmem(data, len, "/tmp/demo/.env.local", 20) == NULL) return 25;
        \\    if (memmem(data, len, "cat '/tmp/demo/.env.local'", 26) != NULL) return 26;
        \\    if (sa_fs_read_buffer_free(env_handle) != SA_STD_OK) return 27;
        \\
        \\    namespace_handle = sa_deno_chat_sse_to_responses(namespace_chat, sizeof(namespace_chat) - 1, namespace_req, sizeof(namespace_req) - 1);
        \\    if (namespace_handle == 0) return 28;
        \\    data = sa_fs_read_buffer_data(namespace_handle);
        \\    len = sa_fs_read_buffer_len(namespace_handle);
        \\    if (data == NULL || len == 0) return 29;
        \\    if (memmem(data, len, "\"namespace\":\"mcp__code_index__\"", 31) == NULL) return 30;
        \\    if (memmem(data, len, "\"name\":\"describe_index\"", 23) == NULL) return 31;
        \\    if (memmem(data, len, "\"output_kind\":\"function_call_output\"", 36) == NULL) return 32;
        \\    if (memmem(data, len, "\"name\":\"mcp__code_index__describe_index\"", 41) != NULL) return 33;
        \\    if (sa_fs_read_buffer_free(namespace_handle) != SA_STD_OK) return 34;
        \\
        \\    progress_handle = sa_deno_chat_sse_to_responses(progress_chat, sizeof(progress_chat) - 1, req, sizeof(req) - 1);
        \\    if (progress_handle == 0) return 35;
        \\    data = sa_fs_read_buffer_data(progress_handle);
        \\    len = sa_fs_read_buffer_len(progress_handle);
        \\    if (data == NULL || len == 0) return 36;
        \\    if (memmem(data, len, "Progress-only message received", 30) != NULL) return 37;
        \\    if (sa_fs_read_buffer_free(progress_handle) != SA_STD_OK) return 38;
        \\
        \\    progress_handle = sa_deno_chat_sse_to_responses(progress_chat, sizeof(progress_chat) - 1, goal_req, sizeof(goal_req) - 1);
        \\    if (progress_handle == 0) return 39;
        \\    data = sa_fs_read_buffer_data(progress_handle);
        \\    len = sa_fs_read_buffer_len(progress_handle);
        \\    if (data == NULL || len == 0) return 40;
        \\    if (memmem(data, len, "Progress-only message received", 30) == NULL) return 41;
        \\    if (sa_fs_read_buffer_free(progress_handle) != SA_STD_OK) return 42;
        \\
        \\    default_mode_handle = sa_deno_chat_sse_to_responses(progress_chat, sizeof(progress_chat) - 1, default_mode_req, sizeof(default_mode_req) - 1);
        \\    if (default_mode_handle == 0) return 43;
        \\    data = sa_fs_read_buffer_data(default_mode_handle);
        \\    len = sa_fs_read_buffer_len(default_mode_handle);
        \\    if (data == NULL || len == 0) return 44;
        \\    if (memmem(data, len, "Progress-only message received", 30) == NULL) return 45;
        \\    if (sa_fs_read_buffer_free(default_mode_handle) != SA_STD_OK) return 46;
        \\
        \\    final_handle = sa_deno_chat_sse_to_responses(final_chat, sizeof(final_chat) - 1, goal_req, sizeof(goal_req) - 1);
        \\    if (final_handle == 0) return 47;
        \\    data = sa_fs_read_buffer_data(final_handle);
        \\    len = sa_fs_read_buffer_len(final_handle);
        \\    if (data == NULL || len == 0) return 48;
        \\    if (memmem(data, len, "Progress-only message received", 30) != NULL) return 49;
        \\    if (sa_fs_read_buffer_free(final_handle) != SA_STD_OK) return 50;
        \\    puts("sa_std deno chat sse thought split ok");
        \\    return 0;
        \\}
        \\
    ;
    try writeSource(tmp.dir, "main.c", c_source);
    const build_lib_argv = [_][]const u8{
        "zig",
        "build-lib",
        runtime_source,
        pthread_host_source,
        "-O",
        "Debug",
        "-lc",
        "-femit-bin=libsa_std.a",
    };
    const build_lib_result = try runCommand(std.testing.allocator, build_lib_argv[0..]);
    defer std.testing.allocator.free(build_lib_result.stdout);
    defer std.testing.allocator.free(build_lib_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_lib_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const build_demo_argv = [_][]const u8{
        "zig",
        "cc",
        "-I",
        include_dir,
        "main.c",
        "libsa_std.a",
        "-lc",
        "-o",
        "sa_std_deno_chat_sse_demo",
    };
    const build_demo_result = try runCommand(std.testing.allocator, build_demo_argv[0..]);
    defer std.testing.allocator.free(build_demo_result.stdout);
    defer std.testing.allocator.free(build_demo_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_demo_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const run_result = try runCommand(std.testing.allocator, &.{"./sa_std_deno_chat_sse_demo"});
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (run_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });
    try std.testing.expectEqualStrings("sa_std deno chat sse thought split ok\n", run_result.stdout);
}

test "sa_std hashmap helpers are concrete and verifiable" {
    const hashmap_layout = try readFileAlloc(std.testing.allocator, "sa_std/hashmap.sal");
    defer std.testing.allocator.free(hashmap_layout);
    try std.testing.expectEqualStrings(
        "#def HashMap_SIZE = 40\n#def HashMap_slots = +0\n#def HashMap_cap = +8\n#def HashMap_len = +16\n#def HashMap_tombs = +24\n#def HashMap_seed = +32\n\n#def HashMapSlot_SIZE = 32\n#def HashMapSlot_hash = +0\n#def HashMapSlot_key = +8\n#def HashMapSlot_value = +16\n#def HashMapSlot_state = +24\n\n#def HashMap_INITIAL_CAP = 8\n#def HashMap_STATE_EMPTY = 0\n#def HashMap_STATE_FILLED = 1\n#def HashMap_STATE_TOMB = 2\n\n#def HashMap_FNV_OFFSET = -3750763034362895579\n#def HashMap_FNV_PRIME = 1099511628211\n",
        hashmap_layout,
    );

    const collections_hashmap = try readFileAlloc(std.testing.allocator, "sa_std/collections/hashmap.sa");
    defer std.testing.allocator.free(collections_hashmap);
    try std.testing.expect(std.mem.containsAtLeast(u8, collections_hashmap, 1, "@import \"../hashmap.sa\""));

    const hashmap_src = try readFileAlloc(std.testing.allocator, "sa_std/hashmap.sa");
    defer std.testing.allocator.free(hashmap_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@import \"core/mem.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@import \"alloc/vec.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@import \"vec.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@import \"num.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@import \"hashmap.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "EXPAND NUM_U64_CHECKED_MUL new_bytes_ok, new_bytes, new_cap, HashMapSlot_SIZE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "EXPAND NUM_U64_CHECKED_ADD needed_ok, needed, len, additional"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "EXPAND NUM_U64_CHECKED_MUL clear_bytes_ok, bytes, cap, HashMapSlot_SIZE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_new"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_with_capacity"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_free"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_put"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_get"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_del"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_contains_key"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_len"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_capacity"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_reserve"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_shrink_to_fit"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_with_seed"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_with_capacity_seed"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_is_empty"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_clear"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_try_get_disjoint_mut_ptrs"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_try_insert"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_keys_vec"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_values_vec"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "@export sa_map_value_mut_ptrs_vec"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_WITH_SEED"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_WITH_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_WITH_CAPACITY_SEED"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_TRY_WITH_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_RESERVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_TRY_RESERVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_SHRINK_TO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_SHRINK_TO_FIT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_IS_EMPTY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_CONTAINS_KEY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_CLEAR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_PUT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_TRY_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_GET_KEY_VALUE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_GET_MUT_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_TRY_GET_DISJOINT_MUT_PTRS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_INSERT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_TRY_INSERT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_KEYS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_VALUES"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_VALUES_MUT_PTRS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_DRAIN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_EXTRACT_IF"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_REMOVE_ENTRY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_DEL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_FREE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_LIT1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_LIT2"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashmap_src, 1, "[MACRO] MAP_LIT3"));

    var hashmap_error_ctx = saasm.flattener.ErrorContext{};
    var hashmap_flat = saasm.flattener.flattenFileWithContext(std.testing.allocator, "sa_std/hashmap.sa", hashmap_src, &hashmap_error_ctx) catch |err| {
        const source_line = saasm.flattener.takeErrorSourceLine(&hashmap_error_ctx) orelse 0;
        std.debug.print("hashmap flatten failed on line {d}: {s}\n", .{ source_line, @errorName(err) });
        return err;
    };
    defer hashmap_flat.deinit(std.testing.allocator);
    try std.testing.expect(hashmap_flat.instructions.len > 0);
    try std.testing.expect(hashmap_flat.function_sigs.len >= 19);

    const hashmap_verified = try saasm.referee.verify(std.testing.allocator, hashmap_flat.instructions, hashmap_flat.const_decls);
    switch (hashmap_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 19);
            try std.testing.expect(owned.annotated.len > 0);
        },
        .trap => |report| {
            std.debug.print(
                "hashmap smoke verifier trap: {s} (line={d}, source_line={d}, function={s}, text={s}, register={s}, expected={s}, actual={s})\n",
                .{
                    report.message,
                    report.line,
                    report.source_line,
                    std.mem.sliceTo(&report.function_buf, 0),
                    std.mem.sliceTo(&report.source_text_buf, 0),
                    if (report.register) |r| r else std.mem.sliceTo(&report.register_buf, 0),
                    if (report.expected_mask_name) |r| r else "",
                    if (report.actual_mask_name) |r| r else "",
                },
            );
            return error.TestUnexpectedResult;
        },
    }

    const hashmap_fixture =
        \\@import "sa_std/collections/hashmap.sa"
        \\
        \\@const KEY = utf8:"alpha"
        \\@const VALUE = utf8:"A\n"
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    EXPAND MAP_WITH_CAPACITY map, 9
        \\    EXPAND MAP_LEN len0, map
        \\    EXPAND MAP_CAPACITY cap0, map
        \\    EXPAND MAP_IS_EMPTY empty0, map
        \\    key = &KEY
        \\    value = &VALUE
        \\    EXPAND MAP_CONTAINS_KEY has0, map, key
        \\    EXPAND MAP_PUT map, key, value
        \\    EXPAND MAP_LEN len1, map
        \\    EXPAND MAP_CAPACITY cap1, map
        \\    EXPAND MAP_RESERVE map, 20
        \\    EXPAND MAP_CAPACITY cap_after_reserve, map
        \\    EXPAND MAP_IS_EMPTY empty1, map
        \\    EXPAND MAP_CONTAINS_KEY has1, map, key
        \\    EXPAND MAP_GET got1, map, key
        \\    EXPAND MAP_CLEAR map
        \\    EXPAND MAP_LEN len2, map
        \\    EXPAND MAP_IS_EMPTY empty2, map
        \\    EXPAND MAP_CONTAINS_KEY has2, map, key
        \\    EXPAND MAP_GET got2, map, key
        \\    ok_len0 = eq len0, 0
        \\    ok_cap0 = eq cap0, 16
        \\    ok_empty0 = eq empty0, 1
        \\    ok_has0 = eq has0, 0
        \\    ok_len1 = eq len1, 1
        \\    ok_cap1 = eq cap1, 16
        \\    ok_cap_after_reserve = eq cap_after_reserve, 32
        \\    ok_empty1 = eq empty1, 0
        \\    ok_has1 = eq has1, 1
        \\    ok_got1 = eq got1, value
        \\    ok_len2 = eq len2, 0
        \\    ok_empty2 = eq empty2, 1
        \\    ok_has2 = eq has2, 0
        \\    ok_got2 = eq got2, 0
        \\    ok01 = and ok_len0, ok_cap0
        \\    ok02 = and ok01, ok_empty0
        \\    ok03 = and ok02, ok_has0
        \\    ok04 = and ok03, ok_len1
        \\    ok05 = and ok04, ok_cap1
        \\    ok06 = and ok05, ok_cap_after_reserve
        \\    ok07 = and ok06, ok_empty1
        \\    ok08 = and ok07, ok_has1
        \\    ok09 = and ok08, ok_got1
        \\    ok10 = and ok09, ok_len2
        \\    ok11 = and ok10, ok_empty2
        \\    ok12 = and ok11, ok_has2
        \\    ok = and ok12, ok_got2
        \\    !got2
        \\    !has2
        \\    !empty2
        \\    !len2
        \\    !got1
        \\    !has1
        \\    !empty1
        \\    !cap_after_reserve
        \\    !len1
        \\    !has0
        \\    !empty0
        \\    !cap1
        \\    !cap0
        \\    !len0
        \\    !value
        \\    !key
        \\    !ok_len0
        \\    !ok_cap0
        \\    !ok_empty0
        \\    !ok_has0
        \\    !ok_len1
        \\    !ok_cap1
        \\    !ok_cap_after_reserve
        \\    !ok_empty1
        \\    !ok_has1
        \\    !ok_got1
        \\    !ok_len2
        \\    !ok_empty2
        \\    !ok_has2
        \\    !ok_got2
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
        \\    EXPAND MAP_FREE map
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
    var hashmap_fixture_flat = try flattenFixture(std.testing.allocator, "tests/hashmap_fixture.sa", hashmap_fixture);
    defer hashmap_fixture_flat.deinit(std.testing.allocator);
    const hashmap_fixture_verified = try saasm.referee.verify(std.testing.allocator, hashmap_fixture_flat.instructions, hashmap_fixture_flat.const_decls);
    switch (hashmap_fixture_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 15);
        },
        .trap => |report| {
            std.debug.print("hashmap fixture verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }
}

test "sa_std hashset helpers are concrete and verifiable" {
    const hashset_layout = try readFileAlloc(std.testing.allocator, "sa_std/hashset.sal");
    defer std.testing.allocator.free(hashset_layout);
    try std.testing.expectEqualStrings(
        "#def HashSet_SIZE = 32\n#def HashSet_slots = +0\n#def HashSet_cap = +8\n#def HashSet_len = +16\n#def HashSet_tombs = +24\n\n#def HashSetSlot_SIZE = 32\n#def HashSetSlot_hash = +0\n#def HashSetSlot_key = +8\n#def HashSetSlot_value = +16\n#def HashSetSlot_state = +24\n\n#def HashSet_INITIAL_CAP = 8\n#def HashSet_STATE_EMPTY = 0\n#def HashSet_STATE_FILLED = 1\n#def HashSet_STATE_TOMB = 2\n\n#def HashSet_VALUE_SENTINEL = 1\n",
        hashset_layout,
    );

    const collections_hashset = try readFileAlloc(std.testing.allocator, "sa_std/collections/hashset.sa");
    defer std.testing.allocator.free(collections_hashset);
    try std.testing.expect(std.mem.containsAtLeast(u8, collections_hashset, 1, "@import \"../hashset.sa\""));

    const hashset_src = try readFileAlloc(std.testing.allocator, "sa_std/hashset.sa");
    defer std.testing.allocator.free(hashset_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@import \"hashset.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@import \"hashmap.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@import \"vec.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_new"));
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
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_union"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_intersection"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_difference"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "@export sa_set_symmetric_difference"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_WITH_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_TRY_WITH_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_RESERVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_TRY_RESERVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_SHRINK_TO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_SHRINK_TO_FIT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_IS_EMPTY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_CLEAR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_INSERT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_CONTAINS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_TAKE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_REPLACE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_IS_DISJOINT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_IS_SUBSET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_IS_SUPERSET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_REMOVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_DRAIN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_EXTRACT_IF"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_UNION"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_INTERSECTION"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_DIFFERENCE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_SYMMETRIC_DIFFERENCE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_FREE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_LIT1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_LIT2"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hashset_src, 1, "[MACRO] SET_LIT3"));

    var hashset_error_ctx = saasm.flattener.ErrorContext{};
    var hashset_flat = saasm.flattener.flattenFileWithContext(std.testing.allocator, "sa_std/hashset.sa", hashset_src, &hashset_error_ctx) catch |err| {
        const source_line = saasm.flattener.takeErrorSourceLine(&hashset_error_ctx) orelse 0;
        std.debug.print("hashset flatten failed on line {d}: {s}\n", .{ source_line, @errorName(err) });
        return err;
    };
    defer hashset_flat.deinit(std.testing.allocator);
    try std.testing.expect(hashset_flat.instructions.len > 0);
    try std.testing.expect(hashset_flat.function_sigs.len >= 27);

    const hashset_verified = try saasm.referee.verify(std.testing.allocator, hashset_flat.instructions, hashset_flat.const_decls);
    switch (hashset_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 27);
            try std.testing.expect(owned.annotated.len > 0);
        },
        .trap => |report| {
            std.debug.print(
                "hashset smoke verifier trap: {s} (line={d}, source_line={d}, function={s}, text={s}, register={s}, expected={s}, actual={s})\n",
                .{
                    report.message,
                    report.line,
                    report.source_line,
                    std.mem.sliceTo(&report.function_buf, 0),
                    std.mem.sliceTo(&report.source_text_buf, 0),
                    if (report.register) |r| r else std.mem.sliceTo(&report.register_buf, 0),
                    if (report.expected_mask_name) |r| r else "",
                    if (report.actual_mask_name) |r| r else "",
                },
            );
            return error.TestUnexpectedResult;
        },
    }

    const hashset_fixture =
        \\@import "sa_std/collections/hashset.sa"
        \\
        \\@const KEY_A = utf8:"alpha"
        \\@const KEY_B = utf8:"bravo"
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    EXPAND SET_NEW set
        \\    EXPAND SET_LEN len0, set
        \\    EXPAND SET_CAPACITY cap0, set
        \\    EXPAND SET_IS_EMPTY empty0, set
        \\    key_a = &KEY_A
        \\    key_b = &KEY_B
        \\    EXPAND SET_INSERT ins_a, set, key_a
        \\    EXPAND SET_INSERT ins_b, set, key_b
        \\    EXPAND SET_LEN len1, set
        \\    EXPAND SET_CAPACITY cap1, set
        \\    EXPAND SET_RESERVE set, 20
        \\    EXPAND SET_CAPACITY cap_after_reserve, set
        \\    EXPAND SET_IS_EMPTY empty1, set
        \\    EXPAND SET_CONTAINS has_a, set, key_a
        \\    EXPAND SET_CLEAR set
        \\    EXPAND SET_LEN len2, set
        \\    EXPAND SET_IS_EMPTY empty2, set
        \\    EXPAND SET_CONTAINS has_a_after, set, key_a
        \\    ok_len0 = eq len0, 0
        \\    ok_cap0 = eq cap0, 0
        \\    ok_empty0 = eq empty0, 1
        \\    ok_ins_a = eq ins_a, 1
        \\    ok_ins_b = eq ins_b, 1
        \\    ok_len1 = eq len1, 2
        \\    ok_cap1 = eq cap1, 8
        \\    ok_cap_after_reserve = eq cap_after_reserve, 32
        \\    ok_empty1 = eq empty1, 0
        \\    ok_has_a = eq has_a, 1
        \\    ok_len2 = eq len2, 0
        \\    ok_empty2 = eq empty2, 1
        \\    ok_has_a_after = eq has_a_after, 0
        \\    ok01 = and ok_len0, ok_cap0
        \\    ok02 = and ok01, ok_empty0
        \\    ok03 = and ok02, ok_ins_a
        \\    ok04 = and ok03, ok_ins_b
        \\    ok05 = and ok04, ok_len1
        \\    ok06 = and ok05, ok_cap1
        \\    ok07 = and ok06, ok_cap_after_reserve
        \\    ok08 = and ok07, ok_empty1
        \\    ok09 = and ok08, ok_has_a
        \\    ok10 = and ok09, ok_len2
        \\    ok11 = and ok10, ok_empty2
        \\    ok = and ok11, ok_has_a_after
        \\    !has_a_after
        \\    !len2
        \\    !has_a
        \\    !empty2
        \\    !empty1
        \\    !cap_after_reserve
        \\    !cap1
        \\    !len1
        \\    !ins_b
        \\    !ins_a
        \\    !empty0
        \\    !cap0
        \\    !len0
        \\    !key_b
        \\    !key_a
        \\    !ok_cap_after_reserve
        \\    !ok11
        \\    EXPAND SET_FREE set
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
    var hashset_fixture_flat = try flattenFixture(std.testing.allocator, "tests/hashset_fixture.sa", hashset_fixture);
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

test "sa_std vec_deque helpers are concrete and verifiable" {
    const deque_layout = try readFileAlloc(std.testing.allocator, "sa_std/vec_deque.sal");
    defer std.testing.allocator.free(deque_layout);
    try std.testing.expectEqualStrings(
        "#def VecDeque_SIZE = 32\n#def VecDeque_buf = +0\n#def VecDeque_cap = +8\n#def VecDeque_head = +16\n#def VecDeque_len = +24\n\n#def VecDeque_INITIAL_CAP = 8\n#def VecDeque_SLOT_SIZE = 8\n",
        deque_layout,
    );

    const collections_vec_deque = try readFileAlloc(std.testing.allocator, "sa_std/collections/vec_deque.sa");
    defer std.testing.allocator.free(collections_vec_deque);
    try std.testing.expectEqualStrings("@import \"../vec_deque.sa\"\n", collections_vec_deque);

    const deque_src = try readFileAlloc(std.testing.allocator, "sa_std/vec_deque.sa");
    defer std.testing.allocator.free(deque_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@import \"core/mem.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@import \"core/slice.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@import \"core/slice.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@import \"vec.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_new"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_with_capacity"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_free"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_capacity"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_is_empty"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_reserve"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_reserve_exact"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_reserve"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_reserve_exact"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_shrink_to"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_shrink_to_fit"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_shrink_to"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_shrink_to_fit"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_as_slices"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_as_mut_slices"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_make_contiguous"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_push_back"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_push_front"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_get"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_get_mut_ptr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_front_mut_ptr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_back_mut_ptr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_set"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_contains"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_swap"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_insert"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_remove"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_swap_remove_front"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_swap_remove_back"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_pop_front"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_pop_back"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_front"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_back"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_front"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_back"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_clear"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_rotate_left"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_rotate_right"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_truncate"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_try_split_off"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "@export sa_vec_deque_append"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_WITH_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_WITH_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_IS_EMPTY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_GET_MUT_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_FRONT_MUT_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_BACK_MUT_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_SET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_CONTAINS_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_SWAP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_INSERT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_INSERT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_REMOVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_REMOVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_SWAP_REMOVE_FRONT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_SWAP_REMOVE_BACK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_POP_FRONT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_POP_BACK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_POP_FRONT_IF_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_POP_FRONT_IF_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_POP_BACK_IF_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_POP_BACK_IF_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_FRONT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_FRONT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_BACK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_BACK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_CLEAR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_DRAIN_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_RESERVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_RESERVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_AS_SLICES"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_AS_MUT_SLICES"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_MAKE_CONTIGUOUS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_RETAIN_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_SHRINK_TO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_SHRINK_TO_FIT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_SHRINK_TO_FIT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRUNCATE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_APPEND"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_LIT1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_LIT2"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_LIT3"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_FROM_SLICE_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_FROM_VEC_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deque_src, 1, "[MACRO] VEC_DEQUE_TRY_SPLIT_OFF"));

    var deque_error_ctx = saasm.flattener.ErrorContext{};
    var deque_flat = saasm.flattener.flattenFileWithContext(std.testing.allocator, "sa_std/vec_deque.sa", deque_src, &deque_error_ctx) catch |err| {
        const source_line = saasm.flattener.takeErrorSourceLine(&deque_error_ctx) orelse 0;
        std.debug.print("vec_deque flatten failed on line {d}: {s}\n", .{ source_line, @errorName(err) });
        return err;
    };
    defer deque_flat.deinit(std.testing.allocator);
    try std.testing.expect(deque_flat.instructions.len > 0);
    try std.testing.expect(deque_flat.function_sigs.len >= 43);

    const deque_verified = try saasm.referee.verify(std.testing.allocator, deque_flat.instructions, deque_flat.const_decls);
    switch (deque_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 43);
            try std.testing.expect(owned.annotated.len > 0);
        },
        .trap => |report| {
            std.debug.print(
                "vec_deque smoke verifier trap: {s} (line={d}, source_line={d}, function={s}, text={s}, register={s}, expected={s}, actual={s})\n",
                .{
                    report.message,
                    report.line,
                    report.source_line,
                    std.mem.sliceTo(&report.function_buf, 0),
                    std.mem.sliceTo(&report.source_text_buf, 0),
                    if (report.register) |r| r else std.mem.sliceTo(&report.register_buf, 0),
                    if (report.expected_mask_name) |r| r else "",
                    if (report.actual_mask_name) |r| r else "",
                },
            );
            return error.TestUnexpectedResult;
        },
    }

    const deque_fixture = try readFileAlloc(std.testing.allocator, "tests/vec_deque_fixture.sa");
    defer std.testing.allocator.free(deque_fixture);

    var deque_fixture_flat = try flattenFixture(std.testing.allocator, "tests/vec_deque_fixture.sa", deque_fixture);
    defer deque_fixture_flat.deinit(std.testing.allocator);
    const deque_fixture_verified = try saasm.referee.verify(std.testing.allocator, deque_fixture_flat.instructions, deque_fixture_flat.const_decls);
    switch (deque_fixture_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 15);
        },
        .trap => |report| {
            std.debug.print("vec_deque fixture verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }
}

test "sa_std binary_heap helpers are concrete and verifiable" {
    const heap_layout = try readFileAlloc(std.testing.allocator, "sa_std/binary_heap.sal");
    defer std.testing.allocator.free(heap_layout);
    try std.testing.expectEqualStrings(
        "#def BinaryHeap_SIZE = 24\n#def BinaryHeap_buf = +0\n#def BinaryHeap_cap = +8\n#def BinaryHeap_len = +16\n\n#def BinaryHeap_INITIAL_CAP = 8\n#def BinaryHeap_SLOT_SIZE = 8\n",
        heap_layout,
    );

    const collections_binary_heap = try readFileAlloc(std.testing.allocator, "sa_std/collections/binary_heap.sa");
    defer std.testing.allocator.free(collections_binary_heap);
    try std.testing.expectEqualStrings("@import \"../binary_heap.sa\"\n", collections_binary_heap);

    const heap_src = try readFileAlloc(std.testing.allocator, "sa_std/binary_heap.sa");
    defer std.testing.allocator.free(heap_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@import \"core/mem.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@import \"core/slice.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@import \"core/slice.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@import \"alloc/vec.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@import \"vec.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_new"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_with_capacity"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_try_with_capacity"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_free"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_len"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_capacity"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_reserve"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_reserve_exact"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_try_reserve"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_try_reserve_exact"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_shrink_to"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_shrink_to_fit"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_as_slice"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_as_mut_slice"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_into_vec"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_into_sorted_vec"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_is_empty"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_peek"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_try_peek_mut_ptr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_push"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_try_pop"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_clear"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "@export sa_binary_heap_append"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_WITH_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_TRY_WITH_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_FREE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_CAPACITY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_RESERVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_RESERVE_EXACT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_TRY_RESERVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_TRY_RESERVE_EXACT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_SHRINK_TO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_SHRINK_TO_FIT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_AS_SLICE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_AS_MUT_SLICE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_INTO_VEC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_INTO_SORTED_VEC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_IS_EMPTY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_PEEK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_TRY_PEEK_MUT_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_PEEK_MUT_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_PUSH"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_TRY_POP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_CLEAR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_DRAIN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_APPEND"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_LIT1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_LIT2"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_LIT3"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_FROM_SLICE_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_FROM_VEC_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_EXTEND_FROM_SLICE_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, heap_src, 1, "[MACRO] BINARY_HEAP_EXTEND_FROM_VEC_U64"));

    var heap_error_ctx = saasm.flattener.ErrorContext{};
    var heap_flat = saasm.flattener.flattenFileWithContext(std.testing.allocator, "sa_std/binary_heap.sa", heap_src, &heap_error_ctx) catch |err| {
        const source_line = saasm.flattener.takeErrorSourceLine(&heap_error_ctx) orelse 0;
        std.debug.print("binary_heap flatten failed on line {d}: {s}\n", .{ source_line, @errorName(err) });
        return err;
    };
    defer heap_flat.deinit(std.testing.allocator);
    try std.testing.expect(heap_flat.instructions.len > 0);
    try std.testing.expect(heap_flat.function_sigs.len >= 28);

    const heap_verified = try saasm.referee.verify(std.testing.allocator, heap_flat.instructions, heap_flat.const_decls);
    switch (heap_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 28);
            try std.testing.expect(owned.annotated.len > 0);
        },
        .trap => |report| {
            for (heap_flat.instructions, 0..) |inst, i| {
                if (i >= 415 and i <= 425) {
                    std.debug.print("[{d}] {s}\n", .{ i, inst.raw_text });
                }
            }
            std.debug.print(
                "binary_heap smoke verifier trap: {s} (line={d}, source_line={d}, function={s}, text={s}, register={s}, expected={s}, actual={s})\n",
                .{
                    report.message,
                    report.line,
                    report.source_line,
                    std.mem.sliceTo(&report.function_buf, 0),
                    std.mem.sliceTo(&report.source_text_buf, 0),
                    if (report.register) |r| r else std.mem.sliceTo(&report.register_buf, 0),
                    if (report.expected_mask_name) |r| r else "",
                    if (report.actual_mask_name) |r| r else "",
                },
            );
            return error.TestUnexpectedResult;
        },
    }

    const heap_fixture =
        \\@import "sa_std/collections/binary_heap.sa"
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    EXPAND BINARY_HEAP_NEW heap
        \\    EXPAND BINARY_HEAP_PUSH heap, 4
        \\    EXPAND BINARY_HEAP_PUSH heap, 1
        \\    EXPAND BINARY_HEAP_PUSH heap, 7
        \\    EXPAND BINARY_HEAP_PUSH heap, 2
        \\    EXPAND BINARY_HEAP_PUSH heap, 9
        \\    EXPAND BINARY_HEAP_PUSH heap, 3
        \\    EXPAND BINARY_HEAP_PUSH heap, 8
        \\    EXPAND BINARY_HEAP_PUSH heap, 6
        \\    EXPAND BINARY_HEAP_PUSH heap, 5
        \\    EXPAND BINARY_HEAP_LEN len0, heap
        \\    EXPAND BINARY_HEAP_PEEK peek0, heap
        \\    EXPAND BINARY_HEAP_TRY_POP ok0, pop0, heap
        \\    EXPAND BINARY_HEAP_TRY_POP ok1, pop1, heap
        \\    EXPAND BINARY_HEAP_TRY_POP ok2, pop2, heap
        \\    EXPAND BINARY_HEAP_TRY_POP ok3, pop3, heap
        \\    EXPAND BINARY_HEAP_TRY_POP ok4, pop4, heap
        \\    EXPAND BINARY_HEAP_TRY_POP ok5, pop5, heap
        \\    EXPAND BINARY_HEAP_TRY_POP ok6, pop6, heap
        \\    EXPAND BINARY_HEAP_TRY_POP ok7, pop7, heap
        \\    EXPAND BINARY_HEAP_TRY_POP ok8, pop8, heap
        \\    EXPAND BINARY_HEAP_TRY_POP ok_empty, empty_value, heap
        \\    EXPAND BINARY_HEAP_LEN len1, heap
        \\    ok_len0 = eq len0, 9
        \\    ok_peek = eq peek0, 9
        \\    ok0v = eq pop0, 9
        \\    ok1v = eq pop1, 8
        \\    ok2v = eq pop2, 7
        \\    ok3v = eq pop3, 6
        \\    ok4v = eq pop4, 5
        \\    ok5v = eq pop5, 4
        \\    ok6v = eq pop6, 3
        \\    ok7v = eq pop7, 2
        \\    ok8v = eq pop8, 1
        \\    ok_empty_ok = eq ok_empty, 0
        \\    ok_empty_value = eq empty_value, 0
        \\    ok_len1 = eq len1, 0
        \\    ok01 = and ok_len0, ok_peek
        \\    ok02 = and ok01, ok0v
        \\    ok03 = and ok02, ok1v
        \\    ok04 = and ok03, ok2v
        \\    ok05 = and ok04, ok3v
        \\    ok06 = and ok05, ok4v
        \\    ok07 = and ok06, ok5v
        \\    ok08 = and ok07, ok6v
        \\    ok09 = and ok08, ok7v
        \\    ok10 = and ok09, ok8v
        \\    ok11 = and ok10, ok_empty_ok
        \\    ok12 = and ok11, ok_empty_value
        \\    ok = and ok12, ok_len1
        \\    !peek0
        \\    !pop0
        \\    !pop1
        \\    !pop2
        \\    !pop3
        \\    !pop4
        \\    !pop5
        \\    !pop6
        \\    !pop7
        \\    !pop8
        \\    !empty_value
        \\    !ok0
        \\    !ok1
        \\    !ok2
        \\    !ok3
        \\    !ok4
        \\    !ok5
        \\    !ok6
        \\    !ok7
        \\    !ok8
        \\    !ok_empty
        \\    !len0
        \\    !len1
        \\    !ok_len0
        \\    !ok_peek
        \\    !ok0v
        \\    !ok1v
        \\    !ok2v
        \\    !ok3v
        \\    !ok4v
        \\    !ok5v
        \\    !ok6v
        \\    !ok7v
        \\    !ok8v
        \\    !ok_empty_ok
        \\    !ok_empty_value
        \\    !ok_len1
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
        \\    EXPAND BINARY_HEAP_FREE heap
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
    var heap_fixture_flat = try flattenFixture(std.testing.allocator, "tests/binary_heap_fixture.sa", heap_fixture);
    defer heap_fixture_flat.deinit(std.testing.allocator);
    const heap_fixture_verified = try saasm.referee.verify(std.testing.allocator, heap_fixture_flat.instructions, heap_fixture_flat.const_decls);
    switch (heap_fixture_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 31);
        },
        .trap => |report| {
            std.debug.print("binary_heap fixture verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }
}

test "sa_std btree_map helpers are concrete and verifiable" {
    const btree_layout = try readFileAlloc(std.testing.allocator, "sa_std/btree_map.sal");
    defer std.testing.allocator.free(btree_layout);
    try std.testing.expectEqualStrings(
        "#def BTreeMap_SIZE = 24\n#def BTreeMap_entries = +0\n#def BTreeMap_cap = +8\n#def BTreeMap_len = +16\n\n#def BTreeMapEntry_SIZE = 24\n#def BTreeMapEntry_key_ptr = +0\n#def BTreeMapEntry_key_len = +8\n#def BTreeMapEntry_value = +16\n\n#def BTreeMap_INITIAL_CAP = 8\n",
        btree_layout,
    );

    const collections_btree_map = try readFileAlloc(std.testing.allocator, "sa_std/collections/btree_map.sa");
    defer std.testing.allocator.free(collections_btree_map);
    try std.testing.expectEqualStrings("@import \"../btree_map.sa\"\n", collections_btree_map);

    const btree_src = try readFileAlloc(std.testing.allocator, "sa_std/btree_map.sa");
    defer std.testing.allocator.free(btree_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@import \"core/mem.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@import \"core/slice.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@import \"alloc/vec.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_new"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_free"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_len"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_is_empty"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_get"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_try_get"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_try_get_key_value"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_get_mut_ptr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_first_entry_mut_ptr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_last_entry_mut_ptr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_try_get_disjoint_mut_ptrs"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_first_key_value"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_last_key_value"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_contains_key"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_clear"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_remove"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_remove_entry"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_insert"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_insert_old"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_try_insert"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_keys_set"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_values_vec"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_value_mut_ptrs_vec"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_pop_first"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_pop_last"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_append"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_split_off"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "@export sa_btree_map_range"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_IS_EMPTY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_TRY_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_GET_KEY_VALUE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_GET_MUT_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_FIRST_ENTRY_MUT_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_LAST_ENTRY_MUT_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_TRY_GET_DISJOINT_MUT_PTRS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_FIRST_KEY_VALUE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_LAST_KEY_VALUE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_CONTAINS_KEY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_CLEAR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_REMOVE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_REMOVE_ENTRY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_INSERT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_INSERT_OLD"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_TRY_INSERT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_KEYS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_VALUES"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_VALUES_MUT_PTRS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_POP_FIRST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_POP_LAST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_APPEND"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_SPLIT_OFF"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_RANGE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_FREE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_LIT1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_LIT2"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_src, 1, "[MACRO] BTREE_MAP_LIT3"));

    const btree_set_src = try readFileAlloc(std.testing.allocator, "sa_std/btree_set.sa");
    defer std.testing.allocator.free(btree_set_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_range"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_union"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_intersection"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_difference"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "@export sa_btree_set_symmetric_difference"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_FIRST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_LAST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_TAKE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_REPLACE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_POP_FIRST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_POP_LAST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_IS_DISJOINT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_IS_SUBSET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_IS_SUPERSET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_APPEND"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_SPLIT_OFF"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_RANGE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_UNION"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_INTERSECTION"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_DIFFERENCE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_SYMMETRIC_DIFFERENCE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_LIT1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_LIT2"));
    try std.testing.expect(std.mem.containsAtLeast(u8, btree_set_src, 1, "[MACRO] BTREE_SET_LIT3"));

    var btree_error_ctx = saasm.flattener.ErrorContext{};
    var btree_flat = saasm.flattener.flattenFileWithContext(std.testing.allocator, "sa_std/btree_map.sa", btree_src, &btree_error_ctx) catch |err| {
        const source_line = saasm.flattener.takeErrorSourceLine(&btree_error_ctx) orelse 0;
        std.debug.print("btree_map flatten failed on line {d}: {s}\n", .{ source_line, @errorName(err) });
        return err;
    };
    defer btree_flat.deinit(std.testing.allocator);
    try std.testing.expect(btree_flat.instructions.len > 0);
    try std.testing.expect(btree_flat.function_sigs.len >= 35);

    const btree_verified = try saasm.referee.verify(std.testing.allocator, btree_flat.instructions, btree_flat.const_decls);
    switch (btree_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 35);
            try std.testing.expect(owned.annotated.len > 0);
        },
        .trap => |report| {
            std.debug.print(
                "btree_map smoke verifier trap: {s} (line={d}, source_line={d}, function={s}, text={s}, register={s}, expected={s}, actual={s})\n",
                .{
                    report.message,
                    report.line,
                    report.source_line,
                    std.mem.sliceTo(&report.function_buf, 0),
                    std.mem.sliceTo(&report.source_text_buf, 0),
                    if (report.register) |r| r else std.mem.sliceTo(&report.register_buf, 0),
                    if (report.expected_mask_name) |r| r else "",
                    if (report.actual_mask_name) |r| r else "",
                },
            );
            return error.TestUnexpectedResult;
        },
    }

    const btree_fixture =
        \\@import "sa_std/core/slice.sal"
        \\@import "sa_std/core/slice.sa"
        \\@import "sa_std/collections/btree_map.sa"
        \\
        \\@const KEY_ALPHA = utf8:"alpha"
        \\@const KEY_BRAVO = utf8:"bravo"
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    map = 0 as ptr
        \\    alpha = alloc Slice_SIZE
        \\    bravo = alloc Slice_SIZE
        \\    lookup = alloc Slice_SIZE
        \\    EXPAND SLICE_NEW alpha, &KEY_ALPHA, 5
        \\    EXPAND SLICE_NEW bravo, &KEY_BRAVO, 5
        \\    EXPAND SLICE_NEW lookup, &KEY_ALPHA, 5
        \\    EXPAND BTREE_MAP_NEW map
        \\    EXPAND BTREE_MAP_IS_EMPTY empty0, map
        \\    EXPAND BTREE_MAP_INSERT map, bravo, 2
        \\    EXPAND BTREE_MAP_INSERT map, alpha, 1
        \\    EXPAND BTREE_MAP_INSERT map, lookup, 3
        \\    EXPAND BTREE_MAP_CONTAINS_KEY has_alpha, map, alpha
        \\    EXPAND BTREE_MAP_CONTAINS_KEY has_lookup, map, lookup
        \\    value_alpha = call @sa_btree_map_get(&map, &alpha)
        \\    value_bravo = call @sa_btree_map_get(&map, &bravo)
        \\    removed_alpha = call @sa_btree_map_remove(&map, &alpha)
        \\    EXPAND BTREE_MAP_CONTAINS_KEY has_alpha_after, map, alpha
        \\    len = call @sa_btree_map_len(&map)
        \\    EXPAND BTREE_MAP_CLEAR map
        \\    EXPAND BTREE_MAP_IS_EMPTY empty1, map
        \\    ok_alpha = eq value_alpha, 3
        \\    ok_bravo = eq value_bravo, 2
        \\    ok_removed = ne removed_alpha, 0
        \\    ok_len = eq len, 1
        \\    ok_empty0 = eq empty0, 1
        \\    ok_empty1 = eq empty1, 1
        \\    ok_has_alpha = eq has_alpha, 1
        \\    ok_has_lookup = eq has_lookup, 1
        \\    ok_has_alpha_after = eq has_alpha_after, 0
        \\    ok01 = and ok_alpha, ok_bravo
        \\    ok02 = and ok01, ok_removed
        \\    ok03 = and ok02, ok_len
        \\    ok04 = and ok03, ok_empty0
        \\    ok05 = and ok04, ok_empty1
        \\    ok06 = and ok05, ok_has_alpha
        \\    ok07 = and ok06, ok_has_lookup
        \\    ok = and ok07, ok_has_alpha_after
        \\    !ok_has_alpha_after
        \\    !ok_has_lookup
        \\    !ok_has_alpha
        \\    !ok_empty1
        \\    !ok_empty0
        \\    !ok_len
        \\    !ok_removed
        \\    !ok_bravo
        \\    !ok_alpha
        \\    !len
        \\    !value_bravo
        \\    !value_alpha
        \\    !empty1
        \\    !empty0
        \\    !removed_alpha
        \\    !has_alpha_after
        \\    !has_lookup
        \\    !has_alpha
        \\    !lookup
        \\    !bravo
        \\    !alpha
        \\    EXPAND BTREE_MAP_FREE map
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
    var btree_fixture_flat = try flattenFixture(std.testing.allocator, "tests/btree_map_fixture.sa", btree_fixture);
    defer btree_fixture_flat.deinit(std.testing.allocator);
    const btree_fixture_verified = try saasm.referee.verify(std.testing.allocator, btree_fixture_flat.instructions, btree_fixture_flat.const_decls);
    switch (btree_fixture_verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.function_sigs.len >= 28);
        },
        .trap => |report| {
            std.debug.print("btree_map fixture verifier trap: {s}\n", .{report.message});
            return error.TestUnexpectedResult;
        },
    }
}
test "sa_std sort helpers are concrete and verifiable" {
    const sort_src = try readFileAlloc(std.testing.allocator, "sa_std/sort.sa");
    defer std.testing.allocator.free(sort_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, sort_src, 1, "@import \"core/mem.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, sort_src, 1, "[MACRO] QSORT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, sort_src, 1, "@sort_swap_bytes"));
    try std.testing.expect(std.mem.containsAtLeast(u8, sort_src, 1, "@sort_partition_bounds"));
    try std.testing.expect(std.mem.containsAtLeast(u8, sort_src, 1, "@sort_qsort_bounds"));
    try std.testing.expect(std.mem.containsAtLeast(u8, sort_src, 1, "@sort_qsort_len"));

    var sort_flat = try flattenFixture(std.testing.allocator, "sa_std/sort.sa", sort_src);
    defer sort_flat.deinit(std.testing.allocator);
    try std.testing.expect(sort_flat.instructions.len > 0);
    try std.testing.expect(sort_flat.function_sigs.len >= 4);
}

test "sa_std Deno compatibility facade covers HubProxy porting surface" {
    const deno_sai = try readFileAlloc(std.testing.allocator, "../sa_plugins/sa_plugin_deno/deno.sai");
    defer std.testing.allocator.free(deno_sai);
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_deno_plugin_cwd"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_deno_plugin_env_set"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_deno_plugin_random_uuid"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_deno_plugin_args_json"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_deno_plugin_btoa"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_deno_plugin_atob"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_deno_plugin_text_encode"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_deno_plugin_text_decode"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_deno_plugin_chat_sse_to_responses"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_deno_plugin_version_json"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_deno_plugin_build_json"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_deno_plugin_version_deno"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_deno_plugin_build_os"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_deno_plugin_build_platform_family"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_deno_plugin_date_now_iso"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "DENO_HTTP_METHOD_POST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_http_client_req_send"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_http_client_resp_get_header"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_http_server_req_get_method"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_http_server_resp_set_content_type"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_sai, 1, "sa_http_server_resp_stream_write"));

    const deno_src = try readFileAlloc(std.testing.allocator, "../sa_plugins/sa_plugin_deno/deno.sal");
    defer std.testing.allocator.free(deno_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_ARGS_JSON"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_ENV_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_ENV_SET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_CWD"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_RANDOM_UUID"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_CRYPTO_RANDOM_UUID"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_BTOA"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_ATOB"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_TEXT_ENCODE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_TEXT_DECODE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_TEXT_ENCODER_ENCODE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_TEXT_DECODER_DECODE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_CHAT_SSE_TO_RESPONSES"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_VERSION_JSON"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_VERSION_DENO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_BUILD_JSON"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_BUILD_OS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_BUILD_PLATFORM_FAMILY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_DATE_NOW_ISO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_NEW_DATE_TO_ISO_STRING"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_JSON_PARSE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_JSON_STRINGIFY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_JSON_BUFFER_SLICE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_JSON_BUFFER_FREE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_JSON_FREE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_FREE_BUFFER"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_STDOUT_WRITE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_STDERR_WRITE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_READ_TEXT_FILE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_READ_TEXT_FILE_SYNC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_READ_FILE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_READ_FILE_SYNC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_WRITE_TEXT_FILE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_WRITE_TEXT_FILE_SYNC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_WRITE_FILE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_WRITE_FILE_SYNC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_READ_FILE_BASE64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_WRITE_FILE_BASE64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_MKDIR_SYNC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_READ_DIR_JSON"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_READ_DIR_SYNC_JSON"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_READ_DIR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_READ_DIR_SYNC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_LSTAT_JSON"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_LSTAT_SYNC_JSON"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_LSTAT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_LSTAT_SYNC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_STAT_JSON"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_STAT_SYNC_JSON"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_STAT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_STAT_SYNC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_MAKE_TEMP_DIR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_MAKE_TEMP_DIR_SYNC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_MAKE_TEMP_FILE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_MAKE_TEMP_FILE_SYNC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_REMOVE_SYNC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_COPY_FILE_SYNC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_COMMAND_RUN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_COMMAND_EXEC"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_COMMAND_OUTPUT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_COMMAND_SPAWN_STREAM"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_COMMAND_READ_STDOUT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_NOW_MS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_DATE_NOW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_LISTEN_TCP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_CONNECT_TCP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_HTTP_CLIENT_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_HTTP_REQUEST_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_HTTP_REQUEST_SEND"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_HTTP_RESPONSE_GET_HEADER"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_HTTP_RESPONSE_READ_CHUNK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_REQUEST_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_REQUEST_HEADERS_APPEND"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_RESPONSE_HEADERS_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_SERVE_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_SERVE_REQUEST_METHOD"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_SERVE_RESPONSE_SET_CONTENT_TYPE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, deno_src, 1, "[MACRO] DENO_SERVE_STREAM_WRITE"));

    var deno_flat = try flattenFixture(std.testing.allocator, "../sa_plugins/sa_plugin_deno/deno.sal", deno_src);
    defer deno_flat.deinit(std.testing.allocator);
    try std.testing.expect(deno_flat.function_sigs.len >= 60);
}

test "sa_std Deno JSON facade runs from SA" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const deno_sal = try readFileAlloc(std.testing.allocator, "../sa_plugins/sa_plugin_deno/deno.sal");
    defer std.testing.allocator.free(deno_sal);
    const deno_sai = try readFileAlloc(std.testing.allocator, "../sa_plugins/sa_plugin_deno/deno.sai");
    defer std.testing.allocator.free(deno_sai);

    try writeSource(tmp.dir, "deno.sal", deno_sal);
    try writeSource(tmp.dir, "deno.sai", deno_sai);

    const source =
        \\@import "deno.sal"
        \\
        \\@const JSON_DOC = utf8:"{\"ok\":true,\"n\":7}"
        \\
        \\#def JSON_DOC_LEN = 17
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    EXPAND DENO_JSON_PARSE root, JSON_DOC, JSON_DOC_LEN
        \\    root_ok = ne root, 0
        \\    br root_ok -> L_STRINGIFY, L_FAIL_ROOT
        \\
        \\L_STRINGIFY:
        \\    !root_ok
        \\    EXPAND DENO_JSON_STRINGIFY stringify_status, json_buf, root
        \\    stringify_ok = eq stringify_status, 0
        \\    !stringify_status
        \\    br stringify_ok -> L_SLICE, L_FAIL_STRINGIFY
        \\
        \\L_SLICE:
        \\    !stringify_ok
        \\    EXPAND DENO_JSON_BUFFER_SLICE json_ptr, json_len, json_buf
        \\    len_ok = eq json_len, JSON_DOC_LEN
        \\    br len_ok -> L_CLEANUP, L_FAIL_LEN
        \\
        \\L_CLEANUP:
        \\    !len_ok
        \\    EXPAND DENO_JSON_BUFFER_FREE json_buf
        \\    EXPAND DENO_JSON_FREE root
        \\    !json_ptr
        \\    !json_len
        \\    return 0
        \\
        \\L_FAIL_ROOT:
        \\    !root_ok
        \\    return 63
        \\
        \\L_FAIL_STRINGIFY:
        \\    !stringify_ok
        \\    EXPAND DENO_JSON_FREE root
        \\    !json_buf
        \\    return 63
        \\
        \\L_FAIL_LEN:
        \\    !len_ok
        \\    EXPAND DENO_JSON_BUFFER_FREE json_buf
        \\    EXPAND DENO_JSON_FREE root
        \\    !json_ptr
        \\    !json_len
        \\    return 63
    ;
    try writeSource(tmp.dir, "deno_json_facade.sa", source);

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "deno_json_facade.sa", "-o", "deno_json_facade" };
    const exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), exe_code);

    const run_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./deno_json_facade"});
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    switch (run_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
}

test "sa_std Deno text and base64 facade runs from SA" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const deno_sal = try readFileAlloc(std.testing.allocator, "../sa_plugins/sa_plugin_deno/deno.sal");
    defer std.testing.allocator.free(deno_sal);
    const deno_sai = try readFileAlloc(std.testing.allocator, "../sa_plugins/sa_plugin_deno/deno.sai");
    defer std.testing.allocator.free(deno_sai);

    try writeSource(tmp.dir, "deno.sal", deno_sal);
    try writeSource(tmp.dir, "deno.sai", deno_sai);

    const source =
        \\@import "deno.sal"
        \\@import "sa_std/fmt.sai"
        \\@import "sa_std/fs.sai"
        \\
        \\@const TEXT = utf8:"ok"
        \\@const ENCODED = utf8:"b2s="
        \\
        \\#def TEXT_LEN = 2
        \\#def ENCODED_LEN = 4
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    EXPAND DENO_BTOA btoa_buf, TEXT, TEXT_LEN
        \\    btoa_ptr = call @sa_fmt_buffer_data(btoa_buf)
        \\    btoa_len = call @sa_fmt_buffer_len(btoa_buf)
        \\    btoa_len_ok = eq btoa_len, 4
        \\    br btoa_len_ok -> L_DECODE, L_FAIL
        \\
        \\L_DECODE:
        \\    !btoa_len_ok
        \\    EXPAND DENO_ATOB atob_buf, ENCODED, ENCODED_LEN
        \\    atob_ptr = call @sa_fmt_buffer_data(atob_buf)
        \\    atob_len = call @sa_fmt_buffer_len(atob_buf)
        \\    atob_len_ok = eq atob_len, 2
        \\    br atob_len_ok -> L_TEXT_ENCODE, L_FAIL
        \\
        \\L_TEXT_ENCODE:
        \\    !atob_len_ok
        \\    EXPAND DENO_TEXT_ENCODE bytes_buf, TEXT, TEXT_LEN
        \\    bytes_ptr = call @sa_fs_read_buffer_data(bytes_buf)
        \\    bytes_len = call @sa_fs_read_buffer_len(bytes_buf)
        \\    bytes_len_ok = eq bytes_len, 2
        \\    br bytes_len_ok -> L_TEXT_DECODE, L_FAIL
        \\
        \\L_TEXT_DECODE:
        \\    !bytes_len_ok
        \\    EXPAND DENO_TEXT_DECODE text_buf, TEXT, TEXT_LEN
        \\    text_ptr = call @sa_fmt_buffer_data(text_buf)
        \\    text_len = call @sa_fmt_buffer_len(text_buf)
        \\    text_len_ok = eq text_len, 2
        \\    br text_len_ok -> L_VERSION, L_FAIL
        \\
        \\L_VERSION:
        \\    !text_len_ok
        \\    EXPAND DENO_VERSION_JSON version_buf
        \\    version_ptr = call @sa_fs_read_buffer_data(version_buf)
        \\    version_len = call @sa_fs_read_buffer_len(version_buf)
        \\    version_ok = gt version_len, 2
        \\    br version_ok -> L_BUILD, L_FAIL
        \\
        \\L_BUILD:
        \\    !version_ok
        \\    EXPAND DENO_BUILD_JSON build_buf
        \\    build_ptr = call @sa_fs_read_buffer_data(build_buf)
        \\    build_len = call @sa_fs_read_buffer_len(build_buf)
        \\    build_ok = gt build_len, 2
        \\    br build_ok -> L_CLEANUP, L_FAIL
        \\
        \\L_CLEANUP:
        \\    !build_ok
        \\    btoa_free = call @sa_fmt_buffer_free(^btoa_buf)
        \\    atob_free = call @sa_fmt_buffer_free(^atob_buf)
        \\    bytes_free = call @sa_fs_read_buffer_free(^bytes_buf)
        \\    text_free = call @sa_fmt_buffer_free(^text_buf)
        \\    version_free = call @sa_fs_read_buffer_free(^version_buf)
        \\    build_free = call @sa_fs_read_buffer_free(^build_buf)
        \\    !build_ptr
        \\    !version_ptr
        \\    !text_ptr
        \\    !bytes_ptr
        \\    !atob_ptr
        \\    !btoa_ptr
        \\    !build_free
        \\    !version_free
        \\    !text_free
        \\    !bytes_free
        \\    !atob_free
        \\    !btoa_free
        \\    return 0
        \\
        \\L_FAIL:
        \\    return 64
    ;
    try writeSource(tmp.dir, "deno_text_base64.sa", source);

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "deno_text_base64.sa", "-o", "deno_text_base64" };
    const exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), exe_code);

    const run_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./deno_text_base64"});
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    switch (run_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
}

test "sa_std Deno fallible status macros compile and run" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const deno_sal = try readFileAlloc(std.testing.allocator, "../sa_plugins/sa_plugin_deno/deno.sal");
    defer std.testing.allocator.free(deno_sal);
    const deno_sai = try readFileAlloc(std.testing.allocator, "../sa_plugins/sa_plugin_deno/deno.sai");
    defer std.testing.allocator.free(deno_sai);

    try writeSource(tmp.dir, "deno.sal", deno_sal);
    try writeSource(tmp.dir, "deno.sai", deno_sai);

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const source =
        \\@import "deno.sal"
        \\
        \\@const DIR = utf8:"deno_macro_dir"
        \\@const TEXT_PATH = utf8:"deno_macro_dir/text.txt"
        \\@const B64_PATH = utf8:"deno_macro_dir/b64.txt"
        \\@const TEXT = utf8:"hello"
        \\@const B64 = utf8:"aGVsbG8="
        \\
        \\#def DIR_LEN = 14
        \\#def TEXT_PATH_LEN = 23
        \\#def B64_PATH_LEN = 22
        \\#def TEXT_LEN = 5
        \\#def B64_LEN = 8
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    EXPAND DENO_MKDIR mkdir_status, DIR, DIR_LEN
        \\    mkdir_ok = eq mkdir_status, 0
        \\    !mkdir_status
        \\    br mkdir_ok -> L_WRITE_TEXT, L_FAIL_MKDIR
        \\
        \\L_WRITE_TEXT:
        \\    !mkdir_ok
        \\    EXPAND DENO_WRITE_TEXT_FILE text_status, TEXT_PATH, TEXT_PATH_LEN, TEXT, TEXT_LEN
        \\    text_ok = eq text_status, 0
        \\    !text_status
        \\    br text_ok -> L_WRITE_B64, L_FAIL_TEXT
        \\
        \\L_WRITE_B64:
        \\    !text_ok
        \\    EXPAND DENO_WRITE_FILE_BASE64 b64_status, B64_PATH, B64_PATH_LEN, B64, B64_LEN
        \\    b64_ok = eq b64_status, 0
        \\    !b64_status
        \\    br b64_ok -> L_SLEEP, L_FAIL_B64
        \\
        \\L_SLEEP:
        \\    !b64_ok
        \\    EXPAND DENO_SLEEP_MS sleep_status, 0
        \\    sleep_ok = eq sleep_status, 0
        \\    !sleep_status
        \\    br sleep_ok -> L_PASS, L_FAIL_SLEEP
        \\
        \\L_PASS:
        \\    !sleep_ok
        \\    return 0
        \\
        \\L_FAIL_MKDIR:
        \\    !mkdir_ok
        \\    return 41
        \\
        \\L_FAIL_TEXT:
        \\    !text_ok
        \\    return 42
        \\
        \\L_FAIL_B64:
        \\    !b64_ok
        \\    return 43
        \\
        \\L_FAIL_SLEEP:
        \\    !sleep_ok
        \\    return 44
    ;
    try writeSource(tmp.dir, "deno_fallible_status.sa", source);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "deno_fallible_status.sa", "-o", "deno_fallible_status" };
    const exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), exe_code);

    const run_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./deno_fallible_status"});
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    switch (run_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
}

test "std smoke fixture runs through the current compiler surface" {
    const fixture = try readFileAlloc(std.testing.allocator, "tests/std_smoke.sa");
    defer std.testing.allocator.free(fixture);
    try std.testing.expect(std.mem.containsAtLeast(u8, fixture, 1, "ptr_add"));

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    try writeSource(tmp.dir, "std_smoke.sa", fixture);

    const run_argv = [_][]const u8{"sars", "run", "std_smoke.sa" };
    const run_code = try saasm.cli.execute(std.testing.allocator, run_argv[0..]);
    try std.testing.expectEqual(@as(u8, 209), run_code);

    const build_exe_argv = [_][]const u8{"sars", "build-exe", "std_smoke.sa", "-o", "std_smoke.out" };
    const exe_code = try saasm.cli.execute(std.testing.allocator, build_exe_argv[0..]);
    try std.testing.expectEqual(@as(u8, 0), exe_code);

    const artifact_file = try tmp.dir.openFile(std.testing.io, "std_smoke.out.sa.bc", .{});
    defer artifact_file.close(std.testing.io);
    const artifact_bytes = try sio.readToEndAlloc(artifact_file, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(artifact_bytes);
    try std.testing.expect(artifact_bytes.len > 0);

    const exe_result = try runCommandAnyExit(std.testing.allocator, &[_][]const u8{"./std_smoke.out"});
    defer std.testing.allocator.free(exe_result.stdout);
    defer std.testing.allocator.free(exe_result.stderr);
    switch (exe_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 209), code),
        else => return error.TestUnexpectedResult,
    }
}

fn flattenFixture(allocator: std.mem.Allocator, source_path: []const u8, source: []const u8) !saasm.flattener.FlattenResult {
    const repo_root = try repoRoot(allocator);
    defer allocator.free(repo_root);
    var resolve_ctx = saasm.flattener.ResolveContext{};
    resolve_ctx.options.std_root = try std.fs.path.join(allocator, &.{ repo_root, "sa_std" });
    defer allocator.free(resolve_ctx.options.std_root.?);
    return saasm.flattener.flattenFileWithPackages(allocator, source_path, source, resolve_ctx);
}

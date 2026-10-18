const std = @import("std");
const common = @import("std_smoke_common.zig");
const sio = @import("sio");
const saasm = common.saasm;

fn flattenFixture(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !saasm.flattener.FlattenResult {
    return try saasm.flattener.flattenFile(allocator, path, source);
}

test "sa_std core primitives are concrete and verifiable" {
    const slice_layout = try common.readFileAlloc(std.testing.allocator, "sa_std/core/slice.sal");
    defer std.testing.allocator.free(slice_layout);
    try std.testing.expectEqualStrings(
        \\#def Slice_SIZE = 16
        \\#def Slice_ptr  = +0
        \\#def Slice_len  = +8
        \\
        \\#def TryFromSliceError_SIZE = 8
        \\#def TryFromSliceError_code = +0
        \\#def TRY_FROM_SLICE_ERROR_LENGTH_MISMATCH = 0
        \\
    ,
        slice_layout,
    );

    const slice_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/slice.sars");
    defer std.testing.allocator.free(slice_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_GET_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_AS_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_GET_LEN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_IS_EMPTY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_GET_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_GET_MUT_PTR_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_FIRST_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_FIRST_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_FIRST_MUT_PTR_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_FIRST_MUT_PTR_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_LAST_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_LAST_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_LAST_MUT_PTR_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_LAST_MUT_PTR_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_GET_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_GET_MUT_PTR_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_CONTAINS_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_STARTS_WITH_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_ENDS_WITH_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_STRIP_PREFIX_U64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, slice_src, 1, "[MACRO] SLICE_TRY_STRIP_SUFFIX_U64"));
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

    var slice_flat = try saasm.flattener.flatten(std.testing.allocator, slice_src);
    defer slice_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), slice_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), slice_flat.function_sigs.len);

    const slice_fixture =
        \\@import "sa_std/core/slice.sal"
        \\@import "sa_std/core/slice.sars"
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    data = alloc 24
        \\    store data+0, 11 as u64
        \\    store data+8, 22 as u64
        \\    store data+16, 33 as u64
        \\    slice = alloc Slice_SIZE
        \\    empty_slice = alloc Slice_SIZE
        \\    EXPAND SLICE_NEW slice, data, 3
        \\    EXPAND SLICE_NEW empty_slice, data, 0
        \\    EXPAND SLICE_AS_PTR ptr, slice
        \\    EXPAND SLICE_IS_EMPTY empty, slice
        \\    EXPAND SLICE_FIRST_U64 first, slice
        \\    EXPAND SLICE_LAST_U64 last, slice
        \\    EXPAND SLICE_TRY_FIRST_U64 first_try_ok, first_try, slice
        \\    EXPAND SLICE_TRY_LAST_U64 last_try_ok, last_try, slice
        \\    EXPAND SLICE_TRY_GET_U64 hit_ok, hit, slice, 1
        \\    EXPAND SLICE_TRY_GET_U64 miss_ok, miss, slice, 9
        \\    EXPAND SLICE_CONTAINS_U64 contains_22, slice, 22
        \\    EXPAND SLICE_CONTAINS_U64 contains_44, slice, 44
        \\    suffix_ptr = ptr_add data, 8
        \\    miss_prefix_data = alloc 16
        \\    store miss_prefix_data+0, 11 as u64
        \\    store miss_prefix_data+8, 44 as u64
        \\    prefix_slice = alloc Slice_SIZE
        \\    suffix_slice = alloc Slice_SIZE
        \\    miss_prefix_slice = alloc Slice_SIZE
        \\    EXPAND SLICE_NEW prefix_slice, data, 2
        \\    EXPAND SLICE_NEW suffix_slice, suffix_ptr, 2
        \\    EXPAND SLICE_NEW miss_prefix_slice, miss_prefix_data, 2
        \\    !suffix_ptr
        \\    EXPAND SLICE_TRY_STRIP_PREFIX_U64 strip_prefix_ok, strip_prefix_tail, slice, prefix_slice
        \\    EXPAND SLICE_TRY_STRIP_SUFFIX_U64 strip_suffix_ok, strip_suffix_head, slice, suffix_slice
        \\    EXPAND SLICE_TRY_STRIP_PREFIX_U64 strip_prefix_miss_ok, strip_prefix_miss, slice, miss_prefix_slice
        \\    EXPAND SLICE_GET_LEN strip_prefix_tail_len, strip_prefix_tail
        \\    EXPAND SLICE_FIRST_U64 strip_prefix_tail_first, strip_prefix_tail
        \\    EXPAND SLICE_GET_LEN strip_suffix_head_len, strip_suffix_head
        \\    EXPAND SLICE_FIRST_U64 strip_suffix_head_first, strip_suffix_head
        \\    EXPAND SLICE_IS_EMPTY strip_prefix_miss_empty, strip_prefix_miss
        \\    EXPAND SLICE_TRY_FIRST_U64 empty_first_ok, empty_first, empty_slice
        \\    EXPAND SLICE_TRY_LAST_U64 empty_last_ok, empty_last, empty_slice
        \\    ptr_ok = ne ptr, 0
        \\    empty_ok = eq empty, 0
        \\    first_ok = eq first, 11
        \\    last_ok = eq last, 33
        \\    first_try_flag_ok = eq first_try_ok, 1
        \\    first_try_value_ok = eq first_try, 11
        \\    last_try_flag_ok = eq last_try_ok, 1
        \\    last_try_value_ok = eq last_try, 33
        \\    hit_flag_ok = eq hit_ok, 1
        \\    hit_value_ok = eq hit, 22
        \\    miss_flag_ok = eq miss_ok, 0
        \\    miss_value_ok = eq miss, 0
        \\    contains_22_ok = eq contains_22, 1
        \\    contains_44_ok = eq contains_44, 0
        \\    strip_prefix_flag_ok = eq strip_prefix_ok, 1
        \\    strip_suffix_flag_ok = eq strip_suffix_ok, 1
        \\    strip_prefix_miss_flag_ok = eq strip_prefix_miss_ok, 0
        \\    strip_prefix_tail_len_ok = eq strip_prefix_tail_len, 1
        \\    strip_prefix_tail_first_ok = eq strip_prefix_tail_first, 33
        \\    strip_suffix_head_len_ok = eq strip_suffix_head_len, 1
        \\    strip_suffix_head_first_ok = eq strip_suffix_head_first, 11
        \\    strip_prefix_miss_empty_ok = eq strip_prefix_miss_empty, 1
        \\    empty_first_flag_ok = eq empty_first_ok, 0
        \\    empty_first_value_ok = eq empty_first, 0
        \\    empty_last_flag_ok = eq empty_last_ok, 0
        \\    empty_last_value_ok = eq empty_last, 0
        \\    ok01 = and ptr_ok, empty_ok
        \\    ok02 = and ok01, first_ok
        \\    ok03 = and ok02, last_ok
        \\    ok04 = and ok03, first_try_flag_ok
        \\    ok05 = and ok04, first_try_value_ok
        \\    ok06 = and ok05, last_try_flag_ok
        \\    ok07 = and ok06, last_try_value_ok
        \\    ok08 = and ok07, hit_flag_ok
        \\    ok09 = and ok08, hit_value_ok
        \\    ok10 = and ok09, miss_flag_ok
        \\    ok11 = and ok10, miss_value_ok
        \\    ok12 = and ok11, contains_22_ok
        \\    ok13 = and ok12, contains_44_ok
        \\    ok14 = and ok13, strip_prefix_flag_ok
        \\    ok15 = and ok14, strip_suffix_flag_ok
        \\    ok16 = and ok15, strip_prefix_miss_flag_ok
        \\    ok17 = and ok16, strip_prefix_tail_len_ok
        \\    ok18 = and ok17, strip_prefix_tail_first_ok
        \\    ok19 = and ok18, strip_suffix_head_len_ok
        \\    ok20 = and ok19, strip_suffix_head_first_ok
        \\    ok21 = and ok20, strip_prefix_miss_empty_ok
        \\    ok22 = and ok21, empty_first_flag_ok
        \\    ok23 = and ok22, empty_first_value_ok
        \\    ok24 = and ok23, empty_last_flag_ok
        \\    ok = and ok24, empty_last_value_ok
        \\    !ptr
        \\    !empty
        \\    !first
        \\    !last
        \\    !first_try_ok
        \\    !first_try
        \\    !last_try_ok
        \\    !last_try
        \\    !hit_ok
        \\    !hit
        \\    !miss_ok
        \\    !miss
        \\    !contains_22
        \\    !contains_44
        \\    !strip_prefix_ok
        \\    !strip_prefix_tail
        \\    !strip_suffix_ok
        \\    !strip_suffix_head
        \\    !strip_prefix_miss_ok
        \\    !strip_prefix_miss
        \\    !strip_prefix_tail_len
        \\    !strip_prefix_tail_first
        \\    !strip_suffix_head_len
        \\    !strip_suffix_head_first
        \\    !strip_prefix_miss_empty
        \\    !empty_first_ok
        \\    !empty_first
        \\    !empty_last_ok
        \\    !empty_last
        \\    !ptr_ok
        \\    !empty_ok
        \\    !first_ok
        \\    !last_ok
        \\    !first_try_flag_ok
        \\    !first_try_value_ok
        \\    !last_try_flag_ok
        \\    !last_try_value_ok
        \\    !hit_flag_ok
        \\    !hit_value_ok
        \\    !miss_flag_ok
        \\    !miss_value_ok
        \\    !contains_22_ok
        \\    !contains_44_ok
        \\    !strip_prefix_flag_ok
        \\    !strip_suffix_flag_ok
        \\    !strip_prefix_miss_flag_ok
        \\    !strip_prefix_tail_len_ok
        \\    !strip_prefix_tail_first_ok
        \\    !strip_suffix_head_len_ok
        \\    !strip_suffix_head_first_ok
        \\    !strip_prefix_miss_empty_ok
        \\    !empty_first_flag_ok
        \\    !empty_first_value_ok
        \\    !empty_last_flag_ok
        \\    !empty_last_value_ok
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
        \\    !ok16
        \\    !ok17
        \\    !ok18
        \\    !ok19
        \\    !ok20
        \\    !ok21
        \\    !ok22
        \\    !ok23
        \\    !ok24
        \\    !miss_prefix_slice
        \\    !suffix_slice
        \\    !prefix_slice
        \\    !miss_prefix_data
        \\    !empty_slice
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
    var slice_fixture_flat = try flattenFixture(std.testing.allocator, "tests/slice_fixture.sars", slice_fixture);
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

    const mem_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/mem.sars");
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

test "sa_std package manifest declares the std package boundary" {
    const manifest_src = try common.readFileAlloc(std.testing.allocator, "sa_std/sa.mod");
    defer std.testing.allocator.free(manifest_src);

    var manifest_file = try saasm.pkg.manifest.parseManifestWithFile(std.testing.allocator, manifest_src, "sa_std/sa.mod");
    defer manifest_file.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), manifest_file.requires.len);
    try std.testing.expectEqual(@as(usize, 0), manifest_file.mirrors.len);
}

test "sa_std package manifest metadata grammar round trips" {
    const source =
        \\package {
        \\  name "sa_std"
        \\  version "0.1.0"
        \\  abi 7
        \\  features ["core", "windows"]
        \\}
    ;
    var manifest_file = try saasm.pkg.manifest.parseManifestWithFile(std.testing.allocator, source, "fixture/sa.mod");
    defer manifest_file.deinit(std.testing.allocator);
    try std.testing.expect(manifest_file.package_decl != null);
    try std.testing.expectEqualStrings("sa_std", manifest_file.package_decl.?.name);
    try std.testing.expectEqualStrings("0.1.0", manifest_file.package_decl.?.version.?);
    try std.testing.expectEqual(@as(?u32, 7), manifest_file.package_decl.?.abi);
    try std.testing.expectEqual(@as(usize, 2), manifest_file.package_decl.?.features.len);
}

test "sa_std http2 buffer accessors borrow handles before free" {
    const http2_src = try common.readFileAlloc(std.testing.allocator, "sa_std/http2.sars");
    defer std.testing.allocator.free(http2_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, http2_src, 1, "sa_std_http2_buffer_data(%buffer)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, http2_src, 1, "sa_std_http2_buffer_len(%buffer)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, http2_src, 1, "sa_std_http2_buffer_free(^%buffer)"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, http2_src, 1, "sa_std_http2_buffer_len(^%buffer)"));
}

test "sa_std io and process interfaces match native resource ABI" {
    const io_iface = try common.readFileAlloc(std.testing.allocator, "sa_std/io.sai");
    defer std.testing.allocator.free(io_iface);
    try std.testing.expect(std.mem.containsAtLeast(u8, io_iface, 1, "@extern sa_io_stdin() -> u64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_iface, 1, "@extern sa_io_read(handle: u64, &buf: ptr, cap: u64, &out_read: ptr) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_iface, 1, "@extern sa_io_write(handle: u64, &buf: ptr, len: u64, &out_written: ptr) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_iface, 1, "@extern sa_io_close(handle: u64) -> i32"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, io_iface, 1, "@extern sa_io_read(handle: ptr, &buf: ptr, cap: u64) -> u64!"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, io_iface, 1, "@extern sa_io_close(^handle: ptr) -> i32!"));

    const process_iface = try common.readFileAlloc(std.testing.allocator, "sa_std/process.sai");
    defer std.testing.allocator.free(process_iface);
    try std.testing.expect(std.mem.containsAtLeast(u8, process_iface, 1, "@extern sa_std_process_run(&argv: ptr, argv_len: u64, &out_handle: ptr) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, process_iface, 1, "@extern sa_std_process_id() -> u32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, process_iface, 1, "@extern sa_std_process_abort() -> void"));
    try std.testing.expect(std.mem.containsAtLeast(u8, process_iface, 1, "@extern sa_std_process_child_id(handle: u64, &out_pid: ptr) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, process_iface, 1, "@extern sa_std_process_wait(handle: u64, &out_code: ptr) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, process_iface, 1, "@extern sa_std_process_try_wait(handle: u64, &out_ready: ptr, &out_code: ptr) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, process_iface, 1, "@extern sa_std_process_kill(handle: u64) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, process_iface, 1, "@extern sa_std_process_read_stdout(handle: u64, &buf: ptr, cap: u64, &out_read: ptr) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, process_iface, 1, "@extern sa_std_process_read_stderr(handle: u64, &buf: ptr, cap: u64, &out_read: ptr) -> i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, process_iface, 1, "@extern sa_std_process_close(handle: u64) -> i32"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, process_iface, 1, "sa_std_process_wait(handle: ptr"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, process_iface, 1, "sa_std_process_close(^handle: ptr"));

    const process_src = try common.readFileAlloc(std.testing.allocator, "sa_std/process.sars");
    defer std.testing.allocator.free(process_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, process_src, 1, "[MACRO] PROCESS_ABORT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, process_src, 1, "[MACRO] PROCESS_CHILD_ID %out_status, %out_pid, %process"));
    try std.testing.expect(std.mem.containsAtLeast(u8, process_src, 1, "[MACRO] PROCESS_TRY_WAIT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, process_src, 1, "[MACRO] PROCESS_TRY_WAIT_EXIT_STATUS"));
    try std.testing.expect(std.mem.containsAtLeast(u8, process_src, 1, "[MACRO] PROCESS_KILL"));

    const io_src = try common.readFileAlloc(std.testing.allocator, "sa_std/io.sars");
    defer std.testing.allocator.free(io_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, io_src, 1, "[MACRO] READ "));
    try std.testing.expect(std.mem.containsAtLeast(u8, io_src, 1, "[MACRO] WRITE_SOME"));
    var io_flat = try flattenFixture(std.testing.allocator, "sa_std/io.sars", io_src);
    defer io_flat.deinit(std.testing.allocator);
    try std.testing.expect(io_flat.function_sigs.len > 0);

    const buf_reader_src = try common.readFileAlloc(std.testing.allocator, "sa_std/io/buf_reader.sars");
    defer std.testing.allocator.free(buf_reader_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, buf_reader_src, 1, "call @sa_io_read(%handle, &%buf, %cap, &__buf_reader_read_slot)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, buf_reader_src, 1, "call @sa_io_close(%handle)"));
    var buf_reader_flat = try flattenFixture(std.testing.allocator, "sa_std/io/buf_reader.sars", buf_reader_src);
    defer buf_reader_flat.deinit(std.testing.allocator);
    try std.testing.expect(buf_reader_flat.function_sigs.len > 0);

    const buf_writer_src = try common.readFileAlloc(std.testing.allocator, "sa_std/io/buf_writer.sars");
    defer std.testing.allocator.free(buf_writer_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, buf_writer_src, 1, "call @sa_io_write(%handle, &%buf, %len, &__buf_writer_write_slot)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, buf_writer_src, 1, "call @sa_io_close(%handle)"));
    var buf_writer_flat = try flattenFixture(std.testing.allocator, "sa_std/io/buf_writer.sars", buf_writer_src);
    defer buf_writer_flat.deinit(std.testing.allocator);
    try std.testing.expect(buf_writer_flat.function_sigs.len > 0);
}

test "sa_std Deno JSON-RPC params string literal preserves escaped strings" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const runtime_source = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime/sa_std.zig");
    defer std.testing.allocator.free(runtime_source);
    const pthread_host_source = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime/sa_pthread_host.c");
    defer std.testing.allocator.free(pthread_host_source);
    const include_dir = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime");
    defer std.testing.allocator.free(include_dir);

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const c_source =
        \\#include "sa_std.h"
        \\#include <stdint.h>
        \\#include <stdio.h>
        \\#include <string.h>
        \\
        \\static int equals_and_free(uint64_t h, const char *expected) {
        \\    uint8_t *data = sa_fs_read_buffer_data(h);
        \\    uint64_t len = sa_fs_read_buffer_len(h);
        \\    size_t expected_len = strlen(expected);
        \\    int ok = h != 0 && data != NULL && len == expected_len && memcmp(data, expected, expected_len) == 0;
        \\    if (h != 0 && sa_fs_read_buffer_free(h) != SA_STD_OK) return 0;
        \\    return ok;
        \\}
        \\
        \\int main(void) {
        \\    const uint8_t body[] = "{\"jsonrpc\":\"2.0\",\"params\":{\"name\":\"env \\\"quoted\\\"\",\"path\":\"/tmp/a\\\\b\",\"note\":null}}";
        \\    const uint8_t invalid[] = "{\"jsonrpc\":\"2.0\",\"params\":";
        \\    const uint8_t fallback[] = "fallback \"value\"";
        \\    uint64_t h = 0;
        \\
        \\    h = sa_deno_jsonrpc_params_string_literal(body, sizeof(body) - 1, (const uint8_t *)"name", 4, (const uint8_t *)"", 0, 0);
        \\    if (!equals_and_free(h, "\"env \\\"quoted\\\"\"")) return 2;
        \\
        \\    h = sa_deno_jsonrpc_params_string_literal(body, sizeof(body) - 1, (const uint8_t *)"path", 4, (const uint8_t *)"", 0, 0);
        \\    if (!equals_and_free(h, "\"/tmp/a\\\\b\"")) return 3;
        \\
        \\    h = sa_deno_jsonrpc_params_string_literal(body, sizeof(body) - 1, (const uint8_t *)"missing", 7, fallback, sizeof(fallback) - 1, 0);
        \\    if (!equals_and_free(h, "\"fallback \\\"value\\\"\"")) return 4;
        \\
        \\    h = sa_deno_jsonrpc_params_string_literal(body, sizeof(body) - 1, (const uint8_t *)"missing", 7, fallback, sizeof(fallback) - 1, 1);
        \\    if (!equals_and_free(h, "null")) return 5;
        \\
        \\    h = sa_deno_jsonrpc_params_string_literal(body, sizeof(body) - 1, (const uint8_t *)"note", 4, fallback, sizeof(fallback) - 1, 0);
        \\    if (!equals_and_free(h, "\"fallback \\\"value\\\"\"")) return 6;
        \\
        \\    h = sa_deno_jsonrpc_params_string_literal(invalid, sizeof(invalid) - 1, (const uint8_t *)"name", 4, fallback, sizeof(fallback) - 1, 1);
        \\    if (!equals_and_free(h, "null")) return 7;
        \\
        \\    puts("sa_std deno jsonrpc params string literal ok");
        \\    return 0;
        \\}
        \\
    ;
    try common.writeSource(tmp.dir, "main.c", c_source);
    const build_lib_result = try common.runCommand(std.testing.allocator, &.{
        "zig",
        "build-lib",
        runtime_source,
        pthread_host_source,
        "-O",
        "Debug",
        "-lc",
        "-femit-bin=libsa_std.a",
    });
    defer std.testing.allocator.free(build_lib_result.stdout);
    defer std.testing.allocator.free(build_lib_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_lib_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const build_demo_result = try common.runCommand(std.testing.allocator, &.{
        "zig",
        "cc",
        "-I",
        include_dir,
        "main.c",
        "libsa_std.a",
        "-lc",
        "-o",
        "sa_std_deno_jsonrpc_params",
    });
    defer std.testing.allocator.free(build_demo_result.stdout);
    defer std.testing.allocator.free(build_demo_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_demo_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const run_result = try common.runCommand(std.testing.allocator, &.{"./sa_std_deno_jsonrpc_params"});
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (run_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });
    try std.testing.expectEqualStrings("sa_std deno jsonrpc params string literal ok\n", run_result.stdout);
}

test "sa_std Deno chat SSE fallback normalizes Deno proxy edge cases" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const runtime_source = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime/sa_std.zig");
    defer std.testing.allocator.free(runtime_source);
    const pthread_host_source = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime/sa_pthread_host.c");
    defer std.testing.allocator.free(pthread_host_source);
    const include_dir = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime");
    defer std.testing.allocator.free(include_dir);

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const c_source =
        \\#include "sa_std.h"
        \\#include <stdint.h>
        \\#include <stdio.h>
        \\#include <string.h>
        \\
        \\static int has(uint8_t *data, uint64_t len, const char *needle) {
        \\    size_t nlen = strlen(needle);
        \\    if (nlen == 0) return 1;
        \\    if (len < nlen) return 0;
        \\    for (uint64_t i = 0; i <= len - nlen; i++) {
        \\        if (memcmp(data + i, needle, nlen) == 0) return 1;
        \\    }
        \\    return 0;
        \\}
        \\
        \\static int count(uint8_t *data, uint64_t len, const char *needle) {
        \\    size_t nlen = strlen(needle);
        \\    int found = 0;
        \\    if (nlen == 0 || len < nlen) return 0;
        \\    for (uint64_t i = 0; i <= len - nlen; i++) {
        \\        if (memcmp(data + i, needle, nlen) == 0) {
        \\            found++;
        \\            i += nlen - 1;
        \\        }
        \\    }
        \\    return found;
        \\}
        \\
        \\int main(void) {
        \\    const uint8_t req[] = "{\"tools\":[{\"type\":\"function\",\"name\":\"exec_command\"}],\"input\":[{\"role\":\"user\",\"content\":\"hello\"}]}";
        \\    const uint8_t goal_req[] = "{\"tools\":[{\"type\":\"function\",\"name\":\"exec_command\"}],\"input\":[{\"role\":\"developer\",\"content\":\"<goal_context>Continue working.</goal_context>\"}]}";
        \\    const uint8_t default_req[] = "{\"tools\":[{\"type\":\"function\",\"name\":\"exec_command\"}],\"input\":[{\"role\":\"developer\",\"content\":\"<collaboration_mode># Collaboration Mode: Default</collaboration_mode>\"}]}";
        \\    const uint8_t namespace_req[] = "{\"tools\":[{\"type\":\"namespace\",\"name\":\"mcp__code_index__\",\"tools\":[{\"type\":\"function\",\"name\":\"describe_index\"}]}]}";
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
        \\    const uint8_t multi_visible_chat[] =
        \\        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think\"},\"finish_reason\":null}]}\n\n"
        \\        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}\n\n"
        \\        "data: {\"choices\":[{\"delta\":{\"content\":\" world\"},\"finish_reason\":null}]}\n\n"
        \\        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        \\        "data: [DONE]\n\n";
        \\    uint64_t h = sa_deno_chat_sse_to_responses(env_chat, sizeof(env_chat) - 1, req, sizeof(req) - 1);
        \\    uint8_t *data = sa_fs_read_buffer_data(h);
        \\    uint64_t len = sa_fs_read_buffer_len(h);
        \\    if (h == 0 || data == NULL || len == 0) return 2;
        \\    if (!has(data, len, "sed -E") || !has(data, len, "<redacted>") || !has(data, len, "/tmp/demo/.env.local")) return 3;
        \\    if (has(data, len, "cat '/tmp/demo/.env.local'")) return 4;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 5;
        \\
        \\    h = sa_deno_chat_sse_to_responses(namespace_chat, sizeof(namespace_chat) - 1, namespace_req, sizeof(namespace_req) - 1);
        \\    data = sa_fs_read_buffer_data(h);
        \\    len = sa_fs_read_buffer_len(h);
        \\    if (h == 0 || data == NULL || len == 0) return 6;
        \\    if (!has(data, len, "\"namespace\":\"mcp__code_index__\"")) return 7;
        \\    if (!has(data, len, "\"name\":\"describe_index\"")) return 8;
        \\    if (!has(data, len, "\"output_kind\":\"function_call_output\"")) return 9;
        \\    if (has(data, len, "\"name\":\"mcp__code_index__describe_index\"")) return 10;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 11;
        \\
        \\    h = sa_deno_chat_sse_to_responses(progress_chat, sizeof(progress_chat) - 1, req, sizeof(req) - 1);
        \\    data = sa_fs_read_buffer_data(h);
        \\    len = sa_fs_read_buffer_len(h);
        \\    if (h == 0 || data == NULL || len == 0) return 12;
        \\    if (has(data, len, "Progress-only message received")) return 13;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 14;
        \\
        \\    h = sa_deno_chat_sse_to_responses(progress_chat, sizeof(progress_chat) - 1, goal_req, sizeof(goal_req) - 1);
        \\    data = sa_fs_read_buffer_data(h);
        \\    len = sa_fs_read_buffer_len(h);
        \\    if (h == 0 || data == NULL || len == 0) return 15;
        \\    if (!has(data, len, "Progress-only message received")) return 16;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 17;
        \\
        \\    h = sa_deno_chat_sse_to_responses(progress_chat, sizeof(progress_chat) - 1, default_req, sizeof(default_req) - 1);
        \\    data = sa_fs_read_buffer_data(h);
        \\    len = sa_fs_read_buffer_len(h);
        \\    if (h == 0 || data == NULL || len == 0) return 18;
        \\    if (!has(data, len, "Progress-only message received")) return 19;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 20;
        \\
        \\    h = sa_deno_chat_sse_to_responses(final_chat, sizeof(final_chat) - 1, goal_req, sizeof(goal_req) - 1);
        \\    data = sa_fs_read_buffer_data(h);
        \\    len = sa_fs_read_buffer_len(h);
        \\    if (h == 0 || data == NULL || len == 0) return 21;
        \\    if (has(data, len, "Progress-only message received")) return 22;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 23;
        \\
        \\    h = sa_deno_chat_sse_to_responses(multi_visible_chat, sizeof(multi_visible_chat) - 1, req, sizeof(req) - 1);
        \\    data = sa_fs_read_buffer_data(h);
        \\    len = sa_fs_read_buffer_len(h);
        \\    if (h == 0 || data == NULL || len == 0) return 24;
        \\    if (!has(data, len, "\"item_id\":\"msg_chat_fb\"")) return 25;
        \\    if (!has(data, len, "\"content_index\":0")) return 26;
        \\    if (!has(data, len, "\"delta\":\"Hello\"") || !has(data, len, "\"delta\":\" world\"")) return 27;
        \\    if (count(data, len, "event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"think_chat_fb\"") != 1) return 28;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 29;
        \\    puts("sa_std deno chat sse proxy edge cases ok");
        \\    return 0;
        \\}
        \\
    ;
    try common.writeSource(tmp.dir, "main.c", c_source);
    const build_lib_result = try common.runCommand(std.testing.allocator, &.{
        "zig",
        "build-lib",
        runtime_source,
        pthread_host_source,
        "-O",
        "Debug",
        "-lc",
        "-femit-bin=libsa_std.a",
    });
    defer std.testing.allocator.free(build_lib_result.stdout);
    defer std.testing.allocator.free(build_lib_result.stderr);
    const exit_code = switch (build_lib_result.term) {
        .exited => |code| code,
        else => 99,
    };
    if (exit_code != 0) {
        std.debug.print("build-lib failed with code {d}:\nstdout: {s}\nstderr: {s}\n", .{ exit_code, build_lib_result.stdout, build_lib_result.stderr });
    }
    try std.testing.expectEqual(@as(u8, 0), exit_code);

    const build_demo_result = try common.runCommand(std.testing.allocator, &.{
        "zig",
        "cc",
        "-I",
        include_dir,
        "main.c",
        "libsa_std.a",
        "-lc",
        "-o",
        "sa_std_deno_chat_sse_edges",
    });
    defer std.testing.allocator.free(build_demo_result.stdout);
    defer std.testing.allocator.free(build_demo_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_demo_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const run_result = try common.runCommand(std.testing.allocator, &.{"./sa_std_deno_chat_sse_edges"});
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (run_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });
    try std.testing.expectEqualStrings("sa_std deno chat sse proxy edge cases ok\n", run_result.stdout);
}

test "sa_std Deno chat JSON fallback normalizes Deno proxy edge cases" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const runtime_source = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime/sa_std.zig");
    defer std.testing.allocator.free(runtime_source);
    const pthread_host_source = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime/sa_pthread_host.c");
    defer std.testing.allocator.free(pthread_host_source);
    const include_dir = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime");
    defer std.testing.allocator.free(include_dir);

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const c_source =
        \\#include "sa_std.h"
        \\#include <stdint.h>
        \\#include <stdio.h>
        \\#include <string.h>
        \\
        \\static int has(uint8_t *data, uint64_t len, const char *needle) {
        \\    size_t nlen = strlen(needle);
        \\    if (nlen == 0) return 1;
        \\    if (len < nlen) return 0;
        \\    for (uint64_t i = 0; i <= len - nlen; i++) {
        \\        if (memcmp(data + i, needle, nlen) == 0) return 1;
        \\    }
        \\    return 0;
        \\}
        \\
        \\static int check(uint64_t h, const char *needle) {
        \\    uint8_t *data = sa_fs_read_buffer_data(h);
        \\    uint64_t len = sa_fs_read_buffer_len(h);
        \\    if (h == 0 || data == NULL || len == 0) return 0;
        \\    return has(data, len, needle);
        \\}
        \\
        \\int main(void) {
        \\    const uint8_t req[] = "{\"tools\":[{\"type\":\"function\",\"name\":\"exec_command\"}],\"input\":[{\"role\":\"user\",\"content\":\"hello\"}]}";
        \\    const uint8_t goal_req[] = "{\"tools\":[{\"type\":\"function\",\"name\":\"exec_command\"}],\"input\":[{\"role\":\"developer\",\"content\":\"<goal_context>Continue working.</goal_context>\"}]}";
        \\    const uint8_t content_chat[] = "{\"choices\":[{\"message\":{\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":3}}";
        \\    const uint8_t thought_chat[] = "{\"choices\":[{\"message\":{\"content\":\"<thought>internal</thought>Hello\"}}]}";
        \\    const uint8_t reasoning_chat[] = "{\"choices\":[{\"message\":{\"reasoning_content\":\"json think\",\"content\":\"answer\"}}]}";
        \\    const uint8_t tool_chat[] = "{\"choices\":[{\"message\":{\"tool_calls\":[{\"id\":\"call_read\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"filePath\\\":\\\"/tmp/demo/.env.local\\\"}\"}}]}}]}";
        \\    const uint8_t progress_chat[] = "{\"choices\":[{\"message\":{\"content\":\"Let me check the test failure details.\"}}]}";
        \\
        \\    uint64_t h = sa_deno_chat_json_to_responses(content_chat, sizeof(content_chat) - 1, req, sizeof(req) - 1);
        \\    if (!check(h, "\"output_text\":\"ok\"")) return 2;
        \\    if (!check(h, "\"input_tokens\":1") || !check(h, "\"output_tokens\":2") || !check(h, "\"total_tokens\":3")) return 3;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 4;
        \\
        \\    h = sa_deno_chat_json_to_responses(thought_chat, sizeof(thought_chat) - 1, req, sizeof(req) - 1);
        \\    if (!check(h, "\"type\":\"reasoning\"") || !check(h, "internal") || !check(h, "\"output_text\":\"Hello\"")) return 5;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 6;
        \\
        \\    h = sa_deno_chat_json_to_responses(reasoning_chat, sizeof(reasoning_chat) - 1, req, sizeof(req) - 1);
        \\    if (!check(h, "json think") || !check(h, "\"output_text\":\"answer\"")) return 7;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 8;
        \\
        \\    h = sa_deno_chat_json_to_responses(tool_chat, sizeof(tool_chat) - 1, req, sizeof(req) - 1);
        \\    if (!check(h, "\"type\":\"function_call\"") || !check(h, "\"name\":\"exec_command\"")) return 9;
        \\    if (!check(h, "sed -E") || !check(h, "<redacted>")) return 10;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 11;
        \\
        \\    h = sa_deno_chat_json_to_responses(progress_chat, sizeof(progress_chat) - 1, req, sizeof(req) - 1);
        \\    if (check(h, "Progress-only message received")) return 12;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 13;
        \\
        \\    h = sa_deno_chat_json_to_responses(progress_chat, sizeof(progress_chat) - 1, goal_req, sizeof(goal_req) - 1);
        \\    if (!check(h, "Progress-only message received")) return 14;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 15;
        \\
        \\    puts("sa_std deno chat json proxy edge cases ok");
        \\    return 0;
        \\}
        \\
    ;
    try common.writeSource(tmp.dir, "main.c", c_source);
    const build_lib_result = try common.runCommand(std.testing.allocator, &.{
        "zig",
        "build-lib",
        runtime_source,
        pthread_host_source,
        "-O",
        "Debug",
        "-lc",
        "-femit-bin=libsa_std.a",
    });
    defer std.testing.allocator.free(build_lib_result.stdout);
    defer std.testing.allocator.free(build_lib_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_lib_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const build_demo_result = try common.runCommand(std.testing.allocator, &.{
        "zig",
        "cc",
        "-I",
        include_dir,
        "main.c",
        "libsa_std.a",
        "-lc",
        "-o",
        "sa_std_deno_chat_json_edges",
    });
    defer std.testing.allocator.free(build_demo_result.stdout);
    defer std.testing.allocator.free(build_demo_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_demo_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const run_result = try common.runCommand(std.testing.allocator, &.{"./sa_std_deno_chat_json_edges"});
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (run_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });
    try std.testing.expectEqualStrings("sa_std deno chat json proxy edge cases ok\n", run_result.stdout);
}

test "sa_std Deno native responses JSON preserves ordinary responses and normalizes thinking" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const runtime_source = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime/sa_std.zig");
    defer std.testing.allocator.free(runtime_source);
    const pthread_host_source = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime/sa_pthread_host.c");
    defer std.testing.allocator.free(pthread_host_source);
    const include_dir = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime");
    defer std.testing.allocator.free(include_dir);

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const c_source =
        \\#include "sa_std.h"
        \\#include <stdint.h>
        \\#include <stdio.h>
        \\#include <string.h>
        \\
        \\static int has(uint8_t *data, uint64_t len, const char *needle) {
        \\    size_t nlen = strlen(needle);
        \\    if (nlen == 0) return 1;
        \\    if (len < nlen) return 0;
        \\    for (uint64_t i = 0; i <= len - nlen; i++) {
        \\        if (memcmp(data + i, needle, nlen) == 0) return 1;
        \\    }
        \\    return 0;
        \\}
        \\
        \\static int check(uint64_t h, const char *needle) {
        \\    uint8_t *data = sa_fs_read_buffer_data(h);
        \\    uint64_t len = sa_fs_read_buffer_len(h);
        \\    if (h == 0 || data == NULL || len == 0) return 0;
        \\    return has(data, len, needle);
        \\}
        \\
        \\int main(void) {
        \\    const uint8_t ordinary[] = "{\"output\":[],\"status\":\"completed\"}";
        \\    const uint8_t thinking[] = "{\"id\":\"resp_1\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"thinking\":\"private\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}],\"output_text\":\"answer\",\"status\":\"completed\"}";
        \\
        \\    uint64_t h = sa_deno_responses_json_normalize(ordinary, sizeof(ordinary) - 1);
        \\    if (!check(h, "\"output\":[]") || !check(h, "\"status\":\"completed\"")) return 2;
        \\    if (check(h, "\"output_text\":\"\"")) return 3;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 4;
        \\
        \\    h = sa_deno_responses_json_normalize(thinking, sizeof(thinking) - 1);
        \\    if (!check(h, "\"type\":\"reasoning\"") || !check(h, "private") || !check(h, "\"output_text\":\"answer\"")) return 5;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 6;
        \\
        \\    puts("sa_std deno responses json normalize ok");
        \\    return 0;
        \\}
        \\
    ;
    try common.writeSource(tmp.dir, "main.c", c_source);
    const build_lib_result = try common.runCommand(std.testing.allocator, &.{
        "zig",
        "build-lib",
        runtime_source,
        pthread_host_source,
        "-O",
        "Debug",
        "-lc",
        "-femit-bin=libsa_std.a",
    });
    defer std.testing.allocator.free(build_lib_result.stdout);
    defer std.testing.allocator.free(build_lib_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_lib_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const build_demo_result = try common.runCommand(std.testing.allocator, &.{
        "zig",
        "cc",
        "-I",
        include_dir,
        "main.c",
        "libsa_std.a",
        "-lc",
        "-o",
        "sa_std_deno_responses_json_normalize",
    });
    defer std.testing.allocator.free(build_demo_result.stdout);
    defer std.testing.allocator.free(build_demo_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_demo_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const run_result = try common.runCommand(std.testing.allocator, &.{"./sa_std_deno_responses_json_normalize"});
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (run_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });
    try std.testing.expectEqualStrings("sa_std deno responses json normalize ok\n", run_result.stdout);
}

test "sa_std Deno native responses SSE normalizes MCP events generically" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const runtime_source = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime/sa_std.zig");
    defer std.testing.allocator.free(runtime_source);
    const pthread_host_source = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime/sa_pthread_host.c");
    defer std.testing.allocator.free(pthread_host_source);
    const include_dir = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime");
    defer std.testing.allocator.free(include_dir);

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const c_source =
        \\#include "sa_std.h"
        \\#include <stdint.h>
        \\#include <stdio.h>
        \\#include <string.h>
        \\
        \\static int has(uint8_t *data, uint64_t len, const char *needle) {
        \\    size_t nlen = strlen(needle);
        \\    if (nlen == 0) return 1;
        \\    if (len < nlen) return 0;
        \\    for (uint64_t i = 0; i <= len - nlen; i++) {
        \\        if (memcmp(data + i, needle, nlen) == 0) return 1;
        \\    }
        \\    return 0;
        \\}
        \\
        \\int main(void) {
        \\    const uint8_t sse[] =
        \\        "event: response.output_item.added\n"
        \\        "data: {\"type\":\"response.output_item.added\",\"item\":{\"id\":\"tc_search\",\"type\":\"function_call\",\"name\":\"mcp__code_index__search\",\"arguments\":\"{\\\"query\\\":\\\"hello\\\"}\"}}\n\n"
        \\        "event: response.output_item.done\n"
        \\        "data: {\"type\":\"response.output_item.done\",\"item\":{\"id\":\"tc_read\",\"type\":\"function_call\",\"name\":\"mcp__code_index__.read_mcp_resource\",\"arguments\":\"{\\\"server\\\":\\\"code_index\\\",\\\"uri\\\":\\\"file:///foo\\\"}\"}}\n\n"
        \\        "event: response.output_item.done\n"
        \\        "data: {\"type\":\"response.output_item.done\",\"item\":{\"id\":\"tc_custom\",\"type\":\"function_call\",\"name\":\"mcp__custom_tool__some_tool\",\"arguments\":\"{\\\"server\\\":\\\"mcp__custom_tool__\\\"}\"}}\n\n"
        \\        "event: response.completed\n"
        \\        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp\",\"status\":\"completed\"}}\n\n";
        \\    uint64_t h = sa_deno_responses_sse_normalize(sse, sizeof(sse) - 1);
        \\    uint8_t *data = sa_fs_read_buffer_data(h);
        \\    uint64_t len = sa_fs_read_buffer_len(h);
        \\    if (h == 0 || data == NULL || len == 0) return 2;
        \\    if (!has(data, len, "\"namespace\":\"mcp__code_index__\"")) return 3;
        \\    if (!has(data, len, "\"name\":\"search\"")) return 4;
        \\    if (!has(data, len, "\"name\":\"read_mcp_resource\"")) return 5;
        \\    if (!has(data, len, "\\\"server\\\":\\\"code-index\\\"")) return 6;
        \\    if (!has(data, len, "\"namespace\":\"mcp__custom_tool__\"")) return 7;
        \\    if (!has(data, len, "\"name\":\"some_tool\"")) return 8;
        \\    if (!has(data, len, "\\\"server\\\":\\\"custom-tool\\\"")) return 9;
        \\    if (!has(data, len, "\"output_kind\":\"function_call_output\"")) return 10;
        \\    if (has(data, len, "\"name\":\"mcp__code_index__search\"")) return 11;
        \\    if (has(data, len, "\"name\":\"mcp__custom_tool__some_tool\"")) return 12;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 13;
        \\    puts("sa_std deno responses sse normalize ok");
        \\    return 0;
        \\}
        \\
    ;
    try common.writeSource(tmp.dir, "main.c", c_source);
    const build_lib_result = try common.runCommand(std.testing.allocator, &.{
        "zig",
        "build-lib",
        runtime_source,
        pthread_host_source,
        "-O",
        "Debug",
        "-lc",
        "-femit-bin=libsa_std.a",
    });
    defer std.testing.allocator.free(build_lib_result.stdout);
    defer std.testing.allocator.free(build_lib_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_lib_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const build_demo_result = try common.runCommand(std.testing.allocator, &.{
        "zig",
        "cc",
        "-I",
        include_dir,
        "main.c",
        "libsa_std.a",
        "-lc",
        "-o",
        "sa_std_deno_responses_sse_normalize",
    });
    defer std.testing.allocator.free(build_demo_result.stdout);
    defer std.testing.allocator.free(build_demo_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_demo_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const run_result = try common.runCommand(std.testing.allocator, &.{"./sa_std_deno_responses_sse_normalize"});
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (run_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });
    try std.testing.expectEqualStrings("sa_std deno responses sse normalize ok\n", run_result.stdout);
}

test "sa_std Deno responses request normalizes MCP server aliases generically" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const runtime_source = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime/sa_std.zig");
    defer std.testing.allocator.free(runtime_source);
    const pthread_host_source = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime/sa_pthread_host.c");
    defer std.testing.allocator.free(pthread_host_source);
    const include_dir = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime");
    defer std.testing.allocator.free(include_dir);

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const c_source =
        \\#include "sa_std.h"
        \\#include <stdint.h>
        \\#include <stdio.h>
        \\#include <string.h>
        \\
        \\static int has(uint8_t *data, uint64_t len, const char *needle) {
        \\    size_t nlen = strlen(needle);
        \\    if (nlen == 0) return 1;
        \\    if (len < nlen) return 0;
        \\    for (uint64_t i = 0; i <= len - nlen; i++) {
        \\        if (memcmp(data + i, needle, nlen) == 0) return 1;
        \\    }
        \\    return 0;
        \\}
        \\
        \\int main(void) {
        \\    const uint8_t body[] =
        \\        "{\"model\":\"m\",\"input\":["
        \\        "{\"type\":\"function_call\",\"name\":\"read_mcp_resource\",\"arguments\":\"{\\\"server\\\":\\\"Code Index\\\",\\\"uri\\\":\\\"file:///one\\\"}\"},"
        \\        "{\"type\":\"function_call\",\"name\":\"read_mcp_resource\",\"arguments\":\"{\\\"server\\\":\\\"mcp__mcp_code_index___\\\",\\\"uri\\\":\\\"file:///two\\\"}\"},"
        \\        "{\"type\":\"function_call\",\"name\":\"read_mcp_resource\",\"arguments\":\"{\\\"server\\\":\\\"Mimir\\\",\\\"uri\\\":\\\"file:///three\\\"}\"},"
        \\        "{\"type\":\"function_call\",\"name\":\"read_mcp_resource\",\"arguments\":\"{\\\"server\\\":\\\"Custom Tool\\\",\\\"uri\\\":\\\"file:///four\\\"}\"},"
        \\        "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Code Index should remain visible text\"}]}"
        \\        "]}";
        \\    uint64_t h = sa_deno_responses_request_normalize(body, sizeof(body) - 1);
        \\    uint8_t *data = sa_fs_read_buffer_data(h);
        \\    uint64_t len = sa_fs_read_buffer_len(h);
        \\    if (h == 0 || data == NULL || len == 0) return 2;
        \\    if (!has(data, len, "\\\"server\\\":\\\"mcp__code_index__\\\"")) return 3;
        \\    if (!has(data, len, "\\\"server\\\":\\\"mcp__mimir__\\\"")) return 4;
        \\    if (!has(data, len, "\\\"server\\\":\\\"mcp__custom_tool__\\\"")) return 5;
        \\    if (!has(data, len, "Code Index should remain visible text")) return 6;
        \\    if (has(data, len, "mcp__mcp_code_index___")) return 7;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 8;
        \\    puts("sa_std deno responses request normalize ok");
        \\    return 0;
        \\}
        \\
    ;
    try common.writeSource(tmp.dir, "main.c", c_source);
    const build_lib_result = try common.runCommand(std.testing.allocator, &.{
        "zig",
        "build-lib",
        runtime_source,
        pthread_host_source,
        "-O",
        "Debug",
        "-lc",
        "-femit-bin=libsa_std.a",
    });
    defer std.testing.allocator.free(build_lib_result.stdout);
    defer std.testing.allocator.free(build_lib_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_lib_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const build_demo_result = try common.runCommand(std.testing.allocator, &.{
        "zig",
        "cc",
        "-I",
        include_dir,
        "main.c",
        "libsa_std.a",
        "-lc",
        "-o",
        "sa_std_deno_responses_request_normalize",
    });
    defer std.testing.allocator.free(build_demo_result.stdout);
    defer std.testing.allocator.free(build_demo_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_demo_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const run_result = try common.runCommand(std.testing.allocator, &.{"./sa_std_deno_responses_request_normalize"});
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (run_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });
    try std.testing.expectEqualStrings("sa_std deno responses request normalize ok\n", run_result.stdout);
}

test "sa_std Deno responses chat fallback request builds chat body from Responses input arrays" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const runtime_source = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime/sa_std.zig");
    defer std.testing.allocator.free(runtime_source);
    const pthread_host_source = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime/sa_pthread_host.c");
    defer std.testing.allocator.free(pthread_host_source);
    const include_dir = try sio.cwd().realpathAlloc(std.testing.allocator, "src/runtime");
    defer std.testing.allocator.free(include_dir);

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    const c_source =
        \\#include "sa_std.h"
        \\#include <stdint.h>
        \\#include <stdio.h>
        \\#include <string.h>
        \\
        \\static int has(uint8_t *data, uint64_t len, const char *needle) {
        \\    size_t nlen = strlen(needle);
        \\    if (nlen == 0) return 1;
        \\    if (len < nlen) return 0;
        \\    for (uint64_t i = 0; i <= len - nlen; i++) {
        \\        if (memcmp(data + i, needle, nlen) == 0) return 1;
        \\    }
        \\    return 0;
        \\}
        \\
        \\int main(void) {
        \\    const uint8_t default_model[] = "fallback-model";
        \\    const uint8_t body[] =
        \\        "{\"model\":\"models/mimo-v2.5-pro\",\"stream\":false,"
        \\        "\"instructions\":\"follow instructions\","
        \\        "\"store\":false,\"prompt_cache_key\":\"drop-me\",\"include\":[\"reasoning.encrypted_content\"],\"reasoning\":{\"effort\":\"medium\"},"
        \\        "\"tools\":[{\"type\":\"namespace\",\"name\":\"mcp__code_index__\",\"tools\":[{\"type\":\"function\",\"name\":\"describe_index\",\"parameters\":{\"type\":\"object\"}}]}],"
        \\        "\"input\":["
        \\        "{\"type\":\"message\",\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"dev note\"}]},"
        \\        "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hello\"},{\"type\":\"text\",\"text\":\" world\"}]}"
        \\        "]}";
        \\    uint64_t h = sa_deno_responses_chat_fallback_request(body, sizeof(body) - 1, default_model, sizeof(default_model) - 1, 0);
        \\    uint8_t *data = sa_fs_read_buffer_data(h);
        \\    uint64_t len = sa_fs_read_buffer_len(h);
        \\    if (h == 0 || data == NULL || len == 0) return 2;
        \\    if (!has(data, len, "\"model\":\"models/mimo-v2.5-pro\"")) return 3;
        \\    if (!has(data, len, "\"role\":\"system\",\"content\":\"follow instructions\\n\\ndev note\"")) return 4;
        \\    if (!has(data, len, "\"role\":\"user\",\"content\":\"hello world\"")) return 5;
        \\    if (!has(data, len, "\"name\":\"mcp__code_index__describe_index\"")) return 6;
        \\    if (!has(data, len, "\"stream\":false")) return 7;
        \\    if (has(data, len, "prompt_cache_key") || has(data, len, "\"include\"") || has(data, len, "\"reasoning\"")) return 8;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 9;
        \\    const uint8_t top_body[] =
        \\        "{\"model\":\"top-model\",\"stream\":false,\"instructions\":\"top sys\","
        \\        "\"input\":\"top input\",\"content\":\"leak content\",\"text\":\"leak text\",\"store\":false}";
        \\    h = sa_deno_responses_chat_fallback_request(top_body, sizeof(top_body) - 1, default_model, sizeof(default_model) - 1, 0);
        \\    data = sa_fs_read_buffer_data(h);
        \\    len = sa_fs_read_buffer_len(h);
        \\    if (h == 0 || data == NULL || len == 0) return 10;
        \\    if (!has(data, len, "\"model\":\"top-model\"")) return 11;
        \\    if (!has(data, len, "\"role\":\"system\",\"content\":\"top sys\"")) return 12;
        \\    if (!has(data, len, "\"role\":\"user\",\"content\":\"top input\"")) return 13;
        \\    if (has(data, len, "\"input\"") || has(data, len, "leak content") || has(data, len, "leak text") || has(data, len, "\"store\"")) return 14;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 15;
        \\    const uint8_t tool_body[] =
        \\        "{\"model\":\"models/mimo-v2.5-pro\",\"stream\":false,"
        \\        "\"tools\":[{\"type\":\"function\",\"name\":\"exec_command\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}],"
        \\        "\"input\":["
        \\        "{\"type\":\"function_call\",\"call_id\":\"call-1\",\"name\":\"exec_command\",\"arguments\":\"{\\\"cmd\\\":\\\"echo hi\\\"}\"},"
        \\        "{\"type\":\"function_call_output\",\"call_id\":\"call-1\",\"output\":\"ok\"}"
        \\        "]}";
        \\    h = sa_deno_responses_chat_fallback_request(tool_body, sizeof(tool_body) - 1, default_model, sizeof(default_model) - 1, 0);
        \\    data = sa_fs_read_buffer_data(h);
        \\    len = sa_fs_read_buffer_len(h);
        \\    if (h == 0 || data == NULL || len == 0) return 16;
        \\    if (!has(data, len, "\"role\":\"assistant\",\"content\":null,\"tool_calls\"")) return 17;
        \\    if (!has(data, len, "\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"exec_command\"")) return 18;
        \\    if (!has(data, len, "\"role\":\"tool\",\"content\":\"ok\",\"tool_call_id\":\"call-1\",\"name\":\"exec_command\"")) return 19;
        \\    if (!has(data, len, "\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"exec_command\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}}]")) return 20;
        \\    if (sa_fs_read_buffer_free(h) != SA_STD_OK) return 21;
        \\    puts("sa_std deno responses chat fallback request ok");
        \\    return 0;
        \\}
        \\
    ;
    try common.writeSource(tmp.dir, "main.c", c_source);
    const build_lib_result = try common.runCommand(std.testing.allocator, &.{
        "zig",
        "build-lib",
        runtime_source,
        pthread_host_source,
        "-O",
        "Debug",
        "-lc",
        "-femit-bin=libsa_std.a",
    });
    defer std.testing.allocator.free(build_lib_result.stdout);
    defer std.testing.allocator.free(build_lib_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_lib_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const build_demo_result = try common.runCommand(std.testing.allocator, &.{
        "zig",
        "cc",
        "-I",
        include_dir,
        "main.c",
        "libsa_std.a",
        "-lc",
        "-o",
        "sa_std_deno_responses_chat_fallback_request",
    });
    defer std.testing.allocator.free(build_demo_result.stdout);
    defer std.testing.allocator.free(build_demo_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (build_demo_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });

    const run_result = try common.runCommand(std.testing.allocator, &.{"./sa_std_deno_responses_chat_fallback_request"});
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (run_result.term) {
        .exited => |code| code,
        else => return error.TestUnexpectedResult,
    });
    try std.testing.expectEqualStrings("sa_std deno responses chat fallback request ok\n", run_result.stdout);
}

test "sa_std rust core helpers are concrete and verifiable" {
    const option_layout = try common.readFileAlloc(std.testing.allocator, "sa_std/core/option.sal");
    defer std.testing.allocator.free(option_layout);
    try std.testing.expectEqualStrings(
        \\#def Option_SIZE = 16
        \\#def Option_tag = +0
        \\#def Option_value = +8
        \\#def Option_NONE = 0
        \\#def Option_SOME = 1
        \\
        \\
        \\#def OptionPairU64_SIZE = 24
        \\#def OptionPairU64_tag = +0
        \\#def OptionPairU64_value1 = +8
        \\#def OptionPairU64_value2 = +16
        \\
    ,
        option_layout,
    );

    const result_layout = try common.readFileAlloc(std.testing.allocator, "sa_std/core/result.sal");
    defer std.testing.allocator.free(result_layout);
    try std.testing.expectEqualStrings(
        "#def Result_SIZE = 24\n#def Result_tag = +0\n#def Result_ok = +8\n#def Result_err = +16\n#def Result_OK = 0\n#def Result_ERR = 1\n",
        result_layout,
    );

    const iter_layout = try common.readFileAlloc(std.testing.allocator, "sa_std/core/iter.sal");
    defer std.testing.allocator.free(iter_layout);
    try std.testing.expectEqualStrings(
        "#def Iter_SIZE = 24\n#def Iter_ptr = +0\n#def Iter_len = +8\n#def Iter_index = +16\n",
        iter_layout,
    );

    const option_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/option.sars");
    defer std.testing.allocator.free(option_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_NEW_NONE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_NEW_SOME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_IS_SOME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_IS_NONE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_UNWRAP_OR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_UNWRAP_OR_RETURN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] TRY_OPTION"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] TRY_OPTION_RETURN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_UNWRAP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_MAP_OR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_MAP_OR_ELSE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_SET_NONE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_SET_SOME"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_BRANCH"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] MATCHES_OPTION"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] MATCH_OPTION"));
    try std.testing.expect(std.mem.containsAtLeast(u8, option_src, 1, "[MACRO] OPTION_MATCH_SOME_NONE"));

    const result_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/result.sars");
    defer std.testing.allocator.free(result_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_NEW_OK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_NEW_ERR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_IS_OK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_IS_ERR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_GET_OK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_GET_ERR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_UNWRAP_OR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_RETURN_ERR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] TRY_RESULT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] TRY_RESULT_RETURN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_MAP_OK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_UNWRAP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_UNWRAP_ERR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_MAP_OR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_MAP_OR_ELSE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_SET_OK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_SET_ERR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_BRANCH"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] MATCH_RESULT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] MATCHES_RESULT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result_src, 1, "[MACRO] RESULT_MATCH_OK_ERR"));

    const stringify_src = try common.readFileAlloc(std.testing.allocator, "src/flattener.zig");
    defer std.testing.allocator.free(stringify_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, stringify_src, 1, "STRINGIFY!"));

    const sa_core_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/sa_core.sars");
    defer std.testing.allocator.free(sa_core_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, sa_core_src, 1, "[MACRO] CFG"));

    const panic_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/panic.sars");
    defer std.testing.allocator.free(panic_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, panic_src, 1, "[MACRO] PANIC "));
    try std.testing.expect(std.mem.containsAtLeast(u8, panic_src, 1, "[MACRO] PANIC_MSG"));
    try std.testing.expect(std.mem.containsAtLeast(u8, panic_src, 1, "[MACRO] TODO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, panic_src, 1, "[MACRO] UNIMPLEMENTED"));
    try std.testing.expect(std.mem.containsAtLeast(u8, panic_src, 1, "[MACRO] UNREACHABLE"));

    const iter_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/iter.sars");
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

    const loop_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/loop.sars");
    defer std.testing.allocator.free(loop_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, loop_src, 1, "[MACRO] WHILE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, loop_src, 1, "[MACRO] WHILE_COND"));
    try std.testing.expect(std.mem.containsAtLeast(u8, loop_src, 1, "[MACRO] FOR_RANGE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, loop_src, 1, "[MACRO] INDEX_LOOP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, loop_src, 1, "[MACRO] ARRAY_SCAN_MIN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, loop_src, 1, "[MACRO] ARRAY_SCAN_MAX"));

    const control_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/control.sars");
    defer std.testing.allocator.free(control_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, control_src, 1, "[MACRO] MATCH_BOOL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, control_src, 1, "[MACRO] ELIF"));
    try std.testing.expect(std.mem.containsAtLeast(u8, control_src, 1, "[MACRO] WHILE_LET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, control_src, 1, "[MACRO] BREAK_IF"));
    try std.testing.expect(std.mem.containsAtLeast(u8, control_src, 1, "[MACRO] CONTINUE_IF"));

    const bit_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/bit.sars");
    defer std.testing.allocator.free(bit_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, bit_src, 1, "[MACRO] BIT_MASK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, bit_src, 1, "[MACRO] BIT_SET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, bit_src, 1, "[MACRO] BIT_GET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, bit_src, 1, "[MACRO] BIT_CLEAR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, bit_src, 1, "[MACRO] BIT_TEST"));
    try std.testing.expect(std.mem.containsAtLeast(u8, bit_src, 1, "[MACRO] BIT_INDEX_BYTE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, bit_src, 1, "[MACRO] BIT_INDEX_BIT"));

    const hash_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/hash.sars");
    defer std.testing.allocator.free(hash_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, hash_src, 1, "[MACRO] HASH_PTR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hash_src, 1, "[MACRO] HASH_MIX"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hash_src, 1, "[MACRO] HASH_MOD"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hash_src, 1, "[MACRO] PROBE_START"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hash_src, 1, "[MACRO] PROBE_NEXT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hash_src, 1, "[MACRO] MAP_LOOKUP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hash_src, 1, "[MACRO] MAP_INSERT_OR_UPDATE"));

    const cleanup_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/cleanup.sars");
    defer std.testing.allocator.free(cleanup_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, cleanup_src, 1, "[MACRO] DEFER"));
    try std.testing.expect(std.mem.containsAtLeast(u8, cleanup_src, 1, "[MACRO] CLEANUP_ON_ERROR"));
    try std.testing.expect(std.mem.containsAtLeast(u8, cleanup_src, 1, "[MACRO] WITH_TEMP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, cleanup_src, 1, "[MACRO] RETURN_CLEAN"));
    try std.testing.expect(std.mem.containsAtLeast(u8, cleanup_src, 1, "[MACRO] FREE_AND_RETURN"));

    const rust_core_src = try common.readFileAlloc(std.testing.allocator, "sa_std/rust_core.sars");
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
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/loop.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/control.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/bit.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/hash.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/cleanup.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"sync/rwlock.sa\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, rust_core_src, 1, "@import \"core/ascii.sa\""));

    const ascii_layout = try common.readFileAlloc(std.testing.allocator, "sa_std/core/ascii.sal");
    defer std.testing.allocator.free(ascii_layout);
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_layout, 1, "#def ASCII_CASE_MASK = 32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ascii_layout, 1, "#def ASCII_MAX = 127"));

    const ascii_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/ascii.sars");
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

    const cell_layout = try common.readFileAlloc(std.testing.allocator, "sa_std/core/cell.sal");
    defer std.testing.allocator.free(cell_layout);
    try std.testing.expectEqualStrings(
        "#def Cell_SIZE = 4\n#def Cell_value = +0\n\n#def CellU64_SIZE = 8\n#def CellU64_value = +0\n",
        cell_layout,
    );

    const refcell_layout = try common.readFileAlloc(std.testing.allocator, "sa_std/core/refcell.sal");
    defer std.testing.allocator.free(refcell_layout);
    try std.testing.expectEqualStrings(
        \\#def RefCell_SIZE = 8
        \\#def RefCell_value = +0
        \\#def RefCell_borrows = +4
        \\
        \\#def RefCellU64_SIZE = 16
        \\#def RefCellU64_value = +0
        \\#def RefCellU64_borrows = +8
        \\
        \\#def BorrowError_SIZE = 0
        \\#def BorrowError_ALIGN = 1
        \\
        \\#def BorrowMutError_SIZE = 0
        \\#def BorrowMutError_ALIGN = 1
        \\
    ,
        refcell_layout,
    );

    const rc_layout = try common.readFileAlloc(std.testing.allocator, "sa_std/core/rc.sal");
    defer std.testing.allocator.free(rc_layout);
    try std.testing.expectEqualStrings("#def RcBox_SIZE = 24\n#def RcBox_strong = +0\n#def RcBox_weak = +8\n#def RcBox_data = +16\n", rc_layout);

    const weak_layout = try common.readFileAlloc(std.testing.allocator, "sa_std/core/weak.sal");
    defer std.testing.allocator.free(weak_layout);
    try std.testing.expectEqualStrings("#def WeakBox_SIZE = 24\n#def WeakBox_strong = +0\n#def WeakBox_weak = +8\n#def WeakBox_data = +16\n", weak_layout);

    const cell_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/cell.sars");
    defer std.testing.allocator.free(cell_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, cell_src, 1, "[MACRO] CELL_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, cell_src, 1, "[MACRO] CELL_SET"));
    try std.testing.expect(std.mem.containsAtLeast(u8, cell_src, 1, "[MACRO] CELL_REPLACE"));

    const refcell_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/refcell.sars");
    defer std.testing.allocator.free(refcell_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, refcell_src, 1, "[MACRO] REFCELL_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, refcell_src, 1, "[MACRO] REFCELL_BORROW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, refcell_src, 1, "[MACRO] REFCELL_BORROW_MUT"));
    try std.testing.expect(std.mem.containsAtLeast(u8, refcell_src, 1, "[MACRO] REFCELL_RELEASE"));

    const derive_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/derive.sars");
    defer std.testing.allocator.free(derive_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, derive_src, 1, "[MACRO] STRUCT_COPY"));
    try std.testing.expect(std.mem.containsAtLeast(u8, derive_src, 1, "[MACRO] STRUCT_EQ_FIELD"));
    try std.testing.expect(std.mem.containsAtLeast(u8, derive_src, 1, "[MACRO] STRUCT_EQ4"));

    const rc_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/rc.sars");
    defer std.testing.allocator.free(rc_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, rc_src, 1, "[MACRO] RC_NEW"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rc_src, 1, "[MACRO] RC_CLONE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rc_src, 1, "[MACRO] RC_DROP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rc_src, 1, "[MACRO] RC_DOWNGRADE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rc_src, 1, "[MACRO] WEAK_CLONE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rc_src, 1, "[MACRO] WEAK_DROP"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rc_src, 1, "[MACRO] WEAK_UPGRADE"));

    const weak_src = try common.readFileAlloc(std.testing.allocator, "sa_std/core/weak.sars");
    defer std.testing.allocator.free(weak_src);
    try std.testing.expect(std.mem.containsAtLeast(u8, weak_src, 1, "@import \"weak.sal\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, weak_src, 1, "@import \"rc.sa\""));

    var option_flat = try flattenFixture(std.testing.allocator, "sa_std/core/option.sars", option_src);
    defer option_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), option_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), option_flat.function_sigs.len);

    var result_flat = try flattenFixture(std.testing.allocator, "sa_std/core/result.sars", result_src);
    defer result_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), result_flat.function_sigs.len);

    var panic_flat = try flattenFixture(std.testing.allocator, "sa_std/core/panic.sars", panic_src);
    defer panic_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), panic_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), panic_flat.function_sigs.len);

    var iter_flat = try flattenFixture(std.testing.allocator, "sa_std/core/iter.sars", iter_src);
    defer iter_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), iter_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), iter_flat.function_sigs.len);

    var ascii_flat = try flattenFixture(std.testing.allocator, "sa_std/core/ascii.sars", ascii_src);
    defer ascii_flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), ascii_flat.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), ascii_flat.function_sigs.len);

    var rust_core_flat = try flattenFixture(std.testing.allocator, "sa_std/rust_core.sars", rust_core_src);
    defer rust_core_flat.deinit(std.testing.allocator);
    try std.testing.expect(rust_core_flat.instructions.len > 0);
    try std.testing.expect(rust_core_flat.function_sigs.len > 0);
    try std.testing.expect(rust_core_flat.instructions.len >= 1);
}

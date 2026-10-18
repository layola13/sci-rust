const std = @import("std");
const flattener = @import("src/flattener.zig");
const referee = @import("src/verifier.zig");
const emit_llvm_llvmc = @import("src/emit_llvm_llvmc.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dir = try sio.cwd().openDir("demos/rosetta", .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    
    var total_flatten_ns: u64 = 0;
    var total_verify_ns: u64 = 0;
    var total_emit_ns: u64 = 0;
    var total_zigcc_ns: u64 = 0;
    var count: u64 = 0;

    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            const file_path = try std.fmt.allocPrint(alloc, "demos/rosetta/{s}/main.sars", .{entry.name});
            const source = sio.cwd().readFileAlloc(alloc, file_path, 1024 * 1024) catch continue;
            
            const t0 = std.time.nanoTimestamp();
            const flat = flattener.flattenFile(alloc, file_path, source) catch continue;
            const t1 = std.time.nanoTimestamp();
            total_flatten_ns += @intCast(t1 - t0);

            const verified = referee.verify(alloc, flat.instructions, flat.const_decls) catch continue;
            const t2 = std.time.nanoTimestamp();
            total_verify_ns += @intCast(t2 - t1);

            switch (verified) {
                .ok => |ok| {
                    const tmp_bc = "/tmp/bench_tmp.sa.bc";
                    try emit_llvm_llvmc.emitLlvmcToFile(alloc, ok, &flat.def_dict, flat.loc_table, file_path, 64, .{}, tmp_bc);
                    const t4 = std.time.nanoTimestamp();
                    total_emit_ns += @intCast(t4 - t2);

                    const result = sio.Child.run(.{
                        .allocator = alloc,
                        .argv = &[_][]const u8{ "zig", "cc", "-c", tmp_bc, "-o", "/dev/null" },
                    }) catch continue;
                    const t5 = std.time.nanoTimestamp();
                    total_zigcc_ns += @intCast(t5 - t4);
                    
                    alloc.free(result.stdout);
                    alloc.free(result.stderr);
                    count += 1;
                },
                .trap => {},
            }
        }
    }

    std.debug.print("Successfully compiled {} demos.\n", .{count});
    std.debug.print("===================================\n", .{});
    std.debug.print("Flattener (Parse & Macro) : {d} ms\n", .{total_flatten_ns / 1_000_000});
    std.debug.print("Referee   (Verify & Solve): {d} ms\n", .{total_verify_ns / 1_000_000});
    std.debug.print("Emitter   (LLVM-C Bitcode): {d} ms\n", .{total_emit_ns / 1_000_000});
    std.debug.print("Zig CC    (LLVM Backend)  : {d} ms\n", .{total_zigcc_ns / 1_000_000});
    std.debug.print("===================================\n", .{});
    
    const internal_total = (total_flatten_ns + total_verify_ns + total_emit_ns) / 1_000_000;
    std.debug.print("SA-ASM Engine Total       : {d} ms\n", .{internal_total});
}

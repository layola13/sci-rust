const std = @import("std");
const flattener = @import("src/flattener.zig");
const call = @import("src/referee/call.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const source_path = "/tmp/json_writer_debug.sars";
    const source = try sio.cwd().readFileAlloc(allocator, source_path, 4 * 1024 * 1024);
    defer allocator.free(source);
    const project_root = try sio.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(project_root);
    const std_root = try sio.cwd().realpathAlloc(allocator, "sa_std");
    defer allocator.free(std_root);

    var error_ctx: flattener.ErrorContext = .{};
    var flat = try flattener.flattenFileWithContextAndPackages(
        allocator,
        source_path,
        source,
        &error_ctx,
        .{
            .dependencies = &.{},
            .options = .{
                .project_root = project_root,
                .std_root = std_root,
                .offline = true,
            },
        },
    );
    defer flat.deinit(allocator);

    for (flat.function_sigs) |fsig| {
        if (!std.mem.eql(u8, fsig.name, "sa_json_buffer_free")) continue;
        std.debug.print(
            "sig name={s} params={} return={s} fallible={}\n",
            .{ fsig.name, fsig.params.len, @tagName(fsig.return_ty), fsig.return_fallible },
        );
        for (fsig.params, 0..) |param, i| {
            std.debug.print(
                "  param[{}] name={s} ty={s} cap={s}\n",
                .{ i, param.name, @tagName(param.ty), @tagName(param.cap) },
            );
        }
    }
    for (flat.instructions, 0..) |item, i| {
        if (std.mem.indexOf(u8, item.raw_text, "sa_json_buffer_free") == null) continue;
        std.debug.print("inst[{}] {s}\n", .{ i, item.raw_text });
        if (item.kind == .call) {
            var parsed = try call.parseInstructionCall(allocator, item, &flat.symbols);
            defer parsed.deinit(allocator);
            for (parsed.args, 0..) |arg, arg_idx| {
                std.debug.print(
                    "  arg[{}] text={s} prefix={s}\n",
                    .{ arg_idx, arg.text, @tagName(arg.prefix) },
                );
            }
        }
    }
}

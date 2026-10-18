const std = @import("std");
const saasm = @import("saasm");
const sio = @import("sio");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const suite_path = "tests/unit_framework/feature_suite.sars";
    var file = try sio.cwd().openFile(suite_path, .{});
    defer file.close();
    const source = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(source);

    const std_root = try sio.cwd().realpathAlloc(allocator, "sa_std");
    defer allocator.free(std_root);
    const project_root = try sio.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(project_root);

    var error_ctx = saasm.flattener.ErrorContext{};
    const resolve_ctx = saasm.flattener.ResolveContext{
        .dependencies = &.{},
        .options = .{
            .project_root = project_root,
            .std_root = std_root,
            .offline = true,
        },
    };

    var flat = try saasm.flattener.flattenFileWithContextAndPackages(allocator, suite_path, source, &error_ctx, resolve_ctx);
    defer flat.deinit(allocator);

    std.debug.print("Total instructions: {d}\n", .{flat.instructions.len});
    for (3780..3840) |idx| {
        if (idx < flat.instructions.len) {
            const inst = flat.instructions[idx];
            std.debug.print("{d}: {s} (raw: {s})\n", .{idx, @tagName(inst.kind), inst.raw_text});
        }
    }
}

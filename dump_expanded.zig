const std = @import("std");
const flattener = @import("src/flattener.zig");

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

    var error_ctx = flattener.ErrorContext{};
    const resolve_ctx = flattener.ResolveContext{
        .dependencies = &.{},
        .options = .{
            .project_root = project_root,
            .std_root = std_root,
            .offline = true,
        },
    };

    var flat = flattener.flattenFileWithContextAndPackages(allocator, suite_path, source, &error_ctx, resolve_ctx) catch |err| {
        std.debug.print("Flatten failed: {}\n", .{err});
        if (error_ctx.source_line) |line| {
            std.debug.print("Error at source line: {d}\n", .{line});
        }
        return;
    };
    defer flat.deinit(allocator);

    std.debug.print("Flatten succeeded! Total instructions: {d}\n", .{flat.instructions.len});
    var it = flat.def_dict.entries.iterator();
    while (it.next()) |entry| {
        std.debug.print("Key: '{s}' -> '{s}'\n", .{entry.key_ptr.*, entry.value_ptr.*});
    }
}

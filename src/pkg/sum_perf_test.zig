const std = @import("std");

const audit = @import("audit.zig");
const manifest = @import("manifest.zig");
const sum = @import("sum.zig");

test "sum flattens one hundred transitive dependencies within budget" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_count: usize = 100;
    var roots = try std.testing.allocator.alloc([]u8, dep_count);
    defer {
        for (roots) |root| std.testing.allocator.free(root);
        std.testing.allocator.free(roots);
    }
    var hashes = try std.testing.allocator.alloc([32]u8, dep_count);
    defer std.testing.allocator.free(hashes);

    try tmp.dir.createDirPath(std.testing.io, "pkgs");
    for (0..dep_count) |idx| {
        const rel = try std.fmt.allocPrint(std.testing.allocator, "pkgs/pkg{d:0>3}", .{idx});
        defer std.testing.allocator.free(rel);
        try tmp.dir.createDirPath(std.testing.io, rel);
        const source_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/index.sars", .{rel});
        defer std.testing.allocator.free(source_path);
        const source = try std.fmt.allocPrint(std.testing.allocator, "@pkg{d:0>3}() -> i32:\nreturn {d}\n", .{ idx, idx });
        defer std.testing.allocator.free(source);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = source_path, .data = source });
        roots[idx] = try tmp.dir.realPathFileAlloc(std.testing.io, rel, std.testing.allocator);
    }

    var reverse_idx = dep_count;
    while (reverse_idx > 0) {
        reverse_idx -= 1;
        if (reverse_idx + 1 < dep_count) {
            const child_hex = std.fmt.bytesToHex(hashes[reverse_idx + 1], .lower);
            const nested_manifest = try std.fmt.allocPrint(
                std.testing.allocator,
                "require {s} @HEAD sha256:{s}\n",
                .{ roots[reverse_idx + 1], child_hex[0..] },
            );
            defer std.testing.allocator.free(nested_manifest);
            const manifest_path = try std.fmt.allocPrint(std.testing.allocator, "pkgs/pkg{d:0>3}/sa.mod", .{reverse_idx});
            defer std.testing.allocator.free(manifest_path);
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = nested_manifest });
        }

        hashes[reverse_idx] = try audit.hashPackageSource(std.testing.allocator, roots[reverse_idx]);
    }

    const project_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(project_root);
    const root_hex = std.fmt.bytesToHex(hashes[0], .lower);
    const manifest_source = try std.fmt.allocPrint(
        std.testing.allocator,
        "require {s} @HEAD sha256:{s}\n",
        .{ roots[0], root_hex[0..] },
    );
    defer std.testing.allocator.free(manifest_source);
    var project_manifest = try manifest.parseManifestWithFile(std.testing.allocator, manifest_source, "sa.mod");
    defer project_manifest.deinit(std.testing.allocator);

    var timer = try std.time.Timer.start();
    var flattened = try sum.buildFromManifest(std.testing.allocator, project_root, project_manifest);
    const elapsed_ns = timer.read();
    defer flattened.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, dep_count), flattened.entries.len);
    try std.testing.expect(elapsed_ns <= 200 * std.time.ns_per_ms);
}

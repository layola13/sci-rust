const std = @import("std");

const audit = @import("audit.zig");
const manifest = @import("manifest.zig");

test "audit scans synthesized package within fifty milliseconds" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "pkg/src");
    const file_count: usize = 64;
    for (0..file_count) |idx| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "pkg/src/mod{d:0>2}.sars", .{idx});
        defer std.testing.allocator.free(path);
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            \\// deterministic audit fixture {d}
            \\@const MSG{d} = utf8:"@sys_net_tx inside string is ignored"
            \\// call @sys_net_rx(*IGNORED, 4)
            \\call @sys_io_write(*BUF, 4)
            \\
        ,
            .{ idx, idx },
        );
        defer std.testing.allocator.free(source);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = source });
    }

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "pkg", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const grants = [_]manifest.Capability{.io_write};

    var timer = try std.time.Timer.start();
    var report = try audit.auditPackage(std.testing.allocator, "github.com/example/perf", "HEAD", root, grants[0..]);
    const elapsed_ns = timer.read();
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, file_count), report.primitives.len);
    try std.testing.expectEqual(@as(u8, 50), report.trust_score);
    try std.testing.expectEqual(audit.RiskLevel.medium, report.risk_level);
    try std.testing.expect(elapsed_ns <= 50 * std.time.ns_per_ms);
}

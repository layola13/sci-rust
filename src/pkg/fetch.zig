const std = @import("std");
const builtin = @import("builtin");
const sio = @import("sio");

const audit = @import("audit.zig");
const manifest = @import("manifest.zig");
const mirror = @import("mirror.zig");

pub const FetchError = anyerror;

pub const FetchOptions = struct {
    global: bool = false,
    offline: bool = false,
    mirror_rules: []const manifest.MirrorRule = &.{},
    expected_source_sha256: ?[32]u8 = null,
};

pub const FetchResult = struct {
    root: []u8,
    source_sha256: [32]u8 = std.mem.zeroes([32]u8),

    pub fn deinit(self: *FetchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        self.* = undefined;
    }
};

const CopyTreeOptions = struct {
    read_only: bool = false,
};

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

fn validateIdentity(identity: []const u8) FetchError!void {
    const trimmed = trim(identity);
    if (trimmed.len == 0) return error.InvalidUrl;
    if (trimmed[0] == '-') return error.InvalidUrl;
    if (std.mem.indexOfScalar(u8, trimmed, '\x00') != null) return error.InvalidUrl;
    if (std.mem.indexOfScalar(u8, trimmed, '\n') != null or std.mem.indexOfScalar(u8, trimmed, '\r') != null) return error.InvalidUrl;
    if (std.fs.path.isAbsolute(trimmed)) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, trimmed, '\\') != null) return error.InvalidPath;
    var segments = std.mem.splitScalar(u8, trimmed, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidPath;
    }
    if (std.mem.containsAtLeast(u8, trimmed, 1, "../") or std.mem.startsWith(u8, trimmed, "../") or std.mem.eql(u8, trimmed, "..")) {
        return error.InvalidPath;
    }
}

fn validateRef(ref: []const u8) FetchError!void {
    const trimmed = trim(ref);
    if (trimmed.len == 0) return error.InvalidUrl;
    if (trimmed[0] == '-') return error.InvalidUrl;
    if (std.mem.indexOfAny(u8, trimmed, " \t\r\n\x00") != null) return error.InvalidUrl;
}

fn inheritEnvIfPresent(allocator: std.mem.Allocator, env_map: *sio.EnvMap, key: []const u8) !void {
    const value = sio.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return,
        else => return err,
    };
    defer allocator.free(value);
    try env_map.put(key, value);
}

fn pathJoin(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return try std.fs.path.join(allocator, parts);
}

fn homeDir(allocator: std.mem.Allocator) ![]u8 {
    return sio.getEnvVarOwned(allocator, "HOME") catch {
        return sio.getEnvVarOwned(allocator, "USERPROFILE") catch return error.InvalidPath;
    };
}

fn vendorRoot(allocator: std.mem.Allocator, identity: []const u8) ![]u8 {
    return try pathJoin(allocator, &.{ "sa_vendor", identity });
}

fn globalRoot(allocator: std.mem.Allocator, home: []const u8, identity: []const u8, ref: []const u8) ![]u8 {
    const leaf = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ identity, ref });
    errdefer allocator.free(leaf);
    const joined = try pathJoin(allocator, &.{ home, ".sars", "pkg", leaf });
    allocator.free(leaf);
    return joined;
}

fn looksLikeRemote(identity: []const u8) bool {
    return std.mem.containsAtLeast(u8, identity, 1, "://") or
        (std.mem.indexOfScalar(u8, identity, '@') != null and std.mem.indexOfScalar(u8, identity, ':') != null and
            (std.mem.indexOfScalar(u8, identity, '/') orelse identity.len) > (std.mem.indexOfScalar(u8, identity, ':') orelse identity.len));
}

fn remoteUrlFromIdentity(allocator: std.mem.Allocator, identity: []const u8) ![]u8 {
    if (std.mem.containsAtLeast(u8, identity, 1, "://") or looksLikeRemote(identity)) {
        return allocator.dupe(u8, identity);
    }
    return try std.fmt.allocPrint(allocator, "https://{s}.git", .{identity});
}

fn deleteExistingDir(path: []const u8) !void {
    try sio.cwd().deleteTree(path);
}

fn dirExists(path: []const u8) !bool {
    var dir = sio.cwd().openDir(path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    dir.close();
    return true;
}

fn pathHasPrecompiledArtifact(name: []const u8) bool {
    const lower = std.ascii.lowerString;
    var buf: [256]u8 = undefined;
    const slice = if (name.len <= buf.len) lower(&buf, name) else name;
    return std.mem.endsWith(u8, slice, ".so") or
        std.mem.endsWith(u8, slice, ".dll") or
        std.mem.endsWith(u8, slice, ".dylib") or
        std.mem.endsWith(u8, slice, ".a") or
        std.mem.endsWith(u8, slice, ".lib") or
        std.mem.endsWith(u8, slice, ".whl") or
        std.mem.endsWith(u8, slice, ".node");
}

fn isIgnoredTreeDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".codex") or
        std.mem.eql(u8, name, ".mimir") or
        std.mem.eql(u8, name, ".kiro") or
        std.mem.eql(u8, name, "artifacts") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "zig-cache");
}

fn rejectPrecompiledArtifacts(root: sio.Dir, allocator: std.mem.Allocator) !void {
    var walker = try root.inner.walk(allocator);
    defer walker.deinit();
    while (try walker.next(sio.io())) |entry| {
        if (entry.kind != .file) continue;
        if (pathHasPrecompiledArtifact(entry.basename)) return error.PrecompiledArtifactRejected;
    }
}

fn inspectFetchedSource(allocator: std.mem.Allocator, target_root: []const u8) ![32]u8 {
    var target_dir = try sio.cwd().openDir(target_root, .{ .iterate = true });
    defer target_dir.close();
    try rejectPrecompiledArtifacts(target_dir, allocator);
    return try audit.hashPackageSource(allocator, target_root);
}

fn validateExpectedSourceHash(expected: ?[32]u8, actual: [32]u8) !void {
    const wanted = expected orelse return;
    if (!std.mem.eql(u8, wanted[0..], actual[0..])) return error.UpstreamShaMismatch;
}

fn chmodFileReadOnly(path: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    var file = try sio.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();
    try file.chmod(0o444);
}

fn chmodDirReadOnly(path: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    var dir = try sio.cwd().openDir(path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close();
    try dir.chmod(0o555);
}

fn copyTree(src_root: []const u8, dst_root: []const u8, allocator: std.mem.Allocator, options: CopyTreeOptions) !void {
    var src_dir = try sio.cwd().openDir(src_root, .{ .iterate = true });
    defer src_dir.close();

    var walker = try src_dir.inner.walk(allocator);
    defer walker.deinit();

    var copied_dirs = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (copied_dirs.items) |path| allocator.free(path);
        copied_dirs.deinit();
    }

    while (try walker.next(sio.io())) |entry| {
        if (entry.kind == .directory and isIgnoredTreeDir(entry.basename)) continue;
        const dst_path = try std.fs.path.join(allocator, &.{ dst_root, entry.path });
        defer allocator.free(dst_path);

        switch (entry.kind) {
            .directory => {
                try sio.cwd().makePath(dst_path);
                if (options.read_only) try copied_dirs.append(try allocator.dupe(u8, dst_path));
            },
            .file => {
                if (pathHasPrecompiledArtifact(entry.basename)) return error.PrecompiledArtifactRejected;
                if (std.fs.path.dirname(dst_path)) |parent| {
                    try sio.cwd().makePath(parent);
                }
                const entry_dir: sio.Dir = .{ .inner = entry.dir };
                try entry_dir.copyFile(entry.basename, sio.cwd(), dst_path, .{});
                if (options.read_only) try chmodFileReadOnly(dst_path);
            },
            .sym_link => continue,
            else => {},
        }
    }

    if (options.read_only) {
        var idx = copied_dirs.items.len;
        while (idx > 0) {
            idx -= 1;
            try chmodDirReadOnly(copied_dirs.items[idx]);
        }
        try chmodDirReadOnly(dst_root);
    }
}

fn setReadOnlyRecursive(root_path: []const u8, allocator: std.mem.Allocator) !void {
    var root_dir = try sio.cwd().openDir(root_path, .{ .iterate = true, .follow_symlinks = false });
    defer root_dir.close();

    var walker = try root_dir.inner.walk(allocator);
    defer walker.deinit();

    while (try walker.next(sio.io())) |entry| {
        switch (entry.kind) {
            .file => {
                if (builtin.os.tag == .windows) continue;
                const entry_dir: sio.Dir = .{ .inner = entry.dir };
                var file = try entry_dir.openFile(entry.basename, .{ .mode = .read_only });
                defer file.close();
                try file.chmod(0o444);
            },
            .directory => {
                if (builtin.os.tag == .windows) continue;
                const entry_dir: sio.Dir = .{ .inner = entry.dir };
                var dir = try entry_dir.openDir(entry.basename, .{ .iterate = true, .follow_symlinks = false });
                defer dir.close();
                try dir.chmod(0o555);
            },
            .sym_link => continue,
            else => {},
        }
    }

    if (builtin.os.tag != .windows) try root_dir.chmod(0o555);
}

fn runGitClone(allocator: std.mem.Allocator, identity: []const u8, ref: []const u8, target_root: []const u8) !void {
    const remote_url = try remoteUrlFromIdentity(allocator, identity);
    defer allocator.free(remote_url);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();

    try argv.appendSlice(&.{ "git", "clone", "--depth", "1" });
    if (!std.mem.eql(u8, ref, "HEAD")) {
        try argv.appendSlice(&.{ "--branch", ref, "--single-branch" });
    }
    try argv.append("--");
    try argv.append(remote_url);
    try argv.append(target_root);

    var env_map = sio.EnvMap.init(allocator);
    defer env_map.deinit();
    try inheritEnvIfPresent(allocator, &env_map, "PATH");
    try inheritEnvIfPresent(allocator, &env_map, "HOME");
    try inheritEnvIfPresent(allocator, &env_map, "USERPROFILE");
    try inheritEnvIfPresent(allocator, &env_map, "SSL_CERT_FILE");
    try inheritEnvIfPresent(allocator, &env_map, "SSL_CERT_DIR");
    try env_map.put("GIT_TERMINAL_PROMPT", "0");
    if (@import("builtin").os.tag != .windows) {
        try env_map.put("GIT_ASKPASS", "/bin/false");
    }
    try env_map.put("GCM_INTERACTIVE", "Never");

    const result = try sio.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .env_map = &env_map,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.SourceNotFound;
}

fn fetchTargetRoot(allocator: std.mem.Allocator, identity: []const u8, ref: []const u8, global: bool) ![]u8 {
    if (global) {
        const home = try homeDir(allocator);
        defer allocator.free(home);
        const dir = try std.fmt.allocPrint(allocator, "{s}/.sa/pkg/{s}@{s}", .{ home, identity, ref });
        errdefer allocator.free(dir);
        return dir;
    }
    return vendorRoot(allocator, identity);
}

pub fn fetchPackage(allocator: std.mem.Allocator, identity: []const u8, ref: []const u8, options: FetchOptions) !FetchResult {
    try validateIdentity(identity);
    try validateRef(ref);

    const target_root = try fetchTargetRoot(allocator, identity, ref, options.global);
    errdefer allocator.free(target_root);

    if (std.mem.eql(u8, identity, target_root)) return error.InvalidPath;

    const mirrored_identity = try mirror.rewriteIdentity(allocator, identity, options.mirror_rules);
    defer allocator.free(mirrored_identity);
    try validateIdentity(mirrored_identity);
    var copied_read_only = false;

    if (options.offline) {
        if (try dirExists(target_root)) {
            const source_sha256 = try inspectFetchedSource(allocator, target_root);
            try validateExpectedSourceHash(options.expected_source_sha256, source_sha256);
            if (options.global) {
                try setReadOnlyRecursive(target_root, allocator);
            }
            return .{ .root = target_root, .source_sha256 = source_sha256 };
        }

        if (try dirExists(identity)) {
            if (std.mem.eql(u8, identity, target_root)) return error.InvalidPath;
            try deleteExistingDir(target_root);
            try sio.cwd().makePath(target_root);
            try copyTree(identity, target_root, allocator, .{ .read_only = options.global });
            copied_read_only = options.global;
        } else if (!std.mem.eql(u8, mirrored_identity, identity) and try dirExists(mirrored_identity)) {
            if (std.mem.eql(u8, mirrored_identity, target_root)) return error.InvalidPath;
            try deleteExistingDir(target_root);
            try sio.cwd().makePath(target_root);
            try copyTree(mirrored_identity, target_root, allocator, .{ .read_only = options.global });
            copied_read_only = options.global;
        } else {
            return error.SourceNotFound;
        }
    } else if (try dirExists(identity)) {
        try deleteExistingDir(target_root);
        try sio.cwd().makePath(target_root);
        try copyTree(identity, target_root, allocator, .{ .read_only = options.global });
        copied_read_only = options.global;
    } else if (!std.mem.eql(u8, mirrored_identity, identity) and try dirExists(mirrored_identity)) {
        try deleteExistingDir(target_root);
        try sio.cwd().makePath(target_root);
        try copyTree(mirrored_identity, target_root, allocator, .{ .read_only = options.global });
        copied_read_only = options.global;
    } else {
        try deleteExistingDir(target_root);
        try sio.cwd().makePath(target_root);
        try runGitClone(allocator, mirrored_identity, ref, target_root);
    }

    const source_sha256 = try inspectFetchedSource(allocator, target_root);
    validateExpectedSourceHash(options.expected_source_sha256, source_sha256) catch |err| {
        if (!options.offline) {
            deleteExistingDir(target_root) catch |delete_err| {
                // Cleanup after a primary hash-mismatch error is best-effort.
                _ = @errorName(delete_err);
            };
        }
        return err;
    };

    if (options.global and !copied_read_only) {
        try setReadOnlyRecursive(target_root, allocator);
    }

    return .{ .root = target_root, .source_sha256 = source_sha256 };
}

pub fn downloadLocal(allocator: std.mem.Allocator, identity: []const u8) !FetchResult {
    return fetchPackage(allocator, identity, "HEAD", .{});
}

pub fn downloadGlobal(allocator: std.mem.Allocator, identity: []const u8, ref: []const u8) !FetchResult {
    return fetchPackage(allocator, identity, ref, .{ .global = true });
}

test "fetch copies a local source tree into sa_vendor" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "github.com/example/pkg/src");
    var src_file = try tmp.dir.createFile(std.testing.io, "github.com/example/pkg/src/main.sars", .{ .truncate = true });
    defer src_file.close(std.testing.io);
    try src_file.writeStreamingAll(std.testing.io, "@main() -> i32:\n    return 0\n");

    var old_cwd = try sio.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer old_cwd.setAsCwd() catch |err| {
        // Test teardown cannot recover from cwd restoration failure.
        _ = @errorName(err);
    };

    var result = try fetchPackage(std.testing.allocator, "github.com/example/pkg", "HEAD", .{});
    defer result.deinit(std.testing.allocator);

    var copied = try sio.cwd().openDir(result.root, .{ .iterate = true });
    defer copied.close();
    try copied.access("src/main.sars", .{ .read = true });
}

test "copyTree can set read-only permissions while skipping symlinks" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src/nested");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/nested/main.sars", .data = "@main() -> i32:\n    return 0\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside.sars", .data = "outside" });
    try tmp.dir.symLink(std.testing.io, "../outside.sars", "src/link.sars", .{});

    var old_cwd = try sio.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer old_cwd.setAsCwd() catch |err| {
        _ = @errorName(err);
    };
    defer {
        if (builtin.os.tag != .windows) {
            var nested = sio.cwd().openDir("dst/nested", .{ .iterate = true, .follow_symlinks = false }) catch null;
            if (nested) |*dir| {
                dir.chmod(0o755) catch {};
                dir.close();
            }
            var dst = sio.cwd().openDir("dst", .{ .iterate = true, .follow_symlinks = false }) catch null;
            if (dst) |*dir| {
                dir.chmod(0o755) catch {};
                dir.close();
            }
        }
    }

    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try sio.cwd().makePath("dst");
    try copyTree("src", "dst", std.testing.allocator, .{ .read_only = true });

    try sio.cwd().access("dst/nested/main.sars", .{ .read = true });
    try std.testing.expectError(error.FileNotFound, sio.cwd().access("dst/link.sars", .{}));

    var copied_file = try sio.cwd().openFile("dst/nested/main.sars", .{ .mode = .read_only });
    defer copied_file.close();
    const file_mode = @intFromEnum((try copied_file.stat()).permissions) & 0o777;
    try std.testing.expectEqual(@as(u32, 0o444), @as(u32, @intCast(file_mode)));

    var copied_dir = try sio.cwd().openDir("dst/nested", .{ .iterate = true, .follow_symlinks = false });
    defer copied_dir.close();
    const dir_mode = @intFromEnum((try copied_dir.stat()).permissions) & 0o777;
    try std.testing.expectEqual(@as(u32, 0o555), @as(u32, @intCast(dir_mode)));
}

test "setReadOnlyRecursive does not follow symlinked directories" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "root");
    try tmp.dir.createDirPath(std.testing.io, "outside");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside/keep.txt", .data = "keep" });
    try tmp.dir.symLink(std.testing.io, "../outside", "root/linkdir", .{});

    var old_cwd = try sio.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer old_cwd.setAsCwd() catch |err| {
        _ = @errorName(err);
    };
    defer {
        if (builtin.os.tag != .windows) {
            var root = sio.cwd().openDir("root", .{ .iterate = true, .follow_symlinks = false }) catch null;
            if (root) |*dir| {
                dir.chmod(0o755) catch {};
                dir.close();
            }
            var outside = sio.cwd().openDir("outside", .{ .iterate = true, .follow_symlinks = false }) catch null;
            if (outside) |*dir| {
                dir.chmod(0o755) catch {};
                dir.close();
            }
        }
    }

    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try setReadOnlyRecursive("root", std.testing.allocator);

    var outside = try sio.cwd().openDir("outside", .{ .iterate = true, .follow_symlinks = false });
    defer outside.close();
    const outside_mode = @intFromEnum((try outside.stat()).permissions) & 0o777;
    try std.testing.expect((outside_mode & 0o200) != 0);
}

test "PkgMgr-Fetch-Smoke computes hash and does not execute package files" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "github.com/example/smoke");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "github.com/example/smoke/index.sars", .data = "@main() -> i32:\nreturn 0\n" });
    var postinstall = try tmp.dir.createFile(std.testing.io, "github.com/example/smoke/postinstall.sh", .{ .truncate = true });
    {
        var wbuf: [8192]u8 = undefined;
        var wfb = postinstall.writer(std.testing.io, &wbuf);
        try wfb.interface.writeAll(
            \\#!/bin/sh
            \\echo executed > executed.marker
            \\
        );
        try wfb.interface.flush();
    }
    if (builtin.os.tag != .windows) try postinstall.setPermissions(std.testing.io, @enumFromInt(0o755));
    postinstall.close(std.testing.io);

    const source_root = try tmp.dir.realPathFileAlloc(std.testing.io, "github.com/example/smoke", std.testing.allocator);
    defer std.testing.allocator.free(source_root);
    const expected_hash = try audit.hashPackageSource(std.testing.allocator, source_root);

    var old_cwd = try sio.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer old_cwd.setAsCwd() catch |err| {
        // Test teardown cannot recover from cwd restoration failure.
        _ = @errorName(err);
    };

    var result = try fetchPackage(std.testing.allocator, "github.com/example/smoke", "HEAD", .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.eql(u8, expected_hash[0..], result.source_sha256[0..]));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "executed.marker", .{ .read = true }));

    const vendored_hash = try audit.hashPackageSource(std.testing.allocator, result.root);
    try std.testing.expect(std.mem.eql(u8, expected_hash[0..], vendored_hash[0..]));
    try sio.cwd().access("sa_vendor/github.com/example/smoke/postinstall.sh", .{ .read = true });
}

test "fetch rejects precompiled artifacts" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "github.com/example/bad");
    var bad_file = try tmp.dir.createFile(std.testing.io, "github.com/example/bad/libfoo.so", .{ .truncate = true });
    defer bad_file.close(std.testing.io);
    {
        var wbuf: [8192]u8 = undefined;
        var wfb = bad_file.writer(std.testing.io, &wbuf);
        try wfb.interface.writeAll("x");
        try wfb.interface.flush();
    }

    var old_cwd = try sio.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer old_cwd.setAsCwd() catch |err| {
        // Test teardown cannot recover from cwd restoration failure.
        _ = @errorName(err);
    };

    try std.testing.expectError(error.PrecompiledArtifactRejected, fetchPackage(std.testing.allocator, "github.com/example/bad", "HEAD", .{}));
}

test "fetch rejects path traversal identities" {
    try std.testing.expectError(error.InvalidPath, fetchPackage(std.testing.allocator, "../outside", "HEAD", .{ .offline = true }));
    try std.testing.expectError(error.InvalidPath, fetchPackage(std.testing.allocator, "github.com/example/..", "HEAD", .{ .offline = true }));
    try std.testing.expectError(error.InvalidPath, fetchPackage(std.testing.allocator, "/tmp/pkg", "HEAD", .{ .offline = true }));
    try std.testing.expectError(error.InvalidPath, fetchPackage(std.testing.allocator, "github.com\\example\\pkg", "HEAD", .{ .offline = true }));
}

test "fetch rejects option-shaped identities and refs before git clone" {
    try std.testing.expectError(error.InvalidUrl, fetchPackage(std.testing.allocator, "-upload-pack=evil", "HEAD", .{ .offline = true }));
    try std.testing.expectError(error.InvalidUrl, fetchPackage(std.testing.allocator, "github.com/example/pkg", "--upload-pack=evil", .{ .offline = true }));
}

test "dirExists returns false for plain files without swallowing directory errors" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "not_a_dir", .data = "x" });
    var old_cwd = try sio.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer old_cwd.setAsCwd() catch |err| {
        // Test teardown cannot recover from cwd restoration failure.
        _ = @errorName(err);
    };

    try std.testing.expect(!try dirExists("not_a_dir"));
}

test "fetch rejects and removes non-offline packages whose source hash mismatches" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "github.com/example/pkg");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "github.com/example/pkg/index.sars", .data = "@main() -> i32:\nreturn 0\n" });
    const source_root = try tmp.dir.realPathFileAlloc(std.testing.io, "github.com/example/pkg", std.testing.allocator);
    defer std.testing.allocator.free(source_root);
    var wrong_hash = try audit.hashPackageSource(std.testing.allocator, source_root);
    wrong_hash[0] ^= 0xff;

    var old_cwd = try sio.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer old_cwd.setAsCwd() catch |err| {
        // Test teardown cannot recover from cwd restoration failure.
        _ = @errorName(err);
    };

    try std.testing.expectError(error.UpstreamShaMismatch, fetchPackage(std.testing.allocator, "github.com/example/pkg", "HEAD", .{ .expected_source_sha256 = wrong_hash }));
    try std.testing.expectError(error.FileNotFound, sio.cwd().access("sa_vendor/github.com/example/pkg", .{}));
}

test "fetch offline reuses existing vendor without deleting it" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sa_vendor/github.com/example/pkg");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sa_vendor/github.com/example/pkg/index.sars", .data = "@cached() -> i32:\nreturn 1\n" });

    var old_cwd = try sio.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer old_cwd.setAsCwd() catch |err| {
        // Test teardown cannot recover from cwd restoration failure.
        _ = @errorName(err);
    };

    var result = try fetchPackage(std.testing.allocator, "github.com/example/pkg", "HEAD", .{ .offline = true });
    defer result.deinit(std.testing.allocator);
    const expected_root = try std.fs.path.join(std.testing.allocator, &.{ "sa_vendor", "github.com/example/pkg" });
    defer std.testing.allocator.free(expected_root);
    try std.testing.expectEqualStrings(expected_root, result.root);
    const expected_hash = try audit.hashPackageSource(std.testing.allocator, result.root);
    try std.testing.expect(std.mem.eql(u8, expected_hash[0..], result.source_sha256[0..]));
    try sio.cwd().access("sa_vendor/github.com/example/pkg/index.sars", .{ .read = true });
}

test "fetch applies mirror rules before network fallback" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "mirror/github/org/pkg");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "mirror/github/org/pkg/index.sars", .data = "@mirrored() -> i32:\nreturn 9\n" });

    var old_cwd = try sio.cwd().openDir(".", .{});
    defer old_cwd.close();
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer old_cwd.setAsCwd() catch |err| {
        // Test teardown cannot recover from cwd restoration failure.
        _ = @errorName(err);
    };

    const rules = [_]manifest.MirrorRule{.{
        .host_pattern = "github.com",
        .rewrite_to = "mirror/github",
    }};
    var result = try fetchPackage(std.testing.allocator, "github.com/org/pkg", "HEAD", .{ .mirror_rules = rules[0..] });
    defer result.deinit(std.testing.allocator);
    try sio.cwd().access("sa_vendor/github.com/org/pkg/index.sars", .{ .read = true });
}

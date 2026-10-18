const std = @import("std");
const sio = @import("sio");

const manifest = @import("manifest.zig");

pub const ResolveError = error{
    OutOfMemory,
    FileNotFound,
    InvalidFormat,
    InvalidPath,
    DuplicateEntry,
    UnknownPackage,
    MissingDefaultMember,
};

pub const PackageSelection = struct {
    request: ?[]const u8 = null,
};

pub const PackageResolution = struct {
    workspace_root: []u8,
    member_root: []u8,
    workspace_manifest_path: []u8,
    member_manifest_path: []u8,
    workspace_manifest: ?manifest.Manifest,
    member_manifest: ?manifest.Manifest,
    effective_manifest: ?manifest.Manifest,
    selected_package: ?[]u8,
    workspace_rel_member_path: ?[]u8,

    pub fn deinit(self: *PackageResolution, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_root);
        allocator.free(self.member_root);
        allocator.free(self.workspace_manifest_path);
        allocator.free(self.member_manifest_path);
        if (self.workspace_manifest) |*m| m.deinit(allocator);
        if (self.member_manifest) |*m| m.deinit(allocator);
        if (self.effective_manifest) |*m| m.deinit(allocator);
        if (self.selected_package) |name| allocator.free(name);
        if (self.workspace_rel_member_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub const WorkspaceMember = struct {
    rel_path: []u8,
    member_root: []u8,
    package_name: ?[]u8,

    pub fn deinit(self: *WorkspaceMember, allocator: std.mem.Allocator) void {
        allocator.free(self.rel_path);
        allocator.free(self.member_root);
        if (self.package_name) |name| allocator.free(name);
        self.* = undefined;
    }
};

pub fn freeWorkspaceMembers(allocator: std.mem.Allocator, members: []WorkspaceMember) void {
    for (members) |*member| member.deinit(allocator);
    allocator.free(members);
}

const SelectedMember = struct {
    member_root: []u8,
    rel_path: []u8,
    package_name: ?[]u8,
};

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

fn pathJoinAlloc(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return try std.fs.path.join(allocator, parts);
}

fn realpathAllocResolved(allocator: std.mem.Allocator, path: []const u8) ResolveError![]u8 {
    return sio.cwd().realpathAlloc(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.FileNotFound,
        else => error.InvalidPath,
    };
}

fn realpathAllocIfExists(allocator: std.mem.Allocator, path: []const u8) ResolveError!?[]u8 {
    return sio.cwd().realpathAlloc(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => null,
        else => error.InvalidPath,
    };
}

fn pathExists(path: []const u8) bool {
    sio.cwd().access(path, .{}) catch return false;
    return true;
}

fn readManifestTextFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try sio.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, manifest.max_manifest_bytes);
}

fn readManifestFile(allocator: std.mem.Allocator, path: []const u8) ResolveError!?manifest.Manifest {
    const source = readManifestTextFileAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.InvalidPath,
    };
    defer allocator.free(source);
    return manifest.parseManifestWithFile(allocator, source, path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidFormat => error.InvalidFormat,
        error.DuplicateEntry => error.DuplicateEntry,
        else => error.InvalidFormat,
    };
}

fn mapManifestError(err: anyerror) ResolveError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateEntry, error.DuplicateMirror => error.DuplicateEntry,
        error.InvalidFormat,
        error.InvalidCapability,
        error.InvalidSha256,
        error.DuplicateTargetHash,
        error.ForbiddenGlobalConfig,
        => error.InvalidFormat,
        else => error.InvalidFormat,
    };
}

fn cloneManifestResolved(allocator: std.mem.Allocator, source: manifest.Manifest) ResolveError!manifest.Manifest {
    return manifest.cloneManifest(allocator, source) catch |err| return mapManifestError(err);
}

fn mergeWorkspaceManifestsResolved(
    allocator: std.mem.Allocator,
    root_manifest: ?*const manifest.Manifest,
    member_manifest: ?*const manifest.Manifest,
) ResolveError!manifest.Manifest {
    return manifest.mergeWorkspaceManifests(allocator, root_manifest, member_manifest) catch |err| return mapManifestError(err);
}

fn manifestPathForRoot(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
    return try pathJoinAlloc(allocator, &.{ root_path, "sa.mod" });
}

fn sourcePathForRoot(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
    const src_path = try pathJoinAlloc(allocator, &.{ root_path, "src", "main.sars" });
    if (pathExists(src_path)) return src_path;
    allocator.free(src_path);
    const src_sars = try pathJoinAlloc(allocator, &.{ root_path, "src", "main.sars" });
    if (pathExists(src_sars)) return src_sars;
    allocator.free(src_sars);
    const fallback = try pathJoinAlloc(allocator, &.{ root_path, "main.sars" });
    if (pathExists(fallback)) return fallback;
    allocator.free(fallback);
    const fallback_sars = try pathJoinAlloc(allocator, &.{ root_path, "main.sars" });
    if (pathExists(fallback_sars)) return fallback_sars;
    allocator.free(fallback_sars);
    return error.FileNotFound;
}

fn manifestDir(real_path: []const u8) []const u8 {
    return std.fs.path.dirname(real_path) orelse real_path;
}

fn pathContains(path: []const u8, prefix: []const u8) bool {
    if (std.mem.eql(u8, path, prefix)) return true;
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (prefix.len == 0) return true;
    if (prefix[prefix.len - 1] == std.fs.path.sep) return true;
    return path.len > prefix.len and path[prefix.len] == std.fs.path.sep;
}

fn memberRootPath(allocator: std.mem.Allocator, workspace_root: []const u8, member_rel_path: []const u8) ResolveError![]u8 {
    const joined = try pathJoinAlloc(allocator, &.{ workspace_root, member_rel_path });
    errdefer allocator.free(joined);
    if (try realpathAllocIfExists(allocator, joined)) |real_member_root| {
        allocator.free(joined);
        return real_member_root;
    }
    return joined;
}

fn findNearestManifestRoot(allocator: std.mem.Allocator, start_path: []const u8) ResolveError![]u8 {
    var current = try realpathAllocResolved(allocator, start_path);
    errdefer allocator.free(current);
    const fallback = try allocator.dupe(u8, current);
    errdefer allocator.free(fallback);

    while (true) {
        const manifest_path = try pathJoinAlloc(allocator, &.{ current, "sa.mod" });
        defer allocator.free(manifest_path);
        if (pathExists(manifest_path)) {
            allocator.free(fallback);
            return current;
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    allocator.free(current);
    return fallback;
}

pub fn listWorkspaceMembers(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    workspace_manifest: *const manifest.Manifest,
) ResolveError![]WorkspaceMember {
    var members = std.array_list.Managed(WorkspaceMember).init(allocator);
    errdefer {
        for (members.items) |*member| member.deinit(allocator);
        members.deinit();
    }

    if (workspace_manifest.workspace) |workspace_decl| {
        for (workspace_decl.members) |member_rel_path| {
            const member_root = try memberRootPath(allocator, workspace_root, member_rel_path);
            errdefer allocator.free(member_root);

            const member_manifest_path = try pathJoinAlloc(allocator, &.{ member_root, "sa.mod" });
            defer allocator.free(member_manifest_path);
            const maybe_member_manifest = try readManifestFile(allocator, member_manifest_path);

            const package_name = if (maybe_member_manifest != null and maybe_member_manifest.?.package_decl != null)
                try allocator.dupe(u8, maybe_member_manifest.?.package_decl.?.name)
            else
                null;

            if (maybe_member_manifest) |member_manifest| {
                var owned = member_manifest;
                owned.deinit(allocator);
            }

            try members.append(.{
                .rel_path = try allocator.dupe(u8, member_rel_path),
                .member_root = member_root,
                .package_name = package_name,
            });
        }
    } else {
        try members.append(.{
            .rel_path = try allocator.dupe(u8, "."),
            .member_root = try allocator.dupe(u8, workspace_root),
            .package_name = if (workspace_manifest.package_decl) |package_decl| try allocator.dupe(u8, package_decl.name) else null,
        });
    }

    return try members.toOwnedSlice();
}

fn findMemberIndexByPath(members: []const WorkspaceMember, path: []const u8) ?usize {
    var match_index: ?usize = null;
    var match_len: usize = 0;
    for (members, 0..) |member, idx| {
        if (!pathContains(path, member.member_root)) continue;
        if (member.member_root.len < match_len) continue;
        match_index = idx;
        match_len = member.member_root.len;
    }
    return match_index;
}

fn selectWorkspaceMember(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    workspace_manifest: *const manifest.Manifest,
    selection: PackageSelection,
    preferred_member_path: ?[]const u8,
) ResolveError!SelectedMember {
    const members = try listWorkspaceMembers(allocator, workspace_root, workspace_manifest);
    defer freeWorkspaceMembers(allocator, members);

    const requested = if (selection.request) |request| trim(request) else null;
    const workspace_decl = workspace_manifest.workspace;

    var selected_index: ?usize = null;
    if (requested) |req| {
        for (members, 0..) |member, idx| {
            if (std.mem.eql(u8, member.rel_path, req)) {
                selected_index = idx;
                break;
            }
            if (member.package_name) |package_name| {
                if (std.mem.eql(u8, package_name, req)) {
                    selected_index = idx;
                    break;
                }
            }
        }
        if (selected_index == null) return error.UnknownPackage;
    } else if (preferred_member_path) |path| {
        selected_index = findMemberIndexByPath(members, path);
    }

    if (selected_index == null) {
        if (workspace_decl) |decl| {
            if (decl.default_member) |default_member| {
                for (members, 0..) |member, idx| {
                    if (std.mem.eql(u8, member.rel_path, default_member)) {
                        selected_index = idx;
                        break;
                    }
                    if (member.package_name) |package_name| {
                        if (std.mem.eql(u8, package_name, default_member)) {
                            selected_index = idx;
                            break;
                        }
                    }
                }
                if (selected_index == null) return error.MissingDefaultMember;
            } else if (members.len == 1) {
                selected_index = 0;
            } else {
                return error.MissingDefaultMember;
            }
        } else {
            selected_index = 0;
        }
    }

    const selected = members[selected_index.?];
    return .{
        .member_root = try allocator.dupe(u8, selected.member_root),
        .rel_path = try allocator.dupe(u8, selected.rel_path),
        .package_name = if (selected.package_name) |package_name| try allocator.dupe(u8, package_name) else null,
    };
}

fn workspaceContainsPath(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    workspace_manifest: *const manifest.Manifest,
    candidate_path: []const u8,
) ResolveError!bool {
    const members = try listWorkspaceMembers(allocator, workspace_root, workspace_manifest);
    defer freeWorkspaceMembers(allocator, members);
    return findMemberIndexByPath(members, candidate_path) != null;
}

fn findAncestorWorkspaceRoot(allocator: std.mem.Allocator, member_root: []const u8) ResolveError!?[]u8 {
    var current = std.fs.path.dirname(member_root) orelse return null;

    while (true) {
        if (std.mem.eql(u8, current, member_root)) break;

        const manifest_path = try manifestPathForRoot(allocator, current);
        defer allocator.free(manifest_path);
        const maybe_manifest = try readManifestFile(allocator, manifest_path);
        if (maybe_manifest) |workspace_manifest| {
            var owned = workspace_manifest;
            defer owned.deinit(allocator);
            if (owned.workspace != null and try workspaceContainsPath(allocator, current, &owned, member_root)) {
                return try allocator.dupe(u8, current);
            }
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }

    return null;
}

pub fn resolveFromCurrentDir(allocator: std.mem.Allocator, selection: PackageSelection) ResolveError!PackageResolution {
    return try resolveFromRootPath(allocator, ".", selection);
}

pub fn resolveFromRootPath(allocator: std.mem.Allocator, root_path: []const u8, selection: PackageSelection) ResolveError!PackageResolution {
    const start_real = try realpathAllocResolved(allocator, root_path);
    defer allocator.free(start_real);

    const anchor_root = try findNearestManifestRoot(allocator, start_real);
    const ancestor_workspace_root = try findAncestorWorkspaceRoot(allocator, anchor_root);
    errdefer if (ancestor_workspace_root == null) allocator.free(anchor_root);
    defer if (ancestor_workspace_root != null) allocator.free(anchor_root);

    const workspace_root = if (ancestor_workspace_root) |root|
        root
    else
        anchor_root;
    errdefer if (ancestor_workspace_root != null) allocator.free(workspace_root);

    const workspace_manifest_path = try manifestPathForRoot(allocator, workspace_root);
    errdefer allocator.free(workspace_manifest_path);
    const workspace_manifest = try readManifestFile(allocator, workspace_manifest_path);
    errdefer if (workspace_manifest) |manifest_value| {
        var owned = manifest_value;
        owned.deinit(allocator);
    };

    const selected: SelectedMember = if (workspace_manifest) |*workspace_manifest_value|
        try selectWorkspaceMember(
            allocator,
            workspace_root,
            workspace_manifest_value,
            selection,
            if (ancestor_workspace_root != null)
                anchor_root
            else
                start_real,
        )
    else
        SelectedMember{
            .member_root = try allocator.dupe(u8, workspace_root),
            .rel_path = try allocator.dupe(u8, "."),
            .package_name = null,
        };
    errdefer {
        allocator.free(selected.member_root);
        allocator.free(selected.rel_path);
        if (selected.package_name) |name| allocator.free(name);
    }

    const member_manifest_path = try manifestPathForRoot(allocator, selected.member_root);
    errdefer allocator.free(member_manifest_path);
    const member_manifest = try readManifestFile(allocator, member_manifest_path);
    errdefer if (member_manifest) |manifest_value| {
        var owned = manifest_value;
        owned.deinit(allocator);
    };

    const effective_manifest = blk: {
        if (workspace_manifest == null and member_manifest == null) break :blk null;
        if (workspace_manifest != null and std.mem.eql(u8, workspace_root, selected.member_root)) {
            break :blk try cloneManifestResolved(allocator, workspace_manifest.?);
        }
        break :blk try mergeWorkspaceManifestsResolved(allocator, if (workspace_manifest) |*m| m else null, if (member_manifest) |*m| m else null);
    };

    return .{
        .workspace_root = workspace_root,
        .member_root = selected.member_root,
        .workspace_manifest_path = workspace_manifest_path,
        .member_manifest_path = member_manifest_path,
        .workspace_manifest = workspace_manifest,
        .member_manifest = member_manifest,
        .effective_manifest = effective_manifest,
        .selected_package = selected.package_name,
        .workspace_rel_member_path = selected.rel_path,
    };
}

pub fn resolveFromSourcePath(allocator: std.mem.Allocator, source_path: []const u8) ResolveError!PackageResolution {
    const real_source = try sio.cwd().realpathAlloc(allocator, source_path);
    defer allocator.free(real_source);
    return try resolveFromRootPath(allocator, manifestDir(real_source), .{});
}

pub fn selectedSourcePath(allocator: std.mem.Allocator, resolved: *const PackageResolution) ResolveError![]u8 {
    return sourcePathForRoot(allocator, resolved.member_root);
}

test "workspace resolver selects default member by package name" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "members/app/src");
    try tmp.dir.createDirPath(std.testing.io, "members/tool/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sa.mod", .data = 
        \\workspace {
        \\  members ["members/app", "members/tool"]
        \\  default_member "app"
        \\}
        \\
        \\require github.com/acme/shared @v1 sha256:1111111111111111111111111111111111111111111111111111111111111111
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "members/app/sa.mod", .data = 
        \\package "app"
        \\
        \\require github.com/acme/app @v1 sha256:2222222222222222222222222222222222222222222222222222222222222222
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "members/app/src/main.sars", .data = "@main() -> i32:\nreturn 0\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "members/tool/sa.mod", .data = "package \"tool\"\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "members/tool/src/main.sars", .data = "@main() -> i32:\nreturn 1\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var resolved = try resolveFromRootPath(std.testing.allocator, root, .{});
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("members/app", resolved.workspace_rel_member_path.?);
    try std.testing.expectEqualStrings("app", resolved.selected_package.?);
    try std.testing.expect(resolved.effective_manifest != null);
    try std.testing.expectEqual(@as(usize, 2), resolved.effective_manifest.?.requires.len);

    const source_path = try selectedSourcePath(std.testing.allocator, &resolved);
    defer std.testing.allocator.free(source_path);
    try std.testing.expect(std.mem.endsWith(u8, source_path, "members/app/src/main.sars"));
}

test "workspace resolver selects explicit member by relative path" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "members/tool/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sa.mod", .data = 
        \\workspace {
        \\  members ["members/tool"]
        \\  default_member "members/tool"
        \\}
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "members/tool/sa.mod", .data = "package \"tool\"\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "members/tool/src/main.sars", .data = "@main() -> i32:\nreturn 1\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var resolved = try resolveFromRootPath(std.testing.allocator, root, .{ .request = "members/tool" });
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("members/tool", resolved.workspace_rel_member_path.?);
    try std.testing.expectEqualStrings("tool", resolved.selected_package.?);
}

test "workspace resolver climbs from member manifest to ancestor workspace root" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "members/app/src");
    try tmp.dir.createDirPath(std.testing.io, "members/tool/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sa.mod", .data = 
        \\workspace {
        \\  members ["members/app", "members/tool"]
        \\  default_member "tool"
        \\}
        \\
        \\require github.com/acme/shared @v1 sha256:1111111111111111111111111111111111111111111111111111111111111111
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "members/app/sa.mod", .data = 
        \\package "app"
        \\
        \\require github.com/acme/app @v1 sha256:2222222222222222222222222222222222222222222222222222222222222222
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "members/app/src/main.sars", .data = "@main() -> i32:\nreturn 7\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "members/tool/sa.mod", .data = "package \"tool\"\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "members/tool/src/main.sars", .data = "@main() -> i32:\nreturn 9\n" });

    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer original_cwd.setAsCwd() catch {};

    var resolved = try resolveFromRootPath(std.testing.allocator, "members/app/src", .{});
    defer resolved.deinit(std.testing.allocator);

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const member_root = try tmp.dir.realPathFileAlloc(std.testing.io, "members/app", std.testing.allocator);
    defer std.testing.allocator.free(member_root);

    try std.testing.expectEqualStrings(root, resolved.workspace_root);
    try std.testing.expectEqualStrings(member_root, resolved.member_root);
    try std.testing.expectEqualStrings("members/app", resolved.workspace_rel_member_path.?);
    try std.testing.expectEqualStrings("app", resolved.selected_package.?);
    try std.testing.expect(resolved.effective_manifest != null);
    try std.testing.expectEqual(@as(usize, 2), resolved.effective_manifest.?.requires.len);
}

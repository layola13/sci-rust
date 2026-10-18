const std = @import("std");
const builtin = @import("builtin");
const sio = @import("sio");

const def_dict = @import("flattener/def_dict.zig");
const classifier = @import("flattener/line_classifier.zig");
const forbidden = @import("flattener/forbidden.zig");
const symbol = @import("flattener/symbol.zig");
const common_instruction = @import("common/instruction.zig");
const common_const_decl = @import("common/const_decl.zig");
const atomic = @import("common/atomic.zig");
const common_signature = @import("common/signature.zig");
const common_trap = @import("common/trap.zig");
const common_upstream = @import("common/upstream_loc.zig");
const pkg_resolver = @import("pkg/resolver.zig");

pub const LineKind = classifier.LineKind;
pub const InstructionForm = classifier.InstructionForm;
pub const ClassifiedLine = classifier.ClassifiedLine;
pub const ForbiddenHit = forbidden.ForbiddenHit;
pub const DefDict = def_dict.DefDict;
pub const DefError = def_dict.DefError;
pub const SymbolTable = symbol.SymbolTable;
pub const Instruction = common_instruction.Instruction;
pub const InstKind = common_instruction.InstKind;
pub const Operand = common_instruction.Operand;
pub const ConstDecl = common_const_decl.ConstDecl;
pub const FunctionSig = common_signature.FunctionSig;
pub const FunctionKind = common_signature.FunctionKind;
pub const Trap = common_trap.Trap;
pub const LocTable = common_upstream.LocTable;

const max_expanded_instructions: usize = 10_000_000;
const max_expanded_macro_lines: usize = 10_000_000;
const max_macro_expansion_events: u64 = 10_000_000;
const max_macro_recursion_depth: u16 = 256;

fn bumpMacroExpansionCounter(counter: *u64) !u64 {
    if (counter.* >= max_macro_expansion_events) return error.MacroExpansionBudget;
    counter.* += 1;
    return counter.*;
}

fn ensureRepExpansionBudget(count: usize, body_line_count: usize) !void {
    if (body_line_count == 0) return;
    if (count > max_expanded_macro_lines / body_line_count) return error.MacroExpansionBudget;
}

pub const ResolveContext = struct {
    dependencies: []const pkg_resolver.Dependency = &.{},
    options: pkg_resolver.ResolveOptions = .{},
    package_identity: ?[]const u8 = null,
};

pub const LayoutVersion = struct {
    path: []u8,
    version: u64,

    fn deinit(self: *LayoutVersion, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

const MacroDef = struct {
    params: []const []const u8,
    variadic_param: ?[]const u8 = null,
    body_start: usize,
    body_end: usize,
    owned_body_lines: []SourceLine = &.{},
    owned_name: ?[]u8 = null,
    owned_params: [][]const u8 = &.{},
    owned_variadic_param: ?[]u8 = null,

    fn deinit(self: *MacroDef, allocator: std.mem.Allocator) void {
        if (self.owned_body_lines.len != 0) deinitOwnedSourceLines(allocator, self.owned_body_lines);
        if (self.owned_name) |name| allocator.free(name);
        if (self.owned_params.len != 0) {
            for (self.owned_params) |param| allocator.free(param);
            allocator.free(self.owned_params);
        } else {
            allocator.free(self.params);
        }
        if (self.owned_variadic_param) |param| allocator.free(param);
        self.* = undefined;
    }
};

const CachedMacroLine = struct {
    line_no: u32,
    text: []u8,
    package_identity: ?[]u8 = null,
    package_source_sha256: ?[32]u8 = null,

    fn deinit(self: *CachedMacroLine, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.package_identity) |identity| allocator.free(identity);
        self.* = undefined;
    }
};

const CachedMacroDef = struct {
    name: []u8,
    params: [][]const u8,
    variadic_param: ?[]u8 = null,
    body_lines: []CachedMacroLine,

    fn deinit(self: *CachedMacroDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.params) |param| allocator.free(param);
        allocator.free(self.params);
        if (self.variadic_param) |param| allocator.free(param);
        for (self.body_lines) |*line| line.deinit(allocator);
        allocator.free(self.body_lines);
        self.* = undefined;
    }
};

const Replacement = struct {
    needle: []const u8,
    replacement: []const u8,
};

pub const SourceLine = struct {
    line_no: u32,
    text: []const u8,
    classified: ClassifiedLine,
    package_identity: ?[]const u8 = null,
    package_source_sha256: ?[32]u8 = null,
};

pub const ErrorContext = struct {
    source_line: ?u32 = null,
};

pub const IncludeCycle = error{
    IncludeCycle,
};

fn recordErrorSourceLine(error_ctx: ?*ErrorContext, line_no: u32) void {
    if (error_ctx) |ctx| {
        ctx.source_line = line_no;
    }
}

pub fn takeErrorSourceLine(error_ctx: *ErrorContext) ?u32 {
    const line_no = error_ctx.source_line;
    error_ctx.source_line = null;
    return line_no;
}

fn appendExpandedLine(
    out: *std.array_list.Managed(u8),
    line_package_identities: *std.array_list.Managed(?[]const u8),
    line_package_hashes: *std.array_list.Managed(?[32]u8),
    text: []const u8,
    package_identity: ?[]const u8,
    package_hash: ?[32]u8,
) !void {
    try out.appendSlice(text);
    try out.append('\n');
    try line_package_identities.append(package_identity);
    try line_package_hashes.append(package_hash);
}

fn isFunctionLikeLineKind(kind: LineKind) bool {
    return switch (kind) {
        .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => true,
        else => false,
    };
}

fn consumesPendingLoc(kind: LineKind) bool {
    return switch (kind) {
        .const_decl, .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl, .instruction, .native => true,
        else => false,
    };
}

fn appendGeneratedLocLine(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(u8),
    line_package_identities: *std.array_list.Managed(?[]const u8),
    line_package_hashes: *std.array_list.Managed(?[32]u8),
    source_path: []const u8,
    line_no: u32,
    package_identity: ?[]const u8,
    package_hash: ?[32]u8,
) !void {
    const loc_line = try std.fmt.allocPrint(allocator, "#loc \"{s}\":{d}:1", .{ source_path, line_no });
    defer allocator.free(loc_line);
    try appendExpandedLine(out, line_package_identities, line_package_hashes, loc_line, package_identity, package_hash);
}

const ImportExpansion = struct {
    source: []u8,
    active_paths: std.StringHashMap(void),
    seen_paths: std.StringHashMap(void),
    seen_package_identities: std.StringHashMap(void),
    line_package_identities: std.array_list.Managed(?[]const u8),
    line_package_hashes: std.array_list.Managed(?[32]u8),
    owned_paths: std.array_list.Managed([]u8),
    layout_versions: std.array_list.Managed(LayoutVersion),

    pub fn deinit(self: *ImportExpansion, allocator: std.mem.Allocator) void {
        self.line_package_identities.deinit();
        self.line_package_hashes.deinit();
        for (self.owned_paths.items) |path| {
            allocator.free(path);
        }
        self.owned_paths.deinit();
        var pkg_it = self.seen_package_identities.iterator();
        while (pkg_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.seen_package_identities.deinit();
        for (self.layout_versions.items) |*layout_version| layout_version.deinit(allocator);
        self.layout_versions.deinit();
        self.active_paths.deinit();
        self.seen_paths.deinit();
        allocator.free(self.source);
        self.* = undefined;
    }
};

const ImportSourceCacheEntry = struct {
    entry_path: []u8,
    root_dir: ?[]u8,
    package_identity: ?[]u8,
    source_sha256: ?[32]u8,
    source: []u8,
    mtime: i128,
    size: u64,
    is_global: bool,
    last_used_tick: u64,
};

const ExpandedImportCacheFileStat = struct {
    path: []u8,
    mtime: i128,
    size: u64,
};

const ExpandedImportCacheEntry = struct {
    source: []u8,
    line_count: usize,
    files: []ExpandedImportCacheFileStat,
    layout_versions: []LayoutVersion,
    last_used_tick: u64,
};

var import_source_cache_mutex: std.atomic.Mutex = .unlocked;
var import_source_cache: ?std.StringHashMap(ImportSourceCacheEntry) = null;
var import_source_cache_tick: u64 = 0;
var test_import_source_cache_max_entries: ?usize = null;

var expanded_import_cache_mutex: std.atomic.Mutex = .unlocked;
var expanded_import_cache: ?std.StringHashMap(ExpandedImportCacheEntry) = null;
var expanded_import_cache_tick: u64 = 0;
var test_expanded_import_cache_max_entries: ?usize = null;
var test_expanded_import_cache_hits: usize = 0;
var test_expanded_import_cache_stores: usize = 0;

fn importSourceCacheMap() *std.StringHashMap(ImportSourceCacheEntry) {
    if (import_source_cache == null) {
        import_source_cache = std.StringHashMap(ImportSourceCacheEntry).init(std.heap.page_allocator);
    }
    return &import_source_cache.?;
}

fn expandedImportCacheMap() *std.StringHashMap(ExpandedImportCacheEntry) {
    if (expanded_import_cache == null) {
        expanded_import_cache = std.StringHashMap(ExpandedImportCacheEntry).init(std.heap.page_allocator);
    }
    return &expanded_import_cache.?;
}

fn traceImportsEnabled() bool {
    const value = sio.getEnvVarOwned(std.heap.page_allocator, "SAASM_TRACE_IMPORTS") catch return false;
    defer std.heap.page_allocator.free(value);
    return value.len != 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false") and !std.mem.eql(u8, value, "False");
}

fn importSourceCacheMaxEntries() ?usize {
    if (builtin.is_test) {
        if (test_import_source_cache_max_entries) |value| return value;
    }
    const value = sio.getEnvVarOwned(std.heap.page_allocator, "SA_IMPORT_CACHE_MAX_ENTRIES") catch return null;
    defer std.heap.page_allocator.free(value);
    const parsed = std.fmt.parseUnsigned(usize, value, 10) catch return null;
    return if (parsed == 0) null else parsed;
}

fn expandedImportCacheMaxEntries() ?usize {
    if (builtin.is_test) {
        if (test_expanded_import_cache_max_entries) |value| return value;
    }
    const value = sio.getEnvVarOwned(std.heap.page_allocator, "SA_EXPANDED_IMPORT_CACHE_MAX_ENTRIES") catch return null;
    defer std.heap.page_allocator.free(value);
    const parsed = std.fmt.parseUnsigned(usize, value, 10) catch return null;
    return if (parsed == 0) null else parsed;
}

fn nextImportSourceCacheTickLocked() u64 {
    import_source_cache_tick +%= 1;
    return import_source_cache_tick;
}

fn nextExpandedImportCacheTickLocked() u64 {
    expanded_import_cache_tick +%= 1;
    return expanded_import_cache_tick;
}

fn appendCacheBytes(out: *std.array_list.Managed(u8), bytes: []const u8) !void {
    try out.appendSlice(bytes);
    try out.append(0);
}

fn buildImportSourceCacheKey(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    import_path: []const u8,
    resolve_ctx: ?ResolveContext,
) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try appendCacheBytes(&out, base_dir);
    try appendCacheBytes(&out, import_path);
    if (resolve_ctx) |ctx| {
        try appendCacheBytes(&out, if (ctx.options.project_root) |path| path else "");
        try appendCacheBytes(&out, if (ctx.options.home_dir) |path| path else "");
        try appendCacheBytes(&out, if (ctx.options.std_root) |path| path else "");
        var flag_buf: [64]u8 = undefined;
        const flag_text = try std.fmt.bufPrint(&flag_buf, "{}\x00{}\x00", .{ ctx.options.offline, ctx.options.max_local_file_bytes });
        try out.appendSlice(flag_text);
        for (ctx.options.entry_candidates) |candidate| try appendCacheBytes(&out, candidate);
        try out.append(0);
        for (ctx.options.plugin_import_roots) |root| try appendCacheBytes(&out, root);
        try out.append(0);
        for (ctx.options.stable_import_roots) |root| try appendCacheBytes(&out, root);
        try out.append(0);
        for (ctx.dependencies) |dep| {
            try appendCacheBytes(&out, dep.url);
            try appendCacheBytes(&out, dep.ref);
        }
    } else {
        try appendCacheBytes(&out, "default");
    }
    return try out.toOwnedSlice();
}

fn pathWithinRoot(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    return std.mem.startsWith(u8, path, root) and path.len > root.len and std.fs.path.isSep(path[root.len]);
}

fn isStableImportCacheCandidate(allocator: std.mem.Allocator, base_dir: []const u8, import_path: []const u8, roots: []const []const u8) !bool {
    if (roots.len == 0) return false;
    if (std.mem.startsWith(u8, import_path, "sa:") or std.mem.startsWith(u8, import_path, "pkg:")) return false;

    const joined = if (std.fs.path.isAbsolute(import_path))
        try allocator.dupe(u8, import_path)
    else
        try std.fs.path.join(allocator, &.{ base_dir, import_path });
    defer allocator.free(joined);
    const real_import = sio.cwd().realpathAlloc(allocator, joined) catch return false;
    defer allocator.free(real_import);

    for (roots) |root| {
        const real_root = sio.cwd().realpathAlloc(allocator, root) catch continue;
        defer allocator.free(real_root);
        if (pathWithinRoot(real_import, real_root)) return true;
    }
    return false;
}

fn isImportCacheCandidate(allocator: std.mem.Allocator, base_dir: []const u8, import_path: []const u8, resolve_ctx: ?ResolveContext) !bool {
    if (std.mem.startsWith(u8, import_path, "sa_std/")) return true;
    if (std.mem.startsWith(u8, import_path, "../") or std.mem.startsWith(u8, import_path, "./")) {
        if (std.mem.eql(u8, base_dir, "sa_std") or std.mem.startsWith(u8, base_dir, "sa_std/")) return true;
        if (std.mem.indexOf(u8, base_dir, "/sa_std/") != null) return true;
        if (std.mem.endsWith(u8, base_dir, "/sa_std")) return true;
    }
    if (resolve_ctx) |ctx| {
        if (ctx.options.std_root) |std_root| {
            if (std.mem.eql(u8, base_dir, std_root)) return true;
            if (std.mem.startsWith(u8, base_dir, std_root) and base_dir.len > std_root.len and std.fs.path.isSep(base_dir[std_root.len])) return true;
        }
        if (try isStableImportCacheCandidate(allocator, base_dir, import_path, ctx.options.stable_import_roots)) return true;
    }
    return false;
}

fn cloneCachedImport(allocator: std.mem.Allocator, cached: ImportSourceCacheEntry, borrow_source: bool) !pkg_resolver.ResolvedImport {
    const entry_path = try allocator.dupe(u8, cached.entry_path);
    errdefer allocator.free(entry_path);
    const root_dir = if (cached.root_dir) |dir| try allocator.dupe(u8, dir) else null;
    errdefer if (root_dir) |dir| allocator.free(dir);
    const package_identity = if (cached.package_identity) |identity| try allocator.dupe(u8, identity) else null;
    errdefer if (package_identity) |identity| allocator.free(identity);
    const owned_source = if (borrow_source) null else try allocator.dupe(u8, cached.source);
    errdefer if (owned_source) |source| allocator.free(source);

    return .{
        .entry_path = entry_path,
        .source = owned_source orelse cached.source,
        .owned_source = owned_source,
        .root_dir = root_dir,
        .package_identity = package_identity,
        .source_sha256 = cached.source_sha256,
        .is_global = cached.is_global,
    };
}

fn freeImportSourceCacheEntry(entry: ImportSourceCacheEntry, comptime free_source: bool) void {
    const cache_allocator = std.heap.page_allocator;
    cache_allocator.free(entry.entry_path);
    if (entry.root_dir) |root_dir| cache_allocator.free(root_dir);
    if (entry.package_identity) |package_identity| cache_allocator.free(package_identity);
    if (free_source) cache_allocator.free(entry.source);
}

fn freeExpandedImportCacheEntry(entry: ExpandedImportCacheEntry) void {
    const cache_allocator = std.heap.page_allocator;
    cache_allocator.free(entry.source);
    for (entry.files) |file| cache_allocator.free(file.path);
    cache_allocator.free(entry.files);
    for (entry.layout_versions) |*layout_version| layout_version.deinit(cache_allocator);
    cache_allocator.free(entry.layout_versions);
}

fn statImportSourceCacheEntry(path: []const u8) !struct { mtime: i128, size: u64 } {
    const stat = try sio.cwd().statFile(path);
    return .{ .mtime = @as(i128, stat.mtime.toNanoseconds()), .size = stat.size };
}

fn cachedImportStillValid(entry: ImportSourceCacheEntry) bool {
    const stat = statImportSourceCacheEntry(entry.entry_path) catch return false;
    return stat.mtime == entry.mtime and stat.size == entry.size;
}

fn cachedExpandedImportStillValid(entry: ExpandedImportCacheEntry) bool {
    for (entry.files) |file| {
        const stat = statImportSourceCacheEntry(file.path) catch return false;
        if (stat.mtime != file.mtime or stat.size != file.size) return false;
    }
    return true;
}

fn expandedImportCacheEligible(imported_package_identity: ?[]const u8, current_package_identity: ?[]const u8, current_package_hash: ?[32]u8) bool {
    return imported_package_identity == null and current_package_identity == null and current_package_hash == null;
}

fn lineMetadataCacheable(
    line_package_identities: []const ?[]const u8,
    line_package_hashes: []const ?[32]u8,
) bool {
    for (line_package_identities) |identity| {
        if (identity != null) return false;
    }
    for (line_package_hashes) |hash| {
        if (hash != null) return false;
    }
    return true;
}

const ExpandedImportCacheDependency = struct {
    owned_start: usize,
    context_dependent: bool = false,
    parent: ?*ExpandedImportCacheDependency = null,
};

fn ownedPathSliceContains(paths: []const []u8, path: []const u8) bool {
    for (paths) |owned_path| {
        if (std.mem.eql(u8, owned_path, path)) return true;
    }
    return false;
}

fn markSeenImportContextDependency(
    dependency: ?*ExpandedImportCacheDependency,
    owned_paths: []const []u8,
    path: []const u8,
) void {
    var current = dependency;
    while (current) |dep| {
        if (!ownedPathSliceContains(owned_paths[dep.owned_start..], path)) {
            dep.context_dependent = true;
        }
        current = dep.parent;
    }
}

fn rollbackExpandedImportCacheApply(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(u8),
    line_package_identities: *std.array_list.Managed(?[]const u8),
    line_package_hashes: *std.array_list.Managed(?[32]u8),
    seen_paths: *std.StringHashMap(void),
    owned_paths: *std.array_list.Managed([]u8),
    layout_versions: *std.array_list.Managed(LayoutVersion),
    out_len: usize,
    line_len: usize,
    owned_len: usize,
    layout_len: usize,
) void {
    out.shrinkRetainingCapacity(out_len);
    line_package_identities.shrinkRetainingCapacity(line_len);
    line_package_hashes.shrinkRetainingCapacity(line_len);
    for (owned_paths.items[owned_len..]) |path| {
        _ = seen_paths.remove(path);
        allocator.free(path);
    }
    owned_paths.shrinkRetainingCapacity(owned_len);
    for (layout_versions.items[layout_len..]) |*layout_version| layout_version.deinit(allocator);
    layout_versions.shrinkRetainingCapacity(layout_len);
}

fn appendExpandedImportCacheHit(
    allocator: std.mem.Allocator,
    cache_key: []const u8,
    out: *std.array_list.Managed(u8),
    line_package_identities: *std.array_list.Managed(?[]const u8),
    line_package_hashes: *std.array_list.Managed(?[32]u8),
    active_paths: *std.StringHashMap(void),
    seen_paths: *std.StringHashMap(void),
    owned_paths: *std.array_list.Managed([]u8),
    layout_versions: *std.array_list.Managed(LayoutVersion),
) !bool {
    while (!expanded_import_cache_mutex.tryLock()) { std.Thread.yield() catch {}; }
    defer expanded_import_cache_mutex.unlock();

    if (expanded_import_cache == null) return false;
    var cache = expandedImportCacheMap();
    const entry = cache.getPtr(cache_key) orelse return false;
    if (!cachedExpandedImportStillValid(entry.*)) {
        if (cache.fetchRemove(cache_key)) |removed| {
            std.heap.page_allocator.free(removed.key);
            freeExpandedImportCacheEntry(removed.value);
        }
        return false;
    }

    for (entry.files) |file| {
        if (active_paths.contains(file.path)) return error.ImportCycle;
        if (seen_paths.contains(file.path)) return false;
    }

    const out_len = out.items.len;
    const line_len = line_package_identities.items.len;
    const owned_len = owned_paths.items.len;
    const layout_len = layout_versions.items.len;
    errdefer rollbackExpandedImportCacheApply(
        allocator,
        out,
        line_package_identities,
        line_package_hashes,
        seen_paths,
        owned_paths,
        layout_versions,
        out_len,
        line_len,
        owned_len,
        layout_len,
    );

    try out.appendSlice(entry.source);
    try line_package_identities.ensureUnusedCapacity(entry.line_count);
    try line_package_hashes.ensureUnusedCapacity(entry.line_count);
    for (0..entry.line_count) |_| {
        line_package_identities.appendAssumeCapacity(null);
        line_package_hashes.appendAssumeCapacity(null);
    }

    for (entry.files) |file| {
        const path_copy = try allocator.dupe(u8, file.path);
        owned_paths.append(path_copy) catch |err| {
            allocator.free(path_copy);
            return err;
        };
        seen_paths.put(path_copy, {}) catch |err| {
            _ = owned_paths.pop();
            allocator.free(path_copy);
            return err;
        };
    }
    for (entry.layout_versions) |layout_version| {
        const path_copy = try allocator.dupe(u8, layout_version.path);
        layout_versions.append(.{ .path = path_copy, .version = layout_version.version }) catch |err| {
            allocator.free(path_copy);
            return err;
        };
    }

    entry.last_used_tick = nextExpandedImportCacheTickLocked();
    if (builtin.is_test) test_expanded_import_cache_hits += 1;
    return true;
}

fn storeExpandedImportCacheEntry(
    cache_key: []const u8,
    source: []const u8,
    line_count: usize,
    files: []const []u8,
    layout_versions: []const LayoutVersion,
) !void {
    if (source.len == 0 and line_count == 0) return;
    const cache_allocator = std.heap.page_allocator;
    const cache_key_copy = try cache_allocator.dupe(u8, cache_key);
    errdefer cache_allocator.free(cache_key_copy);
    const source_copy = try cache_allocator.dupe(u8, source);
    errdefer cache_allocator.free(source_copy);
    const file_stats = try cache_allocator.alloc(ExpandedImportCacheFileStat, files.len);
    errdefer cache_allocator.free(file_stats);
    var copied_files: usize = 0;
    errdefer {
        for (file_stats[0..copied_files]) |file| cache_allocator.free(file.path);
    }
    for (files, 0..) |path, idx| {
        const stat = try statImportSourceCacheEntry(path);
        file_stats[idx] = .{
            .path = try cache_allocator.dupe(u8, path),
            .mtime = stat.mtime,
            .size = stat.size,
        };
        copied_files += 1;
    }
    const layout_copies = try cache_allocator.alloc(LayoutVersion, layout_versions.len);
    errdefer cache_allocator.free(layout_copies);
    var copied_layouts: usize = 0;
    errdefer {
        for (layout_copies[0..copied_layouts]) |*layout_version| layout_version.deinit(cache_allocator);
    }
    for (layout_versions, 0..) |layout_version, idx| {
        const path_copy = try cache_allocator.dupe(u8, layout_version.path);
        layout_copies[idx] = .{ .path = path_copy, .version = layout_version.version };
        copied_layouts += 1;
    }

    while (!expanded_import_cache_mutex.tryLock()) { std.Thread.yield() catch {}; }
    defer expanded_import_cache_mutex.unlock();
    var cache = expandedImportCacheMap();
    if (cache.getPtr(cache_key)) |old| {
        freeExpandedImportCacheEntry(old.*);
        old.* = .{
            .source = source_copy,
            .line_count = line_count,
            .files = file_stats,
            .layout_versions = layout_copies,
            .last_used_tick = nextExpandedImportCacheTickLocked(),
        };
        cache_allocator.free(cache_key_copy);
    } else {
        try cache.put(cache_key_copy, .{
            .source = source_copy,
            .line_count = line_count,
            .files = file_stats,
            .layout_versions = layout_copies,
            .last_used_tick = nextExpandedImportCacheTickLocked(),
        });
    }
    evictExpandedImportCacheIfNeeded(cache, expandedImportCacheMaxEntries());
    if (builtin.is_test) test_expanded_import_cache_stores += 1;
}

fn storeImportSourceCacheEntry(key: []const u8, resolved: pkg_resolver.ResolvedImport) !void {
    const stat = try statImportSourceCacheEntry(resolved.entry_path);
    const cache_allocator = std.heap.page_allocator;
    const cache_key = try cache_allocator.dupe(u8, key);
    errdefer cache_allocator.free(cache_key);
    const entry_path = try cache_allocator.dupe(u8, resolved.entry_path);
    errdefer cache_allocator.free(entry_path);
    const source = try cache_allocator.dupe(u8, resolved.source);
    errdefer cache_allocator.free(source);
    const root_dir = if (resolved.root_dir) |dir| try cache_allocator.dupe(u8, dir) else null;
    errdefer if (root_dir) |dir| cache_allocator.free(dir);
    const package_identity = if (resolved.package_identity) |identity| try cache_allocator.dupe(u8, identity) else null;
    errdefer if (package_identity) |identity| cache_allocator.free(identity);

    while (!import_source_cache_mutex.tryLock()) { std.Thread.yield() catch {}; }
    defer import_source_cache_mutex.unlock();
    var cache = importSourceCacheMap();
    if (cache.contains(key)) {
        cache_allocator.free(cache_key);
        cache_allocator.free(entry_path);
        cache_allocator.free(source);
        if (root_dir) |dir| cache_allocator.free(dir);
        if (package_identity) |identity| cache_allocator.free(identity);
        return;
    }
    try cache.put(cache_key, .{
        .entry_path = entry_path,
        .root_dir = root_dir,
        .package_identity = package_identity,
        .source_sha256 = resolved.source_sha256,
        .source = source,
        .mtime = stat.mtime,
        .size = stat.size,
        .is_global = resolved.is_global,
        .last_used_tick = nextImportSourceCacheTickLocked(),
    });
    evictImportSourceCacheIfNeeded(cache, importSourceCacheMaxEntries());
}

fn evictImportSourceCacheIfNeeded(cache: *std.StringHashMap(ImportSourceCacheEntry), max_entries: ?usize) void {
    const limit = max_entries orelse return;
    while (cache.count() > limit) {
        var oldest_key: ?[]const u8 = null;
        var oldest_tick: u64 = std.math.maxInt(u64);
        var it = cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_used_tick <= oldest_tick) {
                oldest_key = entry.key_ptr.*;
                oldest_tick = entry.value_ptr.last_used_tick;
            }
        }
        const key = oldest_key orelse return;
        if (cache.fetchRemove(key)) |removed| {
            std.heap.page_allocator.free(removed.key);
            freeImportSourceCacheEntry(removed.value, true);
        } else {
            return;
        }
    }
}

fn evictExpandedImportCacheIfNeeded(cache: *std.StringHashMap(ExpandedImportCacheEntry), max_entries: ?usize) void {
    const limit = max_entries orelse return;
    while (cache.count() > limit) {
        var oldest_key: ?[]const u8 = null;
        var oldest_tick: u64 = std.math.maxInt(u64);
        var it = cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_used_tick <= oldest_tick) {
                oldest_key = entry.key_ptr.*;
                oldest_tick = entry.value_ptr.last_used_tick;
            }
        }
        const key = oldest_key orelse return;
        if (cache.fetchRemove(key)) |removed| {
            std.heap.page_allocator.free(removed.key);
            freeExpandedImportCacheEntry(removed.value);
        } else {
            return;
        }
    }
}

pub const FlattenResult = struct {
    instructions: []Instruction,
    const_decls: []ConstDecl,
    function_sigs: []FunctionSig,
    test_sigs: []FunctionSig,
    cached_macro_defs: []CachedMacroDef,
    def_dict: DefDict,
    symbols: SymbolTable,
    loc_table: LocTable,
    layout_versions: []LayoutVersion,
    package_identities: std.StringHashMap(void),
    owned_text: [][]const u8,
    trap: ?Trap = null,

    pub fn deinit(self: *FlattenResult, allocator: std.mem.Allocator) void {
        for (self.loc_table) |entry| {
            if (entry) |loc| allocator.free(loc.file);
        }
        allocator.free(self.loc_table);
        for (self.layout_versions) |*layout_version| layout_version.deinit(allocator);
        allocator.free(self.layout_versions);
        var pkg_it = self.package_identities.iterator();
        while (pkg_it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.package_identities.deinit();
        for (self.instructions) |item| {
            if (item.package_identity) |identity| allocator.free(identity);
            if (item.upstream_loc) |loc| allocator.free(loc.file);
            if (item.native_reg_names.len != 0) allocator.free(item.native_reg_names);
        }
        for (self.const_decls) |*decl| decl.deinit(allocator);
        allocator.free(self.const_decls);
        for (self.owned_text) |text| allocator.free(text);
        allocator.free(self.owned_text);
        for (self.function_sigs) |*sig| sig.deinit(allocator);
        allocator.free(self.function_sigs);
        allocator.free(self.test_sigs);
        deinitCachedMacroDefs(allocator, self.cached_macro_defs);
        allocator.free(self.instructions);
        self.def_dict.deinit();
        self.symbols.deinit();
        self.* = undefined;
    }
};

pub const ForbiddenLine = struct {
    line_no: u32,
    hit: ForbiddenHit,
};

fn parseTokenList(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) {
        return try allocator.alloc([]const u8, 0);
    }

    var list = std.array_list.Managed([]const u8).init(allocator);
    errdefer list.deinit();

    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |item| {
        const token = std.mem.trim(u8, item, " \t");
        if (token.len == 0) return error.InvalidMacroInvocation;
        try list.append(token);
    }

    return try list.toOwnedSlice();
}

fn parseMacroParams(allocator: std.mem.Allocator, text: []const u8) !struct { params: []const []const u8, variadic_param: ?[]const u8 } {
    const raw_params = try parseTokenList(allocator, text);
    errdefer allocator.free(raw_params);

    var variadic_param: ?[]const u8 = null;
    var param_count = raw_params.len;

    for (raw_params, 0..) |param, idx| {
        if (std.mem.endsWith(u8, param, "...")) {
            if (idx + 1 != raw_params.len) return error.InvalidMacroInvocation;
            const base = std.mem.trimEnd(u8, param[0 .. param.len - 3], " \t");
            if (base.len == 0) return error.InvalidMacroInvocation;
            variadic_param = base;
            param_count = idx;
        }
    }

    if (param_count == raw_params.len) {
        return .{ .params = raw_params, .variadic_param = null };
    }

    const fixed_params = try allocator.alloc([]const u8, param_count);
    errdefer allocator.free(fixed_params);
    @memcpy(fixed_params, raw_params[0..param_count]);
    allocator.free(raw_params);
    return .{ .params = fixed_params, .variadic_param = variadic_param };
}

fn joinTokens(allocator: std.mem.Allocator, tokens: []const []const u8) ![]const u8 {
    if (tokens.len == 0) return try allocator.dupe(u8, "");
    var total_len: usize = 0;
    for (tokens) |token| total_len += token.len;
    total_len += (tokens.len - 1) * 2;

    var out = try allocator.alloc(u8, total_len);
    var cursor: usize = 0;
    for (tokens, 0..) |token, idx| {
        if (idx != 0) {
            out[cursor] = ',';
            out[cursor + 1] = ' ';
            cursor += 2;
        }
        @memcpy(out[cursor .. cursor + token.len], token);
        cursor += token.len;
    }
    return out;
}

fn deinitMacroMap(allocator: std.mem.Allocator, macros: *std.StringHashMap(MacroDef)) void {
    var it = macros.valueIterator();
    while (it.next()) |macro_def| {
        macro_def.deinit(allocator);
    }
    macros.deinit();
}

fn deinitCachedMacroDefs(allocator: std.mem.Allocator, defs: []CachedMacroDef) void {
    for (defs) |*def| def.deinit(allocator);
    allocator.free(defs);
}

fn deinitCachedMacroDefItems(allocator: std.mem.Allocator, defs: []CachedMacroDef) void {
    for (defs) |*def| def.deinit(allocator);
}

fn deinitOwnedSourceLineItems(allocator: std.mem.Allocator, lines: []SourceLine) void {
    for (lines) |line| {
        allocator.free(@constCast(line.text));
        if (line.package_identity) |identity| allocator.free(@constCast(identity));
    }
}

fn deinitOwnedSourceLines(allocator: std.mem.Allocator, lines: []SourceLine) void {
    deinitOwnedSourceLineItems(allocator, lines);
    allocator.free(lines);
}

fn cloneOwnedSourceLines(
    allocator: std.mem.Allocator,
    lines: []const SourceLine,
) ![]SourceLine {
    const owned = try allocator.alloc(SourceLine, lines.len);
    errdefer allocator.free(owned);

    var copied: usize = 0;
    errdefer deinitOwnedSourceLineItems(allocator, owned[0..copied]);

    for (lines, 0..) |line, idx| {
        const owned_text = try allocator.dupe(u8, line.text);
        errdefer allocator.free(owned_text);
        const owned_identity = if (line.package_identity) |identity| try allocator.dupe(u8, identity) else null;
        errdefer if (owned_identity) |identity| allocator.free(identity);
        owned[idx] = .{
            .line_no = line.line_no,
            .text = owned_text,
            .classified = line.classified,
            .package_identity = owned_identity,
            .package_source_sha256 = line.package_source_sha256,
        };
        copied += 1;
    }

    return owned;
}

fn macroDefBodyLines(def: *const MacroDef) ![]const SourceLine {
    if (def.owned_body_lines.len == 0) return error.InvalidMacroInvocation;
    return def.owned_body_lines;
}

fn captureCachedMacroDefs(
    allocator: std.mem.Allocator,
    macros: *const std.StringHashMap(MacroDef),
) ![]CachedMacroDef {
    const defs = try allocator.alloc(CachedMacroDef, macros.count());
    errdefer allocator.free(defs);
    var copied_defs: usize = 0;
    errdefer deinitCachedMacroDefItems(allocator, defs[0..copied_defs]);

    var it = macros.iterator();
    while (it.next()) |entry| {
        const def = entry.value_ptr.*;
        const body_lines = try macroDefBodyLines(&def);
        var cached = CachedMacroDef{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .params = &.{},
            .variadic_param = null,
            .body_lines = &.{},
        };
        errdefer cached.deinit(allocator);

        cached.params = try allocator.alloc([]const u8, def.params.len);
        var copied_params: usize = 0;
        errdefer {
            for (cached.params[0..copied_params]) |param| allocator.free(param);
            allocator.free(cached.params);
            cached.params = &.{};
        }

        for (def.params, 0..) |param, idx| {
            cached.params[idx] = try allocator.dupe(u8, param);
            copied_params += 1;
        }
        if (def.variadic_param) |param| {
            cached.variadic_param = try allocator.dupe(u8, param);
        }

        cached.body_lines = try allocator.alloc(CachedMacroLine, body_lines.len);
        var copied_body_lines: usize = 0;
        errdefer {
            for (cached.body_lines[0..copied_body_lines]) |*line| line.deinit(allocator);
            allocator.free(cached.body_lines);
            cached.body_lines = &.{};
        }

        for (body_lines, 0..) |line, idx| {
            const owned_text = try allocator.dupe(u8, line.text);
            errdefer allocator.free(owned_text);
            const owned_identity = if (line.package_identity) |identity| try allocator.dupe(u8, identity) else null;
            errdefer if (owned_identity) |identity| allocator.free(identity);
            cached.body_lines[idx] = .{
                .line_no = line.line_no,
                .text = owned_text,
                .package_identity = owned_identity,
                .package_source_sha256 = line.package_source_sha256,
            };
            copied_body_lines += 1;
        }

        defs[copied_defs] = cached;
        copied_defs += 1;
    }

    return defs[0..copied_defs];
}

fn restoreCachedMacroDefs(
    allocator: std.mem.Allocator,
    defs: []const CachedMacroDef,
    macros: *std.StringHashMap(MacroDef),
) !void {
    for (defs) |cached| {
        if (macros.contains(cached.name)) {
            continue;
        }

        const owned_body_lines = try allocator.alloc(SourceLine, cached.body_lines.len);
        errdefer allocator.free(owned_body_lines);
        var copied_body_lines: usize = 0;
        errdefer deinitOwnedSourceLineItems(allocator, owned_body_lines[0..copied_body_lines]);
        for (cached.body_lines, 0..) |line, idx| {
            const owned_text = try allocator.dupe(u8, line.text);
            errdefer allocator.free(owned_text);
            const owned_identity = if (line.package_identity) |identity| try allocator.dupe(u8, identity) else null;
            errdefer if (owned_identity) |identity| allocator.free(identity);
            owned_body_lines[idx] = .{
                .line_no = line.line_no,
                .text = owned_text,
                .classified = classifier.classifyLine(owned_text),
                .package_identity = owned_identity,
                .package_source_sha256 = line.package_source_sha256,
            };
            copied_body_lines += 1;
        }

        const owned_name = try allocator.dupe(u8, cached.name);
        errdefer allocator.free(owned_name);
        const owned_params = try allocator.alloc([]const u8, cached.params.len);
        errdefer allocator.free(owned_params);
        var copied_params: usize = 0;
        errdefer {
            for (owned_params[0..copied_params]) |param| allocator.free(param);
        }
        for (cached.params, 0..) |param, idx| {
            owned_params[idx] = try allocator.dupe(u8, param);
            copied_params += 1;
        }
        const owned_variadic_param = if (cached.variadic_param) |param| try allocator.dupe(u8, param) else null;
        errdefer if (owned_variadic_param) |param| allocator.free(param);

        try macros.put(owned_name, .{
            .params = owned_params,
            .variadic_param = owned_variadic_param,
            .body_start = 0,
            .body_end = owned_body_lines.len,
            .owned_body_lines = owned_body_lines,
            .owned_name = owned_name,
            .owned_params = owned_params,
            .owned_variadic_param = owned_variadic_param,
        });
    }
}

fn renderWithReplacements(
    allocator: std.mem.Allocator,
    text: []const u8,
    replacements: []const Replacement,
) ![]const u8 {
    if (replacements.len == 0) {
        return try allocator.dupe(u8, text);
    }

    var current = try allocator.dupe(u8, text);
    errdefer allocator.free(current);

    for (replacements) |replacement| {
        if (replacement.needle.len == 0) continue;
        const next = try std.mem.replaceOwned(u8, allocator, current, replacement.needle, replacement.replacement);
        allocator.free(current);
        current = next;
    }

    return current;
}

fn renderWithTokenReplacements(
    allocator: std.mem.Allocator,
    text: []const u8,
    replacements: []const Replacement,
) ![]const u8 {
    if (replacements.len == 0) {
        return try allocator.dupe(u8, text);
    }

    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        // String literal: copy until closing quote
        if (c == '"') {
            try result.append(c);
            i += 1;
            while (i < text.len and text[i] != '"') {
                try result.append(text[i]);
                i += 1;
            }
            if (i < text.len) {
                try result.append(text[i]); // closing quote
                i += 1;
            }
            continue;
        }

        // Line comment: copy to end
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len) {
                try result.append(text[i]);
                i += 1;
            }
            continue;
        }

        // @ and # prefixed identifiers: always copy as-is (function names, defs)
        if (c == '@' or c == '#') {
            try result.append(c);
            i += 1;
            while (i < text.len and isIdentChar(text[i])) {
                try result.append(text[i]);
                i += 1;
            }
            continue;
        }

        // % prefixed identifiers: collect full token and check for replacement
        if (c == '%') {
            const token_start = i;
            i += 1;
            while (i < text.len and isIdentChar(text[i])) {
                i += 1;
            }
            const token = text[token_start..i]; // e.g. %name_SIZE
            var found = false;
            for (replacements) |r| {
                if (std.mem.eql(u8, r.needle, token)) {
                    // Exact match: replace entire token
                    try result.appendSlice(r.replacement);
                    found = true;
                    break;
                }
            }
            if (!found) {
                // Try prefix match: needle like %name matches %name_SIZE
                for (replacements) |r| {
                    if (r.needle.len > 0 and r.needle[0] == '%' and
                        r.needle.len < token.len and
                        std.mem.eql(u8, r.needle, token[0..r.needle.len]))
                    {
                        try result.appendSlice(r.replacement);
                        try result.appendSlice(token[r.needle.len..]);
                        found = true;
                        break;
                    }
                }
            }
            if (!found) {
                try result.appendSlice(token);
            }
            continue;
        }

        // Identifier: collect and try replacement
        if (isIdentStart(c)) {
            const ident_start = i;
            while (i < text.len and isIdentChar(text[i])) {
                i += 1;
            }
            const ident = text[ident_start..i];

            var found = false;
            for (replacements) |r| {
                if (std.mem.eql(u8, r.needle, ident)) {
                    try result.appendSlice(r.replacement);
                    found = true;
                    break;
                }
            }
            if (!found) {
                try result.appendSlice(ident);
            }
            continue;
        }

        // Other characters: copy as-is
        try result.append(c);
        i += 1;
    }

    return result.toOwnedSlice();
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn collectDefinedNames(
    allocator: std.mem.Allocator,
    lines: []const SourceLine,
    start: usize,
    end: usize,
) !std.StringHashMap(void) {
    var names = std.StringHashMap(void).init(allocator);

    for (start..end) |idx| {
        const line = lines[idx];
        switch (line.classified.kind) {
            .label => {
                const name = line.classified.parts[0];
                if (std.mem.startsWith(u8, name, "L_")) {
                    try names.put(name, {});
                }
            },
            .instruction => {
                const form = line.classified.inst_form orelse continue;
                const should_collect = switch (form) {
                    .alloc, .stack_alloc, .load, .borrow, .move_, .assign, .op, .ptr_add, .call, .call_indirect, .try_, .cmpxchg, .atomic_load, .atomic_rmw, .fence, .raw_cast, .assume_safe, .assume_borrow => true,
                    else => false,
                };
                if (should_collect) {
                    const name = line.classified.parts[0];
                    if (name.len > 0 and name[0] == '_') {
                        try names.put(name, {});
                    }
                }
            },
            else => {},
        }
    }

    return names;
}

fn collectDefinedNamesFromSlice(
    allocator: std.mem.Allocator,
    lines: []const SourceLine,
) !std.StringHashMap(void) {
    return collectDefinedNames(allocator, lines, 0, lines.len);
}

fn buildHygieneReplacements(
    allocator: std.mem.Allocator,
    defined_names: *std.StringHashMap(void),
    expansion_id: u64,
) !std.array_list.Managed(Replacement) {
    var replacements = std.array_list.Managed(Replacement).init(allocator);
    errdefer replacements.deinit();

    var it = defined_names.keyIterator();
    while (it.next()) |name_ptr| {
        const name = name_ptr.*;
        const replacement_text = try std.fmt.allocPrint(allocator, "{s}__sa_hyg{d}", .{ name, expansion_id });
        errdefer allocator.free(replacement_text);
        try replacements.append(.{ .needle = name, .replacement = replacement_text });
    }

    return replacements;
}

fn ownText(
    allocator: std.mem.Allocator,
    owned_text: *std.array_list.Managed([]const u8),
    text: []const u8,
) ![]const u8 {
    const dup = try allocator.dupe(u8, text);
    errdefer allocator.free(dup);
    try owned_text.append(dup);
    return dup;
}

fn ownFoldedText(
    allocator: std.mem.Allocator,
    dict: *DefDict,
    owned_text: *std.array_list.Managed([]const u8),
    text: []const u8,
) ![]const u8 {
    const folded = try dict.foldText(allocator, text);
    errdefer allocator.free(folded);
    try owned_text.append(folded);
    return folded;
}

fn stripLeadingPlus(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len > 0 and trimmed[0] == '+') {
        return std.mem.trimStart(u8, trimmed[1..], " \t");
    }
    return trimmed;
}

fn parseIntAllowLeadingPlus(comptime T: type, text: []const u8) !T {
    const normalized = stripLeadingPlus(text);
    return std.fmt.parseInt(T, normalized, 10) catch |err| {
        return err;
    };
}

fn parseLayoutOffset(
    allocator: std.mem.Allocator,
    dict: *DefDict,
    owned_text: *std.array_list.Managed([]const u8),
    current_package_identity: ?[]const u8,
    text: []const u8,
) !u64 {
    const folded = try ownFoldedText(allocator, dict, owned_text, text);
    if (parseIntAllowLeadingPlus(u64, folded)) |value| {
        return value;
    } else |err| switch (err) {
        error.InvalidCharacter => {},
        else => return err,
    }

    if (dict.get(folded)) |value_text| {
        return try parseIntAllowLeadingPlus(u64, value_text);
    }

    if (current_package_identity) |identity| {
        const prefix = try packageNamespacePrefix(allocator, identity);
        defer allocator.free(prefix);

        const qualified = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, folded });
        defer allocator.free(qualified);

        if (dict.get(qualified)) |value_text| {
            return try parseIntAllowLeadingPlus(u64, value_text);
        }
    }

    var it = dict.entries.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.endsWith(u8, key, folded) and key.len > folded.len) {
            const separator = key[key.len - folded.len - 1];
            if (separator != '.' and separator != '_') continue;
            return try parseIntAllowLeadingPlus(u64, entry.value_ptr.*);
        }
    }

    std.debug.print("\nparseLayoutOffset failed for folded: '{s}' (text: '{s}')\nAvailable keys in dict:\n", .{ folded, text });
    var it_keys = dict.entries.iterator();
    while (it_keys.next()) |entry| {
        std.debug.print("  - '{s}': '{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    return error.InvalidSyntax;
}

fn parseNumericOperand(text: []const u8) ?common_instruction.Operand {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;

    if (std.fmt.parseInt(i64, trimmed, 10)) |value| {
        return .{ .imm_i64 = value };
    } else |err| switch (err) {
        error.Overflow => {
            if (std.fmt.parseInt(u64, trimmed, 10)) |value| {
                return .{ .imm_u64 = value };
            } else |_| {}
        },
        error.InvalidCharacter => {
            const no_plus = stripLeadingPlus(trimmed);
            if (no_plus.len != trimmed.len) {
                if (std.fmt.parseInt(i64, no_plus, 10)) |value| {
                    return .{ .imm_i64 = value };
                } else |retry_err| switch (retry_err) {
                    error.Overflow => {
                        if (std.fmt.parseInt(u64, no_plus, 10)) |value| {
                            return .{ .imm_u64 = value };
                        } else |_| {}
                    },
                    else => {},
                }
            }
        },
    }

    if (std.mem.indexOfAny(u8, trimmed, ".eE")) |_| {
        if (std.fmt.parseFloat(f64, trimmed)) |value| {
            return .{ .imm_float = value };
        } else |_| {}
    }

    return null;
}

fn parseSizeOperand(text: []const u8) ?common_instruction.Operand {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;

    if (std.fmt.parseInt(i64, trimmed, 10)) |value| {
        if (value >= 0) {
            return .{ .imm_u64 = @as(u64, @intCast(value)) };
        }
        return .{ .imm_i64 = value };
    } else |err| switch (err) {
        error.Overflow => {
            if (std.fmt.parseInt(u64, trimmed, 10)) |value| {
                return .{ .imm_u64 = value };
            } else |_| {}
        },
        error.InvalidCharacter => {
            const no_plus = stripLeadingPlus(trimmed);
            if (no_plus.len != trimmed.len) {
                if (std.fmt.parseInt(i64, no_plus, 10)) |value| {
                    if (value >= 0) {
                        return .{ .imm_u64 = @as(u64, @intCast(value)) };
                    }
                    return .{ .imm_i64 = value };
                } else |retry_err| switch (retry_err) {
                    error.Overflow => {
                        if (std.fmt.parseInt(u64, no_plus, 10)) |value| {
                            return .{ .imm_u64 = value };
                        } else |_| {}
                    },
                    else => {},
                }
            }
        },
    }

    return null;
}

fn resolveOperandText(
    allocator: std.mem.Allocator,
    dict: *DefDict,
    owned_text: *std.array_list.Managed([]const u8),
    symbols: *SymbolTable,
    text: []const u8,
) !common_instruction.Operand {
    const folded = try ownFoldedText(allocator, dict, owned_text, text);
    if (parseNumericOperand(folded)) |operand| return operand;
    return .{ .reg = try symbols.intern(folded) };
}

fn resolveSizeOperandText(
    allocator: std.mem.Allocator,
    dict: *DefDict,
    owned_text: *std.array_list.Managed([]const u8),
    symbols: *SymbolTable,
    text: []const u8,
) !common_instruction.Operand {
    const folded = try ownFoldedText(allocator, dict, owned_text, text);
    if (parseSizeOperand(folded)) |operand| return operand;
    if (symbols.findId(folded)) |id| {
        return .{ .reg = id };
    }
    return .{ .reg = try symbols.intern(folded) };
}

fn consumePendingLoc(
    loc_table: *std.array_list.Managed(?common_upstream.UpstreamLoc),
    pending_loc: *?common_upstream.UpstreamLoc,
) !?common_upstream.UpstreamLoc {
    const loc = pending_loc.*;
    try loc_table.append(loc);
    pending_loc.* = null;
    return loc;
}

fn takePendingLoc(
    pending_loc: *?common_upstream.UpstreamLoc,
) ?common_upstream.UpstreamLoc {
    const loc = pending_loc.*;
    pending_loc.* = null;
    return loc;
}

fn appendNullLoc(loc_table: *std.array_list.Managed(?common_upstream.UpstreamLoc)) !void {
    try loc_table.append(null);
}

fn setPendingLoc(
    allocator: std.mem.Allocator,
    pending_loc: *?common_upstream.UpstreamLoc,
    file: []const u8,
    line: u32,
    col: u32,
) !void {
    if (line == 0 or col == 0) return error.InvalidLocHint;
    if (pending_loc.*) |current| {
        allocator.free(current.file);
        pending_loc.* = null;
    }
    const file_copy = try allocator.dupe(u8, file);
    pending_loc.* = .{
        .file = file_copy,
        .line = line,
        .col = col,
    };
}

fn recordLayoutVersion(
    allocator: std.mem.Allocator,
    layout_versions: *std.array_list.Managed(LayoutVersion),
    path: []const u8,
    source: []const u8,
) !void {
    var iterator = std.mem.splitScalar(u8, source, '\n');
    while (iterator.next()) |raw_line| {
        const classified = classifier.classifyLine(raw_line);
        if (classified.kind != .version) continue;

        const version = std.fmt.parseInt(u64, classified.parts[0], 10) catch return error.InvalidSyntax;
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);
        try layout_versions.append(.{
            .path = path_copy,
            .version = version,
        });
        return;
    }
}

fn findBlockEnd(lines: []const SourceLine, start: usize, close_kind: LineKind) ?usize {
    var idx = start;
    while (idx < lines.len) : (idx += 1) {
        if (lines[idx].classified.kind == close_kind) return idx;
    }
    return null;
}

fn findNestedRepEnd(lines: []const SourceLine, start: usize) ?usize {
    var depth: usize = 1;
    var idx = start;
    while (idx < lines.len) : (idx += 1) {
        switch (lines[idx].classified.kind) {
            .rep_start => depth += 1,
            .rep_end => {
                depth -= 1;
                if (depth == 0) return idx;
            },
            else => {},
        }
    }
    return null;
}

const IfBounds = struct {
    else_idx: ?usize,
    end_idx: usize,
};

fn findNestedIfBounds(lines: []const SourceLine, start: usize) ?IfBounds {
    var depth: usize = 1;
    var else_idx: ?usize = null;
    var idx = start;
    while (idx < lines.len) : (idx += 1) {
        switch (lines[idx].classified.kind) {
            .if_start => depth += 1,
            .else_ => {
                if (depth == 1 and else_idx == null) else_idx = idx;
            },
            .if_end => {
                depth -= 1;
                if (depth == 0) return .{ .else_idx = else_idx, .end_idx = idx };
            },
            else => {},
        }
    }
    return null;
}

fn macroConditionIsTrue(text: []const u8) !bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "1") or std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "yes") or std.mem.eql(u8, trimmed, "on")) return true;
    if (std.mem.eql(u8, trimmed, "0") or std.mem.eql(u8, trimmed, "false") or std.mem.eql(u8, trimmed, "no") or std.mem.eql(u8, trimmed, "off")) return false;
    return error.InvalidMacroInvocation;
}

fn mapInstKind(form: InstructionForm) InstKind {
    return switch (form) {
        .alloc => .alloc,
        .stack_alloc => .stack_alloc,
        .load => .load,
        .store => .store,
        .atomic_load => .atomic_load,
        .atomic_store => .atomic_store,
        .cmpxchg => .cmpxchg,
        .atomic_rmw => .atomic_rmw,
        .fence => .fence,
        .borrow => .borrow,
        .move_ => .move_,
        .release => .release,
        .assign => .assign,
        .op => .op,
        .ptr_add => .ptr_add,
        .jmp => .jmp,
        .br => .br,
        .br_null => .br_null,
        .call => .call,
        .call_indirect => .call_indirect,
        .try_ => .early_return,
        .panic => .panic,
        .panic_msg => .panic_msg,
        .return_ => .return_,
        .take => .take,
        .raw_cast => .raw_cast,
        .assume_safe => .assume_safe,
        .assume_borrow => .assume_borrow,
        .unknown => .native,
    };
}

fn parseFunctionSigForKind(
    allocator: std.mem.Allocator,
    raw_line: []const u8,
    id: u32,
    entry_idx: u32,
    kind: FunctionKind,
    symbols: *SymbolTable,
) !FunctionSig {
    var sig = try common_signature.parseFunctionHeader(allocator, raw_line, id, entry_idx, kind);
    errdefer sig.deinit(allocator);
    if (sig.params.len == 0) {
        sig.param_ids = &.{};
        return sig;
    }
    const ids = try allocator.alloc(u32, sig.params.len);
    errdefer allocator.free(ids);
    for (sig.params, 0..) |param, idx| {
        ids[idx] = try symbols.intern(param.name);
    }
    sig.param_ids = ids;
    return sig;
}

fn emitParsedLine(
    allocator: std.mem.Allocator,
    dict: *DefDict,
    symbols: *SymbolTable,
    loc_table: *std.array_list.Managed(?common_upstream.UpstreamLoc),
    pending_loc: *?common_upstream.UpstreamLoc,
    raw_line: []const u8,
    source_line: u32,
    instructions: *std.array_list.Managed(Instruction),
    const_decls: *std.array_list.Managed(ConstDecl),
    function_sigs: *std.array_list.Managed(FunctionSig),
    owned_text: *std.array_list.Managed([]const u8),
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
) !void {
    if (instructions.items.len >= max_expanded_instructions) return error.MacroExpansionBudget;
    const classified = classifier.classifyLine(raw_line);
    switch (classified.kind) {
        .blank_or_comment, .version => {},
        .import_decl => {},
        .const_decl => {
            const upstream_loc = takePendingLoc(pending_loc);
            errdefer if (upstream_loc) |loc| allocator.free(loc.file);
            var decl = try common_const_decl.parseConstDecl(
                allocator,
                raw_line,
                source_line,
                @intCast(instructions.items.len),
                upstream_loc,
            );
            errdefer decl.deinit(allocator);
            _ = try symbols.intern(decl.name);
            try const_decls.append(decl);
        },
        .loc_hint => {
            const line_no = try std.fmt.parseInt(u32, classified.parts[1], 10);
            const col_no = try std.fmt.parseInt(u32, classified.parts[2], 10);
            try setPendingLoc(allocator, pending_loc, classified.parts[0], line_no, col_no);
        },
        .def => try dict.putExpression(classified.parts[0], classified.parts[1]),
        .npm_bind => try dict.putNpmBind(classified.parts[0], classified.parts[1]),
        .native => {
            const inst_loc = try consumePendingLoc(loc_table, pending_loc);
            const raw_copy = try ownText(allocator, owned_text, raw_line);
            const native_copy = try ownText(allocator, owned_text, classified.parts[0]);
            const native_reg_names = try classifier.collectNativeRegisterNames(allocator, native_copy);
            var inst = common_instruction.makeInstruction(.native, source_line, @intCast(instructions.items.len), inst_loc, raw_copy);
            inst.operands[0] = .{ .native_text = native_copy };
            inst.native_reg_names = native_reg_names;
            try instructions.append(inst);
        },
        .label => {
            const label_name = try ownFoldedText(allocator, dict, owned_text, classified.parts[0]);
            try appendNullLoc(loc_table);
            const label_id = try symbols.intern(label_name);
            const raw_copy = try ownText(allocator, owned_text, raw_line);
            var inst = common_instruction.makeInstruction(.label, source_line, @intCast(instructions.items.len), null, raw_copy);
            inst.operands[0] = .{ .symbol = label_id };
            inst.operands[1] = .{ .label = label_id };
            try instructions.append(inst);
        },
        .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
            const kind = switch (classified.kind) {
                .func_decl => FunctionKind.normal,
                .ffi_wrapper_decl => FunctionKind.ffi_wrapper,
                .extern_decl => FunctionKind.external,
                .export_decl => FunctionKind.exported,
                .test_decl => FunctionKind.test_func,
                else => FunctionKind.normal,
            };
            var sig = try parseFunctionSigForKind(
                allocator,
                raw_line,
                @intCast(function_sigs.items.len),
                @intCast(instructions.items.len),
                kind,
                symbols,
            );
            errdefer sig.deinit(allocator);
            var inst_loc: ?common_upstream.UpstreamLoc = null;
            if (pending_loc.*) |loc| {
                const sig_file_copy = try allocator.dupe(u8, loc.file);
                errdefer allocator.free(sig_file_copy);
                const inst_file_copy = try allocator.dupe(u8, loc.file);
                errdefer allocator.free(inst_file_copy);
                sig.upstream_file = sig_file_copy;
                sig.upstream_loc = .{
                    .file = sig_file_copy,
                    .line = loc.line,
                    .col = loc.col,
                };
                inst_loc = .{
                    .file = inst_file_copy,
                    .line = loc.line,
                    .col = loc.col,
                };
            }
            const name_id = try symbols.intern(sig.name);
            const inst_kind: InstKind = switch (kind) {
                .normal => .func_decl,
                .ffi_wrapper => .ffi_wrapper_decl,
                .external => .extern_decl,
                .exported => .export_decl,
                .test_func => .test_decl,
            };
            try appendNullLoc(loc_table);
            const raw_copy = try ownFoldedText(allocator, dict, owned_text, raw_line);
            var inst = common_instruction.makeInstruction(inst_kind, source_line, @intCast(instructions.items.len), inst_loc, raw_copy);
            if (current_package_identity) |identity| {
                inst.package_identity = try allocator.dupe(u8, identity);
            }
            inst.package_source_sha256 = current_package_hash;
            inst.operands[0] = .{ .symbol = name_id };
            inst.operands[1] = .{ .func = name_id };
            try instructions.append(inst);
            try function_sigs.append(sig);
        },
        .instruction => {
            const inst_kind = mapInstKind(classified.inst_form.?);
            const inst_loc = try consumePendingLoc(loc_table, pending_loc);
            const raw_copy = try ownFoldedText(allocator, dict, owned_text, raw_line);
            var inst = common_instruction.makeInstruction(inst_kind, source_line, @intCast(instructions.items.len), inst_loc, raw_copy);
            if (current_package_identity) |identity| {
                inst.package_identity = try allocator.dupe(u8, identity);
            }
            inst.package_source_sha256 = current_package_hash;
            switch (classified.inst_form.?) {
                .alloc => {
                    const dst = try symbols.intern(classified.parts[0]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = try resolveSizeOperandText(allocator, dict, owned_text, symbols, classified.parts[1]);
                    // sci-rust: explicit `mut x = alloc` marker survives via operands[2].
                    if (classified.part_count > 2 and std.mem.eql(u8, classified.parts[2], "mut")) {
                        inst.operands[2] = .{ .text = try ownFoldedText(allocator, dict, owned_text, "mut") };
                    }
                },
                .atomic_load => {
                    const parsed = atomic.parseLoad(raw_line) catch |err| switch (err) {
                        error.InvalidAtomicOrdering => return error.InvalidAtomicOrdering,
                        error.UnsupportedType => return error.UnsupportedType,
                        else => return error.InvalidSyntax,
                    };
                    const dst = try symbols.intern(parsed.dst);
                    const base = try symbols.intern(parsed.base);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = base };
                    const offset_text = try ownFoldedText(allocator, dict, owned_text, parsed.offset);
                    inst.operands[2] = .{ .imm_u64 = try parseLayoutOffset(allocator, dict, owned_text, current_package_identity, offset_text) };
                    inst.atomic_value_ty = if (parsed.ty) |ty| @intFromEnum(ty) else null;
                    inst.atomic_ordering = parsed.ordering;
                },
                .atomic_store => {
                    const parsed = atomic.parseStore(raw_line) catch |err| switch (err) {
                        error.InvalidAtomicOrdering => return error.InvalidAtomicOrdering,
                        error.UnsupportedType => return error.UnsupportedType,
                        else => return error.InvalidSyntax,
                    };
                    const base = try symbols.intern(parsed.base);
                    inst.operands[0] = .{ .reg = base };
                    const offset_text = try ownFoldedText(allocator, dict, owned_text, parsed.offset);
                    inst.operands[1] = .{ .imm_u64 = try parseIntAllowLeadingPlus(u64, offset_text) };
                    const value_text = try ownFoldedText(allocator, dict, owned_text, parsed.value);
                    inst.operands[2] = .{ .text = value_text };
                    inst.atomic_value_ty = if (parsed.ty) |ty| @intFromEnum(ty) else null;
                    inst.atomic_ordering = parsed.ordering;
                },
                .cmpxchg => {
                    const parsed = atomic.parseCmpxchg(raw_line) catch |err| switch (err) {
                        error.InvalidAtomicOrdering => return error.InvalidAtomicOrdering,
                        error.UnsupportedType => return error.UnsupportedType,
                        else => return error.InvalidSyntax,
                    };
                    const dst = try symbols.intern(parsed.dst);
                    const ok = try symbols.intern(parsed.ok);
                    const base = try symbols.intern(parsed.base);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = ok };
                    inst.operands[2] = .{ .reg = base };
                    const offset_text = try ownFoldedText(allocator, dict, owned_text, parsed.offset);
                    inst.operands[3] = .{ .imm_u64 = try parseLayoutOffset(allocator, dict, owned_text, current_package_identity, offset_text) };
                    inst.atomic_expected_text = try ownFoldedText(allocator, dict, owned_text, parsed.expected);
                    inst.atomic_new_text = try ownFoldedText(allocator, dict, owned_text, parsed.new_value);
                    inst.atomic_value_ty = if (parsed.ty) |ty| @intFromEnum(ty) else null;
                    inst.atomic_ordering = parsed.success_ordering;
                    inst.atomic_second_ordering = parsed.failure_ordering;
                },
                .atomic_rmw => {
                    const parsed = atomic.parseRmw(raw_line) catch |err| switch (err) {
                        error.InvalidAtomicOrdering => return error.InvalidAtomicOrdering,
                        error.UnsupportedType => return error.UnsupportedType,
                        else => return error.InvalidSyntax,
                    };
                    const dst = try symbols.intern(parsed.dst);
                    const base = try symbols.intern(parsed.base);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = base };
                    const offset_text = try ownFoldedText(allocator, dict, owned_text, parsed.offset);
                    inst.operands[2] = .{ .imm_u64 = try parseLayoutOffset(allocator, dict, owned_text, current_package_identity, offset_text) };
                    const value_text = try ownFoldedText(allocator, dict, owned_text, parsed.value);
                    inst.operands[3] = .{ .text = value_text };
                    inst.atomic_value_ty = if (parsed.ty) |ty| @intFromEnum(ty) else null;
                    inst.atomic_ordering = parsed.ordering;
                    inst.atomic_rmw_op = parsed.op;
                },
                .fence => {
                    const parsed = atomic.parseFence(raw_line) catch |err| switch (err) {
                        error.InvalidAtomicOrdering => return error.InvalidAtomicOrdering,
                        error.UnsupportedType => return error.UnsupportedType,
                        else => return error.InvalidSyntax,
                    };
                    inst.atomic_ordering = parsed.ordering;
                },
                .stack_alloc => {
                    const dst = try symbols.intern(classified.parts[0]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = try resolveSizeOperandText(allocator, dict, owned_text, symbols, classified.parts[1]);
                    if (classified.part_count > 2 and std.mem.eql(u8, classified.parts[2], "mut")) {
                        inst.operands[2] = .{ .text = try ownFoldedText(allocator, dict, owned_text, "mut") };
                    }
                },
                .load, .take => {
                    const dst = try symbols.intern(classified.parts[0]);
                    const base = try symbols.intern(classified.parts[1]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = base };
                    const offset_text = try ownFoldedText(allocator, dict, owned_text, classified.parts[2]);
                    inst.operands[2] = .{ .imm_u64 = try parseLayoutOffset(allocator, dict, owned_text, current_package_identity, offset_text) };
                    if (classified.part_count > 3) {
                        const ty = try common_signature.parsePrimType(classified.parts[3]);
                        inst.operands[3] = .{ .ty = @intFromEnum(ty) };
                    }
                },
                .borrow => {
                    const dst = try symbols.intern(classified.parts[0]);
                    const source = try symbols.intern(classified.parts[2]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = source };
                    inst.operands[2] = .{ .text = classified.parts[1] };
                    inst.operands[3] = .{ .cap_prefix = .borrow };
                },
                .move_ => {
                    const reg = try symbols.intern(classified.parts[0]);
                    inst.operands[0] = .{ .reg = reg };
                },
                .release => {
                    const reg = try symbols.intern(classified.parts[0]);
                    inst.operands[0] = .{ .reg = reg };
                },
                .assign => {
                    const dst = try symbols.intern(classified.parts[0]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = try resolveOperandText(allocator, dict, owned_text, symbols, classified.parts[1]);
                },
                .store => {
                    const base = try symbols.intern(classified.parts[0]);
                    inst.operands[0] = .{ .reg = base };
                    const offset_text = try ownFoldedText(allocator, dict, owned_text, classified.parts[1]);
                    inst.operands[1] = .{ .imm_u64 = try parseLayoutOffset(allocator, dict, owned_text, current_package_identity, offset_text) };
                    const value_text = try ownFoldedText(allocator, dict, owned_text, classified.parts[2]);
                    inst.operands[2] = .{ .text = value_text };
                    if (classified.part_count > 3) {
                        const ty = try common_signature.parsePrimType(classified.parts[3]);
                        inst.operands[3] = .{ .ty = @intFromEnum(ty) };
                    }
                },
                .op => {
                    const dst = try symbols.intern(classified.parts[0]);
                    const op_name = classified.parts[1];
                    const op_kind = common_instruction.parseOpKind(op_name) orelse return error.InvalidSyntax;
                    inst.operands[0] = .{ .reg = dst };
                    inst.op_kind = op_kind;

                    if (common_instruction.isTernaryOpKind(op_kind)) {
                        inst.operands[1] = try resolveOperandText(allocator, dict, owned_text, symbols, classified.parts[2]);
                        inst.operands[2] = try resolveOperandText(allocator, dict, owned_text, symbols, classified.parts[3]);
                        inst.operands[3] = try resolveOperandText(allocator, dict, owned_text, symbols, classified.parts[4]);
                    } else if (common_instruction.isUnaryOpKind(op_kind)) {
                        inst.operands[1] = try resolveOperandText(allocator, dict, owned_text, symbols, classified.parts[2]);
                        if (common_instruction.isTypeConversionOpKind(op_kind)) {
                            const target_ty: common_signature.PrimType = if (classified.part_count > 3 and classified.parts[3].len != 0)
                                try common_signature.parsePrimType(classified.parts[3])
                            else
                                .i32;
                            inst.operands[2] = .{ .ty = @intFromEnum(target_ty) };
                        }
                    } else if (common_instruction.isBinaryOpKind(op_kind)) {
                        inst.operands[1] = try resolveOperandText(allocator, dict, owned_text, symbols, classified.parts[2]);
                        inst.operands[2] = try resolveOperandText(allocator, dict, owned_text, symbols, classified.parts[3]);
                        if (op_kind == .extract_lane and classified.part_count > 4) {
                            inst.operands[3] = try resolveOperandText(allocator, dict, owned_text, symbols, classified.parts[4]);
                        }
                    } else {
                        return error.InvalidSyntax;
                    }
                },
                .ptr_add => {
                    const dst = try symbols.intern(classified.parts[0]);
                    const base = try symbols.intern(classified.parts[1]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = base };
                    const offset_text = try ownFoldedText(allocator, dict, owned_text, classified.parts[2]);
                    if (std.fmt.parseInt(i64, stripLeadingPlus(offset_text), 10)) |offset| {
                        inst.operands[2] = .{ .imm_i64 = offset };
                    } else |err| switch (err) {
                        error.Overflow => return error.InvalidSyntax,
                        else => {
                            if (symbols.findId(offset_text)) |off_reg| {
                                inst.operands[2] = .{ .reg = off_reg };
                            } else {
                                inst.operands[2] = .{ .text = offset_text };
                            }
                        },
                    }
                },
                .jmp => {
                    const target_text = try dict.foldText(allocator, classified.parts[0]);
                    try owned_text.append(target_text);
                    inst.operands[0] = .{ .symbol = try symbols.intern(target_text) };
                    inst.operands[1] = .{ .label = try symbols.intern(target_text) };
                },
                .br => {
                    const cond_text = try dict.foldText(allocator, classified.parts[0]);
                    try owned_text.append(cond_text);
                    inst.operands[0] = .{ .reg = try symbols.intern(cond_text) };

                    const true_text = try dict.foldText(allocator, classified.parts[1]);
                    try owned_text.append(true_text);
                    inst.operands[1] = .{ .label = try symbols.intern(true_text) };
                    inst.operands[2] = .{ .label = try symbols.intern(true_text) };

                    const false_text = try dict.foldText(allocator, classified.parts[2]);
                    try owned_text.append(false_text);
                    inst.operands[3] = .{ .label = try symbols.intern(false_text) };
                },
                .br_null => {
                    const reg_text = try dict.foldText(allocator, classified.parts[0]);
                    try owned_text.append(reg_text);
                    inst.operands[0] = .{ .reg = try symbols.intern(reg_text) };

                    const null_text = try dict.foldText(allocator, classified.parts[1]);
                    try owned_text.append(null_text);
                    inst.operands[1] = .{ .label = try symbols.intern(null_text) };
                    inst.operands[2] = .{ .label = try symbols.intern(null_text) };

                    const not_null_text = try dict.foldText(allocator, classified.parts[2]);
                    try owned_text.append(not_null_text);
                    inst.operands[3] = .{ .label = try symbols.intern(not_null_text) };
                },
                .call, .call_indirect, .try_, .panic, .panic_msg, .return_ => {
                    if (classified.inst_form == .return_ and classified.part_count == 1) {
                        const folded = try ownFoldedText(allocator, dict, owned_text, classified.parts[0]);
                        if (symbols.findId(folded)) |id| {
                            inst.operands[0] = .{ .reg = id };
                        } else {
                            inst.operands[0] = .{ .text = folded };
                        }
                    } else if (classified.inst_form == .try_) {
                        const dst = try symbols.intern(classified.parts[0]);
                        const source = try symbols.intern(classified.parts[1]);
                        inst.operands[0] = .{ .reg = dst };
                        inst.operands[1] = .{ .reg = source };
                    } else if (classified.part_count == 2) {
                        const dst = try symbols.intern(classified.parts[0]);
                        inst.operands[0] = .{ .reg = dst };
                        const folded = try ownFoldedText(allocator, dict, owned_text, classified.parts[1]);
                        inst.operands[1] = .{ .text = folded };
                    } else {
                        for (classified.parts[0..classified.part_count], 0..) |part, idx| {
                            const folded = try ownFoldedText(allocator, dict, owned_text, part);
                            inst.operands[idx] = .{ .text = folded };
                        }
                    }
                },
                .raw_cast => {
                    const dst = try symbols.intern(classified.parts[0]);
                    const source = try symbols.intern(classified.parts[1]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = source };
                },
                .assume_safe => {
                    const dst = try symbols.intern(classified.parts[0]);
                    const source = try symbols.intern(classified.parts[1]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = source };
                },
                .assume_borrow => {
                    const dst = try symbols.intern(classified.parts[0]);
                    const source = try symbols.intern(classified.parts[1]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = source };
                    if (classified.part_count > 2) {
                        const mode = try ownText(allocator, owned_text, classified.parts[2]);
                        inst.operands[2] = .{ .text = mode };
                    }
                },
                .unknown => {
                    std.debug.print("\n=== INVALID SYNTAX: .unknown inst at line {d}: '{s}' ===\n", .{ source_line, raw_line });
                    return error.InvalidSyntax;
                },
            }
            try instructions.append(inst);
        },
        .unknown => {
            std.debug.print("\n=== INVALID SYNTAX: .unknown line kind at line {d}: '{s}' ===\n", .{ source_line, raw_line });
            return error.InvalidSyntax;
        },
        .macro_start, .macro_end, .rep_start, .rep_end, .if_start, .else_, .if_end, .expand => return error.InvalidSyntax,
    }
}

fn includeFileAsConst(
    allocator: std.mem.Allocator,
    kind: enum { str, bytes },
    args: []const u8,
    source_line: u32,
    source_path: ?[]const u8,
    dict: *DefDict,
    symbols: *SymbolTable,
    loc_table: *std.array_list.Managed(?common_upstream.UpstreamLoc),
    pending_loc: *?common_upstream.UpstreamLoc,
    instructions: *std.array_list.Managed(Instruction),
    const_decls: *std.array_list.Managed(ConstDecl),
    function_sigs: *std.array_list.Managed(FunctionSig),
    owned_text: *std.array_list.Managed([]const u8),
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
) !void {
    const path_arg = std.mem.trim(u8, args, " \t\r\n");
    if (path_arg.len == 0) return error.InvalidMacroInvocation;

    const include_path_raw = try unquoteString(allocator, path_arg);
    defer allocator.free(include_path_raw);

    const resolved_path = if (std.fs.path.isAbsolute(include_path_raw))
        try allocator.dupe(u8, include_path_raw)
    else if (source_path) |sp| blk: {
        const base = std.fs.path.dirname(sp) orelse ".";
        break :blk try std.fs.path.join(allocator, &.{ base, include_path_raw });
    } else try allocator.dupe(u8, include_path_raw);
    defer allocator.free(resolved_path);

    const file = try sio.cwd().openFile(resolved_path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(bytes);

    const const_name = try std.fmt.allocPrint(allocator, "__INCLUDE_{d}_{d}", .{ source_line, const_decls.items.len });
    defer allocator.free(const_name);

    var hex: ?std.array_list.Managed(u8) = null;
    const literal_line = switch (kind) {
        .str => try std.fmt.allocPrint(allocator, "@const {s} = utf8:\"{s}\"", .{ const_name, bytes }),
        .bytes => blk: {
            hex = std.array_list.Managed(u8).init(allocator);
            try hex.?.appendSlice("hex:");
            for (bytes) |b| {
                var hex_byte_buf: [4]u8 = undefined;
                try hex.?.appendSlice(try std.fmt.bufPrint(&hex_byte_buf, "\\x{X:0>2}", .{b}));
            }
            break :blk try std.fmt.allocPrint(allocator, "@const {s} = {s}", .{ const_name, hex.?.items });
        },
    };
    defer allocator.free(literal_line);

    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, literal_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    if (hex) |*h| h.deinit();
}

fn utf8ConstLine(allocator: std.mem.Allocator, name: []const u8, bytes: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("@const {s} = utf8:", .{name});
    try std.json.Stringify.value(bytes, .{}, &aw.writer);
    return try aw.toOwnedSlice();
}

fn expandSourceLocationMacro(
    allocator: std.mem.Allocator,
    macro_name: []const u8,
    args_text: []const u8,
    source_line: u32,
    source_path: ?[]const u8,
    dict: *DefDict,
    symbols: *SymbolTable,
    loc_table: *std.array_list.Managed(?common_upstream.UpstreamLoc),
    pending_loc: *?common_upstream.UpstreamLoc,
    instructions: *std.array_list.Managed(Instruction),
    const_decls: *std.array_list.Managed(ConstDecl),
    function_sigs: *std.array_list.Managed(FunctionSig),
    owned_text: *std.array_list.Managed([]const u8),
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
) !void {
    const out_reg = std.mem.trim(u8, args_text, " \t\r\n");
    if (out_reg.len == 0) return error.InvalidMacroInvocation;

    const loc = if (pending_loc.*) |item|
        item
    else if (loc_table.items.len != 0) blk: {
        if (loc_table.items[loc_table.items.len - 1]) |item| break :blk item;
        if (source_path) |sp| {
            break :blk common_upstream.UpstreamLoc{ .file = sp, .line = source_line, .col = 1 };
        }
        break :blk common_upstream.UpstreamLoc{ .file = "<unknown>", .line = source_line, .col = 1 };
    } else if (source_path) |sp|
        common_upstream.UpstreamLoc{ .file = sp, .line = source_line, .col = 1 }
    else
        common_upstream.UpstreamLoc{ .file = "<unknown>", .line = source_line, .col = 1 };

    if (std.mem.eql(u8, macro_name, "LINE!")) {
        const line_line = try std.fmt.allocPrint(allocator, "{s} = add 0, {d}", .{ out_reg, loc.line });
        defer allocator.free(line_line);
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, line_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
        return;
    }

    if (std.mem.eql(u8, macro_name, "COLUMN!")) {
        const col_line = try std.fmt.allocPrint(allocator, "{s} = add 0, {d}", .{ out_reg, loc.col });
        defer allocator.free(col_line);
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, col_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
        return;
    }

    if (std.mem.eql(u8, macro_name, "FILE!")) {
        const const_name = try std.fmt.allocPrint(allocator, "__SOURCE_FILE_{d}_{d}", .{ source_line, const_decls.items.len });
        defer allocator.free(const_name);

        const file_text = source_path orelse loc.file;
        const const_line = try utf8ConstLine(allocator, const_name, file_text);
        defer allocator.free(const_line);
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, const_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

        const ptr_line = try std.fmt.allocPrint(allocator, "{s} = add 0, 0", .{out_reg});
        defer allocator.free(ptr_line);
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, ptr_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

        const assign_line = try std.fmt.allocPrint(allocator, "{s} = ^{s}", .{ out_reg, const_name });
        defer allocator.free(assign_line);
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, assign_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
        return;
    }

    if (std.mem.eql(u8, macro_name, "MODULE_PATH!")) {
        const module_path = source_path orelse loc.file;
        const const_name = try std.fmt.allocPrint(allocator, "__MODULE_PATH_{d}_{d}", .{ source_line, const_decls.items.len });
        defer allocator.free(const_name);

        const const_line = try utf8ConstLine(allocator, const_name, module_path);
        defer allocator.free(const_line);
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, const_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

        const assign_line = try std.fmt.allocPrint(allocator, "{s} = ^{s}", .{ out_reg, const_name });
        defer allocator.free(assign_line);
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, assign_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
        return;
    }

    return error.InvalidMacroInvocation;
}

fn collectMacroDefinitions(
    allocator: std.mem.Allocator,
    lines: []const SourceLine,
    macros: *std.StringHashMap(MacroDef),
    error_ctx: ?*ErrorContext,
) !void {
    var idx: usize = 0;
    while (idx < lines.len) : (idx += 1) {
        const line = lines[idx];
        recordErrorSourceLine(error_ctx, line.line_no);
        switch (line.classified.kind) {
            .blank_or_comment, .def, .npm_bind, .const_decl, .import_decl, .version, .loc_hint, .native, .label, .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl, .instruction, .unknown, .expand, .rep_start, .rep_end, .if_start, .else_, .if_end, .macro_end => {},
            .macro_start => {
                const end = findBlockEnd(lines, idx + 1, .macro_end) orelse return error.UnbalancedMacro;
                const name = line.classified.parts[0];
                const parsed_params = try parseMacroParams(allocator, line.classified.parts[1]);
                errdefer allocator.free(parsed_params.params);
                if (macros.contains(name)) return error.DuplicateDef;
                const owned_body_lines = try cloneOwnedSourceLines(allocator, lines[idx + 1 .. end]);
                errdefer deinitOwnedSourceLines(allocator, owned_body_lines);
                try macros.put(name, .{
                    .params = parsed_params.params,
                    .variadic_param = parsed_params.variadic_param,
                    .body_start = idx + 1,
                    .body_end = end,
                    .owned_body_lines = owned_body_lines,
                });
                idx = end;
            },
        }
    }
}

fn isFunctionSigDeclared(sigs: []const FunctionSig, name: []const u8) bool {
    for (sigs) |sig| {
        if (std.mem.eql(u8, sig.name, name)) return true;
    }
    return false;
}

fn parsePrintArgs(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var args = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit();
    }

    var i: usize = 0;
    var start: usize = 0;
    var in_quotes: bool = false;
    var escaped: bool = false;

    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_quotes) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_quotes = false;
            }
        } else {
            if (c == '"') {
                in_quotes = true;
            } else if (c == ',') {
                const arg = std.mem.trim(u8, text[start..i], " \t\r\n");
                if (arg.len > 0) {
                    const arg_dup = try allocator.dupe(u8, arg);
                    try args.append(arg_dup);
                }
                start = i + 1;
            }
        }
    }

    const arg = std.mem.trim(u8, text[start..], " \t\r\n");
    if (arg.len > 0) {
        const arg_dup = try allocator.dupe(u8, arg);
        try args.append(arg_dup);
    }
    return try args.toOwnedSlice();
}

fn unquoteString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var raw = text;
    if (std.mem.startsWith(u8, raw, "utf8:\"") and std.mem.endsWith(u8, raw, "\"")) {
        raw = raw[5 .. raw.len - 1];
    } else if (std.mem.startsWith(u8, raw, "\"") and std.mem.endsWith(u8, raw, "\"")) {
        raw = raw[1 .. raw.len - 1];
    } else {
        return error.InvalidFormatString;
    }
    return try allocator.dupe(u8, raw);
}

const FormatSegmentKind = enum {
    literal,
    placeholder,
};

const Specifier = enum {
    none,
    i64,
    u64,
    f64,
    bytes,
};

const FormatSegment = struct {
    kind: FormatSegmentKind,
    text: []const u8,
    specifier: Specifier,
};

fn parseFormatString(allocator: std.mem.Allocator, fmt_str: []const u8) ![]FormatSegment {
    var segments = std.array_list.Managed(FormatSegment).init(allocator);
    errdefer {
        for (segments.items) |seg| {
            if (seg.kind == .literal) allocator.free(seg.text);
        }
        segments.deinit();
    }

    var i: usize = 0;
    var start: usize = 0;
    while (i < fmt_str.len) {
        if (fmt_str[i] == '{') {
            if (i > start) {
                const lit_text = try allocator.dupe(u8, fmt_str[start..i]);
                try segments.append(.{
                    .kind = .literal,
                    .text = lit_text,
                    .specifier = .none,
                });
            }

            const close_idx = std.mem.indexOfScalar(u8, fmt_str[i..], '}') orelse return error.UnbalancedPlaceholder;
            const absolute_close = i + close_idx;
            const spec_text = fmt_str[i + 1 .. absolute_close];

            var spec = Specifier.none;
            if (spec_text.len == 0) {
                spec = .none;
            } else if (std.mem.eql(u8, spec_text, ":i") or std.mem.eql(u8, spec_text, ":d")) {
                spec = .i64;
            } else if (std.mem.eql(u8, spec_text, ":u")) {
                spec = .u64;
            } else if (std.mem.eql(u8, spec_text, ":f")) {
                spec = .f64;
            } else if (std.mem.eql(u8, spec_text, ":b") or std.mem.eql(u8, spec_text, ":s")) {
                spec = .bytes;
            } else {
                return error.InvalidSpecifier;
            }

            try segments.append(.{
                .kind = .placeholder,
                .text = &.{},
                .specifier = spec,
            });

            i = absolute_close + 1;
            start = i;
        } else {
            i += 1;
        }
    }

    if (start < fmt_str.len) {
        const lit_text = try allocator.dupe(u8, fmt_str[start..]);
        try segments.append(.{
            .kind = .literal,
            .text = lit_text,
            .specifier = .none,
        });
    }

    return try segments.toOwnedSlice();
}

fn unescapeLength(text: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len) {
            i += 2;
        } else {
            i += 1;
        }
        len += 1;
    }
    return len;
}

const EXTERN_SA_FMT_I64 = "@extern sa_fmt_i64(value: i64, base: u32) -> u64";
const EXTERN_SA_FMT_U64 = "@extern sa_fmt_u64(value: u64, base: u32) -> u64";
const EXTERN_SA_FMT_F64 = "@extern sa_fmt_f64(value: f64, precision: u32) -> u64";
const EXTERN_SA_FMT_BYTES = "@extern sa_fmt_bytes(&buf: ptr, len: u64) -> u64";
const EXTERN_SA_FMT_BUFFER_DATA = "@extern sa_fmt_buffer_data(buffer: u64) -> &ptr";
const EXTERN_SA_FMT_BUFFER_LEN = "@extern sa_fmt_buffer_len(buffer: u64) -> u64";
const EXTERN_SA_FMT_BUFFER_FREE = "@extern sa_fmt_buffer_free(^buffer: u64) -> i32";
const EXTERN_SA_STRING_CONCAT = "@extern sa_string_concat(left: ptr, left_len: u64, right: ptr, right_len: u64) -> u64";

fn ensureExternSigs(
    allocator: std.mem.Allocator,
    dict: *DefDict,
    symbols: *SymbolTable,
    loc_table: *std.array_list.Managed(?common_upstream.UpstreamLoc),
    pending_loc: *?common_upstream.UpstreamLoc,
    source_line: u32,
    instructions: *std.array_list.Managed(Instruction),
    const_decls: *std.array_list.Managed(ConstDecl),
    function_sigs: *std.array_list.Managed(FunctionSig),
    owned_text: *std.array_list.Managed([]const u8),
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
) !void {
    const sigs = function_sigs.items;
    if (!isFunctionSigDeclared(sigs, "sa_fmt_i64")) {
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, EXTERN_SA_FMT_I64, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    }
    if (!isFunctionSigDeclared(sigs, "sa_fmt_u64")) {
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, EXTERN_SA_FMT_U64, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    }
    if (!isFunctionSigDeclared(sigs, "sa_fmt_f64")) {
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, EXTERN_SA_FMT_F64, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    }
    if (!isFunctionSigDeclared(sigs, "sa_fmt_bytes")) {
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, EXTERN_SA_FMT_BYTES, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    }
    if (!isFunctionSigDeclared(sigs, "sa_fmt_buffer_data")) {
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, EXTERN_SA_FMT_BUFFER_DATA, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    }
    if (!isFunctionSigDeclared(sigs, "sa_fmt_buffer_len")) {
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, EXTERN_SA_FMT_BUFFER_LEN, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    }
    if (!isFunctionSigDeclared(sigs, "sa_fmt_buffer_free")) {
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, EXTERN_SA_FMT_BUFFER_FREE, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    }
    if (!isFunctionSigDeclared(sigs, "sa_string_concat")) {
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, EXTERN_SA_STRING_CONCAT, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    }
}

fn expandPrintOrFormat(
    allocator: std.mem.Allocator,
    macro_name: []const u8,
    args_text: []const u8,
    source_line: u32,
    dict: *DefDict,
    symbols: *SymbolTable,
    loc_table: *std.array_list.Managed(?common_upstream.UpstreamLoc),
    pending_loc: *?common_upstream.UpstreamLoc,
    instructions: *std.array_list.Managed(Instruction),
    const_decls: *std.array_list.Managed(ConstDecl),
    function_sigs: *std.array_list.Managed(FunctionSig),
    owned_text: *std.array_list.Managed([]const u8),
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
) !void {
    try ensureExternSigs(
        allocator,
        dict,
        symbols,
        loc_table,
        pending_loc,
        source_line,
        instructions,
        const_decls,
        function_sigs,
        owned_text,
        current_package_identity,
        current_package_hash,
    );

    const args = try parsePrintArgs(allocator, args_text);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    if (std.mem.eql(u8, macro_name, "PRINT!")) {
        if (args.len < 1) return error.InvalidMacroInvocation;
        const fmt_str_raw = args[0];
        const format_args = args[1..];

        const fmt_str = try unquoteString(allocator, fmt_str_raw);
        defer allocator.free(fmt_str);

        const segments = try parseFormatString(allocator, fmt_str);
        defer {
            for (segments) |seg| {
                if (seg.kind == .literal) allocator.free(seg.text);
            }
            allocator.free(segments);
        }

        var expected_args: usize = 0;
        for (segments) |seg| {
            if (seg.kind == .placeholder) {
                switch (seg.specifier) {
                    .none, .i64, .u64, .f64 => expected_args += 1,
                    .bytes => expected_args += 2,
                }
            }
        }

        if (expected_args != format_args.len) {
            return error.ArgCountMismatch;
        }

        var var_counter: usize = 0;
        var arg_idx: usize = 0;
        for (segments) |seg| {
            if (seg.kind == .literal) {
                const unescaped_len = unescapeLength(seg.text);
                const const_id = const_decls.items.len;
                const const_name = try std.fmt.allocPrint(allocator, "__PRINT_LIT_{d}_{d}", .{ source_line, const_id });
                defer allocator.free(const_name);

                const const_line = try std.fmt.allocPrint(allocator, "@const {s} = utf8:\"{s}\"", .{ const_name, seg.text });
                defer allocator.free(const_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, const_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const print_line = try std.fmt.allocPrint(allocator, "call @sys_print(*{s}, {d})", .{ const_name, unescaped_len });
                defer allocator.free(print_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, print_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
            } else {
                const spec = seg.specifier;
                const fmt_buf = try std.fmt.allocPrint(allocator, "__fmt_buf_{d}_{d}", .{ source_line, var_counter });
                const fmt_ptr = try std.fmt.allocPrint(allocator, "__fmt_ptr_{d}_{d}", .{ source_line, var_counter });
                const fmt_len = try std.fmt.allocPrint(allocator, "__fmt_len_{d}_{d}", .{ source_line, var_counter });
                const fmt_free_ok = try std.fmt.allocPrint(allocator, "__fmt_free_ok_{d}_{d}", .{ source_line, var_counter });
                defer {
                    allocator.free(fmt_buf);
                    allocator.free(fmt_ptr);
                    allocator.free(fmt_len);
                    allocator.free(fmt_free_ok);
                }
                var_counter += 1;

                const call_line = switch (spec) {
                    .none, .i64 => try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_i64({s}, 10)", .{ fmt_buf, format_args[arg_idx] }),
                    .u64 => try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_u64({s}, 10)", .{ fmt_buf, format_args[arg_idx] }),
                    .f64 => try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_f64({s}, 6)", .{ fmt_buf, format_args[arg_idx] }),
                    .bytes => try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_bytes(&{s}, {s})", .{ fmt_buf, format_args[arg_idx], format_args[arg_idx + 1] }),
                };
                defer allocator.free(call_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, call_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                switch (spec) {
                    .none, .i64, .u64, .f64 => arg_idx += 1,
                    .bytes => arg_idx += 2,
                }

                const ptr_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_data({s})", .{ fmt_ptr, fmt_buf });
                defer allocator.free(ptr_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, ptr_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const len_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_len({s})", .{ fmt_len, fmt_buf });
                defer allocator.free(len_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, len_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const print_line = try std.fmt.allocPrint(allocator, "call @sys_print({s}, {s})", .{ fmt_ptr, fmt_len });
                defer allocator.free(print_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, print_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const ptr_release_line = try std.fmt.allocPrint(allocator, "! {s}", .{fmt_ptr});
                defer allocator.free(ptr_release_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, ptr_release_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const len_release_line = try std.fmt.allocPrint(allocator, "! {s}", .{fmt_len});
                defer allocator.free(len_release_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, len_release_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const free_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_free(^{s})", .{ fmt_free_ok, fmt_buf });
                defer allocator.free(free_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, free_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const free_discard_line = try std.fmt.allocPrint(allocator, "! {s}", .{fmt_free_ok});
                defer allocator.free(free_discard_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, free_discard_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
            }
        }
    } else {
        if (args.len < 2) return error.InvalidMacroInvocation;
        const dest_reg = args[0];
        const fmt_str_raw = args[1];
        const format_args = args[2..];

        const fmt_str = try unquoteString(allocator, fmt_str_raw);
        defer allocator.free(fmt_str);

        const segments = try parseFormatString(allocator, fmt_str);
        defer {
            for (segments) |seg| {
                if (seg.kind == .literal) allocator.free(seg.text);
            }
            allocator.free(segments);
        }

        var expected_args: usize = 0;
        for (segments) |seg| {
            if (seg.kind == .placeholder) {
                switch (seg.specifier) {
                    .none, .i64, .u64, .f64 => expected_args += 1,
                    .bytes => expected_args += 2,
                }
            }
        }

        if (expected_args != format_args.len) {
            return error.ArgCountMismatch;
        }

        const SegmentData = struct {
            ptr: []const u8,
            len: []const u8,
            owned: bool,
            owned_buf_name: ?[]const u8,
            release_ptr_len: bool,
        };

        var segment_datas = std.array_list.Managed(SegmentData).init(allocator);
        defer {
            for (segment_datas.items) |sd| {
                allocator.free(sd.ptr);
                allocator.free(sd.len);
                if (sd.owned_buf_name) |ob| allocator.free(ob);
            }
            segment_datas.deinit();
        }

        var var_counter: usize = 0;
        var arg_idx: usize = 0;
        for (segments) |seg| {
            if (seg.kind == .literal) {
                const unescaped_len = unescapeLength(seg.text);
                const const_id = const_decls.items.len;
                const const_name = try std.fmt.allocPrint(allocator, "__PRINT_LIT_{d}_{d}", .{ source_line, const_id });
                defer allocator.free(const_name);

                const const_line = try std.fmt.allocPrint(allocator, "@const {s} = utf8:\"{s}\"", .{ const_name, seg.text });
                defer allocator.free(const_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, const_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const ptr_str = try std.fmt.allocPrint(allocator, "*{s}", .{const_name});
                const len_str = try std.fmt.allocPrint(allocator, "{d}", .{unescaped_len});

                try segment_datas.append(.{
                    .ptr = ptr_str,
                    .len = len_str,
                    .owned = false,
                    .owned_buf_name = null,
                    .release_ptr_len = false,
                });
            } else {
                const spec = seg.specifier;
                const fmt_buf = try std.fmt.allocPrint(allocator, "__fmt_buf_{d}_{d}", .{ source_line, var_counter });
                const fmt_ptr = try std.fmt.allocPrint(allocator, "__fmt_ptr_{d}_{d}", .{ source_line, var_counter });
                const fmt_len = try std.fmt.allocPrint(allocator, "__fmt_len_{d}_{d}", .{ source_line, var_counter });
                defer {
                    allocator.free(fmt_ptr);
                    allocator.free(fmt_len);
                }
                var_counter += 1;

                const call_line = switch (spec) {
                    .none, .i64 => try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_i64({s}, 10)", .{ fmt_buf, format_args[arg_idx] }),
                    .u64 => try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_u64({s}, 10)", .{ fmt_buf, format_args[arg_idx] }),
                    .f64 => try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_f64({s}, 6)", .{ fmt_buf, format_args[arg_idx] }),
                    .bytes => try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_bytes(&{s}, {s})", .{ fmt_buf, format_args[arg_idx], format_args[arg_idx + 1] }),
                };
                defer allocator.free(call_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, call_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                switch (spec) {
                    .none, .i64, .u64, .f64 => arg_idx += 1,
                    .bytes => arg_idx += 2,
                }

                const ptr_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_data({s})", .{ fmt_ptr, fmt_buf });
                defer allocator.free(ptr_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, ptr_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const len_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_len({s})", .{ fmt_len, fmt_buf });
                defer allocator.free(len_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, len_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const ptr_str = try allocator.dupe(u8, fmt_ptr);
                const len_str = try allocator.dupe(u8, fmt_len);

                try segment_datas.append(.{
                    .ptr = ptr_str,
                    .len = len_str,
                    .owned = true,
                    .owned_buf_name = fmt_buf,
                    .release_ptr_len = true,
                });
            }
        }

        if (segment_datas.items.len == 0) {
            const const_id = const_decls.items.len;
            const const_name = try std.fmt.allocPrint(allocator, "__PRINT_LIT_{d}_{d}", .{ source_line, const_id });
            defer allocator.free(const_name);

            const const_line = try std.fmt.allocPrint(allocator, "@const {s} = utf8:\"\"", .{const_name});
            defer allocator.free(const_line);
            try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, const_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

            const empty_const_id = const_decls.items.len;
            const empty_const_name = try std.fmt.allocPrint(allocator, "__PRINT_LIT_{d}_{d}", .{ source_line, empty_const_id });
            defer allocator.free(empty_const_name);

            const empty_const_line = try std.fmt.allocPrint(allocator, "@const {s} = utf8:\"\"", .{empty_const_name});
            defer allocator.free(empty_const_line);
            try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, empty_const_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

            const concat_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_string_concat(*{s}, 0, *{s}, 0)", .{ dest_reg, const_name, empty_const_name });
            defer allocator.free(concat_line);
            try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, concat_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
        } else if (segment_datas.items.len == 1) {
            const first = segment_datas.items[0];
            if (first.owned) {
                if (first.release_ptr_len) {
                    const ptr_release_line = try std.fmt.allocPrint(allocator, "! {s}", .{first.ptr});
                    defer allocator.free(ptr_release_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, ptr_release_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                    const len_release_line = try std.fmt.allocPrint(allocator, "! {s}", .{first.len});
                    defer allocator.free(len_release_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, len_release_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
                }

                const assign_line = try std.fmt.allocPrint(allocator, "{s} = {s}", .{ dest_reg, first.owned_buf_name.? });
                defer allocator.free(assign_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, assign_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
            } else {
                const const_id = const_decls.items.len;
                const const_name = try std.fmt.allocPrint(allocator, "__PRINT_LIT_{d}_{d}", .{ source_line, const_id });
                defer allocator.free(const_name);

                const const_line = try std.fmt.allocPrint(allocator, "@const {s} = utf8:\"\"", .{const_name});
                defer allocator.free(const_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, const_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const concat_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_string_concat({s}, {s}, *{s}, 0)", .{ dest_reg, first.ptr, first.len, const_name });
                defer allocator.free(concat_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, concat_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
            }
        } else {
            const left = segment_datas.items[0];
            var left_owned = left.owned;
            var left_buf_name: ?[]const u8 = if (left_owned) try allocator.dupe(u8, left.owned_buf_name.?) else null;
            var left_release_ptr_len = left.release_ptr_len;
            defer if (left_buf_name) |lbn| allocator.free(lbn);

            var left_ptr = try allocator.dupe(u8, left.ptr);
            var left_len = try allocator.dupe(u8, left.len);
            defer {
                allocator.free(left_ptr);
                allocator.free(left_len);
            }

            var acc_name: ?[]const u8 = null;
            defer if (acc_name) |an| allocator.free(an);

            var i: usize = 1;
            while (i < segment_datas.items.len) : (i += 1) {
                const right = segment_datas.items[i];
                const is_last = (i == segment_datas.items.len - 1);

                const new_acc = if (is_last)
                    dest_reg
                else
                    try std.fmt.allocPrint(allocator, "__fmt_acc_{d}_{d}", .{ source_line, var_counter });
                defer if (!is_last) allocator.free(new_acc);
                if (!is_last) var_counter += 1;

                const concat_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_string_concat({s}, {s}, {s}, {s})", .{ new_acc, left_ptr, left_len, right.ptr, right.len });
                defer allocator.free(concat_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, concat_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                if (left_release_ptr_len) {
                    const ptr_release_line = try std.fmt.allocPrint(allocator, "! {s}", .{left_ptr});
                    defer allocator.free(ptr_release_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, ptr_release_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                    const len_release_line = try std.fmt.allocPrint(allocator, "! {s}", .{left_len});
                    defer allocator.free(len_release_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, len_release_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
                }

                if (left_owned) {
                    const free_ok = try std.fmt.allocPrint(allocator, "__fmt_free_ok_{d}_{d}", .{ source_line, var_counter });
                    defer allocator.free(free_ok);
                    var_counter += 1;

                    const free_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_free(^{s})", .{ free_ok, left_buf_name.? });
                    defer allocator.free(free_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, free_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                    const discard_line = try std.fmt.allocPrint(allocator, "! {s}", .{free_ok});
                    defer allocator.free(discard_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, discard_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
                }

                if (right.release_ptr_len) {
                    const ptr_release_line = try std.fmt.allocPrint(allocator, "! {s}", .{right.ptr});
                    defer allocator.free(ptr_release_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, ptr_release_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                    const len_release_line = try std.fmt.allocPrint(allocator, "! {s}", .{right.len});
                    defer allocator.free(len_release_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, len_release_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
                }

                if (right.owned) {
                    const free_ok = try std.fmt.allocPrint(allocator, "__fmt_free_ok_{d}_{d}", .{ source_line, var_counter });
                    defer allocator.free(free_ok);
                    var_counter += 1;

                    const free_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_free(^{s})", .{ free_ok, right.owned_buf_name.? });
                    defer allocator.free(free_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, free_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                    const discard_line = try std.fmt.allocPrint(allocator, "! {s}", .{free_ok});
                    defer allocator.free(discard_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, discard_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
                }

                if (!is_last) {
                    left_owned = true;
                    left_release_ptr_len = true;
                    if (left_buf_name) |lbn| allocator.free(lbn);
                    left_buf_name = try allocator.dupe(u8, new_acc);

                    const new_ptr = try std.fmt.allocPrint(allocator, "__fmt_ptr_{d}_{d}", .{ source_line, var_counter });
                    const new_len = try std.fmt.allocPrint(allocator, "__fmt_len_{d}_{d}", .{ source_line, var_counter });
                    defer {
                        allocator.free(new_ptr);
                        allocator.free(new_len);
                    }
                    var_counter += 1;

                    const ptr_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_data({s})", .{ new_ptr, new_acc });
                    defer allocator.free(ptr_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, ptr_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                    const len_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_len({s})", .{ new_len, new_acc });
                    defer allocator.free(len_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, len_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                    allocator.free(left_ptr);
                    allocator.free(left_len);
                    left_ptr = try allocator.dupe(u8, new_ptr);
                    left_len = try allocator.dupe(u8, new_len);

                    if (acc_name) |an| allocator.free(an);
                    acc_name = try allocator.dupe(u8, new_acc);
                } else {
                    left_owned = false;
                    left_release_ptr_len = false;
                    if (left_buf_name) |lbn| {
                        allocator.free(lbn);
                        left_buf_name = null;
                    }
                }
            }
        }
    }
}

fn expandStringify(
    allocator: std.mem.Allocator,
    args_text: []const u8,
    source_line: u32,
    dict: *DefDict,
    symbols: *SymbolTable,
    loc_table: *std.array_list.Managed(?common_upstream.UpstreamLoc),
    pending_loc: *?common_upstream.UpstreamLoc,
    instructions: *std.array_list.Managed(Instruction),
    const_decls: *std.array_list.Managed(ConstDecl),
    function_sigs: *std.array_list.Managed(FunctionSig),
    owned_text: *std.array_list.Managed([]const u8),
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
) !void {
    const comma = std.mem.indexOfScalar(u8, args_text, ',') orelse return error.InvalidMacroInvocation;
    const out_reg = std.mem.trim(u8, args_text[0..comma], " \t\r\n");
    const expr_text = std.mem.trim(u8, args_text[comma + 1 ..], " \t\r\n");
    if (out_reg.len == 0 or expr_text.len == 0) return error.InvalidMacroInvocation;

    const const_name = try std.fmt.allocPrint(allocator, "__STRINGIFY_LIT_{d}_{d}", .{ source_line, const_decls.items.len });
    defer allocator.free(const_name);

    var hex = std.array_list.Managed(u8).init(allocator);
    errdefer hex.deinit();
    try hex.appendSlice("hex:");
    for (expr_text) |b| {
        var hex_byte_buf: [4]u8 = undefined;
        try hex.appendSlice(try std.fmt.bufPrint(&hex_byte_buf, "\\x{X:0>2}", .{b}));
    }

    const const_line = try std.fmt.allocPrint(allocator, "@const {s} = {s}", .{ const_name, hex.items });
    defer allocator.free(const_line);
    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, const_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    hex.deinit();

    const len = expr_text.len;
    const ptr_line = try std.fmt.allocPrint(allocator, "store {s}+Slice_ptr, &{s} as ptr", .{ out_reg, const_name });
    defer allocator.free(ptr_line);
    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, ptr_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

    const len_line = try std.fmt.allocPrint(allocator, "store {s}+Slice_len, {d} as u64", .{ out_reg, len });
    defer allocator.free(len_line);
    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, len_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
}

fn expandEnvMacro(
    allocator: std.mem.Allocator,
    macro_name: []const u8,
    args_text: []const u8,
    source_line: u32,
    dict: *DefDict,
    symbols: *SymbolTable,
    loc_table: *std.array_list.Managed(?common_upstream.UpstreamLoc),
    pending_loc: *?common_upstream.UpstreamLoc,
    instructions: *std.array_list.Managed(Instruction),
    const_decls: *std.array_list.Managed(ConstDecl),
    function_sigs: *std.array_list.Managed(FunctionSig),
    owned_text: *std.array_list.Managed([]const u8),
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
) !void {
    const comma = std.mem.indexOfScalar(u8, args_text, ',') orelse return error.InvalidMacroInvocation;
    const out_reg = std.mem.trim(u8, args_text[0..comma], " \t\r\n");
    const key_text = std.mem.trim(u8, args_text[comma + 1 ..], " \t\r\n");
    if (out_reg.len == 0 or key_text.len == 0) return error.InvalidMacroInvocation;

    const key_raw = try unquoteString(allocator, key_text);
    defer allocator.free(key_raw);
    if (key_raw.len == 0) return error.InvalidMacroInvocation;

    const env_value = sio.getEnvVarOwned(allocator, key_raw) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            if (std.mem.eql(u8, macro_name, "OPTION_ENV!")) {
                const none_tag_line = try std.fmt.allocPrint(allocator, "store {s}+Option_tag, Option_NONE as u64", .{out_reg});
                defer allocator.free(none_tag_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, none_tag_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const none_value_line = try std.fmt.allocPrint(allocator, "store {s}+Option_value, 0 as u64", .{out_reg});
                defer allocator.free(none_value_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, none_value_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
                return;
            }
            return error.InvalidMacroInvocation;
        },
        else => return err,
    };
    defer allocator.free(env_value);

    const const_name = try std.fmt.allocPrint(allocator, "__ENV_LIT_{d}_{d}", .{ source_line, const_decls.items.len });
    defer allocator.free(const_name);

    var hex = std.array_list.Managed(u8).init(allocator);
    errdefer hex.deinit();
    try hex.appendSlice("hex:");
    for (env_value) |b| {
        var hex_byte_buf: [4]u8 = undefined;
        try hex.appendSlice(try std.fmt.bufPrint(&hex_byte_buf, "\\x{X:0>2}", .{b}));
    }

    const const_line = try std.fmt.allocPrint(allocator, "@const {s} = {s}", .{ const_name, hex.items });
    defer allocator.free(const_line);
    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, const_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    hex.deinit();

    const value_len = env_value.len;
    if (std.mem.eql(u8, macro_name, "ENV!")) {
        const ptr_line = try std.fmt.allocPrint(allocator, "store {s}+Slice_ptr, &{s} as ptr", .{ out_reg, const_name });
        defer allocator.free(ptr_line);
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, ptr_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

        const len_line = try std.fmt.allocPrint(allocator, "store {s}+Slice_len, {d} as u64", .{ out_reg, value_len });
        defer allocator.free(len_line);
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, len_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
        return;
    }

    if (!std.mem.eql(u8, macro_name, "OPTION_ENV!")) return error.InvalidMacroInvocation;

    const slice_reg = try std.fmt.allocPrint(allocator, "__ENV_SLICE_{d}_{d}", .{ source_line, const_decls.items.len });
    defer allocator.free(slice_reg);

    const slice_alloc_line = try std.fmt.allocPrint(allocator, "{s} = stack_alloc Slice_SIZE", .{slice_reg});
    defer allocator.free(slice_alloc_line);
    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, slice_alloc_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

    const slice_ptr_line = try std.fmt.allocPrint(allocator, "store {s}+Slice_ptr, &{s} as ptr", .{ slice_reg, const_name });
    defer allocator.free(slice_ptr_line);
    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, slice_ptr_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

    const slice_len_line = try std.fmt.allocPrint(allocator, "store {s}+Slice_len, {d} as u64", .{ slice_reg, value_len });
    defer allocator.free(slice_len_line);
    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, slice_len_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

    const some_tag_line = try std.fmt.allocPrint(allocator, "store {s}+Option_tag, Option_SOME as u64", .{out_reg});
    defer allocator.free(some_tag_line);
    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, some_tag_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

    const some_value_line = try std.fmt.allocPrint(allocator, "store {s}+Option_value, {s} as ptr", .{ out_reg, slice_reg });
    defer allocator.free(some_value_line);
    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, some_value_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
}

fn emitRange(
    allocator: std.mem.Allocator,
    lines: []const SourceLine,
    start: usize,
    end: usize,
    depth: u16,
    source_line_override: ?u32,
    source_path: ?[]const u8,
    include_stack: *std.array_list.Managed([]const u8),
    macro_call_stack: *std.array_list.Managed(*const MacroDef),
    replacements: []const Replacement,
    top_level: bool,
    macros: *std.StringHashMap(MacroDef),
    dict: *DefDict,
    symbols: *SymbolTable,
    loc_table: *std.array_list.Managed(?common_upstream.UpstreamLoc),
    pending_loc: *?common_upstream.UpstreamLoc,
    instructions: *std.array_list.Managed(Instruction),
    const_decls: *std.array_list.Managed(ConstDecl),
    function_sigs: *std.array_list.Managed(FunctionSig),
    owned_text: *std.array_list.Managed([]const u8),
    error_ctx: ?*ErrorContext,
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
    expansion_counter: *u64,
) !void {
    if (depth > max_macro_recursion_depth) return error.MacroRecursionLimit;

    var idx = start;
    while (idx < end) : (idx += 1) {
        const line = lines[idx];
        const source_line = source_line_override orelse line.line_no;
        const effective_package_identity = line.package_identity orelse current_package_identity;
        recordErrorSourceLine(error_ctx, source_line);

        switch (line.classified.kind) {
            .blank_or_comment, .import_decl, .version => {},
            .const_decl => {
                if (!top_level) return error.InvalidMacroDefinitionContext;
                const upstream_loc = takePendingLoc(pending_loc);
                errdefer if (upstream_loc) |loc| allocator.free(loc.file);
                var decl = try common_const_decl.parseConstDecl(
                    allocator,
                    line.text,
                    source_line,
                    @intCast(instructions.items.len),
                    upstream_loc,
                );
                errdefer decl.deinit(allocator);
                _ = try symbols.intern(decl.name);
                try const_decls.append(decl);
            },
            .loc_hint => {
                const line_no = try std.fmt.parseInt(u32, line.classified.parts[1], 10);
                const col_no = try std.fmt.parseInt(u32, line.classified.parts[2], 10);
                try setPendingLoc(allocator, pending_loc, line.classified.parts[0], line_no, col_no);
            },
            .def, .npm_bind, .label, .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl, .instruction, .native, .unknown => {
                const should_render = source_line_override != null or replacements.len != 0;
                if (should_render) {
                    const rendered = try renderWithTokenReplacements(allocator, line.text, replacements);
                    try owned_text.append(rendered);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, rendered, source_line, instructions, const_decls, function_sigs, owned_text, effective_package_identity, line.package_source_sha256 orelse current_package_hash);
                } else {
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, line.text, source_line, instructions, const_decls, function_sigs, owned_text, effective_package_identity, line.package_source_sha256 orelse current_package_hash);
                }
            },
            .macro_start => {
                if (!top_level) return error.InvalidMacroDefinitionContext;
                const def = macros.get(line.classified.parts[0]) orelse return error.InvalidMacroInvocation;
                idx = def.body_end;
            },
            .macro_end => return error.UnbalancedMacro,
            .rep_start => {
                const count_text = try dict.foldText(allocator, line.classified.parts[0]);
                try owned_text.append(count_text);
                const count = std.fmt.parseInt(usize, count_text, 10) catch return error.MacroExpansionBudget;
                const rep_end = findNestedRepEnd(lines, idx + 1) orelse return error.UnbalancedRep;
                try ensureRepExpansionBudget(count, rep_end - (idx + 1));

                var rep_index: usize = 0;
                while (rep_index < count) : (rep_index += 1) {
                    const expansion_id = try bumpMacroExpansionCounter(expansion_counter);
                    var rep_defined_names = try collectDefinedNames(allocator, lines, idx + 1, rep_end);
                    defer rep_defined_names.deinit();
                    var hygiene_replacements = try buildHygieneReplacements(allocator, &rep_defined_names, expansion_id);
                    defer {
                        for (hygiene_replacements.items) |r| allocator.free(r.replacement);
                        hygiene_replacements.deinit();
                    }

                    const rep_value = try std.fmt.allocPrint(allocator, "{d}", .{rep_index});
                    defer allocator.free(rep_value);

                    var list = std.array_list.Managed(Replacement).init(allocator);
                    errdefer list.deinit();
                    try list.appendSlice(hygiene_replacements.items);
                    try list.appendSlice(replacements);
                    try list.append(.{ .needle = "%i", .replacement = rep_value });
                    const combined = try list.toOwnedSlice();
                    defer allocator.free(combined);

                    try emitRange(
                        allocator,
                        lines,
                        idx + 1,
                        rep_end,
                        depth + 1,
                        source_line_override orelse line.line_no,
                        source_path,
                        include_stack,
                        macro_call_stack,
                        combined,
                        false,
                        macros,
                        dict,
                        symbols,
                        loc_table,
                        pending_loc,
                        instructions,
                        const_decls,
                        function_sigs,
                        owned_text,
                        error_ctx,
                        effective_package_identity,
                        line.package_source_sha256 orelse current_package_hash,
                        expansion_counter,
                    );
                }

                idx = rep_end;
            },
            .rep_end => return error.UnbalancedRep,
            .if_start => {
                const bounds = findNestedIfBounds(lines, idx + 1) orelse return error.InvalidMacroInvocation;
                const condition_text = if (replacements.len == 0)
                    try allocator.dupe(u8, line.classified.parts[0])
                else
                    try renderWithTokenReplacements(allocator, line.classified.parts[0], replacements);
                defer allocator.free(condition_text);
                try owned_text.append(try allocator.dupe(u8, condition_text));

                const condition_true = try macroConditionIsTrue(condition_text);
                const selected_start = if (condition_true) idx + 1 else (if (bounds.else_idx) |else_idx| else_idx + 1 else bounds.end_idx);
                const selected_end = if (condition_true) (bounds.else_idx orelse bounds.end_idx) else bounds.end_idx;
                if (selected_start < selected_end) {
                    try emitRange(
                        allocator,
                        lines,
                        selected_start,
                        selected_end,
                        depth + 1,
                        source_line_override orelse line.line_no,
                        source_path,
                        include_stack,
                        macro_call_stack,
                        replacements,
                        false,
                        macros,
                        dict,
                        symbols,
                        loc_table,
                        pending_loc,
                        instructions,
                        const_decls,
                        function_sigs,
                        owned_text,
                        error_ctx,
                        effective_package_identity,
                        line.package_source_sha256 orelse current_package_hash,
                        expansion_counter,
                    );
                }
                idx = bounds.end_idx;
            },
            .else_, .if_end => return error.InvalidMacroInvocation,
            .expand => {
                const rendered_line = if (replacements.len == 0) line.text else blk: {
                    const rendered = try renderWithTokenReplacements(allocator, line.text, replacements);
                    try owned_text.append(rendered);
                    break :blk rendered;
                };
                const rendered_classified = classifier.classifyLine(rendered_line);
                if (rendered_classified.kind != .expand) return error.InvalidSyntax;
                const macro_name = rendered_classified.parts[0];
                if (std.mem.eql(u8, macro_name, "PRINT!") or std.mem.eql(u8, macro_name, "FORMAT!")) {
                    try expandPrintOrFormat(
                        allocator,
                        macro_name,
                        rendered_classified.parts[1],
                        source_line,
                        dict,
                        symbols,
                        loc_table,
                        pending_loc,
                        instructions,
                        const_decls,
                        function_sigs,
                        owned_text,
                        effective_package_identity,
                        line.package_source_sha256 orelse current_package_hash,
                    );
                } else if (std.mem.eql(u8, macro_name, "STRINGIFY!")) {
                    try expandStringify(
                        allocator,
                        rendered_classified.parts[1],
                        source_line,
                        dict,
                        symbols,
                        loc_table,
                        pending_loc,
                        instructions,
                        const_decls,
                        function_sigs,
                        owned_text,
                        effective_package_identity,
                        line.package_source_sha256 orelse current_package_hash,
                    );
                } else if (std.mem.eql(u8, macro_name, "CFG!")) {
                    const cfg_args = try parseTokenList(allocator, rendered_classified.parts[1]);
                    defer allocator.free(cfg_args);
                    if (cfg_args.len != 2) return error.InvalidMacroInvocation;
                    const cfg_macro_line = try std.fmt.allocPrint(allocator, "EXPAND CFG {s}, {s}", .{ cfg_args[0], cfg_args[1] });
                    defer allocator.free(cfg_macro_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, cfg_macro_line, source_line, instructions, const_decls, function_sigs, owned_text, effective_package_identity, line.package_source_sha256 orelse current_package_hash);
                } else if (std.mem.eql(u8, macro_name, "ENV!") or std.mem.eql(u8, macro_name, "OPTION_ENV!")) {
                    try expandEnvMacro(
                        allocator,
                        macro_name,
                        rendered_classified.parts[1],
                        source_line,
                        dict,
                        symbols,
                        loc_table,
                        pending_loc,
                        instructions,
                        const_decls,
                        function_sigs,
                        owned_text,
                        effective_package_identity,
                        line.package_source_sha256 orelse current_package_hash,
                    );
                } else if (std.mem.eql(u8, macro_name, "LINE!") or std.mem.eql(u8, macro_name, "FILE!") or std.mem.eql(u8, macro_name, "COLUMN!") or std.mem.eql(u8, macro_name, "MODULE_PATH!")) {
                    try expandSourceLocationMacro(
                        allocator,
                        macro_name,
                        rendered_classified.parts[1],
                        source_line,
                        source_path,
                        dict,
                        symbols,
                        loc_table,
                        pending_loc,
                        instructions,
                        const_decls,
                        function_sigs,
                        owned_text,
                        effective_package_identity,
                        line.package_source_sha256 orelse current_package_hash,
                    );
                } else if (std.mem.eql(u8, macro_name, "INCLUDE!")) {
                    const include_args = try parseTokenList(allocator, rendered_classified.parts[1]);
                    defer allocator.free(include_args);
                    if (include_args.len != 1) return error.InvalidMacroInvocation;
                    const include_path_raw = try unquoteString(allocator, include_args[0]);
                    defer allocator.free(include_path_raw);

                    const resolved_path = if (std.fs.path.isAbsolute(include_path_raw)) blk: {
                        break :blk try allocator.dupe(u8, include_path_raw);
                    } else if (source_path) |sp| blk: {
                        const base = std.fs.path.dirname(sp) orelse ".";
                        break :blk try std.fs.path.join(allocator, &.{ base, include_path_raw });
                    } else blk: {
                        break :blk try allocator.dupe(u8, include_path_raw);
                    };
                    defer allocator.free(resolved_path);

                    for (include_stack.items) |active| {
                        if (std.mem.eql(u8, active, resolved_path)) return error.IncludeCycle;
                    }

                    const source = try sio.cwd().readFileAlloc(allocator, resolved_path, 1 << 20);
                    defer allocator.free(source);
                    try include_stack.append(try allocator.dupe(u8, resolved_path));
                    defer {
                        const popped = include_stack.pop();
                        allocator.free(popped.?);
                    }

                    var expanded = try expandImports(allocator, source, resolved_path, error_ctx, null);
                    defer expanded.deinit(allocator);
                    const included_lines = try scanSource(allocator, expanded.source, expanded.line_package_identities.items[0..], expanded.line_package_hashes.items[0..]);
                    defer allocator.free(included_lines);
                    try collectMacroDefinitions(allocator, included_lines, macros, error_ctx);
                    try emitRange(
                        allocator,
                        included_lines,
                        0,
                        included_lines.len,
                        depth + 1,
                        null,
                        resolved_path,
                        include_stack,
                        macro_call_stack,
                        replacements,
                        false,
                        macros,
                        dict,
                        symbols,
                        loc_table,
                        pending_loc,
                        instructions,
                        const_decls,
                        function_sigs,
                        owned_text,
                        error_ctx,
                        effective_package_identity,
                        line.package_source_sha256 orelse current_package_hash,
                        expansion_counter,
                    );
                } else if (std.mem.eql(u8, macro_name, "INCLUDE_STR!") or std.mem.eql(u8, macro_name, "INCLUDE_BYTES!")) {
                    try includeFileAsConst(
                        allocator,
                        if (std.mem.eql(u8, macro_name, "INCLUDE_STR!")) .str else .bytes,
                        rendered_classified.parts[1],
                        source_line,
                        line.package_identity,
                        dict,
                        symbols,
                        loc_table,
                        pending_loc,
                        instructions,
                        const_decls,
                        function_sigs,
                        owned_text,
                        effective_package_identity,
                        line.package_source_sha256 orelse current_package_hash,
                    );
                } else {
                    const def = macros.getPtr(macro_name) orelse return error.InvalidMacroInvocation;
                    for (macro_call_stack.items) |active_macro| {
                        if (active_macro == def) return error.MacroRecursionLimit;
                    }
                    try macro_call_stack.append(def);
                    defer _ = macro_call_stack.pop();
                    const body_lines = try macroDefBodyLines(def);
                    const args = try parseTokenList(allocator, rendered_classified.parts[1]);
                    defer allocator.free(args);
                    if (def.variadic_param) |variadic_param| {
                        if (args.len < def.params.len) return error.InvalidMacroInvocation;

                        const expansion_id = try bumpMacroExpansionCounter(expansion_counter);
                        var var_defined_names = try collectDefinedNamesFromSlice(allocator, body_lines);
                        defer var_defined_names.deinit();
                        var var_hygiene = try buildHygieneReplacements(allocator, &var_defined_names, expansion_id);
                        defer {
                            for (var_hygiene.items) |r| allocator.free(r.replacement);
                            var_hygiene.deinit();
                        }

                        var local_replacements = std.array_list.Managed(Replacement).init(allocator);
                        errdefer local_replacements.deinit();
                        try local_replacements.appendSlice(var_hygiene.items);
                        for (def.params, 0..) |param, iarg| {
                            try local_replacements.append(.{ .needle = param, .replacement = args[iarg] });
                        }
                        const variadic_args = args[def.params.len..];
                        const joined = try joinTokens(allocator, variadic_args);
                        defer allocator.free(joined);
                        try local_replacements.append(.{ .needle = variadic_param, .replacement = joined });
                        const local_slice = try local_replacements.toOwnedSlice();
                        defer allocator.free(local_slice);
                        try emitRange(
                            allocator,
                            body_lines,
                            0,
                            body_lines.len,
                            depth + 1,
                            source_line_override orelse line.line_no,
                            source_path,
                            include_stack,
                            macro_call_stack,
                            local_slice,
                            false,
                            macros,
                            dict,
                            symbols,
                            loc_table,
                            pending_loc,
                            instructions,
                            const_decls,
                            function_sigs,
                            owned_text,
                            error_ctx,
                            effective_package_identity,
                            line.package_source_sha256 orelse current_package_hash,
                            expansion_counter,
                        );
                        continue;
                    }

                    if (args.len != def.params.len) return error.InvalidMacroInvocation;

                    const expansion_id = try bumpMacroExpansionCounter(expansion_counter);
                    var nv_defined_names = try collectDefinedNamesFromSlice(allocator, body_lines);
                    defer nv_defined_names.deinit();
                    var nv_hygiene = try buildHygieneReplacements(allocator, &nv_defined_names, expansion_id);
                    defer {
                        for (nv_hygiene.items) |r| allocator.free(r.replacement);
                        nv_hygiene.deinit();
                    }

                    var local_replacements = std.array_list.Managed(Replacement).init(allocator);
                    errdefer local_replacements.deinit();
                    try local_replacements.appendSlice(nv_hygiene.items);
                    for (def.params, 0..) |param, iarg| {
                        try local_replacements.append(.{ .needle = param, .replacement = args[iarg] });
                    }
                    const local_slice = try local_replacements.toOwnedSlice();
                    defer allocator.free(local_slice);
                    try emitRange(
                        allocator,
                        body_lines,
                        0,
                        body_lines.len,
                        depth + 1,
                        source_line_override orelse line.line_no,
                        source_path,
                        include_stack,
                        macro_call_stack,
                        local_slice,
                        false,
                        macros,
                        dict,
                        symbols,
                        loc_table,
                        pending_loc,
                        instructions,
                        const_decls,
                        function_sigs,
                        owned_text,
                        error_ctx,
                        effective_package_identity,
                        line.package_source_sha256 orelse current_package_hash,
                        expansion_counter,
                    );
                }
            },
        }
    }
}

fn collectLocTableEntries(
    allocator: std.mem.Allocator,
    instructions: []const Instruction,
) !LocTable {
    var table = std.array_list.Managed(?common_upstream.UpstreamLoc).init(allocator);
    errdefer table.deinit();

    for (instructions) |item| {
        const keep_loc = switch (item.kind) {
            .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .label => false,
            else => true,
        };
        if (keep_loc) {
            if (item.upstream_loc) |loc| {
                const file_copy = try allocator.dupe(u8, loc.file);
                errdefer allocator.free(file_copy);
                try table.append(.{
                    .file = file_copy,
                    .line = loc.line,
                    .col = loc.col,
                });
            } else {
                try table.append(null);
            }
        } else {
            try table.append(null);
        }
    }

    return try table.toOwnedSlice();
}

pub fn scanSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    line_package_identities: []const ?[]const u8,
    line_package_hashes: []const ?[32]u8,
) ![]SourceLine {
    var lines = std.array_list.Managed(SourceLine).init(allocator);
    errdefer lines.deinit();
    try lines.ensureTotalCapacity(countSourceLines(source));

    var iterator = std.mem.splitScalar(u8, source, '\n');
    var line_idx: usize = 0;
    while (iterator.next()) |raw_line| : (line_idx += 1) {
        const line_no = std.math.cast(u32, line_idx + 1) orelse return error.SourceTooLarge;
        const idx = line_idx;
        const package_identity = if (idx < line_package_identities.len) line_package_identities[idx] else null;
        const package_source_sha256 = if (idx < line_package_hashes.len) line_package_hashes[idx] else null;
        try lines.append(.{
            .line_no = line_no,
            .text = raw_line,
            .classified = classifier.classifyLine(raw_line),
            .package_identity = package_identity,
            .package_source_sha256 = package_source_sha256,
        });
    }

    return try lines.toOwnedSlice();
}

fn countSourceLines(source: []const u8) usize {
    return std.mem.count(u8, source, "\n") + 1;
}

fn buildSymbolIdRemap(allocator: std.mem.Allocator, source_symbols: *const SymbolTable, target_symbols: *SymbolTable) ![]u32 {
    const remap = try allocator.alloc(u32, source_symbols.names.items.len);
    errdefer allocator.free(remap);
    for (source_symbols.names.items, 0..) |name, idx| {
        remap[idx] = try target_symbols.intern(name);
    }
    return remap;
}

fn remapSymbolId(remap: []const u32, old_id: u32) !u32 {
    const idx: usize = @intCast(old_id);
    if (idx >= remap.len) return error.InvalidOperand;
    return remap[idx];
}

fn remapOperandSymbolIds(operand: *Operand, remap: []const u32) !void {
    switch (operand.*) {
        .reg => |old_id| operand.* = .{ .reg = try remapSymbolId(remap, old_id) },
        .symbol => |old_id| operand.* = .{ .symbol = try remapSymbolId(remap, old_id) },
        .label => |old_id| operand.* = .{ .label = try remapSymbolId(remap, old_id) },
        .func => |old_id| operand.* = .{ .func = try remapSymbolId(remap, old_id) },
        else => {},
    }
}

fn remapInstructionSymbolIds(instruction: *Instruction, remap: []const u32) !void {
    for (&instruction.operands) |*operand| {
        try remapOperandSymbolIds(operand, remap);
    }
}

fn isOpaqueMacroArgName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__sla_macro_arg_");
}

fn remappedSymbolName(
    source_symbols: *const SymbolTable,
    target_symbols: *const SymbolTable,
    remap: []const u32,
    name: []const u8,
) !?[]const u8 {
    if (isOpaqueMacroArgName(name)) return null;
    const old_id = source_symbols.findId(name) orelse return null;
    const new_id = try remapSymbolId(remap, old_id);
    return target_symbols.lookupName(new_id) orelse error.InvalidOperand;
}

fn appendRemappedSymbolToken(
    out: *std.array_list.Managed(u8),
    source_symbols: *const SymbolTable,
    target_symbols: *const SymbolTable,
    remap: []const u32,
    token: []const u8,
) !void {
    if (try remappedSymbolName(source_symbols, target_symbols, remap, token)) |name| {
        try out.appendSlice(name);
    } else {
        try out.appendSlice(token);
    }
}

fn cloneRemappedSymbolText(
    allocator: std.mem.Allocator,
    owned_text: *std.array_list.Managed([]const u8),
    text: []const u8,
    source_symbols: *const SymbolTable,
    target_symbols: *const SymbolTable,
    remap: []const u32,
) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        if (c == '"') {
            try out.append(c);
            i += 1;
            while (i < text.len) {
                const ch = text[i];
                try out.append(ch);
                i += 1;
                if (ch == '\\' and i < text.len) {
                    try out.append(text[i]);
                    i += 1;
                    continue;
                }
                if (ch == '"') break;
            }
            continue;
        }

        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            try out.appendSlice(text[i..]);
            break;
        }

        if ((c == '@' or c == '#' or c == '%') and i + 1 < text.len and isIdentStart(text[i + 1])) {
            try out.append(c);
            const start = i + 1;
            i = start + 1;
            while (i < text.len and isIdentChar(text[i])) : (i += 1) {}
            if (c == '#') {
                try out.appendSlice(text[start..i]);
            } else {
                try appendRemappedSymbolToken(&out, source_symbols, target_symbols, remap, text[start..i]);
            }
            continue;
        }

        if (isIdentStart(c)) {
            const start = i;
            i += 1;
            while (i < text.len and isIdentChar(text[i])) : (i += 1) {}
            try appendRemappedSymbolToken(&out, source_symbols, target_symbols, remap, text[start..i]);
            continue;
        }

        try out.append(c);
        i += 1;
    }

    const owned = try out.toOwnedSlice();
    errdefer allocator.free(owned);
    try owned_text.append(owned);
    return owned;
}

fn cloneRemappedSymbolIdSlice(allocator: std.mem.Allocator, ids: []const u32, remap: []const u32) ![]const u32 {
    if (ids.len == 0) return &.{};
    const out = try allocator.alloc(u32, ids.len);
    errdefer allocator.free(out);
    for (ids, 0..) |old_id, idx| {
        out[idx] = try remapSymbolId(remap, old_id);
    }
    return out;
}

fn cloneParams(allocator: std.mem.Allocator, params: []const common_signature.ParamSpec) ![]const common_signature.ParamSpec {
    if (params.len == 0) return &.{};
    const out = try allocator.alloc(common_signature.ParamSpec, params.len);
    errdefer allocator.free(out);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |param| allocator.free(param.name);
    }
    for (params, 0..) |param, idx| {
        out[idx] = .{
            .name = try allocator.dupe(u8, param.name),
            .ty = param.ty,
            .cap = param.cap,
        };
        copied += 1;
    }
    return out;
}

fn cloneRemappedFunctionSig(
    allocator: std.mem.Allocator,
    source_sig: FunctionSig,
    remap: []const u32,
    function_id_offset: u32,
    entry_inst_offset: u32,
) !FunctionSig {
    const cloned_id = try std.math.add(u32, source_sig.id, function_id_offset);
    var out = FunctionSig{
        .id = cloned_id,
        .name = try allocator.dupe(u8, source_sig.name),
        .params = &.{},
        .kind = source_sig.kind,
        .return_cap = source_sig.return_cap,
        .return_ty = source_sig.return_ty,
        .return_fallible = source_sig.return_fallible,
        .entry_inst_idx = try std.math.add(u32, source_sig.entry_inst_idx, entry_inst_offset),
        .is_ffi_wrapper = source_sig.is_ffi_wrapper,
        .upstream_file = null,
        .upstream_loc = null,
        .param_ids = &.{},
        .reg_ids = &.{},
        .llvm_name = null,
        .ignored = source_sig.ignored,
        .should_panic = source_sig.should_panic,
    };
    errdefer out.deinit(allocator);

    out.params = try cloneParams(allocator, source_sig.params);
    out.param_ids = try cloneRemappedSymbolIdSlice(allocator, source_sig.param_ids, remap);
    out.reg_ids = try cloneRemappedSymbolIdSlice(allocator, source_sig.reg_ids, remap);
    if (source_sig.upstream_loc) |loc| {
        const file_copy = try allocator.dupe(u8, loc.file);
        out.upstream_file = file_copy;
        out.upstream_loc = .{ .file = file_copy, .line = loc.line, .col = loc.col };
    } else if (source_sig.upstream_file) |file| {
        out.upstream_file = try allocator.dupe(u8, file);
    }
    if (source_sig.llvm_name) |llvm_name| {
        if (source_sig.kind == .test_func) {
            out.llvm_name = try common_signature.testLLVMName(allocator, cloned_id);
        } else {
            out.llvm_name = try allocator.dupe(u8, llvm_name);
        }
    }
    return out;
}

fn cloneExactFunctionSig(allocator: std.mem.Allocator, source_sig: FunctionSig) !FunctionSig {
    var out = FunctionSig{
        .id = source_sig.id,
        .name = try allocator.dupe(u8, source_sig.name),
        .params = &.{},
        .kind = source_sig.kind,
        .return_cap = source_sig.return_cap,
        .return_ty = source_sig.return_ty,
        .return_fallible = source_sig.return_fallible,
        .entry_inst_idx = source_sig.entry_inst_idx,
        .is_ffi_wrapper = source_sig.is_ffi_wrapper,
        .upstream_file = null,
        .upstream_loc = null,
        .param_ids = &.{},
        .reg_ids = &.{},
        .llvm_name = null,
        .ignored = source_sig.ignored,
        .should_panic = source_sig.should_panic,
    };
    errdefer out.deinit(allocator);

    out.params = try cloneParams(allocator, source_sig.params);
    out.param_ids = try allocator.dupe(u32, source_sig.param_ids);
    out.reg_ids = try allocator.dupe(u32, source_sig.reg_ids);
    if (source_sig.upstream_loc) |loc| {
        const file_copy = try allocator.dupe(u8, loc.file);
        out.upstream_file = file_copy;
        out.upstream_loc = .{ .file = file_copy, .line = loc.line, .col = loc.col };
    } else if (source_sig.upstream_file) |file| {
        out.upstream_file = try allocator.dupe(u8, file);
    }
    if (source_sig.llvm_name) |llvm_name| {
        out.llvm_name = try allocator.dupe(u8, llvm_name);
    }
    return out;
}

fn cloneBytesLiteral(allocator: std.mem.Allocator, source: common_const_decl.BytesLiteral) !common_const_decl.BytesLiteral {
    return .{
        .kind = source.kind,
        .bytes = try allocator.dupe(u8, source.bytes),
        .repeat_count = source.repeat_count,
        .repeat_byte = source.repeat_byte,
    };
}

fn cloneVTableSlot(allocator: std.mem.Allocator, source: common_const_decl.VTableSlot) !common_const_decl.VTableSlot {
    var out = common_const_decl.VTableSlot{
        .name = try allocator.dupe(u8, source.name),
        .func_name = &.{},
    };
    errdefer out.deinit(allocator);
    out.func_name = try allocator.dupe(u8, source.func_name);
    return out;
}

fn cloneStructField(allocator: std.mem.Allocator, source: common_const_decl.StructField) anyerror!common_const_decl.StructField {
    var out = common_const_decl.StructField{
        .name = try allocator.dupe(u8, source.name),
        .size = source.size,
        .value = undefined,
    };
    errdefer allocator.free(out.name);
    out.value = try cloneConstValue(allocator, source.value);
    return out;
}

fn cloneConstValue(allocator: std.mem.Allocator, source: common_const_decl.ConstValue) anyerror!common_const_decl.ConstValue {
    switch (source) {
        .hex => |literal| return .{ .hex = try cloneBytesLiteral(allocator, literal) },
        .utf8 => |literal| return .{ .utf8 = try cloneBytesLiteral(allocator, literal) },
        .repeat => |literal| return .{ .repeat = try cloneBytesLiteral(allocator, literal) },
        .struct_ => |literal| {
            const fields = try allocator.alloc(common_const_decl.StructField, literal.fields.len);
            errdefer allocator.free(fields);
            var copied: usize = 0;
            errdefer {
                for (fields[0..copied]) |*field| field.deinit(allocator);
            }
            for (literal.fields, 0..) |field, idx| {
                fields[idx] = try cloneStructField(allocator, field);
                copied += 1;
            }
            return .{ .struct_ = .{ .fields = fields } };
        },
        .vtable => |literal| {
            const slots = try allocator.alloc(common_const_decl.VTableSlot, literal.slots.len);
            errdefer allocator.free(slots);
            var copied: usize = 0;
            errdefer {
                for (slots[0..copied]) |*slot| slot.deinit(allocator);
            }
            for (literal.slots, 0..) |slot, idx| {
                slots[idx] = try cloneVTableSlot(allocator, slot);
                copied += 1;
            }
            return .{ .vtable = .{ .slots = slots } };
        },
    }
}

fn cloneConstDecl(
    allocator: std.mem.Allocator,
    source: ConstDecl,
    source_line_offset: u32,
    expanded_line_offset: u32,
) !ConstDecl {
    const raw_text = try allocator.dupe(u8, source.raw_text);
    errdefer allocator.free(raw_text);
    const name = try allocator.dupe(u8, source.name);
    errdefer allocator.free(name);
    const literal_text = try allocator.dupe(u8, source.literal_text);
    errdefer allocator.free(literal_text);
    var value = try cloneConstValue(allocator, source.value);
    errdefer value.deinit(allocator);

    var upstream_loc: ?common_upstream.UpstreamLoc = null;
    if (source.upstream_loc) |loc| {
        upstream_loc = .{
            .file = try allocator.dupe(u8, loc.file),
            .line = loc.line,
            .col = loc.col,
        };
    }
    errdefer if (upstream_loc) |loc| allocator.free(loc.file);

    return .{
        .source_line = try std.math.add(u32, source.source_line, source_line_offset),
        .expanded_line = try std.math.add(u32, source.expanded_line, expanded_line_offset),
        .upstream_loc = upstream_loc,
        .raw_text = raw_text,
        .name = name,
        .literal_text = literal_text,
        .value = value,
    };
}

fn bytesLiteralEql(a: common_const_decl.BytesLiteral, b: common_const_decl.BytesLiteral) bool {
    return a.kind == b.kind and
        std.mem.eql(u8, a.bytes, b.bytes) and
        a.repeat_count == b.repeat_count and
        a.repeat_byte == b.repeat_byte;
}

fn constValueEql(a: common_const_decl.ConstValue, b: common_const_decl.ConstValue) bool {
    switch (a) {
        .hex => |a_lit| return switch (b) {
            .hex => |b_lit| bytesLiteralEql(a_lit, b_lit),
            else => false,
        },
        .utf8 => |a_lit| return switch (b) {
            .utf8 => |b_lit| bytesLiteralEql(a_lit, b_lit),
            else => false,
        },
        .repeat => |a_lit| return switch (b) {
            .repeat => |b_lit| bytesLiteralEql(a_lit, b_lit),
            else => false,
        },
        .struct_ => |a_lit| return switch (b) {
            .struct_ => |b_lit| structLiteralEql(a_lit, b_lit),
            else => false,
        },
        .vtable => |a_lit| return switch (b) {
            .vtable => |b_lit| vtableLiteralEql(a_lit, b_lit),
            else => false,
        },
    }
}

fn structLiteralEql(a: common_const_decl.StructLiteral, b: common_const_decl.StructLiteral) bool {
    if (a.fields.len != b.fields.len) return false;
    for (a.fields, b.fields) |a_field, b_field| {
        if (!std.mem.eql(u8, a_field.name, b_field.name)) return false;
        if (a_field.size != b_field.size) return false;
        if (!constValueEql(a_field.value, b_field.value)) return false;
    }
    return true;
}

fn vtableLiteralEql(a: common_const_decl.VTableLiteral, b: common_const_decl.VTableLiteral) bool {
    if (a.slots.len != b.slots.len) return false;
    for (a.slots, b.slots) |a_slot, b_slot| {
        if (!std.mem.eql(u8, a_slot.name, b_slot.name)) return false;
        if (!std.mem.eql(u8, a_slot.func_name, b_slot.func_name)) return false;
    }
    return true;
}

fn mergeDefDictAllowingIdentical(target: *DefDict, source: *const DefDict) !void {
    var it = source.entries.iterator();
    while (it.next()) |entry| {
        if (target.entries.get(entry.key_ptr.*)) |existing| {
            if (!std.mem.eql(u8, existing, entry.value_ptr.*)) return error.DuplicateDef;
            continue;
        }
        const key_copy = try target.allocator.dupe(u8, entry.key_ptr.*);
        errdefer target.allocator.free(key_copy);
        const value_copy = try target.allocator.dupe(u8, entry.value_ptr.*);
        errdefer target.allocator.free(value_copy);
        try target.entries.put(key_copy, value_copy);
    }
    var bind_it = source.npm_binds.iterator();
    while (bind_it.next()) |entry| {
        if (target.npm_binds.get(entry.key_ptr.*)) |existing| {
            if (!std.mem.eql(u8, existing, entry.value_ptr.*)) return error.DuplicateDef;
            continue;
        }
        const key_copy = try target.allocator.dupe(u8, entry.key_ptr.*);
        errdefer target.allocator.free(key_copy);
        const value_copy = try target.allocator.dupe(u8, entry.value_ptr.*);
        errdefer target.allocator.free(value_copy);
        try target.npm_binds.put(key_copy, value_copy);
    }
}

fn mergeConstDeclsAllowingIdentical(
    allocator: std.mem.Allocator,
    target: *std.array_list.Managed(ConstDecl),
    source: []const ConstDecl,
    source_line_offset: u32,
    expanded_line_offset: u32,
) !void {
    for (source) |decl| {
        var existing: ?*ConstDecl = null;
        for (target.items) |*item| {
            if (std.mem.eql(u8, item.name, decl.name)) {
                existing = item;
                break;
            }
        }
        if (existing) |item| {
            if (!constValueEql(item.value, decl.value)) return error.DuplicateConstDecl;
            continue;
        }
        const cloned = try cloneConstDecl(allocator, decl, source_line_offset, expanded_line_offset);
        errdefer {
            var cleanup = cloned;
            cleanup.deinit(allocator);
        }
        try target.append(cloned);
    }
}

fn cloneLayoutVersion(allocator: std.mem.Allocator, source: LayoutVersion) !LayoutVersion {
    return .{
        .path = try allocator.dupe(u8, source.path),
        .version = source.version,
    };
}

fn mergeLayoutVersionsAllowingIdentical(
    allocator: std.mem.Allocator,
    target: *std.array_list.Managed(LayoutVersion),
    source: []const LayoutVersion,
) !void {
    for (source) |layout_version| {
        var existing: ?*LayoutVersion = null;
        for (target.items) |*item| {
            if (std.mem.eql(u8, item.path, layout_version.path)) {
                existing = item;
                break;
            }
        }
        if (existing) |item| {
            if (item.version != layout_version.version) return error.LayoutVersionConflict;
            continue;
        }
        const cloned = try cloneLayoutVersion(allocator, layout_version);
        errdefer {
            var cleanup = cloned;
            cleanup.deinit(allocator);
        }
        try target.append(cloned);
    }
}

fn mergePackageIdentities(
    allocator: std.mem.Allocator,
    target: *std.StringHashMap(void),
    source: *const std.StringHashMap(void),
) !void {
    var it = source.iterator();
    while (it.next()) |entry| {
        if (target.contains(entry.key_ptr.*)) continue;
        const copy = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(copy);
        try target.put(copy, {});
    }
}

fn appendFlattenFragment(
    allocator: std.mem.Allocator,
    target_instructions: *std.array_list.Managed(Instruction),
    target_const_decls: *std.array_list.Managed(ConstDecl),
    target_function_sigs: *std.array_list.Managed(FunctionSig),
    target_test_sigs: *std.array_list.Managed(FunctionSig),
    target_def_dict: *DefDict,
    target_symbols: *SymbolTable,
    target_layout_versions: *std.array_list.Managed(LayoutVersion),
    target_package_identities: *std.StringHashMap(void),
    target_owned_text: *std.array_list.Managed([]const u8),
    target_macros: *std.StringHashMap(MacroDef),
    fragment: *const FlattenResult,
    source_line_offset: u32,
    expanded_line_offset: u32,
) !void {
    const remap = try buildSymbolIdRemap(allocator, &fragment.symbols, target_symbols);
    defer allocator.free(remap);

    try mergeDefDictAllowingIdentical(target_def_dict, &fragment.def_dict);
    try mergeConstDeclsAllowingIdentical(
        allocator,
        target_const_decls,
        fragment.const_decls,
        source_line_offset,
        expanded_line_offset,
    );
    try mergeLayoutVersionsAllowingIdentical(allocator, target_layout_versions, fragment.layout_versions);
    try mergePackageIdentities(allocator, target_package_identities, &fragment.package_identities);
    try restoreCachedMacroDefs(allocator, fragment.cached_macro_defs, target_macros);

    const function_id_offset: u32 = @intCast(target_function_sigs.items.len);
    const entry_inst_offset: u32 = @intCast(target_instructions.items.len);
    for (fragment.instructions) |instruction| {
        const cloned = try cloneRemappedInstruction(
            allocator,
            target_owned_text,
            instruction,
            &fragment.symbols,
            target_symbols,
            remap,
            source_line_offset,
            expanded_line_offset,
        );
        try target_instructions.append(cloned);
    }

    for (fragment.function_sigs) |sig| {
        const cloned = try cloneRemappedFunctionSig(
            allocator,
            sig,
            remap,
            function_id_offset,
            entry_inst_offset,
        );
        try target_function_sigs.append(cloned);
        if (cloned.kind == .test_func) {
            try target_test_sigs.append(try cloneExactFunctionSig(allocator, cloned));
        }
    }
}

fn cloneRemappedOperand(
    allocator: std.mem.Allocator,
    owned_text: *std.array_list.Managed([]const u8),
    operand: Operand,
    source_symbols: *const SymbolTable,
    target_symbols: *const SymbolTable,
    remap: []const u32,
) !Operand {
    return switch (operand) {
        .reg => |old_id| .{ .reg = try remapSymbolId(remap, old_id) },
        .symbol => |old_id| .{ .symbol = try remapSymbolId(remap, old_id) },
        .label => |old_id| .{ .label = try remapSymbolId(remap, old_id) },
        .func => |old_id| .{ .func = try remapSymbolId(remap, old_id) },
        .text => |text| .{ .text = try cloneRemappedSymbolText(allocator, owned_text, text, source_symbols, target_symbols, remap) },
        .native_text => |text| .{ .native_text = try cloneRemappedSymbolText(allocator, owned_text, text, source_symbols, target_symbols, remap) },
        else => operand,
    };
}

fn cloneNativeRegNames(
    allocator: std.mem.Allocator,
    owned_text: *std.array_list.Managed([]const u8),
    source: Instruction,
    cloned_native_text: ?[]const u8,
) ![]const []const u8 {
    if (source.native_reg_names.len == 0) return &.{};
    if (cloned_native_text) |native_text| return try classifier.collectNativeRegisterNames(allocator, native_text);

    const out = try allocator.alloc([]const u8, source.native_reg_names.len);
    errdefer allocator.free(out);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |name| {
            for (owned_text.items, 0..) |owned, idx| {
                if (owned.ptr == name.ptr and owned.len == name.len) {
                    _ = owned_text.orderedRemove(idx);
                    allocator.free(owned);
                    break;
                }
            }
        }
    }
    for (source.native_reg_names, 0..) |name, idx| {
        out[idx] = try ownText(allocator, owned_text, name);
        copied += 1;
    }
    return out;
}

fn cloneRemappedInstruction(
    allocator: std.mem.Allocator,
    owned_text: *std.array_list.Managed([]const u8),
    source: Instruction,
    source_symbols: *const SymbolTable,
    target_symbols: *const SymbolTable,
    remap: []const u32,
    source_line_offset: u32,
    expanded_line_offset: u32,
) !Instruction {
    const owned_start = owned_text.items.len;
    errdefer {
        while (owned_text.items.len > owned_start) {
            const text = owned_text.pop().?;
            allocator.free(text);
        }
    }

    var out = common_instruction.makeInstruction(
        source.kind,
        try std.math.add(u32, source.source_line, source_line_offset),
        try std.math.add(u32, source.expanded_line, expanded_line_offset),
        null,
        try cloneRemappedSymbolText(allocator, owned_text, source.raw_text, source_symbols, target_symbols, remap),
    );
    errdefer {
        if (out.package_identity) |identity| allocator.free(identity);
        if (out.upstream_loc) |loc| allocator.free(loc.file);
        if (out.native_reg_names.len != 0) allocator.free(out.native_reg_names);
    }

    if (source.package_identity) |identity| {
        out.package_identity = try allocator.dupe(u8, identity);
    }
    out.package_source_sha256 = source.package_source_sha256;
    if (source.upstream_loc) |loc| {
        out.upstream_loc = .{
            .file = try allocator.dupe(u8, loc.file),
            .line = loc.line,
            .col = loc.col,
        };
    }
    out.op_kind = source.op_kind;
    out.atomic_value_ty = source.atomic_value_ty;
    out.atomic_ordering = source.atomic_ordering;
    out.atomic_second_ordering = source.atomic_second_ordering;
    out.atomic_rmw_op = source.atomic_rmw_op;
    if (source.atomic_expected_text) |text| {
        out.atomic_expected_text = try cloneRemappedSymbolText(allocator, owned_text, text, source_symbols, target_symbols, remap);
    }
    if (source.atomic_new_text) |text| {
        out.atomic_new_text = try cloneRemappedSymbolText(allocator, owned_text, text, source_symbols, target_symbols, remap);
    }

    var cloned_native_text: ?[]const u8 = null;
    for (&out.operands, source.operands) |*dst, operand| {
        dst.* = try cloneRemappedOperand(allocator, owned_text, operand, source_symbols, target_symbols, remap);
        switch (dst.*) {
            .native_text => |text| cloned_native_text = text,
            else => {},
        }
    }
    out.native_reg_names = try cloneNativeRegNames(allocator, owned_text, source, cloned_native_text);
    return out;
}

fn appendOwnedSource(out: *std.array_list.Managed(u8), source: []const u8) !void {
    if (source.len == 0) return;
    const needs_newline = source[source.len - 1] != '\n';
    try out.ensureUnusedCapacity(source.len + @intFromBool(needs_newline));
    try out.appendSlice(source);
    if (needs_newline) try out.append('\n');
}

fn parseImportPath(line: []const u8) ?[]const u8 {
    const classified = classifier.classifyLine(line);
    if (classified.kind != .import_decl) return null;
    return classified.parts[0];
}

fn readImportFile(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    import_path: []const u8,
    resolve_ctx: ?ResolveContext,
) !pkg_resolver.ResolvedImport {
    const use_cache = try isImportCacheCandidate(allocator, base_dir, import_path, resolve_ctx);
    if (!use_cache) {
        const deps = if (resolve_ctx) |ctx| ctx.dependencies else &.{};
        var options: pkg_resolver.ResolveOptions = .{};
        if (resolve_ctx) |ctx| options = ctx.options;
        return try pkg_resolver.resolveImport(allocator, deps, base_dir, import_path, options);
    }

    const cache_key = try buildImportSourceCacheKey(allocator, base_dir, import_path, resolve_ctx);
    defer allocator.free(cache_key);

    while (!import_source_cache_mutex.tryLock()) { std.Thread.yield() catch {}; }
    if (import_source_cache) |*cache| {
        if (cache.getPtr(cache_key)) |cached| {
            if (cachedImportStillValid(cached.*)) {
                const max_entries = importSourceCacheMaxEntries();
                cached.last_used_tick = nextImportSourceCacheTickLocked();
                const cloned = cloneCachedImport(allocator, cached.*, max_entries == null) catch |err| {
                    import_source_cache_mutex.unlock();
                    return err;
                };
                import_source_cache_mutex.unlock();
                return cloned;
            }
            if (cache.fetchRemove(cache_key)) |removed| {
                std.heap.page_allocator.free(removed.key);
                // Default cache hits borrow source slices, so invalidated source buffers stay process-live.
                freeImportSourceCacheEntry(removed.value, false);
            }
        }
    }
    import_source_cache_mutex.unlock();

    const deps = if (resolve_ctx) |ctx| ctx.dependencies else &.{};
    var options: pkg_resolver.ResolveOptions = .{};
    if (resolve_ctx) |ctx| options = ctx.options;
    const resolved = try pkg_resolver.resolveImport(allocator, deps, base_dir, import_path, options);
    storeImportSourceCacheEntry(cache_key, resolved) catch |err| {
        // Import source caching is an optimization; resolution already succeeded and remains authoritative.
        _ = @errorName(err);
    };
    return resolved;
}

pub fn readImportSourceFile(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    import_path: []const u8,
    resolve_ctx: ?ResolveContext,
) !pkg_resolver.ResolvedImport {
    return try readImportFile(allocator, base_dir, import_path, resolve_ctx);
}

fn pathJoin(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return try std.fs.path.join(allocator, parts);
}

fn pathStem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return base[0..dot];
}

fn packageNamespacePrefix(allocator: std.mem.Allocator, package_identity: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, package_identity, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPath;

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice("pkg_");

    for (trimmed) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9' => try out.append(c),
            '_' => try out.appendSlice("_us_"),
            '.' => try out.appendSlice("_dot_"),
            '/' => try out.appendSlice("_slash_"),
            '-' => try out.appendSlice("_dash_"),
            ':' => try out.appendSlice("_colon_"),
            '@' => try out.appendSlice("_at_"),
            '+' => try out.appendSlice("_plus_"),
            '~' => try out.appendSlice("_tilde_"),
            else => {
                try out.appendSlice("_x");
                var hex_c_buf: [2]u8 = undefined;
                const hex_c = std.fmt.bufPrint(&hex_c_buf, "{X:0>2}", .{c}) catch unreachable;
                try out.appendSlice(hex_c);
                try out.append('_');
            },
        }
    }

    return try out.toOwnedSlice();
}

fn rememberPackageIdentity(
    allocator: std.mem.Allocator,
    seen_package_identities: *std.StringHashMap(void),
    package_identity: []const u8,
) ![]const u8 {
    if (seen_package_identities.getKeyPtr(package_identity)) |key_ptr| return key_ptr.*;

    const copy = try allocator.dupe(u8, package_identity);
    errdefer allocator.free(copy);
    try seen_package_identities.put(copy, {});
    return copy;
}

fn containsText(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn rewritePackageLayoutExpr(
    allocator: std.mem.Allocator,
    expr: []const u8,
    prefix: []const u8,
    local_defs: []const []const u8,
) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var idx: usize = 0;
    while (idx < expr.len) {
        if (std.ascii.isAlphabetic(expr[idx]) or expr[idx] == '_') {
            const start = idx;
            idx += 1;
            while (idx < expr.len and (std.ascii.isAlphanumeric(expr[idx]) or expr[idx] == '_' or expr[idx] == '.')) : (idx += 1) {}
            const token = expr[start..idx];
            if (containsText(local_defs, token)) {
                try out.appendSlice(prefix);
                try out.append('.');
                try out.appendSlice(token);
            } else {
                try out.appendSlice(token);
            }
            continue;
        }
        try out.append(expr[idx]);
        idx += 1;
    }

    return try out.toOwnedSlice();
}

fn rewritePackageLayoutSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    package_identity: []const u8,
) ![]u8 {
    const prefix = try packageNamespacePrefix(allocator, package_identity);
    defer allocator.free(prefix);

    var local_defs = std.array_list.Managed([]const u8).init(allocator);
    defer local_defs.deinit();

    var collector = std.mem.splitScalar(u8, source, '\n');
    while (collector.next()) |raw_line| {
        const classified = classifier.classifyLine(raw_line);
        if (classified.kind == .def) {
            try local_defs.append(classified.parts[0]);
        }
    }

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var iterator = std.mem.splitScalar(u8, source, '\n');
    var first_line = true;
    while (iterator.next()) |raw_line| {
        if (!first_line) try out.append('\n');
        first_line = false;

        const classified = classifier.classifyLine(raw_line);
        switch (classified.kind) {
            .def => {
                const rewritten_rhs = try rewritePackageLayoutExpr(allocator, classified.parts[1], prefix, local_defs.items);
                defer allocator.free(rewritten_rhs);
                try out.appendSlice("#def ");
                try out.appendSlice(prefix);
                try out.append('.');
                try out.appendSlice(classified.parts[0]);
                try out.appendSlice(" = ");
                try out.appendSlice(rewritten_rhs);
            },
            else => try out.appendSlice(raw_line),
        }
    }

    if (source.len != 0 and source[source.len - 1] == '\n') {
        try out.append('\n');
    }

    return try out.toOwnedSlice();
}

fn injectImportedFile(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(u8),
    line_package_identities: *std.array_list.Managed(?[]const u8),
    line_package_hashes: *std.array_list.Managed(?[32]u8),
    imported: *pkg_resolver.ResolvedImport,
    active_paths: *std.StringHashMap(void),
    seen_paths: *std.StringHashMap(void),
    seen_package_identities: *std.StringHashMap(void),
    owned_paths: *std.array_list.Managed([]u8),
    layout_versions: *std.array_list.Managed(LayoutVersion),
    error_ctx: ?*ErrorContext,
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
    resolve_ctx: ?ResolveContext,
    cache_dependency: ?*ExpandedImportCacheDependency,
) anyerror!void {
    const entry_path = imported.entry_path;
    if (!std.mem.endsWith(u8, entry_path, ".sa")) return;

    const effective_package_identity = if (imported.package_identity) |identity| blk: {
        break :blk try rememberPackageIdentity(allocator, seen_package_identities, identity);
    } else if (!imported.is_global) blk: {
        if (current_package_identity) |identity| {
            break :blk try rememberPackageIdentity(allocator, seen_package_identities, identity);
        }
        break :blk null;
    } else null;

    const import_dir = std.fs.path.dirname(entry_path) orelse ".";
    const stem = pathStem(entry_path);
    const iface_name = try std.fmt.allocPrint(allocator, "{s}.sai", .{stem});
    defer allocator.free(iface_name);
    const layout_name = try std.fmt.allocPrint(allocator, "{s}.sal", .{stem});
    defer allocator.free(layout_name);

    const injected_root = struct {
        fn run(
            allocator2: std.mem.Allocator,
            out2: *std.array_list.Managed(u8),
            line_package_identities2: *std.array_list.Managed(?[]const u8),
            line_package_hashes2: *std.array_list.Managed(?[32]u8),
            base_dir: []const u8,
            file_name: []const u8,
            active_paths2: *std.StringHashMap(void),
            seen_paths2: *std.StringHashMap(void),
            seen_package_identities2: *std.StringHashMap(void),
            owned_paths2: *std.array_list.Managed([]u8),
            layout_versions2: *std.array_list.Managed(LayoutVersion),
            error_ctx2: ?*ErrorContext,
            current_package_identity2: ?[]const u8,
            current_package_hash2: ?[32]u8,
            resolve_ctx2: ?ResolveContext,
            cache_dependency2: ?*ExpandedImportCacheDependency,
        ) anyerror!void {
            var injected = try readImportFile(allocator2, base_dir, file_name, resolve_ctx2);
            defer injected.deinit(allocator2);
            if (active_paths2.contains(injected.entry_path) or seen_paths2.contains(injected.entry_path)) {
                markSeenImportContextDependency(cache_dependency2, owned_paths2.items, injected.entry_path);
                return;
            }
            owned_paths2.append(injected.entry_path) catch |err| {
                injected.deinit(allocator2);
                return err;
            };
            injected.entry_path_owned = false;
            try seen_paths2.put(injected.entry_path, {});
            try active_paths2.put(injected.entry_path, {});
            defer _ = active_paths2.remove(injected.entry_path);

            const effective_child_package_identity = if (injected.package_identity) |identity|
                identity
            else if (!injected.is_global)
                current_package_identity2
            else
                null;
            const is_layout_file = std.mem.endsWith(u8, injected.entry_path, ".sal");
            var rewritten_source: ?[]u8 = null;
            defer if (rewritten_source) |rewritten| allocator2.free(rewritten);
            const expanded_source = if (is_layout_file) blk: {
                if (effective_child_package_identity) |identity| {
                    const rewritten = try rewritePackageLayoutSource(allocator2, injected.source, identity);
                    rewritten_source = rewritten;
                    break :blk rewritten;
                }
                break :blk injected.source;
            } else injected.source;

            if (is_layout_file) {
                try recordLayoutVersion(allocator2, layout_versions2, injected.entry_path, injected.source);
            }
            const injected_dir = std.fs.path.dirname(injected.entry_path) orelse ".";
            try expandImportsInto(
                allocator2,
                out2,
                line_package_identities2,
                line_package_hashes2,
                expanded_source,
                injected_dir,
                injected.entry_path,
                active_paths2,
                seen_paths2,
                seen_package_identities2,
                owned_paths2,
                layout_versions2,
                error_ctx2,
                effective_child_package_identity,
                current_package_hash2,
                resolve_ctx2,
                cache_dependency2,
            );
        }
    }.run;

    const iface_path = try pathJoin(allocator, &.{ import_dir, iface_name });
    defer allocator.free(iface_path);
    if (sio.cwd().access(iface_path, .{})) |_| {
        try injected_root(
            allocator,
            out,
            line_package_identities,
            line_package_hashes,
            import_dir,
            iface_name,
            active_paths,
            seen_paths,
            seen_package_identities,
            owned_paths,
            layout_versions,
            error_ctx,
            effective_package_identity,
            current_package_hash,
            resolve_ctx,
            cache_dependency,
        );
    } else |_| {}

    const layout_path = try pathJoin(allocator, &.{ import_dir, layout_name });
    defer allocator.free(layout_path);
    if (sio.cwd().access(layout_path, .{})) |_| {
        try injected_root(
            allocator,
            out,
            line_package_identities,
            line_package_hashes,
            import_dir,
            layout_name,
            active_paths,
            seen_paths,
            seen_package_identities,
            owned_paths,
            layout_versions,
            error_ctx,
            effective_package_identity,
            current_package_hash,
            resolve_ctx,
            cache_dependency,
        );
    } else |_| {}
}

fn expandImportsInto(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(u8),
    line_package_identities: *std.array_list.Managed(?[]const u8),
    line_package_hashes: *std.array_list.Managed(?[32]u8),
    source: []const u8,
    base_dir: []const u8,
    current_source_path: ?[]const u8,
    active_paths: *std.StringHashMap(void),
    seen_paths: *std.StringHashMap(void),
    seen_package_identities: *std.StringHashMap(void),
    owned_paths: *std.array_list.Managed([]u8),
    layout_versions: *std.array_list.Managed(LayoutVersion),
    error_ctx: ?*ErrorContext,
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
    resolve_ctx: ?ResolveContext,
    cache_dependency: ?*ExpandedImportCacheDependency,
) !void {
    const estimated_line_count = countSourceLines(source);
    try out.ensureUnusedCapacity(source.len +| 1);
    try line_package_identities.ensureUnusedCapacity(estimated_line_count);
    try line_package_hashes.ensureUnusedCapacity(estimated_line_count);

    var iterator = std.mem.splitScalar(u8, source, '\n');
    var line_no: u32 = 1;
    var explicit_loc_pending = false;
    while (iterator.next()) |raw_line| : (line_no += 1) {
        recordErrorSourceLine(error_ctx, line_no);
        if (parseImportPath(raw_line)) |import_path| {
            var imported = try readImportFile(allocator, base_dir, import_path, resolve_ctx);
            if (traceImportsEnabled()) {
                std.debug.print("\n[IMPORT] resolved '{s}' -> '{s}'\n", .{ import_path, imported.entry_path });
            }
            const imported_package_identity = if (imported.package_identity) |identity| blk: {
                break :blk try rememberPackageIdentity(allocator, seen_package_identities, identity);
            } else if (!imported.is_global) blk: {
                if (current_package_identity) |identity| {
                    break :blk try rememberPackageIdentity(allocator, seen_package_identities, identity);
                }
                break :blk null;
            } else null;
            const imported_package_hash = if (imported.package_identity != null)
                imported.source_sha256 orelse current_package_hash
            else
                current_package_hash;
            const expanded_cache_key = if (expandedImportCacheEligible(imported_package_identity, current_package_identity, current_package_hash))
                try buildImportSourceCacheKey(allocator, base_dir, import_path, resolve_ctx)
            else
                null;
            defer if (expanded_cache_key) |key| allocator.free(key);

            if (active_paths.contains(imported.entry_path)) {
                imported.deinit(allocator);
                return error.ImportCycle;
            }
            if (seen_paths.contains(imported.entry_path)) {
                markSeenImportContextDependency(cache_dependency, owned_paths.items, imported.entry_path);
                imported.deinit(allocator);
                continue;
            }
            if (expanded_cache_key) |key| {
                if (try appendExpandedImportCacheHit(
                    allocator,
                    key,
                    out,
                    line_package_identities,
                    line_package_hashes,
                    active_paths,
                    seen_paths,
                    owned_paths,
                    layout_versions,
                )) {
                    imported.deinit(allocator);
                    continue;
                }
            }
            const fragment_out_start = out.items.len;
            const fragment_line_start = line_package_identities.items.len;
            const fragment_owned_start = owned_paths.items.len;
            const fragment_layout_start = layout_versions.items.len;
            var fragment_dependency = ExpandedImportCacheDependency{
                .owned_start = fragment_owned_start,
                .parent = cache_dependency,
            };
            if (std.mem.endsWith(u8, imported.entry_path, ".sal")) {
                try recordLayoutVersion(allocator, layout_versions, imported.entry_path, imported.source);
            }
            owned_paths.append(imported.entry_path) catch |err| {
                imported.deinit(allocator);
                return err;
            };
            imported.entry_path_owned = false;
            defer imported.deinit(allocator);
            try seen_paths.put(imported.entry_path, {});
            try active_paths.put(imported.entry_path, {});
            defer _ = active_paths.remove(imported.entry_path);

            const import_dir = std.fs.path.dirname(imported.entry_path) orelse ".";
            try injectImportedFile(
                allocator,
                out,
                line_package_identities,
                line_package_hashes,
                &imported,
                active_paths,
                seen_paths,
                seen_package_identities,
                owned_paths,
                layout_versions,
                error_ctx,
                current_package_identity,
                imported_package_hash,
                resolve_ctx,
                &fragment_dependency,
            );
            const is_layout_file = std.mem.endsWith(u8, imported.entry_path, ".sal");
            var rewritten_source: ?[]u8 = null;
            defer if (rewritten_source) |rewritten| allocator.free(rewritten);
            const expanded_source = if (is_layout_file) blk: {
                if (imported_package_identity) |identity| {
                    const rewritten = try rewritePackageLayoutSource(allocator, imported.source, identity);
                    rewritten_source = rewritten;
                    break :blk rewritten;
                }
                break :blk imported.source;
            } else imported.source;
            try expandImportsInto(
                allocator,
                out,
                line_package_identities,
                line_package_hashes,
                expanded_source,
                import_dir,
                imported.entry_path,
                active_paths,
                seen_paths,
                seen_package_identities,
                owned_paths,
                layout_versions,
                error_ctx,
                imported_package_identity,
                imported_package_hash,
                resolve_ctx,
                &fragment_dependency,
            );
            if (expanded_cache_key) |key| {
                const fragment_identities = line_package_identities.items[fragment_line_start..];
                const fragment_hashes = line_package_hashes.items[fragment_line_start..];
                if (!fragment_dependency.context_dependent and lineMetadataCacheable(fragment_identities, fragment_hashes)) {
                    storeExpandedImportCacheEntry(
                        key,
                        out.items[fragment_out_start..],
                        fragment_identities.len,
                        owned_paths.items[fragment_owned_start..],
                        layout_versions.items[fragment_layout_start..],
                    ) catch |err| {
                        // Expanded import caching is an optimization; successful expansion remains authoritative.
                        _ = @errorName(err);
                    };
                }
            }
            continue;
        }

        const classified = classifier.classifyLine(raw_line);
        if (current_source_path) |path| {
            if (isFunctionLikeLineKind(classified.kind) and !explicit_loc_pending) {
                try appendGeneratedLocLine(allocator, out, line_package_identities, line_package_hashes, path, line_no, current_package_identity, current_package_hash);
            }
        }
        try appendExpandedLine(out, line_package_identities, line_package_hashes, raw_line, current_package_identity, current_package_hash);
        if (classified.kind == .loc_hint) {
            explicit_loc_pending = true;
        } else if (consumesPendingLoc(classified.kind)) {
            explicit_loc_pending = false;
        }
    }
}

pub fn expandImports(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_path: ?[]const u8,
    error_ctx: ?*ErrorContext,
    resolve_ctx: ?ResolveContext,
) !ImportExpansion {
    var active_paths = std.StringHashMap(void).init(allocator);
    errdefer active_paths.deinit();

    var seen_paths = std.StringHashMap(void).init(allocator);
    errdefer seen_paths.deinit();

    var seen_package_identities = std.StringHashMap(void).init(allocator);
    errdefer {
        var pkg_it = seen_package_identities.iterator();
        while (pkg_it.next()) |entry| allocator.free(entry.key_ptr.*);
        seen_package_identities.deinit();
    }

    var line_package_identities = std.array_list.Managed(?[]const u8).init(allocator);
    errdefer line_package_identities.deinit();

    var line_package_hashes = std.array_list.Managed(?[32]u8).init(allocator);
    errdefer line_package_hashes.deinit();

    var owned_paths = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (owned_paths.items) |path| allocator.free(path);
        owned_paths.deinit();
    }
    var layout_versions = std.array_list.Managed(LayoutVersion).init(allocator);
    errdefer {
        for (layout_versions.items) |*layout_version| layout_version.deinit(allocator);
        layout_versions.deinit();
    }

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    const base_dir = if (source_path) |path| std.fs.path.dirname(path) orelse "." else ".";
    var root_source_path: ?[]const u8 = null;
    if (source_path) |path| {
        const source_full = if (std.fs.path.isAbsolute(path))
            try allocator.dupe(u8, path)
        else
            try sio.cwd().realpathAlloc(allocator, path);
        owned_paths.append(source_full) catch |err| {
            allocator.free(source_full);
            return err;
        };
        root_source_path = source_full;
        try active_paths.put(source_full, {});
        try seen_paths.put(source_full, {});

        if (std.mem.endsWith(u8, source_full, ".sal")) {
            try recordLayoutVersion(allocator, &layout_versions, source_full, source);
        }
    }

    const current_package_identity = if (resolve_ctx) |ctx|
        if (ctx.package_identity) |identity|
            try rememberPackageIdentity(allocator, &seen_package_identities, identity)
        else
            null
    else
        null;
    try expandImportsInto(
        allocator,
        &out,
        &line_package_identities,
        &line_package_hashes,
        source,
        base_dir,
        root_source_path,
        &active_paths,
        &seen_paths,
        &seen_package_identities,
        &owned_paths,
        &layout_versions,
        error_ctx,
        current_package_identity,
        null,
        resolve_ctx,
        null,
    );

    return .{
        .source = try out.toOwnedSlice(),
        .active_paths = active_paths,
        .seen_paths = seen_paths,
        .seen_package_identities = seen_package_identities,
        .line_package_identities = line_package_identities,
        .line_package_hashes = line_package_hashes,
        .owned_paths = owned_paths,
        .layout_versions = layout_versions,
    };
}

pub fn findFirstForbiddenLine(source: []const u8) ?ForbiddenLine {
    var iterator = std.mem.splitScalar(u8, source, '\n');
    var line_no: u32 = 1;
    while (iterator.next()) |raw_line| : (line_no += 1) {
        const classified = classifier.classifyLine(raw_line);
        if (classified.kind == .native or classified.kind == .import_decl or classified.kind == .const_decl) continue;
        if (forbidden.findForbiddenSyntax(raw_line)) |hit| {
            return .{ .line_no = line_no, .hit = hit };
        }
    }
    return null;
}

fn flattenInternal(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_path: ?[]const u8,
    error_ctx: ?*ErrorContext,
    resolve_ctx: ?ResolveContext,
) !FlattenResult {
    if (error_ctx) |ctx| ctx.source_line = null;
    var expanded = try expandImports(allocator, source, source_path, error_ctx, resolve_ctx);
    defer expanded.deinit(allocator);

    if (findFirstForbiddenLine(expanded.source)) |_| {
        return error.ForbiddenSyntax;
    }

    var dict = DefDict.init(allocator);
    errdefer dict.deinit();
    var symbols = SymbolTable.init(allocator);
    errdefer symbols.deinit();
    var instructions = std.array_list.Managed(Instruction).init(allocator);
    errdefer {
        for (instructions.items) |*inst| {
            if (inst.package_identity) |identity| allocator.free(identity);
            if (inst.upstream_loc) |loc| {
                const is_func_decl = switch (inst.kind) {
                    .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => true,
                    else => false,
                };
                if (is_func_decl) allocator.free(loc.file);
            }
            // NOTE: atomic_expected/new_text alias owned_text entries (see
            // ownFoldedText) and native_reg_names items are slices into the
            // owned native_copy; both are freed via owned_text. Freeing them
            // here double-frees on the error path.
            if (inst.native_reg_names.len > 0) allocator.free(inst.native_reg_names);
        }
        instructions.deinit();
    }
    var const_decls = std.array_list.Managed(ConstDecl).init(allocator);
    errdefer {
        for (const_decls.items) |*decl| decl.deinit(allocator);
        const_decls.deinit();
    }
    var function_sigs = std.array_list.Managed(FunctionSig).init(allocator);
    errdefer {
        for (function_sigs.items) |*sig_item| sig_item.deinit(allocator);
        function_sigs.deinit();
    }
    var owned_text = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (owned_text.items) |text| allocator.free(text);
        owned_text.deinit();
    }
    var loc_table = std.array_list.Managed(?common_upstream.UpstreamLoc).init(allocator);
    errdefer {
        for (loc_table.items) |entry| {
            if (entry) |loc| allocator.free(loc.file);
        }
        loc_table.deinit();
    }
    var pending_loc: ?common_upstream.UpstreamLoc = null;
    errdefer if (pending_loc) |loc| allocator.free(loc.file);

    var macros = std.StringHashMap(MacroDef).init(allocator);
    defer deinitMacroMap(allocator, &macros);

    var include_stack = std.array_list.Managed([]const u8).init(allocator);
    defer include_stack.deinit();
    var macro_call_stack = std.array_list.Managed(*const MacroDef).init(allocator);
    defer macro_call_stack.deinit();

    const lines = try scanSource(allocator, expanded.source, expanded.line_package_identities.items[0..], expanded.line_package_hashes.items[0..]);
    defer allocator.free(lines);

    try collectMacroDefinitions(allocator, lines, &macros, error_ctx);
    const cached_macro_defs = try captureCachedMacroDefs(allocator, &macros);
    errdefer deinitCachedMacroDefs(allocator, cached_macro_defs);
    const empty_replacements = [_]Replacement{};
    var expansion_counter: u64 = 0;
    emitRange(
        allocator,
        lines,
        0,
        lines.len,
        0,
        null,
        source_path,
        &include_stack,
        &macro_call_stack,
        empty_replacements[0..],
        true,
        &macros,
        &dict,
        &symbols,
        &loc_table,
        &pending_loc,
        &instructions,
        &const_decls,
        &function_sigs,
        &owned_text,
        error_ctx,
        null,
        null,
        &expansion_counter,
    ) catch |err| return err;
    if (pending_loc) |loc| {
        allocator.free(loc.file);
        pending_loc = null;
    }

    // `#npm_bind` targets must name a declared `@extern`; anything else
    // (unknown names, non-extern functions) is rejected here so backends
    // never see a dangling binding.
    {
        var bind_it = dict.npm_binds.iterator();
        while (bind_it.next()) |entry| {
            var found = false;
            for (function_sigs.items) |sig| {
                if (sig.kind == .external and std.mem.eql(u8, sig.name, entry.key_ptr.*)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.UnknownNpmBindTarget;
        }
    }

    const loc_table_slice = try collectLocTableEntries(allocator, instructions.items);
    const layout_versions = try expanded.layout_versions.toOwnedSlice();
    const package_identities = expanded.seen_package_identities;
    expanded.seen_package_identities = std.StringHashMap(void).init(allocator);
    loc_table.deinit();

    const function_sigs_slice = try function_sigs.toOwnedSlice();

    // Filter test functions from function_sigs
    var test_sigs_list = std.array_list.Managed(FunctionSig).init(allocator);
    errdefer test_sigs_list.deinit();
    for (function_sigs_slice) |sig| {
        if (sig.kind == .test_func) {
            try test_sigs_list.append(sig);
        }
    }

    return .{
        .instructions = try instructions.toOwnedSlice(),
        .const_decls = try const_decls.toOwnedSlice(),
        .function_sigs = function_sigs_slice,
        .test_sigs = try test_sigs_list.toOwnedSlice(),
        .cached_macro_defs = cached_macro_defs,
        .def_dict = dict,
        .symbols = symbols,
        .loc_table = loc_table_slice,
        .layout_versions = layout_versions,
        .package_identities = package_identities,
        .owned_text = try owned_text.toOwnedSlice(),
        .trap = null,
    };
}

pub fn flatten(allocator: std.mem.Allocator, source: []const u8) !FlattenResult {
    return flattenInternal(allocator, source, null, null, null);
}

pub fn flattenWithContext(allocator: std.mem.Allocator, source: []const u8, error_ctx: ?*ErrorContext) !FlattenResult {
    return flattenInternal(allocator, source, null, error_ctx, null);
}

pub fn flattenFileWithContext(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    source: []const u8,
    error_ctx: ?*ErrorContext,
) !FlattenResult {
    return flattenInternal(allocator, source, source_path, error_ctx, null);
}

pub fn flattenFile(allocator: std.mem.Allocator, source_path: []const u8, source: []const u8) !FlattenResult {
    return flattenInternal(allocator, source, source_path, null, null);
}

pub fn flattenWithPackages(
    allocator: std.mem.Allocator,
    source: []const u8,
    resolve_ctx: ResolveContext,
) !FlattenResult {
    return flattenInternal(allocator, source, null, null, resolve_ctx);
}

pub fn flattenWithContextAndPackages(
    allocator: std.mem.Allocator,
    source: []const u8,
    error_ctx: ?*ErrorContext,
    resolve_ctx: ResolveContext,
) !FlattenResult {
    return flattenInternal(allocator, source, null, error_ctx, resolve_ctx);
}

pub fn flattenFileWithPackages(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    source: []const u8,
    resolve_ctx: ResolveContext,
) !FlattenResult {
    return flattenInternal(allocator, source, source_path, null, resolve_ctx);
}

pub fn flattenFileWithContextAndPackages(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    source: []const u8,
    error_ctx: ?*ErrorContext,
    resolve_ctx: ResolveContext,
) !FlattenResult {
    return flattenInternal(allocator, source, source_path, error_ctx, resolve_ctx);
}

const MacroPbtProgram = struct {
    source: []u8,
    base_name: []u8,
    acc_name: []u8,
    alloc_size: u64,
    count: u8,

    fn deinit(self: *MacroPbtProgram, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.base_name);
        allocator.free(self.acc_name);
        self.* = undefined;
    }
};

fn buildMacroPbtProgram(allocator: std.mem.Allocator, random: std.Random, iter: usize) !MacroPbtProgram {
    const count = random.intRangeAtMost(u8, 0, 4);
    const alloc_size = random.intRangeAtMost(u64, 1, 64);
    const salt = random.intRangeAtMost(u32, 0, 9999);

    const base_name = try std.fmt.allocPrint(allocator, "base_{d}_{d}", .{ iter, salt });
    errdefer allocator.free(base_name);
    const acc_name = try std.fmt.allocPrint(allocator, "acc_{d}_{d}", .{ iter, salt });
    errdefer allocator.free(acc_name);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const writer = &aw.writer;
    try writer.writeAll(
        \\#def REP_COUNT = 
    );
    try writer.print("{d}\n", .{count});
    try writer.writeAll(
        \\[MACRO] INIT %acc, %base
        \\    %acc = add %base, 0
        \\[END_MACRO]
        \\
        \\[MACRO] CHAIN %acc, %base
        \\    EXPAND INIT %acc, %base
        \\    [REP REP_COUNT]
        \\        tmp_%i = add %acc, %i
        \\    [END_REP]
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\
    );
    try writer.print("    {s} = alloc {d}\n", .{ base_name, alloc_size });
    try writer.print("    EXPAND CHAIN {s}, {s}\n", .{ acc_name, base_name });
    try writer.print("    return {s}\n", .{acc_name});

    return .{
        .source = try aw.toOwnedSlice(),
        .base_name = base_name,
        .acc_name = acc_name,
        .alloc_size = alloc_size,
        .count = count,
    };
}

const ArithmeticExpr = struct {
    text: []u8,
    value: i64,

    fn deinit(self: *ArithmeticExpr, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

fn buildArithmeticExpr(allocator: std.mem.Allocator, random: std.Random, depth: u8) !ArithmeticExpr {
    if (depth == 0 or random.intRangeAtMost(u8, 0, 3) == 0) {
        const raw = @as(i64, @intCast(random.intRangeAtMost(u32, 0, 9)));
        const signed = if (random.intRangeLessThan(u8, 0, 2) == 0) raw else -raw;
        return .{
            .text = try std.fmt.allocPrint(allocator, "{d}", .{signed}),
            .value = signed,
        };
    }

    var left = try buildArithmeticExpr(allocator, random, depth - 1);
    defer left.deinit(allocator);
    var right = try buildArithmeticExpr(allocator, random, depth - 1);
    defer right.deinit(allocator);

    const op_index = random.intRangeLessThan(u8, 0, 3);
    const op: u8 = switch (op_index) {
        0 => '+',
        1 => '-',
        else => '*',
    };
    const value: i64 = switch (op) {
        '+' => left.value + right.value,
        '-' => left.value - right.value,
        '*' => left.value * right.value,
        else => unreachable,
    };

    return .{
        .text = try std.fmt.allocPrint(allocator, "({s} {c} {s})", .{ left.text, op, right.text }),
        .value = value,
    };
}

fn expectOperandReg(inst: Instruction, index: usize, expected: u32) !void {
    switch (inst.operands[index]) {
        .reg => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}

fn expectOperandImmU64(inst: Instruction, index: usize, expected: u64) !void {
    switch (inst.operands[index]) {
        .imm_u64 => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}

fn expectOperandImmI64(inst: Instruction, index: usize, expected: i64) !void {
    switch (inst.operands[index]) {
        .imm_i64 => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}

fn expectRawText(inst: Instruction, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, inst.raw_text);
}

test "scanSource preserves line order and classification" {
    const source =
        \\#def SIZE = 16
        \\L_LOOP:
        \\node = alloc 8
    ;
    const lines = try scanSource(std.testing.allocator, source, &.{}, &.{});
    defer std.testing.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqual(@as(u32, 1), lines[0].line_no);
    try std.testing.expectEqual(LineKind.def, lines[0].classified.kind);
    try std.testing.expectEqual(LineKind.label, lines[1].classified.kind);
    try std.testing.expectEqual(LineKind.instruction, lines[2].classified.kind);
    try std.testing.expectEqual(InstructionForm.alloc, lines[2].classified.inst_form.?);
}

test "countSourceLines matches splitScalar line count" {
    try std.testing.expectEqual(@as(usize, 1), countSourceLines(""));
    try std.testing.expectEqual(@as(usize, 1), countSourceLines("one"));
    try std.testing.expectEqual(@as(usize, 2), countSourceLines("one\ntwo"));
    try std.testing.expectEqual(@as(usize, 3), countSourceLines("one\ntwo\n"));
}

test "symbol id remap rewrites instruction symbol operands" {
    var source_symbols = SymbolTable.init(std.testing.allocator);
    defer source_symbols.deinit();
    const reg_id = try source_symbols.intern("value");
    const label_id = try source_symbols.intern("L_DONE");
    const func_id = try source_symbols.intern("callee");

    var target_symbols = SymbolTable.init(std.testing.allocator);
    defer target_symbols.deinit();
    _ = try target_symbols.intern("preexisting");

    const remap = try buildSymbolIdRemap(std.testing.allocator, &source_symbols, &target_symbols);
    defer std.testing.allocator.free(remap);

    var instruction = common_instruction.makeInstruction(.call, 1, 0, null, "dst = call callee(value)");
    instruction.operands[0] = .{ .reg = reg_id };
    instruction.operands[1] = .{ .symbol = label_id };
    instruction.operands[2] = .{ .label = label_id };
    instruction.operands[3] = .{ .func = func_id };

    try remapInstructionSymbolIds(&instruction, remap);
    try std.testing.expectEqual(target_symbols.findId("value").?, instruction.operands[0].reg);
    try std.testing.expectEqual(target_symbols.findId("L_DONE").?, instruction.operands[1].symbol);
    try std.testing.expectEqual(target_symbols.findId("L_DONE").?, instruction.operands[2].label);
    try std.testing.expectEqual(target_symbols.findId("callee").?, instruction.operands[3].func);
    try std.testing.expect(target_symbols.findId("value").? != reg_id);
}

test "symbol id remap leaves non-symbol operands unchanged and rejects unknown ids" {
    var source_symbols = SymbolTable.init(std.testing.allocator);
    defer source_symbols.deinit();
    _ = try source_symbols.intern("value");

    var target_symbols = SymbolTable.init(std.testing.allocator);
    defer target_symbols.deinit();

    const remap = try buildSymbolIdRemap(std.testing.allocator, &source_symbols, &target_symbols);
    defer std.testing.allocator.free(remap);

    var text_operand = Operand{ .text = "value" };
    try remapOperandSymbolIds(&text_operand, remap);
    try std.testing.expectEqualStrings("value", text_operand.text);

    var imm_operand = Operand{ .imm_u64 = 42 };
    try remapOperandSymbolIds(&imm_operand, remap);
    try std.testing.expectEqual(@as(u64, 42), imm_operand.imm_u64);

    var invalid_operand = Operand{ .reg = 99 };
    try std.testing.expectError(error.InvalidOperand, remapOperandSymbolIds(&invalid_operand, remap));
}

test "symbol id remap clones function signature id slices" {
    var source_symbols = SymbolTable.init(std.testing.allocator);
    defer source_symbols.deinit();
    const a = try source_symbols.intern("a");
    const b = try source_symbols.intern("b");
    const c = try source_symbols.intern("c");

    var target_symbols = SymbolTable.init(std.testing.allocator);
    defer target_symbols.deinit();
    _ = try target_symbols.intern("occupied");

    const remap = try buildSymbolIdRemap(std.testing.allocator, &source_symbols, &target_symbols);
    defer std.testing.allocator.free(remap);

    const original = [_]u32{ a, b, c };
    const cloned = try cloneRemappedSymbolIdSlice(std.testing.allocator, original[0..], remap);
    defer std.testing.allocator.free(cloned);
    try std.testing.expectEqualSlices(u32, &.{ target_symbols.findId("a").?, target_symbols.findId("b").?, target_symbols.findId("c").? }, cloned);
    try std.testing.expect(cloned.ptr != original[0..].ptr);

    const empty = try cloneRemappedSymbolIdSlice(std.testing.allocator, &.{}, remap);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.InvalidOperand, cloneRemappedSymbolIdSlice(std.testing.allocator, &.{99}, remap));
}

test "symbol id remap clones full function signatures" {
    var source_symbols = SymbolTable.init(std.testing.allocator);
    defer source_symbols.deinit();
    _ = try source_symbols.intern("work");
    const lhs_id = try source_symbols.intern("lhs");
    const rhs_id = try source_symbols.intern("rhs");
    const tmp_id = try source_symbols.intern("tmp");

    var target_symbols = SymbolTable.init(std.testing.allocator);
    defer target_symbols.deinit();
    _ = try target_symbols.intern("occupied");
    const remap = try buildSymbolIdRemap(std.testing.allocator, &source_symbols, &target_symbols);
    defer std.testing.allocator.free(remap);

    const source_params = try std.testing.allocator.alloc(common_signature.ParamSpec, 2);
    source_params[0] = .{ .name = try std.testing.allocator.dupe(u8, "lhs"), .ty = .i64, .cap = .borrow };
    source_params[1] = .{ .name = try std.testing.allocator.dupe(u8, "rhs"), .ty = .i64, .cap = .move };

    var source_sig = FunctionSig{
        .id = 7,
        .name = try std.testing.allocator.dupe(u8, "work"),
        .params = source_params,
        .kind = .test_func,
        .return_cap = .move,
        .return_ty = .i64,
        .return_fallible = true,
        .entry_inst_idx = 12,
        .is_ffi_wrapper = false,
        .upstream_file = try std.testing.allocator.dupe(u8, "test.sa"),
        .upstream_loc = null,
        .param_ids = try std.testing.allocator.dupe(u32, &.{ lhs_id, rhs_id }),
        .reg_ids = try std.testing.allocator.dupe(u32, &.{ lhs_id, rhs_id, tmp_id }),
        .llvm_name = try std.testing.allocator.dupe(u8, "_saasm_test_7"),
        .ignored = true,
        .should_panic = true,
    };
    source_sig.upstream_loc = .{ .file = source_sig.upstream_file.?, .line = 9, .col = 4 };
    defer source_sig.deinit(std.testing.allocator);

    var cloned = try cloneRemappedFunctionSig(std.testing.allocator, source_sig, remap, 100, 200);
    defer cloned.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 107), cloned.id);
    try std.testing.expectEqual(@as(u32, 212), cloned.entry_inst_idx);
    try std.testing.expectEqualSlices(u32, &.{ target_symbols.findId("lhs").?, target_symbols.findId("rhs").? }, cloned.param_ids);
    try std.testing.expectEqualSlices(u32, &.{ target_symbols.findId("lhs").?, target_symbols.findId("rhs").?, target_symbols.findId("tmp").? }, cloned.reg_ids);
    try std.testing.expectEqualStrings("work", cloned.name);
    try std.testing.expectEqualStrings("lhs", cloned.params[0].name);
    try std.testing.expectEqual(common_signature.PrimType.i64, cloned.params[0].ty);
    try std.testing.expectEqual(common_instruction.CapPrefix.borrow, cloned.params[0].cap);
    try std.testing.expectEqualStrings("_saasm_test_107", cloned.llvm_name.?);
    try std.testing.expect(cloned.ignored);
    try std.testing.expect(cloned.should_panic);
    try std.testing.expect(cloned.name.ptr != source_sig.name.ptr);
    try std.testing.expect(cloned.params[0].name.ptr != source_sig.params[0].name.ptr);
    try std.testing.expect(cloned.param_ids.ptr != source_sig.param_ids.ptr);
    try std.testing.expect(cloned.reg_ids.ptr != source_sig.reg_ids.ptr);
    try std.testing.expect(cloned.upstream_file.?.ptr != source_sig.upstream_file.?.ptr);
    try std.testing.expectEqualStrings("test.sa", cloned.upstream_file.?);
    try std.testing.expectEqualStrings(cloned.upstream_file.?, cloned.upstream_loc.?.file);
    try std.testing.expectEqual(@as(u32, 9), cloned.upstream_loc.?.line);
    try std.testing.expectEqual(@as(u32, 4), cloned.upstream_loc.?.col);
}

test "symbol id remap rejects function signatures with unknown ids" {
    var source_symbols = SymbolTable.init(std.testing.allocator);
    defer source_symbols.deinit();
    const known = try source_symbols.intern("known");
    var target_symbols = SymbolTable.init(std.testing.allocator);
    defer target_symbols.deinit();
    const remap = try buildSymbolIdRemap(std.testing.allocator, &source_symbols, &target_symbols);
    defer std.testing.allocator.free(remap);

    var source_sig = FunctionSig{
        .id = 0,
        .name = try std.testing.allocator.dupe(u8, "missing"),
        .params = &.{},
        .kind = .normal,
        .return_cap = null,
        .return_ty = .void,
        .entry_inst_idx = 0,
        .is_ffi_wrapper = false,
        .param_ids = try std.testing.allocator.dupe(u32, &.{known}),
        .reg_ids = try std.testing.allocator.dupe(u32, &.{99}),
    };
    defer source_sig.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidOperand, cloneRemappedFunctionSig(std.testing.allocator, source_sig, remap, 0, 0));
}

test "frontend cache merge keeps identical defs and rejects conflicts" {
    var target = DefDict.init(std.testing.allocator);
    defer target.deinit();
    try target.putExpression("A", "1");

    var source = DefDict.init(std.testing.allocator);
    defer source.deinit();
    try source.putExpression("A", "1");
    try source.putExpression("B", "A + 1");

    const source_b = source.get("B").?;
    try mergeDefDictAllowingIdentical(&target, &source);
    try std.testing.expectEqual(@as(usize, 2), target.entries.count());
    try std.testing.expectEqualStrings("1", target.get("A").?);
    try std.testing.expectEqualStrings("2", target.get("B").?);
    try std.testing.expect(target.get("B").?.ptr != source_b.ptr);

    var conflict = DefDict.init(std.testing.allocator);
    defer conflict.deinit();
    try conflict.putExpression("A", "2");
    try std.testing.expectError(error.DuplicateDef, mergeDefDictAllowingIdentical(&target, &conflict));
}

test "frontend cache merge clones const declarations and rejects conflicts" {
    const upstream_file = try std.testing.allocator.dupe(u8, "module.sa");
    var source_decl = try common_const_decl.parseConstDecl(
        std.testing.allocator,
        "@const HELLO = utf8:\"hello\"",
        3,
        5,
        .{ .file = upstream_file, .line = 9, .col = 2 },
    );
    defer source_decl.deinit(std.testing.allocator);

    var target = std.array_list.Managed(ConstDecl).init(std.testing.allocator);
    defer {
        for (target.items) |*decl| decl.deinit(std.testing.allocator);
        target.deinit();
    }

    try mergeConstDeclsAllowingIdentical(std.testing.allocator, &target, &.{source_decl}, 10, 20);
    try std.testing.expectEqual(@as(usize, 1), target.items.len);
    try std.testing.expectEqual(@as(u32, 13), target.items[0].source_line);
    try std.testing.expectEqual(@as(u32, 25), target.items[0].expanded_line);
    try std.testing.expectEqualStrings("HELLO", target.items[0].name);
    try std.testing.expectEqualStrings("utf8:\"hello\"", target.items[0].literal_text);
    try std.testing.expect(target.items[0].raw_text.ptr != source_decl.raw_text.ptr);
    try std.testing.expect(target.items[0].name.ptr != source_decl.name.ptr);
    try std.testing.expect(target.items[0].literal_text.ptr != source_decl.literal_text.ptr);
    try std.testing.expect(target.items[0].upstream_loc.?.file.ptr != source_decl.upstream_loc.?.file.ptr);
    switch (target.items[0].value) {
        .utf8 => |literal| switch (source_decl.value) {
            .utf8 => |source_literal| {
                try std.testing.expectEqualStrings("hello", literal.bytes);
                try std.testing.expect(literal.bytes.ptr != source_literal.bytes.ptr);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    try mergeConstDeclsAllowingIdentical(std.testing.allocator, &target, &.{source_decl}, 100, 100);
    try std.testing.expectEqual(@as(usize, 1), target.items.len);

    var conflict = try common_const_decl.parseConstDecl(
        std.testing.allocator,
        "@const HELLO = utf8:\"bye\"",
        4,
        6,
        null,
    );
    defer conflict.deinit(std.testing.allocator);
    try std.testing.expectError(error.DuplicateConstDecl, mergeConstDeclsAllowingIdentical(std.testing.allocator, &target, &.{conflict}, 0, 0));
}

test "frontend cache clone remaps instruction symbols and owned metadata" {
    var source_symbols = SymbolTable.init(std.testing.allocator);
    defer source_symbols.deinit();
    const dst_id = try source_symbols.intern("dst");
    const callee_id = try source_symbols.intern("callee");

    var target_symbols = SymbolTable.init(std.testing.allocator);
    defer target_symbols.deinit();
    _ = try target_symbols.intern("occupied");
    const remap = try buildSymbolIdRemap(std.testing.allocator, &source_symbols, &target_symbols);
    defer std.testing.allocator.free(remap);

    var source = common_instruction.makeInstruction(
        .call,
        7,
        3,
        .{ .file = try std.testing.allocator.dupe(u8, "source.sa"), .line = 40, .col = 5 },
        "dst = call callee(value)",
    );
    defer std.testing.allocator.free(source.upstream_loc.?.file);
    source.package_identity = try std.testing.allocator.dupe(u8, "pkg/core");
    defer std.testing.allocator.free(source.package_identity.?);
    source.package_source_sha256 = @splat(@as(u8, 7));
    source.operands[0] = .{ .reg = dst_id };
    source.operands[1] = .{ .func = callee_id };
    source.operands[2] = .{ .text = "borrow" };
    source.atomic_expected_text = "old";
    source.atomic_new_text = "new";

    var owned_text = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer {
        for (owned_text.items) |text| std.testing.allocator.free(text);
        owned_text.deinit();
    }
    const cloned = try cloneRemappedInstruction(std.testing.allocator, &owned_text, source, &source_symbols, &target_symbols, remap, 10, 20);
    defer {
        if (cloned.package_identity) |identity| std.testing.allocator.free(identity);
        if (cloned.upstream_loc) |loc| std.testing.allocator.free(loc.file);
        if (cloned.native_reg_names.len != 0) std.testing.allocator.free(cloned.native_reg_names);
    }

    try std.testing.expectEqual(InstKind.call, cloned.kind);
    try std.testing.expectEqual(@as(u32, 17), cloned.source_line);
    try std.testing.expectEqual(@as(u32, 23), cloned.expanded_line);
    try std.testing.expectEqual(target_symbols.findId("dst").?, cloned.operands[0].reg);
    try std.testing.expectEqual(target_symbols.findId("callee").?, cloned.operands[1].func);
    try std.testing.expectEqualStrings("borrow", cloned.operands[2].text);
    try std.testing.expect(cloned.operands[2].text.ptr != source.operands[2].text.ptr);
    try std.testing.expectEqualStrings("dst = call callee(value)", cloned.raw_text);
    try std.testing.expect(cloned.raw_text.ptr != source.raw_text.ptr);
    try std.testing.expectEqualStrings("pkg/core", cloned.package_identity.?);
    try std.testing.expect(cloned.package_identity.?.ptr != source.package_identity.?.ptr);
    try std.testing.expectEqual(@as(u8, 7), cloned.package_source_sha256.?[0]);
    try std.testing.expectEqualStrings("source.sa", cloned.upstream_loc.?.file);
    try std.testing.expect(cloned.upstream_loc.?.file.ptr != source.upstream_loc.?.file.ptr);
    try std.testing.expectEqual(@as(u32, 40), cloned.upstream_loc.?.line);
    try std.testing.expectEqual(@as(u32, 5), cloned.upstream_loc.?.col);
    try std.testing.expectEqualStrings("old", cloned.atomic_expected_text.?);
    try std.testing.expectEqualStrings("new", cloned.atomic_new_text.?);
    try std.testing.expect(cloned.atomic_expected_text.?.ptr != source.atomic_expected_text.?.ptr);
    try std.testing.expect(cloned.atomic_new_text.?.ptr != source.atomic_new_text.?.ptr);
}

test "frontend cache clone remaps embedded call text tokens with operands" {
    var source_symbols = SymbolTable.init(std.testing.allocator);
    defer source_symbols.deinit();
    const dst_id = try source_symbols.intern("dst");
    const tmp_id = try source_symbols.intern("tmp_0");
    const callee_id = try source_symbols.intern("callee");
    const opaque_arg_id = try source_symbols.intern("__sla_macro_arg_0");

    var target_symbols = SymbolTable.init(std.testing.allocator);
    defer target_symbols.deinit();
    _ = try target_symbols.intern("occupied");
    const remapped_dst_id = try target_symbols.intern("__frag0_dst");
    const remapped_tmp_id = try target_symbols.intern("__frag1_tmp_0");
    const remapped_callee_id = try target_symbols.intern("renamed_callee");
    const remapped_opaque_arg_id = try target_symbols.intern("__frag2_arg");

    const remap = [_]u32{ remapped_dst_id, remapped_tmp_id, remapped_callee_id, remapped_opaque_arg_id };

    var source = common_instruction.makeInstruction(
        .call,
        11,
        4,
        null,
        "dst = call @callee(^tmp_0, &__sla_macro_arg_0, \"tmp_0\")",
    );
    source.operands[0] = .{ .reg = dst_id };
    source.operands[1] = .{ .text = "@callee(^tmp_0, &__sla_macro_arg_0, \"tmp_0\")" };
    source.atomic_expected_text = "tmp_0";
    source.atomic_new_text = "__sla_macro_arg_0";
    _ = tmp_id;
    _ = callee_id;
    _ = opaque_arg_id;

    var owned_text = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer {
        for (owned_text.items) |text| std.testing.allocator.free(text);
        owned_text.deinit();
    }
    const cloned = try cloneRemappedInstruction(std.testing.allocator, &owned_text, source, &source_symbols, &target_symbols, remap[0..], 0, 0);
    defer {
        if (cloned.package_identity) |identity| std.testing.allocator.free(identity);
        if (cloned.upstream_loc) |loc| std.testing.allocator.free(loc.file);
        if (cloned.native_reg_names.len != 0) std.testing.allocator.free(cloned.native_reg_names);
    }

    try std.testing.expectEqual(remapped_dst_id, cloned.operands[0].reg);
    try std.testing.expectEqualStrings("@renamed_callee(^__frag1_tmp_0, &__sla_macro_arg_0, \"tmp_0\")", cloned.operands[1].text);
    try std.testing.expectEqualStrings("__frag0_dst = call @renamed_callee(^__frag1_tmp_0, &__sla_macro_arg_0, \"tmp_0\")", cloned.raw_text);
    try std.testing.expectEqualStrings("__frag1_tmp_0", cloned.atomic_expected_text.?);
    try std.testing.expectEqualStrings("__sla_macro_arg_0", cloned.atomic_new_text.?);
}

test "frontend cache clone rebuilds native register name slices" {
    var source_symbols = SymbolTable.init(std.testing.allocator);
    defer source_symbols.deinit();
    var target_symbols = SymbolTable.init(std.testing.allocator);
    defer target_symbols.deinit();

    const native_text = "call side(ptr value, i32 7)";
    var source = common_instruction.makeInstruction(.native, 2, 1, null, "$call side(ptr value, i32 7)$");
    source.operands[0] = .{ .native_text = native_text };
    source.native_reg_names = try classifier.collectNativeRegisterNames(std.testing.allocator, native_text);
    defer std.testing.allocator.free(source.native_reg_names);

    var owned_text = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer {
        for (owned_text.items) |text| std.testing.allocator.free(text);
        owned_text.deinit();
    }
    const cloned = try cloneRemappedInstruction(std.testing.allocator, &owned_text, source, &source_symbols, &target_symbols, &.{}, 4, 8);
    defer {
        if (cloned.package_identity) |identity| std.testing.allocator.free(identity);
        if (cloned.upstream_loc) |loc| std.testing.allocator.free(loc.file);
        if (cloned.native_reg_names.len != 0) std.testing.allocator.free(cloned.native_reg_names);
    }

    try std.testing.expectEqual(InstKind.native, cloned.kind);
    try std.testing.expectEqual(@as(u32, 6), cloned.source_line);
    try std.testing.expectEqual(@as(u32, 9), cloned.expanded_line);
    try std.testing.expectEqualStrings(native_text, cloned.operands[0].native_text);
    try std.testing.expect(cloned.operands[0].native_text.ptr != source.operands[0].native_text.ptr);
    try std.testing.expectEqual(@as(usize, 5), cloned.native_reg_names.len);
    try std.testing.expectEqualStrings("call", cloned.native_reg_names[0]);
    try std.testing.expectEqualStrings("side", cloned.native_reg_names[1]);
    try std.testing.expectEqualStrings("ptr", cloned.native_reg_names[2]);
    try std.testing.expectEqualStrings("value", cloned.native_reg_names[3]);
    try std.testing.expectEqualStrings("i32", cloned.native_reg_names[4]);
    try std.testing.expect(cloned.native_reg_names[0].ptr != source.native_reg_names[0].ptr);
}

test "frontend cache merge package identities deep copies new keys" {
    var target = std.StringHashMap(void).init(std.testing.allocator);
    defer {
        var it = target.iterator();
        while (it.next()) |entry| std.testing.allocator.free(entry.key_ptr.*);
        target.deinit();
    }
    try target.put(try std.testing.allocator.dupe(u8, "pkg/a"), {});

    var source = std.StringHashMap(void).init(std.testing.allocator);
    defer {
        var it = source.iterator();
        while (it.next()) |entry| std.testing.allocator.free(entry.key_ptr.*);
        source.deinit();
    }
    try source.put(try std.testing.allocator.dupe(u8, "pkg/a"), {});
    try source.put(try std.testing.allocator.dupe(u8, "pkg/b"), {});
    const source_b_key = source.getKeyPtr("pkg/b").?.*;

    try mergePackageIdentities(std.testing.allocator, &target, &source);
    try std.testing.expectEqual(@as(u32, 2), target.count());
    const target_b_key = target.getKeyPtr("pkg/b").?.*;
    try std.testing.expectEqualStrings("pkg/b", target_b_key);
    try std.testing.expect(target_b_key.ptr != source_b_key.ptr);

    try mergePackageIdentities(std.testing.allocator, &target, &source);
    try std.testing.expectEqual(@as(u32, 2), target.count());
}

test "frontend cache merge layout versions skips identical and rejects conflicts" {
    var target = std.array_list.Managed(LayoutVersion).init(std.testing.allocator);
    defer {
        for (target.items) |*item| item.deinit(std.testing.allocator);
        target.deinit();
    }
    try target.append(.{ .path = try std.testing.allocator.dupe(u8, "a.sal"), .version = 1 });

    var source = [_]LayoutVersion{
        .{ .path = try std.testing.allocator.dupe(u8, "a.sal"), .version = 1 },
        .{ .path = try std.testing.allocator.dupe(u8, "b.sal"), .version = 2 },
    };
    defer for (&source) |*item| item.deinit(std.testing.allocator);

    try mergeLayoutVersionsAllowingIdentical(std.testing.allocator, &target, source[0..]);
    try std.testing.expectEqual(@as(usize, 2), target.items.len);
    try std.testing.expectEqualStrings("b.sal", target.items[1].path);
    try std.testing.expectEqual(@as(u64, 2), target.items[1].version);
    try std.testing.expect(target.items[1].path.ptr != source[1].path.ptr);

    var conflict = [_]LayoutVersion{
        .{ .path = try std.testing.allocator.dupe(u8, "a.sal"), .version = 99 },
    };
    defer for (&conflict) |*item| item.deinit(std.testing.allocator);
    try std.testing.expectError(error.LayoutVersionConflict, mergeLayoutVersionsAllowingIdentical(std.testing.allocator, &target, conflict[0..]));
}

test "frontend cache append fragment remaps and merges end to end" {
    const source =
        \\#def SIZE = 8
        \\@const HELLO = utf8:"hello"
        \\@main() -> i32:
        \\L_MAIN:
        \\tmp = alloc SIZE
        \\return 0
        \\@test should_panic "panic path"():
        \\L_TEST:
        \\panic 32
    ;
    var fragment = try flatten(std.testing.allocator, source);
    defer fragment.deinit(std.testing.allocator);

    std.testing.allocator.free(fragment.layout_versions);
    fragment.layout_versions = try std.testing.allocator.alloc(LayoutVersion, 1);
    fragment.layout_versions[0] = .{
        .path = try std.testing.allocator.dupe(u8, "pkg/layout.sal"),
        .version = 42,
    };
    try fragment.package_identities.put(try std.testing.allocator.dupe(u8, "pkg/core"), {});

    var target_instructions = std.array_list.Managed(Instruction).init(std.testing.allocator);
    defer {
        for (target_instructions.items) |item| {
            if (item.package_identity) |identity| std.testing.allocator.free(identity);
            if (item.upstream_loc) |loc| std.testing.allocator.free(loc.file);
            if (item.native_reg_names.len != 0) std.testing.allocator.free(item.native_reg_names);
        }
        target_instructions.deinit();
    }
    var target_const_decls = std.array_list.Managed(ConstDecl).init(std.testing.allocator);
    defer {
        for (target_const_decls.items) |*decl| decl.deinit(std.testing.allocator);
        target_const_decls.deinit();
    }
    var target_function_sigs = std.array_list.Managed(FunctionSig).init(std.testing.allocator);
    defer {
        for (target_function_sigs.items) |*sig| sig.deinit(std.testing.allocator);
        target_function_sigs.deinit();
    }
    var target_test_sigs = std.array_list.Managed(FunctionSig).init(std.testing.allocator);
    defer {
        for (target_test_sigs.items) |*sig| sig.deinit(std.testing.allocator);
        target_test_sigs.deinit();
    }
    var target_def_dict = DefDict.init(std.testing.allocator);
    defer target_def_dict.deinit();
    var target_symbols = SymbolTable.init(std.testing.allocator);
    defer target_symbols.deinit();
    var target_layout_versions = std.array_list.Managed(LayoutVersion).init(std.testing.allocator);
    defer {
        for (target_layout_versions.items) |*item| item.deinit(std.testing.allocator);
        target_layout_versions.deinit();
    }
    var target_package_identities = std.StringHashMap(void).init(std.testing.allocator);
    defer {
        var it = target_package_identities.iterator();
        while (it.next()) |entry| std.testing.allocator.free(entry.key_ptr.*);
        target_package_identities.deinit();
    }
    var target_owned_text = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer {
        for (target_owned_text.items) |text| std.testing.allocator.free(text);
        target_owned_text.deinit();
    }
    var target_macros = std.StringHashMap(MacroDef).init(std.testing.allocator);
    defer deinitMacroMap(std.testing.allocator, &target_macros);

    _ = try target_symbols.intern("occupied");
    try target_def_dict.putExpression("EXISTING", "1");
    try target_package_identities.put(try std.testing.allocator.dupe(u8, "pkg/seed"), {});
    try target_function_sigs.append(.{
        .id = 99,
        .name = try std.testing.allocator.dupe(u8, "seed"),
        .params = &.{},
        .kind = .normal,
        .return_cap = null,
        .return_ty = .void,
        .entry_inst_idx = 0,
        .is_ffi_wrapper = false,
    });
    try target_instructions.append(common_instruction.makeInstruction(
        .label,
        1,
        0,
        null,
        try ownText(std.testing.allocator, &target_owned_text, "L_SEED:"),
    ));

    try appendFlattenFragment(
        std.testing.allocator,
        &target_instructions,
        &target_const_decls,
        &target_function_sigs,
        &target_test_sigs,
        &target_def_dict,
        &target_symbols,
        &target_layout_versions,
        &target_package_identities,
        &target_owned_text,
        &target_macros,
        &fragment,
        10,
        20,
    );

    try std.testing.expectEqual(@as(usize, 1 + fragment.instructions.len), target_instructions.items.len);
    try std.testing.expectEqual(@as(usize, 1), target_const_decls.items.len);
    try std.testing.expectEqual(@as(usize, 1 + fragment.function_sigs.len), target_function_sigs.items.len);
    try std.testing.expectEqual(@as(usize, fragment.test_sigs.len), target_test_sigs.items.len);
    try std.testing.expectEqualStrings("8", target_def_dict.get("SIZE").?);
    try std.testing.expectEqualStrings("1", target_def_dict.get("EXISTING").?);
    try std.testing.expectEqual(@as(u32, 2), target_package_identities.count());
    try std.testing.expectEqual(@as(usize, 1), target_layout_versions.items.len);
    try std.testing.expectEqualStrings("pkg/layout.sal", target_layout_versions.items[0].path);
    try std.testing.expectEqual(@as(u64, 42), target_layout_versions.items[0].version);
    try std.testing.expect(target_layout_versions.items[0].path.ptr != fragment.layout_versions[0].path.ptr);

    try std.testing.expectEqualStrings("HELLO", target_const_decls.items[0].name);
    try std.testing.expectEqual(@as(u32, fragment.const_decls[0].source_line + 10), target_const_decls.items[0].source_line);
    try std.testing.expectEqual(@as(u32, fragment.const_decls[0].expanded_line + 20), target_const_decls.items[0].expanded_line);

    try std.testing.expectEqual(@as(u32, 99), target_function_sigs.items[0].id);
    try std.testing.expectEqual(@as(u32, fragment.function_sigs[0].id + 1), target_function_sigs.items[1].id);
    try std.testing.expectEqual(@as(u32, fragment.function_sigs[1].id + 1), target_function_sigs.items[2].id);
    try std.testing.expectEqual(@as(u32, fragment.function_sigs[0].entry_inst_idx + 1), target_function_sigs.items[1].entry_inst_idx);
    try std.testing.expectEqual(@as(u32, fragment.function_sigs[1].entry_inst_idx + 1), target_function_sigs.items[2].entry_inst_idx);
    try std.testing.expect(target_function_sigs.items[2].should_panic);
    try std.testing.expectEqualStrings("\"panic path\"", target_test_sigs.items[0].name);
    try std.testing.expect(target_test_sigs.items[0].name.ptr != target_function_sigs.items[2].name.ptr);

    try std.testing.expectEqual(@as(u32, fragment.instructions[0].source_line + 10), target_instructions.items[1].source_line);
    try std.testing.expectEqual(@as(u32, fragment.instructions[0].expanded_line + 20), target_instructions.items[1].expanded_line);
    try std.testing.expectEqualStrings(fragment.instructions[0].raw_text, target_instructions.items[1].raw_text);
    try std.testing.expect(target_instructions.items[1].raw_text.ptr != fragment.instructions[0].raw_text.ptr);

    try std.testing.expect(target_macros.contains("SIZE") == false);
}

test "frontend cache append fragment restores imported macro defs for later expansion" {
    const imported_source =
        \\[MACRO] MAKE_TMP %out
        \\    _tmp = add 0, 7
        \\    %out = add _tmp, 0
        \\[END_MACRO]
    ;
    var fragment = try flatten(std.testing.allocator, imported_source);
    defer fragment.deinit(std.testing.allocator);

    var target_instructions = std.array_list.Managed(Instruction).init(std.testing.allocator);
    defer {
        for (target_instructions.items) |item| {
            if (item.package_identity) |identity| std.testing.allocator.free(identity);
            if (item.upstream_loc) |loc| std.testing.allocator.free(loc.file);
            if (item.native_reg_names.len != 0) std.testing.allocator.free(item.native_reg_names);
        }
        target_instructions.deinit();
    }
    var target_const_decls = std.array_list.Managed(ConstDecl).init(std.testing.allocator);
    defer {
        for (target_const_decls.items) |*decl| decl.deinit(std.testing.allocator);
        target_const_decls.deinit();
    }
    var target_function_sigs = std.array_list.Managed(FunctionSig).init(std.testing.allocator);
    defer {
        for (target_function_sigs.items) |*sig| sig.deinit(std.testing.allocator);
        target_function_sigs.deinit();
    }
    var target_test_sigs = std.array_list.Managed(FunctionSig).init(std.testing.allocator);
    defer {
        for (target_test_sigs.items) |*sig| sig.deinit(std.testing.allocator);
        target_test_sigs.deinit();
    }
    var target_def_dict = DefDict.init(std.testing.allocator);
    defer target_def_dict.deinit();
    var target_symbols = SymbolTable.init(std.testing.allocator);
    defer target_symbols.deinit();
    var target_layout_versions = std.array_list.Managed(LayoutVersion).init(std.testing.allocator);
    defer {
        for (target_layout_versions.items) |*item| item.deinit(std.testing.allocator);
        target_layout_versions.deinit();
    }
    var target_package_identities = std.StringHashMap(void).init(std.testing.allocator);
    defer {
        var it = target_package_identities.iterator();
        while (it.next()) |entry| std.testing.allocator.free(entry.key_ptr.*);
        target_package_identities.deinit();
    }
    var target_owned_text = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer {
        for (target_owned_text.items) |text| std.testing.allocator.free(text);
        target_owned_text.deinit();
    }
    var target_macros = std.StringHashMap(MacroDef).init(std.testing.allocator);
    defer deinitMacroMap(std.testing.allocator, &target_macros);

    try appendFlattenFragment(
        std.testing.allocator,
        &target_instructions,
        &target_const_decls,
        &target_function_sigs,
        &target_test_sigs,
        &target_def_dict,
        &target_symbols,
        &target_layout_versions,
        &target_package_identities,
        &target_owned_text,
        &target_macros,
        &fragment,
        0,
        0,
    );

    const source =
        \\@main() -> i32:
        \\    EXPAND MAKE_TMP out
        \\    return out
    ;
    const lines = try scanSource(std.testing.allocator, source, &.{}, &.{});
    defer std.testing.allocator.free(lines);

    const empty_replacements = [_]Replacement{};
    var pending_loc: ?common_upstream.UpstreamLoc = null;
    defer if (pending_loc) |loc| std.testing.allocator.free(loc.file);
    var loc_table = std.array_list.Managed(?common_upstream.UpstreamLoc).init(std.testing.allocator);
    defer {
        for (loc_table.items) |entry| {
            if (entry) |loc| std.testing.allocator.free(loc.file);
        }
        loc_table.deinit();
    }
    var include_stack = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer include_stack.deinit();
    var macro_call_stack = std.array_list.Managed(*const MacroDef).init(std.testing.allocator);
    defer macro_call_stack.deinit();
    var expansion_counter: u64 = 0;

    try emitRange(
        std.testing.allocator,
        lines,
        0,
        lines.len,
        0,
        null,
        null,
        &include_stack,
        &macro_call_stack,
        empty_replacements[0..],
        true,
        &target_macros,
        &target_def_dict,
        &target_symbols,
        &loc_table,
        &pending_loc,
        &target_instructions,
        &target_const_decls,
        &target_function_sigs,
        &target_owned_text,
        null,
        null,
        null,
        &expansion_counter,
    );

    try std.testing.expect(target_symbols.findId("out") != null);
    try std.testing.expect(target_symbols.findId("_tmp__sa_hyg1") != null);
}

test "cached macro helper path survives allocation failure injection" {
    const Ctx = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const package_identity = "pkg:macro-cache-test";
            const source =
                \\[MACRO] MAKE_TMP %out
                \\    _tmp = add 0, 7
                \\    %out = add _tmp, 0
                \\[END_MACRO]
            ;
            const identities = [_]?[]const u8{
                package_identity,
                package_identity,
                package_identity,
                package_identity,
            };
            const lines = try scanSource(allocator, source, identities[0..], &.{});
            defer allocator.free(lines);

            var source_macros = std.StringHashMap(MacroDef).init(allocator);
            defer deinitMacroMap(allocator, &source_macros);
            try collectMacroDefinitions(allocator, lines, &source_macros, null);

            const cached_defs = try captureCachedMacroDefs(allocator, &source_macros);
            defer deinitCachedMacroDefs(allocator, cached_defs);

            var target_macros = std.StringHashMap(MacroDef).init(allocator);
            defer deinitMacroMap(allocator, &target_macros);

            try restoreCachedMacroDefs(allocator, cached_defs, &target_macros);
            const restored = target_macros.getPtr("MAKE_TMP") orelse return error.MissingRestoredMacro;
            try std.testing.expectEqual(@as(usize, 1), restored.params.len);
            try std.testing.expectEqualStrings("%out", restored.params[0]);
            try std.testing.expectEqual(@as(usize, 2), restored.owned_body_lines.len);
            try std.testing.expectEqualStrings(package_identity, restored.owned_body_lines[0].package_identity.?);
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Ctx.run, .{});
}

test "macroDefBodyLines rejects missing owned macro body" {
    const macro_params = [_][]const u8{"%out"};
    const def = MacroDef{
        .params = macro_params[0..],
        .body_start = 1,
        .body_end = 3,
    };

    try std.testing.expectError(error.InvalidMacroInvocation, macroDefBodyLines(&def));
}

test "findFirstForbiddenLine skips native blocks and catches keywords" {
    const source =
        \\$if not scanned$
        \\let x = 1
        \\foo.a.b
    ;
    const hit = findFirstForbiddenLine(source).?;
    try std.testing.expectEqual(@as(u32, 3), hit.line_no);
    try std.testing.expectEqual(forbidden.ForbiddenToken.property_chain, hit.hit.token);
}

test "flatten builds instruction stream with symbol and def tables" {
    const source =
        \\#def SIZE = 8
        \\@entry() -> i32:
        \\L_ENTRY:
        \\node = alloc SIZE
        \\return node
    ;
    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), result.instructions.len);
    try std.testing.expectEqual(@as(usize, 1), result.function_sigs.len);
    try std.testing.expectEqual(InstKind.func_decl, result.instructions[0].kind);
    try std.testing.expectEqual(InstKind.label, result.instructions[1].kind);
    try std.testing.expectEqual(InstKind.alloc, result.instructions[2].kind);
    try std.testing.expectEqual(InstKind.return_, result.instructions[3].kind);
    try std.testing.expectEqualStrings("8", result.def_dict.get("SIZE").?);
    try std.testing.expectEqualStrings("entry", result.symbols.lookupName(0).?);
    try std.testing.expectEqualStrings("L_ENTRY", result.symbols.lookupName(1).?);
    try std.testing.expectEqualStrings("entry", result.function_sigs[0].name);
    try std.testing.expectEqual(@as(usize, result.instructions.len), result.loc_table.len);
}

test "flatten preserves structured const declarations separately from instructions" {
    const source =
        \\#loc "main.rs":7:3
        \\@const HELLO = utf8:"hello"
        \\@main() -> i32:
        \\L_ENTRY:
        \\return 0
    ;
    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.instructions.len);
    try std.testing.expectEqual(@as(usize, 1), result.const_decls.len);
    try std.testing.expectEqualStrings("HELLO", result.const_decls[0].name);
    try std.testing.expectEqualStrings("utf8:\"hello\"", result.const_decls[0].literal_text);
    try std.testing.expect(result.const_decls[0].upstream_loc != null);
    try std.testing.expectEqualStrings("main.rs", result.const_decls[0].upstream_loc.?.file);
    try std.testing.expectEqual(@as(u32, 7), result.const_decls[0].upstream_loc.?.line);
    try std.testing.expectEqual(@as(u32, 3), result.const_decls[0].upstream_loc.?.col);
    switch (result.const_decls[0].value) {
        .utf8 => |literal| try std.testing.expectEqualStrings("hello", literal.bytes),
        else => return error.TestUnexpectedResult,
    }
}

test "flatten keeps native escape text and extracted register names" {
    const source =
        \\@main() -> i32:
        \\value = alloc 8
        \\$call side(ptr value, i32 7, @glob, %tmp)$
        \\return 0
    ;
    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), result.instructions.len);
    try std.testing.expectEqual(InstKind.native, result.instructions[2].kind);
    try std.testing.expectEqualStrings("call side(ptr value, i32 7, @glob, %tmp)", result.instructions[2].operands[0].native_text);
    try std.testing.expectEqual(@as(usize, 5), result.instructions[2].native_reg_names.len);
    try std.testing.expectEqualStrings("call", result.instructions[2].native_reg_names[0]);
    try std.testing.expectEqualStrings("side", result.instructions[2].native_reg_names[1]);
    try std.testing.expectEqualStrings("ptr", result.instructions[2].native_reg_names[2]);
    try std.testing.expectEqualStrings("value", result.instructions[2].native_reg_names[3]);
    try std.testing.expectEqualStrings("i32", result.instructions[2].native_reg_names[4]);
}

test "flatten attaches loc hint to the next real instruction only" {
    const source =
        \\#loc "up.rs":12:3
        \\@entry() -> i32:
        \\#loc "up.rs":13:5
        \\L_ENTRY:
        \\#loc "up.rs":14:7
        \\node = alloc 8
        \\return node
    ;
    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), result.instructions.len);
    try std.testing.expect(result.instructions[0].upstream_loc != null);
    try std.testing.expectEqualStrings("up.rs", result.instructions[0].upstream_loc.?.file);
    try std.testing.expectEqual(@as(u32, 12), result.instructions[0].upstream_loc.?.line);
    try std.testing.expectEqual(@as(u32, 3), result.instructions[0].upstream_loc.?.col);
    try std.testing.expect(result.instructions[1].upstream_loc == null);
    try std.testing.expect(result.instructions[2].upstream_loc != null);
    try std.testing.expectEqualStrings("up.rs", result.instructions[2].upstream_loc.?.file);
    try std.testing.expectEqual(@as(u32, 14), result.instructions[2].upstream_loc.?.line);
    try std.testing.expectEqual(@as(u32, 7), result.instructions[2].upstream_loc.?.col);
    try std.testing.expect(result.instructions[3].upstream_loc == null);
    try std.testing.expectEqual(@as(usize, result.instructions.len), result.loc_table.len);
    try std.testing.expect(result.loc_table[0] == null);
    try std.testing.expect(result.loc_table[1] == null);
    try std.testing.expect(result.loc_table[2] != null);
    try std.testing.expectEqualStrings("up.rs", result.loc_table[2].?.file);
    try std.testing.expect(result.loc_table[3] == null);
    try std.testing.expectEqualStrings("up.rs", result.function_sigs[0].upstream_loc.?.file);
    try std.testing.expectEqual(@as(u32, 12), result.function_sigs[0].upstream_loc.?.line);
    try std.testing.expectEqual(@as(u32, 3), result.function_sigs[0].upstream_loc.?.col);
}

test "flatten rejects zero loc hint coordinates" {
    const source =
        \\#loc "up.rs":0:0
        \\@entry() -> i32:
        \\return 0
    ;
    try std.testing.expectError(error.InvalidLocHint, flatten(std.testing.allocator, source));
}

test "flattenFile expands relative @import files" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    try tdir.makePath("sa_std/io");
    var iface = try tdir.createFile("sa_std/io/print.sai", .{ .truncate = true });
    try iface.writeAll("@extern sa_print_bytes(&msg: ptr, len: u64) -> void\n");
    iface.close();

    var main_file = try tdir.createFile("main.sa", .{ .truncate = true });
    try main_file.writeAll(
        \\@import "sa_std/io/print.sai"
        \\@main() -> i32:
        \\L_ENTRY:
        \\    return 0
    );
    main_file.close();

    const source = try tdir.readFileAlloc(std.testing.allocator, "main.sa", 4096);
    defer std.testing.allocator.free(source);

    const source_path = try tdir.realpathAlloc(std.testing.allocator, "main.sa");
    defer std.testing.allocator.free(source_path);

    var result = try flattenFile(std.testing.allocator, source_path, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.function_sigs.len);
    try std.testing.expectEqual(FunctionKind.external, result.function_sigs[0].kind);
    try std.testing.expectEqualStrings("sa_print_bytes", result.function_sigs[0].name);
    try std.testing.expectEqual(FunctionKind.normal, result.function_sigs[1].kind);
    try std.testing.expectEqualStrings("main", result.function_sigs[1].name);
}

test "flattenFile tags imported functions with imported source path" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    var module_file = try tdir.createFile("module.sa", .{ .truncate = true });
    try module_file.writeAll(
        \\@helper() -> i32:
        \\L_ENTRY:
        \\    return 7
    );
    module_file.close();

    var main_file = try tdir.createFile("main.sa", .{ .truncate = true });
    try main_file.writeAll(
        \\@import "module.sa"
        \\@main() -> i32:
        \\L_ENTRY:
        \\    return 0
    );
    main_file.close();

    const source = try tdir.readFileAlloc(std.testing.allocator, "main.sa", 4096);
    defer std.testing.allocator.free(source);

    const source_path = try tdir.realpathAlloc(std.testing.allocator, "main.sa");
    defer std.testing.allocator.free(source_path);
    const module_path = try tdir.realpathAlloc(std.testing.allocator, "module.sa");
    defer std.testing.allocator.free(module_path);

    var result = try flattenFile(std.testing.allocator, source_path, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.function_sigs.len);
    try std.testing.expectEqualStrings("helper", result.function_sigs[0].name);
    try std.testing.expect(result.function_sigs[0].upstream_loc != null);
    try std.testing.expectEqualStrings(module_path, result.function_sigs[0].upstream_loc.?.file);
}

test "std import source cache reuses source without cloning on hit" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    try tdir.makePath("sa_std/core");
    var iface = try tdir.createFile("sa_std/core/cache_probe.sai", .{ .truncate = true });
    try iface.writeAll("@extern cache_probe() -> i32\n");
    iface.close();

    const project_root = try tdir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);
    const std_root = try tdir.realpathAlloc(std.testing.allocator, "sa_std");
    defer std.testing.allocator.free(std_root);
    const resolve_ctx = ResolveContext{ .options = .{ .project_root = project_root, .std_root = std_root } };

    var first = try readImportFile(std.testing.allocator, project_root, "sa_std/core/cache_probe.sai", resolve_ctx);
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.owned_source != null);
    try std.testing.expectEqualStrings("@extern cache_probe() -> i32\n", first.source);

    var second = try readImportFile(std.testing.allocator, project_root, "sa_std/core/cache_probe.sai", resolve_ctx);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(second.owned_source == null);
    try std.testing.expectEqualStrings(first.source, second.source);
}

fn clearImportSourceCacheForTest() void {
    while (!import_source_cache_mutex.tryLock()) { std.Thread.yield() catch {}; }
    defer import_source_cache_mutex.unlock();
    if (import_source_cache) |*cache| {
        var it = cache.iterator();
        while (it.next()) |entry| {
            std.heap.page_allocator.free(entry.key_ptr.*);
            freeImportSourceCacheEntry(entry.value_ptr.*, true);
        }
        cache.deinit();
        import_source_cache = null;
    }
    import_source_cache_tick = 0;
    test_import_source_cache_max_entries = null;
}

fn importSourceCacheHasEntryPathForTest(path: []const u8) bool {
    while (!import_source_cache_mutex.tryLock()) { std.Thread.yield() catch {}; }
    defer import_source_cache_mutex.unlock();
    const cache = if (import_source_cache) |*cache| cache else return false;
    var it = cache.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.entry_path, path)) return true;
    }
    return false;
}

fn clearExpandedImportCacheForTest() void {
    while (!expanded_import_cache_mutex.tryLock()) { std.Thread.yield() catch {}; }
    defer expanded_import_cache_mutex.unlock();
    if (expanded_import_cache) |*cache| {
        var it = cache.iterator();
        while (it.next()) |entry| {
            std.heap.page_allocator.free(entry.key_ptr.*);
            freeExpandedImportCacheEntry(entry.value_ptr.*);
        }
        cache.deinit();
        expanded_import_cache = null;
    }
    expanded_import_cache_tick = 0;
    test_expanded_import_cache_max_entries = null;
    test_expanded_import_cache_hits = 0;
    test_expanded_import_cache_stores = 0;
}

test "expanded import cache reuses expanded std fragments across flatten calls" {
    clearImportSourceCacheForTest();
    defer clearImportSourceCacheForTest();
    clearExpandedImportCacheForTest();
    defer clearExpandedImportCacheForTest();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    try tdir.makePath("sa_std/core");
    {
        var file = try tdir.createFile("sa_std/core/cache_expanded.sai", .{ .truncate = true });
        defer file.close();
        try file.writeAll("#def EXPANDED_CACHE_VALUE = 7\n");
    }
    {
        var file = try tdir.createFile("main_a.sa", .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            \\@import "sa_std/core/cache_expanded.sai"
            \\@main() -> i32:
            \\return EXPANDED_CACHE_VALUE
            \\
        );
    }
    {
        var file = try tdir.createFile("main_b.sa", .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            \\@import "sa_std/core/cache_expanded.sai"
            \\@main() -> i32:
            \\return EXPANDED_CACHE_VALUE
            \\
        );
    }

    const project_root = try tdir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);
    const std_root = try tdir.realpathAlloc(std.testing.allocator, "sa_std");
    defer std.testing.allocator.free(std_root);
    const resolve_ctx = ResolveContext{ .options = .{ .project_root = project_root, .std_root = std_root } };

    const source_a = try tdir.readFileAlloc(std.testing.allocator, "main_a.sa", 4096);
    defer std.testing.allocator.free(source_a);
    const source_path_a = try tdir.realpathAlloc(std.testing.allocator, "main_a.sa");
    defer std.testing.allocator.free(source_path_a);
    var first = try flattenFileWithPackages(std.testing.allocator, source_path_a, source_a, resolve_ctx);
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(test_expanded_import_cache_stores > 0);
    try std.testing.expectEqual(@as(usize, 0), test_expanded_import_cache_hits);

    const source_b = try tdir.readFileAlloc(std.testing.allocator, "main_b.sa", 4096);
    defer std.testing.allocator.free(source_b);
    const source_path_b = try tdir.realpathAlloc(std.testing.allocator, "main_b.sa");
    defer std.testing.allocator.free(source_path_b);
    var second = try flattenFileWithPackages(std.testing.allocator, source_path_b, source_b, resolve_ctx);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(test_expanded_import_cache_hits > 0);
    try std.testing.expectEqual(first.instructions.len, second.instructions.len);
}

test "expanded import cache invalidates when transitive import changes" {
    clearImportSourceCacheForTest();
    defer clearImportSourceCacheForTest();
    clearExpandedImportCacheForTest();
    defer clearExpandedImportCacheForTest();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    try tdir.makePath("sa_std/core");
    {
        var file = try tdir.createFile("sa_std/core/cache_mutable.sai", .{ .truncate = true });
        defer file.close();
        try file.writeAll("#def EXPANDED_CACHE_VALUE = 7\n");
    }
    const main_source =
        \\@import "sa_std/core/cache_mutable.sai"
        \\@main() -> i32:
        \\return EXPANDED_CACHE_VALUE
        \\
    ;
    {
        var file = try tdir.createFile("main_a.sa", .{ .truncate = true });
        defer file.close();
        try file.writeAll(main_source);
    }
    {
        var file = try tdir.createFile("main_b.sa", .{ .truncate = true });
        defer file.close();
        try file.writeAll(main_source);
    }

    const project_root = try tdir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);
    const std_root = try tdir.realpathAlloc(std.testing.allocator, "sa_std");
    defer std.testing.allocator.free(std_root);
    const resolve_ctx = ResolveContext{ .options = .{ .project_root = project_root, .std_root = std_root } };

    const source_a = try tdir.readFileAlloc(std.testing.allocator, "main_a.sa", 4096);
    defer std.testing.allocator.free(source_a);
    const source_path_a = try tdir.realpathAlloc(std.testing.allocator, "main_a.sa");
    defer std.testing.allocator.free(source_path_a);
    var first = try flattenFileWithPackages(std.testing.allocator, source_path_a, source_a, resolve_ctx);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("7", first.def_dict.get("EXPANDED_CACHE_VALUE").?);

    {
        var file = try tdir.createFile("sa_std/core/cache_mutable.sai", .{ .truncate = true });
        defer file.close();
        try file.writeAll("#def EXPANDED_CACHE_VALUE = 777\n");
    }
    test_expanded_import_cache_hits = 0;
    const source_b = try tdir.readFileAlloc(std.testing.allocator, "main_b.sa", 4096);
    defer std.testing.allocator.free(source_b);
    const source_path_b = try tdir.realpathAlloc(std.testing.allocator, "main_b.sa");
    defer std.testing.allocator.free(source_path_b);
    var second = try flattenFileWithPackages(std.testing.allocator, source_path_b, source_b, resolve_ctx);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), test_expanded_import_cache_hits);
    try std.testing.expectEqualStrings("777", second.def_dict.get("EXPANDED_CACHE_VALUE").?);
}

test "expanded import cache does not store fragments that skipped caller-seen imports" {
    clearImportSourceCacheForTest();
    defer clearImportSourceCacheForTest();
    clearExpandedImportCacheForTest();
    defer clearExpandedImportCacheForTest();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    try tdir.makePath("sa_std/core");
    {
        var file = try tdir.createFile("sa_std/core/dep.sa", .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            \\@dep_value() -> u64:
            \\L_ENTRY:
            \\    return 42
            \\
        );
    }
    {
        var file = try tdir.createFile("sa_std/core/wrapper.sa", .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            \\@import "dep.sa"
            \\
            \\[MACRO] WRAP_CALL %out
            \\    %out = call @dep_value()
            \\[END_MACRO]
            \\
        );
    }
    {
        var file = try tdir.createFile("main_a.sa", .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            \\@import "sa_std/core/dep.sa"
            \\@import "sa_std/core/wrapper.sa"
            \\@main() -> i32:
            \\L_ENTRY:
            \\    EXPAND WRAP_CALL value
            \\    !value
            \\    return 0
            \\
        );
    }
    {
        var file = try tdir.createFile("main_b.sa", .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            \\@import "sa_std/core/wrapper.sa"
            \\@main() -> i32:
            \\L_ENTRY:
            \\    EXPAND WRAP_CALL value
            \\    !value
            \\    return 0
            \\
        );
    }

    const project_root = try tdir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);
    const std_root = try tdir.realpathAlloc(std.testing.allocator, "sa_std");
    defer std.testing.allocator.free(std_root);
    const resolve_ctx = ResolveContext{ .options = .{ .project_root = project_root, .std_root = std_root } };

    const source_a = try tdir.readFileAlloc(std.testing.allocator, "main_a.sa", 4096);
    defer std.testing.allocator.free(source_a);
    const source_path_a = try tdir.realpathAlloc(std.testing.allocator, "main_a.sa");
    defer std.testing.allocator.free(source_path_a);
    var first = try flattenFileWithPackages(std.testing.allocator, source_path_a, source_a, resolve_ctx);
    defer first.deinit(std.testing.allocator);

    const source_b = try tdir.readFileAlloc(std.testing.allocator, "main_b.sa", 4096);
    defer std.testing.allocator.free(source_b);
    const source_path_b = try tdir.realpathAlloc(std.testing.allocator, "main_b.sa");
    defer std.testing.allocator.free(source_path_b);
    var second = try flattenFileWithPackages(std.testing.allocator, source_path_b, source_b, resolve_ctx);
    defer second.deinit(std.testing.allocator);

    var saw_dep = false;
    for (second.function_sigs) |sig| {
        if (std.mem.eql(u8, sig.name, "dep_value")) saw_dep = true;
    }
    try std.testing.expect(saw_dep);
}

test "expanded import cache LRU is opt-in" {
    clearImportSourceCacheForTest();
    defer clearImportSourceCacheForTest();
    clearExpandedImportCacheForTest();
    defer clearExpandedImportCacheForTest();
    test_expanded_import_cache_max_entries = 1;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    try tdir.makePath("sa_std/core");
    {
        var file = try tdir.createFile("sa_std/core/cache_lru_a.sai", .{ .truncate = true });
        defer file.close();
        try file.writeAll("#def EXPANDED_CACHE_VALUE = 11\n");
    }
    {
        var file = try tdir.createFile("sa_std/core/cache_lru_b.sai", .{ .truncate = true });
        defer file.close();
        try file.writeAll("#def EXPANDED_CACHE_VALUE = 22\n");
    }
    {
        var file = try tdir.createFile("main_a.sa", .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            \\@import "sa_std/core/cache_lru_a.sai"
            \\@main() -> i32:
            \\return EXPANDED_CACHE_VALUE
            \\
        );
    }
    {
        var file = try tdir.createFile("main_b.sa", .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            \\@import "sa_std/core/cache_lru_b.sai"
            \\@main() -> i32:
            \\return EXPANDED_CACHE_VALUE
            \\
        );
    }

    const project_root = try tdir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);
    const std_root = try tdir.realpathAlloc(std.testing.allocator, "sa_std");
    defer std.testing.allocator.free(std_root);
    const resolve_ctx = ResolveContext{ .options = .{ .project_root = project_root, .std_root = std_root } };

    const source_a = try tdir.readFileAlloc(std.testing.allocator, "main_a.sa", 4096);
    defer std.testing.allocator.free(source_a);
    const source_path_a = try tdir.realpathAlloc(std.testing.allocator, "main_a.sa");
    defer std.testing.allocator.free(source_path_a);
    var first_a = try flattenFileWithPackages(std.testing.allocator, source_path_a, source_a, resolve_ctx);
    defer first_a.deinit(std.testing.allocator);

    const source_b = try tdir.readFileAlloc(std.testing.allocator, "main_b.sa", 4096);
    defer std.testing.allocator.free(source_b);
    const source_path_b = try tdir.realpathAlloc(std.testing.allocator, "main_b.sa");
    defer std.testing.allocator.free(source_path_b);
    var first_b = try flattenFileWithPackages(std.testing.allocator, source_path_b, source_b, resolve_ctx);
    defer first_b.deinit(std.testing.allocator);

    test_expanded_import_cache_hits = 0;
    var second_a = try flattenFileWithPackages(std.testing.allocator, source_path_a, source_a, resolve_ctx);
    defer second_a.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), test_expanded_import_cache_hits);
    try std.testing.expectEqualStrings("11", second_a.def_dict.get("EXPANDED_CACHE_VALUE").?);
}

test "layout import exposes sibling extern declarations from sai" {
    clearImportSourceCacheForTest();
    defer clearImportSourceCacheForTest();
    clearExpandedImportCacheForTest();
    defer clearExpandedImportCacheForTest();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    {
        var sai = try tdir.createFile("db.sai", .{ .truncate = true });
        defer sai.close();
        try sai.writeAll("@extern sa_db_tx_insert_rows(handle: ptr, &rows: ptr, rows_len: u64, row_count: u64, &out_info: ptr) -> u32\n");
    }
    {
        var sal = try tdir.createFile("db.sal", .{ .truncate = true });
        defer sal.close();
        try sal.writeAll("@import \"db.sai\"\n");
    }
    {
        var main = try tdir.createFile("main.sa", .{ .truncate = true });
        defer main.close();
        try main.writeAll(
            \\@import "db.sal"
            \\
            \\@main() -> i32:
            \\L_ENTRY:
            \\    rows = stack_alloc 8
            \\    info = stack_alloc 32
            \\    handle = stack_alloc 8
            \\    store handle+0, 0 as ptr
            \\    status = call @sa_db_tx_insert_rows(handle, &rows, 8, 1, &info)
            \\    return status
            \\
        );
    }

    const project_root = try tdir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);
    const resolve_ctx = ResolveContext{ .options = .{ .project_root = project_root } };
    const source = try tdir.readFileAlloc(std.testing.allocator, "main.sa", 4096);
    defer std.testing.allocator.free(source);
    const source_path = try tdir.realpathAlloc(std.testing.allocator, "main.sa");
    defer std.testing.allocator.free(source_path);

    var result = try flattenFileWithPackages(std.testing.allocator, source_path, source, resolve_ctx);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(isFunctionSigDeclared(result.function_sigs, "sa_db_tx_insert_rows"));
}

test "import source cache LRU is opt-in and avoids borrowed hits" {
    clearImportSourceCacheForTest();
    defer clearImportSourceCacheForTest();
    test_import_source_cache_max_entries = 2;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    try tdir.makePath("sa_std/core");
    var a_file = try tdir.createFile("sa_std/core/cache_a.sai", .{ .truncate = true });
    try a_file.writeAll("#def CACHE_A = 1\n");
    a_file.close();
    var b_file = try tdir.createFile("sa_std/core/cache_b.sai", .{ .truncate = true });
    try b_file.writeAll("#def CACHE_B = 2\n");
    b_file.close();
    var c_file = try tdir.createFile("sa_std/core/cache_c.sai", .{ .truncate = true });
    try c_file.writeAll("#def CACHE_C = 3\n");
    c_file.close();

    const project_root = try tdir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);
    const std_root = try tdir.realpathAlloc(std.testing.allocator, "sa_std");
    defer std.testing.allocator.free(std_root);
    const a_path = try tdir.realpathAlloc(std.testing.allocator, "sa_std/core/cache_a.sai");
    defer std.testing.allocator.free(a_path);
    const b_path = try tdir.realpathAlloc(std.testing.allocator, "sa_std/core/cache_b.sai");
    defer std.testing.allocator.free(b_path);
    const c_path = try tdir.realpathAlloc(std.testing.allocator, "sa_std/core/cache_c.sai");
    defer std.testing.allocator.free(c_path);
    const resolve_ctx = ResolveContext{ .options = .{ .project_root = project_root, .std_root = std_root } };

    var first_a = try readImportFile(std.testing.allocator, project_root, "sa_std/core/cache_a.sai", resolve_ctx);
    defer first_a.deinit(std.testing.allocator);
    var first_b = try readImportFile(std.testing.allocator, project_root, "sa_std/core/cache_b.sai", resolve_ctx);
    defer first_b.deinit(std.testing.allocator);

    var second_a = try readImportFile(std.testing.allocator, project_root, "sa_std/core/cache_a.sai", resolve_ctx);
    defer second_a.deinit(std.testing.allocator);
    try std.testing.expect(second_a.owned_source != null);

    var first_c = try readImportFile(std.testing.allocator, project_root, "sa_std/core/cache_c.sai", resolve_ctx);
    defer first_c.deinit(std.testing.allocator);
    try std.testing.expect(importSourceCacheHasEntryPathForTest(a_path));
    try std.testing.expect(!importSourceCacheHasEntryPathForTest(b_path));
    try std.testing.expect(importSourceCacheHasEntryPathForTest(c_path));
}

test "stable import roots participate in import source cache" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    try tdir.makePath("tests/unit_framework/support");
    var support = try tdir.createFile("tests/unit_framework/support/index.sa", .{ .truncate = true });
    try support.writeAll("@support_value() -> i32:\nreturn 42\n");
    support.close();

    const project_root = try tdir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);
    const stable_root = try tdir.realpathAlloc(std.testing.allocator, "tests/unit_framework/support");
    defer std.testing.allocator.free(stable_root);
    const base_dir = try tdir.realpathAlloc(std.testing.allocator, "tests/unit_framework");
    defer std.testing.allocator.free(base_dir);
    const stable_roots = [_][]const u8{stable_root};
    const resolve_ctx = ResolveContext{ .options = .{ .project_root = project_root, .stable_import_roots = stable_roots[0..] } };

    var first = try readImportFile(std.testing.allocator, base_dir, "support/index.sa", resolve_ctx);
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.owned_source != null);
    try std.testing.expectEqualStrings("@support_value() -> i32:\nreturn 42\n", first.source);

    var second = try readImportFile(std.testing.allocator, base_dir, "support/index.sa", resolve_ctx);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(second.owned_source == null);
    try std.testing.expectEqualStrings(first.source, second.source);
}

test "flattenFileWithPackages injects package iface and namespaced layout defs once" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    try tdir.makePath("sa_vendor/github.com/example/pkg");

    var pkg_main = try tdir.createFile("sa_vendor/github.com/example/pkg/index.sa", .{ .truncate = true });
    try pkg_main.writeAll("// package body intentionally empty\n");
    pkg_main.close();

    var pkg_iface = try tdir.createFile("sa_vendor/github.com/example/pkg/index.sai", .{ .truncate = true });
    try pkg_iface.writeAll("@extern pkg_iface() -> i32\n");
    pkg_iface.close();

    var pkg_layout = try tdir.createFile("sa_vendor/github.com/example/pkg/index.sal", .{ .truncate = true });
    try pkg_layout.writeAll(
        \\#version 1
        \\#def Pkg_SIZE = 4
    );
    pkg_layout.close();

    var main_file = try tdir.createFile("main.sa", .{ .truncate = true });
    try main_file.writeAll(
        \\@import "github.com/example/pkg"
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    return 0
    );
    main_file.close();

    const source = try tdir.readFileAlloc(std.testing.allocator, "main.sa", 4096);
    defer std.testing.allocator.free(source);

    const source_path = try tdir.realpathAlloc(std.testing.allocator, "main.sa");
    defer std.testing.allocator.free(source_path);

    const project_root = try tdir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);

    var result = try flattenFileWithPackages(
        std.testing.allocator,
        source_path,
        source,
        .{
            .options = .{ .project_root = project_root },
        },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.function_sigs.len);
    try std.testing.expectEqualStrings("pkg_iface", result.function_sigs[0].name);
    try std.testing.expectEqualStrings("main", result.function_sigs[1].name);
    try std.testing.expectEqual(@as(usize, 1), result.layout_versions.len);
    try std.testing.expectEqual(@as(u64, 1), result.layout_versions[0].version);

    const prefix = try packageNamespacePrefix(std.testing.allocator, "github.com/example/pkg");
    defer std.testing.allocator.free(prefix);
    const namespaced_key = try std.fmt.allocPrint(std.testing.allocator, "{s}.Pkg_SIZE", .{prefix});
    defer std.testing.allocator.free(namespaced_key);
    try std.testing.expectEqualStrings("4", result.def_dict.get(namespaced_key).?);
}

test "flattenFileWithPackages preserves package identity on imported instructions" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    try tdir.makePath("sa_vendor/github.com/example/pkg");

    var pkg_main = try tdir.createFile("sa_vendor/github.com/example/pkg/index.sa", .{ .truncate = true });
    try pkg_main.writeAll(
        \\@main() -> i32:
        \\L_ENTRY:
        \\path = alloc 8
        \\data = alloc 8
        \\value = call @sys_write_file(*path, 4, *data, 4)
        \\!path
        \\!data
        \\return value
    );
    pkg_main.close();

    var main_file = try tdir.createFile("main.sa", .{ .truncate = true });
    try main_file.writeAll(
        \\@import "github.com/example/pkg"
    );
    main_file.close();

    const source = try tdir.readFileAlloc(std.testing.allocator, "main.sa", 4096);
    defer std.testing.allocator.free(source);

    const source_path = try tdir.realpathAlloc(std.testing.allocator, "main.sa");
    defer std.testing.allocator.free(source_path);

    const project_root = try tdir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);

    var resolved = try pkg_resolver.resolveImport(
        std.testing.allocator,
        &.{},
        project_root,
        "github.com/example/pkg",
        .{ .project_root = project_root },
    );
    defer resolved.deinit(std.testing.allocator);
    const expected_hash = resolved.source_sha256 orelse return error.TestUnexpectedResult;

    var result = try flattenFileWithPackages(
        std.testing.allocator,
        source_path,
        source,
        .{
            .options = .{ .project_root = project_root },
        },
    );
    defer result.deinit(std.testing.allocator);

    var saw_pkg_instruction = false;
    var saw_pkg_call = false;
    for (result.instructions) |item| {
        if (item.package_identity) |identity| {
            if (std.mem.eql(u8, identity, "github.com/example/pkg")) {
                saw_pkg_instruction = true;
                try std.testing.expect(item.package_source_sha256 != null);
                const actual_hash = item.package_source_sha256.?;
                try std.testing.expect(std.mem.eql(u8, actual_hash[0..], expected_hash[0..]));
                if (std.mem.eql(u8, item.raw_text, "value = call @sys_write_file(*path, 4, *data, 4)")) {
                    saw_pkg_call = true;
                }
            }
        }
    }
    try std.testing.expect(saw_pkg_instruction);
    try std.testing.expect(saw_pkg_call);
}

test "flattenFile rejects import cycles" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    var a_file = try tdir.createFile("a.sa", .{ .truncate = true });
    try a_file.writeAll("@import \"b.sa\"\n");
    a_file.close();

    var b_file = try tdir.createFile("b.sa", .{ .truncate = true });
    try b_file.writeAll("@import \"a.sa\"\n");
    b_file.close();

    const source = try tdir.readFileAlloc(std.testing.allocator, "a.sa", 4096);
    defer std.testing.allocator.free(source);

    const source_path = try tdir.realpathAlloc(std.testing.allocator, "a.sa");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectError(error.ImportCycle, flattenFile(std.testing.allocator, source_path, source));
}

test "flatten expands source location macros from upstream location and file path" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    var main_file = try tdir.createFile("main.sa", .{ .truncate = true });
    try main_file.writeAll(
        \\#loc "up.rs":42:7
        \\@main() -> i32:
        \\L_ENTRY:
        \\line_out = alloc 8
        \\#loc "up.rs":42:9
        \\EXPAND LINE! line_out
        \\EXPAND COLUMN! line_out
        \\file_slice = alloc 8
        \\EXPAND FILE! file_slice
        \\return 0
    );
    main_file.close();

    const source = try tdir.readFileAlloc(std.testing.allocator, "main.sa", 4096);
    defer std.testing.allocator.free(source);

    const source_path = try tdir.realpathAlloc(std.testing.allocator, "main.sa");
    defer std.testing.allocator.free(source_path);

    var result = try flattenFile(std.testing.allocator, source_path, source);
    defer result.deinit(std.testing.allocator);

    var saw_line = false;
    var saw_column = false;
    var saw_file_decl = false;
    for (result.instructions) |inst| {
        if (inst.kind != .op) continue;
        if (inst.op_kind != .add) continue;
        switch (inst.operands[2]) {
            .imm_i64 => |value| {
                if (value == 42) saw_line = true;
                if (value == 9) saw_column = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_line);
    try std.testing.expect(saw_column);

    for (result.const_decls) |decl| {
        switch (decl.value) {
            .utf8 => |literal| {
                if (std.mem.eql(u8, literal.bytes, source_path)) {
                    if (std.mem.startsWith(u8, decl.name, "__SOURCE_FILE_")) saw_file_decl = true;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(saw_file_decl);
}

test "macro PBT expands nested macros and repeat bodies deterministically" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6A10);
    const random = prng.random();

    for (0..48) |iter| {
        var program = try buildMacroPbtProgram(std.testing.allocator, random, iter);
        defer program.deinit(std.testing.allocator);

        var result = try flatten(std.testing.allocator, program.source);
        defer result.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 1), result.function_sigs.len);
        try std.testing.expectEqual(@as(usize, 0), result.const_decls.len);
        try std.testing.expectEqual(@as(usize, 4) + program.count, result.instructions.len);

        const base_id = result.symbols.findId(program.base_name) orelse return error.TestUnexpectedResult;
        const acc_id = result.symbols.findId(program.acc_name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(program.base_name, result.symbols.lookupName(base_id).?);
        try std.testing.expectEqualStrings(program.acc_name, result.symbols.lookupName(acc_id).?);

        try std.testing.expectEqual(InstKind.func_decl, result.instructions[0].kind);
        try std.testing.expectEqual(InstKind.alloc, result.instructions[1].kind);
        try std.testing.expectEqual(InstKind.op, result.instructions[2].kind);
        try std.testing.expectEqual(common_instruction.OpKind.add, result.instructions[2].op_kind.?);
        try std.testing.expectEqual(InstKind.return_, result.instructions[result.instructions.len - 1].kind);

        var line_buf: [128]u8 = undefined;
        var tmp_buf: [32]u8 = undefined;

        const alloc_line = try std.fmt.bufPrint(&line_buf, "    {s} = alloc {d}", .{ program.base_name, program.alloc_size });
        try expectRawText(result.instructions[1], alloc_line);
        try expectOperandReg(result.instructions[1], 0, base_id);
        try expectOperandImmU64(result.instructions[1], 1, program.alloc_size);

        const seed_line = try std.fmt.bufPrint(&line_buf, "    {s} = add {s}, 0", .{ program.acc_name, program.base_name });
        try expectRawText(result.instructions[2], seed_line);
        try expectOperandReg(result.instructions[2], 0, acc_id);
        try expectOperandReg(result.instructions[2], 1, base_id);
        try expectOperandImmI64(result.instructions[2], 2, 0);

        for (0..program.count) |idx| {
            const tmp_name = try std.fmt.bufPrint(&tmp_buf, "tmp_{d}", .{idx});
            const tmp_id = result.symbols.findId(tmp_name) orelse return error.TestUnexpectedResult;
            const inst = result.instructions[3 + idx];
            const expected_text = try std.fmt.bufPrint(&line_buf, "        {s} = add {s}, {d}", .{ tmp_name, program.acc_name, idx });
            try expectRawText(inst, expected_text);
            try std.testing.expectEqual(InstKind.op, inst.kind);
            try std.testing.expectEqual(common_instruction.OpKind.add, inst.op_kind.?);
            try expectOperandReg(inst, 0, tmp_id);
            try expectOperandReg(inst, 1, acc_id);
            try expectOperandImmI64(inst, 2, @intCast(idx));
        }

        const return_line = try std.fmt.bufPrint(&line_buf, "    return {s}", .{program.acc_name});
        try expectRawText(result.instructions[result.instructions.len - 1], return_line);
        try expectOperandReg(result.instructions[result.instructions.len - 1], 0, acc_id);
    }
}

test "variadic macro parameters consume remaining arguments" {
    const source =
        \\[MACRO] CALL_SUM %dst, %args...
        \\    %dst = call @sum(%args)
        \\[END_MACRO]
        \\[MACRO] ZERO_OK %dst, %args...
        \\    %dst = add 1, 0
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\    EXPAND CALL_SUM total, 1, 2, 3
        \\    EXPAND ZERO_OK empty
        \\    return 0
    ;

    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), result.instructions.len);
    try std.testing.expectEqual(InstKind.func_decl, result.instructions[0].kind);
    try std.testing.expectEqual(InstKind.call, result.instructions[1].kind);
    try expectRawText(result.instructions[1], "    total = call @sum(1, 2, 3)");
    try std.testing.expectEqual(InstKind.op, result.instructions[2].kind);
    try expectRawText(result.instructions[2], "    empty = add 1, 0");
    try std.testing.expectEqual(InstKind.return_, result.instructions[3].kind);
}

test "variadic macro parameter must be last" {
    const source =
        \\[MACRO] BAD %args..., %tail
        \\    %tail = add 1, 0
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\    return 0
    ;

    try std.testing.expectError(error.InvalidMacroInvocation, flatten(std.testing.allocator, source));
}

test "macro-time conditionals select then else and nested branches" {
    const source =
        \\[MACRO] PICK %dst, %flag
        \\[IF %flag]
        \\    %dst = add 10, 1
        \\[ELSE]
        \\    %dst = add 20, 2
        \\[END_IF]
        \\[END_MACRO]
        \\[MACRO] NEST %dst, %outer, %inner
        \\[IF %outer]
        \\[IF %inner]
        \\    %dst = add 1, 1
        \\[ELSE]
        \\    %dst = add 2, 2
        \\[END_IF]
        \\[END_IF]
        \\[END_MACRO]
        \\[MACRO] MAYBE %dst, %flag
        \\[IF %flag]
        \\    %dst = add 9, 9
        \\[END_IF]
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\    EXPAND PICK a, true
        \\    EXPAND PICK b, false
        \\    EXPAND NEST c, 1, 0
        \\    EXPAND MAYBE d, 0
        \\    return 0
    ;

    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), result.instructions.len);
    try expectRawText(result.instructions[1], "    a = add 10, 1");
    try expectRawText(result.instructions[2], "    b = add 20, 2");
    try expectRawText(result.instructions[3], "    c = add 2, 2");
    try std.testing.expectEqual(InstKind.return_, result.instructions[4].kind);
}

test "macro-time conditional rejects invalid condition values" {
    const source =
        \\[MACRO] BAD %flag
        \\[IF %flag]
        \\    x = add 1, 0
        \\[END_IF]
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\    EXPAND BAD maybe
        \\    return 0
    ;

    try std.testing.expectError(error.InvalidMacroInvocation, flatten(std.testing.allocator, source));
}

test "duplicate macro definitions are rejected" {
    const source =
        \\[MACRO] DUP %x
        \\    %x = add 1, 0
        \\[END_MACRO]
        \\[MACRO] DUP %x
        \\    %x = add 2, 0
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\    return 0
    ;

    try std.testing.expectError(error.DuplicateDef, flatten(std.testing.allocator, source));
}

test "macro PBT rejects invalid definitions and invocations" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6A11);
    const random = prng.random();

    for (0..36) |iter| {
        const case_id = random.intRangeLessThan(u8, 0, 6);
        const ghost_name = try std.fmt.allocPrint(std.testing.allocator, "ghost_{d}_{d}", .{ iter, random.intRangeAtMost(u16, 0, 9999) });
        defer std.testing.allocator.free(ghost_name);

        const source = switch (case_id) {
            0 => try std.fmt.allocPrint(std.testing.allocator,
                \\@main() -> i32:
                \\EXPAND {s} value
                \\return 0
            , .{ghost_name}),
            1 => try std.fmt.allocPrint(std.testing.allocator,
                \\[MACRO] SINGLE %x
                \\    %x = add 1, 0
                \\[END_MACRO]
                \\
                \\@main() -> i32:
                \\    EXPAND SINGLE value, extra
                \\    return 0
            , .{}),
            2 => try std.fmt.allocPrint(std.testing.allocator,
                \\[MACRO] DUP %x
                \\    %x = add 1, 0
                \\[END_MACRO]
                \\[MACRO] DUP %x
                \\    %x = add 2, 0
                \\[END_MACRO]
                \\
                \\@main() -> i32:
                \\    return 0
            , .{}),
            3 => try std.fmt.allocPrint(std.testing.allocator,
                \\[MACRO] OPEN %x
                \\    %x = add 1, 0
                \\
                \\@main() -> i32:
                \\    return 0
            , .{}),
            4 => try std.fmt.allocPrint(std.testing.allocator,
                \\@main() -> i32:
                \\[REP 2]
                \\    return 0
                \\return 0
            , .{}),
            5 => try std.fmt.allocPrint(std.testing.allocator,
                \\[MACRO] LOOP %x
                \\    EXPAND LOOP %x
                \\[END_MACRO]
                \\
                \\@main() -> i32:
                \\    EXPAND LOOP value
                \\    return 0
            , .{}),
            else => unreachable,
        };
        defer std.testing.allocator.free(source);

        const expected_error = switch (case_id) {
            0, 1 => error.InvalidMacroInvocation,
            2 => error.DuplicateDef,
            3 => error.UnbalancedMacro,
            4 => error.UnbalancedRep,
            5 => error.MacroRecursionLimit,
            else => unreachable,
        };
        try std.testing.expectError(expected_error, flatten(std.testing.allocator, source));
    }
}

test "REP fan-out over the expanded line budget fails before expansion" {
    const source =
        \\@main() -> i32:
        \\[REP 10000001]
        \\    _tmp%i = add 0, 0
        \\[END_REP]
        \\    return 0
    ;

    try std.testing.expectError(error.MacroExpansionBudget, flatten(std.testing.allocator, source));
}

test "REP count overflow maps to macro expansion budget" {
    const source =
        \\@main() -> i32:
        \\[REP 999999999999999999999999]
        \\    _tmp%i = add 0, 0
        \\[END_REP]
        \\    return 0
    ;

    try std.testing.expectError(error.MacroExpansionBudget, flatten(std.testing.allocator, source));
}

test "def dict PBT folds random arithmetic expressions through flatten" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6A20);
    const random = prng.random();

    for (0..48) |iter| {
        var base_expr = try buildArithmeticExpr(std.testing.allocator, random, 3);
        defer base_expr.deinit(std.testing.allocator);

        const delta = @as(i64, @intCast(random.intRangeAtMost(i32, -3, 6)));
        const size_value = base_expr.value + delta;

        const tmp_name = try std.fmt.allocPrint(std.testing.allocator, "tmp_{d}", .{iter});
        defer std.testing.allocator.free(tmp_name);

        var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
        errdefer aw.deinit();
        const writer = &aw.writer;
        try writer.writeAll("#def BASE = ");
        try writer.writeAll(base_expr.text);
        try writer.writeByte('\n');
        try writer.print("#def SIZE = BASE + {d}\n", .{delta});
        try writer.writeAll("@main() -> i32:\n");
        try writer.print("{s} = add SIZE, 1\n", .{tmp_name});
        try writer.print("return {s}\n", .{tmp_name});

        const source_text = try aw.toOwnedSlice();
        defer std.testing.allocator.free(source_text);

        var result = try flatten(std.testing.allocator, source_text);
        defer result.deinit(std.testing.allocator);

        var base_buf: [32]u8 = undefined;
        const base_text = try std.fmt.bufPrint(&base_buf, "{d}", .{base_expr.value});
        try std.testing.expectEqualStrings(base_text, result.def_dict.get("BASE").?);

        var size_buf: [32]u8 = undefined;
        const size_text = try std.fmt.bufPrint(&size_buf, "{d}", .{size_value});
        try std.testing.expectEqualStrings(size_text, result.def_dict.get("SIZE").?);

        try std.testing.expectEqual(@as(usize, 3), result.instructions.len);
        try std.testing.expectEqual(InstKind.func_decl, result.instructions[0].kind);
        try std.testing.expectEqual(InstKind.op, result.instructions[1].kind);
        try std.testing.expectEqual(common_instruction.OpKind.add, result.instructions[1].op_kind.?);
        try expectOperandImmI64(result.instructions[1], 1, size_value);
        try expectOperandImmI64(result.instructions[1], 2, 1);
        try std.testing.expectEqual(InstKind.return_, result.instructions[2].kind);
    }
}

test "forbidden syntax PBT rejects random forbidden lines through flatten" {
    const ForbiddenCase = struct {
        text: []const u8,
        token: forbidden.ForbiddenToken,
    };

    const cases = [_]ForbiddenCase{
        .{ .text = "if x = 1", .token = .keyword_if },
        .{ .text = "else x = 1", .token = .keyword_else },
        .{ .text = "while x = 1", .token = .keyword_while },
        .{ .text = "for x = 1", .token = .keyword_for },
        .{ .text = "x = { y }", .token = .brace_open },
        .{ .text = "x = }", .token = .brace_close },
        .{ .text = "x = a.b.c", .token = .property_chain },
    };

    var prng = std.Random.DefaultPrng.init(0x5A5A_6A21);
    const random = prng.random();

    for (0..48) |iter| {
        const case = cases[random.intRangeLessThan(usize, 0, cases.len)];
        try std.testing.expectEqual(case.token, forbidden.findForbiddenSyntax(case.text).?.token);

        const forbidden_at_tail = (iter & 1) == 0;
        const source = if (forbidden_at_tail) blk: {
            break :blk try std.fmt.allocPrint(std.testing.allocator,
                \\@main() -> i32:
                \\value = alloc 8
                \\{s}
                \\return 0
            , .{case.text});
        } else blk: {
            break :blk try std.fmt.allocPrint(std.testing.allocator,
                \\@main() -> i32:
                \\{s}
                \\value = alloc 8
                \\return 0
            , .{case.text});
        };
        defer std.testing.allocator.free(source);

        const expected_line_no: u32 = if (forbidden_at_tail) 3 else 2;
        const found = findFirstForbiddenLine(source).?;
        try std.testing.expectEqual(expected_line_no, found.line_no);
        try std.testing.expectEqual(case.token, found.hit.token);
        try std.testing.expectError(error.ForbiddenSyntax, flatten(std.testing.allocator, source));
    }
}

test "PRINT! and FORMAT! macro static expansion" {
    const source =
        \\@main() -> i32:
        \\EXPAND PRINT! "Hello, world!"
        \\EXPAND PRINT! "Value: {}", %val
        \\EXPAND FORMAT! %res, "A: {}, B: {}", %val1, %val2
        \\return 0
    ;

    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    // Let's assert that we have registered some const_decls for the literal segments
    try std.testing.expect(result.const_decls.len >= 3);

    // Let's verify that the literal contents match
    var found_hello = false;
    var found_value = false;
    var found_a = false;
    for (result.const_decls) |decl| {
        if (std.mem.eql(u8, decl.name, "__PRINT_LIT_2_0")) {
            try std.testing.expectEqualStrings("Hello, world!", decl.value.utf8.bytes);
            found_hello = true;
        }
        if (std.mem.indexOf(u8, decl.name, "__PRINT_LIT_3_") != null) {
            try std.testing.expectEqualStrings("Value: ", decl.value.utf8.bytes);
            found_value = true;
        }
        if (std.mem.indexOf(u8, decl.name, "__PRINT_LIT_4_") != null) {
            if (std.mem.eql(u8, decl.value.utf8.bytes, "A: ")) {
                found_a = true;
            }
        }
    }
    try std.testing.expect(found_hello);
    try std.testing.expect(found_value);
    try std.testing.expect(found_a);

    // Verify some instructions generated by the macros exist
    var found_sys_print = false;
    var found_direct_fmt_handle = false;
    var found_direct_fmt_data = false;
    var found_moved_fmt_free = false;
    var found_try_on_fmt = false;
    var found_legacy_fmt_data_borrow = false;
    for (result.instructions) |inst| {
        const raw_text = inst.raw_text;
        if (std.mem.indexOf(u8, raw_text, "call @sa_fmt_i64(%val, 10)") != null) {
            found_direct_fmt_handle = true;
        }
        if (std.mem.indexOf(u8, raw_text, "call @sa_fmt_buffer_data(__fmt_buf_3_0)") != null) {
            found_direct_fmt_data = true;
        }
        if (std.mem.indexOf(u8, raw_text, "call @sa_fmt_buffer_free(^__fmt_buf_3_0)") != null) {
            found_moved_fmt_free = true;
        }
        if (std.mem.indexOf(u8, raw_text, "call @sa_fmt_buffer_data(&") != null) {
            found_legacy_fmt_data_borrow = true;
        }
        if (inst.kind == .call) {
            if (inst.operands[0] == .text) {
                if (std.mem.startsWith(u8, inst.operands[0].text, "@sys_print")) {
                    found_sys_print = true;
                }
            }
        } else if (inst.kind == .early_return) {
            const src_name = result.symbols.lookupName(inst.operands[1].reg) orelse "";
            if (std.mem.startsWith(u8, src_name, "__fmt_")) {
                found_try_on_fmt = true;
            }
        }
    }
    try std.testing.expect(found_sys_print);
    try std.testing.expect(found_direct_fmt_handle);
    try std.testing.expect(found_direct_fmt_data);
    try std.testing.expect(found_moved_fmt_free);
    try std.testing.expect(!found_try_on_fmt);
    try std.testing.expect(!found_legacy_fmt_data_borrow);
}

test "hygiene: two macro expansions produce distinct internal symbols" {
    const source =
        \\[MACRO] BAR %x
        \\    _tmp = add %x, 1
        \\    return _tmp
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    EXPAND BAR 5
        \\    EXPAND BAR 10
    ;

    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    // Both expansions should have hygienified _tmp
    try std.testing.expect(result.symbols.contains("_tmp__sa_hyg1"));
    try std.testing.expect(result.symbols.contains("_tmp__sa_hyg2"));
    // Original _tmp should NOT appear as a symbol
    try std.testing.expect(!result.symbols.contains("_tmp"));
}

test "hygiene: parameter text is not hygienified" {
    const source =
        \\[MACRO] BAZ %out, %val
        \\    _internal = add %val, 1
        \\    %out = _internal
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    EXPAND BAZ _tmp, 5
        \\    return _tmp
    ;

    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    // _internal defined in macro body should be hygienified
    try std.testing.expect(result.symbols.contains("_internal__sa_hyg1"));
    // _tmp passed as parameter should NOT be hygienified
    try std.testing.expect(result.symbols.contains("_tmp"));
    // Original _internal should not appear
    try std.testing.expect(!result.symbols.contains("_internal"));
}

test "hygiene: token boundary does not falsely match partial identifiers" {
    const source =
        \\[MACRO] QUUX %x
        \\    _tmp = add %x, 1
        \\    _tmp2 = add _tmp, 2
        \\    return _tmp2
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    EXPAND QUUX 3
    ;

    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    // Both _tmp and _tmp2 should be hygienified (exact match)
    try std.testing.expect(result.symbols.contains("_tmp__sa_hyg1"));
    try std.testing.expect(result.symbols.contains("_tmp2__sa_hyg1"));
}

test "hygiene: REP labels are unique per iteration" {
    const source =
        \\@main() -> i32:
        \\L_ENTRY:
        \\[REP 3]
        \\L_LOOP:
        \\    tmp_%i = add %i, 0
        \\[END_REP]
        \\    return 0
    ;

    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    // Each REP iteration should produce a distinct hygienified label
    try std.testing.expect(result.symbols.contains("L_LOOP__sa_hyg1"));
    try std.testing.expect(result.symbols.contains("L_LOOP__sa_hyg2"));
    try std.testing.expect(result.symbols.contains("L_LOOP__sa_hyg3"));
    // Original L_LOOP should NOT appear as a label symbol
    try std.testing.expect(!result.symbols.contains("L_LOOP"));
}

test "hygiene: string and comment contents are not modified" {
    const source =
        \\[MACRO] STR5 %x
        \\    _tmp = add %x, 1
        \\    _msg = add 0, 0
        \\    return _tmp
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    EXPAND STR5 42
    ;

    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    // _tmp and _msg should be hygienified
    try std.testing.expect(result.symbols.contains("_tmp__sa_hyg1"));
    try std.testing.expect(result.symbols.contains("_msg__sa_hyg1"));
    // Original _tmp and _msg should NOT appear
    try std.testing.expect(!result.symbols.contains("_tmp"));
    try std.testing.expect(!result.symbols.contains("_msg"));
}

test "hygiene: nested macro expansion applies unique ids" {
    const source =
        \\[MACRO] INNER %x
        \\    _val = add %x, 1
        \\    return _val
        \\[END_MACRO]
        \\[MACRO] OUTER %y
        \\    _val = add %y, 2
        \\    EXPAND INNER _val
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    _out = alloc 8
        \\    EXPAND OUTER 5
    ;

    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    // OUTER's _val should be hygienified
    try std.testing.expect(result.symbols.contains("_val__sa_hyg1"));
    // INNER's _val should get a different hygiene id
    try std.testing.expect(result.symbols.contains("_val__sa_hyg2"));
    // Both expansions produced _val, but with different ids
    // Original _val should NOT appear
    try std.testing.expect(!result.symbols.contains("_val"));
}

test "hygiene: while-let macro with multiple expansions" {
    const source =
        \\#def Option_SIZE = 8
        \\
        \\[MACRO] UNWRAP_OR_ZERO %out, %opt_ptr
        \\    _tag = load %opt_ptr+0 as u32
        \\    _is_some = eq _tag, 1
        \\    !_tag
        \\    br _is_some -> L_SOME, L_NONE
        \\L_SOME:
        \\    !_is_some
        \\    %out = load %opt_ptr+4 as i32
        \\    !%opt_ptr
        \\    jmp L_END
        \\L_NONE:
        \\    !_is_some
        \\    !%opt_ptr
        \\    %out = add 0, 0
        \\L_END:
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    opt0 = alloc Option_SIZE
        \\    store opt0+0, 1 as u32
        \\    store opt0+4, 42 as i32
        \\    opt1 = alloc Option_SIZE
        \\    store opt1+0, 0 as u32
        \\    EXPAND UNWRAP_OR_ZERO v0, opt0
        \\    EXPAND UNWRAP_OR_ZERO v1, opt1
        \\    sum = add v0, v1
        \\    return sum
    ;

    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    // Labels should be hygienified - different per expansion
    try std.testing.expect(result.symbols.contains("L_SOME__sa_hyg1"));
    try std.testing.expect(result.symbols.contains("L_SOME__sa_hyg2"));
    try std.testing.expect(!result.symbols.contains("L_SOME"));

    // Internal names should be hygienified
    try std.testing.expect(result.symbols.contains("_tag__sa_hyg1"));
    try std.testing.expect(result.symbols.contains("_tag__sa_hyg2"));
    try std.testing.expect(!result.symbols.contains("_tag"));

    // Output params should NOT be hygienified
    try std.testing.expect(result.symbols.contains("v0"));
    try std.testing.expect(result.symbols.contains("v1"));
}

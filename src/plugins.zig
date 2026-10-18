const std = @import("std");
const sio = @import("sio");

pub const abi_version: u32 = 1;
pub const host_version: []const u8 = "sci-0.2";
pub const descriptor_symbol_name: [:0]const u8 = "saasm_plugin_descriptor_v1";
pub const descriptor_fn_symbol_name: [:0]const u8 = "saasm_plugin_descriptor_v1_fn";
pub const broker_abi_version: u32 = 1;

fn targetDynamicLibrarySuffix() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => ".dll",
        .macos => ".dylib",
        else => ".so",
    };
}

fn isDynamicLibraryPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".so") or
        std.mem.endsWith(u8, path, ".dll") or
        std.mem.endsWith(u8, path, ".dylib");
}

fn targetArtifactKey() []const u8 {
    const builtin = @import("builtin");
    return switch (builtin.cpu.arch) {
        .x86_64 => switch (builtin.os.tag) {
            .windows => "windows-x86_64",
            .linux => "linux-x86_64",
            .macos => "macos-x86_64",
            else => "linux-x86_64",
        },
        .aarch64 => switch (builtin.os.tag) {
            .windows => "windows-aarch64",
            .linux => "linux-aarch64",
            .macos => "macos-aarch64",
            else => "linux-aarch64",
        },
        else => switch (builtin.os.tag) {
            .windows => "windows-x86_64",
            .linux => "linux-x86_64",
            .macos => "macos-x86_64",
            else => "linux-x86_64",
        },
    };
}

test "plugin target helpers select host dynamic library and artifact key" {
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
        .windows => {
            try std.testing.expectEqualStrings(".dll", targetDynamicLibrarySuffix());
            try std.testing.expect(std.mem.startsWith(u8, targetArtifactKey(), "windows-"));
            try std.testing.expect(isDynamicLibraryPath("plugin.dll"));
        },
        .macos => {
            try std.testing.expectEqualStrings(".dylib", targetDynamicLibrarySuffix());
            try std.testing.expect(std.mem.startsWith(u8, targetArtifactKey(), "macos-"));
            try std.testing.expect(isDynamicLibraryPath("plugin.dylib"));
        },
        else => {
            try std.testing.expectEqualStrings(".so", targetDynamicLibrarySuffix());
            try std.testing.expect(std.mem.startsWith(u8, targetArtifactKey(), "linux-"));
            try std.testing.expect(isDynamicLibraryPath("plugin.so"));
        },
    }
}

pub const SkillSection = struct {
    name: []const u8,
    summary: []const u8,
    items: []const []const u8,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    host_version: ?[]const u8 = host_version,
    log: ?*const fn (ctx: *const anyopaque, level: LogLevel, message_ptr: [*]const u8, message_len: usize) callconv(.c) void = null,
    log_ctx: ?*anyopaque = null,
    json_mode: bool = false,
    broker_abi_version: u32 = 0,
    broker_call: ?BrokerCallFn = null,
    broker_ctx: ?*anyopaque = null,
};

pub const LogLevel = enum(u8) {
    debug,
    info,
    warn,
    err,
};

pub const AbiStatus = enum(u32) {
    ok = 0,
    unknown_command = 1,
    failed = 2,
    version_mismatch = 3,
    invalid_descriptor = 4,
};

pub const BrokerCallFn = *const fn (ctx: ?*anyopaque, op: u32, req: ?*const anyopaque, resp: ?*anyopaque) callconv(.c) u32;

pub const BrokerOp = enum(u32) {
    env_get = 1,
    fs_read = 2,
    http_request = 3,
    process_spawn = 4,
};

pub const BrokerStatus = enum(u32) {
    ok = 0,
    denied = 1,
    unsupported = 2,
    invalid_request = 3,
    not_found = 4,
    insufficient_buffer = 5,
    failed = 6,
};

pub const BrokerEnvGetRequest = extern struct {
    name_ptr: [*]const u8,
    name_len: usize,
    value_ptr: ?[*]u8,
    value_cap: usize,
};

pub const BrokerEnvGetResponse = extern struct {
    value_len: usize,
};

pub const BrokerFsReadRequest = extern struct {
    path_ptr: [*]const u8,
    path_len: usize,
    value_ptr: ?[*]u8,
    value_cap: usize,
};

pub const BrokerFsReadResponse = extern struct {
    value_len: usize,
};

pub const BrokerHttpRequest = extern struct {
    method_ptr: [*]const u8,
    method_len: usize,
    url_ptr: [*]const u8,
    url_len: usize,
    body_ptr: ?[*]const u8,
    body_len: usize,
    value_ptr: ?[*]u8,
    value_cap: usize,
};

pub const BrokerHttpResponse = extern struct {
    status_code: u16,
    value_len: usize,
};

pub const BrokerHttpResult = struct {
    status_code: u16,
    body: []const u8,
};

pub const BrokerString = extern struct {
    ptr: [*]const u8,
    len: usize,
};

pub const BrokerProcessSpawnRequest = extern struct {
    path_ptr: [*]const u8,
    path_len: usize,
    argv_ptr: ?[*]const BrokerString,
    argv_len: usize,
    stdout_ptr: ?[*]u8,
    stdout_cap: usize,
    stderr_ptr: ?[*]u8,
    stderr_cap: usize,
};

pub const BrokerProcessSpawnResponse = extern struct {
    exit_code: u32,
    stdout_len: usize,
    stderr_len: usize,
};

pub const BrokerProcessSpawnResult = struct {
    exit_code: u32,
    stdout: []const u8,
    stderr: []const u8,
};

pub const BrokerError = error{
    Unsupported,
    Denied,
    InvalidRequest,
    NotFound,
    InsufficientBuffer,
    Failed,
};

pub const RuntimeAuthorizationInput = struct {
    dev_mode: bool = false,
    project_root: ?[]const u8 = null,
    allow_env_declared: bool = false,
    allow_env: []const []const u8 = &.{},
    allow_read_declared: bool = false,
    allow_read: []const []const u8 = &.{},
    allow_write_declared: bool = false,
    allow_write: []const []const u8 = &.{},
    allow_net_declared: bool = false,
    allow_net: []const []const u8 = &.{},
    allow_run_declared: bool = false,
    allow_run: []const []const u8 = &.{},
};

pub fn brokerAvailable(ctx: *const Context) bool {
    const version = ctx.host_version orelse return false;
    if (!hostVersionSupportsBroker(version)) return false;
    return ctx.broker_call != null and ctx.broker_abi_version >= broker_abi_version;
}

pub fn brokerEnvGet(ctx: *const Context, name: []const u8, buffer: []u8) BrokerError![]const u8 {
    if (!brokerAvailable(ctx)) return error.Unsupported;
    const broker_call = ctx.broker_call orelse return error.Unsupported;
    var response = BrokerEnvGetResponse{ .value_len = 0 };
    const request = BrokerEnvGetRequest{
        .name_ptr = name.ptr,
        .name_len = name.len,
        .value_ptr = if (buffer.len == 0) null else buffer.ptr,
        .value_cap = buffer.len,
    };
    const status = brokerStatusFromInt(broker_call(ctx.broker_ctx, @intFromEnum(BrokerOp.env_get), &request, &response));
    return switch (status) {
        .ok => buffer[0..response.value_len],
        .denied => error.Denied,
        .unsupported => error.Unsupported,
        .invalid_request => error.InvalidRequest,
        .not_found => error.NotFound,
        .insufficient_buffer => error.InsufficientBuffer,
        .failed => error.Failed,
    };
}

pub fn brokerFsRead(ctx: *const Context, path: []const u8, buffer: []u8) BrokerError![]const u8 {
    if (!brokerAvailable(ctx)) return error.Unsupported;
    const broker_call = ctx.broker_call orelse return error.Unsupported;
    var response = BrokerFsReadResponse{ .value_len = 0 };
    const request = BrokerFsReadRequest{
        .path_ptr = path.ptr,
        .path_len = path.len,
        .value_ptr = if (buffer.len == 0) null else buffer.ptr,
        .value_cap = buffer.len,
    };
    const status = brokerStatusFromInt(broker_call(ctx.broker_ctx, @intFromEnum(BrokerOp.fs_read), &request, &response));
    return switch (status) {
        .ok => buffer[0..response.value_len],
        .denied => error.Denied,
        .unsupported => error.Unsupported,
        .invalid_request => error.InvalidRequest,
        .not_found => error.NotFound,
        .insufficient_buffer => error.InsufficientBuffer,
        .failed => error.Failed,
    };
}

pub fn brokerHttpRequest(
    ctx: *const Context,
    method: []const u8,
    url: []const u8,
    body: []const u8,
    buffer: []u8,
) BrokerError!BrokerHttpResult {
    if (!brokerAvailable(ctx)) return error.Unsupported;
    const broker_call = ctx.broker_call orelse return error.Unsupported;
    var response = BrokerHttpResponse{
        .status_code = 0,
        .value_len = 0,
    };
    const request = BrokerHttpRequest{
        .method_ptr = method.ptr,
        .method_len = method.len,
        .url_ptr = url.ptr,
        .url_len = url.len,
        .body_ptr = if (body.len == 0) null else body.ptr,
        .body_len = body.len,
        .value_ptr = if (buffer.len == 0) null else buffer.ptr,
        .value_cap = buffer.len,
    };
    const status = brokerStatusFromInt(broker_call(ctx.broker_ctx, @intFromEnum(BrokerOp.http_request), &request, &response));
    return switch (status) {
        .ok => .{
            .status_code = response.status_code,
            .body = buffer[0..response.value_len],
        },
        .denied => error.Denied,
        .unsupported => error.Unsupported,
        .invalid_request => error.InvalidRequest,
        .not_found => error.NotFound,
        .insufficient_buffer => error.InsufficientBuffer,
        .failed => error.Failed,
    };
}

pub fn brokerProcessSpawn(
    ctx: *const Context,
    path: []const u8,
    argv: []const BrokerString,
    stdout_buffer: []u8,
    stderr_buffer: []u8,
) BrokerError!BrokerProcessSpawnResult {
    if (!brokerAvailable(ctx)) return error.Unsupported;
    const broker_call = ctx.broker_call orelse return error.Unsupported;
    var response = BrokerProcessSpawnResponse{
        .exit_code = 0,
        .stdout_len = 0,
        .stderr_len = 0,
    };
    const request = BrokerProcessSpawnRequest{
        .path_ptr = path.ptr,
        .path_len = path.len,
        .argv_ptr = if (argv.len == 0) null else argv.ptr,
        .argv_len = argv.len,
        .stdout_ptr = if (stdout_buffer.len == 0) null else stdout_buffer.ptr,
        .stdout_cap = stdout_buffer.len,
        .stderr_ptr = if (stderr_buffer.len == 0) null else stderr_buffer.ptr,
        .stderr_cap = stderr_buffer.len,
    };
    const status = brokerStatusFromInt(broker_call(ctx.broker_ctx, @intFromEnum(BrokerOp.process_spawn), &request, &response));
    return switch (status) {
        .ok => .{
            .exit_code = response.exit_code,
            .stdout = stdout_buffer[0..response.stdout_len],
            .stderr = stderr_buffer[0..response.stderr_len],
        },
        .denied => error.Denied,
        .unsupported => error.Unsupported,
        .invalid_request => error.InvalidRequest,
        .not_found => error.NotFound,
        .insufficient_buffer => error.InsufficientBuffer,
        .failed => error.Failed,
    };
}

fn hostVersionSupportsBroker(version: []const u8) bool {
    const prefix = "sci-";
    if (!std.mem.startsWith(u8, version, prefix)) return false;
    var it = std.mem.splitScalar(u8, version[prefix.len..], '.');
    const major_text = it.next() orelse return false;
    const minor_text = it.next() orelse return false;
    const major = std.fmt.parseUnsigned(u32, major_text, 10) catch return false;
    const minor = std.fmt.parseUnsigned(u32, minor_text, 10) catch return false;
    return major > 0 or minor >= 2;
}

fn brokerStatusFromInt(value: u32) BrokerStatus {
    return switch (value) {
        @intFromEnum(BrokerStatus.ok) => .ok,
        @intFromEnum(BrokerStatus.denied) => .denied,
        @intFromEnum(BrokerStatus.unsupported) => .unsupported,
        @intFromEnum(BrokerStatus.invalid_request) => .invalid_request,
        @intFromEnum(BrokerStatus.not_found) => .not_found,
        @intFromEnum(BrokerStatus.insufficient_buffer) => .insufficient_buffer,
        @intFromEnum(BrokerStatus.failed) => .failed,
        else => .failed,
    };
}

pub const StreamWriteAllFn = *const fn (ctx: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) u32;

pub const HostStream = extern struct {
    ctx: ?*anyopaque,
    write_all: ?StreamWriteAllFn,
};

pub const PluginDescriptor = extern struct {
    abi_version: u32,
    descriptor_size: u32,
    name: [*:0]const u8,
    init: ?*const fn (ctx: *const Context) callconv(.c) u32,
    prebuild: ?*const fn (ctx: *const Context, compile_options: ?*anyopaque) callconv(.c) u32,
    postbuild: ?*const fn (ctx: *const Context) callconv(.c) u32,
    handle_command: ?*const fn (ctx: *const Context, argv: [*]const [*:0]const u8, argv_len: usize, stdout: HostStream, stderr: HostStream, out_code: *u8) callconv(.c) u32,
    skills_ptr: [*]const SkillSection,
    skills_len: usize,
};

pub const DescriptorFn = *const fn (out: *PluginDescriptor) callconv(.c) void;

pub const LoadDiagnostic = struct {
    path: []const u8,
    reason: []const u8,

    pub fn deinit(self: *LoadDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.reason);
        self.* = undefined;
    }
};

const LoadedPlugin = struct {
    path: []const u8,
    lib: std.DynLib,
    descriptor: PluginDescriptor,
    permission_policy: RuntimePermissionPolicy = .{},

    fn exportsAny(self: *LoadedPlugin, allocator: std.mem.Allocator, symbol_names: []const []const u8) !bool {
        for (symbol_names) |symbol| {
            const symbol_z = try allocator.dupeSentinel(u8, symbol, 0);
            defer allocator.free(symbol_z);
            if (self.lib.lookup(*anyopaque, symbol_z)) |_| return true;
        }
        return false;
    }

    fn exportsAll(self: *LoadedPlugin, allocator: std.mem.Allocator, symbol_names: []const []u8) !bool {
        for (symbol_names) |symbol| {
            const symbol_z = try allocator.dupeSentinel(u8, symbol, 0);
            defer allocator.free(symbol_z);
            if (self.lib.lookup(*anyopaque, symbol_z) == null) return false;
        }
        return true;
    }

    fn deinit(self: *LoadedPlugin, allocator: std.mem.Allocator) void {
        self.lib.close();
        allocator.free(self.path);
        self.permission_policy.deinit(allocator);
        self.* = undefined;
    }
};

const ManifestHelpEntry = struct {
    name: []u8,
    sap_path: []u8,

    fn deinit(self: *ManifestHelpEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.sap_path);
        self.* = undefined;
    }
};

const FsPermissionOp = enum {
    read,
    write,
    create,
    delete,
    metadata,
};

const FsPermission = struct {
    op: FsPermissionOp,
    path: []u8,

    fn deinit(self: *FsPermission, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

const HttpMethodMask = struct {
    bits: u16 = 0,

    fn default() HttpMethodMask {
        var mask = HttpMethodMask{};
        mask.insert(.GET);
        return mask;
    }

    fn insert(self: *HttpMethodMask, method: std.http.Method) void {
        self.bits |= httpMethodBit(method) orelse 0;
    }

    fn contains(self: HttpMethodMask, method: std.http.Method) bool {
        const bit = httpMethodBit(method) orelse return false;
        return (self.bits & bit) != 0;
    }
};

const NetPermission = struct {
    url: []u8,
    methods: HttpMethodMask,

    fn deinit(self: *NetPermission, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        self.* = undefined;
    }
};

const ProcessExecPermission = struct {
    path: []u8,
    args: [][]u8,

    fn deinit(self: *ProcessExecPermission, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.args) |arg| allocator.free(arg);
        allocator.free(self.args);
        self.* = undefined;
    }
};

const RuntimePermissionPolicy = struct {
    has_manifest: bool = false,
    requires_sandbox: bool = false,
    env_permissions: std.ArrayList([]u8) = .empty,
    fs_permissions: std.ArrayList(FsPermission) = .empty,
    net_permissions: std.ArrayList(NetPermission) = .empty,
    process_spawn: bool = false,
    process_exec_permissions: std.ArrayList(ProcessExecPermission) = .empty,

    fn initFromManifest(allocator: std.mem.Allocator, manifest: SapManifest) !RuntimePermissionPolicy {
        var policy = RuntimePermissionPolicy{
            .has_manifest = true,
            .requires_sandbox = manifest.requires_sandbox,
        };
        errdefer policy.deinit(allocator);
        for (manifest.env_permissions) |entry| {
            try policy.env_permissions.append(allocator, try allocator.dupe(u8, entry));
        }
        for (manifest.fs_permissions) |entry| {
            try policy.fs_permissions.append(allocator, .{
                .op = entry.op,
                .path = try allocator.dupe(u8, entry.path),
            });
        }
        for (manifest.net_permissions) |entry| {
            try policy.net_permissions.append(allocator, .{
                .url = try allocator.dupe(u8, entry.url),
                .methods = entry.methods,
            });
        }
        policy.process_spawn = manifest.process_spawn;
        for (manifest.process_exec_permissions) |entry| {
            var owned_args = std.array_list.Managed([]u8).init(allocator);
            errdefer {
                for (owned_args.items) |arg| allocator.free(arg);
                owned_args.deinit();
            }
            for (entry.args) |arg| try owned_args.append(try allocator.dupe(u8, arg));
            try policy.process_exec_permissions.append(allocator, .{
                .path = try allocator.dupe(u8, entry.path),
                .args = try owned_args.toOwnedSlice(),
            });
        }
        return policy;
    }

    fn deinit(self: *RuntimePermissionPolicy, allocator: std.mem.Allocator) void {
        for (self.env_permissions.items) |entry| allocator.free(entry);
        self.env_permissions.deinit(allocator);
        for (self.fs_permissions.items) |*entry| entry.deinit(allocator);
        self.fs_permissions.deinit(allocator);
        for (self.net_permissions.items) |*entry| entry.deinit(allocator);
        self.net_permissions.deinit(allocator);
        for (self.process_exec_permissions.items) |*entry| entry.deinit(allocator);
        self.process_exec_permissions.deinit(allocator);
        self.* = undefined;
    }

    fn allowsEnv(self: *const RuntimePermissionPolicy, name: []const u8) bool {
        return matchesAnyEnvPattern(self.env_permissions.items, name);
    }

    fn allowsFs(self: *const RuntimePermissionPolicy, allocator: std.mem.Allocator, project_root: []const u8, op: FsPermissionOp, abs_path: []const u8) !bool {
        for (self.fs_permissions.items) |entry| {
            if (entry.op != op) continue;
            if (try matchesPathPermissionPattern(allocator, entry.path, project_root, abs_path)) return true;
        }
        return false;
    }

    fn allowsNet(self: *const RuntimePermissionPolicy, allocator: std.mem.Allocator, method: std.http.Method, url: []const u8) !bool {
        for (self.net_permissions.items) |entry| {
            if (!entry.methods.contains(method)) continue;
            if (try matchesUrlPermissionPattern(allocator, entry.url, url)) return true;
        }
        return false;
    }

    fn allowsProcessSpawn(self: *const RuntimePermissionPolicy, allocator: std.mem.Allocator, abs_path: []const u8, argv: []const []const u8) !bool {
        if (!self.process_spawn) return false;
        for (self.process_exec_permissions.items) |entry| {
            if (try matchesExecutablePermissionPath(allocator, entry.path, abs_path) and processArgsMatch(entry.args, argv)) return true;
        }
        return false;
    }
};

const RuntimeHostAuthorization = struct {
    dev_mode: bool = false,
    project_root: ?[]u8 = null,
    allow_env_declared: bool = false,
    allow_read_declared: bool = false,
    allow_write_declared: bool = false,
    allow_net_declared: bool = false,
    allow_run_declared: bool = false,
    allow_env: std.ArrayList([]u8) = .empty,
    allow_read: std.ArrayList([]u8) = .empty,
    allow_write: std.ArrayList([]u8) = .empty,
    allow_net: std.ArrayList([]u8) = .empty,
    allow_run: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator, input: RuntimeAuthorizationInput) !RuntimeHostAuthorization {
        var auth = RuntimeHostAuthorization{
            .dev_mode = input.dev_mode,
            .allow_env_declared = input.allow_env_declared,
            .allow_read_declared = input.allow_read_declared,
            .allow_write_declared = input.allow_write_declared,
            .allow_net_declared = input.allow_net_declared,
            .allow_run_declared = input.allow_run_declared,
        };
        errdefer auth.deinit(allocator);
        auth.project_root = if (input.project_root) |root|
            try allocator.dupe(u8, root)
        else
            try sio.cwd().realpathAlloc(allocator, ".");
        try appendOwnedStrings(allocator, &auth.allow_env, input.allow_env);
        try appendOwnedStrings(allocator, &auth.allow_read, input.allow_read);
        try appendOwnedStrings(allocator, &auth.allow_write, input.allow_write);
        try appendOwnedStrings(allocator, &auth.allow_net, input.allow_net);
        try appendOwnedStrings(allocator, &auth.allow_run, input.allow_run);
        return auth;
    }

    fn deinit(self: *RuntimeHostAuthorization, allocator: std.mem.Allocator) void {
        if (self.project_root) |root| allocator.free(root);
        freeOwnedStringList(allocator, &self.allow_env);
        freeOwnedStringList(allocator, &self.allow_read);
        freeOwnedStringList(allocator, &self.allow_write);
        freeOwnedStringList(allocator, &self.allow_net);
        freeOwnedStringList(allocator, &self.allow_run);
        self.* = undefined;
    }

    fn effectiveProjectRoot(self: *const RuntimeHostAuthorization) []const u8 {
        return self.project_root orelse ".";
    }

    fn allowsEnv(self: *const RuntimeHostAuthorization, name: []const u8) bool {
        if (self.dev_mode) return true;
        if (self.allow_env_declared) return true;
        return matchesAnyEnvPattern(self.allow_env.items, name);
    }

    fn allowsRead(self: *const RuntimeHostAuthorization, allocator: std.mem.Allocator, abs_path: []const u8) !bool {
        if (self.dev_mode) return true;
        if (self.allow_read_declared) return true;
        const project_root = self.effectiveProjectRoot();
        for (self.allow_read.items) |entry| {
            if (try matchesPathPermissionPattern(allocator, entry, project_root, abs_path)) return true;
        }
        return false;
    }

    fn allowsNet(self: *const RuntimeHostAuthorization, allocator: std.mem.Allocator, url: []const u8) !bool {
        if (self.dev_mode) return true;
        if (self.allow_net_declared) return true;
        for (self.allow_net.items) |entry| {
            if (try matchesUrlPermissionPattern(allocator, entry, url)) return true;
        }
        return false;
    }

    fn allowsRun(self: *const RuntimeHostAuthorization, allocator: std.mem.Allocator, abs_path: []const u8) !bool {
        if (self.dev_mode) return true;
        if (self.allow_run_declared) return true;
        for (self.allow_run.items) |entry| {
            if (try matchesExecutablePermissionPath(allocator, entry, abs_path)) return true;
        }
        return false;
    }
};

const RuntimeBroker = struct {
    allocator: std.mem.Allocator,
    policy: *const RuntimePermissionPolicy,
    authorization: *const RuntimeHostAuthorization,
};

const max_net_probe_bytes: usize = 4 * 1024 * 1024;
const max_process_probe_bytes: usize = 4 * 1024 * 1024;

fn runtimeBrokerCall(ctx: ?*anyopaque, op_value: u32, req: ?*const anyopaque, resp: ?*anyopaque) callconv(.c) u32 {
    const broker = if (ctx) |raw|
        @as(*const RuntimeBroker, @ptrCast(@alignCast(raw)))
    else
        return @intFromEnum(BrokerStatus.invalid_request);

    const op = switch (op_value) {
        @intFromEnum(BrokerOp.env_get) => BrokerOp.env_get,
        @intFromEnum(BrokerOp.fs_read) => BrokerOp.fs_read,
        @intFromEnum(BrokerOp.http_request) => BrokerOp.http_request,
        @intFromEnum(BrokerOp.process_spawn) => BrokerOp.process_spawn,
        else => return @intFromEnum(BrokerStatus.unsupported),
    };

    return @intFromEnum(switch (op) {
        .env_get => runtimeBrokerEnvGet(broker, req, resp),
        .fs_read => runtimeBrokerFsRead(broker, req, resp),
        .http_request => runtimeBrokerHttpRequest(broker, req, resp),
        .process_spawn => runtimeBrokerProcessSpawn(broker, req, resp),
    });
}

fn runtimeBrokerEnvGet(broker: *const RuntimeBroker, req: ?*const anyopaque, resp: ?*anyopaque) BrokerStatus {
    const request = if (req) |raw|
        @as(*const BrokerEnvGetRequest, @ptrCast(@alignCast(raw)))
    else
        return .invalid_request;
    const response = if (resp) |raw|
        @as(*BrokerEnvGetResponse, @ptrCast(@alignCast(raw)))
    else
        return .invalid_request;
    response.* = .{ .value_len = 0 };

    if (request.name_len == 0) return .invalid_request;
    if (request.value_cap != 0 and request.value_ptr == null) return .invalid_request;

    const env_name = request.name_ptr[0..request.name_len];
    if (!broker.policy.allowsEnv(env_name)) return .denied;
    if (!broker.authorization.allowsEnv(env_name)) return .denied;

    const value = sio.getEnvVarOwned(broker.allocator, env_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return .not_found,
        else => return .failed,
    };
    defer broker.allocator.free(value);

    response.value_len = value.len;
    if (value.len > request.value_cap) return .insufficient_buffer;
    if (value.len != 0) {
        const out_ptr = request.value_ptr orelse return .invalid_request;
        @memcpy(out_ptr[0..value.len], value);
    }
    return .ok;
}

fn runtimeBrokerFsRead(broker: *const RuntimeBroker, req: ?*const anyopaque, resp: ?*anyopaque) BrokerStatus {
    const request = if (req) |raw|
        @as(*const BrokerFsReadRequest, @ptrCast(@alignCast(raw)))
    else
        return .invalid_request;
    const response = if (resp) |raw|
        @as(*BrokerFsReadResponse, @ptrCast(@alignCast(raw)))
    else
        return .invalid_request;
    response.* = .{ .value_len = 0 };

    if (request.path_len == 0) return .invalid_request;
    if (request.value_cap != 0 and request.value_ptr == null) return .invalid_request;

    const project_root = broker.authorization.effectiveProjectRoot();
    const abs_path = resolveBrokerRequestPath(broker.allocator, request.path_ptr[0..request.path_len], project_root) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        else => return .failed,
    };
    defer broker.allocator.free(abs_path);

    const manifest_allowed = broker.policy.allowsFs(broker.allocator, project_root, .read, abs_path) catch return .failed;
    if (!manifest_allowed) return .denied;
    const host_allowed = broker.authorization.allowsRead(broker.allocator, abs_path) catch return .failed;
    if (!host_allowed) return .denied;

    var file = sio.openFileAbsolute(abs_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        else => return .failed,
    };
    defer file.close();

    const file_size = file.getEndPos() catch return .failed;
    response.value_len = @as(usize, @intCast(file_size));
    if (file_size > request.value_cap) return .insufficient_buffer;
    if (file_size == 0) return .ok;

    const out_ptr = request.value_ptr orelse return .invalid_request;
    const out = out_ptr[0..@as(usize, @intCast(file_size))];
    file.readAll(out) catch return .failed;
    return .ok;
}

fn runtimeBrokerHttpRequest(broker: *const RuntimeBroker, req: ?*const anyopaque, resp: ?*anyopaque) BrokerStatus {
    const request = if (req) |raw|
        @as(*const BrokerHttpRequest, @ptrCast(@alignCast(raw)))
    else
        return .invalid_request;
    const response = if (resp) |raw|
        @as(*BrokerHttpResponse, @ptrCast(@alignCast(raw)))
    else
        return .invalid_request;
    response.* = .{
        .status_code = 0,
        .value_len = 0,
    };

    if (request.method_len == 0 or request.url_len == 0) return .invalid_request;
    if (request.body_len != 0 and request.body_ptr == null) return .invalid_request;
    if (request.value_cap != 0 and request.value_ptr == null) return .invalid_request;

    const method_text = request.method_ptr[0..request.method_len];
    const method = parseBrokerHttpMethod(method_text) orelse return .invalid_request;
    if (request.body_len != 0 and !method.requestHasBody()) return .invalid_request;

    const url = request.url_ptr[0..request.url_len];
    if (!allowedPermissionUrl(url)) return .denied;

    const manifest_allowed = broker.policy.allowsNet(broker.allocator, method, url) catch return .failed;
    if (!manifest_allowed) return .denied;
    const host_allowed = broker.authorization.allowsNet(broker.allocator, url) catch return .failed;
    if (!host_allowed) return .denied;

    const uri = std.Uri.parse(url) catch return .invalid_request;
    const body = if (request.body_len == 0)
        ""
    else
        request.body_ptr.?[0..request.body_len];

    var client: std.http.Client = .{ .allocator = broker.allocator, .io = sio.io() };
    defer client.deinit();

    var http_request = client.request(method, uri, .{
        .redirect_behavior = .not_allowed,
        .keep_alive = false,
        .headers = .{
            .accept_encoding = .omit,
        },
    }) catch return .failed;
    defer http_request.deinit();

    if (method.requestHasBody()) {
        // NOTE(Zig 0.17): sendBodyComplete takes mutable []u8.
        const body_mut = broker.allocator.dupe(u8, body) catch return .failed;
        defer broker.allocator.free(body_mut);
        http_request.sendBodyComplete(body_mut) catch return .failed;
    } else {
        http_request.sendBodiless() catch return .failed;
    }
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response_head = http_request.receiveHead(&redirect_buf) catch return .failed;

    response.status_code = @intFromEnum(response_head.head.status);
    if (!method.responseHasBody()) return .ok;

    if (response_head.head.content_length) |content_length| {
        response.value_len = @as(usize, @intCast(content_length));
        if (content_length > request.value_cap) return .insufficient_buffer;
        if (content_length == 0) return .ok;
        const out_ptr = request.value_ptr orelse return .invalid_request;
        const out = out_ptr[0..@as(usize, @intCast(content_length))];
        var transfer_buf: [8192]u8 = undefined;
        response_head.reader(&transfer_buf).readSliceAll(out) catch return .failed;
        return .ok;
    }

    const unknown_body_limit = if (request.value_cap < max_net_probe_bytes)
        request.value_cap + 1
    else
        max_net_probe_bytes;
    var transfer_buf: [8192]u8 = undefined;
    var body_reader = response_head.reader(&transfer_buf);
    const payload = body_reader.allocRemaining(broker.allocator, .limited(unknown_body_limit)) catch |err| {
        if (err == error.StreamTooLong) {
            response.value_len = unknown_body_limit;
            return .insufficient_buffer;
        }
        return .failed;
    };
    defer broker.allocator.free(payload);

    response.value_len = payload.len;
    if (payload.len > request.value_cap) return .insufficient_buffer;
    if (payload.len == 0) return .ok;

    const out_ptr = request.value_ptr orelse return .invalid_request;
    @memcpy(out_ptr[0..payload.len], payload);
    return .ok;
}

fn runtimeBrokerProcessSpawn(broker: *const RuntimeBroker, req: ?*const anyopaque, resp: ?*anyopaque) BrokerStatus {
    const request = if (req) |raw|
        @as(*const BrokerProcessSpawnRequest, @ptrCast(@alignCast(raw)))
    else
        return .invalid_request;
    const response = if (resp) |raw|
        @as(*BrokerProcessSpawnResponse, @ptrCast(@alignCast(raw)))
    else
        return .invalid_request;
    response.* = .{
        .exit_code = 0,
        .stdout_len = 0,
        .stderr_len = 0,
    };

    if (request.path_len == 0) return .invalid_request;
    if (request.argv_len != 0 and request.argv_ptr == null) return .invalid_request;
    if (request.stdout_cap != 0 and request.stdout_ptr == null) return .invalid_request;
    if (request.stderr_cap != 0 and request.stderr_ptr == null) return .invalid_request;

    const path = request.path_ptr[0..request.path_len];
    const abs_path = resolveExecutablePath(broker.allocator, path) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        error.InvalidPath => return .invalid_request,
        else => return .failed,
    };
    defer broker.allocator.free(abs_path);

    var argv_list = std.array_list.Managed([]const u8).init(broker.allocator);
    defer argv_list.deinit();
    if (request.argv_len != 0) {
        const raw_argv = request.argv_ptr.?[0..request.argv_len];
        for (raw_argv) |arg| {
            if (arg.len == 0) return .invalid_request;
            argv_list.append(arg.ptr[0..arg.len]) catch return .failed;
        }
    }

    const manifest_allowed = broker.policy.allowsProcessSpawn(broker.allocator, abs_path, argv_list.items) catch return .failed;
    if (!manifest_allowed) return .denied;
    const host_allowed = broker.authorization.allowsRun(broker.allocator, abs_path) catch return .failed;
    if (!host_allowed) return .denied;

    var command_argv = std.array_list.Managed([]const u8).init(broker.allocator);
    defer command_argv.deinit();
    command_argv.append(abs_path) catch return .failed;
    command_argv.appendSlice(argv_list.items) catch return .failed;

    const max_output_bytes = if (request.stdout_cap + request.stderr_cap + 1 > max_process_probe_bytes)
        max_process_probe_bytes
    else
        request.stdout_cap + request.stderr_cap + 1;
    const result = sio.Child.run(.{
        .allocator = broker.allocator,
        .argv = command_argv.items,
        .max_output_bytes = max_output_bytes,
    }) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        error.StreamTooLong => return .insufficient_buffer,
        else => return .failed,
    };
    defer broker.allocator.free(result.stdout);
    defer broker.allocator.free(result.stderr);

    response.stdout_len = result.stdout.len;
    response.stderr_len = result.stderr.len;
    if (result.stdout.len > request.stdout_cap or result.stderr.len > request.stderr_cap) return .insufficient_buffer;

    response.exit_code = switch (result.term) {
        .exited => |code| code,
        else => return .failed,
    };

    if (result.stdout.len != 0) {
        const stdout_ptr = request.stdout_ptr orelse return .invalid_request;
        @memcpy(stdout_ptr[0..result.stdout.len], result.stdout);
    }
    if (result.stderr.len != 0) {
        const stderr_ptr = request.stderr_ptr orelse return .invalid_request;
        @memcpy(stderr_ptr[0..result.stderr.len], result.stderr);
    }
    return .ok;
}

fn loadRuntimePermissionPolicy(allocator: std.mem.Allocator, lib_path: []const u8) !RuntimePermissionPolicy {
    const dir_path = std.fs.path.dirname(lib_path) orelse return .{};
    const sap_path = try std.fs.path.join(allocator, &.{ dir_path, "sap.json" });
    defer allocator.free(sap_path);
    if (!fileExistsAbsolute(sap_path)) return .{};

    var manifest = parseSapManifest(allocator, sap_path) catch return .{};
    defer manifest.deinit(allocator);
    return try RuntimePermissionPolicy.initFromManifest(allocator, manifest);
}

fn appendOwnedStrings(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), entries: []const []const u8) !void {
    for (entries) |entry| {
        try list.append(allocator, try allocator.dupe(u8, entry));
    }
}

fn freeOwnedStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |entry| allocator.free(entry);
    list.deinit(allocator);
}

fn matchesAnyEnvPattern(patterns: []const []u8, name: []const u8) bool {
    for (patterns) |entry| {
        if (std.mem.endsWith(u8, entry, "*")) {
            if (std.mem.startsWith(u8, name, entry[0 .. entry.len - 1])) return true;
            continue;
        }
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

fn resolveBrokerRequestPath(allocator: std.mem.Allocator, requested_path: []const u8, project_root: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(requested_path)) return try sio.cwd().realpathAlloc(allocator, requested_path);
    const joined = try std.fs.path.join(allocator, &.{ project_root, requested_path });
    defer allocator.free(joined);
    return try sio.cwd().realpathAlloc(allocator, joined);
}

fn parseBrokerHttpMethod(text: []const u8) ?std.http.Method {
    const method: std.http.Method = std.meta.stringToEnum(std.http.Method, text) orelse return null;
    return switch (method) {
        .GET, .POST, .PUT, .PATCH, .DELETE, .HEAD, .OPTIONS => method,
        else => null,
    };
}

fn httpMethodBit(method: std.http.Method) ?u16 {
    return switch (method) {
        .GET => 1 << 0,
        .POST => 1 << 1,
        .PUT => 1 << 2,
        .PATCH => 1 << 3,
        .DELETE => 1 << 4,
        .HEAD => 1 << 5,
        .OPTIONS => 1 << 6,
        else => null,
    };
}

fn matchesUrlPermissionPattern(allocator: std.mem.Allocator, pattern_url: []const u8, requested_url: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const pattern_uri = std.Uri.parse(pattern_url) catch return false;
    const requested_uri = std.Uri.parse(requested_url) catch return false;

    if (!std.ascii.eqlIgnoreCase(pattern_uri.scheme, requested_uri.scheme)) return false;

    const pattern_host_component = pattern_uri.host orelse return false;
    const requested_host_component = requested_uri.host orelse return false;
    const pattern_host = try pattern_host_component.toRawMaybeAlloc(arena_alloc);
    const requested_host = try requested_host_component.toRawMaybeAlloc(arena_alloc);
    if (!std.ascii.eqlIgnoreCase(pattern_host, requested_host)) return false;

    if (effectiveUriPort(pattern_uri) != effectiveUriPort(requested_uri)) return false;

    const pattern_path = normalizedUriPath(pattern_uri, arena_alloc) catch return false;
    const requested_path = normalizedUriPath(requested_uri, arena_alloc) catch return false;
    return uriPathAllows(pattern_path, requested_path);
}

fn effectiveUriPort(uri: std.Uri) ?u16 {
    if (uri.port) |port| return port;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) return 80;
    return null;
}

fn normalizedUriPath(uri: std.Uri, allocator: std.mem.Allocator) ![]const u8 {
    const raw_path = try uri.path.toRawMaybeAlloc(allocator);
    if (raw_path.len == 0) return "/";
    return trimTrailingSlashExceptRoot(raw_path);
}

fn trimTrailingSlashExceptRoot(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') : (end -= 1) {}
    return path[0..end];
}

fn uriPathAllows(pattern_path: []const u8, requested_path: []const u8) bool {
    if (std.mem.eql(u8, pattern_path, "/")) return true;
    if (std.mem.eql(u8, pattern_path, requested_path)) return true;
    if (!std.mem.startsWith(u8, requested_path, pattern_path)) return false;
    return requested_path.len > pattern_path.len and requested_path[pattern_path.len] == '/';
}

fn resolveExecutablePath(allocator: std.mem.Allocator, requested_path: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(requested_path)) return error.InvalidPath;
    return try sio.cwd().realpathAlloc(allocator, requested_path);
}

fn matchesExecutablePermissionPath(allocator: std.mem.Allocator, declared_path: []const u8, abs_path: []const u8) !bool {
    if (!std.fs.path.isAbsolute(declared_path)) return false;
    const resolved_declared = sio.cwd().realpathAlloc(allocator, declared_path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(resolved_declared);
    return std.mem.eql(u8, resolved_declared, abs_path);
}

fn processArgsMatch(patterns: []const []u8, argv: []const []const u8) bool {
    if (patterns.len != argv.len) return false;
    for (patterns, argv) |pattern, arg| {
        if (std.mem.eql(u8, pattern, "*")) continue;
        if (!std.mem.eql(u8, pattern, arg)) return false;
    }
    return true;
}

fn matchesPathPermissionPattern(allocator: std.mem.Allocator, pattern: []const u8, project_root: []const u8, abs_path: []const u8) !bool {
    const resolved = try resolvePermissionPathPattern(allocator, pattern, project_root);
    defer allocator.free(resolved);

    const normalized_resolved = try normalizePermissionPathForMatch(allocator, resolved);
    defer allocator.free(normalized_resolved);
    const normalized_abs_path = try normalizePermissionPathForMatch(allocator, abs_path);
    defer allocator.free(normalized_abs_path);

    const recursive = std.mem.endsWith(u8, normalized_resolved, "/**");
    const base = if (recursive) normalized_resolved[0 .. normalized_resolved.len - 3] else normalized_resolved;
    if (recursive) {
        if (std.mem.eql(u8, normalized_abs_path, base)) return true;
        if (base.len == 0) return false;
        if (!std.mem.startsWith(u8, normalized_abs_path, base)) return false;
        return normalized_abs_path.len > base.len and normalized_abs_path[base.len] == '/';
    }
    return std.mem.eql(u8, normalized_abs_path, base);
}

fn normalizePermissionPathForMatch(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, path);
    for (normalized) |*c| {
        if (c.* == '\\') c.* = '/';
        if (@import("builtin").os.tag == .windows) c.* = std.ascii.toLower(c.*);
    }
    return normalized;
}

fn permissionHome(allocator: std.mem.Allocator) ![]u8 {
    return sio.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => if (@import("builtin").os.tag == .windows)
            sio.getEnvVarOwned(allocator, "USERPROFILE")
        else
            error.EnvironmentVariableNotFound,
        else => err,
    };
}

fn resolvePermissionPathPattern(allocator: std.mem.Allocator, pattern: []const u8, project_root: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, pattern, "$PROJECT/") or std.mem.eql(u8, pattern, "$PROJECT")) {
        return try resolvePatternFromRoot(allocator, project_root, pattern["$PROJECT".len..]);
    }
    if (std.mem.startsWith(u8, pattern, "$HOME/") or std.mem.eql(u8, pattern, "$HOME")) {
        const home = permissionHome(allocator) catch return error.InvalidPath;
        defer allocator.free(home);
        return try resolvePatternFromRoot(allocator, home, pattern["$HOME".len..]);
    }
    if (std.mem.startsWith(u8, pattern, "$SA_PLUGINS_HOME/") or std.mem.eql(u8, pattern, "$SA_PLUGINS_HOME")) {
        const home = try pluginsHome(allocator);
        defer allocator.free(home);
        return try resolvePatternFromRoot(allocator, home, pattern["$SA_PLUGINS_HOME".len..]);
    }
    if (std.mem.startsWith(u8, pattern, "$SA_CACHE/") or std.mem.eql(u8, pattern, "$SA_CACHE")) {
        const cache_root = try std.fs.path.join(allocator, &.{ project_root, ".sa_cache" });
        defer allocator.free(cache_root);
        return try resolvePatternFromRoot(allocator, cache_root, pattern["$SA_CACHE".len..]);
    }
    if (std.fs.path.isAbsolute(pattern)) return try allocator.dupe(u8, pattern);
    return error.InvalidPath;
}

fn resolvePatternFromRoot(allocator: std.mem.Allocator, root: []const u8, suffix: []const u8) ![]u8 {
    const recursive = std.mem.endsWith(u8, suffix, "/**");
    const suffix_body = if (recursive) suffix[0 .. suffix.len - 3] else suffix;
    const trimmed = std.mem.trimStart(u8, suffix_body, "/");
    const base = if (trimmed.len == 0)
        try allocator.dupe(u8, root)
    else
        try std.fs.path.join(allocator, &.{ root, trimmed });
    if (!recursive) return base;
    defer allocator.free(base);
    return try std.fmt.allocPrint(allocator, "{s}/**", .{base});
}

test "Windows permission path matching ignores separator and ASCII case" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };
    const project_root = try tdir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);
    const requested_path = try std.fs.path.join(std.testing.allocator, &.{ project_root, "DATA", "ITEM.TXT" });
    defer std.testing.allocator.free(requested_path);
    for (requested_path) |*c| {
        if (c.* == '\\') c.* = '/';
        c.* = std.ascii.toUpper(c.*);
    }

    try std.testing.expect(try matchesPathPermissionPattern(
        std.testing.allocator,
        "$PROJECT/data/**",
        project_root,
        requested_path,
    ));
}

test "permission path roots expand for host matching" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };
    const project_root = try tdir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);

    const project_path = try std.fs.path.join(std.testing.allocator, &.{ project_root, "data", "item.txt" });
    defer std.testing.allocator.free(project_path);
    try std.testing.expect(try matchesPathPermissionPattern(std.testing.allocator, "$PROJECT/data/**", project_root, project_path));

    const cache_path = try std.fs.path.join(std.testing.allocator, &.{ project_root, ".sa_cache", "item.txt" });
    defer std.testing.allocator.free(cache_path);
    try std.testing.expect(try matchesPathPermissionPattern(std.testing.allocator, "$SA_CACHE/**", project_root, cache_path));

    const home = try permissionHome(std.testing.allocator);
    defer std.testing.allocator.free(home);
    const home_path = try std.fs.path.join(std.testing.allocator, &.{ home, "sa-permission-item.txt" });
    defer std.testing.allocator.free(home_path);
    try std.testing.expect(try matchesPathPermissionPattern(std.testing.allocator, "$HOME/**", project_root, home_path));

    const plugins_home = try pluginsHome(std.testing.allocator);
    defer std.testing.allocator.free(plugins_home);
    const plugin_path = try std.fs.path.join(std.testing.allocator, &.{ plugins_home, "installed", "item" });
    defer std.testing.allocator.free(plugin_path);
    try std.testing.expect(try matchesPathPermissionPattern(std.testing.allocator, "$SA_PLUGINS_HOME/**", project_root, plugin_path));
}

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    plugins: std.array_list.Managed(LoadedPlugin),
    manifest_help: std.array_list.Managed(ManifestHelpEntry),
    diagnostics: std.array_list.Managed(LoadDiagnostic),
    host_authorization: RuntimeHostAuthorization,

    pub fn init(allocator: std.mem.Allocator) Runtime {
        return .{
            .allocator = allocator,
            .plugins = std.array_list.Managed(LoadedPlugin).init(allocator),
            .manifest_help = std.array_list.Managed(ManifestHelpEntry).init(allocator),
            .diagnostics = std.array_list.Managed(LoadDiagnostic).init(allocator),
            .host_authorization = .{},
        };
    }

    pub fn initWithAuthorization(allocator: std.mem.Allocator, authorization: RuntimeAuthorizationInput) !Runtime {
        var runtime = Runtime.init(allocator);
        errdefer runtime.deinit();
        runtime.host_authorization = try RuntimeHostAuthorization.init(allocator, authorization);
        return runtime;
    }

    pub fn initFromEnv(allocator: std.mem.Allocator) !Runtime {
        var runtime = try Runtime.initWithAuthorization(allocator, .{
            .dev_mode = pluginDevMode(allocator),
        });
        errdefer runtime.deinit();
        try runtime.loadFromEnv();
        return runtime;
    }

    pub fn initFromEnvWithAuthorization(allocator: std.mem.Allocator, authorization: RuntimeAuthorizationInput) !Runtime {
        var runtime = try Runtime.initWithAuthorization(allocator, authorization);
        errdefer runtime.deinit();
        try runtime.loadFromEnv();
        return runtime;
    }

    pub fn initFromPathList(allocator: std.mem.Allocator, path_list: []const u8) !Runtime {
        var runtime = try Runtime.initWithAuthorization(allocator, .{
            .dev_mode = pluginDevMode(allocator),
        });
        errdefer runtime.deinit();
        try runtime.loadPathList(path_list);
        return runtime;
    }

    pub fn initFromPathListWithAuthorization(allocator: std.mem.Allocator, path_list: []const u8, authorization: RuntimeAuthorizationInput) !Runtime {
        var runtime = try Runtime.initWithAuthorization(allocator, authorization);
        errdefer runtime.deinit();
        try runtime.loadPathList(path_list);
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        for (self.plugins.items) |*plugin| plugin.deinit(self.allocator);
        self.plugins.deinit();
        for (self.manifest_help.items) |*entry| entry.deinit(self.allocator);
        self.manifest_help.deinit();
        for (self.diagnostics.items) |*diagnostic| diagnostic.deinit(self.allocator);
        self.diagnostics.deinit();
        self.host_authorization.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn loadFromEnv(self: *Runtime) !void {
        if (sio.getEnvVarOwned(self.allocator, "SA_PLUGINS_PATH")) |path_list| {
            defer self.allocator.free(path_list);
            try self.loadPathList(path_list);
            return;
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => {},
            else => return err,
        }

        const home = try pluginsHome(self.allocator);
        defer self.allocator.free(home);

        const installed = try std.fs.path.join(self.allocator, &.{ home, "installed" });
        defer self.allocator.free(installed);
        try self.loadInstalledRoot(installed);
    }

    pub fn loadPathList(self: *Runtime, path_list: []const u8) !void {
        const separator: u8 = if (@import("builtin").os.tag == .windows) ';' else ':';
        var it = std.mem.splitScalar(u8, path_list, separator);
        while (it.next()) |raw_entry| {
            const entry = std.mem.trim(u8, raw_entry, " \t\r\n");
            if (entry.len == 0) continue;
            try self.loadPath(entry);
        }
    }

    pub fn loadPath(self: *Runtime, path: []const u8) !void {
        var resolved_path: ?[]u8 = null;
        const load_path = if (std.fs.path.isAbsolute(path)) path else blk: {
            const absolute = sio.cwd().realpathAlloc(self.allocator, path) catch |err| {
                try self.addDiagnostic(path, @errorName(err));
                return;
            };
            resolved_path = absolute;
            break :blk absolute;
        };
        defer if (resolved_path) |absolute| self.allocator.free(absolute);

        if (isDynamicLibraryPath(load_path)) {
            try self.noteManifestHelpForLibrary(load_path);
            if (try self.runtimePolicyDenialForLibrary(load_path)) |reason| {
                defer self.allocator.free(reason);
                try self.addDiagnostic(load_path, reason);
                return;
            }
            try self.loadLibrary(load_path);
            return;
        }
        try self.loadDirectory(load_path);
    }

    pub fn appendSkills(self: *const Runtime, list: anytype) !void {
        for (self.plugins.items) |loaded| {
            if (!try self.shouldAdvertiseSkills(loaded)) continue;
            const skills = loaded.descriptor.skills_ptr[0..loaded.descriptor.skills_len];
            for (skills) |section| {
                try list.append(.{
                    .name = section.name,
                    .summary = section.summary,
                    .items = section.items,
                });
            }
        }
    }

    fn shouldAdvertiseSkills(self: *const Runtime, loaded: LoadedPlugin) !bool {
        const plugin_dir = std.fs.path.dirname(loaded.path) orelse return true;
        const sap_path = try std.fs.path.join(self.allocator, &.{ plugin_dir, "sap.json" });
        defer self.allocator.free(sap_path);
        if (!fileExistsAbsolute(sap_path)) return true;

        var manifest = parseSapManifest(self.allocator, sap_path) catch return true;
        defer manifest.deinit(self.allocator);
        for (manifest.dependencies) |dep| {
            const dependency = self.loadedPluginByName(dep.name) orelse {
                if (dep.optional) return false;
                return false;
            };
            if (dep.symbols.len != 0 and !(try dependency.exportsAll(self.allocator, dep.symbols))) {
                if (dep.optional) return false;
                return false;
            }
        }
        return true;
    }

    fn loadedPluginByName(self: *const Runtime, name: []const u8) ?*LoadedPlugin {
        const mutable_items: []LoadedPlugin = @constCast(self.plugins.items);
        for (mutable_items) |*loaded| {
            if (std.mem.eql(u8, std.mem.span(loaded.descriptor.name), name)) return loaded;
        }
        return null;
    }

    pub fn appendLibrariesExportingAny(
        self: *Runtime,
        list: *std.array_list.Managed([]const u8),
        symbol_names: []const []const u8,
    ) !void {
        if (symbol_names.len == 0) return;
        for (self.plugins.items) |*loaded| {
            if (try loaded.exportsAny(self.allocator, symbol_names)) {
                try list.append(loaded.path);
            }
        }
    }

    pub fn dispatchCommand(
        self: *Runtime,
        argv: []const []const u8,
        stdout: anytype,
        stderr: anytype,
        json_mode: bool,
    ) !?u8 {
        if (argv.len < 2) return null;

        if (try self.dispatchRecordedManifestHelpIfRequested(argv, stdout)) |code| return code;

        for (self.plugins.items) |*loaded| {
            if (try self.dispatchManifestHelpIfRequested(argv, loaded, stdout)) |code| return code;
        }

        var plugin_argv = std.array_list.Managed([]const u8).init(self.allocator);
        defer plugin_argv.deinit();
        try plugin_argv.appendSlice(argv);
        if (json_mode) try plugin_argv.append("--json");

        const c_argv = try dupeZArgs(self.allocator, plugin_argv.items);
        defer freeZArgs(self.allocator, c_argv);

        var stdout_value = stdout;
        var stderr_value = stderr;
        var stdout_ctx = StreamCtx(@TypeOf(stdout_value)){ .writer = &stdout_value };
        var stderr_ctx = StreamCtx(@TypeOf(stderr_value)){ .writer = &stderr_value };
        const stdout_stream = HostStream{ .ctx = &stdout_ctx, .write_all = streamWriteAll(@TypeOf(stdout_value)) };
        const stderr_stream = HostStream{ .ctx = &stderr_ctx, .write_all = streamWriteAll(@TypeOf(stderr_value)) };

        for (self.plugins.items) |*loaded| {
            var broker = RuntimeBroker{
                .allocator = self.allocator,
                .policy = &loaded.permission_policy,
                .authorization = &self.host_authorization,
            };
            var ctx = Context{
                .allocator = self.allocator,
                .json_mode = json_mode,
                .broker_abi_version = broker_abi_version,
                .broker_call = runtimeBrokerCall,
                .broker_ctx = &broker,
            };
            const handle = loaded.descriptor.handle_command orelse continue;
            var out_code: u8 = 0;
            const status_value = handle(&ctx, c_argv.ptr, c_argv.len, stdout_stream, stderr_stream, &out_code);
            const status = abiStatusFromInt(status_value);
            switch (status) {
                .ok => return out_code,
                .unknown_command => continue,
                .failed, .version_mismatch, .invalid_descriptor => {
                    try stderr.print("error[SA-PLUGIN]: plugin {s} failed with {s}\n", .{
                        std.mem.span(loaded.descriptor.name),
                        @tagName(status),
                    });
                    return 1;
                },
            }
        }
        return null;
    }

    fn dispatchRecordedManifestHelpIfRequested(
        self: *Runtime,
        argv: []const []const u8,
        stdout: anytype,
    ) !?u8 {
        if (argv.len < 3) return null;
        if (!pluginHelpTokenPresent(argv[2..])) return null;
        for (self.manifest_help.items) |entry| {
            if (!std.mem.eql(u8, entry.name, argv[1])) continue;
            try self.writeManifestHelpPath(entry.sap_path, stdout, entry.name, null);
            return 0;
        }
        return null;
    }

    fn dispatchManifestHelpIfRequested(
        self: *Runtime,
        argv: []const []const u8,
        loaded: *LoadedPlugin,
        stdout: anytype,
    ) !?u8 {
        if (argv.len < 3) return null;
        if (!pluginHelpTokenPresent(argv[2..])) return null;
        if (!try self.pluginCommandMatches(loaded, argv[1])) return null;
        try self.writePluginManifestHelp(loaded, stdout);
        return 0;
    }

    fn pluginCommandMatches(self: *Runtime, loaded: *LoadedPlugin, command: []const u8) !bool {
        if (std.mem.eql(u8, std.mem.span(loaded.descriptor.name), command)) return true;
        const sap_path = try self.pluginSapPath(loaded) orelse return false;
        defer self.allocator.free(sap_path);
        if (!fileExistsAbsolute(sap_path)) return false;

        const source = readFileAbsoluteAlloc(self.allocator, sap_path, 1 << 20) catch return false;
        defer self.allocator.free(source);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, source, .{}) catch return false;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |obj| obj,
            else => return false,
        };
        const manifest_name = jsonString(object.get("name") orelse return false) catch return false;
        return std.mem.eql(u8, manifest_name, command);
    }

    fn writePluginManifestHelp(self: *Runtime, loaded: *LoadedPlugin, stdout: anytype) !void {
        const sap_path = try self.pluginSapPath(loaded) orelse {
            try writePluginHelpFallback(loaded, stdout, null, null);
            return;
        };
        defer self.allocator.free(sap_path);
        if (!fileExistsAbsolute(sap_path)) {
            try writePluginHelpFallback(loaded, stdout, null, null);
            return;
        }

        const source = readFileAbsoluteAlloc(self.allocator, sap_path, 1 << 20) catch {
            try writePluginHelpFallback(loaded, stdout, null, null);
            return;
        };
        defer self.allocator.free(source);
        try self.writeManifestHelpSource(source, stdout, loaded, null);
    }

    fn writeManifestHelpPath(
        self: *Runtime,
        sap_path: []const u8,
        stdout: anytype,
        fallback_name: []const u8,
        loaded: ?*const LoadedPlugin,
    ) !void {
        const source = readFileAbsoluteAlloc(self.allocator, sap_path, 1 << 20) catch {
            if (loaded) |plugin| try writePluginHelpFallback(plugin, stdout, fallback_name, null) else try writeManifestHelpFallback(stdout, fallback_name, null);
            return;
        };
        defer self.allocator.free(source);
        try self.writeManifestHelpSource(source, stdout, loaded, fallback_name);
    }

    fn writeManifestHelpSource(
        self: *Runtime,
        source: []const u8,
        stdout: anytype,
        loaded: ?*const LoadedPlugin,
        fallback_name: ?[]const u8,
    ) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, source, .{}) catch {
            if (loaded) |plugin| try writePluginHelpFallback(plugin, stdout, fallback_name, null) else try writeManifestHelpFallback(stdout, fallback_name orelse "plugin", null);
            return;
        };
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |obj| obj,
            else => {
                if (loaded) |plugin| try writePluginHelpFallback(plugin, stdout, fallback_name, null) else try writeManifestHelpFallback(stdout, fallback_name orelse "plugin", null);
                return;
            },
        };

        const manifest_name = if (object.get("name")) |value| jsonString(value) catch null else fallback_name;
        const manifest_version = if (object.get("version")) |value| jsonString(value) catch null else null;

        if (object.get("help")) |help_value| {
            if (try writeManifestHelpValue(stdout, help_value)) return;
        }
        if (loaded) |plugin| {
            try writePluginHelpFallback(plugin, stdout, manifest_name, manifest_version);
        } else {
            try writeManifestHelpFallback(stdout, manifest_name orelse fallback_name orelse "plugin", manifest_version);
        }
    }

    fn pluginSapPath(self: *Runtime, loaded: *const LoadedPlugin) !?[]u8 {
        const plugin_dir = std.fs.path.dirname(loaded.path) orelse return null;
        return try std.fs.path.join(self.allocator, &.{ plugin_dir, "sap.json" });
    }

    fn loadInstalledRoot(self: *Runtime, root_path: []const u8) !void {
        var root = sio.openDirAbsolute(root_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        defer root.close();

        var it = root.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory and entry.kind != .sym_link) continue;
            const current = try std.fs.path.join(self.allocator, &.{ root_path, entry.name, "current" });
            defer self.allocator.free(current);
            try self.loadDirectory(current);
        }
    }

    fn loadDirectory(self: *Runtime, dir_path: []const u8) !void {
        try self.noteManifestHelpForDirectory(dir_path);

        if (try self.runtimePolicyDenialForDirectory(dir_path)) |reason| {
            defer self.allocator.free(reason);
            try self.addDiagnostic(dir_path, reason);
            return;
        }

        var dir = sio.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                try self.addDiagnostic(dir_path, @errorName(err));
                return;
            },
            else => return err,
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, entry.name, targetDynamicLibrarySuffix())) continue;
            const lib_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
            defer self.allocator.free(lib_path);
            try self.loadLibrary(lib_path);
        }
    }

    fn loadLibrary(self: *Runtime, path: []const u8) !void {
        if (try invalidDynamicLibraryHeader(self.allocator, path)) |reason| {
            try self.addDiagnostic(path, reason);
            return;
        }

        if (try self.runtimeArtifactHashMismatch(path)) |reason| {
            defer self.allocator.free(reason);
            try self.addDiagnostic(path, reason);
            return;
        }

        var lib = blk: {
            if (@import("builtin").os.tag == .windows) {
                // Plugin DLLs live outside the executable directory, so their
                // own dependencies (LLVM-C.dll, sibling plugin DLLs) must be
                // resolved relative to the DLL's install directory.
                const path_raw = std.fmt.allocPrint(self.allocator, "{s}", .{path}) catch |err| {
                    try self.addDiagnostic(path, @errorName(err));
                    return;
                };
                defer self.allocator.free(path_raw);
                const path_z = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, path_raw) catch |err| {
                    try self.addDiagnostic(path, @errorName(err));
                    return;
                };
                defer self.allocator.free(path_z);
                const handle = std.os.windows.LoadLibraryExW(path_z.ptr, .load_with_altered_search_path) catch |err| {
                    try self.addDiagnostic(path, @errorName(err));
                    return;
                };
                break :blk std.DynLib{ .inner = .{ .dll = handle } };
            }
            break :blk std.DynLib.open(path) catch |err| {
                try self.addDiagnostic(path, @errorName(err));
                return;
            };
        };
        var keep_lib = false;
        defer if (!keep_lib) lib.close();

        const descriptor = loadDescriptor(&lib) orelse {
            try self.addDiagnostic(path, "missing descriptor");
            return;
        };

        if (validateDescriptor(descriptor)) |reason| {
            try self.addDiagnostic(path, reason);
            return;
        }

        var permission_policy = try loadRuntimePermissionPolicy(self.allocator, path);
        errdefer permission_policy.deinit(self.allocator);

        if (descriptor.init) |init_fn| {
            var broker = RuntimeBroker{
                .allocator = self.allocator,
                .policy = &permission_policy,
                .authorization = &self.host_authorization,
            };
            var ctx = Context{
                .allocator = self.allocator,
                .broker_abi_version = broker_abi_version,
                .broker_call = runtimeBrokerCall,
                .broker_ctx = &broker,
            };
            const status = abiStatusFromInt(init_fn(&ctx));
            if (status != .ok) {
                try self.addDiagnostic(path, @tagName(status));
                return;
            }
        }

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.plugins.append(.{
            .path = owned_path,
            .lib = lib,
            .descriptor = descriptor,
            .permission_policy = permission_policy,
        });
        keep_lib = true;
    }

    fn runtimePolicyDenialForLibrary(self: *Runtime, lib_path: []const u8) !?[]u8 {
        const dir = std.fs.path.dirname(lib_path) orelse return null;
        return try self.runtimePolicyDenialForDirectory(dir);
    }

    fn runtimeArtifactHashMismatch(self: *Runtime, lib_path: []const u8) !?[]u8 {
        const dir_path = std.fs.path.dirname(lib_path) orelse return null;
        const sap_path = try std.fs.path.join(self.allocator, &.{ dir_path, "sap.json" });
        defer self.allocator.free(sap_path);
        if (!fileExistsAbsolute(sap_path)) return null;

        var manifest = parseSapManifest(self.allocator, sap_path) catch |err| {
            return try std.fmt.allocPrint(self.allocator, "plugin manifest could not be parsed before load: {s}", .{@errorName(err)});
        };
        defer manifest.deinit(self.allocator);

        const expected = manifest.artifact_sha256 orelse return null;
        if (!std.mem.eql(u8, std.fs.path.basename(lib_path), std.fs.path.basename(manifest.artifact_rel))) return null;

        const actual = sha256File(self.allocator, lib_path) catch |err| {
            return try std.fmt.allocPrint(self.allocator, "plugin artifact sha256 could not be computed before load: {s}", .{@errorName(err)});
        };
        if (std.mem.eql(u8, actual[0..], expected[0..])) return null;

        const actual_hex = std.fmt.bytesToHex(actual, .lower);
        const expected_hex = std.fmt.bytesToHex(expected, .lower);
        return try std.fmt.allocPrint(
            self.allocator,
            "plugin artifact sha256 mismatch before load: expected {s}, actual {s}",
            .{ expected_hex, actual_hex },
        );
    }

    fn runtimePolicyDenialForDirectory(self: *Runtime, dir_path: []const u8) !?[]u8 {
        if (pluginDevMode(self.allocator) or self.host_authorization.dev_mode) return null;

        const sap_path = try std.fs.path.join(self.allocator, &.{ dir_path, "sap.json" });
        defer self.allocator.free(sap_path);
        if (!fileExistsAbsolute(sap_path)) return null;

        var manifest = parseSapManifest(self.allocator, sap_path) catch |err| {
            return try std.fmt.allocPrint(self.allocator, "plugin manifest could not be parsed at runtime: {s}", .{@errorName(err)});
        };
        defer manifest.deinit(self.allocator);
        if (!manifest.requires_sandbox) return null;

        const lock_path = try std.fs.path.join(self.allocator, &.{ dir_path, "permissions.lock" });
        defer self.allocator.free(lock_path);
        const lock_text = readFileAbsoluteAlloc(self.allocator, lock_path, 1 << 20) catch |err| switch (err) {
            error.FileNotFound => {
                return try std.fmt.allocPrint(
                    self.allocator,
                    "privileged plugin {s} is blocked in formal runtime mode: permissions.lock missing and runtime sandbox is not enforced",
                    .{manifest.name},
                );
            },
            else => return err,
        };
        defer self.allocator.free(lock_text);

        if (lockHasKeyValue(lock_text, "dev_install", "true")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "privileged plugin {s} is blocked in formal runtime mode: plugin was installed in development mode; use SA_PLUGIN_DEV=1 only for trusted development",
                .{manifest.name},
            );
        }
        if (lockHasKeyValue(lock_text, "sandbox_enforced", "true")) return null;
        return try std.fmt.allocPrint(
            self.allocator,
            "privileged plugin {s} is blocked in formal runtime mode: runtime sandbox/broker enforcement is not active; use SA_PLUGIN_DEV=1 only for trusted development",
            .{manifest.name},
        );
    }

    fn addDiagnostic(self: *Runtime, path: []const u8, reason: []const u8) !void {
        try self.diagnostics.append(.{
            .path = try self.allocator.dupe(u8, path),
            .reason = try self.allocator.dupe(u8, reason),
        });
    }

    fn noteManifestHelpForLibrary(self: *Runtime, lib_path: []const u8) !void {
        const dir_path = std.fs.path.dirname(lib_path) orelse return;
        try self.noteManifestHelpForDirectory(dir_path);
    }

    fn noteManifestHelpForDirectory(self: *Runtime, dir_path: []const u8) !void {
        const sap_path = try std.fs.path.join(self.allocator, &.{ dir_path, "sap.json" });
        errdefer self.allocator.free(sap_path);
        if (!fileExistsAbsolute(sap_path)) {
            self.allocator.free(sap_path);
            return;
        }

        for (self.manifest_help.items) |entry| {
            if (std.mem.eql(u8, entry.sap_path, sap_path)) {
                self.allocator.free(sap_path);
                return;
            }
        }

        const source = readFileAbsoluteAlloc(self.allocator, sap_path, 1 << 20) catch {
            self.allocator.free(sap_path);
            return;
        };
        defer self.allocator.free(source);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, source, .{}) catch {
            self.allocator.free(sap_path);
            return;
        };
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |obj| obj,
            else => {
                self.allocator.free(sap_path);
                return;
            },
        };
        const name_text = jsonString(object.get("name") orelse {
            self.allocator.free(sap_path);
            return;
        }) catch {
            self.allocator.free(sap_path);
            return;
        };
        const name = try self.allocator.dupe(u8, name_text);
        errdefer self.allocator.free(name);
        try self.manifest_help.append(.{
            .name = name,
            .sap_path = sap_path,
        });
    }
};

fn invalidDynamicLibraryHeader(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    _ = allocator;
    if (@import("builtin").os.tag != .windows) return null;

    var file = sio.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return "FileNotFound",
        else => return err,
    };
    defer file.close();

    var magic: [2]u8 = undefined;
    file.readAll(&magic) catch |err| switch (err) {
        error.EndOfStream => return "invalid dynamic library header",
        else => return err,
    };
    if (!std.mem.eql(u8, magic[0..], "MZ")) return "invalid dynamic library header";
    return null;
}

pub const InstallOptions = struct {
    overwrite: bool = true,
    dev: bool = false,
    review: bool = false,
    optimize: []const u8 = "ReleaseFast",
};

const SapManifest = struct {
    root_dir: []u8,
    sap_path: []u8,
    name: []u8,
    version: []u8,
    abi_plugin: u32,
    artifact_rel: []u8,
    artifact_sha256: ?[32]u8,
    interface_files: []InterfaceFile,
    asset_files: []AssetFile,
    dependencies: []PluginDependency,
    env_permissions: [][]u8,
    fs_permissions: []FsPermission,
    net_permissions: []NetPermission,
    process_spawn: bool,
    process_exec_permissions: []ProcessExecPermission,
    permission_digest: [32]u8,
    external_urls: [][]u8,
    requires_sandbox: bool,
    has_fs_permission: bool,
    has_net_permission: bool,
    has_env_permission: bool,
    has_process_permission: bool,

    fn deinit(self: *SapManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.root_dir);
        allocator.free(self.sap_path);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.artifact_rel);
        for (self.interface_files) |*iface| iface.deinit(allocator);
        allocator.free(self.interface_files);
        for (self.asset_files) |*asset| asset.deinit(allocator);
        allocator.free(self.asset_files);
        for (self.dependencies) |*dep| dep.deinit(allocator);
        allocator.free(self.dependencies);
        for (self.env_permissions) |entry| allocator.free(entry);
        allocator.free(self.env_permissions);
        for (self.fs_permissions) |*entry| entry.deinit(allocator);
        allocator.free(self.fs_permissions);
        for (self.net_permissions) |*entry| entry.deinit(allocator);
        allocator.free(self.net_permissions);
        for (self.process_exec_permissions) |*entry| entry.deinit(allocator);
        allocator.free(self.process_exec_permissions);
        for (self.external_urls) |url| allocator.free(url);
        allocator.free(self.external_urls);
        self.* = undefined;
    }
};

const InterfaceKind = enum {
    sa,
    sai,
    sal,
    wasm_import,
};

const InterfaceFile = struct {
    kind: InterfaceKind,
    path: []u8,
    sha256: ?[32]u8,

    fn deinit(self: *InterfaceFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

const AssetKind = enum {
    share,
};

const AssetFile = struct {
    kind: AssetKind,
    path: []u8,
    target: []u8,
    sha256: ?[32]u8,

    fn deinit(self: *AssetFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.target);
        self.* = undefined;
    }
};

const PluginDependency = struct {
    name: []u8,
    version: []u8,
    abi: u32,
    optional: bool,
    symbols: [][]u8,
    path: ?[]u8,
    url: ?[]u8,

    fn deinit(self: *PluginDependency, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        for (self.symbols) |symbol| allocator.free(symbol);
        allocator.free(self.symbols);
        if (self.path) |path| allocator.free(path);
        if (self.url) |url| allocator.free(url);
        self.* = undefined;
    }
};

pub fn installFromPath(allocator: std.mem.Allocator, path: []const u8, stdout: anytype, options: InstallOptions) !u8 {
    return try installFromPathInternal(allocator, path, stdout, options, 0, &.{});
}

fn installFromPathInternal(allocator: std.mem.Allocator, path: []const u8, stdout: anytype, options: InstallOptions, depth: u8, ancestors: []const []const u8) anyerror!u8 {
    if (depth > 32) return error.PluginDependencyCycle;
    if (isDynamicLibraryPath(path)) {
        try stdout.writeAll("refusing to install a raw dynamic library; install a plugin project directory or sap.json instead\n");
        return 1;
    }
    if (std.mem.startsWith(u8, path, "github:") or std.mem.indexOf(u8, path, "://") != null) {
        const fetched_root = try fetchRemotePluginSource(allocator, path, stdout, options);
        defer allocator.free(fetched_root);
        return try installFromPathInternal(allocator, fetched_root, stdout, options, depth, ancestors);
    }

    var manifest = try parseSapManifest(allocator, path);
    defer manifest.deinit(allocator);
    for (ancestors) |ancestor| {
        if (std.mem.eql(u8, ancestor, manifest.sap_path)) {
            try stdout.print("plugin dependency cycle detected at {s}\n", .{manifest.sap_path});
            return 1;
        }
    }
    try warnBroadNetPermissions(stdout, manifest);
    const next_ancestors = try allocator.alloc([]const u8, ancestors.len + 1);
    defer allocator.free(next_ancestors);
    @memcpy(next_ancestors[0..ancestors.len], ancestors);
    next_ancestors[ancestors.len] = manifest.sap_path;

    if (options.review) {
        const review_text = try renderPermissionsLock(allocator, manifest, false, false);
        defer allocator.free(review_text);
        try stdout.writeAll(review_text);
        return 0;
    }

    if (try installPluginDependencies(allocator, manifest, stdout, options, depth, next_ancestors) != 0) return 1;

    if (!fileExistsInProject(allocator, manifest.root_dir, "build.zig") or
        !fileExistsInProject(allocator, manifest.root_dir, "src/plugin.zig"))
    {
        try stdout.writeAll("refusing to install plugin without text source project: required build.zig and src/plugin.zig\n");
        return 1;
    }

    const locked_permissions_confirmed = try permissionsLockMatches(allocator, manifest);
    var manual_permissions_confirmed = false;
    if (manifest.requires_sandbox and !locked_permissions_confirmed and !options.dev and !pluginDevMode(allocator)) {
        const confirmed = try confirmPrivilegedPluginInstall(stdout, manifest);
        if (!confirmed) return 1;
        manual_permissions_confirmed = true;
    }
    const permissions_confirmed = !manifest.requires_sandbox or locked_permissions_confirmed or manual_permissions_confirmed;

    if (try verifyInterfaceFiles(allocator, manifest) != 0) return 1;
    if (try verifyAssetFiles(allocator, manifest) != 0) return 1;
    if (try verifyInstalledExternSymbolConflicts(allocator, manifest, stdout) != 0) return 1;

    if (try buildPluginProject(allocator, manifest.root_dir, stdout, options.optimize) != 0) return 1;

    const artifact_abs = try std.fs.path.join(allocator, &.{ manifest.root_dir, manifest.artifact_rel });
    defer allocator.free(artifact_abs);
    if (!fileExistsAbsolute(artifact_abs)) {
        try stdout.print("plugin build did not produce declared artifact: {s}\n", .{artifact_abs});
        return 1;
    }

    const home = try pluginsHome(allocator);
    defer allocator.free(home);
    const installed_dir = try std.fs.path.join(allocator, &.{ home, "installed", manifest.name, "current" });
    defer allocator.free(installed_dir);
    const version_dir = try std.fs.path.join(allocator, &.{ home, "installed", manifest.name, manifest.version });
    defer allocator.free(version_dir);

    if (options.overwrite and dirExistsAbsolute(installed_dir)) try sio.cwd().deleteTree(installed_dir);
    if (options.overwrite and dirExistsAbsolute(version_dir)) try sio.cwd().deleteTree(version_dir);
    try sio.cwd().makePath(installed_dir);
    try sio.cwd().makePath(version_dir);

    const artifact_name = std.fs.path.basename(manifest.artifact_rel);
    const installed_artifact = try std.fs.path.join(allocator, &.{ installed_dir, artifact_name });
    defer allocator.free(installed_artifact);
    try copyFileAbsolute(artifact_abs, installed_artifact);
    const version_artifact = try std.fs.path.join(allocator, &.{ version_dir, artifact_name });
    defer allocator.free(version_artifact);
    try copyFileAbsolute(artifact_abs, version_artifact);

    const installed_sap = try std.fs.path.join(allocator, &.{ installed_dir, "sap.json" });
    defer allocator.free(installed_sap);
    try copyFileAbsolute(manifest.sap_path, installed_sap);
    const version_sap = try std.fs.path.join(allocator, &.{ version_dir, "sap.json" });
    defer allocator.free(version_sap);
    try copyFileAbsolute(manifest.sap_path, version_sap);

    if (try verifySymbolSmoke(allocator, manifest, artifact_abs, stdout) != 0) return 1;
    if (try verifyArtifactStaticPolicy(allocator, manifest, artifact_abs, stdout, options) != 0) return 1;

    if (manifest.interface_files.len > 0) {
        const sa_dir = try std.fs.path.join(allocator, &.{ installed_dir, "sa" });
        defer allocator.free(sa_dir);
        try sio.cwd().makePath(sa_dir);
        const version_sa_dir = try std.fs.path.join(allocator, &.{ version_dir, "sa" });
        defer allocator.free(version_sa_dir);
        try sio.cwd().makePath(version_sa_dir);
        for (manifest.interface_files) |iface| {
            const rel = iface.path;
            const src = try std.fs.path.join(allocator, &.{ manifest.root_dir, rel });
            defer allocator.free(src);
            if (!fileExistsAbsolute(src)) return error.PluginInterfaceMissing;
            const dst = try std.fs.path.join(allocator, &.{ sa_dir, std.fs.path.basename(rel) });
            defer allocator.free(dst);
            try copyFileAbsolute(src, dst);
            const version_dst = try std.fs.path.join(allocator, &.{ version_sa_dir, std.fs.path.basename(rel) });
            defer allocator.free(version_dst);
            try copyFileAbsolute(src, version_dst);
        }
    }
    try copyAssetFiles(allocator, manifest, installed_dir, version_dir);

    var artifact_file = try sio.openFileAbsolute(artifact_abs, .{});
    defer artifact_file.close();
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try artifact_file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const permission_digest_hex = std.fmt.bytesToHex(manifest.permission_digest, .lower);
    const dependency_graph_digest = dependencyGraphDigest(manifest);
    const dependency_graph_digest_hex = std.fmt.bytesToHex(dependency_graph_digest, .lower);

    const lock_path = try std.fs.path.join(allocator, &.{ installed_dir, "sap.lock" });
    defer allocator.free(lock_path);
    const lock_text = try std.fmt.allocPrint(allocator,
        \\name={s}
        \\version={s}
        \\artifact={s}
        \\sha256={s}
        \\permissions_sha256={s}
        \\dependency_graph_sha256={s}
        \\dependencies={d}
        \\
    , .{ manifest.name, manifest.version, artifact_name, digest_hex, permission_digest_hex, dependency_graph_digest_hex, manifest.dependencies.len });
    defer allocator.free(lock_text);
    try writeFileAbsolute(lock_path, lock_text);
    const version_lock_path = try std.fs.path.join(allocator, &.{ version_dir, "sap.lock" });
    defer allocator.free(version_lock_path);
    try writeFileAbsolute(version_lock_path, lock_text);

    const dev_install = options.dev or pluginDevMode(allocator);
    const permissions_lock_text = try renderPermissionsLock(allocator, manifest, permissions_confirmed, dev_install);
    defer allocator.free(permissions_lock_text);
    const permissions_lock_path = try std.fs.path.join(allocator, &.{ installed_dir, "permissions.lock" });
    defer allocator.free(permissions_lock_path);
    try writeFileAbsolute(permissions_lock_path, permissions_lock_text);
    const version_permissions_lock_path = try std.fs.path.join(allocator, &.{ version_dir, "permissions.lock" });
    defer allocator.free(version_permissions_lock_path);
    try writeFileAbsolute(version_permissions_lock_path, permissions_lock_text);

    try stdout.print("{s}\n", .{installed_dir});
    return 0;
}

fn installPluginDependencies(allocator: std.mem.Allocator, manifest: SapManifest, stdout: anytype, options: InstallOptions, depth: u8, ancestors: []const []const u8) anyerror!u8 {
    for (manifest.dependencies) |dep| {
        const dep_path = dep.path orelse {
            if (dep.optional) continue;
            if (dep.url) |url| {
                const remote_spec = try remoteSpecForDependency(allocator, url, dep.version);
                defer allocator.free(remote_spec);
                const fetched_root = try fetchRemotePluginSource(allocator, remote_spec, stdout, options);
                defer allocator.free(fetched_root);
                var dep_manifest = try parseSapManifest(allocator, fetched_root);
                defer dep_manifest.deinit(allocator);
                if (!std.mem.eql(u8, dep_manifest.name, dep.name)) {
                    try stdout.print("plugin dependency name mismatch: expected {s}, found {s}\n", .{ dep.name, dep_manifest.name });
                    return 1;
                }
                if (dep_manifest.abi_plugin != dep.abi) {
                    try stdout.print("plugin dependency {s} ABI mismatch: expected {d}, found {d}\n", .{ dep.name, dep.abi, dep_manifest.abi_plugin });
                    return 1;
                }
                const code = try installFromPathInternal(allocator, fetched_root, stdout, options, depth + 1, ancestors);
                if (code != 0) return code;
                continue;
            } else {
                try stdout.print("required plugin dependency {s} has no local path; remote dependency resolver is not implemented yet\n", .{dep.name});
            }
            return 1;
        };
        const resolved_path = if (std.fs.path.isAbsolute(dep_path))
            try allocator.dupe(u8, dep_path)
        else
            try std.fs.path.join(allocator, &.{ manifest.root_dir, dep_path });
        defer allocator.free(resolved_path);

        var dep_manifest = try parseSapManifest(allocator, resolved_path);
        defer dep_manifest.deinit(allocator);
        if (!std.mem.eql(u8, dep_manifest.name, dep.name)) {
            try stdout.print("plugin dependency name mismatch: expected {s}, found {s}\n", .{ dep.name, dep_manifest.name });
            return 1;
        }
        if (dep_manifest.abi_plugin != dep.abi) {
            try stdout.print("plugin dependency {s} ABI mismatch: expected {d}, found {d}\n", .{ dep.name, dep.abi, dep_manifest.abi_plugin });
            return 1;
        }

        const code = try installFromPathInternal(allocator, resolved_path, stdout, options, depth + 1, ancestors);
        if (code != 0) return code;
    }
    return 0;
}

pub fn listInstalled(allocator: std.mem.Allocator, stdout: anytype) !u8 {
    const home = try pluginsHome(allocator);
    defer allocator.free(home);
    const root_path = try std.fs.path.join(allocator, &.{ home, "installed" });
    defer allocator.free(root_path);
    var root = sio.openDirAbsolute(root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            try stdout.writeAll("plugin\tinstalled_path\n");
            return 0;
        },
        else => return err,
    };
    defer root.close();

    try stdout.writeAll("plugin\tinstalled_path\n");
    var it = root.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        const current = try std.fs.path.join(allocator, &.{ root_path, entry.name, "current" });
        defer allocator.free(current);
        if (dirExistsAbsolute(current)) {
            try stdout.print("{s}\t{s}\n", .{ entry.name, current });
        }
    }
    return 0;
}

fn renderPermissionsLock(allocator: std.mem.Allocator, manifest: SapManifest, confirmed: bool, dev_install: bool) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    const digest_hex = std.fmt.bytesToHex(manifest.permission_digest, .lower);
    const graph_digest = dependencyGraphDigest(manifest);
    const graph_digest_hex = std.fmt.bytesToHex(graph_digest, .lower);
    try w.print(
        \\schema=sa.permissions/1
        \\plugin={s}
        \\version={s}
        \\permissions_sha256={s}
        \\dependency_graph_sha256={s}
        \\requires_confirmation={s}
        \\confirmed={s}
        \\dev_install={s}
        \\artifact_scan=dynamic-imports
        \\sandbox_enforced=false
        \\
    , .{
        manifest.name,
        manifest.version,
        digest_hex,
        graph_digest_hex,
        if (manifest.requires_sandbox) "true" else "false",
        if (confirmed) "true" else "false",
        if (dev_install) "true" else "false",
    });
    if (manifest.external_urls.len != 0) {
        try w.writeAll("external_urls\n");
        for (manifest.external_urls) |url| try w.print("- {s}\n", .{url});
    }
    if (manifest.dependencies.len != 0) {
        try w.writeAll("plugin_dependencies\n");
        for (manifest.dependencies) |dep| {
            try w.print("- {s} version={s} abi={d} optional={s}", .{
                dep.name,
                dep.version,
                dep.abi,
                if (dep.optional) "true" else "false",
            });
            if (dep.symbols.len != 0) {
                try w.writeAll(" symbols=");
                for (dep.symbols, 0..) |symbol, idx| {
                    if (idx != 0) try w.writeByte(',');
                    try w.writeAll(symbol);
                }
            }
            if (dep.path) |path| try w.print(" path={s}", .{path});
            if (dep.url) |url| try w.print(" url={s}", .{url});
            try w.writeByte('\n');
        }
    }
    return try aw.toOwnedSlice();
}

fn dependencyGraphDigest(manifest: SapManifest) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (manifest.dependencies) |dep| {
        hasher.update(dep.name);
        hasher.update("\x00");
        hasher.update(dep.version);
        hasher.update("\x00");
        var abi_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &abi_buf, dep.abi, .little);
        hasher.update(&abi_buf);
        hasher.update(if (dep.optional) "optional" else "required");
        hasher.update("\x00");
        for (dep.symbols) |symbol| {
            hasher.update(symbol);
            hasher.update("\x00");
        }
        if (dep.path) |path| hasher.update(path);
        hasher.update("\x00");
        if (dep.url) |url| hasher.update(url);
        hasher.update("\x00");
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn permissionsLockMatches(allocator: std.mem.Allocator, manifest: SapManifest) !bool {
    const home = try pluginsHome(allocator);
    defer allocator.free(home);
    const lock_path = try std.fs.path.join(allocator, &.{ home, "installed", manifest.name, "current", "permissions.lock" });
    defer allocator.free(lock_path);
    const lock_text = readFileAbsoluteAlloc(allocator, lock_path, 1 << 20) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(lock_text);

    const permission_digest_hex = std.fmt.bytesToHex(manifest.permission_digest, .lower);
    const graph_digest = dependencyGraphDigest(manifest);
    const graph_digest_hex = std.fmt.bytesToHex(graph_digest, .lower);
    return lockHasLine(lock_text, "confirmed=true") and
        lockHasKeyValue(lock_text, "permissions_sha256", permission_digest_hex[0..]) and
        lockHasKeyValue(lock_text, "dependency_graph_sha256", graph_digest_hex[0..]);
}

fn lockHasKeyValue(text: []const u8, key: []const u8, value: []const u8) bool {
    var line_buf: [256]u8 = undefined;
    const expected = std.fmt.bufPrint(&line_buf, "{s}={s}", .{ key, value }) catch return false;
    return lockHasLine(text, expected);
}

fn lockHasLine(text: []const u8, expected: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), expected)) return true;
    }
    return false;
}

const RemotePluginSpec = struct {
    kind: RemotePluginKind,
    url: []u8,
    ref: ?[]u8,
    archive_sha256: ?[32]u8 = null,
    archive_format: ?ArchiveFormat = null,

    fn deinit(self: *RemotePluginSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.ref) |ref| allocator.free(ref);
        self.* = undefined;
    }
};

const RemotePluginKind = enum {
    git,
    archive,
};

const ArchiveFormat = enum {
    tar_gz,
    tgz,
    tar_xz,
    tar_zst,
};

fn fetchRemotePluginSource(allocator: std.mem.Allocator, spec_text: []const u8, stdout: anytype, options: InstallOptions) ![]u8 {
    var spec = try parseRemotePluginSpec(allocator, spec_text);
    defer spec.deinit(allocator);

    if (!options.dev and !pluginDevMode(allocator)) switch (spec.kind) {
        .git => if (spec.ref == null) {
            try stdout.print("refusing remote plugin install without fixed #ref: {s}\n", .{spec.url});
            return error.RemotePluginRefRequired;
        },
        .archive => if (spec.archive_sha256 == null) {
            try stdout.print("refusing remote plugin archive install without #sha256:<digest>: {s}\n", .{spec.url});
            return error.RemotePluginRefRequired;
        },
    };
    if (!options.dev and !pluginDevMode(allocator)) {
        const confirmed = try confirmExternalUrl(stdout, spec.url);
        if (!confirmed) return error.RemotePluginUrlNotConfirmed;
    }

    return switch (spec.kind) {
        .git => try fetchRemoteGitPluginSource(allocator, spec, stdout),
        .archive => try fetchRemoteArchivePluginSource(allocator, spec, stdout),
    };
}

fn fetchRemoteGitPluginSource(allocator: std.mem.Allocator, spec: RemotePluginSpec, stdout: anytype) ![]u8 {
    std.debug.assert(spec.kind == .git);

    const home = try pluginsHome(allocator);
    defer allocator.free(home);
    const cache_root = try std.fs.path.join(allocator, &.{ home, "cache", "git" });
    defer allocator.free(cache_root);
    try sio.cwd().makePath(cache_root);

    const cache_key = remoteCacheKeyForSpec(spec);
    const cache_key_hex = std.fmt.bytesToHex(cache_key, .lower);
    const checkout_dir = try std.fs.path.join(allocator, &.{ cache_root, cache_key_hex[0..] });
    errdefer allocator.free(checkout_dir);
    if (dirExistsAbsolute(checkout_dir)) try sio.cwd().deleteTree(checkout_dir);

    const clone_result = try sio.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "clone", "--quiet", spec.url, checkout_dir },
    });
    defer allocator.free(clone_result.stdout);
    defer allocator.free(clone_result.stderr);
    if (!childExitedZero(clone_result.term)) {
        try stdout.print("git clone failed for plugin source {s}\n{s}", .{ spec.url, clone_result.stderr });
        return error.RemotePluginFetchFailed;
    }

    if (spec.ref) |ref| {
        const checkout_result = try sio.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "-C", checkout_dir, "checkout", "--quiet", ref },
        });
        defer allocator.free(checkout_result.stdout);
        defer allocator.free(checkout_result.stderr);
        if (!childExitedZero(checkout_result.term)) {
            try stdout.print("git checkout failed for plugin source {s} ref {s}\n{s}", .{ spec.url, ref, checkout_result.stderr });
            return error.RemotePluginFetchFailed;
        }
    }

    return checkout_dir;
}

fn parseRemotePluginSpec(allocator: std.mem.Allocator, spec_text: []const u8) !RemotePluginSpec {
    const split = splitRemoteRef(spec_text);
    const url_text = split.url;
    const ref_text = split.ref;
    const url = if (std.mem.startsWith(u8, url_text, "github:")) blk: {
        const repo = url_text["github:".len..];
        if (repo.len == 0 or std.mem.indexOf(u8, repo, "..") != null) return error.InvalidRemotePluginSource;
        break :blk try std.fmt.allocPrint(allocator, "https://github.com/{s}.git", .{repo});
    } else blk: {
        if (!allowedExternalUrl(url_text)) return error.InvalidRemotePluginSource;
        break :blk try allocator.dupe(u8, url_text);
    };
    errdefer allocator.free(url);
    const ref = if (ref_text) |text| try allocator.dupe(u8, text) else null;
    const archive_format = archiveFormatFromUrl(url_text);
    if (archive_format) |format| {
        const archive_sha256 = if (ref_text) |text| try parseArchiveSha256(text) else null;
        return .{
            .kind = .archive,
            .url = url,
            .ref = ref,
            .archive_sha256 = archive_sha256,
            .archive_format = format,
        };
    }
    return .{
        .kind = .git,
        .url = url,
        .ref = ref,
    };
}

fn splitRemoteRef(text: []const u8) struct { url: []const u8, ref: ?[]const u8 } {
    if (std.mem.lastIndexOfScalar(u8, text, '#')) |idx| {
        const ref = text[idx + 1 ..];
        return .{ .url = text[0..idx], .ref = if (ref.len == 0) null else ref };
    }
    return .{ .url = text, .ref = null };
}

fn remoteSpecForDependency(allocator: std.mem.Allocator, url: []const u8, version: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, url, '#') != null or std.mem.eql(u8, version, "*") or archiveFormatFromUrl(url) != null) {
        return try allocator.dupe(u8, url);
    }
    return try std.fmt.allocPrint(allocator, "{s}#{s}", .{ url, version });
}

fn remoteCacheKey(text: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(text);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn remoteCacheKeyForSpec(spec: RemotePluginSpec) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(spec.url);
    hasher.update("\x00");
    if (spec.ref) |ref| hasher.update(ref);
    hasher.update("\x00");
    if (spec.archive_sha256) |digest| hasher.update(&digest);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn childExitedZero(term: sio.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn fetchRemoteArchivePluginSource(allocator: std.mem.Allocator, spec: RemotePluginSpec, stdout: anytype) ![]u8 {
    std.debug.assert(spec.kind == .archive);
    const format = spec.archive_format orelse return error.InvalidRemotePluginSource;

    const home = try pluginsHome(allocator);
    defer allocator.free(home);
    const cache_root = try std.fs.path.join(allocator, &.{ home, "cache", "archive" });
    defer allocator.free(cache_root);
    try sio.cwd().makePath(cache_root);

    const cache_key = remoteCacheKeyForSpec(spec);
    const cache_key_hex = std.fmt.bytesToHex(cache_key, .lower);
    const bundle_dir = try std.fs.path.join(allocator, &.{ cache_root, cache_key_hex[0..] });
    defer allocator.free(bundle_dir);
    if (dirExistsAbsolute(bundle_dir)) try sio.cwd().deleteTree(bundle_dir);
    try sio.cwd().makePath(bundle_dir);

    const archive_path = try std.fs.path.join(allocator, &.{ bundle_dir, archiveFilename(format) });
    defer allocator.free(archive_path);
    try downloadRemoteFile(allocator, spec.url, archive_path, stdout);

    if (spec.archive_sha256) |expected| {
        const actual = try sha256File(allocator, archive_path);
        if (!std.mem.eql(u8, actual[0..], expected[0..])) {
            try stdout.print("remote plugin archive sha256 mismatch for {s}\n", .{spec.url});
            return error.RemotePluginArchiveShaMismatch;
        }
    }

    const extract_dir = try std.fs.path.join(allocator, &.{ bundle_dir, "extract" });
    defer allocator.free(extract_dir);
    try sio.cwd().makePath(extract_dir);
    try extractArchiveToDirectory(allocator, archive_path, extract_dir, format, stdout);
    return try findExtractedPluginRoot(allocator, extract_dir);
}

fn downloadRemoteFile(allocator: std.mem.Allocator, url: []const u8, dst_path: []const u8, stdout: anytype) !void {
    const curl_result = sio.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-L", "--fail", "--silent", "--show-error", "--noproxy", "127.0.0.1,localhost,::1", "-o", dst_path, url },
    }) catch |err| switch (err) {
        error.FileNotFound => {
            const wget_result = try sio.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "wget", "-q", "-O", dst_path, url },
            });
            defer allocator.free(wget_result.stdout);
            defer allocator.free(wget_result.stderr);
            if (!childExitedZero(wget_result.term)) {
                try stdout.print("remote archive download failed for {s}\n{s}", .{ url, wget_result.stderr });
                return error.RemotePluginFetchFailed;
            }
            return;
        },
        else => return err,
    };
    defer allocator.free(curl_result.stdout);
    defer allocator.free(curl_result.stderr);
    if (!childExitedZero(curl_result.term)) {
        try stdout.print("remote archive download failed for {s}\n{s}", .{ url, curl_result.stderr });
        return error.RemotePluginFetchFailed;
    }
}

fn extractArchiveToDirectory(
    allocator: std.mem.Allocator,
    archive_path: []const u8,
    extract_dir: []const u8,
    format: ArchiveFormat,
    stdout: anytype,
) !void {
    const argv: []const []const u8 = switch (format) {
        // --no-same-owner: never restore uid/gid from the archive. GNU tar
        // defaults to --same-owner when run as root, which fails in
        // containers without chown permission (and would be a security
        // hole for remote archives anyway).
        .tar_gz, .tgz => &.{ "tar", "--no-same-owner", "-xzf", archive_path, "-C", extract_dir },
        .tar_xz => &.{ "tar", "--no-same-owner", "-xJf", archive_path, "-C", extract_dir },
        .tar_zst => &.{ "tar", "--no-same-owner", "--zstd", "-xf", archive_path, "-C", extract_dir },
    };
    const result = try sio.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!childExitedZero(result.term)) {
        try stdout.print("remote plugin archive extraction failed for {s}\n{s}", .{ archive_path, result.stderr });
        return error.RemotePluginFetchFailed;
    }
}

fn findExtractedPluginRoot(allocator: std.mem.Allocator, extract_dir: []const u8) ![]u8 {
    if (fileExistsInProject(allocator, extract_dir, "sap.json")) return try allocator.dupe(u8, extract_dir);
    return try findUniqueSapRoot(allocator, extract_dir, 0);
}

fn findUniqueSapRoot(allocator: std.mem.Allocator, root: []const u8, depth: u8) anyerror![]u8 {
    if (depth > 4) return error.NoPluginManifestInArchive;
    var dir = try sio.openDirAbsolute(root, .{ .iterate = true });
    defer dir.close();

    var found: ?[]u8 = null;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        const child = try std.fs.path.join(allocator, &.{ root, entry.name });
        defer allocator.free(child);
        if (fileExistsInProject(allocator, child, "sap.json")) {
            if (found != null) return error.InvalidRemotePluginSource;
            found = try allocator.dupe(u8, child);
            continue;
        }
        const nested = findUniqueSapRoot(allocator, child, depth + 1) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.NoPluginManifestInArchive => null,
            else => return err,
        };
        if (nested) |path| {
            if (found != null) {
                allocator.free(path);
                return error.InvalidRemotePluginSource;
            }
            found = path;
        }
    }
    return found orelse error.NoPluginManifestInArchive;
}

fn archiveFormatFromUrl(url: []const u8) ?ArchiveFormat {
    const path = urlPathForRemote(url);
    if (std.mem.endsWith(u8, path, ".tar.gz")) return .tar_gz;
    if (std.mem.endsWith(u8, path, ".tgz")) return .tgz;
    if (std.mem.endsWith(u8, path, ".tar.xz")) return .tar_xz;
    if (std.mem.endsWith(u8, path, ".tar.zst")) return .tar_zst;
    return null;
}

fn urlPathForRemote(url: []const u8) []const u8 {
    const query_idx = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    return url[0..query_idx];
}

fn parseArchiveSha256(text: []const u8) ![32]u8 {
    if (!std.mem.startsWith(u8, text, "sha256:")) return error.InvalidRemotePluginSource;
    return try parseSha256Text(text["sha256:".len..]);
}

fn parseSha256Text(body: []const u8) ![32]u8 {
    if (body.len != 64) return error.InvalidRemotePluginSource;
    var bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(bytes[0..], body) catch return error.InvalidRemotePluginSource;
    return bytes;
}

fn archiveFilename(format: ArchiveFormat) []const u8 {
    return switch (format) {
        .tar_gz => "plugin.tar.gz",
        .tgz => "plugin.tgz",
        .tar_xz => "plugin.tar.xz",
        .tar_zst => "plugin.tar.zst",
    };
}

fn stdinIsTty() bool {
    _ = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return false;
    return true;
}

const StdinLineReader = struct {
    inner: *std.Io.Reader,

    pub fn readUntilDelimiterOrEof(self: StdinLineReader, buf: []u8, delimiter: u8) !?[]u8 {
        var i: usize = 0;
        var eof = false;
        while (true) {
            const b = self.inner.takeByte() catch |err| switch (err) {
                error.EndOfStream => {
                    eof = true;
                    break;
                },
                else => return err,
            };
            if (b == delimiter) break;
            if (i >= buf.len) return error.StreamTooLong;
            buf[i] = b;
            i += 1;
        }
        if (i == 0 and eof) return null;
        return buf[0..i];
    }
};

fn confirmExternalUrl(stdout: anytype, url: []const u8) !bool {
    if (!stdinIsTty()) {
        try stdout.print("refusing remote plugin URL {s}: manual TTY confirmation is required\n", .{url});
        return false;
    }
    try stdout.print(
        \\SA PLUGIN REMOTE SOURCE REVIEW REQUIRED
        \\url: {s}
        \\Type the exact URL to fetch this plugin source: 
    , .{url});
    var buffer: [1024]u8 = undefined;
    var stdin_buf: [8192]u8 = undefined;
    var stdin_stream = sio.getStdIn().reader(&stdin_buf);
    var stdin_reader = StdinLineReader{ .inner = &stdin_stream.interface };
    const line = (try stdin_reader.readUntilDelimiterOrEof(&buffer, '\n')) orelse "";
    const answer = std.mem.trim(u8, line, " \t\r\n");
    if (!std.mem.eql(u8, answer, url)) {
        try stdout.writeAll("remote plugin install cancelled\n");
        return false;
    }
    return true;
}

pub fn defaultPluginsHome(allocator: std.mem.Allocator) ![]u8 {
    if (@import("builtin").os.tag == .windows) {
        const local_app_data = sio.getEnvVarOwned(allocator, "LOCALAPPDATA") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (local_app_data) |root| {
            defer allocator.free(root);
            if (std.fs.path.isAbsolute(root)) return try std.fs.path.join(allocator, &.{ root, "sa_plugins" });
        }

        const user_profile = sio.getEnvVarOwned(allocator, "USERPROFILE") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (user_profile) |root| {
            defer allocator.free(root);
            if (std.fs.path.isAbsolute(root)) return try std.fs.path.join(allocator, &.{ root, ".local", "share", "sa_plugins" });
        }

        const cwd = try sio.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(cwd);
        return try std.fs.path.join(allocator, &.{ cwd, ".sa_plugins" });
    }

    const home = sio.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            const cwd = try sio.cwd().realpathAlloc(allocator, ".");
            defer allocator.free(cwd);
            return try std.fs.path.join(allocator, &.{ cwd, ".sa_plugins" });
        },
        else => return err,
    };
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".local", "share", "sa_plugins" });
}

pub fn pluginsHomePath(allocator: std.mem.Allocator) ![]u8 {
    return try pluginsHome(allocator);
}

fn pluginsHome(allocator: std.mem.Allocator) ![]u8 {
    const configured = sio.getEnvVarOwned(allocator, "SA_PLUGINS_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return try defaultPluginsHome(allocator),
        else => return err,
    };
    defer allocator.free(configured);
    if (std.fs.path.isAbsolute(configured)) return try allocator.dupe(u8, configured);
    const cwd = try sio.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, configured });
}

fn parseSapManifest(allocator: std.mem.Allocator, input_path: []const u8) !SapManifest {
    const sap_path = if (std.mem.endsWith(u8, input_path, "sap.json"))
        try absolutePath(allocator, input_path)
    else blk: {
        const root = try absolutePath(allocator, input_path);
        defer allocator.free(root);
        break :blk try std.fs.path.join(allocator, &.{ root, "sap.json" });
    };
    errdefer allocator.free(sap_path);

    const root_dir = try allocator.dupe(u8, std.fs.path.dirname(sap_path) orelse ".");
    errdefer allocator.free(root_dir);

    const source = try readFileAbsoluteAlloc(allocator, sap_path, 1 << 20);
    defer allocator.free(source);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidSapManifest,
    };

    const schema = try jsonString(object.get("schema") orelse return error.InvalidSapManifest);
    if (!std.mem.eql(u8, schema, "sa.plugin/1")) return error.UnsupportedSapSchema;
    _ = object.get("permissions") orelse return error.PluginPermissionsMissing;
    var permission_info = try validatePermissions(allocator, object.get("permissions").?);
    defer permission_info.deinit(allocator);
    try collectManifestExternalUrls(allocator, object, &permission_info.urls);

    const name = try allocator.dupe(u8, try jsonString(object.get("name") orelse return error.InvalidSapManifest));
    errdefer allocator.free(name);
    const version = try allocator.dupe(u8, try jsonString(object.get("version") orelse return error.InvalidSapManifest));
    errdefer allocator.free(version);
    const abi_plugin = try parseAbiPlugin(object.get("abi"));
    const artifact = try selectArtifact(object.get("artifacts") orelse return error.InvalidSapManifest);
    const artifact_rel = try allocator.dupe(u8, artifact.path);
    errdefer allocator.free(artifact_rel);
    try validateProjectRelativePath(artifact_rel);
    const interface_files = try collectInterfaceFiles(allocator, object.get("interfaces"));
    errdefer {
        for (interface_files) |*iface| iface.deinit(allocator);
        allocator.free(interface_files);
    }
    const asset_files = try collectAssetFiles(allocator, object.get("assets"));
    errdefer {
        for (asset_files) |*asset| asset.deinit(allocator);
        allocator.free(asset_files);
    }
    const dependencies = try collectPluginDependencies(allocator, object.get("dependencies"));
    errdefer {
        for (dependencies) |*dep| dep.deinit(allocator);
        allocator.free(dependencies);
    }

    return .{
        .root_dir = root_dir,
        .sap_path = sap_path,
        .name = name,
        .version = version,
        .abi_plugin = abi_plugin,
        .artifact_rel = artifact_rel,
        .artifact_sha256 = artifact.sha256,
        .interface_files = interface_files,
        .asset_files = asset_files,
        .dependencies = dependencies,
        .env_permissions = try permission_info.env_permissions.toOwnedSlice(),
        .fs_permissions = try permission_info.fs_permissions.toOwnedSlice(),
        .net_permissions = try permission_info.net_permissions.toOwnedSlice(),
        .process_spawn = permission_info.process_spawn,
        .process_exec_permissions = try permission_info.process_exec_permissions.toOwnedSlice(),
        .permission_digest = permission_info.digest,
        .external_urls = try permission_info.urls.toOwnedSlice(),
        .requires_sandbox = permission_info.requires_sandbox,
        .has_fs_permission = permission_info.has_fs_permission,
        .has_net_permission = permission_info.has_net_permission,
        .has_env_permission = permission_info.has_env_permission,
        .has_process_permission = permission_info.has_process_permission,
    };
}

fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);
    return try sio.cwd().realpathAlloc(allocator, path);
}

fn jsonString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.InvalidSapManifest,
    };
}

fn pluginHelpTokenPresent(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or
            std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "help")) return true;
    }
    return false;
}

fn writeManifestHelpValue(writer: anytype, value: std.json.Value) !bool {
    switch (value) {
        .string => |text| {
            try writer.writeAll(text);
            if (text.len == 0 or text[text.len - 1] != '\n') try writer.writeByte('\n');
            return true;
        },
        .object => |object| {
            if (object.get("text")) |text_value| {
                const text = jsonString(text_value) catch return false;
                try writer.writeAll(text);
                if (text.len == 0 or text[text.len - 1] != '\n') try writer.writeByte('\n');
                return true;
            }

            var wrote_any = false;
            if (object.get("usage")) |usage_value| {
                const usage = jsonString(usage_value) catch return false;
                try writer.print("usage: {s}\n", .{usage});
                wrote_any = true;
            }
            if (object.get("summary")) |summary_value| {
                const summary = jsonString(summary_value) catch return false;
                if (wrote_any) try writer.writeByte('\n');
                try writer.print("{s}\n", .{summary});
                wrote_any = true;
            }
            if (object.get("commands")) |commands_value| {
                const commands = switch (commands_value) {
                    .array => |arr| arr,
                    else => return false,
                };
                if (wrote_any) try writer.writeByte('\n');
                try writer.writeAll("Commands:\n");
                for (commands.items) |item| {
                    const command = switch (item) {
                        .object => |command_object| command_object,
                        else => return false,
                    };
                    const label = if (command.get("usage")) |usage_value|
                        jsonString(usage_value) catch return false
                    else if (command.get("name")) |name_value|
                        jsonString(name_value) catch return false
                    else
                        return false;
                    if (command.get("description")) |description_value| {
                        const description = jsonString(description_value) catch return false;
                        try writer.print("  {s}\n      {s}\n", .{ label, description });
                    } else {
                        try writer.print("  {s}\n", .{label});
                    }
                }
                wrote_any = true;
            }
            if (object.get("options")) |options_value| {
                const options = switch (options_value) {
                    .array => |arr| arr,
                    else => return false,
                };
                if (wrote_any) try writer.writeByte('\n');
                try writer.writeAll("Options:\n");
                for (options.items) |item| {
                    const option = switch (item) {
                        .object => |option_object| option_object,
                        else => return false,
                    };
                    const flags = jsonString(option.get("flags") orelse return false) catch return false;
                    if (option.get("description")) |description_value| {
                        const description = jsonString(description_value) catch return false;
                        try writer.print("  {s}\n      {s}\n", .{ flags, description });
                    } else {
                        try writer.print("  {s}\n", .{flags});
                    }
                }
                wrote_any = true;
            }
            return wrote_any;
        },
        else => return false,
    }
}

fn writePluginHelpFallback(loaded: *const LoadedPlugin, writer: anytype, manifest_name: ?[]const u8, manifest_version: ?[]const u8) !void {
    const plugin_name = manifest_name orelse std.mem.span(loaded.descriptor.name);
    try writeManifestHelpFallback(writer, plugin_name, manifest_version);

    const skills = loaded.descriptor.skills_ptr[0..loaded.descriptor.skills_len];
    if (skills.len == 0) return;
    try writer.writeAll("\nSkills:\n");
    for (skills) |section| {
        try writer.print("  {s}", .{section.name});
        const summary = section.summary;
        if (summary.len != 0) try writer.print(" - {s}", .{summary});
        try writer.writeByte('\n');
    }
}

fn writeManifestHelpFallback(writer: anytype, plugin_name: []const u8, manifest_version: ?[]const u8) !void {
    try writer.print("usage: sars {s} [--help]\n\n", .{plugin_name});
    if (manifest_version) |version| {
        try writer.print("{s} {s}\n", .{ plugin_name, version });
    } else {
        try writer.print("{s}\n", .{plugin_name});
    }
}

fn parseAbiPlugin(maybe_value: ?std.json.Value) !u32 {
    const value = maybe_value orelse return abi_version;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidSapManifest,
    };
    const plugin_value = obj.get("plugin") orelse return abi_version;
    return switch (plugin_value) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @as(u32, @intCast(n)) else error.InvalidSapManifest,
        else => error.InvalidSapManifest,
    };
}

const SelectedArtifact = struct {
    path: []const u8,
    sha256: ?[32]u8,
};

fn selectArtifact(value: std.json.Value) !SelectedArtifact {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidSapManifest,
    };
    if (obj.get(targetArtifactKey())) |target_value| {
        return try artifactFromValue(target_value);
    }
    if (obj.get("linux-x86_64")) |target_value| {
        return try artifactFromValue(target_value);
    }
    var it = obj.iterator();
    if (it.next()) |entry| return try artifactFromValue(entry.value_ptr.*);
    return error.InvalidSapManifest;
}

fn artifactFromValue(value: std.json.Value) !SelectedArtifact {
    return switch (value) {
        .string => |s| .{ .path = s, .sha256 = null },
        .object => |o| blk: {
            try rejectUnknownSapKeys(o, &.{ "path", "sha256" });
            const path = try jsonString(o.get("path") orelse return error.InvalidSapManifest);
            const hash = if (o.get("sha256")) |hash_value| try parseSha256Json(hash_value) else null;
            break :blk .{ .path = path, .sha256 = hash };
        },
        else => error.InvalidSapManifest,
    };
}

fn collectInterfaceFiles(allocator: std.mem.Allocator, maybe_value: ?std.json.Value) ![]InterfaceFile {
    var files = std.array_list.Managed(InterfaceFile).init(allocator);
    errdefer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit();
    }
    const value = maybe_value orelse return try files.toOwnedSlice();
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidSapManifest,
    };
    if (obj.get("sa")) |sa_value| switch (sa_value) {
        .array => |arr| for (arr.items) |item| try files.append(try interfaceFileFromValue(allocator, .sa, item)),
        else => return error.InvalidSapManifest,
    };
    if (obj.get("sai")) |sai_value| try files.append(try interfaceFileFromValue(allocator, .sai, sai_value));
    if (obj.get("sal")) |sal_value| try files.append(try interfaceFileFromValue(allocator, .sal, sal_value));
    if (obj.get("wasm_imports")) |wasm_imports_value| switch (wasm_imports_value) {
        .array => |arr| for (arr.items) |item| try files.append(try interfaceFileFromValue(allocator, .wasm_import, item)),
        else => try files.append(try interfaceFileFromValue(allocator, .wasm_import, wasm_imports_value)),
    };
    return try files.toOwnedSlice();
}

fn interfaceFileFromValue(allocator: std.mem.Allocator, kind: InterfaceKind, value: std.json.Value) !InterfaceFile {
    switch (value) {
        .string => |s| return .{ .kind = kind, .path = try allocator.dupe(u8, s), .sha256 = null },
        .object => |o| {
            try rejectUnknownSapKeys(o, &.{ "path", "sha256" });
            const path = try allocator.dupe(u8, try jsonString(o.get("path") orelse return error.InvalidSapManifest));
            errdefer allocator.free(path);
            const hash = if (o.get("sha256")) |hash_value| try parseSha256Json(hash_value) else null;
            return .{ .kind = kind, .path = path, .sha256 = hash };
        },
        else => return error.InvalidSapManifest,
    }
}

fn collectAssetFiles(allocator: std.mem.Allocator, maybe_value: ?std.json.Value) ![]AssetFile {
    var files = std.array_list.Managed(AssetFile).init(allocator);
    errdefer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit();
    }
    const value = maybe_value orelse return try files.toOwnedSlice();
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidSapManifest,
    };
    if (obj.get("share")) |share_value| switch (share_value) {
        .array => |arr| for (arr.items) |item| try files.append(try assetFileFromValue(allocator, .share, item)),
        else => return error.InvalidSapManifest,
    };
    return try files.toOwnedSlice();
}

fn assetFileFromValue(allocator: std.mem.Allocator, kind: AssetKind, value: std.json.Value) !AssetFile {
    switch (value) {
        .string => |s| {
            try validateProjectRelativePath(s);
            const target = std.fs.path.basename(s);
            try validateProjectRelativePath(target);
            return .{
                .kind = kind,
                .path = try allocator.dupe(u8, s),
                .target = try allocator.dupe(u8, target),
                .sha256 = null,
            };
        },
        .object => |o| {
            try rejectUnknownSapKeys(o, &.{ "path", "target", "sha256" });
            const path_text = try jsonString(o.get("path") orelse return error.InvalidSapManifest);
            try validateProjectRelativePath(path_text);
            const target_text = if (o.get("target")) |target_value| try jsonString(target_value) else std.fs.path.basename(path_text);
            try validateProjectRelativePath(target_text);
            const path = try allocator.dupe(u8, path_text);
            errdefer allocator.free(path);
            const target = try allocator.dupe(u8, target_text);
            errdefer allocator.free(target);
            const hash = if (o.get("sha256")) |hash_value| try parseSha256Json(hash_value) else null;
            return .{ .kind = kind, .path = path, .target = target, .sha256 = hash };
        },
        else => return error.InvalidSapManifest,
    }
}

fn rejectUnknownSapKeys(obj: std.json.ObjectMap, allowed: []const []const u8) !void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        var ok = false;
        for (allowed) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                ok = true;
                break;
            }
        }
        if (!ok) return error.InvalidSapManifest;
    }
}

fn parseSha256Json(value: std.json.Value) ![32]u8 {
    const text = try jsonString(value);
    const body = if (std.mem.startsWith(u8, text, "sha256:")) text["sha256:".len..] else text;
    if (body.len != 64) return error.InvalidSapManifest;
    var bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(bytes[0..], body) catch return error.InvalidSapManifest;
    return bytes;
}

fn validateProjectRelativePath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.InvalidSapManifest;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidSapManifest;
    }
}

fn verifyInterfaceFiles(allocator: std.mem.Allocator, manifest: SapManifest) !u8 {
    for (manifest.interface_files) |iface| {
        try validateProjectRelativePath(iface.path);
        const path = try std.fs.path.join(allocator, &.{ manifest.root_dir, iface.path });
        defer allocator.free(path);
        if (!fileExistsAbsolute(path)) return error.PluginInterfaceMissing;
        if (iface.sha256) |expected| {
            const actual = try sha256File(allocator, path);
            if (!std.mem.eql(u8, actual[0..], expected[0..])) return error.PluginInterfaceHashMismatch;
        }
    }
    return 0;
}

fn verifyAssetFiles(allocator: std.mem.Allocator, manifest: SapManifest) !u8 {
    for (manifest.asset_files) |asset| {
        try validateProjectRelativePath(asset.path);
        try validateProjectRelativePath(asset.target);
        const path = try std.fs.path.join(allocator, &.{ manifest.root_dir, asset.path });
        defer allocator.free(path);
        if (!fileExistsAbsolute(path)) return error.PluginInterfaceMissing;
        if (asset.sha256) |expected| {
            const actual = try sha256File(allocator, path);
            if (!std.mem.eql(u8, actual[0..], expected[0..])) return error.PluginInterfaceHashMismatch;
        }
    }
    return 0;
}

fn copyAssetFiles(allocator: std.mem.Allocator, manifest: SapManifest, installed_dir: []const u8, version_dir: []const u8) !void {
    for (manifest.asset_files) |asset| {
        const src = try std.fs.path.join(allocator, &.{ manifest.root_dir, asset.path });
        defer allocator.free(src);
        switch (asset.kind) {
            .share => {
                const dst = try std.fs.path.join(allocator, &.{ installed_dir, "share", asset.target });
                defer allocator.free(dst);
                try copyFileAbsolute(src, dst);
                const version_dst = try std.fs.path.join(allocator, &.{ version_dir, "share", asset.target });
                defer allocator.free(version_dst);
                try copyFileAbsolute(src, version_dst);
            },
        }
    }
}

fn verifySymbolSmoke(allocator: std.mem.Allocator, manifest: SapManifest, artifact_abs: []const u8, stdout: anytype) !u8 {
    var externs = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (externs.items) |name| allocator.free(name);
        externs.deinit();
    }
    for (manifest.interface_files) |iface| {
        if (iface.kind != .sai) continue;
        const path = try std.fs.path.join(allocator, &.{ manifest.root_dir, iface.path });
        defer allocator.free(path);
        try collectExternSymbolsFromSai(allocator, path, &externs);
    }
    if (externs.items.len == 0) return 0;

    var lib = std.DynLib.open(artifact_abs) catch |err| {
        try stdout.print("plugin artifact could not be opened for symbol smoke: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer lib.close();
    for (externs.items) |symbol| {
        const symbol_z = try allocator.dupeSentinel(u8, symbol, 0);
        defer allocator.free(symbol_z);
        if (lib.lookup(*anyopaque, symbol_z) == null) {
            try stdout.print("plugin artifact missing @extern symbol from .sai: {s}\n", .{symbol});
            return 1;
        }
    }
    return 0;
}

fn collectExternSymbolsFromSai(allocator: std.mem.Allocator, path: []const u8, out: *std.array_list.Managed([]u8)) !void {
    const source = try readFileAbsoluteAlloc(allocator, path, 1 << 20);
    defer allocator.free(source);
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "@extern ")) continue;
        const rest = std.mem.trim(u8, line["@extern ".len..], " \t");
        const paren = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
        const symbol = std.mem.trim(u8, rest[0..paren], " \t");
        if (symbol.len == 0) continue;
        if (externSymbolExists(out.items, symbol)) return error.PluginDuplicateExternSymbol;
        try out.append(try allocator.dupe(u8, symbol));
    }
}

fn externSymbolExists(items: []const []u8, symbol: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, symbol)) return true;
    }
    return false;
}

const ExternProvider = struct {
    symbol: []u8,
    plugin: []u8,

    fn deinit(self: *ExternProvider, allocator: std.mem.Allocator) void {
        allocator.free(self.symbol);
        allocator.free(self.plugin);
        self.* = undefined;
    }
};

fn verifyInstalledExternSymbolConflicts(allocator: std.mem.Allocator, manifest: SapManifest, stdout: anytype) !u8 {
    var installed = std.array_list.Managed(ExternProvider).init(allocator);
    defer {
        for (installed.items) |*provider| provider.deinit(allocator);
        installed.deinit();
    }
    if (try collectInstalledExternProviders(allocator, manifest.name, stdout, &installed) != 0) return 1;

    var current = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (current.items) |symbol| allocator.free(symbol);
        current.deinit();
    }
    try collectManifestExternSymbols(allocator, manifest, &current);
    for (current.items) |symbol| {
        if (findExternProvider(installed.items, symbol)) |provider| {
            try stdout.print(
                "plugin extern symbol conflict: {s} already provided by installed plugin {s}\n",
                .{ symbol, provider.plugin },
            );
            return 1;
        }
    }
    return 0;
}

fn collectInstalledExternProviders(
    allocator: std.mem.Allocator,
    installing_name: []const u8,
    stdout: anytype,
    out: *std.array_list.Managed(ExternProvider),
) !u8 {
    const home = try pluginsHome(allocator);
    defer allocator.free(home);
    const root_path = try std.fs.path.join(allocator, &.{ home, "installed" });
    defer allocator.free(root_path);
    var root = sio.openDirAbsolute(root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return 0,
        else => return err,
    };
    defer root.close();

    var it = root.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (std.mem.eql(u8, entry.name, installing_name)) continue;
        const sa_dir = try std.fs.path.join(allocator, &.{ root_path, entry.name, "current", "sa" });
        defer allocator.free(sa_dir);
        var dir = sio.openDirAbsolute(sa_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        defer dir.close();

        var dir_it = dir.iterate();
        while (try dir_it.next()) |sa_entry| {
            if (sa_entry.kind != .file and sa_entry.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, sa_entry.name, ".sai")) continue;
            const sai_path = try std.fs.path.join(allocator, &.{ sa_dir, sa_entry.name });
            defer allocator.free(sai_path);
            var symbols = std.array_list.Managed([]u8).init(allocator);
            defer symbols.deinit();
            try collectExternSymbolsFromSai(allocator, sai_path, &symbols);
            for (symbols.items, 0..) |symbol, idx| {
                if (findExternProvider(out.items, symbol)) |existing| {
                    if (std.mem.eql(u8, existing.plugin, entry.name)) {
                        try stdout.print(
                            "installed plugin duplicate extern symbol: {s} is declared more than once by installed plugin {s}\n",
                            .{ symbol, entry.name },
                        );
                    } else {
                        try stdout.print(
                            "installed plugin extern symbol conflict: {s} is provided by both {s} and {s}\n",
                            .{ symbol, existing.plugin, entry.name },
                        );
                    }
                    for (symbols.items[idx..]) |owned| allocator.free(owned);
                    return 1;
                }
                try out.append(.{
                    .symbol = symbol,
                    .plugin = try allocator.dupe(u8, entry.name),
                });
            }
            symbols.items.len = 0;
        }
    }
    return 0;
}

fn collectManifestExternSymbols(allocator: std.mem.Allocator, manifest: SapManifest, out: *std.array_list.Managed([]u8)) !void {
    for (manifest.interface_files) |iface| {
        if (iface.kind != .sai) continue;
        const path = try std.fs.path.join(allocator, &.{ manifest.root_dir, iface.path });
        defer allocator.free(path);
        try collectExternSymbolsFromSai(allocator, path, out);
    }
}

fn findExternProvider(items: []const ExternProvider, symbol: []const u8) ?*const ExternProvider {
    for (items) |*item| {
        if (std.mem.eql(u8, item.symbol, symbol)) return item;
    }
    return null;
}

const ArtifactImportCapability = enum {
    fs,
    net,
    env,
    process,
    dynamic_loader,
};

const ArtifactImportRule = struct {
    symbol: []const u8,
    capability: ArtifactImportCapability,
};

const artifact_import_rules = [_]ArtifactImportRule{
    .{ .symbol = "connect", .capability = .net },
    .{ .symbol = "socket", .capability = .net },
    .{ .symbol = "WSAStartup", .capability = .net },
    .{ .symbol = "WSASocketA", .capability = .net },
    .{ .symbol = "WSASocketW", .capability = .net },
    .{ .symbol = "closesocket", .capability = .net },
    .{ .symbol = "getaddrinfo", .capability = .net },
    .{ .symbol = "send", .capability = .net },
    .{ .symbol = "sendto", .capability = .net },
    .{ .symbol = "recv", .capability = .net },
    .{ .symbol = "recvfrom", .capability = .net },
    .{ .symbol = "open", .capability = .fs },
    .{ .symbol = "openat", .capability = .fs },
    .{ .symbol = "fopen", .capability = .fs },
    .{ .symbol = "mkdir", .capability = .fs },
    .{ .symbol = "rename", .capability = .fs },
    .{ .symbol = "unlink", .capability = .fs },
    .{ .symbol = "readlink", .capability = .fs },
    .{ .symbol = "stat", .capability = .fs },
    .{ .symbol = "getenv", .capability = .env },
    .{ .symbol = "_getenv", .capability = .env },
    .{ .symbol = "setenv", .capability = .env },
    .{ .symbol = "unsetenv", .capability = .env },
    .{ .symbol = "putenv", .capability = .env },
    .{ .symbol = "_putenv", .capability = .env },
    .{ .symbol = "_putenv_s", .capability = .env },
    .{ .symbol = "execve", .capability = .process },
    .{ .symbol = "CreateProcessA", .capability = .process },
    .{ .symbol = "CreateProcessW", .capability = .process },
    .{ .symbol = "execvpe", .capability = .process },
    .{ .symbol = "posix_spawn", .capability = .process },
    .{ .symbol = "fork", .capability = .process },
    .{ .symbol = "vfork", .capability = .process },
    .{ .symbol = "popen", .capability = .process },
    .{ .symbol = "system", .capability = .process },
    .{ .symbol = "dlopen", .capability = .dynamic_loader },
    .{ .symbol = "dlmopen", .capability = .dynamic_loader },
    .{ .symbol = "__libc_dlopen_mode", .capability = .dynamic_loader },
    .{ .symbol = "LoadLibraryA", .capability = .dynamic_loader },
    .{ .symbol = "LoadLibraryW", .capability = .dynamic_loader },
    .{ .symbol = "LoadLibraryExA", .capability = .dynamic_loader },
    .{ .symbol = "LoadLibraryExW", .capability = .dynamic_loader },
};

fn verifyArtifactStaticPolicy(
    allocator: std.mem.Allocator,
    manifest: SapManifest,
    artifact_abs: []const u8,
    stdout: anytype,
    options: InstallOptions,
) !u8 {
    var imports = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (imports.items) |symbol| allocator.free(symbol);
        imports.deinit();
    }
    try collectArtifactUndefinedImports(allocator, artifact_abs, &imports);
    for (artifact_import_rules) |rule| {
        if (!externSymbolExists(imports.items, rule.symbol)) continue;
        switch (rule.capability) {
            .fs => if (!manifest.has_fs_permission) {
                try stdout.print("plugin artifact references file-system symbol without declared fs permission: {s}\n", .{rule.symbol});
                return 1;
            },
            .net => if (!manifest.has_net_permission) {
                try stdout.print("plugin artifact references network symbol without declared net permission: {s}\n", .{rule.symbol});
                return 1;
            },
            .env => if (!manifest.has_env_permission) {
                try stdout.print("plugin artifact references environment symbol without declared env permission: {s}\n", .{rule.symbol});
                return 1;
            },
            .process => if (!manifest.has_process_permission and !options.dev and !pluginDevMode(allocator)) {
                try stdout.print("plugin artifact references process symbol without declared process permission: {s}\n", .{rule.symbol});
                return 1;
            },
            .dynamic_loader => if (!options.dev and !pluginDevMode(allocator)) {
                try stdout.print("plugin artifact references dynamic loader symbol forbidden for formal install: {s}\n", .{rule.symbol});
                return 1;
            },
        }
    }
    return 0;
}

fn collectArtifactUndefinedImports(allocator: std.mem.Allocator, artifact_abs: []const u8, out: *std.array_list.Managed([]u8)) !void {
    if (@import("builtin").os.tag == .windows) {
        const tools = [_][]const u8{"dumpbin"};
        for (tools) |tool| {
            const result = sio.Child.run(.{
                .allocator = allocator,
                .argv = &.{ tool, "/nologo", "/imports", artifact_abs },
            }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (!childExitedZero(result.term)) continue;
            try parseDumpbinImportList(allocator, result.stdout, out);
            return;
        }
        return error.PluginArtifactScanUnavailable;
    }

    const tools = [_][]const u8{ "nm", "llvm-nm" };
    for (tools) |tool| {
        const result = sio.Child.run(.{
            .allocator = allocator,
            .argv = &.{ tool, "-D", "--undefined-only", artifact_abs },
        }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (!childExitedZero(result.term)) continue;
        try parseUndefinedImportList(allocator, result.stdout, out);
        return;
    }
    return error.PluginArtifactScanUnavailable;
}

fn parseDumpbinImportList(allocator: std.mem.Allocator, text: []const u8, out: *std.array_list.Managed([]u8)) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.endsWith(u8, line, ".dll") or std.mem.endsWith(u8, line, ".DLL")) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const first = fields.next() orelse continue;
        if (!isHexToken(first)) continue;
        const symbol = fields.next() orelse continue;
        if (std.mem.eql(u8, symbol, "Ordinal")) continue;
        if (symbol.len == 0 or externSymbolExists(out.items, symbol)) continue;
        try out.append(try allocator.dupe(u8, symbol));
    }
}

fn isHexToken(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => {},
        else => return false,
    };
    return true;
}

fn parseUndefinedImportList(allocator: std.mem.Allocator, text: []const u8, out: *std.array_list.Managed([]u8)) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const last_delim = std.mem.lastIndexOfAny(u8, line, " \t") orelse continue;
        var symbol = std.mem.trim(u8, line[last_delim + 1 ..], " \t");
        if (std.mem.indexOfScalar(u8, symbol, '@')) |version_idx| symbol = symbol[0..version_idx];
        if (symbol.len == 0 or externSymbolExists(out.items, symbol)) continue;
        try out.append(try allocator.dupe(u8, symbol));
    }
}

fn collectStringArray(allocator: std.mem.Allocator, maybe_value: ?std.json.Value) ![][]u8 {
    var items = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit();
    }
    const value = maybe_value orelse return try items.toOwnedSlice();
    const arr = switch (value) {
        .array => |a| a,
        else => return error.InvalidSapManifest,
    };
    for (arr.items) |item| try items.append(try allocator.dupe(u8, try jsonString(item)));
    return try items.toOwnedSlice();
}

fn collectPluginDependencies(allocator: std.mem.Allocator, maybe_value: ?std.json.Value) ![]PluginDependency {
    var deps = std.array_list.Managed(PluginDependency).init(allocator);
    errdefer {
        for (deps.items) |*dep| dep.deinit(allocator);
        deps.deinit();
    }
    const value = maybe_value orelse return try deps.toOwnedSlice();
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidSapManifest,
    };
    var it = obj.iterator();
    while (it.next()) |entry| {
        const dep_obj = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => return error.InvalidSapManifest,
        };
        const version = if (dep_obj.get("version")) |version_value| try jsonString(version_value) else "*";
        const abi = if (dep_obj.get("abi")) |abi_value| switch (abi_value) {
            .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @as(u32, @intCast(n)) else return error.InvalidSapManifest,
            else => return error.InvalidSapManifest,
        } else abi_version;
        const optional = if (dep_obj.get("optional")) |optional_value| switch (optional_value) {
            .bool => |b| b,
            else => return error.InvalidSapManifest,
        } else false;
        const dep_symbols = try collectStringArray(allocator, dep_obj.get("symbols"));
        errdefer {
            for (dep_symbols) |symbol| allocator.free(symbol);
            allocator.free(dep_symbols);
        }
        const dep_path = if (dep_obj.get("path")) |path_value| try allocator.dupe(u8, try jsonString(path_value)) else null;
        errdefer if (dep_path) |path| allocator.free(path);
        const dep_url = if (dep_obj.get("url")) |url_value| blk: {
            const url = try jsonString(url_value);
            if (!allowedExternalUrl(url)) return error.InvalidSapManifest;
            break :blk try allocator.dupe(u8, url);
        } else null;
        errdefer if (dep_url) |url| allocator.free(url);
        try rejectUnknownKeys(dep_obj, &.{ "version", "abi", "optional", "symbols", "path", "url" });
        try deps.append(.{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .version = try allocator.dupe(u8, version),
            .abi = abi,
            .optional = optional,
            .symbols = dep_symbols,
            .path = dep_path,
            .url = dep_url,
        });
    }
    return try deps.toOwnedSlice();
}

fn collectManifestExternalUrls(allocator: std.mem.Allocator, object: std.json.ObjectMap, urls: *std.array_list.Managed([]u8)) !void {
    if (object.get("source")) |source_value| {
        const source_obj = switch (source_value) {
            .object => |o| o,
            else => return error.InvalidSapManifest,
        };
        if (source_obj.get("url")) |url_value| {
            const url = try jsonString(url_value);
            if (!allowedExternalUrl(url)) return error.InvalidSapManifest;
            try urls.append(try allocator.dupe(u8, url));
        }
    }
    if (object.get("dependencies")) |deps_value| {
        const deps_obj = switch (deps_value) {
            .object => |o| o,
            else => return error.InvalidSapManifest,
        };
        var it = deps_obj.iterator();
        while (it.next()) |entry| {
            const dep_obj = switch (entry.value_ptr.*) {
                .object => |o| o,
                else => return error.InvalidSapManifest,
            };
            if (dep_obj.get("url")) |url_value| {
                const url = try jsonString(url_value);
                if (!allowedExternalUrl(url)) return error.InvalidSapManifest;
                try urls.append(try allocator.dupe(u8, url));
            }
        }
    }
}

const PermissionInfo = struct {
    requires_sandbox: bool,
    digest: [32]u8,
    urls: std.array_list.Managed([]u8),
    env_permissions: std.array_list.Managed([]u8),
    fs_permissions: std.array_list.Managed(FsPermission),
    net_permissions: std.array_list.Managed(NetPermission),
    process_spawn: bool,
    process_exec_permissions: std.array_list.Managed(ProcessExecPermission),
    has_fs_permission: bool,
    has_net_permission: bool,
    has_env_permission: bool,
    has_process_permission: bool,

    fn deinit(self: *PermissionInfo, allocator: std.mem.Allocator) void {
        for (self.urls.items) |url| allocator.free(url);
        self.urls.deinit();
        for (self.env_permissions.items) |entry| allocator.free(entry);
        self.env_permissions.deinit();
        for (self.fs_permissions.items) |*entry| entry.deinit(allocator);
        self.fs_permissions.deinit();
        for (self.net_permissions.items) |*entry| entry.deinit(allocator);
        self.net_permissions.deinit();
        for (self.process_exec_permissions.items) |*entry| entry.deinit(allocator);
        self.process_exec_permissions.deinit();
        self.* = undefined;
    }
};

fn validatePermissions(allocator: std.mem.Allocator, value: std.json.Value) !PermissionInfo {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.PluginPermissionsMissing,
    };
    try validatePermissionKeys(obj);
    const permissions_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(permissions_json);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(permissions_json);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var requires_sandbox = false;
    var has_fs_permission = false;
    var has_net_permission = false;
    var has_env_permission = false;
    var has_process_permission = false;
    var urls = std.array_list.Managed([]u8).init(allocator);
    var env_permissions = std.array_list.Managed([]u8).init(allocator);
    var fs_permissions = std.array_list.Managed(FsPermission).init(allocator);
    var net_permissions = std.array_list.Managed(NetPermission).init(allocator);
    var process_spawn = false;
    var process_exec_permissions = std.array_list.Managed(ProcessExecPermission).init(allocator);
    errdefer {
        for (urls.items) |url| allocator.free(url);
        urls.deinit();
        for (env_permissions.items) |entry| allocator.free(entry);
        env_permissions.deinit();
        for (fs_permissions.items) |*entry| entry.deinit(allocator);
        fs_permissions.deinit();
        for (net_permissions.items) |*entry| entry.deinit(allocator);
        net_permissions.deinit();
        for (process_exec_permissions.items) |*entry| entry.deinit(allocator);
        process_exec_permissions.deinit();
    }

    if (obj.get("fs")) |fs_value| switch (fs_value) {
        .array => |arr| {
            has_fs_permission = arr.items.len != 0;
            if (arr.items.len != 0) requires_sandbox = true;
            for (arr.items) |item| try fs_permissions.append(try parseFsPermission(allocator, item));
        },
        else => return error.InvalidPluginPermission,
    } else return error.InvalidPluginPermission;
    if (obj.get("net")) |net_value| switch (net_value) {
        .array => |arr| {
            has_net_permission = arr.items.len != 0;
            if (arr.items.len != 0) requires_sandbox = true;
            for (arr.items) |item| {
                var permission = try parseNetPermission(allocator, item);
                errdefer permission.deinit(allocator);
                try urls.append(try allocator.dupe(u8, permission.url));
                try net_permissions.append(permission);
            }
        },
        else => return error.InvalidPluginPermission,
    } else return error.InvalidPluginPermission;
    if (obj.get("env")) |env_value| switch (env_value) {
        .array => |arr| {
            has_env_permission = arr.items.len != 0;
            if (arr.items.len != 0) requires_sandbox = true;
            for (arr.items) |item| {
                const name = try jsonString(item);
                if (!validEnvPermission(name)) return error.InvalidPluginPermission;
                try env_permissions.append(try allocator.dupe(u8, name));
            }
        },
        else => return error.InvalidPluginPermission,
    } else return error.InvalidPluginPermission;
    if (obj.get("process")) |process_value| {
        const process_obj = switch (process_value) {
            .object => |o| o,
            else => return error.InvalidPluginPermission,
        };
        try rejectUnknownKeys(process_obj, &.{ "spawn", "exec" });
        if (process_obj.get("spawn")) |spawn_value| switch (spawn_value) {
            .bool => |spawn_value_bool| {
                if (spawn_value_bool) requires_sandbox = true;
                if (spawn_value_bool) has_process_permission = true;
                process_spawn = spawn_value_bool;
            },
            else => return error.InvalidPluginPermission,
        } else return error.InvalidPluginPermission;
        if (process_obj.get("exec")) |exec_value| switch (exec_value) {
            .array => |arr| {
                if (arr.items.len != 0) has_process_permission = true;
                if (arr.items.len != 0) requires_sandbox = true;
                if (arr.items.len != 0 and !process_spawn) return error.InvalidPluginPermission;
                if (process_spawn and arr.items.len == 0) return error.InvalidPluginPermission;
                for (arr.items) |item| try process_exec_permissions.append(try parseProcessExecPermission(allocator, item));
            },
            else => return error.InvalidPluginPermission,
        } else return error.InvalidPluginPermission;
    } else return error.InvalidPluginPermission;
    return .{
        .requires_sandbox = requires_sandbox,
        .digest = digest,
        .urls = urls,
        .env_permissions = env_permissions,
        .fs_permissions = fs_permissions,
        .net_permissions = net_permissions,
        .process_spawn = process_spawn,
        .process_exec_permissions = process_exec_permissions,
        .has_fs_permission = has_fs_permission,
        .has_net_permission = has_net_permission,
        .has_env_permission = has_env_permission,
        .has_process_permission = has_process_permission,
    };
}

fn validatePermissionKeys(obj: std.json.ObjectMap) !void {
    try rejectUnknownKeys(obj, &.{ "fs", "net", "env", "process" });
}

fn rejectUnknownKeys(obj: std.json.ObjectMap, allowed: []const []const u8) !void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        var ok = false;
        for (allowed) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                ok = true;
                break;
            }
        }
        if (!ok) return error.InvalidPluginPermission;
    }
}

fn parseFsPermission(allocator: std.mem.Allocator, value: std.json.Value) !FsPermission {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidPluginPermission,
    };
    try rejectUnknownKeys(obj, &.{ "op", "path" });
    const op = try jsonString(obj.get("op") orelse return error.InvalidPluginPermission);
    const path = try jsonString(obj.get("path") orelse return error.InvalidPluginPermission);
    if (!validPermissionPath(path)) return error.InvalidPluginPermission;
    return .{
        .op = parseFsPermissionOp(op) orelse return error.InvalidPluginPermission,
        .path = try allocator.dupe(u8, path),
    };
}

fn parseNetPermission(allocator: std.mem.Allocator, value: std.json.Value) !NetPermission {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidPluginPermission,
    };
    try rejectUnknownKeys(obj, &.{ "url", "methods" });
    const url = try jsonString(obj.get("url") orelse return error.InvalidPluginPermission);
    if (!allowedPermissionUrl(url)) return error.InvalidPluginPermission;
    return .{
        .url = try allocator.dupe(u8, url),
        .methods = if (obj.get("methods")) |methods_value|
            try parseHttpMethods(methods_value)
        else
            HttpMethodMask.default(),
    };
}

fn parseFsPermissionOp(text: []const u8) ?FsPermissionOp {
    if (std.mem.eql(u8, text, "read")) return .read;
    if (std.mem.eql(u8, text, "write")) return .write;
    if (std.mem.eql(u8, text, "create")) return .create;
    if (std.mem.eql(u8, text, "delete")) return .delete;
    if (std.mem.eql(u8, text, "metadata")) return .metadata;
    return null;
}

fn validPermissionPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/**") or std.mem.eql(u8, path, "~/**")) return false;
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    if (std.mem.indexOf(u8, path, "**") != null and !std.mem.endsWith(u8, path, "/**")) return false;
    return std.mem.startsWith(u8, path, "$PROJECT/") or
        std.mem.startsWith(u8, path, "$HOME/") or
        std.mem.startsWith(u8, path, "$SA_CACHE/") or
        std.mem.startsWith(u8, path, "$SA_PLUGINS_HOME/") or
        (std.fs.path.isAbsolute(path) and !std.mem.startsWith(u8, path, "/dev/") and !std.mem.startsWith(u8, path, "/proc/"));
}

fn parseHttpMethods(value: std.json.Value) !HttpMethodMask {
    const arr = switch (value) {
        .array => |a| a,
        else => return error.InvalidPluginPermission,
    };
    var mask = HttpMethodMask{};
    for (arr.items) |item| {
        const method = try jsonString(item);
        mask.insert(parseBrokerHttpMethod(method) orelse return error.InvalidPluginPermission);
    }
    if (mask.bits == 0) return error.InvalidPluginPermission;
    return mask;
}

fn validEnvPermission(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, "*")) return false;
    const body = if (std.mem.endsWith(u8, name, "*")) name[0 .. name.len - 1] else name;
    if (body.len == 0) return false;
    for (body) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn parseProcessExecPermission(allocator: std.mem.Allocator, value: std.json.Value) !ProcessExecPermission {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidPluginPermission,
    };
    try rejectUnknownKeys(obj, &.{ "path", "args" });
    const path = try jsonString(obj.get("path") orelse return error.InvalidPluginPermission);
    if (!std.fs.path.isAbsolute(path)) return error.InvalidPluginPermission;
    var args = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit();
    }
    if (obj.get("args")) |args_value| {
        const arr = switch (args_value) {
            .array => |a| a,
            else => return error.InvalidPluginPermission,
        };
        for (arr.items) |item| {
            const arg = try jsonString(item);
            if (arg.len == 0) return error.InvalidPluginPermission;
            try args.append(try allocator.dupe(u8, arg));
        }
    }
    return .{
        .path = try allocator.dupe(u8, path),
        .args = try args.toOwnedSlice(),
    };
}

const PermissionUrlParts = struct {
    scheme: []const u8,
    host: []const u8,
};

fn allowedPermissionUrl(url: []const u8) bool {
    const parts = parsePermissionUrlParts(url) orelse return false;
    if (std.ascii.eqlIgnoreCase(parts.scheme, "http")) return isLoopbackPermissionHost(parts.host);
    if (!std.ascii.eqlIgnoreCase(parts.scheme, "https")) return false;
    if (isWildcardPermissionHost(parts.host)) return true;
    if (isIpLiteralHost(parts.host) and !isLoopbackPermissionHost(parts.host)) return false;
    return true;
}

fn allowedExternalUrl(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "github:")) return true;
    return allowedPermissionUrl(url);
}

fn parsePermissionUrlParts(url: []const u8) ?PermissionUrlParts {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..scheme_end];
    if (scheme.len == 0) return null;
    const rest = url[scheme_end + 3 ..];
    if (rest.len == 0) return null;

    if (rest[0] == '[') {
        const close_rel = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
        if (close_rel <= 1) return null;
        const suffix = rest[close_rel + 1 ..];
        if (!validUrlHostSuffix(suffix)) return null;
        return .{ .scheme = scheme, .host = rest[1..close_rel] };
    }

    var host_end: usize = 0;
    while (host_end < rest.len and rest[host_end] != ':' and rest[host_end] != '/' and rest[host_end] != '?' and rest[host_end] != '#') : (host_end += 1) {}
    const host = rest[0..host_end];
    if (host.len == 0 or std.mem.indexOfScalar(u8, host, '@') != null) return null;
    return .{ .scheme = scheme, .host = host };
}

fn validUrlHostSuffix(suffix: []const u8) bool {
    return suffix.len == 0 or suffix[0] == ':' or suffix[0] == '/' or suffix[0] == '?' or suffix[0] == '#';
}

fn isWildcardPermissionHost(host: []const u8) bool {
    return std.mem.indexOfScalar(u8, host, '*') != null;
}

fn isLoopbackPermissionHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1");
}

fn isIpLiteralHost(host: []const u8) bool {
    _ = std.Io.net.IpAddress.parseIp4(host, 0) catch {
        _ = std.Io.net.IpAddress.parseIp6(host, 0) catch return false;
        return true;
    };
    return true;
}

fn warnBroadNetPermissions(stdout: anytype, manifest: SapManifest) !void {
    for (manifest.net_permissions) |permission| {
        const parts = parsePermissionUrlParts(permission.url) orelse continue;
        if (isWildcardPermissionHost(parts.host)) {
            try stdout.print("warning: plugin {s} declares broad network permission: {s}\n", .{ manifest.name, permission.url });
        }
    }
}

test "plugin network permission URLs reject remote http and bare remote IPs" {
    try std.testing.expect(allowedPermissionUrl("http://127.0.0.1:18094/allowed"));
    try std.testing.expect(allowedPermissionUrl("http://localhost/allowed"));
    try std.testing.expect(allowedPermissionUrl("http://[::1]/allowed"));
    try std.testing.expect(allowedPermissionUrl("https://example.com/api"));
    try std.testing.expect(allowedPermissionUrl("https://*/api"));

    try std.testing.expect(!allowedPermissionUrl("http://example.com/api"));
    try std.testing.expect(!allowedPermissionUrl("example.com/api"));
    try std.testing.expect(!allowedPermissionUrl("https://192.168.1.10/api"));
    try std.testing.expect(!allowedPermissionUrl("https://[2001:db8::1]/api"));
    try std.testing.expect(!allowedPermissionUrl("http://localhost.evil.example/api"));
}

fn pluginDevMode(allocator: std.mem.Allocator) bool {
    const value = sio.getEnvVarOwned(allocator, "SA_PLUGIN_DEV") catch return false;
    defer allocator.free(value);
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
}

fn confirmPrivilegedPluginInstall(stdout: anytype, manifest: SapManifest) !bool {
    if (!stdinIsTty()) {
        try stdout.print("refusing to install privileged plugin {s}: manual TTY confirmation is required\n", .{manifest.name});
        return false;
    }
    try stdout.print(
        \\SA PLUGIN PERMISSION REVIEW REQUIRED
        \\plugin: {s}
        \\version: {s}
        \\permissions_sha256: {s}
        \\
    , .{ manifest.name, manifest.version, std.fmt.bytesToHex(manifest.permission_digest, .lower) });
    if (manifest.external_urls.len != 0) {
        try stdout.writeAll("external URLs:\n");
        for (manifest.external_urls) |url| try stdout.print("- {s}\n", .{url});
    }
    if (manifest.dependencies.len != 0) {
        try stdout.writeAll("plugin dependencies:\n");
        for (manifest.dependencies) |dep| try stdout.print("- {s} version={s} abi={d} optional={s}\n", .{
            dep.name,
            dep.version,
            dep.abi,
            if (dep.optional) "true" else "false",
        });
    }
    try stdout.print("Type the exact plugin name to continue: ", .{});
    var buffer: [256]u8 = undefined;
    var stdin_buf: [8192]u8 = undefined;
    var stdin_stream = sio.getStdIn().reader(&stdin_buf);
    var stdin_reader = StdinLineReader{ .inner = &stdin_stream.interface };
    const line = (try stdin_reader.readUntilDelimiterOrEof(&buffer, '\n')) orelse "";
    const answer = std.mem.trim(u8, line, " \t\r\n");
    if (!std.mem.eql(u8, answer, manifest.name)) {
        try stdout.writeAll("plugin install cancelled\n");
        return false;
    }
    return true;
}

fn fileExistsAbsolute(path: []const u8) bool {
    var file = sio.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn sha256File(allocator: std.mem.Allocator, path: []const u8) ![32]u8 {
    _ = allocator;
    var file = try sio.openFileAbsolute(path, .{});
    defer file.close();
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn fileExistsInProject(allocator: std.mem.Allocator, root_dir: []const u8, rel: []const u8) bool {
    const path = std.fs.path.join(allocator, &.{ root_dir, rel }) catch return false;
    defer allocator.free(path);
    return fileExistsAbsolute(path);
}

fn buildPluginProject(allocator: std.mem.Allocator, root_dir: []const u8, stdout: anytype, optimize: []const u8) !u8 {
    const optimize_arg = try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{optimize});
    defer allocator.free(optimize_arg);
    const resolved_zig = try sio.resolveHostExe(allocator, "zig");
    defer if (resolved_zig) |p| allocator.free(p);
    const zig_exe = resolved_zig orelse "zig";
    const result = sio.Child.run(.{
        .allocator = allocator,
        .argv = &.{ zig_exe, "build", optimize_arg, "--summary", "all" },
        .cwd = root_dir,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            try stdout.writeAll("error: cannot build plugin project: 'zig' not found in PATH (sa plugin install builds the plugin with zig; install zig 0.14.1+ or add it to PATH)\n");
            return 1;
        },
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) return 0;
            try stdout.print("zig build failed for plugin project {s}\n{s}", .{ root_dir, result.stderr });
            return 1;
        },
        else => {
            try stdout.print("zig build did not exit cleanly for plugin project {s}\n{s}", .{ root_dir, result.stderr });
            return 1;
        },
    }
}

fn dirExistsAbsolute(path: []const u8) bool {
    var dir = sio.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

// NOTE(Zig 0.17): @cImport was moved to an external package; declare the
// single libc symbol this test needs directly.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

test "plugin build reports clear error when zig is missing from PATH" {
    const allocator = std.testing.allocator;
    const old_path = sio.getEnvVarOwned(allocator, "PATH") catch null;
    defer if (old_path) |p| allocator.free(p);
    // Point PATH at a nonexistent dir so `zig` cannot be resolved; buildPluginProject
    // must return 1 with a clear message instead of propagating error.FileNotFound.
    if (setenv("PATH", "/tmp/sa-test-no-such-path-dir", 1) != 0) return error.SetEnvFailed;
    defer blk: {
        if (old_path) |p| {
            const z = allocator.dupeSentinel(u8, p, 0) catch break :blk;
            defer allocator.free(z);
            _ = setenv("PATH", z.ptr, 1);
        }
    }
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const rc = try buildPluginProject(allocator, "/tmp", &aw.writer, "ReleaseFast");
    try std.testing.expectEqual(@as(u8, 1), rc);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "PATH") != null);
}

fn readFileAbsoluteAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try sio.openFileAbsolute(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, max_bytes);
}

fn copyFileAbsolute(src: []const u8, dst: []const u8) !void {
    try ensureParentDir(dst);
    try sio.copyFileAbsolute(src, dst);
}

fn writeFileAbsolute(path: []const u8, bytes: []const u8) !void {
    try ensureParentDir(path);
    var file = try sio.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn ensureParentDir(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try sio.cwd().makePath(dir);
}

fn loadDescriptor(lib: *std.DynLib) ?PluginDescriptor {
    if (lib.lookup(*const PluginDescriptor, descriptor_symbol_name)) |descriptor_ptr| {
        return descriptor_ptr.*;
    }
    if (lib.lookup(DescriptorFn, descriptor_fn_symbol_name)) |descriptor_fn| {
        var descriptor: PluginDescriptor = undefined;
        descriptor_fn(&descriptor);
        return descriptor;
    }
    return null;
}

fn validateDescriptor(descriptor: PluginDescriptor) ?[]const u8 {
    if (descriptor.abi_version != abi_version) return "abi version mismatch";
    if (descriptor.descriptor_size != @as(u32, @intCast(@sizeOf(PluginDescriptor)))) return "descriptor size mismatch";
    if (std.mem.span(descriptor.name).len == 0) return "empty plugin name";
    return null;
}

fn abiStatusFromInt(value: u32) AbiStatus {
    return switch (value) {
        @intFromEnum(AbiStatus.ok) => .ok,
        @intFromEnum(AbiStatus.unknown_command) => .unknown_command,
        @intFromEnum(AbiStatus.failed) => .failed,
        @intFromEnum(AbiStatus.version_mismatch) => .version_mismatch,
        @intFromEnum(AbiStatus.invalid_descriptor) => .invalid_descriptor,
        else => .failed,
    };
}

fn dupeZArgs(allocator: std.mem.Allocator, argv: []const []const u8) ![][*:0]const u8 {
    var out = try allocator.alloc([*:0]const u8, argv.len);
    errdefer allocator.free(out);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |arg| allocator.free(std.mem.sliceTo(arg, 0));
    }
    for (argv, 0..) |arg, idx| {
        out[idx] = try allocator.dupeSentinel(u8, arg, 0);
        copied += 1;
    }
    return out;
}

fn freeZArgs(allocator: std.mem.Allocator, argv: [][*:0]const u8) void {
    for (argv) |arg| allocator.free(std.mem.sliceTo(arg, 0));
    allocator.free(argv);
}

fn StreamCtx(comptime Writer: type) type {
    return struct {
        writer: *Writer,
    };
}

fn streamWriteAll(comptime Writer: type) StreamWriteAllFn {
    return struct {
        fn write(ctx: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) u32 {
            const stream_ctx = @as(*StreamCtx(Writer), @ptrCast(@alignCast(ctx orelse return @intFromEnum(AbiStatus.failed))));
            stream_ctx.writer.*.writeAll(bytes[0..len]) catch return @intFromEnum(AbiStatus.failed);
            return @intFromEnum(AbiStatus.ok);
        }
    }.write;
}

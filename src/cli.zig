const std = @import("std");
const builtin = @import("builtin");
const sio = @import("sio");

const flattener = @import("flattener.zig");
const line_classifier = @import("flattener/line_classifier.zig");
const interp = @import("interp.zig");
const build_options = @import("build_options");
const driver = @import("driver/zigcc.zig");
const emit_options = @import("emit_options.zig");
const emit_llvm_llvmc = @import("emit_llvm_llvmc.zig");
const emit_js = @import("emit_js.zig");
const emit_c = @import("emit_c.zig");
const bc2sa = @import("llvm2sa.zig");
const layout = @import("layout.zig");
const sab = @import("sab.zig");
const plugin_bridge = @import("plugin_bridge.zig");
const plugins = @import("plugins.zig");
const manifest = @import("pkg/manifest.zig");
const pkg_audit = @import("pkg/audit.zig");
const pkg_ci = @import("pkg/ci.zig");
const pkg_confirm = @import("pkg/confirm.zig");
const pkg_fetch = @import("pkg/fetch.zig");
const pkg_mirror = @import("pkg/mirror.zig");
const pkg_resolver = @import("pkg/resolver.zig");
const pkg_sum = @import("pkg/sum.zig");
const pkg_workspace = @import("pkg/workspace.zig");
const referee_call = @import("referee/call.zig");
const referee = @import("referee.zig");
const test_formatter = @import("test_formatter.zig");
const test_meta = @import("test_meta.zig");
const test_runner = @import("test_runner.zig");
const trap = @import("common/trap.zig");
const affected_tests = @import("affected_tests.zig");
const daemon_cancel = @import("daemon_cancel.zig");
const daemon_client = @import("daemon_client.zig");
const incr_verify = @import("incr_verify.zig");
const common_signature = @import("common/signature.zig");
const common_upstream = @import("common/upstream_loc.zig");

const DceMode = emit_options.DceMode;

fn intermediateArtifactPath(allocator: std.mem.Allocator, out_path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}.sa.bc", .{out_path});
}

const CompileOk = struct {
    flat: flattener.FlattenResult,
    verified: referee.VerifyOk,
    metrics: CompileMetrics,

    fn deinit(self: *CompileOk, allocator: std.mem.Allocator) void {
        self.verified.deinit(allocator);
        self.flat.deinit(allocator);
        self.* = undefined;
    }
};

const CompileResult = union(enum) {
    ok: CompileOk,
    trap: trap.TrapReport,
};

const GraphNodeKind = enum {
    source_file,
    function,
    call_target,
};

const GraphNode = struct {
    id: []const u8,
    kind: GraphNodeKind,
    label: []const u8,
};

const GraphEdgeKind = enum {
    imports,
    calls,
};

const GraphEdge = struct {
    from: []const u8,
    to: []const u8,
    kind: GraphEdgeKind,
};

const FunctionSizeEntry = struct {
    name: []const u8,
    instruction_count: u64,
    byte_count: u64,
};

const CompilePhaseMetrics = struct {
    load_ns: u64 = 0,
    setup_ns: u64 = 0,
    flatten_ns: u64 = 0,
    verify_ns: u64 = 0,
    emit_ns: ?u64 = null,
    link_ns: ?u64 = null,
    total_ns: ?u64 = null,
};

const VerifierMemoryMetrics = struct {
    start_rss_bytes: ?u64 = null,
    after_classify_rss_bytes: ?u64 = null,
    after_metadata_rss_bytes: ?u64 = null,
    after_chunks_rss_bytes: ?u64 = null,
    parallel_start_rss_bytes: ?u64 = null,
    parallel_after_worker_allocators_rss_bytes: ?u64 = null,
    parallel_after_body_rss_bytes: ?u64 = null,
    parallel_merge_rss_bytes: ?u64 = null,
    after_body_rss_bytes: ?u64 = null,
    after_finalize_rss_bytes: ?u64 = null,
    empty_rss_bytes: ?u64 = null,
};

const CompileMemoryMetrics = struct {
    start_rss_bytes: ?u64 = null,
    after_load_rss_bytes: ?u64 = null,
    after_setup_rss_bytes: ?u64 = null,
    after_flatten_rss_bytes: ?u64 = null,
    after_verify_rss_bytes: ?u64 = null,
    after_emit_rss_bytes: ?u64 = null,
    after_link_rss_bytes: ?u64 = null,
    end_rss_bytes: ?u64 = null,
    peak_rss_bytes: ?u64 = null,
    verifier: VerifierMemoryMetrics = .{},

    fn updatePeak(self: *CompileMemoryMetrics, rss: ?u64) void {
        const value = rss orelse return;
        if (self.peak_rss_bytes == null or value > self.peak_rss_bytes.?) {
            self.peak_rss_bytes = value;
        }
    }

    fn recordStart(self: *CompileMemoryMetrics) void {
        const rss = currentRssBytes();
        self.start_rss_bytes = rss;
        self.updatePeak(rss);
    }

    fn recordAfterLoad(self: *CompileMemoryMetrics) void {
        const rss = currentRssBytes();
        self.after_load_rss_bytes = rss;
        self.updatePeak(rss);
    }

    fn recordAfterSetup(self: *CompileMemoryMetrics) void {
        const rss = currentRssBytes();
        self.after_setup_rss_bytes = rss;
        self.updatePeak(rss);
    }

    fn recordAfterFlatten(self: *CompileMemoryMetrics) void {
        const rss = currentRssBytes();
        self.after_flatten_rss_bytes = rss;
        self.updatePeak(rss);
    }

    fn recordAfterVerify(self: *CompileMemoryMetrics) void {
        const rss = currentRssBytes();
        self.after_verify_rss_bytes = rss;
        self.updatePeak(rss);
    }

    fn recordAfterEmit(self: *CompileMemoryMetrics) void {
        const rss = currentRssBytes();
        self.after_emit_rss_bytes = rss;
        self.updatePeak(rss);
    }

    fn recordAfterLink(self: *CompileMemoryMetrics) void {
        const rss = currentRssBytes();
        self.after_link_rss_bytes = rss;
        self.updatePeak(rss);
    }

    fn recordEnd(self: *CompileMemoryMetrics) void {
        const rss = currentRssBytes();
        self.end_rss_bytes = rss;
        self.updatePeak(rss);
    }

    fn recordVerifierStage(self: *CompileMemoryMetrics, stage: []const u8, rss: ?u64) void {
        if (std.mem.eql(u8, stage, "start")) {
            self.verifier.start_rss_bytes = rss;
        } else if (std.mem.eql(u8, stage, "after_classify")) {
            self.verifier.after_classify_rss_bytes = rss;
        } else if (std.mem.eql(u8, stage, "after_metadata")) {
            self.verifier.after_metadata_rss_bytes = rss;
        } else if (std.mem.eql(u8, stage, "after_chunks")) {
            self.verifier.after_chunks_rss_bytes = rss;
        } else if (std.mem.eql(u8, stage, "parallel_start")) {
            self.verifier.parallel_start_rss_bytes = rss;
        } else if (std.mem.eql(u8, stage, "parallel_after_worker_allocators")) {
            self.verifier.parallel_after_worker_allocators_rss_bytes = rss;
        } else if (std.mem.eql(u8, stage, "parallel_after_body")) {
            self.verifier.parallel_after_body_rss_bytes = rss;
        } else if (std.mem.eql(u8, stage, "parallel_merge")) {
            self.verifier.parallel_merge_rss_bytes = rss;
        } else if (std.mem.eql(u8, stage, "after_body")) {
            self.verifier.after_body_rss_bytes = rss;
        } else if (std.mem.eql(u8, stage, "after_finalize")) {
            self.verifier.after_finalize_rss_bytes = rss;
        } else if (std.mem.eql(u8, stage, "empty")) {
            self.verifier.empty_rss_bytes = rss;
        }
        self.updatePeak(rss);
    }
};

const BackendIrMetrics = struct {
    functions: u64 = 0,
    blocks: u64 = 0,
    instructions: u64 = 0,
    alloca_slots: u64 = 0,
    loads: u64 = 0,
    stores: u64 = 0,
};

const CompileMetrics = struct {
    compile_tokens: u64,
    instruction_count: u64,
    phases: ?CompilePhaseMetrics = null,
    memory: ?CompileMemoryMetrics = null,
    backend_ir: ?BackendIrMetrics = null,
    cache: ?BuildCacheMetrics = null,
};

const BuildCacheMetrics = struct {
    kind: []const u8,
    hit: bool,
};

fn computeCompileMetrics(flat: *const flattener.FlattenResult, verified: *const referee.VerifyOk, phases: ?CompilePhaseMetrics, memory: ?CompileMemoryMetrics) CompileMetrics {
    const compile_tokens = @as(u64, flat.instructions.len) + @as(u64, flat.const_decls.len) + @as(u64, flat.function_sigs.len) + @as(u64, flat.test_sigs.len) + @as(u64, verified.annotated.len);
    return .{
        .compile_tokens = compile_tokens,
        .instruction_count = @as(u64, verified.annotated.len),
        .phases = phases,
        .memory = memory,
    };
}

fn currentRssBytes() ?u64 {
    if (builtin.os.tag != .linux) return null;

    var file = sio.openFileAbsolute("/proc/self/statm", .{}) catch return null;
    defer file.close();

    var buf: [128]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = file.read(buf[len..]) catch return null;
        if (n == 0) break;
        len += n;
    }
    var it = std.mem.tokenizeAny(u8, buf[0..len], " \t\r\n");
    _ = it.next() orelse return null;
    const rss_pages_text = it.next() orelse return null;
    const rss_pages = std.fmt.parseInt(u64, rss_pages_text, 10) catch return null;
    const page_size: u64 = @intCast(std.heap.pageSize());
    return rss_pages * page_size;
}

fn elapsedNs(start: std.Io.Timestamp) u64 {
    const end = std.Io.Clock.awake.now(sio.io());
    const ns: i96 = start.durationTo(end).toNanoseconds();
    return if (ns < 0) 0 else @intCast(ns);
}

fn finishProfileMetrics(metrics: *CompileMetrics, emit_ns: ?u64, link_ns: ?u64, total_ns: ?u64) void {
    if (metrics.phases) |phases| {
        metrics.phases = .{
            .load_ns = phases.load_ns,
            .setup_ns = phases.setup_ns,
            .flatten_ns = phases.flatten_ns,
            .verify_ns = phases.verify_ns,
            .emit_ns = emit_ns,
            .link_ns = link_ns,
            .total_ns = total_ns,
        };
    }
}

fn recordMetricMemoryAfterEmit(metrics: *CompileMetrics) void {
    if (metrics.memory) |*memory| memory.recordAfterEmit();
}

fn recordMetricMemoryAfterLink(metrics: *CompileMetrics) void {
    if (metrics.memory) |*memory| memory.recordAfterLink();
}

fn recordMetricMemoryEnd(metrics: *CompileMetrics) void {
    if (metrics.memory) |*memory| memory.recordEnd();
}

fn cacheHitMemoryMetrics(enabled: bool) ?CompileMemoryMetrics {
    if (!enabled) return null;
    var memory = CompileMemoryMetrics{};
    memory.recordStart();
    memory.recordEnd();
    return memory;
}

fn estimateBackendIrMetrics(verified: *const referee.VerifyOk, debug: bool) BackendIrMetrics {
    var out = BackendIrMetrics{};
    var sig_index: usize = 0;
    for (verified.annotated) |item| {
        switch (item.base.kind) {
            .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
                out.functions += 1;
                out.blocks += 1;
                if (sig_index < verified.function_sigs.len) {
                    if (debug) out.alloca_slots += @as(u64, @intCast(verified.function_sigs[sig_index].reg_ids.len));
                    sig_index += 1;
                }
            },
            .label => out.blocks += 1,
            .load, .take, .atomic_load => {
                out.instructions += 1;
                out.loads += 1;
            },
            .store, .atomic_store => {
                out.instructions += 1;
                out.stores += 1;
            },
            .move_, .release => {},
            else => out.instructions += 1,
        }
    }
    return out;
}

fn attachBackendIrMetrics(metrics: *CompileMetrics, verified: *const referee.VerifyOk, debug: bool) void {
    if (metrics.phases == null) return;
    metrics.backend_ir = estimateBackendIrMetrics(verified, debug);
}

fn computeFunctionSizes(allocator: std.mem.Allocator, verified: *const referee.VerifyOk) ![]FunctionSizeEntry {
    var entries = std.array_list.Managed(FunctionSizeEntry).init(allocator);
    errdefer entries.deinit();

    for (verified.function_sigs, 0..) |sig_item, idx| {
        const start = @as(usize, @intCast(sig_item.entry_inst_idx));
        const end = if (idx + 1 < verified.function_sigs.len)
            @as(usize, @intCast(verified.function_sigs[idx + 1].entry_inst_idx))
        else
            verified.annotated.len;

        var instruction_count: u64 = 0;
        var byte_count: u64 = 0;
        if (start < end and end <= verified.annotated.len) {
            for (verified.annotated[start..end]) |item| {
                instruction_count += 1;
                byte_count += @as(u64, @intCast(item.base.raw_text.len));
            }
        }

        try entries.append(.{
            .name = sig_item.name,
            .instruction_count = instruction_count,
            .byte_count = byte_count,
        });
    }

    return try entries.toOwnedSlice();
}

const GraphBuildContext = struct {
    allocator: std.mem.Allocator,
    node_map: *std.StringHashMap(usize),
    nodes: *std.array_list.Managed(GraphNode),
    edges: *std.array_list.Managed(GraphEdge),
    dependencies: []const pkg_resolver.Dependency,
    plugin_import_roots: []const []const u8,
    project_root: []const u8,
    offline: bool,
};

fn graphNodeId(allocator: std.mem.Allocator, kind: []const u8, text: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ kind, text });
}

fn graphNodeKindName(kind: GraphNodeKind) []const u8 {
    return switch (kind) {
        .source_file => "source_file",
        .function => "function",
        .call_target => "call_target",
    };
}

fn graphEdgeKindName(kind: GraphEdgeKind) []const u8 {
    return switch (kind) {
        .imports => "imports",
        .calls => "calls",
    };
}

fn ensureGraphNode(ctx: *GraphBuildContext, id: []const u8, kind: GraphNodeKind, label: []const u8) !usize {
    if (ctx.node_map.get(id)) |index| {
        ctx.allocator.free(id);
        return index;
    }

    const key = try ctx.allocator.dupe(u8, id);
    errdefer ctx.allocator.free(key);
    const label_copy = try ctx.allocator.dupe(u8, label);
    errdefer ctx.allocator.free(label_copy);

    const index = ctx.nodes.items.len;
    try ctx.node_map.put(key, index);
    try ctx.nodes.append(.{
        .id = id,
        .kind = kind,
        .label = label_copy,
    });
    return index;
}

fn appendGraphEdge(ctx: *GraphBuildContext, from: []const u8, to: []const u8, kind: GraphEdgeKind) !void {
    try ctx.edges.append(.{ .from = from, .to = to, .kind = kind });
}

fn collectSourceGraph(ctx: *GraphBuildContext, source_path: []const u8) !usize {
    const source_id = try graphNodeId(ctx.allocator, "source", source_path);
    if (ctx.node_map.get(source_id)) |index| {
        ctx.allocator.free(source_id);
        return index;
    }

    const stable_source_id = try ensureGraphNode(ctx, source_id, .source_file, source_path);
    const source = try loadSource(ctx.allocator, source_path);
    defer ctx.allocator.free(source);

    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |line| {
        const classified = line_classifier.classifyLine(line);
        if (classified.kind != .import_decl) continue;
        const import_path = classified.parts[0];
        var imported = try pkg_resolver.resolveImport(ctx.allocator, ctx.dependencies, std.fs.path.dirname(source_path) orelse ".", import_path, .{
            .project_root = ctx.project_root,
            .offline = ctx.offline,
            .plugin_import_roots = ctx.plugin_import_roots,
        });
        defer imported.deinit(ctx.allocator);

        const child_index = try collectSourceGraph(ctx, imported.entry_path);
        try appendGraphEdge(ctx, ctx.nodes.items[stable_source_id].id, ctx.nodes.items[child_index].id, .imports);
    }

    return stable_source_id;
}

fn buildFunctionGraph(ctx: *GraphBuildContext, verified: *const referee.VerifyOk) !std.StringHashMap(usize) {
    var function_nodes = std.StringHashMap(usize).init(ctx.allocator);
    errdefer function_nodes.deinit();

    for (verified.function_sigs) |sig_item| {
        const node_id = try graphNodeId(ctx.allocator, "function", sig_item.name);
        const index = try ensureGraphNode(ctx, node_id, .function, sig_item.name);
        try function_nodes.put(sig_item.name, index);
    }

    return function_nodes;
}

fn buildCallGraph(
    ctx: *GraphBuildContext,
    verified: *const referee.VerifyOk,
    function_nodes: *const std.StringHashMap(usize),
) !void {
    var current_fn: ?usize = null;
    var sig_index: usize = 0;

    for (verified.annotated) |item| {
        switch (item.base.kind) {
            .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
                if (sig_index >= verified.function_sigs.len) break;
                const sig_item = verified.function_sigs[sig_index];
                sig_index += 1;
                current_fn = function_nodes.get(sig_item.name);
            },
            .call, .call_indirect => {
                const caller_index = current_fn orelse continue;
                var parsed = referee_call.parseCall(ctx.allocator, item.base.raw_text) catch continue;
                defer parsed.deinit(ctx.allocator);

                const target_index = if (function_nodes.get(parsed.callee)) |fn_idx| blk: {
                    break :blk fn_idx;
                } else blk: {
                    const call_target_id = try graphNodeId(ctx.allocator, "target", parsed.callee);
                    break :blk try ensureGraphNode(ctx, call_target_id, .call_target, parsed.callee);
                };
                try appendGraphEdge(ctx, ctx.nodes.items[caller_index].id, ctx.nodes.items[target_index].id, .calls);
            },
            else => {},
        }
    }
}

fn writeGraphJson(writer: anytype, metrics: CompileMetrics, nodes: []const GraphNode, edges: []const GraphEdge) !void {
    try writer.writeAll("{\"status\":\"ok\",\"metrics\":");
    try writeMetricsJson(writer, metrics);
    try writer.writeAll(",\"graph\":{\"nodes\":[");
    for (nodes, 0..) |node, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"id\":");
        try writeJsonString(writer, node.id);
        try writer.writeAll(",\"kind\":");
        try writeJsonString(writer, graphNodeKindName(node.kind));
        try writer.writeAll(",\"label\":");
        try writeJsonString(writer, node.label);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"edges\":[");
    for (edges, 0..) |edge, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"from\":");
        try writeJsonString(writer, edge.from);
        try writer.writeAll(",\"to\":");
        try writeJsonString(writer, edge.to);
        try writer.writeAll(",\"kind\":");
        try writeJsonString(writer, graphEdgeKindName(edge.kind));
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
}

fn writeGraphText(writer: anytype, metrics: CompileMetrics, nodes: []const GraphNode, edges: []const GraphEdge) !void {
    try writer.print("compile_tokens: {d}\n", .{metrics.compile_tokens});
    try writer.print("instruction_count: {d}\n", .{metrics.instruction_count});
    try writer.print("nodes: {d}\n", .{nodes.len});
    for (nodes) |node| {
        try writer.print("- {s} [{s}] {s}\n", .{ node.id, graphNodeKindName(node.kind), node.label });
    }
    try writer.print("edges: {d}\n", .{edges.len});
    for (edges) |edge| {
        try writer.print("- {s} -> {s} ({s})\n", .{ edge.from, edge.to, graphEdgeKindName(edge.kind) });
    }
}

fn writeSizeJson(writer: anytype, metrics: CompileMetrics, entries: []const FunctionSizeEntry) !void {
    try writer.writeAll("{\"status\":\"ok\",\"metrics\":");
    try writeMetricsJson(writer, metrics);
    try writer.writeAll(",\"functions\":[");
    for (entries, 0..) |entry, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"name\":");
        try writeJsonString(writer, entry.name);
        try writer.writeAll(",\"instruction_count\":");
        try writer.print("{d}", .{entry.instruction_count});
        try writer.writeAll(",\"byte_count\":");
        try writer.print("{d}", .{entry.byte_count});
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
}

fn writeSizeText(writer: anytype, metrics: CompileMetrics, entries: []const FunctionSizeEntry) !void {
    try writer.print("compile_tokens: {d}\n", .{metrics.compile_tokens});
    try writer.print("instruction_count: {d}\n", .{metrics.instruction_count});
    try writer.writeAll("functions:\n");
    for (entries) |entry| {
        try writer.print("- {s}: instructions={d} bytes={d}\n", .{ entry.name, entry.instruction_count, entry.byte_count });
    }
}

const CompileOptions = struct {
    jobs: ?usize = null,
    jobs_explicit: bool = false,
    dce: DceMode = .std,
    incremental_cache: bool = true,
    offline: bool = false,
    ci: bool = false,
    allow_unaudited_risks: bool = false,
    auto_approve_requested: bool = false,
    permission_set: ?[]const u8 = null,
    allow_env_requested: bool = false,
    allow_net_requested: bool = false,
    allow_read_requested: bool = false,
    allow_write_requested: bool = false,
    allow_run_requested: bool = false,
    package_name: ?[]const u8 = null,
    project_root: ?[]const u8 = null,
    profile: bool = false,
    mem_report: bool = false,
    mem_report_live: bool = false,
    stdin_reader: ?*std.Io.Reader = null,
    stdin_is_tty: ?bool = null,
    diagnostic_writer: ?*std.Io.Writer = null,
    sab_selected_test_names: []const []const u8 = &.{},
    sab_skip_verify: bool = false,
    target_triple: ?[]const u8 = null,
    // sci-rust Rust edition switches (default: legacy mutable behavior).
    default_immutable: bool = false,
    rust_strict_mut: bool = false,
    rust_copy_elision: bool = false,
    rust_edition: bool = false,
};

const TestCommandOptions = struct {
    selection: test_meta.TestSelection,
    list: bool = false,
    compile_only: bool = false,
    trace_panic: bool = false,
    affected: bool = false,
    // Test binaries are dev-time artifacts: link with zero optimization by
    // default; --release-small/--release-fast opt in to LLVM optimization.
    optimization: driver.Optimization = .none,
};

pub const DiagnosticsMode = enum {
    human,
    json,
};

pub const ExplainEntry = struct {
    codes: []const []const u8,
    title: []const u8,
    summary: []const u8,
    details: []const []const u8,
    fix_hint: ?[]const u8 = null,
};

pub const FixPlanStep = struct {
    action: []const u8,
    target: []const u8,
    detail: []const u8,
};

pub const FixPlan = struct {
    steps: []const FixPlanStep,
    rationale: []const []const u8,
};

pub const SkillSection = struct {
    name: []const u8,
    summary: []const u8,
    items: []const []const u8,
};

const SaStdSurface = struct {
    files: []const []const u8,
    macros: []const []const u8,
    externs: []const []const u8,

    fn deinit(self: SaStdSurface, allocator: std.mem.Allocator) void {
        freeOwnedStringSlice(allocator, self.files);
        freeOwnedStringSlice(allocator, self.macros);
        freeOwnedStringSlice(allocator, self.externs);
    }
};

const SaPluginsSurface = struct {
    root: ?[]const u8,
    plugins: []const []const u8,
    declarations: []const []const u8,
    notes: []const []const u8,

    fn deinit(self: SaPluginsSurface, allocator: std.mem.Allocator) void {
        if (self.root) |root| allocator.free(root);
        freeOwnedStringSlice(allocator, self.plugins);
        freeOwnedStringSlice(allocator, self.declarations);
        freeOwnedStringSlice(allocator, self.notes);
    }
};

const AgentSkillPaths = struct {
    sa_codex: []const u8,
    sa_claude: []const u8,
    plugins_codex: []const u8,
    plugins_claude: []const u8,

    fn deinit(self: AgentSkillPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.sa_codex);
        allocator.free(self.sa_claude);
        allocator.free(self.plugins_codex);
        allocator.free(self.plugins_claude);
    }
};

const OwnedPluginRuntimeAuthorization = struct {
    input: plugins.RuntimeAuthorizationInput = .{},
    env: []const []const u8 = &.{},
    read: []const []const u8 = &.{},
    write: []const []const u8 = &.{},
    net: []const []const u8 = &.{},
    run: []const []const u8 = &.{},
    project_root: ?[]u8 = null,

    fn deinit(self: *OwnedPluginRuntimeAuthorization, allocator: std.mem.Allocator) void {
        for (self.env) |entry| allocator.free(entry);
        allocator.free(self.env);
        for (self.read) |entry| allocator.free(entry);
        allocator.free(self.read);
        for (self.write) |entry| allocator.free(entry);
        allocator.free(self.write);
        for (self.net) |entry| allocator.free(entry);
        allocator.free(self.net);
        for (self.run) |entry| allocator.free(entry);
        allocator.free(self.run);
        if (self.project_root) |root| allocator.free(root);
        self.* = undefined;
    }
};

const CliErrorInfo = struct {
    code: ?[]const u8,
    message: []const u8,
    hint: ?[]const u8,
};

const Command = enum {
    run,
    init,
    install,
    plugin,
    pkg,
    cache,
    build,
    build_workspace,
    build_exe,
    build_wasm,
    build_js,
    build_c,
    build_obj,
    bc2sa,
    audit,
    check,
    graph,
    layout,
    fetch,
    size,
    test_cmd,
    explain,
    fix,
    skills,
    daemon,
    help,
    version,
};

pub fn hasJsonFlag(argv: []const []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

fn stripJsonFlag(allocator: std.mem.Allocator, argv: []const []const u8) ![]const []const u8 {
    var items = std.array_list.Managed([]const u8).init(allocator);
    errdefer items.deinit();

    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--json")) continue;
        try items.append(arg);
    }

    return try items.toOwnedSlice();
}

const ProjectTargetKind = enum {
    native,
    wasm32,
    wasm64,
};

const ProjectTarget = struct {
    kind: ProjectTargetKind,
    name: []const u8,
    output_suffix: []const u8,
    source_suffix: []const u8,
    wasm: ?WasmTarget = null,
    size_bits: u16,
};

const AuditHit = struct {
    capability: manifest.Capability,
    callee: []const u8,
    raw_text: []const u8,
    source_line: u32,
    upstream_loc: ?common_upstream.UpstreamLoc,

    fn deinit(self: *AuditHit, allocator: std.mem.Allocator) void {
        if (self.upstream_loc) |loc| allocator.free(loc.file);
        allocator.free(self.callee);
        allocator.free(self.raw_text);
        self.* = undefined;
    }
};

const PackageAudit = struct {
    identity: []const u8,
    ref: []const u8,
    source_sha256: [32]u8,
    declared_grants: []const manifest.Capability,
    hits: std.array_list.Managed(AuditHit),
    requested_caps: std.array_list.Managed(manifest.Capability),
    risk_score: u8 = 100,
    approved_hash: ?[32]u8 = null,
    source_sha_matches: bool = true,
    lock_present: bool = false,
    lock_hash_matches: bool = false,

    fn deinit(self: *PackageAudit, allocator: std.mem.Allocator) void {
        for (self.hits.items) |*hit| hit.deinit(allocator);
        self.hits.deinit();
        allocator.free(self.identity);
        allocator.free(self.ref);
        allocator.free(self.declared_grants);
        self.requested_caps.deinit();
        self.* = undefined;
    }
};

const AuditReport = struct {
    packages: std.array_list.Managed(PackageAudit),
    fn deinit(self: *AuditReport, allocator: std.mem.Allocator) void {
        for (self.packages.items) |*item| item.deinit(allocator);
        self.packages.deinit();
        self.* = undefined;
    }
};

const ProjectAuditResult = union(enum) {
    ok: AuditReport,
    trap: trap.TrapReport,
};

const TemporaryApproval = struct {
    url: []const u8,
    ref: []const u8,
    source_sha256: [32]u8,
    grants: []const manifest.Capability,
};

const ProjectBuildOptions = struct {
    ci: bool = false,
    allow_unaudited_risks: bool = false,
    offline: bool = false,
    all_targets: bool = false,
    lock_only: bool = false,
    debug: bool = false,
    release_fast: bool = false,
    out_path: ?[]const u8 = null,
    jobs: ?usize = null,
};

const ProjectAuditOptions = struct {
    update_lock: bool = false,
    offline: bool = false,
    all_targets: bool = false,
    jobs: ?usize = null,
};

const ProjectBuildArtifact = struct {
    name: []const u8,
    out_path: []const u8,
    artifact_path: []const u8,
    target_name: []const u8,
    source_suffix: []const u8,
    hash_key: []const u8,

    fn deinit(self: *ProjectBuildArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.out_path);
        allocator.free(self.artifact_path);
        allocator.free(self.target_name);
        allocator.free(self.source_suffix);
        allocator.free(self.hash_key);
        self.* = undefined;
    }
};

const ProjectContext = struct {
    root_path: []const u8,
    member_root_path: []const u8,
    workspace_manifest_path: []const u8,
    member_manifest_path: []const u8,
    manifest: ?manifest.Manifest,
    workspace_manifest: ?manifest.Manifest,
    member_manifest: ?manifest.Manifest,
    lock_file: ?manifest.LockFile,
    sum_file: ?manifest.SumFile,

    fn deinit(self: *ProjectContext, allocator: std.mem.Allocator) void {
        if (self.manifest) |*m| m.deinit(allocator);
        if (self.workspace_manifest) |*m| m.deinit(allocator);
        if (self.member_manifest) |*m| m.deinit(allocator);
        if (self.lock_file) |*lock| lock.deinit(allocator);
        if (self.sum_file) |*sum| sum.deinit(allocator);
        allocator.free(self.root_path);
        allocator.free(self.member_root_path);
        allocator.free(self.workspace_manifest_path);
        allocator.free(self.member_manifest_path);
        self.* = undefined;
    }
};

const WasmTarget = struct {
    triple: []const u8,
    no_entry: bool,
    size_bits: u16,
};

fn nativeSizeBits() u16 {
    return @as(u16, @bitSizeOf(usize));
}

/// Pointer size for a cross-compilation triple (zig-style arch-os-abi).
/// Unknown triples default to 64-bit.
fn sizeBitsForTriple(triple: ?[]const u8) u16 {
    const t = triple orelse return nativeSizeBits();
    const arch = if (std.mem.indexOfScalar(u8, t, '-')) |i| t[0..i] else t;
    for ([_][]const u8{ "wasm32", "i386", "i486", "i586", "i686", "arm", "armeb", "thumb", "riscv32", "mips", "mipsel", "mips64el", "powerpc", "sparc", "sparcel", "s390", "xcore", "nvptx", "amdgcn", "bpfel", "bpfeb", "csky", "hexagon", "m68k", "msp430", "avr", "arc", "xtensa" }) |a32| {
        if (std.mem.eql(u8, arch, a32)) return 32;
    }
    return 64;
}

fn tripleIsWindows(triple: ?[]const u8) bool {
    const t = triple orelse return builtin.os.tag == .windows;
    return std.mem.indexOf(u8, t, "windows") != null;
}

fn executableSuffixForTriple(triple: ?[]const u8) []const u8 {
    return if (tripleIsWindows(triple)) ".exe" else "";
}

fn boolEnv(name: []const u8) bool {
    const value = sio.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(value);
    return value.len != 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false") and !std.mem.eql(u8, value, "False");
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

    pub fn takeDelimiterExclusive(self: StdinLineReader, delimiter: u8) ![]u8 {
        return try self.inner.takeDelimiterExclusive(delimiter);
    }
};

fn isCiMode(options: ProjectBuildOptions) bool {
    return options.ci or boolEnv("CI") or boolEnv("GITHUB_ACTIONS") or !stdinIsTty();
}

fn isProjectRootPath(path: []const u8) bool {
    return std.fs.path.basename(path).len != 0;
}

fn projectRootDir(allocator: std.mem.Allocator) ![]u8 {
    return sio.cwd().realpathAlloc(allocator, ".") catch return error.InvalidPath;
}

fn pathJoinAlloc(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return try std.fs.path.join(allocator, parts);
}

fn projectPathExists(path: []const u8) bool {
    sio.cwd().access(path, .{}) catch return false;
    return true;
}

fn readTextFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try sio.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
}

fn readManifestTextFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try sio.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, manifest.max_manifest_bytes);
}

fn projectManifestPath(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
    return try pathJoinAlloc(allocator, &.{ root_path, "sa.mod" });
}

fn projectLockPath(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
    return try pathJoinAlloc(allocator, &.{ root_path, "sa.lock" });
}

fn projectSumPath(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
    return try pathJoinAlloc(allocator, &.{ root_path, "sa.sum" });
}

fn projectSourcePath(allocator: std.mem.Allocator, root_path: []const u8, package_name: ?[]const u8) ![]u8 {
    var resolved = try pkg_workspace.resolveFromRootPath(allocator, root_path, .{ .request = package_name });
    defer resolved.deinit(allocator);
    return try pkg_workspace.selectedSourcePath(allocator, &resolved);
}

fn readManifestFile(allocator: std.mem.Allocator, path: []const u8) !manifest.Manifest {
    const source = try readManifestTextFileAlloc(allocator, path);
    defer allocator.free(source);
    return try manifest.parseManifestWithFile(allocator, source, path);
}

fn readLockFile(allocator: std.mem.Allocator, path: []const u8) !?manifest.LockFile {
    const source = sio.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer source.close();
    const bytes = try source.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    return try manifest.parseLock(allocator, bytes);
}

fn readSumFile(allocator: std.mem.Allocator, path: []const u8) !?manifest.SumFile {
    const source = sio.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer source.close();
    const bytes = try source.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    return try manifest.parseSum(allocator, bytes);
}

fn loadProjectContext(allocator: std.mem.Allocator, root_path: []const u8, package_name: ?[]const u8) !ProjectContext {
    const resolution = try pkg_workspace.resolveFromRootPath(allocator, root_path, .{ .request = package_name });

    var ctx = ProjectContext{
        .root_path = resolution.workspace_root,
        .member_root_path = resolution.member_root,
        .workspace_manifest_path = resolution.workspace_manifest_path,
        .member_manifest_path = resolution.member_manifest_path,
        .manifest = resolution.effective_manifest,
        .workspace_manifest = resolution.workspace_manifest,
        .member_manifest = resolution.member_manifest,
        .lock_file = null,
        .sum_file = null,
    };
    errdefer ctx.deinit(allocator);
    if (resolution.selected_package) |name| allocator.free(name);
    if (resolution.workspace_rel_member_path) |path| allocator.free(path);

    const lock_path = try projectLockPath(allocator, ctx.root_path);
    defer allocator.free(lock_path);
    if (try readLockFile(allocator, lock_path)) |lock_file| {
        ctx.lock_file = lock_file;
    }

    const sum_path = try projectSumPath(allocator, ctx.root_path);
    defer allocator.free(sum_path);
    if (try readSumFile(allocator, sum_path)) |sum_file| {
        ctx.sum_file = sum_file;
    }

    return ctx;
}

fn sourceHashHex(hash: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(hash, .lower);
}

fn hashBytes(bytes: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn hashFileHex(allocator: std.mem.Allocator, path: []const u8) ![64]u8 {
    _ = allocator;
    var file = try sio.cwd().openFile(path, .{});
    defer file.close();
    return try hashOpenFileHex(&file);
}

fn hashDirFileHex(dir: sio.Dir, name: []const u8) ![64]u8 {
    var file = try dir.openFile(name, .{});
    defer file.close();
    return try hashOpenFileHex(&file);
}

fn hashOpenFileHex(file: *sio.File) ![64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return sourceHashHex(out);
}

fn sourceStem(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return basename;
    return basename[0..dot];
}

fn projectTargetKey(allocator: std.mem.Allocator, target_name: []const u8, source_suffix: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ target_name, source_suffix });
}

fn projectTargetDisplayName(allocator: std.mem.Allocator, target_name: []const u8, source_suffix: []const u8) ![]u8 {
    if (source_suffix.len == 0) return try allocator.dupe(u8, target_name);
    return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ target_name, source_suffix });
}

fn targetTripleName(target: builtin.Target) ![]u8 {
    return try target.zigTriple(std.heap.page_allocator);
}

fn emitSumFromManifest(allocator: std.mem.Allocator, manifest_file: *const manifest.Manifest) !manifest.SumFile {
    var entries = std.array_list.Managed(manifest.SumEntry).init(allocator);
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit();
    }

    for (manifest_file.requires) |entry| {
        try entries.append(.{
            .url = try allocator.dupe(u8, entry.url),
            .ref = try allocator.dupe(u8, entry.ref),
            .source_sha256 = entry.source_sha256,
            .depth = 0,
        });
    }

    std.sort.insertion(manifest.SumEntry, entries.items, {}, struct {
        fn lessThan(_: void, lhs: manifest.SumEntry, rhs: manifest.SumEntry) bool {
            const order = std.mem.order(u8, lhs.url, rhs.url);
            if (order != .eq) return order == .lt;
            return std.mem.order(u8, lhs.ref, rhs.ref) == .lt;
        }
    }.lessThan);

    return .{ .entries = try entries.toOwnedSlice() };
}

fn targetHashKeyForName(allocator: std.mem.Allocator, name: []const u8, source_suffix: []const u8) ![]const u8 {
    return try projectTargetKey(allocator, name, source_suffix);
}

fn computeArtifactHash(source_path: []const u8, source_bytes: []const u8, target_name: []const u8, source_suffix: []const u8, out_path: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(source_path);
    hasher.update(&[_]u8{0});
    hasher.update(source_bytes);
    hasher.update(&[_]u8{0});
    hasher.update(target_name);
    hasher.update(&[_]u8{0});
    hasher.update(source_suffix);
    hasher.update(&[_]u8{0});
    hasher.update(out_path);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn commandName(cmd: Command) []const u8 {
    return switch (cmd) {
        .build => "build",
        .build_workspace => "build-workspace",
        .run => "run",
        .init => "init",
        .install => "install",
        .plugin => "plugin",
        .pkg => "pkg",
        .cache => "cache",
        .build_exe => "build-exe",
        .build_wasm => "build-wasm",
        .build_js => "build-js",
        .build_c => "build-c",
        .build_obj => "build-obj",
        .bc2sa => "bc2sa",
        .audit => "audit",
        .check => "check",
        .graph => "graph",
        .fetch => "fetch",
        .layout => "layout",
        .size => "size",
        .test_cmd => "test",
        .explain => "explain",
        .fix => "fix",
        .skills => "skills",
        .daemon => "daemon",
        .help => "help",
        .version => "version",
    };
}

fn commandFromName(name: []const u8) ?Command {
    inline for (std.meta.tags(Command).*) |cmd| {
        if (std.mem.eql(u8, name, commandName(cmd))) return cmd;
    }
    return null;
}

fn commandSupported(name: []const u8) bool {
    return commandFromName(name) != null;
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn commandHelpRequested(cmd: Command, args: []const []const u8) bool {
    if (args.len < 3) return false;
    if (isHelpFlag(args[2])) return true;
    return switch (cmd) {
        .pkg, .plugin, .cache => args.len >= 4 and isHelpFlag(args[3]),
        else => false,
    };
}

fn writeCompileOptionsHelp(writer: anytype) !void {
    try writer.writeAll("  --jobs auto|N                  Set parallel compile jobs\n");
    try writer.writeAll("  --dce no|std|full              Select dead-code elimination level\n");
    try writer.writeAll("  --no-incremental               Disable the default project build cache\n");
    try writer.writeAll("  --project-root <dir>           Use a specific project root for package resolution and .sa_cache\n");
    try writer.writeAll("  --profile                      Include compile phase timings in JSON metrics\n");
    try writer.writeAll("  --mem-report                   Print compile RSS stage samples; JSON mode includes metrics\n");
    try writer.writeAll("  --offline                      Use local package cache only\n");
    try writer.writeAll("  --ci                           Use CI package preflight behavior\n");
    try writer.writeAll("  --allow-unaudited-risks        Allow high-risk package audit findings\n");
    try writer.writeAll("  --yes, --auto-approve          Approve package review prompts when allowed\n");
    try writer.writeAll("  -p, --package <name>           Select a workspace member package\n");
    try writer.writeAll("  -P, --permission-set <name>    Select a named permission set\n");
    try writer.writeAll("  --allow-env[=list]             Allow environment access for reviewed packages\n");
    try writer.writeAll("  --allow-net[=list]             Allow network access for reviewed packages\n");
    try writer.writeAll("  --allow-read[=list]            Allow filesystem reads for reviewed packages\n");
    try writer.writeAll("  --allow-write[=list]           Allow filesystem writes for reviewed packages\n");
    try writer.writeAll("  --allow-run[=list]             Allow process execution for reviewed packages\n");
    try writer.writeAll("  --default-immutable            Rust edition: alloc defaults to Active|Immutable\n");
    try writer.writeAll("  --rust-strict-mut              Rust edition: require explicit &mut for exclusive borrow\n");
    try writer.writeAll("  --rust-copy-elision            Rust edition: scalar Copy values skip release tracking\n");
    try writer.writeAll("  --edition rust                 Enable full Rust edition (all three switches above)\n");
}

fn writeBuildOptionsHelp(writer: anytype, artifact: []const u8, include_incremental: bool) !void {
    try writer.print("  -o <path>                      Write {s} to path\n", .{artifact});
    try writer.writeAll("  -g                             Include debug information\n");
    try writer.writeAll("  --no-debug                     Disable debug information\n");
    try writer.writeAll("  --release-small                Optimize for small release output\n");
    try writer.writeAll("  --release-fast                 Optimize for fast release output\n");
    try writer.writeAll("  --target <triple>              Cross-compile for a zig-style target triple (e.g. aarch64-linux-gnu)\n");
    if (include_incremental) try writer.writeAll("  --incremental                  Reuse per-function cached objects when building .o\n");
    try writeCompileOptionsHelp(writer);
}

fn printPkgHelp(writer: anytype, args: []const []const u8) !void {
    const sub = if (args.len != 0 and !isHelpFlag(args[0])) args[0] else "";
    if (std.mem.eql(u8, sub, "install")) {
        try writer.writeAll("usage: sars pkg install [options] [identity]\n\n");
        try writer.writeAll("Fetch project dependencies from sa.mod, or fetch one package identity.\n\n");
        try writer.writeAll("Options:\n");
        try writer.writeAll("  --offline                      Use local package cache only\n");
        try writer.writeAll("  -g                             Install into the global package cache\n");
        try writer.writeAll("  -p, --package <name>           Install one workspace member package\n");
        try writer.writeAll("  --ref <ref>                    Fetch a specific package ref\n");
        try writer.writeAll("  -h, --help                     Show this help message\n");
        return;
    }
    if (std.mem.eql(u8, sub, "fetch")) {
        try writer.writeAll("usage: sars pkg fetch [options] <identity>\n\n");
        try writer.writeAll("Fetch and cache one package identity.\n\n");
        try writer.writeAll("Options:\n");
        try writer.writeAll("  --offline                      Use local package cache only\n");
        try writer.writeAll("  -g                             Install into the global package cache\n");
        try writer.writeAll("  --ref <ref>                    Fetch a specific package ref\n");
        try writer.writeAll("  -h, --help                     Show this help message\n");
        return;
    }
    if (std.mem.eql(u8, sub, "audit")) {
        try writer.writeAll("usage: sars pkg audit [options] <identity>\n\n");
        try writer.writeAll("Audit a package source tree and report required capabilities.\n\n");
        try writer.writeAll("Options:\n");
        try writer.writeAll("  --format text|json             Select report format\n");
        try writer.writeAll("  --json                         Emit JSON report\n");
        try writer.writeAll("  --ci                           Fail on CI policy violations\n");
        try writer.writeAll("  --allow-unaudited-risks        Allow high-risk audit findings\n");
        try writer.writeAll("  --update-lock                  Update project package lock metadata\n");
        try writer.writeAll("  --ref <ref>                    Audit a specific package ref\n");
        try writer.writeAll("  -h, --help                     Show this help message\n");
        return;
    }

    try writer.writeAll("usage: sars pkg <install|fetch|audit> [options]\n\n");
    try writer.writeAll("Package fetch, audit, install, and lock commands.\n\n");
    try writer.writeAll("Subcommands:\n");
    try writer.writeAll("  install                        Fetch project dependencies or one identity\n");
    try writer.writeAll("  fetch                          Fetch and cache one identity\n");
    try writer.writeAll("  audit                          Audit package capabilities and risk\n");
    try writer.writeAll("\nUse `sa pkg <subcommand> --help` for subcommand options.\n");
}

fn printCacheHelp(writer: anytype, args: []const []const u8) !void {
    const sub = if (args.len != 0 and !isHelpFlag(args[0])) args[0] else "";
    if (std.mem.eql(u8, sub, "clean")) {
        try writer.writeAll("usage: sars cache clean [options]\n\n");
        try writer.writeAll("Remove invalid, incomplete, or expired project cache entries from .sa_cache.\n\n");
        try writer.writeAll("Options:\n");
        try writer.writeAll("  --dry-run                      Report removals without deleting files\n");
        try writer.writeAll("  --max-age-days <n>             Remove complete entries older than n days (default: 30)\n");
        try writer.writeAll("  -h, --help                     Show this help message\n");
        return;
    }

    try writer.writeAll("usage: sars cache <clean> [options]\n\n");
    try writer.writeAll("Inspect and clean project-local SA build/test caches.\n\n");
    try writer.writeAll("Subcommands:\n");
    try writer.writeAll("  clean                          Remove invalid or expired .sa_cache entries\n");
    try writer.writeAll("\nUse `sa cache <subcommand> --help` for subcommand options.\n");
}

fn printPluginHelp(writer: anytype, args: []const []const u8) !void {
    const sub = if (args.len != 0 and !isHelpFlag(args[0])) args[0] else "";
    if (std.mem.eql(u8, sub, "install")) {
        try writer.writeAll("usage: sars plugin install [--dev] [--review] <path|sap.json>\n\n");
        try writer.writeAll("Build, verify, and install a native SA plugin project.\n\n");
        try writer.writeAll("Options:\n");
        try writer.writeAll("  --dev                          Allow development-mode install checks\n");
        try writer.writeAll("  --review                       Force review output before install\n");
        try writer.writeAll("  -h, --help                     Show this help message\n");
        return;
    }
    if (std.mem.eql(u8, sub, "list")) {
        try writer.writeAll("usage: sars plugin list\n\n");
        try writer.writeAll("List installed native SA plugins.\n\n");
        try writer.writeAll("Options:\n");
        try writer.writeAll("  -h, --help                     Show this help message\n");
        return;
    }

    try writer.writeAll("usage: sars plugin <install|list> [options]\n\n");
    try writer.writeAll("Install and list native SA plugins.\n\n");
    try writer.writeAll("Subcommands:\n");
    try writer.writeAll("  install                        Install a plugin project or sap.json\n");
    try writer.writeAll("  list                           List installed plugins\n");
    try writer.writeAll("\nUse `sa plugin <subcommand> --help` for subcommand options.\n");
}

fn printCommandHelp(writer: anytype, cmd: Command, args: []const []const u8) !void {
    switch (cmd) {
        .init => {
            try writer.writeAll("usage: sars init [path]\n\n");
            try writer.writeAll("Create a new SA binary project.\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .install => {
            try writer.writeAll("usage: sars install [options] [identity]\n\n");
            try writer.writeAll("Install project dependencies or one package identity. This is a compatibility alias for package install behavior.\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  --offline                      Use local package cache only\n");
            try writer.writeAll("  -g                             Install into the global package cache\n");
            try writer.writeAll("  -p, --package <name>           Install one workspace member package\n");
            try writer.writeAll("  --ref <ref>                    Fetch a specific package ref\n");
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .plugin => try printPluginHelp(writer, args),
        .pkg => try printPkgHelp(writer, args),
        .cache => try printCacheHelp(writer, args),
        .build => {
            try writer.writeAll("usage: sars build <file> [options]\n\n");
            try writer.writeAll("Compile a .sa source file or .sab binary to a native executable.\n\n");
            try writer.writeAll("Options:\n");
            try writeBuildOptionsHelp(writer, "the executable", false);
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .build_workspace => {
            try writer.writeAll("usage: sars build-workspace [options]\n\n");
            try writer.writeAll("Build the selected workspace member from the current workspace root or member directory.\n\n");
            try writer.writeAll("Options:\n");
            try writeBuildOptionsHelp(writer, "the executable", false);
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .build_exe => {
            try writer.writeAll("usage: sars build-exe <file> [options]\n\n");
            try writer.writeAll("Build a standalone native executable. This is an alias for `sa build`.\n\n");
            try writer.writeAll("Options:\n");
            try writeBuildOptionsHelp(writer, "the executable", false);
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .build_obj => {
            try writer.writeAll("usage: sars build-obj <file> [options]\n\n");
            try writer.writeAll("Build a native object file from a .sa source file or .sab binary.\n\n");
            try writer.writeAll("Options:\n");
            try writeBuildOptionsHelp(writer, "the object file", true);
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .build_wasm => {
            try writer.writeAll("usage: sars build-wasm <file> [options]\n\n");
            try writer.writeAll("Build a WebAssembly module from a .sa source file or .sab binary.\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  --target wasm32|wasm64         Select the WebAssembly target\n");
            try writeBuildOptionsHelp(writer, "the wasm module", false);
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .build_js => {
            try writer.writeAll("usage: sars build-js <file> [options]\n\n");
            try writer.writeAll("Build a JavaScript module from a .sa source file or .sab binary (JS backend, coexists with LLVM).\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  --format esm|cjs              Select the JS module format (default: esm)\n");
            try writeBuildOptionsHelp(writer, "the js module", false);
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .build_c => {
            try writer.writeAll("usage: sars build-c <file> [options]\n\n");
            try writer.writeAll("Build a portable C file from a .sa source file or .sab binary (C backend, MVP).\n\n");
            try writer.writeAll("Options:\n");
            try writeBuildOptionsHelp(writer, "the c file", false);
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .run => {
            try writer.writeAll("usage: sars run <file> [compile-options] [args...]\n\n");
            try writer.writeAll("Compile and execute a .sa source file or .sab binary.\n\n");
            try writer.writeAll("Options:\n");
            try writeCompileOptionsHelp(writer);
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .fetch => {
            try writer.writeAll("usage: sars fetch <identity>\n\n");
            try writer.writeAll("Fetch and cache a remote package. This is a compatibility alias; prefer `sa pkg fetch`.\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .audit => {
            try writer.writeAll("usage: sars audit <identity>\n\n");
            try writer.writeAll("Compatibility alias for package audit. Prefer `sa pkg audit <identity>`.\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .graph => {
            try writer.writeAll("usage: sars graph [path] [options]\n\n");
            try writer.writeAll("Output a dependency and call graph for a source file or project.\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  --json                         Emit graph JSON\n");
            try writeCompileOptionsHelp(writer);
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .layout => {
            try writer.writeAll("usage: sars layout --name <TypeName> --fields <name:ty,...> [options]\n\n");
            try writer.writeAll("Compute and print struct layout information.\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  --name <TypeName>              Struct/type name to display\n");
            try writer.writeAll("  --fields <name:ty,...>         Comma-separated field list\n");
            try writer.writeAll("  --format text|json|debug|dict  Select output format\n");
            try writer.writeAll("  --target 32|64                 Select pointer width\n");
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .size => {
            try writer.writeAll("usage: sars size [path] [options]\n\n");
            try writer.writeAll("Print function size statistics for a source file or project.\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  --json                         Emit size data as JSON\n");
            try writeCompileOptionsHelp(writer);
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .test_cmd => {
            try writer.writeAll("usage: sars test <file> [options]\n\n");
            try writer.writeAll("Run @test blocks in a .sa source file.\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  --list                         List selected tests after frontend checks only\n");
            try writer.writeAll("  --compile-only                 Compile and link tests without running them\n");
            try writer.writeAll("  --trace-panic                  Include panic diagnostics on failed tests\n");
            try writer.writeAll("  --test-debug                   Alias for --trace-panic\n");
            try writer.writeAll("  --filter <pattern>             Include only matching tests (repeatable)\n");
            try writer.writeAll("  --skip <pattern>               Exclude matching tests (repeatable)\n");
            try writer.writeAll("  --exact                        Match test names exactly\n");
            try writer.writeAll("  --ignored                      Run only ignored tests\n");
            try writer.writeAll("  --include-ignored              Run all tests including ignored\n");
            try writer.writeAll("  --affected                     Run only tests impacted by changed functions\n");
            try writer.writeAll("  --release-small                Link test binaries with -O1 (default: -O0)\n");
            try writer.writeAll("  --release-fast                 Link test binaries with -O3 (default: -O0)\n");
            try writeCompileOptionsHelp(writer);
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .check => {
            try writer.writeAll("usage: sars check <file> [options]\n\n");
            try writer.writeAll("Flatten and verify a .sa/.sab file without codegen or linking.\n");
            try writer.writeAll("Uses the process/daemon-scoped verdict cache so unchanged streams skip re-verify.\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  --json                         Emit JSON report\n");
            try writer.writeAll("  --emit-sab <path>              Write the verified program as a .sab binary\n");
            try writeCompileOptionsHelp(writer);
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .bc2sa => {
            try writer.writeAll("usage: sars bc2sa <file.bc>\n\n");
            try writer.writeAll("Translate LLVM bitcode to SA assembly.\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .explain => {
            try writer.writeAll("usage: sars explain <code>\n\n");
            try writer.writeAll("Explain a diagnostic error code.\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  --json                         Emit explanation as JSON\n");
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .fix => {
            try writer.writeAll("usage: sars fix [--plan] <code>\n\n");
            try writer.writeAll("Suggest fixes for diagnostics.\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  --plan                         Print a deterministic fix plan\n");
            try writer.writeAll("  --json                         Emit fix plan as JSON\n");
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .skills => {
            try writer.writeAll("usage: sars skills [--json]\n\n");
            try writer.writeAll("List compiler and plugin skills/capabilities. Text mode also writes agent skills into the current directory.\n");
            try writer.writeAll("The generated SA skill scans the current sa_std root and records every .sa/.sal/.sai macro and extern/export declaration.\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  --json                         Emit skills as JSON\n");
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
        .daemon => {
            try writer.writeAll("usage: sars daemon [--socket path] [--max-workers N] [--per-agent-limit N]\n\n");
            try writer.writeAll("Run a persistent compile/verify/test server over a Unix socket.\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  --socket <path>                Unix socket path (default /tmp/sa-daemon.sock)\n");
            try writer.writeAll("  --max-workers <N>              Max concurrent request workers (default 8)\n");
            try writer.writeAll("  --per-agent-limit <N>          Max in-flight requests per agent_id (default 4)\n");
        },
        .help => {
            try writer.writeAll("usage: sars help [command]\n\n");
            try writer.writeAll("Show global help or help for one command.\n\n");
            try writer.writeAll("Examples:\n");
            try writer.writeAll("  sa help test\n");
            try writer.writeAll("  sa help pkg audit\n");
            try writer.writeAll("  sa test --help\n");
        },
        .version => {
            try writer.writeAll("usage: sars version\n\n");
            try writer.writeAll("Print the SA toolchain version.\n\n");
            try writer.writeAll("Options:\n");
            try writer.writeAll("  --version                      Print version and exit\n");
            try writer.writeAll("  -h, --help                     Show this help message\n");
        },
    }
}

fn printHelpTopic(writer: anytype, args: []const []const u8) !u8 {
    if (args.len == 0) {
        try printUsage(writer);
        return 0;
    }
    if (isHelpFlag(args[0])) {
        try printCommandHelp(writer, .help, &.{});
        return 0;
    }
    const cmd = commandFromName(args[0]) orelse {
        try writer.print("unknown help topic: {s}\n", .{args[0]});
        return 1;
    };
    try printCommandHelp(writer, cmd, args[1..]);
    return 0;
}

fn explainEntries() []const ExplainEntry {
    return &.{
        .{
            .codes = &.{ "ForbiddenSyntax", "SA-FLAT-001" },
            .title = "Flattening rejected surface syntax",
            .summary = "The flattener only accepts the SA linear instruction surface.",
            .details = &.{
                "Braces, if/else, while, for, and dotted property chains are rejected before verification.",
                "The frontend must lower structured control flow into labels, branches, and explicit register moves.",
            },
            .fix_hint = "Rewrite the source into labels and br/jmp blocks before flattening.",
        },
        .{
            .codes = &.{ "ImportResolutionFailed", "SA-FLAT-050" },
            .title = "Import could not be resolved",
            .summary = "The import path or package identity could not be matched to a source artifact.",
            .details = &.{
                "The resolver accepts source packages and pinned package identities.",
                "Ambiguous versions, rejected artifacts, and invalid paths all surface through the same public trap.",
            },
            .fix_hint = "Pin the package ref, fix the path, or depend on the source package instead of a precompiled artifact.",
        },
        .{
            .codes = &.{ "RegisterRedefinition", "SA-REF-010" },
            .title = "Live register re-bound",
            .summary = "A register that is still live cannot be assigned a second time without an explicit move or release.",
            .details = &.{
                "The referee checks register ownership and capability masks on every instruction.",
                "Rebinding a live register without consuming the previous value violates the linear ownership model.",
            },
            .fix_hint = "Rename the destination register or release/move the old value first.",
        },
        .{
            .codes = &.{ "UnknownRegister", "SA-REF-011" },
            .title = "Register used before declaration",
            .summary = "The verifier could not resolve the register name to a live slot.",
            .details = &.{
                "All register reads and writes must refer to a register introduced by a preceding instruction.",
                "Import-expanded code and macro-generated code must keep the same register namespace consistent.",
            },
            .fix_hint = "Declare the register earlier or thread the correct register name through the macro expansion.",
        },
        .{
            .codes = &.{"SA-CLI-001"},
            .title = "Missing required operand",
            .summary = "The CLI command needs a positional argument such as a source file or project path.",
            .details = &.{
                "The top-level dispatcher fails fast when no source or operand is provided.",
                "The same issue appears in build, run, test, and fetch subcommands when the target path is omitted.",
            },
            .fix_hint = "Pass the required file, path, or operand after the command.",
        },
    };
}

fn explainEntryForCode(code: []const u8) ?ExplainEntry {
    for (explainEntries()) |entry| {
        for (entry.codes) |alias| {
            if (std.mem.eql(u8, alias, code)) return entry;
        }
    }
    return null;
}

fn printTrapReport(writer: anytype, report: trap.TrapReport, mode: DiagnosticsMode) !void {
    switch (mode) {
        .human => {
            const function_text = textOrBuf(report.function, report.function_buf[0..]);
            const register_text = textOrBuf(report.register, report.register_buf[0..]);
            var source_text_buf: [256]u8 = std.mem.zeroes([256]u8);
            copyTextBuf(&source_text_buf, reportText(&report));
            const source_text = bufText(source_text_buf[0..]);
            try writer.print("error[{s}]: {s}\n", .{ trap.trapName(report.trap), report.message });
            if (function_text.len != 0) {
                try writer.print("  in function {s}\n", .{function_text});
            }
            try printUpstreamLocation(writer, report);
            if (source_text.len != 0) {
                if (report.source_line != 0) {
                    if (report.line != 0 and report.line != report.source_line) {
                        try writer.print("  line {d} (expanded {d}): {s}\n", .{ report.source_line, report.line, source_text });
                    } else {
                        try writer.print("  line {d}: {s}\n", .{ report.source_line, source_text });
                    }
                } else {
                    try writer.print("  source: {s}\n", .{source_text});
                }
            }
            if (register_text.len != 0) {
                try writer.print("  register: {s}\n", .{register_text});
            } else if (report.registers.len != 0) {
                try writer.writeAll("  registers:");
                for (report.registers) |name| {
                    try writer.print(" {s}", .{name});
                }
                try writer.writeByte('\n');
            }
            try printMaskState(writer, report);
            if (report.hint) |hint| {
                try writer.print("  help: {s}\n", .{hint});
            }
            if (report.repair_action) |action| {
                try writer.print("  repair: {s}\n", .{action});
                if (report.repair_hint) |hint| {
                    try writer.print("    hint: {s}\n", .{hint});
                }
                if (report.repair_confidence) |confidence| {
                    try writer.print("    confidence: {s}\n", .{confidence});
                }
            }
            try trap.writeJson(writer, report);
            try writer.writeByte('\n');
        },
        .json => {
            try writer.writeAll("{\"status\":\"error\",\"diagnostics\":[");
            try trap.writeJson(writer, report);
            try writer.writeAll("]}\n");
        },
    }
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll("usage: sars <command> [options]\n\n");
    try writer.writeAll("Commands:\n");
    try writer.writeAll("  init         [path]            Create a new SA binary project\n");
    try writer.writeAll("  pkg          <subcommand>      Package fetch, audit, install, and lock commands\n");
    try writer.writeAll("  plugin       <subcommand>      Install and list native SA plugins\n");
    try writer.writeAll("  cache        <subcommand>      Inspect and clean project-local caches\n");
    try writer.writeAll("  install      [identity]        Install project dependencies or one package (compat)\n");
    try writer.writeAll("  build        <file>            Compile a .sa/.sab source to a native executable\n");
    try writer.writeAll("  build-workspace                Build the selected workspace member executable\n");
    try writer.writeAll("  run          <file>            Compile and immediately execute a .sa/.sab file\n");
    try writer.writeAll("  build-exe    <file>            Build a standalone executable (alias for build)\n");
    try writer.writeAll("  build-obj    <file>            Build an object file (.o)\n");
    try writer.writeAll("  build-wasm   <file>            Build a WebAssembly module (.wasm)\n");
    try writer.writeAll("  build-js     <file>            Build a JavaScript module (.js, JS backend)\n");
    try writer.writeAll("  build-c      <file>            Build a portable C file (.c, C backend)\n");
    try writer.writeAll("  test         <file>            Run @test blocks in a .sa/.sab file\n");
    try writer.writeAll("  check        <file>            Flatten and verify without codegen\n");
    try writer.writeAll("  fetch        <url>             Fetch and cache a remote package (compat)\n");
    try writer.writeAll("  audit        <file>            Use `sa pkg audit` from the package plugin\n");
    try writer.writeAll("  graph        <path>            Output a dependency/call graph\n");
    try writer.writeAll("  layout       ...               Print struct layout information\n");
    try writer.writeAll("  size         <file>            Print function size statistics\n");
    try writer.writeAll("  bc2sa      <file>            Translate LLVM bitcode to SA assembly\n");
    try writer.writeAll("  explain      <code>            Explain a diagnostic error code\n");
    try writer.writeAll("  fix          <file>            Suggest fixes for diagnostics\n");
    try writer.writeAll("  skills                         List compiler skills and capabilities\n");
    try writer.writeAll("  daemon                         Run a persistent compile/verify server\n");
    try writer.writeAll("  help         [command]         Show this help message\n");
    try writer.writeAll("  version                        Print the SA toolchain version\n");
    try writer.writeAll("\nGlobal options:\n");
    try writer.writeAll("  --json                         Output diagnostics in JSON format\n");
    try writer.writeAll("  --profile                      Include compile phase timings in JSON metrics\n");
    try writer.writeAll("  --mem-report                   Print compile RSS stage samples; JSON mode includes metrics\n");
    try writer.writeAll("  --jobs auto|N                  Set the number of parallel compile jobs\n");
    try writer.writeAll("  --dce no|std|full              Select dead-code elimination level\n");
    try writer.writeAll("  --no-incremental               Disable the default project build cache\n");
    try writer.writeAll("  -h, --help                     Show this help message\n");
    try writer.writeAll("  --version                      Print version and exit\n");
    try writer.writeAll("\nTest flags:\n");
    try writer.writeAll("  --list                         List selected tests after frontend checks only\n");
    try writer.writeAll("  --compile-only                 Compile and link tests without running them\n");
    try writer.writeAll("  --trace-panic                  Include panic diagnostics on failed tests\n");
    try writer.writeAll("  --test-debug                   Alias for --trace-panic\n");
    try writer.writeAll("  --filter <pattern>             Include only matching tests (repeatable)\n");
    try writer.writeAll("  --skip <pattern>               Exclude matching tests (repeatable)\n");
    try writer.writeAll("  --exact                        Match test names exactly\n");
    try writer.writeAll("  --ignored                      Run only ignored tests\n");
    try writer.writeAll("  --include-ignored              Run all tests including ignored\n");
    try writer.writeAll("  --affected                     Run only tests impacted by changed functions\n");
}

fn printVersion(writer: anytype) !void {
    const ver = build_options.version;
    try writer.print("sars {s}\n", .{ver});
}

const TmpWorkDir = struct {
    dir: sio.Dir,
    parent_dir: sio.Dir,
    sub_path: [std.base64.standard.Encoder.calcSize(12)]u8,

    fn init() !TmpWorkDir {
        var random_bytes: [12]u8 = undefined;
        sio.io().random(&random_bytes);

        var sub_path: [std.base64.standard.Encoder.calcSize(12)]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&sub_path, &random_bytes);

        const cwd = sio.cwd();
        try cwd.makePath(".zig-cache");
        var cache_dir = try cwd.openDir(".zig-cache", .{});
        defer cache_dir.close();
        try cache_dir.makePath("tmp");
        var parent_dir = try cache_dir.openDir("tmp", .{});
        errdefer parent_dir.close();
        try parent_dir.makePath(&sub_path);
        const dir = try parent_dir.openDir(&sub_path, .{});
        return .{ .dir = dir, .parent_dir = parent_dir, .sub_path = sub_path };
    }

    fn cleanup(self: *TmpWorkDir) void {
        self.dir.close();
        self.parent_dir.deleteTree(&self.sub_path) catch |err| {
            // Temporary build directories are best-effort cleanup after the caller has finished using them.
            _ = @errorName(err);
        };
        self.parent_dir.close();
        self.* = undefined;
    }
};

fn writeFile(dir: sio.Dir, path: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn forbiddenHint(hit: flattener.ForbiddenHit) []const u8 {
    return switch (hit.token) {
        .brace_open, .brace_close => "remove brace syntax and flatten the control flow into labels and jumps",
        .keyword_if, .keyword_else, .keyword_while, .keyword_for => "replace control-flow keywords with labels and jmp/br instructions",
        .property_chain => "replace dotted property access with explicit SSA registers or constant expansion",
    };
}

fn lineContains(line: ?[]const u8, needle: []const u8) bool {
    return if (line) |text| std.mem.indexOf(u8, text, needle) != null else false;
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{X:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn writeMaybeJsonString(writer: anytype, value: ?[]const u8) !void {
    if (value) |text| {
        try writeJsonString(writer, text);
    } else {
        try writer.writeAll("null");
    }
}

fn copyContextLine(report: *trap.TrapReport, idx: usize, line_no: u32, text: []const u8) void {
    if (idx >= report.context.len) return;
    report.context[idx].line = line_no;
    report.context[idx].text = null;
    report.context[idx].text_buf = std.mem.zeroes([256]u8);
    copyTextBuf(&report.context[idx].text_buf, std.mem.trimEnd(u8, text, "\r"));
}

fn copyBadToken(report: *trap.TrapReport, token: []const u8) void {
    report.bad_token = null;
    report.bad_token_buf = std.mem.zeroes([64]u8);
    copyTextBuf(&report.bad_token_buf, token);
}

fn setFile(report: *trap.TrapReport, source_path: []const u8) void {
    report.file = null;
    report.file_buf = std.mem.zeroes([128]u8);
    copyTextBuf(&report.file_buf, source_path);
}

fn setContextFromLine(report: *trap.TrapReport, line_no: u32, text: ?[]const u8) void {
    if (text) |line| {
        copyContextLine(report, 0, line_no, line);
        report.context_len = 1;
    }
}

fn setRepairAlternatives(report: *trap.TrapReport, alternatives: []const []const u8) void {
    const limit = @min(report.repair_alternatives.len, alternatives.len);
    report.repair_alternatives_len = @intCast(limit);
    for (0..limit) |idx| {
        report.repair_alternatives[idx] = null;
        report.repair_alternatives_buf[idx] = std.mem.zeroes([64]u8);
        copyTextBuf(&report.repair_alternatives_buf[idx], alternatives[idx]);
        const end = std.mem.indexOfScalar(u8, report.repair_alternatives_buf[idx][0..], 0) orelse alternatives[idx].len;
        report.repair_alternatives[idx] = report.repair_alternatives_buf[idx][0..end];
    }
}

fn firstBadTokenForTypeLine(line: ?[]const u8) ?[]const u8 {
    const text = line orelse return null;
    if (std.mem.indexOf(u8, text, "*")) |idx| {
        const tail = text[idx..];
        const end = std.mem.indexOfAny(u8, tail, " \t,)]}") orelse tail.len;
        return tail[0..end];
    }
    if (std.mem.indexOf(u8, text, "bool")) |_| return "bool";
    if (std.mem.indexOf(u8, text, "string")) |_| return "string";
    if (std.mem.indexOf(u8, text, "&")) |_| return "&";
    return null;
}

fn fillContextWindow(report: *trap.TrapReport, source: []const u8, center_line: u32) void {
    const start_line = if (center_line > 2) center_line - 2 else 1;
    var idx: usize = 0;
    var line_no = start_line;
    while (idx < report.context.len and line_no <= center_line + 2) : ({
        idx += 1;
        line_no += 1;
    }) {
        if (lineAt(source, line_no)) |line| {
            copyContextLine(report, idx, line_no, sourceExcerpt(line));
        }
    }
    report.context_len = @intCast(idx);
}

fn setLineText(report: *trap.TrapReport, text: []const u8) void {
    report.source_text = null;
    report.original_text = null;
    report.source_text_buf = std.mem.zeroes([256]u8);
    report.original_text_buf = std.mem.zeroes([256]u8);
    copyTextBuf(&report.source_text_buf, text);
    copyTextBuf(&report.original_text_buf, text);
}

fn unsupportedTypeHint(line: ?[]const u8) []const u8 {
    if (lineContains(line, "call @")) {
        return "inspect the callee declaration referenced by this call site; the unsupported annotation is usually in the imported signature";
    }
    if (lineContains(line, "@import")) {
        return "inspect the imported file for unsupported primitive names or ownership suffixes";
    }
    return "check the primitive type names and ownership suffixes in the declaration";
}

fn cliErrorInfo(err: anyerror) CliErrorInfo {
    return switch (err) {
        error.MissingSourcePath => .{
            .code = "SA-CLI-001",
            .message = "missing required positional argument",
            .hint = "pass the source file, project path, or required operand after the command",
        },
        error.MissingOutputPath => .{
            .code = "SA-CLI-002",
            .message = "missing output path after -o",
            .hint = "add a path after -o or omit -o to use the default output name",
        },
        error.MissingJobs => .{
            .code = "SA-CLI-003",
            .message = "missing job count after --jobs",
            .hint = "use --jobs auto or --jobs <positive integer>",
        },
        error.InvalidJobs => .{
            .code = "SA-CLI-004",
            .message = "invalid job count",
            .hint = "use --jobs auto or a positive integer",
        },
        error.MissingDceMode => .{
            .code = "SA-CLI-020",
            .message = "missing DCE mode after --dce",
            .hint = "use --dce no, --dce std, or --dce full",
        },
        error.InvalidDceMode => .{
            .code = "SA-CLI-021",
            .message = "invalid DCE mode",
            .hint = "use --dce no, --dce std, or --dce full",
        },
        error.MissingTarget => .{
            .code = "SA-CLI-005",
            .message = "missing target after --target",
            .hint = "use wasm32 or wasm64 after --target",
        },
        error.InvalidTarget => .{
            .code = "SA-CLI-006",
            .message = "invalid target",
            .hint = "use wasm32 or wasm64 after --target",
        },
        error.MissingFilterValue => .{
            .code = "SA-CLI-007",
            .message = "missing filter pattern",
            .hint = "pass a pattern after --filter or --skip",
        },
        error.MissingLayoutName => .{
            .code = "SA-CLI-008",
            .message = "missing layout name",
            .hint = "pass --name <TypeName>",
        },
        error.MissingLayoutFields => .{
            .code = "SA-CLI-009",
            .message = "missing layout fields",
            .hint = "pass --fields <name:ty,...>",
        },
        error.MissingLayoutFormat => .{
            .code = "SA-CLI-010",
            .message = "missing layout format",
            .hint = "use --format text, --format json, --format debug, or --format dict",
        },
        error.InvalidLayoutFormat => .{
            .code = "SA-CLI-011",
            .message = "invalid layout format",
            .hint = "use --format text, --format json, --format debug, or --format dict",
        },
        error.UnsupportedBitcodeInput => .{
            .code = "SA-CLI-012",
            .message = "unsupported bitcode input",
            .hint = "bc2sa expects real LLVM bitcode (.bc); text LLVM IR and non-bitcode files are rejected",
        },
        error.LlvmDisNotFound => .{
            .code = "SA-CLI-016",
            .message = "LLVM bitcode disassembler not found",
            .hint = "install llvm-dis-14/llvm-dis or clang and make one of them available on PATH before running bc2sa",
        },
        error.LlvmDisFailed => .{
            .code = "SA-CLI-017",
            .message = "llvm-dis failed",
            .hint = "verify the input is valid LLVM bitcode for the installed LLVM toolchain",
        },
        error.UnsupportedInstruction => .{
            .code = "SA-CLI-018",
            .message = "unsupported LLVM instruction",
            .hint = "bc2sa currently supports a conservative scalar/load-store/branch subset and rejects unsupported IR instead of emitting invalid SA",
        },
        error.StaticMemoryOverflow => .{
            .code = "SA-CLI-019",
            .message = "static memory overflow detected in LLVM bitcode",
            .hint = "reduce the constant GEP/index offset or widen the fixed-size array before translating",
        },
        error.UnknownCommand => .{
            .code = "SA-CLI-013",
            .message = "unknown command",
            .hint = "use build, build-workspace, run, build-exe, build-wasm, build-js, build-c, build-obj, pkg, cache, graph, layout, size, test, explain, fix, skills, bc2sa, help, or version",
        },
        error.UnexpectedArgument => .{
            .code = "SA-CLI-014",
            .message = "unexpected argument",
            .hint = "check option order and remove unsupported flags",
        },
        error.InvalidPath => .{
            .code = "SA-CLI-014",
            .message = "invalid path",
            .hint = "check the filesystem path and project root",
        },
        error.MissingRef => .{
            .code = "SA-CLI-015",
            .message = "missing package ref",
            .hint = "pass a ref value after --ref",
        },
        else => .{
            .code = null,
            .message = @errorName(err),
            .hint = null,
        },
    };
}

pub fn printCliError(writer: anytype, err: anyerror, mode: DiagnosticsMode) !void {
    const info = cliErrorInfo(err);
    switch (mode) {
        .human => {
            if (info.code) |code| {
                try writer.print("error[{s}]: {s}\n", .{ code, info.message });
            } else {
                try writer.print("error: {s}\n", .{info.message});
            }
            if (info.hint) |hint| {
                try writer.print("  help: {s}\n", .{hint});
            }
        },
        .json => {
            try writer.writeAll("{\"status\":\"error\",\"error\":{");
            try writer.writeAll("\"name\":");
            try writeJsonString(writer, @errorName(err));
            try writer.writeAll(",\"code\":");
            try writeMaybeJsonString(writer, info.code);
            try writer.writeAll(",\"message\":");
            try writeJsonString(writer, info.message);
            try writer.writeAll(",\"hint\":");
            try writeMaybeJsonString(writer, info.hint);
            try writer.writeAll("}}\n");
        },
    }
}

fn printLlvmcEmitError(writer: anytype, err: anyerror, mode: DiagnosticsMode) !void {
    if (err == error.Failed) {
        if (emit_llvm_llvmc.lastErrorMessage()) |message| {
            switch (mode) {
                .human => try writer.print("error[LLVMBackend]: {s}\n", .{message}),
                .json => {
                    try writer.writeAll("{\"status\":\"error\",\"error\":{");
                    try writer.writeAll("\"name\":\"LLVMBackend\",\"code\":\"SA-LLVM-001\",\"message\":");
                    try writeJsonString(writer, message);
                    try writer.writeAll(",\"hint\":\"configure LLVM-C support or rebuild with -Dllvm=true and valid LLVM paths\"}}\n");
                },
            }
            return;
        }
    }
    try printCliError(writer, err, mode);
}

fn importResolutionMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidImportPath => "invalid import path",
        error.PackageNotResolved => "import path could not be resolved",
        error.AmbiguousPackageVersion => "multiple package versions match this import",
        error.PrecompiledArtifactRejected => "precompiled artifact imports are not allowed",
        error.InvalidPath => "invalid path while resolving an import",
        else => "import resolution failed",
    };
}

fn importResolutionHint(line: ?[]const u8, err: anyerror) []const u8 {
    _ = line;
    return switch (err) {
        error.InvalidImportPath => "use a valid relative `.sa` or package identity without `../`, empty segments, or whitespace",
        error.PackageNotResolved => "check the import path, package identity, local vendor tree, and package cache",
        error.AmbiguousPackageVersion => "pin the required package ref in `sa.mod` so the resolver can choose one version",
        error.PrecompiledArtifactRejected => "depend on the source package instead of a precompiled artifact",
        error.InvalidPath => "check the project root or import path for filesystem errors",
        else => "check the import path, package identity, local vendor tree, and package cache",
    };
}

fn lineAt(source: []const u8, target_line: u32) ?[]const u8 {
    if (target_line == 0) return null;
    var iter = std.mem.splitScalar(u8, source, '\n');
    var line_no: u32 = 1;
    while (iter.next()) |line| : (line_no += 1) {
        if (line_no == target_line) return line;
    }
    return null;
}

fn sourceExcerpt(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

fn copyTextBuf(dest: []u8, text: []const u8) void {
    const len = @min(dest.len, text.len);
    std.mem.copyForwards(u8, dest[0..len], text[0..len]);
}

fn bufText(buf: []const u8) []const u8 {
    return buf[0..(std.mem.indexOfScalar(u8, buf, 0) orelse buf.len)];
}

fn textOrBuf(value: ?[]const u8, buf: []const u8) []const u8 {
    if (value) |text| return text;
    return bufText(buf);
}

fn reportText(report: *const trap.TrapReport) []const u8 {
    if (report.source_text) |text| return text;
    const source_fallback = bufText(report.source_text_buf[0..]);
    if (source_fallback.len != 0) return source_fallback;
    if (report.original_text) |text| return text;
    return bufText(report.original_text_buf[0..]);
}

fn printUpstreamLocation(writer: anytype, report: trap.TrapReport) !void {
    if (report.upstream_loc) |loc| {
        try writer.print("  upstream {s}:{d}:{d}\n", .{ loc.file, loc.line, loc.col });
        return;
    }

    const file = bufText(report.upstream_file_buf[0..]);
    if (file.len == 0) return;

    if (report.upstream_line != 0 and report.upstream_col != 0) {
        try writer.print("  upstream {s}:{d}:{d}\n", .{ file, report.upstream_line, report.upstream_col });
    } else if (report.upstream_line != 0) {
        try writer.print("  upstream {s}:{d}\n", .{ file, report.upstream_line });
    } else {
        try writer.print("  upstream {s}\n", .{file});
    }
}

fn printMaskState(writer: anytype, report: trap.TrapReport) !void {
    if (report.expected_mask_name) |expected| {
        if (report.actual_mask_name) |actual| {
            try writer.print("  state: expected {s}, actual {s}\n", .{ expected, actual });
            return;
        }
        try writer.print("  state: expected {s}\n", .{expected});
        return;
    }

    if (report.actual_mask_name) |actual| {
        try writer.print("  state: {s}\n", .{actual});
        return;
    }

    if (report.expected_mask) |expected| {
        if (report.actual_mask) |actual| {
            try writer.print("  state: expected {d}, actual {d}\n", .{ expected, actual });
            return;
        }
        try writer.print("  state: expected {d}\n", .{expected});
        return;
    }

    if (report.actual_mask) |actual| {
        try writer.print("  state: {d}\n", .{actual});
    }
}

fn writeMetricsJson(writer: anytype, metrics: CompileMetrics) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"compile_tokens\":");
    try writer.print("{d}", .{metrics.compile_tokens});
    try writer.writeAll(",\"instruction_count\":");
    try writer.print("{d}", .{metrics.instruction_count});
    if (metrics.phases) |phases| {
        try writer.writeAll(",\"phases_ns\":{");
        try writer.writeAll("\"load\":");
        try writer.print("{d}", .{phases.load_ns});
        try writer.writeAll(",\"setup\":");
        try writer.print("{d}", .{phases.setup_ns});
        try writer.writeAll(",\"flatten\":");
        try writer.print("{d}", .{phases.flatten_ns});
        try writer.writeAll(",\"verify\":");
        try writer.print("{d}", .{phases.verify_ns});
        if (phases.emit_ns) |ns| {
            try writer.writeAll(",\"emit\":");
            try writer.print("{d}", .{ns});
        }
        if (phases.link_ns) |ns| {
            try writer.writeAll(",\"link\":");
            try writer.print("{d}", .{ns});
        }
        if (phases.total_ns) |ns| {
            try writer.writeAll(",\"total\":");
            try writer.print("{d}", .{ns});
        }
        try writer.writeByte('}');
        try writer.writeAll(",\"phases_ms\":{");
        try writer.writeAll("\"load\":");
        try writer.print("{d}", .{phases.load_ns / 1_000_000});
        try writer.writeAll(",\"setup\":");
        try writer.print("{d}", .{phases.setup_ns / 1_000_000});
        try writer.writeAll(",\"flatten\":");
        try writer.print("{d}", .{phases.flatten_ns / 1_000_000});
        try writer.writeAll(",\"verify\":");
        try writer.print("{d}", .{phases.verify_ns / 1_000_000});
        if (phases.emit_ns) |ns| {
            try writer.writeAll(",\"emit\":");
            try writer.print("{d}", .{ns / 1_000_000});
        }
        if (phases.link_ns) |ns| {
            try writer.writeAll(",\"link\":");
            try writer.print("{d}", .{ns / 1_000_000});
        }
        if (phases.total_ns) |ns| {
            try writer.writeAll(",\"total\":");
            try writer.print("{d}", .{ns / 1_000_000});
        }
        try writer.writeByte('}');
    }
    if (metrics.memory) |memory| {
        try writer.writeAll(",\"memory\":{");
        try writer.writeAll("\"rss_bytes\":{");
        try writeOptionalJsonU64Field(writer, "start", memory.start_rss_bytes, true);
        try writeOptionalJsonU64Field(writer, "after_load", memory.after_load_rss_bytes, false);
        try writeOptionalJsonU64Field(writer, "after_setup", memory.after_setup_rss_bytes, false);
        try writeOptionalJsonU64Field(writer, "after_flatten", memory.after_flatten_rss_bytes, false);
        try writeOptionalJsonU64Field(writer, "after_verify", memory.after_verify_rss_bytes, false);
        try writeOptionalJsonU64Field(writer, "after_emit", memory.after_emit_rss_bytes, false);
        try writeOptionalJsonU64Field(writer, "after_link", memory.after_link_rss_bytes, false);
        try writeOptionalJsonU64Field(writer, "end", memory.end_rss_bytes, false);
        try writer.writeByte('}');
        try writer.writeAll(",\"verifier_rss_bytes\":{");
        try writeOptionalJsonU64Field(writer, "start", memory.verifier.start_rss_bytes, true);
        try writeOptionalJsonU64Field(writer, "after_classify", memory.verifier.after_classify_rss_bytes, false);
        try writeOptionalJsonU64Field(writer, "after_metadata", memory.verifier.after_metadata_rss_bytes, false);
        try writeOptionalJsonU64Field(writer, "after_chunks", memory.verifier.after_chunks_rss_bytes, false);
        try writeOptionalJsonU64Field(writer, "parallel_start", memory.verifier.parallel_start_rss_bytes, false);
        try writeOptionalJsonU64Field(writer, "parallel_after_worker_allocators", memory.verifier.parallel_after_worker_allocators_rss_bytes, false);
        try writeOptionalJsonU64Field(writer, "parallel_after_body", memory.verifier.parallel_after_body_rss_bytes, false);
        try writeOptionalJsonU64Field(writer, "parallel_merge", memory.verifier.parallel_merge_rss_bytes, false);
        try writeOptionalJsonU64Field(writer, "after_body", memory.verifier.after_body_rss_bytes, false);
        try writeOptionalJsonU64Field(writer, "after_finalize", memory.verifier.after_finalize_rss_bytes, false);
        try writeOptionalJsonU64Field(writer, "empty", memory.verifier.empty_rss_bytes, false);
        try writer.writeByte('}');
        try writer.writeAll(",\"peak_rss_bytes\":");
        try writeOptionalJsonU64(writer, memory.peak_rss_bytes);
        try writer.writeByte('}');
    }
    if (metrics.backend_ir) |ir| {
        try writer.writeAll(",\"backend\":{\"ir\":{");
        try writer.writeAll("\"functions\":");
        try writer.print("{d}", .{ir.functions});
        try writer.writeAll(",\"blocks\":");
        try writer.print("{d}", .{ir.blocks});
        try writer.writeAll(",\"instructions\":");
        try writer.print("{d}", .{ir.instructions});
        try writer.writeAll(",\"alloca_slots\":");
        try writer.print("{d}", .{ir.alloca_slots});
        try writer.writeAll(",\"loads\":");
        try writer.print("{d}", .{ir.loads});
        try writer.writeAll(",\"stores\":");
        try writer.print("{d}", .{ir.stores});
        try writer.writeAll("}}");
    }
    if (metrics.cache) |cache| {
        try writer.writeAll(",\"cache\":{");
        try writer.writeAll("\"kind\":");
        try writeJsonString(writer, cache.kind);
        try writer.writeAll(",\"hit\":");
        try writer.writeAll(if (cache.hit) "true" else "false");
        try writer.writeByte('}');
    }
    try writer.writeByte('}');
}

fn writeOptionalJsonU64(writer: anytype, value: ?u64) !void {
    if (value) |v| {
        try writer.print("{d}", .{v});
    } else {
        try writer.writeAll("null");
    }
}

fn writeOptionalJsonU64Field(writer: anytype, name: []const u8, value: ?u64, first: bool) !void {
    if (!first) try writer.writeByte(',');
    try writer.writeByte('"');
    try writer.writeAll(name);
    try writer.writeAll("\":");
    try writeOptionalJsonU64(writer, value);
}

fn writeSuccessJson(writer: anytype, metrics: CompileMetrics) !void {
    try writer.writeAll("{\"status\":\"ok\",\"metrics\":");
    try writeMetricsJson(writer, metrics);
    try writer.writeAll("}\n");
}

fn writeMemoryAmount(writer: anytype, value: ?u64) !void {
    const bytes = value orelse {
        try writer.writeAll("n/a");
        return;
    };
    const bytes_per_mib: u64 = 1024 * 1024;
    const tenths = (bytes * 10 + bytes_per_mib / 2) / bytes_per_mib;
    try writer.print("{d}.{d} MiB", .{ tenths / 10, tenths % 10 });
}

fn writeMemoryDelta(writer: anytype, previous: ?u64, current: ?u64) !void {
    const prev = previous orelse return;
    const curr = current orelse return;
    try writer.writeAll("  delta ");
    if (curr >= prev) {
        try writer.writeByte('+');
        try writeMemoryAmount(writer, curr - prev);
    } else {
        try writer.writeByte('-');
        try writeMemoryAmount(writer, prev - curr);
    }
}

fn writeMemoryStageLine(writer: anytype, label: []const u8, value: ?u64, previous: ?u64) !void {
    try writer.print("  {s}", .{label});
    try writeMemoryAmount(writer, value);
    try writeMemoryDelta(writer, previous, value);
    try writer.writeByte('\n');
}

fn writeMemoryStageSample(writer: anytype, label: []const u8, value: ?u64, previous: ?u64) !void {
    try writer.writeAll("memory stage ");
    try writer.writeAll(label);
    try writer.writeByte(' ');
    try writeMemoryAmount(writer, value);
    try writeMemoryDelta(writer, previous, value);
    try writer.writeByte('\n');
}

fn writeMemoryStageSampleForOptions(options: CompileOptions, label: []const u8, value: ?u64, previous: ?u64) !void {
    if (!options.mem_report_live) return;
    const writer = options.diagnostic_writer orelse return;
    try writeMemoryStageSample(writer, label, value, previous);
}

const MemoryStageReporterContext = struct {
    writer: *std.Io.Writer,
    memory: ?*CompileMemoryMetrics = null,
    previous_rss_bytes: ?u64 = null,
    peak_rss_bytes: ?u64 = null,
    live: bool = false,
};

fn writeVerifierMemoryStage(context: *MemoryStageReporterContext, stage: []const u8, completed: usize, total: usize) !void {
    const rss = currentRssBytes();
    if (context.memory) |memory| memory.recordVerifierStage(stage, rss);
    if (rss) |value| {
        if (context.peak_rss_bytes == null or value > context.peak_rss_bytes.?) {
            context.peak_rss_bytes = value;
        }
    }

    if (!context.live) {
        context.previous_rss_bytes = rss;
        return;
    }

    try context.writer.writeAll("memory stage verifier.");
    try context.writer.writeAll(stage);
    if (total != 0) {
        try context.writer.print(" {d}/{d}", .{ completed, total });
    }
    try context.writer.writeByte(' ');
    try writeMemoryAmount(context.writer, rss);
    try writeMemoryDelta(context.writer, context.previous_rss_bytes, rss);
    try context.writer.writeByte('\n');
    context.previous_rss_bytes = rss;
}

fn reportVerifierMemoryStage(context: *anyopaque, stage: []const u8, completed: usize, total: usize) void {
    const typed = @as(*MemoryStageReporterContext, @ptrCast(@alignCast(context)));
    writeVerifierMemoryStage(typed, stage, completed, total) catch {};
}

fn memoryEndPrevious(memory: CompileMemoryMetrics) ?u64 {
    return memory.after_link_rss_bytes orelse memory.after_emit_rss_bytes orelse memory.after_verify_rss_bytes;
}

fn writeMemoryReportText(writer: anytype, metrics: CompileMetrics) !void {
    const memory = metrics.memory orelse return;
    try writer.writeAll("memory report (RSS)\n");
    try writeMemoryStageLine(writer, "start          ", memory.start_rss_bytes, null);
    try writeMemoryStageLine(writer, "after_load     ", memory.after_load_rss_bytes, memory.start_rss_bytes);
    try writeMemoryStageLine(writer, "after_setup    ", memory.after_setup_rss_bytes, memory.after_load_rss_bytes);
    try writeMemoryStageLine(writer, "after_flatten  ", memory.after_flatten_rss_bytes, memory.after_setup_rss_bytes);
    try writeMemoryStageLine(writer, "after_verify   ", memory.after_verify_rss_bytes, memory.after_flatten_rss_bytes);
    try writeMemoryStageLine(writer, "after_emit     ", memory.after_emit_rss_bytes, memory.after_verify_rss_bytes);
    try writeMemoryStageLine(writer, "after_link     ", memory.after_link_rss_bytes, memory.after_emit_rss_bytes);
    try writeMemoryStageLine(writer, "end            ", memory.end_rss_bytes, memoryEndPrevious(memory));
    try writer.writeAll("  peak           ");
    try writeMemoryAmount(writer, memory.peak_rss_bytes);
    try writer.writeByte('\n');
}

fn writeSuccessDiagnostics(writer: anytype, metrics: CompileMetrics, mode: DiagnosticsMode) !void {
    switch (mode) {
        .json => try writeSuccessJson(writer, metrics),
        .human => try writeMemoryReportText(writer, metrics),
    }
}

fn writeJsonStringArray(writer: anytype, items: []const []const u8) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeJsonString(writer, item);
    }
    try writer.writeByte(']');
}

fn writeExplainEntryJson(writer: anytype, entry: ExplainEntry) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"codes\":");
    try writeJsonStringArray(writer, entry.codes);
    try writer.writeAll(",\"title\":");
    try writeJsonString(writer, entry.title);
    try writer.writeAll(",\"summary\":");
    try writeJsonString(writer, entry.summary);
    try writer.writeAll(",\"details\":");
    try writeJsonStringArray(writer, entry.details);
    try writer.writeAll(",\"fix_hint\":");
    try writeMaybeJsonString(writer, entry.fix_hint);
    try writer.writeByte('}');
}

fn writeExplainEntryText(writer: anytype, entry: ExplainEntry) !void {
    try writer.print("code: {s}\n", .{entry.codes[0]});
    if (entry.codes.len > 1) {
        try writer.writeAll("aliases:");
        for (entry.codes[1..]) |alias| {
            try writer.print(" {s}", .{alias});
        }
        try writer.writeByte('\n');
    }
    try writer.print("title: {s}\n", .{entry.title});
    try writer.print("summary: {s}\n", .{entry.summary});
    for (entry.details) |detail| {
        try writer.print("detail: {s}\n", .{detail});
    }
    if (entry.fix_hint) |hint| {
        try writer.print("fix: {s}\n", .{hint});
    }
}

fn writeFixPlanJson(writer: anytype, code: []const u8, plan: FixPlan) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"code\":");
    try writeJsonString(writer, code);
    try writer.writeAll(",\"plan\":[");
    for (plan.steps, 0..) |step, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"action\":");
        try writeJsonString(writer, step.action);
        try writer.writeAll(",\"target\":");
        try writeJsonString(writer, step.target);
        try writer.writeAll(",\"detail\":");
        try writeJsonString(writer, step.detail);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"rationale\":");
    try writeJsonStringArray(writer, plan.rationale);
    try writer.writeByte('}');
}

fn writeFixPlanText(writer: anytype, code: []const u8, plan: FixPlan) !void {
    try writer.print("code: {s}\n", .{code});
    for (plan.rationale) |item| {
        try writer.print("rationale: {s}\n", .{item});
    }
    for (plan.steps) |step| {
        try writer.print("plan: {s} {s} - {s}\n", .{ step.action, step.target, step.detail });
    }
}

fn writeTrapExplanation(writer: anytype, t: trap.Trap, json_mode: bool) !void {
    const ex = trap.explainTrap(t);
    const name = trap.trapName(t);
    const numeric = trap.trapCode(t);
    if (json_mode) {
        try writer.writeAll("{\"status\":\"ok\",\"explain\":{\"name\":");
        try writeJsonString(writer, name);
        try writer.writeAll(",\"stable_code\":");
        try writeJsonString(writer, ex.stable_code);
        try writer.print(",\"numeric_code\":{d},\"summary\":", .{numeric});
        try writeJsonString(writer, ex.summary);
        try writer.writeAll(",\"fix_hint\":");
        try writeJsonString(writer, ex.fix_hint);
        try writer.writeAll("}}\n");
    } else {
        try writer.print("{s} [{s} / {d}]: {s}\n", .{ name, ex.stable_code, numeric, ex.summary });
        try writer.print("fix: {s}\n", .{ex.fix_hint});
    }
}

fn explainCommand(writer: anytype, args: []const []const u8, json_mode: bool) !u8 {
    if (args.len < 3) return error.MissingSourcePath;
    const code = args[2];
    // Resolve by trap name, stable code (SA-REF-010), or numeric code (1006).
    // Covers all 57 traps via trap_agent.
    const maybe_trap = trap.trapFromName(code) orelse trap.trapFromStableCode(code) orelse blk: {
        const n = std.fmt.parseInt(u32, code, 10) catch break :blk null;
        break :blk trap.trapFromNumericCode(n);
    };
    if (maybe_trap) |t| {
        try writeTrapExplanation(writer, t, json_mode);
        return 0;
    }
    const entry = explainEntryForCode(code) orelse {
        if (json_mode) {
            try writer.writeAll("{\"status\":\"error\",\"explain\":null}\n");
        } else {
            try writer.print("unknown code: {s}\n", .{code});
        }
        return 1;
    };
    if (json_mode) {
        try writer.writeAll("{\"status\":\"ok\",\"explain\":");
        try writeExplainEntryJson(writer, entry);
        try writer.writeAll("}\n");
    } else {
        try writeExplainEntryText(writer, entry);
    }
    return 0;
}

fn fixPlanForCode(code: []const u8) ?FixPlan {
    return if (std.mem.eql(u8, code, "ForbiddenSyntax")) .{
        .steps = &.{
            .{ .action = "rewrite", .target = "control-flow", .detail = "lower braces and keywords into labels, br, and jmp" },
            .{ .action = "re-run", .target = "flattener", .detail = "verify that the line stream no longer contains forbidden syntax" },
        },
        .rationale = &.{
            "The flattener rejects structured syntax before semantic verification.",
            "Agent-side patching should preserve the original semantics while removing unsupported surface forms.",
        },
    } else if (std.mem.eql(u8, code, "ImportResolutionFailed")) .{
        .steps = &.{
            .{ .action = "pin", .target = "package-ref", .detail = "choose a single version or local path and record it in the manifest" },
            .{ .action = "retry", .target = "resolver", .detail = "re-run the import resolution against the pinned source" },
        },
        .rationale = &.{
            "The resolver needs one concrete source artifact, not an ambiguous graph.",
            "The current CLI fallback already treats invalid import data as a structured trap.",
        },
    } else if (std.mem.eql(u8, code, "SA-CLI-001")) .{
        .steps = &.{
            .{ .action = "add", .target = "positional-argument", .detail = "supply the missing source file or project path" },
            .{ .action = "retry", .target = "command", .detail = "invoke the same CLI command with the required operand" },
        },
        .rationale = &.{
            "The command dispatcher needs an explicit target path to operate on.",
            "This is a deterministic CLI error rather than a semantic trap.",
        },
    } else null;
}

fn fixCommand(writer: anytype, args: []const []const u8, json_mode: bool) !u8 {
    var code: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--plan")) continue;
        if (std.mem.eql(u8, arg, "--json")) continue;
        if (code == null) {
            code = arg;
            continue;
        }
        return error.UnexpectedArgument;
    }
    const target = code orelse return error.MissingSourcePath;
    // Trap-code fix: resolve by name/stable/numeric and synthesize a one-step
    // plan from the trap's fix_hint. Covers all 57 traps.
    if (trap.trapFromName(target) orelse trap.trapFromStableCode(target) orelse blk: {
        const num = std.fmt.parseInt(u32, target, 10) catch break :blk null;
        break :blk trap.trapFromNumericCode(num);
    }) |t| {
        const ex = trap.explainTrap(t);
        const steps = [_]FixPlanStep{.{ .action = "apply", .target = trap.trapStableCode(t), .detail = ex.fix_hint }};
        const rationale = [_][]const u8{ex.summary};
        const tplan = FixPlan{ .steps = &steps, .rationale = &rationale };
        if (json_mode) {
            try writer.writeAll("{\"status\":\"ok\",\"fix\":");
            try writeFixPlanJson(writer, trap.trapStableCode(t), tplan);
            try writer.writeAll("}\n");
        } else {
            try writeFixPlanText(writer, trap.trapStableCode(t), tplan);
        }
        return 0;
    }
    const plan = fixPlanForCode(target) orelse {
        try writer.print("unknown code: {s}\n", .{target});
        return 1;
    };
    if (json_mode) {
        try writer.writeAll("{\"status\":\"ok\",\"fix\":");
        try writeFixPlanJson(writer, target, plan);
        try writer.writeAll("}\n");
    } else {
        try writeFixPlanText(writer, target, plan);
    }
    return 0;
}

fn writeSkillSectionText(writer: anytype, title: []const u8, summary: []const u8, items: []const []const u8) !void {
    try writer.print("{s}\n", .{title});
    try writer.print("summary: {s}\n", .{summary});
    for (items) |item| {
        try writer.print("- {s}\n", .{item});
    }
}

fn writeSkillsJson(writer: anytype, sections: []const SkillSection) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"status\":\"ok\",\"skills\":[");
    for (sections, 0..) |section, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"name\":");
        try writeJsonString(writer, section.name);
        try writer.writeAll(",\"summary\":");
        try writeJsonString(writer, section.summary);
        try writer.writeAll(",\"items\":");
        try writeJsonStringArray(writer, section.items);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
}

fn stringSliceLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn freeStringArrayListItems(allocator: std.mem.Allocator, list: *std.array_list.Managed([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit();
}

fn normalizeSkillPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, path.len);
    for (path, 0..) |c, idx| {
        out[idx] = if (std.fs.path.isSep(c)) '/' else c;
    }
    return out;
}

fn isSaStdSurfaceFile(path: []const u8) bool {
    if (std.mem.eql(u8, std.fs.path.basename(path), "sa.mod")) return true;
    const ext = std.fs.path.extension(path);
    return std.mem.eql(u8, ext, ".sa") or
        std.mem.eql(u8, ext, ".sars") or
        std.mem.eql(u8, ext, ".sal") or
        std.mem.eql(u8, ext, ".sai");
}

fn appendStdDeclarations(
    allocator: std.mem.Allocator,
    macros: *std.array_list.Managed([]const u8),
    externs: *std.array_list.Managed([]const u8),
    rel_path: []const u8,
    source: []const u8,
) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "[MACRO] ")) {
            try macros.append(try std.fmt.allocPrint(allocator, "{s}: {s}", .{ rel_path, line }));
        } else if (std.mem.startsWith(u8, line, "@extern ") or std.mem.startsWith(u8, line, "@export ")) {
            try externs.append(try std.fmt.allocPrint(allocator, "{s}: {s}", .{ rel_path, line }));
        }
    }
}

fn collectSaStdSurface(allocator: std.mem.Allocator, std_root: []const u8) !SaStdSurface {
    var files = std.array_list.Managed([]const u8).init(allocator);
    var macros = std.array_list.Managed([]const u8).init(allocator);
    var externs = std.array_list.Managed([]const u8).init(allocator);
    var files_slice: ?[]const []const u8 = null;
    var macros_slice: ?[]const []const u8 = null;
    var externs_slice: ?[]const []const u8 = null;
    errdefer {
        if (files_slice) |items| freeOwnedStringSlice(allocator, items) else freeStringArrayListItems(allocator, &files);
        if (macros_slice) |items| freeOwnedStringSlice(allocator, items) else freeStringArrayListItems(allocator, &macros);
        if (externs_slice) |items| freeOwnedStringSlice(allocator, items) else freeStringArrayListItems(allocator, &externs);
    }

    var root = try sio.cwd().openDir(std_root, .{ .iterate = true });
    defer root.close();

    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isSaStdSurfaceFile(entry.path)) continue;

        const rel_path = try normalizeSkillPathAlloc(allocator, entry.path);
        errdefer allocator.free(rel_path);
        try files.append(rel_path);

        const source = try root.readFileAlloc(allocator, entry.path, 16 * 1024 * 1024);
        defer allocator.free(source);
        try appendStdDeclarations(allocator, &macros, &externs, rel_path, source);
    }

    std.mem.sort([]const u8, files.items, {}, stringSliceLessThan);
    std.mem.sort([]const u8, macros.items, {}, stringSliceLessThan);
    std.mem.sort([]const u8, externs.items, {}, stringSliceLessThan);

    files_slice = try files.toOwnedSlice();
    macros_slice = try macros.toOwnedSlice();
    externs_slice = try externs.toOwnedSlice();

    const result = SaStdSurface{
        .files = files_slice.?,
        .macros = macros_slice.?,
        .externs = externs_slice.?,
    };
    files_slice = null;
    macros_slice = null;
    externs_slice = null;
    return result;
}

const common_official_plugins = [_][]const u8{
    "bc2sa",
    "db",
    "deno",
    "http-client",
    "http-server",
    "node",
    "pkg",
    "sax",
    "vm",
};

fn isCommonOfficialPluginName(name: []const u8) bool {
    const normalized = if (std.mem.startsWith(u8, name, "sa_plugin_")) name["sa_plugin_".len..] else name;
    for (common_official_plugins) |candidate| {
        if (std.mem.eql(u8, normalized, candidate)) return true;
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn dirExistsAbsolute(path: []const u8) bool {
    var dir = sio.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

fn dirExistsCwd(path: []const u8) bool {
    var dir = sio.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

fn officialPluginsRootFromEnv(allocator: std.mem.Allocator) !?[]u8 {
    if (dirExistsCwd("sa_plugins")) {
        return try sio.cwd().realpathAlloc(allocator, "sa_plugins");
    }

    const env_root = sio.getEnvVarOwned(allocator, "SA_PLUGINS_WORKSPACE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_root) |root| {
        defer allocator.free(root);
        if (std.fs.path.isAbsolute(root)) {
            if (dirExistsAbsolute(root)) return try allocator.dupe(u8, root);
        } else if (dirExistsCwd(root)) {
            return try sio.cwd().realpathAlloc(allocator, root);
        }
    }

    if (std.fs.path.dirname(build_options.repo_root)) |parent| {
        const sibling = try std.fs.path.join(allocator, &.{ parent, "sa_plugins" });
        defer allocator.free(sibling);
        if (dirExistsAbsolute(sibling)) return try allocator.dupe(u8, sibling);
    }

    return null;
}

fn appendJsonStringArrayToCsv(
    allocator: std.mem.Allocator,
    list: *std.array_list.Managed([]const u8),
    value: ?std.json.Value,
) ![]const u8 {
    var scratch = std.array_list.Managed([]const u8).init(allocator);
    defer scratch.deinit();
    if (value) |v| switch (v) {
        .array => |arr| {
            for (arr.items) |item| switch (item) {
                .string => |text| try scratch.append(text),
                else => {},
            };
        },
        else => {},
    };
    if (scratch.items.len == 0) {
        const owned = try allocator.dupe(u8, "none");
        try list.append(owned);
        return owned;
    }
    const owned = try std.mem.join(allocator, ", ", scratch.items);
    try list.append(owned);
    return owned;
}

fn appendJsonObjectKeysToCsv(
    allocator: std.mem.Allocator,
    list: *std.array_list.Managed([]const u8),
    value: ?std.json.Value,
) ![]const u8 {
    var scratch = std.array_list.Managed([]const u8).init(allocator);
    defer scratch.deinit();
    if (value) |v| switch (v) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| try scratch.append(entry.key_ptr.*);
        },
        else => {},
    };
    if (scratch.items.len == 0) {
        const owned = try allocator.dupe(u8, "none");
        try list.append(owned);
        return owned;
    }
    std.mem.sort([]const u8, scratch.items, {}, stringSliceLessThan);
    const owned = try std.mem.join(allocator, ", ", scratch.items);
    try list.append(owned);
    return owned;
}

fn appendJsonInterfaceSummary(
    allocator: std.mem.Allocator,
    list: *std.array_list.Managed([]const u8),
    value: ?std.json.Value,
) ![]const u8 {
    var scratch = std.array_list.Managed([]const u8).init(allocator);
    defer scratch.deinit();
    if (value) |v| switch (v) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                switch (entry.value_ptr.*) {
                    .string => |path| try scratch.append(try std.fmt.allocPrint(allocator, "{s}:{s}", .{ key, path })),
                    .object => |o| if (o.get("path")) |path_value| switch (path_value) {
                        .string => |path| try scratch.append(try std.fmt.allocPrint(allocator, "{s}:{s}", .{ key, path })),
                        else => {},
                    },
                    .array => |arr| for (arr.items) |item| switch (item) {
                        .string => |path| try scratch.append(try std.fmt.allocPrint(allocator, "{s}:{s}", .{ key, path })),
                        .object => |o| if (o.get("path")) |path_value| switch (path_value) {
                            .string => |path| try scratch.append(try std.fmt.allocPrint(allocator, "{s}:{s}", .{ key, path })),
                            else => {},
                        },
                        else => {},
                    },
                    else => {},
                }
            }
        },
        else => {},
    };
    defer {
        for (scratch.items) |item| allocator.free(item);
    }
    if (scratch.items.len == 0) {
        const owned = try allocator.dupe(u8, "CLI-only or native descriptor only");
        try list.append(owned);
        return owned;
    }
    std.mem.sort([]const u8, scratch.items, {}, stringSliceLessThan);
    const owned = try std.mem.join(allocator, ", ", scratch.items);
    try list.append(owned);
    return owned;
}

fn appendPermissionSummary(
    allocator: std.mem.Allocator,
    list: *std.array_list.Managed([]const u8),
    value: ?std.json.Value,
) ![]const u8 {
    const obj = if (value) |v| switch (v) {
        .object => |o| o,
        else => null,
    } else null;
    if (obj == null) {
        const owned = try allocator.dupe(u8, "no manifest permissions declared");
        try list.append(owned);
        return owned;
    }
    const o = obj.?;
    const fs_count = if (o.get("fs")) |fs_value| switch (fs_value) {
        .array => |arr| arr.items.len,
        else => 0,
    } else 0;
    const net_count = if (o.get("net")) |net_value| switch (net_value) {
        .array => |arr| arr.items.len,
        else => 0,
    } else 0;
    const env_count = if (o.get("env")) |env_value| switch (env_value) {
        .array => |arr| arr.items.len,
        else => 0,
    } else 0;
    const process_spawn = if (o.get("process")) |process_value| switch (process_value) {
        .object => |process_obj| if (process_obj.get("spawn")) |spawn_value| switch (spawn_value) {
            .bool => |b| b,
            else => false,
        } else false,
        else => false,
    } else false;
    const owned = try std.fmt.allocPrint(allocator, "fs:{d}, net:{d}, env:{d}, process_spawn:{s}", .{ fs_count, net_count, env_count, if (process_spawn) "yes" else "no" });
    try list.append(owned);
    return owned;
}

fn pluginInterfaceFileCandidate(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "expanded.sa")) return false;
    if (std.mem.eql(u8, base, "expanded.sars")) return false;
    if (std.mem.startsWith(u8, base, "tmp_")) return false;
    if (std.mem.startsWith(u8, base, "_tmp")) return false;
    const ext = std.fs.path.extension(path);
    return std.mem.eql(u8, ext, ".sa") or
        std.mem.eql(u8, ext, ".sars") or
        std.mem.eql(u8, ext, ".sal") or
        std.mem.eql(u8, ext, ".sai");
}

fn appendPluginDeclarations(
    allocator: std.mem.Allocator,
    declarations: *std.array_list.Managed([]const u8),
    plugin_name: []const u8,
    plugin_dir_name: []const u8,
    plugin_dir: sio.Dir,
) !void {
    var it = plugin_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!pluginInterfaceFileCandidate(entry.name)) continue;
        const source = try plugin_dir.readFileAlloc(allocator, entry.name, 16 * 1024 * 1024);
        defer allocator.free(source);
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (std.mem.startsWith(u8, line, "[MACRO] ") or
                std.mem.startsWith(u8, line, "@extern ") or
                std.mem.startsWith(u8, line, "@export "))
            {
                try declarations.append(try std.fmt.allocPrint(allocator, "{s}/{s}/{s}: {s}", .{ plugin_name, plugin_dir_name, entry.name, line }));
            }
        }
    }
}

fn appendDocSummary(
    allocator: std.mem.Allocator,
    list: *std.array_list.Managed([]const u8),
    plugin_dir: sio.Dir,
) ![]const u8 {
    const doc_names = [_][]const u8{ "README.md", "api.md", "AGENTS.md" };
    for (doc_names) |doc_name| {
        const source = plugin_dir.readFileAlloc(allocator, doc_name, 128 * 1024) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(source);
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "#")) continue;
            if (std.mem.startsWith(u8, line, "---")) continue;
            if (std.mem.startsWith(u8, line, "```")) continue;
            const owned = try allocator.dupe(u8, line);
            try list.append(owned);
            return owned;
        }
    }
    const owned = try allocator.dupe(u8, "No README summary found; inspect the plugin manifest and interface files before using it.");
    try list.append(owned);
    return owned;
}

fn appendOfficialPluginInfo(
    allocator: std.mem.Allocator,
    plugins_list: *std.array_list.Managed([]const u8),
    declarations: *std.array_list.Managed([]const u8),
    notes: *std.array_list.Managed([]const u8),
    root_dir: sio.Dir,
    root_path: []const u8,
    dir_name: []const u8,
) !void {
    var plugin_dir = try root_dir.openDir(dir_name, .{ .iterate = true });
    defer plugin_dir.close();

    const manifest_source = plugin_dir.readFileAlloc(allocator, "sap.json", 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(manifest_source);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_source, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return,
    };
    const manifest_name = switch (object.get("name") orelse return) {
        .string => |s| s,
        else => return,
    };
    if (!isCommonOfficialPluginName(manifest_name) and !isCommonOfficialPluginName(dir_name)) return;

    const version = if (object.get("version")) |version_value| switch (version_value) {
        .string => |s| s,
        else => "unknown",
    } else "unknown";
    const doc_summary = try appendDocSummary(allocator, notes, plugin_dir);
    const skills = try appendJsonStringArrayToCsv(allocator, notes, object.get("skills"));
    const interfaces = try appendJsonInterfaceSummary(allocator, notes, object.get("interfaces"));
    const dependencies = try appendJsonObjectKeysToCsv(allocator, notes, object.get("dependencies"));
    const permissions = try appendPermissionSummary(allocator, notes, object.get("permissions"));
    const plugin_path = try std.fs.path.join(allocator, &.{ root_path, dir_name });
    defer allocator.free(plugin_path);

    try plugins_list.append(try std.fmt.allocPrint(
        allocator,
        "{s} ({s}) from `{s}`: {s} Skills: {s}. Interfaces: {s}. Dependencies: {s}. Permissions: {s}. Optional plugin: install before use with `SA_PLUGIN_DEV=1 sa plugin install --dev {s}`, then verify availability with `sa plugin list` or `sa skills --json`.",
        .{ manifest_name, version, dir_name, doc_summary, skills, interfaces, dependencies, permissions, plugin_path },
    ));

    try appendPluginDeclarations(allocator, declarations, manifest_name, dir_name, plugin_dir);
}

fn collectOfficialSaPluginsSurface(allocator: std.mem.Allocator) !SaPluginsSurface {
    var plugins_list = std.array_list.Managed([]const u8).init(allocator);
    var declarations = std.array_list.Managed([]const u8).init(allocator);
    var notes = std.array_list.Managed([]const u8).init(allocator);
    var plugins_slice: ?[]const []const u8 = null;
    var declarations_slice: ?[]const []const u8 = null;
    var notes_slice: ?[]const []const u8 = null;
    var root_owned: ?[]u8 = null;
    errdefer {
        if (root_owned) |root| allocator.free(root);
        if (plugins_slice) |items| freeOwnedStringSlice(allocator, items) else freeStringArrayListItems(allocator, &plugins_list);
        if (declarations_slice) |items| freeOwnedStringSlice(allocator, items) else freeStringArrayListItems(allocator, &declarations);
        if (notes_slice) |items| freeOwnedStringSlice(allocator, items) else freeStringArrayListItems(allocator, &notes);
    }

    root_owned = try officialPluginsRootFromEnv(allocator);
    if (root_owned) |root_path| {
        var root_dir = try sio.openDirAbsolute(root_path, .{ .iterate = true });
        defer root_dir.close();
        var it = root_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory and entry.kind != .sym_link) continue;
            if (!std.mem.startsWith(u8, entry.name, "sa_plugin_")) continue;
            try appendOfficialPluginInfo(allocator, &plugins_list, &declarations, &notes, root_dir, root_path, entry.name);
        }
    }

    std.mem.sort([]const u8, plugins_list.items, {}, stringSliceLessThan);
    std.mem.sort([]const u8, declarations.items, {}, stringSliceLessThan);
    plugins_slice = try plugins_list.toOwnedSlice();
    declarations_slice = try declarations.toOwnedSlice();
    notes_slice = try notes.toOwnedSlice();

    const result = SaPluginsSurface{
        .root = root_owned,
        .plugins = plugins_slice.?,
        .declarations = declarations_slice.?,
        .notes = notes_slice.?,
    };
    root_owned = null;
    plugins_slice = null;
    declarations_slice = null;
    notes_slice = null;
    return result;
}

fn writeFrontmatterField(writer: anytype, name: []const u8, value: []const u8) !void {
    try writer.print("{s}: ", .{name});
    try writeJsonString(writer, value);
    try writer.writeByte('\n');
}

fn writeMarkdownCodeList(writer: anytype, items: []const []const u8) !void {
    if (items.len == 0) {
        try writer.writeAll("- none\n");
        return;
    }
    for (items) |item| {
        try writer.print("- `{s}`\n", .{item});
    }
}

fn writeMarkdownTextList(writer: anytype, items: []const []const u8) !void {
    if (items.len == 0) {
        try writer.writeAll("- none\n");
        return;
    }
    for (items) |item| {
        try writer.print("- {s}\n", .{item});
    }
}

fn writeSaAgentSkillMarkdown(
    writer: anytype,
    agent_name: []const u8,
    std_root: []const u8,
    sections: []const SkillSection,
    surface: SaStdSurface,
) !void {
    const description = if (std.mem.eql(u8, agent_name, "claude"))
        "Use the installed SA compiler and current sa_std surface to build, test, debug, and inspect SA projects from Claude."
    else
        "Use the installed SA compiler and current sa_std surface to build, test, debug, and inspect SA projects from Codex.";
    try writer.writeAll("---\n");
    try writeFrontmatterField(writer, "name", "sa");
    try writeFrontmatterField(writer, "description", description);
    try writeFrontmatterField(writer, "when_to_use", "Use when working on SA assembly, running SA CLI builds/tests, diagnosing verifier errors, or checking the available sa_std macros and extern APIs.");
    try writer.writeAll("---\n\n");

    try writer.writeAll("# SA Toolchain\n\n");
    try writer.writeAll("## Core Workflow\n");
    try writer.writeAll("- Run `sa version` to confirm the installed compiler version.\n");
    try writer.writeAll("- Use `sa build <file>` to compile and verify SA source without running it; project build caching is on by default and `--no-incremental` forces a clean rebuild.\n");
    try writer.writeAll("- Use `sa run <file> [args...]` for compile-and-run workflows.\n");
    try writer.writeAll("- Use `sa build-workspace -p <package> -o <path>` for workspace-root member builds, or `sa build-exe <file> -o <path>`, `sa build-obj <file> -o <path>`, and `sa build-wasm <file> -o <path>` for direct file artifacts.\n");
    try writer.writeAll("- Use `sa test <file> --list`, `sa test <file> --filter <pattern>`, `sa test <file> --compile-only`, and `sa test <file> --trace-panic` for unit tests.\n");
    try writer.writeAll("- Use `sa explain <code>` and `sa fix --plan <code>` before guessing at diagnostics.\n");
    try writer.writeAll("- Treat the `sa_std Surface` section below as authoritative for currently available macros and extern/export declarations; it is generated by scanning the active std root.\n");
    try writer.writeAll("- Keep plugin-specific APIs out of compiler std; optional official plugin notes are generated separately at `../sa_plugins/SKILL.md`.\n");
    try writer.writeAll("- Before using any plugin API, run `sa plugin list` or `sa skills --json` to confirm that the plugin is installed for this environment.\n\n");

    try writer.writeAll("## CLI Skill Sections\n");
    for (sections) |section| {
        try writer.print("### {s}\n", .{section.name});
        try writer.print("{s}\n", .{section.summary});
        try writeMarkdownCodeList(writer, section.items);
        try writer.writeByte('\n');
    }

    try writer.writeAll("## Std Coverage Guide\n");
    try writer.writeAll("- Core macro families include string, vec, slice, option, result, iter, mem, ptr, num, cmp, ops, default, convert, borrow, any, error, hash, marker, pin, char, and ascii helpers.\n");
    try writer.writeAll("- Runtime-backed std families include fs, env, process, io, time, net, path, term, fmt, json, regex, and sync helpers.\n");
    try writer.writeAll("- Rust-style fs coverage includes create_dir, create_dir_all, remove_dir, remove_dir_all, read_to_string, try_exists, canonicalize, hard_link, symlink, read_link, permissions, and file sync helpers where listed in the generated surface.\n");
    try writer.writeAll("- Rust-style net coverage includes owned address handles, ToSocketAddrs first-address resolution, TCP listener/stream helpers, UDP socket helpers, and address formatting where listed in the generated surface.\n");
    try writer.writeAll("- Future/task/async macros cover the current SA facade; Rust's full std::future/std::task poll, executor, join, select, trait, and generic type system are not implied unless concrete macros appear below.\n");
    try writer.writeAll("- Deno, http, node, db, sax, vm, bc2sa, and other optional plugin APIs are documented separately under `../sa_plugins/SKILL.md` and must not be assumed installed.\n\n");

    try writer.writeAll("## sa_std Surface\n");
    try writer.print("Generated from `{s}`.\n\n", .{std_root});
    try writer.print("- files: `{d}`\n", .{surface.files.len});
    try writer.print("- macros: `{d}`\n", .{surface.macros.len});
    try writer.print("- extern/export declarations: `{d}`\n\n", .{surface.externs.len});

    try writer.writeAll("### Files\n");
    try writeMarkdownCodeList(writer, surface.files);
    try writer.writeAll("\n### Macros\n");
    try writeMarkdownCodeList(writer, surface.macros);
    try writer.writeAll("\n### Externs And Exports\n");
    try writeMarkdownCodeList(writer, surface.externs);
}

fn writeSaPluginsAgentSkillMarkdown(
    writer: anytype,
    agent_name: []const u8,
    surface: SaPluginsSurface,
) !void {
    const description = if (std.mem.eql(u8, agent_name, "claude"))
        "Use the optional official SA plugin catalog from Claude without assuming plugins are installed."
    else
        "Use the optional official SA plugin catalog from Codex without assuming plugins are installed.";
    try writer.writeAll("---\n");
    try writeFrontmatterField(writer, "name", "sa_plugins");
    try writeFrontmatterField(writer, "description", description);
    try writeFrontmatterField(writer, "when_to_use", "Use when a task mentions optional SA plugins such as deno, http-client, http-server, node, pkg, db, sax, bc2sa, or vm. Always verify installation before using plugin APIs.");
    try writer.writeAll("---\n\n");

    try writer.writeAll("# SA Optional Plugins\n\n");
    try writer.writeAll("## Rules\n");
    try writer.writeAll("- This file is a catalog of common official plugins, not proof that any plugin is installed.\n");
    try writer.writeAll("- Run `sa plugin list` to inspect installed plugins before using plugin commands or imports.\n");
    try writer.writeAll("- Run `sa skills --json` to inspect capability sections exported by currently loaded plugins.\n");
    try writer.writeAll("- Install a needed local official plugin with `SA_PLUGIN_DEV=1 sa plugin install --dev <plugin-dir>`; plugin dependencies may need to be installed first or declared in `sap.json`.\n");
    try writer.writeAll("- Keep these APIs out of compiler `sa_std`; plugin availability is per environment and can change.\n\n");

    try writer.writeAll("## Source\n");
    if (surface.root) |root| {
        try writer.print("Generated from optional plugin workspace `{s}`.\n", .{root});
    } else {
        try writer.writeAll("No official plugin workspace was found. Set `SA_PLUGINS_WORKSPACE` or keep `/home/vscode/projects/sa_plugins` beside the compiler checkout to populate this catalog.\n");
    }
    try writer.print("- common plugins listed: `{d}`\n", .{surface.plugins.len});
    try writer.print("- interface declarations listed: `{d}`\n\n", .{surface.declarations.len});

    try writer.writeAll("## Common Official Plugins\n");
    try writeMarkdownTextList(writer, surface.plugins);
    try writer.writeAll("\n## Interface Declarations\n");
    try writeMarkdownCodeList(writer, surface.declarations);
}

fn writeSaAgentSkills(
    allocator: std.mem.Allocator,
    std_root: []const u8,
    sections: []const SkillSection,
    surface: SaStdSurface,
    plugins_surface: SaPluginsSurface,
) !AgentSkillPaths {
    const sa_codex_dir = ".codex/skills/sa";
    const sa_claude_dir = ".claude/skills/sa";
    const plugins_codex_dir = ".codex/skills/sa_plugins";
    const plugins_claude_dir = ".claude/skills/sa_plugins";
    const sa_codex_path = ".codex/skills/sa/SKILL.md";
    const sa_claude_path = ".claude/skills/sa/SKILL.md";
    const plugins_codex_path = ".codex/skills/sa_plugins/SKILL.md";
    const plugins_claude_path = ".claude/skills/sa_plugins/SKILL.md";

    try sio.cwd().makePath(sa_codex_dir);
    try sio.cwd().makePath(sa_claude_dir);
    try sio.cwd().makePath(plugins_codex_dir);
    try sio.cwd().makePath(plugins_claude_dir);

    {
        var file = try sio.cwd().createFile(sa_codex_path, .{ .truncate = true });
        defer file.close();
        var fbuf: [8192]u8 = undefined;
        var fw = file.writer(&fbuf);
        try writeSaAgentSkillMarkdown(&fw.interface, "codex", std_root, sections, surface);
        try fw.interface.flush();
    }
    {
        var file = try sio.cwd().createFile(sa_claude_path, .{ .truncate = true });
        defer file.close();
        var fbuf: [8192]u8 = undefined;
        var fw = file.writer(&fbuf);
        try writeSaAgentSkillMarkdown(&fw.interface, "claude", std_root, sections, surface);
        try fw.interface.flush();
    }
    {
        var file = try sio.cwd().createFile(plugins_codex_path, .{ .truncate = true });
        defer file.close();
        var fbuf: [8192]u8 = undefined;
        var fw = file.writer(&fbuf);
        try writeSaPluginsAgentSkillMarkdown(&fw.interface, "codex", plugins_surface);
        try fw.interface.flush();
    }
    {
        var file = try sio.cwd().createFile(plugins_claude_path, .{ .truncate = true });
        defer file.close();
        var fbuf: [8192]u8 = undefined;
        var fw = file.writer(&fbuf);
        try writeSaPluginsAgentSkillMarkdown(&fw.interface, "claude", plugins_surface);
        try fw.interface.flush();
    }

    return .{
        .sa_codex = try allocator.dupe(u8, sa_codex_path),
        .sa_claude = try allocator.dupe(u8, sa_claude_path),
        .plugins_codex = try allocator.dupe(u8, plugins_codex_path),
        .plugins_claude = try allocator.dupe(u8, plugins_claude_path),
    };
}

fn skillsCommand(allocator: std.mem.Allocator, writer: anytype, json_mode: bool) !u8 {
    const base_sections = [_]SkillSection{
        .{ .name = "core diagnostics", .summary = "Agent-facing error handling and JSON reports", .items = &.{
            "stable trap names and trap codes",
            "structured JSON diagnostics with repair hints",
            "human and JSON output modes remain aligned",
        } },
        .{ .name = "cli toolchain", .summary = "Agent-first CLI entry points", .items = &.{
            "init [path]",
            "pkg install [identity]",
            "explain <code>",
            "fix --plan --json",
            "skills",
            "check <file>",
            "test --affected",
            "daemon",
        } },
        .{ .name = "project lifecycle", .summary = "Rust-like project setup and local builds", .items = &.{
            "init [path]",
            "pkg install",
            "build src/main.sars",
            "run src/main.sars",
            "test <file>",
        } },
        .{ .name = "std runtime", .summary = "Current Zig-backed facade surface", .items = &.{
            "Rust-style string/vec/slice/option/result/core helper macros",
            "fs/env/process/io/time/net/sync facades over the compiler runtime",
            "JSON DOM, regex, formatting, path, and terminal facades",
            "optional deno/http/node/db/plugin APIs stay outside compiler std",
        } },
    };
    var sections_list = std.array_list.Managed(SkillSection).init(allocator);
    errdefer sections_list.deinit();
    try sections_list.appendSlice(base_sections[0..]);
    // Diagnostic catalog: expose all verifier/flattener traps (name + stable
    // code) so Agents can discover the full diagnostic surface. Items live for
    // the function scope; sections are rendered before this list is freed.
    var trap_items = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (trap_items.items) |it| allocator.free(it);
        trap_items.deinit();
    }
    for (trap.allTraps()) |t| {
        const it = std.fmt.allocPrint(allocator, "{s} ({s})", .{ trap.trapName(t), trap.trapStableCode(t) }) catch continue;
        trap_items.append(it) catch continue;
    }
    try sections_list.append(.{ .name = "diagnostic catalog", .summary = "All verifier/flattener traps; use sa explain <name|code> for details", .items = trap_items.items });
    var plugin_runtime = try plugins.Runtime.initFromEnv(allocator);
    defer plugin_runtime.deinit();
    try plugin_runtime.appendSkills(&sections_list);
    const sections = try sections_list.toOwnedSlice();
    defer allocator.free(sections);

    if (json_mode) {
        try writeSkillsJson(writer, sections);
    } else {
        const std_root = try stdRootFromEnv(allocator);
        defer allocator.free(std_root);
        const surface = try collectSaStdSurface(allocator, std_root);
        defer surface.deinit(allocator);
        const plugins_surface = try collectOfficialSaPluginsSurface(allocator);
        defer plugins_surface.deinit(allocator);
        const skill_paths = try writeSaAgentSkills(allocator, std_root, sections, surface, plugins_surface);
        defer skill_paths.deinit(allocator);

        try writer.writeAll("agent-first toolchain\n");
        try writer.print("generated agent skills:\n- {s}\n- {s}\n- {s}\n- {s}\n", .{ skill_paths.sa_codex, skill_paths.sa_claude, skill_paths.plugins_codex, skill_paths.plugins_claude });
        try writer.print("std surface: {d} files, {d} macros, {d} extern/export declarations\n", .{ surface.files.len, surface.macros.len, surface.externs.len });
        try writer.print("official plugin catalog: {d} common plugins, {d} interface declarations; availability still depends on local installation\n", .{ plugins_surface.plugins.len, plugins_surface.declarations.len });
        for (sections) |section| {
            try writeSkillSectionText(writer, section.name, section.summary, section.items);
        }
    }
    return 0;
}

fn daemonWrite(stream: std.Io.net.Stream, bytes: []const u8) void {
    var wbuf: [8192]u8 = undefined;
    var w = stream.writer(sio.io(), &wbuf);
    w.interface.writeAll(bytes) catch {};
    w.interface.flush() catch {};
}

fn daemonWorker(allocator: std.mem.Allocator, stream: std.Io.net.Stream, in_flight: *std.atomic.Value(usize)) void {
    defer _ = in_flight.fetchSub(1, .monotonic);
    handleDaemonConnection(allocator, stream);
}

var daemon_shutdown_flag = std.atomic.Value(bool).init(false);
var daemon_in_flight_global = std.atomic.Value(usize).init(0);
var daemon_cwd_lock: std.Io.RwLock = .init;

fn handleDaemonConnection(allocator: std.mem.Allocator, stream: std.Io.net.Stream) void {
    defer stream.close(sio.io());
    var request_buf = std.array_list.Managed(u8).init(allocator);
    defer request_buf.deinit();
    var read_buf: [4096]u8 = undefined;
    var request_line: []const u8 = &.{};
    var sock_rbuf: [4096]u8 = undefined;
    var sock_reader = stream.reader(sio.io(), &sock_rbuf);
    while (true) {
        const n = sock_reader.interface.readSliceShort(read_buf[0..]) catch return;
        if (n == 0) return;
        if (request_buf.items.len > daemon_client.MAX_REQUEST_BYTES - n) {
            daemonWrite(stream, "{\"status\":\"error\",\"message\":\"request too large\"}\n");
            return;
        }
        request_buf.appendSlice(read_buf[0..n]) catch return;
        if (std.mem.indexOfScalar(u8, request_buf.items, '\n')) |newline| {
            request_line = std.mem.trimEnd(u8, request_buf.items[0..newline], "\r ");
            break;
        }
    }
    if (request_line.len == 0) return;

    // Control ops that don't need argv execution.
    if (std.mem.indexOf(u8, request_line, "\"op\":\"ping\"") != null or std.mem.indexOf(u8, request_line, "\"op\": \"ping\"") != null) {
        const st = daemon_cancel.stats();
        const vs = incr_verify.stats();
        const as = affected_tests.stats();
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        aw.writer.print(
            "{{\"status\":\"ok\",\"code\":0,\"metrics\":{{\"in_flight\":{d},\"accepted\":{d},\"canceled\":{d},\"busy_rejects\":{d},\"verdict_hits\":{d},\"verdict_misses\":{d},\"affected_hits\":{d},\"affected_misses\":{d}}}}}\n",
            .{
                daemon_in_flight_global.load(.monotonic),
                st.accepted,
                st.canceled,
                st.busy_rejects,
                vs.hits,
                vs.misses,
                as.hits,
                as.misses,
            },
        ) catch return;
        daemonWrite(stream, aw.written());
        return;
    }
    if (std.mem.indexOf(u8, request_line, "\"op\":\"shutdown\"") != null or std.mem.indexOf(u8, request_line, "\"op\": \"shutdown\"") != null) {
        daemon_shutdown_flag.store(true, .monotonic);
        daemonWrite(stream, "{\"status\":\"ok\",\"code\":0,\"message\":\"shutting down\"}\n");
        return;
    }
    if (std.mem.indexOf(u8, request_line, "\"op\":\"cancel\"") != null or std.mem.indexOf(u8, request_line, "\"op\": \"cancel\"") != null) {
        const agent_id = daemon_cancel.parseJsonStrField(request_line, "\"agent_id\"") orelse "";
        const gen = daemon_cancel.cancelAgent(agent_id);
        daemon_cancel.noteCanceled();
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        aw.writer.print("{{\"status\":\"ok\",\"code\":0,\"canceled_generation\":{d}}}\n", .{gen}) catch return;
        daemonWrite(stream, aw.written());
        return;
    }

    // Cooperative cancellation: skip work if a newer generation superseded this.
    const agent_id = daemon_cancel.parseJsonStrField(request_line, "\"agent_id\"") orelse "";
    const generation = daemon_cancel.parseJsonU64Field(request_line, "\"generation\"") orelse 0;
    if (agent_id.len != 0) {
        _ = daemon_cancel.registerGeneration(agent_id, generation);
        if (!daemon_cancel.generationIsCurrent(agent_id, generation)) {
            daemon_cancel.noteCanceled();
            daemonWrite(stream, "{\"status\":\"canceled\"}\n");
            return;
        }
    }

    // Per-agent quota: reject if this agent already has too many in-flight
    // requests. Prevents one agent from starving others. Empty id = unlimited.
    if (agent_id.len != 0 and !daemon_cancel.acquireSlot(agent_id)) {
        daemonWrite(stream, "{\"status\":\"busy\",\"message\":\"per-agent quota exceeded\"}\n");
        return;
    }
    defer if (agent_id.len != 0) daemon_cancel.releaseSlot(agent_id);

    const parsed = parseDaemonArgv(allocator, request_line) catch {
        daemonWrite(stream, "{\"status\":\"error\",\"message\":\"invalid request\"}\n");
        return;
    };
    defer freeDaemonArgv(allocator, parsed);

    const requested_cwd = daemon_cancel.parseJsonStrField(request_line, "\"cwd\"");
    if (requested_cwd != null) {
        daemon_cwd_lock.lock(sio.io()) catch {};
    } else {
        daemon_cwd_lock.lockShared(sio.io()) catch {};
    }
    defer if (requested_cwd != null) daemon_cwd_lock.unlock(sio.io()) else daemon_cwd_lock.unlockShared(sio.io());

    var old_cwd_buf: [sio.max_path_bytes]u8 = undefined;
    const old_cwd = if (requested_cwd != null) sio.cwd().realpath(".", &old_cwd_buf) catch null else null;
    if (requested_cwd) |cwd| {
        sio.changeCurDir(cwd) catch {
            daemonWrite(stream, "{\"status\":\"error\",\"message\":\"invalid cwd\"}\n");
            return;
        };
    }
    defer if (old_cwd) |c| sio.changeCurDir(c) catch {};

    const wall_start = std.Io.Clock.awake.now(sio.io());
    var resp: std.Io.Writer.Allocating = .init(allocator);
    defer resp.deinit();
    const code: u8 = executeWithWritersAndOptions(allocator, parsed, &resp.writer, &resp.writer, .{}) catch |err| blk: {
        resp.clearRetainingCapacity();
        resp.writer.print("execution error: {s}", .{@errorName(err)}) catch {};
        break :blk @as(u8, 1);
    };
    const wall_ms: u64 = elapsedNs(wall_start) / 1_000_000;
    const vs = incr_verify.stats();
    const as = affected_tests.stats();

    // Re-check cancellation after work (cooperative end boundary).
    if (agent_id.len != 0 and !daemon_cancel.generationIsCurrent(agent_id, generation)) {
        daemon_cancel.noteCanceled();
        daemonWrite(stream, "{\"status\":\"canceled\"}\n");
        return;
    }

    var haw: std.Io.Writer.Allocating = .init(allocator);
    defer haw.deinit();
    haw.writer.print(
        "{{\"status\":\"ok\",\"code\":{d},\"len\":{d},\"metrics\":{{\"wall_ms\":{d},\"verdict_hits\":{d},\"verdict_misses\":{d},\"affected_hits\":{d},\"affected_misses\":{d}}}}}\n",
        .{ code, resp.written().len, wall_ms, vs.hits, vs.misses, as.hits, as.misses },
    ) catch return;
    daemonWrite(stream, haw.written());
    daemonWrite(stream, resp.written());
}

fn parseDaemonArgv(allocator: std.mem.Allocator, request: []const u8) ![]const []const u8 {
    // Prefer explicit argv array. Also accept op/file/args document style.
    if (std.mem.indexOf(u8, request, "\"argv\"")) |_| {
        const lb = std.mem.indexOfScalar(u8, request, '[') orelse return error.InvalidRequest;
        const rb = std.mem.lastIndexOfScalar(u8, request, ']') orelse return error.InvalidRequest;
        if (rb <= lb) return error.InvalidRequest;
        const inner = request[lb + 1 .. rb];
        var list = std.array_list.Managed([]const u8).init(allocator);
        errdefer {
            for (list.items) |it| allocator.free(it);
            list.deinit();
        }
        var i: usize = 0;
        while (i < inner.len) {
            if (inner[i] != '"') {
                i += 1;
                continue;
            }
            i += 1;
            var item = std.array_list.Managed(u8).init(allocator);
            errdefer item.deinit();
            while (i < inner.len and inner[i] != '"') {
                if (inner[i] == '\\' and i + 1 < inner.len) {
                    i += 1;
                }
                try item.append(inner[i]);
                i += 1;
            }
            i += 1; // closing quote
            try list.append(try item.toOwnedSlice());
        }
        // Normalize argv[0] to "sars" (legacy "sa" accepted). Clients may send
        // the real binary path (e.g. zig-out/bin/sars) or omit argv[0]
        // entirely and start at the command.
        if (list.items.len == 0) {
            try list.insert(0, try allocator.dupe(u8, "sars"));
        } else if (std.mem.eql(u8, list.items[0], "sars") or std.mem.endsWith(u8, list.items[0], "/sars") or std.mem.eql(u8, list.items[0], "sa") or std.mem.endsWith(u8, list.items[0], "/sa")) {
            if (!std.mem.eql(u8, list.items[0], "sars")) {
                allocator.free(list.items[0]);
                list.items[0] = try allocator.dupe(u8, "sars");
            }
        } else if (commandFromName(list.items[0]) != null or std.mem.eql(u8, list.items[0], "help") or std.mem.eql(u8, list.items[0], "version")) {
            try list.insert(0, try allocator.dupe(u8, "sars"));
        } else {
            // Unknown first token: still force sars so dispatch can error cleanly.
            try list.insert(0, try allocator.dupe(u8, "sars"));
        }
        return try list.toOwnedSlice();
    }

    // Document-style: {"op":"build","file":"x.sars","args":["--json"]}
    const op = daemon_cancel.parseJsonStrField(request, "\"op\"") orelse return error.InvalidRequest;
    var list = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (list.items) |it| allocator.free(it);
        list.deinit();
    }
    try list.append(try allocator.dupe(u8, "sars"));
    try list.append(try allocator.dupe(u8, op));
    if (daemon_cancel.parseJsonStrField(request, "\"file\"")) |file| {
        try list.append(try allocator.dupe(u8, file));
    }
    // Best-effort: pull string items after "args"
    if (std.mem.indexOf(u8, request, "\"args\"")) |ap| {
        const sub = request[ap..];
        const lb = std.mem.indexOfScalar(u8, sub, '[') orelse 0;
        const rb = std.mem.indexOfScalar(u8, sub, ']') orelse 0;
        if (rb > lb) {
            const inner = sub[lb + 1 .. rb];
            var i: usize = 0;
            while (i < inner.len) {
                if (inner[i] != '"') {
                    i += 1;
                    continue;
                }
                i += 1;
                var item = std.array_list.Managed(u8).init(allocator);
                errdefer item.deinit();
                while (i < inner.len and inner[i] != '"') {
                    if (inner[i] == '\\' and i + 1 < inner.len) i += 1;
                    try item.append(inner[i]);
                    i += 1;
                }
                i += 1;
                try list.append(try item.toOwnedSlice());
            }
        }
    }
    return try list.toOwnedSlice();
}

fn freeDaemonArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |a| allocator.free(a);
    allocator.free(argv);
}

fn restrictDaemonSocket(socket_path: []const u8) bool {
    if (comptime builtin.os.tag != .linux) return true;
    var path_buf: [sio.max_path_bytes + 1]u8 = undefined;
    const path_slice = std.fmt.bufPrint(path_buf[0..sio.max_path_bytes], "{s}", .{socket_path}) catch return false;
    path_buf[path_slice.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);
    const rc = std.os.linux.chmod(path_z, 0o600);
    return std.os.linux.errno(rc) == .SUCCESS;
}

fn daemonCommand(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    // The persistent daemon relies on Unix-domain sockets, which are not
    // available on Windows targets (Zig 0.14.1 std.net also fails to compile
    // initUnix/connectUnixSocket for windows-gnu). Comptime branch keeps the
    // unix-only body out of Windows semantic analysis.
    if (comptime builtin.os.tag == .windows) {
        try stderr.print("daemon: not supported on Windows\n", .{});
        return 1;
    } else {
        return try daemonCommandUnix(allocator, args, stdout, stderr);
    }
}

fn daemonCommandUnix(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    var socket_path: []const u8 = "/tmp/sa-daemon.sock";
    var max_workers: usize = 8;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--socket") and i + 1 < args.len) {
            socket_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--max-workers") and i + 1 < args.len) {
            max_workers = std.fmt.parseInt(usize, args[i + 1], 10) catch 8;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--per-agent-limit") and i + 1 < args.len) {
            daemon_cancel.setPerAgentLimit(std.fmt.parseInt(u32, args[i + 1], 10) catch 4);
            i += 1;
        }
    }
    sio.cwd().deleteFile(socket_path) catch {};
    const ua = try std.Io.net.UnixAddress.init(socket_path);
    var server = ua.listen(sio.io(), .{}) catch |err| {
        try stderr.print("daemon: failed to listen on {s}: {s}\n", .{ socket_path, @errorName(err) });
        return 1;
    };
    defer server.deinit(sio.io());
    if (!restrictDaemonSocket(socket_path)) {
        try stderr.print("daemon: failed to restrict socket permissions for {s}\n", .{socket_path});
        return 1;
    }
    try stdout.print("sars daemon listening on {s} (max_workers={d})\n", .{ socket_path, max_workers });

    var in_flight = std.atomic.Value(usize).init(0);
    daemon_shutdown_flag.store(false, .monotonic);
    while (!daemon_shutdown_flag.load(.monotonic)) {
        const stream = server.accept(sio.io()) catch |err| {
            if (daemon_shutdown_flag.load(.monotonic)) break;
            try stderr.print("daemon: accept failed: {s}\n", .{@errorName(err)});
            continue;
        };
        // Backpressure: at capacity, handle inline (blocks accept) instead of
        // spawning unbounded threads. Bounds memory under many agents.
        daemon_in_flight_global.store(in_flight.load(.monotonic), .monotonic);
        if (in_flight.load(.monotonic) >= max_workers) {
            handleDaemonConnection(allocator, stream);
            continue;
        }
        _ = in_flight.fetchAdd(1, .monotonic);
        daemon_in_flight_global.store(in_flight.load(.monotonic), .monotonic);
        const thread = std.Thread.spawn(.{}, daemonWorker, .{ allocator, stream, &in_flight }) catch {
            _ = in_flight.fetchSub(1, .monotonic);
            handleDaemonConnection(allocator, stream);
            continue;
        };
        thread.detach();
    }
    // Wait briefly for in-flight workers to drain.
    var spins: usize = 0;
    while (in_flight.load(.monotonic) > 0 and spins < 1000) : (spins += 1) {
        sio.io().sleep(.fromNanoseconds(1 * std.time.ns_per_ms), .awake) catch {};
    }
    sio.cwd().deleteFile(socket_path) catch {};
    return 0;
}

fn trapFromFlattenError(source_path: []const u8, source: []const u8, err: anyerror, last_line: ?u32) trap.TrapReport {
    const forbidden = flattener.findFirstForbiddenLine(source);
    const line_no = if (forbidden) |hit| hit.line_no else last_line orelse 1;
    const line_text = lineAt(source, line_no);
    const source_text = if (line_text) |line| std.mem.trimEnd(u8, line, "\r") else null;
    const source_text_buf: [256]u8 = std.mem.zeroes([256]u8);
    const original_text_buf: [256]u8 = std.mem.zeroes([256]u8);
    const file_buf: [128]u8 = std.mem.zeroes([128]u8);
    const bad_token_buf: [64]u8 = std.mem.zeroes([64]u8);
    var report: trap.TrapReport = switch (err) {
        error.ForbiddenSyntax => .{
            .trap = .forbidden_syntax,
            .trap_code = trap.trapCode(.forbidden_syntax),
            .file_buf = file_buf,
            .file = source_path,
            .line = line_no,
            .source_line = line_no,
            .column = if (forbidden) |hit| @as(u32, @intCast(hit.hit.column)) else null,
            .source_text_buf = source_text_buf,
            .original_text_buf = original_text_buf,
            .source_text = null,
            .original_text = null,
            .bad_token_buf = bad_token_buf,
            .bad_token = if (forbidden) |hit| switch (hit.hit.token) {
                .brace_open => "{",
                .brace_close => "}",
                .keyword_if => "if",
                .keyword_else => "else",
                .keyword_while => "while",
                .keyword_for => "for",
                .property_chain => ".",
            } else null,
            .context = .{ .{}, .{}, .{}, .{}, .{} },
            .context_len = 0,
            .register = null,
            .registers = &.{},
            .expected_mask = null,
            .actual_mask = null,
            .expected_mask_name = null,
            .actual_mask_name = null,
            .function = null,
            .is_ffi_wrapper = null,
            .message = "forbidden syntax detected during flattening",
            .hint = if (forbidden) |hit| forbiddenHint(hit.hit) else null,
        },
        error.UnsupportedType => .{
            .trap = .unsupported_type,
            .trap_code = trap.trapCode(.unsupported_type),
            .file_buf = file_buf,
            .file = source_path,
            .line = line_no,
            .source_line = line_no,
            .column = if (line_text) |lt| if (std.mem.indexOfAny(u8, lt, "*&")) |idx| @as(u32, @intCast(idx + 1)) else null else null,
            .source_text_buf = source_text_buf,
            .original_text_buf = original_text_buf,
            .source_text = null,
            .original_text = null,
            .bad_token_buf = bad_token_buf,
            .bad_token = firstBadTokenForTypeLine(source_text),
            .context = .{ .{}, .{}, .{}, .{}, .{} },
            .context_len = 0,
            .register = null,
            .registers = &.{},
            .expected_mask = null,
            .actual_mask = null,
            .expected_mask_name = null,
            .actual_mask_name = null,
            .function = null,
            .is_ffi_wrapper = null,
            .message = "unsupported type annotation during flattening",
            .hint = unsupportedTypeHint(line_text),
            .repair_alternatives = .{ null, null, null },
            .repair_alternatives_len = 0,
        },
        error.InvalidImportPath, error.PackageNotResolved, error.AmbiguousPackageVersion, error.PrecompiledArtifactRejected, error.InvalidPath => .{
            .trap = .import_resolution_failed,
            .trap_code = trap.trapCode(.import_resolution_failed),
            .file_buf = file_buf,
            .file = source_path,
            .line = line_no,
            .source_line = line_no,
            .column = null,
            .source_text_buf = source_text_buf,
            .original_text_buf = original_text_buf,
            .source_text = null,
            .original_text = null,
            .bad_token_buf = bad_token_buf,
            .bad_token = null,
            .context = .{ .{}, .{}, .{}, .{}, .{} },
            .context_len = 0,
            .register = null,
            .registers = &.{},
            .expected_mask = null,
            .actual_mask = null,
            .expected_mask_name = null,
            .actual_mask_name = null,
            .function = null,
            .is_ffi_wrapper = null,
            .message = importResolutionMessage(err),
            .hint = importResolutionHint(line_text, err),
            .repair_action = "fix-import",
            .repair_hint = importResolutionHint(line_text, err),
            .repair_confidence = if (err == error.InvalidImportPath) "high" else "medium",
            .repair_alternatives = .{ null, null, null },
            .repair_alternatives_len = 0,
        },
        error.OutOfMemory => .{
            .trap = .arena_oom,
            .trap_code = trap.trapCode(.arena_oom),
            .file_buf = file_buf,
            .file = source_path,
            .line = line_no,
            .source_line = line_no,
            .column = null,
            .source_text_buf = source_text_buf,
            .original_text_buf = original_text_buf,
            .source_text = null,
            .original_text = null,
            .bad_token_buf = bad_token_buf,
            .bad_token = null,
            .context = .{ .{}, .{}, .{}, .{}, .{} },
            .context_len = 0,
            .register = null,
            .registers = &.{},
            .expected_mask = null,
            .actual_mask = null,
            .expected_mask_name = null,
            .actual_mask_name = null,
            .function = null,
            .is_ffi_wrapper = null,
            .message = "out of memory while flattening",
            .hint = null,
        },
        error.ImportCycle => .{
            .trap = .forbidden_syntax,
            .trap_code = trap.trapCode(.forbidden_syntax),
            .file_buf = file_buf,
            .file = source_path,
            .line = line_no,
            .source_line = line_no,
            .column = null,
            .source_text_buf = source_text_buf,
            .original_text_buf = original_text_buf,
            .source_text = null,
            .original_text = null,
            .bad_token_buf = bad_token_buf,
            .bad_token = null,
            .context = .{ .{}, .{}, .{}, .{}, .{} },
            .context_len = 0,
            .register = null,
            .registers = &.{},
            .expected_mask = null,
            .actual_mask = null,
            .expected_mask_name = null,
            .actual_mask_name = null,
            .function = null,
            .is_ffi_wrapper = null,
            .message = "import cycle detected during flattening",
            .hint = "break the cycle in imported files or inline the shared definitions",
        },
        error.DuplicateDef => .{
            .trap = .duplicate_def,
            .trap_code = trap.trapCode(.duplicate_def),
            .file_buf = file_buf,
            .file = source_path,
            .line = line_no,
            .source_line = line_no,
            .column = null,
            .source_text_buf = source_text_buf,
            .original_text_buf = original_text_buf,
            .source_text = null,
            .original_text = null,
            .bad_token_buf = bad_token_buf,
            .bad_token = null,
            .context = .{ .{}, .{}, .{}, .{}, .{} },
            .context_len = 0,
            .register = null,
            .registers = &.{},
            .expected_mask = null,
            .actual_mask = null,
            .expected_mask_name = null,
            .actual_mask_name = null,
            .function = null,
            .is_ffi_wrapper = null,
            .message = "duplicate definition detected during flattening",
            .hint = null,
        },
        error.UnknownNpmBindTarget => .{
            .trap = .import_resolution_failed,
            .trap_code = trap.trapCode(.import_resolution_failed),
            .file_buf = file_buf,
            .file = source_path,
            .line = line_no,
            .source_line = line_no,
            .column = null,
            .source_text_buf = source_text_buf,
            .original_text_buf = original_text_buf,
            .source_text = null,
            .original_text = null,
            .bad_token_buf = bad_token_buf,
            .bad_token = null,
            .context = .{ .{}, .{}, .{}, .{}, .{} },
            .context_len = 0,
            .register = null,
            .registers = &.{},
            .expected_mask = null,
            .actual_mask = null,
            .expected_mask_name = null,
            .actual_mask_name = null,
            .function = null,
            .is_ffi_wrapper = null,
            .message = "#npm_bind target must name a declared @extern function",
            .hint = "bind each #npm_bind line to an @extern with the same name; npm bindings are only honored by `sa build-js`",
            .repair_action = "fix-import",
            .repair_hint = "bind each #npm_bind line to an @extern with the same name",
            .repair_confidence = "high",
            .repair_alternatives = .{ null, null, null },
            .repair_alternatives_len = 0,
        },
        error.MacroRecursionLimit => .{
            .trap = .macro_recursion_limit,
            .trap_code = trap.trapCode(.macro_recursion_limit),
            .file_buf = file_buf,
            .file = source_path,
            .line = line_no,
            .source_line = line_no,
            .column = null,
            .source_text_buf = source_text_buf,
            .original_text_buf = original_text_buf,
            .source_text = null,
            .original_text = null,
            .bad_token_buf = bad_token_buf,
            .bad_token = null,
            .context = .{ .{}, .{}, .{}, .{}, .{} },
            .context_len = 0,
            .register = null,
            .registers = &.{},
            .expected_mask = null,
            .actual_mask = null,
            .expected_mask_name = null,
            .actual_mask_name = null,
            .function = null,
            .is_ffi_wrapper = null,
            .message = "macro recursion limit exceeded",
            .hint = null,
        },
        error.InvalidAtomicOrdering => .{
            .trap = .invalid_atomic_ordering,
            .trap_code = trap.trapCode(.invalid_atomic_ordering),
            .file_buf = file_buf,
            .file = source_path,
            .line = line_no,
            .source_line = line_no,
            .column = null,
            .source_text_buf = source_text_buf,
            .original_text_buf = original_text_buf,
            .source_text = null,
            .original_text = null,
            .bad_token_buf = bad_token_buf,
            .bad_token = null,
            .context = .{ .{}, .{}, .{}, .{}, .{} },
            .context_len = 0,
            .register = null,
            .registers = &.{},
            .expected_mask = null,
            .actual_mask = null,
            .expected_mask_name = null,
            .actual_mask_name = null,
            .function = null,
            .is_ffi_wrapper = null,
            .message = "invalid atomic ordering",
            .hint = null,
        },
        error.InvalidMacroInvocation, error.InvalidMacroDefinitionContext, error.UnbalancedMacro, error.UnbalancedRep, error.InvalidSyntax => .{
            .trap = .forbidden_syntax,
            .trap_code = trap.trapCode(.forbidden_syntax),
            .file_buf = file_buf,
            .file = source_path,
            .line = line_no,
            .source_line = line_no,
            .column = null,
            .source_text_buf = source_text_buf,
            .original_text_buf = original_text_buf,
            .source_text = null,
            .original_text = null,
            .bad_token_buf = bad_token_buf,
            .bad_token = null,
            .context = .{ .{}, .{}, .{}, .{}, .{} },
            .context_len = 0,
            .register = null,
            .registers = &.{},
            .expected_mask = null,
            .actual_mask = null,
            .expected_mask_name = null,
            .actual_mask_name = null,
            .function = null,
            .is_ffi_wrapper = null,
            .message = @errorName(err),
            .hint = switch (err) {
                error.InvalidMacroInvocation => "check the macro name, argument count, and comma-separated expansion syntax",
                error.InvalidMacroDefinitionContext => "macro definitions are only allowed at top level",
                error.UnbalancedMacro => "make sure [MACRO] has a matching [END_MACRO]",
                error.UnbalancedRep => "make sure [REP] has a matching [END_REP]",
                error.InvalidSyntax => "check the flattened line syntax and operand ordering",
                else => null,
            },
        },
        else => .{
            .trap = .forbidden_syntax,
            .trap_code = trap.trapCode(.forbidden_syntax),
            .file_buf = file_buf,
            .file = source_path,
            .line = line_no,
            .source_line = line_no,
            .column = null,
            .source_text_buf = source_text_buf,
            .original_text_buf = original_text_buf,
            .source_text = null,
            .original_text = null,
            .bad_token_buf = bad_token_buf,
            .bad_token = null,
            .context = .{ .{}, .{}, .{}, .{}, .{} },
            .context_len = 0,
            .register = null,
            .registers = &.{},
            .expected_mask = null,
            .actual_mask = null,
            .expected_mask_name = null,
            .actual_mask_name = null,
            .function = null,
            .is_ffi_wrapper = null,
            .message = @errorName(err),
            .hint = "flattening failed before a public trap mapping was available",
        },
    };
    if (line_text) |line| {
        const excerpt = sourceExcerpt(line);
        setLineText(&report, excerpt);
        fillContextWindow(&report, source, line_no);
    }
    switch (report.trap) {
        .forbidden_syntax => {
            report.repair_action = "rewrite";
            report.repair_hint = "lower structured control flow into labels, branches, and explicit register moves";
            report.repair_confidence = "high";
            setRepairAlternatives(&report, &.{ "jmp", "label", "ptr" });
        },
        .unsupported_type => {
            report.repair_action = "inspect-signature";
            report.repair_hint = "replace unsupported structured types with ptr or a primitive SA type and adjust the callee signature";
            report.repair_confidence = "medium";
            setRepairAlternatives(&report, &.{ "ptr", "u64", "i64" });
        },
        .import_resolution_failed => {
            report.repair_action = "pin-import";
            report.repair_hint = "pin one package ref or replace the import path with a unique local package identity";
            report.repair_confidence = "medium";
            setRepairAlternatives(&report, &.{ "sa.mod", "local package", "pinned ref" });
        },
        .duplicate_def => {
            report.repair_action = "rename-def";
            report.repair_hint = "change one of the conflicting names or namespace the symbol";
            report.repair_confidence = "high";
        },
        .macro_recursion_limit => {
            report.repair_action = "simplify-macro";
            report.repair_hint = "reduce recursive expansion depth or inline the macro body";
            report.repair_confidence = "medium";
        },
        .invalid_atomic_ordering => {
            report.repair_action = "adjust-ordering";
            report.repair_hint = "use a success ordering that is not weaker than the failure ordering";
            report.repair_confidence = "medium";
        },
        else => {},
    }
    return report;
}

const PackageTrapInfo = struct {
    kind: trap.Trap,
    message: []const u8,
    hint: ?[]const u8,
};

fn trapFromPackagePreflightError(err: anyerror) ?trap.TrapReport {
    const info: PackageTrapInfo = switch (err) {
        error.ForbiddenGlobalConfig => .{
            .kind = .forbidden_global_config,
            .message = "global SA package configuration is forbidden for reproducible builds",
            .hint = "remove ~/.sa/config.toml, ~/.sa/mirror.toml, and /etc/sa/*.toml; use sa.mod or project .sa_env mirrors instead",
        },
        error.SumHashMismatch => .{
            .kind = .sum_hash_mismatch,
            .message = "sa.sum does not match the resolved dependency tree",
            .hint = "run sa install to refresh sa.sum, or restore the vendored dependency source",
        },
        error.UpstreamShaMismatch => .{
            .kind = .upstream_sha_mismatch,
            .message = "package source hash does not match the granted requirement",
            .hint = "verify the dependency source and update the manifest hash only after auditing it",
        },
        error.UnauthorizedPrimitive => .{
            .kind = .unauthorized_primitive,
            .message = "package uses @sys_* outside its declared grants",
            .hint = "add the explicit grant only after auditing the package source, or remove the dependency",
        },
        error.MissingTtyForConfirmation => .{
            .kind = .missing_tty_for_confirmation,
            .message = "high-risk package confirmation requires an interactive TTY",
            .hint = "run from a real terminal and type the full package URL, or use CI taint mode deliberately",
        },
        error.BlockedRiskUnconfirmed => .{
            .kind = .blocked_risk_unconfirmed,
            .message = "high-risk package confirmation did not match the full package URL",
            .hint = "rerun and type the exact package URL shown in the review banner",
        },
        error.AutoApproveForbidden => .{
            .kind = .blocked_risk_unconfirmed,
            .message = "package risk confirmation cannot be auto-approved",
            .hint = "remove --yes/--auto-approve and type the exact package URL in a TTY",
        },
        error.UnauditedRiskBlocked => .{
            .kind = .blocked_risk_unconfirmed,
            .message = "CI blocked a high-risk unaudited package",
            .hint = "audit the dependency locally or rerun CI with --allow-unaudited-risks to produce a tainted build",
        },
        error.PackageNotResolved, error.InvalidImportPath, error.AmbiguousPackageVersion, error.PrecompiledArtifactRejected, error.InvalidPath => .{
            .kind = .import_resolution_failed,
            .message = importResolutionMessage(err),
            .hint = importResolutionHint(null, err),
        },
        else => return null,
    };

    return .{
        .trap = info.kind,
        .trap_code = trap.trapCode(info.kind),
        .line = 1,
        .source_line = 1,
        .registers = &.{},
        .message = info.message,
        .hint = info.hint,
    };
}

fn pathExists(path: []const u8) !bool {
    sio.cwd().access(path, .{ .read = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn dirExists(path: []const u8) bool {
    var dir = sio.cwd().openDir(path, .{ .iterate = true }) catch return false;
    dir.close();
    return true;
}

fn globalCacheRoot(allocator: std.mem.Allocator, identity: []const u8, ref: []const u8) ![]u8 {
    const home = sio.getEnvVarOwned(allocator, "HOME") catch {
        return error.PackageNotResolved;
    };
    defer allocator.free(home);
    const leaf = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ identity, ref });
    defer allocator.free(leaf);
    return try std.fs.path.join(allocator, &.{ home, ".sa", "pkg", leaf });
}

fn resolvePackageAuditRoot(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    entry: manifest.RequireEntry,
    offline: bool,
) ![]u8 {
    const local_root = try std.fs.path.join(allocator, &.{ project_root, "sa_vendor", entry.url });
    errdefer allocator.free(local_root);
    if (dirExists(local_root)) return local_root;
    allocator.free(local_root);

    if (offline) return error.PackageNotResolved;

    const global_root = try globalCacheRoot(allocator, entry.url, entry.ref);
    errdefer allocator.free(global_root);
    if (dirExists(global_root)) return global_root;
    allocator.free(global_root);

    return error.PackageNotResolved;
}

fn hashesEqual(lhs: [32]u8, rhs: [32]u8) bool {
    return std.mem.eql(u8, lhs[0..], rhs[0..]);
}

fn appendCiSummaryIfConfigured(
    allocator: std.mem.Allocator,
    report: pkg_audit.AuditReport,
    status: pkg_ci.VerifyStatus,
) !void {
    const summary_path = sio.getEnvVarOwned(allocator, "GITHUB_STEP_SUMMARY") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return,
        else => return err,
    };
    defer allocator.free(summary_path);
    var summary_file = try sio.cwd().openFile(summary_path, .{ .mode = .write_only });
    defer summary_file.close();
    try summary_file.seekTo(try summary_file.getEndPos());
    var sbuf: [8192]u8 = undefined;
    var sw = summary_file.writer(&sbuf);
    try pkg_ci.writeGithubSummary(&sw.interface, report, status);
    try sw.interface.flush();
}

fn preflightCiPackage(
    allocator: std.mem.Allocator,
    report: pkg_audit.AuditReport,
    expected_source_sha256: [32]u8,
    options: CompileOptions,
) !void {
    const status = try pkg_ci.dualTrackVerify(report, .{
        .expected_source_sha256 = expected_source_sha256,
        .allow_unaudited_risks = options.allow_unaudited_risks,
    });
    if (status == .tainted_unaudited_code) {
        var null_buf: [64]u8 = undefined;
        var null_discarding: std.Io.Writer.Discarding = .init(&null_buf);
        const writer = options.diagnostic_writer orelse &null_discarding.writer;
        try pkg_ci.writeTaintBanner(writer, report);
        try appendCiSummaryIfConfigured(allocator, report, status);
    }
}

fn preflightInteractivePackage(
    report: pkg_audit.AuditReport,
    expected_source_sha256: [32]u8,
    session: *pkg_confirm.Session,
    options: CompileOptions,
) !void {
    if (!hashesEqual(report.source_sha256, expected_source_sha256)) return error.UpstreamShaMismatch;

    var empty_input: std.Io.Reader = .fixed("");
    var null_buf: [64]u8 = undefined;
    var null_discarding: std.Io.Writer.Discarding = .init(&null_buf);
    const base_reader = options.stdin_reader orelse &empty_input;
    const stdin_adapter = StdinLineReader{ .inner = base_reader };
    const writer = options.diagnostic_writer orelse &null_discarding.writer;
    const stdin_is_tty = options.stdin_is_tty orelse stdinIsTty();
    try pkg_confirm.confirmWithReaderWriter(
        session,
        report,
        stdin_adapter,
        writer,
        stdin_is_tty,
        options.auto_approve_requested,
    );
}

fn verifyProjectPackageState(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    project_manifest: manifest.Manifest,
    options: CompileOptions,
) !void {
    try pkg_mirror.rejectForbiddenGlobalConfig(allocator);

    const sum_path = try std.fs.path.join(allocator, &.{ project_root, "sa.sum" });
    defer allocator.free(sum_path);
    if (try pathExists(sum_path)) {
        try pkg_sum.verifyProjectSum(allocator, project_root, project_manifest);
    }

    var session = pkg_confirm.Session.init(allocator);
    defer session.deinit();
    const stdin_is_tty = options.stdin_is_tty orelse stdinIsTty();
    const ci_mode = pkg_ci.detectMode(.{
        .explicit_ci = options.ci,
        // Plain pipes must not silently become the CI taint path; they should
        // hit the interactive confirmation guard and fail with MissingTty.
        .stdin_is_tty = if (options.ci) stdin_is_tty else true,
    });
    if (options.permission_set) |set_name| {
        if (!manifestPermissionSetExists(project_manifest, set_name)) return error.InvalidPermissionSet;
    } else if (ci_mode and project_manifest.permission_sets.len != 0 and !compileOptionsHaveAllowList(options)) {
        return error.MissingPermissionSet;
    }

    for (project_manifest.requires) |entry| {
        const audit_root = try resolvePackageAuditRoot(allocator, project_root, entry, options.offline);
        defer allocator.free(audit_root);
        var report = try pkg_audit.auditPackage(allocator, entry.url, entry.ref, audit_root, entry.grants);
        defer report.deinit(allocator);

        if (ci_mode) {
            try preflightCiPackage(allocator, report, entry.source_sha256, options);
        } else {
            try preflightInteractivePackage(report, entry.source_sha256, &session, options);
        }
    }
}

fn manifestPermissionSetExists(project_manifest: manifest.Manifest, name: []const u8) bool {
    for (project_manifest.permission_sets) |set| {
        if (std.mem.eql(u8, set.name, name)) return true;
    }
    return false;
}

fn compileOptionsHaveAllowList(options: CompileOptions) bool {
    return options.allow_env_requested or
        options.allow_net_requested or
        options.allow_read_requested or
        options.allow_write_requested or
        options.allow_run_requested;
}

fn consumeCompileOption(arg: []const u8, args: []const []const u8, index: *usize, options: *CompileOptions) !bool {
    if (try consumeJobsOption(arg, args, index, options)) return true;
    if (try consumeDceOption(arg, args, index, options)) return true;
    if (try consumePackageOption(arg, args, index, options)) return true;
    if (consumeProfileOption(arg, options)) return true;
    if (consumeMemReportOption(arg, options)) return true;
    if (try consumePermissionSetOption(arg, args, index, options)) return true;
    if (consumeAllowOption(arg, options)) return true;
    if (std.mem.eql(u8, arg, "--offline")) {
        options.offline = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--no-incremental")) {
        options.incremental_cache = false;
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--project-root=")) {
        options.project_root = arg["--project-root=".len..];
        if (options.project_root.?.len == 0) return error.InvalidPath;
        return true;
    }
    if (std.mem.eql(u8, arg, "--project-root")) {
        if (index.* + 1 >= args.len) return error.InvalidPath;
        options.project_root = args[index.* + 1];
        if (options.project_root.?.len == 0) return error.InvalidPath;
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--ci")) {
        options.ci = true;
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--target=")) {
        const triple = arg["--target=".len..];
        if (triple.len == 0) return error.InvalidTarget;
        options.target_triple = triple;
        return true;
    }
    if (std.mem.eql(u8, arg, "--target")) {
        if (index.* + 1 >= args.len) return error.InvalidTarget;
        const triple = args[index.* + 1];
        if (triple.len == 0) return error.InvalidTarget;
        options.target_triple = triple;
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--allow-unaudited-risks")) {
        options.allow_unaudited_risks = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "--auto-approve")) {
        options.auto_approve_requested = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--default-immutable")) {
        options.default_immutable = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--rust-strict-mut")) {
        options.rust_strict_mut = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--rust-copy-elision")) {
        options.rust_copy_elision = true;
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--edition=")) {
        const edition = arg["--edition=".len..];
        if (std.mem.eql(u8, edition, "rust") or std.mem.eql(u8, edition, "2024-rust") or std.mem.eql(u8, edition, "rust-edition")) {
            options.rust_edition = true;
            options.default_immutable = true;
            options.rust_strict_mut = true;
            options.rust_copy_elision = true;
            return true;
        }
        return false;
    }
    if (std.mem.eql(u8, arg, "--edition")) {
        if (index.* + 1 >= args.len) return false;
        const edition = args[index.* + 1];
        if (std.mem.eql(u8, edition, "rust") or std.mem.eql(u8, edition, "2024-rust") or std.mem.eql(u8, edition, "rust-edition")) {
            options.rust_edition = true;
            options.default_immutable = true;
            options.rust_strict_mut = true;
            options.rust_copy_elision = true;
            index.* += 1;
            return true;
        }
        return false;
    }
    return false;
}

fn consumePackageOption(arg: []const u8, args: []const []const u8, index: *usize, options: *CompileOptions) !bool {
    if (std.mem.startsWith(u8, arg, "--package=")) {
        options.package_name = arg["--package=".len..];
        if (options.package_name.?.len == 0) return error.UnknownPackage;
        return true;
    }
    if (std.mem.eql(u8, arg, "--package") or std.mem.eql(u8, arg, "-p")) {
        if (index.* + 1 >= args.len) return error.UnknownPackage;
        options.package_name = args[index.* + 1];
        if (options.package_name.?.len == 0) return error.UnknownPackage;
        index.* += 1;
        return true;
    }
    if (std.mem.startsWith(u8, arg, "-p=")) {
        options.package_name = arg["-p=".len..];
        if (options.package_name.?.len == 0) return error.UnknownPackage;
        return true;
    }
    return false;
}

fn parseDceValue(text: []const u8) !DceMode {
    return DceMode.parse(text) orelse error.InvalidDceMode;
}

fn consumeDceOption(arg: []const u8, args: []const []const u8, index: *usize, options: *CompileOptions) !bool {
    if (std.mem.startsWith(u8, arg, "--dce=")) {
        options.dce = try parseDceValue(arg["--dce=".len..]);
        return true;
    }
    if (std.mem.eql(u8, arg, "--dce")) {
        if (index.* + 1 >= args.len) return error.MissingDceMode;
        options.dce = try parseDceValue(args[index.* + 1]);
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--no-dce")) {
        options.dce = .no;
        return true;
    }
    return false;
}

fn consumePermissionSetOption(arg: []const u8, args: []const []const u8, index: *usize, options: *CompileOptions) !bool {
    if (std.mem.startsWith(u8, arg, "--permission-set=")) {
        options.permission_set = arg["--permission-set=".len..];
        if (options.permission_set.?.len == 0) return error.InvalidPermissionSet;
        return true;
    }
    if (std.mem.eql(u8, arg, "--permission-set")) {
        if (index.* + 1 >= args.len) return error.MissingPermissionSet;
        options.permission_set = args[index.* + 1];
        index.* += 1;
        return true;
    }
    if (std.mem.startsWith(u8, arg, "-P=")) {
        options.permission_set = arg["-P=".len..];
        if (options.permission_set.?.len == 0) return error.InvalidPermissionSet;
        return true;
    }
    if (std.mem.eql(u8, arg, "-P")) {
        options.permission_set = "default";
        return true;
    }
    return false;
}

fn consumeAllowOption(arg: []const u8, options: *CompileOptions) bool {
    if (std.mem.eql(u8, arg, "--allow-env") or std.mem.startsWith(u8, arg, "--allow-env=")) {
        options.allow_env_requested = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--allow-net") or std.mem.startsWith(u8, arg, "--allow-net=")) {
        options.allow_net_requested = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--allow-read") or std.mem.startsWith(u8, arg, "--allow-read=")) {
        options.allow_read_requested = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--allow-write") or std.mem.startsWith(u8, arg, "--allow-write=")) {
        options.allow_write_requested = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--allow-run") or std.mem.startsWith(u8, arg, "--allow-run=")) {
        options.allow_run_requested = true;
        return true;
    }
    return false;
}

fn parseJobsValue(text: []const u8) !?usize {
    if (std.mem.eql(u8, text, "auto")) return null;
    const jobs = std.fmt.parseInt(usize, text, 10) catch return error.InvalidJobs;
    if (jobs == 0) return error.InvalidJobs;
    return jobs;
}

fn consumeJobsOption(arg: []const u8, args: []const []const u8, index: *usize, options: *CompileOptions) !bool {
    if (!std.mem.eql(u8, arg, "--jobs")) return false;
    if (index.* + 1 >= args.len) return error.MissingJobs;
    options.jobs = try parseJobsValue(args[index.* + 1]);
    options.jobs_explicit = true;
    index.* += 1;
    return true;
}

fn consumeProfileOption(arg: []const u8, options: *CompileOptions) bool {
    if (!std.mem.eql(u8, arg, "--profile")) return false;
    options.profile = true;
    return true;
}

fn consumeMemReportOption(arg: []const u8, options: *CompileOptions) bool {
    if (!std.mem.eql(u8, arg, "--mem-report")) return false;
    options.mem_report = true;
    return true;
}

pub const ExecuteOptions = struct {
    stdin_reader: ?*std.Io.Reader = null,
    stdin_is_tty: ?bool = null,
};

fn applyExecuteOptions(options: *CompileOptions, exec_options: ExecuteOptions, diagnostic_writer: *std.Io.Writer) void {
    options.stdin_reader = exec_options.stdin_reader;
    options.stdin_is_tty = exec_options.stdin_is_tty;
    options.diagnostic_writer = diagnostic_writer;
}

fn newCompileOptions(exec_options: ExecuteOptions, diagnostic_writer: *std.Io.Writer) CompileOptions {
    var options: CompileOptions = .{};
    applyExecuteOptions(&options, exec_options, diagnostic_writer);
    return options;
}

fn configureCompileDiagnostics(options: *CompileOptions, json_mode: bool) void {
    options.mem_report_live = options.mem_report and !json_mode;
}

fn loadSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (builtin.is_test) test_source_tree_load_count += 1;
    var file = try sio.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
}

fn loadSabFlat(allocator: std.mem.Allocator, source_path: []const u8) !flattener.FlattenResult {
    const bytes = try loadSource(allocator, source_path);
    defer allocator.free(bytes);
    var module = try sab.decodeModule(allocator, bytes);
    errdefer module.deinit(allocator);

    var symbols = flattener.SymbolTable.init(allocator);
    errdefer symbols.deinit();
    for (module.symbols) |name| _ = try symbols.intern(name);

    if (module.owns_symbol_text) {
        for (module.symbols) |name| allocator.free(name);
    }
    allocator.free(module.symbols);
    module.symbols = &.{};
    module.owns_symbol_text = false;

    var test_sigs = std.array_list.Managed(flattener.FunctionSig).init(allocator);
    errdefer test_sigs.deinit();
    for (module.function_sigs) |fsig| {
        if (fsig.kind == .test_func) try test_sigs.append(fsig);
    }

    const loc_table = try allocator.alloc(?common_upstream.UpstreamLoc, module.instructions.len);
    @memset(loc_table, null);

    const result = flattener.FlattenResult{
        .instructions = module.instructions,
        .const_decls = module.const_decls,
        .function_sigs = module.function_sigs,
        .test_sigs = try test_sigs.toOwnedSlice(),
        .cached_macro_defs = &.{},
        .def_dict = flattener.DefDict.init(allocator),
        .symbols = symbols,
        .loc_table = loc_table,
        .layout_versions = &.{},
        .package_identities = std.StringHashMap(void).init(allocator),
        .owned_text = module.owned_text,
        .trap = null,
    };
    module.instructions = &.{};
    module.const_decls = &.{};
    module.function_sigs = &.{};
    module.owned_text = &.{};
    return result;
}

fn collectSabTestListFast(allocator: std.mem.Allocator, source_path: []const u8) !test_meta.TestList {
    const bytes = try loadSource(allocator, source_path);
    defer allocator.free(bytes);

    const function_sigs = try sab.decodeTestFunctionSigsOnly(allocator, bytes);
    defer {
        for (function_sigs) |*function_sig| function_sig.deinit(allocator);
        allocator.free(function_sigs);
    }

    return try test_meta.collect(allocator, function_sigs);
}

fn hasExplicitTestSelection(selection: test_meta.TestSelection) bool {
    return selection.include_filters.len != 0 or
        selection.skip_filters.len != 0 or
        selection.exact or
        selection.ignored != .normal;
}

fn selectedTestNamesFromList(allocator: std.mem.Allocator, test_list: test_meta.TestList, selection: test_meta.TestSelection) ![]const []const u8 {
    if (!hasExplicitTestSelection(selection)) return &.{};
    const selected_count = selection.countSelected(test_list.tests);
    if (selected_count == 0) return &.{};

    const selected_names = try allocator.alloc([]const u8, selected_count);
    errdefer allocator.free(selected_names);
    var selected_index: usize = 0;
    for (test_list.tests) |test_case| {
        if (!selection.shouldRun(test_case)) continue;
        selected_names[selected_index] = test_case.selectorName();
        selected_index += 1;
    }
    return selected_names;
}

fn sabPruneDebugEnabled(allocator: std.mem.Allocator) bool {
    const value = sio.getEnvVarOwned(allocator, "SA_DEBUG_SAB_PRUNE") catch return false;
    defer allocator.free(value);
    return value.len != 0 and !std.mem.eql(u8, value, "0");
}

const SabFunctionRange = struct {
    sig_index: usize,
    start: usize,
    end: usize,
};

fn isSabFunctionDecl(kind: flattener.InstKind) bool {
    return switch (kind) {
        .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => true,
        else => false,
    };
}

fn buildSabFunctionRanges(allocator: std.mem.Allocator, instructions: []const flattener.Instruction) ![]SabFunctionRange {
    var ranges = std.array_list.Managed(SabFunctionRange).init(allocator);
    errdefer ranges.deinit();

    var current_start: ?usize = null;
    var current_sig_index: usize = 0;
    var next_sig_index: usize = 0;
    for (instructions, 0..) |item, idx| {
        if (!isSabFunctionDecl(item.kind)) continue;
        if (current_start) |start| {
            try ranges.append(.{
                .sig_index = current_sig_index,
                .start = start,
                .end = idx,
            });
        }
        current_start = idx;
        current_sig_index = next_sig_index;
        next_sig_index += 1;
    }
    if (current_start) |start| {
        try ranges.append(.{
            .sig_index = current_sig_index,
            .start = start,
            .end = instructions.len,
        });
    }
    return try ranges.toOwnedSlice();
}

fn putSabFunctionAlias(index: *std.StringHashMap(usize), name: []const u8, sig_index: usize) !void {
    if (name.len == 0 or index.contains(name)) return;
    try index.put(name, sig_index);
}

fn buildSabFunctionSigIndex(allocator: std.mem.Allocator, function_sigs: []const flattener.FunctionSig) !std.StringHashMap(usize) {
    var index = std.StringHashMap(usize).init(allocator);
    errdefer index.deinit();
    const max_aliases = std.math.mul(usize, function_sigs.len, 2) catch function_sigs.len;
    try index.ensureTotalCapacity(@intCast(max_aliases));
    for (function_sigs, 0..) |function_sig, sig_index| {
        try putSabFunctionAlias(&index, function_sig.name, sig_index);
        if (function_sig.llvm_name) |llvm_name| try putSabFunctionAlias(&index, llvm_name, sig_index);
    }
    return index;
}

fn buildSabConstIndex(allocator: std.mem.Allocator, const_decls: []const flattener.ConstDecl) !std.StringHashMap(usize) {
    var index = std.StringHashMap(usize).init(allocator);
    errdefer index.deinit();
    try index.ensureTotalCapacity(@intCast(const_decls.len));
    for (const_decls, 0..) |decl, const_index| {
        if (!index.contains(decl.name)) try index.put(decl.name, const_index);
    }
    return index;
}

fn markSabReachableByName(
    reachable: *std.AutoHashMap(usize, void),
    sig_index_by_name: *const std.StringHashMap(usize),
    name: []const u8,
) !bool {
    const sig_index = sig_index_by_name.get(name) orelse return false;
    if (reachable.contains(sig_index)) return false;
    try reachable.put(sig_index, {});
    return true;
}

fn sabReferenceName(text: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, text, " \t\r");
    while (trimmed.len != 0 and (trimmed[0] == '&' or trimmed[0] == '^' or trimmed[0] == '*')) {
        trimmed = std.mem.trim(u8, trimmed[1..], " \t\r");
    }
    return trimmed;
}

fn markSabReachableVtableConstByName(
    reachable_functions: *std.AutoHashMap(usize, void),
    reachable_vtable_consts: *std.AutoHashMap(usize, void),
    sig_index_by_name: *const std.StringHashMap(usize),
    const_index_by_name: *const std.StringHashMap(usize),
    const_decls: []const flattener.ConstDecl,
    name: []const u8,
) !bool {
    const normalized = sabReferenceName(name);
    if (normalized.len == 0) return false;
    const const_index = const_index_by_name.get(normalized) orelse return false;
    switch (const_decls[const_index].value) {
        .vtable => |literal| {
            var changed = false;
            if (!reachable_vtable_consts.contains(const_index)) {
                try reachable_vtable_consts.put(const_index, {});
                changed = true;
            }
            for (literal.slots) |slot| {
                changed = (try markSabReachableByName(reachable_functions, sig_index_by_name, slot.func_name)) or changed;
            }
            return changed;
        },
        else => return false,
    }
}

fn markSabReachableVtableConstFromOperand(
    reachable_functions: *std.AutoHashMap(usize, void),
    reachable_vtable_consts: *std.AutoHashMap(usize, void),
    sig_index_by_name: *const std.StringHashMap(usize),
    const_index_by_name: *const std.StringHashMap(usize),
    flat: *const flattener.FlattenResult,
    operand: anytype,
) !bool {
    const text = switch (operand) {
        .reg => |id| flat.symbols.lookupName(id),
        .symbol => |id| flat.symbols.lookupName(id),
        .label => |id| flat.symbols.lookupName(id),
        .func => |id| flat.symbols.lookupName(id),
        .text => |value| value,
        .native_text => |value| value,
        else => null,
    } orelse return false;
    return try markSabReachableVtableConstByName(reachable_functions, reachable_vtable_consts, sig_index_by_name, const_index_by_name, flat.const_decls, text);
}

fn freeFlatInstructionMetadata(allocator: std.mem.Allocator, item: flattener.Instruction) void {
    if (item.package_identity) |identity| allocator.free(identity);
    if (item.upstream_loc) |loc| allocator.free(loc.file);
    if (item.native_reg_names.len != 0) allocator.free(item.native_reg_names);
}

fn freeFlatLocEntry(allocator: std.mem.Allocator, entry: ?common_upstream.UpstreamLoc) void {
    if (entry) |loc| allocator.free(loc.file);
}

fn pruneSabVtableConsts(
    allocator: std.mem.Allocator,
    flat: *flattener.FlattenResult,
    reachable_vtable_consts: *const std.AutoHashMap(usize, void),
) !void {
    if (flat.const_decls.len == 0) return;

    var keep = try allocator.alloc(bool, flat.const_decls.len);
    defer allocator.free(keep);
    var pruned_any = false;
    var kept_count: usize = 0;
    for (flat.const_decls, 0..) |decl, const_index| {
        keep[const_index] = switch (decl.value) {
            .vtable => reachable_vtable_consts.contains(const_index),
            else => true,
        };
        if (keep[const_index]) {
            kept_count += 1;
        } else {
            pruned_any = true;
        }
    }
    if (!pruned_any) return;

    const new_const_decls = try allocator.alloc(flattener.ConstDecl, kept_count);
    var kept_index: usize = 0;
    for (flat.const_decls, 0..) |decl, const_index| {
        if (keep[const_index]) {
            new_const_decls[kept_index] = decl;
            kept_index += 1;
        } else {
            var dropped = decl;
            dropped.deinit(allocator);
        }
    }
    allocator.free(flat.const_decls);
    flat.const_decls = new_const_decls;
}

fn collectSabSelectedReachability(
    allocator: std.mem.Allocator,
    flat: *const flattener.FlattenResult,
    ranges: []const SabFunctionRange,
    sig_index_by_name: *const std.StringHashMap(usize),
    const_index_by_name: *const std.StringHashMap(usize),
    selected_test_names: []const []const u8,
    reachable_vtable_consts: *std.AutoHashMap(usize, void),
) !std.AutoHashMap(usize, void) {
    var reachable = std.AutoHashMap(usize, void).init(allocator);
    errdefer reachable.deinit();

    for (selected_test_names) |name| {
        _ = try markSabReachableByName(&reachable, sig_index_by_name, name);
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (ranges) |range| {
            if (!reachable.contains(range.sig_index)) continue;
            for (flat.instructions[range.start..range.end]) |item| {
                if (item.kind != .call and item.kind != .call_indirect) continue;
                var parsed = referee_call.parseInstructionCall(allocator, item, &flat.symbols) catch |err| switch (err) {
                    error.InvalidCallSyntax => continue,
                    else => return err,
                };
                defer parsed.deinit(allocator);
                if (parsed.is_indirect) continue;
                changed = (try markSabReachableByName(&reachable, sig_index_by_name, parsed.callee)) or changed;
            }
            for (flat.instructions[range.start..range.end]) |item| {
                inline for (0..4) |operand_index| {
                    changed = (try markSabReachableVtableConstFromOperand(&reachable, reachable_vtable_consts, sig_index_by_name, const_index_by_name, flat, item.operands[operand_index])) or changed;
                }
            }
        }
    }

    return reachable;
}

fn pruneSabFlatToSelectedTests(allocator: std.mem.Allocator, flat: *flattener.FlattenResult, selected_test_names: []const []const u8) !void {
    if (selected_test_names.len == 0 or flat.function_sigs.len == 0 or flat.instructions.len == 0) return;
    const original_function_count = flat.function_sigs.len;
    const original_test_count = flat.test_sigs.len;
    const original_instruction_count = flat.instructions.len;
    const original_const_count = flat.const_decls.len;

    const ranges = try buildSabFunctionRanges(allocator, flat.instructions);
    defer allocator.free(ranges);
    if (ranges.len == 0) return;

    var sig_index_by_name = try buildSabFunctionSigIndex(allocator, flat.function_sigs);
    defer sig_index_by_name.deinit();

    var const_index_by_name = try buildSabConstIndex(allocator, flat.const_decls);
    defer const_index_by_name.deinit();

    var reachable_vtable_consts = std.AutoHashMap(usize, void).init(allocator);
    defer reachable_vtable_consts.deinit();

    var reachable = try collectSabSelectedReachability(allocator, flat, ranges, &sig_index_by_name, &const_index_by_name, selected_test_names, &reachable_vtable_consts);
    defer reachable.deinit();
    if (reachable.count() == 0) return;

    var kept_sigs = std.array_list.Managed(flattener.FunctionSig).init(allocator);
    errdefer kept_sigs.deinit();
    var kept_test_sigs = std.array_list.Managed(flattener.FunctionSig).init(allocator);
    errdefer kept_test_sigs.deinit();
    var kept_instructions = std.array_list.Managed(flattener.Instruction).init(allocator);
    errdefer kept_instructions.deinit();
    var kept_loc_table = std.array_list.Managed(?common_upstream.UpstreamLoc).init(allocator);
    errdefer kept_loc_table.deinit();

    var keep_ranges = try allocator.alloc(bool, ranges.len);
    defer allocator.free(keep_ranges);
    @memset(keep_ranges, false);
    for (ranges, 0..) |range, range_idx| {
        if (range.sig_index >= flat.function_sigs.len) continue;
        if (!reachable.contains(range.sig_index)) continue;
        keep_ranges[range_idx] = true;

        const function_sig = flat.function_sigs[range.sig_index];
        try kept_sigs.append(function_sig);
        if (function_sig.kind == .test_func) try kept_test_sigs.append(function_sig);
        try kept_instructions.appendSlice(flat.instructions[range.start..range.end]);
        try kept_loc_table.appendSlice(flat.loc_table[range.start..range.end]);
    }
    if (kept_sigs.items.len == 0) return;

    const new_function_sigs = try kept_sigs.toOwnedSlice();
    errdefer allocator.free(new_function_sigs);
    const new_test_sigs = try kept_test_sigs.toOwnedSlice();
    errdefer allocator.free(new_test_sigs);
    const new_instructions = try kept_instructions.toOwnedSlice();
    errdefer allocator.free(new_instructions);
    const new_loc_table = try kept_loc_table.toOwnedSlice();
    errdefer allocator.free(new_loc_table);

    try pruneSabVtableConsts(allocator, flat, &reachable_vtable_consts);

    var range_index: usize = 0;
    var instruction_index: usize = 0;
    while (instruction_index < flat.instructions.len) {
        if (range_index < ranges.len and instruction_index == ranges[range_index].start) {
            const range = ranges[range_index];
            if (!keep_ranges[range_index]) {
                for (flat.instructions[range.start..range.end]) |item| freeFlatInstructionMetadata(allocator, item);
                for (flat.loc_table[range.start..range.end]) |entry| freeFlatLocEntry(allocator, entry);
            }
            instruction_index = range.end;
            range_index += 1;
            continue;
        }
        freeFlatInstructionMetadata(allocator, flat.instructions[instruction_index]);
        freeFlatLocEntry(allocator, flat.loc_table[instruction_index]);
        instruction_index += 1;
    }

    var sig_keep = try allocator.alloc(bool, flat.function_sigs.len);
    defer allocator.free(sig_keep);
    @memset(sig_keep, false);
    for (ranges, 0..) |range, range_idx| {
        if (range.sig_index < sig_keep.len and keep_ranges[range_idx]) sig_keep[range.sig_index] = true;
    }
    for (flat.function_sigs, 0..) |*function_sig, sig_index| {
        if (!sig_keep[sig_index]) function_sig.deinit(allocator);
    }

    allocator.free(flat.function_sigs);
    allocator.free(flat.test_sigs);
    allocator.free(flat.instructions);
    allocator.free(flat.loc_table);

    flat.function_sigs = new_function_sigs;
    flat.test_sigs = new_test_sigs;
    flat.instructions = new_instructions;
    flat.loc_table = new_loc_table;

    if (sabPruneDebugEnabled(allocator)) {
        std.debug.print(
            "sab prune: funcs {d}->{d}, tests {d}->{d}, inst {d}->{d}, consts {d}->{d}, vtables_kept {d}\n",
            .{
                original_function_count,
                flat.function_sigs.len,
                original_test_count,
                flat.test_sigs.len,
                original_instruction_count,
                flat.instructions.len,
                original_const_count,
                flat.const_decls.len,
                reachable_vtable_consts.count(),
            },
        );
    }
}

fn cloneSabFunctionSig(allocator: std.mem.Allocator, source: flattener.FunctionSig) !flattener.FunctionSig {
    const name = try allocator.dupe(u8, source.name);
    errdefer allocator.free(name);

    const params = try allocator.alloc(common_signature.ParamSpec, source.params.len);
    errdefer allocator.free(params);
    var param_initialized: usize = 0;
    errdefer for (params[0..param_initialized]) |param| allocator.free(param.name);
    for (source.params, 0..) |param, idx| {
        params[idx] = .{
            .name = try allocator.dupe(u8, param.name),
            .ty = param.ty,
            .cap = param.cap,
        };
        param_initialized += 1;
    }

    const param_ids = try allocator.dupe(u32, source.param_ids);
    errdefer allocator.free(param_ids);
    const reg_ids = try allocator.dupe(u32, source.reg_ids);
    errdefer allocator.free(reg_ids);

    var upstream_file: ?[]u8 = null;
    errdefer if (upstream_file) |file| allocator.free(file);
    if (source.upstream_file) |file| upstream_file = try allocator.dupe(u8, file);

    var upstream_loc: ?common_upstream.UpstreamLoc = null;
    errdefer if (upstream_loc) |loc| allocator.free(loc.file);
    if (source.upstream_loc) |loc| {
        upstream_loc = .{
            .file = try allocator.dupe(u8, loc.file),
            .line = loc.line,
            .col = loc.col,
        };
    }

    var llvm_name: ?[]u8 = null;
    errdefer if (llvm_name) |value| allocator.free(value);
    if (source.llvm_name) |value| llvm_name = try allocator.dupe(u8, value);

    return .{
        .id = source.id,
        .name = name,
        .params = params,
        .kind = source.kind,
        .return_cap = source.return_cap,
        .return_ty = source.return_ty,
        .return_fallible = source.return_fallible,
        .entry_inst_idx = source.entry_inst_idx,
        .is_ffi_wrapper = source.is_ffi_wrapper,
        .upstream_file = upstream_file,
        .upstream_loc = upstream_loc,
        .param_ids = param_ids,
        .reg_ids = reg_ids,
        .llvm_name = llvm_name,
        .ignored = source.ignored,
        .should_panic = source.should_panic,
    };
}

fn trustedSabVerifyOk(allocator: std.mem.Allocator, flat: *flattener.FlattenResult) !referee.VerifyOk {
    // Verdict-cache fast path: the reused sigs never went through scope
    // finalization, so rebuild verifier-equivalent reg scopes (and localize
    // body regs to slots) before codegen, which requires populated reg_ids.
    try referee.populateTrustedRegScopes(allocator, flat.instructions, flat.const_decls, flat.function_sigs, &flat.symbols);
    var annotated = std.array_list.Managed(referee.AnnotatedInstruction).init(allocator);
    errdefer annotated.deinit();
    var fatal_terminated = false;
    for (flat.instructions) |item| {
        if (fatal_terminated and item.kind != .label and !isSabFunctionDecl(item.kind)) continue;
        if (item.kind == .label or isSabFunctionDecl(item.kind)) fatal_terminated = false;
        try annotated.append(.{
            .base = item,
            .delta = .{ .changes = &.{} },
            .gas_step_cost = 0,
        });
        if (item.kind == .panic or item.kind == .panic_msg) fatal_terminated = true;
    }
    const annotated_slice = try annotated.toOwnedSlice();
    errdefer allocator.free(annotated_slice);

    const function_sigs = flat.function_sigs;
    flat.function_sigs = &.{};

    const symbols = flat.symbols;
    flat.symbols = flattener.SymbolTable.init(allocator);

    return .{
        .annotated = annotated_slice,
        .function_sigs = function_sigs,
        .symbols = symbols,
        .const_decls = flat.const_decls,
        .gas = .{
            .max_alloc_bytes = 0,
            .max_instruction_steps = .{ .bounded = 0 },
            .call_depth = 0,
            .has_unbounded_loop = false,
        },
    };
}

var test_source_tree_load_count: usize = 0;

fn resolveProjectFromSourcePath(allocator: std.mem.Allocator, source_path: []const u8, package_name: ?[]const u8) !pkg_workspace.PackageResolution {
    const real_source = try sio.cwd().realpathAlloc(allocator, source_path);
    defer allocator.free(real_source);
    const source_dir = std.fs.path.dirname(real_source) orelse ".";
    return try pkg_workspace.resolveFromRootPath(allocator, source_dir, .{ .request = package_name });
}

fn projectRootFromSourcePath(allocator: std.mem.Allocator, source_path: []const u8) ![]u8 {
    var resolved = try resolveProjectFromSourcePath(allocator, source_path, null);
    defer resolved.deinit(allocator);
    return try allocator.dupe(u8, resolved.workspace_root);
}

fn stdRootFromEnv(allocator: std.mem.Allocator) ![]u8 {
    const repo_std_root = try std.fs.path.join(allocator, &.{ build_options.repo_root, "sa_std" });
    errdefer allocator.free(repo_std_root);

    if (builtin.is_test) return repo_std_root;

    const env_root = sio.getEnvVarOwned(allocator, "SA_STD_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return repo_std_root,
        else => return err,
    };
    errdefer allocator.free(env_root);

    const required_files = [_][]const u8{
        "io/print.sai",
        "core/sa_core.sars",
        "core/result.sars",
        "core/option.sars",
    };
    for (required_files) |rel| {
        const probe_path = try std.fs.path.join(allocator, &.{ env_root, rel });
        defer allocator.free(probe_path);
        if (sio.cwd().openFile(probe_path, .{})) |file| {
            file.close();
        } else |err| switch (err) {
            error.FileNotFound => {
                allocator.free(env_root);
                return repo_std_root;
            },
            else => return err,
        }
    }

    allocator.free(repo_std_root);
    return env_root;
}

fn defaultStableImportRoots(allocator: std.mem.Allocator, project_root: []const u8) ![]const []const u8 {
    var roots = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (roots.items) |root| allocator.free(root);
        roots.deinit();
    }

    const unit_support = try std.fs.path.join(allocator, &.{ project_root, "tests", "unit_framework", "support" });
    if (dirExistsAbsolute(unit_support)) {
        try roots.append(unit_support);
    } else {
        allocator.free(unit_support);
    }

    return try roots.toOwnedSlice();
}

fn readProjectManifest(allocator: std.mem.Allocator, project_root: []const u8) !?manifest.Manifest {
    const manifest_path = try std.fs.path.join(allocator, &.{ project_root, "sa.mod" });
    defer allocator.free(manifest_path);

    const file = sio.cwd().openFile(manifest_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const source = try file.readToEndAlloc(allocator, manifest.max_manifest_bytes);
    defer allocator.free(source);
    return try manifest.parseManifestWithFile(allocator, source, manifest_path);
}

fn projectRootFromCurrentDir(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try pkg_workspace.resolveFromCurrentDir(allocator, .{});
    defer resolved.deinit(allocator);
    return try allocator.dupe(u8, resolved.workspace_root);
}

fn parseAllowListFragment(allocator: std.mem.Allocator, list: *std.array_list.Managed([]const u8), value_text: []const u8) !void {
    var it = std.mem.splitScalar(u8, value_text, ',');
    while (it.next()) |raw_item| {
        const item = std.mem.trim(u8, raw_item, " \t\r\n");
        if (item.len == 0) return error.InvalidArgument;
        try list.append(try allocator.dupe(u8, item));
    }
}

fn appendPermissionSetStrings(allocator: std.mem.Allocator, list: *std.array_list.Managed([]const u8), entries: []const []const u8) !void {
    for (entries) |entry| try list.append(try allocator.dupe(u8, entry));
}

fn validateRunAllowList(entries: []const []const u8) !void {
    for (entries) |entry| {
        if (!std.fs.path.isAbsolute(entry)) return error.InvalidArgument;
    }
}

fn findPermissionSet(project_manifest: manifest.Manifest, name: []const u8) ?*const manifest.PermissionSet {
    for (project_manifest.permission_sets) |*set| {
        if (std.mem.eql(u8, set.name, name)) return set;
    }
    return null;
}

fn buildPluginRuntimeAuthorization(allocator: std.mem.Allocator, args: []const []const u8) !OwnedPluginRuntimeAuthorization {
    var env = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (env.items) |entry| allocator.free(entry);
        env.deinit();
    }
    var read = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (read.items) |entry| allocator.free(entry);
        read.deinit();
    }
    var write = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (write.items) |entry| allocator.free(entry);
        write.deinit();
    }
    var net = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (net.items) |entry| allocator.free(entry);
        net.deinit();
    }
    var run = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (run.items) |entry| allocator.free(entry);
        run.deinit();
    }

    var permission_set: ?[]const u8 = null;
    var allow_env_declared = false;
    var allow_read_declared = false;
    var allow_write_declared = false;
    var allow_net_declared = false;
    var allow_run_declared = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--permission-set=")) {
            permission_set = arg["--permission-set=".len..];
            if (permission_set.?.len == 0) return error.InvalidPermissionSet;
            continue;
        }
        if (std.mem.eql(u8, arg, "--permission-set")) {
            if (i + 1 >= args.len) return error.MissingPermissionSet;
            permission_set = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-P=")) {
            permission_set = arg["-P=".len..];
            if (permission_set.?.len == 0) return error.InvalidPermissionSet;
            continue;
        }
        if (std.mem.eql(u8, arg, "-P")) {
            permission_set = "default";
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--allow-env=")) {
            try parseAllowListFragment(allocator, &env, arg["--allow-env=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--allow-env")) {
            allow_env_declared = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--allow-read=")) {
            try parseAllowListFragment(allocator, &read, arg["--allow-read=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--allow-read")) {
            allow_read_declared = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--allow-write=")) {
            try parseAllowListFragment(allocator, &write, arg["--allow-write=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--allow-write")) {
            allow_write_declared = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--allow-net=")) {
            try parseAllowListFragment(allocator, &net, arg["--allow-net=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--allow-net")) {
            allow_net_declared = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--allow-run=")) {
            try parseAllowListFragment(allocator, &run, arg["--allow-run=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--allow-run")) {
            allow_run_declared = true;
            continue;
        }
    }

    const project_root = try projectRootFromCurrentDir(allocator);
    errdefer allocator.free(project_root);

    if (permission_set) |set_name| {
        var project_manifest = (try readProjectManifest(allocator, project_root)) orelse return error.InvalidPermissionSet;
        defer project_manifest.deinit(allocator);
        const selected = findPermissionSet(project_manifest, set_name) orelse return error.InvalidPermissionSet;
        try appendPermissionSetStrings(allocator, &env, selected.env);
        try appendPermissionSetStrings(allocator, &read, selected.read);
        try appendPermissionSetStrings(allocator, &write, selected.write);
        try appendPermissionSetStrings(allocator, &net, selected.net);
        try appendPermissionSetStrings(allocator, &run, selected.run);
    }
    try validateRunAllowList(run.items);

    var owned = OwnedPluginRuntimeAuthorization{
        .project_root = project_root,
        .env = try env.toOwnedSlice(),
        .read = try read.toOwnedSlice(),
        .write = try write.toOwnedSlice(),
        .net = try net.toOwnedSlice(),
        .run = try run.toOwnedSlice(),
    };
    owned.input = .{
        .dev_mode = false,
        .project_root = owned.project_root,
        .allow_env_declared = allow_env_declared,
        .allow_env = owned.env,
        .allow_read_declared = allow_read_declared,
        .allow_read = owned.read,
        .allow_write_declared = allow_write_declared,
        .allow_write = owned.write,
        .allow_net_declared = allow_net_declared,
        .allow_net = owned.net,
        .allow_run_declared = allow_run_declared,
        .allow_run = owned.run,
    };
    return owned;
}

fn manifestDependencies(manifest_file: *const manifest.Manifest, allocator: std.mem.Allocator) ![]pkg_resolver.Dependency {
    var deps = std.array_list.Managed(pkg_resolver.Dependency).init(allocator);
    errdefer deps.deinit();

    for (manifest_file.requires) |entry| {
        try deps.append(.{
            .url = entry.url,
            .ref = entry.ref,
            .source_sha256 = entry.source_sha256,
        });
    }

    return try deps.toOwnedSlice();
}

fn freeOwnedStringSlice(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn manifestPluginImportRoots(manifest_file: *const manifest.Manifest, allocator: std.mem.Allocator) ![]const []const u8 {
    var roots = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (roots.items) |root| allocator.free(root);
        roots.deinit();
    }

    if (manifest_file.plugin_requires.len == 0) return try roots.toOwnedSlice();

    const home = try plugins.pluginsHomePath(allocator);
    defer allocator.free(home);

    for (manifest_file.plugin_requires) |entry| {
        try roots.append(try std.fs.path.join(allocator, &.{ home, "installed", entry.identity, "current", "sa" }));
    }

    return try roots.toOwnedSlice();
}

fn compileSource(allocator: std.mem.Allocator, source_path: []const u8, options: CompileOptions) !CompileResult {
    var memory_metrics: ?CompileMemoryMetrics = if (options.mem_report) .{} else null;
    if (memory_metrics) |*memory| {
        memory.recordStart();
        try writeMemoryStageSampleForOptions(options, "start", memory.start_rss_bytes, null);
    }

    const total_start = if (options.profile) std.Io.Clock.awake.now(sio.io()) else null;
    if (std.mem.endsWith(u8, source_path, ".sab")) {
        const load_flat_start = if (options.profile) std.Io.Clock.awake.now(sio.io()) else null;
        var flat = try loadSabFlat(allocator, source_path);
        errdefer flat.deinit(allocator);
        const load_flat_ns = if (load_flat_start) |start| elapsedNs(start) else null;
        const prune_start = if (options.profile) std.Io.Clock.awake.now(sio.io()) else null;
        try pruneSabFlatToSelectedTests(allocator, &flat, options.sab_selected_test_names);
        const prune_ns = if (prune_start) |start| elapsedNs(start) else null;
        const verify_start = if (options.profile) std.Io.Clock.awake.now(sio.io()) else null;
        if (options.sab_skip_verify and options.sab_selected_test_names.len != 0) {
            const trusted = try trustedSabVerifyOk(allocator, &flat);
            const verify_ns = if (verify_start) |start| elapsedNs(start) else null;
            if (options.profile) {
                var null_buf: [64]u8 = undefined;
                var null_discarding: std.Io.Writer.Discarding = .init(&null_buf);
                const writer = options.diagnostic_writer orelse &null_discarding.writer;
                try writer.print(
                    "profile sab load_flat={d:.3}ms prune={d:.3}ms verify={d:.3}ms trusted=1\n",
                    .{
                        @as(f64, @floatFromInt(load_flat_ns orelse 0)) / 1_000_000.0,
                        @as(f64, @floatFromInt(prune_ns orelse 0)) / 1_000_000.0,
                        @as(f64, @floatFromInt(verify_ns orelse 0)) / 1_000_000.0,
                    },
                );
            }
            return .{ .ok = .{ .flat = flat, .verified = trusted, .metrics = computeCompileMetrics(&flat, &trusted, if (options.profile) .{ .load_ns = load_flat_ns orelse 0, .setup_ns = 0, .flatten_ns = prune_ns orelse 0, .verify_ns = verify_ns orelse 0, .total_ns = if (total_start) |start| elapsedNs(start) else null } else null, memory_metrics) } };
        }
        const verified = try referee.verifyWithOptions(allocator, flat.instructions, flat.const_decls, .{
            .jobs = options.jobs,
            .stage_reporter = null,
            .predecoded_symbol_names = flat.symbols.names.items,
            .predecoded_function_sigs = flat.function_sigs,
            .check_exit_leaks = options.sab_selected_test_names.len == 0,
            .default_immutable = options.default_immutable,
            .rust_strict_mut = options.rust_strict_mut,
            .rust_copy_elision = options.rust_copy_elision,
        });
        const verify_ns = if (verify_start) |start| elapsedNs(start) else null;
        if (options.profile) {
            var null_buf: [64]u8 = undefined;
            var null_discarding: std.Io.Writer.Discarding = .init(&null_buf);
            const writer = options.diagnostic_writer orelse &null_discarding.writer;
            try writer.print(
                "profile sab load_flat={d:.3}ms prune={d:.3}ms verify={d:.3}ms\n",
                .{
                    @as(f64, @floatFromInt(load_flat_ns orelse 0)) / 1_000_000.0,
                    @as(f64, @floatFromInt(prune_ns orelse 0)) / 1_000_000.0,
                    @as(f64, @floatFromInt(verify_ns orelse 0)) / 1_000_000.0,
                },
            );
        }
        return switch (verified) {
            .ok => |ok| blk: {
                const digest = incr_verify.hashInstructions(flat.instructions);
                incr_verify.recordVerified(digest);
                break :blk .{ .ok = .{ .flat = flat, .verified = ok, .metrics = computeCompileMetrics(&flat, &ok, if (options.profile) .{ .load_ns = 0, .setup_ns = 0, .flatten_ns = 0, .verify_ns = 0, .total_ns = if (total_start) |start| elapsedNs(start) else null } else null, memory_metrics) } };
            },
            .trap => |report| {
                var r = report;
                if (r.file == null) setFile(&r, source_path);
                flat.deinit(allocator);
                return .{ .trap = r };
            },
        };
    }
    const load_start = if (options.profile) std.Io.Clock.awake.now(sio.io()) else null;
    const source = try loadSource(allocator, source_path);
    defer allocator.free(source);
    const load_ns = if (load_start) |start| elapsedNs(start) else 0;
    if (memory_metrics) |*memory| {
        memory.recordAfterLoad();
        try writeMemoryStageSampleForOptions(options, "after_load", memory.after_load_rss_bytes, memory.start_rss_bytes);
    }

    const setup_start = if (options.profile) std.Io.Clock.awake.now(sio.io()) else null;
    var resolution = if (options.project_root) |project_root|
        try pkg_workspace.resolveFromRootPath(allocator, project_root, .{ .request = options.package_name })
    else
        try resolveProjectFromSourcePath(allocator, source_path, options.package_name);
    defer resolution.deinit(allocator);

    const project_root = resolution.workspace_root;
    const member_root = resolution.member_root;
    const std_root = try stdRootFromEnv(allocator);
    defer allocator.free(std_root);

    const project_manifest = resolution.effective_manifest;

    var dependency_slice: []pkg_resolver.Dependency = &.{};
    defer if (dependency_slice.len != 0) allocator.free(dependency_slice);

    var plugin_import_roots: []const []const u8 = &.{};
    defer if (plugin_import_roots.len != 0) freeOwnedStringSlice(allocator, plugin_import_roots);
    const stable_import_roots = try defaultStableImportRoots(allocator, member_root);
    defer freeOwnedStringSlice(allocator, stable_import_roots);

    if (project_manifest) |*m| {
        verifyProjectPackageState(allocator, project_root, m.*, options) catch |err| {
            if (trapFromPackagePreflightError(err)) |report| {
                return .{ .trap = report };
            }
            return err;
        };
        dependency_slice = try manifestDependencies(m, allocator);
        plugin_import_roots = try manifestPluginImportRoots(m, allocator);
    }

    const package_grants: []const manifest.RequireEntry = if (project_manifest) |*m| m.requires else &.{};

    var error_ctx: flattener.ErrorContext = .{};
    const resolve_ctx = flattener.ResolveContext{
        .dependencies = dependency_slice,
        .options = .{
            .project_root = project_root,
            .std_root = std_root,
            .offline = options.offline,
            .plugin_import_roots = plugin_import_roots,
            .stable_import_roots = stable_import_roots,
        },
    };
    const setup_ns = if (setup_start) |start| elapsedNs(start) else 0;
    if (memory_metrics) |*memory| {
        memory.recordAfterSetup();
        try writeMemoryStageSampleForOptions(options, "after_setup", memory.after_setup_rss_bytes, memory.after_load_rss_bytes);
    }

    const flatten_start = if (options.profile) std.Io.Clock.awake.now(sio.io()) else null;
    var flat = flattener.flattenFileWithContextAndPackages(allocator, source_path, source, &error_ctx, resolve_ctx) catch |err| {
        return .{ .trap = trapFromFlattenError(source_path, source, err, flattener.takeErrorSourceLine(&error_ctx)) };
    };
    errdefer flat.deinit(allocator);
    const flatten_ns = if (flatten_start) |start| elapsedNs(start) else 0;
    if (memory_metrics) |*memory| {
        memory.recordAfterFlatten();
        try writeMemoryStageSampleForOptions(options, "after_flatten", memory.after_flatten_rss_bytes, memory.after_setup_rss_bytes);
    }

    var null_buf: [64]u8 = undefined;
    var null_discarding: std.Io.Writer.Discarding = .init(&null_buf);
    var verifier_stage_context = MemoryStageReporterContext{
        .writer = options.diagnostic_writer orelse &null_discarding.writer,
        .memory = if (memory_metrics) |*memory| memory else null,
        .previous_rss_bytes = if (memory_metrics) |memory| memory.after_flatten_rss_bytes else null,
        .peak_rss_bytes = if (memory_metrics) |memory| memory.peak_rss_bytes else null,
        .live = options.mem_report_live,
    };
    const verifier_stage_reporter: ?referee.VerifyStageReporter = if (options.mem_report)
        .{ .context = &verifier_stage_context, .report_fn = reportVerifierMemoryStage }
    else
        null;

    const verify_start = if (options.profile) std.Io.Clock.awake.now(sio.io()) else null;
    const content_hash = incr_verify.hashInstructions(flat.instructions);
    // Phase B-B hybrid: on verdict hit rebuild a trusted annotated shell from the
    // current FlattenResult (no dangling VerifyOk reuse). Misses run the referee.
    if (incr_verify.isVerified(content_hash)) {
        const trusted = try trustedSabVerifyOk(allocator, &flat);
        const verify_ns = if (verify_start) |start| elapsedNs(start) else 0;
        if (memory_metrics) |*memory| {
            memory.recordAfterVerify();
            try writeMemoryStageSampleForOptions(options, "after_verify", memory.after_verify_rss_bytes, memory.after_flatten_rss_bytes);
            memory.recordEnd();
        }
        var metrics = computeCompileMetrics(&flat, &trusted, if (options.profile) .{ .load_ns = load_ns, .setup_ns = setup_ns, .flatten_ns = flatten_ns, .verify_ns = verify_ns, .total_ns = if (total_start) |start| elapsedNs(start) else null } else null, memory_metrics);
        metrics.cache = .{ .kind = "verdict", .hit = true };
        return .{ .ok = .{ .flat = flat, .verified = trusted, .metrics = metrics } };
    }
    const verified = try referee.verifyWithOptions(allocator, flat.instructions, flat.const_decls, .{ .jobs = options.jobs, .package_grants = package_grants, .stage_reporter = verifier_stage_reporter, .default_immutable = options.default_immutable, .rust_strict_mut = options.rust_strict_mut, .rust_copy_elision = options.rust_copy_elision });
    const verify_ns = if (verify_start) |start| elapsedNs(start) else 0;
    if (memory_metrics) |*memory| {
        memory.updatePeak(verifier_stage_context.peak_rss_bytes);
        memory.recordAfterVerify();
        try writeMemoryStageSampleForOptions(options, "after_verify", memory.after_verify_rss_bytes, memory.after_flatten_rss_bytes);
        memory.recordEnd();
    }

    return switch (verified) {
        .ok => |ok| blk: {
            incr_verify.recordVerified(content_hash);
            var names = std.array_list.Managed([]const u8).init(allocator);
            defer names.deinit();
            for (ok.function_sigs) |fs| names.append(fs.name) catch {};
            incr_verify.recordResultFromInstructions(content_hash, flat.instructions, names.items);
            var metrics = computeCompileMetrics(&flat, &ok, if (options.profile) .{ .load_ns = load_ns, .setup_ns = setup_ns, .flatten_ns = flatten_ns, .verify_ns = verify_ns, .total_ns = if (total_start) |start| elapsedNs(start) else null } else null, memory_metrics);
            metrics.cache = .{ .kind = "verdict", .hit = false };
            break :blk .{ .ok = .{ .flat = flat, .verified = ok, .metrics = metrics } };
        },
        .trap => |report| {
            var r = report;
            if (r.file == null) {
                setFile(&r, source_path);
            }
            flat.deinit(allocator);
            return .{ .trap = r };
        },
    };
}

fn collectExternalSymbolNames(allocator: std.mem.Allocator, verified: *const referee.VerifyOk) ![]const []const u8 {
    var names = std.array_list.Managed([]const u8).init(allocator);
    errdefer names.deinit();
    for (verified.function_sigs) |fsig| {
        if (fsig.kind == .external) try names.append(fsig.name);
    }
    return try names.toOwnedSlice();
}

fn appendNativePluginLinkInputs(
    allocator: std.mem.Allocator,
    link_inputs: *std.array_list.Managed([]const u8),
    owned_link_inputs: *std.array_list.Managed([]const u8),
    verified: *const referee.VerifyOk,
) !void {
    const extern_names = try collectExternalSymbolNames(allocator, verified);
    defer allocator.free(extern_names);
    if (extern_names.len == 0) return;

    // Native linking only needs plugin metadata and exported symbols. Do not
    // apply runtime sandbox gating here, or privileged plugins such as HTTP
    // client/server are silently skipped and their externs fail at link time.
    var plugin_runtime = try plugins.Runtime.initFromEnvWithAuthorization(allocator, .{
        .dev_mode = true,
    });
    defer plugin_runtime.deinit();

    var plugin_libs = std.array_list.Managed([]const u8).init(allocator);
    defer plugin_libs.deinit();
    try plugin_runtime.appendLibrariesExportingAny(&plugin_libs, extern_names);

    for (plugin_libs.items) |lib_path| {
        const owned_lib_path = try allocator.dupe(u8, lib_path);
        link_inputs.append(owned_lib_path) catch |err| {
            allocator.free(owned_lib_path);
            return err;
        };
        owned_link_inputs.append(owned_lib_path) catch |err| {
            allocator.free(owned_lib_path);
            return err;
        };
        if (std.fs.path.dirname(lib_path)) |dir| {
            const rpath_arg = try std.fmt.allocPrint(allocator, "-Wl,-rpath,{s}", .{dir});
            link_inputs.append(rpath_arg) catch |err| {
                allocator.free(rpath_arg);
                return err;
            };
            owned_link_inputs.append(rpath_arg) catch |err| {
                allocator.free(rpath_arg);
                return err;
            };
        }
    }
}

fn deriveOutputPath(allocator: std.mem.Allocator, source_path: []const u8, suffix: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(source_path);
    const stem = sourceStem(source_path);
    if (dir) |parent| {
        return try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ parent, stem, suffix });
    }
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, suffix });
}

pub fn defaultExecutableSuffix() []const u8 {
    return if (builtin.os.tag == .windows) ".exe" else "";
}

fn ensureParentDir(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len != 0) try sio.cwd().makePath(dir);
    }
}

fn writeAllFile(path: []const u8, bytes: []const u8) !void {
    try ensureParentDir(path);
    var file = try sio.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn writeTextFile(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    _ = allocator;
    try writeAllFile(path, bytes);
}

fn copyFileAlloc(allocator: std.mem.Allocator, src_path: []const u8, dst_path: []const u8) !void {
    _ = allocator;
    try ensureParentDir(dst_path);
    try sio.cwd().copyFile(src_path, sio.cwd(), dst_path, .{});
}

fn makeExecutable(path: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    var file = try sio.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    try file.chmod(0o755);
}

fn cacheRootPath(allocator: std.mem.Allocator, project_root: []const u8) ![]u8 {
    return try pathJoinAlloc(allocator, &.{ project_root, ".sa_cache" });
}

const BuildCacheKind = enum {
    build_exe,
    build_obj,
    build_wasm,
    build_obj_incremental,
    test_cache,

    fn dirName(self: BuildCacheKind) []const u8 {
        return switch (self) {
            .build_exe => "build-exe",
            .build_obj => "build-obj",
            .build_wasm => "build-wasm",
            .build_obj_incremental => "build-obj-incremental",
            .test_cache => "test",
        };
    }
};

const CacheCleanStats = struct {
    scanned: usize = 0,
    removed: usize = 0,
    kept: usize = 0,
};

const CacheCleanOptions = struct {
    dry_run: bool = false,
    max_age_days: u64 = 30,
};

const ProjectCacheKey = struct {
    hex: [64]u8,

    fn slice(self: *const ProjectCacheKey) []const u8 {
        return self.hex[0..];
    }
};

fn cacheBytes(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    hasher.update(bytes);
    hasher.update(&[_]u8{0});
}

fn cacheU64(hasher: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    hasher.update(&buf);
}

fn cacheBool(hasher: *std.crypto.hash.sha2.Sha256, value: bool) void {
    hasher.update(&.{if (value) 1 else 0});
}

const RuntimeArchiveFingerprint = struct { size: u64, mtime_ns: u64 };

fn runtimeArchiveFingerprint(allocator: std.mem.Allocator) ?RuntimeArchiveFingerprint {
    const archive_path = saStdArchivePath(allocator) catch return null;
    defer allocator.free(archive_path);
    const stat = sio.cwd().statFile(archive_path) catch return null;
    return .{
        .size = stat.size,
        .mtime_ns = @as(u64, @intCast(stat.mtime.toNanoseconds())),
    };
}

fn cacheCompilerVersion() []const u8 {
    if (builtin.is_test) return "test";
    return build_options.version;
}

fn projectFileMaybeHash(hasher: *std.crypto.hash.sha2.Sha256, allocator: std.mem.Allocator, path: []const u8) !void {
    if (!projectPathExists(path)) return;
    const bytes = try readTextFileAlloc(allocator, path);
    defer allocator.free(bytes);
    cacheBytes(hasher, bytes);
}

const SourceTreeFileStat = struct {
    path: []u8,
    mtime: std.Io.Timestamp,
    size: u64,
};

const SourceTreeHashCacheEntry = struct {
    digest: [32]u8,
    files: []SourceTreeFileStat,
    last_used_tick: u64,
};

var source_tree_hash_cache_mutex: std.atomic.Mutex = .unlocked;
var source_tree_hash_cache: ?std.StringHashMap(SourceTreeHashCacheEntry) = null;
var source_tree_hash_cache_tick: u64 = 0;
var test_source_tree_hash_cache_max_entries: ?usize = null;

fn sourceTreeHashCacheMap() *std.StringHashMap(SourceTreeHashCacheEntry) {
    if (source_tree_hash_cache == null) {
        source_tree_hash_cache = std.StringHashMap(SourceTreeHashCacheEntry).init(std.heap.page_allocator);
    }
    return &source_tree_hash_cache.?;
}

fn freeSourceTreeHashCacheEntry(entry: SourceTreeHashCacheEntry) void {
    for (entry.files) |file| std.heap.page_allocator.free(file.path);
    std.heap.page_allocator.free(entry.files);
}

fn sourceTreeHashCacheMaxEntries() ?usize {
    if (builtin.is_test) {
        if (test_source_tree_hash_cache_max_entries) |value| return value;
    }
    const value = sio.getEnvVarOwned(std.heap.page_allocator, "SA_SOURCE_TREE_HASH_CACHE_MAX_ENTRIES") catch return null;
    defer std.heap.page_allocator.free(value);
    const parsed = std.fmt.parseUnsigned(usize, value, 10) catch return null;
    return if (parsed == 0) null else parsed;
}

fn nextSourceTreeHashCacheTickLocked() u64 {
    source_tree_hash_cache_tick +%= 1;
    return source_tree_hash_cache_tick;
}

fn buildSourceTreeHashCacheKey(
    allocator: std.mem.Allocator,
    dependencies: []pkg_resolver.Dependency,
    plugin_import_roots: []const []const u8,
    project_root: []const u8,
    std_root: []const u8,
    offline: bool,
    real_source_path: []const u8,
) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try appendCacheKeyBytes(&out, cacheCompilerVersion());
    try appendCacheKeyBytes(&out, project_root);
    try appendCacheKeyBytes(&out, std_root);
    try appendCacheKeyBytes(&out, real_source_path);
    var offline_buf: [8]u8 = undefined;
    const offline_text = try std.fmt.bufPrint(&offline_buf, "{}\x00", .{offline});
    try out.appendSlice(offline_text);
    for (plugin_import_roots) |root| try appendCacheKeyBytes(&out, root);
    try out.append(0);
    for (dependencies) |dep| {
        try appendCacheKeyBytes(&out, dep.url);
        try appendCacheKeyBytes(&out, dep.ref);
    }
    return try out.toOwnedSlice();
}

fn appendCacheKeyBytes(out: *std.array_list.Managed(u8), bytes: []const u8) !void {
    try out.appendSlice(bytes);
    try out.append(0);
}

fn sourceTreeHashCacheHit(cache_key: []const u8) ?[32]u8 {
    while (!source_tree_hash_cache_mutex.tryLock()) { std.Thread.yield() catch {}; }
    defer source_tree_hash_cache_mutex.unlock();
    const cache = sourceTreeHashCacheMap();
    const entry = cache.getPtr(cache_key) orelse return null;
    for (entry.files) |file| {
        const stat = sio.cwd().statFile(file.path) catch return null;
        if (stat.mtime.toNanoseconds() != file.mtime.toNanoseconds() or stat.size != file.size) return null;
    }
    entry.last_used_tick = nextSourceTreeHashCacheTickLocked();
    return entry.digest;
}

fn storeSourceTreeHashCacheEntry(cache_key: []const u8, digest: [32]u8, files: []const SourceTreeFileStat) !void {
    const cache_allocator = std.heap.page_allocator;
    const owned_key = try cache_allocator.dupe(u8, cache_key);
    errdefer cache_allocator.free(owned_key);
    const owned_files = try cache_allocator.alloc(SourceTreeFileStat, files.len);
    errdefer cache_allocator.free(owned_files);
    var copied: usize = 0;
    errdefer {
        for (owned_files[0..copied]) |file| cache_allocator.free(file.path);
    }
    for (files, 0..) |file, idx| {
        owned_files[idx] = .{
            .path = try cache_allocator.dupe(u8, file.path),
            .mtime = file.mtime,
            .size = file.size,
        };
        copied += 1;
    }

    while (!source_tree_hash_cache_mutex.tryLock()) { std.Thread.yield() catch {}; }
    defer source_tree_hash_cache_mutex.unlock();
    var cache = sourceTreeHashCacheMap();
    if (cache.getPtr(cache_key)) |old| {
        freeSourceTreeHashCacheEntry(old.*);
        old.* = .{ .digest = digest, .files = owned_files, .last_used_tick = nextSourceTreeHashCacheTickLocked() };
        cache_allocator.free(owned_key);
        evictSourceTreeHashCacheIfNeeded(cache, sourceTreeHashCacheMaxEntries());
        return;
    }
    try cache.put(owned_key, .{ .digest = digest, .files = owned_files, .last_used_tick = nextSourceTreeHashCacheTickLocked() });
    evictSourceTreeHashCacheIfNeeded(cache, sourceTreeHashCacheMaxEntries());
}

fn evictSourceTreeHashCacheIfNeeded(cache: *std.StringHashMap(SourceTreeHashCacheEntry), max_entries: ?usize) void {
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
            freeSourceTreeHashCacheEntry(removed.value);
        } else {
            return;
        }
    }
}

fn addSourceTreeDigestToHasher(hasher: *std.crypto.hash.sha2.Sha256, digest: [32]u8) void {
    cacheBytes(hasher, "source-tree-digest-v1");
    hasher.update(&digest);
}

fn hashResolvedSourceTreeUncached(
    allocator: std.mem.Allocator,
    hasher: *std.crypto.hash.sha2.Sha256,
    dependencies: []pkg_resolver.Dependency,
    plugin_import_roots: []const []const u8,
    project_root: []const u8,
    std_root: []const u8,
    offline: bool,
    source_path: []const u8,
    visited: *std.StringHashMap(void),
    files: *std.array_list.Managed(SourceTreeFileStat),
    resolved_source: ?[]const u8,
) !void {
    const real_source_path = try sio.cwd().realpathAlloc(allocator, source_path);
    var owned_by_files = false;
    errdefer if (!owned_by_files) allocator.free(real_source_path);
    if (visited.contains(real_source_path)) {
        allocator.free(real_source_path);
        return;
    }
    const visited_key = try allocator.dupe(u8, real_source_path);
    var visited_key_inserted = false;
    errdefer if (!visited_key_inserted) allocator.free(visited_key);
    try visited.put(visited_key, {});
    visited_key_inserted = true;

    const stat = try sio.cwd().statFile(real_source_path);
    try files.append(.{ .path = real_source_path, .mtime = stat.mtime, .size = stat.size });
    owned_by_files = true;

    cacheBytes(hasher, real_source_path);
    const owned_source = if (resolved_source == null) try loadSource(allocator, source_path) else null;
    defer if (owned_source) |source| allocator.free(source);
    const source = resolved_source orelse owned_source.?;
    cacheBytes(hasher, source);

    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |line| {
        const classified = line_classifier.classifyLine(line);
        if (classified.kind != .import_decl) continue;
        const import_path = classified.parts[0];
        const resolve_ctx = flattener.ResolveContext{ .dependencies = dependencies, .options = .{
            .project_root = project_root,
            .std_root = std_root,
            .offline = offline,
            .plugin_import_roots = plugin_import_roots,
        } };
        var imported = try flattener.readImportSourceFile(allocator, std.fs.path.dirname(source_path) orelse ".", import_path, resolve_ctx);
        defer imported.deinit(allocator);
        try hashResolvedSourceTreeUncached(allocator, hasher, dependencies, plugin_import_roots, project_root, std_root, offline, imported.entry_path, visited, files, imported.source);
    }
}

fn hashResolvedSourceTree(
    allocator: std.mem.Allocator,
    hasher: *std.crypto.hash.sha2.Sha256,
    dependencies: []pkg_resolver.Dependency,
    plugin_import_roots: []const []const u8,
    project_root: []const u8,
    std_root: []const u8,
    offline: bool,
    source_path: []const u8,
) !void {
    const real_source_path = try sio.cwd().realpathAlloc(allocator, source_path);
    defer allocator.free(real_source_path);
    const cache_key = try buildSourceTreeHashCacheKey(allocator, dependencies, plugin_import_roots, project_root, std_root, offline, real_source_path);
    defer allocator.free(cache_key);
    if (sourceTreeHashCacheHit(cache_key)) |digest| {
        addSourceTreeDigestToHasher(hasher, digest);
        return;
    }

    var tree_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var it = visited.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        visited.deinit();
    }
    var files = std.array_list.Managed(SourceTreeFileStat).init(allocator);
    defer {
        for (files.items) |file| allocator.free(file.path);
        files.deinit();
    }
    try hashResolvedSourceTreeUncached(allocator, &tree_hasher, dependencies, plugin_import_roots, project_root, std_root, offline, source_path, &visited, &files, null);
    var digest: [32]u8 = undefined;
    tree_hasher.final(&digest);
    try storeSourceTreeHashCacheEntry(cache_key, digest, files.items);
    addSourceTreeDigestToHasher(hasher, digest);
}

fn computeProjectBuildKey(
    allocator: std.mem.Allocator,
    project_context: *const ProjectContext,
    project_root: []const u8,
    source_path: []const u8,
    target_name: []const u8,
    source_suffix: []const u8,
    kind: BuildCacheKind,
    debug: bool,
    release_fast: bool,
    incremental: bool,
    wasm: ?WasmTarget,
    hash_source_tree: bool,
    offline: bool,
    dce: DceMode,
) !ProjectCacheKey {
    const std_root = try stdRootFromEnv(allocator);
    defer allocator.free(std_root);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    cacheBytes(&hasher, "sa-build-cache");
    cacheBytes(&hasher, cacheCompilerVersion());
    cacheBytes(&hasher, project_root);
    cacheBytes(&hasher, kind.dirName());
    cacheBytes(&hasher, source_path);
    cacheBytes(&hasher, target_name);
    cacheBytes(&hasher, source_suffix);
    cacheBool(&hasher, debug);
    cacheBool(&hasher, release_fast);
    cacheBool(&hasher, incremental);
    cacheBytes(&hasher, dce.name());
    // Fingerprint the linked sa_std runtime archive (size+mtime): a rebuilt
    // runtime must invalidate cached exes, otherwise stale-linked binaries
    // are silently reused (observed: AVX-512-linked test exes kept running
    // after the archive was rebuilt without AVX-512, SIGILL). Cheap stat,
    // no content hashing; missing archive keeps old behavior.
    if (runtimeArchiveFingerprint(allocator)) |fp| {
        cacheU64(&hasher, fp.size);
        cacheU64(&hasher, fp.mtime_ns);
    }
    if (wasm) |target| {
        cacheBytes(&hasher, target.triple);
        cacheBool(&hasher, target.no_entry);
        cacheU64(&hasher, target.size_bits);
    }

    const project_manifest = project_context.manifest;
    if (project_manifest) |*m| {
        cacheBytes(&hasher, project_context.workspace_manifest_path);
        if (projectPathExists(project_context.workspace_manifest_path)) {
            const workspace_manifest_bytes = try readTextFileAlloc(allocator, project_context.workspace_manifest_path);
            defer allocator.free(workspace_manifest_bytes);
            cacheBytes(&hasher, workspace_manifest_bytes);
        }
        if (!std.mem.eql(u8, project_context.member_manifest_path, project_context.workspace_manifest_path)) {
            cacheBytes(&hasher, project_context.member_manifest_path);
            if (projectPathExists(project_context.member_manifest_path)) {
                const member_manifest_bytes = try readTextFileAlloc(allocator, project_context.member_manifest_path);
                defer allocator.free(member_manifest_bytes);
                cacheBytes(&hasher, member_manifest_bytes);
            }
        }
        if (project_context.lock_file != null) {
            const lock_path = try projectLockPath(allocator, project_context.root_path);
            defer allocator.free(lock_path);
            try projectFileMaybeHash(&hasher, allocator, lock_path);
        }
        if (project_context.sum_file != null) {
            const sum_path = try projectSumPath(allocator, project_context.root_path);
            defer allocator.free(sum_path);
            try projectFileMaybeHash(&hasher, allocator, sum_path);
        }
        var dependency_slice: []pkg_resolver.Dependency = &.{};
        defer if (dependency_slice.len != 0) allocator.free(dependency_slice);
        var plugin_import_roots: []const []const u8 = &.{};
        defer if (plugin_import_roots.len != 0) freeOwnedStringSlice(allocator, plugin_import_roots);
        if (m.requires.len != 0) {
            dependency_slice = try manifestDependencies(m, allocator);
        }
        if (m.plugin_requires.len != 0) {
            plugin_import_roots = try manifestPluginImportRoots(m, allocator);
        }

        if (hash_source_tree) {
            try hashResolvedSourceTree(allocator, &hasher, dependency_slice, plugin_import_roots, project_context.root_path, std_root, offline, source_path);
        }
    } else {
        try projectFileMaybeHash(&hasher, allocator, project_context.workspace_manifest_path);
        if (!std.mem.eql(u8, project_context.member_manifest_path, project_context.workspace_manifest_path)) {
            try projectFileMaybeHash(&hasher, allocator, project_context.member_manifest_path);
        }
        if (hash_source_tree) {
            try hashResolvedSourceTree(allocator, &hasher, &.{}, &.{}, project_context.root_path, std_root, offline, source_path);
        }
    }

    var out: [32]u8 = undefined;
    hasher.final(&out);
    return .{ .hex = std.fmt.bytesToHex(out, .lower) };
}

fn projectCacheDir(allocator: std.mem.Allocator, project_root: []const u8, kind: BuildCacheKind, key: ProjectCacheKey) ![]u8 {
    return try pathJoinAlloc(allocator, &.{ project_root, ".sa_cache", kind.dirName(), key.slice() });
}

fn projectCacheArtifactPath(allocator: std.mem.Allocator, project_root: []const u8, kind: BuildCacheKind, key: ProjectCacheKey, filename: []const u8) ![]u8 {
    const dir = try projectCacheDir(allocator, project_root, kind, key);
    defer allocator.free(dir);
    return try pathJoinAlloc(allocator, &.{ dir, filename });
}

fn projectCacheRemoveKey(allocator: std.mem.Allocator, project_root: []const u8, kind: BuildCacheKind, key: ProjectCacheKey) void {
    const dir = projectCacheDir(allocator, project_root, kind, key) catch return;
    defer allocator.free(dir);
    sio.cwd().deleteTree(dir) catch |err| {
        // Build cache repair is opportunistic here; callers fall back to recompilation on unusable entries.
        _ = @errorName(err);
    };
}

fn projectCacheArtifactExistsNonEmpty(path: []const u8) bool {
    const stat = sio.cwd().statFile(path) catch return false;
    return stat.kind == .file and stat.size != 0;
}

fn projectCacheManifestPath(allocator: std.mem.Allocator, project_root: []const u8, kind: BuildCacheKind, key: ProjectCacheKey) ![]u8 {
    return try projectCacheArtifactPath(allocator, project_root, kind, key, "manifest.json");
}

fn jsonGetObject(value: std.json.Value, key: []const u8) !std.json.Value {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidCacheManifest,
    };
    return object.get(key) orelse return error.InvalidCacheManifest;
}

fn jsonStringEquals(value: std.json.Value, expected: []const u8) bool {
    return switch (value) {
        .string => |text| std.mem.eql(u8, text, expected),
        else => false,
    };
}

fn jsonIntEquals(value: std.json.Value, expected: u64) bool {
    return switch (value) {
        .integer => |v| v >= 0 and @as(u64, @intCast(v)) == expected,
        else => false,
    };
}

fn projectCacheArtifactMatchesManifest(allocator: std.mem.Allocator, artifact_value: std.json.Value, path: []const u8) !bool {
    const stat = sio.cwd().statFile(path) catch return false;
    if (stat.kind != .file or stat.size == 0) return false;
    if (!jsonIntEquals(try jsonGetObject(artifact_value, "size"), stat.size)) return false;
    const hash_hex = try hashFileHex(allocator, path);
    return jsonStringEquals(try jsonGetObject(artifact_value, "sha256"), hash_hex[0..]);
}

fn projectCacheManifestValid(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    kind: BuildCacheKind,
    key: ProjectCacheKey,
    artifact_path: []const u8,
    out_path: []const u8,
) bool {
    const manifest_path = projectCacheManifestPath(allocator, project_root, kind, key) catch return false;
    defer allocator.free(manifest_path);
    const manifest_bytes = readTextFileAlloc(allocator, manifest_path) catch return false;
    defer allocator.free(manifest_bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{}) catch return false;
    defer parsed.deinit();
    if (!jsonIntEquals(jsonGetObject(parsed.value, "version") catch return false, 1)) return false;
    if (!jsonStringEquals(jsonGetObject(parsed.value, "kind") catch return false, kind.dirName())) return false;
    if (!jsonStringEquals(jsonGetObject(parsed.value, "key") catch return false, key.slice())) return false;
    if (!(projectCacheArtifactMatchesManifest(allocator, jsonGetObject(parsed.value, "artifact") catch return false, artifact_path) catch return false)) return false;
    if (!(projectCacheArtifactMatchesManifest(allocator, jsonGetObject(parsed.value, "output") catch return false, out_path) catch return false)) return false;
    return true;
}

fn writeCacheArtifactManifestEntry(writer: anytype, allocator: std.mem.Allocator, name: []const u8, path: []const u8) !void {
    const stat = try sio.cwd().statFile(path);
    const hash_hex = try hashFileHex(allocator, path);
    try writer.writeByte('"');
    try writer.writeAll(name);
    try writer.writeAll("\":{\"size\":");
    try writer.print("{d}", .{stat.size});
    try writer.writeAll(",\"sha256\":");
    try writeJsonString(writer, hash_hex[0..]);
    try writer.writeByte('}');
}

fn projectCacheWriteManifest(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    kind: BuildCacheKind,
    key: ProjectCacheKey,
    cached_artifact: []const u8,
    cached_output: []const u8,
) !void {
    const manifest_path = try projectCacheManifestPath(allocator, project_root, kind, key);
    defer allocator.free(manifest_path);
    try ensureParentDir(manifest_path);
    var file = try sio.cwd().createFile(manifest_path, .{ .truncate = true });
    defer file.close();
    var fbuf: [8192]u8 = undefined;
    var fw = file.writer(&fbuf);
    const writer = &fw.interface;
    try writer.writeAll("{\"version\":1,\"kind\":");
    try writeJsonString(writer, kind.dirName());
    try writer.writeAll(",\"key\":");
    try writeJsonString(writer, key.slice());
    try writer.writeByte(',');
    try writeCacheArtifactManifestEntry(writer, allocator, "artifact", cached_artifact);
    try writer.writeByte(',');
    try writeCacheArtifactManifestEntry(writer, allocator, "output", cached_output);
    try writer.writeAll("}\n");
    try fw.interface.flush();
}

fn projectCacheHit(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    kind: BuildCacheKind,
    key: ProjectCacheKey,
    artifact_path: []const u8,
    out_path: []const u8,
) !bool {
    const cached_artifact = try projectCacheArtifactPath(allocator, project_root, kind, key, "artifact.sa.bc");
    defer allocator.free(cached_artifact);
    const cached_output = try projectCacheArtifactPath(allocator, project_root, kind, key, "output.bin");
    defer allocator.free(cached_output);
    const cached_test_metadata = if (kind == .test_cache) try projectCacheTestMetadataPath(allocator, project_root, key) else null;
    defer if (cached_test_metadata) |path| allocator.free(path);
    if (!projectCacheArtifactExistsNonEmpty(cached_artifact) or
        !projectCacheArtifactExistsNonEmpty(cached_output) or
        (if (cached_test_metadata) |path| !projectCacheArtifactExistsNonEmpty(path) else false) or
        !projectCacheManifestValid(allocator, project_root, kind, key, cached_artifact, cached_output))
    {
        projectCacheRemoveKey(allocator, project_root, kind, key);
        return false;
    }
    copyFileAlloc(allocator, cached_artifact, artifact_path) catch |err| {
        projectCacheRemoveKey(allocator, project_root, kind, key);
        return err;
    };
    copyFileAlloc(allocator, cached_output, out_path) catch |err| {
        projectCacheRemoveKey(allocator, project_root, kind, key);
        return err;
    };
    return true;
}

fn projectCacheStore(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    kind: BuildCacheKind,
    key: ProjectCacheKey,
    artifact_path: []const u8,
    out_path: []const u8,
) !void {
    const cached_artifact = try projectCacheArtifactPath(allocator, project_root, kind, key, "artifact.sa.bc");
    defer allocator.free(cached_artifact);
    const cached_output = try projectCacheArtifactPath(allocator, project_root, kind, key, "output.bin");
    defer allocator.free(cached_output);
    try copyFileAlloc(allocator, artifact_path, cached_artifact);
    try copyFileAlloc(allocator, out_path, cached_output);
    try projectCacheWriteManifest(allocator, project_root, kind, key, cached_artifact, cached_output);
}

fn projectCacheTestMetadataPath(allocator: std.mem.Allocator, project_root: []const u8, key: ProjectCacheKey) ![]u8 {
    return try projectCacheArtifactPath(allocator, project_root, .test_cache, key, "test-metadata.json");
}

fn writeOptionalJsonString(writer: anytype, value: ?[]const u8) !void {
    if (value) |text| {
        try writeJsonString(writer, text);
    } else {
        try writer.writeAll("null");
    }
}

fn projectCacheWriteTestMetadata(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    key: ProjectCacheKey,
    test_list: test_meta.TestList,
) !void {
    const metadata_path = try projectCacheTestMetadataPath(allocator, project_root, key);
    defer allocator.free(metadata_path);
    try ensureParentDir(metadata_path);
    var file = try sio.cwd().createFile(metadata_path, .{ .truncate = true });
    defer file.close();
    var fbuf: [8192]u8 = undefined;
    var fw = file.writer(&fbuf);
    const writer = &fw.interface;
    try writer.writeAll("{\"version\":1,\"tests\":[");
    for (test_list.tests, 0..) |test_case, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try writer.print("{d}", .{test_case.desc.id});
        try writer.writeAll(",\"name\":");
        try writeJsonString(writer, test_case.desc.name);
        try writer.writeAll(",\"selector\":");
        try writeJsonString(writer, test_case.testfn.selector_name);
        try writer.writeAll(",\"source_file\":");
        try writeOptionalJsonString(writer, test_case.desc.source_file);
        try writer.writeAll(",\"line\":");
        try writer.print("{d}", .{test_case.desc.line});
        try writer.writeAll(",\"col\":");
        try writer.print("{d}", .{test_case.desc.col});
        try writer.writeAll(",\"ignored\":");
        try writer.writeAll(if (test_case.desc.ignored) "true" else "false");
        try writer.writeAll(",\"should_panic\":");
        try writer.writeAll(if (test_case.desc.should_panic) "true" else "false");
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
    try fw.interface.flush();
}

fn projectCacheStoreTest(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    key: ProjectCacheKey,
    artifact_path: []const u8,
    out_path: []const u8,
    test_list: test_meta.TestList,
) !void {
    const cached_artifact = try projectCacheArtifactPath(allocator, project_root, .test_cache, key, "artifact.sa.bc");
    defer allocator.free(cached_artifact);
    const cached_output = try projectCacheArtifactPath(allocator, project_root, .test_cache, key, "output.bin");
    defer allocator.free(cached_output);
    try copyFileAlloc(allocator, artifact_path, cached_artifact);
    try copyFileAlloc(allocator, out_path, cached_output);
    try projectCacheWriteTestMetadata(allocator, project_root, key, test_list);
    try projectCacheWriteManifest(allocator, project_root, .test_cache, key, cached_artifact, cached_output);
}

fn jsonBool(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |v| v,
        else => error.InvalidCacheManifest,
    };
}

fn jsonU32(value: std.json.Value) !u32 {
    return switch (value) {
        .integer => |v| if (v >= 0 and v <= std.math.maxInt(u32)) @intCast(v) else error.InvalidCacheManifest,
        else => error.InvalidCacheManifest,
    };
}

fn jsonStringDup(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .string => |text| try allocator.dupe(u8, text),
        else => error.InvalidCacheManifest,
    };
}

fn jsonOptionalStringDup(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    return switch (value) {
        .null => null,
        .string => |text| try allocator.dupe(u8, text),
        else => error.InvalidCacheManifest,
    };
}

fn projectCacheReadTestMetadata(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    key: ProjectCacheKey,
) !test_meta.TestList {
    const metadata_path = try projectCacheTestMetadataPath(allocator, project_root, key);
    defer allocator.free(metadata_path);
    const metadata_bytes = try readTextFileAlloc(allocator, metadata_path);
    defer allocator.free(metadata_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, metadata_bytes, .{});
    defer parsed.deinit();
    if (!jsonIntEquals(try jsonGetObject(parsed.value, "version"), 1)) return error.InvalidCacheManifest;
    const tests_value = try jsonGetObject(parsed.value, "tests");
    const tests_array = switch (tests_value) {
        .array => |array| array.items,
        else => return error.InvalidCacheManifest,
    };

    var tests = std.array_list.Managed(test_meta.TestDescAndFn).init(allocator);
    errdefer {
        for (tests.items) |*test_case| test_case.deinit(allocator);
        tests.deinit();
    }
    for (tests_array) |item| {
        switch (item) {
            .object => {},
            else => return error.InvalidCacheManifest,
        }
        const name = try jsonStringDup(allocator, try jsonGetObject(item, "name"));
        errdefer allocator.free(name);
        const selector = try jsonStringDup(allocator, try jsonGetObject(item, "selector"));
        errdefer allocator.free(selector);
        const source_file = try jsonOptionalStringDup(allocator, try jsonGetObject(item, "source_file"));
        errdefer if (source_file) |file| allocator.free(file);
        try tests.append(.{
            .desc = .{
                .id = try jsonU32(try jsonGetObject(item, "id")),
                .name = name,
                .source_file = source_file,
                .line = try jsonU32(try jsonGetObject(item, "line")),
                .col = try jsonU32(try jsonGetObject(item, "col")),
                .ignored = try jsonBool(try jsonGetObject(item, "ignored")),
                .should_panic = try jsonBool(try jsonGetObject(item, "should_panic")),
            },
            .testfn = .{ .selector_name = selector },
        });
    }
    return .{ .tests = try tests.toOwnedSlice(), .order = .Unsorted };
}

fn isHexCacheKey(name: []const u8) bool {
    if (name.len != 64) return false;
    for (name) |c| {
        switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => return false,
        }
    }
    return true;
}

fn cacheEntryExpired(stat: sio.Stat, max_age_days: u64) bool {
    if (max_age_days == 0) return false;
    const now = std.Io.Clock.real.now(sio.io());
    if (stat.mtime.compare(.gte, now)) return false;
    const max_age_ns: i96 = @as(i96, @intCast(max_age_days)) * 24 * 60 * 60 * std.time.ns_per_s;
    return stat.mtime.durationTo(now).toNanoseconds() > max_age_ns;
}

fn cacheFilePresentNonEmpty(dir: sio.Dir, name: []const u8) bool {
    const stat = dir.statFile(name) catch return false;
    return stat.kind == .file and stat.size != 0;
}

fn cacheDirPresent(dir: sio.Dir, name: []const u8) bool {
    const stat = dir.statFile(name) catch return false;
    return stat.kind == .directory;
}

fn cacheEntryComplete(kind: BuildCacheKind, entry_dir: sio.Dir) bool {
    return switch (kind) {
        .build_exe, .build_obj, .build_wasm => cacheFilePresentNonEmpty(entry_dir, "artifact.sa.bc") and cacheFilePresentNonEmpty(entry_dir, "output.bin") and cacheFilePresentNonEmpty(entry_dir, "manifest.json"),
        .test_cache => cacheFilePresentNonEmpty(entry_dir, "artifact.sa.bc") and cacheFilePresentNonEmpty(entry_dir, "output.bin") and cacheFilePresentNonEmpty(entry_dir, "manifest.json") and cacheFilePresentNonEmpty(entry_dir, "test-metadata.json"),
        .build_obj_incremental => cacheFilePresentNonEmpty(entry_dir, "manifest.json") and cacheDirPresent(entry_dir, "functions"),
    };
}

fn cacheEntryArtifactMatchesManifest(entry_dir: sio.Dir, artifact_value: std.json.Value, name: []const u8) !bool {
    const stat = entry_dir.statFile(name) catch return false;
    if (stat.kind != .file or stat.size == 0) return false;
    if (!jsonIntEquals(try jsonGetObject(artifact_value, "size"), stat.size)) return false;
    const hash_hex = try hashDirFileHex(entry_dir, name);
    return jsonStringEquals(try jsonGetObject(artifact_value, "sha256"), hash_hex[0..]);
}

fn cacheEntryManifestValid(kind: BuildCacheKind, key_name: []const u8, entry_dir: sio.Dir) bool {
    if (kind == .build_obj_incremental) return true;
    const manifest_bytes = entry_dir.readFileAlloc(std.heap.page_allocator, "manifest.json", 64 * 1024) catch return false;
    defer std.heap.page_allocator.free(manifest_bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, manifest_bytes, .{}) catch return false;
    defer parsed.deinit();
    if (!jsonIntEquals(jsonGetObject(parsed.value, "version") catch return false, 1)) return false;
    if (!jsonStringEquals(jsonGetObject(parsed.value, "kind") catch return false, kind.dirName())) return false;
    if (!jsonStringEquals(jsonGetObject(parsed.value, "key") catch return false, key_name)) return false;
    if (!(cacheEntryArtifactMatchesManifest(entry_dir, jsonGetObject(parsed.value, "artifact") catch return false, "artifact.sa.bc") catch return false)) return false;
    if (!(cacheEntryArtifactMatchesManifest(entry_dir, jsonGetObject(parsed.value, "output") catch return false, "output.bin") catch return false)) return false;
    return true;
}

fn cleanCacheKindDir(
    root_dir: sio.Dir,
    kind: BuildCacheKind,
    options: CacheCleanOptions,
    stats: *CacheCleanStats,
) !void {
    var kind_dir = root_dir.openDir(kind.dirName(), .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => {
            stats.scanned += 1;
            stats.removed += 1;
            if (!options.dry_run) try root_dir.deleteFile(kind.dirName());
            return;
        },
        else => return err,
    };
    defer kind_dir.close();

    var iter = kind_dir.iterate();
    while (try iter.next()) |entry| {
        stats.scanned += 1;
        var remove = entry.kind != .directory or !isHexCacheKey(entry.name);
        if (!remove) {
            var entry_dir = kind_dir.openDir(entry.name, .{}) catch {
                remove = true;
                if (!options.dry_run) try kind_dir.deleteTree(entry.name);
                stats.removed += 1;
                continue;
            };
            defer entry_dir.close();

            const stat: ?sio.Stat = kind_dir.statFile(entry.name) catch null;
            remove = !cacheEntryComplete(kind, entry_dir) or
                !cacheEntryManifestValid(kind, entry.name, entry_dir) or
                (if (stat) |s| cacheEntryExpired(s, options.max_age_days) else true);
        }

        if (remove) {
            stats.removed += 1;
            if (!options.dry_run) {
                if (entry.kind == .directory) {
                    try kind_dir.deleteTree(entry.name);
                } else {
                    try kind_dir.deleteFile(entry.name);
                }
            }
        } else {
            stats.kept += 1;
        }
    }
}

fn cleanProjectCache(allocator: std.mem.Allocator, project_root: []const u8, options: CacheCleanOptions) !CacheCleanStats {
    const cache_root = try cacheRootPath(allocator, project_root);
    defer allocator.free(cache_root);
    var root_dir = sio.cwd().openDir(cache_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        error.NotDir => {
            if (!options.dry_run) try sio.cwd().deleteFile(cache_root);
            return .{ .scanned = 1, .removed = 1 };
        },
        else => return err,
    };
    defer root_dir.close();

    var stats: CacheCleanStats = .{};
    try cleanCacheKindDir(root_dir, .build_exe, options, &stats);
    try cleanCacheKindDir(root_dir, .build_obj, options, &stats);
    try cleanCacheKindDir(root_dir, .build_wasm, options, &stats);
    try cleanCacheKindDir(root_dir, .build_obj_incremental, options, &stats);
    try cleanCacheKindDir(root_dir, .test_cache, options, &stats);
    return stats;
}

fn executeCacheCommand(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype) !u8 {
    if (args.len == 0 or isHelpFlag(args[0])) {
        try printCacheHelp(stdout, args);
        return 0;
    }
    if (!std.mem.eql(u8, args[0], "clean")) return error.UnknownCommand;

    var options: CacheCleanOptions = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (isHelpFlag(args[i])) {
            try printCacheHelp(stdout, args);
            return 0;
        }
        if (std.mem.eql(u8, args[i], "--dry-run")) {
            options.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--max-age-days")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            options.max_age_days = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, args[i], "--max-age-days=")) {
            options.max_age_days = try std.fmt.parseInt(u64, args[i]["--max-age-days=".len..], 10);
            continue;
        }
        return error.UnexpectedArgument;
    }

    const project_root = try projectRootDir(allocator);
    defer allocator.free(project_root);
    const stats = try cleanProjectCache(allocator, project_root, options);
    try stdout.print("cache clean: scanned={d} removed={d} kept={d} dry_run={} max_age_days={d}\n", .{ stats.scanned, stats.removed, stats.kept, options.dry_run, options.max_age_days });
    return 0;
}

fn projectFunctionCachePath(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    key: ProjectCacheKey,
    function_key: []const u8,
) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}.o", .{function_key});
    defer allocator.free(filename);
    return try pathJoinAlloc(allocator, &.{ project_root, ".sa_cache", BuildCacheKind.build_obj_incremental.dirName(), key.slice(), "functions", filename });
}

fn projectFunctionCacheManifestPath(allocator: std.mem.Allocator, project_root: []const u8, key: ProjectCacheKey) ![]u8 {
    return try pathJoinAlloc(allocator, &.{ project_root, ".sa_cache", BuildCacheKind.build_obj_incremental.dirName(), key.slice(), "manifest.json" });
}

fn cacheFunctionSig(hasher: *std.crypto.hash.sha2.Sha256, sig_item: anytype) void {
    cacheBytes(hasher, sig_item.name);
    cacheU64(hasher, @intFromEnum(sig_item.kind));
    cacheBool(hasher, sig_item.return_fallible);
    cacheBool(hasher, sig_item.is_ffi_wrapper);
    cacheBool(hasher, sig_item.ignored);
    cacheBool(hasher, sig_item.should_panic);
    cacheU64(hasher, @intFromEnum(sig_item.return_ty));
    if (sig_item.return_cap) |cap| {
        cacheBool(hasher, true);
        cacheU64(hasher, @intFromEnum(cap));
    } else {
        cacheBool(hasher, false);
    }
    if (sig_item.llvm_name) |name| cacheBytes(hasher, name) else cacheBytes(hasher, "");
    for (sig_item.params) |param| {
        cacheBytes(hasher, param.name);
        cacheU64(hasher, @intFromEnum(param.ty));
        cacheU64(hasher, @intFromEnum(param.cap));
    }
}

fn computeFunctionObjectKey(allocator: std.mem.Allocator, source_path: []const u8, verified: *const referee.VerifyOk, sig_index: usize, start_idx: usize, end_idx: usize) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    cacheBytes(&hasher, "sa-build-obj-function-cache");
    cacheBytes(&hasher, cacheCompilerVersion());
    cacheBytes(&hasher, source_path);
    for (verified.function_sigs) |sig_item| {
        cacheFunctionSig(&hasher, sig_item);
    }
    for (verified.const_decls) |decl| {
        cacheBytes(&hasher, decl.raw_text);
    }
    cacheU64(&hasher, sig_index);
    cacheFunctionSig(&hasher, verified.function_sigs[sig_index]);
    for (verified.annotated[start_idx..end_idx]) |item| {
        cacheBytes(&hasher, item.base.raw_text);
    }
    var out: [32]u8 = undefined;
    hasher.final(&out);
    const hex = std.fmt.bytesToHex(out, .lower);
    return try allocator.dupe(u8, hex[0..]);
}

fn buildIncrementalObject(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    cache_key: ProjectCacheKey,
    compiled: *const CompileOk,
    source_path: []const u8,
    out_path: []const u8,
    debug: bool,
    optimization: driver.Optimization,
    compile_options: CompileOptions,
    stderr: anytype,
) !void {
    const opt_level = emitOptLevel(debug, optimization);
    const emit_std_root = try stdRootFromEnv(allocator);
    defer allocator.free(emit_std_root);
    var object_paths = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (object_paths.items) |path| allocator.free(path);
        object_paths.deinit();
    }
    var function_keys = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (function_keys.items) |key| allocator.free(key);
        function_keys.deinit();
    }

    var sig_index: usize = 0;
    var idx: usize = 0;
    var task_idx: usize = 0;
    while (idx < compiled.verified.annotated.len) : (idx += 1) {
        const item = compiled.verified.annotated[idx].base;
        switch (item.kind) {
            .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
                if (sig_index >= compiled.verified.function_sigs.len) return error.UnknownFunction;
                const current_sig_index = sig_index;
                sig_index += 1;

                var end = idx + 1;
                while (end < compiled.verified.annotated.len and switch (compiled.verified.annotated[end].base.kind) {
                    .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => false,
                    else => true,
                }) : (end += 1) {}

                if (item.kind != .extern_decl) {
                    const function_key = try computeFunctionObjectKey(allocator, source_path, &compiled.verified, current_sig_index, idx, end);
                    var function_key_owned = true;
                    errdefer if (function_key_owned) allocator.free(function_key);
                    const object_path = try projectFunctionCachePath(allocator, project_root, cache_key, function_key);
                    var object_path_owned = true;
                    errdefer if (object_path_owned) allocator.free(object_path);
                    if (!projectPathExists(object_path)) {
                        try ensureParentDir(object_path);
                        try emit_llvm_llvmc.emitLlvmcToObject(
                            allocator,
                            compiled.verified,
                            &compiled.flat.def_dict,
                            compiled.flat.loc_table,
                            source_path,
                            nativeSizeBits(),
                            .{
                                .debug = debug,
                                .jobs = 1,
                                .opt_level = opt_level,
                                .function_task_index = task_idx,
                                .dce = compile_options.dce,
                                .std_root = emit_std_root,
                            },
                            object_path,
                            opt_level,
                        );
                    }
                    try function_keys.append(function_key);
                    function_key_owned = false;
                    try object_paths.append(object_path);
                    object_path_owned = false;
                }

                task_idx += 1;
                idx = end - 1;
            },
            else => {},
        }
    }

    if (object_paths.items.len == 0) {
        return error.UnknownFunction;
    }

    try ensureParentDir(out_path);
    driver.compileRelocatableObj(allocator, object_paths.items, out_path, stderr) catch |err| switch (err) {
        error.ChildProcessFailed => return error.ChildProcessFailed,
        else => return err,
    };

    const manifest_path = try projectFunctionCacheManifestPath(allocator, project_root, cache_key);
    defer allocator.free(manifest_path);
    try ensureParentDir(manifest_path);
    var manifest_file = try sio.cwd().createFile(manifest_path, .{ .truncate = true });
    defer manifest_file.close();
    var mfbuf: [8192]u8 = undefined;
    var mfw = manifest_file.writer(&mfbuf);
    const writer = &mfw.interface;
    try writer.writeAll("{\"version\":1,\"kind\":\"build-obj-incremental\",\"source\":");
    try writeJsonString(writer, source_path);
    try writer.writeAll(",\"cache_key\":");
    try writeJsonString(writer, cache_key.slice());
    try writer.writeAll(",\"functions\":[");
    for (function_keys.items, object_paths.items, 0..) |function_key, object_path, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.writeAll("{\"key\":");
        try writeJsonString(writer, function_key);
        try writer.writeAll(",\"object\":");
        try writeJsonString(writer, object_path);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
    try mfw.interface.flush();
}

fn ensureNewFile(path: []const u8, bytes: []const u8) !void {
    try ensureParentDir(path);
    var file = try sio.cwd().createFile(path, .{ .exclusive = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn executeInit(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype) !u8 {
    if (args.len > 1) return error.UnexpectedArgument;
    const project_path = if (args.len == 1) args[0] else ".";

    try sio.cwd().makePath(project_path);

    const src_dir = try std.fs.path.join(allocator, &.{ project_path, "src" });
    defer allocator.free(src_dir);
    try sio.cwd().makePath(src_dir);

    const manifest_path = try std.fs.path.join(allocator, &.{ project_path, "sa.mod" });
    defer allocator.free(manifest_path);
    const main_path = try std.fs.path.join(allocator, &.{ project_path, "src", "main.sars" });
    defer allocator.free(main_path);
    const gitignore_path = try std.fs.path.join(allocator, &.{ project_path, ".gitignore" });
    defer allocator.free(gitignore_path);

    try ensureNewFile(manifest_path,
        \\# generated by sa init
        \\
    );
    try ensureNewFile(main_path,
        \\@main() -> i32:
        \\return 0
        \\
    );
    try ensureNewFile(gitignore_path,
        \\.zig-cache/
        \\.sa_cache/
        \\zig-out/
        \\*.out
        \\*.sa.bc
        \\
    );

    try stdout.print("Initialized SA binary project: {s}\n", .{project_path});
    try stdout.print("Entry: {s}\n", .{main_path});
    return 0;
}

const InstallArgs = struct {
    options: pkg_fetch.FetchOptions = .{},
    identity: ?[]const u8 = null,
    ref: []const u8 = "HEAD",
    package_name: ?[]const u8 = null,
};

fn fetchManifestRequires(allocator: std.mem.Allocator, manifest_file: *const manifest.Manifest, fetch_options: pkg_fetch.FetchOptions, stdout: anytype) !void {
    for (manifest_file.requires) |entry| {
        var entry_fetch_options = fetch_options;
        entry_fetch_options.expected_source_sha256 = entry.source_sha256;
        var result = try pkg_fetch.fetchPackage(allocator, entry.url, entry.ref, entry_fetch_options);
        defer result.deinit(allocator);
        if (!hashesEqual(result.source_sha256, entry.source_sha256)) return error.UpstreamShaMismatch;
        try stdout.print("{s}\n", .{result.root});
    }
}

fn installManifestPlugins(allocator: std.mem.Allocator, manifest_file: *const manifest.Manifest, stdout: anytype) !u8 {
    for (manifest_file.plugin_requires) |entry| {
        _ = entry.abi;
        _ = entry.ref;
        const code = try plugins.installFromPath(allocator, entry.identity, stdout, .{});
        if (code != 0) return code;
    }
    return 0;
}

fn parseInstallArgs(args: []const []const u8) !InstallArgs {
    var parsed = InstallArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-g")) {
            parsed.options.global = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--offline")) {
            parsed.options.offline = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--package") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 >= args.len) return error.UnknownPackage;
            parsed.package_name = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--package=")) {
            parsed.package_name = arg["--package=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-p=")) {
            parsed.package_name = arg["-p=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--ref")) {
            if (i + 1 >= args.len) return error.MissingRef;
            parsed.ref = args[i + 1];
            i += 1;
            continue;
        }
        if (parsed.identity == null) {
            parsed.identity = arg;
            continue;
        }
        return error.UnexpectedArgument;
    }
    return parsed;
}

fn installManifestDependencies(allocator: std.mem.Allocator, options: pkg_fetch.FetchOptions, package_name: ?[]const u8, stdout: anytype) !u8 {
    var resolution = try pkg_workspace.resolveFromCurrentDir(allocator, .{ .request = package_name });
    defer resolution.deinit(allocator);

    const project_root = resolution.workspace_root;
    const project_manifest = resolution.effective_manifest orelse return 0;

    const current_dir = try sio.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(current_dir);

    if (package_name == null and
        resolution.workspace_manifest != null and
        resolution.workspace_manifest.?.workspace != null and
        std.mem.eql(u8, current_dir, resolution.workspace_root))
    {
        const members = try pkg_workspace.listWorkspaceMembers(allocator, resolution.workspace_root, &resolution.workspace_manifest.?);
        defer pkg_workspace.freeWorkspaceMembers(allocator, members);

        var member_manifests = std.array_list.Managed(manifest.Manifest).init(allocator);
        defer {
            for (member_manifests.items) |*member_manifest| member_manifest.deinit(allocator);
            member_manifests.deinit();
        }

        var member_manifest_ptrs = std.array_list.Managed(*const manifest.Manifest).init(allocator);
        defer member_manifest_ptrs.deinit();

        for (members) |member| {
            const member_manifest_path = try projectManifestPath(allocator, member.member_root);
            defer allocator.free(member_manifest_path);
            const member_manifest = try readManifestFile(allocator, member_manifest_path);
            try member_manifests.append(member_manifest);
        }

        for (member_manifests.items) |*member_manifest| {
            try member_manifest_ptrs.append(member_manifest);
        }

        var aggregate_manifest = try manifest.mergeWorkspaceMemberSet(
            allocator,
            &resolution.workspace_manifest.?,
            member_manifest_ptrs.items,
        );
        defer aggregate_manifest.deinit(allocator);

        var mirror_rules = try pkg_mirror.loadProjectRules(allocator, project_root, aggregate_manifest.mirrors);
        defer mirror_rules.deinit(allocator);

        var fetch_options = options;
        fetch_options.mirror_rules = mirror_rules.rules;

        try fetchManifestRequires(allocator, &aggregate_manifest, fetch_options, stdout);
        const plugin_code = try installManifestPlugins(allocator, &aggregate_manifest, stdout);
        if (plugin_code != 0) return plugin_code;

        var update = try pkg_sum.updateProjectSum(allocator, project_root, aggregate_manifest);
        defer update.deinit(allocator);
        return 0;
    }

    var mirror_rules = try pkg_mirror.loadProjectRules(allocator, project_root, project_manifest.mirrors);
    defer mirror_rules.deinit(allocator);

    var fetch_options = options;
    fetch_options.mirror_rules = mirror_rules.rules;

    try fetchManifestRequires(allocator, &project_manifest, fetch_options, stdout);
    const plugin_code = try installManifestPlugins(allocator, &project_manifest, stdout);
    if (plugin_code != 0) return plugin_code;

    var update = try pkg_sum.updateProjectSum(allocator, project_root, project_manifest);
    defer update.deinit(allocator);

    return 0;
}

fn executeInstall(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype) !u8 {
    const parsed = try parseInstallArgs(args);
    if (parsed.identity) |identity| {
        var result = try pkg_fetch.fetchPackage(allocator, identity, parsed.ref, parsed.options);
        defer result.deinit(allocator);
        try stdout.print("{s}\n", .{result.root});
        return 0;
    }
    return try installManifestDependencies(allocator, parsed.options, parsed.package_name, stdout);
}

fn executePkgCommandFallback(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !?u8 {
    if (args.len < 3) return null;
    const sub = args[2];
    if (std.mem.eql(u8, sub, "install")) {
        return try executeInstall(allocator, args[3..], stdout);
    }
    _ = stderr;
    return null;
}

fn executePluginCommand(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    if (args.len == 0) {
        try stderr.writeAll("usage: sars plugin install [--dev] [--review] <path|sap.json> | list\n");
        return 1;
    }
    if (std.mem.eql(u8, args[0], "install")) {
        if (args.len < 2) {
            try stderr.writeAll("usage: sars plugin install [--dev] [--review] <path|sap.json>\n");
            return 1;
        }
        var dev = false;
        var review = false;
        var target: ?[]const u8 = null;
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--dev")) {
                dev = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--review")) {
                review = true;
                continue;
            }
            if (target == null) {
                target = arg;
                continue;
            }
            return error.UnexpectedArgument;
        }
        return try plugins.installFromPath(allocator, target orelse return error.MissingSourcePath, stdout, .{ .dev = dev, .review = review });
    }
    if (std.mem.eql(u8, args[0], "list")) {
        if (args.len > 1) return error.UnexpectedArgument;
        return try plugins.listInstalled(allocator, stdout);
    }
    try stderr.writeAll("usage: sars plugin install [--dev] [--review] <path|sap.json> | list\n");
    return 1;
}

fn saStdArchivePath(allocator: std.mem.Allocator) ![]u8 {
    const archive_name = switch (builtin.os.tag) {
        .windows => "sa_std.lib",
        else => "libsa_std.a",
    };
    if (builtin.is_test) {
        return try allocator.dupe(u8, build_options.sa_std_archive_path);
    }
    const env_root: ?[]u8 = sio.getEnvVarOwned(allocator, "SA_STD_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_root) |root| {
        errdefer allocator.free(root);
        const archive = try std.fs.path.join(allocator, &.{ root, archive_name });
        if (sio.cwd().openFile(archive, .{})) |file| {
            file.close();
            allocator.free(root);
            return archive;
        } else |_| {
            allocator.free(archive);
        }
        allocator.free(root);
    }
    return try allocator.dupe(u8, build_options.sa_std_archive_path);
}

/// Locate the sa_std static archive for an optional cross-compilation triple.
/// Layout: $SA_STD_DIR/<triple>/libsa_std.a (or sa_std.lib for windows triples).
/// Returns error.ArchiveNotFoundForTarget when the triple archive is missing.
fn saStdArchivePathForTarget(allocator: std.mem.Allocator, target_triple: ?[]const u8) ![]u8 {
    const triple = target_triple orelse return saStdArchivePath(allocator);
    const archive_name: []const u8 = if (tripleIsWindows(target_triple)) "sa_std.lib" else "libsa_std.a";
    const env_root: ?[]u8 = sio.getEnvVarOwned(allocator, "SA_STD_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_root) |root| {
        defer allocator.free(root);
        const archive = try std.fs.path.join(allocator, &.{ root, triple, archive_name });
        errdefer allocator.free(archive);
        if (sio.cwd().openFile(archive, .{})) |file| {
            file.close();
            return archive;
        } else |_| {}
        return error.ArchiveNotFoundForTarget;
    }
    return error.ArchiveNotFoundForTarget;
}

/// `#npm_bind` bindings only lower under `sa build-js`. Every other
/// emit/run path rejects them here with a targeted diagnostic instead of
/// a confusing missing-symbol failure downstream (JS target only; the
/// wasm and native backends have no ESM import mechanism).
fn rejectNpmBindsUnlessJs(cmd_name: []const u8, flat: *const flattener.FlattenResult, stderr: anytype) !void {
    if (flat.def_dict.npm_binds.count() == 0) return;
    try stderr.print("error: {s} does not support `#npm_bind` npm imports; use `sa build-js` (JS target only)\n", .{cmd_name});
    return error.NpmImportJsOnly;
}

fn executeRun(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    compile_options: CompileOptions,
    argv: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    diagnostics_mode: DiagnosticsMode,
) !u8 {
    const compiled = try compileSource(allocator, source_path, compile_options);
    switch (compiled) {
        .trap => |report| {
            try printTrapReport(stderr, report, diagnostics_mode);
            return 1;
        },
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(allocator);
            rejectNpmBindsUnlessJs("sa run", &owned.flat, stderr) catch return 1;
            var run_out_forward = sio.ForwardWriter(@TypeOf(stdout)).init(stdout);
            defer run_out_forward.writer().flush() catch {};
            var run_err_forward = sio.ForwardWriter(@TypeOf(stderr)).init(stderr);
            defer run_err_forward.writer().flush() catch {};
            const code = interp.runWithWriters(allocator, &owned.verified, argv, run_out_forward.writer(), run_err_forward.writer()) catch |err| switch (err) {
                error.UserExit => 0,
                error.UnsupportedExtern => return 1,
                else => {
                    try printCliError(stderr, err, diagnostics_mode);
                    return 1;
                },
            };
            try writeSuccessDiagnostics(stderr, owned.metrics, diagnostics_mode);
            return code;
        },
    }
}

fn executeBuildExe(allocator: std.mem.Allocator, source_path: []const u8, out_path: []const u8, debug: bool, optimization: driver.Optimization, compile_options: CompileOptions, stderr: anytype, diagnostics_mode: DiagnosticsMode) !u8 {
    const total_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
    const project_root_owned = compile_options.project_root == null;
    const project_root = compile_options.project_root orelse try projectRootFromSourcePath(allocator, source_path);
    defer if (project_root_owned) allocator.free(project_root);
    var project_context = try loadProjectContext(allocator, project_root, compile_options.package_name);
    defer project_context.deinit(allocator);
    const cache_key: ?ProjectCacheKey = if (compile_options.incremental_cache)
        try computeProjectBuildKey(allocator, &project_context, project_root, source_path, "exe", compile_options.target_triple orelse "", .build_exe, debug, optimization == .release_fast, false, null, true, compile_options.offline, compile_options.dce)
    else
        null;
    const artifact_path = try intermediateArtifactPath(allocator, out_path);
    defer allocator.free(artifact_path);

    if (cache_key) |key| {
        if (try projectCacheHit(allocator, project_root, .build_exe, key, artifact_path, out_path)) {
            try makeExecutable(out_path);
            if (diagnostics_mode == .json or compile_options.mem_report) {
                const metrics = CompileMetrics{ .compile_tokens = 0, .instruction_count = 0, .phases = if (compile_options.profile) .{ .load_ns = 0, .setup_ns = 0, .flatten_ns = 0, .verify_ns = 0, .emit_ns = 0, .link_ns = 0, .total_ns = if (total_start) |start| elapsedNs(start) else null } else null, .memory = cacheHitMemoryMetrics(compile_options.mem_report), .cache = .{ .kind = BuildCacheKind.build_exe.dirName(), .hit = true } };
                try writeSuccessDiagnostics(stderr, metrics, diagnostics_mode);
            }
            return 0;
        }
    }

    const compiled = try compileSource(allocator, source_path, compile_options);
    switch (compiled) {
        .trap => |report| {
            try printTrapReport(stderr, report, diagnostics_mode);
            return 1;
        },
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(allocator);
            rejectNpmBindsUnlessJs("sa build-exe", &owned.flat, stderr) catch return 1;
            const emit_std_root = try stdRootFromEnv(allocator);
            defer allocator.free(emit_std_root);
            const std_archive_path = saStdArchivePathForTarget(allocator, compile_options.target_triple) catch |err| {
                if (err == error.ArchiveNotFoundForTarget) {
                    try stderr.print("error: no sa_std archive for target '{s}'. Build it with:\n", .{compile_options.target_triple.?});
                    try stderr.writeAll("  zig build -Dtarget=<triple> sa-std-static\n");
                    try stderr.writeAll("then copy zig-out/lib/<libsa_std.a|sa_std.lib> to $SA_STD_DIR/<triple>/\n");
                    return 1;
                }
                return err;
            };
            defer allocator.free(std_archive_path);
            const size_bits = sizeBitsForTriple(compile_options.target_triple);

            const worker_count = blk: {
                if (compile_options.jobs) |j| {
                    break :blk j;
                }
                break :blk std.Thread.getCpuCount() catch 1;
            };
            const emission_workers = @max(@min(worker_count, 4), 1);
            const use_cgu = (compile_options.jobs_explicit and emission_workers > 1 and owned.verified.function_sigs.len >= 100);

            if (use_cgu) {
                const cgu_count = @min(@max(emission_workers, 2), 4);

                const cgu_obj_paths = try allocator.alloc([]const u8, cgu_count);
                defer {
                    for (cgu_obj_paths) |p| allocator.free(p);
                    allocator.free(cgu_obj_paths);
                }
                for (0..cgu_count) |i| {
                    cgu_obj_paths[i] = try std.fmt.allocPrint(allocator, "{s}_cgu_{d}.o", .{ out_path, i });
                }

                // Ensure parent directory exists for all of them
                for (cgu_obj_paths) |p| {
                    try ensureParentDir(p);
                }

                // Parallel emit CGU bitcode files
                const VerifiedType = @TypeOf(owned.verified);
                const CguEmitWorker = struct {
                    alloc_val: std.mem.Allocator,
                    verified_ptr: *const VerifiedType,
                    def_dict_ptr: ?*const flattener.DefDict,
                    loc_table_val: @TypeOf(owned.flat.loc_table),
                    source_path_val: []const u8,
                    size_bits_val: u16,
                    debug_val: bool,
                    jobs_val: ?usize,
                    dce_val: DceMode,
                    cgu_idx_val: usize,
                    cgu_count_val: usize,
                    object_path_val: []const u8,
                    opt_level_val: u8,
                    std_root_val: []const u8,
                    target_triple_val: ?[]const u8,
                    err: ?anyerror = null,

                    pub fn run(self: *@This()) void {
                        emit_llvm_llvmc.emitLlvmcToObject(
                            self.alloc_val,
                            self.verified_ptr.*,
                            self.def_dict_ptr,
                            self.loc_table_val,
                            self.source_path_val,
                            self.size_bits_val,
                            .{
                                .debug = self.debug_val,
                                .jobs = self.jobs_val,
                                .opt_level = self.opt_level_val,
                                .codegen_unit_index = self.cgu_idx_val,
                                .codegen_unit_count = self.cgu_count_val,
                                .dce = self.dce_val,
                                .std_root = self.std_root_val,
                                .target_triple = self.target_triple_val,
                            },
                            self.object_path_val,
                            self.opt_level_val,
                        ) catch |err| {
                            self.err = err;
                        };
                    }
                };

                var cgu_emit_workers = try allocator.alloc(CguEmitWorker, cgu_count);
                defer allocator.free(cgu_emit_workers);

                for (0..cgu_count) |i| {
                    cgu_emit_workers[i] = .{
                        .alloc_val = allocator,
                        .verified_ptr = &owned.verified,
                        .def_dict_ptr = &owned.flat.def_dict,
                        .loc_table_val = owned.flat.loc_table,
                        .source_path_val = source_path,
                        .size_bits_val = size_bits,
                        .debug_val = debug,
                        .jobs_val = if (compile_options.jobs) |j| if (j > 1) 1 else j else 1,
                        .dce_val = compile_options.dce,
                        .cgu_idx_val = i,
                        .cgu_count_val = cgu_count,
                        .object_path_val = cgu_obj_paths[i],
                        .opt_level_val = emitOptLevel(debug, optimization),
                        .std_root_val = emit_std_root,
                        .target_triple_val = compile_options.target_triple,
                    };
                }

                var cgu_emit_threads = try allocator.alloc(std.Thread, cgu_count - 1);
                defer allocator.free(cgu_emit_threads);

                var started_cgu_emit: usize = 0;
                errdefer {
                    while (started_cgu_emit > 0) {
                        started_cgu_emit -= 1;
                        cgu_emit_threads[started_cgu_emit].join();
                    }
                }

                const emit_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
                while (started_cgu_emit < cgu_count - 1) : (started_cgu_emit += 1) {
                    cgu_emit_threads[started_cgu_emit] = try std.Thread.spawn(.{}, CguEmitWorker.run, .{&cgu_emit_workers[started_cgu_emit + 1]});
                }

                cgu_emit_workers[0].run();

                while (started_cgu_emit > 0) {
                    started_cgu_emit -= 1;
                    cgu_emit_threads[started_cgu_emit].join();
                }

                for (cgu_emit_workers) |w| {
                    if (w.err) |err| return err;
                }
                const emit_ns = if (emit_start) |start| elapsedNs(start) else null;
                recordMetricMemoryAfterEmit(&owned.metrics);
                if (owned.metrics.memory) |memory| try writeMemoryStageSampleForOptions(compile_options, "after_emit", memory.after_emit_rss_bytes, memory.after_verify_rss_bytes);

                var link_inputs = std.array_list.Managed([]const u8).init(allocator);
                defer link_inputs.deinit();
                var owned_link_inputs = std.array_list.Managed([]const u8).init(allocator);
                defer {
                    for (owned_link_inputs.items) |arg| allocator.free(arg);
                    owned_link_inputs.deinit();
                }

                for (1..cgu_count) |i| {
                    try link_inputs.append(cgu_obj_paths[i]);
                }
                if (compile_options.target_triple) |triple| {
                    const extern_names = try collectExternalSymbolNames(allocator, &owned.verified);
                    defer allocator.free(extern_names);
                    if (extern_names.len != 0) {
                        try stderr.print("error: --target {s} does not support native plugins yet (program uses extern symbol '{s}')\n", .{ triple, extern_names[0] });
                        return 1;
                    }
                } else {
                    try appendNativePluginLinkInputs(allocator, &link_inputs, &owned_link_inputs, &owned.verified);
                }

                const link_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
                driver.compileExe(allocator, cgu_obj_paths[0], out_path, optimization, std_archive_path, link_inputs.items, debug, stderr, compile_options.target_triple) catch |err| switch (err) {
                    error.ChildProcessFailed => return 1,
                    else => return err,
                };
                const link_ns = if (link_start) |start| elapsedNs(start) else null;
                recordMetricMemoryAfterLink(&owned.metrics);
                if (owned.metrics.memory) |memory| try writeMemoryStageSampleForOptions(compile_options, "after_link", memory.after_link_rss_bytes, memory.after_emit_rss_bytes);
                recordMetricMemoryEnd(&owned.metrics);
                if (owned.metrics.memory) |memory| try writeMemoryStageSampleForOptions(compile_options, "end", memory.end_rss_bytes, memoryEndPrevious(memory));
                finishProfileMetrics(&owned.metrics, emit_ns, link_ns, if (total_start) |start| elapsedNs(start) else null);
            } else {
                try ensureParentDir(artifact_path);
                const emit_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
                emit_llvm_llvmc.emitLlvmcToFile(allocator, owned.verified, &owned.flat.def_dict, owned.flat.loc_table, source_path, size_bits, .{ .debug = debug, .jobs = compile_options.jobs, .opt_level = emitOptLevel(debug, optimization), .dce = compile_options.dce, .std_root = emit_std_root, .target_triple = compile_options.target_triple }, artifact_path) catch |err| {
                    try printLlvmcEmitError(stderr, err, diagnostics_mode);
                    return 1;
                };
                const emit_ns = if (emit_start) |start| elapsedNs(start) else null;
                recordMetricMemoryAfterEmit(&owned.metrics);
                if (owned.metrics.memory) |memory| try writeMemoryStageSampleForOptions(compile_options, "after_emit", memory.after_emit_rss_bytes, memory.after_verify_rss_bytes);

                const link_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
                var link_inputs = std.array_list.Managed([]const u8).init(allocator);
                defer link_inputs.deinit();
                var owned_link_inputs = std.array_list.Managed([]const u8).init(allocator);
                defer {
                    for (owned_link_inputs.items) |arg| allocator.free(arg);
                    owned_link_inputs.deinit();
                }
                if (compile_options.target_triple) |triple| {
                    const extern_names = try collectExternalSymbolNames(allocator, &owned.verified);
                    defer allocator.free(extern_names);
                    if (extern_names.len != 0) {
                        try stderr.print("error: --target {s} does not support native plugins yet (program uses extern symbol '{s}')\n", .{ triple, extern_names[0] });
                        return 1;
                    }
                } else {
                    try appendNativePluginLinkInputs(allocator, &link_inputs, &owned_link_inputs, &owned.verified);
                }
                driver.compileExe(allocator, artifact_path, out_path, optimization, std_archive_path, link_inputs.items, debug, stderr, compile_options.target_triple) catch |err| switch (err) {
                    error.ChildProcessFailed => return 1,
                    else => return err,
                };
                const link_ns = if (link_start) |start| elapsedNs(start) else null;
                recordMetricMemoryAfterLink(&owned.metrics);
                if (owned.metrics.memory) |memory| try writeMemoryStageSampleForOptions(compile_options, "after_link", memory.after_link_rss_bytes, memory.after_emit_rss_bytes);
                recordMetricMemoryEnd(&owned.metrics);
                if (owned.metrics.memory) |memory| try writeMemoryStageSampleForOptions(compile_options, "end", memory.end_rss_bytes, memoryEndPrevious(memory));
                finishProfileMetrics(&owned.metrics, emit_ns, link_ns, if (total_start) |start| elapsedNs(start) else null);
                if (cache_key) |key| try projectCacheStore(allocator, project_root, .build_exe, key, artifact_path, out_path);
            }
            attachBackendIrMetrics(&owned.metrics, &owned.verified, debug);
            if (cache_key != null) owned.metrics.cache = .{ .kind = BuildCacheKind.build_exe.dirName(), .hit = false };

            try writeSuccessDiagnostics(stderr, owned.metrics, diagnostics_mode);
            return 0;
        },
    }
}

fn executeBuildObj(allocator: std.mem.Allocator, source_path: []const u8, out_path: []const u8, debug: bool, optimization: driver.Optimization, incremental: bool, compile_options: CompileOptions, stderr: anytype, diagnostics_mode: DiagnosticsMode) !u8 {
    const total_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
    const project_root_owned = compile_options.project_root == null;
    const project_root = compile_options.project_root orelse try projectRootFromSourcePath(allocator, source_path);
    defer if (project_root_owned) allocator.free(project_root);
    var project_context = try loadProjectContext(allocator, project_root, compile_options.package_name);
    defer project_context.deinit(allocator);
    const cache_key: ?ProjectCacheKey = if (compile_options.incremental_cache)
        try computeProjectBuildKey(allocator, &project_context, project_root, source_path, "obj", compile_options.target_triple orelse "", .build_obj, debug, optimization == .release_fast, incremental, null, true, compile_options.offline, compile_options.dce)
    else
        null;
    const artifact_path = try intermediateArtifactPath(allocator, out_path);
    defer allocator.free(artifact_path);

    if (cache_key) |key| {
        if (try projectCacheHit(allocator, project_root, .build_obj, key, artifact_path, out_path)) {
            if (diagnostics_mode == .json or compile_options.mem_report) {
                const metrics = CompileMetrics{ .compile_tokens = 0, .instruction_count = 0, .phases = if (compile_options.profile) .{ .load_ns = 0, .setup_ns = 0, .flatten_ns = 0, .verify_ns = 0, .emit_ns = 0, .link_ns = 0, .total_ns = if (total_start) |start| elapsedNs(start) else null } else null, .memory = cacheHitMemoryMetrics(compile_options.mem_report), .cache = .{ .kind = BuildCacheKind.build_obj.dirName(), .hit = true } };
                try writeSuccessDiagnostics(stderr, metrics, diagnostics_mode);
            }
            return 0;
        }
    }

    const compiled = try compileSource(allocator, source_path, compile_options);
    switch (compiled) {
        .trap => |report| {
            try printTrapReport(stderr, report, diagnostics_mode);
            return 1;
        },
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(allocator);
            rejectNpmBindsUnlessJs("sa build-obj", &owned.flat, stderr) catch return 1;
            const emit_std_root = try stdRootFromEnv(allocator);
            defer allocator.free(emit_std_root);
            try ensureParentDir(artifact_path);
            const emit_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
            const opt_level = emitOptLevel(debug, optimization);
            if (compile_options.target_triple != null and incremental) {
                try stderr.writeAll("error: --target cannot be combined with --incremental yet\n");
                return 1;
            }
            const size_bits = sizeBitsForTriple(compile_options.target_triple);
            if (incremental) {
                const incremental_key = try computeProjectBuildKey(allocator, &project_context, project_root, source_path, "obj", "", .build_obj_incremental, debug, optimization == .release_fast, true, null, false, compile_options.offline, compile_options.dce);
                try buildIncrementalObject(allocator, project_root, incremental_key, &owned, source_path, out_path, debug, optimization, compile_options, stderr);
                emit_llvm_llvmc.emitLlvmcToFile(allocator, owned.verified, &owned.flat.def_dict, owned.flat.loc_table, source_path, size_bits, .{ .debug = debug, .jobs = compile_options.jobs, .opt_level = opt_level, .dce = compile_options.dce, .std_root = emit_std_root, .target_triple = compile_options.target_triple }, artifact_path) catch |err| {
                    try printLlvmcEmitError(stderr, err, diagnostics_mode);
                    return 1;
                };
            } else {
                emit_llvm_llvmc.emitLlvmcToArtifacts(allocator, owned.verified, &owned.flat.def_dict, owned.flat.loc_table, source_path, size_bits, .{ .debug = debug, .jobs = compile_options.jobs, .opt_level = opt_level, .dce = compile_options.dce, .std_root = emit_std_root, .target_triple = compile_options.target_triple }, artifact_path, out_path, opt_level) catch |err| {
                    try printLlvmcEmitError(stderr, err, diagnostics_mode);
                    return 1;
                };
            }
            recordMetricMemoryAfterEmit(&owned.metrics);
            if (owned.metrics.memory) |memory| try writeMemoryStageSampleForOptions(compile_options, "after_emit", memory.after_emit_rss_bytes, memory.after_verify_rss_bytes);
            recordMetricMemoryEnd(&owned.metrics);
            if (owned.metrics.memory) |memory| try writeMemoryStageSampleForOptions(compile_options, "end", memory.end_rss_bytes, memoryEndPrevious(memory));
            finishProfileMetrics(&owned.metrics, if (emit_start) |start| elapsedNs(start) else null, null, if (total_start) |start| elapsedNs(start) else null);
            attachBackendIrMetrics(&owned.metrics, &owned.verified, debug);
            if (cache_key) |key| try projectCacheStore(allocator, project_root, .build_obj, key, artifact_path, out_path);
            if (cache_key != null) owned.metrics.cache = .{ .kind = BuildCacheKind.build_obj.dirName(), .hit = false };
            try writeSuccessDiagnostics(stderr, owned.metrics, diagnostics_mode);
            return 0;
        },
    }
}

fn executeBuildWasm(allocator: std.mem.Allocator, source_path: []const u8, out_path: []const u8, target: WasmTarget, debug: bool, optimization: driver.Optimization, compile_options: CompileOptions, stderr: anytype, diagnostics_mode: DiagnosticsMode) !u8 {
    const total_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
    const project_root_owned = compile_options.project_root == null;
    const project_root = compile_options.project_root orelse try projectRootFromSourcePath(allocator, source_path);
    defer if (project_root_owned) allocator.free(project_root);
    var project_context = try loadProjectContext(allocator, project_root, compile_options.package_name);
    defer project_context.deinit(allocator);
    const cache_key: ?ProjectCacheKey = if (compile_options.incremental_cache)
        try computeProjectBuildKey(allocator, &project_context, project_root, source_path, "wasm", target.triple, .build_wasm, debug, optimization == .release_fast, false, target, true, compile_options.offline, compile_options.dce)
    else
        null;
    const artifact_path = try intermediateArtifactPath(allocator, out_path);
    defer allocator.free(artifact_path);

    if (cache_key) |key| {
        if (try projectCacheHit(allocator, project_root, .build_wasm, key, artifact_path, out_path)) {
            if (diagnostics_mode == .json or compile_options.mem_report) {
                const metrics = CompileMetrics{ .compile_tokens = 0, .instruction_count = 0, .phases = if (compile_options.profile) .{ .load_ns = 0, .setup_ns = 0, .flatten_ns = 0, .verify_ns = 0, .emit_ns = 0, .link_ns = 0, .total_ns = if (total_start) |start| elapsedNs(start) else null } else null, .memory = cacheHitMemoryMetrics(compile_options.mem_report), .cache = .{ .kind = BuildCacheKind.build_wasm.dirName(), .hit = true } };
                try writeSuccessDiagnostics(stderr, metrics, diagnostics_mode);
            }
            return 0;
        }
    }

    const compiled = try compileSource(allocator, source_path, compile_options);
    switch (compiled) {
        .trap => |report| {
            try printTrapReport(stderr, report, diagnostics_mode);
            return 1;
        },
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(allocator);
            rejectNpmBindsUnlessJs("sa build-wasm", &owned.flat, stderr) catch return 1;
            const emit_std_root = try stdRootFromEnv(allocator);
            defer allocator.free(emit_std_root);
            try ensureParentDir(artifact_path);
            const emit_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
            emit_llvm_llvmc.emitLlvmcToFile(allocator, owned.verified, &owned.flat.def_dict, owned.flat.loc_table, source_path, target.size_bits, .{ .debug = debug, .wasm_compat = true, .jobs = compile_options.jobs, .opt_level = emitOptLevel(debug, optimization), .dce = compile_options.dce, .std_root = emit_std_root }, artifact_path) catch |err| {
                try printLlvmcEmitError(stderr, err, diagnostics_mode);
                return 1;
            };
            const emit_ns = if (emit_start) |start| elapsedNs(start) else null;
            recordMetricMemoryAfterEmit(&owned.metrics);
            if (owned.metrics.memory) |memory| try writeMemoryStageSampleForOptions(compile_options, "after_emit", memory.after_emit_rss_bytes, memory.after_verify_rss_bytes);

            const std_archive_path: ?[]const u8 = saStdArchivePathForTarget(allocator, target.triple) catch |err| blk: {
                if (err == error.ArchiveNotFoundForTarget) {
                    break :blk null;
                }
                return err;
            };
            defer if (std_archive_path) |p| allocator.free(p);
            const link_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
            driver.compileWasm(allocator, artifact_path, out_path, .{ .triple = target.triple, .no_entry = target.no_entry }, optimization, debug, std_archive_path, stderr) catch |err| switch (err) {
                error.ChildProcessFailed => {
                    if (std_archive_path == null) {
                        try stderr.print("hint: no sa_std archive for target '{s}' was linked. Build it with:\n", .{target.triple});
                        try stderr.writeAll("  zig build -Dtarget=<triple> sa-std-static\n");
                        try stderr.writeAll("then copy zig-out/lib/<libsa_std.a|sa_std.lib> to $SA_STD_DIR/<triple>/\n");
                    }
                    return 1;
                },
                else => return err,
            };
            const link_ns = if (link_start) |start| elapsedNs(start) else null;
            recordMetricMemoryAfterLink(&owned.metrics);
            if (owned.metrics.memory) |memory| try writeMemoryStageSampleForOptions(compile_options, "after_link", memory.after_link_rss_bytes, memory.after_emit_rss_bytes);
            recordMetricMemoryEnd(&owned.metrics);
            if (owned.metrics.memory) |memory| try writeMemoryStageSampleForOptions(compile_options, "end", memory.end_rss_bytes, memoryEndPrevious(memory));
            finishProfileMetrics(&owned.metrics, emit_ns, link_ns, if (total_start) |start| elapsedNs(start) else null);
            attachBackendIrMetrics(&owned.metrics, &owned.verified, debug);
            if (cache_key) |key| try projectCacheStore(allocator, project_root, .build_wasm, key, artifact_path, out_path);
            if (cache_key != null) owned.metrics.cache = .{ .kind = BuildCacheKind.build_wasm.dirName(), .hit = false };
            try writeSuccessDiagnostics(stderr, owned.metrics, diagnostics_mode);
            return 0;
        },
    }
}

fn executeBuildJs(allocator: std.mem.Allocator, source_path: []const u8, out_path: []const u8, js_format: emit_js.JsFormat, debug: bool, compile_options: CompileOptions, stderr: anytype, diagnostics_mode: DiagnosticsMode) !u8 {
    const total_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
    const compiled = try compileSource(allocator, source_path, compile_options);
    switch (compiled) {
        .trap => |report| {
            try printTrapReport(stderr, report, diagnostics_mode);
            return 1;
        },
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(allocator);
            try ensureParentDir(out_path);
            const emit_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
            const size_bits = sizeBitsForTriple(compile_options.target_triple);
            emit_js.emitJsToFile(allocator, owned.verified, source_path, size_bits, .{ .format = js_format, .debug_comments = debug }, &owned.flat.def_dict.npm_binds, out_path) catch |err| {
                try stderr.print("error: JS backend emit failed: {s}", .{@errorName(err)});
                if (emit_js.last_js_func.len != 0) try stderr.print(" in {s}", .{emit_js.last_js_func});
                if (emit_js.last_js_inst.len != 0) try stderr.print(": {s}", .{std.mem.trim(u8, emit_js.last_js_inst, " \t\r\n")});
                try stderr.writeAll("\n");
                return 1;
            };
            const emit_ns = if (emit_start) |start| elapsedNs(start) else null;
            recordMetricMemoryAfterEmit(&owned.metrics);
            if (owned.metrics.memory) |memory| try writeMemoryStageSampleForOptions(compile_options, "after_emit", memory.after_emit_rss_bytes, memory.after_verify_rss_bytes);
            recordMetricMemoryEnd(&owned.metrics);
            if (owned.metrics.memory) |memory| try writeMemoryStageSampleForOptions(compile_options, "end", memory.end_rss_bytes, memoryEndPrevious(memory));
            finishProfileMetrics(&owned.metrics, emit_ns, null, if (total_start) |start| elapsedNs(start) else null);
            attachBackendIrMetrics(&owned.metrics, &owned.verified, debug);
            try writeSuccessDiagnostics(stderr, owned.metrics, diagnostics_mode);
            return 0;
        },
    }
}

fn executeBuildC(allocator: std.mem.Allocator, source_path: []const u8, out_path: []const u8, debug: bool, compile_options: CompileOptions, stderr: anytype, diagnostics_mode: DiagnosticsMode) !u8 {
    const total_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
    const compiled = try compileSource(allocator, source_path, compile_options);
    switch (compiled) {
        .trap => |report| {
            try printTrapReport(stderr, report, diagnostics_mode);
            return 1;
        },
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(allocator);
            try ensureParentDir(out_path);
            const emit_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
            const size_bits = sizeBitsForTriple(compile_options.target_triple);
            emit_c.emitCToFile(allocator, owned.verified, source_path, size_bits, .{ .debug_comments = debug }, out_path) catch |err| {
                try stderr.print("error: C backend emit failed: {s}", .{@errorName(err)});
                if (emit_c.last_c_func.len != 0) try stderr.print(" in {s}", .{emit_c.last_c_func});
                if (emit_c.last_c_inst.len != 0) try stderr.print(": {s}", .{std.mem.trim(u8, emit_c.last_c_inst, " \t\r\n")});
                try stderr.writeAll("\n");
                return 1;
            };
            const emit_ns = if (emit_start) |start| elapsedNs(start) else null;
            recordMetricMemoryAfterEmit(&owned.metrics);
            if (owned.metrics.memory) |memory| try writeMemoryStageSampleForOptions(compile_options, "after_emit", memory.after_emit_rss_bytes, memory.after_verify_rss_bytes);
            recordMetricMemoryEnd(&owned.metrics);
            if (owned.metrics.memory) |memory| try writeMemoryStageSampleForOptions(compile_options, "end", memory.end_rss_bytes, memoryEndPrevious(memory));
            finishProfileMetrics(&owned.metrics, emit_ns, null, if (total_start) |start| elapsedNs(start) else null);
            attachBackendIrMetrics(&owned.metrics, &owned.verified, debug);
            try writeSuccessDiagnostics(stderr, owned.metrics, diagnostics_mode);
            return 0;
        },
    }
}

fn executeLayout(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var name: ?[]const u8 = null;
    var fields: ?[]const u8 = null;
    var format: layout.LayoutFormat = .text;
    var target_bits: u16 = 64;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--name")) {
            if (i + 1 >= args.len) return error.MissingLayoutName;
            name = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--fields")) {
            if (i + 1 >= args.len) return error.MissingLayoutFields;
            fields = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            if (i + 1 >= args.len) return error.MissingLayoutFormat;
            const value = args[i + 1];
            if (std.mem.eql(u8, value, "json")) {
                format = .json;
            } else if (std.mem.eql(u8, value, "text")) {
                format = .text;
            } else if (std.mem.eql(u8, value, "debug")) {
                format = .debug;
            } else if (std.mem.eql(u8, value, "dict")) {
                format = .dict;
            } else {
                return error.InvalidLayoutFormat;
            }
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--target")) {
            if (i + 1 >= args.len) return error.MissingTarget;
            target_bits = try layout.parseTargetBits(args[i + 1]);
            i += 1;
            continue;
        }
        return error.UnexpectedArgument;
    }

    const layout_name = name orelse return error.MissingLayoutName;
    const layout_fields = fields orelse return error.MissingLayoutFields;
    var computed = try layout.compute(allocator, layout_name, layout_fields, target_bits);
    defer computed.deinit(allocator);

    switch (format) {
        .text => try layout.writeText(stdout, computed),
        .json => {
            try layout.writeJson(stdout, computed);
            try stdout.writeByte('\n');
        },
        .debug => try layout.writeDebug(stdout, computed),
        .dict => try layout.writeDict(stdout, computed),
    }
    _ = stderr;
    return 0;
}

fn executeCheck(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    json_mode: bool,
    exec_options: ExecuteOptions,
) !u8 {
    var diag_forward = sio.ForwardWriter(@TypeOf(stderr)).init(stderr);
    defer diag_forward.writer().flush() catch {};
    var compile_options = newCompileOptions(exec_options, diag_forward.writer());
    var source_arg: ?[]const u8 = null;
    var emit_sab_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try consumeCompileOption(arg, args, &i, &compile_options)) continue;
        if (std.mem.eql(u8, arg, "--emit-sab")) {
            if (i + 1 >= args.len) return error.MissingOutputPath;
            emit_sab_path = args[i + 1];
            i += 1;
            continue;
        }
        if (source_arg == null) {
            source_arg = arg;
            continue;
        }
        return error.UnexpectedArgument;
    }
    if (source_arg == null) return error.MissingSourcePath;
    const source_path = source_arg.?;
    configureCompileDiagnostics(&compile_options, json_mode);

    const total_start = std.Io.Clock.awake.now(sio.io());
    // Flatten via compileSource front half by reusing compileSource then discarding codegen.
    // Fast path: if we already verified this instruction stream, skip verify.
    const compiled = try compileSourceForCheck(allocator, source_path, compile_options);
    const wall_ns = elapsedNs(total_start);
    switch (compiled) {
        .trap => |report| {
            try printTrapReport(if (json_mode) stdout else stderr, report, if (json_mode) .json else .human);
            return 1;
        },
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(allocator);
            if (emit_sab_path) |sab_path| {
                // SAB encode path is standalone: it never falls back to .sa text.
                // encodeSabFromFlat re-verifies and returns error.VerificationTrap
                // on failure, which we surface as a check failure.
                const sab_bytes = plugin_bridge.encodeSabFromFlat(allocator, &owned.flat) catch |err| {
                    if (err == error.VerificationTrap) {
                        try stderr.print("check: SAB encode failed: verification trap\n", .{});
                        return 1;
                    }
                    return err;
                };
                defer allocator.free(sab_bytes);
                const cwd = sio.cwd();
                const sab_file = try cwd.createFile(sab_path, .{});
                defer sab_file.close();
                try sab_file.writeAll(sab_bytes);
                if (!json_mode) {
                    try stdout.print("check ok: wrote SAB binary: {s} ({d} bytes)\n", .{ sab_path, sab_bytes.len });
                }
            }
            if (json_mode) {
                try stdout.writeAll("{\"status\":\"ok\",\"metrics\":");
                try writeMetricsJson(stdout, owned.metrics);
                try stdout.print(",\"wall_ms\":{d}", .{wall_ns / 1_000_000});
                try stdout.writeAll("}\n");
            } else {
                const cache_hit = if (owned.metrics.cache) |c| c.hit else false;
                try stdout.print("check ok: instructions={d} compile_tokens={d} verdict_cache={s}\n", .{
                    owned.metrics.instruction_count,
                    owned.metrics.compile_tokens,
                    if (cache_hit) "hit" else "miss",
                });
            }
            return 0;
        },
    }
}

/// Check-oriented compile: flatten + verify, with verdict-cache short circuit.
fn compileSourceForCheck(allocator: std.mem.Allocator, source_path: []const u8, options: CompileOptions) !CompileResult {
    var memory_metrics: ?CompileMemoryMetrics = if (options.mem_report) .{} else null;
    if (memory_metrics) |*memory| memory.recordStart();
    const total_start = if (options.profile) std.Io.Clock.awake.now(sio.io()) else null;

    if (std.mem.endsWith(u8, source_path, ".sab")) {
        // Reuse the normal SAB path (already records verdict on success).
        return try compileSource(allocator, source_path, options);
    }

    const load_start = if (options.profile) std.Io.Clock.awake.now(sio.io()) else null;
    const source = try loadSource(allocator, source_path);
    defer allocator.free(source);
    const load_ns = if (load_start) |start| elapsedNs(start) else 0;

    const setup_start = if (options.profile) std.Io.Clock.awake.now(sio.io()) else null;
    var resolution = if (options.project_root) |project_root|
        try pkg_workspace.resolveFromRootPath(allocator, project_root, .{ .request = options.package_name })
    else
        try resolveProjectFromSourcePath(allocator, source_path, options.package_name);
    defer resolution.deinit(allocator);
    const project_root = resolution.workspace_root;
    const member_root = resolution.member_root;
    const std_root = try stdRootFromEnv(allocator);
    defer allocator.free(std_root);
    const project_manifest = resolution.effective_manifest;
    var dependency_slice: []pkg_resolver.Dependency = &.{};
    defer if (dependency_slice.len != 0) allocator.free(dependency_slice);
    var plugin_import_roots: []const []const u8 = &.{};
    defer if (plugin_import_roots.len != 0) freeOwnedStringSlice(allocator, plugin_import_roots);
    const stable_import_roots = try defaultStableImportRoots(allocator, member_root);
    defer freeOwnedStringSlice(allocator, stable_import_roots);
    if (project_manifest) |*m| {
        verifyProjectPackageState(allocator, project_root, m.*, options) catch |err| {
            if (trapFromPackagePreflightError(err)) |report| return .{ .trap = report };
            return err;
        };
        dependency_slice = try manifestDependencies(m, allocator);
        plugin_import_roots = try manifestPluginImportRoots(m, allocator);
    }
    const package_grants: []const manifest.RequireEntry = if (project_manifest) |*m| m.requires else &.{};
    var error_ctx: flattener.ErrorContext = .{};
    const resolve_ctx = flattener.ResolveContext{
        .dependencies = dependency_slice,
        .options = .{
            .project_root = project_root,
            .std_root = std_root,
            .offline = options.offline,
            .plugin_import_roots = plugin_import_roots,
            .stable_import_roots = stable_import_roots,
        },
    };
    const setup_ns = if (setup_start) |start| elapsedNs(start) else 0;

    const flatten_start = if (options.profile) std.Io.Clock.awake.now(sio.io()) else null;
    var flat = flattener.flattenFileWithContextAndPackages(allocator, source_path, source, &error_ctx, resolve_ctx) catch |err| {
        return .{ .trap = trapFromFlattenError(source_path, source, err, flattener.takeErrorSourceLine(&error_ctx)) };
    };
    errdefer flat.deinit(allocator);
    const flatten_ns = if (flatten_start) |start| elapsedNs(start) else 0;

    const content_hash = incr_verify.hashInstructions(flat.instructions);
    const verify_start = if (options.profile) std.Io.Clock.awake.now(sio.io()) else null;
    if (incr_verify.isVerified(content_hash)) {
        // Verdict hit: build a trusted shell without re-running the referee.
        const trusted = try trustedSabVerifyOk(allocator, &flat);
        const verify_ns = if (verify_start) |start| elapsedNs(start) else 0;
        var metrics = computeCompileMetrics(&flat, &trusted, if (options.profile) .{ .load_ns = load_ns, .setup_ns = setup_ns, .flatten_ns = flatten_ns, .verify_ns = verify_ns, .total_ns = if (total_start) |start| elapsedNs(start) else null } else null, memory_metrics);
        metrics.cache = .{ .kind = "verdict", .hit = true };
        return .{ .ok = .{ .flat = flat, .verified = trusted, .metrics = metrics } };
    }

    const verified = try referee.verifyWithOptions(allocator, flat.instructions, flat.const_decls, .{
        .jobs = options.jobs,
        .package_grants = package_grants,
        .stage_reporter = null,
        .default_immutable = options.default_immutable,
        .rust_strict_mut = options.rust_strict_mut,
        .rust_copy_elision = options.rust_copy_elision,
    });
    const verify_ns = if (verify_start) |start| elapsedNs(start) else 0;
    return switch (verified) {
        .ok => |ok| blk: {
            incr_verify.recordVerified(content_hash);
            var names = std.array_list.Managed([]const u8).init(allocator);
            defer names.deinit();
            for (ok.function_sigs) |fs| names.append(fs.name) catch {};
            incr_verify.recordResultFromInstructions(content_hash, flat.instructions, names.items);
            var metrics = computeCompileMetrics(&flat, &ok, if (options.profile) .{ .load_ns = load_ns, .setup_ns = setup_ns, .flatten_ns = flatten_ns, .verify_ns = verify_ns, .total_ns = if (total_start) |start| elapsedNs(start) else null } else null, memory_metrics);
            metrics.cache = .{ .kind = "verdict", .hit = false };
            break :blk .{ .ok = .{ .flat = flat, .verified = ok, .metrics = metrics } };
        },
        .trap => |report| {
            var r = report;
            if (r.file == null) setFile(&r, source_path);
            flat.deinit(allocator);
            return .{ .trap = r };
        },
    };
}

fn executeGraph(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    json_mode: bool,
    exec_options: ExecuteOptions,
) !u8 {
    var diag_forward = sio.ForwardWriter(@TypeOf(stderr)).init(stderr);
    defer diag_forward.writer().flush() catch {};
    var compile_options = newCompileOptions(exec_options, diag_forward.writer());
    var source_arg: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try consumeCompileOption(arg, args, &i, &compile_options)) continue;
        if (source_arg == null) {
            source_arg = arg;
            continue;
        }
        return error.UnexpectedArgument;
    }

    const project_root = try projectRootDir(allocator);
    defer allocator.free(project_root);
    const source_path = if (source_arg) |path| path else try projectSourcePath(allocator, project_root, compile_options.package_name);
    defer if (source_arg == null) allocator.free(source_path);
    configureCompileDiagnostics(&compile_options, json_mode);

    const compiled = try compileSource(allocator, source_path, compile_options);
    switch (compiled) {
        .trap => |report| {
            try printTrapReport(stderr, report, if (json_mode) .json else .human);
            return 1;
        },
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(allocator);

            var resolution = if (compile_options.project_root) |root|
                try pkg_workspace.resolveFromRootPath(allocator, root, .{ .request = compile_options.package_name })
            else
                try resolveProjectFromSourcePath(allocator, source_path, compile_options.package_name);
            defer resolution.deinit(allocator);

            const resolved_project_root = resolution.workspace_root;
            const project_manifest = resolution.effective_manifest;

            var dependencies: []pkg_resolver.Dependency = &.{};
            defer if (dependencies.len != 0) allocator.free(dependencies);
            var plugin_import_roots: []const []const u8 = &.{};
            defer if (plugin_import_roots.len != 0) freeOwnedStringSlice(allocator, plugin_import_roots);
            if (project_manifest) |*m| {
                dependencies = try manifestDependencies(m, allocator);
                plugin_import_roots = try manifestPluginImportRoots(m, allocator);
            }

            var node_map = std.StringHashMap(usize).init(allocator);
            defer {
                var it = node_map.iterator();
                while (it.next()) |entry| allocator.free(entry.key_ptr.*);
                node_map.deinit();
            }
            var nodes = std.array_list.Managed(GraphNode).init(allocator);
            defer {
                for (nodes.items) |node| {
                    allocator.free(node.id);
                    allocator.free(node.label);
                }
                nodes.deinit();
            }
            var edges = std.array_list.Managed(GraphEdge).init(allocator);
            defer edges.deinit();

            var graph_ctx = GraphBuildContext{
                .allocator = allocator,
                .node_map = &node_map,
                .nodes = &nodes,
                .edges = &edges,
                .dependencies = dependencies,
                .plugin_import_roots = plugin_import_roots,
                .project_root = resolved_project_root,
                .offline = compile_options.offline,
            };

            _ = try collectSourceGraph(&graph_ctx, source_path);
            var function_nodes = try buildFunctionGraph(&graph_ctx, &owned.verified);
            defer function_nodes.deinit();
            try buildCallGraph(&graph_ctx, &owned.verified, &function_nodes);

            if (json_mode) {
                try writeGraphJson(stdout, owned.metrics, nodes.items, edges.items);
            } else {
                try writeGraphText(stdout, owned.metrics, nodes.items, edges.items);
            }
            return 0;
        },
    }
}

fn executeSize(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    json_mode: bool,
    exec_options: ExecuteOptions,
) !u8 {
    var diag_forward = sio.ForwardWriter(@TypeOf(stderr)).init(stderr);
    defer diag_forward.writer().flush() catch {};
    var compile_options = newCompileOptions(exec_options, diag_forward.writer());
    var source_arg: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try consumeCompileOption(arg, args, &i, &compile_options)) continue;
        if (source_arg == null) {
            source_arg = arg;
            continue;
        }
        return error.UnexpectedArgument;
    }

    const project_root = try projectRootDir(allocator);
    defer allocator.free(project_root);
    const source_path = if (source_arg) |path| path else try projectSourcePath(allocator, project_root, compile_options.package_name);
    defer if (source_arg == null) allocator.free(source_path);
    configureCompileDiagnostics(&compile_options, json_mode);

    const compiled = try compileSource(allocator, source_path, compile_options);
    switch (compiled) {
        .trap => |report| {
            try printTrapReport(stderr, report, if (json_mode) .json else .human);
            return 1;
        },
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(allocator);
            const sizes = try computeFunctionSizes(allocator, &owned.verified);
            defer allocator.free(sizes);

            if (json_mode) {
                try writeSizeJson(stdout, owned.metrics, sizes);
            } else {
                try writeSizeText(stdout, owned.metrics, sizes);
            }
            return 0;
        },
    }
}

fn parseTarget(text: []const u8) !WasmTarget {
    if (std.mem.eql(u8, text, "wasm32")) return .{ .triple = "wasm32-wasi", .no_entry = false, .size_bits = 32 };
    if (std.mem.eql(u8, text, "wasm64")) return .{ .triple = "wasm64-freestanding", .no_entry = true, .size_bits = 64 };
    return error.InvalidTarget;
}

fn parseOptimizationFlag(arg: []const u8) ?driver.Optimization {
    if (std.mem.eql(u8, arg, "--release-fast")) return .release_fast;
    if (std.mem.eql(u8, arg, "--release-small")) return .release_small;
    return null;
}

fn emitOptLevel(debug: bool, optimization: driver.Optimization) u8 {
    if (debug) return 0;
    return switch (optimization) {
        .none => 0,
        .release_small => 1,
        .release_fast => 3,
    };
}

fn executeTest(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    compile_options: CompileOptions,
    test_options: TestCommandOptions,
    stdout: anytype,
    stderr: anytype,
    diagnostics_mode: DiagnosticsMode,
) !u8 {
    if (!test_options.affected) return executeTestInner(allocator, source_path, compile_options, test_options, stdout, stderr, diagnostics_mode);

    // Level-1 whole-source pass cache (fast path for identical inputs).
    const src = sio.cwd().readFileAlloc(allocator, source_path, 1 << 24) catch {
        return executeTestInner(allocator, source_path, compile_options, test_options, stdout, stderr, diagnostics_mode);
    };
    defer allocator.free(src);
    const filt: ?[]const u8 = if (test_options.selection.include_filters.len > 0)
        test_options.selection.include_filters[0]
    else
        null;
    const digest = affected_tests.hashInput(src, filt);
    if (affected_tests.isCachedPass(digest)) {
        if (diagnostics_mode == .json) {
            try stdout.writeAll("{\"status\":\"ok\",\"affected\":{\"skipped\":true,\"reason\":\"source-pass-cache\"}}\n");
        } else {
            try stdout.writeAll("affected: unchanged since last pass; skipped\n");
        }
        return 0;
    }

    // Level-2: call-graph selective execution. Compile once to inspect functions,
    // compute changed set vs baseline, restrict selection.include_filters to
    // impacted tests, then run. On first baseline, run all selected tests.
    const compiled = try compileSource(allocator, source_path, compile_options);
    switch (compiled) {
        .trap => |report| {
            try printTrapReport(stderr, report, diagnostics_mode);
            return 1;
        },
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(allocator);

            var function_bodies = try collectFunctionBodyHashes(allocator, &owned.verified);
            defer freeFunctionBodyHashes(allocator, &function_bodies);

            var changed = std.array_list.Managed([]const u8).init(allocator);
            defer changed.deinit();
            const had_baseline = affected_tests.hasFunctionBaseline();
            var it = function_bodies.iterator();
            while (it.next()) |entry| {
                if (!had_baseline or affected_tests.functionChanged(entry.key_ptr.*, entry.value_ptr.*)) {
                    try changed.append(entry.key_ptr.*);
                }
            }

            // Build call edges from annotated stream.
            var callers = std.array_list.Managed([]const u8).init(allocator);
            defer callers.deinit();
            var callees = std.array_list.Managed([]const u8).init(allocator);
            defer {
                for (callees.items) |c| allocator.free(c);
                callees.deinit();
            }
            try collectCallEdges(allocator, &owned.verified, &callers, &callees);

            var rev = try affected_tests.buildReverseCallMap(allocator, callers.items, callees.items);
            defer {
                var rit = rev.iterator();
                while (rit.next()) |e| e.value_ptr.deinit();
                rev.deinit();
            }

            // Normalize changed names for reverse-graph lookup.
            var changed_norm = std.array_list.Managed([]const u8).init(allocator);
            defer changed_norm.deinit();
            for (changed.items) |c| try changed_norm.append(normalizeFnName(c));
            var impacted = try affected_tests.impactedFunctions(allocator, changed_norm.items, &rev);
            defer impacted.deinit();

            // Identify tests by function_sigs kind == test_func.
            var selected_names = std.array_list.Managed([]const u8).init(allocator);
            defer {
                for (selected_names.items) |n| allocator.free(n);
                selected_names.deinit();
            }
            var total_tests: usize = 0;
            for (owned.verified.function_sigs) |fs| {
                if (fs.kind != .test_func) continue;
                total_tests += 1;
                const display = common_signature.displayName(fs.kind, fs.name);
                const norm = normalizeFnName(fs.name);
                const keep = if (!had_baseline)
                    true
                else
                    impacted.contains(norm) or impacted.contains(display);
                if (keep) try selected_names.append(try allocator.dupe(u8, display));
            }

            if (diagnostics_mode == .json) {
                try stdout.writeAll("{\"status\":\"ok\",\"affected\":{");
                try stdout.print("\"had_baseline\":{s},\"changed_functions\":{d},\"selected_tests\":{d},\"total_tests\":{d}", .{
                    if (had_baseline) "true" else "false",
                    changed.items.len,
                    selected_names.items.len,
                    total_tests,
                });
                try stdout.writeAll("}}\n");
            } else {
                try stdout.print(
                    "affected: baseline={s} changed_fns={d} selected_tests={d}/{d}\n",
                    .{ if (had_baseline) "yes" else "no", changed.items.len, selected_names.items.len, total_tests },
                );
            }

            // Update baselines after analysis (whether or not tests pass, body hashes are current).
            var bit = function_bodies.iterator();
            while (bit.next()) |entry| {
                affected_tests.recordFunctionHash(entry.key_ptr.*, entry.value_ptr.*);
            }

            if (had_baseline and selected_names.items.len == 0) {
                affected_tests.recordPass(digest);
                if (diagnostics_mode != .json) try stdout.writeAll("affected: no impacted tests; skipped\n");
                return 0;
            }

            // Restrict filters to selected test names when we have a baseline.
            var effective = test_options;
            var owned_filters: []const []const u8 = &.{};
            defer if (owned_filters.len != 0) {
                for (owned_filters) |f| allocator.free(f);
                allocator.free(owned_filters);
            };
            if (had_baseline and selected_names.items.len > 0) {
                var filters = try allocator.alloc([]const u8, selected_names.items.len);
                for (selected_names.items, 0..) |n, idx| filters[idx] = try allocator.dupe(u8, n);
                owned_filters = filters;
                effective.selection.include_filters = owned_filters;
                effective.selection.exact = true;
            }

            const code = try executeTestInner(allocator, source_path, compile_options, effective, stdout, stderr, diagnostics_mode);
            if (code == 0) affected_tests.recordPass(digest);
            return code;
        },
    }
}

const FunctionBodyHashMap = std.StringHashMap([32]u8);

fn collectFunctionBodyHashes(allocator: std.mem.Allocator, verified: *const referee.VerifyOk) !FunctionBodyHashMap {
    var map = FunctionBodyHashMap.init(allocator);
    errdefer freeFunctionBodyHashes(allocator, &map);
    var sig_index: usize = 0;
    var idx: usize = 0;
    while (idx < verified.annotated.len) : (idx += 1) {
        const item = verified.annotated[idx].base;
        switch (item.kind) {
            .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
                if (sig_index >= verified.function_sigs.len) break;
                const fs = verified.function_sigs[sig_index];
                sig_index += 1;
                var end = idx + 1;
                while (end < verified.annotated.len and switch (verified.annotated[end].base.kind) {
                    .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => false,
                    else => true,
                }) : (end += 1) {}
                var lines = std.array_list.Managed([]const u8).init(allocator);
                defer lines.deinit();
                var j = idx;
                while (j < end) : (j += 1) try lines.append(verified.annotated[j].base.raw_text);
                const digest = affected_tests.hashFunctionBody(fs.name, lines.items);
                const key = try allocator.dupe(u8, fs.name);
                try map.put(key, digest);
                idx = end - 1;
            },
            else => {},
        }
    }
    return map;
}

fn freeFunctionBodyHashes(allocator: std.mem.Allocator, map: *FunctionBodyHashMap) void {
    var it = map.keyIterator();
    while (it.next()) |k| allocator.free(k.*);
    map.deinit();
}

fn normalizeFnName(name: []const u8) []const u8 {
    var s = name;
    if (s.len > 0 and s[0] == '@') s = s[1..];
    // Strip signature tail: `@foo() -> i32:` / `foo():` -> foo / display text
    if (std.mem.indexOfScalar(u8, s, '(')) |paren| s = s[0..paren];
    if (std.mem.indexOfScalar(u8, s, '"')) |q1| {
        if (std.mem.indexOfScalar(u8, s[q1 + 1 ..], '"')) |q2| {
            return s[q1 + 1 .. q1 + 1 + q2];
        }
    }
    return s;
}

fn collectCallEdges(
    allocator: std.mem.Allocator,
    verified: *const referee.VerifyOk,
    callers: *std.array_list.Managed([]const u8),
    callees: *std.array_list.Managed([]const u8),
) !void {
    var current_fn: ?[]const u8 = null;
    var sig_index: usize = 0;
    for (verified.annotated) |item| {
        switch (item.base.kind) {
            .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
                if (sig_index >= verified.function_sigs.len) break;
                current_fn = verified.function_sigs[sig_index].name;
                sig_index += 1;
            },
            .call, .call_indirect => {
                const caller = current_fn orelse continue;
                var parsed = referee_call.parseCall(allocator, item.base.raw_text) catch continue;
                defer parsed.deinit(allocator);
                try callers.append(normalizeFnName(caller));
                const callee_owned = try allocator.dupe(u8, normalizeFnName(parsed.callee));
                try callees.append(callee_owned);
            },
            else => {},
        }
    }
}

fn executeTestInner(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    compile_options: CompileOptions,
    test_options: TestCommandOptions,
    stdout: anytype,
    stderr: anytype,
    diagnostics_mode: DiagnosticsMode,
) !u8 {
    if (test_options.list and std.mem.endsWith(u8, source_path, ".sab")) {
        var test_list = try collectSabTestListFast(allocator, source_path);
        defer test_list.deinit(allocator);
        try test_formatter.writeList(stdout, test_list.tests, test_options.selection);
        return 0;
    }

    const std_archive_path = try saStdArchivePath(allocator);
    defer allocator.free(std_archive_path);

    var tmp = try TmpWorkDir.init();
    defer tmp.cleanup();

    const source_stem = sourceStem(source_path);
    const artifact_name = try std.fmt.allocPrint(allocator, "{s}.test.sa.bc", .{source_stem});
    defer allocator.free(artifact_name);
    const exe_name = try std.fmt.allocPrint(allocator, "{s}.test", .{source_stem});
    defer allocator.free(exe_name);

    const artifact_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(artifact_dir);

    const artifact_full_path = try std.fs.path.join(allocator, &.{ artifact_dir, artifact_name });
    defer allocator.free(artifact_full_path);
    const exe_full_path = try std.fs.path.join(allocator, &.{ artifact_dir, exe_name });
    defer allocator.free(exe_full_path);

    const project_root_owned = compile_options.project_root == null;
    const project_root = compile_options.project_root orelse try projectRootFromSourcePath(allocator, source_path);
    defer if (project_root_owned) allocator.free(project_root);
    var project_context = try loadProjectContext(allocator, project_root, compile_options.package_name);
    defer project_context.deinit(allocator);
    const cache_key: ?ProjectCacheKey = if (compile_options.incremental_cache)
        try computeProjectBuildKey(allocator, &project_context, project_root, source_path, "test", "", .test_cache, false, false, false, null, true, compile_options.offline, compile_options.dce)
    else
        null;

    if (cache_key) |key| cached: {
        var cached_test_list = projectCacheReadTestMetadata(allocator, project_root, key) catch |err| {
            _ = @errorName(err);
            break :cached;
        };
        const hit = projectCacheHit(allocator, project_root, .test_cache, key, artifact_full_path, exe_full_path) catch |err| {
            cached_test_list.deinit(allocator);
            return err;
        };
        if (hit) {
            makeExecutable(exe_full_path) catch |err| {
                cached_test_list.deinit(allocator);
                return err;
            };
            if (test_options.list) {
                defer cached_test_list.deinit(allocator);
                try test_formatter.writeList(stdout, cached_test_list.tests, test_options.selection);
                return 0;
            }
            if (test_options.compile_only) {
                defer cached_test_list.deinit(allocator);
                try stdout.print(
                    "compiled {d} selected tests ({d} discovered)\n",
                    .{
                        test_options.selection.countSelected(cached_test_list.tests),
                        cached_test_list.tests.len,
                    },
                );
                return 0;
            }
            var run_out_fw = sio.ForwardWriter(@TypeOf(stdout)).init(stdout);
            defer run_out_fw.writer().flush() catch {};
            var run_err_fw = sio.ForwardWriter(@TypeOf(stderr)).init(stderr);
            defer run_err_fw.writer().flush() catch {};
            return try test_runner.run(
                allocator,
                exe_full_path,
                tmp.dir,
                &cached_test_list,
                test_options.selection,
                test_options.trace_panic,
                compile_options.jobs,
                run_out_fw.writer(),
                run_err_fw.writer(),
            );
        }
        cached_test_list.deinit(allocator);
    }

    const test_total_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
    var effective_compile_options = compile_options;
    var sab_selected_test_list: ?test_meta.TestList = null;
    defer if (sab_selected_test_list) |*list| list.deinit(allocator);
    var selected_test_names: []const []const u8 = &.{};
    defer if (selected_test_names.len != 0) allocator.free(selected_test_names);

    if (std.mem.endsWith(u8, source_path, ".sab") and hasExplicitTestSelection(test_options.selection)) {
        sab_selected_test_list = try collectSabTestListFast(allocator, source_path);
        selected_test_names = try selectedTestNamesFromList(allocator, sab_selected_test_list.?, test_options.selection);
        effective_compile_options.sab_selected_test_names = selected_test_names;
        effective_compile_options.sab_skip_verify = test_options.compile_only;
    }

    const compile_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
    const compiled = try compileSource(allocator, source_path, effective_compile_options);
    const compile_ns = if (compile_start) |start| elapsedNs(start) else null;
    switch (compiled) {
        .trap => |report| {
            try printTrapReport(stderr, report, diagnostics_mode);
            return 1;
        },
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(allocator);

            rejectNpmBindsUnlessJs("sa test", &owned.flat, stderr) catch return 1;
            var compiled_test_list: ?test_meta.TestList = null;
            defer if (compiled_test_list) |*list| list.deinit(allocator);
            if (sab_selected_test_list == null) {
                compiled_test_list = try test_meta.collect(allocator, owned.verified.function_sigs);
            }
            const test_list = if (sab_selected_test_list) |*list| list else &compiled_test_list.?;
            if (test_options.list) {
                try test_formatter.writeList(stdout, test_list.tests, test_options.selection);
                return 0;
            }

            const has_explicit_test_selection = hasExplicitTestSelection(test_options.selection);
            if (selected_test_names.len == 0 and has_explicit_test_selection) {
                selected_test_names = try selectedTestNamesFromList(allocator, test_list.*, test_options.selection);
            }

            var link_inputs = std.array_list.Managed([]const u8).init(allocator);
            defer link_inputs.deinit();
            var owned_link_inputs = std.array_list.Managed([]const u8).init(allocator);
            defer {
                for (owned_link_inputs.items) |arg| allocator.free(arg);
                owned_link_inputs.deinit();
            }
            try appendNativePluginLinkInputs(allocator, &link_inputs, &owned_link_inputs, &owned.verified);

            const emit_std_root = try stdRootFromEnv(allocator);
            defer allocator.free(emit_std_root);
            const emit_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
            emit_llvm_llvmc.emitLlvmcToFile(allocator, owned.verified, &owned.flat.def_dict, owned.flat.loc_table, source_path, nativeSizeBits(), .{ .jobs = compile_options.jobs, .test_mode = true, .dce = compile_options.dce, .std_root = emit_std_root, .selected_test_names = selected_test_names }, artifact_full_path) catch |err| {
                try printLlvmcEmitError(stderr, err, diagnostics_mode);
                return 1;
            };
            const emit_ns = if (emit_start) |start| elapsedNs(start) else null;

            const fast_sab_compile_only = test_options.compile_only and std.mem.endsWith(u8, source_path, ".sab") and has_explicit_test_selection;
            if (fast_sab_compile_only) {
                if (compile_options.profile) {
                    try stderr.print(
                        "profile test compile={d:.3}ms emit={d:.3}ms link=0.000ms total={d:.3}ms\n",
                        .{
                            @as(f64, @floatFromInt(compile_ns orelse 0)) / 1_000_000.0,
                            @as(f64, @floatFromInt(emit_ns orelse 0)) / 1_000_000.0,
                            @as(f64, @floatFromInt(if (test_total_start) |start| elapsedNs(start) else 0)) / 1_000_000.0,
                        },
                    );
                }
                try stdout.print(
                    "compiled {d} selected tests ({d} discovered)\n",
                    .{
                        test_options.selection.countSelected(test_list.tests),
                        test_list.tests.len,
                    },
                );
                return 0;
            }

            const link_start = if (compile_options.profile) std.Io.Clock.awake.now(sio.io()) else null;
            driver.compileExe(allocator, artifact_full_path, exe_full_path, test_options.optimization, std_archive_path, link_inputs.items, false, stderr, null) catch |err| switch (err) {
                error.ChildProcessFailed => return 1,
                else => return err,
            };
            const link_ns = if (link_start) |start| elapsedNs(start) else null;
            if (compile_options.profile) {
                try stderr.print(
                    "profile test compile={d:.3}ms emit={d:.3}ms link={d:.3}ms total={d:.3}ms\n",
                    .{
                        @as(f64, @floatFromInt(compile_ns orelse 0)) / 1_000_000.0,
                        @as(f64, @floatFromInt(emit_ns orelse 0)) / 1_000_000.0,
                        @as(f64, @floatFromInt(link_ns orelse 0)) / 1_000_000.0,
                        @as(f64, @floatFromInt(if (test_total_start) |start| elapsedNs(start) else 0)) / 1_000_000.0,
                    },
                );
            }

            if (cache_key) |key| {
                if (!has_explicit_test_selection and link_inputs.items.len == 0) try projectCacheStoreTest(allocator, project_root, key, artifact_full_path, exe_full_path, test_list.*);
            }

            if (test_options.compile_only) {
                try stdout.print(
                    "compiled {d} selected tests ({d} discovered)\n",
                    .{
                        test_options.selection.countSelected(test_list.tests),
                        test_list.tests.len,
                    },
                );
                return 0;
            }

            if (sab_selected_test_list) |list| {
                var run_list = list;
                sab_selected_test_list = null;
                var run_out_fw = sio.ForwardWriter(@TypeOf(stdout)).init(stdout);
                defer run_out_fw.writer().flush() catch {};
                var run_err_fw = sio.ForwardWriter(@TypeOf(stderr)).init(stderr);
                defer run_err_fw.writer().flush() catch {};
                return try test_runner.run(
                    allocator,
                    exe_full_path,
                    tmp.dir,
                    &run_list,
                    test_options.selection,
                    test_options.trace_panic,
                    compile_options.jobs,
                    run_out_fw.writer(),
                    run_err_fw.writer(),
                );
            } else {
                var run_list = compiled_test_list.?;
                compiled_test_list = null;
                var run_out_fw = sio.ForwardWriter(@TypeOf(stdout)).init(stdout);
                defer run_out_fw.writer().flush() catch {};
                var run_err_fw = sio.ForwardWriter(@TypeOf(stderr)).init(stderr);
                defer run_err_fw.writer().flush() catch {};
                return try test_runner.run(
                    allocator,
                    exe_full_path,
                    tmp.dir,
                    &run_list,
                    test_options.selection,
                    test_options.trace_panic,
                    compile_options.jobs,
                    run_out_fw.writer(),
                    run_err_fw.writer(),
                );
            }
        },
    }
}

pub fn executeWithWritersAndOptions(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    exec_options: ExecuteOptions,
) !u8 {
    const normalized_args = try stripJsonFlag(allocator, argv);
    defer allocator.free(normalized_args);

    const args = normalized_args;
    const json_mode = hasJsonFlag(argv);

    // Global flags: --help / -h / --version (checked before command dispatch)
    if (args.len >= 2) {
        if (isHelpFlag(args[1])) {
            try printUsage(stdout);
            return 0;
        }
        if (std.mem.eql(u8, args[1], "--version")) {
            try printVersion(stdout);
            return 0;
        }
    }

    if (args.len < 2) {
        try printUsage(stderr);
        return 1;
    }

    const cmd: Command = if (commandFromName(args[1])) |known| known else {
        var plugin_auth = try buildPluginRuntimeAuthorization(allocator, args);
        defer plugin_auth.deinit(allocator);
        var plugin_runtime = try plugins.Runtime.initFromEnvWithAuthorization(allocator, plugin_auth.input);
        defer plugin_runtime.deinit();
        if (try plugin_runtime.dispatchCommand(args, stdout, stderr, json_mode)) |code| return code;
        for (plugin_runtime.diagnostics.items) |diagnostic| {
            try stderr.print("note: plugin load skipped: {s}: {s}\n", .{ diagnostic.path, diagnostic.reason });
        }
        return error.UnknownCommand;
    };

    if (commandHelpRequested(cmd, args)) {
        try printCommandHelp(stdout, cmd, args[2..]);
        return 0;
    }

    switch (cmd) {
        .help => {
            return try printHelpTopic(stdout, args[2..]);
        },
        .version => {
            try printVersion(stdout);
            return 0;
        },
        .layout => {
            return try executeLayout(allocator, args[2..], stdout, stderr);
        },
        .graph => {
            return try executeGraph(allocator, args[2..], stdout, stderr, json_mode, exec_options);
        },
        .pkg => {
            if (try executePkgCommandFallback(allocator, args, stdout, stderr)) |code| return code;
            var plugin_auth = try buildPluginRuntimeAuthorization(allocator, args);
            defer plugin_auth.deinit(allocator);
            var plugin_runtime = try plugins.Runtime.initFromEnvWithAuthorization(allocator, plugin_auth.input);
            defer plugin_runtime.deinit();
            if (try plugin_runtime.dispatchCommand(args, stdout, stderr, json_mode)) |code| return code;
            return error.UnknownCommand;
        },
        .cache => return try executeCacheCommand(allocator, args[2..], stdout),
        .audit => return error.UnknownCommand,
        .check => {
            return try executeCheck(allocator, args[2..], stdout, stderr, json_mode, exec_options);
        },
        .explain => return try explainCommand(stdout, args, json_mode),
        .fix => return try fixCommand(stdout, args, json_mode),
        .skills => return try skillsCommand(allocator, stdout, json_mode),
        .daemon => return try daemonCommand(allocator, args[2..], stdout, stderr),
        .init => return try executeInit(allocator, args[2..], stdout),
        .install => return try executeInstall(allocator, args[2..], stdout),
        .plugin => return try executePluginCommand(allocator, args[2..], stdout, stderr),
        .build => {
            var diag_forward = sio.ForwardWriter(@TypeOf(stderr)).init(stderr);
            defer diag_forward.writer().flush() catch {};
            var compile_options = newCompileOptions(exec_options, diag_forward.writer());
            var source_path: ?[]const u8 = null;
            var out_path: ?[]const u8 = null;
            var debug = false;
            var optimization: driver.Optimization = .none;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (try consumeCompileOption(args[i], args, &i, &compile_options)) continue;
                if (source_path == null) {
                    source_path = args[i];
                    continue;
                }
                if (std.mem.eql(u8, args[i], "-o")) {
                    if (i + 1 >= args.len) return error.MissingOutputPath;
                    out_path = args[i + 1];
                    i += 1;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "-g")) {
                    debug = true;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--no-debug")) {
                    debug = false;
                    continue;
                }
                if (parseOptimizationFlag(args[i])) |mode| {
                    optimization = mode;
                    continue;
                }
                return error.UnexpectedArgument;
            }
            const project_root = try projectRootDir(allocator);
            defer allocator.free(project_root);
            const owned_source_path = if (source_path) |_| null else try projectSourcePath(allocator, project_root, compile_options.package_name);
            defer if (owned_source_path) |path| allocator.free(path);
            const final_source_path = source_path orelse owned_source_path.?;
            const owned_out = if (out_path) |p| p else try deriveOutputPath(allocator, final_source_path, executableSuffixForTriple(compile_options.target_triple));
            defer if (out_path == null) allocator.free(owned_out);
            configureCompileDiagnostics(&compile_options, json_mode);
            return try executeBuildExe(allocator, final_source_path, if (out_path) |p| p else owned_out, debug, optimization, compile_options, stderr, if (json_mode) .json else .human);
        },
        .build_workspace => {
            var diag_forward = sio.ForwardWriter(@TypeOf(stderr)).init(stderr);
            defer diag_forward.writer().flush() catch {};
            var compile_options = newCompileOptions(exec_options, diag_forward.writer());
            var out_path: ?[]const u8 = null;
            var debug = false;
            var optimization: driver.Optimization = .none;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (try consumeCompileOption(args[i], args, &i, &compile_options)) continue;
                if (std.mem.eql(u8, args[i], "-o")) {
                    if (i + 1 >= args.len) return error.MissingOutputPath;
                    out_path = args[i + 1];
                    i += 1;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "-g")) {
                    debug = true;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--no-debug")) {
                    debug = false;
                    continue;
                }
                if (parseOptimizationFlag(args[i])) |mode| {
                    optimization = mode;
                    continue;
                }
                return error.UnexpectedArgument;
            }
            const project_root = try projectRootDir(allocator);
            defer allocator.free(project_root);
            const final_source_path = try projectSourcePath(allocator, project_root, compile_options.package_name);
            defer allocator.free(final_source_path);
            const owned_out = if (out_path) |p| p else try deriveOutputPath(allocator, final_source_path, executableSuffixForTriple(compile_options.target_triple));
            defer if (out_path == null) allocator.free(owned_out);
            configureCompileDiagnostics(&compile_options, json_mode);
            return try executeBuildExe(allocator, final_source_path, if (out_path) |p| p else owned_out, debug, optimization, compile_options, stderr, if (json_mode) .json else .human);
        },
        .fetch => {
            if (args.len < 3) return error.MissingSourcePath;
            var result = try pkg_fetch.fetchPackage(allocator, args[2], "HEAD", .{});
            defer result.deinit(allocator);
            try stdout.print("{s}\n", .{result.root});
            return 0;
        },
        .size => {
            return try executeSize(allocator, args[2..], stdout, stderr, json_mode, exec_options);
        },
        .run => {
            if (args.len < 3) return error.MissingSourcePath;
            var diag_forward = sio.ForwardWriter(@TypeOf(stderr)).init(stderr);
            defer diag_forward.writer().flush() catch {};
            var compile_options = newCompileOptions(exec_options, diag_forward.writer());
            var source_path: ?[]const u8 = null;
            var runtime_args = std.array_list.Managed([]const u8).init(allocator);
            defer runtime_args.deinit();

            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (try consumeCompileOption(args[i], args, &i, &compile_options)) continue;
                if (source_path == null) {
                    source_path = args[i];
                    continue;
                }
                try runtime_args.append(args[i]);
            }
            const source = source_path orelse return error.MissingSourcePath;
            configureCompileDiagnostics(&compile_options, json_mode);
            return try executeRun(allocator, source, compile_options, runtime_args.items, stdout, stderr, if (json_mode) .json else .human);
        },
        .build_exe => {
            var diag_forward = sio.ForwardWriter(@TypeOf(stderr)).init(stderr);
            defer diag_forward.writer().flush() catch {};
            var compile_options = newCompileOptions(exec_options, diag_forward.writer());
            var source_path: ?[]const u8 = null;
            var out_path: ?[]const u8 = null;
            var debug = false;
            var optimization: driver.Optimization = .none;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (try consumeCompileOption(args[i], args, &i, &compile_options)) continue;
                if (source_path == null) {
                    source_path = args[i];
                    continue;
                }
                if (std.mem.eql(u8, args[i], "-o")) {
                    if (i + 1 >= args.len) return error.MissingOutputPath;
                    out_path = args[i + 1];
                    i += 1;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "-g")) {
                    debug = true;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--no-debug")) {
                    debug = false;
                    continue;
                }
                if (parseOptimizationFlag(args[i])) |mode| {
                    optimization = mode;
                    continue;
                }
                return error.UnexpectedArgument;
            }
            const project_root = try projectRootDir(allocator);
            defer allocator.free(project_root);
            const owned_source_path = if (source_path) |_| null else try projectSourcePath(allocator, project_root, compile_options.package_name);
            defer if (owned_source_path) |path| allocator.free(path);
            const final_source_path = source_path orelse owned_source_path.?;
            const owned_out = if (out_path) |p| p else try deriveOutputPath(allocator, final_source_path, executableSuffixForTriple(compile_options.target_triple));
            defer if (out_path == null) allocator.free(owned_out);
            configureCompileDiagnostics(&compile_options, json_mode);
            return try executeBuildExe(allocator, final_source_path, if (out_path) |p| p else owned_out, debug, optimization, compile_options, stderr, if (json_mode) .json else .human);
        },
        .build_obj => {
            var diag_forward = sio.ForwardWriter(@TypeOf(stderr)).init(stderr);
            defer diag_forward.writer().flush() catch {};
            var compile_options = newCompileOptions(exec_options, diag_forward.writer());
            var source_path: ?[]const u8 = null;
            var out_path: ?[]const u8 = null;
            var debug = false;
            var optimization: driver.Optimization = .none;
            var incremental = false;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (try consumeCompileOption(args[i], args, &i, &compile_options)) continue;
                if (source_path == null) {
                    source_path = args[i];
                    continue;
                }
                if (std.mem.eql(u8, args[i], "-o")) {
                    if (i + 1 >= args.len) return error.MissingOutputPath;
                    out_path = args[i + 1];
                    i += 1;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "-g")) {
                    debug = true;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--no-debug")) {
                    debug = false;
                    continue;
                }
                if (parseOptimizationFlag(args[i])) |mode| {
                    optimization = mode;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--incremental")) {
                    incremental = true;
                    continue;
                }
                return error.UnexpectedArgument;
            }
            const project_root = try projectRootDir(allocator);
            defer allocator.free(project_root);
            const owned_source_path = if (source_path) |_| null else try projectSourcePath(allocator, project_root, compile_options.package_name);
            defer if (owned_source_path) |path| allocator.free(path);
            const final_source_path = source_path orelse owned_source_path.?;
            const owned_out = if (out_path) |p| p else try deriveOutputPath(allocator, final_source_path, ".o");
            defer if (out_path == null) allocator.free(owned_out);
            configureCompileDiagnostics(&compile_options, json_mode);
            return try executeBuildObj(allocator, final_source_path, if (out_path) |p| p else owned_out, debug, optimization, incremental, compile_options, stderr, if (json_mode) .json else .human);
        },
        .build_wasm => {
            var diag_forward = sio.ForwardWriter(@TypeOf(stderr)).init(stderr);
            defer diag_forward.writer().flush() catch {};
            var compile_options = newCompileOptions(exec_options, diag_forward.writer());
            var source_path: ?[]const u8 = null;
            var out_path: ?[]const u8 = null;
            var target: WasmTarget = .{ .triple = "wasm32-wasi", .no_entry = false, .size_bits = 32 };
            var debug = false;
            var optimization: driver.Optimization = .none;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (try consumeCompileOption(args[i], args, &i, &compile_options)) continue;
                if (source_path == null) {
                    source_path = args[i];
                    continue;
                }
                if (std.mem.eql(u8, args[i], "-o")) {
                    if (i + 1 >= args.len) return error.MissingOutputPath;
                    out_path = args[i + 1];
                    i += 1;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "-g")) {
                    debug = true;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--no-debug")) {
                    debug = false;
                    continue;
                }
                if (parseOptimizationFlag(args[i])) |mode| {
                    optimization = mode;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--target")) {
                    if (i + 1 >= args.len) return error.MissingTarget;
                    target = try parseTarget(args[i + 1]);
                    i += 1;
                    continue;
                }
                return error.UnexpectedArgument;
            }
            const project_root = try projectRootDir(allocator);
            defer allocator.free(project_root);
            const owned_source_path = if (source_path) |_| null else try projectSourcePath(allocator, project_root, compile_options.package_name);
            defer if (owned_source_path) |path| allocator.free(path);
            const final_source_path = source_path orelse owned_source_path.?;
            const owned_out = if (out_path) |p| p else try deriveOutputPath(allocator, final_source_path, ".wasm");
            defer if (out_path == null) allocator.free(owned_out);
            configureCompileDiagnostics(&compile_options, json_mode);
            return try executeBuildWasm(allocator, final_source_path, if (out_path) |p| p else owned_out, target, debug, optimization, compile_options, stderr, if (json_mode) .json else .human);
        },
        .build_js => {
            var diag_forward = sio.ForwardWriter(@TypeOf(stderr)).init(stderr);
            defer diag_forward.writer().flush() catch {};
            var compile_options = newCompileOptions(exec_options, diag_forward.writer());
            var source_path: ?[]const u8 = null;
            var out_path: ?[]const u8 = null;
            var js_format: emit_js.JsFormat = .esm;
            var debug = false;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (try consumeCompileOption(args[i], args, &i, &compile_options)) continue;
                if (source_path == null) {
                    source_path = args[i];
                    continue;
                }
                if (std.mem.eql(u8, args[i], "-o")) {
                    if (i + 1 >= args.len) return error.MissingOutputPath;
                    out_path = args[i + 1];
                    i += 1;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "-g")) {
                    debug = true;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--no-debug")) {
                    debug = false;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--format")) {
                    if (i + 1 >= args.len) return error.MissingOutputPath;
                    js_format = emit_js.JsFormat.parse(args[i + 1]) orelse return error.UnexpectedArgument;
                    i += 1;
                    continue;
                }
                return error.UnexpectedArgument;
            }
            const project_root = try projectRootDir(allocator);
            defer allocator.free(project_root);
            const owned_source_path = if (source_path) |_| null else try projectSourcePath(allocator, project_root, compile_options.package_name);
            defer if (owned_source_path) |path| allocator.free(path);
            const final_source_path = source_path orelse owned_source_path.?;
            const owned_out = if (out_path) |p| p else try deriveOutputPath(allocator, final_source_path, ".js");
            defer if (out_path == null) allocator.free(owned_out);
            configureCompileDiagnostics(&compile_options, json_mode);
            return try executeBuildJs(allocator, final_source_path, if (out_path) |p| p else owned_out, js_format, debug, compile_options, stderr, if (json_mode) .json else .human);
        },
        .build_c => {
            var diag_forward = sio.ForwardWriter(@TypeOf(stderr)).init(stderr);
            defer diag_forward.writer().flush() catch {};
            var compile_options = newCompileOptions(exec_options, diag_forward.writer());
            var source_path: ?[]const u8 = null;
            var out_path: ?[]const u8 = null;
            var debug = false;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (try consumeCompileOption(args[i], args, &i, &compile_options)) continue;
                if (source_path == null) {
                    source_path = args[i];
                    continue;
                }
                if (std.mem.eql(u8, args[i], "-o")) {
                    if (i + 1 >= args.len) return error.MissingOutputPath;
                    out_path = args[i + 1];
                    i += 1;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "-g")) {
                    debug = true;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--no-debug")) {
                    debug = false;
                    continue;
                }
                return error.UnexpectedArgument;
            }
            const project_root = try projectRootDir(allocator);
            defer allocator.free(project_root);
            const owned_source_path = if (source_path) |_| null else try projectSourcePath(allocator, project_root, compile_options.package_name);
            defer if (owned_source_path) |path| allocator.free(path);
            const final_source_path = source_path orelse owned_source_path.?;
            const owned_out = if (out_path) |p| p else try deriveOutputPath(allocator, final_source_path, ".c");
            defer if (out_path == null) allocator.free(owned_out);
            configureCompileDiagnostics(&compile_options, json_mode);
            return try executeBuildC(allocator, final_source_path, if (out_path) |p| p else owned_out, debug, compile_options, stderr, if (json_mode) .json else .human);
        },
        .bc2sa => {
            if (args.len < 3) return error.MissingSourcePath;
            if (args.len > 3) return error.UnexpectedArgument;
            const source_path = args[2];
            const translated = bc2sa.translateBitcodeFile(allocator, source_path) catch |err| {
                try printCliError(stderr, err, if (json_mode) .json else .human);
                return 1;
            };
            defer allocator.free(translated);
            try stdout.writeAll(translated);
            if (translated.len == 0 or translated[translated.len - 1] != '\n') try stdout.writeByte('\n');
            return 0;
        },
        .test_cmd => {
            var diag_forward = sio.ForwardWriter(@TypeOf(stderr)).init(stderr);
            defer diag_forward.writer().flush() catch {};
            var compile_options = newCompileOptions(exec_options, diag_forward.writer());
            var source_path: ?[]const u8 = null;
            var include_filters = std.array_list.Managed([]const u8).init(allocator);
            defer include_filters.deinit();
            var skip_filters = std.array_list.Managed([]const u8).init(allocator);
            defer skip_filters.deinit();
            var exact = false;
            var run_ignored = test_meta.RunIgnored.normal;
            var list_tests = false;
            var compile_only = false;
            var trace_panic = false;
            var affected_flag = false;
            var test_optimization: driver.Optimization = .none;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (try consumeCompileOption(args[i], args, &i, &compile_options)) continue;
                if (source_path == null) {
                    source_path = args[i];
                    continue;
                }
                if (parseOptimizationFlag(args[i])) |mode| {
                    test_optimization = mode;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--list")) {
                    list_tests = true;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--compile-only")) {
                    compile_only = true;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--trace-panic") or std.mem.eql(u8, args[i], "--test-debug")) {
                    trace_panic = true;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--affected")) {
                    affected_flag = true;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--filter")) {
                    if (i + 1 >= args.len) return error.MissingFilterValue;
                    try include_filters.append(args[i + 1]);
                    i += 1;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--skip")) {
                    if (i + 1 >= args.len) return error.MissingFilterValue;
                    try skip_filters.append(args[i + 1]);
                    i += 1;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--exact")) {
                    exact = true;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--ignored")) {
                    run_ignored = .only;
                    continue;
                }
                if (std.mem.eql(u8, args[i], "--include-ignored")) {
                    run_ignored = .include;
                    continue;
                }
                return error.UnexpectedArgument;
            }
            const selection = test_meta.TestSelection{
                .include_filters = include_filters.items,
                .skip_filters = skip_filters.items,
                .exact = exact,
                .ignored = run_ignored,
            };
            const project_root = try projectRootDir(allocator);
            defer allocator.free(project_root);
            const owned_source_path = if (source_path) |_| null else try projectSourcePath(allocator, project_root, compile_options.package_name);
            defer if (owned_source_path) |path| allocator.free(path);
            const final_source_path = source_path orelse owned_source_path.?;
            configureCompileDiagnostics(&compile_options, json_mode);
            return try executeTest(allocator, final_source_path, compile_options, .{
                .selection = selection,
                .list = list_tests,
                .compile_only = compile_only,
                .trace_panic = trace_panic,
                .affected = affected_flag,
                .optimization = test_optimization,
            }, stdout, stderr, if (json_mode) .json else .human);
        },
    }
}

pub fn executeWithWriters(allocator: std.mem.Allocator, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    return executeWithWritersAndOptions(allocator, argv, stdout, stderr, .{});
}

pub fn execute(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    var stdout_buf: [8192]u8 = undefined;
    var stdout_stream = sio.getStdOut().writer(&stdout_buf);
    var stderr_buf: [8192]u8 = undefined;
    var stderr_stream = sio.getStdErr().writer(&stderr_buf);
    const code: u8 = if (try daemon_client.tryDaemonClient(allocator, argv, &stdout_stream.interface)) |c|
        c
    else
        try executeWithWriters(allocator, argv, &stdout_stream.interface, &stderr_stream.interface);
    stdout_stream.interface.flush() catch {};
    stderr_stream.interface.flush() catch {};
    return code;
}

test "trap reports print a human summary and preserve json payload" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var report = trap.TrapReport{
        .trap = .memory_leak,
        .trap_code = trap.trapCode(.memory_leak),
        .line = 12,
        .source_line = 9,
        .source_text_buf = std.mem.zeroes([256]u8),
        .original_text_buf = std.mem.zeroes([256]u8),
        .source_text = null,
        .original_text = null,
        .register_buf = std.mem.zeroes([64]u8),
        .register = null,
        .registers = &.{},
        .expected_mask = null,
        .actual_mask = 1,
        .expected_mask_name = null,
        .actual_mask_name = "Active",
        .upstream_loc = null,
        .upstream_file_buf = std.mem.zeroes([128]u8),
        .upstream_line = 42,
        .upstream_col = 7,
        .function_buf = std.mem.zeroes([64]u8),
        .function = null,
        .is_ffi_wrapper = false,
        .message = "live registers remain at function exit",
        .hint = "insert explicit release",
    };
    const source = "result = load node+0 as i32";
    std.mem.copyForwards(u8, report.source_text_buf[0..source.len], source);
    const register = "r1";
    std.mem.copyForwards(u8, report.register_buf[0..register.len], register);
    const upstream_file = "main.rs";
    std.mem.copyForwards(u8, report.upstream_file_buf[0..upstream_file.len], upstream_file);
    const function = "@main() -> i32:";
    std.mem.copyForwards(u8, report.function_buf[0..function.len], function);
    try printTrapReport(&aw.writer, report, .human);
    const output = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, output, "error[MemoryLeak]: live registers remain at function exit") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  in function @main() -> i32:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  upstream main.rs:42:7") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  line 9 (expanded 12): result = load node+0 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  register: r1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  state: Active") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  help: insert explicit release") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"trap\":\"MemoryLeak\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"function\":\"@main() -> i32:\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"register\":\"r1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"hint\":\"insert explicit release\"") != null);
}

test "cli error printing is detailed and json capable" {
    var haw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer haw.deinit();
    try printCliError(&haw.writer, error.MissingSourcePath, .human);
    try std.testing.expect(std.mem.indexOf(u8, haw.written(), "error[SA-CLI-001]: missing required positional argument") != null);
    try std.testing.expect(std.mem.indexOf(u8, haw.written(), "help: pass the source file, project path, or required operand after the command") != null);

    var jaw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer jaw.deinit();
    try printCliError(&jaw.writer, error.InvalidTarget, .json);
    try std.testing.expect(std.mem.indexOf(u8, jaw.written(), "\"status\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jaw.written(), "\"code\":\"SA-CLI-006\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jaw.written(), "\"name\":\"InvalidTarget\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jaw.written(), "\"message\":\"invalid target\"") != null);
}

test "build-workspace command is recognized in help" {
    var law: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer law.deinit();

    try printUsage(&law.writer);
    try std.testing.expect(std.mem.indexOf(u8, law.written(), "build-workspace") != null);

    law.clearRetainingCapacity();
    try printCommandHelp(&law.writer, .build_workspace, &.{});
    try std.testing.expect(std.mem.indexOf(u8, law.written(), "usage: sars build-workspace [options]") != null);
}

test "source tree hash cache reuses mtime size digest without reloading unchanged files" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    try tdir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    try tdir.makePath("sa_std/core");

    {
        var file = try tdir.createFile("main.sars", .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            \\@import "sa_std/core/cache_probe.sai"
            \\@main() -> i32:
            \\return dep_value
            \\
        );
    }
    {
        var file = try tdir.createFile("sa_std/core/cache_probe.sai", .{ .truncate = true });
        defer file.close();
        try file.writeAll("#def dep_value = 7\n");
    }

    const project_root = try sio.cwd().realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);
    const std_root = try sio.cwd().realpathAlloc(std.testing.allocator, "sa_std");
    defer std.testing.allocator.free(std_root);

    test_source_tree_load_count = 0;
    var first_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    try hashResolvedSourceTree(std.testing.allocator, &first_hasher, &.{}, &.{}, project_root, std_root, false, "main.sars");
    var first_digest: [32]u8 = undefined;
    first_hasher.final(&first_digest);
    try std.testing.expectEqual(@as(usize, 1), test_source_tree_load_count);

    const resolve_ctx = flattener.ResolveContext{ .options = .{ .project_root = project_root, .std_root = std_root } };
    var warmed_import = try flattener.readImportSourceFile(std.testing.allocator, ".", "sa_std/core/cache_probe.sai", resolve_ctx);
    defer warmed_import.deinit(std.testing.allocator);
    try std.testing.expect(warmed_import.owned_source == null);

    var second_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    try hashResolvedSourceTree(std.testing.allocator, &second_hasher, &.{}, &.{}, project_root, std_root, false, "main.sars");
    var second_digest: [32]u8 = undefined;
    second_hasher.final(&second_digest);
    try std.testing.expectEqual(@as(usize, 1), test_source_tree_load_count);
    try std.testing.expectEqualSlices(u8, first_digest[0..], second_digest[0..]);

    {
        var file = try tdir.createFile("sa_std/core/cache_probe.sai", .{ .truncate = true });
        defer file.close();
        try file.writeAll("#def dep_value = 777\n");
    }

    var third_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    try hashResolvedSourceTree(std.testing.allocator, &third_hasher, &.{}, &.{}, project_root, std_root, false, "main.sars");
    var third_digest: [32]u8 = undefined;
    third_hasher.final(&third_digest);
    try std.testing.expect(test_source_tree_load_count > 1);
    try std.testing.expect(!std.mem.eql(u8, first_digest[0..], third_digest[0..]));
}

test "source tree hash missing import returns PackageNotResolved without ownership errors" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    try tdir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    try tdir.makePath("sa_std/core");
    {
        var file = try tdir.createFile("main.sars", .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            \\@import "missing.sars"
            \\@main() -> i32:
            \\return 0
            \\
        );
    }

    const project_root = try sio.cwd().realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);
    const std_root = try sio.cwd().realpathAlloc(std.testing.allocator, "sa_std");
    defer std.testing.allocator.free(std_root);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    try std.testing.expectError(
        error.PackageNotResolved,
        hashResolvedSourceTree(std.testing.allocator, &hasher, &.{}, &.{}, project_root, std_root, false, "main.sars"),
    );
}

test "source tree hash cache LRU is opt-in" {
    const previous_limit = test_source_tree_hash_cache_max_entries;
    test_source_tree_hash_cache_max_entries = 1;
    defer test_source_tree_hash_cache_max_entries = previous_limit;

    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    try tdir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    {
        var file = try tdir.createFile("a.sars", .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            \\@main() -> i32:
            \\return 1
            \\
        );
    }
    {
        var file = try tdir.createFile("b.sars", .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            \\@main() -> i32:
            \\return 2
            \\
        );
    }

    const project_root = try sio.cwd().realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);

    test_source_tree_load_count = 0;
    var first_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    try hashResolvedSourceTree(std.testing.allocator, &first_hasher, &.{}, &.{}, project_root, project_root, false, "a.sars");
    try std.testing.expectEqual(@as(usize, 1), test_source_tree_load_count);

    var second_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    try hashResolvedSourceTree(std.testing.allocator, &second_hasher, &.{}, &.{}, project_root, project_root, false, "b.sars");
    try std.testing.expectEqual(@as(usize, 2), test_source_tree_load_count);

    var second_hit_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    try hashResolvedSourceTree(std.testing.allocator, &second_hit_hasher, &.{}, &.{}, project_root, project_root, false, "b.sars");
    try std.testing.expectEqual(@as(usize, 2), test_source_tree_load_count);

    var first_again_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    try hashResolvedSourceTree(std.testing.allocator, &first_again_hasher, &.{}, &.{}, project_root, project_root, false, "a.sars");
    try std.testing.expectEqual(@as(usize, 3), test_source_tree_load_count);
}

test "flatten error mapping keeps import resolution and unsupported type hints specific" {
    const import_source =
        \\@import "missing.sars"
        \\@main() -> i32:
        \\    return 0
    ;
    const import_report = trapFromFlattenError("/tmp/import.sars", import_source, error.PackageNotResolved, 1);
    try std.testing.expectEqual(trap.Trap.import_resolution_failed, import_report.trap);
    try std.testing.expectEqual(@as(u32, 1050), import_report.trap_code.?);
    try std.testing.expectEqualStrings("/tmp/import.sars", import_report.file.?);
    try std.testing.expectEqualStrings("import path could not be resolved", import_report.message);
    try std.testing.expectEqualStrings("check the import path, package identity, local vendor tree, and package cache", import_report.hint.?);
    try std.testing.expectEqualStrings("pin-import", import_report.repair_action.?);

    const type_source =
        \\@test "probe":
        \\    point = call @support_make_point(10, 20)
    ;
    const type_report = trapFromFlattenError("/tmp/type.sars", type_source, error.UnsupportedType, 2);
    try std.testing.expectEqual(trap.Trap.unsupported_type, type_report.trap);
    try std.testing.expectEqualStrings("/tmp/type.sars", type_report.file.?);
    try std.testing.expectEqualStrings("unsupported type annotation during flattening", type_report.message);
    try std.testing.expectEqualStrings("inspect the callee declaration referenced by this call site; the unsupported annotation is usually in the imported signature", type_report.hint.?);
}

test "duplicate definition trap gets a repair hint" {
    const source =
        \\#def X = 1
        \\#def X = 2
    ;
    const report = trapFromFlattenError("/tmp/dup.sars", source, error.DuplicateDef, 2);
    try std.testing.expectEqual(trap.Trap.duplicate_def, report.trap);
    try std.testing.expectEqualStrings("/tmp/dup.sars", report.file.?);
    try std.testing.expectEqualStrings("rename-def", report.repair_action.?);
    try std.testing.expectEqualStrings("change one of the conflicting names or namespace the symbol", report.repair_hint.?);
    try std.testing.expectEqualStrings("high", report.repair_confidence.?);
}

test "compileSource accepts true SAB without text flattener" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };
    try tdir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const reg_ids = [_]u32{1};
    const fsig = @import("common/signature.zig").FunctionSig{
        .id = 0,
        .name = "main",
        .params = &.{},
        .kind = .normal,
        .return_cap = null,
        .return_ty = .i32,
        .entry_inst_idx = 0,
        .is_ffi_wrapper = false,
        .reg_ids = reg_ids[0..],
    };
    var decl = @import("common/instruction.zig").makeInstruction(.func_decl, 1, 0, null, "");
    decl.operands[0] = .{ .symbol = 0 };
    decl.operands[1] = .{ .func = 0 };
    var assign = @import("common/instruction.zig").makeInstruction(.assign, 2, 1, null, "");
    assign.operands[0] = .{ .reg = 1 };
    assign.operands[1] = .{ .imm_i64 = 7 };
    var ret = @import("common/instruction.zig").makeInstruction(.return_, 3, 2, null, "");
    ret.operands[0] = .{ .reg = 1 };

    const bytes = try sab.encodeProgram(std.testing.allocator, &.{ "main", "value" }, &.{fsig}, &.{ decl, assign, ret });
    defer std.testing.allocator.free(bytes);
    try tdir.writeFile(.{ .sub_path = "main.sab", .data = bytes });

    var compiled = try compileSource(std.testing.allocator, "main.sab", .{});
    switch (compiled) {
        .ok => |*ok| {
            defer ok.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 3), ok.verified.annotated.len);
        },
        .trap => return error.TestUnexpectedResult,
    }
}

test "check --emit-sab roundtrips through compileSource without text fallback" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };
    try tdir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    // Write a minimal .sa program, compile it, encode to SAB via the same
    // plugin_bridge.encodeSabFromFlat that `check --emit-sab` uses, then
    // reload the .sab and verify the decoded program matches. The SAB path
    // must be standalone: a corrupt .sab must fail loudly, never silently
    // fall back to text.
    const sa_source =
        \\@main():
        \\L_ENTRY:
        \\    x = add 40, 2
        \\    return x
    ;
    try tdir.writeFile(.{ .sub_path = "rt.sars", .data = sa_source });

    var compiled_sa = try compileSource(std.testing.allocator, "rt.sars", .{});
    var ok_sa = switch (compiled_sa) {
        .ok => |*ok| ok,
        .trap => return error.TestUnexpectedResult,
    };
    defer ok_sa.deinit(std.testing.allocator);

    const sab_bytes = try plugin_bridge.encodeSabFromFlat(std.testing.allocator, &ok_sa.flat);
    defer std.testing.allocator.free(sab_bytes);
    // SAB magic "SAB\x00", version 4.0.
    try std.testing.expect(sab_bytes.len > 6);
    try std.testing.expectEqualStrings("SAB\x00", sab_bytes[0..4]);
    try std.testing.expectEqual(@as(u8, 4), sab_bytes[4]);
    try tdir.writeFile(.{ .sub_path = "rt.sab", .data = sab_bytes });

    var compiled_sab = try compileSource(std.testing.allocator, "rt.sab", .{});
    switch (compiled_sab) {
        .ok => |*ok| {
            defer ok.deinit(std.testing.allocator);
            try std.testing.expectEqual(ok_sa.flat.instructions.len, ok.flat.instructions.len);
            try std.testing.expectEqual(ok_sa.flat.symbols.names.items.len, ok.flat.symbols.names.items.len);
        },
        .trap => return error.TestUnexpectedResult,
    }

    // Corrupt SAB must fail with a SAB-specific error, not fall back to text.
    try tdir.writeFile(.{ .sub_path = "bad.sab", .data = sab_bytes[0..10] });
    try std.testing.expectError(error.TruncatedSab, compileSource(std.testing.allocator, "bad.sab", .{}));
    try tdir.writeFile(.{ .sub_path = "fake.sab", .data = "this is not a sab binary" });
    try std.testing.expectError(error.InvalidSabMagic, compileSource(std.testing.allocator, "fake.sab", .{}));
}

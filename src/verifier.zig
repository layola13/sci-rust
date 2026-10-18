const std = @import("std");
const builtin = @import("builtin");

const call = @import("referee/call.zig");
const cap = @import("common/capability.zig");
const atomic = @import("common/atomic.zig");
const gas = @import("common/gas.zig");
const const_decl = @import("common/const_decl.zig");
const inst = @import("common/instruction.zig");
const pkg_manifest = @import("pkg/manifest.zig");
const sig = @import("common/signature.zig");
const trap = @import("common/trap.zig");
const upstream = @import("common/upstream_loc.zig");
const classifier = @import("flattener/line_classifier.zig");
const symbol = @import("flattener/symbol.zig");

pub const RegStateChange = struct {
    reg: u32,
    before: u16,
    after: u16,
};

const RegStateDelta = struct {
    changes: []RegStateChange,

    fn deinit(self: *RegStateDelta, allocator: std.mem.Allocator) void {
        if (self.changes.len != 0) allocator.free(self.changes);
        self.* = undefined;
    }
};

const empty_reg_state_changes: [0]RegStateChange = .{};

fn emptyRegStateDelta() RegStateDelta {
    return .{ .changes = @constCast(empty_reg_state_changes[0..]) };
}

pub const AnnotatedInstruction = struct {
    base: inst.Instruction,
    delta: RegStateDelta,
    gas_step_cost: u32,

    fn deinit(self: *AnnotatedInstruction, allocator: std.mem.Allocator) void {
        self.delta.deinit(allocator);
        self.* = undefined;
    }
};

pub const VerifyOk = struct {
    annotated: []AnnotatedInstruction,
    function_sigs: []sig.FunctionSig,
    symbols: symbol.SymbolTable,
    const_decls: []const const_decl.ConstDecl = &.{},
    gas: gas.GasReport,

    pub fn deinit(self: *VerifyOk, allocator: std.mem.Allocator) void {
        for (self.annotated) |item| {
            var owned = item;
            owned.deinit(allocator);
        }
        allocator.free(self.annotated);
        for (self.function_sigs) |*item| item.deinit(allocator);
        allocator.free(self.function_sigs);
        self.symbols.deinit();
        self.* = undefined;
    }
};

pub const VerifyResult = union(enum) {
    ok: VerifyOk,
    trap: trap.TrapReport,
};

const ParallelFunctionChunk = struct {
    start: usize,
    end: usize,
    sig_index: usize,
};

pub const VerifyOptions = struct {
    jobs: ?usize = null,
    package_grants: []const pkg_manifest.RequireEntry = &.{},
    sax_context: ?SaxValidationContext = null,
    stage_reporter: ?VerifyStageReporter = null,
    predecoded_symbol_names: []const []const u8 = &.{},
    predecoded_function_sigs: []const sig.FunctionSig = &.{},
    check_exit_leaks: bool = true,
    // Rust edition (sci-rust): default-immutable + strict &mut + Copy elision.
    default_immutable: bool = false,
    rust_strict_mut: bool = false,
    rust_copy_elision: bool = false,
};

pub const VerifyStageReporter = struct {
    context: *anyopaque,
    report_fn: *const fn (*anyopaque, []const u8, usize, usize) void,

    fn report(self: VerifyStageReporter, stage: []const u8, completed: usize, total: usize) void {
        self.report_fn(self.context, stage, completed, total);
    }
};

pub const SaxValidationContext = struct {
    component_name: []const u8,
};

const VerifyBodyOk = struct {
    annotated: []AnnotatedInstruction,
    gas: gas.GasReport,
    has_unbounded_loop: bool,
};

const VerifyBodyResult = union(enum) {
    ok: VerifyBodyOk,
    trap: trap.TrapReport,
};

fn appendRandomLocBlock(
    writer: anytype,
    random: std.Random,
    expected: *?upstream.UpstreamLoc,
    min_count: u8,
) !void {
    const count = if (min_count >= 3) 3 else random.intRangeAtMost(u8, min_count, 3);
    var idx: u8 = 0;
    while (idx < count) : (idx += 1) {
        const line = random.intRangeAtMost(u32, 1, 2000);
        const col = random.intRangeAtMost(u32, 1, 80);
        try writer.print("#loc \"pbt.rs\":{d}:{d}\n", .{ line, col });
        expected.* = .{ .file = "pbt.rs", .line = line, .col = col };
    }
}

fn expectOptionalUpstreamLoc(actual: ?upstream.UpstreamLoc, expected: ?upstream.UpstreamLoc) !void {
    if (expected) |exp| {
        const act = actual orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(exp.file, act.file);
        try std.testing.expectEqual(exp.line, act.line);
        try std.testing.expectEqual(exp.col, act.col);
    } else {
        try std.testing.expect(actual == null);
    }
}

fn expectTrapReportUpstreamLoc(report: trap.TrapReport, expected: ?upstream.UpstreamLoc) !void {
    if (expected) |exp| {
        if (report.upstream_loc) |act| {
            try std.testing.expectEqualStrings(exp.file, act.file);
            try std.testing.expectEqual(exp.line, act.line);
            try std.testing.expectEqual(exp.col, act.col);
            return;
        }

        const file = std.mem.sliceTo(&report.upstream_file_buf, 0);
        try std.testing.expectEqualStrings(exp.file, file);
        try std.testing.expectEqual(exp.line, report.upstream_line);
        try std.testing.expectEqual(exp.col, report.upstream_col);
    } else {
        try std.testing.expect(report.upstream_loc == null);
        try std.testing.expect(std.mem.sliceTo(&report.upstream_file_buf, 0).len == 0);
        try std.testing.expectEqual(@as(u32, 0), report.upstream_line);
        try std.testing.expectEqual(@as(u32, 0), report.upstream_col);
    }
}

const ParallelVerifyJob = struct {
    result: ?VerifyBodyResult = null,
    err: ?anyerror = null,
    worker_index: usize = 0,
};

const ParallelVerifyWorker = struct {
    gpa: std.heap.DebugAllocator(.{}) = .{},

    fn allocator(self: *ParallelVerifyWorker) std.mem.Allocator {
        return self.gpa.allocator();
    }

    fn deinit(self: *ParallelVerifyWorker) void {
        _ = self.gpa.deinit();
        self.* = .{};
    }
};

fn cleanupParallelJobResults(jobs: []ParallelVerifyJob, workers: []ParallelVerifyWorker) void {
    for (jobs) |*job| {
        const result = job.result orelse continue;
        switch (result) {
            .ok => |ok| {
                const worker_index = job.worker_index;
                if (worker_index < workers.len) {
                    freeAnnotatedSlice(workers[worker_index].allocator(), ok.annotated);
                }
            },
            .trap => {},
        }
        job.result = null;
    }
}

const ParallelVerifyContext = struct {
    allocator: std.mem.Allocator,
    instructions: []const inst.Instruction,
    classified_lines: []const classifier.ClassifiedLine,
    const_decls: []const const_decl.ConstDecl,
    metadata: *const CollectResult,
    package_grants: []const pkg_manifest.RequireEntry,
    sax_context: ?SaxValidationContext,
    chunks: []const ParallelFunctionChunk,
    jobs: []ParallelVerifyJob,
    workers: []ParallelVerifyWorker,
    requested_jobs: ?usize,
    check_exit_leaks: bool,
    default_immutable: bool = false,
    rust_strict_mut: bool = false,
    rust_copy_elision: bool = false,
    next_chunk: std.atomic.Value(usize),
};

const CollectResult = struct {
    symbols: symbol.SymbolTable,
    sigs: std.array_list.Managed(sig.FunctionSig),
    sig_index_by_name: std.StringHashMap(usize),
    const_vtables: std.array_list.Managed(ConstVTable),
    function_starts: std.array_list.Managed(usize),
};

var test_classify_line_count: if (builtin.is_test) usize else void = if (builtin.is_test) 0 else {};
var test_consumed_scan_count: if (builtin.is_test) usize else void = if (builtin.is_test) 0 else {};

fn resetTestClassifyLineCount() void {
    if (builtin.is_test) test_classify_line_count = 0;
}

fn readTestClassifyLineCount() usize {
    return if (builtin.is_test) test_classify_line_count else 0;
}

fn resetTestConsumedScanCount() void {
    if (builtin.is_test) test_consumed_scan_count = 0;
}

fn readTestConsumedScanCount() usize {
    return if (builtin.is_test) test_consumed_scan_count else 0;
}

fn symbolName(symbol_names: []const []const u8, id: u32) []const u8 {
    const idx: usize = @intCast(id);
    if (idx >= symbol_names.len) return "";
    return symbol_names[idx];
}

fn operandName(symbol_names: []const []const u8, operand: inst.Operand) []const u8 {
    return switch (operand) {
        .reg => |id| symbolName(symbol_names, id),
        .symbol => |id| symbolName(symbol_names, id),
        .label => |id| symbolName(symbol_names, id),
        .func => |id| symbolName(symbol_names, id),
        .text => |text| text,
        .native_text => |text| text,
        else => "",
    };
}

fn operandDebugName(operand: inst.Operand) []const u8 {
    return switch (operand) {
        .reg => |id| switch (id) {
            0 => "r0",
            1 => "r1",
            2 => "r2",
            3 => "r3",
            4 => "r4",
            5 => "r5",
            6 => "r6",
            7 => "r7",
            8 => "r8",
            9 => "r9",
            else => "r",
        },
        .text => |text| text,
        .native_text => |text| text,
        else => "",
    };
}

fn structuredInstForm(kind: inst.InstKind) ?classifier.InstructionForm {
    return switch (kind) {
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
        .try_ => .try_,
        .panic => .panic,
        .panic_msg => .panic_msg,
        .return_ => .return_,
        .take => .take,
        .raw_cast => .raw_cast,
        .assume_safe => .assume_safe,
        .assume_borrow => .assume_borrow,
        else => null,
    };
}

fn structuredLineKind(kind: inst.InstKind) classifier.LineKind {
    return switch (kind) {
        .func_decl => .func_decl,
        .ffi_wrapper_decl => .ffi_wrapper_decl,
        .extern_decl => .extern_decl,
        .export_decl => .export_decl,
        .test_decl => .test_decl,
        .label => .label,
        .native => .native,
        else => if (structuredInstForm(kind) != null) .instruction else .unknown,
    };
}

fn addStructuredPart(line: *classifier.ClassifiedLine, idx: usize, value: []const u8) void {
    if (idx >= line.parts.len) return;
    line.parts[idx] = value;
    const count: u8 = @intCast(idx + 1);
    if (line.part_count < count) line.part_count = count;
}

fn classifyStructuredInstruction(item: inst.Instruction, symbol_names: []const []const u8) classifier.ClassifiedLine {
    var out = classifier.ClassifiedLine{
        .kind = structuredLineKind(item.kind),
        .inst_form = structuredInstForm(item.kind),
        .raw = item.raw_text,
        .trimmed = item.raw_text,
    };

    switch (item.kind) {
        .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
            addStructuredPart(&out, 0, operandName(symbol_names, item.operands[0]));
        },
        .label => {
            addStructuredPart(&out, 0, operandName(symbol_names, item.operands[1]));
        },
        .alloc, .stack_alloc, .assign, .atomic_load, .raw_cast, .assume_safe => {
            addStructuredPart(&out, 0, operandName(symbol_names, item.operands[0]));
            addStructuredPart(&out, 1, operandName(symbol_names, item.operands[1]));
        },
        .load, .take, .ptr_add => {
            addStructuredPart(&out, 0, operandName(symbol_names, item.operands[0]));
            addStructuredPart(&out, 1, operandName(symbol_names, item.operands[1]));
            addStructuredPart(&out, 2, operandName(symbol_names, item.operands[2]));
        },
        .store, .atomic_store => {
            addStructuredPart(&out, 0, operandName(symbol_names, item.operands[0]));
            addStructuredPart(&out, 1, operandName(symbol_names, item.operands[1]));
            addStructuredPart(&out, 2, operandName(symbol_names, item.operands[2]));
        },
        .cmpxchg, .atomic_rmw => {
            addStructuredPart(&out, 0, operandName(symbol_names, item.operands[0]));
            addStructuredPart(&out, 1, operandName(symbol_names, item.operands[1]));
            addStructuredPart(&out, 2, operandName(symbol_names, item.operands[2]));
            addStructuredPart(&out, 3, operandName(symbol_names, item.operands[3]));
        },
        .op => {
            addStructuredPart(&out, 0, operandName(symbol_names, item.operands[0]));
            if (item.op_kind) |op| addStructuredPart(&out, 1, @tagName(op));
            addStructuredPart(&out, 2, operandName(symbol_names, item.operands[1]));
            addStructuredPart(&out, 3, operandName(symbol_names, item.operands[2]));
            addStructuredPart(&out, 4, operandName(symbol_names, item.operands[3]));
        },
        .borrow, .assume_borrow => {
            addStructuredPart(&out, 0, operandName(symbol_names, item.operands[0]));
            addStructuredPart(&out, 1, operandName(symbol_names, item.operands[2]));
            addStructuredPart(&out, 2, operandName(symbol_names, item.operands[1]));
        },
        .move_, .release, .return_, .panic, .panic_msg, .call_indirect, .try_ => {
            addStructuredPart(&out, 0, operandName(symbol_names, item.operands[0]));
            addStructuredPart(&out, 1, operandName(symbol_names, item.operands[1]));
        },
        .jmp => addStructuredPart(&out, 0, operandName(symbol_names, item.operands[1])),
        .br, .br_null => {
            addStructuredPart(&out, 0, operandName(symbol_names, item.operands[0]));
            addStructuredPart(&out, 1, operandName(symbol_names, item.operands[1]));
            addStructuredPart(&out, 2, operandName(symbol_names, item.operands[3]));
        },
        .call => {
            addStructuredPart(&out, 0, operandName(symbol_names, item.operands[0]));
            addStructuredPart(&out, 1, operandName(symbol_names, item.operands[1]));
        },
        .native => addStructuredPart(&out, 0, operandName(symbol_names, item.operands[0])),
        else => {},
    }
    return out;
}

fn classifyInstructions(allocator: std.mem.Allocator, instructions: []const inst.Instruction, symbol_names: []const []const u8) ![]classifier.ClassifiedLine {
    const classified_lines = try allocator.alloc(classifier.ClassifiedLine, instructions.len);
    errdefer allocator.free(classified_lines);
    for (instructions, 0..) |item, idx| {
        if (builtin.is_test) test_classify_line_count += 1;
        classified_lines[idx] = if (symbol_names.len != 0 and structuredLineKind(item.kind) != .unknown)
            classifyStructuredInstruction(item, symbol_names)
        else
            classifier.classifyLine(item.raw_text);
    }
    return classified_lines;
}

const FunctionRegScope = struct {
    allocator: std.mem.Allocator,
    reg_ids: []const u32,
    owns_reg_ids: bool = true,
    slot_by_id: std.AutoHashMap(u32, u32),

    fn init(allocator: std.mem.Allocator, reg_ids: []const u32) !FunctionRegScope {
        var slot_by_id = std.AutoHashMap(u32, u32).init(allocator);
        errdefer slot_by_id.deinit();
        try slot_by_id.ensureTotalCapacity(@intCast(reg_ids.len));
        for (reg_ids, 0..) |reg_id, idx| {
            _ = slot_by_id.putAssumeCapacity(reg_id, @intCast(idx));
        }
        return .{
            .allocator = allocator,
            .reg_ids = reg_ids,
            .owns_reg_ids = true,
            .slot_by_id = slot_by_id,
        };
    }

    fn initBorrowed(allocator: std.mem.Allocator, reg_ids: []const u32) !FunctionRegScope {
        var scope = try FunctionRegScope.init(allocator, reg_ids);
        scope.owns_reg_ids = false;
        return scope;
    }

    fn deinit(self: *FunctionRegScope) void {
        self.slot_by_id.deinit();
        if (self.owns_reg_ids and self.reg_ids.len != 0) self.allocator.free(self.reg_ids);
        self.* = undefined;
    }

    fn slotOf(self: *const FunctionRegScope, reg_id: u32) ?u32 {
        return self.slot_by_id.get(reg_id);
    }

    fn globalId(self: *const FunctionRegScope, slot: u32) u32 {
        return self.reg_ids[@intCast(slot)];
    }

    fn nameOf(self: *const FunctionRegScope, symbols: *const symbol.SymbolTable, slot: u32) ?[]const u8 {
        if (@as(usize, @intCast(slot)) >= self.reg_ids.len) return null;
        return symbols.lookupName(self.globalId(slot));
    }
};

const ConstVTableSlot = struct {
    slot_name: []const u8,
    function_name: []const u8,
    signature: sig.FunctionSig,
};

const ConstVTable = struct {
    name: []const u8,
    slots: []ConstVTableSlot,

    fn deinit(self: *ConstVTable, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
        allocator.free(self.name);
        self.* = undefined;
    }
};

const CallProvenance = struct {
    callee_name: []const u8,
    is_vtable_slot: bool = false,
    vtable_name: ?[]const u8 = null,
    slot_name: ?[]const u8 = null,
    slot_signature: ?sig.FunctionSig = null,
    const_name: ?[]const u8 = null,
};

const ValueProvenance = struct {
    const_decl_idx: ?u32 = null,
    const_offset: u64 = 0,
    indirect_sig_index: ?usize = null,
};

fn maskOf(tag: cap.CapabilityMask) u16 {
    return @intFromEnum(tag);
}

fn trapCode(kind: trap.Trap) u32 {
    return trap.trapCode(kind);
}

fn trimTrailingCr(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, "\r");
}

fn copyTextBuf(dest: []u8, text: []const u8) void {
    const len = @min(dest.len, text.len);
    std.mem.copyForwards(u8, dest[0..len], text[0..len]);
}

const regFlagRawPointer: u8 = 0x01;
const regFlagStackAlloc: u8 = 0x02;
const regFlagImmutable: u8 = 0x04;
const regFlagBranchCondition: u8 = 0x08;
const regFlagEphemeralScalar: u8 = 0x10;

const InteriorContext = struct {
    state: []u16,
    interior_parent: []?u32,
    interior_first_child: []?u32,
    interior_next_sibling: []?u32,
    interior_root: []?u32,
    interior_offset: []u64,
    interior_offset_known: []bool,
    alloc_size: []u64,
    alloc_size_known: []bool,
};

const LabelStateChange = struct {
    reg: u32,
    state: ?u16 = null,
    origins: ?u32 = null,
    locks: ?u16 = null,
    flags: ?u8 = null,
    interior_parent: ?u32 = null,
    interior_first_child: ?u32 = null,
    interior_next_sibling: ?u32 = null,
    interior_root: ?u32 = null,
    interior_offset: ?u64 = null,
    interior_offset_known: ?bool = null,
    alloc_size: ?u64 = null,
    alloc_size_known: ?bool = null,
};

const LabelSnapshot = struct {
    changes: []LabelStateChange,

    fn deinit(self: *LabelSnapshot, allocator: std.mem.Allocator) void {
        if (self.changes.len != 0) allocator.free(self.changes);
        self.* = undefined;
    }
};

fn isIdentLike(text: []const u8) bool {
    return text.len != 0 and (std.ascii.isAlphabetic(text[0]) or text[0] == '_');
}

fn isImmutable(mask: u16) bool {
    return (mask & maskOf(.immutable)) != 0;
}

fn isImmutableConst(state: []const u16, flags: []const u8, id: u32) bool {
    const idx: usize = @intCast(id);
    return isImmutable(state[idx]) or (flags[idx] & regFlagImmutable) != 0;
}

fn constTrap(
    item: inst.Instruction,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
    register: []const u8,
    actual_mask: u16,
    message: []const u8,
) VerifyBodyResult {
    return trapReport(.const_mutation, item, function_text, is_ffi_wrapper, register, maskOf(.immutable), actual_mask, message, null);
}

fn seedConstSymbols(
    state: []u16,
    flags: []u8,
    scope: *const FunctionRegScope,
    symbols: *const symbol.SymbolTable,
    const_decls: []const const_decl.ConstDecl,
) void {
    for (const_decls) |decl| {
        if (symbols.findId(decl.name)) |id| {
            const idx: usize = @intCast(scope.slotOf(id) orelse continue);
            state[idx] = maskOf(.active) | maskOf(.immutable);
            flags[idx] |= regFlagImmutable;
        }
    }
}

fn isDecl(kind: inst.InstKind) bool {
    return switch (kind) {
        .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => true,
        else => false,
    };
}

fn isTerminator(kind: inst.InstKind) bool {
    return switch (kind) {
        .jmp, .br, .br_null, .early_return, .return_, .panic, .panic_msg => true,
        else => false,
    };
}

fn isExecKind(kind: inst.InstKind) bool {
    return switch (kind) {
        .alloc, .stack_alloc, .load, .store, .atomic_load, .atomic_store, .cmpxchg, .atomic_rmw, .fence, .borrow, .move_, .release, .assign, .op, .ptr_add, .jmp, .br, .br_null, .call, .call_indirect, .try_, .early_return, .panic, .panic_msg, .return_, .take, .raw_cast, .assume_safe, .assume_borrow, .native => true,
        else => false,
    };
}

fn isConstDeclText(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    return std.mem.startsWith(u8, trimmed, "@const ");
}

fn parseConstDeclName(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "@const ")) return null;
    const after = std.mem.trimStart(u8, trimmed["@const ".len..], " \t\r");
    const eq = std.mem.indexOfScalar(u8, after, '=') orelse return null;
    const name = std.mem.trim(u8, after[0..eq], " \t\r");
    if (name.len == 0) return null;
    return name;
}

fn parseVtableSlotName(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "vtable {")) return null;
    const open = std.mem.indexOfScalar(u8, trimmed, '{') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, trimmed, '}') orelse return null;
    if (close <= open) return null;
    const body = std.mem.trim(u8, trimmed[open + 1 .. close], " \t\r");
    const eq = std.mem.indexOfScalar(u8, body, '=') orelse return null;
    const slot = std.mem.trim(u8, body[0..eq], " \t\r");
    if (slot.len == 0) return null;
    return slot;
}

fn parseVtableSlots(allocator: std.mem.Allocator, literal: const_decl.VTableLiteral, sigs: []const sig.FunctionSig) ![]ConstVTableSlot {
    var slots = std.array_list.Managed(ConstVTableSlot).init(allocator);
    errdefer slots.deinit();
    for (literal.slots) |slot| {
        var sig_match: ?sig.FunctionSig = null;
        for (sigs) |item| {
            if (std.mem.eql(u8, item.name, slot.func_name)) {
                sig_match = item;
                break;
            }
        }
        const resolved = sig_match orelse return error.UnknownRegister;
        // sci-rust P1.1a object-safety: vtable slot methods must take the
        // receiver by borrow (`&self: ptr`). By-value `^self` would consume
        // the object into the vtable call and is rejected here.
        if (resolved.params.len == 0) return error.VTableSignatureMismatch;
        if (resolved.params[0].cap != .borrow or resolved.params[0].ty != .ptr) return error.VTableSignatureMismatch;
        try slots.append(.{
            .slot_name = slot.name,
            .function_name = slot.func_name,
            .signature = resolved,
        });
    }
    return try slots.toOwnedSlice();
}

fn collectConstVtables(
    allocator: std.mem.Allocator,
    const_decls: []const const_decl.ConstDecl,
    sigs: []const sig.FunctionSig,
) !std.array_list.Managed(ConstVTable) {
    var out = std.array_list.Managed(ConstVTable).init(allocator);
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit();
    }

    for (const_decls) |decl| {
        switch (decl.value) {
            .vtable => |literal| {
                const name_copy = try allocator.dupe(u8, decl.name);
                errdefer allocator.free(name_copy);
                const slots = try parseVtableSlots(allocator, literal, sigs);
                try out.append(.{
                    .name = name_copy,
                    .slots = slots,
                });
            },
            else => {},
        }
    }
    return out;
}

fn findConstVtableByName(const_vtables: []const ConstVTable, name: []const u8) ?ConstVTable {
    for (const_vtables) |item| {
        if (std.mem.eql(u8, item.name, name)) return item;
    }
    return null;
}

fn parseCallProvenance(
    item: inst.Instruction,
    parsed: call.ParsedCall,
    symbols: *const symbol.SymbolTable,
    state: []const u16,
    const_vtables: []const ConstVTable,
    origins: []?u32,
    const_reg_names: []const ?[]const u8,
) ?CallProvenance {
    _ = item;
    if (!parsed.is_indirect) return null;
    const callee_id = symbols.findId(parsed.callee) orelse return null;
    const callee_idx: usize = @intCast(callee_id);
    const callee_mask = state[callee_idx];
    if ((callee_mask & maskOf(.untracked)) != 0) return null;

    const candidate_const_name = if (const_reg_names[callee_idx]) |name| name else blk: {
        if (origins[callee_idx]) |origin_id| {
            const origin_idx: usize = @intCast(origin_id);
            break :blk const_reg_names[origin_idx] orelse return null;
        }
        break :blk null;
    } orelse return null;

    const vt = findConstVtableByName(const_vtables, candidate_const_name) orelse return null;
    const slot_name = parsed.callee;
    for (vt.slots) |slot| {
        if (std.mem.eql(u8, slot.function_name, slot_name) or std.mem.eql(u8, slot.slot_name, slot_name)) {
            return .{
                .callee_name = parsed.callee,
                .is_vtable_slot = true,
                .vtable_name = vt.name,
                .slot_name = slot.slot_name,
                .slot_signature = slot.signature,
                .const_name = candidate_const_name,
            };
        }
    }
    return .{
        .callee_name = parsed.callee,
        .is_vtable_slot = true,
        .vtable_name = vt.name,
        .slot_name = parsed.callee,
        .slot_signature = null,
        .const_name = candidate_const_name,
    };
}

fn atomicKey(inst_: inst.Instruction) ?u64 {
    return switch (inst_.kind) {
        .cmpxchg => (@as(u64, inst_.operands[2].reg) << 32) | @as(u64, inst_.operands[3].imm_u64),
        .atomic_rmw => (@as(u64, inst_.operands[1].reg) << 32) | @as(u64, inst_.operands[2].imm_u64),
        else => null,
    };
}

fn atomicOrderingOf(inst_: inst.Instruction) atomic.AtomicOrdering {
    return switch (inst_.kind) {
        .cmpxchg => inst_.atomic_ordering orelse .seq_cst,
        .atomic_rmw => inst_.atomic_ordering orelse .seq_cst,
        else => .seq_cst,
    };
}

fn atomicSeenBit(ordering: atomic.AtomicOrdering) u8 {
    return switch (ordering) {
        .relaxed => 0x01,
        .acquire => 0x02,
        .release => 0x04,
        .acq_rel => 0x08,
        .seq_cst => 0x10,
    };
}

fn checkAtomicOrdering(
    item: inst.Instruction,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
    seen: *std.AutoHashMap(u64, u8),
) ?VerifyBodyResult {
    const key = atomicKey(item) orelse return null;
    const ordering = atomicOrderingOf(item);
    const current = seen.get(key) orelse 0;
    for ([_]atomic.AtomicOrdering{ .relaxed, .acquire, .release, .acq_rel, .seq_cst }) |prev| {
        const bit = atomicSeenBit(prev);
        if ((current & bit) == 0) continue;
        if (!atomic.sameAddressRmwCompatible(prev, ordering)) {
            return trapReport(.atomic_ordering_mismatch, item, function_text, is_ffi_wrapper, null, null, null, "same-address RMW ordering combination is not allowed", null);
        }
    }
    seen.put(key, current | atomicSeenBit(ordering)) catch {
        return trapReport(.arena_oom, item, function_text, is_ffi_wrapper, null, null, null, "unable to record atomic ordering history", null);
    };
    return null;
}

fn hasInteriorPtr(mask: u16) bool {
    return (mask & maskOf(.interior_ptr)) != 0;
}

fn hasInteriorTree(state: []const u16, interior_first_child: []const ?u32, id: u32) bool {
    const idx: usize = @intCast(id);
    return hasInteriorPtr(state[idx]) or interior_first_child[idx] != null;
}

fn hasActiveBorrowRefs(locks: []const u16, id: u32) bool {
    const idx: usize = @intCast(id);
    if (locks[idx] != 0) return true;
    return false;
}

fn statesCompatibleForJoin(lhs: []const u16, rhs: []const u16) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (left == right) continue;
        if ((left == 0 and right == maskOf(.consumed)) or (right == 0 and left == maskOf(.consumed))) continue;
        return false;
    }
    return true;
}

const StateMismatch = struct {
    name: []const u8,
    expected: u16,
    actual: u16,
};

fn firstStateMismatch(lhs: []const u16, rhs: []const u16, symbols: *const symbol.SymbolTable) ?StateMismatch {
    if (lhs.len != rhs.len) return null;
    for (lhs, rhs, 0..) |left, right, idx| {
        if (left == right) continue;
        if ((left == 0 and right == maskOf(.consumed)) or (right == 0 and left == maskOf(.consumed))) continue;
        const name = symbols.lookupName(@intCast(idx)) orelse continue;
        return .{
            .name = name,
            .expected = right,
            .actual = left,
        };
    }
    return null;
}

fn mergeJoinMask(left: u16, right: u16) ?u16 {
    if (left == right) return left;
    if ((left == 0 and right == maskOf(.consumed)) or (right == 0 and left == maskOf(.consumed))) {
        return maskOf(.consumed);
    }

    // PATCH: Allow Active ↔ Uninitialized merging (similar to Consumed ↔ Uninitialized)
    // This fixes SLA PhiStateConflict in while loops and if-without-else patterns
    const active_mask = maskOf(.active);
    if ((left == 0 and right == active_mask) or (right == 0 and left == active_mask)) {
        return 0; // Merge to Uninitialized (safe: uninit is the conservative state)
    }

    // PATCH 1b: Allow (Active|BorrowView) ↔ Uninitialized merging.
    // A borrow created on one if/else branch but not the other merges to
    // Uninitialized (the borrow is dead on the merged path). This mirrors
    // the Active ↔ Uninitialized patch above.
    const borrow_active_mask = maskOf(.active) | maskOf(.borrow_view);
    if ((left == 0 and right == borrow_active_mask) or (right == 0 and left == borrow_active_mask)) {
        return 0;
    }

    // PATCH 2: Allow Active ↔ Untracked merging for primitive types
    // Untracked is used for non-affine types (int, float, bool)
    const untracked_mask = maskOf(.untracked);
    if ((left == active_mask and right == untracked_mask) or (right == active_mask and left == untracked_mask)) {
        return untracked_mask;  // Merge to Untracked (safe: untracked types don't need tracking)
    }

    // PATCH 3: Allow Untracked ↔ Uninitialized merging for primitive types
    if ((left == 0 and right == untracked_mask) or (right == 0 and left == untracked_mask)) {
        return untracked_mask;
    }

    const merged = left & right;
    const core_mask = maskOf(.active) | maskOf(.locked_read) | maskOf(.locked_mut) | maskOf(.consumed) | maskOf(.untracked) | maskOf(.fallible) | maskOf(.immutable) | maskOf(.interior_ptr);
    if ((merged & core_mask) == 0) return null;
    return merged;
}

fn mergeJoinStates(dst: []u16, src: []const u16) bool {
    if (dst.len != src.len) return false;
    for (dst, src) |*left, right| {
        left.* = mergeJoinMask(left.*, right) orelse return false;
    }
    return true;
}

fn captureLabelSnapshot(
    allocator: std.mem.Allocator,
    state: []const u16,
    origins: []const ?u32,
    locks: []const u16,
    flags: []const u8,
    interior_parent: []const ?u32,
    interior_first_child: []const ?u32,
    interior_next_sibling: []const ?u32,
    interior_root: []const ?u32,
    interior_offset: []const u64,
    interior_offset_known: []const bool,
    alloc_size: []const u64,
    alloc_size_known: []const bool,
) !LabelSnapshot {
    var changes = std.array_list.Managed(LabelStateChange).init(allocator);
    errdefer changes.deinit();

    for (state, 0..) |mask, idx| {
        const origin = origins[idx];
        const lock = locks[idx];
        const flag = flags[idx];
        const parent = interior_parent[idx];
        const first_child = interior_first_child[idx];
        const next_sibling = interior_next_sibling[idx];
        const root = interior_root[idx];
        const offset_known = interior_offset_known[idx];
        const size_known = alloc_size_known[idx];
        const changed = mask != 0 or origin != null or lock != 0 or flag != 0 or parent != null or first_child != null or next_sibling != null or root != null or offset_known or size_known;
        if (!changed) continue;
        try changes.append(.{
            .reg = @intCast(idx),
            .state = if (mask != 0) mask else null,
            .origins = origin,
            .locks = if (lock != 0) lock else null,
            .flags = if (flag != 0) flag else null,
            .interior_parent = parent,
            .interior_first_child = first_child,
            .interior_next_sibling = next_sibling,
            .interior_root = root,
            .interior_offset = if (offset_known) interior_offset[idx] else null,
            .interior_offset_known = if (offset_known) true else null,
            .alloc_size = if (size_known) alloc_size[idx] else null,
            .alloc_size_known = if (size_known) true else null,
        });
    }

    return .{ .changes = try changes.toOwnedSlice() };
}

fn restoreLabelSnapshot(
    snapshot: *const LabelSnapshot,
    state: []u16,
    origins: []?u32,
    locks: []u16,
    flags: []u8,
    interior_parent: []?u32,
    interior_first_child: []?u32,
    interior_next_sibling: []?u32,
    interior_root: []?u32,
    interior_offset: []u64,
    interior_offset_known: []bool,
    alloc_size: []u64,
    alloc_size_known: []bool,
) void {
    @memset(state, 0);
    @memset(origins, null);
    @memset(locks, 0);
    @memset(flags, 0);
    @memset(interior_parent, null);
    @memset(interior_first_child, null);
    @memset(interior_next_sibling, null);
    @memset(interior_root, null);
    @memset(interior_offset, 0);
    @memset(interior_offset_known, false);
    @memset(alloc_size, 0);
    @memset(alloc_size_known, false);

    for (snapshot.changes) |change| {
        const idx: usize = @intCast(change.reg);
        if (change.state) |value| state[idx] = value;
        if (change.origins) |value| origins[idx] = value;
        if (change.locks) |value| locks[idx] = value;
        if (change.flags) |value| flags[idx] = value;
        if (change.interior_parent) |value| interior_parent[idx] = value;
        if (change.interior_first_child) |value| interior_first_child[idx] = value;
        if (change.interior_next_sibling) |value| interior_next_sibling[idx] = value;
        if (change.interior_root) |value| interior_root[idx] = value;
        if (change.interior_offset) |value| interior_offset[idx] = value;
        if (change.interior_offset_known) |value| interior_offset_known[idx] = value;
        if (change.alloc_size) |value| alloc_size[idx] = value;
        if (change.alloc_size_known) |value| alloc_size_known[idx] = value;
    }
}

fn snapshotChangeFor(snapshot: *const LabelSnapshot, reg: u32) ?LabelStateChange {
    for (snapshot.changes) |change| {
        if (change.reg == reg) return change;
    }
    return null;
}

fn snapshotStateAt(snapshot: *const LabelSnapshot, reg: u32) u16 {
    return snapshotChangeFor(snapshot, reg) orelse .{ .reg = reg };
}

fn snapshotMaskAt(snapshot: *const LabelSnapshot, reg: u32) u16 {
    const change = snapshotChangeFor(snapshot, reg) orelse return 0;
    return change.state orelse 0;
}

fn snapshotStatesCompatible(snapshot: *const LabelSnapshot, state: []const u16) bool {
    const active_mask: u16 = 0x01;      // maskOf(.active)
    const untracked_mask: u16 = 0x40;   // maskOf(.untracked)
    const consumed_mask: u16 = 0x08;    // maskOf(.consumed)

    for (state, 0..) |mask, idx| {
        const snap_mask = snapshotMaskAt(snapshot, @intCast(idx));
        if (snap_mask == mask) continue;

        // Allow Uninitialized ↔ Consumed
        if ((snap_mask == 0 and mask == consumed_mask) or (mask == 0 and snap_mask == consumed_mask)) continue;
        if ((snap_mask == consumed_mask and mask == 0) or (mask == consumed_mask and snap_mask == 0)) continue;

        // PATCH: Allow Active ↔ Uninitialized
        if ((snap_mask == 0 and mask == active_mask) or (mask == 0 and snap_mask == active_mask)) continue;

        // PATCH: Allow (Active|BorrowView) ↔ Uninitialized (while-loop back-edge
        // with a borrow created inside the loop but not at entry).
        const borrow_active_mask: u16 = 0x01 | 0x10; // active | borrow_view
        if ((snap_mask == 0 and mask == borrow_active_mask) or (mask == 0 and snap_mask == borrow_active_mask)) continue;

        // PATCH: Allow Active (0x01) ↔ Untracked (0x40)
        if (snap_mask == active_mask and mask == untracked_mask) continue;
        if (mask == active_mask and snap_mask == untracked_mask) continue;

        // PATCH: Allow Untracked (0x40) ↔ Uninitialized (0)
        if ((snap_mask == 0 and mask == untracked_mask) or (mask == 0 and snap_mask == untracked_mask)) continue;

        return false;
    }
    return true;
}

fn snapshotMergeCompatible(snapshot: *const LabelSnapshot, state: []const u16) bool {
    if (snapshot.changes.len == 0) return state.len == 0;
    for (snapshot.changes) |change| {
        const idx: usize = @intCast(change.reg);
        if (idx >= state.len) return false;
        if (mergeJoinMask(change.state orelse 0, state[idx]) == null) return false;
    }
    return true;
}

fn snapshotFirstMismatch(snapshot: *const LabelSnapshot, state: []const u16, symbols: *const symbol.SymbolTable) ?StateMismatch {
    for (state, 0..) |mask, idx| {
        const snap_mask = snapshotMaskAt(snapshot, @intCast(idx));
        if (snap_mask == mask) continue;
        if ((snap_mask == 0 and mask == maskOf(.consumed)) or (mask == 0 and snap_mask == maskOf(.consumed))) continue;
        if ((snap_mask == maskOf(.consumed) and mask == 0) or (mask == maskOf(.consumed) and snap_mask == 0)) continue;

        // PATCH: Allow Active ↔ Uninitialized
        const active_mask = maskOf(.active);
        if ((snap_mask == 0 and mask == active_mask) or (mask == 0 and snap_mask == active_mask)) continue;

        // PATCH: Allow (Active|BorrowView) ↔ Uninitialized (while-loop back-edge
        // with a borrow created inside the loop but not at entry).
        const borrow_active_mask = maskOf(.active) | maskOf(.borrow_view);
        if ((snap_mask == 0 and mask == borrow_active_mask) or (mask == 0 and snap_mask == borrow_active_mask)) continue;

        // PATCH: Allow Active ↔ Untracked
        const untracked_mask = maskOf(.untracked);
        if ((snap_mask == active_mask and mask == untracked_mask) or (mask == active_mask and snap_mask == untracked_mask)) continue;

        // PATCH: Allow Untracked ↔ Uninitialized
        if ((snap_mask == 0 and mask == untracked_mask) or (mask == 0 and snap_mask == untracked_mask)) continue;

        // PATCH: Allow Untracked ↔ Uninitialized
        if ((snap_mask == 0 and mask == untracked_mask) or (mask == 0 and snap_mask == untracked_mask)) continue;

        const name = symbols.lookupName(@intCast(idx)) orelse continue;
        return .{ .name = name, .expected = mask, .actual = snap_mask };
    }
    return null;
}

fn snapshotFirstMismatchInScope(snapshot: *const LabelSnapshot, state: []const u16, scope: *const FunctionRegScope, symbols: *const symbol.SymbolTable) ?StateMismatch {
    for (state, 0..) |mask, idx| {
        const snap_mask = snapshotMaskAt(snapshot, @intCast(idx));
        if (snap_mask == mask) continue;
        if ((snap_mask == 0 and mask == maskOf(.consumed)) or (mask == 0 and snap_mask == maskOf(.consumed))) continue;
        if ((snap_mask == maskOf(.consumed) and mask == 0) or (mask == maskOf(.consumed) and snap_mask == 0)) continue;

        // PATCH: Allow Active ↔ Uninitialized
        const active_mask = maskOf(.active);
        if ((snap_mask == 0 and mask == active_mask) or (mask == 0 and snap_mask == active_mask)) continue;

        // PATCH: Allow (Active|BorrowView) ↔ Uninitialized (while-loop back-edge
        // with a borrow created inside the loop but not at entry).
        const borrow_active_mask = maskOf(.active) | maskOf(.borrow_view);
        if ((snap_mask == 0 and mask == borrow_active_mask) or (mask == 0 and snap_mask == borrow_active_mask)) continue;

        // PATCH: Allow Active ↔ Untracked
        const untracked_mask = maskOf(.untracked);
        if ((snap_mask == active_mask and mask == untracked_mask) or (mask == active_mask and snap_mask == untracked_mask)) continue;

        // PATCH: Allow Untracked ↔ Uninitialized
        if ((snap_mask == 0 and mask == untracked_mask) or (mask == 0 and snap_mask == untracked_mask)) continue;

        // PATCH: Allow Untracked ↔ Uninitialized
        if ((snap_mask == 0 and mask == untracked_mask) or (mask == 0 and snap_mask == untracked_mask)) continue;

        const name = scope.nameOf(symbols, @intCast(idx)) orelse symbols.lookupName(@intCast(idx)) orelse continue;
        return .{ .name = name, .expected = mask, .actual = snap_mask };
    }
    return null;
}

fn replaceLabelStateSnapshot(
    allocator: std.mem.Allocator,
    snapshot: *LabelSnapshot,
    state: []const u16,
    origins: []const ?u32,
    locks: []const u16,
    flags: []const u8,
    interior_parent: []const ?u32,
    interior_first_child: []const ?u32,
    interior_next_sibling: []const ?u32,
) !void {
    _ = origins;
    _ = locks;
    _ = flags;
    _ = interior_parent;
    _ = interior_first_child;
    _ = interior_next_sibling;
    var changes = std.array_list.Managed(LabelStateChange).init(allocator);
    errdefer changes.deinit();

    for (state, 0..) |mask, idx| {
        const existing = snapshotChangeFor(snapshot, @intCast(idx));
        const prev = existing.?.state orelse 0;
        const merged = mergeJoinMask(prev, mask) orelse return error.InvalidJoinState;
        const meta = existing orelse .{ .reg = @as(u32, @intCast(idx)) };
        const have_meta = meta.origins != null or meta.locks != null or meta.flags != null or meta.interior_parent != null or meta.interior_first_child != null or meta.interior_next_sibling != null;
        if (merged == 0 and !have_meta) continue;
        try changes.append(.{
            .reg = @intCast(idx),
            .state = if (merged != 0) merged else null,
            .origins = meta.origins,
            .locks = meta.locks,
            .flags = meta.flags,
            .interior_parent = meta.interior_parent,
            .interior_first_child = meta.interior_first_child,
            .interior_next_sibling = meta.interior_next_sibling,
        });
    }

    snapshot.deinit(allocator);
    snapshot.* = .{ .changes = try changes.toOwnedSlice() };
}

fn snapshotMergeState(snapshot: *const LabelSnapshot, state: []const u16, symbols: *const symbol.SymbolTable) ?StateMismatch {
    for (state, 0..) |mask, idx| {
        const snap_mask = snapshotMaskAt(snapshot, @intCast(idx));
        if (snap_mask == mask) continue;
        if (mergeJoinMask(snap_mask, mask) != null) continue;
        const name = symbols.lookupName(@intCast(idx)) orelse continue;
        return .{ .name = name, .expected = mask, .actual = snap_mask };
    }
    return null;
}

fn snapshotMergeStateInScope(snapshot: *const LabelSnapshot, state: []const u16, scope: *const FunctionRegScope, symbols: *const symbol.SymbolTable) ?StateMismatch {
    for (state, 0..) |mask, idx| {
        const snap_mask = snapshotMaskAt(snapshot, @intCast(idx));
        if (snap_mask == mask) continue;
        if (mergeJoinMask(snap_mask, mask) != null) continue;
        const name = scope.nameOf(symbols, @intCast(idx)) orelse symbols.lookupName(@intCast(idx)) orelse continue;
        return .{ .name = name, .expected = mask, .actual = snap_mask };
    }
    return null;
}

fn callConsumesByValueArg(callee: []const u8) bool {
    return std.mem.eql(u8, callee, "pthread_drop") or
        std.mem.eql(u8, callee, "fd_close") or
        std.mem.eql(u8, callee, "dlclose") or
        std.mem.eql(u8, callee, "munmap") or
        std.mem.eql(u8, callee, "sqlite3_finalize") or
        std.mem.endsWith(u8, callee, "_close") or
        std.mem.endsWith(u8, callee, "_drop") or
        std.mem.endsWith(u8, callee, "_unmap") or
        std.mem.endsWith(u8, callee, "_finalize") or
        std.mem.endsWith(u8, callee, "_free") or
        std.mem.endsWith(u8, callee, "_destroy") or
        std.mem.endsWith(u8, callee, "_release");
}

fn markConsumedGlobalReg(scope: *const FunctionRegScope, global_reg: u32, consumed_in_function: []bool) void {
    const slot = scope.slotOf(global_reg) orelse return;
    consumed_in_function[@intCast(slot)] = true;
}

fn markCaretConsumedRegs(text: []const u8, symbols: *const symbol.SymbolTable, scope: *const FunctionRegScope, consumed_in_function: []bool) void {
    var search_start: usize = 0;
    while (search_start < text.len) {
        const caret_idx = std.mem.indexOfPos(u8, text, search_start, "^") orelse return;
        const name_start = caret_idx + 1;
        var name_end = name_start;
        while (name_end < text.len and (std.ascii.isAlphanumeric(text[name_end]) or text[name_end] == '_')) : (name_end += 1) {}
        if (name_end > name_start) {
            if (symbols.findId(text[name_start..name_end])) |global_reg| {
                markConsumedGlobalReg(scope, global_reg, consumed_in_function);
            }
        }
        search_start = caret_idx + 1;
    }
}

fn markCaretConsumedOperand(operand: inst.Operand, symbols: *const symbol.SymbolTable, scope: *const FunctionRegScope, consumed_in_function: []bool) void {
    switch (operand) {
        .text => |text| markCaretConsumedRegs(text, symbols, scope, consumed_in_function),
        .native_text => |text| markCaretConsumedRegs(text, symbols, scope, consumed_in_function),
        else => {},
    }
}

fn markConsumedScopedName(symbols: *const symbol.SymbolTable, scope: *const FunctionRegScope, name: []const u8, consumed_in_function: []bool) void {
    const global_reg = symbols.findId(name) orelse return;
    const slot = scope.slotOf(global_reg) orelse return;
    consumed_in_function[@intCast(slot)] = true;
}

fn markStructuredCallConsumedRegs(
    allocator: std.mem.Allocator,
    item: inst.Instruction,
    symbols: *const symbol.SymbolTable,
    scope: *const FunctionRegScope,
    consumed_in_function: []bool,
) void {
    switch (item.kind) {
        .call, .call_indirect, .panic, .panic_msg => {},
        else => return,
    }

    var parsed = parseInstructionCallForFunctionScan(allocator, symbols, scope, item) catch return;
    defer parsed.deinit(allocator);
    for (parsed.args) |arg| {
        if (arg.prefix != .move) continue;
        if (!isIdentLike(arg.text)) continue;
        markConsumedScopedName(symbols, scope, arg.text, consumed_in_function);
    }
}

fn markInstructionConsumedRegs(
    allocator: std.mem.Allocator,
    item: inst.Instruction,
    symbols: *const symbol.SymbolTable,
    scope: *const FunctionRegScope,
    consumed_in_function: []bool,
) void {
    switch (item.kind) {
        .move_, .release => if (item.operands[0] == .reg) markConsumedGlobalReg(scope, item.operands[0].reg, consumed_in_function),
        .assign => if (item.operands[1] == .reg) markConsumedGlobalReg(scope, item.operands[1].reg, consumed_in_function),
        .return_ => if (item.operands[0] == .reg) markConsumedGlobalReg(scope, item.operands[0].reg, consumed_in_function),
        .try_, .early_return => if (item.operands[1] == .reg) markConsumedGlobalReg(scope, item.operands[1].reg, consumed_in_function),
        else => {},
    }
    markStructuredCallConsumedRegs(allocator, item, symbols, scope, consumed_in_function);
    for (item.operands) |operand| {
        markCaretConsumedOperand(operand, symbols, scope, consumed_in_function);
    }
}

fn computeFunctionConsumedRegs(
    allocator: std.mem.Allocator,
    instructions: []const inst.Instruction,
    function_start_idx: usize,
    symbols: *const symbol.SymbolTable,
    scope: *const FunctionRegScope,
    consumed_in_function: []bool,
) void {
    @memset(consumed_in_function, false);
    var idx = function_start_idx + 1;
    while (idx < instructions.len) : (idx += 1) {
        const item = instructions[idx];
        if (isDecl(item.kind)) break;
        if (builtin.is_test) test_consumed_scan_count += 1;
        markInstructionConsumedRegs(allocator, item, symbols, scope, consumed_in_function);
    }
}

fn detachInteriorChild(
    state: []u16,
    interior_parent: []?u32,
    interior_first_child: []?u32,
    interior_next_sibling: []?u32,
    child_id: u32,
) void {
    _ = state;
    const child_idx: usize = @intCast(child_id);
    if (interior_parent[child_idx]) |parent_id| {
        const parent_idx: usize = @intCast(parent_id);
        var prev: ?u32 = null;
        var current = interior_first_child[parent_idx];
        while (current) |current_id| {
            if (current_id == child_id) {
                const next = interior_next_sibling[child_idx];
                if (prev) |prev_id| {
                    interior_next_sibling[@intCast(prev_id)] = next;
                } else {
                    interior_first_child[parent_idx] = next;
                }
                break;
            }
            prev = current_id;
            current = interior_next_sibling[@intCast(current_id)];
        }
    }
    interior_parent[child_idx] = null;
    interior_next_sibling[child_idx] = null;
}

fn attachInteriorChild(
    state: []u16,
    interior_parent: []?u32,
    interior_first_child: []?u32,
    interior_next_sibling: []?u32,
    parent_id: u32,
    child_id: u32,
) void {
    detachInteriorChild(state, interior_parent, interior_first_child, interior_next_sibling, child_id);
    const parent_idx: usize = @intCast(parent_id);
    const child_idx: usize = @intCast(child_id);
    interior_parent[child_idx] = parent_id;
    interior_next_sibling[child_idx] = interior_first_child[parent_idx];
    interior_first_child[parent_idx] = child_id;
}

fn clearInteriorOffsetMeta(interior: *InteriorContext, id: u32) void {
    const idx: usize = @intCast(id);
    if (idx >= interior.interior_root.len) return;
    interior.interior_root[idx] = null;
    interior.interior_offset[idx] = 0;
    interior.interior_offset_known[idx] = false;
}

fn staticByteOffset(operand: inst.Operand) ?u64 {
    return switch (operand) {
        .imm_u64 => |value| value,
        .imm_i64 => |value| if (value >= 0) @as(u64, @intCast(value)) else null,
        else => null,
    };
}

fn parseAllocSizeOperand(operand: inst.Operand) ?u64 {
    return switch (operand) {
        .imm_u64 => |value| value,
        .imm_i64 => |value| if (value > 0) @as(u64, @intCast(value)) else null,
        .text => |t| std.fmt.parseInt(u64, std.mem.trim(u8, t, " \t\r\n"), 10) catch null,
        else => null,
    };
}

fn clearAllocSizeMeta(interior: *InteriorContext, id: u32) void {
    const idx: usize = @intCast(id);
    if (idx >= interior.alloc_size.len) return;
    interior.alloc_size[idx] = 0;
    interior.alloc_size_known[idx] = false;
}

fn recordAllocSize(interior: *InteriorContext, id: u32, maybe_size: ?u64) void {
    const idx: usize = @intCast(id);
    if (idx >= interior.alloc_size.len) return;
    if (maybe_size) |size| {
        interior.alloc_size[idx] = size;
        interior.alloc_size_known[idx] = true;
    } else {
        interior.alloc_size[idx] = 0;
        interior.alloc_size_known[idx] = false;
    }
}

/// Follow interior_root, then borrow origins, to the ultimate allocation.
/// Returns the allocation register id, or null when the chain is unknown.
fn resolveAllocRoot(
    interior: *const InteriorContext,
    origins: []const ?u32,
    id: u32,
) ?u32 {
    var current: u32 = id;
    var hops: usize = 0;
    while (hops < origins.len + 1) : (hops += 1) {
        const idx: usize = @intCast(current);
        if (idx >= interior.interior_root.len or idx >= origins.len) return null;
        if (interior.interior_root[idx]) |root| {
            if (root == current) break;
            current = root;
            continue;
        }
        if (origins[idx]) |origin| {
            if (origin == current) break;
            current = origin;
            continue;
        }
        break;
    }
    return current;
}

/// Total static byte offset of `id` relative to its allocation root, or null
/// when any step of the chain is dynamic/unknown.
/// A fresh borrow view or allocation root with no recorded offset counts as
/// zero and the walk continues through origins; a derived pointer
/// (interior_root set) with unknown offset denotes a dynamic offset and
/// stays permissive.
fn chainBaseOffset(
    interior: *const InteriorContext,
    origins: []const ?u32,
    id: u32,
) ?u64 {
    var total: u64 = 0;
    var current: u32 = id;
    var hops: usize = 0;
    const bound: usize = origins.len + 1;
    while (hops < bound) : (hops += 1) {
        const idx: usize = @intCast(current);
        if (idx >= interior.interior_offset_known.len or idx >= interior.interior_root.len or idx >= origins.len) return null;
        if (interior.interior_offset_known[idx]) {
            const sum = @addWithOverflow(total, interior.interior_offset[idx]);
            if (sum[1] != 0) return null;
            total = sum[0];
        } else if (interior.interior_root[idx] == null and origins[idx] == null) {
            // Allocation root (or plain value) with no offset: contributes 0.
        } else if (interior.interior_root[idx] == null and origins[idx] != null) {
            // Fresh borrow view directly on its source: contributes 0.
        } else {
            // Derived pointer with dynamic/unknown offset: permissive.
            return null;
        }
        if (interior.interior_root[idx]) |root| {
            if (root == current) {
                // Root link resolved; continue through borrow origins if any.
                if (origins[idx]) |origin| {
                    if (origin == current) break;
                    current = origin;
                    continue;
                }
                break;
            }
            current = root;
            continue;
        }
        if (origins[idx]) |origin| {
            if (origin == current) break;
            current = origin;
            continue;
        }
        break;
    }
    return total;
}

/// Total static byte offset of `id` relative to its allocation root, or null
/// when any step of the chain is dynamic/unknown.
fn totalStaticOffset(interior: *const InteriorContext, id: u32) ?u64 {
    const idx: usize = @intCast(id);
    if (idx >= interior.interior_offset_known.len) return null;
    if (!interior.interior_offset_known[idx]) return null;
    return interior.interior_offset[idx];
}

fn checkStaticOffsetInBounds(
    item: inst.Instruction,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
    name: []const u8,
    interior: *const InteriorContext,
    origins: []const ?u32,
    state: []const u16,
    id: u32,
    static_offset: ?u64,
) ?VerifyBodyResult {
    const off = static_offset orelse return null;
    const root = resolveAllocRoot(interior, origins, id) orelse return null;
    const root_idx: usize = @intCast(root);
    if (root_idx >= interior.alloc_size_known.len) return null;
    if (!interior.alloc_size_known[root_idx]) return null;
    const size = interior.alloc_size[root_idx];
    // Base offset accumulated along the interior/borrow chain (fresh views
    // count as zero; dynamic steps stay permissive).
    const base_off = chainBaseOffset(interior, origins, id) orelse return null;
    const sum = @addWithOverflow(base_off, off);
    if (sum[1] != 0) {
        return trapReport(.borrow_conflict, item, function_text, is_ffi_wrapper, name, maskOf(.active), state[@intCast(id)], "pointer offset exceeds allocation size", "shrink the constant offset or widen the allocation");
    }
    const total = sum[0];
    // Offset equal to size is one-past-the-end: forming it is legal only if
    // never dereferenced, but our load/store/ptr_add use sites all denote an
    // actual access here, so require strict containment.
    if (total >= size) {
        return trapReport(.borrow_conflict, item, function_text, is_ffi_wrapper, name, maskOf(.active), state[@intCast(id)], "pointer offset exceeds allocation size", "shrink the constant offset or widen the allocation");
    }
    return null;
}

fn setInteriorOffsetFromBase(interior: *InteriorContext, base_id: u32, child_id: u32, maybe_offset: ?u64) void {
    const base_idx: usize = @intCast(base_id);
    const child_idx: usize = @intCast(child_id);
    if (child_idx >= interior.interior_root.len or base_idx >= interior.interior_root.len) return;

    const root = interior.interior_root[base_idx] orelse base_id;
    interior.interior_root[child_idx] = root;
    if (maybe_offset) |offset| {
        if (interior.interior_offset_known[base_idx]) {
            const sum = @addWithOverflow(interior.interior_offset[base_idx], offset);
            if (sum[1] != 0) {
                interior.interior_offset[child_idx] = 0;
                interior.interior_offset_known[child_idx] = false;
                return;
            }
            interior.interior_offset[child_idx] = sum[0];
        } else {
            interior.interior_offset[child_idx] = offset;
        }
        interior.interior_offset_known[child_idx] = true;
    } else {
        interior.interior_offset[child_idx] = 0;
        interior.interior_offset_known[child_idx] = false;
    }
}

fn sameInteriorField(interior: *const InteriorContext, lhs: u32, rhs: u32) bool {
    const lhs_idx: usize = @intCast(lhs);
    const rhs_idx: usize = @intCast(rhs);
    if (lhs_idx >= interior.interior_root.len or rhs_idx >= interior.interior_root.len) return true;
    const lhs_root = interior.interior_root[lhs_idx] orelse lhs;
    const rhs_root = interior.interior_root[rhs_idx] orelse rhs;
    if (lhs_root != rhs_root) return false;
    if (!interior.interior_offset_known[lhs_idx] or !interior.interior_offset_known[rhs_idx]) return true;
    return interior.interior_offset[lhs_idx] == interior.interior_offset[rhs_idx];
}

fn hasOverlappingInteriorBorrow(interior: *const InteriorContext, locks: []const u16, source_id: u32) bool {
    const source_idx: usize = @intCast(source_id);
    if (source_idx >= interior.state.len) return true;
    for (locks, 0..) |lock, idx| {
        if (idx == source_idx or lock == 0) continue;
        const other_id: u32 = @intCast(idx);
        if (sameInteriorField(interior, source_id, other_id)) return true;
    }
    return false;
}

fn clearInteriorNode(
    state: []u16,
    interior_parent: []?u32,
    interior_first_child: []?u32,
    interior_next_sibling: []?u32,
    id: u32,
) void {
    const idx: usize = @intCast(id);
    var current = interior_first_child[idx];
    interior_first_child[idx] = null;
    while (current) |child_id| {
        const next = interior_next_sibling[@intCast(child_id)];
        detachInteriorChild(state, interior_parent, interior_first_child, interior_next_sibling, child_id);
        current = next;
    }
}

fn consumeInteriorChildren(
    state: []u16,
    interior_parent: []?u32,
    interior_first_child: []?u32,
    interior_next_sibling: []?u32,
    id: u32,
) void {
    const idx: usize = @intCast(id);
    var current = interior_first_child[idx];
    interior_first_child[idx] = null;
    while (current) |child_id| {
        const child_idx: usize = @intCast(child_id);
        const next = interior_next_sibling[child_idx];
        detachInteriorChild(state, interior_parent, interior_first_child, interior_next_sibling, child_id);
        if (hasInteriorPtr(state[child_idx]) or interior_first_child[child_idx] != null) {
            consumeInteriorChildren(state, interior_parent, interior_first_child, interior_next_sibling, child_id);
        }
        state[child_idx] = maskOf(.consumed);
        current = next;
    }
}

fn consumeInteriorValue(
    state: []u16,
    interior_parent: []?u32,
    interior_first_child: []?u32,
    interior_next_sibling: []?u32,
    id: u32,
) void {
    const idx: usize = @intCast(id);
    if ((state[idx] & maskOf(.interior_ptr)) == 0 and interior_first_child[idx] == null) return;
    detachInteriorChild(state, interior_parent, interior_first_child, interior_next_sibling, id);
    consumeInteriorChildren(state, interior_parent, interior_first_child, interior_next_sibling, id);
    state[idx] = maskOf(.consumed);
}

fn trapReport(
    kind: trap.Trap,
    item: inst.Instruction,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
    register: ?[]const u8,
    expected_mask: ?u16,
    actual_mask: ?u16,
    message: []const u8,
    hint: ?[]const u8,
) VerifyBodyResult {
    const source_text = trimTrailingCr(item.raw_text);
    var report: trap.TrapReport = .{
        .trap = kind,
        .trap_code = trapCode(kind),
        .line = item.expanded_line + 1,
        .source_line = item.source_line,
        .source_text_buf = std.mem.zeroes([256]u8),
        .original_text_buf = std.mem.zeroes([256]u8),
        .source_text = null,
        .original_text = null,
        .register = null,
        .registers = &.{},
        .expected_mask = expected_mask,
        .actual_mask = actual_mask,
        .expected_mask_name = if (expected_mask) |v| cap.maskName(v) else null,
        .actual_mask_name = if (actual_mask) |v| cap.maskName(v) else null,
        .upstream_loc = item.upstream_loc,
        .upstream_file_buf = std.mem.zeroes([128]u8),
        .upstream_line = if (item.upstream_loc) |loc| loc.line else 0,
        .upstream_col = if (item.upstream_loc) |loc| loc.col else 0,
        .function = null,
        .is_ffi_wrapper = if (function_text != null) is_ffi_wrapper else null,
        .message = message,
        .hint = hint,
    };

    copyTextBuf(&report.source_text_buf, source_text);
    copyTextBuf(&report.original_text_buf, source_text);

    if (register) |value| {
        const len = @min(report.register_buf.len, value.len);
        std.mem.copyForwards(u8, report.register_buf[0..len], value[0..len]);
    }
    if (function_text) |value| {
        const len = @min(report.function_buf.len, value.len);
        std.mem.copyForwards(u8, report.function_buf[0..len], value[0..len]);
    }
    if (report.upstream_loc) |loc| {
        const len = @min(report.upstream_file_buf.len, loc.file.len);
        std.mem.copyForwards(u8, report.upstream_file_buf[0..len], loc.file[0..len]);
        report.upstream_loc = null;
    }

    return .{ .trap = report };
}

fn trapReportWithRegisters(
    kind: trap.Trap,
    item: inst.Instruction,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
    register: ?[]const u8,
    registers: []const []const u8,
    expected_mask: ?u16,
    actual_mask: ?u16,
    message: []const u8,
    hint: ?[]const u8,
) VerifyBodyResult {
    const result = trapReport(kind, item, function_text, is_ffi_wrapper, register, expected_mask, actual_mask, message, hint);
    _ = registers;
    return result;
}

fn phiStateConflictReport(
    item: inst.Instruction,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
    target: u32,
    last_seen_label: ?u32,
    mismatch: ?StateMismatch,
    symbols: *const symbol.SymbolTable,
) VerifyBodyResult {
    const mismatch_name = if (mismatch) |m| m.name else "unknown";
    const expected_mask = if (mismatch) |m| m.expected else null;
    const actual_mask = if (mismatch) |m| m.actual else null;

    const target_name = symbols.lookupName(target) orelse "unknown";
    const current_block_name = if (last_seen_label) |l| symbols.lookupName(l) orelse "unknown" else "entry";

    const expected_name = if (expected_mask) |m| cap.maskName(m) else "Uninitialized";
    const actual_name = if (actual_mask) |m| cap.maskName(m) else "Uninitialized";

    var result = trapReportWithRegisters(
        .phi_state_conflict,
        item,
        function_text,
        is_ffi_wrapper,
        if (mismatch) |m| m.name else null,
        if (mismatch) |m| &[_][]const u8{m.name} else &.{},
        expected_mask,
        actual_mask,
        "incoming control-flow states do not agree",
        null,
    );

    var advice_buf: [256]u8 = std.mem.zeroes([256]u8);
    const advice = if (expected_mask != null or actual_mask != null) blk: {
        const m1 = expected_mask orelse 0;
        const m2 = actual_mask orelse 0;
        const active_mask = maskOf(.active);
        const consumed_mask = maskOf(.consumed);
        const is_borrow1 = (m1 & (maskOf(.locked_read) | maskOf(.locked_mut) | maskOf(.borrow_view) | maskOf(.ffi_borrow))) != 0;
        const is_borrow2 = (m2 & (maskOf(.locked_read) | maskOf(.locked_mut) | maskOf(.borrow_view) | maskOf(.ffi_borrow))) != 0;

        if (is_borrow1 or is_borrow2) {
            break :blk std.fmt.bufPrint(
                &advice_buf,
                "Release all active borrows of '{s}' before paths merge.",
                .{mismatch_name},
            ) catch "";
        } else if ((m1 == active_mask and (m2 == 0 or m2 == consumed_mask)) or
            (m2 == active_mask and (m1 == 0 or m1 == consumed_mask)))
        {
            break :blk std.fmt.bufPrint(
                &advice_buf,
                "Consume/release '{s}' on all paths (e.g. using '!{s}'), or don't consume it on any path.",
                .{ mismatch_name, mismatch_name },
            ) catch "";
        } else {
            break :blk std.fmt.bufPrint(
                &advice_buf,
                "Ensure '{s}' has matching capability states across all paths.",
                .{mismatch_name},
            ) catch "";
        }
    } else "";

    _ = std.fmt.bufPrint(
        &result.trap.hint_buf,
        "register '{s}' has mismatched path states:\n  - Path via '{s}': {s}\n  - Path via target '{s}': {s}\nSelf-repair hint: {s}",
        .{ mismatch_name, current_block_name, expected_name, target_name, actual_name, advice },
    ) catch |err| {
        // Diagnostic buffer formatting is best-effort; the trap kind and core message are already set.
        _ = @errorName(err);
    };

    return result;
}

fn saxTrapReport(
    kind: trap.Trap,
    item: inst.Instruction,
    component_name: []const u8,
    register: ?[]const u8,
    expected_mask: ?u16,
    actual_mask: ?u16,
    message: []const u8,
    hint: ?[]const u8,
) VerifyBodyResult {
    var report: trap.TrapReport = .{
        .trap = kind,
        .trap_code = trapCode(kind),
        .line = item.expanded_line + 1,
        .source_line = item.source_line,
        .source_text_buf = std.mem.zeroes([256]u8),
        .original_text_buf = std.mem.zeroes([256]u8),
        .source_text = null,
        .original_text = null,
        .register = null,
        .registers = &.{},
        .expected_mask = expected_mask,
        .actual_mask = actual_mask,
        .expected_mask_name = if (expected_mask) |v| cap.maskName(v) else null,
        .actual_mask_name = if (actual_mask) |v| cap.maskName(v) else null,
        .upstream_loc = item.upstream_loc,
        .upstream_file_buf = std.mem.zeroes([128]u8),
        .upstream_line = if (item.upstream_loc) |loc| loc.line else 0,
        .upstream_col = if (item.upstream_loc) |loc| loc.col else 0,
        .function = null,
        .is_ffi_wrapper = null,
        .message = message,
        .hint = hint,
    };
    copyTextBuf(&report.source_text_buf, trimTrailingCr(item.raw_text));
    copyTextBuf(&report.original_text_buf, trimTrailingCr(item.raw_text));
    copyTextBuf(&report.function_buf, component_name);
    if (register) |value| {
        const len = @min(report.register_buf.len, value.len);
        std.mem.copyForwards(u8, report.register_buf[0..len], value[0..len]);
    }
    if (report.upstream_loc) |loc| {
        const len = @min(report.upstream_file_buf.len, loc.file.len);
        std.mem.copyForwards(u8, report.upstream_file_buf[0..len], loc.file[0..len]);
        report.upstream_loc = null;
    }
    return .{ .trap = report };
}

fn saxReport(
    ctx: SaxValidationContext,
    kind: trap.Trap,
    item: inst.Instruction,
    register: ?[]const u8,
    expected_mask: ?u16,
    actual_mask: ?u16,
    message: []const u8,
    hint: ?[]const u8,
) VerifyBodyResult {
    return saxTrapReport(kind, item, ctx.component_name, register, expected_mask, actual_mask, message, hint);
}

fn trapReportFromText(
    kind: trap.Trap,
    line: u32,
    source_line: u32,
    raw_text: []const u8,
    message: []const u8,
    hint: ?[]const u8,
) trap.TrapReport {
    var report: trap.TrapReport = .{
        .trap = kind,
        .trap_code = trapCode(kind),
        .line = line,
        .source_line = source_line,
        .source_text_buf = std.mem.zeroes([256]u8),
        .original_text_buf = std.mem.zeroes([256]u8),
        .source_text = null,
        .original_text = null,
        .register = null,
        .registers = &.{},
        .expected_mask = null,
        .actual_mask = null,
        .expected_mask_name = null,
        .actual_mask_name = null,
        .upstream_loc = null,
        .upstream_file_buf = std.mem.zeroes([128]u8),
        .upstream_line = 0,
        .upstream_col = 0,
        .function = null,
        .is_ffi_wrapper = null,
        .message = message,
        .hint = hint,
    };
    const text = trimTrailingCr(raw_text);
    copyTextBuf(&report.source_text_buf, text);
    copyTextBuf(&report.original_text_buf, text);
    return report;
}

fn builtinArgSpec(name: []const u8) ?[]const inst.CapPrefix {
    if (std.mem.eql(u8, name, "panic")) return &.{.by_value};
    if (std.mem.eql(u8, name, "panic_msg")) return &.{ .by_value, .raw, .by_value };
    if (std.mem.eql(u8, name, "sys_print")) return &.{ .raw, .by_value };
    if (std.mem.eql(u8, name, "sys_read_file")) return &.{ .raw, .by_value, .raw };
    if (std.mem.eql(u8, name, "sys_write_file")) return &.{ .raw, .by_value, .raw, .by_value };
    if (std.mem.eql(u8, name, "sys_exit")) return &.{.by_value};
    if (std.mem.eql(u8, name, "sys_argv")) return &.{.by_value};
    if (std.mem.eql(u8, name, "sys_argc")) return &.{};
    return null;
}

fn builtinGrantRequirement(name: []const u8) ?pkg_manifest.Capability {
    if (std.mem.eql(u8, name, "sys_print")) return .io_write;
    if (std.mem.eql(u8, name, "sys_read_file")) return .io_read;
    if (std.mem.eql(u8, name, "sys_write_file")) return .io_write;
    if (std.mem.eql(u8, name, "sys_exit")) return .proc_exit;
    if (std.mem.eql(u8, name, "sys_argv")) return .proc_args;
    if (std.mem.eql(u8, name, "sys_argc")) return .proc_args;
    return null;
}

fn packageGrantEntry(
    package_identity: ?[]const u8,
    package_grants: []const pkg_manifest.RequireEntry,
) ?*const pkg_manifest.RequireEntry {
    const identity = package_identity orelse return null;
    for (package_grants, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry.url, identity)) {
            return &package_grants[idx];
        }
    }
    return null;
}

fn packageGrantAllowsEntry(entry: *const pkg_manifest.RequireEntry, required: pkg_manifest.Capability) bool {
    for (entry.grants) |grant| {
        if (grant == required) return true;
    }
    return false;
}

fn packageGrantAllows(
    package_identity: ?[]const u8,
    required: pkg_manifest.Capability,
    package_grants: []const pkg_manifest.RequireEntry,
) bool {
    const entry = packageGrantEntry(package_identity, package_grants) orelse return true;
    return packageGrantAllowsEntry(entry, required);
}

fn builtinReturnCap(name: []const u8) ?inst.CapPrefix {
    if (std.mem.eql(u8, name, "panic")) return null;
    if (std.mem.eql(u8, name, "panic_msg")) return null;
    if (std.mem.eql(u8, name, "sys_read_file")) return .raw;
    if (std.mem.eql(u8, name, "sys_argv")) return .raw;
    if (std.mem.eql(u8, name, "sys_argc")) return .by_value;
    if (std.mem.eql(u8, name, "sys_exit")) return .by_value;
    if (std.mem.eql(u8, name, "sys_write_file")) return .by_value;
    if (std.mem.eql(u8, name, "sys_print")) return null;
    return null;
}

fn callTextForInstruction(
    allocator: std.mem.Allocator,
    symbols: *const symbol.SymbolTable,
    item: inst.Instruction,
) ![]u8 {
    _ = symbols;
    if (item.raw_text.len != 0) return try allocator.dupe(u8, item.raw_text);
    switch (item.kind) {
        .call, .call_indirect => {
            if (item.operands[0] == .reg and item.operands[1] == .text) {
                return try std.fmt.allocPrint(
                    allocator,
                    "{s} = {s} {s}",
                    .{ operandDebugName(item.operands[0]), if (item.kind == .call) "call" else "call_indirect", item.operands[1].text },
                );
            }
            if (item.operands[0] == .text) {
                return try std.fmt.allocPrint(
                    allocator,
                    "{s} {s}",
                    .{ if (item.kind == .call) "call" else "call_indirect", item.operands[0].text },
                );
            }
            if (item.operands[1] == .text) {
                return try std.fmt.allocPrint(
                    allocator,
                    "{s} {s}",
                    .{ if (item.kind == .call) "call" else "call_indirect", item.operands[1].text },
                );
            }
        },
        .panic, .panic_msg => {
            const callee = if (item.kind == .panic) "panic" else "panic_msg";
            if (item.kind == .panic_msg and item.operands[0] != .none and item.operands[1] != .none and item.operands[2] != .none) {
                return try std.fmt.allocPrint(
                    allocator,
                    "{s}({s}, {s}, {s})",
                    .{ callee, operandDebugName(item.operands[0]), operandDebugName(item.operands[1]), operandDebugName(item.operands[2]) },
                );
            }
            if (item.operands[0] == .text) {
                const arg = item.operands[0].text;
                if (arg.len >= 2 and arg[0] == '(' and arg[arg.len - 1] == ')') {
                    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ callee, arg });
                }
                return try std.fmt.allocPrint(allocator, "{s}({s})", .{ callee, arg });
            }
            if (item.operands[0] == .reg) {
                return try std.fmt.allocPrint(allocator, "{s}({s})", .{ callee, operandDebugName(item.operands[0]) });
            }
        },
        else => {},
    }
    return try allocator.dupe(u8, item.raw_text);
}

fn parseInstructionCallForVerifier(
    allocator: std.mem.Allocator,
    symbols: *const symbol.SymbolTable,
    item: inst.Instruction,
) !call.ParsedCall {
    return try call.parseInstructionCall(allocator, item, symbols);
}

const ScopedSymbolLookup = struct {
    symbols: *const symbol.SymbolTable,
    scope: *const FunctionRegScope,

    pub fn lookupName(self: ScopedSymbolLookup, id: u32) ?[]const u8 {
        return self.scope.nameOf(self.symbols, id) orelse self.symbols.lookupName(id);
    }
};

fn parseInstructionCallForLocalizedVerifier(
    allocator: std.mem.Allocator,
    symbols: *const symbol.SymbolTable,
    scope: ?*const FunctionRegScope,
    item: inst.Instruction,
) !call.ParsedCall {
    if (scope) |active_scope| {
        const lookup = ScopedSymbolLookup{ .symbols = symbols, .scope = active_scope };
        return try call.parseInstructionCall(allocator, item, lookup);
    }
    return try parseInstructionCallForVerifier(allocator, symbols, item);
}

const ScopedGlobalFirstSymbolLookup = struct {
    symbols: *const symbol.SymbolTable,
    scope: *const FunctionRegScope,

    pub fn lookupName(self: ScopedGlobalFirstSymbolLookup, id: u32) ?[]const u8 {
        return self.symbols.lookupName(id) orelse self.scope.nameOf(self.symbols, id);
    }
};

fn parseInstructionCallForFunctionScan(
    allocator: std.mem.Allocator,
    symbols: *const symbol.SymbolTable,
    scope: *const FunctionRegScope,
    item: inst.Instruction,
) !call.ParsedCall {
    const lookup = ScopedGlobalFirstSymbolLookup{ .symbols = symbols, .scope = scope };
    return try call.parseInstructionCall(allocator, item, lookup);
}

fn callPrefixMatchesParam(param: sig.ParamSpec, arg_prefix: inst.CapPrefix) bool {
    if (arg_prefix == param.cap) return true;
    if (param.cap != .by_value or param.ty != .ptr) return false;
    return switch (arg_prefix) {
        .borrow, .raw => true,
        else => false,
    };
}

fn isFallibleCall(
    sig_match: ?sig.FunctionSig,
    callee: []const u8,
) bool {
    if (sig_match) |resolved| {
        return resolved.return_fallible;
    }
    return std.mem.eql(u8, callee, "sys_read_file") or std.mem.eql(u8, callee, "sys_argv");
}

fn fallibleValueType(return_cap: ?inst.CapPrefix, return_ty: sig.PrimType) sig.PrimType {
    return sig.returnValueType(return_cap, return_ty);
}

fn fallibleResultMask() u16 {
    return maskOf(.fallible);
}

fn panicMsgAllowsRawArg(callee: []const u8, args_len: usize, idx: usize) bool {
    return std.mem.eql(u8, callee, "panic_msg") and args_len == 3 and idx == 1;
}

fn readCheckAllowRaw(
    item: inst.Instruction,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
    name: []const u8,
    id: u32,
    state: []u16,
    flags: []u8,
) ?VerifyBodyResult {
    _ = flags;
    const idx: usize = @intCast(id);
    const current = state[idx];
    if (current == 0) return trapReport(.unknown_register, item, function_text, is_ffi_wrapper, name, null, null, "register is not declared in the current scope", null);
    if ((current & maskOf(.consumed)) != 0) return trapReport(.use_after_move, item, function_text, is_ffi_wrapper, name, maskOf(.consumed), current, "moved value is no longer usable", null);
    if ((current & maskOf(.locked_mut)) != 0 and (current & maskOf(.borrow_view)) == 0) {
        return trapReport(.borrow_conflict, item, function_text, is_ffi_wrapper, name, maskOf(.active), current, "borrow rules reject this access", null);
    }
    return null;
}

fn parseDeclKind(kind: inst.InstKind) ?sig.FunctionKind {
    return switch (kind) {
        .func_decl => .normal,
        .ffi_wrapper_decl => .ffi_wrapper,
        .extern_decl => .external,
        .export_decl => .exported,
        .test_decl => .test_func,
        else => null,
    };
}

fn addScopeReg(
    reg_ids: *std.array_list.Managed(u32),
    seen: *std.AutoHashMap(u32, void),
    reg_id: u32,
) !void {
    if (seen.contains(reg_id)) return;
    try seen.put(reg_id, {});
    try reg_ids.append(reg_id);
}

fn finalizeFunctionScope(
    sigs: *std.array_list.Managed(sig.FunctionSig),
    reg_ids: *std.array_list.Managed(u32),
    reg_seen: *std.AutoHashMap(u32, void),
    const_decls: []const const_decl.ConstDecl,
    symbols: *const symbol.SymbolTable,
) !void {
    if (sigs.items.len == 0) {
        reg_ids.clearRetainingCapacity();
        return;
    }
    for (const_decls) |decl| {
        if (symbols.findId(decl.name)) |id| {
            try addScopeReg(reg_ids, reg_seen, id);
        }
    }
    const slice = try reg_ids.toOwnedSlice();
    sigs.items[sigs.items.len - 1].reg_ids = slice;
}

fn buildFunctionRegScope(
    allocator: std.mem.Allocator,
    instructions: []const inst.Instruction,
    param_ids: []const u32,
    const_decls: []const const_decl.ConstDecl,
    symbols: *const symbol.SymbolTable,
) !FunctionRegScope {
    var reg_ids = std.array_list.Managed(u32).init(allocator);
    errdefer reg_ids.deinit();
    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();

    try reg_ids.ensureTotalCapacity(param_ids.len);
    try seen.ensureTotalCapacity(@intCast(param_ids.len));
    for (param_ids) |reg_id| {
        try addScopeReg(&reg_ids, &seen, reg_id);
    }

    for (instructions) |item| {
        for (item.operands) |operand| {
            if (operand == .reg) {
                try addScopeReg(&reg_ids, &seen, operand.reg);
            }
        }

        switch (item.kind) {
            .call, .call_indirect, .panic, .panic_msg, .return_, .native => {
            if (parseInstructionCallForVerifier(allocator, &symbols, item)) |parsed0| {
                    var parsed = parsed0;
                    defer parsed.deinit(allocator);
                    if (parsed.dest) |dest| {
                        if (isIdentLike(dest)) {
                            if (symbols.findId(dest)) |id| {
                                try addScopeReg(&reg_ids, &seen, id);
                            }
                        }
                    }
                } else |_| {}
            },
            else => {},
        }
    }

    for (const_decls) |decl| {
        if (symbols.findId(decl.name)) |id| {
            try addScopeReg(&reg_ids, &seen, id);
        }
    }

    const slice = try reg_ids.toOwnedSlice();
    errdefer allocator.free(slice);
    return try FunctionRegScope.init(allocator, slice);
}

fn localizeInstructionRegs(
    item: *inst.Instruction,
    scope: *const FunctionRegScope,
    symbols: *const symbol.SymbolTable,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
) ?VerifyBodyResult {
    for (&item.operands) |*operand| {
        if (operand.* == .reg) {
            const slot = scope.slotOf(operand.reg) orelse {
                return trapReport(.unknown_register, item.*, function_text, is_ffi_wrapper, symbols.lookupName(operand.reg), null, null, "register is not declared in the current scope", null);
            };
            operand.* = .{ .reg = slot };
        }
    }
    return null;
}

fn resolveScopedRegId(
    scope: *const FunctionRegScope,
    symbols: *const symbol.SymbolTable,
    text: []const u8,
) ?u32 {
    const global_id = symbols.findId(text) orelse return null;
    return scope.slotOf(global_id);
}

/// Rebuild per-function register scopes for a trusted (previously verified)
/// instruction stream. The verdict-cache fast path reuses FlattenResult sigs
/// whose `reg_ids` were never finalized, which leaves every `regSlot`/`slotOf`
/// lookup in codegen failing with `InvalidOperand`. This mirrors the scope
/// collection order of `collectMetadata` (params, body `.reg` operands and
/// call dests interleaved per instruction, then const decl names), assigns
/// owned `reg_ids` on each sig, and localizes body `.reg` operands to slots
/// exactly like full verification output.
pub fn populateTrustedRegScopes(
    allocator: std.mem.Allocator,
    instructions: []inst.Instruction,
    const_decls: []const const_decl.ConstDecl,
    function_sigs: []sig.FunctionSig,
    symbols: *const symbol.SymbolTable,
) !void {
    var sig_index: usize = 0;
    var range_start: ?usize = null;
    var idx: usize = 0;
    while (idx <= instructions.len) : (idx += 1) {
        const at_decl = idx < instructions.len and isDecl(instructions[idx].kind);
        if (idx == instructions.len or at_decl) {
            if (range_start) |start| {
                if (sig_index >= function_sigs.len) return error.InvalidTrustedScope;
                try populateTrustedFunctionScope(allocator, instructions[start..idx], const_decls, &function_sigs[sig_index], symbols);
                sig_index += 1;
            }
            if (idx < instructions.len) range_start = idx + 1;
        }
    }
    if (sig_index != function_sigs.len) return error.InvalidTrustedScope;
}

fn populateTrustedFunctionScope(
    allocator: std.mem.Allocator,
    body: []inst.Instruction,
    const_decls: []const const_decl.ConstDecl,
    function_sig: *sig.FunctionSig,
    symbols: *const symbol.SymbolTable,
) !void {
    var reg_ids = std.array_list.Managed(u32).init(allocator);
    errdefer reg_ids.deinit();
    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();

    for (function_sig.param_ids) |reg_id| {
        try addScopeReg(&reg_ids, &seen, reg_id);
    }
    for (body) |item| {
        for (item.operands) |operand| {
            if (operand == .reg) {
                try addScopeReg(&reg_ids, &seen, operand.reg);
            }
        }
        if (parseInstructionCallForVerifier(allocator, symbols, item)) |parsed0| {
            var parsed = parsed0;
            defer parsed.deinit(allocator);
            if (parsed.dest) |dest| {
                if (isIdentLike(dest)) {
                    if (symbols.findId(dest)) |id| {
                        try addScopeReg(&reg_ids, &seen, id);
                    }
                }
            }
        } else |_| {}
    }
    for (const_decls) |decl| {
        if (symbols.findId(decl.name)) |id| {
            try addScopeReg(&reg_ids, &seen, id);
        }
    }

    var scope = try FunctionRegScope.init(allocator, try reg_ids.toOwnedSlice());
    errdefer scope.deinit();
    for (body) |*item| {
        for (&item.operands) |*operand| {
            if (operand.* == .reg) {
                operand.* = .{ .reg = scope.slotOf(operand.reg) orelse return error.InvalidTrustedScope };
            }
        }
    }
    function_sig.reg_ids = scope.reg_ids;
    scope.owns_reg_ids = false;
    scope.deinit();
}

fn collectMetadata(
    allocator: std.mem.Allocator,
    instructions: []const inst.Instruction,
    classified_lines: []const classifier.ClassifiedLine,
    const_decls: []const const_decl.ConstDecl,
) !CollectResult {
    std.debug.assert(classified_lines.len == instructions.len);
    var symbols = symbol.SymbolTable.init(allocator);
    errdefer symbols.deinit();

    var sigs = std.array_list.Managed(sig.FunctionSig).init(allocator);
    errdefer {
        for (sigs.items) |*item| item.deinit(allocator);
        sigs.deinit();
    }
    var sig_index_by_name = std.StringHashMap(usize).init(allocator);
    errdefer sig_index_by_name.deinit();
    var function_starts = std.array_list.Managed(usize).init(allocator);
    errdefer function_starts.deinit();
    var current_reg_ids = std.array_list.Managed(u32).init(allocator);
    defer current_reg_ids.deinit();
    var current_reg_seen = std.AutoHashMap(u32, void).init(allocator);
    defer current_reg_seen.deinit();
    var current_sig_index: usize = 0;

    var const_idx: usize = 0;
    for (instructions, 0..) |item, inst_idx| {
        while (const_idx < const_decls.len and const_decls[const_idx].expanded_line <= item.expanded_line) {
            const decl = const_decls[const_idx];
            if (decl.name.len != 0) {
                _ = try symbols.intern(decl.name);
            }
            const_idx += 1;
        }

        const classified = classified_lines[inst_idx];

        if (isDecl(item.kind)) {
            const kind = parseDeclKind(item.kind).?;
            if (sigs.items.len != 0 and current_sig_index < sigs.items.len) {
                try finalizeFunctionScope(&sigs, &current_reg_ids, &current_reg_seen, const_decls, &symbols);
            }
            current_reg_ids.clearRetainingCapacity();
            current_reg_seen.clearRetainingCapacity();
            var parsed = sig.parseFunctionHeader(allocator, item.raw_text, @intCast(sigs.items.len), item.expanded_line, kind) catch |err| {
                return switch (err) {
                    sig.ParseError.UnsupportedType => error.UnsupportedType,
                    else => error.InvalidFunctionSig,
                };
            };
            errdefer parsed.deinit(allocator);

            // Validate @test function signatures: must be () -> void
            if (kind == .test_func) {
                if (parsed.params.len != 0) {
                    return error.TestFuncSignatureMismatch;
                }
                if (parsed.return_ty != .void) {
                    return error.TestFuncSignatureMismatch;
                }
            }

            if (item.upstream_loc) |loc| {
                const file_copy = try allocator.dupe(u8, loc.file);
                errdefer allocator.free(file_copy);
                parsed.upstream_file = file_copy;
                parsed.upstream_loc = .{
                    .file = file_copy,
                    .line = loc.line,
                    .col = loc.col,
                };
            }
            if (parsed.params.len != 0) {
                const ids = try allocator.alloc(u32, parsed.params.len);
                errdefer allocator.free(ids);
                for (parsed.params, 0..) |param, idx| {
                    ids[idx] = try symbols.intern(param.name);
                    try addScopeReg(&current_reg_ids, &current_reg_seen, ids[idx]);
                }
                parsed.param_ids = ids;
            }
            _ = try symbols.intern(parsed.name);
            try sigs.append(parsed);
            const inserted_idx = sigs.items.len - 1;
            if (!sig_index_by_name.contains(parsed.name)) {
                try sig_index_by_name.put(parsed.name, inserted_idx);
            }
            try function_starts.append(inst_idx);
            current_sig_index = sigs.items.len - 1;
            continue;
        }

        for (item.operands) |operand| {
            if (operand == .reg) {
                try addScopeReg(&current_reg_ids, &current_reg_seen, operand.reg);
            }
        }

        if (parseInstructionCallForVerifier(allocator, &symbols, item)) |parsed0| {
            var parsed = parsed0;
            defer parsed.deinit(allocator);
            if (parsed.dest) |dest| {
                if (isIdentLike(dest)) {
                    if (symbols.findId(dest)) |id| {
                        try addScopeReg(&current_reg_ids, &current_reg_seen, id);
                    }
                }
            }
        } else |_| {}

        switch (item.kind) {
            .label => {
                _ = try symbols.intern(classified.parts[0]);
            },
            .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => unreachable,
            .alloc, .stack_alloc => {
                _ = try symbols.intern(classified.parts[0]);
            },
            .move_, .release, .raw_cast, .assume_safe, .assume_borrow => {
                _ = try symbols.intern(classified.parts[0]);
                if (classified.part_count > 1 and isIdentLike(classified.parts[1])) {
                    _ = try symbols.intern(classified.parts[1]);
                }
                if (classified.part_count > 2 and isIdentLike(classified.parts[2])) {
                    _ = try symbols.intern(classified.parts[2]);
                }
            },
            .assign => {
                _ = try symbols.intern(classified.parts[0]);
                if (item.operands[1] == .reg) {
                    _ = try symbols.intern(classified.parts[1]);
                }
            },
            .load, .take => {
                _ = try symbols.intern(classified.parts[0]);
                if (item.operands[1] == .reg) {
                    _ = try symbols.intern(classified.parts[1]);
                }
            },
            .ptr_add => {
                _ = try symbols.intern(classified.parts[0]);
                if (item.operands[1] == .reg) {
                    _ = try symbols.intern(classified.parts[1]);
                }
            },
            .atomic_load => {
                const parsed = try atomic.parseLoad(item.raw_text);
                _ = try symbols.intern(parsed.dst);
                if (isIdentLike(parsed.base)) _ = try symbols.intern(parsed.base);
            },
            .atomic_store => {
                const parsed = try atomic.parseStore(item.raw_text);
                if (isIdentLike(parsed.base)) _ = try symbols.intern(parsed.base);
            },
            .cmpxchg => {
                const parsed = try atomic.parseCmpxchg(item.raw_text);
                _ = try symbols.intern(parsed.dst);
                _ = try symbols.intern(parsed.ok);
                if (isIdentLike(parsed.base)) _ = try symbols.intern(parsed.base);
            },
            .atomic_rmw => {
                const parsed = try atomic.parseRmw(item.raw_text);
                _ = try symbols.intern(parsed.dst);
                if (isIdentLike(parsed.base)) _ = try symbols.intern(parsed.base);
            },
            .fence => {},
            .borrow => {
                _ = try symbols.intern(classified.parts[0]);
                if (isIdentLike(classified.parts[2])) _ = try symbols.intern(classified.parts[2]);
            },
            .store => {
                _ = try symbols.intern(classified.parts[0]);
                if (item.operands[2] == .text and isIdentLike(item.operands[2].text)) {
                    _ = try symbols.intern(classified.parts[2]);
                }
            },
            .op => {
                _ = try symbols.intern(classified.parts[0]);
                inline for ([_]usize{ 1, 2, 3 }) |op_idx| {
                    if (op_idx >= item.operands.len) break;
                    const part_idx = op_idx + 1;
                    if (part_idx >= classified.part_count) break;
                    switch (item.operands[op_idx]) {
                        .reg => _ = try symbols.intern(classified.parts[part_idx]),
                        .text => |text| {
                            if (isIdentLike(text)) _ = try symbols.intern(classified.parts[part_idx]);
                        },
                        else => {},
                    }
                }
            },
            .jmp => {
                _ = try symbols.intern(classified.parts[0]);
            },
            .br, .br_null => {
                if (isIdentLike(classified.parts[0])) _ = try symbols.intern(classified.parts[0]);
                if (isIdentLike(classified.parts[1])) _ = try symbols.intern(classified.parts[1]);
                if (isIdentLike(classified.parts[2])) _ = try symbols.intern(classified.parts[2]);
            },
            .try_, .early_return => {
                if (classified.part_count > 0 and isIdentLike(classified.parts[0])) _ = try symbols.intern(classified.parts[0]);
                if (classified.part_count > 1 and isIdentLike(classified.parts[1])) _ = try symbols.intern(classified.parts[1]);
            },
            .call, .call_indirect, .panic, .panic_msg, .return_, .native => {
                if (parseInstructionCallForVerifier(allocator, &symbols, item)) |parsed0| {
                    var parsed = parsed0;
                    defer parsed.deinit(allocator);
                    if (parsed.dest) |dest| {
                        if (isIdentLike(dest)) _ = try symbols.intern(dest);
                    }
                } else |_| {}
            },
        }
    }

    while (const_idx < const_decls.len) {
        const decl = const_decls[const_idx];
        if (decl.name.len != 0) {
            _ = try symbols.intern(decl.name);
        }
        const_idx += 1;
    }

    if (sigs.items.len != 0) {
        try finalizeFunctionScope(&sigs, &current_reg_ids, &current_reg_seen, const_decls, &symbols);
    }

    return .{
        .symbols = symbols,
        .sigs = sigs,
        .sig_index_by_name = sig_index_by_name,
        .const_vtables = try collectConstVtables(allocator, const_decls, sigs.items),
        .function_starts = function_starts,
    };
}

fn clonePredecodedFunctionSig(allocator: std.mem.Allocator, source: sig.FunctionSig) !sig.FunctionSig {
    const name = try allocator.dupe(u8, source.name);
    errdefer allocator.free(name);

    const params = try allocator.alloc(sig.ParamSpec, source.params.len);
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

    const param_ids = if (source.param_ids.len == 0) &.{} else try allocator.dupe(u32, source.param_ids);
    errdefer if (param_ids.len != 0) allocator.free(param_ids);
    const reg_ids = if (source.reg_ids.len == 0) &.{} else try allocator.dupe(u32, source.reg_ids);
    errdefer if (reg_ids.len != 0) allocator.free(reg_ids);

    const upstream_file = if (source.upstream_file) |file| try allocator.dupe(u8, file) else null;
    errdefer if (upstream_file) |file| allocator.free(file);
    var upstream_loc: ?upstream.UpstreamLoc = null;
    errdefer if (upstream_loc) |loc| allocator.free(loc.file);
    if (source.upstream_loc) |loc| {
        upstream_loc = .{ .file = try allocator.dupe(u8, loc.file), .line = loc.line, .col = loc.col };
    }
    const llvm_name = if (source.llvm_name) |nm| try allocator.dupe(u8, nm) else null;
    errdefer if (llvm_name) |nm| allocator.free(nm);

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
        .param_ids = param_ids,
        .reg_ids = reg_ids,
        .upstream_file = upstream_file,
        .upstream_loc = upstream_loc,
        .llvm_name = llvm_name,
        .ignored = source.ignored,
        .should_panic = source.should_panic,
    };
}

fn collectPredecodedMetadata(
    allocator: std.mem.Allocator,
    symbol_names: []const []const u8,
    function_sigs: []const sig.FunctionSig,
    const_decls: []const const_decl.ConstDecl,
) !CollectResult {
    var symbols = symbol.SymbolTable.init(allocator);
    errdefer symbols.deinit();
    for (symbol_names) |name| _ = try symbols.intern(name);

    var sigs = std.array_list.Managed(sig.FunctionSig).init(allocator);
    errdefer freeSigs(allocator, &sigs);
    var sig_index_by_name = std.StringHashMap(usize).init(allocator);
    errdefer sig_index_by_name.deinit();
    var function_starts = std.array_list.Managed(usize).init(allocator);
    errdefer function_starts.deinit();

    for (function_sigs) |source| {
        var cloned = try clonePredecodedFunctionSig(allocator, source);
        errdefer cloned.deinit(allocator);
        try sigs.append(cloned);
        const idx = sigs.items.len - 1;
        if (!sig_index_by_name.contains(cloned.name)) {
            try sig_index_by_name.put(cloned.name, idx);
        }
        try function_starts.append(cloned.entry_inst_idx);
    }

    return .{
        .symbols = symbols,
        .sigs = sigs,
        .sig_index_by_name = sig_index_by_name,
        .const_vtables = try collectConstVtables(allocator, const_decls, sigs.items),
        .function_starts = function_starts,
    };
}

fn metadataTrapKind(err: anyerror) trap.Trap {
    return switch (err) {
        error.UnsupportedType => .unsupported_type,
        error.OutOfMemory => .arena_oom,
        error.TestFuncSignatureMismatch => .test_func_signature_mismatch,
        error.InvalidAtomicOrdering => .invalid_atomic_ordering,
        error.VTableSignatureMismatch => .vtable_signature_mismatch,
        error.InvalidFunctionSig, error.InvalidAtomicSyntax => .forbidden_syntax,
        else => .import_resolution_failed,
    };
}

fn metadataTrapMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedType => "unsupported type annotation while rebuilding metadata",
        error.OutOfMemory => "out of memory while rebuilding metadata",
        error.TestFuncSignatureMismatch => "@test function must have signature () -> void",
        error.InvalidAtomicOrdering => "invalid atomic ordering while rebuilding metadata",
        error.VTableSignatureMismatch => "vtable slot method must take receiver by borrow (&self: ptr) for object safety",
        error.InvalidFunctionSig => "invalid function signature while rebuilding metadata",
        error.InvalidAtomicSyntax => "invalid atomic syntax while rebuilding metadata",
        else => "unclassified metadata rebuild error",
    };
}

fn metadataTrapHint(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.UnsupportedType => "check primitive type names in signatures and atomic suffixes",
        error.TestFuncSignatureMismatch => "test functions cannot have parameters and must return void",
        error.InvalidAtomicOrdering => "check success/failure ordering pairs and atomic ordering suffixes",
        error.VTableSignatureMismatch => "declare the method as (@name(&self: ptr) -> ...) so dyn dispatch borrows the receiver",
        error.InvalidFunctionSig => "check declaration spelling, parentheses, parameters, return arrow, and trailing colon",
        error.InvalidAtomicSyntax => "check atomic instruction spelling, destination registers, address, value, and ordering fields",
        error.OutOfMemory => null,
        else => "metadata collection returned an unclassified error; inspect the declaration or instruction at this source location",
    };
}

fn isStackAllocated(flags: []const u8, origins: []const ?u32, state: []const u16, id: u32) bool {
    const idx: usize = @intCast(id);
    if ((flags[idx] & regFlagStackAlloc) != 0) return true;
    if ((state[idx] & maskOf(.borrow_view)) != 0) {
        if (origins[idx]) |origin| {
            const origin_idx: usize = @intCast(origin);
            if (origin_idx >= flags.len) return false;
            return (flags[origin_idx] & regFlagStackAlloc) != 0;
        }
    }
    return false;
}

fn readCheck(
    item: inst.Instruction,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
    name: []const u8,
    id: u32,
    state: []u16,
    flags: []u8,
) ?VerifyBodyResult {
    _ = flags;
    const idx: usize = @intCast(id);
    const current = state[idx];
    if (current == 0) return trapReport(.unknown_register, item, function_text, is_ffi_wrapper, name, null, null, "register is not declared in the current scope", null);
    if ((current & maskOf(.consumed)) != 0) return trapReport(.use_after_move, item, function_text, is_ffi_wrapper, name, maskOf(.consumed), current, "moved value is no longer usable", null);
    if ((current & maskOf(.locked_mut)) != 0 and (current & maskOf(.borrow_view)) == 0) {
        return trapReport(.borrow_conflict, item, function_text, is_ffi_wrapper, name, maskOf(.active), current, "borrow rules reject this access", null);
    }
    return null;
}

fn writeCheck(
    item: inst.Instruction,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
    name: []const u8,
    id: u32,
    state: []u16,
    flags: []u8,
    origins: []?u32,
    locks: []u16,
) ?VerifyBodyResult {
    const idx: usize = @intCast(id);
    const current = state[idx];
    if (current == 0) return trapReport(.unknown_register, item, function_text, is_ffi_wrapper, name, null, null, "register is not declared in the current scope", null);
    if ((current & maskOf(.consumed)) != 0) return trapReport(.use_after_move, item, function_text, is_ffi_wrapper, name, maskOf(.consumed), current, "moved value is no longer usable", null);
    if (isImmutableConst(state, flags, id)) {
        return constTrap(item, function_text, is_ffi_wrapper, name, current, "immutable registers cannot be written, moved, or exclusively borrowed");
    }
    if ((current & maskOf(.borrow_view)) != 0) {
        const origin_id = origins[idx] orelse return trapReport(.borrow_conflict, item, function_text, is_ffi_wrapper, name, maskOf(.active), current, "borrow rules reject this access", null);
        const origin_idx: usize = @intCast(origin_id);
        if (origin_idx >= locks.len) return trapReport(.unknown_register, item, function_text, is_ffi_wrapper, name, null, null, "register is not declared in the current scope", null);
        if (locks[origin_idx] > 1) {
            return trapReport(.read_write_conflict, item, function_text, is_ffi_wrapper, name, maskOf(.active), current, "cannot write through a shared borrow", null);
        }
    } else if ((current & maskOf(.locked_read)) != 0) {
        return trapReport(.read_write_conflict, item, function_text, is_ffi_wrapper, name, maskOf(.active), current, "cannot write through a shared borrow", null);
    }
    if ((current & maskOf(.locked_mut)) != 0 and (current & maskOf(.borrow_view)) == 0) {
        return trapReport(.borrow_conflict, item, function_text, is_ffi_wrapper, name, maskOf(.active), current, "borrow rules reject this access", null);
    }
    return null;
}

fn assignValueCtx(
    item: inst.Instruction,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
    name: []const u8,
    id: u32,
    state: []u16,
    flags: []u8,
    mask: u16,
    interior: *InteriorContext,
) ?VerifyBodyResult {
    const idx: usize = @intCast(id);
    if (idx >= state.len) {
        return trapReport(.unknown_register, item, function_text, is_ffi_wrapper, name, null, null, "register is not declared in the current scope", null);
    }
    const current = state[idx];
    if (current != 0 and (current & maskOf(.consumed)) == 0 and (current & maskOf(.untracked)) == 0 and (flags[idx] & regFlagEphemeralScalar) == 0 and (flags[idx] & regFlagRawPointer) == 0) {
        return trapReport(.register_redefinition, item, function_text, is_ffi_wrapper, name, null, null, "register is already live", null);
    }
    if (hasInteriorPtr(current) or interior.interior_first_child[idx] != null) {
        consumeInteriorValue(interior.state, interior.interior_parent, interior.interior_first_child, interior.interior_next_sibling, id);
    } else {
        clearInteriorNode(interior.state, interior.interior_parent, interior.interior_first_child, interior.interior_next_sibling, id);
    }
    clearInteriorOffsetMeta(interior, id);
    clearAllocSizeMeta(interior, id);
    state[idx] = mask;
    flags[idx] &= ~(regFlagBranchCondition | regFlagEphemeralScalar);
    return null;
}

fn assignValue(
    item: inst.Instruction,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
    name: []const u8,
    id: u32,
    state: []u16,
    flags: []u8,
    mask: u16,
    interior: *InteriorContext,
) ?VerifyBodyResult {
    return assignValueCtx(item, function_text, is_ffi_wrapper, name, id, state, flags, mask, interior);
}

fn consumeSourceValueCtx(
    item: inst.Instruction,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
    name: []const u8,
    id: u32,
    state: []u16,
    flags: []u8,
    origins: []?u32,
    locks: []u16,
    interior_parent: []?u32,
    interior_first_child: []?u32,
    interior_next_sibling: []?u32,
    allow_const_copy: bool,
    interior: *InteriorContext,
) ?VerifyBodyResult {
    const idx: usize = @intCast(id);
    if (allow_const_copy and isImmutableConst(state, flags, id)) return null;
    if (isImmutableConst(state, flags, id)) {
        return constTrap(item, function_text, is_ffi_wrapper, name, state[idx], "immutable registers cannot be moved");
    }
    if (isStackAllocated(flags, origins, state, id)) {
        return trapReport(.stack_escape, item, function_text, is_ffi_wrapper, name, maskOf(.active), state[idx], "stack allocation cannot be moved out of its function", null);
    }
    if ((flags[idx] & regFlagRawPointer) != 0) return null;
    if ((state[idx] & maskOf(.borrow_view)) != 0) {
        clearBorrowCtx(state, flags, origins, locks, id, interior);
    } else {
        if (hasInteriorTree(state, interior_first_child, id)) {
            consumeInteriorValue(state, interior_parent, interior_first_child, interior_next_sibling, id);
        } else {
            state[idx] = maskOf(.consumed);
        }
    }
    return null;
}

fn consumeSourceValue(
    item: inst.Instruction,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
    name: []const u8,
    id: u32,
    state: []u16,
    flags: []u8,
    origins: []?u32,
    locks: []u16,
    interior_parent: []?u32,
    interior_first_child: []?u32,
    interior_next_sibling: []?u32,
    allow_const_copy: bool,
    interior: *InteriorContext,
) ?VerifyBodyResult {
    return consumeSourceValueCtx(item, function_text, is_ffi_wrapper, name, id, state, flags, origins, locks, interior_parent, interior_first_child, interior_next_sibling, allow_const_copy, interior);
}

fn setBorrowState(state: []u16, flags: []u8, origins: []?u32, locks: []u16, dst: u32, src: u32, is_mut: bool, is_ffi: bool) void {
    const dst_idx: usize = @intCast(dst);
    const src_idx: usize = @intCast(src);
    state[dst_idx] = maskOf(.active) | maskOf(.borrow_view) | (if (is_ffi) (if (is_mut) maskOf(.locked_mut) else maskOf(.locked_read)) | maskOf(.ffi_borrow) else 0);
    flags[dst_idx] = if (is_ffi) 0x01 else 0x00;
    origins[dst_idx] = src;
    locks[src_idx] += 1;
    if (is_mut) {
        if (state[src_idx] == maskOf(.active)) state[src_idx] = maskOf(.locked_mut);
    } else {
        if (state[src_idx] == maskOf(.active)) state[src_idx] = maskOf(.locked_read);
    }
}

fn clearBorrowCtx(
    state: []u16,
    flags: []u8,
    origins: []?u32,
    locks: []u16,
    id: u32,
    interior: *InteriorContext,
) void {
    const idx: usize = @intCast(id);
    if ((state[idx] & maskOf(.borrow_view)) == 0) return;

    if (hasInteriorPtr(state[idx])) {
        consumeInteriorValue(interior.state, interior.interior_parent, interior.interior_first_child, interior.interior_next_sibling, id);
    } else {
        consumeInteriorChildren(interior.state, interior.interior_parent, interior.interior_first_child, interior.interior_next_sibling, id);
    }

    if ((flags[idx] & regFlagRawPointer) != 0) {
        state[idx] = 0;
        flags[idx] = 0;
        origins[idx] = null;
        return;
    }
    const origin = origins[idx] orelse {
        state[idx] = 0;
        flags[idx] = 0;
        return;
    };
    const origin_idx: usize = @intCast(origin);
    if (origin_idx >= locks.len) {
        state[idx] = 0;
        flags[idx] = 0;
        origins[idx] = null;
        return;
    }
    if (locks[origin_idx] > 0) {
        locks[origin_idx] -= 1;
        if (locks[origin_idx] == 0) {
            state[origin_idx] = if (isImmutableConst(state, flags, origin)) maskOf(.active) | maskOf(.immutable) else maskOf(.active);
        }
    }
    state[idx] = 0;
    flags[idx] = 0;
    origins[idx] = null;
}

fn clearBorrow(
    state: []u16,
    flags: []u8,
    origins: []?u32,
    locks: []u16,
    id: u32,
    interior: *InteriorContext,
) void {
    clearBorrowCtx(state, flags, origins, locks, id, interior);
}

fn consumeAtContractBoundaryCtx(
    item: inst.Instruction,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
    name: []const u8,
    id: u32,
    state: []u16,
    flags: []u8,
    origins: []?u32,
    locks: []u16,
    interior_parent: []?u32,
    interior_first_child: []?u32,
    interior_next_sibling: []?u32,
    interior: *InteriorContext,
) ?VerifyBodyResult {
    if (readCheck(item, function_text, is_ffi_wrapper, name, id, state, flags)) |tr| return tr;

    const idx: usize = @intCast(id);
    if (hasActiveBorrowRefs(locks, id)) {
        return trapReport(.borrow_conflict, item, function_text, is_ffi_wrapper, name, maskOf(.active), state[idx], "borrow rules reject this access", null);
    }
    if (isStackAllocated(flags, origins, state, id)) {
        return trapReport(.stack_escape, item, function_text, is_ffi_wrapper, name, maskOf(.active), state[idx], "stack allocation cannot cross a native escape boundary", null);
    }

    if ((state[idx] & maskOf(.borrow_view)) != 0) {
        clearBorrowCtx(state, flags, origins, locks, id, interior);
    } else if (hasInteriorTree(state, interior_first_child, id)) {
        consumeInteriorValue(state, interior_parent, interior_first_child, interior_next_sibling, id);
    } else {
        state[idx] = maskOf(.consumed);
    }
    return null;
}

fn consumeAtContractBoundary(
    item: inst.Instruction,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
    name: []const u8,
    id: u32,
    state: []u16,
    flags: []u8,
    origins: []?u32,
    locks: []u16,
    interior_parent: []?u32,
    interior_first_child: []?u32,
    interior_next_sibling: []?u32,
    interior: *InteriorContext,
) ?VerifyBodyResult {
    return consumeAtContractBoundaryCtx(item, function_text, is_ffi_wrapper, name, id, state, flags, origins, locks, interior_parent, interior_first_child, interior_next_sibling, interior);
}

fn markBranchCondition(flags: []u8, id: u32) void {
    flags[@intCast(id)] |= regFlagBranchCondition;
}

fn updateLabel(
    item: inst.Instruction,
    labels: *std.AutoHashMap(u32, LabelSnapshot),
    state: []u16,
    origins: []?u32,
    locks: []u16,
    flags: []u8,
    interior_parent: []?u32,
    interior_first_child: []?u32,
    interior_next_sibling: []?u32,
    interior_root: []?u32,
    interior_offset: []u64,
    interior_offset_known: []bool,
    alloc_size: []u64,
    alloc_size_known: []bool,
    allocator: std.mem.Allocator,
    function_text: ?[]const u8,
    is_ffi_wrapper: bool,
) ?VerifyBodyResult {
    const label_id = item.operands[1].label;
    if (labels.getPtr(label_id)) |entry| {
        restoreLabelSnapshot(entry, state, origins, locks, flags, interior_parent, interior_first_child, interior_next_sibling, interior_root, interior_offset, interior_offset_known, alloc_size, alloc_size_known);
        return null;
    }
    var dup = captureLabelSnapshot(allocator, state, origins, locks, flags, interior_parent, interior_first_child, interior_next_sibling, interior_root, interior_offset, interior_offset_known, alloc_size, alloc_size_known) catch {
        return trapReport(.arena_oom, item, function_text, is_ffi_wrapper, null, null, null, "unable to record label state", null);
    };
    labels.put(label_id, dup) catch {
        dup.deinit(allocator);
        return trapReport(.arena_oom, item, function_text, is_ffi_wrapper, null, null, null, "unable to record label state", null);
    };
    return null;
}

fn freeSigs(allocator: std.mem.Allocator, sigs: *std.array_list.Managed(sig.FunctionSig)) void {
    for (sigs.items) |*item| item.deinit(allocator);
    sigs.deinit();
}

fn freeConstVtables(allocator: std.mem.Allocator, const_vtables: *std.array_list.Managed(ConstVTable)) void {
    for (const_vtables.items) |*item| item.deinit(allocator);
    const_vtables.deinit();
}

fn freeFunctionStarts(starts: *std.array_list.Managed(usize)) void {
    starts.deinit();
}

fn freeAnnotated(allocator: std.mem.Allocator, annotated: *std.array_list.Managed(AnnotatedInstruction)) void {
    for (annotated.items) |item| {
        var owned = item;
        owned.deinit(allocator);
    }
    annotated.deinit();
}

fn diffState(allocator: std.mem.Allocator, before: []const u16, after: []const u16) !RegStateDelta {
    if (before.len != after.len) return error.InvalidOperand;

    var change_count: usize = 0;
    for (before, after) |prev, next| {
        if (next != prev) change_count += 1;
    }
    if (change_count == 0) return emptyRegStateDelta();

    var changes = try allocator.alloc(RegStateChange, change_count);
    var out_idx: usize = 0;
    errdefer allocator.free(changes);
    for (before, after, 0..) |prev, next, idx| {
        if (next == prev) continue;
        changes[out_idx] = .{ .reg = @intCast(idx), .before = prev, .after = next };
        out_idx += 1;
    }
    return .{ .changes = changes };
}

fn applyStateDelta(state: []u16, delta: []const RegStateChange) void {
    for (delta) |change| {
        state[change.reg] = change.after;
    }
}

fn resetLabels(allocator: std.mem.Allocator, labels: *std.AutoHashMap(u32, LabelSnapshot)) void {
    var it = labels.iterator();
    while (it.next()) |entry| entry.value_ptr.deinit(allocator);
    labels.clearRetainingCapacity();
}

const VerifierBufferPool = struct {
    allocator: std.mem.Allocator,
    state: []u16 = &.{},
    flags: []u8 = &.{},
    origins: []?u32 = &.{},
    locks: []u16 = &.{},
    consumed_in_function: []bool = &.{},
    interior_parent: []?u32 = &.{},
    interior_first_child: []?u32 = &.{},
    interior_next_sibling: []?u32 = &.{},
    interior_root: []?u32 = &.{},
    interior_offset: []u64 = &.{},
    interior_offset_known: []bool = &.{},
    alloc_size: []u64 = &.{},
    alloc_size_known: []bool = &.{},

    fn init(allocator: std.mem.Allocator) VerifierBufferPool {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *VerifierBufferPool) void {
        const allocator = self.allocator;
        if (self.state.len != 0) self.allocator.free(self.state);
        if (self.flags.len != 0) self.allocator.free(self.flags);
        if (self.origins.len != 0) self.allocator.free(self.origins);
        if (self.locks.len != 0) self.allocator.free(self.locks);
        if (self.consumed_in_function.len != 0) self.allocator.free(self.consumed_in_function);
        if (self.interior_parent.len != 0) self.allocator.free(self.interior_parent);
        if (self.interior_first_child.len != 0) self.allocator.free(self.interior_first_child);
        if (self.interior_next_sibling.len != 0) self.allocator.free(self.interior_next_sibling);
        if (self.interior_root.len != 0) self.allocator.free(self.interior_root);
        if (self.interior_offset.len != 0) self.allocator.free(self.interior_offset);
        if (self.interior_offset_known.len != 0) self.allocator.free(self.interior_offset_known);
        if (self.alloc_size.len != 0) self.allocator.free(self.alloc_size);
        if (self.alloc_size_known.len != 0) self.allocator.free(self.alloc_size_known);
        self.* = .{ .allocator = allocator };
    }

    fn ensureCapacity(self: *VerifierBufferPool, reg_count: usize) !void {
        if (self.state.len >= reg_count) return;

        var next = VerifierBufferPool.init(self.allocator);
        errdefer next.deinit();
        next.state = try self.allocator.alloc(u16, reg_count);
        next.flags = try self.allocator.alloc(u8, reg_count);
        next.origins = try self.allocator.alloc(?u32, reg_count);
        next.locks = try self.allocator.alloc(u16, reg_count);
        next.consumed_in_function = try self.allocator.alloc(bool, reg_count);
        next.interior_parent = try self.allocator.alloc(?u32, reg_count);
        next.interior_first_child = try self.allocator.alloc(?u32, reg_count);
        next.interior_next_sibling = try self.allocator.alloc(?u32, reg_count);
        next.interior_root = try self.allocator.alloc(?u32, reg_count);
        next.interior_offset = try self.allocator.alloc(u64, reg_count);
        next.interior_offset_known = try self.allocator.alloc(bool, reg_count);
        next.alloc_size = try self.allocator.alloc(u64, reg_count);
        next.alloc_size_known = try self.allocator.alloc(bool, reg_count);

        self.deinit();
        self.* = next;
    }
};

fn verifyBody(
    allocator: std.mem.Allocator,
    instructions: []const inst.Instruction,
    classified_lines: []const classifier.ClassifiedLine,
    const_decls: []const const_decl.ConstDecl,
    metadata: *const CollectResult,
    sig_index_start: usize,
    check_exit_leaks: bool,
    package_grants: []const pkg_manifest.RequireEntry,
    sax_context: ?SaxValidationContext,
    default_immutable: bool,
    rust_strict_mut: bool,
    rust_copy_elision: bool,
) !VerifyBodyResult {
    std.debug.assert(classified_lines.len == instructions.len);
    var sig_index = sig_index_start;
    var state: []u16 = &.{};
    var flags: []u8 = &.{};
    var origins: []?u32 = &.{};
    var locks: []u16 = &.{};
    var consumed_in_function: []bool = &.{};
    var interior_parent: []?u32 = &.{};
    var interior_first_child: []?u32 = &.{};
    var interior_next_sibling: []?u32 = &.{};
    var interior_root: []?u32 = &.{};
    var interior_offset: []u64 = &.{};
    var interior_offset_known: []bool = &.{};
    var alloc_size: []u64 = &.{};
    var alloc_size_known: []bool = &.{};
    var buffers = VerifierBufferPool.init(allocator);
    defer buffers.deinit();
    var current_scope: ?FunctionRegScope = null;
    defer {
        if (current_scope) |*scope| scope.deinit();
    }
    var interior = InteriorContext{
        .state = state,
        .interior_parent = interior_parent,
        .interior_first_child = interior_first_child,
        .interior_next_sibling = interior_next_sibling,
        .interior_root = interior_root,
        .interior_offset = interior_offset,
        .interior_offset_known = interior_offset_known,
        .alloc_size = alloc_size,
        .alloc_size_known = alloc_size_known,
    };
    var atomic_history = std.AutoHashMap(u64, u8).init(allocator);
    defer atomic_history.deinit();

    var labels = std.AutoHashMap(u32, LabelSnapshot).init(allocator);
    defer {
        var it = labels.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(allocator);
        labels.deinit();
    }
    var defined_labels = std.AutoHashMap(u32, void).init(allocator);
    defer defined_labels.deinit();

    var annotated = std.array_list.Managed(AnnotatedInstruction).init(allocator);
    var completed = false;
    defer {
        if (!completed) {
            freeAnnotated(allocator, &annotated);
        }
    }

    var current_function_text: ?[]const u8 = null;
    var current_is_ffi_wrapper = false;
    var current_sig: ?sig.FunctionSig = null;
    var body_seen = false;
    var terminated = false;
    var fatal_terminated = false;
    var gas_alloc_bytes: u64 = 0;
    var gas_steps: u64 = 0;
    const call_depth: u16 = 0;
    var has_unbounded_loop = false;
    var last_seen_label: ?u32 = null;

    for (instructions, 0..) |raw_item, inst_idx| {
        var item = raw_item;
        const classified = classified_lines[inst_idx];

        if (isDecl(item.kind)) {
            if (body_seen and !terminated and current_function_text != null) {
                return trapReport(.fallthrough_forbidden, item, current_function_text, current_is_ffi_wrapper, null, null, null, "basic blocks must end with jmp, br, br_null, or return", "insert an explicit terminator before the next declaration");
            }

            current_function_text = item.raw_text;
            current_is_ffi_wrapper = item.kind == .ffi_wrapper_decl;
            last_seen_label = null;
            terminated = false;
            fatal_terminated = false;
            body_seen = false;
            resetLabels(allocator, &labels);

            if (sig_index < metadata.sigs.items.len) {
                current_sig = metadata.sigs.items[sig_index];
                sig_index += 1;
            } else {
                current_sig = null;
            }

            if (current_scope) |*scope| scope.deinit();
            current_scope = null;
            state = &.{};
            flags = &.{};
            origins = &.{};
            locks = &.{};
            consumed_in_function = &.{};
            interior_parent = &.{};
            interior_first_child = &.{};
            interior_next_sibling = &.{};
            interior_root = &.{};
            interior_offset = &.{};
            interior_offset_known = &.{};
            alloc_size = &.{};
            alloc_size_known = &.{};

            if (current_sig) |decl_sig| {
                var next_scope = try FunctionRegScope.initBorrowed(allocator, decl_sig.reg_ids);
                errdefer next_scope.deinit();
                const reg_count = next_scope.reg_ids.len;
                buffers.ensureCapacity(reg_count) catch {
                    current_scope = null;
                    return .{ .trap = trapReportFromText(.arena_oom, 1, 1, item.raw_text, "unable to allocate verifier state", null) };
                };
                state = buffers.state[0..reg_count];
                @memset(state, 0);
                flags = buffers.flags[0..reg_count];
                @memset(flags, 0);
                origins = buffers.origins[0..reg_count];
                @memset(origins, null);
                locks = buffers.locks[0..reg_count];
                @memset(locks, 0);
                consumed_in_function = buffers.consumed_in_function[0..reg_count];
                @memset(consumed_in_function, false);
                interior_parent = buffers.interior_parent[0..reg_count];
                @memset(interior_parent, null);
                interior_first_child = buffers.interior_first_child[0..reg_count];
                @memset(interior_first_child, null);
                interior_next_sibling = buffers.interior_next_sibling[0..reg_count];
                @memset(interior_next_sibling, null);
                interior_root = buffers.interior_root[0..reg_count];
                @memset(interior_root, null);
                interior_offset = buffers.interior_offset[0..reg_count];
                @memset(interior_offset, 0);
                interior_offset_known = buffers.interior_offset_known[0..reg_count];
                @memset(interior_offset_known, false);
                alloc_size = buffers.alloc_size[0..reg_count];
                @memset(alloc_size, 0);
                alloc_size_known = buffers.alloc_size_known[0..reg_count];
                @memset(alloc_size_known, false);
                interior = .{
                    .state = state,
                    .interior_parent = interior_parent,
                    .interior_first_child = interior_first_child,
                    .interior_next_sibling = interior_next_sibling,
                    .interior_root = interior_root,
                    .interior_offset = interior_offset,
                    .interior_offset_known = interior_offset_known,
                    .alloc_size = alloc_size,
                    .alloc_size_known = alloc_size_known,
                };
                current_scope = next_scope;
                computeFunctionConsumedRegs(allocator, instructions, inst_idx, &metadata.symbols, &current_scope.?, consumed_in_function);
                errdefer {
                    if (current_scope) |*scope| scope.deinit();
                    current_scope = null;
                }

                // A corrupted artifact (e.g. a hand-edited or truncated .sab) may carry
                // a signature whose param_ids do not line up with its params or whose
                // param register ids are not declared in the function scope. Both
                // are reported as structured traps; the old `orelse unreachable`
                // panicked and the bare `param_ids[pidx]` indexing could read out
                // of bounds.
                if (decl_sig.param_ids.len < decl_sig.params.len) {
                    return trapReport(
                        .corrupted_signature,
                        item,
                        current_function_text,
                        current_is_ffi_wrapper,
                        null,
                        null,
                        null,
                        "corrupted function signature: parameter count exceeds param_ids count",
                        "rebuild the module from source; the artifact's signature metadata is inconsistent",
                    );
                }
                for (decl_sig.params, 0..) |param, pidx| {
                    const reg_id = decl_sig.param_ids[pidx];
                    const reg_slot = current_scope.?.slotOf(reg_id) orelse {
                        return trapReport(
                            .corrupted_signature,
                            item,
                            current_function_text,
                            current_is_ffi_wrapper,
                            param.name,
                            null,
                            null,
                            "corrupted function signature: parameter references a register id that is not declared in this function scope",
                            "rebuild the module from source; the artifact's param_ids are inconsistent with its register scope",
                        );
                    };
                    const reg_idx: usize = @intCast(reg_slot);
                    state[reg_idx] = switch (param.cap) {
                        .by_value, .move => maskOf(.active),
                        .borrow => maskOf(.active) | maskOf(.borrow_view) | maskOf(.locked_read),
                        .raw => maskOf(.untracked),
                    };
                    flags[reg_idx] = if (param.cap == .raw) regFlagRawPointer else 0;
                    if (param.cap == .borrow) {
                        origins[reg_idx] = reg_slot;
                        locks[reg_idx] = 1;
                    }
                }
            } else {
                current_scope = null;
            }

            atomic_history.clearRetainingCapacity();
            defined_labels.clearRetainingCapacity();
            if (current_scope) |scope| {
                seedConstSymbols(state, flags, &scope, &metadata.symbols, const_decls);
            }

            try annotated.append(.{
                .base = item,
                .delta = .{ .changes = &.{} },
                .gas_step_cost = 0,
            });
            continue;
        }

        if (fatal_terminated and item.kind != .label) {
            continue;
        }

        if (terminated) {
            if (!isDecl(item.kind) and item.kind != .label) {
                return trapReport(.fallthrough_forbidden, item, current_function_text, current_is_ffi_wrapper, null, null, null, "basic blocks must end with jmp, br, br_null, or return", "insert an explicit terminator before the next declaration");
            }
            terminated = false;
            fatal_terminated = false;
        }

        if (current_scope) |*scope| {
            if (localizeInstructionRegs(&item, scope, &metadata.symbols, current_function_text, current_is_ffi_wrapper)) |tr| {
                return tr;
            }
        }

        if (item.kind == .label) {
            last_seen_label = item.operands[1].label;
            if (defined_labels.contains(item.operands[1].label)) {
                return trapReport(.duplicate_label, item, current_function_text, current_is_ffi_wrapper, null, null, null, "label is already defined", "rename the label or merge the blocks");
            }
            if (updateLabel(item, &labels, state, origins, locks, flags, interior_parent, interior_first_child, interior_next_sibling, interior_root, interior_offset, interior_offset_known, alloc_size, alloc_size_known, allocator, current_function_text, current_is_ffi_wrapper)) |tr| {
                return tr;
            }
            defined_labels.put(item.operands[1].label, {}) catch {
                return trapReport(.arena_oom, item, current_function_text, current_is_ffi_wrapper, null, null, null, "unable to record label definition", null);
            };
            try annotated.append(.{
                .base = item,
                .delta = .{ .changes = &.{} },
                .gas_step_cost = 0,
            });
            continue;
        }

        if (!isExecKind(item.kind)) {
            try annotated.append(.{
                .base = item,
                .delta = .{ .changes = &.{} },
                .gas_step_cost = 0,
            });
            continue;
        }

        body_seen = true;
        gas_steps += 1;
        const snapshot_before = try allocator.dupe(u16, state);
        defer allocator.free(snapshot_before);

        switch (item.kind) {
            .alloc => {
                // sci-rust: explicit `mut x = alloc` (operands[2]=="mut") opts
                // out even under --default-immutable; otherwise the edition
                // default applies.
                const explicit_mut = item.operands[2] == .text and std.mem.eql(u8, item.operands[2].text, "mut");
                const alloc_mask: u16 = if (explicit_mut) maskOf(.active) else if (default_immutable) maskOf(.active) | maskOf(.immutable) else maskOf(.active);
                if (assignValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags, alloc_mask, &interior)) |tr| return tr;
                flags[@intCast(item.operands[0].reg)] = 0;
                recordAllocSize(&interior, item.operands[0].reg, parseAllocSizeOperand(item.operands[1]));
                gas_alloc_bytes += switch (item.operands[1]) {
                    .imm_u64 => |v| v,
                    .imm_i64 => |v| if (v > 0) @as(u64, @intCast(v)) else 0,
                    .text => |t| std.fmt.parseInt(u64, t, 10) catch 0,
                    else => 0,
                };
            },
            .stack_alloc => {
                const explicit_mut = item.operands[2] == .text and std.mem.eql(u8, item.operands[2].text, "mut");
                const alloc_mask: u16 = if (explicit_mut) maskOf(.active) else if (default_immutable) maskOf(.active) | maskOf(.immutable) else maskOf(.active);
                if (assignValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags, alloc_mask, &interior)) |tr| return tr;
                flags[@intCast(item.operands[0].reg)] = regFlagStackAlloc;
                recordAllocSize(&interior, item.operands[0].reg, parseAllocSizeOperand(item.operands[1]));
                gas_alloc_bytes += switch (item.operands[1]) {
                    .imm_u64 => |v| v,
                    .imm_i64 => |v| if (v > 0) @as(u64, @intCast(v)) else 0,
                    .text => |t| std.fmt.parseInt(u64, t, 10) catch 0,
                    else => 0,
                };
            },
            .load, .take => {
                if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[1], item.operands[1].reg, state, flags)) |tr| return tr;
                if (checkStaticOffsetInBounds(item, current_function_text, current_is_ffi_wrapper, classified.parts[1], &interior, origins, state, item.operands[1].reg, staticByteOffset(item.operands[2]))) |tr| return tr;
                const loaded_ty: sig.PrimType = if (item.operands[3] == .ty) blk: {
                    break :blk sig.primTypeFromTag(item.operands[3].ty) orelse if (item.kind == .take) .ptr else .i64;
                } else if (item.kind == .take) .ptr else .i64;
                const source_idx: usize = @intCast(item.operands[1].reg);
                const source_mask = state[source_idx];
                const load_is_borrowed_ptr =
                    loaded_ty == .ptr and
                    ((source_mask & (maskOf(.borrow_view) | maskOf(.ffi_borrow))) != 0);
                // sci-rust: under --default-immutable, values loaded from an
                // immutable source inherit Active|Immutable.
                const load_inherits_immutable = default_immutable and isImmutableConst(state, flags, item.operands[1].reg);
                const new_mask = maskOf(.active) | if (load_is_borrowed_ptr) maskOf(.interior_ptr) else 0 | if (load_inherits_immutable) maskOf(.immutable) else 0;
                if (assignValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags, new_mask, &interior)) |tr| return tr;
                flags[@intCast(item.operands[0].reg)] = if (item.kind == .load) (if (loaded_ty == .ptr) regFlagRawPointer else regFlagEphemeralScalar) else 0;
                if (item.kind == .take and ((source_mask & (maskOf(.borrow_view) | maskOf(.ffi_borrow) | maskOf(.interior_ptr))) != 0 or hasInteriorTree(state, interior_first_child, item.operands[1].reg))) {
                    attachInteriorChild(state, interior_parent, interior_first_child, interior_next_sibling, item.operands[1].reg, item.operands[0].reg);
                    setInteriorOffsetFromBase(&interior, item.operands[1].reg, item.operands[0].reg, staticByteOffset(item.operands[2]));
                }
            },
            .store => {
                if (sax_context) |ctx| {
                    const trimmed = std.mem.trim(u8, item.raw_text, " \t\r");
                    if (std.mem.startsWith(u8, trimmed, "store state+") and !current_is_ffi_wrapper) {
                        return saxReport(ctx, .sax_state_write_from_outside, item, classified.parts[0], null, null, "state slot written from outside component", null);
                    }
                }
                if (writeCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags, origins, locks)) |tr| return tr;
                if (checkStaticOffsetInBounds(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], &interior, origins, state, item.operands[0].reg, staticByteOffset(item.operands[1]))) |tr| return tr;
                const dst_idx: usize = @intCast(item.operands[0].reg);
                if ((state[dst_idx] & maskOf(.borrow_view)) != 0) {
                    const origin_id = origins[dst_idx] orelse unreachable;
                    const origin_idx: usize = @intCast(origin_id);
                    if (origin_idx < state.len and state[origin_idx] == maskOf(.locked_read)) {
                        // sci-rust: under --rust-strict-mut, writing through a
                        // shared borrow is rejected; use `&mut` explicitly.
                        if (rust_strict_mut) {
                            return trapReport(.read_write_conflict, item, current_function_text, current_is_ffi_wrapper, classified.parts[0], maskOf(.active), state[origin_idx], "rust edition: writing through a shared (&) borrow requires an explicit &mut borrow", "borrow with `r = &mut x` or `r = borrow mut x`");
                        }
                        state[origin_idx] = maskOf(.locked_mut);
                    }
                }
                if (item.operands[2] == .text and isIdentLike(item.operands[2].text)) {
                    if (current_scope) |scope| {
                        if (resolveScopedRegId(&scope, &metadata.symbols, item.operands[2].text)) |value_id| {
                            if (readCheck(item, current_function_text, current_is_ffi_wrapper, item.operands[2].text, value_id, state, flags)) |tr| return tr;
                        }
                    }
                }
            },
            .atomic_load => {
                if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[1], item.operands[1].reg, state, flags)) |tr| return tr;
                if (assignValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags, maskOf(.untracked), &interior)) |tr| return tr;
                flags[@intCast(item.operands[0].reg)] = regFlagEphemeralScalar;
            },
            .atomic_store => {
                if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[1], item.operands[0].reg, state, flags)) |tr| return tr;
                if (item.operands[2] == .text and isIdentLike(item.operands[2].text)) {
                    if (current_scope) |scope| {
                        if (resolveScopedRegId(&scope, &metadata.symbols, item.operands[2].text)) |value_id| {
                            if (readCheck(item, current_function_text, current_is_ffi_wrapper, item.operands[2].text, value_id, state, flags)) |tr| return tr;
                        }
                    }
                }
            },
            .cmpxchg => {
                if (checkAtomicOrdering(item, current_function_text, current_is_ffi_wrapper, &atomic_history)) |tr| return tr;
                if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[1], item.operands[2].reg, state, flags)) |tr| return tr;
                if (item.operands[3] == .imm_u64) {
                    _ = item.operands[3].imm_u64;
                }
                if (assignValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags, maskOf(.active), &interior)) |tr| return tr;
                if (assignValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[1], item.operands[1].reg, state, flags, maskOf(.active), &interior)) |tr| return tr;
                flags[@intCast(item.operands[0].reg)] = 0;
                flags[@intCast(item.operands[1].reg)] = 0;
            },
            .atomic_rmw => {
                if (checkAtomicOrdering(item, current_function_text, current_is_ffi_wrapper, &atomic_history)) |tr| return tr;
                if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[1], item.operands[1].reg, state, flags)) |tr| return tr;
                if (item.operands[3] == .text and isIdentLike(item.operands[3].text)) {
                    if (current_scope) |scope| {
                        if (resolveScopedRegId(&scope, &metadata.symbols, item.operands[3].text)) |value_id| {
                            if (readCheck(item, current_function_text, current_is_ffi_wrapper, item.operands[3].text, value_id, state, flags)) |tr| return tr;
                        }
                    }
                }
                if (assignValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags, maskOf(.active), &interior)) |tr| return tr;
                flags[@intCast(item.operands[0].reg)] = regFlagEphemeralScalar;
            },
            .fence => {},
            .op => {
                inline for ([_]usize{ 1, 2, 3 }) |op_idx| {
                    if (op_idx >= item.operands.len) break;
                    const part_idx = op_idx + 1;
                    if (part_idx >= classified.part_count) break;
                    switch (item.operands[op_idx]) {
                        .reg => |id| if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[part_idx], id, state, flags)) |tr| return tr,
                        .text => |text| if (isIdentLike(text)) {
                            if (current_scope) |scope| {
                                if (resolveScopedRegId(&scope, &metadata.symbols, text)) |id| {
                                    if (readCheck(item, current_function_text, current_is_ffi_wrapper, text, id, state, flags)) |tr| return tr;
                                } else {
                                    return trapReport(.unknown_register, item, current_function_text, current_is_ffi_wrapper, text, null, null, "register is not declared in the current scope", null);
                                }
                            } else {
                                return trapReport(.unknown_register, item, current_function_text, current_is_ffi_wrapper, text, null, null, "register is not declared in the current scope", null);
                            }
                        },
                        else => {},
                    }
                }
                if (assignValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags, maskOf(.untracked), &interior)) |tr| return tr;
                flags[@intCast(item.operands[0].reg)] = 0;
            },
            .ptr_add => {
                if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[1], item.operands[1].reg, state, flags)) |tr| return tr;
                if (item.operands[2] == .reg) {
                    if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[2], item.operands[2].reg, state, flags)) |tr| return tr;
                } else if (item.operands[2] == .text and isIdentLike(item.operands[2].text)) {
                    if (current_scope) |scope| {
                        if (resolveScopedRegId(&scope, &metadata.symbols, item.operands[2].text)) |value_id| {
                            if (readCheck(item, current_function_text, current_is_ffi_wrapper, item.operands[2].text, value_id, state, flags)) |tr| return tr;
                        }
                    }
                }
                const src_idx: usize = @intCast(item.operands[1].reg);
                const has_field_identity = (state[src_idx] & (maskOf(.active) | maskOf(.borrow_view) | maskOf(.locked_read) | maskOf(.locked_mut) | maskOf(.interior_ptr))) != 0;
                const has_borrow_lifetime = (state[src_idx] & (maskOf(.borrow_view) | maskOf(.ffi_borrow) | maskOf(.interior_ptr))) != 0 or hasInteriorTree(state, interior_first_child, item.operands[1].reg);
                // Static OOB check before linking the child: forming an
                // out-of-bounds derived pointer is rejected even if it is
                // never dereferenced.
                if (checkStaticOffsetInBounds(item, current_function_text, current_is_ffi_wrapper, classified.parts[1], &interior, origins, state, item.operands[1].reg, staticByteOffset(item.operands[2]))) |tr| return tr;
                const dst_mask: u16 = if (has_borrow_lifetime) maskOf(.active) | maskOf(.interior_ptr) else maskOf(.active);
                if (assignValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags, dst_mask, &interior)) |tr| return tr;
                if (has_borrow_lifetime) {
                    attachInteriorChild(state, interior_parent, interior_first_child, interior_next_sibling, item.operands[1].reg, item.operands[0].reg);
                }
                if (has_field_identity) {
                    setInteriorOffsetFromBase(&interior, item.operands[1].reg, item.operands[0].reg, staticByteOffset(item.operands[2]));
                }
                flags[@intCast(item.operands[0].reg)] = 0;
            },
            .borrow => {
                const source_reg: u32 = blk: {
                    if (item.operands[1] == .reg) break :blk item.operands[1].reg;
                    if (item.operands[2] == .reg) break :blk item.operands[2].reg;
                    return trapReport(.forbidden_syntax, item, current_function_text, current_is_ffi_wrapper, null, null, null, "invalid borrow syntax", null);
                };
                const mode_text: []const u8 = blk: {
                    if (item.operands[1] == .text) break :blk item.operands[1].text;
                    if (item.operands[2] == .text) break :blk item.operands[2].text;
                    return trapReport(.forbidden_syntax, item, current_function_text, current_is_ffi_wrapper, null, null, null, "invalid borrow syntax", null);
                };
                const is_mut = std.mem.eql(u8, mode_text, "mut");
                if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[2], source_reg, state, flags)) |tr| return tr;
                if (is_mut) {
                    const source_idx: usize = @intCast(source_reg);
                    if (isImmutableConst(state, flags, source_reg)) {
                        return constTrap(item, current_function_text, current_is_ffi_wrapper, classified.parts[2], state[source_idx], "immutable registers cannot be exclusively borrowed");
                    }
                    if ((state[source_idx] & maskOf(.borrow_view)) != 0 or locks[source_idx] != 0) {
                        return trapReport(.read_write_conflict, item, current_function_text, current_is_ffi_wrapper, classified.parts[2], maskOf(.active), state[source_idx], "cannot borrow mut while shared borrows are active", null);
                    }
                    if (hasOverlappingInteriorBorrow(&interior, locks, source_reg)) {
                        return trapReport(.read_write_conflict, item, current_function_text, current_is_ffi_wrapper, classified.parts[2], maskOf(.active), state[source_idx], "cannot borrow mut while overlapping field borrows are active", null);
                    }
                    if ((state[source_idx] & maskOf(.locked_mut)) != 0) {
                        return trapReport(.double_mutable_borrow, item, current_function_text, current_is_ffi_wrapper, classified.parts[2], maskOf(.active), state[source_idx], "cannot borrow mut more than once", null);
                    }
                }
                if (assignValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags, maskOf(.active) | maskOf(.borrow_view), &interior)) |tr| return tr;
                setBorrowState(state, flags, origins, locks, item.operands[0].reg, source_reg, is_mut, false);
            },
            .move_ => {
                if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags)) |tr| return tr;
                // sci-rust P2.1 Copy elision: under --rust-copy-elision,
                // ephemeral scalars (Copy values) are not consumed by move.
                const copy_scalar = rust_copy_elision and (flags[@intCast(item.operands[0].reg)] & regFlagEphemeralScalar) != 0;
                if (!copy_scalar) {
                    if (consumeSourceValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags, origins, locks, interior_parent, interior_first_child, interior_next_sibling, false, &interior)) |tr| return tr;
                }
            },
            .assign => {
                const dst_id = item.operands[0].reg;
                const source_is_ephemeral = switch (item.operands[1]) {
                    .imm_i64, .imm_u64, .imm_int, .imm_float => true,
                    .reg => |src| (flags[@intCast(src)] & regFlagEphemeralScalar) != 0,
                    else => false,
                };
                if (item.operands[1] == .reg and item.operands[1].reg != dst_id) {
                    if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[1], item.operands[1].reg, state, flags)) |tr| return tr;
                }
                if (assignValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], dst_id, state, flags, maskOf(.active), &interior)) |tr| return tr;
                if (item.operands[1] == .reg) {
                    const src_flags = flags[@intCast(item.operands[1].reg)];
                    if ((src_flags & regFlagRawPointer) != 0) {
                        flags[@intCast(dst_id)] |= regFlagRawPointer;
                    }
                }
                if (source_is_ephemeral) {
                    flags[@intCast(dst_id)] = regFlagEphemeralScalar;
                }
                if (item.operands[1] == .reg and item.operands[1].reg != dst_id) {
                    // sci-rust P2.1: Copy scalars survive rebinding.
                    const copy_keep = rust_copy_elision and source_is_ephemeral;
                    if (!copy_keep) {
                        if (consumeSourceValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[1], item.operands[1].reg, state, flags, origins, locks, interior_parent, interior_first_child, interior_next_sibling, true, &interior)) |tr| return tr;
                    }
                }
            },
            .release => {
                const idx: usize = @intCast(item.operands[0].reg);
                if ((state[idx] & maskOf(.borrow_view)) != 0) {
                    clearBorrow(state, flags, origins, locks, item.operands[0].reg, &interior);
                } else if ((flags[idx] & (regFlagRawPointer | regFlagEphemeralScalar)) != 0 and
                    state[idx] == maskOf(.active))
                {
                    // Plain raw pointers and ephemeral scalars carry no
                    // ownership: release is a no-op and must not mark the
                    // register Consumed. Otherwise a `!tp`/`!tn` (e.g. at a
                    // loop back-edge) poisons the phi snapshot for later
                    // redefinitions of the same register name, producing a
                    // false PhiStateConflict (Active vs Consumed).
                    // NOTE: check borrow_view first above: setBorrowState
                    // reuses bit 0x01 for FFI borrows, which collides with
                    // regFlagRawPointer; FFI borrows must still go through
                    // clearBorrow.
                    // NOTE: only apply to PLAIN Active values. A raw ptr
                    // loaded from a borrow view carries InteriorPtr state
                    // (Active|InteriorPtr composite); it is borrow-tracked
                    // and must go through the normal release path so macro
                    // temps (e.g. VEC_AS_SLICE's __vec_ptr_...) are properly
                    // cleared for loop-head phi merges.
                    if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags)) |tr| return tr;
                } else {
                    if (isImmutableConst(state, flags, item.operands[0].reg)) {
                        return constTrap(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], state[idx], "immutable registers cannot be released");
                    }
                    if (hasActiveBorrowRefs(locks, item.operands[0].reg)) {
                        return trapReport(.borrow_conflict, item, current_function_text, current_is_ffi_wrapper, classified.parts[0], maskOf(.active), state[idx], "borrow rules reject this access", null);
                    }
                    if (isStackAllocated(flags, origins, state, item.operands[0].reg)) {
                        return trapReport(.stack_escape, item, current_function_text, current_is_ffi_wrapper, classified.parts[0], maskOf(.active), state[idx], "stack allocation cannot be released explicitly", null);
                    }
                    if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags)) |tr| return tr;
                    if (hasInteriorTree(state, interior_first_child, item.operands[0].reg)) {
                        consumeInteriorValue(state, interior_parent, interior_first_child, interior_next_sibling, item.operands[0].reg);
                    } else {
                        state[idx] = maskOf(.consumed);
                    }
                }
            },
            .raw_cast => {
                if (!current_is_ffi_wrapper) return trapReport(.illegal_unsafe_context, item, current_function_text, current_is_ffi_wrapper, null, null, null, "raw pointer and assume_* instructions are only legal inside @ffi_wrapper", null);
                if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[1], item.operands[1].reg, state, flags)) |tr| return tr;
                if (assignValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags, maskOf(.untracked), &interior)) |tr| return tr;
            },
            .assume_safe => {
                if (!current_is_ffi_wrapper) return trapReport(.illegal_unsafe_context, item, current_function_text, current_is_ffi_wrapper, null, null, null, "raw pointer and assume_* instructions are only legal inside @ffi_wrapper", null);
                if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[1], item.operands[1].reg, state, flags)) |tr| return tr;
                if (assignValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags, maskOf(.active), &interior)) |tr| return tr;
            },
            .assume_borrow => {
                if (!current_is_ffi_wrapper) return trapReport(.illegal_unsafe_context, item, current_function_text, current_is_ffi_wrapper, null, null, null, "raw pointer and assume_* instructions are only legal inside @ffi_wrapper", null);
                if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[1], item.operands[1].reg, state, flags)) |tr| return tr;
                const is_mut = item.operands[2] == .text and std.mem.eql(u8, item.operands[2].text, "mut");
                if (is_mut and isImmutableConst(state, flags, item.operands[1].reg)) {
                    return constTrap(item, current_function_text, current_is_ffi_wrapper, classified.parts[1], state[@intCast(item.operands[1].reg)], "immutable registers cannot be exclusively borrowed");
                }
                if (assignValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags, maskOf(.active) | maskOf(.borrow_view), &interior)) |tr| return tr;
                setBorrowState(state, flags, origins, locks, item.operands[0].reg, item.operands[1].reg, is_mut, true);
            },
            .native => {
                for (item.native_reg_names) |name| {
                    if (!isIdentLike(name)) continue;
                    if (current_scope) |scope| {
                        if (resolveScopedRegId(&scope, &metadata.symbols, name)) |id| {
                            if (consumeAtContractBoundary(item, current_function_text, current_is_ffi_wrapper, name, id, state, flags, origins, locks, interior_parent, interior_first_child, interior_next_sibling, &interior)) |tr| return tr;
                        }
                    }
                }
            },
            .jmp => {
                const target = item.operands[1].label;
                if (defined_labels.contains(target)) has_unbounded_loop = true;
                if (labels.getPtr(target)) |entry| {
                    if (defined_labels.contains(target)) {
                        if (!snapshotStatesCompatible(entry, state)) {
                            const mismatch = if (current_scope) |scope|
                                snapshotFirstMismatchInScope(entry, state, &scope, &metadata.symbols)
                            else
                                snapshotFirstMismatch(entry, state, &metadata.symbols);
                            return phiStateConflictReport(item, current_function_text, current_is_ffi_wrapper, target, last_seen_label, mismatch, &metadata.symbols);
                        }
                    } else {
                        if (!snapshotMergeCompatible(entry, state)) {
                            const mismatch = if (current_scope) |scope|
                                snapshotMergeStateInScope(entry, state, &scope, &metadata.symbols)
                            else
                                snapshotMergeState(entry, state, &metadata.symbols);
                            return phiStateConflictReport(item, current_function_text, current_is_ffi_wrapper, target, last_seen_label, mismatch, &metadata.symbols);
                        }
                    }
                } else {
                    var snapshot = captureLabelSnapshot(allocator, state, origins, locks, flags, interior_parent, interior_first_child, interior_next_sibling, interior_root, interior_offset, interior_offset_known, alloc_size, alloc_size_known) catch {
                        return trapReport(.arena_oom, item, current_function_text, current_is_ffi_wrapper, null, null, null, "unable to record label state", null);
                    };
                    labels.put(target, snapshot) catch {
                        snapshot.deinit(allocator);
                        return trapReport(.arena_oom, item, current_function_text, current_is_ffi_wrapper, null, null, null, "unable to record label state", null);
                    };
                }
                terminated = true;
            },
            .br => {
                if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags)) |tr| return tr;
                markBranchCondition(flags, item.operands[0].reg);
                for ([_]u32{ item.operands[1].label, item.operands[3].label }) |target| {
                    if (labels.getPtr(target)) |entry| {
                        if (defined_labels.contains(target)) {
                            if (!snapshotStatesCompatible(entry, state)) {
                                const mismatch = if (current_scope) |scope|
                                    snapshotFirstMismatchInScope(entry, state, &scope, &metadata.symbols)
                                else
                                    snapshotFirstMismatch(entry, state, &metadata.symbols);
                                return phiStateConflictReport(item, current_function_text, current_is_ffi_wrapper, target, last_seen_label, mismatch, &metadata.symbols);
                            }
                        } else {
                            if (!snapshotMergeCompatible(entry, state)) {
                                const mismatch = if (current_scope) |scope|
                                    snapshotMergeStateInScope(entry, state, &scope, &metadata.symbols)
                                else
                                    snapshotMergeState(entry, state, &metadata.symbols);
                                return phiStateConflictReport(item, current_function_text, current_is_ffi_wrapper, target, last_seen_label, mismatch, &metadata.symbols);
                            }
                        }
                    } else {
                        var snapshot = captureLabelSnapshot(allocator, state, origins, locks, flags, interior_parent, interior_first_child, interior_next_sibling, interior_root, interior_offset, interior_offset_known, alloc_size, alloc_size_known) catch {
                            return trapReport(.arena_oom, item, current_function_text, current_is_ffi_wrapper, null, null, null, "unable to record label state", null);
                        };
                        labels.put(target, snapshot) catch {
                            snapshot.deinit(allocator);
                            return trapReport(.arena_oom, item, current_function_text, current_is_ffi_wrapper, null, null, null, "unable to record label state", null);
                        };
                    }
                    if (defined_labels.contains(target)) has_unbounded_loop = true;
                }
                terminated = true;
            },
            .br_null => {
                if (readCheck(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], item.operands[0].reg, state, flags)) |tr| return tr;
                markBranchCondition(flags, item.operands[0].reg);
                for ([_]u32{ item.operands[1].label, item.operands[3].label }) |target| {
                    if (labels.getPtr(target)) |entry| {
                        if (defined_labels.contains(target)) {
                            if (!snapshotStatesCompatible(entry, state)) {
                                const mismatch = if (current_scope) |scope|
                                    snapshotFirstMismatchInScope(entry, state, &scope, &metadata.symbols)
                                else
                                    snapshotFirstMismatch(entry, state, &metadata.symbols);
                                return phiStateConflictReport(item, current_function_text, current_is_ffi_wrapper, target, last_seen_label, mismatch, &metadata.symbols);
                            }
                        } else {
                            if (!snapshotMergeCompatible(entry, state)) {
                                const mismatch = if (current_scope) |scope|
                                    snapshotMergeStateInScope(entry, state, &scope, &metadata.symbols)
                                else
                                    snapshotMergeState(entry, state, &metadata.symbols);
                                return phiStateConflictReport(item, current_function_text, current_is_ffi_wrapper, target, last_seen_label, mismatch, &metadata.symbols);
                            }
                        }
                    } else {
                        var snapshot = captureLabelSnapshot(allocator, state, origins, locks, flags, interior_parent, interior_first_child, interior_next_sibling, interior_root, interior_offset, interior_offset_known, alloc_size, alloc_size_known) catch {
                            return trapReport(.arena_oom, item, current_function_text, current_is_ffi_wrapper, null, null, null, "unable to record label state", null);
                        };
                        labels.put(target, snapshot) catch {
                            snapshot.deinit(allocator);
                            return trapReport(.arena_oom, item, current_function_text, current_is_ffi_wrapper, null, null, null, "unable to record label state", null);
                        };
                    }
                    if (defined_labels.contains(target)) has_unbounded_loop = true;
                }
                terminated = true;
            },
            .call, .call_indirect, .panic, .panic_msg => {
                var parsed = parseInstructionCallForLocalizedVerifier(allocator, &metadata.symbols, if (current_scope) |*scope| scope else null, item) catch {
                    return trapReport(.forbidden_syntax, item, current_function_text, current_is_ffi_wrapper, null, null, null, "invalid call syntax", null);
                };
                defer parsed.deinit(allocator);

                if (sax_context) |ctx| {
                    if (std.mem.eql(u8, parsed.callee, "render") and !current_is_ffi_wrapper) {
                        return saxReport(ctx, .sax_render_outside_handler, item, parsed.dest, null, null, "call @render() is only legal inside @handler", null);
                    }
                }

                const sig_match: ?*const sig.FunctionSig = if (metadata.sig_index_by_name.get(parsed.callee)) |sig_idx| &metadata.sigs.items[sig_idx] else null;
                const builtin_spec = builtinArgSpec(parsed.callee);

                if (!parsed.is_indirect and sig_match == null and builtin_spec == null and !std.mem.startsWith(u8, parsed.callee, "sys_")) {
                    return trapReport(.unknown_register, item, current_function_text, current_is_ffi_wrapper, parsed.dest, null, null, "callee is not declared", null);
                }

                if (!parsed.is_indirect and builtin_spec == null and std.mem.startsWith(u8, parsed.callee, "sys_")) {
                    return trapReport(.unsupported_sys_intrinsic, item, current_function_text, current_is_ffi_wrapper, parsed.dest, null, null, "target runtime does not support this @sys_* intrinsic", null);
                }

                if (!parsed.is_indirect) {
                    if (builtinGrantRequirement(parsed.callee)) |required_grant| {
                        if (item.package_identity) |identity| {
                            const grant_entry = packageGrantEntry(identity, package_grants) orelse {
                                return trapReport(.unauthorized_primitive, item, current_function_text, current_is_ffi_wrapper, parsed.dest, null, null, "package grants do not allow this @sys_* intrinsic", null);
                            };
                            if (!packageGrantAllowsEntry(grant_entry, required_grant)) {
                                return trapReport(.unauthorized_primitive, item, current_function_text, current_is_ffi_wrapper, parsed.dest, null, null, "package grants do not allow this @sys_* intrinsic", null);
                            }
                            const package_hash = item.package_source_sha256 orelse {
                                return trapReport(.upstream_sha_mismatch, item, current_function_text, current_is_ffi_wrapper, parsed.dest, null, null, "package source hash does not match the granted requirement", null);
                            };
                            if (!std.mem.eql(u8, grant_entry.source_sha256[0..], package_hash[0..])) {
                                return trapReport(.upstream_sha_mismatch, item, current_function_text, current_is_ffi_wrapper, parsed.dest, null, null, "package source hash does not match the granted requirement", null);
                            }
                        }
                    }
                }

                if (!parsed.is_indirect) {
                    if (sig_match) |resolved| {
                        if (resolved.params.len != parsed.args.len) {
                            return trapReport(.capability_mismatch, item, current_function_text, current_is_ffi_wrapper, parsed.dest, null, null, "call-site capability prefix does not match the callee contract", null);
                        }
                        for (parsed.args, resolved.params) |arg, param| {
                            if (!callPrefixMatchesParam(param, arg.prefix)) {
                                return trapReport(.capability_mismatch, item, current_function_text, current_is_ffi_wrapper, parsed.dest, null, null, "call-site capability prefix does not match the callee contract", null);
                            }
                        }
                    } else if (builtin_spec) |spec| {
                        if (spec.len != parsed.args.len) {
                            return trapReport(.capability_mismatch, item, current_function_text, current_is_ffi_wrapper, parsed.dest, null, null, "call-site capability prefix does not match the callee contract", null);
                        }
                        for (parsed.args, spec) |arg, expected| {
                            if (arg.prefix != expected) {
                                return trapReport(.capability_mismatch, item, current_function_text, current_is_ffi_wrapper, parsed.dest, null, null, "call-site capability prefix does not match the callee contract", null);
                            }
                        }
                    }
                }

                for (parsed.args, 0..) |arg, arg_idx| {
                    if (isIdentLike(arg.text)) {
                        if (current_scope) |scope| {
                            if (resolveScopedRegId(&scope, &metadata.symbols, arg.text)) |arg_id| {
                                const arg_reg_idx: usize = @intCast(arg_id);
                                if (metadata.sig_index_by_name.contains(arg.text)) {
                                    if (sig_match) |resolved| {
                                        if (arg_idx < resolved.params.len and resolved.params[arg_idx].ty == .ptr) {
                                            continue;
                                        }
                                    }
                                }
                                if (sig_match) |resolved| {
                                    if (arg.prefix != .borrow and (resolved.kind == .external or resolved.kind == .ffi_wrapper) and hasInteriorTree(state, interior_first_child, arg_id)) {
                                        return trapReport(.interior_ptr_escape, item, current_function_text, current_is_ffi_wrapper, arg.text, maskOf(.interior_ptr), state[arg_reg_idx], "interior pointers cannot cross FFI boundaries", null);
                                    }
                                }
                                switch (arg.prefix) {
                                    .borrow => if (readCheck(item, current_function_text, current_is_ffi_wrapper, arg.text, arg_id, state, flags)) |tr| return tr,
                                    .by_value => if (readCheck(item, current_function_text, current_is_ffi_wrapper, arg.text, arg_id, state, flags)) |tr| return tr,
                                    .raw => if (panicMsgAllowsRawArg(parsed.callee, parsed.args.len, arg_idx)) {
                                        if (readCheckAllowRaw(item, current_function_text, current_is_ffi_wrapper, arg.text, arg_id, state, flags)) |tr| return tr;
                                    } else {
                                        if (readCheck(item, current_function_text, current_is_ffi_wrapper, arg.text, arg_id, state, flags)) |tr| return tr;
                                    },
                                    .move => {
                                        if (isImmutableConst(state, flags, arg_id)) {
                                            return constTrap(item, current_function_text, current_is_ffi_wrapper, arg.text, state[arg_reg_idx], "immutable registers cannot be moved");
                                        }
                                        if (readCheck(item, current_function_text, current_is_ffi_wrapper, arg.text, arg_id, state, flags)) |tr| return tr;
                                        if (isStackAllocated(flags, origins, state, arg_id)) {
                                            return trapReport(.stack_escape, item, current_function_text, current_is_ffi_wrapper, arg.text, maskOf(.active), state[@intCast(arg_id)], "stack allocation cannot be passed by move", null);
                                        }
                                        const move_arg_reg_idx: usize = @intCast(arg_id);
                                        if ((flags[move_arg_reg_idx] & regFlagRawPointer) != 0) {
                                            continue;
                                        }
                                        if ((state[move_arg_reg_idx] & maskOf(.borrow_view)) != 0) {
                                            clearBorrow(state, flags, origins, locks, arg_id, &interior);
                                        } else {
                                            if (hasInteriorTree(state, interior_first_child, arg_id)) {
                                                consumeInteriorValue(state, interior_parent, interior_first_child, interior_next_sibling, arg_id);
                                            } else {
                                                state[move_arg_reg_idx] = maskOf(.consumed);
                                            }
                                        }
                                    },
                                }
                            } else if (sig_match) |resolved| {
                                if (arg_idx < resolved.params.len and resolved.params[arg_idx].ty == .ptr) {
                                    continue;
                                }
                                return trapReport(.unknown_register, item, current_function_text, current_is_ffi_wrapper, arg.text, null, null, "register is not declared in the current scope", null);
                            } else {
                                return trapReport(.unknown_register, item, current_function_text, current_is_ffi_wrapper, arg.text, null, null, "register is not declared in the current scope", null);
                            }
                        } else if (sig_match) |resolved| {
                            if (arg_idx < resolved.params.len and resolved.params[arg_idx].ty == .ptr) {
                                continue;
                            }
                            return trapReport(.unknown_register, item, current_function_text, current_is_ffi_wrapper, arg.text, null, null, "register is not declared in the current scope", null);
                        }
                    }
                }

                if (parsed.dest) |dest| {
                    if (isIdentLike(dest)) {
                        if (current_scope) |scope| {
                            if (resolveScopedRegId(&scope, &metadata.symbols, dest)) |dest_id| {
                                const idx: usize = @intCast(dest_id);
                                // The stdlib VEC_PUSH macro expands to:
                                //   %vec_reg = call @sa_vec_push(^%vec_reg, %value, %elem_size)
                                // In SA IR, `^` is the .move prefix (not .borrow; `&` is .borrow).
                                // This "update via move" pattern is legal SA: the dest is moved
                                // into the call via ^, then reassigned with the (mutated) result.
                                // SA-text verifies the EXPAND directive and never sees the expanded
                                // form; SAB contains the expanded instructions, so the SAB verifier
                                // must allow the pattern here to maintain SAB/SA-text parity.
                                // Note: if the moved arg has regFlagRawPointer, the .move handler
                                // above does `continue` without marking it consumed, so the dest
                                // check below would falsely report redefinition without this allowance.
                                var dest_is_moved_arg = false;
                                for (parsed.args) |arg| {
                                    if (arg.prefix != .move) continue;
                                    if (!isIdentLike(arg.text)) continue;
                                    if (resolveScopedRegId(&scope, &metadata.symbols, arg.text)) |arg_id| {
                                        if (arg_id == dest_id) {
                                            dest_is_moved_arg = true;
                                            break;
                                        }
                                    }
                                }
                                if (!dest_is_moved_arg and state[idx] != 0 and (state[idx] & maskOf(.consumed)) == 0 and (state[idx] & maskOf(.untracked)) == 0 and (flags[idx] & regFlagEphemeralScalar) == 0) {
                                    return trapReport(.register_redefinition, item, current_function_text, current_is_ffi_wrapper, dest, null, null, "register is already live", null);
                                }
                                if (isImmutableConst(state, flags, dest_id)) {
                                    return constTrap(item, current_function_text, current_is_ffi_wrapper, dest, state[idx], "immutable registers cannot be overwritten");
                                }
                                const ret_cap = if (parsed.is_indirect) null else if (sig_match) |resolved| resolved.return_cap else builtinReturnCap(parsed.callee);
                                const ret_state = if (!parsed.is_indirect) blk: {
                                    if (sig_match) |resolved| {
                                        if (resolved.return_fallible) break :blk maskOf(.fallible);
                                    }
                                    break :blk switch (ret_cap orelse .move) {
                                        .raw => maskOf(.untracked),
                                        .borrow => maskOf(.active) | maskOf(.borrow_view),
                                        .move, .by_value => maskOf(.active),
                                    };
                                } else blk: {
                                    break :blk switch (ret_cap orelse .move) {
                                        .raw => maskOf(.untracked),
                                        .borrow => maskOf(.active) | maskOf(.borrow_view),
                                        .move, .by_value => maskOf(.active),
                                    };
                                };
                                state[idx] = ret_state;
                                flags[idx] = 0;
                            }
                        }
                    }
                }

                if (item.kind == .panic or item.kind == .panic_msg) {
                    terminated = true;
                    fatal_terminated = true;
                }
            },
            .try_, .early_return => {
                const src_id = item.operands[1].reg;
                const dst_id = item.operands[0].reg;
                const src_idx: usize = @intCast(src_id);
                const src_mask = state[src_idx];
                if ((src_mask & maskOf(.fallible)) == 0) {
                    const src_name = current_scope.?.nameOf(&metadata.symbols, src_id) orelse metadata.symbols.lookupName(current_scope.?.globalId(src_id)) orelse "";
                    return trapReport(.fallible_contract_mismatch, item, current_function_text, current_is_ffi_wrapper, src_name, maskOf(.fallible), src_mask, "? can only be applied to fallible return values", null);
                }

                for (state, 0..) |mask, idx| {
                    if (idx == src_idx) continue;
                    if (mask == 0 or mask == maskOf(.consumed) or mask == maskOf(.untracked)) continue;
                    if ((mask & maskOf(.active)) == 0 and (mask & maskOf(.locked_read)) == 0 and (mask & maskOf(.locked_mut)) == 0) continue;
                    if ((mask & maskOf(.immutable)) != 0 or (flags[idx] & regFlagImmutable) != 0) continue;
                    if ((flags[idx] & regFlagEphemeralScalar) != 0) continue;
                    // Raw pointers carry no ownership (release is a no-op for
                    // them); a live raw-pointer temp is never a leak, same as
                    // an ephemeral scalar temp.
                    if ((flags[idx] & regFlagRawPointer) != 0) continue;
                    if (isStackAllocated(flags, origins, state, @intCast(idx))) continue;
                    if (idx < consumed_in_function.len and consumed_in_function[idx]) continue;
                    const src_name = current_scope.?.nameOf(&metadata.symbols, src_id) orelse metadata.symbols.lookupName(current_scope.?.globalId(src_id)) orelse "";
                    return trapReport(.early_return_leak, item, current_function_text, current_is_ffi_wrapper, src_name, maskOf(.fallible), src_mask, "early return would leak live registers", null);
                }

                if (assignValue(item, current_function_text, current_is_ffi_wrapper, classified.parts[0], dst_id, state, flags, maskOf(.active), &interior)) |tr| return tr;
                flags[@intCast(dst_id)] = 0;
            },
            .return_ => {
                if (item.operands[0] == .reg) {
                    const ret_id = item.operands[0].reg;
                    const ret_name = current_scope.?.nameOf(&metadata.symbols, ret_id) orelse metadata.symbols.lookupName(current_scope.?.globalId(ret_id)) orelse item.operands[0].text;
                    const idx: usize = @intCast(ret_id);
                    if (readCheck(item, current_function_text, current_is_ffi_wrapper, ret_name, ret_id, state, flags)) |tr| {
                        return tr;
                    }
                    if ((state[idx] & maskOf(.fallible)) != 0) {
                        if (current_sig == null or current_sig.?.return_fallible == false) {
                            return trapReport(.fallible_contract_mismatch, item, current_function_text, current_is_ffi_wrapper, ret_name, maskOf(.fallible), state[idx], "fallible values must be propagated with ? or returned from a fallible function", null);
                        }
                        if (hasInteriorTree(state, interior_first_child, ret_id)) {
                            consumeInteriorValue(state, interior_parent, interior_first_child, interior_next_sibling, ret_id);
                        } else {
                            state[idx] = maskOf(.consumed);
                        }
                    } else {
                        if ((state[idx] & maskOf(.borrow_view)) == 0 and hasActiveBorrowRefs(locks, ret_id)) {
                            return trapReport(.borrow_conflict, item, current_function_text, current_is_ffi_wrapper, ret_name, maskOf(.active), state[idx], "borrow rules reject this access", null);
                        }
                        if (isStackAllocated(flags, origins, state, ret_id)) {
                            return trapReport(.stack_escape, item, current_function_text, current_is_ffi_wrapper, ret_name, maskOf(.active), state[idx], "stack allocation cannot be returned", null);
                        }
                        if ((flags[idx] & regFlagRawPointer) == 0) {
                            if ((state[idx] & maskOf(.borrow_view)) != 0) {
                                clearBorrow(state, flags, origins, locks, ret_id, &interior);
                            } else if (hasInteriorTree(state, interior_first_child, ret_id)) {
                                consumeInteriorValue(state, interior_parent, interior_first_child, interior_next_sibling, ret_id);
                            } else if ((state[idx] & maskOf(.untracked)) == 0) {
                                state[idx] = maskOf(.consumed);
                            }
                        }
                    }
                } else if (item.operands[0] == .text and isIdentLike(item.operands[0].text)) {
                    if (current_scope) |scope| {
                        if (resolveScopedRegId(&scope, &metadata.symbols, item.operands[0].text)) |ret_id| {
                            const idx: usize = @intCast(ret_id);
                            const ret_name = scope.nameOf(&metadata.symbols, ret_id) orelse item.operands[0].text;
                            if (readCheck(item, current_function_text, current_is_ffi_wrapper, item.operands[0].text, ret_id, state, flags)) |tr| {
                                return tr;
                            }
                            if (isImmutableConst(state, flags, ret_id)) {
                                return constTrap(item, current_function_text, current_is_ffi_wrapper, ret_name, state[idx], "immutable registers cannot be returned by move");
                            }
                            if ((state[idx] & maskOf(.fallible)) != 0) {
                                if (current_sig == null or current_sig.?.return_fallible == false) {
                                    return trapReport(.fallible_contract_mismatch, item, current_function_text, current_is_ffi_wrapper, ret_name, maskOf(.fallible), state[idx], "fallible values must be propagated with ? or returned from a fallible function", null);
                                }
                                if (hasInteriorTree(state, interior_first_child, ret_id)) {
                                    consumeInteriorValue(state, interior_parent, interior_first_child, interior_next_sibling, ret_id);
                                } else {
                                    state[idx] = maskOf(.consumed);
                                }
                            } else {
                                if ((state[idx] & maskOf(.borrow_view)) == 0 and hasActiveBorrowRefs(locks, ret_id)) {
                                    return trapReport(.borrow_conflict, item, current_function_text, current_is_ffi_wrapper, ret_name, maskOf(.active), state[idx], "borrow rules reject this access", null);
                                }
                                if (isStackAllocated(flags, origins, state, ret_id)) {
                                    return trapReport(.stack_escape, item, current_function_text, current_is_ffi_wrapper, ret_name, maskOf(.active), state[idx], "stack allocation cannot be returned", null);
                                }
                                if ((flags[idx] & regFlagRawPointer) == 0) {
                                    if ((state[idx] & maskOf(.borrow_view)) != 0) {
                                        clearBorrow(state, flags, origins, locks, ret_id, &interior);
                                    } else if (hasInteriorTree(state, interior_first_child, ret_id)) {
                                        consumeInteriorValue(state, interior_parent, interior_first_child, interior_next_sibling, ret_id);
                                    } else if ((state[idx] & maskOf(.untracked)) == 0) {
                                        state[idx] = maskOf(.consumed);
                                    }
                                }
                            }
                        } else {
                            return trapReport(.unknown_register, item, current_function_text, current_is_ffi_wrapper, item.operands[0].text, null, null, "register is not declared in the current scope", null);
                        }
                    } else {
                        return trapReport(.unknown_register, item, current_function_text, current_is_ffi_wrapper, item.operands[0].text, null, null, "register is not declared in the current scope", null);
                    }
                }
                terminated = true;
            },
            else => {},
        }

        const delta = try diffState(allocator, snapshot_before, state);
        errdefer {
            var owned = delta;
            owned.deinit(allocator);
        }
        try annotated.append(.{
            .base = item,
            .delta = delta,
            .gas_step_cost = if (isExecKind(item.kind)) 1 else 0,
        });
    }

    if (body_seen and !terminated) {
        return trapReport(.fallthrough_forbidden, instructions[instructions.len - 1], current_function_text, current_is_ffi_wrapper, null, null, null, "function body ended without a terminator", "end the last block with jmp, br, br_null, or return");
    }

    const current_is_bodyless_extern = current_sig != null and current_sig.?.kind == .external and !body_seen;
    if (check_exit_leaks and !fatal_terminated and !current_is_bodyless_extern) {
        for (state, 0..) |mask, idx| {
            if (mask == 0 or mask == maskOf(.consumed) or mask == maskOf(.untracked)) continue;
            if ((mask & maskOf(.immutable)) != 0 or (flags[idx] & regFlagImmutable) != 0) continue;
            if ((flags[idx] & regFlagEphemeralScalar) != 0) continue;
            // Raw pointers carry no ownership (release is a no-op for them);
            // a live raw-pointer temp is never a leak, same as an ephemeral
            // scalar temp.
            if ((flags[idx] & regFlagRawPointer) != 0) continue;
            if ((flags[idx] & regFlagBranchCondition) != 0) continue;
            if (isStackAllocated(flags, origins, state, @intCast(idx))) continue;
            if (idx < consumed_in_function.len and consumed_in_function[idx]) continue;
            const leak_name = current_scope.?.nameOf(&metadata.symbols, @intCast(idx)) orelse metadata.symbols.lookupName(current_scope.?.globalId(@intCast(idx)));
            if (sax_context) |ctx| {
                if (current_is_ffi_wrapper and current_function_text != null and std.mem.containsAtLeast(u8, current_function_text.?, 1, "destroy")) {
                    return saxReport(ctx, .sax_state_leak, instructions[instructions.len - 1], leak_name, null, mask, "live state remains at component teardown", null);
                }
            }
            return trapReport(.memory_leak, instructions[instructions.len - 1], current_function_text, current_is_ffi_wrapper, leak_name, null, mask, "live registers remain at function exit", null);
        }
    }

    if (current_scope) |*scope| {
        scope.deinit();
        current_scope = null;
    }

    const annotated_slice = annotated.toOwnedSlice() catch {
        return .{ .trap = trapReportFromText(.arena_oom, 1, 1, instructions[instructions.len - 1].raw_text, "unable to finalize annotations", null) };
    };
    completed = true;

    return .{ .ok = .{
        .annotated = annotated_slice,
        .gas = .{
            .max_alloc_bytes = gas_alloc_bytes,
            .max_instruction_steps = if (has_unbounded_loop) .{ .unbounded = .{ .bounded_prefix = gas_steps } } else .{ .bounded = gas_steps },
            .call_depth = call_depth,
            .has_unbounded_loop = has_unbounded_loop,
        },
        .has_unbounded_loop = has_unbounded_loop,
    } };
}

fn freeAnnotatedSlice(allocator: std.mem.Allocator, annotated: []AnnotatedInstruction) void {
    for (annotated) |item| {
        var owned = item;
        owned.deinit(allocator);
    }
    allocator.free(annotated);
}

fn buildVerifyChunks(
    allocator: std.mem.Allocator,
    instructions: []const inst.Instruction,
) ![]ParallelFunctionChunk {
    if (instructions.len == 0) {
        return try allocator.alloc(ParallelFunctionChunk, 0);
    }

    var chunks = std.array_list.Managed(ParallelFunctionChunk).init(allocator);
    errdefer chunks.deinit();

    var current_start: ?usize = null;
    var current_sig_index: usize = 0;
    var next_sig_index: usize = 0;
    var saw_decl = false;

    for (instructions, 0..) |item, idx| {
        if (isDecl(item.kind)) {
            saw_decl = true;
            if (current_start) |start| {
                try chunks.append(.{
                    .start = start,
                    .end = idx,
                    .sig_index = current_sig_index,
                });
            }
            current_start = idx;
            current_sig_index = next_sig_index;
            next_sig_index += 1;
            continue;
        }

        if (!saw_decl) {
            return try allocator.alloc(ParallelFunctionChunk, 0);
        }
    }

    if (current_start) |start| {
        try chunks.append(.{
            .start = start,
            .end = instructions.len,
            .sig_index = current_sig_index,
        });
    }

    return try chunks.toOwnedSlice();
}

fn chooseVerifyWorkerCount(requested_jobs: ?usize, chunk_count: usize) usize {
    if (chunk_count < 2) return 1;
    if (requested_jobs) |jobs| {
        return if (jobs <= 1) 1 else @min(jobs, chunk_count);
    }
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return if (cpu_count <= 1) 1 else @min(cpu_count, chunk_count);
}

fn verifyWorker(context: *ParallelVerifyContext, worker_index: usize) void {
    const worker_allocator = context.workers[worker_index].allocator();
    while (true) {
        const chunk_index = context.next_chunk.fetchAdd(1, .monotonic);
        if (chunk_index >= context.chunks.len) return;

        const chunk = context.chunks[chunk_index];
        const job = &context.jobs[chunk_index];
        job.worker_index = worker_index;
        const result = verifyBody(
            worker_allocator,
            context.instructions[chunk.start..chunk.end],
            context.classified_lines[chunk.start..chunk.end],
            context.const_decls,
            context.metadata,
            chunk.sig_index,
            context.check_exit_leaks and chunk_index + 1 == context.chunks.len,
            context.package_grants,
            context.sax_context,
            context.default_immutable,
            context.rust_strict_mut,
            context.rust_copy_elision,
        ) catch |err| {
            job.err = err;
            return;
        };
        job.result = result;
    }
}

fn verifyParallel(
    allocator: std.mem.Allocator,
    instructions: []const inst.Instruction,
    classified_lines: []const classifier.ClassifiedLine,
    const_decls: []const const_decl.ConstDecl,
    metadata: *const CollectResult,
    package_grants: []const pkg_manifest.RequireEntry,
    sax_context: ?SaxValidationContext,
    chunks: []const ParallelFunctionChunk,
    requested_jobs: ?usize,
    check_exit_leaks: bool,
    default_immutable: bool,
    rust_strict_mut: bool,
    rust_copy_elision: bool,
    stage_reporter: ?VerifyStageReporter,
) !VerifyBodyResult {
    const worker_count = chooseVerifyWorkerCount(requested_jobs, chunks.len);
    if (worker_count <= 1) {
        return verifyBody(allocator, instructions, classified_lines, const_decls, metadata, 0, check_exit_leaks, package_grants, sax_context, default_immutable, rust_strict_mut, rust_copy_elision);
    }

    if (stage_reporter) |reporter| reporter.report("parallel_start", worker_count, chunks.len);

    const jobs = try allocator.alloc(ParallelVerifyJob, chunks.len);
    for (jobs) |*job| {
        job.* = .{};
    }
    defer {
        allocator.free(jobs);
    }

    const workers = try allocator.alloc(ParallelVerifyWorker, worker_count);
    for (workers) |*worker| worker.* = .{};
    defer {
        for (workers) |*worker| worker.deinit();
        allocator.free(workers);
    }
    defer cleanupParallelJobResults(jobs, workers);
    if (stage_reporter) |reporter| reporter.report("parallel_after_worker_allocators", worker_count, chunks.len);

    var context = ParallelVerifyContext{
        .allocator = allocator,
        .instructions = instructions,
        .classified_lines = classified_lines,
        .const_decls = const_decls,
        .metadata = metadata,
        .package_grants = package_grants,
        .sax_context = sax_context,
        .chunks = chunks,
        .jobs = jobs,
        .workers = workers,
        .requested_jobs = requested_jobs,
        .check_exit_leaks = check_exit_leaks,
        .default_immutable = default_immutable,
        .rust_strict_mut = rust_strict_mut,
        .rust_copy_elision = rust_copy_elision,
        .next_chunk = std.atomic.Value(usize).init(0),
    };
    _ = context.allocator;
    _ = context.requested_jobs;

    const spawned_count = worker_count - 1;
    var threads = try allocator.alloc(std.Thread, spawned_count);
    defer allocator.free(threads);
    var started_threads: usize = 0;
    errdefer {
        while (started_threads > 0) {
            started_threads -= 1;
            threads[started_threads].join();
        }
    }

    while (started_threads < spawned_count) : (started_threads += 1) {
        threads[started_threads] = try std.Thread.spawn(.{}, verifyWorker, .{ &context, started_threads + 1 });
    }

    verifyWorker(&context, 0);

    while (started_threads > 0) {
        started_threads -= 1;
        threads[started_threads].join();
    }
    if (stage_reporter) |reporter| reporter.report("parallel_after_body", chunks.len, chunks.len);

    var annotated = std.array_list.Managed(AnnotatedInstruction).init(allocator);
    errdefer freeAnnotated(allocator, &annotated);
    var gas_alloc_bytes: u64 = 0;
    var gas_steps: u64 = 0;
    var has_unbounded_loop = false;

    for (jobs, 0..) |*job, job_index| {
        if (job.err) |err| return err;
        const result = job.result orelse return error.UnexpectedResult;
        switch (result) {
            .trap => |report| {
                freeAnnotated(allocator, &annotated);
                return .{ .trap = report };
            },
            .ok => |ok| {
                defer {
                    freeAnnotatedSlice(workers[job.worker_index].allocator(), ok.annotated);
                    job.result = null;
                }
                for (ok.annotated) |item| {
                    const delta_changes = if (item.delta.changes.len == 0)
                        emptyRegStateDelta().changes
                    else
                        try allocator.dupe(RegStateChange, item.delta.changes);
                    var delta_owned = false;
                    defer if (!delta_owned and delta_changes.len != 0) allocator.free(delta_changes);
                    try annotated.append(.{
                        .base = item.base,
                        .delta = .{ .changes = delta_changes },
                        .gas_step_cost = item.gas_step_cost,
                    });
                    delta_owned = true;
                }
                gas_alloc_bytes += ok.gas.max_alloc_bytes;
                switch (ok.gas.max_instruction_steps) {
                    .bounded => |steps| gas_steps += steps,
                    .unbounded => |unbounded| {
                        gas_steps += unbounded.bounded_prefix;
                        has_unbounded_loop = true;
                    },
                }
                if (ok.has_unbounded_loop) {
                    has_unbounded_loop = true;
                }
            },
        }

        if (stage_reporter) |reporter| {
            const completed = job_index + 1;
            if (completed == jobs.len or completed % 128 == 0) {
                reporter.report("parallel_merge", completed, jobs.len);
            }
        }
    }

    const annotated_slice = try annotated.toOwnedSlice();
    return .{ .ok = .{
        .annotated = annotated_slice,
        .gas = .{
            .max_alloc_bytes = gas_alloc_bytes,
            .max_instruction_steps = if (has_unbounded_loop) .{ .unbounded = .{ .bounded_prefix = gas_steps } } else .{ .bounded = gas_steps },
            .call_depth = 0,
            .has_unbounded_loop = has_unbounded_loop,
        },
        .has_unbounded_loop = has_unbounded_loop,
    } };
}

pub fn verifyWithOptions(
    allocator: std.mem.Allocator,
    instructions: []const inst.Instruction,
    const_decls: []const const_decl.ConstDecl,
    options: VerifyOptions,
) !VerifyResult {
    if (options.stage_reporter) |reporter| reporter.report("start", 0, instructions.len);

    if (instructions.len == 0) {
        const symbols = symbol.SymbolTable.init(allocator);
        if (options.stage_reporter) |reporter| reporter.report("empty", 0, 0);
        return .{ .ok = .{
            .annotated = &.{},
            .function_sigs = &.{},
            .symbols = symbols,
            .const_decls = const_decls,
            .gas = .{
                .max_alloc_bytes = 0,
                .max_instruction_steps = .{ .bounded = 0 },
                .call_depth = 0,
                .has_unbounded_loop = false,
            },
        } };
    }

    const classified_lines = try classifyInstructions(allocator, instructions, options.predecoded_symbol_names);
    defer allocator.free(classified_lines);
    if (options.stage_reporter) |reporter| reporter.report("after_classify", classified_lines.len, instructions.len);

    const has_predecoded_metadata = options.predecoded_symbol_names.len != 0 or options.predecoded_function_sigs.len != 0;
    var metadata = (if (has_predecoded_metadata)
        collectPredecodedMetadata(allocator, options.predecoded_symbol_names, options.predecoded_function_sigs, const_decls)
    else
        collectMetadata(allocator, instructions, classified_lines, const_decls)) catch |err| {
        return .{ .trap = trapReportFromText(
            metadataTrapKind(err),
            1,
            1,
            instructions[0].raw_text,
            metadataTrapMessage(err),
            metadataTrapHint(err),
        ) };
    };
    defer freeSigs(allocator, &metadata.sigs);
    defer metadata.sig_index_by_name.deinit();
    defer freeConstVtables(allocator, &metadata.const_vtables);
    defer freeFunctionStarts(&metadata.function_starts);
    var symbols_moved = false;
    defer if (!symbols_moved) metadata.symbols.deinit();
    if (options.stage_reporter) |reporter| reporter.report("after_metadata", metadata.sigs.items.len, instructions.len);

    const chunks = try buildVerifyChunks(allocator, instructions);
    defer allocator.free(chunks);
    if (options.stage_reporter) |reporter| reporter.report("after_chunks", chunks.len, instructions.len);
    const worker_count = chooseVerifyWorkerCount(options.jobs, chunks.len);

    const body_result = if (worker_count > 1 and chunks.len > 0) blk: {
        const parallel = try verifyParallel(allocator, instructions, classified_lines, const_decls, &metadata, options.package_grants, options.sax_context, chunks, options.jobs, options.check_exit_leaks, options.default_immutable, options.rust_strict_mut, options.rust_copy_elision, options.stage_reporter);
        break :blk parallel;
    } else blk: {
        const serial = try verifyBody(allocator, instructions, classified_lines, const_decls, &metadata, 0, options.check_exit_leaks, options.package_grants, options.sax_context, options.default_immutable, options.rust_strict_mut, options.rust_copy_elision);
        if (options.stage_reporter) |reporter| reporter.report("after_body", instructions.len, instructions.len);
        break :blk serial;
    };

    switch (body_result) {
        .trap => |report| return .{ .trap = report },
        .ok => |body| {
            const owned_body = body;
            var finalized = false;
            defer if (!finalized) freeAnnotatedSlice(allocator, owned_body.annotated);
            const sigs_slice = try metadata.sigs.toOwnedSlice();
            errdefer {
                for (sigs_slice) |*item| item.deinit(allocator);
                allocator.free(sigs_slice);
            }

            symbols_moved = true;
            finalized = true;
            if (options.stage_reporter) |reporter| reporter.report("after_finalize", owned_body.annotated.len, instructions.len);
            return .{ .ok = .{
                .annotated = owned_body.annotated,
                .function_sigs = sigs_slice,
                .symbols = metadata.symbols,
                .const_decls = const_decls,
                .gas = body.gas,
            } };
        },
    }
}

pub fn verify(
    allocator: std.mem.Allocator,
    instructions: []const inst.Instruction,
    const_decls: []const const_decl.ConstDecl,
) !VerifyResult {
    return verifyWithOptions(allocator, instructions, const_decls, .{});
}

test "verifier preclassifies each instruction once" {
    const program = [_]inst.Instruction{
        .{
            .kind = .func_decl,
            .source_line = 1,
            .expanded_line = 0,
            .operands = .{
                .{ .symbol = 0 },
                .{ .func = 0 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "@main() -> i32:",
        },
        .{
            .kind = .assign,
            .source_line = 2,
            .expanded_line = 1,
            .operands = .{
                .{ .reg = 0 },
                .{ .imm_i64 = 1 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "x = 1",
        },
        .{
            .kind = .return_,
            .source_line = 3,
            .expanded_line = 2,
            .operands = .{
                .{ .reg = 0 },
                .{ .none = {} },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "return x",
        },
    };

    resetTestClassifyLineCount();
    const verified = try verifyWithOptions(std.testing.allocator, program[0..], &.{}, .{ .jobs = 1 });
    defer switch (verified) {
        .ok => |ok| {
            var owned = ok;
            owned.deinit(std.testing.allocator);
        },
        .trap => {},
    };
    try std.testing.expect(verified == .ok);
    try std.testing.expectEqual(program.len, readTestClassifyLineCount());
}

test "metadata errors map to explicit trap kinds" {
    try std.testing.expectEqual(trap.Trap.unsupported_type, metadataTrapKind(error.UnsupportedType));
    try std.testing.expectEqual(trap.Trap.arena_oom, metadataTrapKind(error.OutOfMemory));
    try std.testing.expectEqual(trap.Trap.test_func_signature_mismatch, metadataTrapKind(error.TestFuncSignatureMismatch));
    try std.testing.expectEqual(trap.Trap.invalid_atomic_ordering, metadataTrapKind(error.InvalidAtomicOrdering));
    try std.testing.expectEqual(trap.Trap.forbidden_syntax, metadataTrapKind(error.InvalidFunctionSig));
    try std.testing.expectEqual(trap.Trap.forbidden_syntax, metadataTrapKind(error.InvalidAtomicSyntax));
    try std.testing.expectEqual(trap.Trap.import_resolution_failed, metadataTrapKind(error.InvalidJoinState));
}

test "metadata atomic ordering failure keeps atomic trap code" {
    const program = [_]inst.Instruction{
        inst.makeInstruction(.func_decl, 1, 0, null, "@main() -> i32:"),
        inst.makeInstruction(.alloc, 2, 1, null, "node = alloc 8"),
        inst.makeInstruction(.cmpxchg, 3, 2, null, "old, ok = cmpxchg node+0, 0, 1 acquire seq_cst"),
        inst.makeInstruction(.return_, 4, 3, null, "return 0"),
    };

    const verified = try verify(std.testing.allocator, &program, &.{});
    switch (verified) {
        .trap => |report| {
            try std.testing.expectEqual(trap.Trap.invalid_atomic_ordering, report.trap);
            try std.testing.expectEqual(trap.trapCode(.invalid_atomic_ordering), report.trap_code orelse return error.TestUnexpectedResult);
            try std.testing.expect(std.mem.containsAtLeast(u8, report.message, 1, "invalid atomic ordering"));
        },
        .ok => return error.TestUnexpectedResult,
    }
}

test "verifier precomputes consumed registers once per function body" {
    const source =
        \\@fail() -> i32!:
        \\return 1
        \\@main() -> i32!:
        \\res = call @fail()
        \\leak_a = alloc 8
        \\leak_b = alloc 16
        \\leak_c = alloc 24
        \\ok = ? res
        \\return ok
    ;

    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    resetTestConsumedScanCount();
    const verified = try verifyWithOptions(std.testing.allocator, flat.instructions, flat.const_decls, .{ .jobs = 1 });
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.early_return_leak, report.trap),
        .ok => |ok| {
            var owned = ok;
            owned.deinit(std.testing.allocator);
            return error.TestUnexpectedResult;
        },
    }

    var expected_scanned: usize = 0;
    for (flat.instructions) |item| {
        if (!isDecl(item.kind)) expected_scanned += 1;
    }
    try std.testing.expectEqual(expected_scanned, readTestConsumedScanCount());
}

test "panic terminates without forcing a leak trap" {
    const program = [_]inst.Instruction{
        .{
            .kind = .func_decl,
            .source_line = 1,
            .expanded_line = 0,
            .operands = .{
                .{ .symbol = 0 },
                .{ .func = 0 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "@main() -> i32:",
        },
        .{
            .kind = .alloc,
            .source_line = 2,
            .expanded_line = 1,
            .operands = .{
                .{ .reg = 0 },
                .{ .imm_u64 = 8 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "x = alloc 8",
        },
        .{
            .kind = .panic,
            .source_line = 3,
            .expanded_line = 2,
            .operands = .{
                .{ .text = "7" },
                .{ .none = {} },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "panic(7)",
        },
    };

    const verified = try verify(std.testing.allocator, program[0..], &.{});
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 3), owned.annotated.len);
        },
        .trap => return error.TestUnexpectedResult,
    }
}

test "panic_msg is treated as a terminator" {
    const program = [_]inst.Instruction{
        .{
            .kind = .func_decl,
            .source_line = 1,
            .expanded_line = 0,
            .operands = .{
                .{ .symbol = 0 },
                .{ .func = 0 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "@main() -> i32:",
        },
        .{
            .kind = .alloc,
            .source_line = 2,
            .expanded_line = 1,
            .operands = .{
                .{ .reg = 1 },
                .{ .imm_u64 = 3 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "buf = alloc 3",
        },
        .{
            .kind = .panic_msg,
            .source_line = 3,
            .expanded_line = 2,
            .operands = .{
                .{ .text = "7" },
                .{ .text = "buf" },
                .{ .text = "2" },
                .{ .none = {} },
            },
            .raw_text = "panic_msg(7, *buf, 2)",
        },
    };

    const verified = try verify(std.testing.allocator, program[0..], &.{});
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 3), owned.annotated.len);
        },
        .trap => return error.TestUnexpectedResult,
    }
}

test "panic does not leak termination state into the next function" {
    const source =
        \\@first() -> i32:
        \\L_ENTRY:
        \\panic(7)
        \\@second() -> i32:
        \\L_ENTRY:
        \\return 0
    ;

    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 6), owned.annotated.len);
        },
        .trap => |report| {
            std.debug.print("trap={s} msg={s} line={} source_line={} source={s}\n", .{
                @tagName(report.trap),
                report.message,
                report.line,
                report.source_line,
                report.source_text orelse "",
            });
            return error.TestUnexpectedResult;
        },
    }
}

test "function scope rebuilds correctly with consts across declarations" {
    const source =
        \\@const MSG = utf8:"ok\\n"
        \\@first() -> i32:
        \\L_ENTRY:
        \\return 1
        \\@second() -> i32:
        \\L_ENTRY:
        \\return 0
    ;

    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.annotated.len > 0);
        },
        .trap => |report| {
            std.debug.print("trap={s} msg={s} line={} source_line={} source={s}\n", .{
                @tagName(report.trap),
                report.message,
                report.line,
                report.source_line,
                report.source_text orelse "",
            });
            return error.TestUnexpectedResult;
        },
    }
}

test "branch conditions are consumed by control flow" {
    const source =
        \\@main() -> i32:
        \\L_ENTRY:
        \\cond = eq 1, 1
        \\br cond -> L_OK, L_ERR
        \\L_OK:
        \\return 0
        \\L_ERR:
        \\return 1
    ;

    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.annotated.len > 0);
        },
        .trap => |report| {
            std.debug.print("trap={s} msg={s} line={} source_line={} source={s}\n", .{
                @tagName(report.trap),
                report.message,
                report.line,
                report.source_line,
                report.source_text orelse "",
            });
            return error.TestUnexpectedResult;
        },
    }
}

test "early return ignores immutable const data while checking for leaks" {
    const source =
        \\@const MSG = utf8:"ok\n"
        \\@fail() -> i32!:
        \\return 7
        \\@main() -> i32!:
        \\res = call @fail()
        \\value = ? res
        \\return value
    ;

    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.annotated.len > 0);
        },
        .trap => |report| {
            std.debug.print("trap={s} msg={s} line={} source_line={} source={s}\n", .{
                @tagName(report.trap),
                report.message,
                report.line,
                report.source_line,
                report.source_text orelse "",
            });
            return error.TestUnexpectedResult;
        },
    }
}

test "stack_alloc is exempt from memory leak and rejects escape" {
    const program = [_]inst.Instruction{
        .{
            .kind = .func_decl,
            .source_line = 1,
            .expanded_line = 0,
            .operands = .{
                .{ .symbol = 0 },
                .{ .func = 0 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "@main() -> i32:",
        },
        .{
            .kind = .stack_alloc,
            .source_line = 2,
            .expanded_line = 1,
            .operands = .{
                .{ .reg = 1 },
                .{ .imm_u64 = 8 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "tmp = stack_alloc 8",
        },
        .{
            .kind = .return_,
            .source_line = 3,
            .expanded_line = 2,
            .operands = .{
                .{ .text = "0" },
                .{ .none = {} },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "return 0",
        },
    };

    const verified = try verify(std.testing.allocator, program[0..], &.{});
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 3), owned.annotated.len);
        },
        .trap => return error.TestUnexpectedResult,
    }
}

test "interior pointers are consumed when their parent borrow is released" {
    const program = [_]inst.Instruction{
        .{
            .kind = .func_decl,
            .source_line = 1,
            .expanded_line = 0,
            .operands = .{
                .{ .symbol = 0 },
                .{ .func = 0 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "@main() -> i32:",
        },
        .{
            .kind = .alloc,
            .source_line = 2,
            .expanded_line = 1,
            .operands = .{
                .{ .reg = 1 },
                .{ .imm_u64 = 8 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "base = alloc 8",
        },
        .{
            .kind = .borrow,
            .source_line = 3,
            .expanded_line = 2,
            .operands = .{
                .{ .reg = 2 },
                .{ .text = "read" },
                .{ .reg = 1 },
                .{ .none = {} },
            },
            .raw_text = "view = & base",
        },
        .{
            .kind = .take,
            .source_line = 4,
            .expanded_line = 3,
            .operands = .{
                .{ .reg = 3 },
                .{ .reg = 2 },
                .{ .imm_u64 = 4 },
                .{ .none = {} },
            },
            .raw_text = "ip = take view+4",
        },
        .{
            .kind = .release,
            .source_line = 5,
            .expanded_line = 4,
            .operands = .{
                .{ .reg = 2 },
                .{ .none = {} },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "!view",
        },
        .{
            .kind = .return_,
            .source_line = 6,
            .expanded_line = 5,
            .operands = .{
                .{ .reg = 1 },
                .{ .none = {} },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "return base",
        },
    };

    const verified = try verify(std.testing.allocator, program[0..], &.{});
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 6), owned.annotated.len);
        },
        .trap => return error.TestUnexpectedResult,
    }
}

test "interior pointers trap when passed to extern calls" {
    const source =
        \\@ffi_wrapper sink(*p: ptr) -> i32:
        \\return 0
        \\@ffi_wrapper wrap() -> i32:
        \\base = alloc 8
        \\view = & base
        \\ip = take view+4
        \\call @sink(*ip)
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .trap => |report| {
            try std.testing.expectEqual(trap.Trap.interior_ptr_escape, report.trap);
        },
        .ok => return error.TestUnexpectedResult,
    }
}

test "borrowed views can upgrade to mutable write when unique" {
    const source =
        \\@main() -> i32:
        \\base = alloc 8
        \\view = & base
        \\store view+0, 7 as i8
        \\!view
        \\!base
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 7), owned.annotated.len);
        },
        .trap => return error.TestUnexpectedResult,
    }
}

test "borrowed parameters can be written through when unique" {
    const source =
        \\@bump(&box: ptr) -> void:
        \\value = load box+0 as i32
        \\next = add value, 1
        \\store box+0, next as i32
        \\!value
        \\!next
        \\!box
        \\return
        \\@main() -> i32:
        \\box = alloc 4
        \\store box+0, 9 as i32
        \\call @bump(&box)
        \\value = load box+0 as i32
        \\!value
        \\!box
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.annotated.len > 0);
        },
        .trap => |report| {
            std.debug.print("trap={s} msg={s}\n", .{ @tagName(report.trap), report.message });
            return error.TestUnexpectedResult;
        },
    }
}

test "borrowed parameters can be released without origin index overflow" {
    const source =
        \\@bump(&box: ptr) -> void:
        \\!box
        \\return
        \\@main() -> i32:
        \\box = alloc 4
        \\call @bump(&box)
        \\!box
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.annotated.len > 0);
        },
        .trap => |report| {
            std.debug.print("trap={s} msg={s}\n", .{ @tagName(report.trap), report.message });
            return error.TestUnexpectedResult;
        },
    }
}

test "borrowed views trap on write when shared" {
    const source =
        \\@main() -> i32:
        \\base = alloc 8
        \\view_a = & base
        \\view_b = & base
        \\store view_a+0, 7 as i8
        \\!view_a
        \\!view_b
        \\!base
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.read_write_conflict, report.trap),
        .ok => return error.TestUnexpectedResult,
    }
}

test "borrow view of stack_alloc traps on return escape" {
    const source =
        \\@helper() -> &ptr:
        \\tmp = stack_alloc 8
        \\view = & tmp
        \\return view
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.stack_escape, report.trap),
        .ok => return error.TestUnexpectedResult,
    }
}

test "borrow view of stack_alloc traps on move escape" {
    const source =
        \\@extern sink(^owned: ptr) -> i32
        \\@main() -> i32:
        \\tmp = stack_alloc 8
        \\view = & tmp
        \\value = call @sink(^view)
        \\!view
        \\!tmp
        \\return value
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.stack_escape, report.trap),
        .ok => return error.TestUnexpectedResult,
    }
}

fn fieldBorrowInstruction(kind: inst.InstKind, source_line: u32, expanded_line: u32, raw_text: []const u8, operands: [4]inst.Operand) inst.Instruction {
    var item = inst.makeInstruction(kind, source_line, expanded_line, null, raw_text);
    item.operands = operands;
    return item;
}

test "borrowed views trap when escaping across ffi boundary" {
    const source =
        \\@ffi_wrapper sink(*p: ptr) -> i32:
        \\return 0
        \\@ffi_wrapper wrap() -> i32:
        \\base = alloc 8
        \\view = & base
        \\ip = take view+0
        \\call @sink(*ip)
        \\!view
        \\!base
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.interior_ptr_escape, report.trap),
        .ok => return error.TestUnexpectedResult,
    }
}

test "borrowed views trap when source is released while borrowed" {
    const source =
        \\@main() -> i32:
        \\base = alloc 8
        \\view = & base
        \\!base
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.borrow_conflict, report.trap),
        .ok => return error.TestUnexpectedResult,
    }
}

test "field-level mutable borrows allow distinct static offsets" {
    const program = [_]inst.Instruction{
        fieldBorrowInstruction(.func_decl, 1, 0, "@main() -> i32:", .{ .{ .symbol = 0 }, .{ .func = 0 }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.alloc, 2, 1, "base = alloc 16", .{ .{ .reg = 1 }, .{ .imm_u64 = 16 }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.ptr_add, 3, 2, "field_a = ptr_add base, 0", .{ .{ .reg = 2 }, .{ .reg = 1 }, .{ .imm_i64 = 0 }, .{ .none = {} } }),
        fieldBorrowInstruction(.ptr_add, 4, 3, "field_b = ptr_add base, 8", .{ .{ .reg = 3 }, .{ .reg = 1 }, .{ .imm_i64 = 8 }, .{ .none = {} } }),
        fieldBorrowInstruction(.borrow, 5, 4, "view_a = borrow mut field_a", .{ .{ .reg = 4 }, .{ .text = "mut" }, .{ .reg = 2 }, .{ .none = {} } }),
        fieldBorrowInstruction(.borrow, 6, 5, "view_b = borrow mut field_b", .{ .{ .reg = 5 }, .{ .text = "mut" }, .{ .reg = 3 }, .{ .none = {} } }),
        fieldBorrowInstruction(.release, 7, 6, "!view_b", .{ .{ .reg = 5 }, .{ .none = {} }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.release, 8, 7, "!view_a", .{ .{ .reg = 4 }, .{ .none = {} }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.release, 9, 8, "!field_b", .{ .{ .reg = 3 }, .{ .none = {} }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.release, 10, 9, "!field_a", .{ .{ .reg = 2 }, .{ .none = {} }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.release, 11, 10, "!base", .{ .{ .reg = 1 }, .{ .none = {} }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.return_, 12, 11, "return 0", .{ .{ .imm_i64 = 0 }, .{ .none = {} }, .{ .none = {} }, .{ .none = {} } }),
    };

    const verified = try verify(std.testing.allocator, program[0..], &.{});
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
        },
        .trap => return error.TestUnexpectedResult,
    }
}

test "field-level mutable borrows reject identical static offsets" {
    const program = [_]inst.Instruction{
        fieldBorrowInstruction(.func_decl, 1, 0, "@main() -> i32:", .{ .{ .symbol = 0 }, .{ .func = 0 }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.alloc, 2, 1, "base = alloc 16", .{ .{ .reg = 1 }, .{ .imm_u64 = 16 }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.ptr_add, 3, 2, "field_a = ptr_add base, 0", .{ .{ .reg = 2 }, .{ .reg = 1 }, .{ .imm_i64 = 0 }, .{ .none = {} } }),
        fieldBorrowInstruction(.ptr_add, 4, 3, "field_b = ptr_add base, 0", .{ .{ .reg = 3 }, .{ .reg = 1 }, .{ .imm_i64 = 0 }, .{ .none = {} } }),
        fieldBorrowInstruction(.borrow, 5, 4, "view_a = borrow mut field_a", .{ .{ .reg = 4 }, .{ .text = "mut" }, .{ .reg = 2 }, .{ .none = {} } }),
        fieldBorrowInstruction(.borrow, 6, 5, "view_b = borrow mut field_b", .{ .{ .reg = 5 }, .{ .text = "mut" }, .{ .reg = 3 }, .{ .none = {} } }),
    };

    const verified = try verify(std.testing.allocator, program[0..], &.{});
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.read_write_conflict, report.trap),
        .ok => |ok| {
            var owned = ok;
            owned.deinit(std.testing.allocator);
            return error.TestUnexpectedResult;
        },
    }
}

test "ptr_add beyond allocation size traps borrow_conflict" {
    const program = [_]inst.Instruction{
        fieldBorrowInstruction(.func_decl, 1, 0, "@main() -> i32:", .{ .{ .symbol = 0 }, .{ .func = 0 }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.alloc, 2, 1, "base = alloc 8", .{ .{ .reg = 1 }, .{ .imm_u64 = 8 }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.ptr_add, 3, 2, "far = ptr_add base, 8", .{ .{ .reg = 2 }, .{ .reg = 1 }, .{ .imm_i64 = 8 }, .{ .none = {} } }),
    };

    const verified = try verify(std.testing.allocator, program[0..], &.{});
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.borrow_conflict, report.trap),
        .ok => |ok| {
            var owned = ok;
            owned.deinit(std.testing.allocator);
            return error.TestUnexpectedResult;
        },
    }
}

test "borrow view ptr_add beyond allocation size traps borrow_conflict" {
    const program = [_]inst.Instruction{
        fieldBorrowInstruction(.func_decl, 1, 0, "@main() -> i32:", .{ .{ .symbol = 0 }, .{ .func = 0 }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.alloc, 2, 1, "base = alloc 8", .{ .{ .reg = 1 }, .{ .imm_u64 = 8 }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.borrow, 3, 2, "view = borrow base", .{ .{ .reg = 2 }, .{ .text = "read" }, .{ .reg = 1 }, .{ .none = {} } }),
        fieldBorrowInstruction(.ptr_add, 4, 3, "far = ptr_add view, 8", .{ .{ .reg = 3 }, .{ .reg = 2 }, .{ .imm_i64 = 8 }, .{ .none = {} } }),
        fieldBorrowInstruction(.release, 5, 4, "!view", .{ .{ .reg = 2 }, .{ .none = {} }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.release, 6, 5, "!far", .{ .{ .reg = 3 }, .{ .none = {} }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.release, 7, 6, "!base", .{ .{ .reg = 1 }, .{ .none = {} }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.return_, 8, 7, "return 0", .{ .{ .imm_i64 = 0 }, .{ .none = {} }, .{ .none = {} }, .{ .none = {} } }),
    };

    const verified = try verify(std.testing.allocator, program[0..], &.{});
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.borrow_conflict, report.trap),
        .ok => |ok| {
            var owned = ok;
            owned.deinit(std.testing.allocator);
            return error.TestUnexpectedResult;
        },
    }
}

test "load with offset beyond allocation size traps borrow_conflict" {
    const program = [_]inst.Instruction{
        fieldBorrowInstruction(.func_decl, 1, 0, "@main() -> i32:", .{ .{ .symbol = 0 }, .{ .func = 0 }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.alloc, 2, 1, "base = alloc 8", .{ .{ .reg = 1 }, .{ .imm_u64 = 8 }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.load, 3, 2, "v = load base+8 as u64", .{ .{ .reg = 2 }, .{ .reg = 1 }, .{ .imm_u64 = 8 }, .{ .ty = @intFromEnum(sig.PrimType.u64) } }),
    };

    const verified = try verify(std.testing.allocator, program[0..], &.{});
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.borrow_conflict, report.trap),
        .ok => |ok| {
            var owned = ok;
            owned.deinit(std.testing.allocator);
            return error.TestUnexpectedResult;
        },
    }
}

test "in-bounds borrow view offsets still verify" {
    const program = [_]inst.Instruction{
        fieldBorrowInstruction(.func_decl, 1, 0, "@main() -> i32:", .{ .{ .symbol = 0 }, .{ .func = 0 }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.alloc, 2, 1, "base = alloc 16", .{ .{ .reg = 1 }, .{ .imm_u64 = 16 }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.borrow, 3, 2, "view = borrow base", .{ .{ .reg = 2 }, .{ .text = "read" }, .{ .reg = 1 }, .{ .none = {} } }),
        fieldBorrowInstruction(.ptr_add, 4, 3, "field = ptr_add view, 8", .{ .{ .reg = 3 }, .{ .reg = 2 }, .{ .imm_i64 = 8 }, .{ .none = {} } }),
        fieldBorrowInstruction(.release, 5, 4, "!field", .{ .{ .reg = 3 }, .{ .none = {} }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.release, 6, 5, "!view", .{ .{ .reg = 2 }, .{ .none = {} }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.release, 7, 6, "!base", .{ .{ .reg = 1 }, .{ .none = {} }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.return_, 8, 7, "return 0", .{ .{ .imm_i64 = 0 }, .{ .none = {} }, .{ .none = {} }, .{ .none = {} } }),
    };

    const verified = try verify(std.testing.allocator, program[0..], &.{});
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
        },
        .trap => return error.TestUnexpectedResult,
    }
}

test "whole-object mutable borrow rejects active field borrow" {
    const program = [_]inst.Instruction{
        fieldBorrowInstruction(.func_decl, 1, 0, "@main() -> i32:", .{ .{ .symbol = 0 }, .{ .func = 0 }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.alloc, 2, 1, "base = alloc 16", .{ .{ .reg = 1 }, .{ .imm_u64 = 16 }, .{ .none = {} }, .{ .none = {} } }),
        fieldBorrowInstruction(.ptr_add, 3, 2, "field_a = ptr_add base, 0", .{ .{ .reg = 2 }, .{ .reg = 1 }, .{ .imm_i64 = 0 }, .{ .none = {} } }),
        fieldBorrowInstruction(.borrow, 4, 3, "view_a = borrow mut field_a", .{ .{ .reg = 3 }, .{ .text = "mut" }, .{ .reg = 2 }, .{ .none = {} } }),
        fieldBorrowInstruction(.borrow, 5, 4, "view_base = borrow mut base", .{ .{ .reg = 4 }, .{ .text = "mut" }, .{ .reg = 1 }, .{ .none = {} } }),
    };

    const verified = try verify(std.testing.allocator, program[0..], &.{});
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.read_write_conflict, report.trap),
        .ok => |ok| {
            var owned = ok;
            owned.deinit(std.testing.allocator);
            return error.TestUnexpectedResult;
        },
    }
}

test "sax verifier hook maps state writes outside ffi wrappers to sax trap" {
    const source =
        \\@main() -> i32:
        \\state = alloc 8
        \\store state+0, 1 as i64
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verifyWithOptions(std.testing.allocator, flat.instructions, flat.const_decls, .{ .sax_context = .{ .component_name = "App" } });
    switch (verified) {
        .trap => |report| {
            try std.testing.expectEqual(trap.Trap.sax_state_write_from_outside, report.trap);
            try std.testing.expectEqualStrings("App", std.mem.sliceTo(&report.function_buf, 0));
        },
        .ok => return error.TestUnexpectedResult,
    }
}

test "sax verifier hook maps render outside ffi wrappers to sax trap" {
    const source =
        \\@main() -> i32:
        \\call @render()
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verifyWithOptions(std.testing.allocator, flat.instructions, flat.const_decls, .{ .sax_context = .{ .component_name = "App" } });
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.sax_render_outside_handler, report.trap),
        .ok => return error.TestUnexpectedResult,
    }
}

test "mutable borrow of the same source after shared borrow traps borrow conflict" {
    const program = [_]inst.Instruction{
        .{
            .kind = .func_decl,
            .source_line = 1,
            .expanded_line = 0,
            .operands = .{
                .{ .symbol = 0 },
                .{ .func = 0 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "@main() -> i32:",
        },
        .{
            .kind = .alloc,
            .source_line = 2,
            .expanded_line = 1,
            .operands = .{
                .{ .reg = 1 },
                .{ .imm_u64 = 8 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "base = alloc 8",
        },
        .{
            .kind = .borrow,
            .source_line = 3,
            .expanded_line = 2,
            .operands = .{
                .{ .reg = 2 },
                .{ .text = "read" },
                .{ .reg = 1 },
                .{ .none = {} },
            },
            .raw_text = "view_a = & base",
        },
        .{
            .kind = .borrow,
            .source_line = 4,
            .expanded_line = 3,
            .operands = .{
                .{ .reg = 3 },
                .{ .text = "mut" },
                .{ .reg = 1 },
                .{ .none = {} },
            },
            .raw_text = "view_b = borrow mut base",
        },
    };

    const verified = try verify(std.testing.allocator, program[0..], &.{});
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.read_write_conflict, report.trap),
        .ok => return error.TestUnexpectedResult,
    }
}

test "assume_borrow marks ffi borrow state and release clears it without freeing" {
    const source =
        \\@ffi_wrapper wrap(*raw: ptr) -> i32:
        \\view = assume_borrow raw
        \\!view
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            var saw_assume = false;
            var saw_release = false;
            for (owned.annotated) |item| {
                if (item.base.kind == .assume_borrow) {
                    saw_assume = true;
                    var found = false;
                    for (item.delta.changes) |change| {
                        if (change.reg == item.base.operands[0].reg) {
                            found = true;
                            try std.testing.expect((change.after & maskOf(.ffi_borrow)) != 0);
                            try std.testing.expect((change.after & maskOf(.borrow_view)) != 0);
                            break;
                        }
                    }
                    try std.testing.expect(found);
                } else if (item.base.kind == .release) {
                    saw_release = true;
                    var found = false;
                    for (item.delta.changes) |change| {
                        if (change.reg == item.base.operands[0].reg) {
                            found = true;
                            try std.testing.expectEqual(@as(u16, 0), change.after);
                            break;
                        }
                    }
                    try std.testing.expect(found);
                }
            }
            try std.testing.expect(saw_assume);
            try std.testing.expect(saw_release);
        },
        .trap => return error.TestUnexpectedResult,
    }
}

test "ffi borrow views can be moved or returned" {
    const move_source =
        \\@ffi_wrapper wrap(*raw: ptr) -> i32:
        \\view = assume_borrow raw
        \\^view
        \\return 0
    ;
    var move_flat = try @import("flattener.zig").flatten(std.testing.allocator, move_source);
    defer move_flat.deinit(std.testing.allocator);

    const moved = try verify(std.testing.allocator, move_flat.instructions, move_flat.const_decls);
    switch (moved) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            var saw_move = false;
            for (owned.annotated) |item| {
                if (item.base.kind == .move_) {
                    saw_move = true;
                }
            }
            try std.testing.expect(saw_move);
        },
        .trap => return error.TestUnexpectedResult,
    }

    const return_source =
        \\@ffi_wrapper wrap(*raw: ptr) -> &ptr:
        \\view = assume_borrow raw
        \\return view
    ;
    var return_flat = try @import("flattener.zig").flatten(std.testing.allocator, return_source);
    defer return_flat.deinit(std.testing.allocator);

    const returned = try verify(std.testing.allocator, return_flat.instructions, return_flat.const_decls);
    switch (returned) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            var saw_return = false;
            for (owned.annotated) |item| {
                if (item.base.kind == .return_ and item.base.operands[0] == .reg) {
                    saw_return = true;
                }
            }
            try std.testing.expect(saw_return);
        },
        .trap => return error.TestUnexpectedResult,
    }
}

test "immutable const data can be read and printed without leak traps" {
    var consts = [_]const_decl.ConstDecl{
        .{
            .source_line = 1,
            .expanded_line = 0,
            .raw_text = try std.testing.allocator.dupe(u8, "@const HELLO_MSG = utf8:\"hello, saasm\\n\""),
            .name = try std.testing.allocator.dupe(u8, "HELLO_MSG"),
            .literal_text = try std.testing.allocator.dupe(u8, "utf8:\"hello, saasm\\n\""),
            .value = .{
                .utf8 = .{
                    .kind = .utf8,
                    .bytes = try std.testing.allocator.dupe(u8, "hello, saasm\n"),
                    .repeat_count = null,
                    .repeat_byte = null,
                },
            },
        },
    };
    defer {
        for (&consts) |*decl| decl.deinit(std.testing.allocator);
    }

    const program = [_]inst.Instruction{
        .{
            .kind = .extern_decl,
            .source_line = 1,
            .expanded_line = 0,
            .operands = .{
                .{ .symbol = 2 },
                .{ .func = 1 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "@extern sa_print_bytes(&msg: ptr, len: u64) -> void",
        },
        .{
            .kind = .func_decl,
            .source_line = 2,
            .expanded_line = 1,
            .operands = .{
                .{ .symbol = 0 },
                .{ .func = 0 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "@main() -> i32:",
        },
        .{
            .kind = .label,
            .source_line = 3,
            .expanded_line = 2,
            .operands = .{
                .{ .symbol = 1 },
                .{ .label = 1 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "L_ENTRY:",
        },
        .{
            .kind = .call,
            .source_line = 4,
            .expanded_line = 3,
            .operands = .{
                .{ .text = "call @sa_print_bytes(&HELLO_MSG, 13)" },
                .{ .none = {} },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "call @sa_print_bytes(&HELLO_MSG, 13)",
        },
        .{
            .kind = .return_,
            .source_line = 5,
            .expanded_line = 4,
            .operands = .{
                .{ .text = "0" },
                .{ .none = {} },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "return 0",
        },
    };

    const verified = try verify(std.testing.allocator, program[0..], consts[0..]);
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 5), owned.annotated.len);
        },
        .trap => return error.TestUnexpectedResult,
    }
}

test "loop snapshots ignore stable extern calls that touch const data" {
    const source =
        \\@extern sa_print_bytes(&msg: ptr, len: u64) -> i32
        \\@const HELLO_MSG = utf8:"hello"
        \\@helper() -> i32:
        \\L_HELPER:
        \\printed = call @sa_print_bytes(&HELLO_MSG, 5)
        \\return printed
        \\@main(n: u64) -> i32:
        \\L_ENTRY:
        \\i_slot = stack_alloc 8
        \\store i_slot+0, 0 as u64
        \\jmp L_COND
        \\L_COND:
        \\i = load i_slot+0 as u64
        \\keep_going = ult i, n
        \\br keep_going -> L_BODY, L_EXIT
        \\L_BODY:
        \\printed = call @helper()
        \\next = add i, 1
        \\store i_slot+0, next as u64
        \\!next
        \\!printed
        \\!i
        \\!keep_going
        \\jmp L_COND
        \\L_EXIT:
        \\!i
        \\!keep_going
        \\!n
        \\return 0
    ;

    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.annotated.len > 0);
        },
        .trap => |report| {
            std.debug.print("trap={s} msg={s} line={} source_line={} source={s} register={s}\n", .{
                @tagName(report.trap),
                report.message,
                report.line,
                report.source_line,
                report.source_text orelse "",
                report.register orelse "",
            });
            return error.TestUnexpectedResult;
        },
    }
}

test "bodyless extern at end does not leak its signature parameters" {
    const source =
        \\@main() -> i32:
        \\L_ENTRY:
        \\return 0
        \\@extern sa_http_client_free(^client: ptr) -> u32
    ;

    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const serial = try verifyWithOptions(std.testing.allocator, flat.instructions, flat.const_decls, .{ .jobs = 1 });
    switch (serial) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 2), owned.function_sigs.len);
        },
        .trap => |report| {
            std.debug.print("serial trap={s} msg={s} source={s} register={s}\n", .{
                @tagName(report.trap),
                report.message,
                report.source_text orelse "",
                report.register orelse "",
            });
            return error.TestUnexpectedResult;
        },
    }

    const parallel = try verifyWithOptions(std.testing.allocator, flat.instructions, flat.const_decls, .{ .jobs = 2 });
    switch (parallel) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 2), owned.function_sigs.len);
        },
        .trap => |report| {
            std.debug.print("parallel trap={s} msg={s} source={s} register={s}\n", .{
                @tagName(report.trap),
                report.message,
                report.source_text orelse "",
                report.register orelse "",
            });
            return error.TestUnexpectedResult;
        },
    }
}

test "function declaration operands do not pollute previous function scope" {
    const source =
        \\@first() -> i32:
        \\L_FIRST:
        \\left = add 1, 1
        \\!left
        \\return 0
        \\@second(&out_len: ptr) -> i32:
        \\L_SECOND:
        \\!out_len
        \\return 0
    ;

    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 2), owned.function_sigs.len);
            for (owned.function_sigs[0].reg_ids) |reg_id| {
                const name = owned.symbols.lookupName(reg_id) orelse "";
                try std.testing.expect(!std.mem.eql(u8, name, "out_len"));
            }
        },
        .trap => |report| {
            std.debug.print("trap={s} msg={s} line={} source_line={} source={s} register={s}\n", .{
                @tagName(report.trap),
                report.message,
                report.line,
                report.source_line,
                report.source_text orelse "",
                report.register orelse "",
            });
            return error.TestUnexpectedResult;
        },
    }
}

test "verifier rejects call-site capability prefix mismatches" {
    const source =
        \\@extern sink(&p: ptr, ^q: ptr) -> i32
        \\@main() -> i32:
        \\left = alloc 8
        \\right = alloc 8
        \\value = call @sink(^left, ^right)
        \\!left
        \\return value
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.capability_mismatch, report.trap),
        .ok => return error.TestUnexpectedResult,
    }
}

test "verifier preserves by-value ptr fallible extern capability across metadata" {
    const source =
        \\@extern free_like(buffer: ptr) -> i32!
        \\@extern consume_later(^owned: ptr) -> i32
        \\@helper(value: i32) -> i32:
        \\return value
        \\@main() -> i32:
        \\buffer = alloc 8
        \\result = call @free_like(buffer)
        \\!result
        \\!buffer
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .trap => |report| {
            std.debug.print("trap={s} msg={s} source={s}\n", .{
                @tagName(report.trap),
                report.message,
                report.source_text orelse "",
            });
            return error.TestUnexpectedResult;
        },
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            const free_like_sig = for (owned.function_sigs) |item| {
                if (std.mem.eql(u8, item.name, "free_like")) break item;
            } else return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 1), free_like_sig.params.len);
            try std.testing.expectEqual(inst.CapPrefix.by_value, free_like_sig.params[0].cap);
            try std.testing.expectEqual(sig.PrimType.ptr, free_like_sig.params[0].ty);
            try std.testing.expect(free_like_sig.return_fallible);
        },
    }
}

fn packageSourceHashForIdentity(instructions: []const inst.Instruction, identity: []const u8) ?[32]u8 {
    for (instructions) |item| {
        if (item.package_identity) |item_identity| {
            if (std.mem.eql(u8, item_identity, identity)) {
                if (item.package_source_sha256) |hash| return hash;
            }
        }
    }
    return null;
}

fn makePackageGrant(
    allocator: std.mem.Allocator,
    url: []const u8,
    ref: []const u8,
    source_sha256: [32]u8,
    grants: []const pkg_manifest.Capability,
) !pkg_manifest.RequireEntry {
    return .{
        .url = try allocator.dupe(u8, url),
        .ref = try allocator.dupe(u8, ref),
        .source_sha256 = source_sha256,
        .grants = try allocator.dupe(pkg_manifest.Capability, grants),
        .upstream_loc = .{ .file = try allocator.dupe(u8, "sa.mod"), .line = 1, .col = 1 },
    };
}

fn verifyPackageIntrinsicProgram(
    allocator: std.mem.Allocator,
    package_body: []const u8,
    grant_caps: []const pkg_manifest.Capability,
    mismatch_hash: bool,
) !VerifyResult {
    const root_source = "@import \"github.com/example/pkg\"\n";

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makePath("sa_vendor/github.com/example/pkg");

    var pkg_main = try tmp.dir.createFile("sa_vendor/github.com/example/pkg/index.sa", .{ .truncate = true });
    try pkg_main.writeAll(package_body);
    pkg_main.close();

    var main_file = try tmp.dir.createFile("main.sa", .{ .truncate = true });
    try main_file.writeAll(root_source);
    main_file.close();

    const source_text = try tmp.dir.readFileAlloc(allocator, "main.sa", 4096);
    defer allocator.free(source_text);

    const path = try tmp.dir.realpathAlloc(allocator, "main.sa");
    defer allocator.free(path);
    const project_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(project_root);

    var flat = try @import("flattener.zig").flattenFileWithPackages(
        allocator,
        path,
        source_text,
        .{
            .options = .{ .project_root = project_root },
        },
    );
    defer flat.deinit(allocator);

    const package_hash = packageSourceHashForIdentity(flat.instructions, "github.com/example/pkg") orelse return error.TestUnexpectedResult;
    var grant_hash = package_hash;
    if (mismatch_hash) {
        grant_hash[0] ^= 0xFF;
    }

    var grants = [_]pkg_manifest.RequireEntry{
        try makePackageGrant(allocator, "github.com/example/pkg", "main", grant_hash, grant_caps),
    };
    defer grants[0].deinit(allocator);

    return try verifyWithOptions(allocator, flat.instructions, flat.const_decls, .{ .package_grants = grants[0..] });
}

test "verifier rejects ungranted sys file write for package instructions" {
    const result = try verifyPackageIntrinsicProgram(std.testing.allocator,
        \\@main() -> i32:
        \\L_ENTRY:
        \\path = alloc 8
        \\data = alloc 8
        \\value = call @sys_write_file(*path, 4, *data, 4)
        \\!path
        \\!data
        \\return value
    , &.{}, false);
    switch (result) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.unauthorized_primitive, report.trap),
        .ok => return error.TestUnexpectedResult,
    }
}

test "verifier allows granted sys file write for package instructions" {
    const result = try verifyPackageIntrinsicProgram(std.testing.allocator,
        \\@main() -> i32:
        \\L_ENTRY:
        \\path = alloc 8
        \\data = alloc 8
        \\value = call @sys_write_file(*path, 4, *data, 4)
        \\!path
        \\!data
        \\return value
    , &.{.io_write}, false);
    switch (result) {
        .trap => return error.TestUnexpectedResult,
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.annotated.len > 0);
        },
    }
}

test "verifier allows granted sys print for package instructions" {
    const result = try verifyPackageIntrinsicProgram(std.testing.allocator,
        \\@main() -> i32:
        \\L_ENTRY:
        \\msg = alloc 8
        \\call @sys_print(*msg, 5)
        \\!msg
        \\return 0
    , &.{.io_write}, false);
    switch (result) {
        .trap => return error.TestUnexpectedResult,
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.annotated.len > 0);
        },
    }
}

test "verifier allows granted sys exit for package instructions" {
    const result = try verifyPackageIntrinsicProgram(std.testing.allocator,
        \\@main() -> i32:
        \\L_ENTRY:
        \\code = call @sys_exit(0)
        \\return code
    , &.{.proc_exit}, false);
    switch (result) {
        .trap => return error.TestUnexpectedResult,
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.annotated.len > 0);
        },
    }
}

test "verifier allows granted sys argc for package instructions" {
    const result = try verifyPackageIntrinsicProgram(std.testing.allocator,
        \\@main() -> i32:
        \\L_ENTRY:
        \\argc = call @sys_argc()
        \\return argc
    , &.{.proc_args}, false);
    switch (result) {
        .trap => return error.TestUnexpectedResult,
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.annotated.len > 0);
        },
    }
}

test "verifier allows granted sys argv for package instructions" {
    const result = try verifyPackageIntrinsicProgram(std.testing.allocator,
        \\@main() -> i32:
        \\L_ENTRY:
        \\argv = call @sys_argv(0)
        \\return 0
    , &.{.proc_args}, false);
    switch (result) {
        .trap => return error.TestUnexpectedResult,
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expect(owned.annotated.len > 0);
        },
    }
}

test "verifier rejects package source hash mismatch for granted sys write" {
    const result = try verifyPackageIntrinsicProgram(std.testing.allocator,
        \\@main() -> i32:
        \\L_ENTRY:
        \\path = alloc 8
        \\data = alloc 8
        \\value = call @sys_write_file(*path, 4, *data, 4)
        \\!path
        \\!data
        \\return value
    , &.{.io_write}, true);
    switch (result) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.upstream_sha_mismatch, report.trap),
        .ok => return error.TestUnexpectedResult,
    }
}

test "verifier call contract PBT traps on random prefix mismatches" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6121);
    const random = prng.random();
    const caps = [_]struct { text: []const u8, prefix: inst.CapPrefix }{
        .{ .text = "", .prefix = .by_value },
        .{ .text = "&", .prefix = .borrow },
        .{ .text = "^", .prefix = .move },
    };

    for (0..48) |iter| {
        const expected = if (random.boolean()) caps[1] else caps[2];
        var actual = caps[random.intRangeLessThan(usize, 0, caps.len)];
        if (actual.prefix == expected.prefix) {
            actual = caps[(random.intRangeLessThan(usize, 1, caps.len) + @intFromEnum(expected.prefix)) % caps.len];
            if (actual.prefix == expected.prefix) actual = caps[(@intFromEnum(expected.prefix) + 1) % caps.len];
        }

        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\@extern sink({s}p: ptr) -> i32
            \\@main() -> i32:
            \\value = alloc 8
            \\ret = call @sink({s}value)
            \\!value
            \\return ret
        , .{ expected.text, actual.text });
        defer std.testing.allocator.free(source);

        var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
        defer flat.deinit(std.testing.allocator);

        const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
        switch (verified) {
            .trap => |report| try std.testing.expectEqual(trap.Trap.capability_mismatch, report.trap),
            .ok => {
                _ = iter;
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "native escape conservatively consumes referenced registers" {
    const source =
        \\@main() -> i32:
        \\value = alloc 8
        \\$touch value$
        \\probe = load value+0 as i8
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.use_after_move, report.trap),
        .ok => |ok| {
            var owned = ok;
            owned.deinit(std.testing.allocator);
            return error.TestUnexpectedResult;
        },
    }
}

test "native escape rejects stack allocations crossing the boundary" {
    const source =
        \\@main() -> i32:
        \\tmp = stack_alloc 8
        \\$touch tmp$
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.stack_escape, report.trap),
        .ok => |ok| {
            var owned = ok;
            owned.deinit(std.testing.allocator);
            return error.TestUnexpectedResult;
        },
    }
}

test "native escape PBT conservatively consumes random referenced registers" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6300);
    const random = prng.random();

    for (0..32) |_| {
        const size = random.intRangeAtMost(u64, 1, 64);
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\@main() -> i32:
            \\value = alloc {d}
            \\$touch value$
            \\probe = load value+0 as i8
            \\return 0
        , .{size});
        defer std.testing.allocator.free(source);

        var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
        defer flat.deinit(std.testing.allocator);

        const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
        switch (verified) {
            .trap => |report| try std.testing.expectEqual(trap.Trap.use_after_move, report.trap),
            .ok => |ok| {
                var owned = ok;
                owned.deinit(std.testing.allocator);
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "early return leak PBT traps when random live allocations survive the fail edge" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6244);
    const random = prng.random();

    for (0..32) |_| {
        const extra_count = random.intRangeAtMost(usize, 1, 4);
        var source = std.array_list.Managed(u8).init(std.testing.allocator);
        defer source.deinit();

        try source.appendSlice(
            \\@fail() -> i32!:
            \\return 1
            \\@main() -> i32!:
            \\res = call @fail()
        );
        try source.append('\n');

        for (0..extra_count) |idx| {
            try source.print("leak_{d} = alloc {d}\n", .{ idx, random.intRangeAtMost(u64, 1, 64) });
        }

        try source.appendSlice(
            \\ok = ? res
            \\return ok
        );
        try source.append('\n');

        var flat = try @import("flattener.zig").flatten(std.testing.allocator, source.items);
        defer flat.deinit(std.testing.allocator);

        const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
        switch (verified) {
            .trap => |report| try std.testing.expectEqual(trap.Trap.early_return_leak, report.trap),
            .ok => return error.TestUnexpectedResult,
        }
    }
}

test "gas report stays bounded for forward jumps" {
    const program = [_]inst.Instruction{
        .{
            .kind = .func_decl,
            .source_line = 1,
            .expanded_line = 0,
            .operands = .{
                .{ .symbol = 0 },
                .{ .func = 0 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "@main() -> i32:",
        },
        .{
            .kind = .jmp,
            .source_line = 2,
            .expanded_line = 1,
            .operands = .{
                .{ .symbol = 1 },
                .{ .label = 1 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "jmp L_END",
        },
        .{
            .kind = .label,
            .source_line = 3,
            .expanded_line = 2,
            .operands = .{
                .{ .symbol = 1 },
                .{ .label = 1 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "L_END:",
        },
        .{
            .kind = .return_,
            .source_line = 4,
            .expanded_line = 3,
            .operands = .{
                .{ .text = "0" },
                .{ .none = {} },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "return 0",
        },
    };

    const verified = try verify(std.testing.allocator, program[0..], &.{});
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(u64, 0), owned.gas.max_alloc_bytes);
            try std.testing.expectEqual(false, owned.gas.has_unbounded_loop);
            switch (owned.gas.max_instruction_steps) {
                .bounded => |steps| try std.testing.expectEqual(@as(u64, 2), steps),
                .unbounded => return error.TestUnexpectedResult,
            }
        },
        .trap => return error.TestUnexpectedResult,
    }
}

test "gas report marks backward jumps as unbounded" {
    const program = [_]inst.Instruction{
        .{
            .kind = .func_decl,
            .source_line = 1,
            .expanded_line = 0,
            .operands = .{
                .{ .symbol = 0 },
                .{ .func = 0 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "@main() -> i32:",
        },
        .{
            .kind = .label,
            .source_line = 2,
            .expanded_line = 1,
            .operands = .{
                .{ .symbol = 1 },
                .{ .label = 1 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "L_LOOP:",
        },
        .{
            .kind = .jmp,
            .source_line = 3,
            .expanded_line = 2,
            .operands = .{
                .{ .symbol = 1 },
                .{ .label = 1 },
                .{ .none = {} },
                .{ .none = {} },
            },
            .raw_text = "jmp L_LOOP",
        },
    };

    const verified = try verify(std.testing.allocator, program[0..], &.{});
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(true, owned.gas.has_unbounded_loop);
            switch (owned.gas.max_instruction_steps) {
                .unbounded => |info| try std.testing.expectEqual(@as(u64, 1), info.bounded_prefix),
                .bounded => return error.TestUnexpectedResult,
            }
        },
        .trap => return error.TestUnexpectedResult,
    }
}

const VerifyOkSnapshot = struct {
    annotated: []const AnnotatedInstruction,
    function_sigs: []const sig.FunctionSig,
    symbol_names: []const []const u8,
    gas: gas.GasReport,
};

const VerifySnapshot = union(enum) {
    ok: VerifyOkSnapshot,
    trap: trap.TrapReport,
};

fn trapSnapshot(report: trap.TrapReport) struct {
    trap: trap.Trap,
    trap_code: u32,
    line: u32,
    source_line: u32,
    message: []const u8,
    register: []const u8,
    function: []const u8,
} {
    return .{
        .trap = report.trap,
        .trap_code = report.trap_code orelse 0,
        .line = report.line,
        .source_line = report.source_line,
        .message = report.message,
        .register = if (report.register) |text| text else std.mem.sliceTo(&report.register_buf, 0),
        .function = if (report.function) |text| text else std.mem.sliceTo(&report.function_buf, 0),
    };
}

fn expectVerifyResultEqual(lhs: VerifyResult, rhs: VerifyResult) !void {
    switch (lhs) {
        .ok => |l_ok| switch (rhs) {
            .ok => |r_ok| {
                try std.testing.expectEqual(l_ok.annotated.len, r_ok.annotated.len);
                try std.testing.expectEqual(l_ok.function_sigs.len, r_ok.function_sigs.len);
                try std.testing.expectEqualDeep(l_ok.gas, r_ok.gas);
                try std.testing.expectEqualDeep(l_ok.symbols.names.items, r_ok.symbols.names.items);
            },
            .trap => return error.TestUnexpectedResult,
        },
        .trap => |l_trap| switch (rhs) {
            .trap => |r_trap| {
                const lhs_snap = trapSnapshot(l_trap);
                const rhs_snap = trapSnapshot(r_trap);
                try std.testing.expectEqualDeep(lhs_snap, rhs_snap);
            },
            .ok => return error.TestUnexpectedResult,
        },
    }
}

test "verifyWithOptions serial and parallel results are identical" {
    const source =
        \\@first() -> i32:
        \\a = alloc 8
        \\!a
        \\return 0
        \\
        \\@second() -> i32:
        \\b = alloc 8
        \\!b
        \\return 1
    ;

    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const serial = try verifyWithOptions(std.testing.allocator, flat.instructions, flat.const_decls, .{ .jobs = 1 });
    const parallel = try verifyWithOptions(std.testing.allocator, flat.instructions, flat.const_decls, .{ .jobs = 2 });

    defer switch (serial) {
        .ok => |ok| {
            var owned = ok;
            owned.deinit(std.testing.allocator);
        },
        .trap => {},
    };
    defer switch (parallel) {
        .ok => |ok| {
            var owned = ok;
            owned.deinit(std.testing.allocator);
        },
        .trap => {},
    };

    try expectVerifyResultEqual(serial, parallel);
}

test "verifyWithOptions serial and parallel traps are identical" {
    const source =
        \\@first() -> i32:
        \\return missing_value
        \\
        \\@second() -> i32:
        \\return 0
    ;

    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const serial = try verifyWithOptions(std.testing.allocator, flat.instructions, flat.const_decls, .{ .jobs = 1 });
    const parallel = try verifyWithOptions(std.testing.allocator, flat.instructions, flat.const_decls, .{ .jobs = 2 });

    try expectVerifyResultEqual(serial, parallel);
}

const GasFixture = struct {
    instructions: []inst.Instruction,
    owned_texts: [][]u8,
    expected_alloc_bytes: u64,
    expected_steps: u64,
    has_unbounded_loop: bool,

    fn deinit(self: *GasFixture, allocator: std.mem.Allocator) void {
        for (self.owned_texts) |text| allocator.free(text);
        allocator.free(self.owned_texts);
        allocator.free(self.instructions);
        self.* = undefined;
    }
};

fn snapshotResult(result: VerifyResult) VerifySnapshot {
    return switch (result) {
        .ok => |ok| .{
            .ok = .{
                .annotated = ok.annotated,
                .function_sigs = ok.function_sigs,
                .symbol_names = ok.symbols.names.items,
                .gas = ok.gas,
            },
        },
        .trap => |report| .{ .trap = report },
    };
}

fn appendOwnedText(
    texts: *std.array_list.Managed([]u8),
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) ![]const u8 {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    errdefer allocator.free(text);
    try texts.append(text);
    return text;
}

fn buildGasFixture(
    allocator: std.mem.Allocator,
    random: std.Random,
    bounded: bool,
) !GasFixture {
    var instructions = std.array_list.Managed(inst.Instruction).init(allocator);
    var instructions_moved = false;
    defer if (!instructions_moved) instructions.deinit();

    var owned_texts = std.array_list.Managed([]u8).init(allocator);
    var owned_texts_moved = false;
    defer if (!owned_texts_moved) {
        for (owned_texts.items) |text| allocator.free(text);
        owned_texts.deinit();
    };

    const size_choices = [_]u64{ 0, 1, 2, 8, 13, 21, 34, 55, 89, 144 };
    const size = size_choices[random.intRangeLessThan(usize, 0, size_choices.len)];
    const fence_count = random.intRangeAtMost(usize, 0, 4);
    const stack_text = try appendOwnedText(&owned_texts, allocator, "tmp = stack_alloc {d}", .{size});

    var item = inst.makeInstruction(.func_decl, 1, 0, null, "@main() -> i32:");
    item.operands[0] = .{ .symbol = 0 };
    item.operands[1] = .{ .func = 0 };
    try instructions.append(item);

    item = inst.makeInstruction(.stack_alloc, 2, 1, null, stack_text);
    item.operands[0] = .{ .reg = 1 };
    item.operands[1] = .{ .imm_u64 = size };
    try instructions.append(item);

    for (0..fence_count) |idx| {
        item = inst.makeInstruction(.fence, @intCast(3 + idx), @intCast(2 + idx), null, "fence seq_cst");
        try instructions.append(item);
    }

    const next_source_line: u32 = @intCast(3 + fence_count);
    const next_expanded_line: u32 = @intCast(2 + fence_count);

    if (bounded) {
        item = inst.makeInstruction(.jmp, next_source_line, next_expanded_line, null, "jmp L_END");
        item.operands[0] = .{ .symbol = 2 };
        item.operands[1] = .{ .label = 2 };
        try instructions.append(item);

        item = inst.makeInstruction(.label, next_source_line + 1, next_expanded_line + 1, null, "L_END:");
        item.operands[0] = .{ .symbol = 2 };
        item.operands[1] = .{ .label = 2 };
        try instructions.append(item);

        item = inst.makeInstruction(.return_, next_source_line + 2, next_expanded_line + 2, null, "return 0");
        item.operands[0] = .{ .text = "0" };
        try instructions.append(item);
    } else {
        item = inst.makeInstruction(.label, next_source_line, next_expanded_line, null, "L_LOOP:");
        item.operands[0] = .{ .symbol = 2 };
        item.operands[1] = .{ .label = 2 };
        try instructions.append(item);

        item = inst.makeInstruction(.jmp, next_source_line + 1, next_expanded_line + 1, null, "jmp L_LOOP");
        item.operands[0] = .{ .symbol = 2 };
        item.operands[1] = .{ .label = 2 };
        try instructions.append(item);
    }

    const owned_instructions = try instructions.toOwnedSlice();
    instructions_moved = true;
    const owned_text_slice = try owned_texts.toOwnedSlice();
    owned_texts_moved = true;

    var step_count: usize = fence_count + 2;
    if (bounded) step_count += 1;

    return .{
        .instructions = owned_instructions,
        .owned_texts = owned_text_slice,
        .expected_alloc_bytes = size,
        .expected_steps = @intCast(step_count),
        .has_unbounded_loop = !bounded,
    };
}

fn verifyTwiceAndExpectEqual(allocator: std.mem.Allocator, program: []const inst.Instruction) !void {
    const first = try verify(allocator, program, &.{});
    defer switch (first) {
        .ok => |ok| {
            var owned = ok;
            owned.deinit(allocator);
        },
        .trap => {},
    };

    const second = try verify(allocator, program, &.{});
    defer switch (second) {
        .ok => |ok| {
            var owned = ok;
            owned.deinit(allocator);
        },
        .trap => {},
    };

    try std.testing.expectEqualDeep(snapshotResult(first), snapshotResult(second));
}

test "gas PBT stays bounded for random forward-jump programs" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6244);
    const random = prng.random();

    for (0..32) |_| {
        var fixture = try buildGasFixture(std.testing.allocator, random, true);
        defer fixture.deinit(std.testing.allocator);

        const verified = try verify(std.testing.allocator, fixture.instructions, &.{});
        switch (verified) {
            .ok => |ok| {
                var owned = ok;
                defer owned.deinit(std.testing.allocator);

                try std.testing.expectEqual(fixture.expected_alloc_bytes, owned.gas.max_alloc_bytes);
                try std.testing.expectEqual(false, owned.gas.has_unbounded_loop);
                switch (owned.gas.max_instruction_steps) {
                    .bounded => |steps| try std.testing.expectEqual(fixture.expected_steps, steps),
                    .unbounded => return error.TestUnexpectedResult,
                }
            },
            .trap => return error.TestUnexpectedResult,
        }
    }
}

test "gas PBT marks random back-edge programs as unbounded" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6245);
    const random = prng.random();

    for (0..32) |_| {
        var fixture = try buildGasFixture(std.testing.allocator, random, false);
        defer fixture.deinit(std.testing.allocator);

        const verified = try verify(std.testing.allocator, fixture.instructions, &.{});
        switch (verified) {
            .ok => |ok| {
                var owned = ok;
                defer owned.deinit(std.testing.allocator);

                try std.testing.expectEqual(fixture.expected_alloc_bytes, owned.gas.max_alloc_bytes);
                try std.testing.expectEqual(true, owned.gas.has_unbounded_loop);
                switch (owned.gas.max_instruction_steps) {
                    .unbounded => |info| try std.testing.expectEqual(fixture.expected_steps, info.bounded_prefix),
                    .bounded => return error.TestUnexpectedResult,
                }
            },
            .trap => return error.TestUnexpectedResult,
        }
    }
}

test "referee determinism PBT stays stable across repeated verify runs" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6250);
    const random = prng.random();

    for (0..32) |idx| {
        var fixture = try buildGasFixture(std.testing.allocator, random, (idx & 1) == 0);
        defer fixture.deinit(std.testing.allocator);

        try verifyTwiceAndExpectEqual(std.testing.allocator, fixture.instructions);
    }
}

test "cfg integrity PBT keeps matching branch states and traps on mismatched joins" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6252);
    const random = prng.random();

    for (0..48) |_| {
        const left_consume = random.boolean();
        const right_consume = random.boolean();
        const expect_conflict = left_consume != right_consume;
        const left_text = if (left_consume) "    !victim\n" else "";
        const right_text = if (right_consume) "    !victim\n" else "";
        const join_text = if (!left_consume and !right_consume) "    !victim\n" else "";
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\@main() -> i32:
            \\victim = alloc 8
            \\cond = eq 1, 1
            \\br cond -> L_LEFT, L_RIGHT
            \\L_LEFT:
            \\{s}    jmp L_JOIN
            \\L_RIGHT:
            \\{s}    jmp L_JOIN
            \\L_JOIN:
            \\{s}    !cond
            \\    return 0
        , .{ left_text, right_text, join_text });
        defer std.testing.allocator.free(source);

        var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
        defer flat.deinit(std.testing.allocator);

        const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
        if (expect_conflict) {
            switch (verified) {
                .trap => |report| {
                    try std.testing.expectEqual(trap.Trap.phi_state_conflict, report.trap);
                    try std.testing.expect(std.mem.containsAtLeast(u8, report.message, 1, "incoming control-flow states do not agree"));
                },
                .ok => return error.TestUnexpectedResult,
            }
        } else {
            switch (verified) {
                .ok => |ok| {
                    var owned = ok;
                    defer owned.deinit(std.testing.allocator);
                    try std.testing.expect(owned.annotated.len > 0);
                },
                .trap => |report| {
                    std.debug.print("unexpected trap {s}: {s}\n", .{ @tagName(report.trap), report.message });
                    return error.TestUnexpectedResult;
                },
            }
        }
    }
}

test "phi join AND PBT keeps borrow-view branches compatible and traps consumed mismatches" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6253);
    const random = prng.random();

    for (0..48) |_| {
        const case_id = random.intRangeLessThan(u8, 0, 3);
        const right_text = switch (case_id) {
            0 => "    view = alloc 8\n",
            1 => "    view = & MSG\n",
            else => "    view = alloc 8\n    !view\n",
        };
        const expect_conflict = case_id == 2;
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\@const MSG = utf8:"ok\n"
            \\@main() -> i32:
            \\cond = eq 1, 1
            \\br cond -> L_LEFT, L_RIGHT
            \\L_LEFT:
            \\    view = alloc 8
            \\    jmp L_JOIN
            \\L_RIGHT:
            \\{s}    jmp L_JOIN
            \\L_JOIN:
            \\    !view
            \\    !cond
            \\    return 0
        , .{right_text});
        defer std.testing.allocator.free(source);

        var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
        defer flat.deinit(std.testing.allocator);

        const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
        if (expect_conflict) {
            switch (verified) {
                .trap => |report| try std.testing.expectEqual(trap.Trap.phi_state_conflict, report.trap),
                .ok => return error.TestUnexpectedResult,
            }
        } else {
            switch (verified) {
                .ok => |ok| {
                    var owned = ok;
                    defer owned.deinit(std.testing.allocator);
                    try std.testing.expect(owned.annotated.len > 0);
                },
                .trap => |report| {
                    std.debug.print("unexpected trap {s}: {s}\n", .{ @tagName(report.trap), report.message });
                    return error.TestUnexpectedResult;
                },
            }
        }
    }
}

test "unknown register PBT traps on random undeclared op operands" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6251);
    const random = prng.random();

    for (0..48) |iter| {
        var name_buf: [32]u8 = undefined;
        const ghost_name = try std.fmt.bufPrint(&name_buf, "ghost_{d}", .{random.int(u32)});
        const unknown_first = (iter & 1) == 0;

        const source = if (unknown_first) blk: {
            break :blk try std.fmt.allocPrint(std.testing.allocator,
                \\@main() -> i32:
                \\value = add {s}, 1
                \\return value
            , .{ghost_name});
        } else blk: {
            break :blk try std.fmt.allocPrint(std.testing.allocator,
                \\@main() -> i32:
                \\value = add 1, {s}
                \\return value
            , .{ghost_name});
        };
        defer std.testing.allocator.free(source);

        var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
        defer flat.deinit(std.testing.allocator);

        const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
        switch (verified) {
            .trap => |report| {
                try std.testing.expectEqual(trap.Trap.unknown_register, report.trap);
                try std.testing.expectEqual(trap.trapCode(.unknown_register), report.trap_code orelse return error.TestUnexpectedResult);
                try std.testing.expect(report.register == null);
                try std.testing.expect(std.mem.startsWith(u8, report.register_buf[0..], ghost_name));
            },
            .ok => return error.TestUnexpectedResult,
        }
    }
}

test "#loc PBT keeps trap upstream locations aligned with loc table entries" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6254);
    const random = prng.random();

    for (0..48) |iter| {
        const ghost_name = try std.fmt.allocPrint(std.testing.allocator, "ghost_{d}", .{iter});
        defer std.testing.allocator.free(ghost_name);

        var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
        errdefer source.deinit();
        const writer = &source.writer;

        var expected_main_loc: ?upstream.UpstreamLoc = null;
        var expected_alloc_loc: ?upstream.UpstreamLoc = null;
        var expected_error_loc: ?upstream.UpstreamLoc = null;
        var expected_return_loc: ?upstream.UpstreamLoc = null;

        try appendRandomLocBlock(writer, random, &expected_main_loc, 0);
        try writer.writeAll("@main() -> i32:\n");
        try appendRandomLocBlock(writer, random, &expected_alloc_loc, 0);
        try writer.writeAll("value = alloc 8\n");
        try appendRandomLocBlock(writer, random, &expected_error_loc, 1);
        if ((iter & 1) == 0) {
            try writer.print("result = add {s}, 1\n", .{ghost_name});
        } else {
            try writer.print("result = add 1, {s}\n", .{ghost_name});
        }
        try appendRandomLocBlock(writer, random, &expected_return_loc, 0);
        try writer.writeAll("return result\n");

        const source_text = try source.toOwnedSlice();
        defer std.testing.allocator.free(source_text);

        var flat = try @import("flattener.zig").flatten(std.testing.allocator, source_text);
        defer flat.deinit(std.testing.allocator);

        const expected_alloc_effective_loc = expected_alloc_loc orelse expected_main_loc;

        try std.testing.expectEqual(@as(usize, 4), flat.instructions.len);
        try std.testing.expectEqual(flat.instructions.len, flat.loc_table.len);
        try expectOptionalUpstreamLoc(flat.instructions[0].upstream_loc, expected_main_loc);
        try expectOptionalUpstreamLoc(flat.loc_table[0], null);
        try expectOptionalUpstreamLoc(flat.instructions[1].upstream_loc, expected_alloc_effective_loc);
        try expectOptionalUpstreamLoc(flat.loc_table[1], expected_alloc_effective_loc);
        try expectOptionalUpstreamLoc(flat.loc_table[2], expected_error_loc);
        try expectOptionalUpstreamLoc(flat.instructions[3].upstream_loc, expected_return_loc);
        try expectOptionalUpstreamLoc(flat.loc_table[3], expected_return_loc);

        const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
        switch (verified) {
            .trap => |report| {
                try std.testing.expectEqual(trap.Trap.unknown_register, report.trap);
                try std.testing.expectEqual(trap.trapCode(.unknown_register), report.trap_code orelse return error.TestUnexpectedResult);
                try expectTrapReportUpstreamLoc(report, expected_error_loc);
                try std.testing.expect(std.mem.startsWith(u8, report.register_buf[0..], ghost_name));
            },
            .ok => return error.TestUnexpectedResult,
        }
    }
}

test "interior ptr PBT traps on use after releasing parent borrow" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6260);
    const random = prng.random();

    for (0..32) |_| {
        const offset: u64 = random.intRangeAtMost(u64, 0, 32);
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\@main() -> i32:
            \\base = alloc 64
            \\view = & base
            \\ip = take view+{d}
            \\!view
            \\value = load ip+0 as u8
            \\return value
        , .{offset});
        defer std.testing.allocator.free(source);

        var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
        defer flat.deinit(std.testing.allocator);

        const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
        switch (verified) {
            .trap => |report| try std.testing.expectEqual(trap.Trap.use_after_move, report.trap),
            .ok => return error.TestUnexpectedResult,
        }
    }
}

test "interior ptr PBT traps on ffi escape" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6261);
    const random = prng.random();

    for (0..32) |_| {
        const offset: u64 = random.intRangeAtMost(u64, 0, 32);
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\@extern sink(*p: ptr) -> i32
            \\@ffi_wrapper wrap(*raw: ptr) -> i32:
            \\safe = assume_safe raw
            \\view = & safe
            \\ip = take view+{d}
            \\value = call @sink(*ip)
            \\return value
            \\@main() -> i32:
            \\base = alloc 64
            \\return 0
        , .{offset});
        defer std.testing.allocator.free(source);

        var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
        defer flat.deinit(std.testing.allocator);

        const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
        switch (verified) {
            .trap => |report| try std.testing.expectEqual(trap.Trap.interior_ptr_escape, report.trap),
            .ok => return error.TestUnexpectedResult,
        }
    }
}

test "ffi airlock isolation PBT rejects unsafe ops outside ffi wrapper" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6262);
    const random = prng.random();

    for (0..48) |_| {
        const case_id = random.intRangeLessThan(u8, 0, 3);
        const source = switch (case_id) {
            0 => try std.fmt.allocPrint(std.testing.allocator,
                \\@main() -> i32:
                \\node = alloc 8
                \\raw = *node
                \\return 0
            , .{}),
            1 => try std.fmt.allocPrint(std.testing.allocator,
                \\@extern grab() -> *ptr
                \\@main() -> i32:
                \\raw = call @grab()
                \\safe = assume_safe raw
                \\return 0
            , .{}),
            else => try std.fmt.allocPrint(std.testing.allocator,
                \\@extern grab() -> *ptr
                \\@main() -> i32:
                \\raw = call @grab()
                \\view = assume_borrow raw
                \\return 0
            , .{}),
        };
        defer std.testing.allocator.free(source);

        var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
        defer flat.deinit(std.testing.allocator);

        const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
        switch (verified) {
            .trap => |report| try std.testing.expectEqual(trap.Trap.illegal_unsafe_context, report.trap),
            .ok => return error.TestUnexpectedResult,
        }
    }
}

test "ffi wrapper allows raw params in branch control flow" {
    const source =
        \\@ffi_wrapper branch(*flag: i32) -> i32:
        \\br flag -> L_TRUE, L_FALSE
        \\L_TRUE:
        \\return 1
        \\L_FALSE:
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 6), owned.annotated.len);
        },
        .trap => return error.TestUnexpectedResult,
    }
}

test "raw pointer load temp live at exit is not a memory leak" {
    // A `load` whose type is .ptr is flagged regFlagRawPointer. Raw pointers
    // carry no ownership (release is a no-op for them), so a live raw-pointer
    // temp at function exit must not trap -- same as an ephemeral scalar.
    // This is the verifier side of the SAB/SA-text parity fix for
    // PhiStateConflict on ptr phi joins: the flag must be assignable without
    // forcing the compiler to emit a release for every compiler-generated
    // ptr temp.
    const source =
        \\@main() -> i32:
        \\data = stack_alloc 8
        \\tmp = load data+0 as ptr
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
        },
        .trap => |report| {
            std.debug.print("unexpected trap: {s}\n", .{@tagName(report.trap)});
            return error.TestUnexpectedResult;
        },
    }
}

test "raw pointer release is a no-op: no false PhiStateConflict at diamond merge" {
    // Releasing a plain raw pointer (`!tp` where tp was loaded `as ptr`)
    // must not mark the register Consumed: raw pointers carry no ownership.
    // Pre-fix, `!tp` marked tp Consumed, so at L_M the path via L_B
    // (tp=Consumed) clashed with the path via L_A (tp=Active after
    // redefinition), producing a false PhiStateConflict. Post-fix both
    // paths carry tp=Active and the join succeeds.
    // This test FAILS on the pre-fix verifier (trap PhiStateConflict).
    const source =
        \\@main() -> i32:
        \\data = stack_alloc 8
        \\i = stack_alloc 8
        \\n = 2
        \\tmp0 = 0
        \\store i+0, tmp0 as u64
        \\!tmp0
        \\tp = load data+0 as ptr
        \\!tp
        \\tmp1 = load i+0 as u64
        \\tmp2 = ult tmp1, n
        \\!tmp1
        \\br tmp2 -> L_A, L_B
        \\L_A:
        \\!tmp2
        \\tp = load data+0 as ptr
        \\jmp L_M
        \\L_B:
        \\!tmp2
        \\jmp L_M
        \\L_M:
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
        },
        .trap => |report| {
            std.debug.print("unexpected trap: {s}\n", .{@tagName(report.trap)});
            return error.TestUnexpectedResult;
        },
    }
}

test "ephemeral scalar release is a no-op: no false PhiStateConflict at diamond merge" {
    // Same shape as the raw-pointer test, but for an ephemeral scalar
    // (`tmp0 = 0`, an immediate assignment). Pre-fix, `!tmp0` marked it
    // Consumed and the L_M join of Active (L_A, redefined) vs Consumed
    // (L_B) trapped with a false PhiStateConflict. Post-fix both paths
    // stay Active.
    // This test FAILS on the pre-fix verifier (trap PhiStateConflict).
    const source =
        \\@main() -> i32:
        \\data = stack_alloc 8
        \\i = stack_alloc 8
        \\n = 2
        \\tmp0 = 0
        \\store i+0, tmp0 as u64
        \\!tmp0
        \\tmp1 = load i+0 as u64
        \\tmp2 = ult tmp1, n
        \\!tmp1
        \\br tmp2 -> L_A, L_B
        \\L_A:
        \\!tmp2
        \\tmp0 = 5
        \\jmp L_M
        \\L_B:
        \\!tmp2
        \\jmp L_M
        \\L_M:
        \\!tmp0
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
        },
        .trap => |report| {
            std.debug.print("unexpected trap: {s}\n", .{@tagName(report.trap)});
            return error.TestUnexpectedResult;
        },
    }
}

test "owned alloc live at exit still traps memory leak" {
    // Negative control for the raw-pointer leak exemption: a genuinely owned
    // value (heap alloc, not a raw pointer) left live at function exit must
    // still trap .memory_leak.
    const source =
        \\@main() -> i32:
        \\leak_0 = alloc 8
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.memory_leak, report.trap),
        .ok => return error.TestUnexpectedResult,
    }
}

test "redefining live owned register still traps register redefinition" {
    // Negative control for the raw-pointer redefinition exemption: an owned
    // (non-raw-pointer, non-ephemeral) live register must still trap
    // .register_redefinition when reassigned.
    const source =
        \\@main() -> i32:
        \\leak_0 = alloc 8
        \\leak_0 = alloc 16
        \\return 0
    ;
    var flat = try @import("flattener.zig").flatten(std.testing.allocator, source);
    defer flat.deinit(std.testing.allocator);

    const verified = try verify(std.testing.allocator, flat.instructions, flat.const_decls);
    switch (verified) {
        .trap => |report| try std.testing.expectEqual(trap.Trap.register_redefinition, report.trap),
        .ok => return error.TestUnexpectedResult,
    }
}

test "predecoded metadata verifies basic instructions without raw text" {
    const symbol_names = [_][]const u8{ "main", "value" };
    const reg_ids = [_]u32{1};
    const fsig = sig.FunctionSig{
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

    var decl = inst.makeInstruction(.func_decl, 1, 0, null, "");
    decl.operands[0] = .{ .symbol = 0 };
    decl.operands[1] = .{ .func = 0 };
    var assign = inst.makeInstruction(.assign, 2, 1, null, "");
    assign.operands[0] = .{ .reg = 1 };
    assign.operands[1] = .{ .imm_i64 = 7 };
    var ret = inst.makeInstruction(.return_, 3, 2, null, "");
    ret.operands[0] = .{ .reg = 1 };
    const instructions = [_]inst.Instruction{ decl, assign, ret };

    const verified = try verifyWithOptions(std.testing.allocator, instructions[0..], &.{}, .{
        .predecoded_symbol_names = symbol_names[0..],
        .predecoded_function_sigs = &.{fsig},
    });
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 3), owned.annotated.len);
        },
        .trap => return error.TestUnexpectedResult,
    }
}

test "predecoded structured call move args mark function consumed regs" {
    var symbols = symbol.SymbolTable.init(std.testing.allocator);
    defer symbols.deinit();

    _ = try symbols.intern("sa_vec_extend_from_slice");
    _ = try symbols.intern("padding");
    const dst_vec = try symbols.intern("dst_vec");

    const reg_ids = [_]u32{dst_vec};
    var scope = try FunctionRegScope.initBorrowed(std.testing.allocator, reg_ids[0..]);
    defer scope.deinit();

    var call_item = inst.makeInstruction(.call, 42, 1, null, "");
    call_item.operands[0] = .{ .reg = dst_vec };
    call_item.operands[1] = .{ .text = "@sa_vec_extend_from_slice(^dst_vec)" };

    var consumed = [_]bool{false};
    markInstructionConsumedRegs(std.testing.allocator, call_item, &symbols, &scope, consumed[0..]);

    try std.testing.expect(consumed[0]);
}

test "predecoded structured call supports move arg rebound to same destination" {
    const symbol_names = [_][]const u8{
        "sa_vec_extend_from_slice",
        "sa_vec_append",
        "dst_vec",
        "src_slice",
        "elem_size",
    };
    const params = [_]sig.ParamSpec{
        .{ .name = "dst_vec", .ty = .ptr, .cap = .move },
        .{ .name = "src_slice", .ty = .ptr, .cap = .borrow },
        .{ .name = "elem_size", .ty = .u64, .cap = .by_value },
    };
    const param_ids = [_]u32{ 2, 3, 4 };
    const reg_ids = [_]u32{ 2, 3, 4 };
    const callee_sig = sig.FunctionSig{
        .id = 0,
        .name = "sa_vec_extend_from_slice",
        .params = params[0..],
        .kind = .external,
        .return_cap = .move,
        .return_ty = .ptr,
        .entry_inst_idx = 0,
        .is_ffi_wrapper = false,
        .param_ids = param_ids[0..],
        .reg_ids = reg_ids[0..],
    };
    const caller_sig = sig.FunctionSig{
        .id = 1,
        .name = "sa_vec_append",
        .params = params[0..],
        .kind = .exported,
        .return_cap = .move,
        .return_ty = .ptr,
        .entry_inst_idx = 1,
        .is_ffi_wrapper = false,
        .param_ids = param_ids[0..],
        .reg_ids = reg_ids[0..],
    };

    var callee_decl = inst.makeInstruction(.extern_decl, 1, 0, null, "");
    callee_decl.operands[0] = .{ .symbol = 0 };
    callee_decl.operands[1] = .{ .func = 0 };
    var caller_decl = inst.makeInstruction(.export_decl, 2, 1, null, "");
    caller_decl.operands[0] = .{ .symbol = 1 };
    caller_decl.operands[1] = .{ .func = 1 };
    var call_item = inst.makeInstruction(.call, 3, 2, null, "");
    call_item.operands[0] = .{ .reg = 2 };
    call_item.operands[1] = .{ .text = "@sa_vec_extend_from_slice(^dst_vec, &src_slice, elem_size)" };
    var release_slice = inst.makeInstruction(.release, 4, 3, null, "");
    release_slice.operands[0] = .{ .reg = 3 };
    var release_elem_size = inst.makeInstruction(.release, 5, 4, null, "");
    release_elem_size.operands[0] = .{ .reg = 4 };
    var ret = inst.makeInstruction(.return_, 6, 5, null, "");
    ret.operands[0] = .{ .reg = 2 };

    const instructions = [_]inst.Instruction{ callee_decl, caller_decl, call_item, release_slice, release_elem_size, ret };
    const verified = try verifyWithOptions(std.testing.allocator, instructions[0..], &.{}, .{
        .jobs = 1,
        .predecoded_symbol_names = symbol_names[0..],
        .predecoded_function_sigs = &.{ callee_sig, caller_sig },
    });
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 6), owned.annotated.len);
        },
        .trap => return error.TestUnexpectedResult,
    }
}

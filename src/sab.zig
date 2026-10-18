const std = @import("std");
pub const instruction = @import("common/instruction.zig");
pub const signature = @import("common/signature.zig");
pub const const_decl = @import("common/const_decl.zig");
const upstream = @import("common/upstream_loc.zig");

const inst = instruction;
const sig = signature;

pub const magic = "SAB\x00";
pub const version_major: u8 = 4;
pub const version_minor: u8 = 0;

const SectionId = enum(u64) {
    symbol_pool = 1,
    function_sigs = 2,
    const_decls = 3,
    instructions = 4,
};

pub const Error = error{
    InvalidSabMagic,
    UnsupportedSabVersion,
    MissingInstructionSection,
    TruncatedSab,
    Leb128Overflow,
    InvalidTag,
    OutOfMemory,
};

pub const Module = struct {
    symbols: []const []const u8,
    owns_symbol_text: bool = true,
    function_sigs: []sig.FunctionSig,
    const_decls: []const_decl.ConstDecl,
    instructions: []inst.Instruction,
    owned_text: [][]const u8,

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        if (self.owns_symbol_text) {
            for (self.symbols) |name| allocator.free(name);
        }
        allocator.free(self.symbols);
        for (self.function_sigs) |*item| item.deinit(allocator);
        allocator.free(self.function_sigs);
        for (self.const_decls) |*decl| decl.deinit(allocator);
        allocator.free(self.const_decls);
        for (self.owned_text) |text| allocator.free(text);
        allocator.free(self.owned_text);
        freeDecodedInstructionMetadata(allocator, self.instructions);
        allocator.free(self.instructions);
        self.* = undefined;
    }
};

const Cursor = struct {
    bytes: []const u8,
    index: usize = 0,

    fn readByte(self: *Cursor) Error!u8 {
        if (self.index >= self.bytes.len) return error.TruncatedSab;
        const byte = self.bytes[self.index];
        self.index += 1;
        return byte;
    }

    fn readSlice(self: *Cursor, len: usize) Error![]const u8 {
        if (len > self.bytes.len - self.index) return error.TruncatedSab;
        const start = self.index;
        self.index += len;
        return self.bytes[start..self.index];
    }
};

pub fn encodeUleb128(writer: *std.Io.Writer, value: u64) !void {
    var remaining = value;
    while (true) {
        var byte: u8 = @intCast(remaining & 0x7f);
        remaining >>= 7;
        if (remaining != 0) byte |= 0x80;
        try writer.writeByte(byte);
        if (remaining == 0) break;
    }
}

pub fn decodeUleb128(cursor: *Cursor) Error!u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        const byte = try cursor.readByte();
        result |= @as(u64, byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) return result;
        if (shift >= 63) return error.Leb128Overflow;
        shift += 7;
    }
}

pub fn encodeSleb128(writer: *std.Io.Writer, value: i64) !void {
    var remaining = value;
    var more = true;
    while (more) {
        var byte: u8 = @intCast(@as(u64, @bitCast(remaining)) & 0x7f);
        const sign_bit_set = (byte & 0x40) != 0;
        remaining >>= 7;
        more = !((remaining == 0 and !sign_bit_set) or (remaining == -1 and sign_bit_set));
        if (more) byte |= 0x80;
        try writer.writeByte(byte);
    }
}

pub fn decodeSleb128(cursor: *Cursor) Error!i64 {
    var result: i64 = 0;
    var shift: u6 = 0;
    var byte: u8 = 0;
    while (true) {
        byte = try cursor.readByte();
        result |= @as(i64, byte & 0x7f) << shift;
        shift += 7;
        if ((byte & 0x80) == 0) break;
        if (shift >= 63) return error.Leb128Overflow;
    }
    if (shift < 64 and (byte & 0x40) != 0) {
        result |= -(@as(i64, 1) << shift);
    }
    return result;
}

fn writeSection(writer: *std.Io.Writer, id: SectionId, payload: []const u8) !void {
    try encodeUleb128(writer, @intFromEnum(id));
    try encodeUleb128(writer, payload.len);
    try writer.writeAll(payload);
}

fn writeStringPool(writer: *std.Io.Writer, symbols: []const []const u8) !void {
    try encodeUleb128(writer, symbols.len);
    for (symbols) |name| {
        try encodeUleb128(writer, name.len);
        try writer.writeAll(name);
    }
}

fn readStringPool(allocator: std.mem.Allocator, payload: []const u8) ![]const []const u8 {
    var cursor = Cursor{ .bytes = payload };
    const count = try decodeUleb128(&cursor);
    if (count > std.math.maxInt(usize)) return error.Leb128Overflow;
    const symbols = try allocator.alloc([]const u8, @intCast(count));
    errdefer allocator.free(symbols);
    var initialized: usize = 0;
    errdefer for (symbols[0..initialized]) |name| allocator.free(name);
    for (symbols) |*slot| {
        const len = try decodeUleb128(&cursor);
        if (len > std.math.maxInt(usize)) return error.Leb128Overflow;
        slot.* = try allocator.dupe(u8, try cursor.readSlice(@intCast(len)));
        initialized += 1;
    }
    return symbols;
}

fn readStringPoolBorrowed(allocator: std.mem.Allocator, payload: []const u8) ![]const []const u8 {
    var cursor = Cursor{ .bytes = payload };
    const count = try decodeUleb128(&cursor);
    if (count > std.math.maxInt(usize)) return error.Leb128Overflow;
    const symbols = try allocator.alloc([]const u8, @intCast(count));
    errdefer allocator.free(symbols);
    for (symbols) |*slot| {
        const len = try decodeUleb128(&cursor);
        if (len > std.math.maxInt(usize)) return error.Leb128Overflow;
        slot.* = try cursor.readSlice(@intCast(len));
    }
    return symbols;
}

fn writeOptionalEnum(writer: *std.Io.Writer, value: anytype) !void {
    if (value) |v| {
        try writer.writeByte(1);
        try writer.writeByte(@intFromEnum(v));
    } else {
        try writer.writeByte(0);
    }
}

fn readOptionalEnum(comptime T: type, cursor: *Cursor) !?T {
    const present = try cursor.readByte();
    if (present == 0) return null;
    if (present != 1) return error.InvalidTag;
    return std.enums.fromInt(T, try cursor.readByte()) orelse error.InvalidTag;
}

fn writeOperand(writer: *std.Io.Writer, operand: inst.Operand, pool: *std.StringHashMap(u32)) !void {
    switch (operand) {
        .none => try writer.writeByte(0),
        .reg => |v| {
            try writer.writeByte(1);
            try encodeUleb128(writer, v);
        },
        .symbol => |v| {
            try writer.writeByte(2);
            try encodeUleb128(writer, v);
        },
        .label => |v| {
            try writer.writeByte(3);
            try encodeUleb128(writer, v);
        },
        .func => |v| {
            try writer.writeByte(4);
            try encodeUleb128(writer, v);
        },
        .imm_i64 => |v| {
            try writer.writeByte(5);
            try encodeSleb128(writer, v);
        },
        .imm_u64 => |v| {
            try writer.writeByte(6);
            try encodeUleb128(writer, v);
        },
        .imm_int => |v| {
            try writer.writeByte(7);
            try encodeSleb128(writer, v);
        },
        .imm_float => |v| {
            try writer.writeByte(8);
            try writer.writeInt(u64, @bitCast(v), .little);
        },
        .op_code => |v| {
            try writer.writeByte(9);
            try writer.writeByte(@intFromEnum(v));
        },
        .cap_prefix => |v| {
            try writer.writeByte(10);
            try writer.writeByte(@intFromEnum(v));
        },
        .offset => |v| {
            try writer.writeByte(11);
            try encodeUleb128(writer, v);
        },
        .ty => |v| {
            try writer.writeByte(12);
            try encodeUleb128(writer, v);
        },
        .text => |v| {
            try writer.writeByte(13);
            try encodeUleb128(writer, pool.get(v) orelse return error.InvalidTag);
        },
        .native_text => |v| {
            try writer.writeByte(14);
            try encodeUleb128(writer, pool.get(v) orelse return error.InvalidTag);
        },
    }
}

fn readPooledText(allocator: std.mem.Allocator, symbols: []const []const u8, owned_text: *std.array_list.Managed([]const u8), id: u64) ![]const u8 {
    if (id > std.math.maxInt(usize)) return error.Leb128Overflow;
    const idx: usize = @intCast(id);
    if (idx >= symbols.len) return error.InvalidTag;
    const text = try allocator.dupe(u8, symbols[idx]);
    errdefer allocator.free(text);
    try owned_text.append(text);
    return text;
}

fn poolId(pool: *std.StringHashMap(u32), text: []const u8) !u32 {
    return pool.get(text) orelse error.InvalidTag;
}

fn writeOptionalPoolText(writer: *std.Io.Writer, pool: *std.StringHashMap(u32), text: ?[]const u8) !void {
    if (text) |value| {
        try writer.writeByte(1);
        try encodeUleb128(writer, try poolId(pool, value));
    } else {
        try writer.writeByte(0);
    }
}

fn writeOptionalHash(writer: *std.Io.Writer, hash: ?[32]u8) !void {
    if (hash) |value| {
        try writer.writeByte(1);
        try writer.writeAll(value[0..]);
    } else {
        try writer.writeByte(0);
    }
}

fn writeOptionalUpstreamLoc(writer: *std.Io.Writer, pool: *std.StringHashMap(u32), loc: ?upstream.UpstreamLoc) !void {
    if (loc) |value| {
        try writer.writeByte(1);
        try encodeUleb128(writer, try poolId(pool, value.file));
        try encodeUleb128(writer, value.line);
        try encodeUleb128(writer, value.col);
    } else {
        try writer.writeByte(0);
    }
}

fn readOptionalPooledText(allocator: std.mem.Allocator, symbols: []const []const u8, owned_text: *std.array_list.Managed([]const u8), cursor: *Cursor) !?[]const u8 {
    const present = try cursor.readByte();
    if (present == 0) return null;
    if (present != 1) return error.InvalidTag;
    return try readPooledText(allocator, symbols, owned_text, try decodeUleb128(cursor));
}

fn readOptionalAllocText(allocator: std.mem.Allocator, symbols: []const []const u8, cursor: *Cursor) !?[]u8 {
    const present = try cursor.readByte();
    if (present == 0) return null;
    if (present != 1) return error.InvalidTag;
    return try readSymbolName(allocator, symbols, try decodeUleb128(cursor));
}

fn skipOptionalPoolText(cursor: *Cursor) !void {
    const present = try cursor.readByte();
    if (present == 0) return;
    if (present != 1) return error.InvalidTag;
    _ = try decodeUleb128(cursor);
}

fn readOptionalHash(cursor: *Cursor) !?[32]u8 {
    const present = try cursor.readByte();
    if (present == 0) return null;
    if (present != 1) return error.InvalidTag;
    var out: [32]u8 = undefined;
    @memcpy(out[0..], try cursor.readSlice(32));
    return out;
}

fn readOptionalPooledUpstreamLoc(allocator: std.mem.Allocator, symbols: []const []const u8, owned_text: *std.array_list.Managed([]const u8), cursor: *Cursor) !?upstream.UpstreamLoc {
    const present = try cursor.readByte();
    if (present == 0) return null;
    if (present != 1) return error.InvalidTag;
    return .{
        .file = try readPooledText(allocator, symbols, owned_text, try decodeUleb128(cursor)),
        .line = @intCast(try decodeUleb128(cursor)),
        .col = @intCast(try decodeUleb128(cursor)),
    };
}

fn readOptionalAllocUpstreamLoc(allocator: std.mem.Allocator, symbols: []const []const u8, cursor: *Cursor) !?upstream.UpstreamLoc {
    const present = try cursor.readByte();
    if (present == 0) return null;
    if (present != 1) return error.InvalidTag;
    const file = try readSymbolName(allocator, symbols, try decodeUleb128(cursor));
    errdefer allocator.free(file);
    return .{
        .file = file,
        .line = @intCast(try decodeUleb128(cursor)),
        .col = @intCast(try decodeUleb128(cursor)),
    };
}

fn skipOptionalUpstreamLoc(cursor: *Cursor) !void {
    const present = try cursor.readByte();
    if (present == 0) return;
    if (present != 1) return error.InvalidTag;
    _ = try decodeUleb128(cursor);
    _ = try decodeUleb128(cursor);
    _ = try decodeUleb128(cursor);
}

fn readOperand(allocator: std.mem.Allocator, symbols: []const []const u8, owned_text: *std.array_list.Managed([]const u8), cursor: *Cursor) !inst.Operand {
    return switch (try cursor.readByte()) {
        0 => .{ .none = {} },
        1 => .{ .reg = @intCast(try decodeUleb128(cursor)) },
        2 => .{ .symbol = @intCast(try decodeUleb128(cursor)) },
        3 => .{ .label = @intCast(try decodeUleb128(cursor)) },
        4 => .{ .func = @intCast(try decodeUleb128(cursor)) },
        5 => .{ .imm_i64 = try decodeSleb128(cursor) },
        6 => .{ .imm_u64 = try decodeUleb128(cursor) },
        7 => .{ .imm_int = try decodeSleb128(cursor) },
        8 => blk: {
            const raw = try cursor.readSlice(8);
            const bits = std.mem.readInt(u64, raw[0..8], .little);
            break :blk .{ .imm_float = @bitCast(bits) };
        },
        9 => .{ .op_code = (std.enums.fromInt(inst.OpCode, try cursor.readByte()) orelse return error.InvalidTag) },
        10 => .{ .cap_prefix = (std.enums.fromInt(inst.CapPrefix, try cursor.readByte()) orelse return error.InvalidTag) },
        11 => .{ .offset = @intCast(try decodeUleb128(cursor)) },
        12 => .{ .ty = @intCast(try decodeUleb128(cursor)) },
        13 => .{ .text = try readPooledText(allocator, symbols, owned_text, try decodeUleb128(cursor)) },
        14 => .{ .native_text = try readPooledText(allocator, symbols, owned_text, try decodeUleb128(cursor)) },
        else => error.InvalidTag,
    };
}

fn operandRegName(symbols: []const []const u8, operand: inst.Operand) ![]const u8 {
    if (operand != .reg) return error.InvalidTag;
    const idx: usize = @intCast(operand.reg);
    if (idx >= symbols.len) return error.InvalidTag;
    return symbols[idx];
}

fn synthesizeRawText(
    allocator: std.mem.Allocator,
    symbols: []const []const u8,
    owned_text: *std.array_list.Managed([]const u8),
    item: *inst.Instruction,
) !void {
    const raw = switch (item.kind) {
        .call, .call_indirect => blk: {
            if (item.operands[0] == .reg) {
                const body = if (item.operands[1] == .text) item.operands[1].text else return;
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "{s} = {s} {s}",
                    .{ try operandRegName(symbols, item.operands[0]), if (item.kind == .call) "call" else "call_indirect", body },
                );
            }
            const body = if (item.operands[0] == .text)
                item.operands[0].text
            else if (item.operands[1] == .text)
                item.operands[1].text
            else
                return;
            break :blk try std.fmt.allocPrint(
                allocator,
                "{s} {s}",
                .{ if (item.kind == .call) "call" else "call_indirect", body },
            );
        },
        .panic, .panic_msg => blk: {
            const arg = switch (item.operands[0]) {
                .text => |text| text,
                .reg => try operandRegName(symbols, item.operands[0]),
                else => "1",
            };
            if (arg.len >= 2 and arg[0] == '(' and arg[arg.len - 1] == ')') {
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "{s}{s}",
                    .{ if (item.kind == .panic) "panic" else "panic_msg", arg },
                );
            }
            break :blk try std.fmt.allocPrint(
                allocator,
                "{s}({s})",
                .{ if (item.kind == .panic) "panic" else "panic_msg", arg },
            );
        },
        else => return,
    };
    errdefer allocator.free(raw);
    try owned_text.append(raw);
    item.raw_text = raw;
}

fn writeInstructions(writer: *std.Io.Writer, instructions: []const inst.Instruction, pool: *std.StringHashMap(u32)) !void {
    try encodeUleb128(writer, instructions.len);
    for (instructions) |item| {
        try writer.writeByte(@intFromEnum(item.kind));
        try encodeUleb128(writer, item.source_line);
        try encodeUleb128(writer, item.expanded_line);
        try writeOptionalEnum(writer, item.op_kind);
        for (item.operands) |operand| try writeOperand(writer, operand, pool);
        try writer.writeByte(if (item.atomic_value_ty != null) 1 else 0);
        if (item.atomic_value_ty) |ty| try encodeUleb128(writer, ty);
        try writeOptionalEnum(writer, item.atomic_ordering);
        try writeOptionalEnum(writer, item.atomic_second_ordering);
        try writeOptionalEnum(writer, item.atomic_rmw_op);
        try writeOptionalPoolText(writer, pool, item.atomic_expected_text);
        try writeOptionalPoolText(writer, pool, item.atomic_new_text);
        try encodeUleb128(writer, item.native_reg_names.len);
        for (item.native_reg_names) |name| try encodeUleb128(writer, try poolId(pool, name));
        try writeOptionalPoolText(writer, pool, item.package_identity);
        try writeOptionalHash(writer, item.package_source_sha256);
        try writeOptionalUpstreamLoc(writer, pool, item.upstream_loc);
    }
}

fn addPoolText(pool_items: *std.array_list.Managed([]const u8), pool: *std.StringHashMap(u32), text: []const u8) !void {
    if (pool.contains(text)) return;
    const id: u32 = @intCast(pool_items.items.len);
    try pool_items.append(text);
    try pool.put(text, id);
}

fn collectConstValueSymbols(pool_items: *std.array_list.Managed([]const u8), pool: *std.StringHashMap(u32), value: const_decl.ConstValue) !void {
    switch (value) {
        .hex, .utf8, .repeat => {},
        .struct_ => |literal| {
            for (literal.fields) |field| {
                try addPoolText(pool_items, pool, field.name);
                try collectConstValueSymbols(pool_items, pool, field.value);
            }
        },
        .vtable => |literal| {
            for (literal.slots) |slot| {
                try addPoolText(pool_items, pool, slot.name);
                try addPoolText(pool_items, pool, slot.func_name);
            }
        },
    }
}

fn writeBytesLiteral(writer: *std.Io.Writer, literal: const_decl.BytesLiteral) !void {
    try encodeUleb128(writer, literal.bytes.len);
    try writer.writeAll(literal.bytes);
    if (literal.repeat_count) |count| {
        try writer.writeByte(1);
        try encodeUleb128(writer, count);
        try writer.writeByte(literal.repeat_byte orelse 0);
    } else {
        try writer.writeByte(0);
    }
}

fn readBytesLiteral(allocator: std.mem.Allocator, cursor: *Cursor, kind: const_decl.ConstLiteralKind) !const_decl.BytesLiteral {
    const len = try decodeUleb128(cursor);
    if (len > std.math.maxInt(usize)) return error.Leb128Overflow;
    const bytes = try allocator.dupe(u8, try cursor.readSlice(@intCast(len)));
    errdefer allocator.free(bytes);
    const repeat_present = try cursor.readByte();
    if (repeat_present == 0) {
        return .{ .kind = kind, .bytes = bytes };
    }
    if (repeat_present != 1) return error.InvalidTag;
    return .{
        .kind = kind,
        .bytes = bytes,
        .repeat_count = try decodeUleb128(cursor),
        .repeat_byte = try cursor.readByte(),
    };
}

fn writeConstValue(writer: *std.Io.Writer, value: const_decl.ConstValue, pool: *std.StringHashMap(u32)) !void {
    const tag = std.meta.activeTag(value);
    try writer.writeByte(@intFromEnum(tag));
    switch (value) {
        .hex, .utf8, .repeat => |literal| try writeBytesLiteral(writer, literal),
        .struct_ => |literal| {
            try encodeUleb128(writer, literal.fields.len);
            for (literal.fields) |field| {
                try encodeUleb128(writer, try poolId(pool, field.name));
                try encodeUleb128(writer, field.size);
                try writeConstValue(writer, field.value, pool);
            }
        },
        .vtable => |literal| {
            try encodeUleb128(writer, literal.slots.len);
            for (literal.slots) |slot| {
                try encodeUleb128(writer, try poolId(pool, slot.name));
                try encodeUleb128(writer, try poolId(pool, slot.func_name));
            }
        },
    }
}

fn readConstValue(allocator: std.mem.Allocator, symbols: []const []const u8, cursor: *Cursor) !const_decl.ConstValue {
    const tag = (std.enums.fromInt(const_decl.ConstLiteralKind, try cursor.readByte()) orelse return error.InvalidTag);
    return switch (tag) {
        .hex => .{ .hex = try readBytesLiteral(allocator, cursor, .hex) },
        .utf8 => .{ .utf8 = try readBytesLiteral(allocator, cursor, .utf8) },
        .repeat => .{ .repeat = try readBytesLiteral(allocator, cursor, .repeat) },
        .struct_ => blk: {
            const count = try decodeUleb128(cursor);
            if (count > std.math.maxInt(usize)) return error.Leb128Overflow;
            const fields = try allocator.alloc(const_decl.StructField, @intCast(count));
            errdefer allocator.free(fields);
            var initialized: usize = 0;
            errdefer for (fields[0..initialized]) |*field| field.deinit(allocator);
            for (fields) |*field| {
                field.* = .{
                    .name = try readSymbolName(allocator, symbols, try decodeUleb128(cursor)),
                    .size = try decodeUleb128(cursor),
                    .value = try readConstValue(allocator, symbols, cursor),
                };
                initialized += 1;
            }
            break :blk .{ .struct_ = .{ .fields = fields } };
        },
        .vtable => blk: {
            const count = try decodeUleb128(cursor);
            if (count > std.math.maxInt(usize)) return error.Leb128Overflow;
            const slots = try allocator.alloc(const_decl.VTableSlot, @intCast(count));
            errdefer allocator.free(slots);
            var initialized: usize = 0;
            errdefer for (slots[0..initialized]) |*slot| slot.deinit(allocator);
            for (slots) |*slot| {
                slot.* = .{
                    .name = try readSymbolName(allocator, symbols, try decodeUleb128(cursor)),
                    .func_name = try readSymbolName(allocator, symbols, try decodeUleb128(cursor)),
                };
                initialized += 1;
            }
            break :blk .{ .vtable = .{ .slots = slots } };
        },
    };
}

fn writeConstDecls(writer: *std.Io.Writer, const_decls: []const const_decl.ConstDecl, pool: *std.StringHashMap(u32)) !void {
    try encodeUleb128(writer, const_decls.len);
    for (const_decls) |decl| {
        try encodeUleb128(writer, decl.source_line);
        try encodeUleb128(writer, decl.expanded_line);
        try encodeUleb128(writer, try poolId(pool, decl.name));
        try encodeUleb128(writer, try poolId(pool, decl.literal_text));
        try writeOptionalUpstreamLoc(writer, pool, decl.upstream_loc);
        try writeConstValue(writer, decl.value, pool);
    }
}

fn readConstDecls(allocator: std.mem.Allocator, symbols: []const []const u8, payload: []const u8, has_metadata: bool) ![]const_decl.ConstDecl {
    var cursor = Cursor{ .bytes = payload };
    const count = try decodeUleb128(&cursor);
    if (count > std.math.maxInt(usize)) return error.Leb128Overflow;
    const out = try allocator.alloc(const_decl.ConstDecl, @intCast(count));
    errdefer allocator.free(out);
    var initialized: usize = 0;
    errdefer for (out[0..initialized]) |*decl| decl.deinit(allocator);
    for (out) |*decl| {
        const source_line: u32 = @intCast(try decodeUleb128(&cursor));
        const expanded_line: u32 = @intCast(try decodeUleb128(&cursor));
        const name = try readSymbolName(allocator, symbols, try decodeUleb128(&cursor));
        errdefer allocator.free(name);
        const literal_text = try readSymbolName(allocator, symbols, try decodeUleb128(&cursor));
        errdefer allocator.free(literal_text);
        const raw_text = try std.fmt.allocPrint(allocator, "@const {s} = {s}", .{ name, literal_text });
        errdefer allocator.free(raw_text);
        var upstream_loc: ?upstream.UpstreamLoc = null;
        errdefer if (upstream_loc) |loc| allocator.free(loc.file);
        if (has_metadata) upstream_loc = try readOptionalAllocUpstreamLoc(allocator, symbols, &cursor);
        decl.* = .{
            .source_line = source_line,
            .expanded_line = expanded_line,
            .upstream_loc = upstream_loc,
            .raw_text = raw_text,
            .name = name,
            .literal_text = literal_text,
            .value = try readConstValue(allocator, symbols, &cursor),
        };
        upstream_loc = null;
        initialized += 1;
    }
    return out;
}

fn writeFunctionSigs(writer: *std.Io.Writer, function_sigs: []const sig.FunctionSig, pool: *std.StringHashMap(u32)) !void {
    try encodeUleb128(writer, function_sigs.len);
    for (function_sigs) |item| {
        try encodeUleb128(writer, item.id);
        try encodeUleb128(writer, try poolId(pool, item.name));
        try writer.writeByte(@intFromEnum(item.kind));
        try writer.writeByte(if (item.return_cap != null) 1 else 0);
        if (item.return_cap) |cap| try writer.writeByte(@intFromEnum(cap));
        try writer.writeByte(@intFromEnum(item.return_ty));
        try writer.writeByte(if (item.return_fallible) 1 else 0);
        try encodeUleb128(writer, item.entry_inst_idx);
        try writer.writeByte(if (item.is_ffi_wrapper) 1 else 0);
        try writer.writeByte(if (item.ignored) 1 else 0);
        try writer.writeByte(if (item.should_panic) 1 else 0);
        try writeOptionalPoolText(writer, pool, item.upstream_file);
        try writeOptionalUpstreamLoc(writer, pool, item.upstream_loc);
        try writeOptionalPoolText(writer, pool, item.llvm_name);

        try encodeUleb128(writer, item.params.len);
        for (item.params) |param| {
            try encodeUleb128(writer, try poolId(pool, param.name));
            try writer.writeByte(@intFromEnum(param.ty));
            try writer.writeByte(@intFromEnum(param.cap));
        }
        try encodeUleb128(writer, item.param_ids.len);
        for (item.param_ids) |id| try encodeUleb128(writer, id);
        try encodeUleb128(writer, item.reg_ids.len);
        for (item.reg_ids) |id| try encodeUleb128(writer, id);
    }
}

fn readSymbolName(allocator: std.mem.Allocator, symbols: []const []const u8, id: u64) ![]u8 {
    if (id > std.math.maxInt(usize)) return error.Leb128Overflow;
    const idx: usize = @intCast(id);
    if (idx >= symbols.len) return error.InvalidTag;
    return try allocator.dupe(u8, symbols[idx]);
}

fn readFunctionSigs(allocator: std.mem.Allocator, symbols: []const []const u8, payload: []const u8, has_metadata: bool) ![]sig.FunctionSig {
    var cursor = Cursor{ .bytes = payload };
    const count = try decodeUleb128(&cursor);
    if (count > std.math.maxInt(usize)) return error.Leb128Overflow;
    const out = try allocator.alloc(sig.FunctionSig, @intCast(count));
    errdefer allocator.free(out);
    var initialized: usize = 0;
    errdefer for (out[0..initialized]) |*item| item.deinit(allocator);

    for (out) |*item| {
        const id: u32 = @intCast(try decodeUleb128(&cursor));
        const name = try readSymbolName(allocator, symbols, try decodeUleb128(&cursor));
        errdefer allocator.free(name);
        const kind = (std.enums.fromInt(sig.FunctionKind, try cursor.readByte()) orelse return error.InvalidTag);
        const return_cap_present = try cursor.readByte();
        const return_cap: ?inst.CapPrefix = if (return_cap_present == 1)
            (std.enums.fromInt(inst.CapPrefix, try cursor.readByte()) orelse return error.InvalidTag)
        else if (return_cap_present == 0) null else return error.InvalidTag;
        const return_ty = (std.enums.fromInt(sig.PrimType, try cursor.readByte()) orelse return error.InvalidTag);
        const return_fallible = (try cursor.readByte()) == 1;
        const entry_inst_idx: u32 = @intCast(try decodeUleb128(&cursor));
        const is_ffi_wrapper = (try cursor.readByte()) == 1;
        const ignored = (try cursor.readByte()) == 1;
        const should_panic = (try cursor.readByte()) == 1;
        var upstream_file: ?[]u8 = null;
        errdefer if (upstream_file) |file| allocator.free(file);
        var upstream_loc: ?upstream.UpstreamLoc = null;
        errdefer if (upstream_loc) |loc| allocator.free(loc.file);
        var llvm_name: ?[]u8 = null;
        errdefer if (llvm_name) |value| allocator.free(value);
        if (has_metadata) {
            upstream_file = try readOptionalAllocText(allocator, symbols, &cursor);
            upstream_loc = try readOptionalAllocUpstreamLoc(allocator, symbols, &cursor);
            llvm_name = try readOptionalAllocText(allocator, symbols, &cursor);
        }

        const param_count = try decodeUleb128(&cursor);
        if (param_count > std.math.maxInt(usize)) return error.Leb128Overflow;
        const params = try allocator.alloc(sig.ParamSpec, @intCast(param_count));
        errdefer allocator.free(params);
        var param_initialized: usize = 0;
        errdefer for (params[0..param_initialized]) |param| allocator.free(param.name);
        for (params) |*param| {
            param.* = .{
                .name = try readSymbolName(allocator, symbols, try decodeUleb128(&cursor)),
                .ty = (std.enums.fromInt(sig.PrimType, try cursor.readByte()) orelse return error.InvalidTag),
                .cap = (std.enums.fromInt(inst.CapPrefix, try cursor.readByte()) orelse return error.InvalidTag),
            };
            param_initialized += 1;
        }

        const param_id_count = try decodeUleb128(&cursor);
        if (param_id_count > std.math.maxInt(usize)) return error.Leb128Overflow;
        const param_ids = try allocator.alloc(u32, @intCast(param_id_count));
        errdefer allocator.free(param_ids);
        for (param_ids) |*slot| slot.* = @intCast(try decodeUleb128(&cursor));

        const reg_id_count = try decodeUleb128(&cursor);
        if (reg_id_count > std.math.maxInt(usize)) return error.Leb128Overflow;
        const reg_ids = try allocator.alloc(u32, @intCast(reg_id_count));
        errdefer allocator.free(reg_ids);
        for (reg_ids) |*slot| slot.* = @intCast(try decodeUleb128(&cursor));

        item.* = .{
            .id = id,
            .name = name,
            .params = params,
            .kind = kind,
            .return_cap = return_cap,
            .return_ty = return_ty,
            .return_fallible = return_fallible,
            .entry_inst_idx = entry_inst_idx,
            .is_ffi_wrapper = is_ffi_wrapper,
            .param_ids = param_ids,
            .reg_ids = reg_ids,
            .upstream_file = upstream_file,
            .upstream_loc = upstream_loc,
            .llvm_name = llvm_name,
            .ignored = ignored,
            .should_panic = should_panic,
        };
        upstream_file = null;
        upstream_loc = null;
        llvm_name = null;
        initialized += 1;
    }
    return out;
}

fn readTestFunctionSigs(allocator: std.mem.Allocator, symbols: []const []const u8, payload: []const u8, has_metadata: bool) ![]sig.FunctionSig {
    var cursor = Cursor{ .bytes = payload };
    const count = try decodeUleb128(&cursor);
    if (count > std.math.maxInt(usize)) return error.Leb128Overflow;

    var out = std.array_list.Managed(sig.FunctionSig).init(allocator);
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit();
    }

    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const id: u32 = @intCast(try decodeUleb128(&cursor));
        const name_id = try decodeUleb128(&cursor);
        const kind = (std.enums.fromInt(sig.FunctionKind, try cursor.readByte()) orelse return error.InvalidTag);
        const return_cap_present = try cursor.readByte();
        const return_cap: ?inst.CapPrefix = if (return_cap_present == 1)
            (std.enums.fromInt(inst.CapPrefix, try cursor.readByte()) orelse return error.InvalidTag)
        else if (return_cap_present == 0) null else return error.InvalidTag;
        const return_ty = (std.enums.fromInt(sig.PrimType, try cursor.readByte()) orelse return error.InvalidTag);
        const return_fallible = (try cursor.readByte()) == 1;
        const entry_inst_idx: u32 = @intCast(try decodeUleb128(&cursor));
        const is_ffi_wrapper = (try cursor.readByte()) == 1;
        const ignored = (try cursor.readByte()) == 1;
        const should_panic = (try cursor.readByte()) == 1;

        var upstream_file: ?[]u8 = null;
        errdefer if (upstream_file) |file| allocator.free(file);
        var upstream_loc: ?upstream.UpstreamLoc = null;
        errdefer if (upstream_loc) |loc| allocator.free(loc.file);
        var llvm_name: ?[]u8 = null;
        errdefer if (llvm_name) |value| allocator.free(value);

        const is_test = kind == .test_func;
        if (has_metadata) {
            if (is_test) {
                upstream_file = try readOptionalAllocText(allocator, symbols, &cursor);
                upstream_loc = try readOptionalAllocUpstreamLoc(allocator, symbols, &cursor);
                llvm_name = try readOptionalAllocText(allocator, symbols, &cursor);
            } else {
                try skipOptionalPoolText(&cursor);
                try skipOptionalUpstreamLoc(&cursor);
                try skipOptionalPoolText(&cursor);
            }
        }

        const param_count = try decodeUleb128(&cursor);
        var param_i: u64 = 0;
        while (param_i < param_count) : (param_i += 1) {
            _ = try decodeUleb128(&cursor);
            _ = try cursor.readByte();
            _ = try cursor.readByte();
        }

        const param_id_count = try decodeUleb128(&cursor);
        var param_id_i: u64 = 0;
        while (param_id_i < param_id_count) : (param_id_i += 1) _ = try decodeUleb128(&cursor);

        const reg_id_count = try decodeUleb128(&cursor);
        var reg_id_i: u64 = 0;
        while (reg_id_i < reg_id_count) : (reg_id_i += 1) _ = try decodeUleb128(&cursor);

        if (!is_test) continue;

        const name = try readSymbolName(allocator, symbols, name_id);
        errdefer allocator.free(name);
        const params = try allocator.alloc(sig.ParamSpec, 0);
        errdefer allocator.free(params);

        try out.append(.{
            .id = id,
            .name = name,
            .params = params,
            .kind = kind,
            .return_cap = return_cap,
            .return_ty = return_ty,
            .return_fallible = return_fallible,
            .entry_inst_idx = entry_inst_idx,
            .is_ffi_wrapper = is_ffi_wrapper,
            .param_ids = &.{},
            .reg_ids = &.{},
            .upstream_file = upstream_file,
            .upstream_loc = upstream_loc,
            .llvm_name = llvm_name,
            .ignored = ignored,
            .should_panic = should_panic,
        });
        upstream_file = null;
        upstream_loc = null;
        llvm_name = null;
    }

    return try out.toOwnedSlice();
}

fn freeDecodedInstructionMetadataOne(allocator: std.mem.Allocator, item: *const inst.Instruction) void {
    if (item.package_identity) |identity| allocator.free(identity);
    if (item.upstream_loc) |loc| allocator.free(loc.file);
    if (item.native_reg_names.len != 0) allocator.free(item.native_reg_names);
}

fn freeDecodedInstructionMetadata(allocator: std.mem.Allocator, instructions: []inst.Instruction) void {
    for (instructions) |*item| freeDecodedInstructionMetadataOne(allocator, item);
}

fn readInstructions(allocator: std.mem.Allocator, symbols: []const []const u8, owned_text: *std.array_list.Managed([]const u8), payload: []const u8, has_raw_text: bool, has_full_metadata: bool, synthesize_debug_text: bool) ![]inst.Instruction {
    var cursor = Cursor{ .bytes = payload };
    const count = try decodeUleb128(&cursor);
    if (count > std.math.maxInt(usize)) return error.Leb128Overflow;
    const instructions = try allocator.alloc(inst.Instruction, @intCast(count));
    var initialized: usize = 0;
    errdefer {
        freeDecodedInstructionMetadata(allocator, instructions[0..initialized]);
        allocator.free(instructions);
    }
    for (instructions) |*item| {
        const kind = (std.enums.fromInt(inst.InstKind, try cursor.readByte()) orelse return error.InvalidTag);
        // SA-text 为语义标准：保留编码中的 expanded_line（宏展开行号），
        // 不得以解码序号覆盖，否则诊断行号/const 交错与文本路径分歧。
        item.* = inst.makeInstruction(kind, @intCast(try decodeUleb128(&cursor)), @intCast(try decodeUleb128(&cursor)), null, "");
        var item_initialized = false;
        errdefer if (!item_initialized) freeDecodedInstructionMetadataOne(allocator, item);
        item.op_kind = try readOptionalEnum(inst.OpKind, &cursor);
        for (&item.operands) |*operand| operand.* = try readOperand(allocator, symbols, owned_text, &cursor);
        if (has_raw_text) {
            const raw_present = try cursor.readByte();
            if (raw_present == 1) {
                item.raw_text = try readPooledText(allocator, symbols, owned_text, try decodeUleb128(&cursor));
            } else if (raw_present != 0) {
                return error.InvalidTag;
            }
        }
        item.atomic_value_ty = if (try cursor.readByte() == 1) @intCast(try decodeUleb128(&cursor)) else null;
        item.atomic_ordering = try readOptionalEnum(inst.AtomicOrdering, &cursor);
        item.atomic_second_ordering = try readOptionalEnum(inst.AtomicOrdering, &cursor);
        item.atomic_rmw_op = try readOptionalEnum(inst.AtomicRmwOp, &cursor);
        if (has_full_metadata) {
            item.atomic_expected_text = try readOptionalPooledText(allocator, symbols, owned_text, &cursor);
            item.atomic_new_text = try readOptionalPooledText(allocator, symbols, owned_text, &cursor);

            const native_count = try decodeUleb128(&cursor);
            if (native_count > std.math.maxInt(usize)) return error.Leb128Overflow;
            if (native_count != 0) {
                const native_names = try allocator.alloc([]const u8, @intCast(native_count));
                errdefer allocator.free(native_names);
                for (native_names) |*name| name.* = try readPooledText(allocator, symbols, owned_text, try decodeUleb128(&cursor));
                item.native_reg_names = native_names;
            }

            item.package_identity = try readOptionalAllocText(allocator, symbols, &cursor);
            item.package_source_sha256 = try readOptionalHash(&cursor);
            item.upstream_loc = try readOptionalAllocUpstreamLoc(allocator, symbols, &cursor);
        }
        if (synthesize_debug_text and item.raw_text.len == 0) try synthesizeRawText(allocator, symbols, owned_text, item);
        item_initialized = true;
        initialized += 1;
    }
    return instructions;
}

pub fn encodeProgramWithConsts(allocator: std.mem.Allocator, symbols: []const []const u8, const_decls: []const const_decl.ConstDecl, function_sigs: []const sig.FunctionSig, instructions: []const inst.Instruction) ![]u8 {
    var pool_items = std.array_list.Managed([]const u8).init(allocator);
    defer pool_items.deinit();
    var pool = std.StringHashMap(u32).init(allocator);
    defer pool.deinit();

    for (symbols) |name| {
        try addPoolText(&pool_items, &pool, name);
    }
    for (instructions) |item| {
        if (item.atomic_expected_text) |text| try addPoolText(&pool_items, &pool, text);
        if (item.atomic_new_text) |text| try addPoolText(&pool_items, &pool, text);
        for (item.native_reg_names) |name| try addPoolText(&pool_items, &pool, name);
        if (item.package_identity) |identity| try addPoolText(&pool_items, &pool, identity);
        if (item.upstream_loc) |loc| try addPoolText(&pool_items, &pool, loc.file);
        for (item.operands) |operand| switch (operand) {
            .text, .native_text => |text| try addPoolText(&pool_items, &pool, text),
            else => {},
        };
    }
    for (function_sigs) |item| {
        try addPoolText(&pool_items, &pool, item.name);
        if (item.upstream_file) |file| try addPoolText(&pool_items, &pool, file);
        if (item.upstream_loc) |loc| try addPoolText(&pool_items, &pool, loc.file);
        if (item.llvm_name) |name| try addPoolText(&pool_items, &pool, name);
        for (item.params) |param| {
            try addPoolText(&pool_items, &pool, param.name);
        }
    }
    for (const_decls) |decl| {
        try addPoolText(&pool_items, &pool, decl.name);
        try addPoolText(&pool_items, &pool, decl.literal_text);
        if (decl.upstream_loc) |loc| try addPoolText(&pool_items, &pool, loc.file);
        try collectConstValueSymbols(&pool_items, &pool, decl.value);
    }

    var sym_payload: std.Io.Writer.Allocating = .init(allocator);
    defer sym_payload.deinit();
    try writeStringPool(&sym_payload.writer, pool_items.items);

    var inst_payload: std.Io.Writer.Allocating = .init(allocator);
    defer inst_payload.deinit();
    try writeInstructions(&inst_payload.writer, instructions, &pool);

    var sig_payload: std.Io.Writer.Allocating = .init(allocator);
    defer sig_payload.deinit();
    try writeFunctionSigs(&sig_payload.writer, function_sigs, &pool);

    var const_payload: std.Io.Writer.Allocating = .init(allocator);
    defer const_payload.deinit();
    try writeConstDecls(&const_payload.writer, const_decls, &pool);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(magic);
    try out.writer.writeByte(version_major);
    try out.writer.writeByte(version_minor);
    try encodeUleb128(&out.writer, 4);
    try writeSection(&out.writer, .symbol_pool, sym_payload.writer.buffered());
    try writeSection(&out.writer, .function_sigs, sig_payload.writer.buffered());
    try writeSection(&out.writer, .const_decls, const_payload.writer.buffered());
    try writeSection(&out.writer, .instructions, inst_payload.writer.buffered());
    return try out.toOwnedSlice();
}

pub fn encodeProgram(allocator: std.mem.Allocator, symbols: []const []const u8, function_sigs: []const sig.FunctionSig, instructions: []const inst.Instruction) ![]u8 {
    return encodeProgramWithConsts(allocator, symbols, &.{}, function_sigs, instructions);
}

pub fn encodeModule(allocator: std.mem.Allocator, symbols: []const []const u8, instructions: []const inst.Instruction) ![]u8 {
    return encodeProgram(allocator, symbols, &.{}, instructions);
}

pub fn decodeModule(allocator: std.mem.Allocator, bytes: []const u8) !Module {
    if (bytes.len < magic.len + 2) return error.TruncatedSab;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidSabMagic;
    var cursor = Cursor{ .bytes = bytes, .index = magic.len };
    const major = try cursor.readByte();
    _ = try cursor.readByte();
    if (major != 1 and major != 2 and major != 3 and major != version_major) return error.UnsupportedSabVersion;
    const has_raw_text = major >= 2 and major < 4;
    const has_full_metadata = major >= 3;
    const synthesize_debug_text = major < 4;

    var symbols: []const []const u8 = &.{};
    var function_sigs: []sig.FunctionSig = &.{};
    var const_decls: []const_decl.ConstDecl = &.{};
    var instructions: ?[]inst.Instruction = null;
    var owned_text = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (owned_text.items) |text| allocator.free(text);
        owned_text.deinit();
    }
    const section_count = try decodeUleb128(&cursor);
    var i: u64 = 0;
    while (i < section_count) : (i += 1) {
        const id = try decodeUleb128(&cursor);
        const len = try decodeUleb128(&cursor);
        if (len > std.math.maxInt(usize)) return error.Leb128Overflow;
        const payload = try cursor.readSlice(@intCast(len));
        if (id == @intFromEnum(SectionId.symbol_pool)) symbols = try readStringPoolBorrowed(allocator, payload);
        if (id == @intFromEnum(SectionId.function_sigs)) function_sigs = try readFunctionSigs(allocator, symbols, payload, has_full_metadata);
        if (id == @intFromEnum(SectionId.const_decls)) const_decls = try readConstDecls(allocator, symbols, payload, has_full_metadata);
        if (id == @intFromEnum(SectionId.instructions)) instructions = try readInstructions(allocator, symbols, &owned_text, payload, has_raw_text, has_full_metadata, synthesize_debug_text);
    }
    return .{ .symbols = symbols, .owns_symbol_text = false, .function_sigs = function_sigs, .const_decls = const_decls, .instructions = instructions orelse return error.MissingInstructionSection, .owned_text = try owned_text.toOwnedSlice() };
}

pub fn decodeFunctionSigsOnly(allocator: std.mem.Allocator, bytes: []const u8) ![]sig.FunctionSig {
    if (bytes.len < magic.len + 2) return error.TruncatedSab;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidSabMagic;
    var cursor = Cursor{ .bytes = bytes, .index = magic.len };
    const major = try cursor.readByte();
    _ = try cursor.readByte();
    if (major != 1 and major != 2 and major != 3 and major != version_major) return error.UnsupportedSabVersion;
    const has_full_metadata = major >= 3;

    var symbols: []const []const u8 = &.{};
    defer {
        for (symbols) |name| allocator.free(name);
        allocator.free(symbols);
    }

    var function_sig_payload: ?[]const u8 = null;
    const section_count = try decodeUleb128(&cursor);
    var i: u64 = 0;
    while (i < section_count) : (i += 1) {
        const id = try decodeUleb128(&cursor);
        const len = try decodeUleb128(&cursor);
        if (len > std.math.maxInt(usize)) return error.Leb128Overflow;
        const payload = try cursor.readSlice(@intCast(len));
        if (id == @intFromEnum(SectionId.symbol_pool)) symbols = try readStringPool(allocator, payload);
        if (id == @intFromEnum(SectionId.function_sigs)) function_sig_payload = payload;
    }

    if (function_sig_payload) |payload| {
        return try readFunctionSigs(allocator, symbols, payload, has_full_metadata);
    }
    return try allocator.alloc(sig.FunctionSig, 0);
}

pub fn decodeTestFunctionSigsOnly(allocator: std.mem.Allocator, bytes: []const u8) ![]sig.FunctionSig {
    if (bytes.len < magic.len + 2) return error.TruncatedSab;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidSabMagic;
    var cursor = Cursor{ .bytes = bytes, .index = magic.len };
    const major = try cursor.readByte();
    _ = try cursor.readByte();
    if (major != 1 and major != 2 and major != 3 and major != version_major) return error.UnsupportedSabVersion;
    const has_full_metadata = major >= 3;

    var symbols: []const []const u8 = &.{};
    defer allocator.free(symbols);

    var function_sig_payload: ?[]const u8 = null;
    const section_count = try decodeUleb128(&cursor);
    var i: u64 = 0;
    while (i < section_count) : (i += 1) {
        const id = try decodeUleb128(&cursor);
        const len = try decodeUleb128(&cursor);
        if (len > std.math.maxInt(usize)) return error.Leb128Overflow;
        const payload = try cursor.readSlice(@intCast(len));
        if (id == @intFromEnum(SectionId.symbol_pool)) symbols = try readStringPoolBorrowed(allocator, payload);
        if (id == @intFromEnum(SectionId.function_sigs)) function_sig_payload = payload;
    }

    if (function_sig_payload) |payload| {
        return try readTestFunctionSigs(allocator, symbols, payload, has_full_metadata);
    }
    return try allocator.alloc(sig.FunctionSig, 0);
}

pub fn disasmModule(allocator: std.mem.Allocator, bytes: []const u8, writer: *std.Io.Writer) !void {
    var module = try decodeModule(allocator, bytes);
    defer module.deinit(allocator);

    for (module.function_sigs) |fsig| {
        try sig.writeFunctionHeader(writer, fsig);
        try writer.writeByte('\n');
    }
    if (module.function_sigs.len > 0) try writer.writeByte('\n');

    for (module.const_decls) |decl| {
        try writer.print("@const {s} = {s}\n", .{ decl.name, decl.literal_text });
    }
    if (module.const_decls.len > 0) try writer.writeByte('\n');

    for (module.instructions) |item| {
        switch (item.kind) {
            .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
                try writer.writeByte('\n');
                try writeDisasmInstruction(writer, item, module.symbols);
            },
            .label => {
                try writeDisasmInstruction(writer, item, module.symbols);
            },
            else => {
                try writer.writeAll("    ");
                try writeDisasmInstruction(writer, item, module.symbols);
            },
        }
    }
}

fn writeDisasmInstruction(writer: *std.Io.Writer, item: inst.Instruction, symbols: []const []const u8) !void {
    if (item.kind == .call or item.kind == .call_indirect) {
        if (try writeDisasmCallInstruction(writer, item, symbols)) return;
    }

    try writer.print("{s}", .{@tagName(item.kind)});
    if (item.op_kind) |ok| {
        try writer.print(".{s}", .{@tagName(ok)});
    }
    var has_operand = false;
    for (item.operands) |operand| {
        switch (operand) {
            .none => continue,
            else => {},
        }
        if (has_operand) {
            try writer.writeAll(",");
        } else {
            try writer.writeAll(" ");
        }
        has_operand = true;
        try writeDisasmOperand(writer, operand, symbols);
    }
    try writer.writeByte('\n');
}

fn splitCallBody(body: []const u8) ?struct { target: []const u8, args: []const u8 } {
    const trimmed = std.mem.trim(u8, body, " \t");
    const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, trimmed, ')') orelse return null;
    if (close < open) return null;
    if (std.mem.trim(u8, trimmed[close + 1 ..], " \t").len != 0) return null;
    const target = std.mem.trim(u8, trimmed[0..open], " \t");
    if (target.len == 0) return null;
    return .{ .target = target, .args = std.mem.trim(u8, trimmed[open + 1 .. close], " \t") };
}

fn writeDisasmCallInstruction(writer: *std.Io.Writer, item: inst.Instruction, symbols: []const []const u8) !bool {
    const has_dst = item.operands[0] == .reg;
    const body_operand = if (has_dst) item.operands[1] else item.operands[0];
    const body = switch (body_operand) {
        .text => |text| text,
        else => return false,
    };
    const split = splitCallBody(body) orelse return false;

    try writer.print("{s}", .{@tagName(item.kind)});
    if (has_dst) {
        try writer.writeByte(' ');
        try writeDisasmOperand(writer, item.operands[0], symbols);
        try writer.writeByte(',');
    } else {
        try writer.writeByte(' ');
    }
    try writer.print("\"{s}\",\"{s}\"\n", .{ split.target, split.args });
    return true;
}

fn writeDisasmOperand(writer: *std.Io.Writer, operand: inst.Operand, symbols: []const []const u8) !void {
    switch (operand) {
        .none => {},
        .reg => |v| try writer.print("r{d}", .{v}),
        .symbol => |v| {
            if (v < symbols.len) {
                try writer.print("${s}", .{symbols[v]});
            } else {
                try writer.print("sym:{d}", .{v});
            }
        },
        .label => |v| try writer.print("L{d}", .{v}),
        .func => |v| try writer.print("fn:{d}", .{v}),
        .imm_i64 => |v| try writer.print("{d}", .{v}),
        .imm_u64 => |v| try writer.print("{d}u", .{v}),
        .imm_int => |v| try writer.print("{d}", .{v}),
        .imm_float => |v| try writer.print("{d}", .{v}),
        .op_code => |v| try writer.print("op:{s}", .{@tagName(v)}),
        .cap_prefix => |v| try writer.print("cap:{s}", .{@tagName(v)}),
        .offset => |v| try writer.print("+{d}", .{v}),
        .ty => |v| try writer.print("ty:{d}", .{v}),
        .text => |v| try writer.print("\"{s}\"", .{v}),
        .native_text => |v| try writer.print("native:\"{s}\"", .{v}),
    }
}

test "sleb128 roundtrip" {
    const values = [_]i64{ -129, -1, 0, 1, 127, 128, 4096 };
    for (values) |value| {
        var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer buf.deinit();
        try encodeSleb128(&buf.writer, value);
        var cursor = Cursor{ .bytes = buf.writer.buffered() };
        try std.testing.expectEqual(value, try decodeSleb128(&cursor));
    }
}

test "sab instruction roundtrip keeps semantics without raw source text" {
    const symbols = [_][]const u8{ "main", "value" };
    var item = inst.makeInstruction(.assign, 2, 0, null, "value = 7");
    item.operands[0] = .{ .reg = 1 };
    item.operands[1] = .{ .imm_i64 = 7 };

    const encoded = try encodeModule(std.testing.allocator, symbols[0..], &.{item});
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "value = 7") == null);

    var decoded = try decodeModule(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded.instructions.len);
    try std.testing.expectEqual(inst.InstKind.assign, decoded.instructions[0].kind);
    try std.testing.expectEqual(@as(u32, 1), decoded.instructions[0].operands[0].reg);
    try std.testing.expectEqual(@as(i64, 7), decoded.instructions[0].operands[1].imm_i64);
    try std.testing.expectEqualStrings("", decoded.instructions[0].raw_text);
}

test "sab text operands roundtrip without raw source text" {
    var item = inst.makeInstruction(.panic, 3, 0, null, "panic(7)");
    item.operands[0] = .{ .text = "7" };

    const encoded = try encodeModule(std.testing.allocator, &.{}, &.{item});
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "panic(7)") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "7") != null);

    var decoded = try decodeModule(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(inst.InstKind.panic, decoded.instructions[0].kind);
    try std.testing.expectEqualStrings("7", decoded.instructions[0].operands[0].text);
    try std.testing.expectEqualStrings("", decoded.instructions[0].raw_text);
}

test "sab borrow roundtrip preserves structured operands" {
    const symbols = [_][]const u8{ "GLOBAL", "view" };
    var item = inst.makeInstruction(.borrow, 4, 0, null, "view = &GLOBAL");
    item.operands[0] = .{ .reg = 1 };
    item.operands[1] = .{ .reg = 0 };
    item.operands[2] = .{ .text = "read" };
    item.operands[3] = .{ .cap_prefix = .borrow };

    const encoded = try encodeModule(std.testing.allocator, symbols[0..], &.{item});
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeModule(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(inst.InstKind.borrow, decoded.instructions[0].kind);
    try std.testing.expectEqual(@as(u32, 1), decoded.instructions[0].operands[0].reg);
    try std.testing.expectEqual(@as(u32, 0), decoded.instructions[0].operands[1].reg);
    try std.testing.expectEqualStrings("read", decoded.instructions[0].operands[2].text);
    try std.testing.expectEqualStrings("", decoded.instructions[0].raw_text);
}

test "sab roundtrip preserves expanded_line from SA-text" {
    // SA-text 为语义标准：解码不得以指令序号覆盖 expanded_line（宏展开行号），
    // 否则 Referee 诊断行号/const 交错与文本路径分歧。
    const symbols = [_][]const u8{ "a", "b", "c" };
    var items = [_]inst.Instruction{
        inst.makeInstruction(.assign, 5, 10, null, ""),
        inst.makeInstruction(.assign, 9, 42, null, ""),
        inst.makeInstruction(.assign, 30, 7, null, ""),
        // 边界：expanded_line = 0 必须原样保留（旧逻辑会写成指令序号 3）。
        inst.makeInstruction(.assign, 100, 0, null, ""),
    };
    items[0].operands[0] = .{ .reg = 0 };
    items[0].operands[1] = .{ .imm_i64 = 1 };
    items[1].operands[0] = .{ .reg = 1 };
    items[1].operands[1] = .{ .imm_i64 = 2 };
    items[2].operands[0] = .{ .reg = 2 };
    items[2].operands[1] = .{ .imm_i64 = 3 };
    items[3].operands[0] = .{ .reg = 0 };
    items[3].operands[1] = .{ .imm_i64 = 4 };

    const encoded = try encodeModule(std.testing.allocator, symbols[0..], items[0..]);
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeModule(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), decoded.instructions.len);
    try std.testing.expectEqual(@as(u32, 5), decoded.instructions[0].source_line);
    try std.testing.expectEqual(@as(u32, 10), decoded.instructions[0].expanded_line);
    try std.testing.expectEqual(@as(u32, 9), decoded.instructions[1].source_line);
    try std.testing.expectEqual(@as(u32, 42), decoded.instructions[1].expanded_line);
    try std.testing.expectEqual(@as(u32, 30), decoded.instructions[2].source_line);
    try std.testing.expectEqual(@as(u32, 7), decoded.instructions[2].expanded_line);
    try std.testing.expectEqual(@as(u32, 100), decoded.instructions[3].source_line);
    try std.testing.expectEqual(@as(u32, 0), decoded.instructions[3].expanded_line);
}

fn decodedOwnsPooledText(module: *const Module, text: []const u8) bool {
    for (module.owned_text) |owned| {
        if (owned.ptr == text.ptr) return true;
    }
    return false;
}

fn expectOperandEqual(expected: inst.Operand, got: inst.Operand) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(got));
    switch (expected) {
        .none => {},
        .reg => |value| try std.testing.expectEqual(value, got.reg),
        .symbol => |value| try std.testing.expectEqual(value, got.symbol),
        .label => |value| try std.testing.expectEqual(value, got.label),
        .func => |value| try std.testing.expectEqual(value, got.func),
        .imm_i64 => |value| try std.testing.expectEqual(value, got.imm_i64),
        .imm_u64 => |value| try std.testing.expectEqual(value, got.imm_u64),
        .imm_int => |value| try std.testing.expectEqual(value, got.imm_int),
        .imm_float => |value| try std.testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(got.imm_float))),
        .op_code => |value| try std.testing.expectEqual(value, got.op_code),
        .cap_prefix => |value| try std.testing.expectEqual(value, got.cap_prefix),
        .offset => |value| try std.testing.expectEqual(value, got.offset),
        .ty => |value| try std.testing.expectEqual(value, got.ty),
        .text => |value| try std.testing.expectEqualStrings(value, got.text),
        .native_text => |value| try std.testing.expectEqualStrings(value, got.native_text),
    }
}

test "sab v4 preserves structured instruction metadata required by SA backends" {
    const symbols = [_][]const u8{ "ok", "slot", "base", "offset", "old", "new", "pkg", "pkg/main.sars", "native_name" };
    var hash: [32]u8 = std.mem.zeroes([32]u8);
    hash[0] = 0xaa;

    var item = inst.makeInstruction(.cmpxchg, 9, 0, .{ .file = "pkg/main.sars", .line = 9, .col = 5 }, "ok, old = cmpxchg base+offset, old => new seq_cst seq_cst as i64");
    item.operands[0] = .{ .reg = 0 };
    item.operands[1] = .{ .reg = 1 };
    item.operands[2] = .{ .reg = 2 };
    item.operands[3] = .{ .reg = 3 };
    item.atomic_value_ty = @intFromEnum(sig.PrimType.i64);
    item.atomic_ordering = .seq_cst;
    item.atomic_second_ordering = .seq_cst;
    item.atomic_expected_text = "old";
    item.atomic_new_text = "new";
    item.native_reg_names = &.{"native_name"};
    item.package_identity = "pkg";
    item.package_source_sha256 = hash;

    const encoded = try encodeModule(std.testing.allocator, symbols[0..], &.{item});
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeModule(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    const got = decoded.instructions[0];
    try std.testing.expectEqual(inst.InstKind.cmpxchg, got.kind);
    try std.testing.expectEqualStrings("old", got.atomic_expected_text.?);
    try std.testing.expectEqualStrings("new", got.atomic_new_text.?);
    try std.testing.expectEqual(@as(usize, 1), got.native_reg_names.len);
    try std.testing.expectEqualStrings("native_name", got.native_reg_names[0]);
    try std.testing.expectEqualStrings("pkg", got.package_identity.?);
    try std.testing.expectEqual(@as(u8, 0xaa), got.package_source_sha256.?[0]);
    try std.testing.expectEqualStrings("pkg/main.sars", got.upstream_loc.?.file);
    try std.testing.expectEqual(@as(u32, 9), got.upstream_loc.?.line);
    try std.testing.expectEqual(@as(u32, 5), got.upstream_loc.?.col);
    try std.testing.expectEqualStrings("", got.raw_text);
    try std.testing.expect(!decodedOwnsPooledText(&decoded, got.package_identity.?));
    try std.testing.expect(!decodedOwnsPooledText(&decoded, got.upstream_loc.?.file));
}

test "sab roundtrip covers every SA instruction and op kind" {
    var instructions = std.array_list.Managed(inst.Instruction).init(std.testing.allocator);
    defer instructions.deinit();

    inline for (std.meta.tags(inst.InstKind).*) |kind| {
        var item = inst.makeInstruction(kind, 10, @intCast(instructions.items.len), null, @tagName(kind));
        item.operands[0] = .{ .reg = 0 };
        item.operands[1] = .{ .symbol = 1 };
        item.operands[2] = .{ .label = 2 };
        item.operands[3] = if (kind == .native) .{ .native_text = "mov native" } else .{ .text = @tagName(kind) };
        try instructions.append(item);
    }

    inline for (std.meta.tags(inst.OpKind).*) |op_kind| {
        var item = inst.makeInstruction(.op, 20, @intCast(instructions.items.len), null, @tagName(op_kind));
        item.op_kind = op_kind;
        item.operands[0] = .{ .reg = 0 };
        item.operands[1] = .{ .reg = 1 };
        item.operands[2] = .{ .reg = 2 };
        try instructions.append(item);
    }

    const encoded = try encodeModule(std.testing.allocator, &.{ "r0", "sym", "label" }, instructions.items);
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeModule(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(instructions.items.len, decoded.instructions.len);
    for (instructions.items, decoded.instructions) |expected, got| {
        try std.testing.expectEqual(expected.kind, got.kind);
        try std.testing.expectEqual(expected.op_kind, got.op_kind);
        try std.testing.expectEqualStrings("", got.raw_text);
    }
}

test "sab roundtrip covers every SA operand kind" {
    var instructions = std.array_list.Managed(inst.Instruction).init(std.testing.allocator);
    defer instructions.deinit();

    const samples = [_]inst.Operand{
        .{ .none = {} },
        .{ .reg = 0 },
        .{ .symbol = 1 },
        .{ .label = 2 },
        .{ .func = 3 },
        .{ .imm_i64 = -42 },
        .{ .imm_u64 = 42 },
        .{ .imm_int = -7 },
        .{ .imm_float = 3.5 },
        .{ .op_code = .add },
        .{ .cap_prefix = .borrow },
        .{ .offset = 99 },
        .{ .ty = 4 },
        .{ .text = "plain operand text" },
        .{ .native_text = "mov %rax, %rbx" },
    };

    for (samples, 0..) |operand, idx| {
        var item = inst.makeInstruction(.assign, 30, @intCast(idx), null, "operand sample");
        item.operands[0] = operand;
        try instructions.append(item);
    }

    inline for (std.meta.tags(inst.OpCode).*) |value| {
        var item = inst.makeInstruction(.op, 40, @intCast(instructions.items.len), null, @tagName(value));
        item.operands[0] = .{ .op_code = value };
        try instructions.append(item);
    }

    inline for (std.meta.tags(inst.CapPrefix).*) |value| {
        var item = inst.makeInstruction(.borrow, 50, @intCast(instructions.items.len), null, @tagName(value));
        item.operands[0] = .{ .cap_prefix = value };
        try instructions.append(item);
    }

    const encoded = try encodeModule(std.testing.allocator, &.{ "r0", "sym", "label", "fn", "ty" }, instructions.items);
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeModule(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(instructions.items.len, decoded.instructions.len);
    for (instructions.items, decoded.instructions) |expected, got| {
        try expectOperandEqual(expected.operands[0], got.operands[0]);
    }
}

test "sab parenthesized panic operand stays structured" {
    var item = inst.makeInstruction(.panic, 3, 0, null, "");
    item.operands[0] = .{ .text = "(1701)" };

    const encoded = try encodeModule(std.testing.allocator, &.{}, &.{item});
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeModule(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(inst.InstKind.panic, decoded.instructions[0].kind);
    try std.testing.expectEqualStrings("(1701)", decoded.instructions[0].operands[0].text);
    try std.testing.expectEqualStrings("", decoded.instructions[0].raw_text);
}

test "sab no-destination call stays structured" {
    var item = inst.makeInstruction(.call, 3, 0, null, "");
    item.operands[0] = .{ .text = "@sink(value)" };

    const encoded = try encodeModule(std.testing.allocator, &.{}, &.{item});
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeModule(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(inst.InstKind.call, decoded.instructions[0].kind);
    try std.testing.expectEqualStrings("@sink(value)", decoded.instructions[0].operands[0].text);
    try std.testing.expectEqualStrings("", decoded.instructions[0].raw_text);
}

test "sab function signatures roundtrip without function header text" {
    const params = try std.testing.allocator.alloc(sig.ParamSpec, 1);
    defer std.testing.allocator.free(params);
    params[0] = .{ .name = "argc", .ty = .i32, .cap = .by_value };
    const param_ids = [_]u32{1};
    const reg_ids = [_]u32{1};
    const fsig = sig.FunctionSig{
        .id = 0,
        .name = "main",
        .params = params,
        .kind = .normal,
        .return_cap = null,
        .return_ty = .i32,
        .entry_inst_idx = 0,
        .is_ffi_wrapper = false,
        .upstream_file = "src/main.sars",
        .upstream_loc = .{ .file = "src/main.sars", .line = 11, .col = 2 },
        .param_ids = param_ids[0..],
        .reg_ids = reg_ids[0..],
        .llvm_name = "saasm_main",
    };

    const encoded = try encodeProgram(std.testing.allocator, &.{}, &.{fsig}, &.{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "@main") == null);

    var decoded = try decodeModule(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded.function_sigs.len);
    try std.testing.expectEqualStrings("main", decoded.function_sigs[0].name);
    try std.testing.expectEqual(sig.PrimType.i32, decoded.function_sigs[0].return_ty);
    try std.testing.expectEqualStrings("argc", decoded.function_sigs[0].params[0].name);
    try std.testing.expectEqualStrings("src/main.sars", decoded.function_sigs[0].upstream_file.?);
    try std.testing.expectEqualStrings("src/main.sars", decoded.function_sigs[0].upstream_loc.?.file);
    try std.testing.expectEqual(@as(u32, 11), decoded.function_sigs[0].upstream_loc.?.line);
    try std.testing.expectEqual(@as(u32, 2), decoded.function_sigs[0].upstream_loc.?.col);
    try std.testing.expectEqualStrings("saasm_main", decoded.function_sigs[0].llvm_name.?);
}

test "disasmModule produces readable text from binary SAB" {
    const reg_ids = [_]u32{1};
    const fsig_val = sig.FunctionSig{
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
    assign.operands[1] = .{ .imm_i64 = 42 };
    var ret = inst.makeInstruction(.return_, 3, 2, null, "");
    ret.operands[0] = .{ .reg = 1 };

    const encoded = try encodeProgram(std.testing.allocator, &.{ "main", "value" }, &.{fsig_val}, &.{ decl, assign, ret });
    defer std.testing.allocator.free(encoded);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try disasmModule(std.testing.allocator, encoded, &output.writer);

    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "func_decl") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "assign") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "return_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "@main") != null);
}

test "disasmModule separates call target from call args" {
    const reg_ids = [_]u32{1};
    const fsig_val = sig.FunctionSig{
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
    var call_item = inst.makeInstruction(.call, 2, 1, null, "");
    call_item.operands[0] = .{ .reg = 1 };
    call_item.operands[1] = .{ .text = "@sink(&arg, value)" };

    const encoded = try encodeProgram(std.testing.allocator, &.{ "main", "out" }, &.{fsig_val}, &.{ decl, call_item });
    defer std.testing.allocator.free(encoded);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try disasmModule(std.testing.allocator, encoded, &output.writer);

    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "call r1,\"@sink\",\"&arg, value\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "@sink(") == null);
}

test "decoded sab verifies through predecoded metadata without text parser" {
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

    const encoded = try encodeProgram(std.testing.allocator, &.{ "main", "value" }, &.{fsig}, &.{ decl, assign, ret });
    defer std.testing.allocator.free(encoded);
    var decoded = try decodeModule(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);

    const verifier = @import("verifier.zig");
    const verified = try verifier.verifyWithOptions(std.testing.allocator, decoded.instructions, &.{}, .{
        .predecoded_symbol_names = decoded.symbols,
        .predecoded_function_sigs = decoded.function_sigs,
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

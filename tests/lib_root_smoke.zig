const std = @import("std");
const saasm = @import("saasm");
const sio = @import("sio");

fn expectCliHelp(argv: []const []const u8, expected: []const u8) !void {
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const code = try saasm.cli.executeWithWriters(std.testing.allocator, argv, sio.managedWriter(&stdout_buffer), sio.managedWriter(&stderr_buffer));
    if (code != 0 or stderr_buffer.items.len != 0 or std.mem.indexOf(u8, stdout_buffer.items, expected) == null) {
        std.debug.print("help command failed: ", .{});
        for (argv) |arg| std.debug.print("{s} ", .{arg});
        std.debug.print("\ncode: {d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ code, stdout_buffer.items, stderr_buffer.items });
    }
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, expected) != null);
}

test "root module imports common types" {
    _ = saasm.common.instruction.InstKind.alloc;
    _ = saasm.common.capability.CapabilityMask.active;
    _ = saasm.common.trap.Trap.forbidden_syntax;
    _ = saasm.common.upstream_loc.UpstreamLoc;
    _ = saasm.common.gas.GasReport;
    _ = saasm.common.signature.FunctionSig;
    _ = saasm.test_executor.TestExecutor;
    _ = saasm.test_formatter.RunSummary{ .passed = 0, .failed = 0, .skipped = 0, .ignored = 0 };
    _ = saasm.test_meta.TestListOrder.Unsorted;
    _ = saasm.test_result.Termination{ .exited = 0 };
    _ = saasm.test_runner.run;
    _ = saasm.pkg.manifest.Capability.mem_alloc;
    _ = saasm.pkg.resolver.Dependency{ .url = "example", .ref = "HEAD" };

    const source =
        \\#def SIZE = 16
        \\L_START:
        \\node = alloc 8
    ;
    const lines = try saasm.flattener.scanSource(std.testing.allocator, source, &.{}, &.{});
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqual(saasm.flattener.LineKind.def, lines[0].classified.kind);
    try std.testing.expectEqual(saasm.flattener.LineKind.label, lines[1].classified.kind);
    try std.testing.expectEqual(saasm.flattener.InstructionForm.alloc, lines[2].classified.inst_form.?);

    const program = [_]saasm.flattener.Instruction{
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
            .raw_text = "@main() -> ptr:",
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
            .raw_text = "node = alloc 8",
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
            .raw_text = "return node",
        },
    };
    const verified = try saasm.referee.verify(std.testing.allocator, program[0..], &.{});
    switch (verified) {
        .ok => |ok| {
            var owned = ok;
            try std.testing.expectEqual(@as(usize, 3), owned.annotated.len);
            owned.deinit(std.testing.allocator);
        },
        .trap => return error.TestUnexpectedResult,
    }

    var flat_result = try saasm.flattener.flatten(std.testing.allocator, source);
    defer flat_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), flat_result.instructions.len);

    var layout_result = try saasm.layout.compute(std.testing.allocator, "Entity", "id:u32, pos:f64", 64);
    defer layout_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 16), layout_result.size);
    try std.testing.expectEqual(@as(u32, 8), layout_result.fields[1].offset);
}

test "cli command help covers built-in commands" {
    const cases = [_]struct {
        argv: []const []const u8,
        expected: []const u8,
    }{
        .{ .argv = &.{"sars", "init", "--help" }, .expected = "usage: sars init [path]" },
        .{ .argv = &.{"sars", "install", "--help" }, .expected = "usage: sars install [options] [identity]" },
        .{ .argv = &.{"sars", "plugin", "--help" }, .expected = "usage: sars plugin <install|list> [options]" },
        .{ .argv = &.{"sars", "plugin", "install", "--help" }, .expected = "usage: sars plugin install [--dev] [--review] <path|sap.json>" },
        .{ .argv = &.{"sars", "plugin", "list", "--help" }, .expected = "usage: sars plugin list" },
        .{ .argv = &.{"sars", "pkg", "--help" }, .expected = "usage: sars pkg <install|fetch|audit> [options]" },
        .{ .argv = &.{"sars", "pkg", "install", "--help" }, .expected = "usage: sars pkg install [options] [identity]" },
        .{ .argv = &.{"sars", "pkg", "fetch", "--help" }, .expected = "usage: sars pkg fetch [options] <identity>" },
        .{ .argv = &.{"sars", "pkg", "audit", "--help" }, .expected = "usage: sars pkg audit [options] <identity>" },
        .{ .argv = &.{"sars", "build", "--help" }, .expected = "usage: sars build <file> [options]" },
        .{ .argv = &.{"sars", "build-exe", "--help" }, .expected = "usage: sars build-exe <file> [options]" },
        .{ .argv = &.{"sars", "build-obj", "--help" }, .expected = "usage: sars build-obj <file> [options]" },
        .{ .argv = &.{"sars", "build-wasm", "--help" }, .expected = "usage: sars build-wasm <file> [options]" },
        .{ .argv = &.{"sars", "run", "--help" }, .expected = "usage: sars run <file> [compile-options] [args...]" },
        .{ .argv = &.{"sars", "fetch", "--help" }, .expected = "usage: sars fetch <identity>" },
        .{ .argv = &.{"sars", "audit", "--help" }, .expected = "usage: sars audit <identity>" },
        .{ .argv = &.{"sars", "graph", "--help" }, .expected = "usage: sars graph [path] [options]" },
        .{ .argv = &.{"sars", "layout", "--help" }, .expected = "usage: sars layout --name <TypeName> --fields <name:ty,...> [options]" },
        .{ .argv = &.{"sars", "size", "--help" }, .expected = "usage: sars size [path] [options]" },
        .{ .argv = &.{"sars", "test", "--help" }, .expected = "usage: sars test <file> [options]" },
        .{ .argv = &.{"sars", "test", "-h" }, .expected = "--filter <pattern>" },
        .{ .argv = &.{"sars", "bc2sa", "--help" }, .expected = "usage: sars bc2sa <file.bc>" },
        .{ .argv = &.{"sars", "explain", "--help" }, .expected = "usage: sars explain <code>" },
        .{ .argv = &.{"sars", "fix", "--help" }, .expected = "usage: sars fix [--plan] <code>" },
        .{ .argv = &.{"sars", "skills", "--help" }, .expected = "usage: sars skills [--json]" },
        .{ .argv = &.{"sars", "help", "--help" }, .expected = "usage: sars help [command]" },
        .{ .argv = &.{"sars", "version", "--help" }, .expected = "usage: sars version" },
        .{ .argv = &.{"sars", "help", "test" }, .expected = "usage: sars test <file> [options]" },
        .{ .argv = &.{"sars", "help", "pkg", "audit" }, .expected = "usage: sars pkg audit [options] <identity>" },
    };

    for (cases) |case| try expectCliHelp(case.argv, case.expected);
}

test "bc2sa rejects extra positional arguments" {
    var stdout_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const argv = [_][]const u8{"sars", "bc2sa", "input.bc", "extra" };
    try std.testing.expectError(error.UnexpectedArgument, saasm.cli.executeWithWriters(std.testing.allocator, argv[0..], sio.managedWriter(&stdout_buffer), sio.managedWriter(&stderr_buffer)));
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
}

test "release packager defaults to latest git tag" {
    const release_script = try sio.cwd().readFileAlloc(std.testing.allocator, "tools/release.sh", 1024 * 1024);
    defer std.testing.allocator.free(release_script);

    try std.testing.expect(std.mem.containsAtLeast(u8, release_script, 1, "latest_source_tag()"));
    try std.testing.expect(std.mem.containsAtLeast(u8, release_script, 1, "git -C \"$REPO_ROOT\" tag --sort=-v:refname"));
    try std.testing.expect(std.mem.containsAtLeast(u8, release_script, 1, "VERSION=\"$(latest_source_tag)\""));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, release_script, "describe --tags --exact-match"));
}

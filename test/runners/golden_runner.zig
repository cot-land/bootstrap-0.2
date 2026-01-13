//! Golden file test runner.
//!
//! Compares compiler output against known-good snapshots.
//! Go reference: Similar to Go's testdata golden file patterns.
//!
//! ## Usage
//!
//! Golden files are stored in test/golden/ with extensions indicating the phase:
//! - .ssa.golden - SSA dump output
//! - .generic.golden - Generic codegen output
//! - .arm64.golden - ARM64 codegen output
//! - .stderr.golden - Expected error output
//!
//! To update golden files, set COT_UPDATE_GOLDEN=1

const std = @import("std");

// Import compiler modules
const main = @import("main");
const ssa = main.ssa;
const codegen = main.codegen;

/// Golden test specification.
pub const GoldenTest = struct {
    name: []const u8,
    golden_path: []const u8,
    phase: Phase,
    setup_fn: *const fn (std.mem.Allocator) anyerror!TestOutput,

    pub const Phase = enum {
        ssa,
        generic_codegen,
        arm64_codegen,
    };
};

/// Output from running a test.
pub const TestOutput = struct {
    output: []const u8,
    func: ?*ssa.Func = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TestOutput) void {
        self.allocator.free(self.output);
        if (self.func) |f| {
            // Note: Func owns the allocator reference internally
            _ = f;
        }
    }
};

/// Simple line-by-line diff result.
const DiffResult = struct {
    has_differences: bool,
    first_diff_line: ?usize,
    expected_line: ?[]const u8,
    actual_line: ?[]const u8,
};

/// Compare two strings line by line.
fn simpleDiff(expected: []const u8, actual: []const u8) DiffResult {
    var exp_lines = std.mem.splitSequence(u8, expected, "\n");
    var act_lines = std.mem.splitSequence(u8, actual, "\n");

    var line_num: usize = 1;
    while (true) {
        const exp = exp_lines.next();
        const act = act_lines.next();

        if (exp == null and act == null) break;

        const exp_line = exp orelse "";
        const act_line = act orelse "";

        if (!std.mem.eql(u8, exp_line, act_line)) {
            return .{
                .has_differences = true,
                .first_diff_line = line_num,
                .expected_line = exp,
                .actual_line = act,
            };
        }
        line_num += 1;
    }

    return .{
        .has_differences = false,
        .first_diff_line = null,
        .expected_line = null,
        .actual_line = null,
    };
}

/// Run a golden test.
pub fn runGoldenTest(t: GoldenTest, allocator: std.mem.Allocator) !void {
    // Generate actual output
    var test_output = try t.setup_fn(allocator);
    defer test_output.deinit();

    const actual = test_output.output;

    // Check if we should update golden files
    const update_golden = std.process.getEnvVarOwned(allocator, "COT_UPDATE_GOLDEN") catch null;
    defer if (update_golden) |u| allocator.free(u);

    if (update_golden != null) {
        // Update mode: write actual output as new golden
        try writeGoldenFile(t.golden_path, actual);
        std.debug.print("Updated golden file: {s}\n", .{t.golden_path});
        return;
    }

    // Read expected golden file
    const expected = readGoldenFile(allocator, t.golden_path) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print(
                \\Golden file not found: {s}
                \\
                \\To create it, run with COT_UPDATE_GOLDEN=1
                \\
            , .{t.golden_path});
            return err;
        }
        return err;
    };
    defer allocator.free(expected);

    // Compare
    const result = simpleDiff(expected, actual);

    if (result.has_differences) {
        std.debug.print("\n=== Golden test FAILED: {s} ===\n", .{t.name});
        std.debug.print("First difference at line {d}:\n", .{result.first_diff_line.?});
        std.debug.print("  Expected: {s}\n", .{result.expected_line orelse "(missing)"});
        std.debug.print("  Actual:   {s}\n", .{result.actual_line orelse "(missing)"});

        // Write actual output for debugging
        const actual_path = try std.fmt.allocPrint(allocator, "{s}.actual", .{t.golden_path});
        defer allocator.free(actual_path);
        try writeGoldenFile(actual_path, actual);
        std.debug.print("\nActual output written to: {s}\n", .{actual_path});

        return error.GoldenMismatch;
    }
}

fn readGoldenFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    const content = try allocator.alloc(u8, stat.size);
    const bytes_read = try file.readAll(content);
    return content[0..bytes_read];
}

fn writeGoldenFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

// =========================================
// Example Golden Tests
// =========================================

fn setupSimpleAdd(allocator: std.mem.Allocator) !TestOutput {
    var f = ssa.Func.init(allocator, "simple_add");
    defer f.deinit();

    const entry = try f.newBlock(.ret);

    const c40 = try f.newValue(.const_int, 0, entry, .{});
    c40.aux_int = 40;
    try entry.addValue(allocator, c40);

    const c2 = try f.newValue(.const_int, 0, entry, .{});
    c2.aux_int = 2;
    try entry.addValue(allocator, c2);

    const add = try f.newValue(.add, 0, entry, .{});
    add.addArg2(c40, c2);
    try entry.addValue(allocator, add);
    entry.setControl(add);

    // Generate SSA dump
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    try ssa.dump(&f, .text, output.writer(allocator));

    return .{
        .output = try output.toOwnedSlice(allocator),
        .func = null,
        .allocator = allocator,
    };
}

fn setupSimpleAddGeneric(allocator: std.mem.Allocator) !TestOutput {
    var f = ssa.Func.init(allocator, "simple_add");
    defer f.deinit();

    const entry = try f.newBlock(.ret);

    const c40 = try f.newValue(.const_int, 0, entry, .{});
    c40.aux_int = 40;
    try entry.addValue(allocator, c40);

    const c2 = try f.newValue(.const_int, 0, entry, .{});
    c2.aux_int = 2;
    try entry.addValue(allocator, c2);

    const add = try f.newValue(.add, 0, entry, .{});
    add.addArg2(c40, c2);
    try entry.addValue(allocator, add);
    entry.setControl(add);

    // Generate generic codegen output
    var gen = codegen.GenericCodeGen.init(allocator);
    defer gen.deinit();

    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    try gen.generate(&f, output.writer(allocator));

    return .{
        .output = try output.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// All registered golden tests.
pub const golden_tests = [_]GoldenTest{
    .{
        .name = "simple_add SSA dump",
        .golden_path = "test/golden/ssa/simple_add.ssa.golden",
        .phase = .ssa,
        .setup_fn = setupSimpleAdd,
    },
    .{
        .name = "simple_add generic codegen",
        .golden_path = "test/golden/codegen/simple_add.generic.golden",
        .phase = .generic_codegen,
        .setup_fn = setupSimpleAddGeneric,
    },
};

// =========================================
// Test Entry Point
// =========================================

test "run all golden tests" {
    const allocator = std.testing.allocator;

    var failed: usize = 0;
    var passed: usize = 0;

    for (golden_tests) |t| {
        runGoldenTest(t, allocator) catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print("SKIP (no golden file): {s}\n", .{t.name});
                continue;
            }
            std.debug.print("FAIL: {s}\n", .{t.name});
            failed += 1;
            continue;
        };
        passed += 1;
    }

    std.debug.print("\nGolden tests: {d} passed, {d} failed\n", .{ passed, failed });

    if (failed > 0) {
        return error.GoldenTestsFailed;
    }
}

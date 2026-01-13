//! Cot 0.2 Bootstrap Compiler
//!
//! A complete rewrite using Go's proven compiler architecture.
//! See EXECUTION_PLAN.md for details.

const std = @import("std");

// Core modules
pub const core = struct {
    pub const types = @import("core/types.zig");
    pub const errors = @import("core/errors.zig");
    pub const testing = @import("core/testing.zig");
    pub const CompileError = errors.CompileError;
    pub const VerifyError = errors.VerifyError;
    pub const CountingAllocator = testing.CountingAllocator;
};

// SSA modules
pub const ssa = struct {
    pub const Value = @import("ssa/value.zig").Value;
    pub const Aux = @import("ssa/value.zig").Aux;
    pub const SymbolOff = @import("ssa/value.zig").SymbolOff;
    pub const CondCode = @import("ssa/value.zig").CondCode;
    pub const AuxCall = @import("ssa/value.zig").AuxCall;
    pub const Block = @import("ssa/block.zig").Block;
    pub const BlockKind = @import("ssa/block.zig").BlockKind;
    pub const Edge = @import("ssa/block.zig").Edge;
    pub const Func = @import("ssa/func.zig").Func;
    pub const Op = @import("ssa/op.zig").Op;
    pub const OpInfo = @import("ssa/op.zig").OpInfo;

    // Pass infrastructure
    pub const compile = @import("ssa/compile.zig");
    pub const Pass = compile.Pass;
    pub const Config = compile.Config;

    // Analysis
    pub const dom = @import("ssa/dom.zig");
    pub const DomTree = dom.DomTree;
    pub const computeDominators = dom.computeDominators;

    // Debug
    pub const debug = @import("ssa/debug.zig");

    pub const Format = debug.Format;
    pub const dump = debug.dump;
    pub const dumpToFile = debug.dumpToFile;
    pub const verify = debug.verify;

    // Test helpers (for testing infrastructure)
    pub const test_helpers = @import("ssa/test_helpers.zig");
    pub const TestFuncBuilder = test_helpers.TestFuncBuilder;
};

// Code generation modules
pub const codegen = struct {
    pub const generic = @import("codegen/generic.zig");
    pub const arm64 = @import("codegen/arm64.zig");
    pub const GenericCodeGen = generic.GenericCodeGen;
    pub const ARM64CodeGen = arm64.ARM64CodeGen;
};

pub fn main() !void {
    // Parse command-line arguments
    var args = std.process.args();
    _ = args.skip(); // Skip program name

    const input_file = args.next() orelse {
        std.debug.print("Usage: cot <input.cot> -o <output>\n", .{});
        return;
    };

    std.debug.print("Cot 0.2 Bootstrap Compiler\n", .{});
    std.debug.print("Input: {s}\n", .{input_file});

    // TODO: Implement compilation pipeline
    // 1. Parse source file
    // 2. Type check
    // 3. Lower to IR
    // 4. Convert to SSA
    // 5. Run optimization passes
    // 6. Register allocation
    // 7. Code generation
    // 8. Write object file

    std.debug.print("\nCompilation pipeline not yet implemented.\n", .{});
    std.debug.print("Run 'zig build test' to verify core data structures.\n", .{});
}

// =========================================
// Tests - Import all test modules
// =========================================

test {
    // Core modules
    _ = @import("core/types.zig");
    _ = @import("core/errors.zig");
    _ = @import("core/testing.zig");

    // SSA modules
    _ = @import("ssa/value.zig");
    _ = @import("ssa/block.zig");
    _ = @import("ssa/func.zig");
    _ = @import("ssa/op.zig");

    // New modules
    _ = @import("ssa/compile.zig");
    _ = @import("ssa/dom.zig");
    _ = @import("ssa/debug.zig");
    _ = @import("ssa/test_helpers.zig");

    // Code generation
    _ = @import("codegen/generic.zig");
    _ = @import("codegen/arm64.zig");
}

test "SSA integration: build simple function" {
    const allocator = std.testing.allocator;

    // Build: fn test() int { return 40 + 2; }
    var f = ssa.Func.init(allocator, "test");
    defer f.deinit();

    // Create entry block
    const entry = try f.newBlock(.plain);

    // Create constants
    const c40 = try f.newValue(.const_int, 0, entry, .{});
    c40.aux_int = 40;
    try entry.addValue(allocator, c40);

    const c2 = try f.newValue(.const_int, 0, entry, .{});
    c2.aux_int = 2;
    try entry.addValue(allocator, c2);

    // Create add
    const add = try f.newValue(.add, 0, entry, .{});
    add.addArg2(c40, c2);
    try entry.addValue(allocator, add);

    // Create return block
    const ret_block = try f.newBlock(.ret);
    ret_block.setControl(add);

    // Connect blocks
    try entry.addEdgeTo(allocator, ret_block);

    // Verify structure
    try std.testing.expectEqual(@as(usize, 2), f.numBlocks());
    try std.testing.expectEqual(@as(usize, 3), entry.values.items.len);
    try std.testing.expectEqual(@as(i32, 1), c40.uses); // Used by add
    try std.testing.expectEqual(@as(i32, 1), c2.uses); // Used by add
    try std.testing.expectEqual(@as(i32, 1), add.uses); // Used by ret control

    // Verify CFG
    try std.testing.expectEqual(@as(usize, 1), entry.succs.len);
    try std.testing.expectEqual(ret_block, entry.succs[0].b);
}

test "SSA integration: build if-else" {
    const allocator = std.testing.allocator;

    // Build: if (cond) { x = 1 } else { x = 2 }; return x
    var f = ssa.Func.init(allocator, "test_if");
    defer f.deinit();

    // Create blocks
    const entry = try f.newBlock(.if_);
    const b_then = try f.newBlock(.plain);
    const b_else = try f.newBlock(.plain);
    const b_end = try f.newBlock(.ret);

    // Entry: condition
    const cond = try f.newValue(.const_bool, 0, entry, .{});
    cond.aux_int = 1;
    try entry.addValue(allocator, cond);
    entry.setControl(cond);

    // Then: x = 1
    const c1 = try f.newValue(.const_int, 0, b_then, .{});
    c1.aux_int = 1;
    try b_then.addValue(allocator, c1);

    // Else: x = 2
    const c2 = try f.newValue(.const_int, 0, b_else, .{});
    c2.aux_int = 2;
    try b_else.addValue(allocator, c2);

    // End: phi(c1, c2)
    const phi = try f.newValue(.phi, 0, b_end, .{});
    phi.addArg2(c1, c2);
    try b_end.addValue(allocator, phi);
    b_end.setControl(phi);

    // Connect CFG
    try entry.addEdgeTo(allocator, b_then); // true branch
    try entry.addEdgeTo(allocator, b_else); // false branch
    try b_then.addEdgeTo(allocator, b_end);
    try b_else.addEdgeTo(allocator, b_end);

    // Verify structure
    try std.testing.expectEqual(@as(usize, 4), f.numBlocks());
    try std.testing.expectEqual(@as(usize, 2), entry.succs.len);
    try std.testing.expectEqual(@as(usize, 2), b_end.preds.len);

    // Verify phi has both args
    try std.testing.expectEqual(@as(usize, 2), phi.argsLen());
}

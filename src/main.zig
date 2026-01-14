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

    pub const liveness = @import("ssa/liveness.zig");
    pub const LiveInfo = liveness.LiveInfo;
    pub const LiveMap = liveness.LiveMap;
    pub const LivenessResult = liveness.LivenessResult;
    pub const computeLiveness = liveness.computeLiveness;

    pub const regalloc_mod = @import("ssa/regalloc.zig");
    pub const RegAllocState = regalloc_mod.RegAllocState;
    pub const ValState = regalloc_mod.ValState;
    pub const RegState = regalloc_mod.RegState;
    pub const ARM64Regs = regalloc_mod.ARM64Regs;
    pub const regalloc = regalloc_mod.regalloc;

    // Passes
    pub const lower = @import("ssa/passes/lower.zig");
    pub const ARM64Op = lower.ARM64Op;
    pub const LoweringResult = lower.LoweringResult;

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

// ARM64 instruction encoding
pub const arm64_asm = @import("arm64/asm.zig");

// Object file output
pub const macho = @import("obj/macho.zig");

// Frontend modules (ported from bootstrap using Go patterns)
pub const frontend = struct {
    pub const token = @import("frontend/token.zig");
    pub const source = @import("frontend/source.zig");
    pub const errors = @import("frontend/errors.zig");
    pub const scanner = @import("frontend/scanner.zig");
    pub const ast = @import("frontend/ast.zig");
    pub const parser = @import("frontend/parser.zig");
    pub const types = @import("frontend/types.zig");
    pub const checker = @import("frontend/checker.zig");
    pub const ir = @import("frontend/ir.zig");
    pub const lower = @import("frontend/lower.zig");

    pub const Token = token.Token;
    pub const Pos = source.Pos;
    pub const Position = source.Position;
    pub const Span = source.Span;
    pub const Source = source.Source;
    pub const Error = errors.Error;
    pub const ErrorCode = errors.ErrorCode;
    pub const ErrorReporter = errors.ErrorReporter;
    pub const Scanner = scanner.Scanner;
    pub const TokenInfo = scanner.TokenInfo;
    pub const Ast = ast.Ast;
    pub const Node = ast.Node;
    pub const NodeIndex = ast.NodeIndex;
    pub const null_node = ast.null_node;
    pub const Parser = parser.Parser;
    pub const TypeIndex = types.TypeIndex;
    pub const TypeRegistry = types.TypeRegistry;
    pub const Type = types.Type;
    pub const Checker = checker.Checker;
    pub const Scope = checker.Scope;
    pub const Symbol = checker.Symbol;

    // IR types
    pub const IR = ir.IR;
    pub const IRNode = ir.Node;
    pub const IRNodeIndex = ir.NodeIndex;
    pub const IRLocalIdx = ir.LocalIdx;
    pub const IRBlockIndex = ir.BlockIndex;
    pub const IRFunc = ir.Func;
    pub const IRFuncBuilder = ir.FuncBuilder;
    pub const IRBuilder = ir.Builder;
    pub const BinaryOp = ir.BinaryOp;
    pub const UnaryOp = ir.UnaryOp;

    // Lowerer
    pub const Lowerer = lower.Lowerer;
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
    _ = @import("ssa/liveness.zig");
    _ = @import("ssa/regalloc.zig");
    _ = @import("ssa/passes/lower.zig");

    // Code generation
    _ = @import("codegen/generic.zig");
    _ = @import("codegen/arm64.zig");

    // ARM64 encoding
    _ = @import("arm64/asm.zig");

    // Object output
    _ = @import("obj/macho.zig");

    // Frontend modules
    _ = @import("frontend/token.zig");
    _ = @import("frontend/source.zig");
    _ = @import("frontend/errors.zig");
    _ = @import("frontend/scanner.zig");
    _ = @import("frontend/ast.zig");
    _ = @import("frontend/parser.zig");
    _ = @import("frontend/types.zig");
    _ = @import("frontend/checker.zig");
    _ = @import("frontend/ir.zig");
    _ = @import("frontend/lower.zig");
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

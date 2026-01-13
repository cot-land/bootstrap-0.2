//! Test helpers for SSA testing.
//!
//! Go reference: [export_test.go] pattern - expose internals for testing
//!
//! Provides utilities for creating test fixtures and validating invariants
//! without polluting the public API.
//!
//! ## Fixtures
//!
//! - [TestFuncBuilder] - Fluent builder for test functions
//! - [createDiamondCFG] - Common if-else merge pattern
//! - [createLinearCFG] - Simple sequence of blocks
//!
//! ## Validation
//!
//! - [validateInvariants] - Check all SSA invariants
//! - [validateUseCounts] - Verify use count consistency
//! - [validateEdges] - Check bidirectional edge invariant
//!
//! ## Example
//!
//! ```zig
//! const builder = TestFuncBuilder.init(allocator, "test");
//! defer builder.deinit();
//!
//! const diamond = try builder.createDiamondCFG();
//! // diamond.entry, diamond.then_block, diamond.else_block, diamond.merge
//!
//! try validateInvariants(builder.func);
//! ```

const std = @import("std");
const Func = @import("func.zig").Func;
const Block = @import("block.zig").Block;
const BlockKind = @import("block.zig").BlockKind;
const Value = @import("value.zig").Value;
const Op = @import("op.zig").Op;
const types = @import("../core/types.zig");
const errors = @import("../core/errors.zig");

const ID = types.ID;
const VerifyError = errors.VerifyError;

/// Result of creating a diamond CFG pattern.
pub const DiamondCFG = struct {
    entry: *Block,
    then_block: *Block,
    else_block: *Block,
    merge: *Block,
    /// Condition value in entry block
    condition: *Value,
    /// Phi node in merge block (if created)
    phi: ?*Value,
};

/// Result of creating a linear CFG pattern.
pub const LinearCFG = struct {
    blocks: []*Block,
    entry: *Block,
    exit: *Block,
};

/// Fluent builder for creating test functions.
pub const TestFuncBuilder = struct {
    func: *Func,
    allocator: std.mem.Allocator,
    owned: bool,

    /// Initialize builder with new function.
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !TestFuncBuilder {
        const f = try allocator.create(Func);
        f.* = Func.init(allocator, name);
        return .{
            .func = f,
            .allocator = allocator,
            .owned = true,
        };
    }

    /// Initialize builder with existing function.
    pub fn withFunc(f: *Func) TestFuncBuilder {
        return .{
            .func = f,
            .allocator = f.allocator,
            .owned = false,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *TestFuncBuilder) void {
        if (self.owned) {
            self.func.deinit();
            self.allocator.destroy(self.func);
        }
    }

    /// Create a simple diamond CFG (if-then-else-merge).
    ///
    /// ```
    ///     entry (if_)
    ///      / \
    ///  then   else
    ///      \ /
    ///    merge (ret)
    /// ```
    pub fn createDiamondCFG(self: *TestFuncBuilder) !DiamondCFG {
        const entry = try self.func.newBlock(.if_);
        const then_block = try self.func.newBlock(.plain);
        const else_block = try self.func.newBlock(.plain);
        const merge = try self.func.newBlock(.ret);

        // Create condition
        const cond = try self.func.newValue(.const_bool, 0, entry, .{});
        cond.aux_int = 1;
        try entry.addValue(self.allocator, cond);
        entry.setControl(cond);

        // Connect edges
        try entry.addEdgeTo(self.allocator, then_block); // True branch
        try entry.addEdgeTo(self.allocator, else_block); // False branch
        try then_block.addEdgeTo(self.allocator, merge);
        try else_block.addEdgeTo(self.allocator, merge);

        return .{
            .entry = entry,
            .then_block = then_block,
            .else_block = else_block,
            .merge = merge,
            .condition = cond,
            .phi = null,
        };
    }

    /// Create diamond with values in branches and phi at merge.
    pub fn createDiamondWithPhi(self: *TestFuncBuilder) !DiamondCFG {
        var diamond = try self.createDiamondCFG();

        // Add values to branches
        const then_val = try self.func.newValue(.const_int, 0, diamond.then_block, .{});
        then_val.aux_int = 1;
        try diamond.then_block.addValue(self.allocator, then_val);

        const else_val = try self.func.newValue(.const_int, 0, diamond.else_block, .{});
        else_val.aux_int = 2;
        try diamond.else_block.addValue(self.allocator, else_val);

        // Create phi at merge
        const phi = try self.func.newValue(.phi, 0, diamond.merge, .{});
        phi.addArg2(then_val, else_val);
        try diamond.merge.addValue(self.allocator, phi);
        diamond.merge.setControl(phi);
        diamond.phi = phi;

        return diamond;
    }

    /// Create a linear sequence of blocks.
    ///
    /// ```
    /// b0 -> b1 -> b2 -> ... -> bN
    /// ```
    pub fn createLinearCFG(self: *TestFuncBuilder, count: usize) !LinearCFG {
        if (count == 0) return error.InvalidCount;

        var blocks = try self.allocator.alloc(*Block, count);

        // Create blocks
        for (0..count) |i| {
            const kind: BlockKind = if (i == count - 1) .ret else .plain;
            blocks[i] = try self.func.newBlock(kind);
        }

        // Connect edges
        for (0..count - 1) |i| {
            try blocks[i].addEdgeTo(self.allocator, blocks[i + 1]);
        }

        return .{
            .blocks = blocks,
            .entry = blocks[0],
            .exit = blocks[count - 1],
        };
    }

    /// Add a constant integer to a block.
    pub fn addConst(self: *TestFuncBuilder, block: *Block, value: i64) !*Value {
        const v = try self.func.newValue(.const_int, 0, block, .{});
        v.aux_int = value;
        try block.addValue(self.allocator, v);
        return v;
    }

    /// Add a binary operation to a block.
    pub fn addBinOp(self: *TestFuncBuilder, block: *Block, op: Op, left: *Value, right: *Value) !*Value {
        const v = try self.func.newValue(op, 0, block, .{});
        v.addArg2(left, right);
        try block.addValue(self.allocator, v);
        return v;
    }
};

/// Validate all SSA invariants for a function.
///
/// Returns a list of errors found (empty if valid).
pub fn validateInvariants(f: *const Func, allocator: std.mem.Allocator) ![]VerifyError {
    var errors_list = std.ArrayListUnmanaged(VerifyError){};

    // Check each block
    for (f.blocks.items) |b| {
        // Check value membership
        for (b.values.items) |v| {
            if (v.block != b) {
                try errors_list.append(allocator, .{
                    .message = "value block pointer mismatch",
                    .block_id = b.id,
                    .value_id = v.id,
                });
            }
        }

        // Check edge invariants
        for (b.succs, 0..) |succ, i| {
            if (succ.i >= succ.b.preds.len or succ.b.preds[succ.i].b != b) {
                try errors_list.append(allocator, .{
                    .message = "successor edge invariant violated",
                    .block_id = b.id,
                });
            }
            _ = i;
        }

        for (b.preds, 0..) |pred, i| {
            if (pred.i >= pred.b.succs.len or pred.b.succs[pred.i].b != b) {
                try errors_list.append(allocator, .{
                    .message = "predecessor edge invariant violated",
                    .block_id = b.id,
                });
            }
            _ = i;
        }
    }

    return errors_list.toOwnedSlice(allocator);
}

/// Validate use counts are consistent.
///
/// Recomputes use counts from scratch and compares to stored values.
pub fn validateUseCounts(f: *const Func, allocator: std.mem.Allocator) ![]VerifyError {
    var errors_list = std.ArrayListUnmanaged(VerifyError){};

    // Build map of expected use counts
    var expected_uses = std.AutoHashMap(ID, i32).init(allocator);
    defer expected_uses.deinit();

    // Count uses from value args
    for (f.blocks.items) |b| {
        for (b.values.items) |v| {
            for (v.args) |arg| {
                const entry = try expected_uses.getOrPut(arg.id);
                if (!entry.found_existing) {
                    entry.value_ptr.* = 0;
                }
                entry.value_ptr.* += 1;
            }
        }

        // Count uses from control values
        for (b.controlValues()) |cv| {
            const entry = try expected_uses.getOrPut(cv.id);
            if (!entry.found_existing) {
                entry.value_ptr.* = 0;
            }
            entry.value_ptr.* += 1;
        }
    }

    // Compare against actual use counts
    for (f.blocks.items) |b| {
        for (b.values.items) |v| {
            const expected = expected_uses.get(v.id) orelse 0;
            if (v.uses != expected) {
                try errors_list.append(allocator, .{
                    .message = "use count mismatch",
                    .value_id = v.id,
                    .block_id = b.id,
                });
            }
        }
    }

    return errors_list.toOwnedSlice(allocator);
}

/// Free verification errors.
pub fn freeErrors(errs: []VerifyError, allocator: std.mem.Allocator) void {
    allocator.free(errs);
}

// =========================================
// Tests
// =========================================

test "TestFuncBuilder diamond CFG" {
    const allocator = std.testing.allocator;

    var builder = try TestFuncBuilder.init(allocator, "test_diamond");
    defer builder.deinit();

    const diamond = try builder.createDiamondCFG();

    // Verify structure
    try std.testing.expectEqual(@as(usize, 4), builder.func.numBlocks());
    try std.testing.expectEqual(@as(usize, 2), diamond.entry.succs.len);
    try std.testing.expectEqual(@as(usize, 2), diamond.merge.preds.len);

    // Verify invariants
    const errs = try validateInvariants(builder.func, allocator);
    defer freeErrors(errs, allocator);
    try std.testing.expectEqual(@as(usize, 0), errs.len);
}

test "TestFuncBuilder diamond with phi" {
    const allocator = std.testing.allocator;

    var builder = try TestFuncBuilder.init(allocator, "test_phi");
    defer builder.deinit();

    const diamond = try builder.createDiamondWithPhi();

    // Verify phi exists
    try std.testing.expect(diamond.phi != null);
    try std.testing.expectEqual(@as(usize, 2), diamond.phi.?.argsLen());

    // Verify use counts
    const errs = try validateUseCounts(builder.func, allocator);
    defer freeErrors(errs, allocator);
    try std.testing.expectEqual(@as(usize, 0), errs.len);
}

test "TestFuncBuilder linear CFG" {
    const allocator = std.testing.allocator;

    var builder = try TestFuncBuilder.init(allocator, "test_linear");
    defer builder.deinit();

    const linear = try builder.createLinearCFG(5);
    defer builder.allocator.free(linear.blocks);

    try std.testing.expectEqual(@as(usize, 5), linear.blocks.len);
    try std.testing.expectEqual(linear.blocks[0], linear.entry);
    try std.testing.expectEqual(linear.blocks[4], linear.exit);

    // Verify chain
    for (0..4) |i| {
        try std.testing.expectEqual(@as(usize, 1), linear.blocks[i].succs.len);
        try std.testing.expectEqual(linear.blocks[i + 1], linear.blocks[i].succs[0].b);
    }
}

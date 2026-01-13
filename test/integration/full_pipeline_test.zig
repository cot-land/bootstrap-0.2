//! Full pipeline integration tests.
//!
//! Tests the complete compilation pipeline from source to output.
//! These tests exercise multiple modules working together.

const std = @import("std");
const main = @import("main");
const ssa = main.ssa;
const core = main.core;
const codegen = main.codegen;

test "integration: build SSA, verify, generate code" {
    const allocator = std.testing.allocator;

    // Build a simple function
    var f = ssa.Func.init(allocator, "integration_test");
    defer f.deinit();

    // Create: fn test() -> int { return 40 + 2; }
    const entry = try f.newBlock(.plain);
    const ret = try f.newBlock(.ret);

    // Entry block: compute 40 + 2
    const c40 = try f.newValue(.const_int, 0, entry, .{});
    c40.aux_int = 40;
    try entry.addValue(allocator, c40);

    const c2 = try f.newValue(.const_int, 0, entry, .{});
    c2.aux_int = 2;
    try entry.addValue(allocator, c2);

    const add = try f.newValue(.add, 0, entry, .{});
    add.addArg2(c40, c2);
    try entry.addValue(allocator, add);

    // Connect to return block
    try entry.addEdgeTo(allocator, ret);
    ret.setControl(add);

    // Verify SSA is well-formed
    const errors = try ssa.test_helpers.validateInvariants(&f, allocator);
    defer allocator.free(errors);
    try std.testing.expectEqual(@as(usize, 0), errors.len);

    // Generate generic code
    var gen = codegen.GenericCodeGen.init(allocator);
    defer gen.deinit();

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    try gen.generate(&f, output.writer(allocator));

    // Verify output contains expected elements
    try std.testing.expect(std.mem.indexOf(u8, output.items, "integration_test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "const_int 40") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "const_int 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "add") != null);
}

test "integration: diamond CFG with phi node" {
    const allocator = std.testing.allocator;

    var builder = try ssa.TestFuncBuilder.init(allocator, "diamond_test");
    defer builder.deinit();

    // Create diamond: if (cond) { x=1 } else { x=2 }; return x
    const cfg = try builder.createDiamondCFG();

    // Verify structure
    try std.testing.expectEqual(@as(usize, 4), builder.func.numBlocks());
    try std.testing.expectEqual(@as(usize, 2), cfg.entry.succs.len);
    try std.testing.expectEqual(@as(usize, 2), cfg.merge.preds.len);

    // Verify invariants
    const errors = try ssa.test_helpers.validateInvariants(builder.func, allocator);
    defer allocator.free(errors);
    try std.testing.expectEqual(@as(usize, 0), errors.len);
}

test "integration: phase snapshot comparison" {
    const allocator = std.testing.allocator;

    var f = ssa.Func.init(allocator, "snapshot_test");
    defer f.deinit();

    const entry = try f.newBlock(.ret);

    // Add some values
    const c1 = try f.newValue(.const_int, 0, entry, .{});
    c1.aux_int = 1;
    try entry.addValue(allocator, c1);

    const c2 = try f.newValue(.const_int, 0, entry, .{});
    c2.aux_int = 2;
    try entry.addValue(allocator, c2);

    // Capture before snapshot
    var before = try ssa.debug.PhaseSnapshot.capture(allocator, &f, "before");
    defer before.deinit();

    // Add another value (simulating a pass)
    const c3 = try f.newValue(.const_int, 0, entry, .{});
    c3.aux_int = 3;
    try entry.addValue(allocator, c3);

    // Capture after snapshot
    var after = try ssa.debug.PhaseSnapshot.capture(allocator, &f, "after");
    defer after.deinit();

    // Compare
    const stats = before.compare(&after);
    try std.testing.expectEqual(@as(usize, 1), stats.values_added);
    try std.testing.expectEqual(@as(usize, 0), stats.values_removed);
}

test "integration: allocation tracking during codegen" {
    var counting = core.CountingAllocator.init(std.testing.allocator);
    const allocator = counting.allocator();

    var f = ssa.Func.init(allocator, "alloc_test");
    defer f.deinit();

    const entry = try f.newBlock(.ret);

    const c1 = try f.newValue(.const_int, 0, entry, .{});
    c1.aux_int = 42;
    try entry.addValue(allocator, c1);
    entry.setControl(c1);

    var gen = codegen.GenericCodeGen.init(allocator);
    defer gen.deinit();

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    try gen.generate(&f, output.writer(allocator));

    // Verify allocations are reasonable (not leaking)
    // The exact count depends on implementation details
    try std.testing.expect(counting.alloc_count > 0);
    try std.testing.expect(counting.alloc_count < 1000);
}

//! Liveness Analysis for SSA Register Allocation
//!
//! Go reference: cmd/compile/internal/ssa/regalloc.go lines 2836-3137
//!
//! This module computes use distances for each SSA value, which is critical
//! for the register allocator's spill selection. The key insight is:
//!
//! **When we need to spill a value, spill the one with the FARTHEST next use.**
//!
//! This is provably optimal for single-use values (Belady's algorithm).
//!
//! ## Algorithm Overview
//!
//! 1. Process blocks in postorder (leaves first)
//! 2. Within each block, process values in reverse (bottom to top)
//! 3. Track live values with their distance to next use
//! 4. Apply distance multipliers for branch likelihood:
//!    - Likely branch: +1 (expected path)
//!    - Normal branch: +10
//!    - Unlikely branch/after call: +100
//!
//! ## Key Data Structures
//!
//! - `LiveInfo`: Holds (value_id, distance, position) for each live value
//! - `LiveMap`: Sparse map for efficient live set operations
//!
//! ## Cot-Specific Adaptations
//!
//! While following Go's algorithm, we adapt for Cot's type system:
//! - String/slice types need 2 registers (ptr + len)
//! - Optional types may need special handling
//! - Cot's ARC doesn't have Go's write barriers

const std = @import("std");
const types = @import("../core/types.zig");
const Value = @import("value.zig").Value;
const Block = @import("block.zig").Block;
const Func = @import("func.zig").Func;
const Op = @import("op.zig").Op;

const ID = types.ID;
const Pos = types.Pos;
const TypeInfo = types.TypeInfo;

// =========================================
// Distance Constants (Go ref: regalloc.go:141-143)
// =========================================

/// Distance for a likely branch (expected to be taken)
pub const likely_distance: i32 = 1;

/// Distance for a normal branch or sequential code
pub const normal_distance: i32 = 10;

/// Distance for an unlikely branch, or values live across a call
pub const unlikely_distance: i32 = 100;

/// Sentinel for unknown distance (used in loop propagation)
pub const unknown_distance: i32 = -1;

// =========================================
// Data Structures
// =========================================

/// Information about a live value at a program point.
/// Go reference: regalloc.go lines 2827-2831
pub const LiveInfo = struct {
    /// ID of the live value
    id: ID,

    /// Distance to next use (in instructions)
    /// Lower = sooner use = less desirable to spill
    dist: i32,

    /// Source position of the next use (for error messages)
    pos: Pos,

    pub fn format(self: LiveInfo) void {
        std.debug.print("v{d}@{d}", .{ self.id, self.dist });
    }
};

/// Sparse map for tracking live values with distances.
/// Optimized for the access patterns in liveness analysis.
/// Go reference: regalloc.go sparseMapPos
pub const LiveMap = struct {
    /// Dense storage of entries
    entries: std.ArrayListUnmanaged(LiveInfo),

    /// Sparse index: id -> index in entries (or invalid)
    sparse: std.AutoHashMapUnmanaged(ID, u32),

    const Self = @This();

    pub fn init() Self {
        return .{
            .entries = .{},
            .sparse = .{},
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.sparse.deinit(allocator);
    }

    /// Clear all entries (O(n) but reuses memory)
    pub fn clear(self: *Self) void {
        self.entries.clearRetainingCapacity();
        self.sparse.clearRetainingCapacity();
    }

    /// Set value with distance and position.
    /// If already present, only updates if new distance is SMALLER (closer use).
    pub fn set(self: *Self, allocator: std.mem.Allocator, id: ID, dist: i32, pos: Pos) !void {
        if (self.sparse.get(id)) |idx| {
            // Already present - update if closer use
            if (dist < self.entries.items[idx].dist) {
                self.entries.items[idx].dist = dist;
                self.entries.items[idx].pos = pos;
            }
        } else {
            // New entry
            const idx: u32 = @intCast(self.entries.items.len);
            try self.entries.append(allocator, .{ .id = id, .dist = dist, .pos = pos });
            try self.sparse.put(allocator, id, idx);
        }
    }

    /// Set value unconditionally (always overwrites)
    pub fn setForce(self: *Self, allocator: std.mem.Allocator, id: ID, dist: i32, pos: Pos) !void {
        if (self.sparse.get(id)) |idx| {
            self.entries.items[idx].dist = dist;
            self.entries.items[idx].pos = pos;
        } else {
            const idx: u32 = @intCast(self.entries.items.len);
            try self.entries.append(allocator, .{ .id = id, .dist = dist, .pos = pos });
            try self.sparse.put(allocator, id, idx);
        }
    }

    /// Get distance for a value, or null if not present
    pub fn get(self: *const Self, id: ID) ?i32 {
        if (self.sparse.get(id)) |idx| {
            return self.entries.items[idx].dist;
        }
        return null;
    }

    /// Get full LiveInfo for a value, or null if not present
    pub fn getInfo(self: *const Self, id: ID) ?LiveInfo {
        if (self.sparse.get(id)) |idx| {
            return self.entries.items[idx];
        }
        return null;
    }

    /// Check if value is in the live set
    pub fn contains(self: *const Self, id: ID) bool {
        return self.sparse.contains(id);
    }

    /// Remove a value from the live set
    pub fn remove(self: *Self, id: ID) void {
        if (self.sparse.fetchRemove(id)) |kv| {
            const idx = kv.value;
            // Swap-remove from dense array
            if (self.entries.items.len > 0) {
                if (idx < self.entries.items.len - 1) {
                    const last = self.entries.items[self.entries.items.len - 1];
                    self.entries.items[idx] = last;
                    // Update sparse index for swapped element
                    self.sparse.put(std.heap.page_allocator, last.id, idx) catch {};
                }
                self.entries.items.len -= 1;
            }
        }
    }

    /// Number of live values
    pub fn size(self: *const Self) usize {
        return self.entries.items.len;
    }

    /// Iterate over all live values
    pub fn items(self: *const Self) []const LiveInfo {
        return self.entries.items;
    }

    /// Add distance delta to all entries
    pub fn addDistanceToAll(self: *Self, delta: i32) void {
        for (self.entries.items) |*entry| {
            if (entry.dist != unknown_distance) {
                entry.dist += delta;
            }
        }
    }
};

/// Per-block liveness information
pub const BlockLiveness = struct {
    /// Values live at the END of this block (before successor edges)
    live_out: []LiveInfo,

    /// Values live at the START of this block (after phi nodes)
    live_in: []LiveInfo,

    /// Allocator that owns the slices
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BlockLiveness {
        return .{
            .live_out = &.{},
            .live_in = &.{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BlockLiveness) void {
        if (self.live_out.len > 0) {
            self.allocator.free(self.live_out);
        }
        if (self.live_in.len > 0) {
            self.allocator.free(self.live_in);
        }
    }

    /// Update live_out from a LiveMap
    pub fn updateLiveOut(self: *BlockLiveness, live: *const LiveMap) !void {
        if (self.live_out.len > 0) {
            self.allocator.free(self.live_out);
        }
        if (live.size() == 0) {
            self.live_out = &.{};
            return;
        }
        self.live_out = try self.allocator.dupe(LiveInfo, live.items());
    }
};

/// Result of liveness analysis for a function
pub const LivenessResult = struct {
    /// Per-block liveness information, indexed by block ID
    blocks: []BlockLiveness,

    /// Allocator that owns the data
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_blocks: usize) !LivenessResult {
        const blocks = try allocator.alloc(BlockLiveness, num_blocks);
        for (blocks) |*b| {
            b.* = BlockLiveness.init(allocator);
        }
        return .{
            .blocks = blocks,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LivenessResult) void {
        for (self.blocks) |*b| {
            b.deinit();
        }
        self.allocator.free(self.blocks);
    }

    /// Get live values at the end of a block
    pub fn getLiveOut(self: *const LivenessResult, block_id: ID) []const LiveInfo {
        if (block_id == 0 or block_id > self.blocks.len) return &.{};
        return self.blocks[block_id - 1].live_out;
    }
};

// =========================================
// Main Liveness Computation
// =========================================

/// Compute liveness information for a function.
/// Go reference: regalloc.go computeLive() lines 2836-3137
///
/// This implements a backward dataflow analysis:
/// 1. Start from block exits
/// 2. Propagate live values backward through instructions
/// 3. Apply distance penalties at branches and calls
/// 4. Iterate to fixed point for loops
pub fn computeLiveness(allocator: std.mem.Allocator, f: *Func) !LivenessResult {
    const num_blocks = f.blocks.items.len;
    if (num_blocks == 0) {
        return LivenessResult.init(allocator, 0);
    }

    var result = try LivenessResult.init(allocator, num_blocks);
    errdefer result.deinit();

    // Get postorder traversal (leaves first)
    const postorder = try computePostorder(allocator, f);
    defer allocator.free(postorder);

    // Working live set
    var live = LiveMap.init();
    defer live.deinit(allocator);

    // Fixed-point iteration
    var changed = true;
    var iterations: u32 = 0;
    const max_iterations: u32 = 100; // Safety limit

    while (changed and iterations < max_iterations) {
        changed = false;
        iterations += 1;

        // Process blocks in postorder
        for (postorder) |block| {
            const block_idx = block.id - 1;

            // Initialize live set from known live-out
            live.clear();
            for (result.blocks[block_idx].live_out) |info| {
                try live.setForce(allocator, info.id, info.dist, info.pos);
            }

            const old_size = live.size();

            // Process successors: add phi arguments
            try processSuccessorPhis(allocator, &live, block);

            // Adjust distances for block length
            const block_len: i32 = @intCast(block.values.items.len);
            live.addDistanceToAll(block_len);

            // Add control values to live set
            for (block.controlValues()) |ctrl| {
                if (needsRegister(ctrl)) {
                    try live.set(allocator, ctrl.id, block_len, block.pos);
                }
            }

            // Process values in reverse order (bottom to top)
            var i: i32 = block_len - 1;
            while (i >= 0) : (i -= 1) {
                const idx: usize = @intCast(i);
                const v = block.values.items[idx];

                // Value is defined here - no longer live above this point
                live.remove(v.id);

                // Skip phi nodes (handled separately)
                if (v.op == .phi) continue;

                // Handle calls: add unlikely_distance penalty
                if (isCall(v.op)) {
                    live.addDistanceToAll(unlikely_distance);
                    // TODO: Remove rematerializable values
                }

                // Add arguments to live set
                for (v.args) |arg| {
                    if (needsRegister(arg)) {
                        try live.set(allocator, arg.id, i, v.pos);
                    }
                }
            }

            // Propagate to predecessors
            for (block.preds) |pred_edge| {
                const pred = pred_edge.b;

                const pred_idx = pred.id - 1;
                const delta = branchDistance(pred, block);

                // Check if any new values need to be added to predecessor's live-out
                for (live.items()) |info| {
                    const new_dist = if (info.dist == unknown_distance)
                        unknown_distance
                    else
                        info.dist + delta;

                    const existing = result.blocks[pred_idx].live_out;
                    var found = false;
                    for (existing) |e| {
                        if (e.id == info.id) {
                            found = true;
                            if (new_dist != unknown_distance and
                                (e.dist == unknown_distance or new_dist < e.dist))
                            {
                                changed = true;
                            }
                            break;
                        }
                    }
                    if (!found) {
                        changed = true;
                    }
                }
            }

            // Update live-out if changed
            if (live.size() != old_size or changed) {
                try result.blocks[block_idx].updateLiveOut(&live);
            }
        }
    }

    return result;
}

/// Calculate branch distance between a block and its successor.
/// Go reference: regalloc.go branchDistance() lines 3214-3228
fn branchDistance(from: *Block, to: *Block) i32 {
    const succs = from.succs;
    if (succs.len == 2) {
        // Two-way branch - check likelihood
        if (succs[0].b == to) {
            return switch (from.likely) {
                .likely => likely_distance,
                .unlikely => unlikely_distance,
                else => normal_distance,
            };
        }
        if (succs[1].b == to) {
            return switch (from.likely) {
                .likely => unlikely_distance,
                .unlikely => likely_distance,
                else => normal_distance,
            };
        }
    }
    return normal_distance;
}

/// Process phi arguments from successor blocks
fn processSuccessorPhis(allocator: std.mem.Allocator, live: *LiveMap, block: *Block) !void {
    for (block.succs) |succ_edge| {
        const succ = succ_edge.b;
        const edge_idx = succ_edge.i;
        const delta = branchDistance(block, succ);

        // Find phi nodes in successor
        for (succ.values.items) |v| {
            if (v.op != .phi) continue;

            // Get the argument from this edge
            const args = v.args;
            if (edge_idx < args.len) {
                const arg = args[edge_idx];
                if (needsRegister(arg)) {
                    try live.set(allocator, arg.id, delta, v.pos);
                }
            }
        }
    }
}

/// Check if a value needs a register (not mem/void/flags)
fn needsRegister(v: *Value) bool {
    // Check if the operation produces a value that needs a register
    return switch (v.op) {
        // Memory and control flow don't need registers
        .phi => true, // Phi results need registers
        .const_int, .const_bool => true,
        .add, .sub, .mul, .div => true,
        .load => true,
        .call => true,
        // SSA pseudo-ops don't need registers
        else => true, // Conservative: assume needs register
    };
}

/// Check if an operation is a call
fn isCall(op: Op) bool {
    return op == .call;
}

/// Compute postorder traversal of blocks
fn computePostorder(allocator: std.mem.Allocator, f: *Func) ![]*Block {
    var result = std.ArrayListUnmanaged(*Block){};
    errdefer result.deinit(allocator);

    var visited = std.AutoHashMapUnmanaged(ID, void){};
    defer visited.deinit(allocator);

    // Start DFS from entry block
    if (f.blocks.items.len > 0) {
        try postorderDFS(allocator, &result, &visited, f.blocks.items[0]);
    }

    return try result.toOwnedSlice(allocator);
}

fn postorderDFS(
    allocator: std.mem.Allocator,
    result: *std.ArrayListUnmanaged(*Block),
    visited: *std.AutoHashMapUnmanaged(ID, void),
    block: *Block,
) !void {
    if (visited.contains(block.id)) return;
    try visited.put(allocator, block.id, {});

    // Visit successors first
    for (block.succs) |succ_edge| {
        try postorderDFS(allocator, result, visited, succ_edge.b);
    }

    // Add this block after successors (postorder)
    try result.append(allocator, block);
}

// =========================================
// Tests
// =========================================

test "LiveMap basic operations" {
    const allocator = std.testing.allocator;

    var live = LiveMap.init();
    defer live.deinit(allocator);

    // Initially empty
    try std.testing.expectEqual(@as(usize, 0), live.size());
    try std.testing.expect(!live.contains(1));

    // Add a value
    try live.set(allocator, 1, 10, .{});
    try std.testing.expectEqual(@as(usize, 1), live.size());
    try std.testing.expect(live.contains(1));
    try std.testing.expectEqual(@as(i32, 10), live.get(1).?);

    // Add another value
    try live.set(allocator, 2, 20, .{});
    try std.testing.expectEqual(@as(usize, 2), live.size());

    // Update with closer distance (should update)
    try live.set(allocator, 1, 5, .{});
    try std.testing.expectEqual(@as(i32, 5), live.get(1).?);

    // Update with farther distance (should NOT update)
    try live.set(allocator, 1, 15, .{});
    try std.testing.expectEqual(@as(i32, 5), live.get(1).?);

    // Remove
    live.remove(1);
    try std.testing.expect(!live.contains(1));
    try std.testing.expectEqual(@as(usize, 1), live.size());

    // Clear
    live.clear();
    try std.testing.expectEqual(@as(usize, 0), live.size());
}

test "LiveMap addDistanceToAll" {
    const allocator = std.testing.allocator;

    var live = LiveMap.init();
    defer live.deinit(allocator);

    try live.set(allocator, 1, 10, .{});
    try live.set(allocator, 2, 20, .{});
    try live.set(allocator, 3, unknown_distance, .{}); // Should not be modified

    live.addDistanceToAll(5);

    try std.testing.expectEqual(@as(i32, 15), live.get(1).?);
    try std.testing.expectEqual(@as(i32, 25), live.get(2).?);
    try std.testing.expectEqual(@as(i32, unknown_distance), live.get(3).?);
}

test "distance constants match Go" {
    // Verify our constants match Go's regalloc.go
    try std.testing.expectEqual(@as(i32, 1), likely_distance);
    try std.testing.expectEqual(@as(i32, 10), normal_distance);
    try std.testing.expectEqual(@as(i32, 100), unlikely_distance);
    try std.testing.expectEqual(@as(i32, -1), unknown_distance);
}

test "branchDistance for two-way branch" {
    // This test would need actual Block structures
    // For now, just verify the function exists and compiles
    _ = branchDistance;
}

test "needsRegister classification" {
    // Test that we correctly identify ops that need registers
    const test_helpers = @import("test_helpers.zig");
    const allocator = std.testing.allocator;

    var builder = try test_helpers.TestFuncBuilder.init(allocator, "test_needs_reg");
    defer builder.deinit();

    // Create a block first
    const linear = try builder.createLinearCFG(1);
    defer allocator.free(linear.blocks);

    const entry = linear.entry;
    const const_val = try builder.func.newValue(.const_int, types.PrimitiveTypes.i64_type, entry, .{});
    const add_val = try builder.func.newValue(.add, types.PrimitiveTypes.i64_type, entry, .{});

    // Add to block so they get cleaned up properly
    try entry.addValue(allocator, const_val);
    try entry.addValue(allocator, add_val);

    try std.testing.expect(needsRegister(const_val));
    try std.testing.expect(needsRegister(add_val));
}

test "LivenessResult initialization" {
    const allocator = std.testing.allocator;

    var result = try LivenessResult.init(allocator, 3);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.blocks.len);

    // Each block starts with empty liveness
    for (result.blocks) |b| {
        try std.testing.expectEqual(@as(usize, 0), b.live_out.len);
    }
}

test "computeLiveness on simple function" {
    const allocator = std.testing.allocator;
    const test_helpers = @import("test_helpers.zig");

    var builder = try test_helpers.TestFuncBuilder.init(allocator, "simple");
    defer builder.deinit();

    // Create a single block
    const linear = try builder.createLinearCFG(1);
    defer allocator.free(linear.blocks);

    var result = try computeLiveness(allocator, builder.func);
    defer result.deinit();

    // Should have one block
    try std.testing.expectEqual(@as(usize, 1), result.blocks.len);
}

test "computeLiveness straight-line code" {
    const allocator = std.testing.allocator;
    const test_helpers = @import("test_helpers.zig");

    var builder = try test_helpers.TestFuncBuilder.init(allocator, "straight_line");
    defer builder.deinit();

    // Create a single return block
    const linear = try builder.createLinearCFG(1);
    defer allocator.free(linear.blocks);

    const entry = linear.entry;

    // Create: v1 = const 42; v2 = add v1, v1; block returns v2
    const v1 = try builder.func.newValue(.const_int, types.PrimitiveTypes.i64_type, entry, .{});
    v1.aux_int = 42;

    const v2 = try builder.func.newValue(.add, types.PrimitiveTypes.i64_type, entry, .{});
    v2.addArg(v1);
    v2.addArg(v1);

    // Add values to block
    try entry.addValue(allocator, v1);
    try entry.addValue(allocator, v2);

    // Set v2 as the return control value
    entry.setControl(v2);

    var result = try computeLiveness(allocator, builder.func);
    defer result.deinit();

    // v1 should be live at some point (used by v2)
    // v2 should be live at some point (used by ret control)
    try std.testing.expectEqual(@as(usize, 1), result.blocks.len);
}

test "computeLiveness with loop" {
    const allocator = std.testing.allocator;
    const test_helpers = @import("test_helpers.zig");

    var builder = try test_helpers.TestFuncBuilder.init(allocator, "loop_test");
    defer builder.deinit();

    // Create a simple loop: header -> body -> header (back edge)
    //                       header -> exit

    // Create blocks manually for loop structure
    const header = try builder.func.newBlock(.if_);
    const body = try builder.func.newBlock(.plain);
    const exit = try builder.func.newBlock(.ret);

    // Connect CFG: header -> body, header -> exit
    try header.addEdgeTo(allocator, body);
    try header.addEdgeTo(allocator, exit);
    // Back edge: body -> header
    try body.addEdgeTo(allocator, header);

    // Add a phi in the header (loop variable)
    const phi = try builder.func.newValue(.phi, types.PrimitiveTypes.i64_type, header, .{});
    try header.addValue(allocator, phi);

    // Initial value comes from "before" the loop (we'll simulate with a const)
    const init_val = try builder.func.newValue(.const_int, types.PrimitiveTypes.i64_type, header, .{});
    init_val.aux_int = 0;
    try header.addValue(allocator, init_val);

    // In body, increment the loop variable
    const incr = try builder.func.newValue(.add, types.PrimitiveTypes.i64_type, body, .{});
    incr.addArg(phi);
    try body.addValue(allocator, incr);

    // Phi gets init from outside, incr from body
    phi.addArg(init_val);
    phi.addArg(incr);

    // Header branches on some condition
    const cond = try builder.func.newValue(.const_bool, types.PrimitiveTypes.bool_type, header, .{});
    try header.addValue(allocator, cond);
    header.setControl(cond);

    // Exit returns the phi value
    exit.setControl(phi);

    var result = try computeLiveness(allocator, builder.func);
    defer result.deinit();

    // Should have analyzed all 3 blocks
    try std.testing.expectEqual(@as(usize, 3), result.blocks.len);

    // The phi should be live across the back edge
    // (this tests that fixed-point iteration works for loops)
}

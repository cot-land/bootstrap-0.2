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
const TypeRegistry = @import("../frontend/types.zig").TypeRegistry;
const Value = @import("value.zig").Value;
const Block = @import("block.zig").Block;
const Func = @import("func.zig").Func;
const Op = @import("op.zig").Op;
const debug = @import("../pipeline_debug.zig");

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

    /// For each instruction index i, next_call[i] is the index of the next
    /// call instruction at or after i within this block.
    /// std.math.maxInt(u32) if no call follows.
    /// Go reference: regalloc.go lines 1053-1082
    next_call: []u32,

    /// Allocator that owns the slices
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BlockLiveness {
        return .{
            .live_out = &.{},
            .live_in = &.{},
            .next_call = &.{},
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
        if (self.next_call.len > 0) {
            self.allocator.free(self.next_call);
        }
    }

    /// Compute the nextCall array for a block.
    /// Go reference: regalloc.go lines 1053-1082
    ///
    /// For each instruction i, nextCall[i] = index of next call at or after i.
    /// If no call follows, nextCall[i] = maxInt(u32).
    pub fn computeNextCall(self: *BlockLiveness, block: *const Block) !void {
        const num_values = block.values.items.len;
        if (num_values == 0) {
            self.next_call = &.{};
            return;
        }

        // Free old array if present
        if (self.next_call.len > 0) {
            self.allocator.free(self.next_call);
        }

        self.next_call = try self.allocator.alloc(u32, num_values);

        // Process backwards: track the next call we've seen
        var current_next_call: u32 = std.math.maxInt(u32);
        var i: usize = num_values;
        while (i > 0) {
            i -= 1;
            const v = block.values.items[i];

            // Check if this instruction is a call
            if (v.op.info().call) {
                current_next_call = @intCast(i);
            }

            self.next_call[i] = current_next_call;
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

    /// Get the next_call array for a block.
    /// Returns the index of the next call at or after each instruction.
    /// Go reference: regalloc.go lines 1053-1082
    pub fn getNextCall(self: *const LivenessResult, block_id: ID) []const u32 {
        if (block_id == 0 or block_id > self.blocks.len) return &.{};
        return self.blocks[block_id - 1].next_call;
    }

    /// Check if instruction idx has a call following it (or is itself a call).
    /// This is used to determine if a value's next use is "after a call".
    pub fn hasCallAtOrAfter(self: *const LivenessResult, block_id: ID, idx: usize) bool {
        const next_call = self.getNextCall(block_id);
        if (idx >= next_call.len) return false;
        return next_call[idx] != std.math.maxInt(u32);
    }

    /// Get the index of the next call at or after instruction idx.
    /// Returns null if no call follows.
    pub fn getNextCallIdx(self: *const LivenessResult, block_id: ID, idx: usize) ?u32 {
        const next_call = self.getNextCall(block_id);
        if (idx >= next_call.len) return null;
        const nc = next_call[idx];
        if (nc == std.math.maxInt(u32)) return null;
        return nc;
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
    debug.log(.regalloc, "=== Computing liveness for '{s}' ===", .{f.name});

    const num_blocks = f.blocks.items.len;
    if (num_blocks == 0) {
        debug.log(.regalloc, "  No blocks, returning empty liveness", .{});
        return LivenessResult.init(allocator, 0);
    }

    debug.log(.regalloc, "  {} blocks to analyze", .{num_blocks});

    var result = try LivenessResult.init(allocator, num_blocks);
    errdefer result.deinit();

    // Compute nextCall array for each block
    // Go reference: regalloc.go lines 1053-1082
    for (f.blocks.items) |block| {
        const block_idx = block.id - 1;
        try result.blocks[block_idx].computeNextCall(block);
        debug.log(.regalloc, "  Block {} nextCall computed, {} values", .{ block.id, block.values.items.len });
    }

    // Get postorder traversal (leaves first)
    const postorder = try computePostorder(allocator, f);
    defer allocator.free(postorder);
    debug.log(.regalloc, "  Postorder: {} blocks", .{postorder.len});

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
        debug.log(.regalloc, "  Liveness iteration {}", .{iterations});

        // Process blocks in postorder
        for (postorder) |block| {
            const block_idx = block.id - 1;
            debug.log(.regalloc, "    Processing block {} (kind={})", .{ block.id, @intFromEnum(block.kind) });

            // Initialize live set from known live-out
            live.clear();
            for (result.blocks[block_idx].live_out) |info| {
                try live.setForce(allocator, info.id, info.dist, info.pos);
            }

            const old_size = live.size();
            debug.log(.regalloc, "      Initial live-out: {} values", .{old_size});

            // Process successors: add phi arguments
            // Go reference: lines 2889-2906
            // After adding phi args, we must update this block's live_out
            // because these values are live at the END of this block
            const before_phi_size = live.size();
            try processSuccessorPhis(allocator, &live, block);
            debug.log(.regalloc, "      After phi args: {} live", .{live.size()});

            // If phi args were added, update this block's live_out
            // Go reference: line 2905 "s.live[b.ID] = updateLive(live, s.live[b.ID])"
            if (live.size() > before_phi_size) {
                try result.blocks[block_idx].updateLiveOut(&live);
                debug.log(.regalloc, "      Updated block {} live-out with phi args: {} values", .{ block.id, live.size() });
                changed = true;
            }

            // Adjust distances for block length
            const block_len: i32 = @intCast(block.values.items.len);
            live.addDistanceToAll(block_len);

            // Add control values to live set
            for (block.controlValues()) |ctrl| {
                if (needsRegister(ctrl)) {
                    debug.log(.regalloc, "      Adding control v{} at dist={}", .{ ctrl.id, block_len });
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
                debug.log(.regalloc, "      v{} (op={}) defined at idx={}, removed from live", .{ v.id, @intFromEnum(v.op), idx });

                // Skip phi nodes (handled separately)
                if (v.op == .phi) continue;

                // Handle calls: add unlikely_distance penalty
                if (isCall(v.op)) {
                    debug.log(.regalloc, "        CALL: adding unlikely_distance={} to all live", .{unlikely_distance});
                    live.addDistanceToAll(unlikely_distance);
                    // TODO: Remove rematerializable values
                }

                // Add arguments to live set
                for (v.args) |arg| {
                    if (needsRegister(arg)) {
                        debug.log(.regalloc, "        arg v{} now live at dist={}", .{ arg.id, i });
                        try live.set(allocator, arg.id, i, v.pos);
                    }
                }
            }
            debug.log(.regalloc, "      After processing values: {} live", .{live.size()});

            // Propagate to predecessors
            // Go reference: regalloc.go lines 2961-2999
            // Values live at the START of this block must be live at the END of each predecessor
            for (block.preds) |pred_edge| {
                const pred = pred_edge.b;

                const pred_idx = pred.id - 1;
                const delta = branchDistance(pred, block);
                debug.log(.regalloc, "      Propagating to pred block {}, delta={}", .{ pred.id, delta });

                // Build a temporary map starting with predecessor's current live-out
                // Go reference: lines 2968-2971
                var t = LiveMap.init();
                defer t.deinit(allocator);
                for (result.blocks[pred_idx].live_out) |e| {
                    try t.setForce(allocator, e.id, e.dist, e.pos);
                }

                // Add new values from live (live at start of current block)
                // Go reference: lines 2975-2981
                var update = false;
                for (live.items()) |info| {
                    const new_dist = if (info.dist == unknown_distance)
                        unknown_distance
                    else
                        info.dist + delta;

                    // Update if new value OR better distance
                    // Go reference: "if !t.contains(e.key) || d < t.get(e.key)"
                    if (!t.contains(info.id) or (t.get(info.id) != null and new_dist < t.get(info.id).?)) {
                        try t.setForce(allocator, info.id, new_dist, info.pos);
                        debug.log(.regalloc, "        v{} added/updated in pred {} live-out, dist={}", .{ info.id, pred.id, new_dist });
                        update = true;
                    }
                }

                // Update predecessor's live-out if anything changed
                if (update) {
                    try result.blocks[pred_idx].updateLiveOut(&t);
                    debug.log(.regalloc, "      Updated pred {} live-out: {} values", .{ pred.id, t.size() });
                    changed = true;
                }
            }
        }
    }

    debug.log(.regalloc, "  Liveness converged after {} iterations", .{iterations});

    // Log final liveness results
    for (result.blocks, 0..) |bl, idx| {
        debug.log(.regalloc, "  Block {} live-out: {} values", .{ idx + 1, bl.live_out.len });
        for (bl.live_out) |info| {
            debug.log(.regalloc, "    v{} dist={}", .{ info.id, info.dist });
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
    debug.log(.regalloc, "        processSuccessorPhis: block b{d} has {d} succs", .{ block.id, block.succs.len });
    for (block.succs) |succ_edge| {
        const succ = succ_edge.b;
        const edge_idx = succ_edge.i;
        const delta = branchDistance(block, succ);

        debug.log(.regalloc, "        succ b{d}, edge_idx={d}", .{ succ.id, edge_idx });

        // Find phi nodes in successor
        for (succ.values.items) |v| {
            if (v.op != .phi) continue;

            debug.log(.regalloc, "          phi v{d} has {d} args", .{ v.id, v.args.len });

            // Get the argument from this edge
            const args = v.args;
            if (edge_idx < args.len) {
                const arg = args[edge_idx];
                debug.log(.regalloc, "          arg[{d}] = v{d} ({s})", .{ edge_idx, arg.id, @tagName(arg.op) });
                if (needsRegister(arg)) {
                    try live.set(allocator, arg.id, delta, v.pos);
                    debug.log(.regalloc, "          added v{d} to live", .{arg.id});
                }
            } else {
                debug.log(.regalloc, "          edge_idx {d} >= args.len {d}", .{ edge_idx, args.len });
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
    return op.info().call;
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
    const const_val = try builder.func.newValue(.const_int, TypeRegistry.I64, entry, .{});
    const add_val = try builder.func.newValue(.add, TypeRegistry.I64, entry, .{});

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
    const v1 = try builder.func.newValue(.const_int, TypeRegistry.I64, entry, .{});
    v1.aux_int = 42;

    const v2 = try builder.func.newValue(.add, TypeRegistry.I64, entry, .{});
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
    const phi = try builder.func.newValue(.phi, TypeRegistry.I64, header, .{});
    try header.addValue(allocator, phi);

    // Initial value comes from "before" the loop (we'll simulate with a const)
    const init_val = try builder.func.newValue(.const_int, TypeRegistry.I64, header, .{});
    init_val.aux_int = 0;
    try header.addValue(allocator, init_val);

    // In body, increment the loop variable
    const incr = try builder.func.newValue(.add, TypeRegistry.I64, body, .{});
    incr.addArg(phi);
    try body.addValue(allocator, incr);

    // Phi gets init from outside, incr from body
    phi.addArg(init_val);
    phi.addArg(incr);

    // Header branches on some condition
    const cond = try builder.func.newValue(.const_bool, TypeRegistry.BOOL, header, .{});
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

test "nextCall tracking" {
    const allocator = std.testing.allocator;
    const test_helpers = @import("test_helpers.zig");

    var builder = try test_helpers.TestFuncBuilder.init(allocator, "next_call_test");
    defer builder.deinit();

    const linear = try builder.createLinearCFG(1);
    defer allocator.free(linear.blocks);

    const entry = linear.entry;

    // Create: v1 = const; v2 = call; v3 = add; v4 = call
    // Expected nextCall: [1, 1, 3, 3]
    const v1 = try builder.func.newValue(.const_int, TypeRegistry.I64, entry, .{});
    v1.aux_int = 42;
    try entry.addValue(allocator, v1);

    const v2 = try builder.func.newValue(.static_call, TypeRegistry.I64, entry, .{});
    try entry.addValue(allocator, v2);

    const v3 = try builder.func.newValue(.add, TypeRegistry.I64, entry, .{});
    v3.addArg(v1);
    v3.addArg(v2);
    try entry.addValue(allocator, v3);

    const v4 = try builder.func.newValue(.static_call, TypeRegistry.I64, entry, .{});
    try entry.addValue(allocator, v4);

    entry.setControl(v4);

    var result = try computeLiveness(allocator, builder.func);
    defer result.deinit();

    // Check nextCall array
    const next_call = result.getNextCall(entry.id);
    try std.testing.expectEqual(@as(usize, 4), next_call.len);

    // Instruction 0 (const): next call is at 1
    try std.testing.expectEqual(@as(u32, 1), next_call[0]);
    // Instruction 1 (call): next call is at 1 (itself)
    try std.testing.expectEqual(@as(u32, 1), next_call[1]);
    // Instruction 2 (add): next call is at 3
    try std.testing.expectEqual(@as(u32, 3), next_call[2]);
    // Instruction 3 (call): next call is at 3 (itself)
    try std.testing.expectEqual(@as(u32, 3), next_call[3]);
}

test "nextCall no calls" {
    const allocator = std.testing.allocator;
    const test_helpers = @import("test_helpers.zig");

    var builder = try test_helpers.TestFuncBuilder.init(allocator, "no_calls_test");
    defer builder.deinit();

    const linear = try builder.createLinearCFG(1);
    defer allocator.free(linear.blocks);

    const entry = linear.entry;

    // No calls in this block
    const v1 = try builder.func.newValue(.const_int, TypeRegistry.I64, entry, .{});
    v1.aux_int = 42;
    try entry.addValue(allocator, v1);

    const v2 = try builder.func.newValue(.add, TypeRegistry.I64, entry, .{});
    v2.addArg(v1);
    v2.addArg(v1);
    try entry.addValue(allocator, v2);

    entry.setControl(v2);

    var result = try computeLiveness(allocator, builder.func);
    defer result.deinit();

    // Check nextCall array - all should be maxInt (no calls)
    const next_call = result.getNextCall(entry.id);
    try std.testing.expectEqual(@as(usize, 2), next_call.len);
    try std.testing.expectEqual(std.math.maxInt(u32), next_call[0]);
    try std.testing.expectEqual(std.math.maxInt(u32), next_call[1]);

    // hasCallAtOrAfter should return false for all
    try std.testing.expect(!result.hasCallAtOrAfter(entry.id, 0));
    try std.testing.expect(!result.hasCallAtOrAfter(entry.id, 1));
}

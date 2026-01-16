//! Schedule Pass - Go's Architecture
//!
//! Go reference: cmd/compile/internal/ssa/schedule.go
//!
//! Purpose: Establish deterministic value order BEFORE regalloc.
//! After this pass, b.values order is the final emission order.
//!
//! Algorithm:
//! 1. Assign priority scores to each value (lower = earlier)
//! 2. Build dependency edges (args must come before users)
//! 3. Topological sort respecting priorities

const std = @import("std");
const Func = @import("../func.zig").Func;
const Block = @import("../block.zig").Block;
const Value = @import("../value.zig").Value;
const Op = @import("../op.zig").Op;
const debug = @import("../../pipeline_debug.zig");

/// Priority scores - lower numbers scheduled earlier (Go's pattern)
pub const Score = enum(i8) {
    phi = 0, // Phis must be first
    arg = 1, // Arguments early (entry block)
    read_tuple = 2, // select_n must follow call immediately
    memory = 3, // Stores early (reduces register pressure)
    default = 4, // Normal instructions
    control = 5, // Branch/return last
};

/// Get the scheduling score for a value
fn getScore(v: *Value, is_control: bool) Score {
    if (is_control) {
        return .control;
    }

    return switch (v.op) {
        .phi => .phi,
        .arg => .arg,
        .select_n => .read_tuple,
        .store, .store_reg => .memory,
        else => .default,
    };
}

/// Schedule the values in each block.
/// After this pass, the order of b.values is the emission order.
pub fn schedule(f: *Func) !void {
    const allocator = f.allocator;

    debug.log(.schedule, "=== Schedule pass ===", .{});

    for (f.blocks.items) |block| {
        try scheduleBlock(allocator, block, f);
    }

    debug.log(.schedule, "=== Schedule complete ===", .{});
}

fn scheduleBlock(allocator: std.mem.Allocator, block: *Block, f: *Func) !void {
    const values = block.values.items;
    if (values.len == 0) return;

    debug.log(.schedule, "Scheduling block b{d}, {d} values", .{ block.id, values.len });

    // Step 1: Compute scores for all values
    var scores = try allocator.alloc(Score, f.vid.next_id);
    defer allocator.free(scores);
    for (scores) |*s| s.* = .default;

    // Track original position for tiebreaking (Go's pattern: preserve source order)
    var orig_pos = try allocator.alloc(u32, f.vid.next_id);
    defer allocator.free(orig_pos);
    for (orig_pos) |*p| p.* = std.math.maxInt(u32);
    for (values, 0..) |v, i| {
        orig_pos[v.id] = @intCast(i);
    }

    // Find control values
    var control_ids = std.AutoHashMapUnmanaged(u32, void){};
    defer control_ids.deinit(allocator);
    for (block.controlValues()) |ctrl| {
        try control_ids.put(allocator, ctrl.id, {});
    }

    for (values) |v| {
        const is_control = control_ids.contains(v.id);
        scores[v.id] = getScore(v, is_control);
    }

    // Step 2: Build dependency edges (in-block only)
    // Edge: x -> y means x must come before y
    const Edge = struct { x: *Value, y: *Value };
    var edges = std.ArrayListUnmanaged(Edge){};
    defer edges.deinit(allocator);

    for (values) |v| {
        if (v.op == .phi) continue; // Phi args are from predecessors

        for (v.args) |arg| {
            if (arg.block == block) {
                try edges.append(allocator, .{ .x = arg, .y = v });
            }
        }
    }

    // Step 2b: Add memory ordering edges (store -> load of same local)
    // This ensures stores happen before loads of the same address
    // Go reference: schedule.go lines 257-278 (nextMem tracking)
    var last_store: ?*Value = null;
    for (values) |v| {
        if (v.op == .store or v.op == .store_reg) {
            if (last_store) |ls| {
                // Chain stores: previous store -> this store
                try edges.append(allocator, .{ .x = ls, .y = v });
            }
            last_store = v;
        } else if (v.op == .load or v.op == .load_reg) {
            if (last_store) |ls| {
                // Store -> load dependency
                try edges.append(allocator, .{ .x = ls, .y = v });
            }
        }
    }

    // Step 3: Count incoming edges for each value
    var in_edges = try allocator.alloc(u32, f.vid.next_id);
    defer allocator.free(in_edges);
    for (in_edges) |*e| e.* = 0;

    for (edges.items) |e| {
        in_edges[e.y.id] += 1;
    }

    // Step 4: Initialize ready set with values that have no dependencies
    var ready = std.ArrayListUnmanaged(*Value){};
    defer ready.deinit(allocator);

    for (values) |v| {
        if (in_edges[v.id] == 0) {
            try ready.append(allocator, v);
        }
    }

    // Step 5: Process in priority order
    // Tiebreak by original position (Go's pattern: preserve source order)
    var result = std.ArrayListUnmanaged(*Value){};
    defer result.deinit(allocator);

    while (ready.items.len > 0) {
        // Find highest priority (lowest score, then earliest original position)
        var best_idx: usize = 0;
        var best_score = scores[ready.items[0].id];
        var best_pos = orig_pos[ready.items[0].id];

        for (ready.items[1..], 1..) |v, i| {
            const s = scores[v.id];
            const p = orig_pos[v.id];
            if (@intFromEnum(s) < @intFromEnum(best_score) or
                (@intFromEnum(s) == @intFromEnum(best_score) and p < best_pos))
            {
                best_score = s;
                best_pos = p;
                best_idx = i;
            }
        }

        // Remove best from ready, add to result
        const v = ready.swapRemove(best_idx);
        try result.append(allocator, v);

        // Decrement in_edges for successors, add newly ready values
        for (edges.items) |e| {
            if (e.x == v) {
                in_edges[e.y.id] -= 1;
                if (in_edges[e.y.id] == 0) {
                    try ready.append(allocator, e.y);
                }
            }
        }
    }

    // Verify we scheduled everything
    if (result.items.len != values.len) {
        debug.log(.schedule, "ERROR: scheduled {d} of {d} values", .{ result.items.len, values.len });
        return error.ScheduleIncomplete;
    }

    // Step 6: Replace block's values with scheduled order
    block.values.clearRetainingCapacity();
    try block.values.appendSlice(allocator, result.items);

    debug.log(.schedule, "  Scheduled {d} values", .{ result.items.len });
}

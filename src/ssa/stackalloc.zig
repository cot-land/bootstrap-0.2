//! Stack Allocation Pass
//!
//! Go reference: cmd/compile/internal/ssa/stackalloc.go
//!
//! This pass assigns stack slots to spilled values. Values that don't have
//! a register assignment (from regalloc) need stack storage.
//!
//! ## Algorithm (from Go)
//!
//! 1. Mark which values need stack slots (no register home, not rematerializeable)
//! 2. Compute liveness: for each value needing a slot, find all blocks where it's live
//! 3. Build interference graph: values interfere if one is defined while other is live
//! 4. Allocate slots: reuse slots that don't interfere, allocate new ones as needed
//!
//! ## Frame Layout (ARM64)
//!
//! ```
//! High addresses
//! +------------------+
//! | Caller's frame   |
//! +------------------+
//! | Return address   |  <- SP at function entry
//! | Saved FP (x29)   |
//! +------------------+  <- New FP (x29) points here
//! | Local 0          |  offset = 16
//! | Local 1          |  offset = 16 + sizeof(local0)
//! | ...              |
//! | Spill slot 0     |  offset = 16 + locals_size
//! | Spill slot 1     |  offset = 16 + locals_size + 8
//! | ...              |
//! +------------------+
//! Low addresses
//! ```

const std = @import("std");
const Func = @import("func.zig").Func;
const Value = @import("value.zig").Value;
const Block = @import("block.zig").Block;
const Op = @import("op.zig").Op;
const debug = @import("../pipeline_debug.zig");
const ID = @import("../core/types.zig").ID;

/// Frame header size: saved FP (x29) + LR (x30) = 16 bytes
pub const FRAME_HEADER_SIZE: i32 = 16;

/// Size of each spill slot (8 bytes for 64-bit values)
pub const SPILL_SLOT_SIZE: i32 = 8;

/// Result of stack allocation
pub const StackAllocResult = struct {
    frame_size: u32,
    num_spill_slots: u32,
    locals_size: u32,
    num_reused: u32,
};

/// Per-value state for stack allocation
/// Go reference: stackalloc.go stackValState
const StackValState = struct {
    type_idx: u32 = 0,
    needs_slot: bool = false,
    def_block: ID = 0,
    // Blocks where this value is used (for liveness propagation)
    use_blocks: std.ArrayListUnmanaged(UseBlock) = .{},

    const UseBlock = struct {
        block_id: ID,
        liveout: bool, // Must be live at end of this block
    };

    fn addUseBlock(self: *StackValState, allocator: std.mem.Allocator, block_id: ID, liveout: bool) !void {
        // Check if already present (simple dedup)
        if (self.use_blocks.items.len > 0) {
            const last = self.use_blocks.items[self.use_blocks.items.len - 1];
            if (last.block_id == block_id and last.liveout == liveout) {
                return;
            }
        }
        try self.use_blocks.append(allocator, .{ .block_id = block_id, .liveout = liveout });
    }

    fn deinit(self: *StackValState, allocator: std.mem.Allocator) void {
        self.use_blocks.deinit(allocator);
    }
};

/// Stack allocator state
/// Go reference: stackalloc.go stackAllocState
pub const StackAllocState = struct {
    allocator: std.mem.Allocator,
    f: *Func,
    values: []StackValState,

    // live[block_id] = list of value IDs live at end of that block
    // Go reference: stackalloc.go line 20-21
    live: std.AutoHashMapUnmanaged(ID, std.ArrayListUnmanaged(ID)),

    // interfere[v.id] = list of value IDs that interfere with v
    // Go reference: stackalloc.go line 26
    interfere: std.AutoHashMapUnmanaged(ID, std.ArrayListUnmanaged(ID)),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, f: *Func) !Self {
        const values = try allocator.alloc(StackValState, f.vid.next_id);
        for (values) |*v| v.* = .{};

        return Self{
            .allocator = allocator,
            .f = f,
            .values = values,
            .live = .{},
            .interfere = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        // Free per-value state
        for (self.values) |*v| {
            v.deinit(self.allocator);
        }
        self.allocator.free(self.values);

        // Free live lists
        var live_it = self.live.valueIterator();
        while (live_it.next()) |list| {
            list.deinit(self.allocator);
        }
        self.live.deinit(self.allocator);

        // Free interference lists
        var int_it = self.interfere.valueIterator();
        while (int_it.next()) |list| {
            list.deinit(self.allocator);
        }
        self.interfere.deinit(self.allocator);
    }

    /// Initialize value state and mark which values need slots
    /// Go reference: stackalloc.go init() lines 113-135
    fn initValues(self: *Self) void {
        const f = self.f;

        for (f.blocks.items) |block| {
            for (block.values.items) |v| {
                self.values[v.id].type_idx = v.type_idx;
                self.values[v.id].def_block = block.id;

                // A value needs a slot if:
                // - It's a store_reg (spill instruction) that is actually loaded (uses > 0)
                // - Go also checks: no register home, not rematerializeable, etc.
                // For us, store_reg is the key indicator that a value needs stack storage
                // CRITICAL: Only allocate slots for store_reg that will be loaded.
                // Dead store_reg (uses=0) don't need slots and would cause incorrect
                // slot reuse if included (BUG-023 fix).
                if (v.op == .store_reg and v.uses > 0) {
                    self.values[v.id].needs_slot = true;
                }
            }
        }
    }

    /// Compute liveness for values needing slots
    /// Go reference: stackalloc.go computeLive() lines 318-408
    /// @param spill_live: spillLive[block_id] from regalloc - which spills are live at block ends
    fn computeLive(self: *Self, spill_live: *const std.AutoHashMapUnmanaged(ID, std.ArrayListUnmanaged(ID))) !void {
        const f = self.f;

        // CRITICAL: First, seed from spillLive (values live at block ends but not in registers)
        // Go reference: lines 326-330
        // This is the key insight from Go - spillLive tells us which spilled values
        // must survive across block boundaries, enabling proper interference detection.
        var spill_it = spill_live.iterator();
        while (spill_it.next()) |entry| {
            const block_id = entry.key_ptr.*;
            const spill_ids = entry.value_ptr.*;
            for (spill_ids.items) |spill_vid| {
                if (spill_vid >= self.values.len) continue;
                const val = &self.values[spill_vid];
                // Mark as liveout at this block - this is crucial!
                // It means the value must persist beyond this block's end.
                debug.log(.regalloc, "  spillLive seed: v{d} liveout at b{d}", .{ spill_vid, block_id });
                try val.addUseBlock(self.allocator, block_id, true);
            }
        }

        // Phase 1: Record where each value is used
        // Go reference: lines 331-350
        for (f.blocks.items) |block| {
            for (block.values.items) |v| {
                // For each arg of this value
                for (v.args) |arg| {
                    if (!self.values[arg.id].needs_slot) continue;

                    // The arg is used in this block
                    // For phi nodes, args come from predecessors (we don't have phis yet, so skip that)
                    try self.values[arg.id].addUseBlock(self.allocator, block.id, false);
                }
            }
        }

        // Phase 2: Backward propagation from uses to definitions
        // Go reference: lines 377-401
        // For each value that needs a slot, propagate liveness backward
        // from use blocks to definition block
        for (self.values, 0..) |*val, vid| {
            if (!val.needs_slot) continue;

            // BFS backward from use blocks to def block
            var seen = std.AutoHashMapUnmanaged(ID, void){};
            defer seen.deinit(self.allocator);

            var worklist = std.ArrayListUnmanaged(ID){};
            defer worklist.deinit(self.allocator);

            // Start with use blocks
            for (val.use_blocks.items) |ub| {
                if (ub.liveout) {
                    // Value must be live at end of this block
                    try self.pushLive(ub.block_id, @intCast(vid));
                }
                try worklist.append(self.allocator, ub.block_id);
            }

            // Propagate backward through predecessors
            while (worklist.pop()) |work_id| {
                // Stop if we've seen this block or reached the definition block
                if (seen.contains(work_id) or work_id == val.def_block) continue;
                try seen.put(self.allocator, work_id, {});

                // Find the block and process its predecessors
                for (f.blocks.items) |block| {
                    if (block.id == work_id) {
                        for (block.preds) |pred| {
                            // Value is live at end of predecessor
                            try self.pushLive(pred.b.id, @intCast(vid));
                            try worklist.append(self.allocator, pred.b.id);
                        }
                        break;
                    }
                }
            }
        }
    }

    /// Add a value to the live-out set of a block
    fn pushLive(self: *Self, block_id: ID, vid: ID) !void {
        var list = self.live.get(block_id) orelse std.ArrayListUnmanaged(ID){};
        // Simple dedup: check if already present at end
        if (list.items.len > 0 and list.items[list.items.len - 1] == vid) {
            return;
        }
        try list.append(self.allocator, vid);
        try self.live.put(self.allocator, block_id, list);
    }

    /// Build interference graph
    /// Go reference: stackalloc.go buildInterferenceGraph() lines 424-480
    fn buildInterference(self: *Self) !void {
        const f = self.f;

        for (f.blocks.items) |block| {
            // Start with values live at end of block
            // Go reference: line 437 "live.addAll(s.live[b.ID])"
            var live = std.AutoHashMapUnmanaged(ID, void){};
            defer live.deinit(self.allocator);

            if (self.live.get(block.id)) |live_list| {
                for (live_list.items) |vid| {
                    try live.put(self.allocator, vid, {});
                }
            }

            // Process values in reverse order
            // Go reference: lines 438-467
            var i: usize = block.values.items.len;
            while (i > 0) {
                i -= 1;
                const v = block.values.items[i];

                if (self.values[v.id].needs_slot) {
                    // Value is defined here - remove from live
                    _ = live.remove(v.id);

                    // All currently live values interfere with v
                    // Go reference: lines 442-449
                    var live_it = live.keyIterator();
                    while (live_it.next()) |live_id| {
                        // Go checks type equality, but we'll be conservative and interfere all
                        try self.addInterference(v.id, live_id.*);
                    }
                }

                // Add args to live set
                for (v.args) |arg| {
                    if (self.values[arg.id].needs_slot) {
                        try live.put(self.allocator, arg.id, {});
                    }
                }
            }
        }

        debug.log(.regalloc, "  Built interference graph", .{});
    }

    fn addInterference(self: *Self, a: ID, b: ID) !void {
        debug.log(.regalloc, "    interference: v{d} <-> v{d}", .{ a, b });

        // Add a interferes with b
        var list_a = self.interfere.get(a) orelse std.ArrayListUnmanaged(ID){};
        // Check if already present
        for (list_a.items) |id| {
            if (id == b) {
                try self.interfere.put(self.allocator, a, list_a);
                return;
            }
        }
        try list_a.append(self.allocator, b);
        try self.interfere.put(self.allocator, a, list_a);

        // Add b interferes with a
        var list_b = self.interfere.get(b) orelse std.ArrayListUnmanaged(ID){};
        for (list_b.items) |id| {
            if (id == a) {
                try self.interfere.put(self.allocator, b, list_b);
                return;
            }
        }
        try list_b.append(self.allocator, a);
        try self.interfere.put(self.allocator, b, list_b);
    }
};

/// Assign stack offsets to all local variables and spill values.
/// Go reference: cmd/compile/internal/ssa/stackalloc.go stackalloc()
/// @param spill_live: spillLive[block_id] = list of spill value IDs live at end of that block.
///                    This comes from regalloc and is needed to compute proper cross-block liveness.
pub fn stackalloc(f: *Func, spill_live: *const std.AutoHashMapUnmanaged(ID, std.ArrayListUnmanaged(ID))) !StackAllocResult {
    debug.log(.regalloc, "=== Stack Allocation for '{s}' ===", .{f.name});

    // Initialize state
    var state = try StackAllocState.init(f.allocator, f);
    defer state.deinit();

    // Phase 1: Mark which values need slots
    state.initValues();

    // Phase 2: Compute liveness (using spillLive from regalloc)
    try state.computeLive(spill_live);

    // Phase 3: Build interference graph
    try state.buildInterference();

    // Phase 4: Allocate locals first
    var current_offset: i32 = FRAME_HEADER_SIZE;
    var num_locals: u32 = 0;
    const locals_start = current_offset;

    // Allocate local_offsets if there are locals
    if (f.local_sizes.len > 0) {
        f.local_offsets = try f.allocator.alloc(i32, f.local_sizes.len);
    }

    for (f.local_sizes, 0..) |size, idx| {
        // Align to 8 bytes
        current_offset = (current_offset + 7) & ~@as(i32, 7);
        f.local_offsets[idx] = current_offset;
        debug.log(.regalloc, "  local {d} (size {d}) -> [sp+{d}]", .{ idx, size, current_offset });
        current_offset += @intCast(size);
        num_locals += 1;
    }

    const locals_size: u32 = @intCast(current_offset - locals_start);

    // Phase 5: Allocate spill slots with reuse
    // Go reference: stackalloc.go lines 239-315
    const Slot = struct {
        offset: i32,
        type_idx: u32,
    };
    var slots = std.ArrayListUnmanaged(Slot){};
    defer slots.deinit(f.allocator);

    // Track which slot each value uses: slots_used[vid] = slot index or -1
    var slots_used = try f.allocator.alloc(i32, f.vid.next_id);
    defer f.allocator.free(slots_used);
    for (slots_used) |*s| s.* = -1;

    // Track which slots are used by interfering values
    var used = std.ArrayListUnmanaged(bool){};
    defer used.deinit(f.allocator);

    var num_spill_slots: u32 = 0;
    var num_reused: u32 = 0;

    for (f.blocks.items) |block| {
        for (block.values.items) |v| {
            if (!state.values[v.id].needs_slot) continue;

            // Get slots of same type
            const type_idx = v.type_idx;

            // Mark all slots used by interfering values
            // Go reference: lines 284-292
            used.clearRetainingCapacity();
            try used.resize(f.allocator, slots.items.len);
            for (used.items) |*u| u.* = false;

            if (state.interfere.get(v.id)) |interfering| {
                for (interfering.items) |xid| {
                    const slot_idx = slots_used[xid];
                    if (slot_idx >= 0) {
                        used.items[@intCast(slot_idx)] = true;
                    }
                }
            }

            // Find an unused slot of matching type
            // Go reference: lines 293-300
            // CONSERVATIVE FIX: Never reuse slots for store_reg values.
            // The proper fix would be computing spillLive in regalloc and
            // using it here for interference, but for now we disable reuse
            // to avoid the slot corruption bug (BUG-023).
            var found_slot: ?usize = null;
            if (v.op != .store_reg) {
                for (slots.items, 0..) |slot, i| {
                    if (slot.type_idx == type_idx and !used.items[i]) {
                        found_slot = i;
                        num_reused += 1;
                        break;
                    }
                }
            }

            // If no slot found, allocate a new one
            // Go reference: lines 301-306
            if (found_slot == null) {
                current_offset = (current_offset + 7) & ~@as(i32, 7);
                try slots.append(f.allocator, .{
                    .offset = current_offset,
                    .type_idx = type_idx,
                });
                found_slot = slots.items.len - 1;
                current_offset += SPILL_SLOT_SIZE;
                num_spill_slots += 1;
            }

            const slot = slots.items[found_slot.?];
            try f.setHome(v, .{ .stack = slot.offset });
            slots_used[v.id] = @intCast(found_slot.?);

            if (found_slot.? == slots.items.len - 1) {
                debug.log(.regalloc, "  store_reg v{d} -> [sp+{d}] (new)", .{ v.id, slot.offset });
            } else {
                debug.log(.regalloc, "  store_reg v{d} -> [sp+{d}] (reused)", .{ v.id, slot.offset });
            }
        }
    }

    // Calculate total frame size (16-byte aligned)
    const total_frame: u32 = @intCast(current_offset);
    const aligned_frame = (total_frame + 15) & ~@as(u32, 15);

    debug.log(.regalloc, "  Stack: {d} locals ({d} bytes), {d} slots ({d} reused), frame {d} bytes", .{ num_locals, locals_size, num_spill_slots, num_reused, aligned_frame });

    return .{
        .frame_size = aligned_frame,
        .num_spill_slots = num_spill_slots,
        .locals_size = locals_size,
        .num_reused = num_reused,
    };
}

// =========================================
// Tests
// =========================================

test "stackalloc empty function" {
    const allocator = std.testing.allocator;

    var f = Func.init(allocator, "test_empty");
    defer f.deinit();

    // Empty spillLive for test
    var spill_live = std.AutoHashMapUnmanaged(ID, std.ArrayListUnmanaged(ID)){};
    defer spill_live.deinit(allocator);

    const result = try stackalloc(&f, &spill_live);

    try std.testing.expectEqual(@as(u32, 16), result.frame_size);
    try std.testing.expectEqual(@as(u32, 0), result.num_spill_slots);
    try std.testing.expectEqual(@as(u32, 0), result.num_reused);
}

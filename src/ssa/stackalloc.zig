//! Stack Allocation Pass
//!
//! Go reference: cmd/compile/internal/ssa/stackalloc.go
//!
//! This pass runs after register allocation and assigns actual stack
//! offsets to spilled values (StoreReg operations) and local variables.
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
//!
//! Locals are allocated based on their sizes (from SSA Func.local_sizes).
//! Spill slots are 8 bytes each (one 64-bit value).
//!
//! ## Slot Reuse (Go's pattern)
//!
//! Go builds an interference graph to track which values can share slots.
//! Two values interfere if one is live when the other is defined.
//! Non-interfering values of the same type can reuse the same slot.

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
    /// Total frame size (header + locals + spill slots), 16-byte aligned
    frame_size: u32,
    /// Number of spill slots allocated
    num_spill_slots: u32,
    /// Total space used by locals
    locals_size: u32,
    /// Number of slots reused (optimization metric)
    num_reused: u32,
};

/// Per-value state for stack allocation
/// Go reference: stackalloc.go stackValState
const StackValState = struct {
    needs_slot: bool = false, // Does this value need a stack slot?
    slot_idx: ?u32 = null, // Index of assigned slot (if any)
    type_idx: u32 = 0, // Type index for slot reuse matching
};

/// Stack allocator state
/// Go reference: stackalloc.go stackAllocState
pub const StackAllocState = struct {
    allocator: std.mem.Allocator,
    f: *Func,
    values: []StackValState,

    // Interference graph: interfere[v.id] = list of value IDs that interfere with v
    // Go reference: stackalloc.go buildInterferenceGraph()
    interfere: std.AutoHashMapUnmanaged(ID, std.ArrayListUnmanaged(ID)),

    // Live values at end of each block
    live_out: std.AutoHashMapUnmanaged(ID, std.ArrayListUnmanaged(ID)),

    // Statistics
    num_reused: u32 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, f: *Func) !Self {
        const values = try allocator.alloc(StackValState, f.vid.next_id);
        for (values) |*v| v.* = .{};

        return Self{
            .allocator = allocator,
            .f = f,
            .values = values,
            .interfere = .{},
            .live_out = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        // Free interference lists
        var it = self.interfere.valueIterator();
        while (it.next()) |list| {
            list.deinit(self.allocator);
        }
        self.interfere.deinit(self.allocator);

        // Free live_out lists
        var it2 = self.live_out.valueIterator();
        while (it2.next()) |list| {
            list.deinit(self.allocator);
        }
        self.live_out.deinit(self.allocator);

        self.allocator.free(self.values);
    }

    /// Compute liveness and build interference graph
    /// Go reference: stackalloc.go computeLive() + buildInterferenceGraph()
    fn buildInterference(self: *Self) !void {
        const f = self.f;

        // Mark which values need slots (StoreReg and their sources)
        for (f.blocks.items) |block| {
            for (block.values.items) |v| {
                if (v.op == .store_reg) {
                    self.values[v.id].needs_slot = true;
                    self.values[v.id].type_idx = v.type_idx;
                    // Also mark the source value
                    if (v.args.len > 0) {
                        const src = v.args[0];
                        self.values[src.id].needs_slot = true;
                        self.values[src.id].type_idx = src.type_idx;
                    }
                }
            }
        }

        // CRITICAL: All store_reg values in the same block that are saved
        // before a call must interfere with each other - they're all needed
        // after the call returns and can't share stack slots.
        for (f.blocks.items) |block| {
            // Collect all store_reg values in this block
            var store_regs = std.ArrayListUnmanaged(ID){};
            defer store_regs.deinit(self.allocator);

            for (block.values.items) |v| {
                if (v.op == .store_reg) {
                    try store_regs.append(self.allocator, v.id);
                } else if (v.op.isCall() or v.op == .string_concat) {
                    // Call encountered - all prior store_regs interfere with each other
                    for (store_regs.items, 0..) |id_a, i| {
                        for (store_regs.items[i + 1 ..]) |id_b| {
                            try self.addInterference(id_a, id_b);
                        }
                    }
                    store_regs.clearRetainingCapacity();
                }
            }
        }

        // Build interference: process blocks in reverse order
        // Two values interfere if one is live when the other is defined
        for (f.blocks.items) |block| {
            // Track live values in this block
            var live = std.AutoHashMapUnmanaged(ID, void){};
            defer live.deinit(self.allocator);

            // Initialize with live-out from successors (simplified)
            // In a full implementation, we'd use proper liveness analysis

            // Process values in reverse order
            var i: usize = block.values.items.len;
            while (i > 0) {
                i -= 1;
                const v = block.values.items[i];

                if (self.values[v.id].needs_slot) {
                    // v is defined here - remove from live set
                    _ = live.remove(v.id);

                    // All currently live values interfere with v
                    var live_it = live.keyIterator();
                    while (live_it.next()) |live_id| {
                        // Add bidirectional interference
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
        // Add a interferes with b
        var list_a = self.interfere.get(a) orelse std.ArrayListUnmanaged(ID){};
        // Check if already present
        for (list_a.items) |id| {
            if (id == b) return;
        }
        try list_a.append(self.allocator, b);
        try self.interfere.put(self.allocator, a, list_a);

        // Add b interferes with a
        var list_b = self.interfere.get(b) orelse std.ArrayListUnmanaged(ID){};
        for (list_b.items) |id| {
            if (id == a) return;
        }
        try list_b.append(self.allocator, a);
        try self.interfere.put(self.allocator, b, list_b);
    }

    /// Check if two values interfere
    fn interferes(self: *const Self, a: ID, b: ID) bool {
        if (self.interfere.get(a)) |list| {
            for (list.items) |id| {
                if (id == b) return true;
            }
        }
        return false;
    }
};

/// Assign stack offsets to all local variables and StoreReg values.
/// Go reference: cmd/compile/internal/ssa/stackalloc.go stackalloc()
pub fn stackalloc(f: *Func) !StackAllocResult {
    debug.log(.regalloc, "=== Stack Allocation for '{s}' ===", .{f.name});

    var current_offset: i32 = FRAME_HEADER_SIZE;

    // Pass 1: Allocate space for local variables
    // Locals get offsets starting after the frame header
    const num_locals = f.local_sizes.len;
    if (num_locals > 0) {
        // Allocate local_offsets array
        const offsets = try f.allocator.alloc(i32, num_locals);
        for (f.local_sizes, 0..) |size, i| {
            // Align to 8 bytes for simplicity (structs may need more)
            current_offset = (current_offset + 7) & ~@as(i32, 7);
            offsets[i] = current_offset;
            debug.log(.regalloc, "  local {d} (size {d}) -> [sp+{d}]", .{ i, size, current_offset });
            current_offset += @intCast(size);
        }
        f.local_offsets = offsets;
    }

    const locals_size: u32 = @intCast(current_offset - FRAME_HEADER_SIZE);

    // Initialize stack allocator state
    var state = try StackAllocState.init(f.allocator, f);
    defer state.deinit();

    // Build interference graph
    try state.buildInterference();

    // Pass 2: Allocate stack slots with reuse
    // Go reference: stackalloc.go - slot reuse based on interference
    const Slot = struct {
        offset: i32,
        type_idx: u32,
        assigned_to: ?ID,
    };
    var slots = std.ArrayListUnmanaged(Slot){};
    defer slots.deinit(f.allocator);

    var next_slot: u32 = 0;
    var num_reused: u32 = 0;

    for (f.blocks.items) |block| {
        for (block.values.items) |v| {
            if (v.op == .store_reg) {
                // Try to reuse an existing slot
                var reused = false;
                for (slots.items) |*slot| {
                    // Can reuse if same type and no interference
                    if (slot.type_idx == v.type_idx) {
                        if (slot.assigned_to) |assigned| {
                            if (!state.interferes(v.id, assigned)) {
                                // Reuse this slot
                                try f.setHome(v, .{ .stack = slot.offset });
                                slot.assigned_to = v.id;
                                debug.log(.regalloc, "  store_reg v{d} -> [sp+{d}] (reused)", .{ v.id, slot.offset });
                                reused = true;
                                num_reused += 1;
                                break;
                            }
                        }
                    }
                }

                if (!reused) {
                    // Allocate new slot
                    current_offset = (current_offset + 7) & ~@as(i32, 7);
                    try f.setHome(v, .{ .stack = current_offset });
                    try slots.append(f.allocator, .{
                        .offset = current_offset,
                        .type_idx = v.type_idx,
                        .assigned_to = v.id,
                    });
                    debug.log(.regalloc, "  store_reg v{d} -> [sp+{d}] (new)", .{ v.id, current_offset });
                    current_offset += SPILL_SLOT_SIZE;
                    next_slot += 1;
                }
            }
        }
    }

    // Calculate total frame size (16-byte aligned)
    const total_frame: u32 = @intCast(current_offset);
    const aligned_frame = (total_frame + 15) & ~@as(u32, 15);

    debug.log(.regalloc, "  Stack: {d} locals ({d} bytes), {d} slots ({d} reused), frame {d} bytes", .{ num_locals, locals_size, next_slot, num_reused, aligned_frame });

    return .{
        .frame_size = aligned_frame,
        .num_spill_slots = next_slot,
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

    // No blocks, no spills
    const result = try stackalloc(&f);

    try std.testing.expectEqual(@as(u32, 16), result.frame_size); // Just header, 16-byte aligned
    try std.testing.expectEqual(@as(u32, 0), result.num_spill_slots);
    try std.testing.expectEqual(@as(u32, 0), result.num_reused);
}

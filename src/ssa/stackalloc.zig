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

const std = @import("std");
const Func = @import("func.zig").Func;
const Value = @import("value.zig").Value;
const Block = @import("block.zig").Block;
const Op = @import("op.zig").Op;
const debug = @import("../pipeline_debug.zig");

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

    // Pass 2: Find all StoreReg values and assign stack slots
    var next_slot: u32 = 0;
    for (f.blocks.items) |block| {
        for (block.values.items) |v| {
            if (v.op == .store_reg) {
                // Align for spill slots
                current_offset = (current_offset + 7) & ~@as(i32, 7);
                // Assign stack offset
                try f.setHome(v, .{ .stack = current_offset });
                debug.log(.regalloc, "  store_reg v{d} -> [sp+{d}]", .{ v.id, current_offset });
                current_offset += SPILL_SLOT_SIZE;
                next_slot += 1;
            }
        }
    }

    // Calculate total frame size (16-byte aligned)
    const total_frame: u32 = @intCast(current_offset);
    const aligned_frame = (total_frame + 15) & ~@as(u32, 15);

    debug.log(.regalloc, "  Stack: {d} locals ({d} bytes), {d} spill slots, frame size {d} bytes", .{ num_locals, locals_size, next_slot, aligned_frame });

    return .{
        .frame_size = aligned_frame,
        .num_spill_slots = next_slot,
        .locals_size = locals_size,
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
}

//! Stack Allocation Pass
//!
//! Go reference: cmd/compile/internal/ssa/stackalloc.go
//!
//! This pass runs after register allocation and assigns actual stack
//! offsets to spilled values (StoreReg operations).
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
//! | Spill slot 0     |  offset = 16
//! | Spill slot 1     |  offset = 24
//! | ...              |
//! | Spill slot N-1   |  offset = 16 + (N-1)*8
//! +------------------+
//! Low addresses
//! ```
//!
//! Each spill slot is 8 bytes (one 64-bit value).

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
    /// Total frame size (header + spill slots), 16-byte aligned
    frame_size: u32,
    /// Number of spill slots allocated
    num_spill_slots: u32,
};

/// Assign stack offsets to all StoreReg values in a function.
/// Go reference: cmd/compile/internal/ssa/stackalloc.go stackalloc()
pub fn stackalloc(f: *Func) !StackAllocResult {
    debug.log(.regalloc, "=== Stack Allocation for '{s}' ===", .{f.name});

    var next_slot: u32 = 0;

    // Pass 1: Find all StoreReg values and assign stack slots
    for (f.blocks.items) |block| {
        for (block.values.items) |v| {
            if (v.op == .store_reg) {
                // Assign stack offset: header + slot * 8
                const offset: i32 = FRAME_HEADER_SIZE + @as(i32, @intCast(next_slot)) * SPILL_SLOT_SIZE;
                try f.setHome(v, .{ .stack = offset });
                debug.log(.regalloc, "  store_reg v{d} -> [sp+{d}]", .{ v.id, offset });
                next_slot += 1;
            }
        }
    }

    // Calculate total frame size (16-byte aligned)
    const spill_space = next_slot * @as(u32, @intCast(SPILL_SLOT_SIZE));
    const total_frame = @as(u32, @intCast(FRAME_HEADER_SIZE)) + spill_space;
    const aligned_frame = (total_frame + 15) & ~@as(u32, 15);

    debug.log(.regalloc, "  Stack: {d} spill slots, frame size {d} bytes", .{ next_slot, aligned_frame });

    return .{
        .frame_size = aligned_frame,
        .num_spill_slots = next_slot,
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

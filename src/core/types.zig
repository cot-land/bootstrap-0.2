//! Core types used throughout the compiler.
//!
//! Go reference: [cmd/compile/internal/ssa/] various files
//!
//! This module defines fundamental types used across all compiler phases:
//! - [ID] - Unique identifiers for Values and Blocks
//! - [TypeIndex] - References into type registry
//! - [RegMask] - Bit sets for register allocation
//! - [Pos] - Source code positions
//!
//! ## Related Modules
//!
//! - [ssa/value.zig] - Uses ID for value identification
//! - [ssa/block.zig] - Uses ID for block identification
//! - [ssa/op.zig] - Uses RegMask for register constraints

const std = @import("std");

/// Unique identifier for SSA values and blocks.
/// Densely allocated starting at 1 (0 reserved for invalid).
pub const ID = u32;

/// Invalid ID constant.
pub const INVALID_ID: ID = 0;

/// Type index into type registry.
pub const TypeIndex = u32;

/// Register mask - bit i set means register i is in the set.
pub const RegMask = u64;

/// Register number (0-63).
pub const RegNum = u6;

/// Position in source code.
/// Go reference: cmd/compile/internal/src/xpos.go
pub const Pos = struct {
    /// Line number (1-indexed, 0 = unknown)
    line: u32 = 0,
    /// Column number (1-indexed, 0 = unknown)
    col: u32 = 0,
    /// File index in file table
    file: u16 = 0,

    pub fn format(self: Pos) []const u8 {
        // For debugging - actual formatting done by caller
        _ = self;
        return "<pos>";
    }
};

/// ID allocator for values and blocks.
pub const IDAllocator = struct {
    next_id: ID = 1,

    pub fn next(self: *IDAllocator) ID {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn reset(self: *IDAllocator) void {
        self.next_id = 1;
    }
};

// RegMask operations

pub fn regMaskSet(mask: RegMask, reg: RegNum) RegMask {
    return mask | (@as(RegMask, 1) << reg);
}

pub fn regMaskClear(mask: RegMask, reg: RegNum) RegMask {
    return mask & ~(@as(RegMask, 1) << reg);
}

pub fn regMaskContains(mask: RegMask, reg: RegNum) bool {
    return (mask & (@as(RegMask, 1) << reg)) != 0;
}

pub fn regMaskCount(mask: RegMask) u32 {
    return @popCount(mask);
}

/// Returns the first set bit (lowest register number), or null if empty.
pub fn regMaskFirst(mask: RegMask) ?RegNum {
    if (mask == 0) return null;
    return @truncate(@ctz(mask));
}

/// Iterator over set bits in a register mask.
pub const RegMaskIterator = struct {
    mask: RegMask,

    pub fn next(self: *RegMaskIterator) ?RegNum {
        if (self.mask == 0) return null;
        const reg: RegNum = @truncate(@ctz(self.mask));
        self.mask &= self.mask - 1; // Clear lowest bit
        return reg;
    }
};

pub fn regMaskIterator(mask: RegMask) RegMaskIterator {
    return .{ .mask = mask };
}

// Tests

test "IDAllocator" {
    var alloc = IDAllocator{};
    try std.testing.expectEqual(@as(ID, 1), alloc.next());
    try std.testing.expectEqual(@as(ID, 2), alloc.next());
    try std.testing.expectEqual(@as(ID, 3), alloc.next());

    alloc.reset();
    try std.testing.expectEqual(@as(ID, 1), alloc.next());
}

test "RegMask operations" {
    var mask: RegMask = 0;

    mask = regMaskSet(mask, 0);
    try std.testing.expect(regMaskContains(mask, 0));
    try std.testing.expect(!regMaskContains(mask, 1));

    mask = regMaskSet(mask, 5);
    try std.testing.expectEqual(@as(u32, 2), regMaskCount(mask));

    mask = regMaskClear(mask, 0);
    try std.testing.expect(!regMaskContains(mask, 0));
    try std.testing.expect(regMaskContains(mask, 5));
}

test "RegMaskIterator" {
    var mask: RegMask = 0;
    mask = regMaskSet(mask, 0);
    mask = regMaskSet(mask, 3);
    mask = regMaskSet(mask, 7);

    var it = regMaskIterator(mask);
    try std.testing.expectEqual(@as(?RegNum, 0), it.next());
    try std.testing.expectEqual(@as(?RegNum, 3), it.next());
    try std.testing.expectEqual(@as(?RegNum, 7), it.next());
    try std.testing.expectEqual(@as(?RegNum, null), it.next());
}

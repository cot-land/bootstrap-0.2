//! Core types used throughout the compiler.
//!
//! Go reference: [cmd/compile/internal/ssa/] various files
//!
//! This module defines fundamental types used across all compiler phases:
//! - [ID] - Unique identifiers for Values and Blocks
//! - [TypeIndex] - References into type registry
//! - [TypeInfo] - Type metadata (size, alignment, fields)
//! - [RegMask] - Bit sets for register allocation
//! - [Pos] - Source code positions
//!
//! ## Lessons from Bootstrap
//!
//! Bootstrap's BUG-008, BUG-009, BUG-010 all stemmed from incomplete type info:
//! - Codegen guessed sizes based on alignment, not actual type
//! - Field offsets computed on-demand, sometimes wrong
//! - Large structs (>8 bytes) not handled correctly
//!
//! This module provides complete type information UPFRONT to prevent these bugs.
//!
//! ## Related Modules
//!
//! - [ssa/value.zig] - Uses ID for value identification
//! - [ssa/block.zig] - Uses ID for block identification
//! - [ssa/op.zig] - Uses RegMask for register constraints
//! - [codegen/*.zig] - Uses TypeInfo for correct load/store widths

const std = @import("std");

/// Unique identifier for SSA values and blocks.
/// Densely allocated starting at 1 (0 reserved for invalid).
pub const ID = u32;

/// Invalid ID constant.
pub const INVALID_ID: ID = 0;

/// Type index into type registry.
pub const TypeIndex = u32;

/// Invalid type index constant.
pub const INVALID_TYPE: TypeIndex = 0;

// =========================================
// Type System (Lessons from Bootstrap)
// =========================================

/// Type kind - what category of type this is.
///
/// Contains both:
/// - Cot language types (from SPEC.md)
/// - SSA pseudo-types (from Go's ssa/types.go, needed for regalloc)
pub const TypeKind = enum {
    // =========================================
    // Cot Language Types (from SPEC.md)
    // =========================================

    /// Invalid/uninitialized type
    invalid,

    /// Void type (no value) - also used as SSA pseudo-type
    void_type,

    /// Boolean (1 byte)
    bool_type,

    /// Signed integers: i8, i16, i32, i64 (int = i64)
    int_type,

    /// Unsigned integers: u8, u16, u32, u64
    uint_type,

    /// Floating point: f32, f64 (float = f64)
    float_type,

    /// String (ptr + len, 16 bytes on 64-bit)
    string_type,

    /// Pointer to T
    pointer_type,

    /// Optional ?T
    optional_type,

    /// Fixed-size array [N]T
    array_type,

    /// Slice []T (ptr + len)
    slice_type,

    /// Struct with named fields
    struct_type,

    /// Enum with named variants
    enum_type,

    /// Tagged union (enum + payload)
    union_type,

    /// Function type fn(args) ret
    function_type,

    // =========================================
    // SSA Pseudo-Types (from Go's ssa/types.go)
    // These are NOT Cot language types - they're
    // internal SSA representations for regalloc.
    // Go ref: cmd/compile/internal/types/type.go:1600-1612
    // =========================================

    /// Memory state - tracks memory ordering in SSA
    /// Go: TypeMem = newSSA("mem")
    ssa_mem,

    /// CPU flags register - for condition codes
    /// Go: TypeFlags = newSSA("flags")
    ssa_flags,

    /// Tuple type - for operations returning multiple values
    /// Go: TypeTuple with TupleElem0, TupleElem1
    ssa_tuple,

    /// Results type - for function multiple returns
    /// Go: TypeResults
    ssa_results,
};

/// Field information for struct types.
/// Offset is computed once when struct is defined, never recomputed.
pub const FieldInfo = struct {
    /// Field name
    name: []const u8,

    /// Field type (index into type registry)
    type_idx: TypeIndex,

    /// Byte offset from struct start (computed at struct definition)
    offset: u32,

    /// Field size in bytes (cached from type info)
    size: u32,
};

/// Complete type information.
///
/// Bootstrap lesson: ALWAYS use TypeInfo for sizes, never guess from alignment.
/// - BUG-008: Guessed string size as 8 bytes (ptr only), lost length
/// - BUG-010: Guessed struct size as 8 bytes, truncated data
pub const TypeInfo = struct {
    /// Type kind
    kind: TypeKind,

    /// Size in bytes (complete, including padding)
    size: u32,

    /// Alignment requirement in bytes
    alignment: u32,

    /// For pointer/optional/array: element type
    element_type: TypeIndex = INVALID_TYPE,

    /// For array: element count
    array_len: u32 = 0,

    /// For struct/union: field definitions
    /// These are owned by the TypeRegistry, not the TypeInfo
    fields: ?[]const FieldInfo = null,

    /// For enum: backing integer type
    backing_type: TypeIndex = INVALID_TYPE,

    /// For function: parameter types (owned by TypeRegistry)
    param_types: ?[]const TypeIndex = null,

    /// For function: return type
    return_type: TypeIndex = INVALID_TYPE,

    // =========================================
    // Size Queries (use these, don't guess!)
    // =========================================

    /// Get size in bytes. Always use this, never guess.
    pub fn sizeOf(self: TypeInfo) u32 {
        return self.size;
    }

    /// Get alignment in bytes.
    pub fn alignOf(self: TypeInfo) u32 {
        return self.alignment;
    }

    /// Does this type fit in registers? (ARM64: ≤16 bytes)
    pub fn fitsInRegs(self: TypeInfo) bool {
        return self.size <= 16;
    }

    /// Is this a primitive type (not compound)?
    pub fn isPrimitive(self: TypeInfo) bool {
        return switch (self.kind) {
            .bool_type, .int_type, .uint_type, .float_type => true,
            else => false,
        };
    }

    /// Is this a string type? (needs 2 registers: ptr + len)
    pub fn isString(self: TypeInfo) bool {
        return self.kind == .string_type;
    }

    /// Is this a slice type? (needs 2 registers: ptr + len)
    pub fn isSlice(self: TypeInfo) bool {
        return self.kind == .slice_type;
    }

    /// Is this a pointer type?
    pub fn isPointer(self: TypeInfo) bool {
        return self.kind == .pointer_type;
    }

    /// Is this a struct type?
    pub fn isStruct(self: TypeInfo) bool {
        return self.kind == .struct_type;
    }

    // =========================================
    // SSA Pseudo-Type Queries (for regalloc)
    // Go ref: cmd/compile/internal/ssa/regalloc.go
    // =========================================

    /// Is this the SSA memory type? (tracks memory ordering)
    /// Go: typ.IsMemory()
    pub fn isMemory(self: TypeInfo) bool {
        return self.kind == .ssa_mem;
    }

    /// Is this the SSA void type? (no value)
    /// Go: typ.IsVoid()
    pub fn isVoid(self: TypeInfo) bool {
        return self.kind == .void_type;
    }

    /// Is this the SSA flags type? (CPU condition codes)
    /// Go: typ.IsFlags()
    pub fn isFlags(self: TypeInfo) bool {
        return self.kind == .ssa_flags;
    }

    /// Is this an SSA tuple type? (multi-value result)
    /// Go: typ.IsTuple()
    pub fn isTuple(self: TypeInfo) bool {
        return self.kind == .ssa_tuple;
    }

    /// Is this an SSA results type? (function multi-return)
    /// Go: typ.IsResults()
    pub fn isResults(self: TypeInfo) bool {
        return self.kind == .ssa_results;
    }

    /// Is this a floating point type? (for FP register class)
    /// Go: typ.IsFloat()
    pub fn isFloat(self: TypeInfo) bool {
        return self.kind == .float_type;
    }

    /// Is this an integer type? (for GP register class)
    /// Go: typ.IsInteger()
    pub fn isInteger(self: TypeInfo) bool {
        return self.kind == .int_type or self.kind == .uint_type;
    }

    /// Is this a signed integer?
    /// Go: typ.IsSigned()
    pub fn isSigned(self: TypeInfo) bool {
        return self.kind == .int_type;
    }

    /// Is this an unsigned integer?
    /// Go: typ.IsUnsigned()
    pub fn isUnsigned(self: TypeInfo) bool {
        return self.kind == .uint_type;
    }

    /// Does this type need a register? (Not mem/void/flags)
    /// Go: regalloc.go uses this pattern throughout
    pub fn needsReg(self: TypeInfo) bool {
        return switch (self.kind) {
            .ssa_mem, .ssa_flags, .void_type => false,
            else => true,
        };
    }

    /// How many registers does this type need for parameter passing?
    /// Bootstrap BUG-016: String uses 2 registers, not 1!
    pub fn registerCount(self: TypeInfo) u32 {
        if (self.kind == .string_type or self.kind == .slice_type) {
            return 2; // ptr + len
        }
        if (self.size <= 8) return 1;
        if (self.size <= 16) return 2;
        return 1; // >16 bytes passed by pointer
    }

    /// Get field by name (for struct types).
    pub fn getField(self: TypeInfo, name: []const u8) ?FieldInfo {
        if (self.fields) |fields| {
            for (fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    return field;
                }
            }
        }
        return null;
    }

    /// Get field by index (for struct types).
    pub fn getFieldByIndex(self: TypeInfo, index: usize) ?FieldInfo {
        if (self.fields) |fields| {
            if (index < fields.len) {
                return fields[index];
            }
        }
        return null;
    }
};

// =========================================
// Predefined Type Indices
// =========================================

/// Well-known type indices for primitives and SSA pseudo-types.
/// These are always at fixed positions in the type registry.
pub const PrimitiveTypes = struct {
    // Cot language primitives
    pub const void_type: TypeIndex = 1;
    pub const bool_type: TypeIndex = 2;
    pub const i8_type: TypeIndex = 3;
    pub const i16_type: TypeIndex = 4;
    pub const i32_type: TypeIndex = 5;
    pub const i64_type: TypeIndex = 6; // int
    pub const u8_type: TypeIndex = 7; // byte
    pub const u16_type: TypeIndex = 8;
    pub const u32_type: TypeIndex = 9;
    pub const u64_type: TypeIndex = 10;
    pub const f32_type: TypeIndex = 11;
    pub const f64_type: TypeIndex = 12; // float
    pub const string_type: TypeIndex = 13;

    // SSA pseudo-types (Go ref: ssa/types.go)
    pub const ssa_mem: TypeIndex = 14;
    pub const ssa_flags: TypeIndex = 15;
    pub const ssa_tuple: TypeIndex = 16;
    pub const ssa_results: TypeIndex = 17;

    /// Alias: int = i64
    pub const int_type: TypeIndex = i64_type;
    /// Alias: byte = u8
    pub const byte_type: TypeIndex = u8_type;
    /// Alias: float = f64
    pub const float_type: TypeIndex = f64_type;

    /// First user-defined type index
    pub const first_user_type: TypeIndex = 18;
};

/// Predefined TypeInfo for primitives and SSA pseudo-types.
pub const PrimitiveTypeInfo = struct {
    // Cot language primitives
    pub const void_info = TypeInfo{ .kind = .void_type, .size = 0, .alignment = 1 };
    pub const bool_info = TypeInfo{ .kind = .bool_type, .size = 1, .alignment = 1 };
    pub const i8_info = TypeInfo{ .kind = .int_type, .size = 1, .alignment = 1 };
    pub const i16_info = TypeInfo{ .kind = .int_type, .size = 2, .alignment = 2 };
    pub const i32_info = TypeInfo{ .kind = .int_type, .size = 4, .alignment = 4 };
    pub const i64_info = TypeInfo{ .kind = .int_type, .size = 8, .alignment = 8 };
    pub const u8_info = TypeInfo{ .kind = .uint_type, .size = 1, .alignment = 1 };
    pub const u16_info = TypeInfo{ .kind = .uint_type, .size = 2, .alignment = 2 };
    pub const u32_info = TypeInfo{ .kind = .uint_type, .size = 4, .alignment = 4 };
    pub const u64_info = TypeInfo{ .kind = .uint_type, .size = 8, .alignment = 8 };
    pub const f32_info = TypeInfo{ .kind = .float_type, .size = 4, .alignment = 4 };
    pub const f64_info = TypeInfo{ .kind = .float_type, .size = 8, .alignment = 8 };
    pub const string_info = TypeInfo{ .kind = .string_type, .size = 16, .alignment = 8 }; // ptr(8) + len(8)

    // SSA pseudo-types (Go ref: ssa/types.go lines 1600-1612)
    // These have size 0 and don't occupy registers in the normal sense
    pub const ssa_mem_info = TypeInfo{ .kind = .ssa_mem, .size = 0, .alignment = 1 };
    pub const ssa_flags_info = TypeInfo{ .kind = .ssa_flags, .size = 0, .alignment = 1 };
    pub const ssa_tuple_info = TypeInfo{ .kind = .ssa_tuple, .size = 0, .alignment = 1 };
    pub const ssa_results_info = TypeInfo{ .kind = .ssa_results, .size = 0, .alignment = 1 };
};

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

// =========================================
// TypeInfo Tests (from IMPROVEMENTS.md)
// =========================================

test "primitive type sizes" {
    // Cot type sizes per SPEC.md
    try std.testing.expectEqual(@as(u32, 0), PrimitiveTypeInfo.void_info.sizeOf());
    try std.testing.expectEqual(@as(u32, 1), PrimitiveTypeInfo.bool_info.sizeOf());
    try std.testing.expectEqual(@as(u32, 1), PrimitiveTypeInfo.i8_info.sizeOf());
    try std.testing.expectEqual(@as(u32, 2), PrimitiveTypeInfo.i16_info.sizeOf());
    try std.testing.expectEqual(@as(u32, 4), PrimitiveTypeInfo.i32_info.sizeOf());
    try std.testing.expectEqual(@as(u32, 8), PrimitiveTypeInfo.i64_info.sizeOf());
    try std.testing.expectEqual(@as(u32, 1), PrimitiveTypeInfo.u8_info.sizeOf());
    try std.testing.expectEqual(@as(u32, 8), PrimitiveTypeInfo.f64_info.sizeOf());
    try std.testing.expectEqual(@as(u32, 16), PrimitiveTypeInfo.string_info.sizeOf()); // ptr + len!
}

test "string type uses 2 registers" {
    // Bootstrap BUG-016: String params overflowed because we counted 1 reg instead of 2
    try std.testing.expectEqual(@as(u32, 2), PrimitiveTypeInfo.string_info.registerCount());
    try std.testing.expect(PrimitiveTypeInfo.string_info.isString());
}

test "primitive types fit in registers" {
    try std.testing.expect(PrimitiveTypeInfo.i64_info.fitsInRegs());
    try std.testing.expect(PrimitiveTypeInfo.string_info.fitsInRegs()); // 16 bytes = ok
}

test "large struct does not fit in registers" {
    // Bootstrap BUG-010: Large structs (>16 bytes) need special handling
    const large_struct = TypeInfo{
        .kind = .struct_type,
        .size = 24, // >16 bytes
        .alignment = 8,
    };
    try std.testing.expect(!large_struct.fitsInRegs());
}

test "struct field lookup" {
    const fields = [_]FieldInfo{
        .{ .name = "x", .type_idx = PrimitiveTypes.i64_type, .offset = 0, .size = 8 },
        .{ .name = "y", .type_idx = PrimitiveTypes.i64_type, .offset = 8, .size = 8 },
    };

    const point_type = TypeInfo{
        .kind = .struct_type,
        .size = 16,
        .alignment = 8,
        .fields = &fields,
    };

    // Get field by name
    const x_field = point_type.getField("x").?;
    try std.testing.expectEqual(@as(u32, 0), x_field.offset);

    const y_field = point_type.getField("y").?;
    try std.testing.expectEqual(@as(u32, 8), y_field.offset);

    // Unknown field returns null
    try std.testing.expect(point_type.getField("z") == null);
}

test "struct field alignment and padding" {
    // struct { a: u8, b: u64, c: u8 }
    // Expected layout: a at 0 (1 byte), padding (7 bytes), b at 8 (8 bytes), c at 16 (1 byte)
    // Total size: 24 bytes (with trailing padding to 8-byte alignment)
    const fields = [_]FieldInfo{
        .{ .name = "a", .type_idx = PrimitiveTypes.u8_type, .offset = 0, .size = 1 },
        .{ .name = "b", .type_idx = PrimitiveTypes.i64_type, .offset = 8, .size = 8 }, // Aligned to 8
        .{ .name = "c", .type_idx = PrimitiveTypes.u8_type, .offset = 16, .size = 1 },
    };

    const padded_struct = TypeInfo{
        .kind = .struct_type,
        .size = 24, // 1 + 7 padding + 8 + 1 + 7 padding = 24
        .alignment = 8, // Max field alignment
        .fields = &fields,
    };

    // Bootstrap BUG-009: Field offsets must be computed correctly
    const b_field = padded_struct.getField("b").?;
    try std.testing.expectEqual(@as(u32, 8), b_field.offset); // NOT 1!

    // Struct doesn't fit in registers (>16 bytes)
    try std.testing.expect(!padded_struct.fitsInRegs());
}

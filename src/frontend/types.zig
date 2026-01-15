//! Type representation for Cot.
//!
//! Architecture modeled on Go's go/types package:
//! - Type as a tagged union (like Go's Type interface implementations)
//! - TypeIndex for compact storage and interning
//! - TypeRegistry for type creation and lookup
//! - BasicKind for primitive types with predicates
//!
//! Key concepts from Go:
//! - Untyped literals (untyped int, untyped float) resolve during assignment
//! - Named types vs underlying types
//! - Type identity vs assignability

const std = @import("std");

// =========================================
// Type Index
// =========================================

/// Index into type pool. Using indices allows type interning and comparison.
pub const TypeIndex = u32;

/// Sentinel for invalid/error types.
pub const invalid_type: TypeIndex = std.math.maxInt(TypeIndex);

// =========================================
// Basic Types (Go's basic.go)
// =========================================

/// Kind of basic type.
pub const BasicKind = enum(u8) {
    // Invalid type
    invalid,

    // Boolean
    bool_type,

    // Signed integers
    i8_type,
    i16_type,
    i32_type,
    i64_type,

    // Unsigned integers
    u8_type,
    u16_type,
    u32_type,
    u64_type,

    // Floating point
    f32_type,
    f64_type,

    // Void (no return value)
    void_type,

    // Untyped literals (resolved during assignment)
    untyped_int,
    untyped_float,
    untyped_bool,
    untyped_null,

    /// Get the name of this basic type.
    pub fn name(self: BasicKind) []const u8 {
        return switch (self) {
            .invalid => "invalid",
            .bool_type => "bool",
            .i8_type => "i8",
            .i16_type => "i16",
            .i32_type => "i32",
            .i64_type => "i64",
            .u8_type => "u8",
            .u16_type => "u16",
            .u32_type => "u32",
            .u64_type => "u64",
            .f32_type => "f32",
            .f64_type => "f64",
            .void_type => "void",
            .untyped_int => "untyped int",
            .untyped_float => "untyped float",
            .untyped_bool => "untyped bool",
            .untyped_null => "untyped null",
        };
    }

    /// Check if this is a numeric type.
    pub fn isNumeric(self: BasicKind) bool {
        return self.isInteger() or self.isFloat();
    }

    /// Check if this is an integer type.
    pub fn isInteger(self: BasicKind) bool {
        return switch (self) {
            .i8_type, .i16_type, .i32_type, .i64_type => true,
            .u8_type, .u16_type, .u32_type, .u64_type => true,
            .untyped_int => true,
            else => false,
        };
    }

    /// Check if this is a signed integer type.
    pub fn isSigned(self: BasicKind) bool {
        return switch (self) {
            .i8_type, .i16_type, .i32_type, .i64_type => true,
            else => false,
        };
    }

    /// Check if this is an unsigned integer type.
    pub fn isUnsigned(self: BasicKind) bool {
        return switch (self) {
            .u8_type, .u16_type, .u32_type, .u64_type => true,
            else => false,
        };
    }

    /// Check if this is a floating point type.
    pub fn isFloat(self: BasicKind) bool {
        return switch (self) {
            .f32_type, .f64_type, .untyped_float => true,
            else => false,
        };
    }

    /// Check if this is an untyped type.
    pub fn isUntyped(self: BasicKind) bool {
        return switch (self) {
            .untyped_int, .untyped_float, .untyped_bool, .untyped_null => true,
            else => false,
        };
    }

    /// Get the size in bytes.
    pub fn size(self: BasicKind) u8 {
        return switch (self) {
            .bool_type => 1,
            .i8_type, .u8_type => 1,
            .i16_type, .u16_type => 2,
            .i32_type, .u32_type, .f32_type => 4,
            .i64_type, .u64_type, .f64_type => 8,
            else => 0, // void, invalid, untyped
        };
    }
};

// =========================================
// Composite Types
// =========================================

/// Pointer type: *T
pub const PointerType = struct {
    elem: TypeIndex,
};

/// Optional type: ?T
pub const OptionalType = struct {
    elem: TypeIndex,
};

/// Slice type: []T
pub const SliceType = struct {
    elem: TypeIndex,
};

/// Array type: [N]T
pub const ArrayType = struct {
    elem: TypeIndex,
    length: u64,
};

/// Map type: Map<K, V>
pub const MapType = struct {
    key: TypeIndex,
    value: TypeIndex,
};

/// List type: List<T>
pub const ListType = struct {
    elem: TypeIndex,
};

// =========================================
// Struct Types
// =========================================

/// Struct field
pub const StructField = struct {
    name: []const u8,
    type_idx: TypeIndex,
    offset: u32, // byte offset (computed during layout)
};

/// Struct type
pub const StructType = struct {
    name: []const u8,
    fields: []const StructField,
    size: u32,
    alignment: u8,
};

// =========================================
// Enum Types
// =========================================

/// Enum variant
pub const EnumVariant = struct {
    name: []const u8,
    value: i64,
};

/// Enum type
pub const EnumType = struct {
    name: []const u8,
    variants: []const EnumVariant,
    backing_type: TypeIndex,
};

// =========================================
// Union Types (tagged unions)
// =========================================

/// Union variant
pub const UnionVariant = struct {
    name: []const u8,
    payload_type: TypeIndex, // invalid_type for unit variants
};

/// Union type
pub const UnionType = struct {
    name: []const u8,
    variants: []const UnionVariant,
    tag_type: TypeIndex, // backing enum type for tag
};

// =========================================
// Function Types
// =========================================

/// Function parameter
pub const FuncParam = struct {
    name: []const u8,
    type_idx: TypeIndex,
};

/// Function type (signature)
pub const FuncType = struct {
    params: []const FuncParam,
    return_type: TypeIndex,
};

// =========================================
// Type (unified representation)
// =========================================

/// Unified type representation (like Go's Type interface).
pub const Type = union(enum) {
    basic: BasicKind,
    pointer: PointerType,
    optional: OptionalType,
    slice: SliceType,
    array: ArrayType,
    map: MapType,
    list: ListType,
    struct_type: StructType,
    enum_type: EnumType,
    union_type: UnionType,
    func: FuncType,

    /// Get the underlying type (for named types, returns the definition).
    /// For Cot, we don't have separate named types yet, so this is identity.
    pub fn underlying(self: Type) Type {
        return self;
    }

    /// Check if this is an error/invalid type.
    pub fn isInvalid(self: Type) bool {
        return self == .basic and self.basic == .invalid;
    }
};

// =========================================
// Type Registry (type interning)
// =========================================

/// Registry for creating and looking up types.
/// Provides interning so identical types share the same index.
pub const TypeRegistry = struct {
    types: std.ArrayListUnmanaged(Type),
    allocator: std.mem.Allocator,

    /// Map from type name to index (for named types like structs, enums).
    name_map: std.StringHashMap(TypeIndex),

    // Pre-registered basic type indices
    pub const INVALID: TypeIndex = 0;
    pub const BOOL: TypeIndex = 1;
    pub const I8: TypeIndex = 2;
    pub const I16: TypeIndex = 3;
    pub const I32: TypeIndex = 4;
    pub const I64: TypeIndex = 5;
    pub const U8: TypeIndex = 6;
    pub const U16: TypeIndex = 7;
    pub const U32: TypeIndex = 8;
    pub const U64: TypeIndex = 9;
    pub const F32: TypeIndex = 10;
    pub const F64: TypeIndex = 11;
    pub const VOID: TypeIndex = 12;
    pub const UNTYPED_INT: TypeIndex = 13;
    pub const UNTYPED_FLOAT: TypeIndex = 14;
    pub const UNTYPED_BOOL: TypeIndex = 15;
    pub const UNTYPED_NULL: TypeIndex = 16;

    // Commonly used composite types
    pub const STRING: TypeIndex = 17; // []u8

    // SSA pseudo-types (Go ref: cmd/compile/internal/ssa/types.go)
    // These represent SSA-specific concepts, not Cot language types.
    // Size is 0 - they don't occupy registers in the normal sense.
    pub const SSA_MEM: TypeIndex = 18; // Memory state
    pub const SSA_FLAGS: TypeIndex = 19; // CPU flags
    pub const SSA_TUPLE: TypeIndex = 20; // Multi-value tuple
    pub const SSA_RESULTS: TypeIndex = 21; // Call results (decomposed by expand_calls)

    // First user-defined type index (structs, enums, etc.)
    pub const FIRST_USER_TYPE: TypeIndex = 22;

    // Default integer type (i64)
    pub const INT: TypeIndex = I64;

    // Default float type (f64)
    pub const FLOAT: TypeIndex = F64;

    /// Get human-readable type name from well-known type index.
    /// Works without a TypeRegistry instance for basic types.
    /// CRITICAL for debugging: makes type mismatches immediately visible.
    pub fn basicTypeName(type_idx: TypeIndex) []const u8 {
        return switch (type_idx) {
            INVALID => "invalid",
            BOOL => "bool",
            I8 => "i8",
            I16 => "i16",
            I32 => "i32",
            I64 => "i64",
            U8 => "u8",
            U16 => "u16",
            U32 => "u32",
            U64 => "u64",
            F32 => "f32",
            F64 => "f64",
            VOID => "void",
            UNTYPED_INT => "untyped_int",
            UNTYPED_FLOAT => "untyped_float",
            UNTYPED_BOOL => "untyped_bool",
            UNTYPED_NULL => "untyped_null",
            STRING => "string",
            SSA_MEM => "ssa_mem",
            SSA_FLAGS => "ssa_flags",
            SSA_TUPLE => "ssa_tuple",
            SSA_RESULTS => "ssa_results",
            else => "composite", // Pointers, slices, arrays, structs
        };
    }

    /// Get size in bytes for well-known type index.
    /// Works without a TypeRegistry instance for basic types.
    /// CRITICAL for codegen: determines load/store instruction size.
    pub fn basicTypeSize(type_idx: TypeIndex) u8 {
        return switch (type_idx) {
            VOID, SSA_MEM, SSA_FLAGS, SSA_TUPLE, SSA_RESULTS => 0,
            BOOL, I8, U8 => 1,
            I16, U16 => 2,
            I32, U32, F32 => 4,
            I64, U64, F64 => 8,
            STRING => 16, // ptr + len
            else => 8, // Default to 64-bit for pointers, etc.
        };
    }

    pub fn init(allocator: std.mem.Allocator) !TypeRegistry {
        var reg = TypeRegistry{
            .types = .{},
            .allocator = allocator,
            .name_map = std.StringHashMap(TypeIndex).init(allocator),
        };

        // Register basic types in order
        try reg.types.append(allocator, .{ .basic = .invalid }); // 0
        try reg.types.append(allocator, .{ .basic = .bool_type }); // 1
        try reg.types.append(allocator, .{ .basic = .i8_type }); // 2
        try reg.types.append(allocator, .{ .basic = .i16_type }); // 3
        try reg.types.append(allocator, .{ .basic = .i32_type }); // 4
        try reg.types.append(allocator, .{ .basic = .i64_type }); // 5
        try reg.types.append(allocator, .{ .basic = .u8_type }); // 6
        try reg.types.append(allocator, .{ .basic = .u16_type }); // 7
        try reg.types.append(allocator, .{ .basic = .u32_type }); // 8
        try reg.types.append(allocator, .{ .basic = .u64_type }); // 9
        try reg.types.append(allocator, .{ .basic = .f32_type }); // 10
        try reg.types.append(allocator, .{ .basic = .f64_type }); // 11
        try reg.types.append(allocator, .{ .basic = .void_type }); // 12
        try reg.types.append(allocator, .{ .basic = .untyped_int }); // 13
        try reg.types.append(allocator, .{ .basic = .untyped_float }); // 14
        try reg.types.append(allocator, .{ .basic = .untyped_bool }); // 15
        try reg.types.append(allocator, .{ .basic = .untyped_null }); // 16

        // Register string type ([]u8)
        try reg.types.append(allocator, .{ .slice = .{ .elem = U8 } }); // 17

        // Register basic type names
        try reg.name_map.put("bool", BOOL);
        try reg.name_map.put("i8", I8);
        try reg.name_map.put("i16", I16);
        try reg.name_map.put("i32", I32);
        try reg.name_map.put("i64", I64);
        try reg.name_map.put("int", INT);
        try reg.name_map.put("u8", U8);
        try reg.name_map.put("u16", U16);
        try reg.name_map.put("u32", U32);
        try reg.name_map.put("u64", U64);
        try reg.name_map.put("f32", F32);
        try reg.name_map.put("f64", F64);
        try reg.name_map.put("float", F64);
        try reg.name_map.put("void", VOID);
        try reg.name_map.put("string", STRING);
        try reg.name_map.put("byte", U8);

        return reg;
    }

    pub fn deinit(self: *TypeRegistry) void {
        self.types.deinit(self.allocator);
        self.name_map.deinit();
    }

    /// Get a type by index.
    pub fn get(self: *const TypeRegistry, idx: TypeIndex) Type {
        if (idx == invalid_type or idx >= self.types.items.len) {
            return .{ .basic = .invalid };
        }
        return self.types.items[idx];
    }

    /// Look up a type by name.
    pub fn lookupByName(self: *const TypeRegistry, name: []const u8) ?TypeIndex {
        return self.name_map.get(name);
    }

    /// Add a new type and return its index.
    pub fn add(self: *TypeRegistry, t: Type) !TypeIndex {
        const idx: TypeIndex = @intCast(self.types.items.len);
        try self.types.append(self.allocator, t);
        return idx;
    }

    /// Register a named type.
    pub fn registerNamed(self: *TypeRegistry, name: []const u8, idx: TypeIndex) !void {
        try self.name_map.put(name, idx);
    }

    /// Create a pointer type.
    pub fn makePointer(self: *TypeRegistry, elem: TypeIndex) !TypeIndex {
        return try self.add(.{ .pointer = .{ .elem = elem } });
    }

    /// Create an optional type.
    pub fn makeOptional(self: *TypeRegistry, elem: TypeIndex) !TypeIndex {
        return try self.add(.{ .optional = .{ .elem = elem } });
    }

    /// Create a slice type.
    pub fn makeSlice(self: *TypeRegistry, elem: TypeIndex) !TypeIndex {
        return try self.add(.{ .slice = .{ .elem = elem } });
    }

    /// Create an array type.
    pub fn makeArray(self: *TypeRegistry, elem: TypeIndex, length: u64) !TypeIndex {
        return try self.add(.{ .array = .{ .elem = elem, .length = length } });
    }

    /// Create a map type.
    pub fn makeMap(self: *TypeRegistry, key: TypeIndex, value: TypeIndex) !TypeIndex {
        return try self.add(.{ .map = .{ .key = key, .value = value } });
    }

    /// Create a list type.
    pub fn makeList(self: *TypeRegistry, elem: TypeIndex) !TypeIndex {
        return try self.add(.{ .list = .{ .elem = elem } });
    }

    /// Create a function type.
    pub fn makeFunc(self: *TypeRegistry, params: []const FuncParam, return_type: TypeIndex) !TypeIndex {
        // Dupe params to ensure they persist
        const duped_params = try self.allocator.dupe(FuncParam, params);
        return try self.add(.{ .func = .{ .params = duped_params, .return_type = return_type } });
    }

    /// Check if a type is a pointer.
    pub fn isPointer(self: *const TypeRegistry, idx: TypeIndex) bool {
        const t = self.get(idx);
        return t == .pointer;
    }

    /// Get the element type of a pointer.
    pub fn pointerElem(self: *const TypeRegistry, idx: TypeIndex) TypeIndex {
        const t = self.get(idx);
        return switch (t) {
            .pointer => |p| p.elem,
            else => invalid_type,
        };
    }

    /// Check if a type is an array.
    pub fn isArray(self: *const TypeRegistry, idx: TypeIndex) bool {
        const t = self.get(idx);
        return t == .array;
    }

    /// Get the element type of an array.
    pub fn arrayElem(self: *const TypeRegistry, idx: TypeIndex) TypeIndex {
        const t = self.get(idx);
        return switch (t) {
            .array => |a| a.elem,
            else => invalid_type,
        };
    }

    /// Get the length of an array.
    pub fn arrayLen(self: *const TypeRegistry, idx: TypeIndex) u64 {
        const t = self.get(idx);
        return switch (t) {
            .array => |a| a.length,
            else => 0,
        };
    }

    /// Get the size of a type in bytes.
    pub fn sizeOf(self: *const TypeRegistry, idx: TypeIndex) u32 {
        // Handle untyped constants by defaulting to their concrete types
        // Following Go's pattern: untyped int defaults to int (64-bit), untyped float to float64
        if (idx == UNTYPED_INT) return 8; // Default to i64
        if (idx == UNTYPED_FLOAT) return 8; // Default to f64

        const t = self.get(idx);
        return switch (t) {
            .basic => |k| k.size(),
            .pointer => 8, // Assuming 64-bit
            .optional => 16, // ptr + tag (simplified)
            .slice => 16, // ptr + len
            .array => |a| @intCast(self.sizeOf(a.elem) * a.length),
            .map => 8, // pointer to runtime map
            .list => 8, // pointer to runtime list
            .struct_type => |s| s.size,
            .enum_type => |e| self.sizeOf(e.backing_type),
            .union_type => 24, // tag + max payload (simplified)
            .func => 8, // function pointer
        };
    }

    /// Get the alignment of a type in bytes.
    pub fn alignmentOf(self: *const TypeRegistry, idx: TypeIndex) u32 {
        const t = self.get(idx);
        return switch (t) {
            .basic => |k| if (k.size() == 0) 1 else k.size(),
            .pointer, .func => 8,
            .optional, .slice => 8,
            .array => |a| self.alignmentOf(a.elem),
            .map, .list => 8,
            .struct_type => |s| s.alignment,
            .enum_type => |e| self.alignmentOf(e.backing_type),
            .union_type => 8,
        };
    }

    /// Look up a basic type by name.
    pub fn lookupBasic(self: *const TypeRegistry, name: []const u8) ?TypeIndex {
        return self.name_map.get(name);
    }

    /// Check if two types are equal.
    pub fn equal(self: *const TypeRegistry, a: TypeIndex, b: TypeIndex) bool {
        if (a == b) return true;
        if (a == invalid_type or b == invalid_type) return false;

        const ta = self.get(a);
        const tb = self.get(b);

        // Both must be same kind
        if (@intFromEnum(ta) != @intFromEnum(tb)) return false;

        return switch (ta) {
            .basic => |ka| tb.basic == ka,
            .pointer => |pa| self.equal(pa.elem, tb.pointer.elem),
            .optional => |oa| self.equal(oa.elem, tb.optional.elem),
            .slice => |sa| self.equal(sa.elem, tb.slice.elem),
            .array => |aa| aa.length == tb.array.length and self.equal(aa.elem, tb.array.elem),
            .map => |ma| self.equal(ma.key, tb.map.key) and self.equal(ma.value, tb.map.value),
            .list => |la| self.equal(la.elem, tb.list.elem),
            .struct_type => |sa| std.mem.eql(u8, sa.name, tb.struct_type.name),
            .enum_type => |ea| std.mem.eql(u8, ea.name, tb.enum_type.name),
            .union_type => |ua| std.mem.eql(u8, ua.name, tb.union_type.name),
            .func => false, // Functions are equal only if same index
        };
    }

    /// Check if a value of type `from` can be assigned to a variable of type `to`.
    pub fn isAssignable(self: *const TypeRegistry, from: TypeIndex, to: TypeIndex) bool {
        if (from == to) return true;
        if (from == invalid_type or to == invalid_type) return true; // Error recovery

        const from_t = self.get(from);
        const to_t = self.get(to);

        // Untyped int -> any integer type
        if (from_t == .basic and from_t.basic == .untyped_int) {
            if (to_t == .basic and to_t.basic.isInteger()) return true;
        }

        // Untyped float -> any float type
        if (from_t == .basic and from_t.basic == .untyped_float) {
            if (to_t == .basic and to_t.basic.isFloat()) return true;
        }

        // Untyped bool -> bool
        if (from_t == .basic and from_t.basic == .untyped_bool) {
            if (to_t == .basic and to_t.basic == .bool_type) return true;
        }

        // Untyped null -> any optional type ?T or pointer *T
        if (from_t == .basic and from_t.basic == .untyped_null) {
            if (to_t == .optional) return true;
            if (to_t == .pointer) return true; // Pointers can be null (like Go)
        }

        // T -> ?T (wrap value in optional)
        if (to_t == .optional) {
            return self.isAssignable(from, to_t.optional.elem);
        }

        // Same numeric types
        if (from_t == .basic and to_t == .basic) {
            if (from_t.basic == to_t.basic) return true;
        }

        // Slices with same element type
        if (from_t == .slice and to_t == .slice) {
            return self.equal(from_t.slice.elem, to_t.slice.elem);
        }

        // Array to slice of same element type
        if (from_t == .array and to_t == .slice) {
            return self.equal(from_t.array.elem, to_t.slice.elem);
        }

        // Struct types (must be exactly equal)
        if (from_t == .struct_type and to_t == .struct_type) {
            return std.mem.eql(u8, from_t.struct_type.name, to_t.struct_type.name);
        }

        // Enum types
        if (from_t == .enum_type and to_t == .enum_type) {
            return std.mem.eql(u8, from_t.enum_type.name, to_t.enum_type.name);
        }

        // Pointer types
        if (from_t == .pointer and to_t == .pointer) {
            return self.equal(from_t.pointer.elem, to_t.pointer.elem);
        }

        // Array types - compare element type and length
        if (from_t == .array and to_t == .array) {
            return from_t.array.length == to_t.array.length and
                self.isAssignable(from_t.array.elem, to_t.array.elem);
        }

        // Function types - compare signatures
        if (from_t == .func and to_t == .func) {
            const from_func = from_t.func;
            const to_func = to_t.func;

            // Check parameter count
            if (from_func.params.len != to_func.params.len) return false;

            // Check each parameter type
            for (from_func.params, to_func.params) |from_param, to_param| {
                if (!self.equal(from_param.type_idx, to_param.type_idx)) return false;
            }

            // Check return type
            return self.equal(from_func.return_type, to_func.return_type);
        }

        return false;
    }
};

// =========================================
// Type Predicates (for checker)
// =========================================

/// Check if a type is numeric.
pub fn isNumeric(t: Type) bool {
    return switch (t) {
        .basic => |k| k.isNumeric(),
        else => false,
    };
}

/// Check if a type is an integer.
pub fn isInteger(t: Type) bool {
    return switch (t) {
        .basic => |k| k.isInteger(),
        else => false,
    };
}

/// Check if a type is a boolean.
pub fn isBool(t: Type) bool {
    return switch (t) {
        .basic => |k| k == .bool_type or k == .untyped_bool,
        else => false,
    };
}

/// Check if a type is untyped.
pub fn isUntyped(t: Type) bool {
    return switch (t) {
        .basic => |k| k.isUntyped(),
        else => false,
    };
}

// =========================================
// Tests
// =========================================

test "BasicKind predicates" {
    try std.testing.expect(BasicKind.i32_type.isInteger());
    try std.testing.expect(BasicKind.i32_type.isNumeric());
    try std.testing.expect(BasicKind.i32_type.isSigned());
    try std.testing.expect(!BasicKind.i32_type.isUnsigned());

    try std.testing.expect(BasicKind.u64_type.isInteger());
    try std.testing.expect(BasicKind.u64_type.isUnsigned());
    try std.testing.expect(!BasicKind.u64_type.isSigned());

    try std.testing.expect(BasicKind.f64_type.isFloat());
    try std.testing.expect(BasicKind.f64_type.isNumeric());

    try std.testing.expect(BasicKind.untyped_int.isUntyped());
    try std.testing.expect(BasicKind.untyped_int.isInteger());
}

test "BasicKind size" {
    try std.testing.expectEqual(@as(u8, 1), BasicKind.bool_type.size());
    try std.testing.expectEqual(@as(u8, 1), BasicKind.i8_type.size());
    try std.testing.expectEqual(@as(u8, 4), BasicKind.i32_type.size());
    try std.testing.expectEqual(@as(u8, 8), BasicKind.i64_type.size());
    try std.testing.expectEqual(@as(u8, 8), BasicKind.f64_type.size());
}

test "TypeRegistry init and lookup" {
    var reg = try TypeRegistry.init(std.testing.allocator);
    defer reg.deinit();

    // Check basic types are registered
    try std.testing.expectEqual(TypeRegistry.BOOL, reg.lookupByName("bool").?);
    try std.testing.expectEqual(TypeRegistry.I64, reg.lookupByName("i64").?);
    try std.testing.expectEqual(TypeRegistry.I64, reg.lookupByName("int").?);
    try std.testing.expectEqual(TypeRegistry.STRING, reg.lookupByName("string").?);

    // Check type retrieval
    const bool_type = reg.get(TypeRegistry.BOOL);
    try std.testing.expect(bool_type == .basic);
    try std.testing.expectEqual(BasicKind.bool_type, bool_type.basic);
}

test "TypeRegistry make composite types" {
    var reg = try TypeRegistry.init(std.testing.allocator);
    defer reg.deinit();

    // Make pointer type
    const ptr_i32 = try reg.makePointer(TypeRegistry.I32);
    const ptr_type = reg.get(ptr_i32);
    try std.testing.expect(ptr_type == .pointer);
    try std.testing.expectEqual(TypeRegistry.I32, ptr_type.pointer.elem);

    // Make slice type
    const slice_u8 = try reg.makeSlice(TypeRegistry.U8);
    const slice_type = reg.get(slice_u8);
    try std.testing.expect(slice_type == .slice);
    try std.testing.expectEqual(TypeRegistry.U8, slice_type.slice.elem);

    // Make array type
    const arr_10_i32 = try reg.makeArray(TypeRegistry.I32, 10);
    const arr_type = reg.get(arr_10_i32);
    try std.testing.expect(arr_type == .array);
    try std.testing.expectEqual(@as(u64, 10), arr_type.array.length);
}

test "Type predicates" {
    try std.testing.expect(isNumeric(.{ .basic = .i32_type }));
    try std.testing.expect(isNumeric(.{ .basic = .f64_type }));
    try std.testing.expect(!isNumeric(.{ .basic = .bool_type }));

    try std.testing.expect(isInteger(.{ .basic = .i32_type }));
    try std.testing.expect(!isInteger(.{ .basic = .f64_type }));

    try std.testing.expect(isBool(.{ .basic = .bool_type }));
    try std.testing.expect(isBool(.{ .basic = .untyped_bool }));
    try std.testing.expect(!isBool(.{ .basic = .i32_type }));

    try std.testing.expect(isUntyped(.{ .basic = .untyped_int }));
    try std.testing.expect(!isUntyped(.{ .basic = .i32_type }));
}

test "TypeRegistry sizeOf" {
    var reg = try TypeRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expectEqual(@as(u32, 1), reg.sizeOf(TypeRegistry.BOOL));
    try std.testing.expectEqual(@as(u32, 4), reg.sizeOf(TypeRegistry.I32));
    try std.testing.expectEqual(@as(u32, 8), reg.sizeOf(TypeRegistry.I64));
    try std.testing.expectEqual(@as(u32, 8), reg.sizeOf(TypeRegistry.F64));
    try std.testing.expectEqual(@as(u32, 16), reg.sizeOf(TypeRegistry.STRING)); // slice = ptr + len
}

test "invalid_type" {
    try std.testing.expectEqual(std.math.maxInt(u32), invalid_type);
}

//! SSA Value representation.
//!
//! Go reference: [cmd/compile/internal/ssa/value.go]
//!
//! A Value represents the result of an SSA operation. Each Value has:
//! - An operation type ([Op]) that defines what it computes
//! - A result type
//! - Zero or more argument Values
//! - A use count tracking how many other Values reference it
//!
//! ## Critical Invariants
//!
//! **Use count tracking** is essential for:
//! - Dead code elimination (uses == 0 → removable)
//! - Register allocation decisions
//! - Constant pool deduplication
//!
//! Always use [Value.addArg] to add arguments - never modify `args` directly!
//!
//! ## Related Modules
//!
//! - [Block] - Contains Values in a basic block
//! - [Func] - Allocates and manages Values
//! - [Op] - Operation types that Values compute
//! - [compile.zig] - Passes that transform Values
//!
//! ## Example
//!
//! ```zig
//! // Create an add operation: v3 = add v1, v2
//! const v3 = try func.newValue(.add, type_int, block, pos);
//! v3.addArg2(v1, v2);  // Increments v1.uses and v2.uses
//! ```

const std = @import("std");
const types = @import("../core/types.zig");
const Op = @import("op.zig").Op;
const abi = @import("abi.zig");

const ID = types.ID;
const TypeIndex = types.TypeIndex;
const Pos = types.Pos;
const INVALID_ID = types.INVALID_ID;

/// Symbol with offset - used for addressing modes.
/// Go reference: cmd/compile/internal/ssa/value.go auxSymOff
pub const SymbolOff = struct {
    sym: ?*anyopaque = null,
    offset: i64 = 0,
};

/// Comparison operation for conditional branches.
pub const CondCode = enum(u8) {
    eq, // Equal
    ne, // Not equal
    lt, // Less than (signed)
    le, // Less or equal (signed)
    gt, // Greater than (signed)
    ge, // Greater or equal (signed)
    ult, // Less than (unsigned)
    ule, // Less or equal (unsigned)
    ugt, // Greater than (unsigned)
    uge, // Greater or equal (unsigned)
};

/// Auxiliary data attached to a Value.
/// The meaning depends on the Op type.
/// Go reference: cmd/compile/internal/ssa/value.go Aux interface
pub const Aux = union(enum) {
    none,
    string: []const u8,
    symbol: ?*anyopaque, // Symbol reference
    symbol_off: SymbolOff, // Symbol + offset (for addressing)
    call: *AuxCall,
    type_ref: TypeIndex,
    cond: CondCode, // Condition code for conditional ops
};

/// Auxiliary data for function calls.
/// Contains ABI information used by register allocation.
///
/// Reference: Go's ssa/op.go:118-122
pub const AuxCall = struct {
    /// Function name (for relocations/debugging)
    fn_name: []const u8 = "",

    /// Function symbol (null for indirect calls)
    func_sym: ?*anyopaque = null,

    /// ABI information describing how parameters and results are passed.
    /// Points to static ABI info (e.g., abi.str_concat_abi) or dynamically allocated.
    abi_info: ?*const abi.ABIParamResultInfo = null,

    /// Lazily-computed register info for regalloc.
    /// Computed on first call to getRegInfo().
    reg_info: ?abi.RegInfo = null,

    /// Allocator for dynamic reg_info allocation
    allocator: ?std.mem.Allocator = null,

    /// Initialize an empty AuxCall
    pub fn init(alloc: std.mem.Allocator) AuxCall {
        return .{
            .allocator = alloc,
        };
    }

    /// Get the RegInfo for this call, computing it lazily if needed.
    /// This is the key method called by register allocation.
    ///
    /// Reference: Go's ssa/op.go AuxCall.Reg() (lines 134-167)
    pub fn getRegInfo(self: *AuxCall) !*const abi.RegInfo {
        if (self.reg_info) |*ri| {
            return ri;
        }

        if (self.abi_info) |abi_info| {
            if (self.allocator) |alloc| {
                self.reg_info = try abi.buildCallRegInfo(alloc, abi_info);
                return &self.reg_info.?;
            }
        }

        // No ABI info - return empty RegInfo
        return &abi.RegInfo.empty;
    }

    /// Get the registers used for input argument N
    pub fn regsOfArg(self: *const AuxCall, which: usize) []const abi.RegIndex {
        if (self.abi_info) |info| {
            return info.regsOfArg(which);
        }
        return &[_]abi.RegIndex{};
    }

    /// Get the registers used for output result N
    pub fn regsOfResult(self: *const AuxCall, which: usize) []const abi.RegIndex {
        if (self.abi_info) |info| {
            return info.regsOfResult(which);
        }
        return &[_]abi.RegIndex{};
    }

    /// Check if this call uses hidden return pointer (>16B return)
    /// Go reference: aux.abiInfo.usesHiddenReturn
    pub fn usesHiddenReturn(self: *const AuxCall) bool {
        if (self.abi_info) |info| {
            return info.uses_hidden_return;
        }
        return false;
    }

    /// Get the hidden return size (0 if not using hidden return)
    /// Go reference: aux.abiInfo.hiddenReturnSize
    pub fn hiddenReturnSize(self: *const AuxCall) u32 {
        if (self.abi_info) |info| {
            return info.hidden_return_size;
        }
        return 0;
    }

    /// Get stack offset for argument N
    /// Go reference: AuxCall.OffsetOfArg
    pub fn offsetOfArg(self: *const AuxCall, which: usize) i32 {
        if (self.abi_info) |info| {
            return info.offsetOfArg(which);
        }
        return 0;
    }

    /// Get stack offset for result N
    /// Go reference: AuxCall.OffsetOfResult
    pub fn offsetOfResult(self: *const AuxCall, which: usize) i32 {
        if (self.abi_info) |info| {
            return info.offsetOfResult(which);
        }
        return 0;
    }

    /// Create AuxCall for __cot_str_concat
    pub fn strConcat(allocator: std.mem.Allocator) AuxCall {
        return .{
            .fn_name = "__cot_str_concat",
            .abi_info = &abi.str_concat_abi,
            .allocator = allocator,
        };
    }
};

/// SSA Value - represents a single operation's result.
///
/// Go reference: cmd/compile/internal/ssa/value.go lines 20-50
pub const Value = struct {
    /// Unique ID within function, densely allocated starting at 1
    id: ID = INVALID_ID,

    /// Operation type - defines what this value computes
    op: Op = .invalid,

    /// Result type - CRITICAL for instruction selection
    /// Use type.size() to select ldrb/ldrh/ldr/etc.
    type_idx: TypeIndex = 0,

    /// Integer auxiliary data:
    /// - For constants: the constant value (floats via @bitCast)
    /// - For loads/stores: offset
    /// - For calls: stack adjustment
    /// Sign-extended even for unsigned values
    aux_int: i64 = 0,

    /// Generic auxiliary data
    aux: Aux = .none,

    /// For calls: ABI information for register allocation.
    /// Computed by expand_calls pass, used by regalloc.
    /// Reference: Go's ssa/op.go AuxCall
    aux_call: ?*AuxCall = null,

    /// Arguments to this operation.
    /// Length determined by Op's argLen property.
    /// For small arg counts (<=3), slices into args_storage.
    /// For larger counts, dynamically allocated.
    args: []*Value = &.{},

    /// Inline storage for first 3 args (optimization).
    /// Go reference: Same pattern in value.go argstorage
    args_storage: [3]*Value = undefined,

    /// True if args points to dynamically allocated memory
    args_dynamic: bool = false,

    /// Containing basic block
    block: ?*Block = null,

    /// Source position for debugging/error messages
    pos: Pos = .{},

    /// Usage count - CRITICAL for optimization.
    /// Incremented when added to Args or Block.Controls.
    /// When 0, value can be eliminated.
    uses: i32 = 0,

    /// True if in function's constant cache.
    /// Must clear before modifying value.
    in_cache: bool = false,

    /// For free list linking when value is recycled
    next_free: ?*Value = null,

    /// Capacity of dynamically allocated args array.
    /// Only valid when args_dynamic is true.
    args_capacity: usize = 0,

    // =========================================
    // Methods
    // =========================================

    /// Initialize value with inline arg storage
    pub fn init(id: ID, op: Op, type_idx: TypeIndex, block: ?*Block, pos: Pos) Value {
        return .{
            .id = id,
            .op = op,
            .type_idx = type_idx,
            .block = block,
            .pos = pos,
        };
    }

    /// Add a single argument, incrementing its use count.
    /// CRITICAL: Always use this instead of directly modifying args!
    /// For >3 args, requires allocator (get from block.func.allocator).
    pub fn addArg(self: *Value, arg: *Value) void {
        self.addArgAlloc(arg, null) catch @panic("addArg failed: need allocator for >3 args");
    }

    /// Add argument with optional allocator for dynamic allocation.
    /// Go reference: cmd/compile/internal/ssa/value.go AddArg
    pub fn addArgAlloc(self: *Value, arg: *Value, allocator: ?std.mem.Allocator) !void {
        arg.uses += 1;
        const count = self.args.len;

        if (count < 3) {
            // Use inline storage
            self.args_storage[count] = arg;
            self.args = self.args_storage[0 .. count + 1];
        } else if (!self.args_dynamic) {
            // Transition from inline to dynamic storage (count == 3)
            const alloc = allocator orelse {
                // Try to get allocator from block's function
                if (self.block) |b| {
                    return self.transitionToDynamic(arg, b.func.allocator);
                }
                return error.NeedAllocator;
            };
            return self.transitionToDynamic(arg, alloc);
        } else {
            // Already dynamic, grow the slice
            const alloc = allocator orelse {
                if (self.block) |b| {
                    return self.growDynamicArgs(arg, b.func.allocator);
                }
                return error.NeedAllocator;
            };
            return self.growDynamicArgs(arg, alloc);
        }
    }

    fn transitionToDynamic(self: *Value, arg: *Value, allocator: std.mem.Allocator) !void {
        // Allocate new array and copy existing args from inline storage
        const new_cap: usize = 8; // Start with capacity 8
        const new_args = try allocator.alloc(*Value, new_cap);
        @memcpy(new_args[0..3], self.args_storage[0..3]);
        new_args[3] = arg;
        self.args = new_args[0..4];
        self.args_capacity = new_cap;
        self.args_dynamic = true;
    }

    fn growDynamicArgs(self: *Value, arg: *Value, allocator: std.mem.Allocator) !void {
        const old_len = self.args.len;
        const old_cap = self.args_capacity;

        if (old_len < old_cap) {
            // Have capacity, just extend
            // We need to use the original pointer with full capacity
            const full_slice = self.args.ptr[0..old_cap];
            full_slice[old_len] = arg;
            self.args = full_slice[0 .. old_len + 1];
        } else {
            // Need to reallocate
            const new_cap = if (old_cap == 0) 8 else old_cap * 2;
            const new_args = try allocator.alloc(*Value, new_cap);
            @memcpy(new_args[0..old_len], self.args);
            new_args[old_len] = arg;

            // Free old dynamic allocation if it exists
            if (old_cap > 0) {
                const old_slice = self.args.ptr[0..old_cap];
                allocator.free(old_slice);
            }

            self.args = new_args[0 .. old_len + 1];
            self.args_capacity = new_cap;
        }
    }

    /// Add two arguments
    pub fn addArg2(self: *Value, arg0: *Value, arg1: *Value) void {
        self.addArg(arg0);
        self.addArg(arg1);
    }

    /// Add three arguments
    pub fn addArg3(self: *Value, arg0: *Value, arg1: *Value, arg2: *Value) void {
        self.addArg(arg0);
        self.addArg(arg1);
        self.addArg(arg2);
    }

    /// Add multiple arguments at once (efficient for phi nodes).
    pub fn addArgs(self: *Value, new_args: []const *Value, allocator: std.mem.Allocator) !void {
        for (new_args) |arg| {
            try self.addArgAlloc(arg, allocator);
        }
    }

    /// Set argument at index, handling use counts.
    pub fn setArg(self: *Value, idx: usize, new_arg: *Value) void {
        if (idx < self.args.len) {
            // Decrement old use count
            self.args[idx].uses -= 1;
        }
        new_arg.uses += 1;
        self.args[idx] = new_arg;
    }

    /// Reset all arguments, decrementing use counts.
    /// Note: Does not free dynamic memory (owned by function's arena).
    pub fn resetArgs(self: *Value) void {
        for (self.args) |arg| {
            arg.uses -= 1;
        }
        self.args = &.{};
        self.args_dynamic = false;
        self.args_capacity = 0;
    }

    /// Reset args and free dynamic memory if allocator provided.
    pub fn resetArgsFree(self: *Value, allocator: ?std.mem.Allocator) void {
        for (self.args) |arg| {
            arg.uses -= 1;
        }
        if (self.args_dynamic and self.args_capacity > 0) {
            if (allocator) |alloc| {
                // Get the full allocation using tracked capacity
                const full_slice = self.args.ptr[0..self.args_capacity];
                alloc.free(full_slice);
            }
        }
        self.args = &.{};
        self.args_dynamic = false;
        self.args_capacity = 0;
    }

    /// Get number of arguments
    pub fn argsLen(self: *const Value) usize {
        return self.args.len;
    }

    /// Check if value is a constant
    pub fn isConst(self: *const Value) bool {
        return switch (self.op) {
            .const_int, .const_bool, .const_nil, .const_string => true,
            else => false,
        };
    }

    /// Check if value is rematerializable (can recompute cheaply)
    pub fn isRematerializable(self: *const Value) bool {
        return self.op.info().rematerializable;
    }

    /// Check if value has side effects (can't be eliminated even if unused)
    pub fn hasSideEffects(self: *const Value) bool {
        return self.op.info().has_side_effects;
    }

    /// Check if this value reads memory
    pub fn readsMemory(self: *const Value) bool {
        return self.op.info().reads_memory;
    }

    /// Check if this value writes memory
    pub fn writesMemory(self: *const Value) bool {
        return self.op.info().writes_memory;
    }

    /// Get memory argument (last arg for memory-reading ops)
    pub fn memoryArg(self: *const Value) ?*Value {
        if (!self.readsMemory()) return null;
        if (self.args.len == 0) return null;
        return self.args[self.args.len - 1];
    }

    /// Format for debugging
    pub fn format(
        self: *const Value,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("v{d} = {s}", .{ self.id, @tagName(self.op) });
        if (self.args.len > 0) {
            try writer.writeAll(" ");
            for (self.args, 0..) |arg, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("v{d}", .{arg.id});
            }
        }
        if (self.aux_int != 0) {
            try writer.print(" [{d}]", .{self.aux_int});
        }
    }

    // =========================================
    // Register Allocation Access (Go pattern)
    // Go reference: cmd/compile/internal/ssa/value.go Reg() method
    // =========================================

    /// Get the register number assigned to this value.
    /// Panics if the value is not assigned to a register.
    /// Go reference: cmd/compile/internal/ssa/value.go Reg()
    pub fn getReg(self: *const Value) u8 {
        const loc = self.getHome() orelse @panic("Value.getReg: no location assigned");
        return loc.reg();
    }

    /// Get the register number if this value is in a register, null otherwise.
    pub fn regOrNull(self: *const Value) ?u8 {
        const loc = self.getHome() orelse return null;
        return switch (loc) {
            .register => |r| r,
            .stack => null,
        };
    }

    /// Get the location (register or stack) for this value.
    /// Returns null if no location has been assigned.
    pub fn getHome(self: *const Value) ?Location {
        const b = self.block orelse return null;
        return b.func.getHome(self.id);
    }

    /// Check if this value has a register assigned.
    pub fn hasReg(self: *const Value) bool {
        const loc = self.getHome() orelse return false;
        return loc.isReg();
    }
};

/// Forward declarations
pub const Block = @import("block.zig").Block;
const func_mod = @import("func.zig");
pub const Func = func_mod.Func;
pub const Location = func_mod.Location;

// =========================================
// Tests
// =========================================

test "Value creation" {
    var v = Value.init(1, .const_int, 0, null, .{});
    v.aux_int = 42;

    try std.testing.expectEqual(@as(ID, 1), v.id);
    try std.testing.expectEqual(Op.const_int, v.op);
    try std.testing.expectEqual(@as(i64, 42), v.aux_int);
    try std.testing.expectEqual(@as(i32, 0), v.uses);
}

test "Value use count tracking" {
    var v1 = Value.init(1, .const_int, 0, null, .{});
    var v2 = Value.init(2, .const_int, 0, null, .{});
    var v3 = Value.init(3, .add, 0, null, .{});

    // Add arguments - should increment use counts
    v3.addArg(&v1);
    v3.addArg(&v2);

    try std.testing.expectEqual(@as(i32, 1), v1.uses);
    try std.testing.expectEqual(@as(i32, 1), v2.uses);
    try std.testing.expectEqual(@as(usize, 2), v3.argsLen());

    // Reset args - should decrement use counts
    v3.resetArgs();

    try std.testing.expectEqual(@as(i32, 0), v1.uses);
    try std.testing.expectEqual(@as(i32, 0), v2.uses);
    try std.testing.expectEqual(@as(usize, 0), v3.argsLen());
}

test "Value setArg replaces correctly" {
    var v1 = Value.init(1, .const_int, 0, null, .{});
    var v2 = Value.init(2, .const_int, 0, null, .{});
    var v3 = Value.init(3, .add, 0, null, .{});

    v3.addArg(&v1);
    try std.testing.expectEqual(@as(i32, 1), v1.uses);

    // Replace v1 with v2
    v3.setArg(0, &v2);
    try std.testing.expectEqual(@as(i32, 0), v1.uses);
    try std.testing.expectEqual(@as(i32, 1), v2.uses);
}

test "Value isConst" {
    var v1 = Value.init(1, .const_int, 0, null, .{});
    var v2 = Value.init(2, .add, 0, null, .{});

    try std.testing.expect(v1.isConst());
    try std.testing.expect(!v2.isConst());
}

test "Value dynamic argument allocation" {
    const allocator = std.testing.allocator;

    // Create values
    var args: [6]Value = undefined;
    for (&args, 0..) |*arg, i| {
        arg.* = Value.init(@intCast(i + 1), .const_int, 0, null, .{});
    }

    // Create a phi node that needs >3 args
    var phi = Value.init(10, .phi, 0, null, .{});

    // Add first 3 args (uses inline storage)
    try phi.addArgAlloc(&args[0], allocator);
    try phi.addArgAlloc(&args[1], allocator);
    try phi.addArgAlloc(&args[2], allocator);
    try std.testing.expectEqual(@as(usize, 3), phi.argsLen());
    try std.testing.expect(!phi.args_dynamic);

    // Add 4th arg - triggers dynamic allocation
    try phi.addArgAlloc(&args[3], allocator);
    try std.testing.expectEqual(@as(usize, 4), phi.argsLen());
    try std.testing.expect(phi.args_dynamic);

    // Add more args
    try phi.addArgAlloc(&args[4], allocator);
    try phi.addArgAlloc(&args[5], allocator);
    try std.testing.expectEqual(@as(usize, 6), phi.argsLen());

    // Verify use counts
    for (&args) |*arg| {
        try std.testing.expectEqual(@as(i32, 1), arg.uses);
    }

    // Clean up
    phi.resetArgsFree(allocator);
    try std.testing.expectEqual(@as(usize, 0), phi.argsLen());

    // Verify use counts decremented
    for (&args) |*arg| {
        try std.testing.expectEqual(@as(i32, 0), arg.uses);
    }
}

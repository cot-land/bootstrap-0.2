//! ABI (Application Binary Interface) structures for function calls.
//!
//! Based on Go's implementation in:
//! - cmd/compile/internal/abi/abiutils.go
//! - cmd/compile/internal/ssa/op.go (AuxCall)
//!
//! This module defines how function parameters and results are passed
//! between caller and callee, following the ARM64 calling convention.
//!
//! ## The Key Guarantee
//!
//! Both caller and callee independently analyze the same function type
//! using identical rules (analyzeFunc), producing identical results.
//! This eliminates coordination bugs between expand_calls and codegen.

const std = @import("std");
const types = @import("../frontend/types.zig");
const TypeRegistry = types.TypeRegistry;
const TypeIndex = types.TypeIndex;
const FuncType = types.FuncType;
const debug = @import("../pipeline_debug.zig");

/// RegIndex stores the index into the set of machine registers used by
/// the ABI for parameter passing. For ARM64:
/// - Values 0-7 are integer registers (x0-x7)
/// - Values 8+ would be floating point registers (not yet implemented)
///
/// Reference: Go's abi/abiutils.go:83-92
pub const RegIndex = u8;

/// RegMask is a bitmask of registers. Bit N corresponds to register N.
/// Used by regalloc to track which registers are available/required.
pub const RegMask = u32;

/// ARM64 calling convention constants.
/// Reference: ARM64 Procedure Call Standard (AAPCS64)
pub const ARM64 = struct {
    /// Number of integer registers for parameter passing (x0-x7)
    pub const int_param_regs: u8 = 8;

    /// Number of integer registers for return values (x0-x1)
    pub const int_result_regs: u8 = 2;

    /// Maximum aggregate size that fits in registers (16 bytes = 2 x 8-byte regs)
    pub const max_reg_aggregate: u32 = 16;

    /// Stack alignment
    pub const stack_align: u32 = 16;

    /// Register size in bytes
    pub const reg_size: u32 = 8;

    /// Hidden return pointer register
    pub const hidden_ret_reg: u5 = 8; // x8

    /// Integer parameter register list
    pub const param_regs = [_]RegIndex{ 0, 1, 2, 3, 4, 5, 6, 7 };

    /// Caller-saved registers: x0-x17 (bits 0-17)
    /// These may be clobbered by any function call.
    pub const caller_save_mask: RegMask = 0x3FFFF; // bits 0-17

    /// Argument registers: x0-x7 (bits 0-7)
    pub const arg_regs_mask: RegMask = 0xFF; // bits 0-7

    /// Convert RegIndex to actual ARM64 register number
    pub fn regIndexToArm64(idx: RegIndex) u5 {
        // For now, integer regs map directly: RegIndex 0 = x0, etc.
        return @intCast(idx);
    }

    /// Convert ARM64 register number to RegIndex
    pub fn arm64ToRegIndex(reg: u5) RegIndex {
        return @intCast(reg);
    }

    /// Get register mask for a single register
    pub fn regMask(reg: u5) RegMask {
        return @as(RegMask, 1) << reg;
    }
};

/// ABIParamAssignment holds information about how a specific parameter or
/// result will be passed: in registers (Registers populated) or on the
/// stack (offset set).
///
/// Reference: Go's abi/abiutils.go:99-104
pub const ABIParamAssignment = struct {
    /// Type of the parameter
    type_idx: TypeIndex,

    /// Registers used for this parameter (empty = stack)
    /// For multi-register values (like strings), contains multiple indices.
    registers: []const RegIndex,

    /// Stack offset if not in registers, or spill offset for register params
    offset: i32,

    /// Size of this parameter in bytes
    size: u32 = 0,

    /// Create a register-passed parameter
    pub fn inRegs(type_idx: TypeIndex, regs: []const RegIndex) ABIParamAssignment {
        return .{
            .type_idx = type_idx,
            .registers = regs,
            .offset = 0,
            .size = @as(u32, @intCast(regs.len)) * 8, // Each reg is 8 bytes
        };
    }

    /// Create a stack-passed parameter
    pub fn onStack(type_idx: TypeIndex, offset: i32, size: u32) ABIParamAssignment {
        return .{
            .type_idx = type_idx,
            .registers = &[_]RegIndex{},
            .offset = offset,
            .size = size,
        };
    }

    /// Check if this parameter is passed in registers
    pub fn isRegister(self: ABIParamAssignment) bool {
        return self.registers.len > 0;
    }

    /// Check if this parameter is passed on stack
    pub fn isStack(self: ABIParamAssignment) bool {
        return self.registers.len == 0;
    }
};

/// ABIParamResultInfo describes the complete ABI for a function call:
/// how all parameters are passed and how results are returned.
///
/// This is THE source of truth for ABI decisions. Both expand_calls
/// and codegen MUST use the same ABIParamResultInfo.
///
/// Reference: Go's abi/abiutils.go:29-37
pub const ABIParamResultInfo = struct {
    /// How each input parameter is passed
    in_params: []const ABIParamAssignment,

    /// How each output/result is returned
    out_params: []const ABIParamAssignment,

    /// Total number of registers used for inputs
    in_registers_used: u32,

    /// Total number of registers used for outputs
    out_registers_used: u32,

    /// True if this function returns via hidden pointer (>16B return)
    uses_hidden_return: bool = false,

    /// Size of hidden return in bytes (0 if not used)
    hidden_return_size: u32 = 0,

    // ========================================
    // Accessor Methods (Go's OffsetOfResult, etc.)
    // ========================================

    /// Get the Nth input parameter assignment
    pub fn inParam(self: *const ABIParamResultInfo, n: usize) ABIParamAssignment {
        if (n >= self.in_params.len) return ABIParamAssignment{ .type_idx = types.invalid_type, .registers = &[_]RegIndex{}, .offset = 0, .size = 0 };
        return self.in_params[n];
    }

    /// Get the Nth output parameter assignment
    pub fn outParam(self: *const ABIParamResultInfo, n: usize) ABIParamAssignment {
        if (n >= self.out_params.len) return ABIParamAssignment{ .type_idx = types.invalid_type, .registers = &[_]RegIndex{}, .offset = 0, .size = 0 };
        return self.out_params[n];
    }

    /// Get registers used by input parameter N
    /// Go reference: AuxCall.RegsOfArg
    pub fn regsOfArg(self: *const ABIParamResultInfo, n: usize) []const RegIndex {
        if (n >= self.in_params.len) return &[_]RegIndex{};
        return self.in_params[n].registers;
    }

    /// Get registers used by output parameter N
    /// Go reference: AuxCall.RegsOfResult
    pub fn regsOfResult(self: *const ABIParamResultInfo, n: usize) []const RegIndex {
        if (n >= self.out_params.len) return &[_]RegIndex{};
        return self.out_params[n].registers;
    }

    /// Get stack offset for argument N
    /// Go reference: AuxCall.OffsetOfArg
    pub fn offsetOfArg(self: *const ABIParamResultInfo, n: usize) i32 {
        if (n >= self.in_params.len) return 0;
        return self.in_params[n].offset;
    }

    /// Get stack offset for result N
    /// Go reference: AuxCall.OffsetOfResult
    pub fn offsetOfResult(self: *const ABIParamResultInfo, n: usize) i32 {
        if (n >= self.out_params.len) return 0;
        return self.out_params[n].offset;
    }

    /// Get type of argument N
    pub fn typeOfArg(self: *const ABIParamResultInfo, n: usize) TypeIndex {
        if (n >= self.in_params.len) return types.invalid_type;
        return self.in_params[n].type_idx;
    }

    /// Get type of result N
    pub fn typeOfResult(self: *const ABIParamResultInfo, n: usize) TypeIndex {
        if (n >= self.out_params.len) return types.invalid_type;
        return self.out_params[n].type_idx;
    }

    /// Number of input parameters
    pub fn numArgs(self: *const ABIParamResultInfo) usize {
        return self.in_params.len;
    }

    /// Number of output results
    pub fn numResults(self: *const ABIParamResultInfo) usize {
        return self.out_params.len;
    }

    /// Total stack width for arguments
    /// Go reference: ABIParamResultInfo.ArgWidth
    pub fn argWidth(self: *const ABIParamResultInfo) u32 {
        var max_offset: u32 = 0;
        for (self.in_params) |p| {
            if (p.isStack()) {
                const end = @as(u32, @intCast(@max(0, p.offset))) + p.size;
                if (end > max_offset) max_offset = end;
            }
        }
        return alignUp(max_offset, ARM64.stack_align);
    }

    /// Debug print
    pub fn dump(self: *const ABIParamResultInfo) void {
        debug.log(.abi, "ABIParamResultInfo:", .{});
        debug.log(.abi, "  in_params ({d}):", .{self.in_params.len});
        for (self.in_params, 0..) |p, i| {
            if (p.registers.len > 0) {
                debug.log(.abi, "    [{d}] size={d} regs={any}", .{ i, p.size, p.registers });
            } else {
                debug.log(.abi, "    [{d}] size={d} stack_off={d}", .{ i, p.size, p.offset });
            }
        }
        debug.log(.abi, "  out_params ({d}):", .{self.out_params.len});
        for (self.out_params, 0..) |p, i| {
            if (p.registers.len > 0) {
                debug.log(.abi, "    [{d}] size={d} regs={any}", .{ i, p.size, p.registers });
            } else {
                debug.log(.abi, "    [{d}] size={d} stack_off={d}", .{ i, p.size, p.offset });
            }
        }
        debug.log(.abi, "  uses_hidden_return={}, hidden_size={d}", .{ self.uses_hidden_return, self.hidden_return_size });
        debug.log(.abi, "  in_regs={d}, out_regs={d}", .{ self.in_registers_used, self.out_registers_used });
    }
};

/// InputInfo describes register requirements for one input to an operation.
/// Used by register allocator to know which register(s) an argument must be in.
///
/// Reference: Go's ssa/op.go regInfo.inputs
pub const InputInfo = struct {
    /// Index into the operation's arguments
    idx: u8,

    /// Bitmask of acceptable registers (usually just one bit set for calls)
    regs: RegMask,
};

/// OutputInfo describes register allocation for one output of an operation.
///
/// Reference: Go's ssa/op.go regInfo.outputs
pub const OutputInfo = struct {
    /// Index of this output (for multi-return)
    idx: u8,

    /// Bitmask of acceptable registers for this output
    regs: RegMask,
};

/// RegInfo describes the register requirements and effects of an operation.
/// For calls, this is computed dynamically from ABIParamResultInfo.
///
/// Reference: Go's ssa/op.go:50-56
pub const RegInfo = struct {
    /// Register requirements for each input argument
    inputs: []const InputInfo,

    /// Register assignments for each output
    outputs: []const OutputInfo,

    /// Registers clobbered by this operation
    clobbers: RegMask,

    /// Empty RegInfo (for operations with no register constraints)
    pub const empty = RegInfo{
        .inputs = &[_]InputInfo{},
        .outputs = &[_]OutputInfo{},
        .clobbers = 0,
    };
};

/// Build RegInfo from ABIParamResultInfo for a function call.
/// This is the key function that generates register constraints dynamically.
///
/// Reference: Go's ssa/op.go AuxCall.Reg() (lines 134-167)
pub fn buildCallRegInfo(
    allocator: std.mem.Allocator,
    abi_info: *const ABIParamResultInfo,
) !RegInfo {
    var inputs = std.ArrayList(InputInfo).init(allocator);
    var outputs = std.ArrayList(OutputInfo).init(allocator);

    // Build input constraints: each register-passed arg needs specific register
    var arg_idx: u8 = 0;
    for (abi_info.in_params) |param| {
        for (param.registers) |reg_idx| {
            const arm64_reg = ARM64.regIndexToArm64(reg_idx);
            try inputs.append(.{
                .idx = arg_idx,
                .regs = ARM64.regMask(arm64_reg),
            });
            arg_idx += 1;
        }
    }

    // Build output constraints
    var out_idx: u8 = 0;
    for (abi_info.out_params) |param| {
        for (param.registers) |reg_idx| {
            const arm64_reg = ARM64.regIndexToArm64(reg_idx);
            try outputs.append(.{
                .idx = out_idx,
                .regs = ARM64.regMask(arm64_reg),
            });
            out_idx += 1;
        }
    }

    return .{
        .inputs = try inputs.toOwnedSlice(),
        .outputs = try outputs.toOwnedSlice(),
        .clobbers = ARM64.caller_save_mask,
    };
}

// ============================================================================
// Pre-built ABI info for common runtime calls
// ============================================================================

/// ABI info for __cot_str_concat(ptr1, len1, ptr2, len2) -> (ptr, len)
/// Input: x0=ptr1, x1=len1, x2=ptr2, x3=len2
/// Output: x0=ptr, x1=len
pub const str_concat_abi = ABIParamResultInfo{
    .in_params = &[_]ABIParamAssignment{
        ABIParamAssignment.inRegs(TypeRegistry.I64, &[_]RegIndex{0}), // ptr1 in x0
        ABIParamAssignment.inRegs(TypeRegistry.I64, &[_]RegIndex{1}), // len1 in x1
        ABIParamAssignment.inRegs(TypeRegistry.I64, &[_]RegIndex{2}), // ptr2 in x2
        ABIParamAssignment.inRegs(TypeRegistry.I64, &[_]RegIndex{3}), // len2 in x3
    },
    .out_params = &[_]ABIParamAssignment{
        ABIParamAssignment.inRegs(TypeRegistry.I64, &[_]RegIndex{0}), // ptr in x0
        ABIParamAssignment.inRegs(TypeRegistry.I64, &[_]RegIndex{1}), // len in x1
    },
    .in_registers_used = 4,
    .out_registers_used = 2,
};

// ============================================================================
// Debug formatting
// ============================================================================

pub fn formatRegMask(mask: RegMask) [32]u8 {
    var buf: [32]u8 = undefined;
    var pos: usize = 0;
    var m = mask;
    var reg: u5 = 0;
    while (m != 0) : (reg += 1) {
        if (m & 1 != 0) {
            if (pos > 0 and pos < 30) {
                buf[pos] = ',';
                pos += 1;
            }
            if (pos < 29) {
                buf[pos] = 'x';
                pos += 1;
                if (reg >= 10) {
                    buf[pos] = '0' + (reg / 10);
                    pos += 1;
                }
                buf[pos] = '0' + (reg % 10);
                pos += 1;
            }
        }
        m >>= 1;
    }
    buf[pos] = 0;
    return buf;
}

// ============================================================================
// ABI Analysis Functions
// Go reference: cmd/compile/internal/abi/abiutils.go ABIAnalyzeFuncType
// ============================================================================

/// Assignment state used during ABI analysis
const AssignState = struct {
    int_reg_idx: usize, // Next integer register to use
    stack_offset: u32, // Next stack offset
    spill_offset: u32, // Next spill offset (for reg params)
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) AssignState {
        return .{
            .int_reg_idx = 0,
            .stack_offset = 0,
            .spill_offset = 0,
            .allocator = allocator,
        };
    }

    /// Reset register counters (called between params and results)
    fn resetRegs(self: *AssignState) void {
        self.int_reg_idx = 0;
    }

    /// Try to allocate register(s) for a type
    /// Returns null if type must go on stack
    fn tryAllocRegs(self: *AssignState, type_size: u32) ?[]const RegIndex {
        // Single register (<=8 bytes)
        if (type_size <= 8 and self.int_reg_idx < ARM64.int_param_regs) {
            const start = self.int_reg_idx;
            self.int_reg_idx += 1;
            return ARM64.param_regs[start .. start + 1];
        }

        // Two registers (9-16 bytes, e.g., strings, 2-field structs)
        if (type_size > 8 and type_size <= 16 and
            self.int_reg_idx + 1 < ARM64.int_param_regs)
        {
            const start = self.int_reg_idx;
            self.int_reg_idx += 2;
            return ARM64.param_regs[start .. start + 2];
        }

        // Can't fit in registers
        return null;
    }

    /// Allocate stack slot
    fn allocStack(self: *AssignState, type_size: u32, alignment: u32) i32 {
        self.stack_offset = alignUp(self.stack_offset, alignment);
        const offset = self.stack_offset;
        self.stack_offset += type_size;
        return @intCast(offset);
    }

    /// Allocate spill slot (for register-allocated params that need stack backup)
    fn allocSpill(self: *AssignState, type_size: u32, alignment: u32) i32 {
        self.spill_offset = alignUp(self.spill_offset, alignment);
        const offset = self.spill_offset;
        self.spill_offset += type_size;
        return @intCast(offset);
    }
};

/// Analyze a function type and return ABI info.
/// This is THE key function - both caller and callee use this.
///
/// Go reference: ABIAnalyzeFuncType in abiutils.go
pub fn analyzeFunc(
    func_type: FuncType,
    type_reg: *const TypeRegistry,
    allocator: std.mem.Allocator,
) !*ABIParamResultInfo {
    debug.log(.abi, "analyzeFunc: {d} params, ret size {d}", .{
        func_type.params.len,
        type_reg.sizeOf(func_type.return_type),
    });

    var state = AssignState.init(allocator);
    var in_params = std.ArrayListUnmanaged(ABIParamAssignment){};
    var out_params = std.ArrayListUnmanaged(ABIParamAssignment){};

    // === Analyze input parameters ===
    for (func_type.params) |param| {
        const param_size = type_reg.sizeOf(param.type_idx);
        const param_align = type_reg.alignmentOf(param.type_idx);

        var assignment = ABIParamAssignment{
            .type_idx = param.type_idx,
            .registers = &[_]RegIndex{},
            .offset = 0,
            .size = param_size,
        };

        if (state.tryAllocRegs(param_size)) |regs| {
            // Register allocated
            assignment.registers = regs;
            assignment.offset = state.allocSpill(param_size, param_align);
            debug.log(.abi, "  param: size={d} -> regs {any}", .{ param_size, regs });
        } else {
            // Stack allocated
            assignment.offset = state.allocStack(param_size, param_align);
            debug.log(.abi, "  param: size={d} -> stack off={d}", .{ param_size, assignment.offset });
        }

        try in_params.append(allocator, assignment);
    }

    const in_regs_used: u32 = @intCast(state.int_reg_idx);

    // === Reset register counters for results ===
    state.resetRegs();

    // === Analyze return type ===
    const ret_type_idx = func_type.return_type;
    const ret_size = type_reg.sizeOf(ret_type_idx);

    var uses_hidden_return = false;
    var hidden_return_size: u32 = 0;

    if (ret_size > 0 and ret_type_idx != TypeRegistry.VOID) {
        if (ret_size > ARM64.max_reg_aggregate) {
            // Large return: use hidden pointer in x8
            uses_hidden_return = true;
            hidden_return_size = ret_size;
            debug.log(.abi, "  result: size={d} -> HIDDEN RETURN via x8", .{ret_size});

            // Result is effectively "returned" via memory
            // Offset 0 means "caller provides address"
            try out_params.append(allocator, .{
                .type_idx = ret_type_idx,
                .registers = &[_]RegIndex{},
                .offset = 0,
                .size = ret_size,
            });
        } else {
            // Small return: in registers
            var assignment = ABIParamAssignment{
                .type_idx = ret_type_idx,
                .registers = &[_]RegIndex{},
                .offset = 0,
                .size = ret_size,
            };

            if (state.tryAllocRegs(ret_size)) |regs| {
                assignment.registers = regs;
                debug.log(.abi, "  result: size={d} -> regs {any}", .{ ret_size, regs });
            } else {
                debug.log(.abi, "  result: size={d} -> stack (unexpected)", .{ret_size});
            }

            try out_params.append(allocator, assignment);
        }
    }

    const out_regs_used: u32 = @intCast(state.int_reg_idx);

    // === Build final ABIParamResultInfo ===
    const info = try allocator.create(ABIParamResultInfo);
    info.* = .{
        .in_params = try in_params.toOwnedSlice(allocator),
        .out_params = try out_params.toOwnedSlice(allocator),
        .in_registers_used = in_regs_used,
        .out_registers_used = out_regs_used,
        .uses_hidden_return = uses_hidden_return,
        .hidden_return_size = hidden_return_size,
    };

    debug.log(.abi, "analyzeFunc: done, uses_hidden={}, hidden_size={d}", .{
        uses_hidden_return,
        hidden_return_size,
    });

    return info;
}

/// Analyze a function type by TypeIndex
/// Looks up the FuncType from the registry and delegates to analyzeFunc
pub fn analyzeFuncType(
    func_type_idx: TypeIndex,
    type_reg: *const TypeRegistry,
    allocator: std.mem.Allocator,
) !*ABIParamResultInfo {
    const t = type_reg.get(func_type_idx);
    if (t != .func) {
        // Not a function type - return empty ABIParamResultInfo
        const info = try allocator.create(ABIParamResultInfo);
        info.* = .{
            .in_params = &[_]ABIParamAssignment{},
            .out_params = &[_]ABIParamAssignment{},
            .in_registers_used = 0,
            .out_registers_used = 0,
            .uses_hidden_return = false,
            .hidden_return_size = 0,
        };
        return info;
    }

    return analyzeFunc(t.func, type_reg, allocator);
}

// ============================================================================
// Utilities
// ============================================================================

/// Align value up to alignment boundary
fn alignUp(value: u32, alignment: u32) u32 {
    if (alignment == 0) return value;
    return (value + alignment - 1) & ~(alignment - 1);
}

// ============================================================================
// Tests
// ============================================================================

test "ARM64 register masks" {
    try std.testing.expectEqual(@as(RegMask, 1), ARM64.regMask(0));
    try std.testing.expectEqual(@as(RegMask, 2), ARM64.regMask(1));
    try std.testing.expectEqual(@as(RegMask, 0x100), ARM64.regMask(8));
}

test "str_concat_abi structure" {
    try std.testing.expectEqual(@as(usize, 4), str_concat_abi.in_params.len);
    try std.testing.expectEqual(@as(usize, 2), str_concat_abi.out_params.len);
    try std.testing.expectEqual(@as(u32, 4), str_concat_abi.in_registers_used);
    try std.testing.expectEqual(@as(u32, 2), str_concat_abi.out_registers_used);

    // First input should be in x0
    try std.testing.expectEqual(@as(RegIndex, 0), str_concat_abi.in_params[0].registers[0]);
}

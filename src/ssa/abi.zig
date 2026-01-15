//! ABI (Application Binary Interface) structures for function calls.
//!
//! Based on Go's implementation in:
//! - cmd/compile/internal/abi/abiutils.go
//! - cmd/compile/internal/ssa/op.go (AuxCall)
//!
//! This module defines how function parameters and results are passed
//! between caller and callee, following the ARM64 calling convention.

const std = @import("std");
const TypeRegistry = @import("../frontend/types.zig").TypeRegistry;
const TypeIndex = @import("../frontend/types.zig").TypeIndex;

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

    /// Stack offset if not in registers (only valid if registers.len == 0)
    offset: i32,

    /// Create a register-passed parameter
    pub fn inRegs(type_idx: TypeIndex, regs: []const RegIndex) ABIParamAssignment {
        return .{
            .type_idx = type_idx,
            .registers = regs,
            .offset = 0,
        };
    }

    /// Create a stack-passed parameter
    pub fn onStack(type_idx: TypeIndex, offset: i32) ABIParamAssignment {
        return .{
            .type_idx = type_idx,
            .registers = &[_]RegIndex{},
            .offset = offset,
        };
    }

    /// Check if this parameter is passed in registers
    pub fn isRegister(self: ABIParamAssignment) bool {
        return self.registers.len > 0;
    }
};

/// ABIParamResultInfo describes the complete ABI for a function call:
/// how all parameters are passed and how results are returned.
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

    /// Get the Nth input parameter assignment
    pub fn inParam(self: *const ABIParamResultInfo, n: usize) ABIParamAssignment {
        return self.in_params[n];
    }

    /// Get the Nth output parameter assignment
    pub fn outParam(self: *const ABIParamResultInfo, n: usize) ABIParamAssignment {
        return self.out_params[n];
    }

    /// Get registers used by input parameter N
    pub fn regsOfArg(self: *const ABIParamResultInfo, n: usize) []const RegIndex {
        return self.in_params[n].registers;
    }

    /// Get registers used by output parameter N
    pub fn regsOfResult(self: *const ABIParamResultInfo, n: usize) []const RegIndex {
        return self.out_params[n].registers;
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

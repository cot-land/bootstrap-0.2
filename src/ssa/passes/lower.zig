//! Lowering Pass - Generic SSA to Architecture-Specific SSA
//!
//! Go reference: cmd/compile/internal/ssa/lower.go
//!
//! This pass converts generic SSA operations to architecture-specific operations.
//! After lowering, the SSA only contains ops that map directly to machine instructions.
//!
//! ## Example Transformations (ARM64)
//!
//! ```
//! add v1, v2      →  ARM64_ADD v1, v2
//! const 42        →  ARM64_MOVDconst 42
//! load [ptr]      →  ARM64_LDR [ptr]
//! store v, [ptr]  →  ARM64_STR v, [ptr]
//! ```
//!
//! ## Large Constants
//!
//! Constants that don't fit in immediate fields need multiple instructions:
//! ```
//! const 0x123456789ABC  →  ARM64_MOVDconst 0x9ABC
//!                       →  ARM64_MOVK (shift 16) 0x5678
//!                       →  ARM64_MOVK (shift 32) 0x1234
//! ```

const std = @import("std");
const Value = @import("../value.zig").Value;
const Block = @import("../block.zig").Block;
const Func = @import("../func.zig").Func;
const Op = @import("../op.zig").Op;
const types = @import("../../core/types.zig");

const ID = types.ID;
const TypeIndex = types.TypeIndex;

// =========================================
// ARM64-Specific Operations
// =========================================

/// ARM64-specific operations after lowering.
/// These map 1:1 to ARM64 machine instructions.
pub const ARM64Op = enum {
    // Data movement
    mov, // MOV Rd, Rn (register to register)
    movz, // MOVZ Rd, #imm16 (move immediate, zero others)
    movk, // MOVK Rd, #imm16, LSL #shift (move immediate, keep others)
    movn, // MOVN Rd, #imm16 (move NOT immediate)

    // Arithmetic
    add, // ADD Rd, Rn, Rm
    add_imm, // ADD Rd, Rn, #imm12
    sub, // SUB Rd, Rn, Rm
    sub_imm, // SUB Rd, Rn, #imm12
    mul, // MUL Rd, Rn, Rm
    sdiv, // SDIV Rd, Rn, Rm
    udiv, // UDIV Rd, Rn, Rm

    // Bitwise
    and_, // AND Rd, Rn, Rm
    orr, // ORR Rd, Rn, Rm
    eor, // EOR Rd, Rn, Rm
    lsl, // LSL Rd, Rn, Rm
    lsr, // LSR Rd, Rn, Rm
    asr, // ASR Rd, Rn, Rm

    // Compare
    cmp, // CMP Rn, Rm (sets flags)
    cmp_imm, // CMP Rn, #imm12
    tst, // TST Rn, Rm (AND, sets flags, discards result)

    // Conditional
    csel, // CSEL Rd, Rn, Rm, cond
    cset, // CSET Rd, cond (conditional set)

    // Memory
    ldr, // LDR Rd, [Rn, #offset]
    ldrb, // LDRB Rd, [Rn, #offset] (byte)
    ldrh, // LDRH Rd, [Rn, #offset] (halfword)
    ldrsw, // LDRSW Rd, [Rn, #offset] (signed word)
    str, // STR Rd, [Rn, #offset]
    strb, // STRB Rd, [Rn, #offset]
    strh, // STRH Rd, [Rn, #offset]
    ldp, // LDP Rt, Rt2, [Rn, #offset] (load pair)
    stp, // STP Rt, Rt2, [Rn, #offset] (store pair)

    // Branch
    b, // B label (unconditional)
    b_cond, // B.cond label (conditional)
    bl, // BL label (call)
    br, // BR Rn (indirect)
    blr, // BLR Rn (indirect call)
    ret, // RET (return)

    // Stack
    stp_pre, // STP with pre-index (for prologue)
    ldp_post, // LDP with post-index (for epilogue)

    // Pseudo-ops (resolved later)
    addr_global, // Address of global symbol
    addr_local, // Address of local (stack slot)
};

// =========================================
// Lowering Result
// =========================================

/// Result of lowering a single generic op.
pub const LowerResult = struct {
    /// Primary lowered operation
    primary: ARM64Op,

    /// Additional ops (for multi-instruction sequences)
    additional: []const ARM64Op = &.{},

    /// Immediate value (if applicable)
    imm: i64 = 0,

    /// Shift amount (for MOVK)
    shift: u6 = 0,
};

// =========================================
// Lowering Rules
// =========================================

/// Lower a generic SSA operation to ARM64.
pub fn lowerOp(op: Op, aux_int: i64) LowerResult {
    return switch (op) {
        // Constants
        .const_int => lowerConst(aux_int),
        .const_bool => .{ .primary = .movz, .imm = if (aux_int != 0) 1 else 0 },

        // Arithmetic
        .add => .{ .primary = .add },
        .add_ptr => .{ .primary = .add }, // Pointer addition is just regular add
        .sub => .{ .primary = .sub },
        .mul => .{ .primary = .mul },
        .div => .{ .primary = .sdiv },

        // Memory
        .load => .{ .primary = .ldr },
        .store => .{ .primary = .str },

        // Calls
        .call => .{ .primary = .bl },

        // Default: keep as-is (will be handled specially)
        else => .{ .primary = .mov },
    };
}

/// Lower a constant to MOV/MOVZ/MOVK sequence.
fn lowerConst(value: i64) LowerResult {
    const uval: u64 = @bitCast(value);

    // Check if fits in single MOVZ
    if (uval <= 0xFFFF) {
        return .{ .primary = .movz, .imm = value };
    }

    // Check for common patterns
    if (value >= -0x10000 and value < 0) {
        // Can use MOVN
        return .{ .primary = .movn, .imm = ~value };
    }

    // Need MOVZ + MOVK sequence
    // For now, just return MOVZ for the low 16 bits
    // Full implementation would return additional ops
    return .{
        .primary = .movz,
        .imm = @as(i64, @intCast(uval & 0xFFFF)),
    };
}

/// Check if a constant can be encoded as an immediate.
pub fn canEncodeImm12(value: i64) bool {
    return value >= 0 and value <= 0xFFF;
}

/// Check if a constant can be encoded with optional shift.
pub fn canEncodeImm12Shifted(value: i64) bool {
    if (canEncodeImm12(value)) return true;
    // Check if fits with 12-bit shift
    if (value >= 0 and @as(u64, @intCast(value)) <= 0xFFF000 and (value & 0xFFF) == 0) {
        return true;
    }
    return false;
}

// =========================================
// Lowering State
// =========================================

/// Stores lowered operation info for each value.
pub const LowerInfo = struct {
    op: ARM64Op,
    imm: i64,
    shift: u6,
};

/// Result of lowering a function - maps value IDs to lowered ops.
pub const LoweringResult = struct {
    /// Lowered info for each value (indexed by value ID)
    info: std.AutoHashMapUnmanaged(ID, LowerInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LoweringResult {
        return .{
            .info = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LoweringResult) void {
        self.info.deinit(self.allocator);
    }

    pub fn get(self: *const LoweringResult, id: ID) ?LowerInfo {
        return self.info.get(id);
    }
};

// =========================================
// Lowering Pass
// =========================================

/// Lower all generic ops in a function to ARM64-specific ops.
/// Returns a LoweringResult mapping value IDs to lowered operations.
pub fn lower(allocator: std.mem.Allocator, f: *Func) !LoweringResult {
    var result = LoweringResult.init(allocator);
    errdefer result.deinit();

    for (f.blocks.items) |block| {
        for (block.values.items) |v| {
            // Skip already-lowered ops
            if (isARM64Op(v.op)) continue;

            // Get lowering for this op
            const lowered = lowerOp(v.op, v.aux_int);

            // Store the lowered info
            try result.info.put(allocator, v.id, .{
                .op = lowered.primary,
                .imm = lowered.imm,
                .shift = lowered.shift,
            });
        }
    }

    return result;
}

/// Check if an op is already ARM64-specific.
fn isARM64Op(op: Op) bool {
    // Currently all our ops are generic
    // When we add ARM64 ops to Op enum, check here
    _ = op;
    return false;
}

// =========================================
// Tests
// =========================================

test "lowerConst small values" {
    // Small positive constants use MOVZ
    const r1 = lowerConst(42);
    try std.testing.expectEqual(ARM64Op.movz, r1.primary);
    try std.testing.expectEqual(@as(i64, 42), r1.imm);

    // Zero
    const r2 = lowerConst(0);
    try std.testing.expectEqual(ARM64Op.movz, r2.primary);
    try std.testing.expectEqual(@as(i64, 0), r2.imm);

    // Max 16-bit
    const r3 = lowerConst(0xFFFF);
    try std.testing.expectEqual(ARM64Op.movz, r3.primary);
}

test "lowerConst negative values" {
    // Small negative values can use MOVN
    const r1 = lowerConst(-1);
    try std.testing.expectEqual(ARM64Op.movn, r1.primary);
}

test "lowerOp arithmetic" {
    try std.testing.expectEqual(ARM64Op.add, lowerOp(.add, 0).primary);
    try std.testing.expectEqual(ARM64Op.sub, lowerOp(.sub, 0).primary);
    try std.testing.expectEqual(ARM64Op.mul, lowerOp(.mul, 0).primary);
    try std.testing.expectEqual(ARM64Op.sdiv, lowerOp(.div, 0).primary);
}

test "lowerOp memory" {
    try std.testing.expectEqual(ARM64Op.ldr, lowerOp(.load, 0).primary);
    try std.testing.expectEqual(ARM64Op.str, lowerOp(.store, 0).primary);
}

test "canEncodeImm12" {
    try std.testing.expect(canEncodeImm12(0));
    try std.testing.expect(canEncodeImm12(0xFFF));
    try std.testing.expect(!canEncodeImm12(0x1000));
    try std.testing.expect(!canEncodeImm12(-1));
}

//! ARM64 Instruction Encoding
//!
//! Encodes ARM64 instructions into machine code bytes.
//! Reference: ARM Architecture Reference Manual ARMv8-A
//!
//! ## Instruction Format
//!
//! ARM64 instructions are always 32 bits (4 bytes), little-endian.
//! Major format groups based on bits [28:25]:
//!
//! - 100x: Data processing (immediate)
//! - 101x: Branches
//! - x1x0: Loads and stores
//! - x101: Data processing (register)

const std = @import("std");

// =========================================
// Register Encoding
// =========================================

/// Encode a general-purpose register (X0-X30, XZR/SP).
pub fn encodeGPR(reg: u5) u32 {
    return @as(u32, reg);
}

/// Encode register as Rd (destination).
pub fn encodeRd(reg: u5) u32 {
    return @as(u32, reg);
}

/// Encode register as Rn (first source).
pub fn encodeRn(reg: u5) u32 {
    return @as(u32, reg) << 5;
}

/// Encode register as Rm (second source).
pub fn encodeRm(reg: u5) u32 {
    return @as(u32, reg) << 16;
}

// =========================================
// Data Processing - Immediate
// =========================================

/// Encode MOVZ: Move wide with zero.
/// MOVZ Xd, #imm16{, LSL #shift}
/// Encoding: 1 10 100101 hw imm16 Rd
pub fn encodeMOVZ(rd: u5, imm16: u16, shift: u2) u32 {
    const sf: u32 = 1; // 64-bit
    const opc: u32 = 0b10; // MOVZ
    const hw: u32 = @as(u32, shift);

    return (sf << 31) |
        (opc << 29) |
        (0b100101 << 23) |
        (hw << 21) |
        (@as(u32, imm16) << 5) |
        encodeRd(rd);
}

/// Encode MOVK: Move wide with keep.
/// MOVK Xd, #imm16{, LSL #shift}
/// Encoding: 1 11 100101 hw imm16 Rd
pub fn encodeMOVK(rd: u5, imm16: u16, shift: u2) u32 {
    const sf: u32 = 1;
    const opc: u32 = 0b11; // MOVK

    return (sf << 31) |
        (opc << 29) |
        (0b100101 << 23) |
        (@as(u32, shift) << 21) |
        (@as(u32, imm16) << 5) |
        encodeRd(rd);
}

/// Encode MOVN: Move wide with NOT.
/// MOVN Xd, #imm16{, LSL #shift}
/// Encoding: 1 00 100101 hw imm16 Rd
pub fn encodeMOVN(rd: u5, imm16: u16, shift: u2) u32 {
    const sf: u32 = 1;
    const opc: u32 = 0b00; // MOVN

    return (sf << 31) |
        (opc << 29) |
        (0b100101 << 23) |
        (@as(u32, shift) << 21) |
        (@as(u32, imm16) << 5) |
        encodeRd(rd);
}

/// Encode ADD immediate.
/// ADD Xd, Xn, #imm12{, LSL #12}
/// Encoding: 1 0 0 10001 sh imm12 Rn Rd
pub fn encodeADDImm(rd: u5, rn: u5, imm12: u12, shift: u1) u32 {
    const sf: u32 = 1; // 64-bit
    const op: u32 = 0; // ADD (not SUB)
    const s: u32 = 0; // Don't set flags

    return (sf << 31) |
        (op << 30) |
        (s << 29) |
        (0b10001 << 24) |
        (@as(u32, shift) << 22) |
        (@as(u32, imm12) << 10) |
        encodeRn(rn) |
        encodeRd(rd);
}

/// Encode SUB immediate.
/// SUB Xd, Xn, #imm12{, LSL #12}
pub fn encodeSUBImm(rd: u5, rn: u5, imm12: u12, shift: u1) u32 {
    const sf: u32 = 1;
    const op: u32 = 1; // SUB (not ADD)
    const s: u32 = 0;

    return (sf << 31) |
        (op << 30) |
        (s << 29) |
        (0b10001 << 24) |
        (@as(u32, shift) << 22) |
        (@as(u32, imm12) << 10) |
        encodeRn(rn) |
        encodeRd(rd);
}

// =========================================
// Data Processing - Register
// =========================================

/// Encode ADD register (shifted).
/// ADD Xd, Xn, Xm{, shift #amount}
/// Encoding: 1 0 0 01011 shift 0 Rm imm6 Rn Rd
pub fn encodeADDReg(rd: u5, rn: u5, rm: u5) u32 {
    const sf: u32 = 1;
    const op: u32 = 0; // ADD
    const s: u32 = 0;
    const shift: u32 = 0b00; // LSL
    const imm6: u32 = 0; // No shift amount

    return (sf << 31) |
        (op << 30) |
        (s << 29) |
        (0b01011 << 24) |
        (shift << 22) |
        (0 << 21) |
        encodeRm(rm) |
        (imm6 << 10) |
        encodeRn(rn) |
        encodeRd(rd);
}

/// Encode SUB register.
pub fn encodeSUBReg(rd: u5, rn: u5, rm: u5) u32 {
    const sf: u32 = 1;
    const op: u32 = 1; // SUB
    const s: u32 = 0;
    const shift: u32 = 0b00;
    const imm6: u32 = 0;

    return (sf << 31) |
        (op << 30) |
        (s << 29) |
        (0b01011 << 24) |
        (shift << 22) |
        (0 << 21) |
        encodeRm(rm) |
        (imm6 << 10) |
        encodeRn(rn) |
        encodeRd(rd);
}

/// Encode MUL (alias for MADD with Xa=XZR).
/// MUL Xd, Xn, Xm
/// Encoding: MADD Xd, Xn, Xm, XZR
pub fn encodeMUL(rd: u5, rn: u5, rm: u5) u32 {
    const sf: u32 = 1;
    // MADD: 1 00 11011 000 Rm 0 Ra Rn Rd
    return (sf << 31) |
        (0b00 << 29) |
        (0b11011 << 24) |
        (0b000 << 21) |
        encodeRm(rm) |
        (0 << 15) | // o0 = 0 for MADD
        (31 << 10) | // Ra = XZR
        encodeRn(rn) |
        encodeRd(rd);
}

/// Encode SDIV.
/// SDIV Xd, Xn, Xm
pub fn encodeSDIV(rd: u5, rn: u5, rm: u5) u32 {
    const sf: u32 = 1;
    // 1 0 0 11010110 Rm 00001 1 Rn Rd
    return (sf << 31) |
        (0 << 30) |
        (0 << 29) |
        (0b11010110 << 21) |
        encodeRm(rm) |
        (0b000011 << 10) |
        encodeRn(rn) |
        encodeRd(rd);
}

/// Encode UDIV.
pub fn encodeUDIV(rd: u5, rn: u5, rm: u5) u32 {
    const sf: u32 = 1;
    return (sf << 31) |
        (0 << 30) |
        (0 << 29) |
        (0b11010110 << 21) |
        encodeRm(rm) |
        (0b000010 << 10) |
        encodeRn(rn) |
        encodeRd(rd);
}

// =========================================
// Loads and Stores
// =========================================

/// Encode LDR (unsigned offset).
/// LDR Xd, [Xn, #offset]
/// Encoding: 11 111 0 01 01 imm12 Rn Rt
pub fn encodeLDR(rt: u5, rn: u5, offset: u12) u32 {
    const size: u32 = 0b11; // 64-bit
    const v: u32 = 0; // Not SIMD
    const opc: u32 = 0b01; // Load

    return (size << 30) |
        (0b111 << 27) |
        (v << 26) |
        (0b01 << 24) |
        (opc << 22) |
        (@as(u32, offset) << 10) |
        encodeRn(rn) |
        encodeRd(rt);
}

/// Encode STR (unsigned offset).
/// STR Xt, [Xn, #offset]
pub fn encodeSTR(rt: u5, rn: u5, offset: u12) u32 {
    const size: u32 = 0b11;
    const v: u32 = 0;
    const opc: u32 = 0b00; // Store

    return (size << 30) |
        (0b111 << 27) |
        (v << 26) |
        (0b01 << 24) |
        (opc << 22) |
        (@as(u32, offset) << 10) |
        encodeRn(rn) |
        encodeRd(rt);
}

/// Encode STP (pre-index) for prologue.
/// STP Xt1, Xt2, [Xn, #offset]!
pub fn encodeSTPPre(rt: u5, rt2: u5, rn: u5, offset: i7) u32 {
    const opc: u32 = 0b10; // 64-bit
    // 10 101 0 011 imm7 Rt2 Rn Rt
    const imm7: u32 = @bitCast(@as(i32, offset) & 0x7F);

    return (opc << 30) |
        (0b101 << 27) |
        (0 << 26) |
        (0b011 << 23) |
        (imm7 << 15) |
        (@as(u32, rt2) << 10) |
        encodeRn(rn) |
        encodeRd(rt);
}

/// Encode LDP (post-index) for epilogue.
/// LDP Xt1, Xt2, [Xn], #offset
pub fn encodeLDPPost(rt: u5, rt2: u5, rn: u5, offset: i7) u32 {
    const opc: u32 = 0b10;
    // 10 101 0 001 imm7 Rt2 Rn Rt
    const imm7: u32 = @bitCast(@as(i32, offset) & 0x7F);

    return (opc << 30) |
        (0b101 << 27) |
        (0 << 26) |
        (0b001 << 23) |
        (imm7 << 15) |
        (@as(u32, rt2) << 10) |
        encodeRn(rn) |
        encodeRd(rt);
}

// =========================================
// Branches
// =========================================

/// Encode unconditional branch.
/// B label (PC-relative)
/// Encoding: 0 00101 imm26
pub fn encodeB(offset: i26) u32 {
    const imm26: u32 = @bitCast(@as(i32, offset) & 0x3FFFFFF);
    return (0b000101 << 26) | imm26;
}

/// Encode branch with link (call).
/// BL label
pub fn encodeBL(offset: i26) u32 {
    const imm26: u32 = @bitCast(@as(i32, offset) & 0x3FFFFFF);
    return (0b100101 << 26) | imm26;
}

/// Encode branch register (indirect).
/// BR Xn
pub fn encodeBR(rn: u5) u32 {
    // 1101011 0000 11111 000000 Rn 00000
    return (0b1101011 << 25) |
        (0b0000 << 21) |
        (0b11111 << 16) |
        (0b000000 << 10) |
        encodeRn(rn) |
        0b00000;
}

/// Encode branch with link register (indirect call).
/// BLR Xn
pub fn encodeBLR(rn: u5) u32 {
    // 1101011 0001 11111 000000 Rn 00000
    return (0b1101011 << 25) |
        (0b0001 << 21) |
        (0b11111 << 16) |
        (0b000000 << 10) |
        encodeRn(rn) |
        0b00000;
}

/// Encode return.
/// RET {Xn} (default X30)
pub fn encodeRET(rn: u5) u32 {
    // 1101011 0010 11111 000000 Rn 00000
    return (0b1101011 << 25) |
        (0b0010 << 21) |
        (0b11111 << 16) |
        (0b000000 << 10) |
        encodeRn(rn) |
        0b00000;
}

/// Condition codes for conditional branches.
pub const Cond = enum(u4) {
    eq = 0b0000, // Equal (Z=1)
    ne = 0b0001, // Not equal (Z=0)
    cs = 0b0010, // Carry set / unsigned higher or same
    cc = 0b0011, // Carry clear / unsigned lower
    mi = 0b0100, // Minus / negative
    pl = 0b0101, // Plus / positive or zero
    vs = 0b0110, // Overflow
    vc = 0b0111, // No overflow
    hi = 0b1000, // Unsigned higher
    ls = 0b1001, // Unsigned lower or same
    ge = 0b1010, // Signed greater or equal
    lt = 0b1011, // Signed less than
    gt = 0b1100, // Signed greater than
    le = 0b1101, // Signed less or equal
    al = 0b1110, // Always
    nv = 0b1111, // Never (reserved)
};

/// Encode conditional branch.
/// B.cond label
pub fn encodeBCond(cond: Cond, offset: i19) u32 {
    const imm19: u32 = @bitCast(@as(i32, offset) & 0x7FFFF);
    // 0101010 0 imm19 0 cond
    return (0b0101010 << 25) |
        (0 << 24) |
        (imm19 << 5) |
        (0 << 4) |
        @as(u32, @intFromEnum(cond));
}

// =========================================
// Compare and Set
// =========================================

/// Encode CMP register (alias for SUBS with Rd=XZR).
/// CMP Xn, Xm
pub fn encodeCMPReg(rn: u5, rm: u5) u32 {
    // SUBS XZR, Xn, Xm
    const sf: u32 = 1;
    const op: u32 = 1; // SUB
    const s: u32 = 1; // Set flags

    return (sf << 31) |
        (op << 30) |
        (s << 29) |
        (0b01011 << 24) |
        (0b00 << 22) | // LSL
        (0 << 21) |
        encodeRm(rm) |
        (0 << 10) | // imm6
        encodeRn(rn) |
        encodeRd(31); // XZR
}

/// Encode NOP.
pub fn encodeNOP() u32 {
    return 0xD503201F;
}

// =========================================
// Instruction Emitter
// =========================================

/// Emitter for building machine code.
pub const Emitter = struct {
    buffer: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Emitter {
        return .{
            .buffer = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Emitter) void {
        self.buffer.deinit(self.allocator);
    }

    /// Emit a 32-bit instruction (little-endian).
    pub fn emit(self: *Emitter, inst: u32) !void {
        try self.buffer.appendSlice(self.allocator, &@as([4]u8, @bitCast(inst)));
    }

    /// Get the emitted code.
    pub fn code(self: *const Emitter) []const u8 {
        return self.buffer.items;
    }

    /// Current offset (for branch calculations).
    pub fn offset(self: *const Emitter) usize {
        return self.buffer.items.len;
    }
};

// =========================================
// Tests
// =========================================

test "encode MOVZ" {
    // MOVZ X0, #42
    const inst = encodeMOVZ(0, 42, 0);
    // Expected: 0xD2800540 = 1101_0010_1000_0000_0000_0101_0100_0000
    try std.testing.expectEqual(@as(u32, 0xD2800540), inst);
}

test "encode ADD register" {
    // ADD X0, X1, X2
    const inst = encodeADDReg(0, 1, 2);
    // Should be: 1 0 0 01011 00 0 00010 000000 00001 00000
    // = 0x8B020020
    try std.testing.expectEqual(@as(u32, 0x8B020020), inst);
}

test "encode SUB register" {
    // SUB X0, X1, X2
    const inst = encodeSUBReg(0, 1, 2);
    // = 0xCB020020
    try std.testing.expectEqual(@as(u32, 0xCB020020), inst);
}

test "encode LDR" {
    // LDR X0, [X1, #0]
    const inst = encodeLDR(0, 1, 0);
    // = 0xF9400020
    try std.testing.expectEqual(@as(u32, 0xF9400020), inst);
}

test "encode STR" {
    // STR X0, [X1, #0]
    const inst = encodeSTR(0, 1, 0);
    // = 0xF9000020
    try std.testing.expectEqual(@as(u32, 0xF9000020), inst);
}

test "encode RET" {
    // RET (uses X30)
    const inst = encodeRET(30);
    // = 0xD65F03C0
    try std.testing.expectEqual(@as(u32, 0xD65F03C0), inst);
}

test "encode BL" {
    // BL +4 (offset in instructions, not bytes)
    const inst = encodeBL(1);
    // = 0x94000001
    try std.testing.expectEqual(@as(u32, 0x94000001), inst);
}

test "encode NOP" {
    const inst = encodeNOP();
    try std.testing.expectEqual(@as(u32, 0xD503201F), inst);
}

test "Emitter" {
    const allocator = std.testing.allocator;
    var emitter = Emitter.init(allocator);
    defer emitter.deinit();

    try emitter.emit(encodeNOP());
    try emitter.emit(encodeRET(30));

    try std.testing.expectEqual(@as(usize, 8), emitter.code().len);
}

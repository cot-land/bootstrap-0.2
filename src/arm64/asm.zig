//! ARM64 Instruction Encoding
//!
//! Encodes ARM64 instructions into machine code bytes.
//! Reference: ARM Architecture Reference Manual ARMv8-A
//!
//! ## Design Philosophy (following Go's cmd/internal/obj/arm64/asm7.go)
//!
//! 1. Related instructions share ONE encoding function with parameters
//! 2. The parameter makes the critical bit EXPLICIT and impossible to forget
//! 3. Every encoding has a test against known-good output
//!
//! ARM64 instructions are always 32 bits (4 bytes), little-endian.

const std = @import("std");

// =========================================
// Register Encoding
// =========================================

/// Encode register in Rd position (bits 4-0).
pub fn encodeRd(reg: u5) u32 {
    return @as(u32, reg);
}

/// Encode register in Rn position (bits 9-5).
pub fn encodeRn(reg: u5) u32 {
    return @as(u32, reg) << 5;
}

/// Encode register in Rm position (bits 20-16).
pub fn encodeRm(reg: u5) u32 {
    return @as(u32, reg) << 16;
}

// =========================================
// Move Wide (MOVZ/MOVK/MOVN)
// =========================================

/// Move wide opcode
pub const MoveWideOp = enum(u2) {
    movn = 0b00, // Move wide with NOT
    movz = 0b10, // Move wide with zero
    movk = 0b11, // Move wide with keep
};

/// Encode move wide instruction (MOVZ, MOVK, MOVN).
/// Single function - opcode parameter makes the instruction type explicit.
/// Go equivalent: handled in asmout() case dispatching
pub fn encodeMoveWide(op: MoveWideOp, rd: u5, imm16: u16, shift: u2) u32 {
    const sf: u32 = 1; // 64-bit
    // Encoding: sf opc 100101 hw imm16 Rd
    return (sf << 31) |
        (@as(u32, @intFromEnum(op)) << 29) |
        (0b100101 << 23) |
        (@as(u32, shift) << 21) |
        (@as(u32, imm16) << 5) |
        encodeRd(rd);
}

// Convenience wrappers (but the core function is parameterized)
pub fn encodeMOVZ(rd: u5, imm16: u16, shift: u2) u32 {
    return encodeMoveWide(.movz, rd, imm16, shift);
}

pub fn encodeMOVK(rd: u5, imm16: u16, shift: u2) u32 {
    return encodeMoveWide(.movk, rd, imm16, shift);
}

pub fn encodeMOVN(rd: u5, imm16: u16, shift: u2) u32 {
    return encodeMoveWide(.movn, rd, imm16, shift);
}

// =========================================
// Add/Subtract Immediate
// =========================================

/// Encode ADD/SUB immediate.
/// Single function - `is_sub` parameter makes it explicit.
/// Go equivalent: opirr() with S/op bits
pub fn encodeAddSubImm(rd: u5, rn: u5, imm12: u12, shift: u1, is_sub: bool, set_flags: bool) u32 {
    const sf: u32 = 1; // 64-bit
    const op: u32 = if (is_sub) 1 else 0;
    const s: u32 = if (set_flags) 1 else 0;
    // Encoding: sf op S 10001 sh imm12 Rn Rd
    return (sf << 31) |
        (op << 30) |
        (s << 29) |
        (0b10001 << 24) |
        (@as(u32, shift) << 22) |
        (@as(u32, imm12) << 10) |
        encodeRn(rn) |
        encodeRd(rd);
}

pub fn encodeADDImm(rd: u5, rn: u5, imm12: u12, shift: u1) u32 {
    return encodeAddSubImm(rd, rn, imm12, shift, false, false);
}

pub fn encodeSUBImm(rd: u5, rn: u5, imm12: u12, shift: u1) u32 {
    return encodeAddSubImm(rd, rn, imm12, shift, true, false);
}

// =========================================
// Add/Subtract Register
// =========================================

/// Encode ADD/SUB register (shifted).
/// Single function - `is_sub` parameter makes it explicit.
/// Go equivalent: oprrr() in asm7.go
pub fn encodeAddSubReg(rd: u5, rn: u5, rm: u5, is_sub: bool, set_flags: bool) u32 {
    const sf: u32 = 1; // 64-bit
    const op: u32 = if (is_sub) 1 else 0;
    const s: u32 = if (set_flags) 1 else 0;
    // Encoding: sf op S 01011 shift 0 Rm imm6 Rn Rd
    return (sf << 31) |
        (op << 30) |
        (s << 29) |
        (0b01011 << 24) |
        (0b00 << 22) | // LSL
        (0 << 21) |
        encodeRm(rm) |
        (0 << 10) | // imm6 = 0
        encodeRn(rn) |
        encodeRd(rd);
}

pub fn encodeADDReg(rd: u5, rn: u5, rm: u5) u32 {
    return encodeAddSubReg(rd, rn, rm, false, false);
}

pub fn encodeSUBReg(rd: u5, rn: u5, rm: u5) u32 {
    return encodeAddSubReg(rd, rn, rm, true, false);
}

/// CMP is SUBS with Rd=XZR
pub fn encodeCMPReg(rn: u5, rm: u5) u32 {
    return encodeAddSubReg(31, rn, rm, true, true);
}

// =========================================
// PC-Relative Address (ADR/ADRP)
// =========================================

/// Encode ADR/ADRP instruction.
/// ADR:  Forms PC-relative address (adds imm to PC)
/// ADRP: Forms page address (adds imm*4096 to PC page)
///
/// For ADRP, the immediate is a 21-bit signed offset scaled by 4KB.
/// The actual offset is typically fixed up by the linker via relocations.
///
/// Encoding: op immlo 10000 immhi Rd
/// op=0: ADR, op=1: ADRP
pub fn encodeAdrp(rd: u5, imm21: i21, is_page: bool) u32 {
    const imm: u21 = @bitCast(imm21);
    const immlo: u32 = @as(u32, imm & 0b11);
    const immhi: u32 = @as(u32, imm >> 2);
    const op: u32 = if (is_page) 1 else 0;

    return (op << 31) |
        (immlo << 29) |
        (0b10000 << 24) |
        (immhi << 5) |
        encodeRd(rd);
}

/// ADRP: Address of 4KB page (PC-relative, page-aligned)
/// Used with ADD to compute full address
pub fn encodeADRP(rd: u5, imm21: i21) u32 {
    return encodeAdrp(rd, imm21, true);
}

/// ADR: PC-relative address
pub fn encodeADR(rd: u5, imm21: i21) u32 {
    return encodeAdrp(rd, imm21, false);
}

// =========================================
// Multiply/Divide
// =========================================

/// Encode MUL (alias for MADD with Ra=XZR).
pub fn encodeMUL(rd: u5, rn: u5, rm: u5) u32 {
    const sf: u32 = 1;
    // MADD: sf 00 11011 000 Rm 0 Ra Rn Rd
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

/// Encode SDIV/UDIV.
/// Single function - `is_signed` parameter makes it explicit.
pub fn encodeDiv(rd: u5, rn: u5, rm: u5, is_signed: bool) u32 {
    const sf: u32 = 1;
    const o1: u32 = if (is_signed) 1 else 0;
    // Encoding: sf 0 0 11010110 Rm 00001 o1 Rn Rd
    return (sf << 31) |
        (0 << 30) |
        (0 << 29) |
        (0b11010110 << 21) |
        encodeRm(rm) |
        (0b00001 << 11) |
        (o1 << 10) |
        encodeRn(rn) |
        encodeRd(rd);
}

pub fn encodeSDIV(rd: u5, rn: u5, rm: u5) u32 {
    return encodeDiv(rd, rn, rm, true);
}

pub fn encodeUDIV(rd: u5, rn: u5, rm: u5) u32 {
    return encodeDiv(rd, rn, rm, false);
}

// =========================================
// Load/Store Register
// =========================================

/// Encode LDR/STR (unsigned offset).
/// Single function - `is_load` parameter makes it explicit.
/// Go equivalent: opldr() in asm7.go
pub fn encodeLdrStr(rt: u5, rn: u5, offset: u12, is_load: bool) u32 {
    const size: u32 = 0b11; // 64-bit
    const v: u32 = 0; // Not SIMD
    const opc: u32 = if (is_load) 0b01 else 0b00;
    // Encoding: size 111 V 01 opc imm12 Rn Rt
    return (size << 30) |
        (0b111 << 27) |
        (v << 26) |
        (0b01 << 24) |
        (opc << 22) |
        (@as(u32, offset) << 10) |
        encodeRn(rn) |
        encodeRd(rt);
}

pub fn encodeLDR(rt: u5, rn: u5, offset: u12) u32 {
    return encodeLdrStr(rt, rn, offset, true);
}

pub fn encodeSTR(rt: u5, rn: u5, offset: u12) u32 {
    return encodeLdrStr(rt, rn, offset, false);
}

// =========================================
// Load/Store Pair (LDP/STP)
// =========================================

/// Addressing mode for load/store pair
pub const LdStPairMode = enum(u2) {
    post_index = 0b01, // [Xn], #imm
    signed_offset = 0b10, // [Xn, #imm]
    pre_index = 0b11, // [Xn, #imm]!
};

/// Encode LDP/STP with explicit load/store parameter.
/// THIS IS THE KEY FUNCTION - Go's opldpstp() equivalent.
/// The `is_load` parameter sets bit 22, making it IMPOSSIBLE to forget.
pub fn encodeLdpStp(rt: u5, rt2: u5, rn: u5, offset: i7, mode: LdStPairMode, is_load: bool) u32 {
    const opc: u32 = 0b10; // 64-bit
    const imm7: u32 = @bitCast(@as(i32, offset) & 0x7F);
    const load_bit: u32 = if (is_load) 1 else 0;
    // Encoding: opc 101 V mode L imm7 Rt2 Rn Rt
    //           31-30 29-27 26 25-23 22 21-15 14-10 9-5 4-0
    return (opc << 30) |
        (0b101 << 27) |
        (0 << 26) | // V = 0 for GPR
        (@as(u32, @intFromEnum(mode)) << 23) |
        (load_bit << 22) | // *** THE CRITICAL BIT - explicit parameter ***
        (imm7 << 15) |
        (@as(u32, rt2) << 10) |
        encodeRn(rn) |
        encodeRd(rt);
}

/// STP pre-index for function prologue.
/// STP Xt1, Xt2, [Xn, #offset]!
pub fn encodeSTPPre(rt: u5, rt2: u5, rn: u5, offset: i7) u32 {
    return encodeLdpStp(rt, rt2, rn, offset, .pre_index, false);
}

/// LDP post-index for function epilogue.
/// LDP Xt1, Xt2, [Xn], #offset
pub fn encodeLDPPost(rt: u5, rt2: u5, rn: u5, offset: i7) u32 {
    return encodeLdpStp(rt, rt2, rn, offset, .post_index, true);
}

// =========================================
// Branches
// =========================================

/// Encode B/BL (unconditional branch).
/// Single function - `link` parameter makes it explicit.
pub fn encodeBranch(offset: i26, link: bool) u32 {
    const imm26: u32 = @bitCast(@as(i32, offset) & 0x3FFFFFF);
    const op: u32 = if (link) 0b100101 else 0b000101;
    return (op << 26) | imm26;
}

pub fn encodeB(offset: i26) u32 {
    return encodeBranch(offset, false);
}

pub fn encodeBL(offset: i26) u32 {
    return encodeBranch(offset, true);
}

/// Branch register opcode
pub const BranchRegOp = enum(u4) {
    br = 0b0000, // Branch to register
    blr = 0b0001, // Branch with link to register
    ret = 0b0010, // Return
};

/// Encode BR/BLR/RET.
/// Single function - opcode parameter makes it explicit.
pub fn encodeBranchReg(rn: u5, op: BranchRegOp) u32 {
    // Encoding: 1101011 opc 11111 000000 Rn 00000
    return (0b1101011 << 25) |
        (@as(u32, @intFromEnum(op)) << 21) |
        (0b11111 << 16) |
        (0b000000 << 10) |
        encodeRn(rn) |
        0b00000;
}

pub fn encodeBR(rn: u5) u32 {
    return encodeBranchReg(rn, .br);
}

pub fn encodeBLR(rn: u5) u32 {
    return encodeBranchReg(rn, .blr);
}

pub fn encodeRET(rn: u5) u32 {
    return encodeBranchReg(rn, .ret);
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
    // Encoding: 0101010 0 imm19 0 cond
    return (0b0101010 << 25) |
        (0 << 24) |
        (imm19 << 5) |
        (0 << 4) |
        @as(u32, @intFromEnum(cond));
}

// =========================================
// Conditional Set (CSET)
// =========================================

/// Invert condition code for CSINC encoding.
fn invertCond(cond: Cond) Cond {
    // Invert by flipping the lowest bit
    return @enumFromInt(@intFromEnum(cond) ^ 1);
}

/// Encode CSET (Conditional Set).
/// CSET Rd, cond = CSINC Rd, XZR, XZR, invert(cond)
/// Sets Rd to 1 if cond is true, 0 otherwise.
pub fn encodeCSET(rd: u5, cond: Cond) u32 {
    const sf: u32 = 1; // 64-bit
    const inv_cond = invertCond(cond);
    // CSINC: sf 0 0 11010100 Rm cond 0 1 Rn Rd
    // For CSET: Rm = XZR (31), Rn = XZR (31)
    return (sf << 31) |
        (0b00 << 29) |
        (0b11010100 << 21) |
        (@as(u32, 31) << 16) | // Rm = XZR
        (@as(u32, @intFromEnum(inv_cond)) << 12) |
        (0b01 << 10) | // op = CSINC
        (31 << 5) | // Rn = XZR
        encodeRd(rd);
}

// =========================================
// Compare and Branch (CBZ/CBNZ)
// =========================================

/// Encode CBZ/CBNZ (Compare and Branch on Zero/Nonzero).
/// Single function - `is_nonzero` parameter makes it explicit.
pub fn encodeCBZNZ(rt: u5, offset: i19, is_nonzero: bool) u32 {
    const sf: u32 = 1; // 64-bit
    const op: u32 = if (is_nonzero) 1 else 0;
    const imm19: u32 = @bitCast(@as(i32, offset) & 0x7FFFF);
    // Encoding: sf 011010 op imm19 Rt
    return (sf << 31) |
        (0b011010 << 25) |
        (op << 24) |
        (imm19 << 5) |
        encodeRd(rt);
}

pub fn encodeCBNZ(rt: u5, offset: i19) u32 {
    return encodeCBZNZ(rt, offset, true);
}

pub fn encodeCBZ(rt: u5, offset: i19) u32 {
    return encodeCBZNZ(rt, offset, false);
}

// =========================================
// Miscellaneous
// =========================================

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
// Tests - EVERY encoding must have a test
// =========================================

test "encode MOVZ" {
    // MOVZ X0, #42
    const inst = encodeMOVZ(0, 42, 0);
    // Expected: 0xD2800540
    try std.testing.expectEqual(@as(u32, 0xD2800540), inst);
}

test "encode MOVK" {
    // MOVK X0, #0x1234, LSL #16
    const inst = encodeMOVK(0, 0x1234, 1);
    // Expected: 0xF2A24680
    try std.testing.expectEqual(@as(u32, 0xF2A24680), inst);
}

test "encode ADD register" {
    // ADD X0, X1, X2
    const inst = encodeADDReg(0, 1, 2);
    // Expected: 0x8B020020
    try std.testing.expectEqual(@as(u32, 0x8B020020), inst);
}

test "encode SUB register" {
    // SUB X0, X1, X2
    const inst = encodeSUBReg(0, 1, 2);
    // Expected: 0xCB020020
    try std.testing.expectEqual(@as(u32, 0xCB020020), inst);
}

test "encode CMP register" {
    // CMP X1, X2 (SUBS XZR, X1, X2)
    const inst = encodeCMPReg(1, 2);
    // Expected: 0xEB02003F
    try std.testing.expectEqual(@as(u32, 0xEB02003F), inst);
}

test "encode MUL" {
    // MUL X0, X1, X2
    const inst = encodeMUL(0, 1, 2);
    // Expected: 0x9B027C20
    try std.testing.expectEqual(@as(u32, 0x9B027C20), inst);
}

test "encode SDIV" {
    // SDIV X0, X1, X2
    const inst = encodeSDIV(0, 1, 2);
    // Expected: 0x9AC20C20
    try std.testing.expectEqual(@as(u32, 0x9AC20C20), inst);
}

test "encode UDIV" {
    // UDIV X0, X1, X2
    const inst = encodeUDIV(0, 1, 2);
    // Expected: 0x9AC20820
    try std.testing.expectEqual(@as(u32, 0x9AC20820), inst);
}

test "encode LDR" {
    // LDR X0, [X1, #0]
    const inst = encodeLDR(0, 1, 0);
    // Expected: 0xF9400020
    try std.testing.expectEqual(@as(u32, 0xF9400020), inst);
}

test "encode STR" {
    // STR X0, [X1, #0]
    const inst = encodeSTR(0, 1, 0);
    // Expected: 0xF9000020
    try std.testing.expectEqual(@as(u32, 0xF9000020), inst);
}

test "encode STP pre-index" {
    // STP X29, X30, [SP, #-16]!
    const inst = encodeSTPPre(29, 30, 31, -2);
    // Expected: 0xA9BF7BFD
    try std.testing.expectEqual(@as(u32, 0xA9BF7BFD), inst);
}

test "encode LDP post-index" {
    // LDP X29, X30, [SP], #16
    const inst = encodeLDPPost(29, 30, 31, 2);
    // Expected: 0xA8C17BFD
    try std.testing.expectEqual(@as(u32, 0xA8C17BFD), inst);
}

test "encode LDP vs STP - verify bit 22 difference" {
    // This test explicitly verifies that LDP and STP differ by bit 22
    const ldp = encodeLdpStp(29, 30, 31, 2, .post_index, true); // is_load = true
    const stp = encodeLdpStp(29, 30, 31, 2, .post_index, false); // is_load = false

    // They should differ ONLY in bit 22
    const diff = ldp ^ stp;
    try std.testing.expectEqual(@as(u32, 1 << 22), diff);

    // LDP should have bit 22 set
    try std.testing.expect((ldp & (1 << 22)) != 0);
    // STP should NOT have bit 22 set
    try std.testing.expect((stp & (1 << 22)) == 0);
}

test "encode B" {
    // B +4 (offset in instructions)
    const inst = encodeB(1);
    // Expected: 0x14000001
    try std.testing.expectEqual(@as(u32, 0x14000001), inst);
}

test "encode BL" {
    // BL +4 (offset in instructions)
    const inst = encodeBL(1);
    // Expected: 0x94000001
    try std.testing.expectEqual(@as(u32, 0x94000001), inst);
}

test "encode RET" {
    // RET (uses X30)
    const inst = encodeRET(30);
    // Expected: 0xD65F03C0
    try std.testing.expectEqual(@as(u32, 0xD65F03C0), inst);
}

test "encode NOP" {
    const inst = encodeNOP();
    try std.testing.expectEqual(@as(u32, 0xD503201F), inst);
}

test "encode ADRP" {
    // ADRP X0, #0 - base case
    const inst = encodeADRP(0, 0);
    // Expected: op=1, immlo=0, 10000, immhi=0, Rd=0
    // 1 00 10000 0000000000000000000 00000 = 0x90000000
    try std.testing.expectEqual(@as(u32, 0x90000000), inst);
}

test "encode ADRP with offset" {
    // ADRP X1, #1 (page offset 1 = 4KB away)
    const inst = encodeADRP(1, 1);
    // immlo = 1 & 3 = 1, immhi = 1 >> 2 = 0
    // 1 01 10000 0000000000000000000 00001 = 0xB0000001
    try std.testing.expectEqual(@as(u32, 0xB0000001), inst);
}

test "Emitter" {
    const allocator = std.testing.allocator;
    var emitter = Emitter.init(allocator);
    defer emitter.deinit();

    try emitter.emit(encodeNOP());
    try emitter.emit(encodeRET(30));

    try std.testing.expectEqual(@as(usize, 8), emitter.code().len);
}

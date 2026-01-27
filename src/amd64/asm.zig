//! AMD64 Instruction Encoding
//!
//! Encodes AMD64/x86-64 instructions into machine code bytes.
//! Reference: Intel 64 and IA-32 Architectures Software Developer's Manual
//!
//! ## AMD64 Instruction Format
//!
//! ```
//! [Prefixes] [REX] [Opcode] [ModR/M] [SIB] [Displacement] [Immediate]
//!    0-4      0-1    1-3      0-1     0-1      0,1,2,4        0,1,2,4
//! ```
//!
//! ## REX Prefix (0x40-0x4F)
//!
//! Required for:
//! - 64-bit operand size (W=1)
//! - Accessing R8-R15 (R, X, or B bits)
//! - Accessing SPL, BPL, SIL, DIL
//!
//! ```
//! REX = 0100 W R X B
//!       W: 1 = 64-bit operand size
//!       R: Extension of ModR/M reg field
//!       X: Extension of SIB index field
//!       B: Extension of ModR/M r/m or SIB base field
//! ```
//!
//! ## ModR/M Byte
//!
//! ```
//! ModR/M = Mod(7:6) | Reg(5:3) | R/M(2:0)
//! Mod: 00 = [reg], 01 = [reg+disp8], 10 = [reg+disp32], 11 = reg
//! ```

const std = @import("std");
const regs = @import("regs.zig");
const Reg = regs.Reg;

// =========================================
// REX Prefix Encoding
// =========================================

/// Encode REX prefix byte.
/// Returns null if no REX prefix is needed.
pub fn encodeREX(w: bool, r: bool, x: bool, b: bool) ?u8 {
    const rex = @as(u8, 0x40) |
        (@as(u8, @intFromBool(w)) << 3) |
        (@as(u8, @intFromBool(r)) << 2) |
        (@as(u8, @intFromBool(x)) << 1) |
        @as(u8, @intFromBool(b));

    // If only the base 0x40 (no bits set), REX is optional
    // But we need it for W=1 or accessing R8-R15
    if (rex == 0x40 and !w and !r and !x and !b) {
        return null;
    }
    return rex;
}

/// Encode REX prefix for 64-bit operation with two registers.
/// reg: register in ModR/M reg field
/// rm: register in ModR/M r/m field
pub fn encodeREX64(reg: Reg, rm: Reg) u8 {
    return 0x48 | // REX.W for 64-bit
        (@as(u8, @intFromBool(reg.needsRex())) << 2) | // REX.R
        @as(u8, @intFromBool(rm.needsRex())); // REX.B
}

/// Encode REX prefix for 64-bit operation with single register in r/m field.
pub fn encodeREX64rm(rm: Reg) u8 {
    return 0x48 | @as(u8, @intFromBool(rm.needsRex())); // REX.W + REX.B
}

// =========================================
// ModR/M Encoding
// =========================================

/// Encode ModR/M byte with register-direct addressing (mod=11).
/// reg: register in reg field (opcode extension or source/dest)
/// rm: register in r/m field (source/dest)
pub fn encodeModRM_RR(reg: Reg, rm: Reg) u8 {
    return 0xC0 | // Mod = 11 (register direct)
        (@as(u8, reg.enc3()) << 3) | // Reg field
        @as(u8, rm.enc3()); // R/M field
}

/// Encode ModR/M byte for [reg] indirect addressing (mod=00).
/// Excludes RSP (needs SIB) and RBP (becomes RIP-relative).
pub fn encodeModRM_Indirect(reg: Reg, rm: Reg) u8 {
    return 0x00 | // Mod = 00 (indirect)
        (@as(u8, reg.enc3()) << 3) | // Reg field
        @as(u8, rm.enc3()); // R/M field
}

/// Encode ModR/M byte for [reg+disp8] addressing (mod=01).
pub fn encodeModRM_Disp8(reg: Reg, rm: Reg) u8 {
    return 0x40 | // Mod = 01 (disp8)
        (@as(u8, reg.enc3()) << 3) |
        @as(u8, rm.enc3());
}

/// Encode ModR/M byte for [reg+disp32] addressing (mod=10).
pub fn encodeModRM_Disp32(reg: Reg, rm: Reg) u8 {
    return 0x80 | // Mod = 10 (disp32)
        (@as(u8, reg.enc3()) << 3) |
        @as(u8, rm.enc3());
}

/// Encode ModR/M with opcode extension in reg field.
/// Used for instructions like PUSH, POP, single-operand arithmetic.
pub fn encodeModRM_Ext(ext: u3, rm: Reg) u8 {
    return 0xC0 | // Mod = 11 (register direct)
        (@as(u8, ext) << 3) |
        @as(u8, rm.enc3());
}

// =========================================
// SIB Encoding (for RSP-based and complex addressing)
// =========================================

/// Encode SIB byte.
/// scale: 0=1, 1=2, 2=4, 3=8
/// index: index register (RSP means no index)
/// base: base register
pub fn encodeSIB(scale: u2, index: Reg, base: Reg) u8 {
    return (@as(u8, scale) << 6) |
        (@as(u8, index.enc3()) << 3) |
        @as(u8, base.enc3());
}

/// SIB byte for [RSP+disp] addressing (no index, RSP base).
pub const SIB_RSP_BASE: u8 = 0x24; // scale=0, index=RSP (4), base=RSP (4)

// =========================================
// Move Instructions
// =========================================

/// MOV r64, imm64 (10 bytes: REX.W + B8+rd + imm64)
/// This is the only way to load a 64-bit immediate into a register.
pub fn encodeMovRegImm64(dst: Reg, imm: u64) [10]u8 {
    var buf: [10]u8 = undefined;
    buf[0] = 0x48 | @as(u8, @intFromBool(dst.needsRex())); // REX.W + REX.B
    buf[1] = 0xB8 + @as(u8, dst.enc3()); // B8+rd
    std.mem.writeInt(u64, buf[2..10], imm, .little);
    return buf;
}

/// MOV r64, r64 (3 bytes: REX.W + 89 /r)
/// 89 /r = MOV r/m64, r64
pub fn encodeMovRegReg(dst: Reg, src: Reg) [3]u8 {
    return .{
        encodeREX64(src, dst),
        0x89,
        encodeModRM_RR(src, dst),
    };
}

/// MOV r64, r/m64 (load from memory)
/// 8B /r = MOV r64, r/m64
pub fn encodeMovRegMem(dst: Reg, base: Reg, disp: i32) []const u8 {
    // RSP/R12 as base requires SIB byte
    // RBP/R13 with disp=0 requires disp8=0
    _ = dst;
    _ = base;
    _ = disp;
    // TODO: implement full memory addressing
    @panic("encodeMovRegMem not yet implemented");
}

/// MOV r/m64, imm32 (sign-extended)
/// C7 /0 = MOV r/m64, imm32
pub fn encodeMovRegImm32(dst: Reg, imm: i32) [7]u8 {
    var buf: [7]u8 = undefined;
    buf[0] = encodeREX64rm(dst);
    buf[1] = 0xC7;
    buf[2] = encodeModRM_Ext(0, dst);
    std.mem.writeInt(i32, buf[3..7], imm, .little);
    return buf;
}

/// XOR r64, r64 (for zeroing a register efficiently)
/// Preferred over MOV reg, 0 because it's shorter and breaks dependencies.
pub fn encodeXorRegReg(dst: Reg, src: Reg) [3]u8 {
    return .{
        encodeREX64(src, dst),
        0x31, // XOR r/m64, r64
        encodeModRM_RR(src, dst),
    };
}

// =========================================
// Stack Operations
// =========================================

/// PUSH r64 (1-2 bytes: [REX.B] + 50+rd)
pub fn encodePush(reg: Reg) struct { data: [2]u8, len: u8 } {
    if (reg.needsRex()) {
        return .{
            .data = .{ 0x41, 0x50 + @as(u8, reg.enc3()) },
            .len = 2,
        };
    } else {
        return .{
            .data = .{ 0x50 + @as(u8, reg.enc3()), 0 },
            .len = 1,
        };
    }
}

/// POP r64 (1-2 bytes: [REX.B] + 58+rd)
pub fn encodePop(reg: Reg) struct { data: [2]u8, len: u8 } {
    if (reg.needsRex()) {
        return .{
            .data = .{ 0x41, 0x58 + @as(u8, reg.enc3()) },
            .len = 2,
        };
    } else {
        return .{
            .data = .{ 0x58 + @as(u8, reg.enc3()), 0 },
            .len = 1,
        };
    }
}

// =========================================
// Control Flow
// =========================================

/// RET (1 byte: C3)
pub fn encodeRet() [1]u8 {
    return .{0xC3};
}

/// CALL rel32 (5 bytes: E8 + rel32)
/// rel32 is PC-relative offset from end of instruction.
pub fn encodeCall(rel32: i32) [5]u8 {
    var buf: [5]u8 = undefined;
    buf[0] = 0xE8;
    std.mem.writeInt(i32, buf[1..5], rel32, .little);
    return buf;
}

/// JMP rel32 (5 bytes: E9 + rel32)
pub fn encodeJmpRel32(rel32: i32) [5]u8 {
    var buf: [5]u8 = undefined;
    buf[0] = 0xE9;
    std.mem.writeInt(i32, buf[1..5], rel32, .little);
    return buf;
}

/// JMP rel8 (2 bytes: EB + rel8)
pub fn encodeJmpRel8(rel8: i8) [2]u8 {
    return .{ 0xEB, @bitCast(rel8) };
}

// =========================================
// Conditional Jumps
// =========================================

/// Condition codes for Jcc instructions
pub const Cond = enum(u4) {
    o = 0x0, // Overflow
    no = 0x1, // Not overflow
    b = 0x2, // Below (unsigned <)
    ae = 0x3, // Above or equal (unsigned >=)
    e = 0x4, // Equal (zero)
    ne = 0x5, // Not equal (not zero)
    be = 0x6, // Below or equal (unsigned <=)
    a = 0x7, // Above (unsigned >)
    s = 0x8, // Sign (negative)
    ns = 0x9, // Not sign (non-negative)
    p = 0xA, // Parity even
    np = 0xB, // Parity odd
    l = 0xC, // Less than (signed <)
    ge = 0xD, // Greater or equal (signed >=)
    le = 0xE, // Less or equal (signed <=)
    g = 0xF, // Greater than (signed >)

    // Aliases
    pub const c = Cond.b; // Carry
    pub const nc = Cond.ae; // No carry
    pub const z = Cond.e; // Zero
    pub const nz = Cond.ne; // Not zero
    pub const nae = Cond.b; // Not above or equal
    pub const nb = Cond.ae; // Not below
    pub const nbe = Cond.a; // Not below or equal
    pub const na = Cond.be; // Not above
    pub const nge = Cond.l; // Not greater or equal
    pub const nl = Cond.ge; // Not less
    pub const nle = Cond.g; // Not less or equal
    pub const ng = Cond.le; // Not greater
};

/// Jcc rel32 (6 bytes: 0F 8x + rel32)
pub fn encodeJccRel32(cond: Cond, rel32: i32) [6]u8 {
    var buf: [6]u8 = undefined;
    buf[0] = 0x0F;
    buf[1] = 0x80 + @as(u8, @intFromEnum(cond));
    std.mem.writeInt(i32, buf[2..6], rel32, .little);
    return buf;
}

/// Jcc rel8 (2 bytes: 7x + rel8)
pub fn encodeJccRel8(cond: Cond, rel8: i8) [2]u8 {
    return .{ 0x70 + @as(u8, @intFromEnum(cond)), @bitCast(rel8) };
}

// =========================================
// Arithmetic Instructions
// =========================================

/// ADD r64, r64 (3 bytes: REX.W + 01 /r)
pub fn encodeAddRegReg(dst: Reg, src: Reg) [3]u8 {
    return .{
        encodeREX64(src, dst),
        0x01, // ADD r/m64, r64
        encodeModRM_RR(src, dst),
    };
}

/// ADD r64, imm32 (sign-extended) (7 bytes: REX.W + 81 /0 + imm32)
pub fn encodeAddRegImm32(dst: Reg, imm: i32) [7]u8 {
    var buf: [7]u8 = undefined;
    buf[0] = encodeREX64rm(dst);
    buf[1] = 0x81;
    buf[2] = encodeModRM_Ext(0, dst);
    std.mem.writeInt(i32, buf[3..7], imm, .little);
    return buf;
}

/// ADD r64, imm8 (sign-extended) (4 bytes: REX.W + 83 /0 + imm8)
pub fn encodeAddRegImm8(dst: Reg, imm: i8) [4]u8 {
    return .{
        encodeREX64rm(dst),
        0x83,
        encodeModRM_Ext(0, dst),
        @bitCast(imm),
    };
}

/// SUB r64, r64 (3 bytes: REX.W + 29 /r)
pub fn encodeSubRegReg(dst: Reg, src: Reg) [3]u8 {
    return .{
        encodeREX64(src, dst),
        0x29, // SUB r/m64, r64
        encodeModRM_RR(src, dst),
    };
}

/// SUB r64, imm32 (sign-extended) (7 bytes: REX.W + 81 /5 + imm32)
pub fn encodeSubRegImm32(dst: Reg, imm: i32) [7]u8 {
    var buf: [7]u8 = undefined;
    buf[0] = encodeREX64rm(dst);
    buf[1] = 0x81;
    buf[2] = encodeModRM_Ext(5, dst);
    std.mem.writeInt(i32, buf[3..7], imm, .little);
    return buf;
}

/// SUB r64, imm8 (sign-extended) (4 bytes: REX.W + 83 /5 + imm8)
pub fn encodeSubRegImm8(dst: Reg, imm: i8) [4]u8 {
    return .{
        encodeREX64rm(dst),
        0x83,
        encodeModRM_Ext(5, dst),
        @bitCast(imm),
    };
}

/// IMUL r64, r64 (4 bytes: REX.W + 0F AF /r)
pub fn encodeImulRegReg(dst: Reg, src: Reg) [4]u8 {
    return .{
        encodeREX64(dst, src),
        0x0F,
        0xAF,
        encodeModRM_RR(dst, src),
    };
}

/// CMP r64, r64 (3 bytes: REX.W + 39 /r)
pub fn encodeCmpRegReg(a: Reg, b: Reg) [3]u8 {
    return .{
        encodeREX64(b, a),
        0x39, // CMP r/m64, r64
        encodeModRM_RR(b, a),
    };
}

/// CMP r64, imm32 (sign-extended) (7 bytes: REX.W + 81 /7 + imm32)
pub fn encodeCmpRegImm32(reg: Reg, imm: i32) [7]u8 {
    var buf: [7]u8 = undefined;
    buf[0] = encodeREX64rm(reg);
    buf[1] = 0x81;
    buf[2] = encodeModRM_Ext(7, reg);
    std.mem.writeInt(i32, buf[3..7], imm, .little);
    return buf;
}

/// CMP r64, imm8 (sign-extended) (4 bytes: REX.W + 83 /7 + imm8)
pub fn encodeCmpRegImm8(reg: Reg, imm: i8) [4]u8 {
    return .{
        encodeREX64rm(reg),
        0x83,
        encodeModRM_Ext(7, reg),
        @bitCast(imm),
    };
}

/// TEST r64, r64 (3 bytes: REX.W + 85 /r)
/// Sets ZF if result is zero (i.e., if both operands have no common bits)
/// Common use: TEST reg, reg to check if reg == 0
pub fn encodeTestRegReg(a: Reg, b: Reg) [3]u8 {
    return .{
        encodeREX64(b, a),
        0x85, // TEST r/m64, r64
        encodeModRM_RR(b, a),
    };
}

// =========================================
// Division (special handling for RDX:RAX)
// =========================================

/// CQO - Sign-extend RAX into RDX:RAX (2 bytes: 48 99)
/// Must be done before IDIV
pub fn encodeCqo() [2]u8 {
    return .{ 0x48, 0x99 };
}

/// IDIV r64 - Signed divide RDX:RAX by r64
/// Quotient in RAX, remainder in RDX
pub fn encodeIdivReg(divisor: Reg) [3]u8 {
    return .{
        encodeREX64rm(divisor),
        0xF7,
        encodeModRM_Ext(7, divisor),
    };
}

/// DIV r64 - Unsigned divide RDX:RAX by r64
pub fn encodeDivReg(divisor: Reg) [3]u8 {
    return .{
        encodeREX64rm(divisor),
        0xF7,
        encodeModRM_Ext(6, divisor),
    };
}

// =========================================
// Load/Store with Memory Operands
// =========================================

/// MOV r64, [base + disp32] - Load 64-bit value from memory
/// 8B /r with mod=10 (disp32)
/// Returns (data, length) tuple since instruction size varies
pub fn encodeLoadDisp32(dst: Reg, base: Reg, disp: i32) struct { data: [8]u8, len: u8 } {
    var buf: [8]u8 = .{0} ** 8;
    var len: u8 = 0;

    // REX prefix
    buf[len] = encodeREX64(dst, base);
    len += 1;

    // Opcode
    buf[len] = 0x8B;
    len += 1;

    // ModR/M
    if (base == .rsp or base == .r12) {
        // RSP/R12 requires SIB
        buf[len] = encodeModRM_Disp32(dst, .rsp); // r/m=100 means SIB follows
        len += 1;
        buf[len] = SIB_RSP_BASE;
        len += 1;
    } else {
        buf[len] = encodeModRM_Disp32(dst, base);
        len += 1;
    }

    // Displacement
    std.mem.writeInt(i32, buf[len..][0..4], disp, .little);
    len += 4;

    return .{ .data = buf, .len = len };
}

/// MOV [base + disp32], r64 - Store 64-bit value to memory
/// 89 /r with mod=10 (disp32)
/// Returns (data, length) tuple since instruction size varies
pub fn encodeStoreDisp32(base: Reg, disp: i32, src: Reg) struct { data: [8]u8, len: u8 } {
    var buf: [8]u8 = .{0} ** 8;
    var len: u8 = 0;

    // REX prefix
    buf[len] = encodeREX64(src, base);
    len += 1;

    // Opcode
    buf[len] = 0x89;
    len += 1;

    // ModR/M
    if (base == .rsp or base == .r12) {
        buf[len] = encodeModRM_Disp32(src, .rsp);
        len += 1;
        buf[len] = SIB_RSP_BASE;
        len += 1;
    } else {
        buf[len] = encodeModRM_Disp32(src, base);
        len += 1;
    }

    // Displacement
    std.mem.writeInt(i32, buf[len..][0..4], disp, .little);
    len += 4;

    return .{ .data = buf, .len = len };
}

// =========================================
// Sized Load/Store Operations
// =========================================

/// MOVZX r64, BYTE PTR [base + disp32] - Load byte with zero-extension
/// 0F B6 /r with mod=10 (disp32)
pub fn encodeLoadByteDisp32(dst: Reg, base: Reg, disp: i32) struct { data: [9]u8, len: u8 } {
    var buf: [9]u8 = .{0} ** 9;
    var len: u8 = 0;

    // REX prefix (need REX.W for 64-bit dest, REX.R/B for extended regs)
    buf[len] = encodeREX64(dst, base);
    len += 1;

    // Opcode: 0F B6
    buf[len] = 0x0F;
    len += 1;
    buf[len] = 0xB6;
    len += 1;

    // ModR/M
    if (base == .rsp or base == .r12) {
        buf[len] = encodeModRM_Disp32(dst, .rsp);
        len += 1;
        buf[len] = SIB_RSP_BASE;
        len += 1;
    } else {
        buf[len] = encodeModRM_Disp32(dst, base);
        len += 1;
    }

    // Displacement
    std.mem.writeInt(i32, buf[len..][0..4], disp, .little);
    len += 4;

    return .{ .data = buf, .len = len };
}

/// MOV BYTE PTR [base + disp32], r8 - Store byte to memory
/// 88 /r with mod=10 (disp32)
pub fn encodeStoreByteDisp32(base: Reg, disp: i32, src: Reg) struct { data: [8]u8, len: u8 } {
    var buf: [8]u8 = .{0} ** 8;
    var len: u8 = 0;

    // REX prefix (needed for R8-R15, also gives access to SIL, DIL, etc.)
    const need_rex = src.needsRex() or base.needsRex() or
        src == .rsp or src == .rbp or src == .rsi or src == .rdi;
    if (need_rex) {
        buf[len] = 0x40 |
            (@as(u8, @intFromBool(src.needsRex())) << 2) |
            @as(u8, @intFromBool(base.needsRex()));
        len += 1;
    }

    // Opcode
    buf[len] = 0x88;
    len += 1;

    // ModR/M
    if (base == .rsp or base == .r12) {
        buf[len] = encodeModRM_Disp32(src, .rsp);
        len += 1;
        buf[len] = SIB_RSP_BASE;
        len += 1;
    } else {
        buf[len] = encodeModRM_Disp32(src, base);
        len += 1;
    }

    // Displacement
    std.mem.writeInt(i32, buf[len..][0..4], disp, .little);
    len += 4;

    return .{ .data = buf, .len = len };
}

/// MOVZX r64, WORD PTR [base + disp32] - Load 16-bit with zero-extension
/// 0F B7 /r with mod=10 (disp32)
pub fn encodeLoadWordDisp32(dst: Reg, base: Reg, disp: i32) struct { data: [9]u8, len: u8 } {
    var buf: [9]u8 = .{0} ** 9;
    var len: u8 = 0;

    // REX prefix
    buf[len] = encodeREX64(dst, base);
    len += 1;

    // Opcode: 0F B7
    buf[len] = 0x0F;
    len += 1;
    buf[len] = 0xB7;
    len += 1;

    // ModR/M
    if (base == .rsp or base == .r12) {
        buf[len] = encodeModRM_Disp32(dst, .rsp);
        len += 1;
        buf[len] = SIB_RSP_BASE;
        len += 1;
    } else {
        buf[len] = encodeModRM_Disp32(dst, base);
        len += 1;
    }

    // Displacement
    std.mem.writeInt(i32, buf[len..][0..4], disp, .little);
    len += 4;

    return .{ .data = buf, .len = len };
}

/// MOV WORD PTR [base + disp32], r16 - Store 16-bit to memory
/// 66 89 /r with mod=10 (disp32)
pub fn encodeStoreWordDisp32(base: Reg, disp: i32, src: Reg) struct { data: [9]u8, len: u8 } {
    var buf: [9]u8 = .{0} ** 9;
    var len: u8 = 0;

    // Operand size prefix for 16-bit
    buf[len] = 0x66;
    len += 1;

    // REX prefix (if needed for R8-R15)
    if (src.needsRex() or base.needsRex()) {
        buf[len] = 0x40 |
            (@as(u8, @intFromBool(src.needsRex())) << 2) |
            @as(u8, @intFromBool(base.needsRex()));
        len += 1;
    }

    // Opcode
    buf[len] = 0x89;
    len += 1;

    // ModR/M
    if (base == .rsp or base == .r12) {
        buf[len] = encodeModRM_Disp32(src, .rsp);
        len += 1;
        buf[len] = SIB_RSP_BASE;
        len += 1;
    } else {
        buf[len] = encodeModRM_Disp32(src, base);
        len += 1;
    }

    // Displacement
    std.mem.writeInt(i32, buf[len..][0..4], disp, .little);
    len += 4;

    return .{ .data = buf, .len = len };
}

/// MOV r32, [base + disp32] - Load 32-bit with implicit zero-extension to 64-bit
/// 8B /r with mod=10 (disp32), no REX.W
pub fn encodeLoadDwordDisp32(dst: Reg, base: Reg, disp: i32) struct { data: [8]u8, len: u8 } {
    var buf: [8]u8 = .{0} ** 8;
    var len: u8 = 0;

    // REX prefix (only if extended regs, no W bit for 32-bit operation)
    if (dst.needsRex() or base.needsRex()) {
        buf[len] = 0x40 |
            (@as(u8, @intFromBool(dst.needsRex())) << 2) |
            @as(u8, @intFromBool(base.needsRex()));
        len += 1;
    }

    // Opcode
    buf[len] = 0x8B;
    len += 1;

    // ModR/M
    if (base == .rsp or base == .r12) {
        buf[len] = encodeModRM_Disp32(dst, .rsp);
        len += 1;
        buf[len] = SIB_RSP_BASE;
        len += 1;
    } else {
        buf[len] = encodeModRM_Disp32(dst, base);
        len += 1;
    }

    // Displacement
    std.mem.writeInt(i32, buf[len..][0..4], disp, .little);
    len += 4;

    return .{ .data = buf, .len = len };
}

/// MOV [base + disp32], r32 - Store 32-bit to memory
/// 89 /r with mod=10 (disp32), no REX.W
pub fn encodeStoreDwordDisp32(base: Reg, disp: i32, src: Reg) struct { data: [8]u8, len: u8 } {
    var buf: [8]u8 = .{0} ** 8;
    var len: u8 = 0;

    // REX prefix (only if extended regs, no W bit for 32-bit operation)
    if (src.needsRex() or base.needsRex()) {
        buf[len] = 0x40 |
            (@as(u8, @intFromBool(src.needsRex())) << 2) |
            @as(u8, @intFromBool(base.needsRex()));
        len += 1;
    }

    // Opcode
    buf[len] = 0x89;
    len += 1;

    // ModR/M
    if (base == .rsp or base == .r12) {
        buf[len] = encodeModRM_Disp32(src, .rsp);
        len += 1;
        buf[len] = SIB_RSP_BASE;
        len += 1;
    } else {
        buf[len] = encodeModRM_Disp32(src, base);
        len += 1;
    }

    // Displacement
    std.mem.writeInt(i32, buf[len..][0..4], disp, .little);
    len += 4;

    return .{ .data = buf, .len = len };
}

// =========================================
// RIP-Relative Addressing (for globals/strings)
// =========================================

/// LEA r64, [RIP + disp32] - Load address using RIP-relative addressing
/// 8D /r with mod=00 and r/m=101 (RIP-relative)
pub fn encodeLeaRipRel32(dst: Reg, disp: i32) [7]u8 {
    var buf: [7]u8 = undefined;

    // REX.W (always 64-bit), REX.R if dst is R8-R15
    buf[0] = 0x48 | (@as(u8, @intFromBool(dst.needsRex())) << 2);

    // LEA opcode
    buf[1] = 0x8D;

    // ModR/M: mod=00, reg=dst, r/m=101 (RIP-relative)
    buf[2] = (@as(u8, dst.enc3()) << 3) | 0x05;

    // disp32
    std.mem.writeInt(i32, buf[3..7], disp, .little);

    return buf;
}

/// MOV r64, [RIP + disp32] - Load 64-bit from RIP-relative address
pub fn encodeLoadRipRel32(dst: Reg, disp: i32) [7]u8 {
    var buf: [7]u8 = undefined;

    // REX.W, REX.R if needed
    buf[0] = 0x48 | (@as(u8, @intFromBool(dst.needsRex())) << 2);

    // MOV opcode
    buf[1] = 0x8B;

    // ModR/M: mod=00, reg=dst, r/m=101 (RIP-relative)
    buf[2] = (@as(u8, dst.enc3()) << 3) | 0x05;

    // disp32
    std.mem.writeInt(i32, buf[3..7], disp, .little);

    return buf;
}

/// MOV [RIP + disp32], r64 - Store 64-bit to RIP-relative address
pub fn encodeStoreRipRel32(disp: i32, src: Reg) [7]u8 {
    var buf: [7]u8 = undefined;

    // REX.W, REX.R if needed
    buf[0] = 0x48 | (@as(u8, @intFromBool(src.needsRex())) << 2);

    // MOV opcode
    buf[1] = 0x89;

    // ModR/M: mod=00, reg=src, r/m=101 (RIP-relative)
    buf[2] = (@as(u8, src.enc3()) << 3) | 0x05;

    // disp32
    std.mem.writeInt(i32, buf[3..7], disp, .little);

    return buf;
}

// =========================================
// Logical Operations
// =========================================

/// AND r64, r64
pub fn encodeAndRegReg(dst: Reg, src: Reg) [3]u8 {
    return .{
        encodeREX64(src, dst),
        0x21, // AND r/m64, r64
        encodeModRM_RR(src, dst),
    };
}

/// OR r64, r64
pub fn encodeOrRegReg(dst: Reg, src: Reg) [3]u8 {
    return .{
        encodeREX64(src, dst),
        0x09, // OR r/m64, r64
        encodeModRM_RR(src, dst),
    };
}

/// XOR r64, r64
pub fn encodeXORRegReg(dst: Reg, src: Reg) [3]u8 {
    return .{
        encodeREX64(src, dst),
        0x31, // XOR r/m64, r64
        encodeModRM_RR(src, dst),
    };
}

/// NOT r64
pub fn encodeNotReg(reg: Reg) [3]u8 {
    return .{
        encodeREX64rm(reg),
        0xF7,
        encodeModRM_Ext(2, reg),
    };
}

/// NEG r64 (two's complement negation)
pub fn encodeNegReg(reg: Reg) [3]u8 {
    return .{
        encodeREX64rm(reg),
        0xF7,
        encodeModRM_Ext(3, reg),
    };
}

// =========================================
// Shift Operations
// =========================================

/// SHL r64, CL (shift left by CL)
pub fn encodeShlRegCl(dst: Reg) [3]u8 {
    return .{
        encodeREX64rm(dst),
        0xD3,
        encodeModRM_Ext(4, dst),
    };
}

/// SHR r64, CL (logical shift right by CL)
pub fn encodeShrRegCl(dst: Reg) [3]u8 {
    return .{
        encodeREX64rm(dst),
        0xD3,
        encodeModRM_Ext(5, dst),
    };
}

/// SAR r64, CL (arithmetic shift right by CL)
pub fn encodeSarRegCl(dst: Reg) [3]u8 {
    return .{
        encodeREX64rm(dst),
        0xD3,
        encodeModRM_Ext(7, dst),
    };
}

/// SHL r64, imm8
pub fn encodeShlRegImm8(dst: Reg, imm: u8) [4]u8 {
    return .{
        encodeREX64rm(dst),
        0xC1,
        encodeModRM_Ext(4, dst),
        imm,
    };
}

/// SHR r64, imm8
pub fn encodeShrRegImm8(dst: Reg, imm: u8) [4]u8 {
    return .{
        encodeREX64rm(dst),
        0xC1,
        encodeModRM_Ext(5, dst),
        imm,
    };
}

/// SAR r64, imm8
pub fn encodeSarRegImm8(dst: Reg, imm: u8) [4]u8 {
    return .{
        encodeREX64rm(dst),
        0xC1,
        encodeModRM_Ext(7, dst),
        imm,
    };
}

// =========================================
// Conditional Set (SETcc)
// =========================================

/// SETcc r/m8 - Set byte based on condition
/// Note: Only sets low 8 bits; upper bits unchanged
pub fn encodeSetcc(cond: Cond, dst: Reg) [4]u8 {
    // For R8-R15, need REX prefix
    const rex: u8 = if (dst.needsRex()) 0x41 else 0x40;
    return .{
        rex, // REX for uniform encoding (allows access to SIL, DIL, etc.)
        0x0F,
        0x90 + @as(u8, @intFromEnum(cond)),
        encodeModRM_Ext(0, dst),
    };
}

/// CMOVcc r64, r64 - Conditional move based on condition flags
/// 4 bytes: REX.W + 0F 4x /r where x is condition code
pub fn encodeCmovcc(cond: Cond, dst: Reg, src: Reg) [4]u8 {
    return .{
        encodeREX64(dst, src),
        0x0F,
        0x40 + @as(u8, @intFromEnum(cond)),
        encodeModRM_RR(dst, src),
    };
}

/// MOVZX r64, r8 - Zero-extend byte to 64-bit
/// Clears upper 56 bits of destination register
/// 4 bytes: REX.W + 0F B6 /r
pub fn encodeMovzxRegReg8(dst: Reg, src: Reg) [4]u8 {
    // REX.W is required for 64-bit destination
    // REX.R extends ModR/M.reg (dst)
    // REX.B extends ModR/M.r/m (src) for accessing SIL, DIL, BPL, SPL
    const rex: u8 = 0x48 | // REX.W
        (if (dst.needsRex()) @as(u8, 0x04) else 0) | // REX.R
        (if (src.needsRex()) @as(u8, 0x01) else 0); // REX.B
    return .{
        rex,
        0x0F,
        0xB6, // MOVZX r64, r/m8
        encodeModRM_RR(dst, src),
    };
}

// =========================================
// LEA (Load Effective Address)
// =========================================

/// LEA r64, [base + disp32]
/// Returns (data, length) tuple since instruction size varies
pub fn encodeLeaDisp32(dst: Reg, base: Reg, disp: i32) struct { data: [8]u8, len: u8 } {
    var buf: [8]u8 = .{0} ** 8;
    var len: u8 = 0;

    buf[len] = encodeREX64(dst, base);
    len += 1;

    buf[len] = 0x8D; // LEA
    len += 1;

    if (base == .rsp or base == .r12) {
        buf[len] = encodeModRM_Disp32(dst, .rsp);
        len += 1;
        buf[len] = SIB_RSP_BASE;
        len += 1;
    } else {
        buf[len] = encodeModRM_Disp32(dst, base);
        len += 1;
    }

    std.mem.writeInt(i32, buf[len..][0..4], disp, .little);
    len += 4;

    return .{ .data = buf, .len = len };
}

/// LEA dst, [base + index] - compute base + index address
/// Uses SIB byte with scale=1, no displacement
pub fn encodeLeaBaseIndex(dst: Reg, base: Reg, index: Reg) struct { data: [5]u8, len: u8 } {
    var buf: [5]u8 = .{0} ** 5;
    var len: u8 = 0;

    // REX prefix: W=1 (64-bit), R if dst needs, X if index needs, B if base needs
    buf[len] = 0x48 |
        (@as(u8, @intFromBool(dst.needsRex())) << 2) |
        (@as(u8, @intFromBool(index.needsRex())) << 1) |
        @as(u8, @intFromBool(base.needsRex()));
    len += 1;

    // LEA opcode
    buf[len] = 0x8D;
    len += 1;

    // Special case: if base is RBP or R13, we need mod=01 with disp8=0
    // because mod=00 with base=101 means disp32 only, no base register
    if (base == .rbp or base == .r13) {
        // ModR/M: mod=01 (disp8), reg=dst, r/m=100 (SIB follows)
        buf[len] = 0x44 | (@as(u8, dst.enc3()) << 3);
        len += 1;
        // SIB: scale=00 (1), index=index, base=base
        buf[len] = (@as(u8, index.enc3()) << 3) | base.enc3();
        len += 1;
        // disp8 = 0
        buf[len] = 0;
        len += 1;
    } else {
        // ModR/M: mod=00, reg=dst, r/m=100 (SIB follows)
        buf[len] = 0x04 | (@as(u8, dst.enc3()) << 3);
        len += 1;
        // SIB: scale=00 (1), index=index, base=base
        buf[len] = (@as(u8, index.enc3()) << 3) | base.enc3();
        len += 1;
    }

    return .{ .data = buf, .len = len };
}

// =========================================
// NOP Instructions
// =========================================

/// Single-byte NOP
pub fn encodeNop() [1]u8 {
    return .{0x90};
}

/// Multi-byte NOP (up to 9 bytes)
/// Uses recommended NOP sequences for best performance
pub fn encodeNopN(n: usize) []const u8 {
    const nop_sequences = [_][]const u8{
        &.{}, // 0 bytes
        &.{0x90}, // 1 byte: NOP
        &.{ 0x66, 0x90 }, // 2 bytes: 66 NOP
        &.{ 0x0F, 0x1F, 0x00 }, // 3 bytes: NOP DWORD ptr [EAX]
        &.{ 0x0F, 0x1F, 0x40, 0x00 }, // 4 bytes
        &.{ 0x0F, 0x1F, 0x44, 0x00, 0x00 }, // 5 bytes
        &.{ 0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00 }, // 6 bytes
        &.{ 0x0F, 0x1F, 0x80, 0x00, 0x00, 0x00, 0x00 }, // 7 bytes
        &.{ 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 8 bytes
        &.{ 0x66, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 }, // 9 bytes
    };

    if (n < nop_sequences.len) {
        return nop_sequences[n];
    }
    return nop_sequences[9]; // Max 9 bytes
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

    /// Emit a single byte
    pub fn emitByte(self: *Emitter, b: u8) !void {
        try self.buffer.append(self.allocator, b);
    }

    /// Emit multiple bytes
    pub fn emitBytes(self: *Emitter, bytes: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    /// Emit a fixed-size array of bytes
    pub fn emit(self: *Emitter, comptime N: usize, bytes: [N]u8) !void {
        try self.buffer.appendSlice(self.allocator, &bytes);
    }

    /// Get the emitted code
    pub fn code(self: *const Emitter) []const u8 {
        return self.buffer.items;
    }

    /// Current offset (for branch calculations)
    pub fn offset(self: *const Emitter) usize {
        return self.buffer.items.len;
    }

    /// Patch a 32-bit value at a specific offset
    pub fn patch32(self: *Emitter, at: usize, value: i32) void {
        std.mem.writeInt(i32, self.buffer.items[at..][0..4], value, .little);
    }
};

// =========================================
// Tests
// =========================================

test "REX prefix encoding" {
    // REX.W only (64-bit)
    try std.testing.expectEqual(@as(u8, 0x48), encodeREX(true, false, false, false).?);

    // REX.W + REX.B (64-bit with R8-R15 in r/m)
    try std.testing.expectEqual(@as(u8, 0x49), encodeREX(true, false, false, true).?);

    // REX.W + REX.R (64-bit with R8-R15 in reg)
    try std.testing.expectEqual(@as(u8, 0x4C), encodeREX(true, true, false, false).?);

    // No REX needed
    try std.testing.expectEqual(@as(?u8, null), encodeREX(false, false, false, false));
}

test "MOV r64, imm64" {
    // MOV RAX, 42
    const inst = encodeMovRegImm64(.rax, 42);
    try std.testing.expectEqual(@as(u8, 0x48), inst[0]); // REX.W
    try std.testing.expectEqual(@as(u8, 0xB8), inst[1]); // B8+rd
    try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, inst[2..10], .little));
}

test "MOV r64, r64" {
    // MOV RAX, RBX
    const inst = encodeMovRegReg(.rax, .rbx);
    try std.testing.expectEqual(@as(u8, 0x48), inst[0]); // REX.W
    try std.testing.expectEqual(@as(u8, 0x89), inst[1]); // opcode
    try std.testing.expectEqual(@as(u8, 0xD8), inst[2]); // ModR/M: 11 011 000

    // MOV R8, R15
    const inst2 = encodeMovRegReg(.r8, .r15);
    try std.testing.expectEqual(@as(u8, 0x4D), inst2[0]); // REX.W + REX.R + REX.B
}

test "RET" {
    const inst = encodeRet();
    try std.testing.expectEqual(@as(u8, 0xC3), inst[0]);
}

test "CALL rel32" {
    const inst = encodeCall(0x12345678);
    try std.testing.expectEqual(@as(u8, 0xE8), inst[0]);
    try std.testing.expectEqual(@as(i32, 0x12345678), std.mem.readInt(i32, inst[1..5], .little));
}

test "PUSH/POP" {
    // PUSH RAX (no REX needed)
    const push_rax = encodePush(.rax);
    try std.testing.expectEqual(@as(u8, 1), push_rax.len);
    try std.testing.expectEqual(@as(u8, 0x50), push_rax.data[0]);

    // PUSH R8 (needs REX.B)
    const push_r8 = encodePush(.r8);
    try std.testing.expectEqual(@as(u8, 2), push_r8.len);
    try std.testing.expectEqual(@as(u8, 0x41), push_r8.data[0]);
    try std.testing.expectEqual(@as(u8, 0x50), push_r8.data[1]);

    // POP RBP (no REX needed)
    const pop_rbp = encodePop(.rbp);
    try std.testing.expectEqual(@as(u8, 1), pop_rbp.len);
    try std.testing.expectEqual(@as(u8, 0x5D), pop_rbp.data[0]);
}

test "ADD r64, r64" {
    // ADD RAX, RBX
    const inst = encodeAddRegReg(.rax, .rbx);
    try std.testing.expectEqual(@as(u8, 0x48), inst[0]); // REX.W
    try std.testing.expectEqual(@as(u8, 0x01), inst[1]); // opcode
}

test "SUB r64, r64" {
    const inst = encodeSubRegReg(.rax, .rbx);
    try std.testing.expectEqual(@as(u8, 0x48), inst[0]);
    try std.testing.expectEqual(@as(u8, 0x29), inst[1]);
}

test "IMUL r64, r64" {
    // IMUL RAX, RBX
    const inst = encodeImulRegReg(.rax, .rbx);
    try std.testing.expectEqual(@as(u8, 0x48), inst[0]); // REX.W
    try std.testing.expectEqual(@as(u8, 0x0F), inst[1]);
    try std.testing.expectEqual(@as(u8, 0xAF), inst[2]);
}

test "CQO and IDIV" {
    const cqo = encodeCqo();
    try std.testing.expectEqual(@as(u8, 0x48), cqo[0]);
    try std.testing.expectEqual(@as(u8, 0x99), cqo[1]);

    const idiv = encodeIdivReg(.rbx);
    try std.testing.expectEqual(@as(u8, 0x48), idiv[0]);
    try std.testing.expectEqual(@as(u8, 0xF7), idiv[1]);
}

test "Jcc rel32" {
    // JE +0x100
    const inst = encodeJccRel32(.e, 0x100);
    try std.testing.expectEqual(@as(u8, 0x0F), inst[0]);
    try std.testing.expectEqual(@as(u8, 0x84), inst[1]); // JE
}

test "Emitter" {
    const allocator = std.testing.allocator;
    var emitter = Emitter.init(allocator);
    defer emitter.deinit();

    try emitter.emit(1, encodeRet());
    try emitter.emit(10, encodeMovRegImm64(.rax, 42));

    try std.testing.expectEqual(@as(usize, 11), emitter.code().len);
}

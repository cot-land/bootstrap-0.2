//! AMD64 Register Definitions
//!
//! Defines AMD64/x86-64 registers and System V ABI constants.
//! Reference: System V AMD64 ABI (https://refspecs.linuxbase.org/elf/x86_64-abi-0.99.pdf)
//!
//! ## Register Naming
//!
//! AMD64 has 16 general-purpose 64-bit registers:
//! - RAX, RBX, RCX, RDX: Legacy 8086 registers (extended to 64-bit)
//! - RSI, RDI: Source/Destination index registers
//! - RBP, RSP: Base/Stack pointer registers
//! - R8-R15: New AMD64 registers
//!
//! Lower portions can be accessed with different names:
//! - 32-bit: EAX, EBX, etc. (writing clears upper 32 bits)
//! - 16-bit: AX, BX, etc.
//! - 8-bit: AL, AH, BL, BH, etc.

const std = @import("std");

/// AMD64 register numbers.
/// Uses the standard AMD64 encoding (0-15).
pub const Reg = enum(u4) {
    rax = 0, // Accumulator, return value
    rcx = 1, // Counter, 4th argument
    rdx = 2, // Data, 3rd argument
    rbx = 3, // Base, callee-saved
    rsp = 4, // Stack pointer
    rbp = 5, // Base pointer, callee-saved
    rsi = 6, // Source index, 2nd argument
    rdi = 7, // Destination index, 1st argument
    r8 = 8, // 5th argument
    r9 = 9, // 6th argument
    r10 = 10, // Temporary
    r11 = 11, // Temporary
    r12 = 12, // Callee-saved
    r13 = 13, // Callee-saved
    r14 = 14, // Callee-saved
    r15 = 15, // Callee-saved

    /// Get the 4-bit encoding for ModR/M
    pub fn enc(self: Reg) u4 {
        return @intFromEnum(self);
    }

    /// Get 3-bit base encoding (lower 3 bits)
    pub fn enc3(self: Reg) u3 {
        return @truncate(@intFromEnum(self));
    }

    /// Does this register require REX.B or REX.R extension?
    pub fn needsRex(self: Reg) bool {
        return @intFromEnum(self) >= 8;
    }

    /// Get register name for debug output
    pub fn name(self: Reg) []const u8 {
        return switch (self) {
            .rax => "rax",
            .rcx => "rcx",
            .rdx => "rdx",
            .rbx => "rbx",
            .rsp => "rsp",
            .rbp => "rbp",
            .rsi => "rsi",
            .rdi => "rdi",
            .r8 => "r8",
            .r9 => "r9",
            .r10 => "r10",
            .r11 => "r11",
            .r12 => "r12",
            .r13 => "r13",
            .r14 => "r14",
            .r15 => "r15",
        };
    }

    /// Get 32-bit register name (for smaller operands)
    pub fn name32(self: Reg) []const u8 {
        return switch (self) {
            .rax => "eax",
            .rcx => "ecx",
            .rdx => "edx",
            .rbx => "ebx",
            .rsp => "esp",
            .rbp => "ebp",
            .rsi => "esi",
            .rdi => "edi",
            .r8 => "r8d",
            .r9 => "r9d",
            .r10 => "r10d",
            .r11 => "r11d",
            .r12 => "r12d",
            .r13 => "r13d",
            .r14 => "r14d",
            .r15 => "r15d",
        };
    }
};

// =========================================
// System V AMD64 ABI
// =========================================

/// System V AMD64 ABI constants.
/// Reference: System V ABI AMD64 Architecture Processor Supplement
pub const AMD64 = struct {
    /// Number of integer registers for parameter passing
    pub const int_param_regs: u8 = 6;

    /// Number of integer registers for return values (RAX, RDX)
    pub const int_result_regs: u8 = 2;

    /// Maximum aggregate size that fits in registers (16 bytes = 2 x 8-byte regs)
    pub const max_reg_aggregate: u32 = 16;

    /// Stack alignment (16 bytes before CALL instruction)
    pub const stack_align: u32 = 16;

    /// Register size in bytes
    pub const reg_size: u32 = 8;

    /// Red zone size (area below RSP that can be used without adjusting RSP)
    /// Only in leaf functions that don't call other functions
    pub const red_zone_size: u32 = 128;

    /// Integer argument registers in order: RDI, RSI, RDX, RCX, R8, R9
    pub const arg_regs = [_]Reg{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };

    /// Integer return registers: RAX (and RDX for 128-bit returns)
    pub const ret_regs = [_]Reg{ .rax, .rdx };

    /// Caller-saved (volatile) registers: RAX, RCX, RDX, RSI, RDI, R8-R11
    /// These may be clobbered by any function call.
    pub const caller_saved = [_]Reg{
        .rax, .rcx, .rdx, .rsi, .rdi, .r8, .r9, .r10, .r11,
    };

    /// Callee-saved (non-volatile) registers: RBX, RBP, R12-R15
    /// Functions must preserve these across calls.
    pub const callee_saved = [_]Reg{
        .rbx, .rbp, .r12, .r13, .r14, .r15,
    };

    /// Caller-saved register mask (bits 0-15 for RAX-R15)
    /// RAX(0), RCX(1), RDX(2), RSI(6), RDI(7), R8-R11(8-11)
    pub const caller_save_mask: u32 = (1 << 0) | // RAX
        (1 << 1) | // RCX
        (1 << 2) | // RDX
        (1 << 6) | // RSI
        (1 << 7) | // RDI
        (1 << 8) | // R8
        (1 << 9) | // R9
        (1 << 10) | // R10
        (1 << 11); // R11

    /// Callee-saved register mask
    /// RBX(3), RBP(5), R12-R15(12-15)
    pub const callee_save_mask: u32 = (1 << 3) | // RBX
        (1 << 5) | // RBP
        (1 << 12) | // R12
        (1 << 13) | // R13
        (1 << 14) | // R14
        (1 << 15); // R15

    /// Argument register mask (RDI, RSI, RDX, RCX, R8, R9)
    pub const arg_regs_mask: u32 = (1 << 7) | // RDI
        (1 << 6) | // RSI
        (1 << 2) | // RDX
        (1 << 1) | // RCX
        (1 << 8) | // R8
        (1 << 9); // R9

    /// Allocatable registers (excludes RSP)
    pub const allocatable_mask: u32 = 0xFFFF & ~(1 << 4); // All except RSP

    /// Convert argument index (0-5) to register
    pub fn argReg(idx: u8) Reg {
        return arg_regs[idx];
    }

    /// Get register mask for a single register
    pub fn regMask(reg: Reg) u32 {
        return @as(u32, 1) << @intFromEnum(reg);
    }
};

// =========================================
// Tests
// =========================================

test "register encoding" {
    try std.testing.expectEqual(@as(u4, 0), Reg.rax.enc());
    try std.testing.expectEqual(@as(u4, 7), Reg.rdi.enc());
    try std.testing.expectEqual(@as(u4, 8), Reg.r8.enc());
    try std.testing.expectEqual(@as(u4, 15), Reg.r15.enc());
}

test "register REX requirements" {
    try std.testing.expect(!Reg.rax.needsRex());
    try std.testing.expect(!Reg.rdi.needsRex());
    try std.testing.expect(Reg.r8.needsRex());
    try std.testing.expect(Reg.r15.needsRex());
}

test "ABI argument registers" {
    try std.testing.expectEqual(Reg.rdi, AMD64.arg_regs[0]);
    try std.testing.expectEqual(Reg.rsi, AMD64.arg_regs[1]);
    try std.testing.expectEqual(Reg.rdx, AMD64.arg_regs[2]);
    try std.testing.expectEqual(Reg.rcx, AMD64.arg_regs[3]);
    try std.testing.expectEqual(Reg.r8, AMD64.arg_regs[4]);
    try std.testing.expectEqual(Reg.r9, AMD64.arg_regs[5]);
}

test "register masks" {
    try std.testing.expectEqual(@as(u32, 1), AMD64.regMask(.rax));
    try std.testing.expectEqual(@as(u32, 0x100), AMD64.regMask(.r8));
}

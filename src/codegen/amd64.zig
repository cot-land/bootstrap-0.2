//! AMD64 code generation.
//!
//! Go reference: [cmd/compile/internal/amd64/ssa.go]
//!
//! Generates optimized AMD64 code with register allocation.
//! Supports Linux System V ABI.
//!
//! ## Design
//!
//! - Uses linear scan register allocation from regalloc.zig
//! - Targets x86-64 / AMD64
//! - Generates proper ABI-compliant code
//! - Uses amd64/asm.zig for machine code encoding
//!
//! ## Related Modules
//!
//! - [arm64.zig] - ARM64 code generator (reference)
//! - [ssa/op.zig] - SSA operations
//! - [ssa/regalloc.zig] - Register allocation
//! - [amd64/asm.zig] - Instruction encoding
//! - [obj/elf.zig] - ELF object file output

const std = @import("std");
const Func = @import("../ssa/func.zig").Func;
const Block = @import("../ssa/block.zig").Block;
const value_mod = @import("../ssa/value.zig");
const Value = value_mod.Value;
const AuxCall = value_mod.AuxCall;
const Op = @import("../ssa/op.zig").Op;
const asm_mod = @import("../amd64/asm.zig");
const regs = @import("../amd64/regs.zig");
const Reg = regs.Reg;
const regalloc = @import("../ssa/regalloc.zig");
const elf = @import("../obj/elf.zig");
const debug = @import("../pipeline_debug.zig");
const types_mod = @import("../frontend/types.zig");
const TypeRegistry = types_mod.TypeRegistry;
const TypeIndex = types_mod.TypeIndex;
const ir_mod = @import("../frontend/ir.zig");

/// Relocation entry for function calls.
pub const Relocation = struct {
    /// Offset in code where CALL instruction's rel32 is located
    offset: u32,
    /// Target symbol name
    target: []const u8,
};

/// Branch fixup entry for patching branch targets after code generation.
const BranchFixup = struct {
    /// Offset in code where the branch instruction is located (at rel32)
    code_offset: u32,
    /// Target block ID to branch to
    target_block_id: u32,
    /// Instruction type for size calculation
    is_jcc: bool, // true = Jcc (6 bytes), false = JMP (5 bytes)
};

/// Reference to a string literal that needs relocation
const StringRef = struct {
    /// Offset in code where the LEA/MOV instruction is
    code_offset: u32,
    /// Actual string data (owned copy)
    string_data: []const u8,
};

/// AMD64 code generator.
pub const AMD64CodeGen = struct {
    allocator: std.mem.Allocator,
    func: *const Func,

    /// Type registry for looking up composite type sizes
    type_reg: ?*const TypeRegistry = null,

    /// Generated machine code bytes
    code: std.ArrayListUnmanaged(u8),

    /// Symbols for object file
    symbols: std.ArrayListUnmanaged(elf.Symbol),

    /// Relocations for function calls
    relocations: std.ArrayListUnmanaged(Relocation),

    /// Register allocation results (borrowed reference)
    regalloc_state: ?*const regalloc.RegAllocState,

    /// Stack frame size for spilled values
    frame_size: u32 = 16, // Default: just RBP

    /// Block ID → code offset mapping (for branch calculations)
    block_offsets: std.AutoHashMapUnmanaged(u32, u32),

    /// Pending branch fixups
    branch_fixups: std.ArrayListUnmanaged(BranchFixup),

    /// Pending string references
    string_refs: std.ArrayListUnmanaged(StringRef),

    /// Global variables to emit in data section
    globals: []const ir_mod.Global = &.{},

    /// Debug info
    debug_source_file: []const u8 = "",
    debug_source_text: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) AMD64CodeGen {
        return .{
            .allocator = allocator,
            .func = undefined,
            .code = .{},
            .symbols = .{},
            .relocations = .{},
            .regalloc_state = null,
            .block_offsets = .{},
            .branch_fixups = .{},
            .string_refs = .{},
        };
    }

    pub fn deinit(self: *AMD64CodeGen) void {
        self.code.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.relocations.deinit(self.allocator);
        self.block_offsets.deinit(self.allocator);
        self.branch_fixups.deinit(self.allocator);
        // Free string data copies
        for (self.string_refs.items) |str_ref| {
            self.allocator.free(str_ref.string_data);
        }
        self.string_refs.deinit(self.allocator);
    }

    /// Set the register allocation state.
    pub fn setRegAllocState(self: *AMD64CodeGen, state: *const regalloc.RegAllocState) void {
        self.regalloc_state = state;
    }

    /// Set the stack frame size.
    pub fn setFrameSize(self: *AMD64CodeGen, size: u32) void {
        self.frame_size = size;
    }

    /// Set global variables.
    pub fn setGlobals(self: *AMD64CodeGen, globs: []const ir_mod.Global) void {
        self.globals = globs;
    }

    /// Set type registry.
    pub fn setTypeRegistry(self: *AMD64CodeGen, reg: *const TypeRegistry) void {
        self.type_reg = reg;
    }

    /// Set debug info.
    pub fn setDebugInfo(self: *AMD64CodeGen, source_file: []const u8, source_text: []const u8) void {
        self.debug_source_file = source_file;
        self.debug_source_text = source_text;
    }

    /// Get the size of a type in bytes.
    fn getTypeSize(self: *const AMD64CodeGen, type_idx: TypeIndex) u8 {
        if (type_idx < TypeRegistry.FIRST_USER_TYPE) {
            return TypeRegistry.basicTypeSize(type_idx);
        }
        if (self.type_reg) |reg| {
            return @intCast(reg.sizeOf(type_idx));
        }
        return TypeRegistry.basicTypeSize(type_idx);
    }

    /// Current code offset
    fn offset(self: *const AMD64CodeGen) u32 {
        return @intCast(self.code.items.len);
    }

    /// Emit bytes to code buffer
    fn emitBytes(self: *AMD64CodeGen, bytes: []const u8) !void {
        try self.code.appendSlice(self.allocator, bytes);
    }

    /// Emit a fixed-size instruction
    fn emit(self: *AMD64CodeGen, comptime N: usize, bytes: [N]u8) !void {
        try self.code.appendSlice(self.allocator, &bytes);
    }

    // ========================================================================
    // Register Mapping
    // ========================================================================

    /// Map regalloc register number to AMD64 register.
    /// ARM64 codegen uses x0-x28, we use a similar mapping.
    fn regNumToAMD64(reg_num: u5) Reg {
        return switch (reg_num) {
            0 => .rax,
            1 => .rcx,
            2 => .rdx,
            3 => .rbx,
            4 => .rsp, // Should not be used for values
            5 => .rbp, // Frame pointer
            6 => .rsi,
            7 => .rdi,
            8 => .r8,
            9 => .r9,
            10 => .r10,
            11 => .r11,
            12 => .r12,
            13 => .r13,
            14 => .r14,
            15 => .r15,
            else => .rax, // Fallback
        };
    }

    /// Get destination register for a value from regalloc.
    /// First checks regalloc_state.values[].regs, then falls back to value.getHome().
    fn getDestRegForValue(self: *AMD64CodeGen, value: *const Value) Reg {
        // First try regalloc_state
        if (self.regalloc_state) |state| {
            if (value.id < state.values.len) {
                const val_state = state.values[value.id];
                if (val_state.firstReg()) |reg_num| {
                    return regNumToAMD64(@intCast(reg_num));
                }
            }
        }
        // Fall back to home assignment
        if (value.getHome()) |loc| {
            switch (loc) {
                .register => |reg_num| return regNumToAMD64(@intCast(reg_num)),
                .stack => {}, // Fall through to RAX fallback
            }
        }
        // Fallback: use RAX
        return .rax;
    }

    /// Get register for a value that's already been computed.
    /// First checks regalloc_state.values[].regs, then falls back to value.getHome().
    /// The regs mask may be cleared when a value becomes "dead" after its last use,
    /// but the home assignment persists.
    fn getRegForValue(self: *AMD64CodeGen, value: *const Value) ?Reg {
        // First try regalloc_state (for values still "live" in regalloc terms)
        if (self.regalloc_state) |state| {
            if (value.id < state.values.len) {
                const val_state = state.values[value.id];
                if (val_state.firstReg()) |reg_num| {
                    return regNumToAMD64(@intCast(reg_num));
                }
            }
        }
        // Fall back to home assignment (persists even after value is "dead")
        if (value.getHome()) |loc| {
            switch (loc) {
                .register => |reg_num| return regNumToAMD64(@intCast(reg_num)),
                .stack => return null, // Value is spilled, not in a register
            }
        }
        return null;
    }

    /// Ensure a value is in a register, loading from spill slot if needed.
    fn ensureInReg(self: *AMD64CodeGen, value: *const Value, hint_reg: Reg) !void {
        // Check if already in a register
        if (self.getRegForValue(value)) |_| {
            return; // Already in register
        }

        // Need to reload from spill slot or rematerialize
        switch (value.op) {
            .const_int, .const_64 => {
                // Rematerialize constant
                try self.emitLoadImmediate(hint_reg, value.aux_int);
            },
            .const_bool => {
                const imm: i64 = if (value.aux_int != 0) 1 else 0;
                try self.emitLoadImmediate(hint_reg, imm);
            },
            .const_nil => {
                // Zero the register
                try self.emit(3, asm_mod.encodeXorRegReg(hint_reg, hint_reg));
            },
            .local_addr => {
                // Rematerialize local address: LEA hint_reg, [RBP - offset]
                const local_idx: usize = @intCast(value.aux_int);
                if (local_idx < self.func.local_offsets.len and local_idx < self.func.local_sizes.len) {
                    const byte_offset = self.func.local_offsets[local_idx];
                    const local_size: i32 = @intCast(self.func.local_sizes[local_idx]);
                    // Use END of allocation to prevent overflow into saved RBP
                    const disp: i32 = -(byte_offset + local_size);
                    const lea = asm_mod.encodeLeaDisp32(hint_reg, .rbp, disp);
                    try self.emitBytes(lea.data[0..lea.len]);
                } else {
                    const lea = asm_mod.encodeLeaDisp32(hint_reg, .rbp, 0);
                    try self.emitBytes(lea.data[0..lea.len]);
                }
            },
            .load => {
                // Need to regenerate the load
                if (value.args.len > 0) {
                    const addr_val = value.args[0];
                    // Get the address register
                    const addr_reg = self.getRegForValue(addr_val) orelse blk: {
                        // Use a different scratch register for address
                        const scratch: Reg = if (hint_reg == .r11) .r10 else .r11;
                        try self.ensureInReg(addr_val, scratch);
                        break :blk scratch;
                    };
                    // Emit load
                    const type_size = self.getTypeSize(value.type_idx);
                    if (type_size == 1) {
                        const load = asm_mod.encodeLoadByteDisp32(hint_reg, addr_reg, 0);
                        try self.emitBytes(load.data[0..load.len]);
                    } else if (type_size == 2) {
                        const load = asm_mod.encodeLoadWordDisp32(hint_reg, addr_reg, 0);
                        try self.emitBytes(load.data[0..load.len]);
                    } else if (type_size == 4) {
                        const load = asm_mod.encodeLoadDwordDisp32(hint_reg, addr_reg, 0);
                        try self.emitBytes(load.data[0..load.len]);
                    } else {
                        const load = asm_mod.encodeLoadDisp32(hint_reg, addr_reg, 0);
                        try self.emitBytes(load.data[0..load.len]);
                    }
                }
            },
            .const_string, .const_ptr => {
                // Rematerialize string literal address via LEA
                const string_index: usize = @intCast(value.aux_int);
                const str_data = if (string_index < self.func.string_literals.len)
                    self.func.string_literals[string_index]
                else
                    "";

                const lea_offset = self.offset();
                try self.emit(7, asm_mod.encodeLeaRipRel32(hint_reg, 0));

                // Record string reference for relocation
                const str_copy = try self.allocator.dupe(u8, str_data);
                try self.string_refs.append(self.allocator, .{
                    .code_offset = lea_offset,
                    .string_data = str_copy,
                });
            },
            .arg => {
                // Rematerialize function argument from ABI register
                // Note: This assumes we haven't called any functions that clobber arg registers
                const arg_idx: usize = @intCast(value.aux_int);
                if (arg_idx < regs.AMD64.arg_regs.len) {
                    const src_reg = regs.AMD64.arg_regs[arg_idx];
                    if (hint_reg != src_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(hint_reg, src_reg));
                    }
                } else {
                    // Stack argument - load from caller's stack frame
                    const stack_offset: i32 = @intCast(16 + (arg_idx - 6) * 8);
                    const load = asm_mod.encodeLoadDisp32(hint_reg, .rbp, stack_offset);
                    try self.emitBytes(load.data[0..load.len]);
                }
            },
            .off_ptr => {
                // Rematerialize pointer offset: LEA hint_reg, [base + offset]
                if (value.args.len > 0) {
                    const base = value.args[0];
                    const field_offset: i64 = value.aux_int;

                    // First get or rematerialize the base pointer
                    var base_reg: Reg = undefined;
                    if (base.op == .local_addr) {
                        // Rematerialize local address first
                        const local_idx: usize = @intCast(base.aux_int);
                        if (local_idx < self.func.local_offsets.len and local_idx < self.func.local_sizes.len) {
                            const local_offset = self.func.local_offsets[local_idx];
                            const local_size: i32 = @intCast(self.func.local_sizes[local_idx]);
                            const disp: i32 = -(local_offset + local_size);
                            const lea = asm_mod.encodeLeaDisp32(hint_reg, .rbp, disp);
                            try self.emitBytes(lea.data[0..lea.len]);
                            base_reg = hint_reg;
                        } else {
                            const lea = asm_mod.encodeLeaDisp32(hint_reg, .rbp, 0);
                            try self.emitBytes(lea.data[0..lea.len]);
                            base_reg = hint_reg;
                        }
                    } else {
                        base_reg = self.getRegForValue(base) orelse blk: {
                            // Use different scratch register for base
                            const scratch: Reg = if (hint_reg == .r11) .r10 else .r11;
                            try self.ensureInReg(base, scratch);
                            break :blk scratch;
                        };
                    }

                    // Now add the offset
                    if (field_offset != 0) {
                        const disp: i32 = @intCast(field_offset);
                        const lea = asm_mod.encodeLeaDisp32(hint_reg, base_reg, disp);
                        try self.emitBytes(lea.data[0..lea.len]);
                    } else if (base_reg != hint_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(hint_reg, base_reg));
                    }
                }
            },
            .add_ptr => {
                // Rematerialize pointer addition: hint_reg = base + offset
                if (value.args.len >= 2) {
                    const base = value.args[0];
                    const off_val = value.args[1];

                    // Get or rematerialize base pointer
                    var base_reg: Reg = undefined;
                    if (base.op == .local_addr) {
                        const local_idx: usize = @intCast(base.aux_int);
                        if (local_idx < self.func.local_offsets.len and local_idx < self.func.local_sizes.len) {
                            const local_offset = self.func.local_offsets[local_idx];
                            const local_size: i32 = @intCast(self.func.local_sizes[local_idx]);
                            const disp: i32 = -(local_offset + local_size);
                            const lea = asm_mod.encodeLeaDisp32(hint_reg, .rbp, disp);
                            try self.emitBytes(lea.data[0..lea.len]);
                            base_reg = hint_reg;
                        } else {
                            const lea = asm_mod.encodeLeaDisp32(hint_reg, .rbp, 0);
                            try self.emitBytes(lea.data[0..lea.len]);
                            base_reg = hint_reg;
                        }
                    } else {
                        base_reg = self.getRegForValue(base) orelse blk: {
                            const scratch: Reg = if (hint_reg == .r11) .r10 else .r11;
                            try self.ensureInReg(base, scratch);
                            break :blk scratch;
                        };
                    }

                    // Get or rematerialize offset
                    const off_reg = self.getRegForValue(off_val) orelse blk: {
                        const scratch: Reg = if (hint_reg == .r10 or base_reg == .r10) .r11 else .r10;
                        try self.ensureInReg(off_val, scratch);
                        break :blk scratch;
                    };

                    // LEA hint_reg, [base + off]
                    const lea = asm_mod.encodeLeaBaseIndex(hint_reg, base_reg, off_reg);
                    try self.emitBytes(lea.data[0..lea.len]);
                }
            },
            .mul => {
                // Rematerialize multiplication - ARM64 style
                if (value.args.len >= 2) {
                    const op1 = value.args[0];
                    const op2 = value.args[1];

                    var op1_scratch: Reg = .r10;
                    var op2_scratch: Reg = .r11;
                    if (hint_reg == .r10) {
                        op1_scratch = .r11;
                        op2_scratch = .rax;
                    } else if (hint_reg == .r11) {
                        op1_scratch = .r10;
                        op2_scratch = .rax;
                    }

                    const op1_reg = self.getRegForValue(op1) orelse blk: {
                        try self.ensureInReg(op1, op1_scratch);
                        break :blk op1_scratch;
                    };

                    const op2_reg = self.getRegForValue(op2) orelse blk: {
                        try self.ensureInReg(op2, op2_scratch);
                        break :blk op2_scratch;
                    };

                    // MOV hint_reg, op1
                    if (hint_reg != op1_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(hint_reg, op1_reg));
                    }
                    // IMUL hint_reg, op2
                    try self.emit(4, asm_mod.encodeImulRegReg(hint_reg, op2_reg));
                }
            },
            .add => {
                // Rematerialize addition - ARM64 style with fixed scratch registers
                if (value.args.len >= 2) {
                    const op1 = value.args[0];
                    const op2 = value.args[1];

                    // Choose scratch registers that don't conflict with each other or hint_reg
                    // We need 2 distinct scratch registers, neither equal to hint_reg
                    var op1_scratch: Reg = .r10;
                    var op2_scratch: Reg = .r11;
                    if (hint_reg == .r10) {
                        op1_scratch = .r11;
                        op2_scratch = .rax;
                    } else if (hint_reg == .r11) {
                        op1_scratch = .r10;
                        op2_scratch = .rax;
                    }

                    const op1_reg = self.getRegForValue(op1) orelse blk: {
                        try self.ensureInReg(op1, op1_scratch);
                        break :blk op1_scratch;
                    };

                    const op2_reg = self.getRegForValue(op2) orelse blk: {
                        try self.ensureInReg(op2, op2_scratch);
                        break :blk op2_scratch;
                    };

                    if (hint_reg != op1_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(hint_reg, op1_reg));
                    }
                    try self.emit(3, asm_mod.encodeAddRegReg(hint_reg, op2_reg));
                }
            },
            .sub => {
                // Rematerialize subtraction - ARM64 style
                // For SUB (non-commutative), order matters: result = op1 - op2
                if (value.args.len >= 2) {
                    const op1 = value.args[0];
                    const op2 = value.args[1];

                    var op1_scratch: Reg = .r10;
                    var op2_scratch: Reg = .r11;
                    if (hint_reg == .r10) {
                        op1_scratch = .r11;
                        op2_scratch = .rax;
                    } else if (hint_reg == .r11) {
                        op1_scratch = .r10;
                        op2_scratch = .rax;
                    }

                    const op1_reg = self.getRegForValue(op1) orelse blk: {
                        try self.ensureInReg(op1, op1_scratch);
                        break :blk op1_scratch;
                    };

                    const op2_reg = self.getRegForValue(op2) orelse blk: {
                        try self.ensureInReg(op2, op2_scratch);
                        break :blk op2_scratch;
                    };

                    if (hint_reg != op1_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(hint_reg, op1_reg));
                    }
                    try self.emit(3, asm_mod.encodeSubRegReg(hint_reg, op2_reg));
                }
            },
            .copy => {
                // Copy needs to trace through to the source value
                if (value.args.len > 0) {
                    try self.ensureInReg(value.args[0], hint_reg);
                }
            },
            .string_make => {
                // For string_make, we need the ptr component (first arg)
                // This is used when a string is passed as an argument to a function
                if (value.args.len > 0) {
                    try self.ensureInReg(value.args[0], hint_reg);
                }
            },
            .static_call => {
                // Function call result is in RAX (System V ABI)
                // The value should have a spill slot if it lived across another call
                if (value.getHome()) |loc| {
                    switch (loc) {
                        .stack => |byte_off| {
                            const disp: i32 = -@as(i32, @intCast(byte_off));
                            const load = asm_mod.encodeLoadDisp32(hint_reg, .rbp, disp);
                            try self.emitBytes(load.data[0..load.len]);
                            debug.log(.codegen, "      reload static_call from [RBP{d}] to {s}", .{ disp, hint_reg.name() });
                        },
                        .register => |reg_num| {
                            const src_reg = regNumToAMD64(@intCast(reg_num));
                            if (src_reg != hint_reg) {
                                try self.emit(3, asm_mod.encodeMovRegReg(hint_reg, src_reg));
                                debug.log(.codegen, "      reload static_call from {s} to {s}", .{ src_reg.name(), hint_reg.name() });
                            }
                        },
                    }
                } else {
                    // Fallback: result should be in RAX
                    if (hint_reg != .rax) {
                        try self.emit(3, asm_mod.encodeMovRegReg(hint_reg, .rax));
                        debug.log(.codegen, "      reload static_call from RAX to {s}", .{hint_reg.name()});
                    }
                }
            },
            .eq, .ne, .lt, .le, .gt, .ge => {
                // Comparison operations need to be rematerialized by re-doing the comparison
                // This happens when regalloc hasn't assigned a persistent register to the result
                if (value.args.len >= 2) {
                    // Get operands - be careful not to clobber each other
                    const op2_reg = self.getRegForValue(value.args[1]) orelse blk: {
                        try self.ensureInReg(value.args[1], .rcx);
                        break :blk Reg.rcx;
                    };
                    const op1_reg = self.getRegForValue(value.args[0]) orelse blk: {
                        const scratch: Reg = if (op2_reg == .rax) .rdx else .rax;
                        try self.ensureInReg(value.args[0], scratch);
                        break :blk scratch;
                    };

                    // CMP op1, op2
                    try self.emit(3, asm_mod.encodeCmpRegReg(op1_reg, op2_reg));

                    // SETcc hint_reg
                    const cond: asm_mod.Cond = switch (value.op) {
                        .eq => .e,
                        .ne => .ne,
                        .lt => .l,
                        .le => .le,
                        .gt => .g,
                        .ge => .ge,
                        else => .e,
                    };
                    try self.emit(4, asm_mod.encodeSetcc(cond, hint_reg));
                    try self.emit(4, asm_mod.encodeMovzxRegReg8(hint_reg, hint_reg));
                    debug.log(.codegen, "      rematerialize comparison {s} to {s}", .{ @tagName(value.op), hint_reg.name() });
                }
            },
            .neg => {
                // Rematerialize negation
                if (value.args.len >= 1) {
                    const op_reg = self.getRegForValue(value.args[0]) orelse blk: {
                        const scratch: Reg = if (hint_reg == .rax) .rcx else .rax;
                        try self.ensureInReg(value.args[0], scratch);
                        break :blk scratch;
                    };
                    if (hint_reg != op_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(hint_reg, op_reg));
                    }
                    try self.emit(3, asm_mod.encodeNegReg(hint_reg));
                    debug.log(.codegen, "      rematerialize neg to {s}", .{hint_reg.name()});
                }
            },
            .not => {
                // Rematerialize bitwise not
                if (value.args.len >= 1) {
                    const op_reg = self.getRegForValue(value.args[0]) orelse blk: {
                        const scratch: Reg = if (hint_reg == .rax) .rcx else .rax;
                        try self.ensureInReg(value.args[0], scratch);
                        break :blk scratch;
                    };
                    if (hint_reg != op_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(hint_reg, op_reg));
                    }
                    try self.emit(3, asm_mod.encodeNotReg(hint_reg));
                    debug.log(.codegen, "      rematerialize not to {s}", .{hint_reg.name()});
                }
            },
            else => {
                // Load from spill slot if available
                if (value.getHome()) |loc| {
                    switch (loc) {
                        .stack => |byte_off| {
                            const disp: i32 = -byte_off;
                            const load = asm_mod.encodeLoadDisp32(hint_reg, .rbp, disp);
                            try self.emitBytes(load.data[0..load.len]);
                            debug.log(.codegen, "      reload {s} from [RBP{d}] to {s}", .{ @tagName(value.op), disp, hint_reg.name() });
                        },
                        .register => |reg_num| {
                            debug.log(.codegen, "      ensureInReg: home.register={d}", .{reg_num});
                            const src_reg = regNumToAMD64(@intCast(reg_num));
                            if (src_reg != hint_reg) {
                                try self.emit(3, asm_mod.encodeMovRegReg(hint_reg, src_reg));
                                debug.log(.codegen, "      reload {s} from {s} to {s}", .{ @tagName(value.op), src_reg.name(), hint_reg.name() });
                            }
                        },
                    }
                } else {
                    debug.log(.codegen, "WARNING: ensureInReg fallback for {s}", .{@tagName(value.op)});
                }
            },
        }
    }

    /// Setup call arguments with parallel copy to avoid clobbering.
    /// Returns the stack cleanup amount in bytes.
    fn setupCallArgs(self: *AMD64CodeGen, args: []*Value) !usize {
        if (args.len == 0) return 0;

        // Handle stack arguments first (args beyond the first 6)
        const num_stack_args: usize = if (args.len > 6) args.len - 6 else 0;
        var stack_cleanup: usize = 0;

        if (num_stack_args > 0) {
            // Push stack arguments in reverse order
            var i: usize = args.len;
            while (i > 6) {
                i -= 1;
                const arg = args[i];
                if (self.getRegForValue(arg)) |src_reg| {
                    const push = asm_mod.encodePush(src_reg);
                    try self.emitBytes(push.data[0..push.len]);
                } else {
                    try self.ensureInReg(arg, .rax);
                    const push = asm_mod.encodePush(.rax);
                    try self.emitBytes(push.data[0..push.len]);
                }
                debug.log(.codegen, "      PUSH (stack arg {d})", .{i});
            }
            stack_cleanup = num_stack_args * 8;
        }

        // Collect register argument moves
        const max_reg_args = @min(args.len, 6);
        const Move = struct {
            src: ?Reg, // null if value needs rematerialization
            dest: Reg,
            value: *Value,
            done: bool,
        };

        var moves: [6]Move = undefined;
        var num_moves: usize = 0;

        for (args[0..max_reg_args], 0..) |arg, i| {
            const dest = regs.AMD64.arg_regs[i];
            const src = self.getRegForValue(arg);
            moves[num_moves] = .{
                .src = src,
                .dest = dest,
                .value = arg,
                .done = (src != null and src.? == dest), // Already in correct register
            };
            num_moves += 1;
        }

        // Process moves that don't conflict first (dest doesn't clobber any needed source)
        var progress = true;
        while (progress) {
            progress = false;
            for (0..num_moves) |mi| {
                if (moves[mi].done) continue;

                // Check if this move's dest would clobber a source we still need
                var would_clobber = false;
                for (0..num_moves) |oi| {
                    if (moves[oi].done) continue;
                    if (moves[oi].src) |other_src| {
                        if (other_src == moves[mi].dest and oi != mi) {
                            would_clobber = true;
                            break;
                        }
                    }
                }

                if (!would_clobber) {
                    // Safe to do this move
                    if (moves[mi].src) |src| {
                        try self.emit(3, asm_mod.encodeMovRegReg(moves[mi].dest, src));
                        debug.log(.codegen, "      arg move: {s} -> {s}", .{ src.name(), moves[mi].dest.name() });
                    } else {
                        // Rematerialize value directly to dest
                        try self.ensureInReg(moves[mi].value, moves[mi].dest);
                    }
                    moves[mi].done = true;
                    progress = true;
                }
            }
        }

        // Handle any remaining cycles using R11 as temp
        for (0..num_moves) |mi| {
            if (moves[mi].done) continue;

            if (moves[mi].src) |start_src| {
                // Save the starting value to R11
                try self.emit(3, asm_mod.encodeMovRegReg(.r11, start_src));
                debug.log(.codegen, "      cycle: save {s} -> R11", .{start_src.name()});

                // Trace and execute the cycle
                var current_dest = start_src;
                var iterations: usize = 0;
                const max_iterations: usize = 8;

                while (iterations < max_iterations) {
                    // Find the move that writes to current_dest
                    var found_move: ?usize = null;
                    for (0..num_moves) |oi| {
                        if (moves[oi].done) continue;
                        if (moves[oi].dest == current_dest) {
                            found_move = oi;
                            break;
                        }
                    }

                    if (found_move) |move_idx| {
                        if (moves[move_idx].src) |src| {
                            // If src is the start, use R11 instead
                            const actual_src: Reg = if (src == start_src) .r11 else src;
                            try self.emit(3, asm_mod.encodeMovRegReg(moves[move_idx].dest, actual_src));
                            debug.log(.codegen, "      cycle: {s} -> {s}", .{ actual_src.name(), moves[move_idx].dest.name() });
                            current_dest = src;
                        } else {
                            try self.ensureInReg(moves[move_idx].value, moves[move_idx].dest);
                        }
                        moves[move_idx].done = true;
                    } else {
                        break;
                    }

                    if (current_dest == start_src) break;
                    iterations += 1;
                }

                // Complete the starting move: R11 -> dest
                try self.emit(3, asm_mod.encodeMovRegReg(moves[mi].dest, .r11));
                debug.log(.codegen, "      cycle: R11 -> {s}", .{moves[mi].dest.name()});
                moves[mi].done = true;
            } else {
                // No source register - just rematerialize
                try self.ensureInReg(moves[mi].value, moves[mi].dest);
                moves[mi].done = true;
            }
        }

        return stack_cleanup;
    }

    // ========================================================================
    // Code Generation
    // ========================================================================

    /// Generate binary code for a function.
    pub fn generateBinary(self: *AMD64CodeGen, f: *const Func, name: []const u8) !void {
        self.func = f;
        const start_offset = self.offset();

        // CRITICAL: Clear per-function state before generating code
        // Block IDs are per-function (all functions start with block 0)
        // so we must clear the mapping to avoid cross-function confusion
        self.block_offsets.clearRetainingCapacity();
        self.branch_fixups.clearRetainingCapacity();

        debug.log(.codegen, "Generating AMD64 code for '{s}'", .{name});
        debug.log(.codegen, "  Stack frame: {d} bytes", .{self.frame_size});

        // Add symbol (no underscore prefix for Linux/ELF)
        try self.symbols.append(self.allocator, .{
            .name = name,
            .value = start_offset,
            .section = 1, // .text section
            .binding = elf.STB_GLOBAL,
            .sym_type = elf.STT_FUNC,
        });

        // Emit prologue
        debug.log(.codegen, "  Emitting prologue", .{});
        try self.emitPrologue();

        // Generate code for each block
        for (f.blocks.items) |block| {
            try self.generateBlockBinary(block);
        }

        // Apply branch fixups
        try self.applyBranchFixups();

        debug.log(.codegen, "  Function '{s}' done, code size: {d} bytes", .{ name, self.offset() - start_offset });
    }

    /// Emit function prologue.
    fn emitPrologue(self: *AMD64CodeGen) !void {
        // PUSH RBP
        const push_rbp = asm_mod.encodePush(.rbp);
        try self.emitBytes(push_rbp.data[0..push_rbp.len]);

        // MOV RBP, RSP
        try self.emit(3, asm_mod.encodeMovRegReg(.rbp, .rsp));

        // SUB RSP, frame_size (if needed)
        if (self.frame_size > 0) {
            const aligned_frame = (self.frame_size + 15) & ~@as(u32, 15); // 16-byte align
            if (aligned_frame <= 127) {
                try self.emit(4, asm_mod.encodeSubRegImm8(.rsp, @intCast(aligned_frame)));
            } else {
                try self.emit(7, asm_mod.encodeSubRegImm32(.rsp, @intCast(aligned_frame)));
            }
        }
    }

    /// Emit function epilogue.
    fn emitEpilogue(self: *AMD64CodeGen) !void {
        // MOV RSP, RBP (restore stack pointer)
        try self.emit(3, asm_mod.encodeMovRegReg(.rsp, .rbp));

        // POP RBP
        const pop_rbp = asm_mod.encodePop(.rbp);
        try self.emitBytes(pop_rbp.data[0..pop_rbp.len]);

        // RET
        try self.emit(1, asm_mod.encodeRet());
    }

    /// Apply branch fixups.
    fn applyBranchFixups(self: *AMD64CodeGen) !void {
        for (self.branch_fixups.items) |fixup| {
            const target_offset = self.block_offsets.get(fixup.target_block_id) orelse continue;

            // Calculate relative offset from end of branch instruction
            const branch_end: i32 = @as(i32, @intCast(fixup.code_offset)) + 4; // rel32 is 4 bytes
            const rel32: i32 = @as(i32, @intCast(target_offset)) - branch_end;

            // Patch the rel32
            std.mem.writeInt(i32, self.code.items[fixup.code_offset..][0..4], rel32, .little);
        }
    }

    /// Generate code for a basic block.
    fn generateBlockBinary(self: *AMD64CodeGen, block: *const Block) !void {
        // Record block offset for branch fixups
        try self.block_offsets.put(self.allocator, block.id, self.offset());

        debug.log(.codegen, "  Block b{d} at offset {d}", .{ block.id, self.offset() });

        // Generate code for each value
        for (block.values.items) |value| {
            try self.generateValueBinary(value);
        }

        // Handle block terminator
        switch (block.kind) {
            .ret => {
                // Return block: move control value to RAX (and RDX for slices) and return
                if (block.controlValues().len > 0) {
                    const ret_val = block.controlValues()[0];

                    // Handle slice returns: ptr in RAX, len in RDX
                    if (ret_val.op == .slice_make and ret_val.args.len >= 2) {
                        // Put ptr in RAX
                        const ptr_val = ret_val.args[0];
                        const ptr_reg = self.getRegForValue(ptr_val) orelse blk: {
                            try self.ensureInReg(ptr_val, .rax);
                            break :blk Reg.rax;
                        };
                        if (ptr_reg != .rax) {
                            try self.emit(3, asm_mod.encodeMovRegReg(.rax, ptr_reg));
                        }
                        // Put len in RDX
                        const len_val = ret_val.args[1];
                        const len_reg = self.getRegForValue(len_val) orelse blk: {
                            try self.ensureInReg(len_val, .rdx);
                            break :blk Reg.rdx;
                        };
                        if (len_reg != .rdx) {
                            try self.emit(3, asm_mod.encodeMovRegReg(.rdx, len_reg));
                        }
                        debug.log(.codegen, "      ret slice: ptr={s}->RAX, len={s}->RDX", .{ ptr_reg.name(), len_reg.name() });
                    } else {
                        try self.moveToRAX(ret_val);
                    }
                }
                try self.emitEpilogue();
            },
            .if_ => {
                // Conditional branch
                if (block.succs.len >= 2) {
                    const cond_val = block.controlValues()[0];
                    const cond_reg = self.getRegForValue(cond_val) orelse blk: {
                        try self.ensureInReg(cond_val, .rax);
                        break :blk Reg.rax;
                    };

                    const then_block = block.succs[0].b;
                    const else_block = block.succs[1].b;

                    // CMP cond_reg, 0
                    try self.emit(4, asm_mod.encodeCmpRegImm8(cond_reg, 0));

                    // JE else_block (jump if zero/false)
                    const je_offset = self.offset();
                    try self.emit(6, asm_mod.encodeJccRel32(.e, 0)); // Placeholder
                    try self.branch_fixups.append(self.allocator, .{
                        .code_offset = @intCast(je_offset + 2), // Skip 0F 84
                        .target_block_id = else_block.id,
                        .is_jcc = true,
                    });

                    // Fall through or jump to then_block
                    // If then_block is not the next block, emit JMP
                    const jmp_offset = self.offset();
                    try self.emit(5, asm_mod.encodeJmpRel32(0)); // Placeholder
                    try self.branch_fixups.append(self.allocator, .{
                        .code_offset = @intCast(jmp_offset + 1), // Skip E9
                        .target_block_id = then_block.id,
                        .is_jcc = false,
                    });
                }
            },
            .plain => {
                // Unconditional branch to successor
                if (block.succs.len > 0) {
                    const succ = block.succs[0].b;
                    const jmp_offset = self.offset();
                    try self.emit(5, asm_mod.encodeJmpRel32(0)); // Placeholder
                    try self.branch_fixups.append(self.allocator, .{
                        .code_offset = @intCast(jmp_offset + 1),
                        .target_block_id = succ.id,
                        .is_jcc = false,
                    });
                }
            },
            else => {},
        }
    }

    /// Generate code for a single SSA value.
    fn generateValueBinary(self: *AMD64CodeGen, value: *const Value) !void {
        debug.log(.codegen, "    v{d}: {s}", .{ value.id, @tagName(value.op) });

        // Skip rematerializeable values that have no register assigned.
        // They will be rematerialized when used (via ensureInReg).
        // This matches ARM64 codegen behavior.
        switch (value.op) {
            .const_int, .const_64, .const_bool, .local_addr => {
                if (value.regOrNull() == null) {
                    debug.log(.codegen, "      (skipped - evicted rematerializeable)", .{});
                    return;
                }
            },
            else => {},
        }

        switch (value.op) {
            .const_int, .const_64 => {
                const dest_reg = self.getDestRegForValue(value);
                try self.emitLoadImmediate(dest_reg, value.aux_int);
                debug.log(.codegen, "      -> {s} = #{d}", .{ dest_reg.name(), value.aux_int });
            },

            .const_bool => {
                const dest_reg = self.getDestRegForValue(value);
                const imm: i64 = if (value.aux_int != 0) 1 else 0;
                try self.emitLoadImmediate(dest_reg, imm);
            },

            .const_nil => {
                const dest_reg = self.getDestRegForValue(value);
                // XOR reg, reg is more efficient for zeroing
                try self.emit(3, asm_mod.encodeXorRegReg(dest_reg, dest_reg));
            },

            .add => {
                const args = value.args;
                if (args.len >= 2) {
                    debug.log(.codegen, "      add args: v{d} ({s}) + v{d} ({s})", .{ args[0].id, @tagName(args[0].op), args[1].id, @tagName(args[1].op) });
                    // First get op1's register
                    const op1_result = self.getRegForValue(args[0]);
                    debug.log(.codegen, "      op1 getRegForValue: {?s}", .{if (op1_result) |r| r.name() else null});
                    const op1_reg = op1_result orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };
                    // Choose op2 scratch that doesn't conflict with op1
                    const op2_scratch: Reg = if (op1_reg == .rcx) .rdx else .rcx;
                    const op2_result = self.getRegForValue(args[1]);
                    debug.log(.codegen, "      op2 getRegForValue: {?s}", .{if (op2_result) |r| r.name() else null});
                    const op2_reg = op2_result orelse blk: {
                        try self.ensureInReg(args[1], op2_scratch);
                        break :blk op2_scratch;
                    };
                    debug.log(.codegen, "      using op1={s}, op2={s}", .{op1_reg.name(), op2_reg.name()});
                    const dest_reg = self.getDestRegForValue(value);

                    // Handle all cases for ADD (commutative operation)
                    if (dest_reg == op1_reg) {
                        // dest already has op1, just add op2
                        try self.emit(3, asm_mod.encodeAddRegReg(dest_reg, op2_reg));
                    } else if (dest_reg == op2_reg) {
                        // dest has op2, and ADD is commutative, so add op1
                        try self.emit(3, asm_mod.encodeAddRegReg(dest_reg, op1_reg));
                    } else {
                        // dest is different from both operands
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, op1_reg));
                        try self.emit(3, asm_mod.encodeAddRegReg(dest_reg, op2_reg));
                    }
                }
            },

            .sub => {
                const args = value.args;
                if (args.len >= 2) {
                    const dest_reg = self.getDestRegForValue(value);

                    // For SUB (non-commutative): ensure op2 doesn't get clobbered
                    // by using a register that won't be overwritten
                    const op2_scratch: Reg = if (dest_reg == .rcx) .rdx else .rcx;
                    const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], op2_scratch);
                        break :blk op2_scratch;
                    };

                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };

                    if (dest_reg == op1_reg) {
                        // dest already has op1, just sub op2
                        try self.emit(3, asm_mod.encodeSubRegReg(dest_reg, op2_reg));
                    } else if (dest_reg == op2_reg) {
                        // PROBLEM: dest has op2, but SUB is not commutative!
                        // We need: dest = op1 - op2
                        // Currently: dest = op2
                        // Solution: use a temp, or NEG and ADD
                        // NEG dest; ADD dest, op1 gives us op1 - op2
                        try self.emit(3, asm_mod.encodeNegReg(dest_reg));
                        try self.emit(3, asm_mod.encodeAddRegReg(dest_reg, op1_reg));
                    } else {
                        // dest is different from both operands
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, op1_reg));
                        try self.emit(3, asm_mod.encodeSubRegReg(dest_reg, op2_reg));
                    }
                }
            },

            .mul => {
                const args = value.args;
                if (args.len >= 2) {
                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };
                    // CRITICAL: op2 must not clobber op1's register
                    const op2_scratch: Reg = if (op1_reg == .rcx) .rdx else .rcx;
                    const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], op2_scratch);
                        break :blk op2_scratch;
                    };
                    const dest_reg = self.getDestRegForValue(value);

                    // Handle all cases for MUL (commutative operation)
                    if (dest_reg == op1_reg) {
                        // dest already has op1, just mul by op2
                        try self.emit(4, asm_mod.encodeImulRegReg(dest_reg, op2_reg));
                    } else if (dest_reg == op2_reg) {
                        // dest has op2, and MUL is commutative, so mul by op1
                        try self.emit(4, asm_mod.encodeImulRegReg(dest_reg, op1_reg));
                    } else {
                        // dest is different from both operands
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, op1_reg));
                        try self.emit(4, asm_mod.encodeImulRegReg(dest_reg, op2_reg));
                    }
                }
            },

            .div => {
                // AMD64 division: IDIV uses RDX:RAX / src -> RAX (quotient), RDX (remainder)
                const args = value.args;
                if (args.len >= 2) {
                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };
                    var op2_reg = self.getRegForValue(args[1]) orelse blk: {
                        // Use R11 for divisor to avoid conflicts with dividend
                        try self.ensureInReg(args[1], .r11);
                        break :blk Reg.r11;
                    };

                    // If op2 is in RAX, move it to R11 before we put op1 in RAX
                    // Use R11 to avoid clobbering op1_reg which might be in RCX
                    if (op2_reg == .rax and op1_reg != .rax) {
                        try self.emit(3, asm_mod.encodeMovRegReg(.r11, .rax));
                        op2_reg = .r11;
                    }

                    // Move dividend to RAX if needed
                    if (op1_reg != .rax) {
                        try self.emit(3, asm_mod.encodeMovRegReg(.rax, op1_reg));
                    }

                    // CQO: sign-extend RAX into RDX:RAX
                    try self.emit(2, asm_mod.encodeCqo());

                    // IDIV op2 (RDX:RAX / op2 -> RAX)
                    try self.emit(3, asm_mod.encodeIdivReg(op2_reg));

                    // Result is in RAX, move to dest if needed
                    const dest_reg = self.getDestRegForValue(value);
                    if (dest_reg != .rax) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, .rax));
                    }
                }
            },

            .mod => {
                // Modulo: same as div but result is in RDX
                const args = value.args;
                if (args.len >= 2) {
                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };
                    var op2_reg = self.getRegForValue(args[1]) orelse blk: {
                        // Use R11 for divisor to avoid conflicts with dividend
                        try self.ensureInReg(args[1], .r11);
                        break :blk Reg.r11;
                    };

                    // If op2 is in RAX, move it to R11 before we put op1 in RAX
                    // Use R11 to avoid clobbering op1_reg which might be in RCX
                    if (op2_reg == .rax and op1_reg != .rax) {
                        try self.emit(3, asm_mod.encodeMovRegReg(.r11, .rax));
                        op2_reg = .r11;
                    }

                    if (op1_reg != .rax) {
                        try self.emit(3, asm_mod.encodeMovRegReg(.rax, op1_reg));
                    }
                    try self.emit(2, asm_mod.encodeCqo());
                    try self.emit(3, asm_mod.encodeIdivReg(op2_reg));

                    // Remainder is in RDX
                    const dest_reg = self.getDestRegForValue(value);
                    if (dest_reg != .rdx) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, .rdx));
                    }
                }
            },

            .add_ptr => {
                // Pointer arithmetic: ptr + offset
                // Used for array indexing: base + (index * element_size)
                const args = value.args;
                if (args.len >= 2) {
                    const ptr_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };
                    const off_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], .rcx);
                        break :blk Reg.rcx;
                    };
                    const dest_reg = self.getDestRegForValue(value);

                    // LEA dest, [ptr + off]
                    const lea = asm_mod.encodeLeaBaseIndex(dest_reg, ptr_reg, off_reg);
                    try self.emitBytes(lea.data[0..lea.len]);
                    debug.log(.codegen, "      -> LEA {s}, [{s}+{s}] (add_ptr)", .{ dest_reg.name(), ptr_reg.name(), off_reg.name() });
                }
            },

            .sub_ptr => {
                // Pointer subtraction: ptr - offset
                const args = value.args;
                if (args.len >= 2) {
                    const ptr_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };
                    const off_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], .rcx);
                        break :blk Reg.rcx;
                    };
                    const dest_reg = self.getDestRegForValue(value);

                    if (dest_reg != ptr_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, ptr_reg));
                    }
                    try self.emit(3, asm_mod.encodeSubRegReg(dest_reg, off_reg));
                    debug.log(.codegen, "      -> SUB {s}, {s} (sub_ptr)", .{ dest_reg.name(), off_reg.name() });
                }
            },

            .eq, .ne, .lt, .le, .gt, .ge => {
                const args = value.args;
                if (args.len >= 2) {
                    // CRITICAL: Get op2 FIRST to avoid clobbering op1
                    // ensureInReg for op2 might use RAX as scratch, which would clobber op1
                    const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], .rcx);
                        break :blk Reg.rcx;
                    };
                    // Now get op1 - since op2 is in RCX, we're safe to use RAX
                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };
                    const dest_reg = self.getDestRegForValue(value);

                    // CMP op1, op2
                    try self.emit(3, asm_mod.encodeCmpRegReg(op1_reg, op2_reg));

                    // SETcc dest (sets low byte based on condition)
                    const cond: asm_mod.Cond = switch (value.op) {
                        .eq => .e,
                        .ne => .ne,
                        .lt => .l,
                        .le => .le,
                        .gt => .g,
                        .ge => .ge,
                        else => .e,
                    };

                    // Set low byte based on flags, then zero-extend
                    // Note: XOR before CMP would clobber flags, so we use MOVZX after SETcc
                    try self.emit(4, asm_mod.encodeSetcc(cond, dest_reg));
                    try self.emit(4, asm_mod.encodeMovzxRegReg8(dest_reg, dest_reg));
                }
            },

            // cond_select(cond, then_val, else_val) -> if cond != 0 then then_val else else_val
            .cond_select => {
                if (value.args.len >= 3) {
                    const cond_val = value.args[0];
                    const then_val = value.args[1];
                    const else_val = value.args[2];
                    const dest_reg = self.getDestRegForValue(value);

                    // Get registers for operands, using scratch regs to avoid conflicts
                    const else_reg = self.getRegForValue(else_val) orelse blk: {
                        try self.ensureInReg(else_val, .r10);
                        break :blk Reg.r10;
                    };
                    const then_reg = self.getRegForValue(then_val) orelse blk: {
                        const scratch: Reg = if (else_reg == .r11) .r10 else .r11;
                        try self.ensureInReg(then_val, scratch);
                        break :blk scratch;
                    };
                    const cond_reg = self.getRegForValue(cond_val) orelse blk: {
                        var scratch: Reg = .rcx;
                        if (scratch == then_reg or scratch == else_reg) scratch = .rax;
                        if (scratch == then_reg or scratch == else_reg) scratch = .rdx;
                        try self.ensureInReg(cond_val, scratch);
                        break :blk scratch;
                    };

                    // Move else_val to dest (default value)
                    if (dest_reg != else_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, else_reg));
                    }

                    // TEST cond, cond (sets ZF if cond is 0)
                    try self.emit(3, asm_mod.encodeTestRegReg(cond_reg, cond_reg));

                    // CMOVNE dest, then_val (if cond != 0, use then_val)
                    try self.emit(4, asm_mod.encodeCmovcc(.ne, dest_reg, then_reg));

                    debug.log(.codegen, "      cond_select: TEST {s}; CMOVNE {s}, {s}", .{ cond_reg.name(), dest_reg.name(), then_reg.name() });
                }
            },

            .copy => {
                // Copy value from one register to another
                const args = value.args;
                if (args.len >= 1) {
                    const src_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };
                    const dest_reg = self.getDestRegForValue(value);
                    if (dest_reg != src_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, src_reg));
                    }
                }
            },

            .phi => {
                // Phi nodes are handled by regalloc shuffle code
                // No code generation needed here
            },

            .arg => {
                // Function argument - System V AMD64 ABI
                // First 6 args in: RDI, RSI, RDX, RCX, R8, R9
                const arg_idx: usize = @intCast(value.aux_int);
                const dest_reg = self.getDestRegForValue(value);

                if (arg_idx < regs.AMD64.arg_regs.len) {
                    // Register argument - move from ABI register to destination
                    const src_reg = regs.AMD64.arg_regs[arg_idx];
                    if (dest_reg != src_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, src_reg));
                        debug.log(.codegen, "      -> MOV {s}, {s} (arg {d})", .{ dest_reg.name(), src_reg.name(), arg_idx });
                    }
                } else {
                    // Stack argument - load from caller's stack frame
                    // After push rbp; mov rbp,rsp, caller's args are at [rbp+16+N*8]
                    const stack_offset: i32 = @intCast(16 + (arg_idx - 6) * 8);
                    const load = asm_mod.encodeLoadDisp32(dest_reg, .rbp, stack_offset);
                    try self.emitBytes(load.data[0..load.len]);
                    debug.log(.codegen, "      -> MOV {s}, [rbp+{d}] (stack arg {d})", .{ dest_reg.name(), stack_offset, arg_idx });
                }
            },

            .static_call => {
                // Function call - System V AMD64 ABI
                // Get target function name from aux.string
                const target_name = switch (value.aux) {
                    .string => |s| s,
                    else => "unknown",
                };

                // Use parallel copy to setup arguments (prevents clobbering)
                const stack_cleanup = try self.setupCallArgs(value.args);

                // Emit CALL rel32 with relocation
                const call_offset = self.offset();
                try self.emit(5, asm_mod.encodeCall(0)); // Placeholder

                // Clean up stack arguments (caller-cleanup on System V AMD64)
                if (stack_cleanup > 0) {
                    const cleanup_size: i32 = @intCast(stack_cleanup);
                    try self.emit(7, asm_mod.encodeAddRegImm32(.rsp, cleanup_size));
                    debug.log(.codegen, "      ADD RSP, {d} (cleanup stack args)", .{cleanup_size});
                }

                // Record relocation
                try self.relocations.append(self.allocator, .{
                    .offset = @intCast(call_offset + 1), // Skip E8 opcode
                    .target = target_name,
                });

                debug.log(.codegen, "      CALL {s}", .{target_name});
                debug.log(.codegen, "      static_call v{d}: uses={d}, has_home={}", .{ value.id, value.uses, value.getHome() != null });

                // Result is in RAX - regalloc will handle spill/reload if needed
                // Go's approach: don't move to callee-saved, let regalloc spill
                // (Same pattern as ARM64 backend)
            },

            .load => {
                // Load from memory address
                // arg[0] is the address
                if (value.args.len > 0) {
                    const addr = value.args[0];
                    const dest_reg = self.getDestRegForValue(value);

                    const addr_reg = self.getRegForValue(addr) orelse blk: {
                        // Address should already be computed - use R11 as scratch
                        try self.ensureInReg(addr, .r11);
                        break :blk Reg.r11;
                    };

                    // Use type-sized load instruction
                    const type_size = self.getTypeSize(value.type_idx);

                    if (type_size == 1) {
                        // MOVZX for byte load (zero-extend to 64-bit)
                        const load = asm_mod.encodeLoadByteDisp32(dest_reg, addr_reg, 0);
                        try self.emitBytes(load.data[0..load.len]);
                    } else if (type_size == 2) {
                        // MOVZX for word load (zero-extend to 64-bit)
                        const load = asm_mod.encodeLoadWordDisp32(dest_reg, addr_reg, 0);
                        try self.emitBytes(load.data[0..load.len]);
                    } else if (type_size == 4) {
                        // MOV r32 for dword load (implicit zero-extend to 64-bit)
                        const load = asm_mod.encodeLoadDwordDisp32(dest_reg, addr_reg, 0);
                        try self.emitBytes(load.data[0..load.len]);
                    } else {
                        // MOV r64 for qword load (default)
                        const load = asm_mod.encodeLoadDisp32(dest_reg, addr_reg, 0);
                        try self.emitBytes(load.data[0..load.len]);
                    }
                    debug.log(.codegen, "      -> LOAD {s} <- [{s}] ({d}B)", .{ dest_reg.name(), addr_reg.name(), type_size });
                }
            },

            .store => {
                // Store to memory address
                // arg[0] is the address, arg[1] is the value to store
                if (value.args.len >= 2) {
                    const addr = value.args[0];
                    const val = value.args[1];

                    // CRITICAL: Use R10 (not R9) because R9 is an argument register
                    // on AMD64 System V ABI (6th argument). Using R9 would clobber
                    // the 6th argument when storing parameters to stack.
                    const val_reg = self.getRegForValue(val) orelse blk: {
                        try self.ensureInReg(val, .r10);
                        break :blk Reg.r10;
                    };

                    // Now get address - ensureInReg for add_ptr can use R10/R11 freely
                    const addr_reg = self.getRegForValue(addr) orelse blk: {
                        try self.ensureInReg(addr, .r11);
                        break :blk Reg.r11;
                    };

                    // Use type-sized store instruction
                    const type_size = self.getTypeSize(val.type_idx);

                    if (type_size == 1) {
                        // MOV BYTE PTR
                        const store = asm_mod.encodeStoreByteDisp32(addr_reg, 0, val_reg);
                        try self.emitBytes(store.data[0..store.len]);
                    } else if (type_size == 2) {
                        // MOV WORD PTR
                        const store = asm_mod.encodeStoreWordDisp32(addr_reg, 0, val_reg);
                        try self.emitBytes(store.data[0..store.len]);
                    } else if (type_size == 4) {
                        // MOV DWORD PTR
                        const store = asm_mod.encodeStoreDwordDisp32(addr_reg, 0, val_reg);
                        try self.emitBytes(store.data[0..store.len]);
                    } else {
                        // MOV QWORD PTR (default)
                        const store = asm_mod.encodeStoreDisp32(addr_reg, 0, val_reg);
                        try self.emitBytes(store.data[0..store.len]);
                    }
                    debug.log(.codegen, "      -> STORE [{s}] <- {s} ({d}B)", .{ addr_reg.name(), val_reg.name(), type_size });
                }
            },

            .local_addr => {
                // Address of local variable on stack
                // Use R11 as default to avoid clobbering values in RAX/RCX
                const dest_reg = if (self.getRegForValue(value)) |r| r else Reg.r11;
                const local_idx: usize = @intCast(value.aux_int);

                // Get stack offset from local_offsets (set by stackalloc)
                // On x86-64, locals are at negative offsets from RBP
                // FIX: Use the END of the allocation, not the start
                // This prevents arrays from overflowing into saved RBP
                if (local_idx < self.func.local_offsets.len and local_idx < self.func.local_sizes.len) {
                    const byte_offset = self.func.local_offsets[local_idx];
                    const local_size: i32 = @intCast(self.func.local_sizes[local_idx]);
                    // local_offsets stores the START of the local, but we need to
                    // position the base address so that arr[N-1] doesn't overflow
                    // disp = -(byte_offset + local_size) positions the base at the
                    // low end, so arr[i] accesses grow toward (but don't reach) RBP
                    const disp: i32 = -(byte_offset + local_size);
                    const lea = asm_mod.encodeLeaDisp32(dest_reg, .rbp, disp);
                    try self.emitBytes(lea.data[0..lea.len]);
                } else {
                    // Fallback: shouldn't happen
                    const lea = asm_mod.encodeLeaDisp32(dest_reg, .rbp, 0);
                    try self.emitBytes(lea.data[0..lea.len]);
                }
            },

            .off_ptr => {
                // Add offset to base pointer (for field/element access)
                // args[0] = base pointer, aux_int = offset
                if (value.args.len > 0) {
                    const base = value.args[0];
                    const field_offset: i64 = value.aux_int;
                    const dest_reg = self.getDestRegForValue(value);

                    // Handle local_addr specially - regenerate if needed
                    var base_reg: Reg = undefined;
                    if (base.op == .local_addr) {
                        // Regenerate local address to avoid register reuse issues
                        const local_idx: usize = @intCast(base.aux_int);
                        if (local_idx < self.func.local_offsets.len and local_idx < self.func.local_sizes.len) {
                            const local_offset = self.func.local_offsets[local_idx];
                            const local_size: i32 = @intCast(self.func.local_sizes[local_idx]);
                            const disp: i32 = -(local_offset + local_size);
                            const lea = asm_mod.encodeLeaDisp32(dest_reg, .rbp, disp);
                            try self.emitBytes(lea.data[0..lea.len]);
                            base_reg = dest_reg;
                        } else {
                            base_reg = self.getRegForValue(base) orelse blk: {
                                try self.ensureInReg(base, dest_reg);
                                break :blk dest_reg;
                            };
                        }
                    } else {
                        base_reg = self.getRegForValue(base) orelse blk: {
                            try self.ensureInReg(base, dest_reg);
                            break :blk dest_reg;
                        };
                    }

                    // LEA dest, [base + offset] or MOV if offset is 0
                    if (field_offset != 0) {
                        const disp: i32 = @intCast(field_offset);
                        const lea = asm_mod.encodeLeaDisp32(dest_reg, base_reg, disp);
                        try self.emitBytes(lea.data[0..lea.len]);
                        debug.log(.codegen, "      -> LEA {s}, [{s}+{d}] (off_ptr)", .{ dest_reg.name(), base_reg.name(), disp });
                    } else if (base_reg != dest_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, base_reg));
                    }
                }
            },

            .const_string, .const_ptr => {
                // String literal: emit LEA with RIP-relative addressing
                // The string index is in aux_int
                const string_index: usize = @intCast(value.aux_int);
                const dest_reg = self.getDestRegForValue(value);

                // Get the string data and make a copy (func may be deinit'd before finalize)
                const str_data = if (string_index < self.func.string_literals.len)
                    self.func.string_literals[string_index]
                else
                    "";

                // Record the offset for relocation fixup
                const lea_offset = self.offset();
                // Emit LEA with disp=0 (linker will fix up via relocation)
                try self.emit(7, asm_mod.encodeLeaRipRel32(dest_reg, 0));

                // Record string reference for relocation during finalize()
                const str_copy = try self.allocator.dupe(u8, str_data);
                try self.string_refs.append(self.allocator, .{
                    .code_offset = lea_offset,
                    .string_data = str_copy,
                });

                debug.log(.codegen, "      -> {s} = str[{d}] len={d} (pending reloc)", .{ dest_reg.name(), string_index, str_data.len });
            },

            .global_addr => {
                // Address of global variable
                const global_name = switch (value.aux) {
                    .string => |s| s,
                    else => "unknown_global",
                };
                const dest_reg = self.getDestRegForValue(value);

                // Record the offset for relocation fixup
                const lea_offset = self.offset();
                // Emit LEA with RIP-relative addressing (disp=0, linker fills in)
                try self.emit(7, asm_mod.encodeLeaRipRel32(dest_reg, 0));

                // Record global reference for relocation
                try self.relocations.append(self.allocator, .{
                    .offset = @intCast(lea_offset + 3), // Skip REX+opcode+ModRM to get to disp32
                    .target = global_name,
                });

                debug.log(.codegen, "      -> {s} = global '{s}' (pending reloc)", .{ dest_reg.name(), global_name });
            },

            .addr => {
                // Address of a symbol (function for function pointers)
                // aux.string contains the symbol name
                const func_name = switch (value.aux) {
                    .string => |s| s,
                    else => "unknown",
                };
                const dest_reg = self.getDestRegForValue(value);

                // Record the offset for relocation fixup
                const lea_offset = self.offset();
                // Emit LEA with RIP-relative addressing
                try self.emit(7, asm_mod.encodeLeaRipRel32(dest_reg, 0));

                // Record function reference for relocation
                try self.relocations.append(self.allocator, .{
                    .offset = @intCast(lea_offset + 3), // Skip REX+opcode+ModRM to get to disp32
                    .target = func_name,
                });

                debug.log(.codegen, "      -> {s} = addr '{s}' (pending reloc)", .{ dest_reg.name(), func_name });
            },

            .slice_ptr => {
                // Get pointer from a slice (first 8 bytes of 16-byte slice)
                const slice_val = value.args[0];
                const dest_reg = self.getDestRegForValue(value);

                // If the slice is a const_string, the pointer is already the string address
                if (slice_val.op == .const_string or slice_val.op == .const_ptr) {
                    const src_reg = self.getRegForValue(slice_val) orelse blk: {
                        try self.ensureInReg(slice_val, .rax);
                        break :blk Reg.rax;
                    };
                    if (dest_reg != src_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, src_reg));
                    }
                } else if (slice_val.op == .static_call) {
                    // Call result: slice ptr is in RAX (System V AMD64 ABI)
                    if (dest_reg != .rax) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, .rax));
                    }
                    debug.log(.codegen, "      slice_ptr from call -> RAX to {s}", .{dest_reg.name()});
                } else {
                    // Load ptr from memory (first 8 bytes of slice)
                    const slice_reg = self.getRegForValue(slice_val) orelse blk: {
                        try self.ensureInReg(slice_val, .r11);
                        break :blk Reg.r11;
                    };
                    const load = asm_mod.encodeLoadDisp32(dest_reg, slice_reg, 0);
                    try self.emitBytes(load.data[0..load.len]);
                }
                debug.log(.codegen, "      -> slice_ptr {s}", .{dest_reg.name()});
            },

            .slice_len => {
                // Get length from a slice (second 8 bytes of 16-byte slice)
                const slice_val = value.args[0];
                const dest_reg = self.getDestRegForValue(value);

                // If the slice is a const_string, get length from string_literals
                if (slice_val.op == .const_string) {
                    const string_index: usize = @intCast(slice_val.aux_int);
                    const str_len: i64 = if (string_index < self.func.string_literals.len)
                        @intCast(self.func.string_literals[string_index].len)
                    else
                        0;
                    try self.emitLoadImmediate(dest_reg, str_len);
                } else if (slice_val.op == .static_call) {
                    // Call result: slice len is in RDX (System V AMD64 ABI)
                    if (dest_reg != .rdx) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, .rdx));
                    }
                    debug.log(.codegen, "      slice_len from call -> RDX to {s}", .{dest_reg.name()});
                } else {
                    // Load len from memory (offset 8 in slice)
                    const slice_reg = self.getRegForValue(slice_val) orelse blk: {
                        try self.ensureInReg(slice_val, .r11);
                        break :blk Reg.r11;
                    };
                    const load = asm_mod.encodeLoadDisp32(dest_reg, slice_reg, 8);
                    try self.emitBytes(load.data[0..load.len]);
                }
                debug.log(.codegen, "      -> slice_len {s}", .{dest_reg.name()});
            },

            .and_ => {
                const args = value.args;
                if (args.len >= 2) {
                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };
                    const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], .rcx);
                        break :blk Reg.rcx;
                    };
                    const dest_reg = self.getDestRegForValue(value);

                    if (dest_reg != op1_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, op1_reg));
                    }
                    try self.emit(3, asm_mod.encodeAndRegReg(dest_reg, op2_reg));
                }
            },

            .or_ => {
                const args = value.args;
                if (args.len >= 2) {
                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };
                    const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], .rcx);
                        break :blk Reg.rcx;
                    };
                    const dest_reg = self.getDestRegForValue(value);

                    if (dest_reg != op1_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, op1_reg));
                    }
                    try self.emit(3, asm_mod.encodeOrRegReg(dest_reg, op2_reg));
                }
            },

            .xor => {
                const args = value.args;
                if (args.len >= 2) {
                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };
                    const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], .rcx);
                        break :blk Reg.rcx;
                    };
                    const dest_reg = self.getDestRegForValue(value);

                    if (dest_reg != op1_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, op1_reg));
                    }
                    try self.emit(3, asm_mod.encodeXorRegReg(dest_reg, op2_reg));
                }
            },

            .shl => {
                // Shift left: arg[0] << arg[1]
                // AMD64 shift by CL (low byte of RCX)
                const args = value.args;
                if (args.len >= 2) {
                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };

                    // Check if shift amount is constant
                    if (args[1].op == .const_int or args[1].op == .const_64) {
                        const dest_reg = self.getDestRegForValue(value);
                        // Move value to dest if needed
                        if (dest_reg != op1_reg) {
                            try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, op1_reg));
                        }
                        const shift_amt: u8 = @intCast(@as(u64, @bitCast(args[1].aux_int)) & 63);
                        try self.emit(4, asm_mod.encodeShlRegImm8(dest_reg, shift_amt));
                    } else {
                        // Variable shift: need amount in CL
                        const assigned_dest = self.getDestRegForValue(value);

                        // Determine if we need to use a temp register
                        // If dest is RCX, compute in RAX to avoid conflict with shift amount
                        const compute_reg: Reg = if (assigned_dest == .rcx) .rax else assigned_dest;

                        // Move value to compute reg first (before we put shift amount in RCX)
                        if (compute_reg != op1_reg) {
                            try self.emit(3, asm_mod.encodeMovRegReg(compute_reg, op1_reg));
                        }

                        // Now put shift amount in RCX
                        const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                            try self.ensureInReg(args[1], .rcx);
                            break :blk Reg.rcx;
                        };
                        if (op2_reg != .rcx) {
                            try self.emit(3, asm_mod.encodeMovRegReg(.rcx, op2_reg));
                        }

                        // Do the shift
                        try self.emit(3, asm_mod.encodeShlRegCl(compute_reg));

                        // Move result to assigned dest if different
                        if (compute_reg != assigned_dest) {
                            try self.emit(3, asm_mod.encodeMovRegReg(assigned_dest, compute_reg));
                        }
                    }
                }
            },

            .shr => {
                // Logical shift right: arg[0] >> arg[1]
                const args = value.args;
                if (args.len >= 2) {
                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };

                    if (args[1].op == .const_int or args[1].op == .const_64) {
                        const dest_reg = self.getDestRegForValue(value);
                        if (dest_reg != op1_reg) {
                            try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, op1_reg));
                        }
                        const shift_amt: u8 = @intCast(@as(u64, @bitCast(args[1].aux_int)) & 63);
                        try self.emit(4, asm_mod.encodeShrRegImm8(dest_reg, shift_amt));
                    } else {
                        // Variable shift: need amount in CL
                        const assigned_dest = self.getDestRegForValue(value);

                        // Determine if we need to use a temp register
                        const compute_reg: Reg = if (assigned_dest == .rcx) .rax else assigned_dest;

                        // Move value to compute reg first (before we put shift amount in RCX)
                        if (compute_reg != op1_reg) {
                            try self.emit(3, asm_mod.encodeMovRegReg(compute_reg, op1_reg));
                        }

                        // Now put shift amount in RCX
                        const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                            try self.ensureInReg(args[1], .rcx);
                            break :blk Reg.rcx;
                        };
                        if (op2_reg != .rcx) {
                            try self.emit(3, asm_mod.encodeMovRegReg(.rcx, op2_reg));
                        }

                        // Do the shift
                        try self.emit(3, asm_mod.encodeShrRegCl(compute_reg));

                        // Move result to assigned dest if different
                        if (compute_reg != assigned_dest) {
                            try self.emit(3, asm_mod.encodeMovRegReg(assigned_dest, compute_reg));
                        }
                    }
                }
            },

            .sar => {
                // Arithmetic shift right: arg[0] >> arg[1] (sign-preserving)
                const args = value.args;
                if (args.len >= 2) {
                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };
                    const dest_reg = self.getDestRegForValue(value);

                    if (dest_reg != op1_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, op1_reg));
                    }

                    if (args[1].op == .const_int or args[1].op == .const_64) {
                        const shift_amt: u8 = @intCast(@as(u64, @bitCast(args[1].aux_int)) & 63);
                        try self.emit(4, asm_mod.encodeSarRegImm8(dest_reg, shift_amt));
                    } else {
                        const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                            try self.ensureInReg(args[1], .rcx);
                            break :blk Reg.rcx;
                        };
                        if (op2_reg != .rcx) {
                            try self.emit(3, asm_mod.encodeMovRegReg(.rcx, op2_reg));
                        }
                        try self.emit(3, asm_mod.encodeSarRegCl(dest_reg));
                    }
                }
            },

            .neg => {
                // Two's complement negation
                const args = value.args;
                if (args.len >= 1) {
                    const op_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };
                    const dest_reg = self.getDestRegForValue(value);

                    if (dest_reg != op_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, op_reg));
                    }
                    try self.emit(3, asm_mod.encodeNegReg(dest_reg));
                }
            },

            .not => {
                // Bitwise NOT
                const args = value.args;
                if (args.len >= 1) {
                    const op_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };
                    const dest_reg = self.getDestRegForValue(value);

                    if (dest_reg != op_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, op_reg));
                    }
                    try self.emit(3, asm_mod.encodeNotReg(dest_reg));
                }
            },

            .string_make => {
                // String construction from ptr and len - this is a marker op
                // The actual work is done by the ptr and len values that feed into
                // whatever consumes this string. No code generation needed here.
                debug.log(.codegen, "      (string_make: no code, components used directly)", .{});
            },

            .store_reg => {
                // Store value to a stack spill slot
                if (value.args.len > 0) {
                    const src_value = value.args[0];
                    const loc = value.getHome() orelse {
                        debug.log(.codegen, "      store_reg v{d}: NO stack location!", .{value.id});
                        return;
                    };
                    const byte_off = loc.stackOffset();

                    // Get the register holding the value to spill
                    const src_reg = self.getRegForValue(src_value) orelse blk: {
                        try self.ensureInReg(src_value, .r11);
                        break :blk Reg.r11;
                    };

                    // MOV [RBP - offset], src_reg
                    const disp: i32 = -@as(i32, @intCast(byte_off));
                    const store = asm_mod.encodeStoreDisp32(.rbp, disp, src_reg);
                    try self.emitBytes(store.data[0..store.len]);
                    debug.log(.codegen, "      -> MOV [RBP{d}], {s}", .{ disp, src_reg.name() });
                }
            },

            .load_reg => {
                // Load value from a stack spill slot
                if (value.args.len > 0) {
                    const spill_value = value.args[0];
                    const loc = spill_value.getHome() orelse {
                        debug.log(.codegen, "      load_reg v{d}: source has NO location!", .{value.id});
                        return;
                    };
                    const byte_off = loc.stackOffset();
                    const dest_reg = self.getDestRegForValue(value);

                    // MOV dest_reg, [RBP - offset]
                    const disp: i32 = -@as(i32, @intCast(byte_off));
                    const load = asm_mod.encodeLoadDisp32(dest_reg, .rbp, disp);
                    try self.emitBytes(load.data[0..load.len]);
                    debug.log(.codegen, "      -> MOV {s}, [RBP{d}]", .{ dest_reg.name(), disp });
                }
            },

            else => {
                // Unhandled operation
                debug.log(.codegen, "      (unhandled op: {s})", .{@tagName(value.op)});
            },
        }
    }

    /// Load immediate value into register.
    fn emitLoadImmediate(self: *AMD64CodeGen, reg: Reg, imm: i64) !void {
        if (imm == 0) {
            // XOR reg, reg (smaller and faster)
            try self.emit(3, asm_mod.encodeXorRegReg(reg, reg));
        } else if (imm >= -2147483648 and imm <= 2147483647) {
            // MOV r64, imm32 (sign-extended) - 7 bytes
            try self.emit(7, asm_mod.encodeMovRegImm32(reg, @intCast(imm)));
        } else {
            // MOV r64, imm64 - 10 bytes
            try self.emit(10, asm_mod.encodeMovRegImm64(reg, @bitCast(imm)));
        }
    }

    /// Move a value to RAX for return.
    fn moveToRAX(self: *AMD64CodeGen, value: *const Value) !void {
        if (self.getRegForValue(value)) |reg| {
            if (reg != .rax) {
                try self.emit(3, asm_mod.encodeMovRegReg(.rax, reg));
            }
        } else {
            // Value not in register, need to rematerialize or load
            try self.ensureInReg(value, .rax);
        }
    }

    // ========================================================================
    // Finalization
    // ========================================================================

    /// Finalize and return the generated object code.
    pub fn finalize(self: *AMD64CodeGen) ![]u8 {
        var elf_writer = elf.ElfWriter.init(self.allocator);
        defer elf_writer.deinit();

        // Add code section
        try elf_writer.addCode(self.code.items);

        // Add symbols
        for (self.symbols.items) |sym| {
            try elf_writer.addSymbol(sym.name, sym.value, sym.section, sym.binding == elf.STB_GLOBAL);
        }

        // Add relocations for function calls
        for (self.relocations.items) |reloc| {
            try elf_writer.addRelocation(reloc.offset, reloc.target);
        }

        // Process string references: add strings to data section and create relocations
        debug.log(.codegen, "[FINALIZE] Processing {d} string_refs entries", .{self.string_refs.items.len});
        for (self.string_refs.items) |str_ref| {
            // Add string to data section and get its symbol name
            const sym_name = try elf_writer.addStringLiteral(str_ref.string_data);

            debug.log(.codegen, "[FINALIZE]   string: \"{s}\" -> symbol '{s}'", .{
                str_ref.string_data,
                sym_name,
            });

            // Add PC-relative relocation for LEA instruction
            // For LEA r64, [RIP+disp32], the disp32 is at offset+3 (after REX, opcode, ModRM)
            try elf_writer.addDataRelocation(str_ref.code_offset + 3, sym_name);
        }

        // Add global variables to data section
        for (self.globals) |global| {
            try elf_writer.addGlobalVariable(global.name, @intCast(global.size));
        }

        // Write ELF to buffer
        var output = std.ArrayListUnmanaged(u8){};
        errdefer output.deinit(self.allocator);

        try elf_writer.write(output.writer(self.allocator));

        return output.toOwnedSlice(self.allocator);
    }
};

// =========================================
// Tests
// =========================================

test "AMD64CodeGen basic" {
    const allocator = std.testing.allocator;
    var codegen = AMD64CodeGen.init(allocator);
    defer codegen.deinit();

    // Just verify it initializes correctly
    try std.testing.expect(codegen.code.items.len == 0);
}

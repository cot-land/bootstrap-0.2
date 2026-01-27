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
    fn getDestRegForValue(self: *AMD64CodeGen, value: *const Value) Reg {
        if (self.regalloc_state) |state| {
            if (value.id < state.values.len) {
                const val_state = state.values[value.id];
                if (val_state.firstReg()) |reg_num| {
                    return regNumToAMD64(@intCast(reg_num));
                }
            }
        }
        // Fallback: use RAX
        return .rax;
    }

    /// Get register for a value that's already been computed.
    fn getRegForValue(self: *AMD64CodeGen, value: *const Value) ?Reg {
        if (self.regalloc_state) |state| {
            if (value.id < state.values.len) {
                const val_state = state.values[value.id];
                if (val_state.firstReg()) |reg_num| {
                    return regNumToAMD64(@intCast(reg_num));
                }
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
            else => {
                // Load from spill slot
                // TODO: implement spill slot loading
                debug.log(.codegen, "WARNING: ensureInReg fallback for {s}", .{@tagName(value.op)});
            },
        }
    }

    // ========================================================================
    // Code Generation
    // ========================================================================

    /// Generate binary code for a function.
    pub fn generateBinary(self: *AMD64CodeGen, f: *const Func, name: []const u8) !void {
        self.func = f;
        const start_offset = self.offset();

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
                // Return block: move control value to RAX and return
                if (block.controlValues().len > 0) {
                    const ret_val = block.controlValues()[0];
                    try self.moveToRAX(ret_val);
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
                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], .rax);
                        break :blk Reg.rax;
                    };
                    const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], .rcx);
                        break :blk Reg.rcx;
                    };
                    const dest_reg = self.getDestRegForValue(value);

                    // If dest != op1, move op1 to dest first
                    if (dest_reg != op1_reg) {
                        try self.emit(3, asm_mod.encodeMovRegReg(dest_reg, op1_reg));
                    }
                    // ADD dest, op2
                    try self.emit(3, asm_mod.encodeAddRegReg(dest_reg, op2_reg));
                }
            },

            .sub => {
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
                    try self.emit(3, asm_mod.encodeSubRegReg(dest_reg, op2_reg));
                }
            },

            .mul => {
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
                    // IMUL dest, op2
                    try self.emit(4, asm_mod.encodeImulRegReg(dest_reg, op2_reg));
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
                    const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], .rcx);
                        break :blk Reg.rcx;
                    };

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
                    const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], .rcx);
                        break :blk Reg.rcx;
                    };

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

            .eq, .ne, .lt, .le, .gt, .ge => {
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

                    // Zero dest first, then set low byte
                    try self.emit(3, asm_mod.encodeXorRegReg(dest_reg, dest_reg));
                    try self.emit(4, asm_mod.encodeSetcc(cond, dest_reg));
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
                // Function argument - already in correct register per ABI
                // RDI, RSI, RDX, RCX, R8, R9 for first 6 args
                // The regalloc should have assigned appropriate registers
            },

            .static_call => {
                // Function call
                // Get target function name from aux.string
                const target_name = switch (value.aux) {
                    .string => |s| s,
                    else => "unknown",
                };

                // Arguments should already be in correct registers per ABI
                // RDI, RSI, RDX, RCX, R8, R9

                // Emit CALL rel32 with relocation
                const call_offset = self.offset();
                try self.emit(5, asm_mod.encodeCall(0)); // Placeholder

                // Record relocation
                try self.relocations.append(self.allocator, .{
                    .offset = @intCast(call_offset + 1), // Skip E8 opcode
                    .target = target_name,
                });

                debug.log(.codegen, "      CALL {s}", .{target_name});
            },

            .load => {
                // Load from memory
                // TODO: implement memory loads
                debug.log(.codegen, "      (load not fully implemented)", .{});
            },

            .store => {
                // Store to memory
                // TODO: implement memory stores
                debug.log(.codegen, "      (store not fully implemented)", .{});
            },

            .local_addr => {
                // Address of local variable on stack
                const dest_reg = self.getDestRegForValue(value);
                const stack_offset = value.aux_int;

                // LEA dest, [RBP - offset]
                const disp: i32 = @intCast(-stack_offset);
                const lea = asm_mod.encodeLeaDisp32(dest_reg, .rbp, disp);
                try self.emitBytes(lea.data[0..lea.len]);
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

        // Add relocations
        for (self.relocations.items) |reloc| {
            try elf_writer.addRelocation(reloc.offset, reloc.target);
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

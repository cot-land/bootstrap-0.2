//! ARM64-optimized code generation.
//!
//! Go reference: [cmd/compile/internal/arm64/ssa.go]
//!
//! Generates optimized ARM64 code with register allocation.
//! Supports both text assembly output (for debugging) and binary output (for object files).
//!
//! ## Design
//!
//! - Uses linear scan register allocation from regalloc.zig
//! - Targets Apple Silicon / ARMv8-A
//! - Generates proper ABI-compliant code
//! - Uses asm.zig for machine code encoding
//!
//! ## Related Modules
//!
//! - [generic.zig] - Reference implementation (no optimization)
//! - [ssa/op.zig] - ARM64-specific operations (arm64_*)
//! - [ssa/regalloc.zig] - Register allocation
//! - [arm64/asm.zig] - Instruction encoding
//!
//! ## Example Output
//!
//! ```asm
//! _test:
//!     stp x29, x30, [sp, #-16]!
//!     mov x0, #42
//!     mov x1, #10
//!     add x0, x0, x1
//!     ldp x29, x30, [sp], #16
//!     ret
//! ```

const std = @import("std");
const Func = @import("../ssa/func.zig").Func;
const Block = @import("../ssa/block.zig").Block;
const Value = @import("../ssa/value.zig").Value;
const Op = @import("../ssa/op.zig").Op;
const Location = @import("../ssa/func.zig").Location;
const asm_mod = @import("../arm64/asm.zig");
const regalloc = @import("../ssa/regalloc.zig");
const macho = @import("../obj/macho.zig");

/// ARM64 register numbers.
pub const Reg = enum(u8) {
    // General purpose registers
    x0 = 0,
    x1,
    x2,
    x3,
    x4,
    x5,
    x6,
    x7,
    x8,
    x9,
    x10,
    x11,
    x12,
    x13,
    x14,
    x15,
    x16, // IP0
    x17, // IP1
    x18, // Platform register
    x19, // Callee-saved
    x20,
    x21,
    x22,
    x23,
    x24,
    x25,
    x26,
    x27,
    x28,
    x29, // FP
    x30, // LR
    sp, // Stack pointer (x31)

    // Floating point registers
    v0 = 32,
    v1,
    v2,
    v3,
    v4,
    v5,
    v6,
    v7,
    // ... more as needed

    pub fn name(self: Reg) []const u8 {
        return switch (self) {
            .x0 => "x0",
            .x1 => "x1",
            .x2 => "x2",
            .x3 => "x3",
            .x4 => "x4",
            .x5 => "x5",
            .x6 => "x6",
            .x7 => "x7",
            .x29 => "x29",
            .x30 => "x30",
            .sp => "sp",
            else => "?",
        };
    }
};

/// Caller-saved registers (can be clobbered by calls).
pub const caller_saved = [_]Reg{
    .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7,
    .x8, .x9, .x10, .x11, .x12, .x13, .x14, .x15,
};

/// Callee-saved registers (must be preserved across calls).
pub const callee_saved = [_]Reg{
    .x19, .x20, .x21, .x22, .x23, .x24, .x25, .x26, .x27, .x28,
};

/// Relocation entry for function calls.
pub const Relocation = struct {
    /// Offset in code where BL instruction is located
    offset: u32,
    /// Target symbol name
    target: []const u8,
};

/// Branch fixup entry for patching branch targets after code generation.
const BranchFixup = struct {
    /// Offset in code where the branch instruction is located
    code_offset: u32,
    /// Target block ID to branch to
    target_block_id: u32,
    /// Is this a CBZ instruction? (vs B instruction)
    is_cbz: bool,
};

/// ARM64 code generator.
///
/// Generates ARM64 code using register allocation.
/// Supports both text output (for debugging) and binary output (for object files).
pub const ARM64CodeGen = struct {
    allocator: std.mem.Allocator,
    func: *const Func,

    /// Stack frame size.
    frame_size: i64 = 0,

    /// Register state.
    reg_state: [32]?*const Value = [_]?*const Value{null} ** 32,

    /// Generated machine code bytes (for binary output)
    code: std.ArrayListUnmanaged(u8),

    /// Symbols for object file
    symbols: std.ArrayListUnmanaged(macho.Symbol),

    /// Relocations for function calls (offset, target symbol name)
    relocations: std.ArrayListUnmanaged(Relocation),

    /// Register allocation results (borrowed reference, owned by caller)
    regalloc_state: ?*const regalloc.RegAllocState,

    /// Simple value-to-register mapping for MVP (before full regalloc integration)
    value_regs: std.AutoHashMapUnmanaged(*const Value, u5),

    /// Next register to allocate for MVP (simple linear allocation)
    next_reg: u5 = 0,

    /// Block ID → code offset mapping (for branch calculations)
    block_offsets: std.AutoHashMapUnmanaged(u32, u32),

    /// Pending branch fixups (patched after all blocks are generated)
    branch_fixups: std.ArrayListUnmanaged(BranchFixup),

    pub fn init(allocator: std.mem.Allocator) ARM64CodeGen {
        return .{
            .allocator = allocator,
            .func = undefined,
            .code = .{},
            .symbols = .{},
            .relocations = .{},
            .regalloc_state = null,
            .value_regs = .{},
            .block_offsets = .{},
            .branch_fixups = .{},
        };
    }

    pub fn deinit(self: *ARM64CodeGen) void {
        self.code.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.relocations.deinit(self.allocator);
        self.value_regs.deinit(self.allocator);
        self.block_offsets.deinit(self.allocator);
        self.branch_fixups.deinit(self.allocator);
        // regalloc_state is borrowed, not owned - don't deinit
    }

    /// Set the register allocation state (borrowed reference).
    /// Must be called before generateBinary.
    pub fn setRegAllocState(self: *ARM64CodeGen, state: *const regalloc.RegAllocState) void {
        self.regalloc_state = state;
    }

    // ========================================================================
    // Text Output (for debugging)
    // ========================================================================

    /// Generate ARM64 assembly for a function (text output for debugging).
    pub fn generate(self: *ARM64CodeGen, f: *const Func, writer: anytype) !void {
        self.func = f;

        // Function prologue
        try writer.print("_{s}:\n", .{f.name});
        try writer.writeAll("    stp x29, x30, [sp, #-16]!\n");
        try writer.writeAll("    mov x29, sp\n");

        // Generate code for each block
        for (f.blocks.items) |b| {
            try self.generateBlock(b, writer);
        }
    }

    fn generateBlock(self: *ARM64CodeGen, b: *const Block, writer: anytype) !void {
        try writer.print(".Lb{d}:\n", .{b.id});

        for (b.values.items) |v| {
            try self.generateValue(v, writer);
        }

        // Block terminator
        switch (b.kind) {
            .ret => {
                try writer.writeAll("    ldp x29, x30, [sp], #16\n");
                try writer.writeAll("    ret\n");
            },
            .if_ => {
                if (b.succs.len >= 2) {
                    try writer.print("    b.ne .Lb{d}\n", .{b.succs[0].b.id});
                    try writer.print("    b .Lb{d}\n", .{b.succs[1].b.id});
                }
            },
            .plain => {
                if (b.succs.len > 0) {
                    try writer.print("    b .Lb{d}\n", .{b.succs[0].b.id});
                }
            },
            else => {},
        }
    }

    fn generateValue(self: *ARM64CodeGen, v: *const Value, writer: anytype) !void {
        _ = self;

        switch (v.op) {
            .arm64_add => try writer.writeAll("    add ...\n"),
            .arm64_sub => try writer.writeAll("    sub ...\n"),
            .arm64_mul => try writer.writeAll("    mul ...\n"),
            .arm64_ldr => try writer.writeAll("    ldr ...\n"),
            .arm64_str => try writer.writeAll("    str ...\n"),
            .arm64_movz => try writer.print("    movz x?, #{d}\n", .{v.aux_int}),

            .const_int => {
                if (v.aux_int >= 0 and v.aux_int <= 65535) {
                    try writer.print("    mov x?, #{d}    ; v{d}\n", .{ v.aux_int, v.id });
                } else {
                    try writer.print("    ; v{d} = const {d}\n", .{ v.id, v.aux_int });
                }
            },

            else => {
                try writer.print("    ; v{d} = {s}\n", .{ v.id, @tagName(v.op) });
            },
        }
    }

    // ========================================================================
    // Binary Output (for object files)
    // ========================================================================

    /// Emit a 32-bit instruction (little-endian)
    fn emit(self: *ARM64CodeGen, inst: u32) !void {
        const bytes: [4]u8 = @bitCast(inst);
        try self.code.appendSlice(self.allocator, &bytes);
    }

    /// Current code offset
    fn offset(self: *const ARM64CodeGen) u32 {
        return @intCast(self.code.items.len);
    }

    /// Generate binary code for a function.
    pub fn generateBinary(self: *ARM64CodeGen, f: *const Func, name: []const u8) !void {
        self.func = f;
        const start_offset = self.offset();

        // Clear state for new function
        self.value_regs.clearRetainingCapacity();
        self.block_offsets.clearRetainingCapacity();
        self.branch_fixups.clearRetainingCapacity();

        // Add symbol (prepend underscore for macOS symbol naming convention)
        // All functions are external so they can be called from other functions
        const sym_name = try std.fmt.allocPrint(self.allocator, "_{s}", .{name});
        try self.symbols.append(self.allocator, .{
            .name = sym_name,
            .value = start_offset,
            .section = 1, // __text section
            .external = true, // All functions are external
        });

        // Emit prologue
        try self.emitPrologue();

        // Generate code for each block, recording offsets
        for (f.blocks.items) |block| {
            try self.generateBlockBinary(block);
        }

        // Apply branch fixups now that we know all block offsets
        try self.applyBranchFixups();
    }

    /// Apply all pending branch fixups.
    fn applyBranchFixups(self: *ARM64CodeGen) !void {
        for (self.branch_fixups.items) |fixup| {
            const target_offset = self.block_offsets.get(fixup.target_block_id) orelse continue;
            // Calculate relative offset in instructions (words, not bytes)
            const branch_addr = fixup.code_offset;
            const target_addr = target_offset;
            const relative_offset: i32 = @as(i32, @intCast(target_addr)) - @as(i32, @intCast(branch_addr));
            const offset_words = @divExact(relative_offset, 4);

            // Patch the instruction
            if (fixup.is_cbz) {
                // CBZ/CBNZ: we emitted CBZ with placeholder, need to patch imm19
                // Re-encode with correct offset
                const offset_i19: i19 = @intCast(offset_words);
                const patched = asm_mod.encodeCBZ(0, offset_i19); // rt=0 as placeholder, will be ORed with existing
                // Read existing instruction to get the register
                const existing = std.mem.readInt(u32, self.code.items[fixup.code_offset..][0..4], .little);
                const rt = existing & 0x1F; // Extract Rt from bits 4-0
                const new_inst = (patched & ~@as(u32, 0x1F)) | rt;
                std.mem.writeInt(u32, self.code.items[fixup.code_offset..][0..4], new_inst, .little);
            } else {
                // Unconditional B: offset_words goes into imm26
                const offset_i26: i26 = @intCast(offset_words);
                const patched = asm_mod.encodeB(offset_i26);
                std.mem.writeInt(u32, self.code.items[fixup.code_offset..][0..4], patched, .little);
            }
        }
    }

    /// Emit function prologue
    fn emitPrologue(self: *ARM64CodeGen) !void {
        // stp x29, x30, [sp, #-16]!
        try self.emit(asm_mod.encodeSTPPre(29, 30, 31, -2)); // -2 * 8 = -16 bytes
    }

    /// Emit function epilogue and return
    fn emitEpilogue(self: *ARM64CodeGen) !void {
        // ldp x29, x30, [sp], #16
        try self.emit(asm_mod.encodeLDPPost(29, 30, 31, 2)); // 2 * 8 = 16 bytes
        // ret
        try self.emit(asm_mod.encodeRET(30));
    }

    /// Generate binary code for a block
    fn generateBlockBinary(self: *ARM64CodeGen, block: *const Block) !void {
        // Record block start offset for branch calculations
        try self.block_offsets.put(self.allocator, block.id, self.offset());

        // Generate each value in the block
        for (block.values.items) |value| {
            try self.generateValueBinary(value);
        }

        // Generate terminator based on block kind
        switch (block.kind) {
            .ret => {
                // Return block - ensure return value is in x0
                if (block.numControls() > 0) {
                    const ret_val = block.controlValues()[0];
                    try self.moveToX0(ret_val);
                }
                try self.emitEpilogue();
            },
            .if_ => {
                // Conditional branch
                // succs[0] = then block, succs[1] = else block
                // Control value is the condition (0 = false, nonzero = true)
                if (block.succs.len >= 2) {
                    const cond_val = block.controlValues()[0];
                    const cond_reg = self.getRegForValue(cond_val) orelse blk: {
                        try self.ensureInReg(cond_val, 8); // Use x8 as temp
                        break :blk @as(u5, 8);
                    };

                    const then_block = block.succs[0].b;
                    const else_block = block.succs[1].b;

                    // Emit CBZ (branch to else if condition is zero/false)
                    // Record fixup to patch later
                    const cbz_offset = self.offset();
                    try self.emit(asm_mod.encodeCBZ(cond_reg, 0)); // Placeholder offset
                    try self.branch_fixups.append(self.allocator, .{
                        .code_offset = cbz_offset,
                        .target_block_id = else_block.id,
                        .is_cbz = true,
                    });

                    // Emit unconditional branch to then block
                    // (in case then block isn't immediately after)
                    const b_offset = self.offset();
                    try self.emit(asm_mod.encodeB(0)); // Placeholder offset
                    try self.branch_fixups.append(self.allocator, .{
                        .code_offset = b_offset,
                        .target_block_id = then_block.id,
                        .is_cbz = false,
                    });
                }
            },
            .plain => {
                // Plain block - branch to successor if not falling through
                if (block.succs.len > 0) {
                    const target = block.succs[0].b;
                    const b_offset = self.offset();
                    try self.emit(asm_mod.encodeB(0)); // Placeholder
                    try self.branch_fixups.append(self.allocator, .{
                        .code_offset = b_offset,
                        .target_block_id = target.id,
                        .is_cbz = false,
                    });
                }
            },
            else => {},
        }
    }

    /// Generate binary code for a value
    fn generateValueBinary(self: *ARM64CodeGen, value: *const Value) !void {
        switch (value.op) {
            .const_int, .const_64 => {
                // Get destination register from regalloc (or fallback to naive)
                const dest_reg = self.getDestRegForValue(value);
                try self.emitLoadImmediate(dest_reg, value.aux_int);
                try self.value_regs.put(self.allocator, value, dest_reg);
            },

            .const_bool => {
                const dest_reg = self.getDestRegForValue(value);
                const imm: i64 = if (value.aux_int != 0) 1 else 0;
                try self.emitLoadImmediate(dest_reg, imm);
                try self.value_regs.put(self.allocator, value, dest_reg);
            },

            .add => {
                const args = value.args;
                if (args.len >= 2) {
                    // Get registers from regalloc (or fallback)
                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], 0);
                        break :blk @as(u5, 0);
                    };
                    const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], 1);
                        break :blk @as(u5, 1);
                    };
                    const dest_reg = self.getDestRegForValue(value);
                    try self.emit(asm_mod.encodeADDReg(dest_reg, op1_reg, op2_reg));
                    try self.value_regs.put(self.allocator, value, dest_reg);
                }
            },

            .sub => {
                const args = value.args;
                if (args.len >= 2) {
                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], 0);
                        break :blk @as(u5, 0);
                    };
                    const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], 1);
                        break :blk @as(u5, 1);
                    };
                    const dest_reg = self.getDestRegForValue(value);
                    try self.emit(asm_mod.encodeSUBReg(dest_reg, op1_reg, op2_reg));
                    try self.value_regs.put(self.allocator, value, dest_reg);
                }
            },

            .mul => {
                const args = value.args;
                if (args.len >= 2) {
                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], 0);
                        break :blk @as(u5, 0);
                    };
                    const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], 1);
                        break :blk @as(u5, 1);
                    };
                    const dest_reg = self.getDestRegForValue(value);
                    try self.emit(asm_mod.encodeMUL(dest_reg, op1_reg, op2_reg));
                    try self.value_regs.put(self.allocator, value, dest_reg);
                }
            },

            .div => {
                const args = value.args;
                if (args.len >= 2) {
                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], 0);
                        break :blk @as(u5, 0);
                    };
                    const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], 1);
                        break :blk @as(u5, 1);
                    };
                    const dest_reg = self.getDestRegForValue(value);
                    try self.emit(asm_mod.encodeSDIV(dest_reg, op1_reg, op2_reg));
                    try self.value_regs.put(self.allocator, value, dest_reg);
                }
            },

            .arg => {
                // Function argument - already in register per ABI
                const arg_idx: u5 = @intCast(value.aux_int);
                try self.value_regs.put(self.allocator, value, arg_idx);
            },

            // === Comparison Operations ===
            .eq, .ne, .lt, .le, .gt, .ge => {
                const args = value.args;
                if (args.len >= 2) {
                    const op1_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], 0);
                        break :blk @as(u5, 0);
                    };
                    const op2_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], 1);
                        break :blk @as(u5, 1);
                    };
                    const dest_reg = self.getDestRegForValue(value);

                    // CMP op1, op2 (sets flags)
                    try self.emit(asm_mod.encodeCMPReg(op1_reg, op2_reg));

                    // CSET dest, cond (set dest to 1 if condition true, 0 otherwise)
                    const cond: asm_mod.Cond = switch (value.op) {
                        .eq => .eq,
                        .ne => .ne,
                        .lt => .lt,
                        .le => .le,
                        .gt => .gt,
                        .ge => .ge,
                        else => .eq,
                    };
                    try self.emit(asm_mod.encodeCSET(dest_reg, cond));
                    try self.value_regs.put(self.allocator, value, dest_reg);
                }
            },

            .phi, .copy, .fwd_ref => {
                // These should be resolved by regalloc
                const dest_reg = self.allocateReg();
                try self.value_regs.put(self.allocator, value, dest_reg);
            },

            .static_call => {
                // Function call - ARM64 ABI: args in x0-x7, result in x0
                const args = value.args;

                // Move arguments to x0-x7
                for (args, 0..) |arg, i| {
                    if (i >= 8) break; // Only first 8 args in registers
                    const arg_reg: u5 = @intCast(i);
                    try self.ensureInReg(arg, arg_reg);
                }

                // Get target function name from aux.string
                const raw_name = switch (value.aux) {
                    .string => |s| s,
                    else => "unknown",
                };

                // Prepend underscore for macOS symbol naming convention
                const target_name = try std.fmt.allocPrint(self.allocator, "_{s}", .{raw_name});

                // Record relocation for linker to resolve
                try self.relocations.append(self.allocator, .{
                    .offset = @intCast(self.offset()),
                    .target = target_name,
                });

                // Emit BL with offset 0 (linker will fix)
                try self.emit(asm_mod.encodeBL(0));

                // Result is in x0
                try self.value_regs.put(self.allocator, value, 0);
            },

            else => {
                // Unhandled op - skip
            },
        }
    }

    /// Allocate a register for a new value
    fn allocateReg(self: *ARM64CodeGen) u5 {
        // Simple linear allocation: x0-x15 are caller-saved
        const reg = self.next_reg;
        self.next_reg = if (self.next_reg >= 15) 0 else self.next_reg + 1;
        return reg;
    }

    /// Ensure a value is in the specified register, regenerating if needed
    fn ensureInReg(self: *ARM64CodeGen, value: *const Value, dest: u5) !void {
        // Check regalloc first, then fallback tracking
        if (self.getRegForValue(value)) |src_reg| {
            if (src_reg != dest) {
                // Move from src to dest (using ADD Rd, Rn, #0)
                try self.emit(asm_mod.encodeADDImm(dest, src_reg, 0, 0));
            }
            return;
        }

        // Value not tracked - regenerate it
        switch (value.op) {
            .const_int, .const_64 => try self.emitLoadImmediate(dest, value.aux_int),
            .const_bool => {
                const imm: i64 = if (value.aux_int != 0) 1 else 0;
                try self.emitLoadImmediate(dest, imm);
            },
            else => {
                // Fallback: emit 0
                try self.emit(asm_mod.encodeMOVZ(dest, 0, 0));
            },
        }
    }

    /// Get register for a value from regalloc (preferred) or value_regs fallback
    fn getRegForValue(self: *ARM64CodeGen, value: *const Value) ?u5 {
        // Check regalloc state FIRST (this is the proper Go-inspired pipeline)
        if (self.regalloc_state) |state| {
            if (value.id < state.values.len) {
                const val_state = state.values[value.id];
                if (val_state.firstReg()) |reg| {
                    return @intCast(reg);
                }
            }
        }

        // Fallback to simple tracking (for values not in regalloc)
        if (self.value_regs.get(value)) |reg| {
            return reg;
        }

        return null;
    }

    /// Get destination register for a value from regalloc, or allocate naively
    fn getDestRegForValue(self: *ARM64CodeGen, value: *const Value) u5 {
        // Check regalloc state FIRST
        if (self.regalloc_state) |state| {
            if (value.id < state.values.len) {
                const val_state = state.values[value.id];
                if (val_state.firstReg()) |reg| {
                    return @intCast(reg);
                }
            }
        }

        // Fallback: naive allocation (shouldn't happen if regalloc is working)
        return self.allocateReg();
    }

    /// Ensure value is in x0
    fn moveToX0(self: *ARM64CodeGen, value: *const Value) !void {
        try self.moveToReg(0, value);
    }

    /// Move value to specified register
    fn moveToReg(self: *ARM64CodeGen, dest: u5, value: *const Value) !void {
        // Check if value is already in the destination register
        if (self.value_regs.get(value)) |src_reg| {
            if (src_reg == dest) return;
            // mov dest, src (via ORR with XZR)
            try self.emit(asm_mod.encodeADDReg(dest, 31, src_reg));
            return;
        }

        // Value not in register - regenerate it
        switch (value.op) {
            .const_int, .const_64 => try self.emitLoadImmediate(dest, value.aux_int),
            .const_bool => {
                const imm: i64 = if (value.aux_int != 0) 1 else 0;
                try self.emitLoadImmediate(dest, imm);
            },
            else => {
                // Fallback: emit 0
                try self.emit(asm_mod.encodeMOVZ(dest, 0, 0));
            },
        }
    }

    /// Emit code to load an immediate value into a register
    fn emitLoadImmediate(self: *ARM64CodeGen, reg: u5, value: i64) !void {
        const uvalue: u64 = @bitCast(value);

        // Check if it fits in 16 bits (most common case)
        if (uvalue <= 0xFFFF) {
            try self.emit(asm_mod.encodeMOVZ(reg, @truncate(uvalue), 0));
            return;
        }

        // Check for negative small number
        if (value < 0 and value >= -65536) {
            const notval: u16 = @truncate(~uvalue);
            try self.emit(asm_mod.encodeMOVN(reg, notval, 0));
            return;
        }

        // Need multiple instructions for larger values
        try self.emit(asm_mod.encodeMOVZ(reg, @truncate(uvalue), 0));

        if ((uvalue >> 16) & 0xFFFF != 0) {
            try self.emit(asm_mod.encodeMOVK(reg, @truncate(uvalue >> 16), 1));
        }
        if ((uvalue >> 32) & 0xFFFF != 0) {
            try self.emit(asm_mod.encodeMOVK(reg, @truncate(uvalue >> 32), 2));
        }
        if ((uvalue >> 48) & 0xFFFF != 0) {
            try self.emit(asm_mod.encodeMOVK(reg, @truncate(uvalue >> 48), 3));
        }
    }

    /// Finalize and write Mach-O object file to a buffer
    pub fn finalize(self: *ARM64CodeGen) ![]u8 {
        var writer = macho.MachOWriter.init(self.allocator);
        defer writer.deinit();

        // Add generated code
        try writer.addCode(self.code.items);

        // Add symbols
        for (self.symbols.items) |sym| {
            try writer.addSymbol(sym.name, sym.value, sym.section, sym.external);
        }

        // Add relocations for function calls
        for (self.relocations.items) |reloc| {
            try writer.addRelocation(reloc.offset, reloc.target);
        }

        // Write to buffer
        var output = std.ArrayListUnmanaged(u8){};
        try writer.write(output.writer(self.allocator));

        return try output.toOwnedSlice(self.allocator);
    }
};

// =========================================
// Tests
// =========================================

test "ARM64CodeGen generates function prologue" {
    const allocator = std.testing.allocator;

    var f = Func.init(allocator, "test_arm64");
    defer f.deinit();

    _ = try f.newBlock(.ret);

    var codegen = ARM64CodeGen.init(allocator);

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    try codegen.generate(&f, output.writer(allocator));

    // Should contain function label and prologue
    try std.testing.expect(std.mem.indexOf(u8, output.items, "_test_arm64") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "stp") != null);
}

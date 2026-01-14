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
const debug = @import("../pipeline_debug.zig");

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
/// Reference to a string literal that needs relocation
const StringRef = struct {
    adrp_offset: u32, // Code offset of ADRP instruction
    add_offset: u32, // Code offset of ADD instruction
    string_data: []const u8, // Actual string data (owned copy)
};

pub const ARM64CodeGen = struct {
    allocator: std.mem.Allocator,
    func: *const Func,

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

    /// Stack frame size for spilled values (set from stackalloc)
    frame_size: u32 = 16, // Default: just FP/LR

    /// Next spill slot to allocate (for Go-style spill/reload)
    next_spill_slot: u32 = 0,

    /// Map from store_reg value to its spill slot index
    spill_slot_map: std.AutoHashMapUnmanaged(*const Value, u32),

    /// Block ID → code offset mapping (for branch calculations)
    block_offsets: std.AutoHashMapUnmanaged(u32, u32),

    /// Pending branch fixups (patched after all blocks are generated)
    branch_fixups: std.ArrayListUnmanaged(BranchFixup),

    /// Pending string references: (adrp_offset, add_offset, string_index)
    /// Used to add relocations during finalize()
    string_refs: std.ArrayListUnmanaged(StringRef),

    /// Data relocations for ADRP/ADD pairs (added during finalize)
    data_relocations: std.ArrayListUnmanaged(macho.ExtRelocation),

    pub fn init(allocator: std.mem.Allocator) ARM64CodeGen {
        return .{
            .allocator = allocator,
            .func = undefined,
            .code = .{},
            .symbols = .{},
            .relocations = .{},
            .regalloc_state = null,
            .value_regs = .{},
            .spill_slot_map = .{},
            .block_offsets = .{},
            .branch_fixups = .{},
            .string_refs = .{},
            .data_relocations = .{},
        };
    }

    pub fn deinit(self: *ARM64CodeGen) void {
        self.code.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.relocations.deinit(self.allocator);
        self.value_regs.deinit(self.allocator);
        self.spill_slot_map.deinit(self.allocator);
        self.block_offsets.deinit(self.allocator);
        self.branch_fixups.deinit(self.allocator);
        // Free string data copies
        for (self.string_refs.items) |str_ref| {
            self.allocator.free(str_ref.string_data);
        }
        self.string_refs.deinit(self.allocator);
        self.data_relocations.deinit(self.allocator);
        // regalloc_state is borrowed, not owned - don't deinit
    }

    /// Set the register allocation state (borrowed reference).
    /// Must be called before generateBinary.
    pub fn setRegAllocState(self: *ARM64CodeGen, state: *const regalloc.RegAllocState) void {
        self.regalloc_state = state;
    }

    /// Set the stack frame size (from stackalloc).
    /// Must be called before generateBinary.
    pub fn setFrameSize(self: *ARM64CodeGen, size: u32) void {
        self.frame_size = size;
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

        debug.log(.codegen, "Generating code for function '{s}', {d} blocks", .{ name, f.blocks.items.len });

        // Clear state for new function
        self.value_regs.clearRetainingCapacity();
        self.block_offsets.clearRetainingCapacity();
        self.branch_fixups.clearRetainingCapacity();
        self.next_reg = 0; // Reset register allocation

        // Log frame size (set by setFrameSize from stackalloc)
        debug.log(.codegen, "  Stack frame: {d} bytes", .{self.frame_size});

        // Add symbol (prepend underscore for macOS symbol naming convention)
        // All functions are external so they can be called from other functions
        const sym_name = try std.fmt.allocPrint(self.allocator, "_{s}", .{name});
        try self.symbols.append(self.allocator, .{
            .name = sym_name,
            .value = start_offset,
            .section = 1, // __text section
            .external = true, // All functions are external
        });

        // Pre-allocate registers for all phi nodes
        // This is necessary so that phi moves know the destination register
        // before the phi block is generated
        try self.preAllocatePhiRegisters(f);

        // Emit prologue (Go's approach: only save FP/LR)
        debug.log(.codegen, "  Emitting prologue", .{});
        try self.emitPrologue();

        // Generate code for each block, recording offsets
        for (f.blocks.items) |block| {
            try self.generateBlockBinary(block);
        }

        // Apply branch fixups now that we know all block offsets
        try self.applyBranchFixups();

        debug.log(.codegen, "  Function '{s}' done, code size: {d} bytes", .{ name, self.offset() - start_offset });
    }

    /// Pre-allocate registers for all phi nodes in the function.
    /// This is called before code generation so that phi moves can
    /// look up the destination register before the phi is generated.
    /// NOTE: When regalloc_state exists, we use regalloc's assignments instead.
    fn preAllocatePhiRegisters(self: *ARM64CodeGen, f: *const Func) !void {
        // Skip pre-allocation if regalloc has already assigned registers
        if (self.regalloc_state != null) {
            return;
        }

        for (f.blocks.items) |block| {
            for (block.values.items) |value| {
                if (value.op == .phi) {
                    const dest_reg = self.allocateReg();
                    try self.value_regs.put(self.allocator, value, dest_reg);
                }
            }
        }
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

    /// Emit function prologue.
    /// Go's approach: only save FP (x29) and LR (x30).
    /// Spilled values go to the stack frame, not callee-saved registers.
    fn emitPrologue(self: *ARM64CodeGen) !void {
        // Use frame_size from stackalloc (already 16-byte aligned)
        const aligned_frame = self.frame_size;

        // STP pre-index can handle up to 504 bytes (7-bit signed * 8)
        // For larger frames, use SUB sp first, then STP with signed offset
        if (aligned_frame <= 504) {
            // STP x29, x30, [sp, #-frame_size]!
            const frame_off: i7 = @intCast(-@divExact(@as(i32, @intCast(aligned_frame)), 8));
            try self.emit(asm_mod.encodeSTPPre(29, 30, 31, frame_off));
        } else {
            // Large frame: SUB sp, sp, #frame_size; STP x29, x30, [sp]
            // SUB immediate can handle up to 4095
            if (aligned_frame <= 4095) {
                try self.emit(asm_mod.encodeSUBImm(31, 31, @intCast(aligned_frame), 0));
            } else {
                // Very large frame: need to use a temp register
                // MOV x16, #frame_size; SUB sp, sp, x16
                try self.emitLoadImmediate(16, @intCast(aligned_frame));
                try self.emit(asm_mod.encodeSUBReg(31, 31, 16));
            }
            // STP x29, x30, [sp] (signed offset 0)
            try self.emit(asm_mod.encodeLdpStp(29, 30, 31, 0, .signed_offset, false));
        }

        // Set up frame pointer: ADD x29, sp, #0
        // (In a full implementation, x29 would point to saved FP location)
        try self.emit(asm_mod.encodeADDImm(29, 31, 0, 0));
    }

    /// Emit function epilogue and return.
    /// Go's approach: only restore FP (x29) and LR (x30).
    fn emitEpilogue(self: *ARM64CodeGen) !void {
        // Use frame_size from stackalloc (already 16-byte aligned)
        const aligned_frame = self.frame_size;

        // For frames <= 504 bytes, use LDP post-index
        // For larger frames, use LDP with offset 0, then ADD sp
        if (aligned_frame <= 504) {
            // LDP x29, x30, [sp], #frame_size
            const frame_off: i7 = @intCast(@divExact(@as(i32, @intCast(aligned_frame)), 8));
            try self.emit(asm_mod.encodeLDPPost(29, 30, 31, frame_off));
        } else {
            // Large frame: LDP x29, x30, [sp]; ADD sp, sp, #frame_size
            // LDP x29, x30, [sp] (signed offset 0)
            try self.emit(asm_mod.encodeLdpStp(29, 30, 31, 0, .signed_offset, true));
            // ADD sp, sp, #frame_size
            if (aligned_frame <= 4095) {
                try self.emit(asm_mod.encodeADDImm(31, 31, @intCast(aligned_frame), 0));
            } else {
                // Very large frame: use temp register
                try self.emitLoadImmediate(16, @intCast(aligned_frame));
                try self.emit(asm_mod.encodeADDReg(31, 31, 16));
            }
        }

        // RET
        try self.emit(asm_mod.encodeRET(30));
    }


    /// Emit phi moves for an edge from current block to target block.
    /// For each phi in the target block, find this block's corresponding argument
    /// and move it to the phi's register.
    fn emitPhiMoves(self: *ARM64CodeGen, current_block: *const Block, target_block: *const Block) !void {
        // Find which predecessor index we are in target's predecessor list
        var pred_idx: ?usize = null;
        for (target_block.preds, 0..) |pred_edge, i| {
            if (pred_edge.b.id == current_block.id) {
                pred_idx = i;
                break;
            }
        }
        const idx = pred_idx orelse return; // Not a predecessor (shouldn't happen)

        // Parallel copy algorithm:
        // When multiple phis need to be resolved, we can't emit moves sequentially
        // because a move's destination might be another move's source.
        // Example: phi1: x1 = x2, phi2: x5 = x1 - if we emit phi1 first, x1 is clobbered!
        //
        // Solution: Two-phase approach
        // Phase 1: Save all source values that might be clobbered to temp registers
        // Phase 2: Copy from temps/sources to final destinations

        const PhiMove = struct {
            src_val: *const Value,
            src_reg: ?u5,
            dest_reg: u5,
            needs_temp: bool,
            temp_reg: u5,
        };

        // Collect all phi moves
        var moves = std.ArrayListUnmanaged(PhiMove){};
        defer moves.deinit(self.allocator);

        for (target_block.values.items) |value| {
            if (value.op != .phi) continue;

            const args = value.args;
            if (idx >= args.len) continue;
            const src_val = args[idx];

            const phi_reg = self.getRegForValue(value) orelse continue;
            const src_reg = self.getRegForValue(src_val);

            try moves.append(self.allocator, .{
                .src_val = src_val,
                .src_reg = src_reg,
                .dest_reg = phi_reg,
                .needs_temp = false,
                .temp_reg = 0,
            });
        }

        if (moves.items.len == 0) return;

        // Detect conflicts: a source reg that will be overwritten before it's read
        // A move needs a temp if its source_reg equals any other move's dest_reg
        var temp_counter: u5 = 16; // Start with x16, x17 are scratch registers
        for (moves.items, 0..) |*move, i| {
            if (move.src_reg) |src| {
                // Check if this source will be clobbered by an earlier move
                for (moves.items[0..i]) |other| {
                    if (other.dest_reg == src) {
                        // This source will be clobbered before we read it
                        move.needs_temp = true;
                        move.temp_reg = temp_counter;
                        temp_counter += 1;
                        if (temp_counter > 17) {
                            // Ran out of scratch registers, fall back to x9-x15
                            temp_counter = 9;
                        }
                        break;
                    }
                }
            }
        }

        // Phase 1: Save conflicting sources to temp registers
        for (moves.items) |move| {
            if (move.needs_temp) {
                if (move.src_reg) |src| {
                    // MOV temp, src (encoded as ADD temp, src, #0)
                    try self.emit(asm_mod.encodeADDImm(move.temp_reg, src, 0, 0));
                }
            }
        }

        // Phase 2: Emit actual moves
        for (moves.items) |move| {
            if (move.needs_temp) {
                // Source was saved to temp
                if (move.src_reg != null) {
                    // MOV dest, temp
                    try self.emit(asm_mod.encodeADDImm(move.dest_reg, move.temp_reg, 0, 0));
                } else {
                    // Source wasn't in a register, regenerate to dest
                    try self.ensureInReg(move.src_val, move.dest_reg);
                }
            } else {
                // No conflict, emit directly
                if (move.src_reg) |s| {
                    if (s != move.dest_reg) {
                        try self.emit(asm_mod.encodeADDImm(move.dest_reg, s, 0, 0));
                    }
                } else {
                    try self.ensureInReg(move.src_val, move.dest_reg);
                }
            }
        }
    }

    /// Generate binary code for a block
    fn generateBlockBinary(self: *ARM64CodeGen, block: *const Block) !void {
        debug.log(.codegen, "  Block b{d}: {d} values, kind={s}", .{ block.id, block.values.items.len, @tagName(block.kind) });

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

                    // Emit phi moves for the else branch (taken when CBZ succeeds)
                    try self.emitPhiMoves(block, else_block);

                    // Emit CBZ (branch to else if condition is zero/false)
                    // Record fixup to patch later
                    const cbz_offset = self.offset();
                    try self.emit(asm_mod.encodeCBZ(cond_reg, 0)); // Placeholder offset
                    try self.branch_fixups.append(self.allocator, .{
                        .code_offset = cbz_offset,
                        .target_block_id = else_block.id,
                        .is_cbz = true,
                    });

                    // Emit phi moves for the then branch
                    try self.emitPhiMoves(block, then_block);

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

                    // Emit phi moves before branching
                    try self.emitPhiMoves(block, target);

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
        debug.log(.codegen, "    v{d} = {s}", .{ value.id, @tagName(value.op) });

        switch (value.op) {
            .const_int, .const_64 => {
                // Get destination register from regalloc (or fallback to naive)
                const dest_reg = self.getDestRegForValue(value);
                try self.emitLoadImmediate(dest_reg, value.aux_int);
                try self.value_regs.put(self.allocator, value, dest_reg);
                debug.log(.codegen, "      -> x{d} = #{d}", .{ dest_reg, value.aux_int });
            },

            .const_bool => {
                const dest_reg = self.getDestRegForValue(value);
                const imm: i64 = if (value.aux_int != 0) 1 else 0;
                try self.emitLoadImmediate(dest_reg, imm);
                try self.value_regs.put(self.allocator, value, dest_reg);
            },

            .const_nil => {
                // Null/nil is just 0 (like Go's nil)
                const dest_reg = self.getDestRegForValue(value);
                try self.emitLoadImmediate(dest_reg, 0);
                try self.value_regs.put(self.allocator, value, dest_reg);
            },

            .const_string => {
                // String literal: emit ADRP + ADD to load the string address.
                // The actual address is filled in by the linker via relocations.
                // The string index is in aux_int.
                const string_index: usize = @intCast(value.aux_int);
                const dest_reg = self.getDestRegForValue(value);

                // Get the string data and make a copy (func may be deinit'd before finalize)
                const str_data = if (string_index < self.func.string_literals.len)
                    self.func.string_literals[string_index]
                else
                    "";

                // Record the offsets for relocation fixup
                const adrp_offset = self.offset();
                // Emit ADRP with imm=0 (linker will fix up)
                try self.emit(asm_mod.encodeADRP(dest_reg, 0));

                const add_offset = self.offset();
                // Emit ADD with imm=0 (linker will fix up)
                try self.emit(asm_mod.encodeADDImm(dest_reg, dest_reg, 0, 0));

                // Record string reference with a copy of the data for relocation during finalize()
                const str_copy = try self.allocator.dupe(u8, str_data);
                try self.string_refs.append(self.allocator, .{
                    .adrp_offset = adrp_offset,
                    .add_offset = add_offset,
                    .string_data = str_copy,
                });

                try self.value_regs.put(self.allocator, value, dest_reg);
                debug.log(.codegen, "      -> x{d} = str[{d}] len={d} (pending reloc)", .{ dest_reg, string_index, str_data.len });
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

            .add_ptr => {
                // Pointer arithmetic - same as add but for addresses
                // Go uses OpPtrIndex which is: ptr + index * elemSize
                // Our add_ptr receives pre-computed offset: ptr + offset
                const args = value.args;
                if (args.len >= 2) {
                    const ptr_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], 0);
                        break :blk @as(u5, 0);
                    };
                    const off_reg = self.getRegForValue(args[1]) orelse blk: {
                        try self.ensureInReg(args[1], 1);
                        break :blk @as(u5, 1);
                    };
                    const dest_reg = self.getDestRegForValue(value);
                    try self.emit(asm_mod.encodeADDReg(dest_reg, ptr_reg, off_reg));
                    try self.value_regs.put(self.allocator, value, dest_reg);
                    debug.log(.codegen, "      -> ADD x{d}, x{d}, x{d} (add_ptr)", .{ dest_reg, ptr_reg, off_reg });
                }
            },

            .neg => {
                // NEG Rd, Rm is an alias for SUB Rd, XZR, Rm
                const args = value.args;
                if (args.len >= 1) {
                    const op_reg = self.getRegForValue(args[0]) orelse blk: {
                        try self.ensureInReg(args[0], 0);
                        break :blk @as(u5, 0);
                    };
                    const dest_reg = self.getDestRegForValue(value);
                    // XZR is register 31
                    try self.emit(asm_mod.encodeSUBReg(dest_reg, 31, op_reg));
                    try self.value_regs.put(self.allocator, value, dest_reg);
                }
            },

            .mod => {
                // ARM64 doesn't have modulo, compute as: a % b = a - (a / b) * b
                // Use x16 as scratch register
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
                    // x16 is scratch (IP0)
                    try self.emit(asm_mod.encodeSDIV(16, op1_reg, op2_reg)); // x16 = a / b
                    try self.emit(asm_mod.encodeMUL(16, 16, op2_reg)); // x16 = (a / b) * b
                    try self.emit(asm_mod.encodeSUBReg(dest_reg, op1_reg, 16)); // dest = a - x16
                    try self.value_regs.put(self.allocator, value, dest_reg);
                }
            },

            // === Bitwise Operations ===
            .and_ => {
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
                    try self.emit(asm_mod.encodeAND(dest_reg, op1_reg, op2_reg));
                    try self.value_regs.put(self.allocator, value, dest_reg);
                }
            },

            .or_ => {
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
                    try self.emit(asm_mod.encodeORR(dest_reg, op1_reg, op2_reg));
                    try self.value_regs.put(self.allocator, value, dest_reg);
                }
            },

            .xor => {
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
                    try self.emit(asm_mod.encodeEOR(dest_reg, op1_reg, op2_reg));
                    try self.value_regs.put(self.allocator, value, dest_reg);
                }
            },

            .shl => {
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
                    try self.emit(asm_mod.encodeLSL(dest_reg, op1_reg, op2_reg));
                    try self.value_regs.put(self.allocator, value, dest_reg);
                }
            },

            .shr => {
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
                    try self.emit(asm_mod.encodeLSR(dest_reg, op1_reg, op2_reg));
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

            .copy => {
                // Copy emits MOV from source to dest
                // Use regalloc's assigned register, not naive allocation
                const dest_reg = self.getDestRegForValue(value);
                const args = value.args;
                if (args.len > 0) {
                    const src = args[0];
                    try self.ensureInReg(src, dest_reg);
                }
                try self.value_regs.put(self.allocator, value, dest_reg);
            },

            .phi => {
                // Phi values are handled at block boundaries (see emitPhiMoves)
                // Register was pre-allocated in preAllocatePhiRegisters
                // Nothing to do here - the phi moves happen at predecessor blocks
            },

            .fwd_ref => {
                // Should not appear after phi insertion
                const dest_reg = self.allocateReg();
                try self.value_regs.put(self.allocator, value, dest_reg);
            },

            .static_call => {
                // Function call - ARM64 ABI: args in x0-x7, result in x0
                const args = value.args;

                // Use parallel copy to move arguments to x0-x7
                // This prevents clobbering when args are in each other's target registers
                // E.g., if arg0 is in x1 and arg1 is in x0, naive sequential moves fail
                try self.setupCallArgs(args);

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
                debug.log(.codegen, "      -> BL {s}, result in x0", .{raw_name});

                // Result is in x0 - regalloc will handle spill/reload if needed
                // Go's approach: don't move to callee-saved, let regalloc spill
                try self.value_regs.put(self.allocator, value, 0);
            },

            .store_reg => {
                // Spill a value to a stack slot (Go's approach)
                // Stack offset assigned by stackalloc via f.setHome()
                if (value.args.len > 0) {
                    const src_value = value.args[0];

                    // Get stack offset from stackalloc's assignment
                    const loc = value.getHome() orelse {
                        debug.log(.codegen, "      store_reg v{d}: NO stack location!", .{value.id});
                        return;
                    };
                    // ARM64 LDR/STR unsigned offset is scaled by 8 for 64-bit ops
                    const byte_off = loc.stackOffset();
                    const spill_off: u12 = @intCast(@divExact(byte_off, 8));

                    // Get the register holding the value to spill
                    const src_reg = self.getRegForValue(src_value) orelse 0;

                    // STR Xn, [SP, #offset]
                    try self.emit(asm_mod.encodeLdrStr(src_reg, 31, spill_off, false)); // false = store
                    debug.log(.codegen, "      -> STR x{d}, [SP, #{d}]", .{ src_reg, spill_off });
                }
            },

            .load_reg => {
                // Reload a value from a stack slot (Go's approach)
                if (value.args.len > 0) {
                    const spill_value = value.args[0];

                    // Get stack offset from the store_reg value's location
                    const loc = spill_value.getHome() orelse {
                        debug.log(.codegen, "      load_reg v{d}: source store_reg has NO location!", .{value.id});
                        return;
                    };
                    // ARM64 LDR/STR unsigned offset is scaled by 8 for 64-bit ops
                    const byte_off = loc.stackOffset();
                    const spill_off: u12 = @intCast(@divExact(byte_off, 8));

                    // Get destination register from regalloc
                    const dest_reg = self.getDestRegForValue(value);

                    // LDR Xn, [SP, #offset]
                    try self.emit(asm_mod.encodeLdrStr(dest_reg, 31, spill_off, true)); // true = load
                    debug.log(.codegen, "      -> LDR x{d}, [SP, #{d}]", .{ dest_reg, spill_off });

                    try self.value_regs.put(self.allocator, value, dest_reg);
                }
            },

            // === Struct Field Access Operations ===
            // Following Go's pattern: LocalAddr + OffPtr + Load/Store

            .local_addr => {
                // Compute address of a local variable on the stack
                // aux_int contains the local index
                const local_idx: usize = @intCast(value.aux_int);
                const dest_reg = self.getDestRegForValue(value);

                // Get stack offset from local_offsets (set by stackalloc)
                if (local_idx < self.func.local_offsets.len) {
                    const byte_off = self.func.local_offsets[local_idx];
                    // ADD Rd, SP, #offset
                    try self.emit(asm_mod.encodeADDImm(dest_reg, 31, @intCast(byte_off), 0));
                    debug.log(.codegen, "      -> ADD x{d}, SP, #{d} (local_addr {d})", .{ dest_reg, byte_off, local_idx });
                } else {
                    // Fallback: offset 0 (shouldn't happen)
                    try self.emit(asm_mod.encodeADDImm(dest_reg, 31, 0, 0));
                    debug.log(.codegen, "      -> ADD x{d}, SP, #0 (local_addr {d} - NO OFFSET!)", .{ dest_reg, local_idx });
                }
                try self.value_regs.put(self.allocator, value, dest_reg);
            },

            .off_ptr => {
                // Add field offset to base pointer
                // aux_int contains the offset, arg[0] is the base pointer
                if (value.args.len > 0) {
                    const base = value.args[0];
                    const field_off: i64 = value.aux_int;
                    const dest_reg = self.getDestRegForValue(value);

                    const base_reg = self.getRegForValue(base) orelse blk: {
                        // Need to get base into a register first
                        try self.ensureInReg(base, dest_reg);
                        break :blk dest_reg;
                    };

                    // ADD Rd, Rn, #offset
                    try self.emit(asm_mod.encodeADDImm(dest_reg, base_reg, @intCast(field_off), 0));
                    debug.log(.codegen, "      -> ADD x{d}, x{d}, #{d} (off_ptr)", .{ dest_reg, base_reg, field_off });
                    try self.value_regs.put(self.allocator, value, dest_reg);
                }
            },

            .load => {
                // Load from memory address
                // arg[0] is the address
                if (value.args.len > 0) {
                    const addr = value.args[0];
                    const dest_reg = self.getDestRegForValue(value);

                    const addr_reg = self.getRegForValue(addr) orelse blk: {
                        // Address should already be computed, but fallback
                        const temp_reg = self.allocateReg();
                        try self.ensureInReg(addr, temp_reg);
                        break :blk temp_reg;
                    };

                    // LDR Rd, [Rn]  (zero offset)
                    try self.emit(asm_mod.encodeLdrStr(dest_reg, addr_reg, 0, true));
                    debug.log(.codegen, "      -> LDR x{d}, [x{d}] (load)", .{ dest_reg, addr_reg });
                    try self.value_regs.put(self.allocator, value, dest_reg);
                }
            },

            .store => {
                // Store to memory address
                // arg[0] is the address, arg[1] is the value to store
                if (value.args.len >= 2) {
                    const addr = value.args[0];
                    const val = value.args[1];

                    const addr_reg = self.getRegForValue(addr) orelse blk: {
                        const temp_reg = self.allocateReg();
                        try self.ensureInReg(addr, temp_reg);
                        break :blk temp_reg;
                    };

                    const val_reg = self.getRegForValue(val) orelse blk: {
                        const temp_reg = self.allocateReg();
                        try self.ensureInReg(val, temp_reg);
                        break :blk temp_reg;
                    };

                    // STR Rn, [Rm]  (zero offset)
                    try self.emit(asm_mod.encodeLdrStr(val_reg, addr_reg, 0, false));
                    debug.log(.codegen, "      -> STR x{d}, [x{d}] (store)", .{ val_reg, addr_reg });
                }
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

    /// Allocate a callee-saved register (x19-x28) for values that must survive calls.
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
            .const_nil => try self.emitLoadImmediate(dest, 0),
            else => {
                // Fallback: emit 0
                try self.emit(asm_mod.encodeMOVZ(dest, 0, 0));
            },
        }
    }

    /// Get register for a value from regalloc (preferred) or value_regs fallback
    fn getRegForValue(self: *ARM64CodeGen, value: *const Value) ?u5 {
        // Check value_regs FIRST for values we've explicitly placed
        // (like static_call results saved to callee-saved registers)
        if (self.value_regs.get(value)) |reg| {
            return reg;
        }

        // Use the new Go-style API: value.regOrNull() looks up f.reg_alloc[v.id]
        if (value.regOrNull()) |reg| {
            return @intCast(reg);
        }

        return null;
    }

    /// Get destination register for a value from regalloc, or allocate naively
    fn getDestRegForValue(self: *ARM64CodeGen, value: *const Value) u5 {
        // Use the new Go-style API: value.regOrNull() looks up f.reg_alloc[v.id]
        if (value.regOrNull()) |reg| {
            debug.log(.codegen, "        getDestReg v{d}: from regalloc -> x{d}", .{ value.id, reg });
            return @intCast(reg);
        }

        // Fallback: naive allocation (shouldn't happen if regalloc is working)
        const reg = self.allocateReg();
        debug.log(.codegen, "        getDestReg v{d}: FALLBACK to naive -> x{d}", .{ value.id, reg });
        return reg;
    }

    /// Ensure value is in x0
    /// Setup call arguments using parallel copy to avoid clobbering
    /// Uses x16 as scratch register for breaking cycles
    fn setupCallArgs(self: *ARM64CodeGen, args: []*Value) !void {
        if (args.len == 0) return;

        const max_args = @min(args.len, 8);

        // Collect moves: (src_reg or null, dest_reg, value)
        const Move = struct {
            src: ?u5, // null if value needs regeneration (const, etc.)
            dest: u5,
            value: *Value,
            done: bool,
        };

        var moves: [8]Move = undefined;
        var num_moves: usize = 0;

        for (args[0..max_args], 0..) |arg, i| {
            const dest: u5 = @intCast(i);
            const src = self.getRegForValue(arg);
            moves[num_moves] = .{
                .src = src,
                .dest = dest,
                .value = arg,
                .done = (src != null and src.? == dest), // Already in correct register
            };
            num_moves += 1;
        }

        // Process moves that don't conflict first (src not in any dest)
        // Then handle cycles using x16 as temp
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
                        try self.emit(asm_mod.encodeADDImm(moves[mi].dest, src, 0, 0));
                        debug.log(.codegen, "      arg move: x{d} -> x{d}", .{ src, moves[mi].dest });
                    } else {
                        // Regenerate value (const, etc.)
                        try self.regenerateValue(moves[mi].dest, moves[mi].value);
                    }
                    moves[mi].done = true;
                    progress = true;
                }
            }
        }

        // Handle any remaining cycles using x16 as temp
        // A cycle exists if we have moves like: x0->x1, x1->x0
        for (0..num_moves) |mi| {
            if (moves[mi].done) continue;

            // This move is part of a cycle - break it using x16
            if (moves[mi].src) |src| {
                // Save our source to x16
                try self.emit(asm_mod.encodeADDImm(16, src, 0, 0));
                debug.log(.codegen, "      cycle: save x{d} -> x16", .{src});

                // Find the move that was blocking us (has dest == our src)
                for (0..num_moves) |oi| {
                    if (moves[oi].done) continue;
                    if (moves[oi].dest == src) {
                        // Do that move first
                        if (moves[oi].src) |os| {
                            try self.emit(asm_mod.encodeADDImm(moves[oi].dest, os, 0, 0));
                            debug.log(.codegen, "      cycle: x{d} -> x{d}", .{ os, moves[oi].dest });
                        } else {
                            try self.regenerateValue(moves[oi].dest, moves[oi].value);
                        }
                        moves[oi].done = true;
                        break;
                    }
                }

                // Now do our move from x16
                try self.emit(asm_mod.encodeADDImm(moves[mi].dest, 16, 0, 0));
                debug.log(.codegen, "      cycle: x16 -> x{d}", .{moves[mi].dest});
                moves[mi].done = true;
            } else {
                // No source register - just regenerate
                try self.regenerateValue(moves[mi].dest, moves[mi].value);
                moves[mi].done = true;
            }
        }
    }

    /// Regenerate a value into a register (for consts, etc.)
    fn regenerateValue(self: *ARM64CodeGen, dest: u5, value: *Value) !void {
        switch (value.op) {
            .const_int, .const_64 => try self.emitLoadImmediate(dest, value.aux_int),
            .const_bool => {
                const imm: i64 = if (value.aux_int != 0) 1 else 0;
                try self.emitLoadImmediate(dest, imm);
            },
            .const_nil => try self.emitLoadImmediate(dest, 0),
            else => {
                // Fallback: emit 0
                debug.log(.codegen, "      WARNING: regenerating unknown op {s} as 0", .{@tagName(value.op)});
                try self.emit(asm_mod.encodeMOVZ(dest, 0, 0));
            },
        }
    }

    fn moveToX0(self: *ARM64CodeGen, value: *const Value) !void {
        debug.log(.codegen, "    moveToX0: v{d} (op={s})", .{ value.id, @tagName(value.op) });
        try self.moveToReg(0, value);
    }

    /// Move value to specified register
    fn moveToReg(self: *ARM64CodeGen, dest: u5, value: *const Value) !void {
        // Check if value is already in a register (check regalloc first, then simple tracking)
        if (self.getRegForValue(value)) |src_reg| {
            debug.log(.codegen, "      v{d} in x{d}, moving to x{d}", .{ value.id, src_reg, dest });
            if (src_reg == dest) return;
            // mov dest, src (via ADD with #0)
            try self.emit(asm_mod.encodeADDImm(dest, src_reg, 0, 0));
            return;
        }
        debug.log(.codegen, "      v{d} not in reg, regenerating to x{d}", .{ value.id, dest });

        // Value not in register - regenerate it
        switch (value.op) {
            .const_int, .const_64 => try self.emitLoadImmediate(dest, value.aux_int),
            .const_bool => {
                const imm: i64 = if (value.aux_int != 0) 1 else 0;
                try self.emitLoadImmediate(dest, imm);
            },
            .const_nil => try self.emitLoadImmediate(dest, 0),
            .phi => {
                // Phi value should already be in a register from phi moves
                // If we get here, something went wrong - but don't emit 0, emit first arg
                if (value.args.len > 0) {
                    try self.moveToReg(dest, value.args[0]);
                } else {
                    try self.emit(asm_mod.encodeMOVZ(dest, 0, 0));
                }
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

        // Process string references: add strings to data section and create relocations
        for (self.string_refs.items) |str_ref| {
            // Add string to data section and get its symbol name
            const sym_name = try writer.addStringLiteral(str_ref.string_data);

            // Add ADRP relocation (PAGE21)
            try writer.addDataRelocation(str_ref.adrp_offset, sym_name, macho.ARM64_RELOC_PAGE21);

            // Add ADD relocation (PAGEOFF12)
            try writer.addDataRelocation(str_ref.add_offset, sym_name, macho.ARM64_RELOC_PAGEOFF12);
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

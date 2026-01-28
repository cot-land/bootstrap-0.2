//! Register Allocator - Go's Architecture
//!
//! Go reference: cmd/compile/internal/ssa/regalloc.go
//!
//! ## Architecture (from Go)
//!
//! Phase 1: INITIALIZATION
//!   - Compute liveness (use distances at block boundaries)
//!   - Establish block visit order
//!
//! Phase 2: LINEAR ALLOCATION (per block)
//!   - For single-pred blocks: restore predecessor's endRegs
//!   - For merge blocks: pick best predecessor, use its endRegs
//!   - Process phis with 3-pass algorithm
//!   - Process values: greedy allocation with farthest-next-use spilling
//!   - Save endRegs[b.ID] after each block
//!
//! Phase 3: SHUFFLE (merge edge fixup)
//!   - For each merge edge: generate moves to fix register mismatches
//!   - Uses parallel copy algorithm with cycle breaking
//!
//! ## Key Invariants
//!
//! 1. values[v.ID].regs is PERSISTENT across all blocks
//! 2. endRegs[b.ID] captures register state at end of each block
//! 3. Codegen uses values[v.ID].regs to find register assignments

const std = @import("std");
const types = @import("../core/types.zig");
const liveness = @import("liveness.zig");
const Value = @import("value.zig").Value;
const Block = @import("block.zig").Block;
const Func = @import("func.zig").Func;
const Op = @import("op.zig").Op;
const debug = @import("../pipeline_debug.zig");
const Target = @import("../core/target.zig").Target;

const ID = types.ID;
const Pos = types.Pos;
const RegMask = types.RegMask;
const RegNum = types.RegNum;

// =========================================
// ARM64 Register Definitions
// =========================================

pub const ARM64Regs = struct {
    pub const x0: RegNum = 0;
    pub const x1: RegNum = 1;
    pub const x2: RegNum = 2;
    pub const x3: RegNum = 3;
    pub const x4: RegNum = 4;
    pub const x5: RegNum = 5;
    pub const x6: RegNum = 6;
    pub const x7: RegNum = 7;

    /// Registers available for allocation (x0-x15, x19-x28)
    pub const allocatable: RegMask = blk: {
        var mask: RegMask = 0;
        for (0..16) |i| {
            mask |= @as(RegMask, 1) << i;
        }
        for (19..29) |i| {
            mask |= @as(RegMask, 1) << i;
        }
        break :blk mask;
    };

    /// Caller-saved registers (clobbered by calls)
    pub const caller_saved: RegMask = blk: {
        var mask: RegMask = 0;
        for (0..18) |i| {
            mask |= @as(RegMask, 1) << i;
        }
        break :blk mask;
    };

    /// Callee-saved registers
    pub const callee_saved: RegMask = blk: {
        var mask: RegMask = 0;
        for (19..29) |i| {
            mask |= @as(RegMask, 1) << i;
        }
        break :blk mask;
    };

    pub const arg_regs = [_]RegNum{ 0, 1, 2, 3, 4, 5, 6, 7 };
};

/// AMD64 register constraints (System V ABI)
/// Register mapping: 0=RAX, 1=RCX, 2=RDX, 3=RBX, 4=RSP, 5=RBP, 6=RSI, 7=RDI, 8-15=R8-R15
pub const AMD64Regs = struct {
    pub const rax: RegNum = 0;
    pub const rcx: RegNum = 1;
    pub const rdx: RegNum = 2;
    pub const rbx: RegNum = 3;
    pub const rsp: RegNum = 4; // Stack pointer - NEVER allocate
    pub const rbp: RegNum = 5; // Frame pointer - NEVER allocate
    pub const rsi: RegNum = 6;
    pub const rdi: RegNum = 7;
    pub const r8: RegNum = 8;
    pub const r9: RegNum = 9;
    pub const r10: RegNum = 10;
    pub const r11: RegNum = 11;
    pub const r12: RegNum = 12;
    pub const r13: RegNum = 13;
    pub const r14: RegNum = 14;
    pub const r15: RegNum = 15;

    /// Registers available for allocation (caller-saved only)
    /// We only use caller-saved registers to avoid having to save/restore callee-saved regs.
    /// Excludes: RSP(4), RBP(5), RBX(3), R12-R15(12-15)
    /// Available: RAX(0), RCX(1), RDX(2), RSI(6), RDI(7), R8-R11(8-11)
    pub const allocatable: RegMask = blk: {
        var mask: RegMask = 0;
        // 0-2: RAX, RCX, RDX (skip RBX=3 which is callee-saved)
        for (0..3) |i| {
            mask |= @as(RegMask, 1) << i;
        }
        // Skip 3 (RBX - callee-saved), 4 (RSP), 5 (RBP)
        // 6-11: RSI, RDI, R8-R11 (all caller-saved)
        for (6..12) |i| {
            mask |= @as(RegMask, 1) << i;
        }
        // Skip 12-15 (R12-R15 - callee-saved)
        break :blk mask;
    };

    /// Caller-saved registers (clobbered by calls): RAX, RCX, RDX, RSI, RDI, R8-R11
    pub const caller_saved: RegMask = blk: {
        var mask: RegMask = 0;
        mask |= @as(RegMask, 1) << 0; // RAX
        mask |= @as(RegMask, 1) << 1; // RCX
        mask |= @as(RegMask, 1) << 2; // RDX
        mask |= @as(RegMask, 1) << 6; // RSI
        mask |= @as(RegMask, 1) << 7; // RDI
        mask |= @as(RegMask, 1) << 8; // R8
        mask |= @as(RegMask, 1) << 9; // R9
        mask |= @as(RegMask, 1) << 10; // R10
        mask |= @as(RegMask, 1) << 11; // R11
        break :blk mask;
    };

    /// Callee-saved registers: RBX, R12-R15
    pub const callee_saved: RegMask = blk: {
        var mask: RegMask = 0;
        mask |= @as(RegMask, 1) << 3; // RBX
        mask |= @as(RegMask, 1) << 12; // R12
        mask |= @as(RegMask, 1) << 13; // R13
        mask |= @as(RegMask, 1) << 14; // R14
        mask |= @as(RegMask, 1) << 15; // R15
        break :blk mask;
    };

    /// Argument registers (System V ABI): RDI, RSI, RDX, RCX, R8, R9
    pub const arg_regs = [_]RegNum{ 7, 6, 2, 1, 8, 9 };
};

// =========================================
// Edge State Tracking (Go's endRegs/startRegs)
// =========================================

/// Register state at end of a block
/// Go reference: regalloc.go line 257
pub const EndReg = struct {
    reg: RegNum,
    v: *Value, // Pre-regalloc value
    c: *Value, // Post-regalloc copy (may equal v)
};

/// Use record for tracking distance to next use of a value.
/// Go reference: regalloc.go lines 219-227
/// Uses are stored in a linked list, sorted by distance (closest first).
pub const Use = struct {
    /// Distance from start of block to this use.
    /// dist == 0: used by first instruction in block
    /// dist == len(b.Values)-1: used by last instruction in block
    /// dist == len(b.Values): used by block's control value
    /// dist > len(b.Values): used by a subsequent block
    dist: i32,
    pos: Pos,
    next: ?*Use, // Linked list of uses in nondecreasing dist order
};

/// Per-value state - PERSISTENT across all blocks
/// Go reference: regalloc.go lines 231-239
pub const ValState = struct {
    regs: RegMask = 0, // Which registers hold this value (PERSISTENT)
    spill: ?*Value = null, // StoreReg instruction
    spill_used: bool = false,
    uses: ?*Use = null, // Linked list of uses in this block (Go pattern)
    rematerializeable: bool = false, // Can be recomputed cheaply (Go's pattern)
    needs_reg: bool = true, // Value needs a register (not void/memory)

    pub fn inReg(self: *const ValState) bool {
        return self.regs != 0;
    }

    pub fn firstReg(self: *const ValState) ?RegNum {
        return types.regMaskFirst(self.regs);
    }
};

/// Per-register state during allocation
pub const RegState = struct {
    v: ?*Value = null, // Value currently in this register
    dirty: bool = false, // Modified since last spill?

    pub fn isFree(self: *const RegState) bool {
        return self.v == null;
    }

    pub fn clear(self: *RegState) void {
        self.v = null;
        self.dirty = false;
    }
};

// =========================================
// Register Allocator State
// =========================================

pub const NUM_REGS: usize = 32;

pub const RegAllocState = struct {
    allocator: std.mem.Allocator,
    f: *Func,
    live: liveness.LivenessResult,

    // Per-value state (PERSISTENT - survives across blocks)
    values: []ValState,

    // Per-register state (reset per block)
    regs: [NUM_REGS]RegState = [_]RegState{.{}} ** NUM_REGS,

    // Edge state tracking (Go's key insight)
    end_regs: std.AutoHashMapUnmanaged(ID, []EndReg),

    // Spills that occurred during allocation and need to be inserted
    // These accumulate when allocReg spills to free a register for a load
    pending_spills: std.ArrayListUnmanaged(*Value) = .{},

    // Registers currently in use for the current instruction's arguments
    // These must NOT be spilled while loading remaining arguments
    // Go reference: regalloc.go 's.used' field
    used: RegMask = 0,

    // spillLive[block_id] = list of spill value IDs live at end of that block
    // Go reference: regalloc.go line 315 "spillLive [][]ID"
    // This tracks which store_reg values are live at each block end,
    // needed by stackalloc to compute proper interference.
    spill_live: std.AutoHashMapUnmanaged(ID, std.ArrayListUnmanaged(ID)) = .{},

    // Free list of Use records for reuse (Go pattern)
    // Go reference: regalloc.go line 314 "freeUseRecords *use"
    free_use_records: ?*Use = null,

    // Current instruction index within the block being processed
    // Go reference: regalloc.go "curIdx"
    cur_idx: usize = 0,

    // Distance to next call instruction for each value index in current block
    // Go reference: regalloc.go line 316 "nextCall []int32"
    next_call: std.ArrayListUnmanaged(i32) = .{},

    // Stats
    num_spills: u32 = 0,

    // Target-specific register constraints
    allocatable_mask: RegMask,
    caller_saved_mask: RegMask,
    num_arg_regs: u8,
    arg_regs: []const RegNum,
    target: Target,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, f: *Func, live: liveness.LivenessResult, target: Target) !Self {
        // Allocate per-value state for all values in the function
        // vid.next_id is the next ID to be allocated, so values 1..next_id-1 exist
        const max_id = f.vid.next_id;
        const values = try allocator.alloc(ValState, max_id);
        for (values) |*v| {
            v.* = .{};
        }

        // Select register constraints based on target architecture
        const allocatable = if (target.arch == .amd64) AMD64Regs.allocatable else ARM64Regs.allocatable;
        const caller_saved = if (target.arch == .amd64) AMD64Regs.caller_saved else ARM64Regs.caller_saved;
        const arg_regs: []const RegNum = if (target.arch == .amd64) &AMD64Regs.arg_regs else &ARM64Regs.arg_regs;
        const num_args: u8 = @intCast(arg_regs.len);

        return Self{
            .allocator = allocator,
            .f = f,
            .live = live,
            .values = values,
            .end_regs = .{},
            .allocatable_mask = allocatable,
            .caller_saved_mask = caller_saved,
            .num_arg_regs = num_args,
            .arg_regs = arg_regs,
            .target = target,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free endRegs arrays
        var it = self.end_regs.valueIterator();
        while (it.next()) |regs| {
            self.allocator.free(regs.*);
        }
        self.end_regs.deinit(self.allocator);
        self.pending_spills.deinit(self.allocator);
        self.allocator.free(self.values);
        self.live.deinit();

        // Free spillLive lists
        var spill_it = self.spill_live.valueIterator();
        while (spill_it.next()) |list| {
            list.deinit(self.allocator);
        }
        self.spill_live.deinit(self.allocator);

        // Free next_call array
        self.next_call.deinit(self.allocator);

        // Free Use records from free list
        var use_ptr = self.free_use_records;
        while (use_ptr) |u| {
            const next = u.next;
            self.allocator.destroy(u);
            use_ptr = next;
        }
    }

    /// Get spillLive for stackalloc
    /// Returns a reference to the spillLive map (caller should not modify)
    pub fn getSpillLive(self: *const Self) *const std.AutoHashMapUnmanaged(ID, std.ArrayListUnmanaged(ID)) {
        return &self.spill_live;
    }

    // =========================================
    // Use Distance Tracking (Go pattern)
    // Go reference: regalloc.go lines 854-920
    // =========================================

    /// Add a use record for a value at the given distance from block start.
    /// All calls to addUse must happen with nonincreasing dist (walking backwards).
    /// Go reference: regalloc.go addUse() line 856
    fn addUse(self: *Self, id: ID, dist: i32, pos: Pos) void {
        if (id >= self.values.len) return;

        // Get a Use record from free list or allocate new
        var r: *Use = undefined;
        if (self.free_use_records) |free| {
            r = free;
            self.free_use_records = free.next;
        } else {
            r = self.allocator.create(Use) catch return;
        }

        r.dist = dist;
        r.pos = pos;
        r.next = self.values[id].uses;
        self.values[id].uses = r;

        // Verify ordering (dist should be nonincreasing)
        if (r.next) |next| {
            if (dist > next.dist) {
                debug.log(.regalloc, "WARNING: uses added in wrong order for v{d}: {d} > {d}", .{ id, dist, next.dist });
            }
        }
    }

    /// Advance uses of v's args after processing v.
    /// Pops the current use off each arg's use list.
    /// Frees registers for args that have no more uses (or next use is after a call).
    /// Go reference: regalloc.go advanceUses() line 872
    fn advanceUses(self: *Self, v: *Value) void {
        for (v.args) |arg| {
            if (arg.id >= self.values.len) continue;
            const vi = &self.values[arg.id];
            if (!vi.needs_reg) continue;

            const r = vi.uses orelse continue;
            vi.uses = r.next;

            // Check if value is dead or next use is after a call
            const next_call_dist = if (self.cur_idx < self.next_call.items.len)
                self.next_call.items[self.cur_idx]
            else
                std.math.maxInt(i32);

            if (r.next == null or r.next.?.dist > next_call_dist) {
                // Value is dead or not used until after a call - free its registers
                self.freeRegs(vi.regs);
            }

            // Return Use record to free list
            r.next = self.free_use_records;
            self.free_use_records = r;
        }
    }

    /// Clear all use lists for values (called at start of each block).
    fn clearUses(self: *Self) void {
        for (self.values) |*vi| {
            // Return all Use records to free list
            var u = vi.uses;
            while (u) |use| {
                const next = use.next;
                use.next = self.free_use_records;
                self.free_use_records = use;
                u = next;
            }
            vi.uses = null;
        }
    }

    /// Build use lists for a block by walking backwards through values.
    /// Go reference: regalloc.go lines 1033-1082
    fn buildUseLists(self: *Self, block: *Block) !void {
        // Clear existing uses from previous block
        self.clearUses();

        const num_values = block.values.items.len;

        // Resize next_call array if needed
        try self.next_call.resize(self.allocator, num_values);

        // Add pseudo-uses for values live out of this block
        const live_out = self.live.getLiveOut(block.id);
        for (live_out) |info| {
            // dist > len(b.Values) means used by subsequent block
            self.addUse(info.id, @intCast(num_values + @as(usize, @intCast(info.dist))), info.pos);
        }

        // Add pseudo-use for control values (e.g., condition of branch)
        for (block.controlValues()) |ctrl| {
            if (ctrl.id < self.values.len and self.values[ctrl.id].needs_reg) {
                self.addUse(ctrl.id, @intCast(num_values), block.pos);
            }
        }

        // Walk backwards through values, adding uses for args
        var next_call_dist: i32 = std.math.maxInt(i32);
        var i: usize = num_values;
        while (i > 0) {
            i -= 1;
            const v = block.values.items[i];

            // Track distance to next call
            if (v.op.info().call) {
                next_call_dist = @intCast(i);
            }
            self.next_call.items[i] = next_call_dist;

            // Add uses for this value's arguments
            for (v.args) |arg| {
                if (arg.id >= self.values.len) continue;
                if (!self.values[arg.id].needs_reg) continue;
                self.addUse(arg.id, @intCast(i), v.pos);
            }
        }

        debug.log(.regalloc, "  Built use lists for block b{d}, {d} values", .{ block.id, num_values });
    }

    // =========================================
    // Register Operations
    // =========================================

    fn findFreeReg(self: *const Self, mask: RegMask) ?RegNum {
        var m = mask;
        while (m != 0) {
            const reg = @ctz(m);
            if (reg < NUM_REGS and self.regs[reg].isFree()) {
                return @intCast(reg);
            }
            m &= m - 1;
        }
        return null;
    }

    fn allocReg(self: *Self, mask: RegMask, block: *Block) !RegNum {

        // Try to find a free register (excluding 'used' registers)
        // Go reference: regalloc.go allocReg excludes s.used
        const available_mask = mask & ~self.used;
        if (self.findFreeReg(available_mask)) |reg| {
            return reg;
        }

        // Must spill - find register with farthest next use
        // CRITICAL: Exclude 'used' registers from spill candidates
        // These are holding arguments for the current instruction
        // Go reference: regalloc.go allocReg() lines 458-489
        var best_reg: ?RegNum = null;
        var best_dist: i32 = -1;

        var m = available_mask; // Exclude 'used' registers from spill candidates
        while (m != 0) {
            const reg: RegNum = @intCast(@ctz(m));
            m &= m - 1;

            if (reg >= NUM_REGS) continue;
            const v = self.regs[reg].v orelse continue;

            // Get distance to next use from per-value use list (Go pattern)
            // This is the key fix: uses.dist tracks INTRA-BLOCK uses correctly
            const vi = &self.values[v.id];
            const dist: i32 = if (vi.uses) |use| use.dist else std.math.maxInt(i32);

            if (dist > best_dist) {
                best_dist = dist;
                best_reg = reg;
            }
        }

        const reg = best_reg orelse return error.NoRegisterAvailable;
        debug.log(.regalloc, "    spilling v{d} from x{d} (dist={d})", .{
            if (self.regs[reg].v) |v| v.id else 0,
            reg,
            best_dist,
        });

        // Spill the value in this register
        // Add to pending_spills so caller can insert it at the right position
        if (try self.spillReg(reg, block)) |spill| {
            try self.pending_spills.append(self.allocator, spill);
        }

        return reg;
    }

    /// Spill a value from a register to a stack slot.
    /// Does NOT add to block.values - caller must do that at the right position.
    /// Returns the store_reg value if one was created, null otherwise.
    /// Go reference: regalloc.go spillReg() line 1420
    /// @param for_call: true if evicting for a function call (caller-saved).
    ///                  When true, don't clear home assignment because the value
    ///                  has already been used to set up call arguments.
    fn spillReg(self: *Self, reg: RegNum, block: *Block) !?*Value {
        const v = self.regs[reg].v orelse return null;
        const vi = &self.values[v.id];

        var result: ?*Value = null;

        // Rematerializeable values don't need spills - they can be recomputed
        // Go reference: regalloc.go line 1650
        if (vi.rematerializeable) {
            debug.log(.regalloc, "    evict v{d} from x{d} (rematerializeable, no spill)", .{ v.id, reg });
            // Always clear home for rematerializeable values when evicted.
            // The register is being reallocated, so the home is stale.
            // When the value is needed again, it will be rematerialized to a new register.
            self.f.clearHome(v.id);
        } else if (vi.spill == null) {
            // Create StoreReg if not already spilled
            const spill = try self.f.newValue(.store_reg, v.type_idx, block, v.pos);
            spill.addArg(v);
            // NOTE: NOT adding to block.values here - caller must insert at correct position
            vi.spill = spill;
            self.num_spills += 1;
            debug.log(.regalloc, "    spill v{d} from x{d}", .{ v.id, reg });
            result = spill;
        }
        vi.spill_used = true;

        // Clear register
        self.regs[reg].clear();
        vi.regs = types.regMaskClear(vi.regs, reg);
        return result;
    }

    fn assignReg(self: *Self, v: *Value, reg: RegNum) !void {
        // Update register state (internal working state)
        self.regs[reg] = .{ .v = v, .dirty = true };
        // Update value state (internal tracking)
        self.values[v.id].regs = types.regMaskSet(self.values[v.id].regs, reg);
        // Record in f.reg_alloc for codegen (Go's setHome pattern)
        try self.f.setHome(v, .{ .register = @intCast(reg) });
        // Go reference: regalloc.go line 430 "s.used |= regMask(1) << r"
        // Mark this register as used
        self.used |= @as(RegMask, 1) << @intCast(reg);
        debug.log(.regalloc, "    assign v{d} -> x{d}", .{ v.id, reg });
    }

    fn freeReg(self: *Self, reg: RegNum) void {
        if (self.regs[reg].v) |v| {
            // Clear this register from value's mask
            self.values[v.id].regs = types.regMaskClear(self.values[v.id].regs, reg);
        }
        self.regs[reg].clear();
        // Go reference: regalloc.go line 373 "s.used &^= regMask(1) << r"
        // Clear this register from 'used' mask
        self.used &= ~(@as(RegMask, 1) << @intCast(reg));
    }

    /// Free all registers in a mask.
    /// Go reference: regalloc.go freeRegs()
    fn freeRegs(self: *Self, mask: RegMask) void {
        var m = mask;
        while (m != 0) {
            const reg: RegNum = @intCast(@ctz(m));
            m &= m - 1;
            if (reg < NUM_REGS) {
                self.freeReg(reg);
            }
        }
    }

    /// Load a spilled value back into a register, or rematerialize it.
    /// Does NOT add to block.values - caller must do that at the right position.
    /// Go reference: regalloc.go loadReg() line 1700
    fn loadValue(self: *Self, v: *Value, block: *Block) !*Value {
        const vi = &self.values[v.id];
        const reg = try self.allocReg(self.allocatable_mask, block);

        // Rematerializeable values: copy the original instead of loading from spill
        // Go reference: regalloc.go line 1750 (copyInto for rematerializeable)
        if (vi.rematerializeable) {
            // Create a copy of the original value
            const copy = try self.f.newValue(v.op, v.type_idx, block, v.pos);
            copy.aux_int = v.aux_int; // Copy constant value
            try self.ensureValState(copy);
            // The copy is also rematerializeable (it's a copy of a rematerializeable value)
            self.values[copy.id].rematerializeable = true;
            try self.assignReg(copy, reg);
            debug.log(.regalloc, "    rematerialize v{d} -> x{d} (v{d})", .{ v.id, reg, copy.id });
            return copy;
        }

        if (vi.spill) |spill| {
            // Create LoadReg - but don't add to block yet
            const load = try self.f.newValue(.load_reg, v.type_idx, block, v.pos);
            load.addArg(spill);
            // NOTE: NOT adding to block.values here - caller must insert at correct position

            try self.ensureValState(load);
            try self.assignReg(load, reg);
            debug.log(.regalloc, "    load v{d} from spill -> x{d} (v{d})", .{ v.id, reg, load.id });
            return load;
        } else {
            // No spill - assign register to original value
            try self.assignReg(v, reg);
            return v;
        }
    }

    // =========================================
    // Block State Management (Go's key insight)
    // =========================================

    fn saveEndRegs(self: *Self, block: *Block) !void {
        // Count values in registers
        var count: usize = 0;
        for (&self.regs) |*r| {
            if (r.v != null) count += 1;
        }

        // Save state
        const end_regs = try self.allocator.alloc(EndReg, count);
        var i: usize = 0;
        for (&self.regs, 0..) |*r, reg| {
            if (r.v) |v| {
                end_regs[i] = .{
                    .reg = @intCast(reg),
                    .v = v,
                    .c = v, // For now, c == v (no copies)
                };
                i += 1;
            }
        }

        try self.end_regs.put(self.allocator, block.id, end_regs);
        debug.log(.regalloc, "  saved endRegs[b{d}]: {d} values", .{ block.id, count });
    }

    fn restoreEndRegs(self: *Self, pred_id: ID) void {
        // Clear current register state
        for (&self.regs) |*r| {
            r.clear();
        }

        // Restore from predecessor's end state
        if (self.end_regs.get(pred_id)) |regs| {
            for (regs) |er| {
                self.regs[er.reg] = .{ .v = er.v, .dirty = false };
                // Note: we don't update values[*].regs here because it's persistent
            }
            debug.log(.regalloc, "  restored from endRegs[b{d}]: {d} values", .{ pred_id, regs.len });
        }
    }

    // =========================================
    // Phi Handling (Go's 3-pass algorithm)
    // =========================================

    fn allocatePhis(self: *Self, block: *Block, primary_pred_idx: usize) !void {
        // Collect phis
        var phis = std.ArrayListUnmanaged(*Value){};
        defer phis.deinit(self.allocator);

        for (block.values.items) |v| {
            if (v.op == .phi) {
                try phis.append(self.allocator, v);
            } else {
                break; // Phis are always first
            }
        }

        if (phis.items.len == 0) return;

        debug.log(.regalloc, "  allocating {d} phis", .{phis.items.len});

        // Track which registers are used by phis
        var phi_used: RegMask = 0;

        // Allocate array for phi register assignments
        const phi_regs = try self.allocator.alloc(?RegNum, phis.items.len);
        defer self.allocator.free(phi_regs);
        for (phi_regs) |*r| {
            r.* = null;
        }

        // Pass 1: Try to reuse primary predecessor's register
        for (phis.items, 0..) |phi, i| {
            if (primary_pred_idx < phi.args.len) {
                const arg = phi.args[primary_pred_idx];
                const arg_regs = self.values[arg.id].regs & ~phi_used & self.allocatable_mask;
                if (arg_regs != 0) {
                    const reg = types.regMaskFirst(arg_regs).?;
                    phi_regs[i] = reg;
                    phi_used |= @as(RegMask, 1) << reg;
                    debug.log(.regalloc, "    phi v{d}: reuse x{d} from arg v{d}", .{ phi.id, reg, arg.id });
                }
            }
        }

        // Pass 2: Allocate fresh registers for remaining phis
        for (phis.items, 0..) |phi, i| {
            if (phi_regs[i] != null) continue;

            const available = self.allocatable_mask & ~phi_used;
            if (self.findFreeReg(available)) |reg| {
                phi_regs[i] = reg;
                phi_used |= @as(RegMask, 1) << reg;
                debug.log(.regalloc, "    phi v{d}: fresh x{d}", .{ phi.id, reg });
            } else {
                // No register available - will need to spill
                debug.log(.regalloc, "    phi v{d}: no register available", .{phi.id});
            }
        }

        // Pass 3: Actually assign registers to phis
        for (phis.items, 0..) |phi, i| {
            if (phi_regs[i]) |reg| {
                // Free the register first if occupied
                if (self.regs[reg].v != null) {
                    self.freeReg(reg);
                }
                try self.assignReg(phi, reg);
            }
        }
    }

    // =========================================
    // Block Processing
    // =========================================

    fn allocBlock(self: *Self, block: *Block) !void {
        debug.log(.regalloc, "Processing block b{d}, {d} values", .{ block.id, block.values.items.len });

        // Initialize register state from predecessor
        if (block.preds.len == 0) {
            // Entry block - start fresh
            for (&self.regs) |*r| {
                r.clear();
            }
        } else if (block.preds.len == 1) {
            // Single predecessor - restore its end state
            self.restoreEndRegs(block.preds[0].b.id);
        } else {
            // Merge block - pick best predecessor
            // For now, use first visited predecessor
            var best_pred: ?ID = null;
            for (block.preds) |pred| {
                if (self.end_regs.contains(pred.b.id)) {
                    best_pred = pred.b.id;
                    break;
                }
            }
            if (best_pred) |pid| {
                self.restoreEndRegs(pid);
            }
        }

        // Find primary predecessor index for phi handling
        var primary_pred_idx: usize = 0;
        for (block.preds, 0..) |pred, i| {
            if (self.end_regs.contains(pred.b.id)) {
                primary_pred_idx = i;
                break;
            }
        }

        // Handle phis first (Go's 3-pass algorithm)
        try self.allocatePhis(block, primary_pred_idx);

        // Build use lists for this block (Go's key pattern for intra-block liveness)
        // Go reference: regalloc.go lines 1033-1082
        try self.buildUseLists(block);

        // Build a NEW values list with loads/spills in the correct positions
        // Go reference: regalloc.go builds output in order as it processes
        var new_values = std.ArrayListUnmanaged(*Value){};
        defer new_values.deinit(self.allocator);

        // Copy original values to iterate (we'll rebuild the list)
        const original_values = try self.allocator.dupe(*Value, block.values.items);
        defer self.allocator.free(original_values);

        for (original_values, 0..) |v, idx| {
            // Track current instruction index for advanceUses
            self.cur_idx = idx;

            if (v.op == .phi) {
                // Phis go first, unchanged
                try new_values.append(self.allocator, v);
                continue;
            }

            debug.log(.regalloc, "  v{d} = {s}", .{ v.id, @tagName(v.op) });

            // Clear 'used' mask at start of each instruction
            // Go reference: regalloc.go clears s.used per-instruction
            self.used = 0;

            // Ensure arguments are in registers - insert loads BEFORE this value
            // Mark each arg's register as 'used' to prevent spilling it for other args
            // For calls: only first N args need registers (6 for AMD64, 8 for ARM64)
            // Stack args will be handled by codegen directly from their spill slots
            const max_reg_args: usize = if (v.op.info().call)
                self.arg_regs.len
            else
                v.args.len;
            const args_to_load = @min(v.args.len, max_reg_args);

            for (v.args[0..args_to_load], 0..) |arg, i| {
                if (!self.values[arg.id].inReg()) {
                    const loaded = try self.loadValue(arg, block);
                    if (loaded != arg) {
                        // Insert any pending spills (from allocReg freeing registers) FIRST
                        for (self.pending_spills.items) |spill| {
                            try new_values.append(self.allocator, spill);
                        }
                        self.pending_spills.clearRetainingCapacity();

                        // Then insert load BEFORE the value that needs it
                        try new_values.append(self.allocator, loaded);
                        // Update the arg to point to the reload value
                        v.args[i] = loaded;
                        // BUG-071 FIX: Increment uses count for rematerialized value
                        // This marks it as non-dead so codegen won't skip it
                        loaded.uses += 1;
                        debug.log(.regalloc, "    updated arg {d} to v{d}", .{ i, loaded.id });
                    }
                }
                // Mark this arg's register as 'used' so we don't spill it for later args
                // Go reference: regalloc.go line 1913 "used |= regMask(1) << r"
                if (self.values[v.args[i].id].firstReg()) |reg| {
                    self.used |= @as(RegMask, 1) << @intCast(reg);
                }
            }

            // NOTE: Do NOT clear 'used' here!
            // Go's pattern: 'used' remains set during output allocation so allocReg
            // won't evict operand registers. Individual bits are cleared by freeReg()
            // when arg use counts reach 0.

            // Handle calls - spill caller-saved registers BEFORE the call
            // Use caller_saved_mask to handle both ARM64 and AMD64 correctly
            // ARM64: x0-x17 (bits 0-17)
            // AMD64: RAX, RCX, RDX, RSI, RDI, R8-R11 (bits 0,1,2,6,7,8,9,10,11)
            if (v.op.info().call) {
                debug.log(.regalloc, "    CALL - spilling caller-saved (mask=0x{x})", .{self.caller_saved_mask});
                var reg: RegNum = 0;
                while (reg < NUM_REGS) : (reg += 1) {
                    const reg_bit = @as(RegMask, 1) << reg;
                    if ((self.caller_saved_mask & reg_bit) != 0 and self.regs[reg].v != null) {
                        // for_call=true: don't clear home assignment for call eviction
                        // because values have already been used to set up call args
                        if (try self.spillReg(reg, block)) |spill| {
                            // Insert spill BEFORE the call
                            try new_values.append(self.allocator, spill);
                        }
                    }
                }
            }

            // AMD64: Division/mod clobbers RAX (dividend) and RDX (CQO sign-extends RAX into RDX:RAX)
            // Must spill both before div/mod to avoid clobbering live values
            if ((v.op == .div or v.op == .mod) and self.target.arch == .amd64) {
                // First spill RAX if it has a live value (not one of the div operands)
                if (self.regs[AMD64Regs.rax].v != null) {
                    const rax_val = self.regs[AMD64Regs.rax].v.?;
                    // Check if this value is one of the div operands (no need to spill if so)
                    var is_operand = false;
                    for (v.args) |arg| {
                        if (arg == rax_val) {
                            is_operand = true;
                            break;
                        }
                    }
                    if (!is_operand) {
                        debug.log(.regalloc, "    DIV/MOD - spilling RAX (clobbered by dividend)", .{});
                        if (try self.spillReg(AMD64Regs.rax, block)) |spill| {
                            try new_values.append(self.allocator, spill);
                        }
                    }
                }
                // Then spill RDX
                if (self.regs[AMD64Regs.rdx].v != null) {
                    debug.log(.regalloc, "    DIV/MOD - spilling RDX (clobbered by CQO)", .{});
                    if (try self.spillReg(AMD64Regs.rdx, block)) |spill| {
                        try new_values.append(self.allocator, spill);
                    }
                }
            }

            // AMD64: Shift operations (shl, shr, sar) use CL (part of RCX) for variable shifts
            // Must spill RCX before shift to avoid clobbering live values
            // Note: Constant shifts don't need RCX, but we spill conservatively
            if ((v.op == .shl or v.op == .shr or v.op == .sar) and self.target.arch == .amd64) {
                if (self.regs[AMD64Regs.rcx].v != null) {
                    debug.log(.regalloc, "    SHIFT - spilling RCX (used for shift count)", .{});
                    if (try self.spillReg(AMD64Regs.rcx, block)) |spill| {
                        try new_values.append(self.allocator, spill);
                    }
                }
            }

            // Now add the value itself
            try new_values.append(self.allocator, v);

            // Allocate output register
            if (needsOutputReg(v)) {
                if (v.op.info().call) {
                    // Call result in x0
                    if (self.regs[0].v != null) {
                        self.freeReg(0);
                    }
                    try self.assignReg(v, 0);
                } else if (v.op == .arg) {
                    // Function argument - use target-specific arg_regs
                    const arg_idx: usize = @intCast(v.aux_int);
                    if (arg_idx < self.arg_regs.len) {
                        // Register argument - use architecture-specific register mapping
                        const arg_reg: RegNum = self.arg_regs[arg_idx];
                        if (self.regs[arg_reg].v != null) {
                            // Another value is in this register - need to spill it
                            if (try self.spillReg(arg_reg, block)) |spill| {
                                try new_values.append(self.allocator, spill);
                            }
                        }
                        try self.assignReg(v, arg_reg);
                    } else {
                        // Stack argument (beyond register args) - allocate a register and mark for stack load
                        // The codegen will emit a load from the appropriate stack slot
                        const reg = try self.allocReg(self.allocatable_mask, block);
                        try self.assignReg(v, reg);
                    }
                } else {
                    const reg = try self.allocReg(self.allocatable_mask, block);
                    try self.assignReg(v, reg);
                }
            }

            // Insert any pending spills from output allocation
            // These must go BEFORE the value that needs the register
            // Since v is already in new_values, we need to insert before it
            if (self.pending_spills.items.len > 0) {
                // Find where v was inserted (should be last item or close to it)
                // Insert spills just before v
                var insert_pos = new_values.items.len;
                while (insert_pos > 0 and new_values.items[insert_pos - 1] != v) {
                    insert_pos -= 1;
                }
                // Insert spills before v's position
                if (insert_pos > 0 and new_values.items[insert_pos - 1] == v) {
                    insert_pos -= 1;
                    for (self.pending_spills.items) |spill| {
                        try new_values.insert(self.allocator, insert_pos, spill);
                        insert_pos += 1;
                    }
                    self.pending_spills.clearRetainingCapacity();
                }
            }

            // CRITICAL: Advance uses and free dead values (Go's pattern)
            // Go reference: regalloc.go advanceUses() - pops current use off each arg's list
            // and frees registers for args with no more uses (or next use after call)
            self.advanceUses(v);
        }

        // Handle control values - may need loads
        for (block.controlValues()) |ctrl| {
            if (!self.values[ctrl.id].inReg()) {
                const loaded = try self.loadValue(ctrl, block);
                if (loaded != ctrl) {
                    // Insert any pending spills first
                    for (self.pending_spills.items) |spill| {
                        try new_values.append(self.allocator, spill);
                    }
                    self.pending_spills.clearRetainingCapacity();

                    // Insert load at end (before terminator, which is implicit)
                    try new_values.append(self.allocator, loaded);
                    // Update control to point to LoadReg
                    block.setControl(loaded);
                    debug.log(.regalloc, "  updated control to v{d}", .{loaded.id});
                }
            }
        }

        // Replace block's values with the correctly ordered list
        block.values.deinit(self.allocator);
        block.values = .{};
        try block.values.appendSlice(self.allocator, new_values.items);

        // Save end state for this block
        try self.saveEndRegs(block);

        // CRITICAL: Compute spillLive for this block
        // Go reference: regalloc.go lines 2096-2116
        // For each value live at block end, if it has a spill (store_reg),
        // record the spill value in spillLive. This is used by stackalloc
        // to ensure proper interference between spilled values across blocks.
        //
        // IMPORTANT: We add to spillLive if the value HAS a spill, regardless
        // Compute spillLive for this block
        // Go reference: regalloc.go lines 2096-2116
        const live_out = self.live.getLiveOut(block.id);
        for (live_out) |info| {
            const vid = info.id;
            if (vid >= self.values.len) continue;
            const vi = &self.values[vid];

            // Skip rematerializeable values (will recompute during merge)
            if (vi.rematerializeable) continue;

            // If value has been spilled and is live at block end, add spill to spillLive
            if (vi.spill) |spill| {
                var list = self.spill_live.get(block.id) orelse std.ArrayListUnmanaged(ID){};
                try list.append(self.allocator, spill.id);
                try self.spill_live.put(self.allocator, block.id, list);
            }
        }
    }

    // =========================================
    // Shuffle Phase (Merge Edge Fixup)
    // =========================================

    fn shuffle(self: *Self) !void {
        debug.log(.regalloc, "=== Shuffle phase ===", .{});

        for (self.f.blocks.items) |block| {
            if (block.preds.len <= 1) continue; // No merge

            debug.log(.regalloc, "Shuffle for merge block b{d}", .{block.id});

            // For each predecessor, generate moves to fix mismatches
            for (block.preds, 0..) |pred, pred_idx| {
                try self.shuffleEdge(pred.b, block, pred_idx);
            }
        }
    }

    /// Shuffle edge fixup with cycle detection (Go's pattern)
    /// Go reference: regalloc.go lines 2320-2700 (edgeState.process)
    fn shuffleEdge(self: *Self, pred: *Block, succ: *Block, pred_idx: usize) !void {
        // Get predecessor's end state
        const src_regs = self.end_regs.get(pred.id) orelse return;

        // Build content map: what value is in each register at pred's end
        var contents: [NUM_REGS]?*Value = [_]?*Value{null} ** NUM_REGS;
        for (src_regs) |er| {
            contents[er.reg] = er.v;
        }
        debug.log(.regalloc, "  contents from pred b{d}: {d} regs", .{ pred.id, src_regs.len });
        for (src_regs) |er| {
            debug.log(.regalloc, "    x{d} = v{d}", .{ er.reg, er.v.id });
        }

        // Collect destination requirements (what each phi needs)
        const Dest = struct {
            dst_reg: RegNum,
            src_reg: ?RegNum,
            value: *Value,
            satisfied: bool,
        };
        var dests = std.ArrayListUnmanaged(Dest){};
        defer dests.deinit(self.allocator);

        for (succ.values.items) |v| {
            if (v.op != .phi) break;

            // Get phi's destination register
            // If phi was spilled, its regs mask is 0, so try to get the register
            // from the first arg (since phi reuses arg[0]'s register)
            const phi_reg = self.values[v.id].firstReg() orelse blk: {
                // Phi was spilled - get register from first arg in first predecessor
                if (v.args.len > 0 and succ.preds.len > 0) {
                    const first_pred_block = succ.preds[0].b;
                    if (self.end_regs.get(first_pred_block.id)) |first_pred_regs| {
                        const first_arg = v.args[0];
                        for (first_pred_regs) |er| {
                            if (er.v.id == first_arg.id) {
                                break :blk er.reg;
                            }
                        }
                    }
                }
                continue;
            };
            if (pred_idx >= v.args.len) continue;

            const arg = v.args[pred_idx];
            // Find which register (if any) contains arg at end of predecessor
            // This is the source of truth - NOT the value's home or regalloc state,
            // because the register might have been reused after the value was "dead".
            // Go reference: edgeState.setup() uses srcReg (from endRegs) to find sources.
            var arg_reg: ?RegNum = null;
            for (contents, 0..) |maybe_val, reg_idx| {
                if (maybe_val) |val| {
                    if (val.id == arg.id) {
                        arg_reg = @intCast(reg_idx);
                        break;
                    }
                }
            }

            // Only need move if src != dst
            if (arg_reg != phi_reg) {
                try dests.append(self.allocator, .{
                    .dst_reg = phi_reg,
                    .src_reg = arg_reg,
                    .value = arg,
                    .satisfied = false,
                });
                debug.log(.regalloc, "  need move: v{d} x{?d} -> x{d}", .{ arg.id, arg_reg, phi_reg });
            }
        }

        if (dests.items.len == 0) return;

        // Track which registers are used by destinations
        var used_regs: RegMask = 0;
        for (dests.items) |d| {
            used_regs |= @as(RegMask, 1) << d.dst_reg;
        }

        // Process destinations with cycle detection (Go's pattern)
        // Go reference: regalloc.go edgeState.process()
        var progress = true;
        while (progress) {
            progress = false;

            // Try to satisfy each destination
            for (dests.items) |*d| {
                if (d.satisfied) continue;

                // Check if destination register is occupied by another pending source
                var blocked = false;
                for (dests.items) |other| {
                    if (other.satisfied) continue;
                    if (other.src_reg) |src| {
                        if (src == d.dst_reg and other.dst_reg != d.dst_reg) {
                            // d.dst_reg is needed as a source for another move
                            blocked = true;
                            break;
                        }
                    }
                }

                if (!blocked) {
                    // Safe to emit this move
                    if (d.src_reg) |src| {
                        try self.emitCopy(pred, d.value, src, d.dst_reg);
                    } else {
                        // Source has no register - need to rematerialize
                        // This happens for const_bool, const_int, etc. that were never allocated
                        // We emit a copy of the value that will be rematerialized by codegen
                        debug.log(.regalloc, "  about to remat: v{d} ({s}) -> x{d}", .{ d.value.id, @tagName(d.value.op), d.dst_reg });
                        try self.emitRematerialize(pred, d.value, d.dst_reg);
                    }
                    d.satisfied = true;
                    progress = true;
                } else {
                    debug.log(.regalloc, "  BLOCKED: v{d} -> x{d}", .{ d.value.id, d.dst_reg });
                }
            }

            // If no progress, we have a cycle - break it with temp register
            if (!progress) {
                // Find first unsatisfied destination
                for (dests.items) |*d| {
                    if (!d.satisfied) {
                        if (d.src_reg) |src| {
                            // Break cycle: copy src to temp, then temp to dst
                            // Find temp register not used by any destination
                            const temp_reg = self.findTempReg(used_regs) orelse {
                                debug.log(.regalloc, "  ERROR: no temp register for cycle break", .{});
                                return error.NoTempRegister;
                            };

                            debug.log(.regalloc, "  breaking cycle: x{d} -> x{d} -> x{d}", .{ src, temp_reg, d.dst_reg });

                            // Copy src to temp
                            const temp_copy = try self.f.newValue(.copy, d.value.type_idx, pred, d.value.pos);
                            temp_copy.addArg(d.value);
                            try self.ensureValState(temp_copy);
                            self.values[temp_copy.id].regs = types.regMaskSet(0, temp_reg);
                            try self.f.setHome(temp_copy, .{ .register = @intCast(temp_reg) });
                            try pred.values.append(self.allocator, temp_copy);

                            // Update contents: temp now holds the value
                            contents[temp_reg] = d.value;
                            // Update this dest to read from temp
                            d.src_reg = temp_reg;
                        } else {
                            // No source register - this is a constant that needs rematerialization
                            // No cycle here, just emit the rematerialization directly
                            try self.emitRematerialize(pred, d.value, d.dst_reg);
                            d.satisfied = true;
                        }

                        progress = true;
                        break;
                    }
                }
            }
        }

        // Emit any remaining satisfied copies that weren't emitted yet
        for (dests.items) |d| {
            if (!d.satisfied) {
                // Should have been handled by cycle breaking
                debug.log(.regalloc, "  WARNING: unsatisfied dest x{d}", .{d.dst_reg});
            }
        }
    }

    fn emitCopy(self: *Self, block: *Block, value: *Value, src_reg: RegNum, dst_reg: RegNum) !void {
        if (src_reg == dst_reg) return;

        const copy = try self.f.newValue(.copy, value.type_idx, block, value.pos);
        copy.addArg(value);
        try self.ensureValState(copy);
        self.values[copy.id].regs = types.regMaskSet(0, dst_reg);
        try self.f.setHome(copy, .{ .register = @intCast(dst_reg) });
        try block.values.append(self.allocator, copy);
        debug.log(.regalloc, "  emit copy v{d} -> v{d} (x{d} -> x{d})", .{ value.id, copy.id, src_reg, dst_reg });
    }

    /// Emit a rematerialization for a value that has no register assigned.
    /// This is used for phi arguments that are constants (const_bool, const_int, etc.)
    /// which may have been evicted or never allocated to a register.
    fn emitRematerialize(self: *Self, block: *Block, value: *Value, dst_reg: RegNum) !void {
        // For rematerializeable values, we emit the value itself with the destination register
        // The codegen will materialize the constant directly into the register
        switch (value.op) {
            .const_bool, .const_int, .const_64, .const_nil => {
                // Create a copy of the constant value and assign it to dst_reg
                const remat = try self.f.newValue(value.op, value.type_idx, block, value.pos);
                remat.aux_int = value.aux_int;
                remat.aux = value.aux;
                try self.ensureValState(remat);
                self.values[remat.id].regs = types.regMaskSet(0, dst_reg);
                try self.f.setHome(remat, .{ .register = @intCast(dst_reg) });
                try block.values.append(self.allocator, remat);
                debug.log(.regalloc, "  emit remat v{d} -> v{d} ({s} -> x{d})", .{ value.id, remat.id, @tagName(value.op), dst_reg });
            },
            else => {
                // For non-rematerializeable values, this shouldn't happen
                // Fall back to creating a copy that references the original (will need a load)
                const copy = try self.f.newValue(.copy, value.type_idx, block, value.pos);
                copy.addArg(value);
                try self.ensureValState(copy);
                self.values[copy.id].regs = types.regMaskSet(0, dst_reg);
                try self.f.setHome(copy, .{ .register = @intCast(dst_reg) });
                try block.values.append(self.allocator, copy);
                debug.log(.regalloc, "  emit fallback copy v{d} -> v{d} (no src -> x{d})", .{ value.id, copy.id, dst_reg });
            },
        }
    }

    fn ensureValState(self: *Self, v: *Value) !void {
        if (v.id >= self.values.len) {
            const old_len = self.values.len;
            self.values = try self.allocator.realloc(self.values, v.id + 1);
            for (old_len..self.values.len) |i| {
                self.values[i] = .{};
            }
        }
    }

    fn findTempReg(self: *const Self, exclude: RegMask) ?RegNum {
        // Find a register that's not in the exclude set and not in use
        const available = self.allocatable_mask & ~exclude;
        var m = available;
        while (m != 0) {
            const reg: RegNum = @intCast(@ctz(m));
            m &= m - 1;
            if (reg < NUM_REGS and self.regs[reg].isFree()) {
                return reg;
            }
        }
        // If no free register, use x16 (IP0) as temp - it's caller-saved scratch
        if (exclude & (@as(RegMask, 1) << 16) == 0) {
            return 16;
        }
        return null;
    }

    // =========================================
    // Main Entry Point
    // =========================================

    pub fn run(self: *Self) !void {
        debug.log(.regalloc, "=== Register Allocation ===", .{});

        // Phase 1: Initialize per-value state
        // Go reference: regalloc.go init() lines 400-500
        // Initialize per-value properties (rematerializeable, needs_reg)
        // Note: uses is now a linked list, built per-block by buildUseLists()
        for (self.f.blocks.items) |block| {
            for (block.values.items) |v| {
                if (v.id < self.values.len) {
                    self.values[v.id].rematerializeable = isRematerializeable(v);
                    self.values[v.id].needs_reg = valueNeedsReg(v);
                }
            }
        }

        // Phase 2: Linear allocation (per block)
        for (self.f.blocks.items) |block| {
            try self.allocBlock(block);
        }

        // Phase 3: Shuffle (merge edge fixup)
        try self.shuffle();

        debug.log(.regalloc, "=== Regalloc complete: {d} spills ===", .{self.num_spills});
    }
};

// =========================================
// Helper Functions
// =========================================

fn needsOutputReg(v: *Value) bool {
    return switch (v.op) {
        .const_int, .const_64, .const_bool => true,
        .add, .sub, .mul, .div => true,
        .eq, .ne, .lt, .le, .gt, .ge => true,
        .load, .load_reg => true,
        .call, .static_call => true,
        .copy => true,
        .phi => true,
        .arg => true,
        .store, .store_reg => false,
        else => true,
    };
}

/// Check if a value can be rematerialized instead of spilled
/// Go reference: regalloc.go line 1650 (rematerializeable)
/// Rematerializeable values are cheap to recompute: constants, zero-arg ops
fn isRematerializeable(v: *Value) bool {
    return switch (v.op) {
        // Constants can always be rematerialized
        .const_int, .const_64, .const_bool => true,
        // local_addr is just LEA from RBP, can be recomputed
        .local_addr => true,
        // SP/SB (if we had them) would be rematerializeable
        // Args are NOT rematerializeable (they're passed in registers)
        else => false,
    };
}

/// Check if a value needs a register (not void/memory type)
/// Go reference: regalloc.go line 237
fn valueNeedsReg(v: *Value) bool {
    return switch (v.op) {
        // Memory/void operations don't need registers
        .store, .store_reg => false,
        // Most values need registers
        else => true,
    };
}

// =========================================
// Public API
// =========================================

pub fn regalloc(allocator: std.mem.Allocator, f: *Func, target: Target) !RegAllocState {
    // First compute liveness
    var live = try liveness.computeLiveness(allocator, f);
    errdefer live.deinit();

    // Then allocate registers
    var state = try RegAllocState.init(allocator, f, live, target);
    errdefer state.deinit();
    try state.run();

    return state;
}

// =========================================
// Tests
// =========================================

test "basic allocation" {
    // TODO: Add tests
}

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

/// Per-value state - PERSISTENT across all blocks
/// Go reference: regalloc.go lines 231-239
pub const ValState = struct {
    regs: RegMask = 0, // Which registers hold this value (PERSISTENT)
    spill: ?*Value = null, // StoreReg instruction
    spill_used: bool = false,
    uses: i32 = 0, // Remaining uses - decremented as args are processed
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

    // Stats
    num_spills: u32 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, f: *Func, live: liveness.LivenessResult) !Self {
        // Allocate per-value state for all values in the function
        // vid.next_id is the next ID to be allocated, so values 1..next_id-1 exist
        const max_id = f.vid.next_id;
        const values = try allocator.alloc(ValState, max_id);
        for (values) |*v| {
            v.* = .{};
        }

        return Self{
            .allocator = allocator,
            .f = f,
            .live = live,
            .values = values,
            .end_regs = .{},
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
        // Try to find a free register
        if (self.findFreeReg(mask)) |reg| {
            return reg;
        }

        // Must spill - find register with farthest next use
        var best_reg: ?RegNum = null;
        var best_dist: i32 = -1;

        // Get liveness info for this block
        const live_out = self.live.getLiveOut(block.id);

        var m = mask;
        while (m != 0) {
            const reg: RegNum = @intCast(@ctz(m));
            m &= m - 1;

            if (reg >= NUM_REGS) continue;
            const v = self.regs[reg].v orelse continue;

            // Get distance to next use from liveness info
            var dist: i32 = std.math.maxInt(i32); // Default: very far (not live)
            for (live_out) |info| {
                if (info.id == v.id) {
                    dist = info.dist;
                    break;
                }
            }

            if (dist > best_dist) {
                best_dist = dist;
                best_reg = reg;
            }
        }

        const reg = best_reg orelse return error.NoRegisterAvailable;

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
    fn spillReg(self: *Self, reg: RegNum, block: *Block) !?*Value {
        const v = self.regs[reg].v orelse return null;
        const vi = &self.values[v.id];

        var result: ?*Value = null;

        // Rematerializeable values don't need spills - they can be recomputed
        // Go reference: regalloc.go line 1650
        if (vi.rematerializeable) {
            debug.log(.regalloc, "    evict v{d} from x{d} (rematerializeable, no spill)", .{ v.id, reg });
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
        debug.log(.regalloc, "    assign v{d} -> x{d}", .{ v.id, reg });
    }

    fn freeReg(self: *Self, reg: RegNum) void {
        if (self.regs[reg].v) |v| {
            // Clear this register from value's mask
            self.values[v.id].regs = types.regMaskClear(self.values[v.id].regs, reg);
        }
        self.regs[reg].clear();
    }

    /// Load a spilled value back into a register, or rematerialize it.
    /// Does NOT add to block.values - caller must do that at the right position.
    /// Go reference: regalloc.go loadReg() line 1700
    fn loadValue(self: *Self, v: *Value, block: *Block) !*Value {
        const vi = &self.values[v.id];
        const reg = try self.allocReg(ARM64Regs.allocatable, block);

        // Rematerializeable values: copy the original instead of loading from spill
        // Go reference: regalloc.go line 1750 (copyInto for rematerializeable)
        if (vi.rematerializeable) {
            // Create a copy of the original value
            const copy = try self.f.newValue(v.op, v.type_idx, block, v.pos);
            copy.aux_int = v.aux_int; // Copy constant value
            try self.ensureValState(copy);
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
                const arg_regs = self.values[arg.id].regs & ~phi_used & ARM64Regs.allocatable;
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

            const available = ARM64Regs.allocatable & ~phi_used;
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

        // Build a NEW values list with loads/spills in the correct positions
        // Go reference: regalloc.go builds output in order as it processes
        var new_values = std.ArrayListUnmanaged(*Value){};
        defer new_values.deinit(self.allocator);

        // Copy original values to iterate (we'll rebuild the list)
        const original_values = try self.allocator.dupe(*Value, block.values.items);
        defer self.allocator.free(original_values);

        for (original_values) |v| {
            if (v.op == .phi) {
                // Phis go first, unchanged
                try new_values.append(self.allocator, v);
                continue;
            }

            debug.log(.regalloc, "  v{d} = {s}", .{ v.id, @tagName(v.op) });

            // Ensure arguments are in registers - insert loads BEFORE this value
            for (v.args, 0..) |arg, i| {
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
                        debug.log(.regalloc, "    updated arg {d} to v{d}", .{ i, loaded.id });
                    }
                }
            }

            // Handle calls - spill caller-saved registers BEFORE the call
            if (v.op.info().call) {
                debug.log(.regalloc, "    CALL - spilling caller-saved", .{});
                var reg: RegNum = 0;
                while (reg < 18) : (reg += 1) {
                    if (self.regs[reg].v != null) {
                        if (try self.spillReg(reg, block)) |spill| {
                            // Insert spill BEFORE the call
                            try new_values.append(self.allocator, spill);
                        }
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
                    // Function argument - fixed register per ABI (x0, x1, ..., x7)
                    const arg_reg: RegNum = @intCast(v.aux_int);
                    if (self.regs[arg_reg].v != null) {
                        // Another value is in this register - need to spill it
                        if (try self.spillReg(arg_reg, block)) |spill| {
                            try new_values.append(self.allocator, spill);
                        }
                    }
                    try self.assignReg(v, arg_reg);
                } else {
                    const reg = try self.allocReg(ARM64Regs.allocatable, block);
                    try self.assignReg(v, reg);
                }
            }

            // CRITICAL: Free registers for args that are now dead (Go's pattern)
            // After this value consumes its args, decrement their use counts
            // and free registers for args whose use count reaches 0
            // BUT: Don't free if the value is live-out (needed by successor phis)
            const live_out = self.live.getLiveOut(block.id);
            for (v.args) |arg| {
                if (arg.id < self.values.len) {
                    const vs = &self.values[arg.id];
                    if (vs.uses > 0) {
                        vs.uses -= 1;
                        if (vs.uses == 0) {
                            // Check if value is live-out before freeing
                            var is_live_out = false;
                            for (live_out) |info| {
                                if (info.id == arg.id) {
                                    is_live_out = true;
                                    break;
                                }
                            }
                            if (!is_live_out) {
                                // This arg has no more uses - free its register
                                if (vs.firstReg()) |reg| {
                                    debug.log(.regalloc, "    free x{d} (v{d} dead)", .{ reg, arg.id });
                                    self.freeReg(reg);
                                }
                            } else {
                                debug.log(.regalloc, "    keep x{?d} (v{d} live-out)", .{ vs.firstReg(), arg.id });
                            }
                        }
                    }
                }
            }
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

            const phi_reg = self.values[v.id].firstReg() orelse continue;
            if (pred_idx >= v.args.len) continue;

            const arg = v.args[pred_idx];
            const arg_reg = self.values[arg.id].firstReg();

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
                    }
                    d.satisfied = true;
                    progress = true;
                }
            }

            // If no progress, we have a cycle - break it with temp register
            if (!progress) {
                // Find first unsatisfied destination
                for (dests.items) |*d| {
                    if (!d.satisfied) {
                        // Break cycle: copy src to temp, then temp to dst
                        // Find temp register not used by any destination
                        const temp_reg = self.findTempReg(used_regs) orelse {
                            debug.log(.regalloc, "  ERROR: no temp register for cycle break", .{});
                            return error.NoTempRegister;
                        };

                        if (d.src_reg) |src| {
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
        const available = ARM64Regs.allocatable & ~exclude;
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
        for (self.f.blocks.items) |block| {
            for (block.values.items) |v| {
                if (v.id < self.values.len) {
                    self.values[v.id].uses = v.uses;
                    self.values[v.id].rematerializeable = isRematerializeable(v);
                    self.values[v.id].needs_reg = valueNeedsReg(v);
                }
            }
            // Also count control values
            for (block.controlValues()) |ctrl| {
                if (ctrl.id < self.values.len) {
                    // Control values have an implicit use
                    self.values[ctrl.id].uses = @max(self.values[ctrl.id].uses, 1);
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

pub fn regalloc(allocator: std.mem.Allocator, f: *Func) !RegAllocState {
    // First compute liveness
    var live = try liveness.computeLiveness(allocator, f);
    errdefer live.deinit();

    // Then allocate registers
    var state = try RegAllocState.init(allocator, f, live);
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

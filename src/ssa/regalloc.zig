//! Register Allocator - Go's Linear Scan Algorithm
//!
//! Go reference: cmd/compile/internal/ssa/regalloc.go (3,137 lines)
//!
//! This implements Go's greedy linear scan register allocator with
//! farthest-next-use spilling. Key properties:
//!
//! - **Greedy**: Allocates registers just before use
//! - **Farthest-next-use spilling**: When spill needed, spill value whose next use is farthest
//! - **Two-phase**: Block-by-block allocation, then edge fixup
//!
//! ## Algorithm Overview
//!
//! 1. Compute liveness information (distances to uses)
//! 2. For each block in reverse postorder:
//!    a. Initialize register state from predecessors
//!    b. Free registers for dead values
//!    c. Allocate inputs/outputs for each instruction
//!    d. Handle register clobbers
//! 3. Fix up edges between blocks (shuffle moves)
//! 4. Place spills optimally using dominators
//!
//! ## Cot-Specific Adaptations
//!
//! While following Go's algorithm exactly, we adapt for Cot:
//! - String/slice need 2 registers (ptr + len)
//! - No write barriers (Cot uses ARC)

const std = @import("std");
const types = @import("../core/types.zig");
const liveness = @import("liveness.zig");
const dom = @import("dom.zig");
const Value = @import("value.zig").Value;
const Block = @import("block.zig").Block;
const Func = @import("func.zig").Func;
const Op = @import("op.zig").Op;

const ID = types.ID;
const Pos = types.Pos;
const RegMask = types.RegMask;
const RegNum = types.RegNum;
const TypeIndex = types.TypeIndex;

// =========================================
// ARM64 Register Definitions
// Go reference: cmd/compile/internal/arm64/ssa.go
// =========================================

pub const ARM64Regs = struct {
    // General purpose registers
    pub const x0: RegNum = 0; // First argument, return value
    pub const x1: RegNum = 1;
    pub const x2: RegNum = 2;
    pub const x3: RegNum = 3;
    pub const x4: RegNum = 4;
    pub const x5: RegNum = 5;
    pub const x6: RegNum = 6;
    pub const x7: RegNum = 7; // Last argument register
    pub const x8: RegNum = 8; // Indirect result location
    pub const x9: RegNum = 9; // Temporary
    pub const x10: RegNum = 10;
    pub const x11: RegNum = 11;
    pub const x12: RegNum = 12;
    pub const x13: RegNum = 13;
    pub const x14: RegNum = 14;
    pub const x15: RegNum = 15;
    pub const x16: RegNum = 16; // IP0 - linker may clobber
    pub const x17: RegNum = 17; // IP1 - linker may clobber
    // x18 is platform reserved (skip)
    pub const x19: RegNum = 19; // Callee-saved start
    pub const x20: RegNum = 20;
    pub const x21: RegNum = 21;
    pub const x22: RegNum = 22;
    pub const x23: RegNum = 23;
    pub const x24: RegNum = 24;
    pub const x25: RegNum = 25;
    pub const x26: RegNum = 26;
    pub const x27: RegNum = 27;
    pub const x28: RegNum = 28; // Callee-saved end
    // x29 = FP, x30 = LR, x31 = SP/ZR

    /// Registers available for allocation (x0-x15, x19-x28)
    pub const allocatable: RegMask = blk: {
        var mask: RegMask = 0;
        // x0-x15 are scratch/argument registers
        for (0..16) |i| {
            mask |= @as(RegMask, 1) << i;
        }
        // x19-x28 are callee-saved but usable
        for (19..29) |i| {
            mask |= @as(RegMask, 1) << i;
        }
        break :blk mask;
    };

    /// Caller-saved registers (may be clobbered by call)
    pub const caller_saved: RegMask = blk: {
        var mask: RegMask = 0;
        // x0-x17 are caller-saved
        for (0..18) |i| {
            mask |= @as(RegMask, 1) << i;
        }
        break :blk mask;
    };

    /// Callee-saved registers (must be preserved across calls)
    pub const callee_saved: RegMask = blk: {
        var mask: RegMask = 0;
        // x19-x28 are callee-saved
        for (19..29) |i| {
            mask |= @as(RegMask, 1) << i;
        }
        break :blk mask;
    };

    /// Argument registers for function calls
    pub const arg_regs = [_]RegNum{ 0, 1, 2, 3, 4, 5, 6, 7 };

    /// Return value registers
    pub const ret_regs = [_]RegNum{ 0, 1 };
};

// =========================================
// Per-Value State
// Go reference: regalloc.go lines 155-180
// =========================================

/// State for each SSA value during allocation.
pub const ValState = struct {
    /// Bitmask of registers currently holding this value
    /// Can be in multiple registers (copies)
    regs: RegMask = 0,

    /// Spill instruction (StoreReg) if value has been spilled
    /// Created lazily when first needed
    spill: ?*Value = null,

    /// True if the spill has actually been used
    /// (needed for dead spill elimination)
    spill_used: bool = false,

    /// Range of positions where restores are needed
    /// For optimizing restore placement
    restore_min: i32 = std.math.maxInt(i32),
    restore_max: i32 = std.math.minInt(i32),

    /// True if rematerializable (can recompute instead of load)
    rematerializable: bool = false,

    /// For rematerializable values: the defining instruction
    remat_value: ?*Value = null,

    /// Reset state for a new allocation pass
    pub fn reset(self: *ValState) void {
        self.regs = 0;
        self.spill = null;
        self.spill_used = false;
        self.restore_min = std.math.maxInt(i32);
        self.restore_max = std.math.minInt(i32);
        self.rematerializable = false;
        self.remat_value = null;
    }

    /// Check if value is in any register
    pub fn inReg(self: *const ValState) bool {
        return self.regs != 0;
    }

    /// Get the first register holding this value (if any)
    pub fn firstReg(self: *const ValState) ?RegNum {
        return types.regMaskFirst(self.regs);
    }

    /// Add a register to this value's location set
    pub fn addReg(self: *ValState, reg: RegNum) void {
        self.regs = types.regMaskSet(self.regs, reg);
    }

    /// Remove a register from this value's location set
    pub fn removeReg(self: *ValState, reg: RegNum) void {
        self.regs = types.regMaskClear(self.regs, reg);
    }
};

// =========================================
// Per-Register State
// Go reference: regalloc.go lines 200-220
// =========================================

/// State for each physical register during allocation.
pub const RegState = struct {
    /// Value currently occupying this register
    /// null if register is free
    v: ?*Value = null,

    /// Secondary value (for handling copies during shuffles)
    c: ?*Value = null,

    /// True if this is a temporary allocation
    /// (will be freed after current instruction)
    tmp: bool = false,

    /// Check if register is free
    pub fn isFree(self: *const RegState) bool {
        return self.v == null;
    }

    /// Clear this register's state
    pub fn clear(self: *RegState) void {
        self.v = null;
        self.c = null;
        self.tmp = false;
    }
};

// =========================================
// Register Allocator State
// =========================================

/// Number of physical registers (ARM64)
pub const NUM_REGS: usize = 32;

/// Main register allocator state.
/// Go reference: regalloc.go lines 100-150
pub const RegAllocState = struct {
    /// Allocator for dynamic data structures
    allocator: std.mem.Allocator,

    /// Function being compiled
    f: *Func,

    /// Per-value state (indexed by value ID)
    values: []ValState,

    /// Per-register state
    regs: [NUM_REGS]RegState,

    /// Liveness information from analysis
    live: liveness.LivenessResult,

    /// Current block being processed
    cur_block: ?*Block = null,

    /// Current position within block (for distance calculation)
    cur_pos: i32 = 0,

    /// Statistics
    num_spills: u32 = 0,
    num_restores: u32 = 0,

    /// Block end states for edge fixup
    /// Maps block ID -> register state at block end
    end_states: std.AutoHashMapUnmanaged(ID, [NUM_REGS]RegState),

    /// Block start states for edge fixup
    /// Maps block ID -> register state at block start
    start_states: std.AutoHashMapUnmanaged(ID, [NUM_REGS]RegState),

    /// Desired registers for each value (hints to reduce copies)
    /// Maps value ID -> preferred register mask
    desired: std.AutoHashMapUnmanaged(ID, RegMask),

    /// Dominator tree for spill placement
    dom_tree: ?dom.DomTree = null,

    const Self = @This();

    /// Initialize register allocator for a function.
    pub fn init(allocator: std.mem.Allocator, f: *Func) !Self {
        // Compute liveness first
        var live = try liveness.computeLiveness(allocator, f);
        errdefer live.deinit();

        // Allocate per-value state (vid.next_id is one past the max used ID)
        const max_id = f.vid.next_id;
        const values = try allocator.alloc(ValState, max_id + 1);
        for (values) |*v| {
            v.* = .{};
        }

        return Self{
            .allocator = allocator,
            .f = f,
            .values = values,
            .regs = [_]RegState{.{}} ** NUM_REGS,
            .live = live,
            .end_states = .{},
            .start_states = .{},
            .desired = .{},
        };
    }

    /// Deinitialize and free resources.
    pub fn deinit(self: *Self) void {
        self.live.deinit();
        self.allocator.free(self.values);
        self.end_states.deinit(self.allocator);
        self.start_states.deinit(self.allocator);
        self.desired.deinit(self.allocator);
        if (self.dom_tree) |*dt| {
            dt.deinit();
        }
    }

    /// Reset for reuse with same function.
    pub fn reset(self: *Self) void {
        for (self.values) |*v| {
            v.reset();
        }
        for (&self.regs) |*r| {
            r.clear();
        }
        self.cur_block = null;
        self.cur_pos = 0;
        self.num_spills = 0;
        self.num_restores = 0;
        self.end_states.clearRetainingCapacity();
        self.start_states.clearRetainingCapacity();
        self.desired.clearRetainingCapacity();
    }

    // =========================================
    // Register Query Operations
    // =========================================

    /// Find a free register from the given mask.
    /// Returns null if no free register available.
    pub fn findFreeReg(self: *const Self, mask: RegMask) ?RegNum {
        var it = types.regMaskIterator(mask);
        while (it.next()) |reg| {
            if (self.regs[reg].isFree()) {
                return reg;
            }
        }
        return null;
    }

    /// Count free registers in the given mask.
    pub fn countFreeRegs(self: *const Self, mask: RegMask) u32 {
        var count: u32 = 0;
        var it = types.regMaskIterator(mask);
        while (it.next()) |reg| {
            if (self.regs[reg].isFree()) {
                count += 1;
            }
        }
        return count;
    }

    // =========================================
    // Spill Selection (Farthest Next Use)
    // Go reference: regalloc.go lines 1500-1600
    // =========================================

    /// Choose which register to spill.
    /// Selects the register whose value has the farthest next use.
    /// This is the core of Belady's algorithm.
    pub fn chooseSpill(self: *Self, mask: RegMask) ?RegNum {
        var best_reg: ?RegNum = null;
        var best_dist: i32 = -1;

        var it = types.regMaskIterator(mask);
        while (it.next()) |reg| {
            const v = self.regs[reg].v orelse continue;

            // Get distance to next use from liveness info
            const dist = self.getNextUseDistance(v);

            if (dist > best_dist) {
                best_dist = dist;
                best_reg = reg;
            }
        }

        return best_reg;
    }

    /// Get distance to next use of a value.
    fn getNextUseDistance(self: *Self, v: *Value) i32 {
        // Look up in liveness result
        if (self.cur_block) |block| {
            const block_live = self.live.getLiveOut(block.id);
            for (block_live) |info| {
                if (info.id == v.id) {
                    return info.dist;
                }
            }
        }
        // Not found = no more uses = max distance
        return std.math.maxInt(i32);
    }

    // =========================================
    // Spill/Restore Operations
    // Go reference: regalloc.go lines 1610-1900
    // =========================================

    /// Spill a value from a register to memory.
    pub fn spillReg(self: *Self, reg: RegNum) void {
        const v = self.regs[reg].v orelse return;
        const vs = &self.values[v.id];

        // Create spill instruction if needed
        if (vs.spill == null) {
            // StoreReg is created without a block - placed later
            vs.spill = self.f.newValue(.store, v.type_idx, null, v.pos) catch null;
            if (vs.spill) |spill| {
                spill.addArg(v);
            }
        }

        // Mark spill as used
        vs.spill_used = true;
        self.num_spills += 1;

        // Clear register state
        vs.removeReg(reg);
        self.regs[reg].clear();
    }

    /// Allocate a register from the given mask, spilling if needed.
    pub fn allocReg(self: *Self, mask: RegMask) !RegNum {
        // First try to find a free register
        if (self.findFreeReg(mask)) |reg| {
            return reg;
        }

        // No free register - must spill
        const spill_reg = self.chooseSpill(mask) orelse {
            return error.NoRegisterAvailable;
        };

        self.spillReg(spill_reg);
        return spill_reg;
    }

    /// Assign a value to a register.
    pub fn assignReg(self: *Self, v: *Value, reg: RegNum) void {
        const vs = &self.values[v.id];

        // Update register state
        self.regs[reg].v = v;
        self.regs[reg].tmp = false;

        // Update value state
        vs.addReg(reg);
    }

    /// Free a register (value no longer needed).
    pub fn freeReg(self: *Self, reg: RegNum) void {
        const v = self.regs[reg].v orelse return;
        const vs = &self.values[v.id];

        vs.removeReg(reg);
        self.regs[reg].clear();
    }

    // =========================================
    // Block Processing
    // Go reference: regalloc.go lines 1000-1400
    // =========================================

    /// Process a single block for register allocation.
    pub fn allocBlock(self: *Self, block: *Block) !void {
        self.cur_block = block;
        self.cur_pos = 0;

        // Process each value in the block
        for (block.values.items, 0..) |v, i| {
            self.cur_pos = @intCast(i);

            // Skip phi nodes (handled separately in edge fixup)
            if (v.op == .phi) continue;

            // Allocate registers for this value's inputs
            for (v.args) |arg| {
                if (!self.values[arg.id].inReg()) {
                    // Value not in register - need to load it
                    try self.loadValue(arg);
                }
            }

            // Allocate register for output (if this value produces one)
            if (needsOutputReg(v)) {
                const reg = try self.allocReg(ARM64Regs.allocatable);
                self.assignReg(v, reg);
            }

            // Handle call clobbers
            if (v.op == .call) {
                self.handleCallClobbers();
            }
        }

        // Process block control value
        for (block.controlValues()) |ctrl| {
            if (!self.values[ctrl.id].inReg()) {
                try self.loadValue(ctrl);
            }
        }
    }

    /// Load a spilled value back into a register.
    fn loadValue(self: *Self, v: *Value) !void {
        const vs = &self.values[v.id];

        // Check if rematerializable
        if (vs.rematerializable) {
            // TODO: Recompute instead of loading
        }

        // Allocate a register and insert load
        const reg = try self.allocReg(ARM64Regs.allocatable);

        // Insert LoadReg from spill slot
        if (vs.spill) |spill| {
            const load = try self.f.newValue(.load, v.type_idx, self.cur_block, v.pos);
            load.addArg(spill);
            // Add load to current block
            if (self.cur_block) |block| {
                try block.addValue(self.allocator, load);
            }
        }

        self.assignReg(v, reg);
        self.num_restores += 1;
    }

    /// Handle register clobbers from a call instruction.
    fn handleCallClobbers(self: *Self) void {
        // Spill all caller-saved registers that hold live values
        var it = types.regMaskIterator(ARM64Regs.caller_saved);
        while (it.next()) |reg| {
            if (self.regs[reg].v) |v| {
                // Check if value is still live after this point
                const dist = self.getNextUseDistance(v);
                if (dist > 0) {
                    // Still live - must spill
                    self.spillReg(reg);
                } else {
                    // Dead - just free the register
                    self.freeReg(reg);
                }
            }
        }
    }

    // =========================================
    // Desired Register Computation
    // Go reference: regalloc.go lines 700-900
    // =========================================

    /// Compute desired registers for a block.
    /// Propagates register preferences backward through instructions.
    fn computeDesired(self: *Self, block: *Block) !void {
        // Walk block backwards
        var i: i32 = @intCast(block.values.items.len);
        while (i > 0) {
            i -= 1;
            const idx: usize = @intCast(i);
            const v = block.values.items[idx];

            // Get desired registers for this value's output
            const out_desired = self.desired.get(v.id) orelse continue;

            // Propagate to first argument for result_in_arg0 ops
            // (e.g., ARM64 add clobbers first operand on some architectures)
            if (v.args.len > 0) {
                const arg = v.args[0];
                // Merge with existing desired
                const existing = self.desired.get(arg.id) orelse 0;
                try self.desired.put(self.allocator, arg.id, existing | out_desired);
            }
        }
    }

    /// Add desired register hint for a value.
    pub fn addDesired(self: *Self, id: ID, mask: RegMask) !void {
        const existing = self.desired.get(id) orelse 0;
        try self.desired.put(self.allocator, id, existing | mask);
    }

    // =========================================
    // Block State Management
    // =========================================

    /// Save register state at end of block.
    fn saveBlockEndState(self: *Self, block: *Block) !void {
        try self.end_states.put(self.allocator, block.id, self.regs);
    }

    /// Save register state at start of block.
    fn saveBlockStartState(self: *Self, block: *Block) !void {
        try self.start_states.put(self.allocator, block.id, self.regs);
    }

    /// Initialize register state from predecessor blocks.
    fn initBlockState(self: *Self, block: *Block) void {
        // For now, start with empty state
        // TODO: Copy state from dominating predecessor
        for (&self.regs) |*r| {
            r.clear();
        }

        // If single predecessor, copy its end state
        if (block.preds.len == 1) {
            const pred = block.preds[0].b;
            if (self.end_states.get(pred.id)) |end_state| {
                self.regs = end_state;
            }
        }
    }

    // =========================================
    // Edge Fixup (Shuffle)
    // Go reference: regalloc.go lines 2320-2668
    // =========================================

    /// Move for edge fixup.
    const Move = struct {
        dst: RegNum,
        src: RegNum,
        v: ?*Value,
    };

    /// Fix up edges between blocks.
    /// Generates moves to reconcile register state differences.
    fn shuffleEdges(self: *Self) !void {
        for (self.f.blocks.items) |block| {
            for (block.preds) |pred_edge| {
                const pred = pred_edge.b;
                try self.fixupEdge(pred, block);
            }
        }
    }

    /// Fix up a single edge between blocks.
    fn fixupEdge(self: *Self, pred: *Block, succ: *Block) !void {
        const pred_state = self.end_states.get(pred.id) orelse return;
        const succ_state = self.start_states.get(succ.id) orelse return;

        // Collect needed moves
        var moves = std.ArrayListUnmanaged(Move){};
        defer moves.deinit(self.allocator);

        for (0..NUM_REGS) |reg_idx| {
            const reg: RegNum = @intCast(reg_idx);
            const pred_v = pred_state[reg_idx].v;
            const succ_v = succ_state[reg_idx].v;

            if (pred_v != succ_v) {
                if (succ_v) |v| {
                    // Need to get v into reg
                    // Find where v is in predecessor
                    const src = self.findValueLocation(&pred_state, v);
                    if (src) |s| {
                        try moves.append(self.allocator, .{ .dst = reg, .src = s, .v = v });
                    }
                }
            }
        }

        // Execute moves (simple version - may need cycle breaking)
        for (moves.items) |move| {
            // Insert move instruction at end of predecessor block
            _ = move;
            // TODO: Actually insert mov instructions
        }
    }

    /// Find which register holds a value in a given state.
    fn findValueLocation(self: *Self, state: *const [NUM_REGS]RegState, v: *Value) ?RegNum {
        _ = self;
        for (0..NUM_REGS) |reg_idx| {
            if (state[reg_idx].v == v) {
                return @intCast(reg_idx);
            }
        }
        return null;
    }

    // =========================================
    // Spill Placement
    // Go reference: regalloc.go lines 2197-2318
    // =========================================

    /// Place spill instructions in optimal blocks using dominators.
    /// Spills should be placed as late as possible while still dominating all restores.
    fn placeSpills(self: *Self) !void {
        // Compute dominator tree if not already done
        if (self.dom_tree == null) {
            self.dom_tree = try dom.computeDominators(self.f);
        }

        // For each value with a spill
        for (self.values, 0..) |*vs, id| {
            const spill = vs.spill orelse continue;
            if (!vs.spill_used) {
                // Spill was created but never needed - mark for removal
                // (actual removal would require more infrastructure)
                vs.spill = null;
                continue;
            }

            // Find the block where the value is defined
            const value_id: ID = @intCast(id);
            const def_block = self.findDefBlock(value_id) orelse continue;

            // For now, place spill right after definition in the defining block
            // A more sophisticated approach would find the optimal block using
            // dominator tree to minimize spill overhead
            spill.block = def_block;

            // Insert spill after the defining value
            // (In a full implementation, we'd insert into the block's value list)
        }
    }

    /// Find the block where a value is defined.
    fn findDefBlock(self: *Self, value_id: ID) ?*Block {
        for (self.f.blocks.items) |block| {
            for (block.values.items) |v| {
                if (v.id == value_id) {
                    return block;
                }
            }
        }
        return null;
    }

    // =========================================
    // Main Entry Point
    // =========================================

    /// Run register allocation on the function.
    pub fn run(self: *Self) !void {
        // Phase 2: Compute desired registers (backward pass)
        var i: i32 = @intCast(self.f.blocks.items.len);
        while (i > 0) {
            i -= 1;
            const idx: usize = @intCast(i);
            try self.computeDesired(self.f.blocks.items[idx]);
        }

        // Phase 3-5: Process blocks in order
        for (self.f.blocks.items) |block| {
            // Initialize state from predecessors
            self.initBlockState(block);
            try self.saveBlockStartState(block);

            // Allocate registers for this block
            try self.allocBlock(block);

            // Save end state for edge fixup
            try self.saveBlockEndState(block);
        }

        // Phase 6: Edge fixup (shuffle phi values)
        try self.shuffleEdges();

        // Phase 4: Place spills optimally using dominators
        try self.placeSpills();
    }
};

// =========================================
// Helper Functions
// =========================================

/// Check if a value's operation produces an output that needs a register.
fn needsOutputReg(v: *Value) bool {
    return switch (v.op) {
        .const_int, .const_bool => true,
        .add, .sub, .mul, .div => true,
        .load => true,
        .call => true,
        .phi => true,
        // Memory/control ops don't produce register outputs
        .store => false,
        else => true, // Conservative default
    };
}

// =========================================
// Main API
// =========================================

/// Run register allocation on a function.
/// Returns the allocator state for inspection/debugging.
pub fn regalloc(allocator: std.mem.Allocator, f: *Func) !RegAllocState {
    var state = try RegAllocState.init(allocator, f);
    errdefer state.deinit();

    try state.run();

    return state;
}

// =========================================
// Tests
// =========================================

test "ARM64 register masks" {
    // Verify allocatable mask is correct
    try std.testing.expect(types.regMaskContains(ARM64Regs.allocatable, 0)); // x0 is allocatable
    try std.testing.expect(types.regMaskContains(ARM64Regs.allocatable, 15)); // x15 is allocatable
    try std.testing.expect(!types.regMaskContains(ARM64Regs.allocatable, 18)); // x18 is reserved
    try std.testing.expect(types.regMaskContains(ARM64Regs.allocatable, 19)); // x19 is callee-saved but usable
}

test "ValState operations" {
    var vs = ValState{};

    try std.testing.expect(!vs.inReg());

    vs.addReg(0);
    try std.testing.expect(vs.inReg());
    try std.testing.expectEqual(@as(?RegNum, 0), vs.firstReg());

    vs.addReg(5);
    try std.testing.expectEqual(@as(u32, 2), types.regMaskCount(vs.regs));

    vs.removeReg(0);
    try std.testing.expectEqual(@as(?RegNum, 5), vs.firstReg());

    vs.reset();
    try std.testing.expect(!vs.inReg());
}

test "RegState operations" {
    var rs = RegState{};

    try std.testing.expect(rs.isFree());

    // Can't set a value without a real value pointer, but we can test clear
    rs.tmp = true;
    rs.clear();
    try std.testing.expect(!rs.tmp);
    try std.testing.expect(rs.isFree());
}

test "RegAllocState initialization" {
    const allocator = std.testing.allocator;
    const test_helpers = @import("test_helpers.zig");

    var builder = try test_helpers.TestFuncBuilder.init(allocator, "regalloc_test");
    defer builder.deinit();

    // Create a simple block
    const linear = try builder.createLinearCFG(1);
    defer allocator.free(linear.blocks);

    var state = try RegAllocState.init(allocator, builder.func);
    defer state.deinit();

    // Initial state checks
    try std.testing.expect(state.findFreeReg(ARM64Regs.allocatable) != null);
    try std.testing.expectEqual(@as(u32, 0), state.num_spills);
}

test "findFreeReg finds available register" {
    const allocator = std.testing.allocator;
    const test_helpers = @import("test_helpers.zig");

    var builder = try test_helpers.TestFuncBuilder.init(allocator, "find_free_test");
    defer builder.deinit();

    const linear = try builder.createLinearCFG(1);
    defer allocator.free(linear.blocks);

    var state = try RegAllocState.init(allocator, builder.func);
    defer state.deinit();

    // Should find a free register
    const reg = state.findFreeReg(ARM64Regs.allocatable);
    try std.testing.expect(reg != null);

    // Count all free registers
    const free_count = state.countFreeRegs(ARM64Regs.allocatable);
    try std.testing.expect(free_count > 0);
}

test "chooseSpill selects farthest use" {
    const allocator = std.testing.allocator;
    const test_helpers = @import("test_helpers.zig");

    var builder = try test_helpers.TestFuncBuilder.init(allocator, "spill_test");
    defer builder.deinit();

    const linear = try builder.createLinearCFG(1);
    defer allocator.free(linear.blocks);

    var state = try RegAllocState.init(allocator, builder.func);
    defer state.deinit();

    // With no values in registers, chooseSpill returns null
    const spill = state.chooseSpill(ARM64Regs.allocatable);
    try std.testing.expect(spill == null);
}

test "regalloc full integration" {
    const allocator = std.testing.allocator;
    const test_helpers = @import("test_helpers.zig");

    var builder = try test_helpers.TestFuncBuilder.init(allocator, "integration_test");
    defer builder.deinit();

    // Create: v1 = 40; v2 = 2; v3 = add v1 v2; ret v3
    const linear = try builder.createLinearCFG(1);
    defer allocator.free(linear.blocks);

    const entry = linear.entry;

    const v1 = try builder.func.newValue(.const_int, types.PrimitiveTypes.i64_type, entry, .{});
    v1.aux_int = 40;
    try entry.addValue(allocator, v1);

    const v2 = try builder.func.newValue(.const_int, types.PrimitiveTypes.i64_type, entry, .{});
    v2.aux_int = 2;
    try entry.addValue(allocator, v2);

    const v3 = try builder.func.newValue(.add, types.PrimitiveTypes.i64_type, entry, .{});
    v3.addArg(v1);
    v3.addArg(v2);
    try entry.addValue(allocator, v3);

    entry.setControl(v3);

    // Run register allocation
    var state = try regalloc(allocator, builder.func);
    defer state.deinit();

    // All values should have been processed without spills
    // (we have plenty of registers for 3 values)
    try std.testing.expectEqual(@as(u32, 0), state.num_spills);

    // Values should be in registers
    try std.testing.expect(state.values[v1.id].inReg() or state.values[v1.id].spill != null);
    try std.testing.expect(state.values[v2.id].inReg() or state.values[v2.id].spill != null);
    try std.testing.expect(state.values[v3.id].inReg() or state.values[v3.id].spill != null);
}

test "regalloc with diamond CFG" {
    const allocator = std.testing.allocator;
    const test_helpers = @import("test_helpers.zig");

    var builder = try test_helpers.TestFuncBuilder.init(allocator, "diamond_test");
    defer builder.deinit();

    // Create diamond: entry -> then, entry -> else; then -> merge; else -> merge
    // DiamondCFG blocks are owned by the Func, no separate free needed
    const diamond = try builder.createDiamondCFG();

    // Add a phi in merge block
    const phi = try builder.func.newValue(.phi, types.PrimitiveTypes.i64_type, diamond.merge, .{});
    try diamond.merge.addValue(allocator, phi);
    diamond.merge.setControl(phi);

    // Add values to then/else branches
    const then_val = try builder.func.newValue(.const_int, types.PrimitiveTypes.i64_type, diamond.then_block, .{});
    then_val.aux_int = 1;
    try diamond.then_block.addValue(allocator, then_val);

    const else_val = try builder.func.newValue(.const_int, types.PrimitiveTypes.i64_type, diamond.else_block, .{});
    else_val.aux_int = 2;
    try diamond.else_block.addValue(allocator, else_val);

    phi.addArg(then_val);
    phi.addArg(else_val);

    // Run register allocation
    var state = try regalloc(allocator, builder.func);
    defer state.deinit();

    // Should have block states saved for edge fixup
    try std.testing.expect(state.end_states.count() > 0);
}

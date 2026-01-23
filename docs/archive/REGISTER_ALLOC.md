# Register Allocation - Go's Exact Algorithm

This document describes Go's linear scan register allocator in enough detail to implement it identically in Zig. This is the most critical component for eliminating the "whack-a-mole" bug pattern.

## Algorithm Overview

Go uses **Linear Scan Register Allocation** - NOT graph coloring.

Key properties:
- **Greedy**: Allocates registers just before use
- **Farthest-next-use spilling**: When spilling needed, spill the value whose next use is farthest away
- **Two-phase**: Block-by-block allocation, then edge fixup

Reference: `cmd/compile/internal/ssa/regalloc.go` (3,137 lines)

## Data Structures

### Per-Value State (valState)

```zig
/// State for each SSA value during allocation.
/// Go reference: regalloc.go lines 155-180
pub const ValState = struct {
    /// Bitmask of registers currently holding this value
    /// Can be in multiple registers (copies)
    regs: RegMask = 0,

    /// Number of uses remaining for this value
    /// Decremented as we process uses
    uses: i32 = 0,

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
};
```

### Per-Register State (regState)

```zig
/// State for each physical register during allocation.
/// Go reference: regalloc.go lines 200-220
pub const RegState = struct {
    /// Value currently occupying this register
    /// null if register is free
    v: ?*Value = null,

    /// Secondary value (for handling copies during shuffles)
    c: ?*Value = null,

    /// True if this is a temporary allocation
    /// (will be freed after current instruction)
    tmp: bool = false,
};
```

### Use Record (use)

```zig
/// Records where a value is used.
/// Forms a DECREASING-DISTANCE linked list from definition to uses.
/// Go reference: regalloc.go lines 250-270
pub const Use = struct {
    /// Distance from start of block (decreasing in list order)
    /// Used for farthest-next-use spilling decision
    dist: i32,

    /// Source position for error messages
    pos: Pos,

    /// Next use record (closer to current point)
    next: ?*Use = null,
};
```

### Desired Registers (desiredState)

```zig
/// Tracks which registers values "want" to be in.
/// Propagated backward through instructions.
/// Go reference: regalloc.go lines 280-300
pub const DesiredState = struct {
    /// For each value ID: bitmask of preferred registers
    entries: []DesiredEntry,
};

pub const DesiredEntry = struct {
    id: ID,
    regs: RegMask,
    /// How strongly we want these registers
    /// Higher = more important
    cost: i32 = 0,
};
```

## Main Algorithm

### Phase 1: Liveness Analysis (3 stages)

Go computes liveness in three stages:

**Stage 1: Basic Backward Analysis**

```zig
/// Compute live values at block boundaries.
/// Go reference: regalloc.go lines 2836-2930
fn computeLive(f: *Func) []LiveInfo {
    // Initialize: each value live at its definition
    for (f.blocks) |b| {
        for (b.values) |v| {
            live[v.id] = LiveInfo{
                .dist = 0,  // Will be filled in stage 2
                .pos = v.pos,
            };
        }
    }

    // Backward pass: mark values live at predecessor block ends
    // if used in successor blocks
    var changed = true;
    while (changed) {
        changed = false;
        for (f.postorder()) |b| {
            for (b.values) |v| {
                for (v.args) |arg| {
                    if (arg.block != b) {
                        // arg defined in different block, live at that block's end
                        if (!liveAtEnd[arg.block.id].contains(arg.id)) {
                            liveAtEnd[arg.block.id].add(arg.id);
                            changed = true;
                        }
                    }
                }
            }
        }
    }
}
```

**Stage 2: Distance Computation**

```zig
/// Assign distances from block start to each use.
/// Go reference: regalloc.go lines 2940-3020
fn computeDistances(f: *Func) void {
    for (f.blocks) |b| {
        var dist: i32 = 0;
        for (b.values) |v| {
            // Each value gets a distance
            distances[v.id] = dist;
            dist += 1;

            // Each argument use gets a Use record
            for (v.args, 0..) |arg, i| {
                const u = allocUse();
                u.dist = dist;
                u.pos = v.pos;
                u.next = uses[arg.id];
                uses[arg.id] = u;
            }
        }
    }
}
```

**Stage 3: Loop Propagation**

```zig
/// Propagate live values through loop headers.
/// Values live at loop end must be live at loop start.
/// Go reference: regalloc.go lines 3030-3100
fn propagateLoopLiveness(f: *Func) void {
    const loops = f.loopnest();
    for (loops) |loop| {
        // Find values live at any exit from loop
        var live_at_exit = RegMask{};
        for (loop.exits) |exit| {
            live_at_exit.unionWith(liveAtEnd[exit.id]);
        }

        // These must also be live at loop header
        liveAtStart[loop.header.id].unionWith(live_at_exit);

        // And at all blocks in loop
        for (loop.blocks) |b| {
            liveAtEnd[b.id].unionWith(live_at_exit);
        }
    }
}
```

### Phase 2: Block-by-Block Allocation

The main allocation loop processes blocks in reverse postorder.

```zig
/// Main register allocation.
/// Go reference: regalloc.go lines 1000-1400
fn regalloc(f: *Func) void {
    // Initialize state
    var state = RegAllocState.init(f);

    // Process blocks in order that minimizes phi-related copies
    for (f.reversePostorder()) |b| {
        state.allocBlock(b);
    }

    // Fix up edges between blocks
    state.shufflePhis();
}

fn allocBlock(state: *RegAllocState, b: *Block) void {
    // 1. Initialize register state from predecessors
    state.initBlockState(b);

    // 2. Process each value in block
    for (b.values) |v| {
        // 2a. Free registers for dead values
        state.freeDeadValues(v);

        // 2b. Allocate registers for this value's inputs
        for (v.args, 0..) |arg, i| {
            const info = v.op.info().reg.inputs[i];
            state.allocInput(v, arg, info.regs);
        }

        // 2c. Allocate register(s) for this value's output
        if (v.op.info().reg.outputs.len > 0) {
            const info = v.op.info().reg.outputs[0];
            state.allocOutput(v, info.regs);
        }

        // 2d. Handle clobbers
        for (v.op.info().reg.clobbers.bits()) |reg| {
            state.spillReg(reg);
        }
    }

    // 3. Process block control value
    if (b.controls[0]) |ctrl| {
        state.allocInput(null, ctrl, state.config.gp_reg_mask);
    }

    // 4. Record end state for edge fixup
    state.saveBlockEndState(b);
}
```

### Phase 3: Spilling

When a register is needed but all are occupied, spill the value whose next use is farthest away.

```zig
/// Choose which value to spill.
/// Go reference: regalloc.go lines 1500-1600
fn chooseSpill(state: *RegAllocState, mask: RegMask) u8 {
    var best_reg: u8 = 0;
    var best_dist: i32 = -1;

    // Find the register whose value has farthest next use
    var it = mask.iterator();
    while (it.next()) |reg| {
        const v = state.regs[reg].v orelse continue;
        const vs = &state.values[v.id];

        // Get distance to next use
        const use = state.uses[v.id];
        const dist = if (use) |u| u.dist else std.math.maxInt(i32);

        if (dist > best_dist) {
            best_dist = dist;
            best_reg = reg;
        }
    }

    return best_reg;
}

/// Spill a value from a register.
/// Go reference: regalloc.go lines 1610-1700
fn spillReg(state: *RegAllocState, reg: u8) void {
    const v = state.regs[reg].v orelse return;
    const vs = &state.values[v.id];

    // Create spill if needed
    if (vs.spill == null) {
        // StoreReg is inserted "blockless" - will be placed later
        vs.spill = state.f.newValue(.store_reg, v.type_idx, null, v.pos);
        vs.spill.?.addArg(v);
    }

    // Mark spill as used
    vs.spill_used = true;

    // Clear register state
    vs.regs &= ~(@as(RegMask, 1) << reg);
    state.regs[reg].v = null;
}
```

### Phase 4: Spill Placement

Spills (StoreReg) are initially created without a block. This phase places them optimally using dominators.

```zig
/// Place spill instructions in optimal blocks.
/// Go reference: regalloc.go lines 2197-2318
fn placeSpills(state: *RegAllocState) void {
    for (state.values, 0..) |*vs, id| {
        const spill = vs.spill orelse continue;
        if (!vs.spill_used) {
            // Spill was created but never needed - delete it
            state.f.freeValue(spill);
            vs.spill = null;
            continue;
        }

        // Find optimal block for spill using dominator tree
        const def_block = state.f.blocks[state.f.values[id].block.id];
        var best_block = def_block;

        // Walk dominator tree to find latest block that dominates all uses
        const uses = collectUseBlocks(state, id);
        for (uses) |use_block| {
            // Find common dominator
            best_block = commonDominator(best_block, use_block);
        }

        // Place spill in best block, right after definition
        spill.block = best_block;
        insertAfter(best_block, state.f.values[id], spill);
    }
}
```

### Phase 5: Restore Insertion

When a spilled value is needed, insert LoadReg to restore it.

```zig
/// Insert restores (LoadReg) for spilled values.
/// Go reference: regalloc.go lines 1800-1900
fn insertRestore(state: *RegAllocState, v: *Value, reg: u8) void {
    const vs = &state.values[v.id];

    // Rematerializable? Recompute instead of load
    if (vs.rematerializable) {
        const remat = copyValue(vs.remat_value.?);
        state.curBlock().values.append(remat);
        state.regs[reg].v = v;
        vs.regs |= @as(RegMask, 1) << reg;
        return;
    }

    // Insert LoadReg from spill slot
    const load = state.f.newValue(.load_reg, v.type_idx, state.curBlock(), v.pos);
    load.addArg(vs.spill.?);
    state.curBlock().values.append(load);

    // Update state
    state.regs[reg].v = v;
    vs.regs |= @as(RegMask, 1) << reg;
}
```

### Phase 6: Edge Fixup (Shuffle)

At block boundaries, values may need to move between registers.

```zig
/// Reconcile register state across block edges.
/// Go reference: regalloc.go lines 2320-2668
fn shuffleEdges(state: *RegAllocState) void {
    for (state.f.blocks) |b| {
        for (b.preds) |pred_edge| {
            const pred = pred_edge.b;

            // Compare end state of pred with start state of b
            const pred_state = state.endStates[pred.id];
            const succ_state = state.startStates[b.id];

            // Generate moves to reconcile differences
            var moves = std.ArrayList(Move).init(state.allocator);
            for (0..NUM_REGS) |reg| {
                const pred_v = pred_state.regs[reg].v;
                const succ_v = succ_state.regs[reg].v;

                if (pred_v != succ_v) {
                    if (succ_v) |v| {
                        // Need to get v into reg
                        const src = findValueLocation(pred_state, v);
                        moves.append(.{ .dst = reg, .src = src, .v = v });
                    }
                }
            }

            // Execute moves, breaking cycles with temp register
            executeMoves(state, pred, b, moves.items);
        }
    }
}

/// Execute a list of moves, handling cycles.
/// Go reference: regalloc.go lines 2500-2600
fn executeMoves(state: *RegAllocState, pred: *Block, succ: *Block, moves: []Move) void {
    while (moves.len > 0) {
        // Find a move whose destination is free
        var found = false;
        for (moves, 0..) |move, i| {
            if (!moveBlocksDest(moves, move.dst)) {
                // Can execute this move directly
                emitMove(pred, move);
                removeMove(moves, i);
                found = true;
                break;
            }
        }

        if (!found) {
            // All destinations are blocked - we have a cycle
            // Break it by moving one value to a temp register
            const move = moves[0];
            const tmp = findFreeReg(state) orelse spillForTemp(state);

            // Move blocked value to temp
            emitMove(pred, .{ .dst = tmp, .src = move.dst, .v = state.regs[move.dst].v });

            // Update moves that referenced the old location
            for (moves) |*m| {
                if (m.src == move.dst) {
                    m.src = tmp;
                }
            }
        }
    }
}
```

## Register Hints (Desired State)

Go propagates "hints" backward to prefer certain registers, reducing copies.

```zig
/// Compute desired registers for each value.
/// Go reference: regalloc.go lines 700-900
fn computeDesired(state: *RegAllocState, b: *Block) void {
    // Walk block backwards
    var i = b.values.len;
    while (i > 0) {
        i -= 1;
        const v = b.values[i];

        // Propagate output preference to inputs
        if (v.op.info().result_in_arg0) {
            // Output must be in same register as arg[0]
            // Propagate any hint for output to arg[0]
            const out_hint = state.desired.get(v.id) orelse continue;
            state.addDesired(v.args[0].id, out_hint.regs);
        }

        // For commutative ops, prefer inputs in same registers
        if (v.op.info().commutative) {
            // If arg[1] already in desired reg for output,
            // swap args to avoid a copy
            const out_hint = state.desired.get(v.id) orelse continue;
            if (state.values[v.args[1].id].regs & out_hint.regs != 0) {
                // Swap args
                const tmp = v.args[0];
                v.args[0] = v.args[1];
                v.args[1] = tmp;
            }
        }
    }
}
```

## ARM64-Specific Details

### Registers

```zig
// ARM64 register assignments
pub const arm64_regs = struct {
    // General purpose (usable for allocation)
    pub const x0 = 0;   // First argument, return value
    pub const x1 = 1;
    pub const x2 = 2;
    pub const x3 = 3;
    pub const x4 = 4;
    pub const x5 = 5;
    pub const x6 = 6;
    pub const x7 = 7;   // Last argument register
    pub const x8 = 8;   // Indirect result location
    pub const x9 = 9;   // Temporary
    pub const x10 = 10;
    pub const x11 = 11;
    pub const x12 = 12;
    pub const x13 = 13;
    pub const x14 = 14;
    pub const x15 = 15;
    pub const x16 = 16; // IP0 - linker may clobber
    pub const x17 = 17; // IP1 - linker may clobber
    pub const x18 = 18; // Platform reserved
    pub const x19 = 19; // Callee-saved
    // x19-x28 are callee-saved
    pub const x29 = 29; // Frame pointer
    pub const x30 = 30; // Link register (return address)
    // x31 = SP or ZR depending on context

    // Allocatable registers (what regalloc can use)
    pub const allocatable: RegMask = blk: {
        var mask: RegMask = 0;
        // x0-x15 are available
        for (0..16) |i| {
            mask |= @as(RegMask, 1) << i;
        }
        // x19-x28 available but callee-saved
        for (19..29) |i| {
            mask |= @as(RegMask, 1) << i;
        }
        break :blk mask;
    };

    // Caller-saved (may clobber across calls)
    pub const caller_saved: RegMask = blk: {
        var mask: RegMask = 0;
        for (0..19) |i| {
            mask |= @as(RegMask, 1) << i;
        }
        break :blk mask;
    };
};
```

### Calling Convention

```zig
/// ARM64 calling convention (AAPCS64).
pub const arm64_abi = struct {
    /// Parameter registers
    pub const int_args = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };  // x0-x7
    pub const float_args = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 }; // v0-v7

    /// Return value registers
    pub const int_results = [_]u8{ 0, 1 };  // x0-x1
    pub const float_results = [_]u8{ 0, 1 }; // v0-v1

    /// For structs > 16 bytes: pointer in x8
    pub const indirect_result = 8;

    /// Compute where parameter goes
    pub fn paramLocation(idx: usize, type_idx: TypeIndex) Location {
        if (idx < int_args.len) {
            return .{ .register = arm64_regs.registers[int_args[idx]] };
        }
        // Overflow to stack
        const offset = (idx - int_args.len) * 8;
        return .{ .stack = .{ .offset = offset } };
    }
};
```

## Implementation Checklist

1. **Data Structures**
   - [ ] ValState with all fields
   - [ ] RegState with all fields
   - [ ] Use linked list with distance
   - [ ] DesiredState for hints

2. **Liveness Analysis**
   - [ ] Stage 1: Basic backward analysis
   - [ ] Stage 2: Distance computation
   - [ ] Stage 3: Loop propagation

3. **Block Allocation**
   - [ ] initBlockState from predecessors
   - [ ] freeDeadValues for each value
   - [ ] allocInput with constraint checking
   - [ ] allocOutput with constraint checking
   - [ ] Handle clobbers
   - [ ] saveBlockEndState

4. **Spilling**
   - [ ] chooseSpill with farthest-next-use
   - [ ] spillReg creating StoreReg
   - [ ] placeSpills using dominators
   - [ ] insertRestore with LoadReg

5. **Edge Fixup**
   - [ ] Detect differences between blocks
   - [ ] Generate move list
   - [ ] Execute moves with cycle breaking

6. **Register Hints**
   - [ ] computeDesired backward pass
   - [ ] Propagate through result_in_arg0
   - [ ] Handle commutative ops

## Testing Strategy

```zig
test "regalloc: simple allocation" {
    // Build: x = 1; y = 2; return x + y
    var f = buildSimpleFunc();
    regalloc(&f);

    // Verify: all values have locations
    for (f.values) |v| {
        try expect(f.reg_alloc[v.id] != .none);
    }
}

test "regalloc: spilling required" {
    // Build function that uses all registers
    var f = buildRegisterPressureFunc();
    regalloc(&f);

    // Verify: spills were inserted
    var spill_count: usize = 0;
    for (f.values) |v| {
        if (v.op == .store_reg) spill_count += 1;
    }
    try expect(spill_count > 0);
}

test "regalloc: edge fixup" {
    // Build: if (cond) { x = 1 } else { x = 2 }; return x
    var f = buildDiamondCFG();
    regalloc(&f);

    // Verify: phi resolved correctly
    // x should be in same register after both branches
}

test "regalloc: cycle in shuffle" {
    // Build case where x->y and y->x simultaneously
    var f = buildCyclicSwap();
    regalloc(&f);

    // Verify: cycle broken with temp
}
```

## Common Bugs and Fixes

### Bug 1: Forgetting to decrement uses

```zig
// WRONG
fn removeArg(v: *Value, idx: usize) void {
    v.args[idx] = v.args[v.args.len - 1];
    v.args.len -= 1;
}

// CORRECT
fn removeArg(v: *Value, idx: usize) void {
    v.args[idx].uses -= 1;  // CRITICAL!
    v.args[idx] = v.args[v.args.len - 1];
    v.args.len -= 1;
}
```

### Bug 2: Not handling result_in_arg0

```zig
// WRONG: Allocate output independently
fn allocOutput(state: *State, v: *Value, mask: RegMask) void {
    const reg = findFreeReg(mask);
    // ...
}

// CORRECT: Check if output must share with arg0
fn allocOutput(state: *State, v: *Value, mask: RegMask) void {
    if (v.op.info().result_in_arg0) {
        // Output MUST be in same register as arg[0]
        const arg0_reg = state.values[v.args[0].id].regs.firstSet();
        // Use that register for output
    } else {
        const reg = findFreeReg(mask);
        // ...
    }
}
```

### Bug 3: Clobbering live values

```zig
// WRONG: Emit instruction then handle clobbers
fn emitCall(state: *State, v: *Value) void {
    emitInstruction(v);
    for (caller_saved) |reg| {
        state.regs[reg].v = null;
    }
}

// CORRECT: Spill clobbers BEFORE emitting
fn emitCall(state: *State, v: *Value) void {
    // Spill all caller-saved registers that hold live values
    for (caller_saved) |reg| {
        if (state.regs[reg].v) |live_v| {
            if (state.values[live_v.id].uses > 0) {
                spillReg(state, reg);
            }
        }
    }
    emitInstruction(v);
    // Now safe to clear
    for (caller_saved) |reg| {
        state.regs[reg].v = null;
    }
}
```

This document provides the complete algorithm and implementation details needed to replicate Go's register allocator exactly.

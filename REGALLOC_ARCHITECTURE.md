# Register Allocator Architecture - Go's Approach

Based on deep study of Go's `cmd/compile/internal/ssa/regalloc.go`.

## The Problem with Our Current Approach

We've been playing whack-a-mole because we're missing fundamental architectural patterns from Go:

1. **No explicit edge state tracking** - Go saves `endRegs[b.ID]` after each block
2. **No merge edge fixup phase** - Go has a dedicated shuffle phase
3. **Phi handling is naive** - Go uses 3-pass approach with predecessor analysis
4. **Values array not persistent** - Our register assignments get lost between blocks

## Go's Architecture (Simplified)

```
Phase 1: INITIALIZATION
  - Compute liveness (use distances)
  - Compute desired registers (hints)
  - Establish block visit order

Phase 2: LINEAR ALLOCATION (per block)
  - For single-pred blocks: copy predecessor's endRegs
  - For merge blocks: pick best predecessor, use its endRegs
  - Process values: greedy allocation with farthest-next-use spilling
  - Save endRegs[b.ID] and startRegs[b.ID] (for merge blocks)

Phase 3: SPILL PLACEMENT
  - Walk dominator tree
  - Place spills optimally (outside loops when possible)

Phase 4: SHUFFLE (merge edge fixup)
  - For each merge edge: generate moves to fix register mismatches
  - Uses parallel copy algorithm with cycle breaking

Phase 5: CLEANUP
  - Delete unused copies
```

## Key Data Structures We Need

### 1. `endRegs[block.ID]` - Register state at block end
```zig
const EndReg = struct {
    reg: RegNum,      // Which register
    v: *Value,        // Pre-regalloc value
    c: *Value,        // Post-regalloc copy (may equal v)
};

end_regs: std.AutoHashMap(ID, []EndReg),
```

### 2. `startRegs[block.ID]` - Required registers at merge block start
```zig
const StartReg = struct {
    reg: RegNum,      // Which register needed
    v: *Value,        // What value should be there
};

start_regs: std.AutoHashMap(ID, []StartReg),
```

### 3. Per-value state (persistent across blocks)
```zig
const ValState = struct {
    regs: RegMask,           // Registers holding this value (PERSISTENT)
    spill: ?*Value,          // StoreReg instruction
    spill_used: bool,        // Whether spill was actually needed
    restore_min: i32,        // Dominator bounds for spill placement
    restore_max: i32,
    rematerializable: bool,  // Can recompute instead of reload?
};
```

## The Three-Pass Phi Algorithm

```zig
// Pass 1: Try to reuse primary predecessor's register
for (phis) |phi| {
    const primary_arg = phi.args[primary_idx];
    const reg = values[primary_arg.id].firstReg();
    if (reg != null and !phi_used.isSet(reg)) {
        phi_regs[i] = reg;
        phi_used.set(reg);
    }
}

// Pass 2: For values live past phi, move to free register first
for (phis, phi_regs) |phi, reg| {
    if (reg == null) continue;
    const arg = phi.args[primary_idx];
    if (isLiveAfterPhi(arg)) {
        // Move arg to free register before deallocating
        const free_reg = findFreeReg();
        if (free_reg) |r| {
            emit copy arg -> r
        }
    }
    freeReg(reg);
}

// Pass 3: Look at other predecessors for consensus
for (phis, phi_regs) |phi, *reg| {
    if (reg.* != null) continue;
    for (other_predecessors) |pred| {
        const other_arg = phi.args[pred_idx];
        const other_reg = endRegs[pred.id].find(other_arg);
        if (other_reg and !phi_used.isSet(other_reg)) {
            reg.* = other_reg;
            break;
        }
    }
}
```

## The Shuffle Algorithm (Parallel Copy)

```zig
fn shuffle(edge: Edge, src_regs: []EndReg, dst_regs: []StartReg) void {
    // Setup: what's where, what needs to go where
    var contents: [NUM_REGS]?*Value = ...;  // Current register contents
    var dests: []Dest = ...;                 // Where values need to go

    // Process until all destinations satisfied
    while (dests.len > 0) {
        var progress = false;
        for (dests) |d| {
            if (tryMove(d)) {
                progress = true;
                remove d from dests;
            }
        }

        if (!progress) {
            // Cycle detected - break it
            // 1. Find a temporary register
            // 2. Move one cycle element to temp
            // 3. Now cycle is broken, continue
            breakCycle(dests[0]);
        }
    }
}

fn tryMove(d: Dest) bool {
    const src = findValue(d.value);
    if (src == d.reg) return true;  // Already there
    if (contents[d.reg] != null) return false;  // Blocked
    emit(mov d.reg, src);
    contents[d.reg] = d.value;
    return true;
}
```

## Recommended Implementation Order

### Step 1: Add endRegs/startRegs tracking
- After processing each block, save `endRegs[b.ID]`
- For merge blocks, save `startRegs[b.ID]`
- Don't clear `values[*].regs` between blocks

### Step 2: Implement proper phi handling
- Implement the 3-pass algorithm
- Consider all predecessors when choosing phi registers

### Step 3: Add shuffle phase
- After all blocks processed, fix merge edges
- Implement parallel copy with cycle breaking

### Step 4: Defer spill placement
- Create spills blockless during allocation
- Place optimally in separate pass

## Why This Matters

The current approach fails because:
1. **Loops**: Back edges mean we visit a block before all predecessors are processed
2. **Merge points**: Multiple paths mean register choices can conflict
3. **State loss**: Clearing state between blocks loses information codegen needs

Go's approach handles this by:
1. **Explicit state saving**: endRegs/startRegs capture the boundary state
2. **Deferred fixup**: shuffle phase handles mismatches after allocation
3. **Persistent values**: values[*].regs survives across all blocks

## Success Criteria

A correct register allocator should:
1. Never assign two live values to the same register
2. Preserve values across calls (spill/reload)
3. Handle phi values correctly at merge points
4. Generate correct parallel copies for edge fixup
5. Place spills optimally (outside loops)

## References

- Go source: `~/learning/go/src/cmd/compile/internal/ssa/regalloc.go`
- Our current impl: `src/ssa/regalloc.zig`
- Test cases: `test/e2e/all_tests.cot` (fibonacci is the key test)

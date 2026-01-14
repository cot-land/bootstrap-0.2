# Register Allocation - Learning from Go

## What We Learned from Go's regalloc.go

### 1. Operation-Level Clobber Information

Each operation has a `regspec` with a `clobbers` field (regMask) indicating which registers are destroyed:

```go
// ARM64Ops.go
callerSave = gp | fp | buildReg("g")  // R0-R26 + FP registers
{name: "CALLstatic", reg: regInfo{clobbers: callerSave}, call: true}
```

**Key insight:** Call instructions explicitly declare they destroy all caller-saved registers.

### 2. nextCall[] Tracking

Before processing a block, Go builds `nextCall[i]` for each instruction:

```go
// regalloc.go:1053-1082
var nextCall int32 = math.MaxInt32
for i := len(b.Values) - 1; i >= 0; i-- {
    v := b.Values[i]
    if opcodeTable[v.Op].call {
        // Function call clobbers all registers but SP and SB
        regValLiveSet.clear()
        nextCall = int32(i)
    }
    s.nextCall[i] = nextCall
}
```

This tells regalloc: "for instruction i, the next call is at index nextCall[i]".

### 3. advanceUses / dropIfUnused

When processing an instruction, Go checks if a value's next use is **after** the next call:

```go
// regalloc.go:882-884
if r.next == nil || r.next.dist > s.nextCall[s.curIdx] {
    // Value is dead (or not used again until after a call)
    s.freeRegs(ai.regs)  // FREE THE REGISTERS!
}
```

**Key insight:** Values whose next use is after a call get their registers freed immediately. They'll be spilled and reloaded.

### 4. Spill/Reload Mechanism

When a value is needed but not in a register:

```go
// regalloc.go:638-644
} else {
    // Load v from its spill location
    spill := s.makeSpill(v, s.curBlock)
    c = s.curBlock.NewValue1(pos, OpLoadReg, v.Type, spill)
}
```

- `OpStoreReg` = spill to stack
- `OpLoadReg` = reload from stack
- Spills are created lazily when first needed
- `placeSpills()` determines optimal placement after allocation

### 5. freeRegs(regspec.clobbers)

At each instruction that clobbers registers:

```go
// regalloc.go:1833
s.freeRegs(regspec.clobbers)
```

---

## What We Got Wrong

Our implementation had these flaws:

1. **No clobbers field on operations** - we don't mark which registers calls destroy
2. **No nextCall tracking** - we don't know where calls are
3. **No spill/reload mechanism** - we don't have StoreReg/LoadReg ops
4. **Conflicting allocation strategies** - regalloc and codegen both assign registers

---

## The Fix: Two Options

### Option A: Full Go-style Spill/Reload (Complex)

1. Add `clobbers: regMask` to Op definitions
2. Mark call ops with `clobbers = CALLER_SAVED`
3. Add `nextCall[]` tracking to liveness analysis
4. Implement `advanceUses` to free registers at calls
5. Add `OpStoreReg`/`OpLoadReg` operations
6. Implement lazy spill creation and `placeSpills()`

**Pros:** Handles any number of live values across calls
**Cons:** Complex, many moving parts

### Option B: Callee-Saved Only for Cross-Call Values (Simpler)

1. Add `clobbers: regMask` to Op definitions
2. During liveness, identify values that live across calls
3. Force those values into callee-saved registers (x19-x28)
4. If more than 10 values live across calls, error (or spill to stack)

**Pros:** Simpler, no spill/reload infrastructure
**Cons:** Limited to 10 values across calls (usually enough)

---

## Recommended Approach: Option A - Full Implementation

Option B would fail for a self-hosting compiler. We need proper spill/reload.

---

## Implementation Plan

### Phase 1: Add Infrastructure to Op Definitions

**File: `src/ssa/op.zig`**

```zig
pub const RegMask = u64;

// ARM64 register masks
pub const CALLER_SAVED: RegMask = 0x07FFFF;  // R0-R18 (minus platform reg)
pub const CALLEE_SAVED: RegMask = 0x1FF80000; // R19-R28
pub const ALL_REGS: RegMask = CALLER_SAVED | CALLEE_SAVED;

pub const OpInfo = struct {
    name: []const u8,
    arg_count: i8 = 0,      // -1 = variadic
    has_aux: bool = false,
    clobbers: RegMask = 0,  // Registers destroyed by this op
    is_call: bool = false,  // Is this a call instruction?
};

// Update op table:
.static_call = .{
    .name = "static_call",
    .arg_count = -1,
    .has_aux = true,
    .clobbers = CALLER_SAVED,
    .is_call = true,
},
```

### Phase 2: Add Spill/Reload Operations

**File: `src/ssa/op.zig`**

```zig
// New ops for spill/reload
.store_reg = .{ .name = "store_reg", .arg_count = 1 },  // Spill to stack
.load_reg = .{ .name = "load_reg", .arg_count = 1 },    // Reload from stack
```

### Phase 3: Track nextCall[] in Liveness

**File: `src/ssa/liveness.zig`**

Add to LivenessInfo:
```zig
pub const LivenessInfo = struct {
    // ... existing fields ...

    /// For each instruction index, the index of the next call at or after it.
    /// MaxInt if no call follows.
    next_call: []u32,
};

/// Build nextCall array for a block (process backwards)
fn buildNextCall(block: *Block, allocator: Allocator) ![]u32 {
    var next_call = try allocator.alloc(u32, block.values.items.len);
    var current: u32 = std.math.maxInt(u32);

    var i = block.values.items.len;
    while (i > 0) {
        i -= 1;
        const v = block.values.items[i];
        if (op_info[v.op].is_call) {
            current = @intCast(i);
        }
        next_call[i] = current;
    }
    return next_call;
}
```

### Phase 4: Rewrite Register Allocator

**File: `src/ssa/regalloc.zig`**

Core changes:
1. Track which register holds each value: `regs: [32]?*Value`
2. Track which registers hold each value: `values: []ValState`
3. When value's next use is after nextCall, free its registers
4. When value needed but not in register, create LoadReg from spill
5. Create StoreReg lazily when value first gets evicted

```zig
pub const ValState = struct {
    regs: RegMask = 0,           // Which registers hold this value
    spill: ?*Value = null,       // Spill value (StoreReg) if created
    uses: ?*UseList = null,      // List of uses with distances
};

pub const RegAllocState = struct {
    allocator: Allocator,
    func: *Func,

    // Current state of each register
    regs: [32]RegState,

    // State for each value
    values: []ValState,

    // Which registers are currently in use
    used: RegMask,

    // nextCall[i] = index of next call at or after instruction i
    next_call: []u32,

    // Current instruction index
    cur_idx: usize,
};

/// Free registers for values whose next use is after the next call
fn advanceUses(self: *RegAllocState, v: *Value) void {
    for (v.args) |arg| {
        const vi = &self.values[arg.id];
        // If next use is after next call, free the registers
        if (vi.uses) |uses| {
            if (uses.next == null or uses.next.?.dist > self.next_call[self.cur_idx]) {
                self.freeRegs(vi.regs);
            }
        }
    }
}

/// Get value into a register, spilling/reloading if necessary
fn allocValToReg(self: *RegAllocState, v: *Value, mask: RegMask) *Value {
    const vi = &self.values[v.id];

    // Already in an acceptable register?
    if (vi.regs & mask != 0) {
        return self.regs[pickReg(vi.regs & mask)].c;
    }

    // Allocate a register (may evict something)
    const r = self.allocReg(mask, v);

    // Get value into the register
    if (vi.regs != 0) {
        // Copy from another register
        const src_reg = pickReg(vi.regs);
        const copy = self.func.newValue(.copy, v.typ);
        copy.args = &[_]*Value{self.regs[src_reg].c};
        self.assignReg(r, v, copy);
        return copy;
    } else {
        // Load from spill location
        const spill = self.makeSpill(v);
        const load = self.func.newValue(.load_reg, v.typ);
        load.args = &[_]*Value{spill};
        self.assignReg(r, v, load);
        return load;
    }
}

/// Create a spill for value v (lazily, first time it's needed)
fn makeSpill(self: *RegAllocState, v: *Value) *Value {
    const vi = &self.values[v.id];
    if (vi.spill) |spill| {
        return spill;
    }
    // Create StoreReg - we'll place it later
    const spill = self.func.newValue(.store_reg, v.typ);
    // Arg will be set when we know where to place it
    vi.spill = spill;
    return spill;
}
```

### Phase 5: Place Spills After Allocation

After main allocation pass, determine optimal placement for each spill:
- Spill must dominate all its reloads
- Spill must be placed where value is still in a register
- Prefer placing outside loops

### Phase 6: Update Codegen

**File: `src/codegen/arm64.zig`**

1. Remove `value_regs` map entirely
2. Remove `allocateCalleeSaved` and secondary allocation
3. Only use `regalloc_state` for register assignments
4. Handle `store_reg` → emit store to stack slot
5. Handle `load_reg` → emit load from stack slot

---

## Files to Modify

| File | Changes |
|------|---------|
| `src/ssa/op.zig` | Add clobbers, is_call, store_reg, load_reg |
| `src/ssa/liveness.zig` | Add nextCall tracking |
| `src/ssa/regalloc.zig` | Full rewrite following Go's approach |
| `src/codegen/arm64.zig` | Remove secondary allocation, add spill/reload codegen |

---

## Success Criteria

1. Simple case: `mul(2,3); mul(6,6); return first_result` returns 6
2. Complex case: Fibonacci returns 55
3. Stress test: 20+ values live across calls (spills correctly)
4. All existing tests pass
5. Architecture supports self-hosting compiler complexity

---

## Implementation Order

1. [ ] Add RegMask type and ARM64 masks to op.zig
2. [ ] Add clobbers and is_call fields to OpInfo
3. [ ] Add store_reg and load_reg ops
4. [ ] Add nextCall tracking to liveness
5. [ ] Implement ValState and RegState structures
6. [ ] Implement allocReg with spill-on-evict
7. [ ] Implement allocValToReg with reload
8. [ ] Implement makeSpill (lazy spill creation)
9. [ ] Implement placeSpills (optimal spill placement)
10. [ ] Update codegen to handle store_reg/load_reg
11. [ ] Remove secondary allocation from codegen
12. [ ] Test and verify

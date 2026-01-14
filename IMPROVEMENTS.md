# Bootstrap 0.2 - Architecture Assessment

**Assessed: 2026-01-14**

This document provides an honest assessment of bootstrap-0.2's architecture compared to Go's compiler.

## Executive Summary

**Is the design solid?** YES. The SSA foundation correctly follows Go's architecture.

**Is the implementation complete?** NO. About 15% complete. The hardest parts are missing.

**Are we set up for success?** YES, IF we implement the missing pieces correctly by following Go's algorithms precisely.

---

## Part 1: What's Done Right

### 1.1 SSA Data Structures (CORRECT)

The core types match Go's design exactly:

| Our Type | Go Type | Status |
|----------|---------|--------|
| `Value` | `ssa.Value` | ✅ Correct |
| `Block` | `ssa.Block` | ✅ Correct |
| `Func` | `ssa.Func` | ✅ Correct |
| `Op` | `ssa.Op` | ✅ Correct |
| `ID` | dense u32 | ✅ Correct |
| `Edge` | bidirectional | ✅ Correct |

Key invariants are maintained:
- Use counting: incremented on addArg, decremented on resetArgs
- Bidirectional edges: `b.succs[i].b.preds[j] = b` where `j = b.succs[i].i`
- Constant caching: no duplicate const_int values

### 1.2 Pass Infrastructure (CORRECT)

The pass system follows Go's pattern:
- Pass registry with metadata
- Phase tracking
- Verification after passes
- Debug output options

### 1.3 Dominator Tree (CORRECT)

The iterative algorithm matches Go's simple dominator computation.

### 1.4 Testing Infrastructure (CORRECT)

- Table-driven tests
- Golden file tests
- Test helpers (TestFuncBuilder)
- Allocation counting

---

## Part 2: What's Missing

### 2.1 Register Allocator (CRITICAL - 0% complete)

Go's regalloc is **3,137 lines** implementing a 6-phase linear scan algorithm.
We have: 0 lines (documented in REGISTER_ALLOC.md, not implemented).

**Go's Algorithm (what we must implement):**

```
Phase 1: Initialization
  - Identify allocatable registers (exclude SP, SB, g, FP, LR)
  - Build block visit order (not control-flow order)
  - Mark values needing registers

Phase 2: Liveness Analysis
  - Compute use distances for each value
  - Distance = instructions until next use
  - Distances: likely=1, normal=10, unlikely=100 (across calls)

Phase 3: Desired Registers
  - Backward scan through values
  - Propagate register preferences
  - Handle two-operand constraints

Phase 4: Main Allocation Loop
  For each block in visit order:
    - Initialize from predecessor(s)
    - Process phis (register or stack)
    - For each value:
      - Allocate input registers
      - If register needed but none free: SPILL
      - Spill selection: value with FARTHEST next use
      - Allocate output register
      - Free clobbered registers
    - Save end state

Phase 5: Spill Placement
  - Walk dominator tree
  - Place spill where it dominates all restores
  - Prefer shallow loop nesting

Phase 6: Merge Edge Fixup
  - For edges to blocks with >1 predecessor
  - Generate moves (OpCopy, OpLoadReg, OpStoreReg)
  - Handle cycles with temporary registers
```

**Key Data Structures Needed:**

```zig
const ValState = struct {
    regs: RegMask,        // which registers hold this value
    uses: ?*Use,          // linked list of uses (sorted by distance DESC)
    spill: ?*Value,       // StoreReg if spilled
    needReg: bool,        // needs a register?
    rematerializeable: bool,  // can recompute instead of spill?
};

const RegState = struct {
    v: ?*Value,           // value in this register (original)
    c: ?*Value,           // current cached copy
};

const Use = struct {
    dist: i32,            // distance to this use
    pos: Pos,             // source position
    next: ?*Use,          // next use (increasing distance)
};
```

### 2.2 Lowering Pass (CRITICAL - 0% complete)

Converts generic ops to architecture-specific ops.

```
add v1, v2  →  arm64_add v1, v2
load v1     →  arm64_ldr v1
const 42    →  arm64_movz 42
```

Without this, we emit generic ops that don't map to real instructions.

### 2.3 Liveness Analysis (CRITICAL - 0% complete)

Required for regalloc spill selection and dead code elimination.

**Go's Algorithm:**
- Backward data flow analysis
- Track live values at each program point
- Compute distances to next use
- Handle loops (iterate to fixed point)

### 2.4 Instruction Emission (INCOMPLETE)

ARM64CodeGen has register definitions but no real instruction emission.
Every instruction is a placeholder: `try writer.writeAll("    add ...\n")`

### 2.5 Phi Insertion (MISSING)

Requires dominance frontier computation (not just dominator tree).
Without this, can't convert IR to proper SSA form.

### 2.6 Frontend (MISSING)

No lexer, parser, type checker, or IR-to-SSA conversion.
The SSA containers exist but have no way to populate them from source.

---

## Part 3: Implementation Order

Based on Go's architecture and dependencies:

### Phase 1: Complete SSA Pipeline (Current Focus)

1. **Liveness Analysis** - Required for everything else
   - File: `src/ssa/liveness.zig`
   - Go ref: `cmd/compile/internal/ssa/regalloc.go` lines 2833-3137
   - Test: verify use distances computed correctly

2. **Register Allocator** - The core algorithm
   - File: `src/ssa/regalloc.zig`
   - Go ref: `cmd/compile/internal/ssa/regalloc.go` (all 3,137 lines)
   - Test: verify correct register assignment, proper spilling

3. **Lowering Pass** - Generic to arch-specific
   - File: `src/ssa/passes/lower.zig`
   - Go ref: `cmd/compile/internal/ssa/lower.go`
   - Test: verify all generic ops lowered

4. **Instruction Emission** - Real ARM64 encoding
   - File: `src/codegen/arm64.zig` (complete it)
   - Go ref: `cmd/compile/internal/arm64/ssa.go`
   - Test: verify correct machine code bytes

### Phase 2: Frontend

5. **Lexer/Parser** - Only after Phase 1 works
6. **Type Checker**
7. **IR-to-SSA Conversion** - Including phi insertion

---

## Part 4: Why Previous Attempts Failed

### Bootstrap (first attempt) - MCValue Approach

Tried Zig's integrated codegen approach:
- Track value locations during emission
- No separate regalloc pass

**Why it failed:**
- Works for simple cases, breaks on complex code
- No global view of register pressure
- BUG-019, BUG-020, BUG-021 block self-hosting
- "Whack-a-mole" debugging: fix one bug, create another

### The Root Cause

Both previous attempts implemented codegen **without understanding Go's regalloc algorithm**:
- Guessed at spill selection (should be farthest-next-use)
- Didn't track use distances
- Didn't handle merge edges properly
- Didn't understand the 6-phase structure

---

## Part 5: How to Implement Correctly

### The Key Insight

Go's regalloc works because of **use distance tracking**:

```
v1 = const 1      ; use distance = 5 (used at instruction 5)
v2 = const 2      ; use distance = 2 (used at instruction 2)
v3 = add v1, v2   ; v2 used here
v4 = mul v3, 10   ;
v5 = sub v4, v1   ; v1 used here (distance was 5)
```

When we need to spill at instruction 3 and only have 2 registers:
- v1 has distance 2 (next use at 5, we're at 3)
- v3 has distance 1 (next use at 4, we're at 3)
- **Spill v1** because it has the FARTHEST next use

This is provably optimal for single-use values.

### Implementation Checklist

Before implementing regalloc:

- [ ] Understand the 6 phases completely
- [ ] Implement ValState with use chains
- [ ] Implement RegState tracking
- [ ] Implement distance computation
- [ ] Write tests for:
  - [ ] Use distance calculation
  - [ ] Spill selection (farthest wins)
  - [ ] Merge edge fixup
  - [ ] Two-operand constraints

---

## Part 6: Success Criteria

Bootstrap-0.2 succeeds when:

1. **Regalloc produces correct output** - Not just "tests pass" but invariants hold:
   - Every value either in register or on stack
   - No register conflicts
   - Spills dominate restores
   - Use distances never increase within a block

2. **Lowering is complete** - Every generic op maps to arch-specific op

3. **Instruction emission works** - Real machine code, not placeholders

4. **Self-hosting works** - Compiler compiles itself without crashes

---

## Part 7: What NOT to Do

1. **Don't implement MCValue** - This was tried and failed
2. **Don't guess at register contents** - Track explicitly
3. **Don't skip liveness analysis** - Required for correct spilling
4. **Don't implement frontend first** - Backend must work first
5. **Don't debug symptoms** - Understand the algorithm

---

## Conclusion

**The design is correct.** Bootstrap-0.2's SSA foundation follows Go exactly.

**The implementation is incomplete.** The hard parts (regalloc, lowering, liveness) are missing.

**We ARE set up for success IF:**
- We implement Go's regalloc algorithm faithfully (all 6 phases)
- We don't cut corners on liveness analysis
- We test invariants, not just outputs
- We understand WHY Go's approach works before implementing

The third time can be the last time - but only if we do the hard work of understanding the algorithm before writing code.

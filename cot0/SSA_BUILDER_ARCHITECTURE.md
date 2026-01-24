# SSA Builder Architecture: Zig vs cot0

## Critical Finding

**cot0's SSA builder does NOT match Zig's architecture for parameter handling.**

This document details the Zig implementation and provides a granular task list for cot0 to match it exactly.

---

## Part 1: Zig's 3-Phase Parameter Handling

### Location
`src/frontend/ssa_builder.zig` lines 111-242

### Why 3 Phases?

The 3-phase approach exists because:
1. **ARM64 ABI uses x0-x7 for first 8 arguments** - these are caller-saved registers
2. **Any operation that produces a result may clobber x0-x7** - including slice_make, which is generated for string params
3. **If we interleave Arg ops with other ops, register values can be lost**

### BUG-010 in Zig (Fixed)

Zig had this exact bug. The old code:
```
for each param:
    if param is string:
        create arg for ptr (x0)
        create arg for len (x1)
        create slice_make    <-- THIS CLOBBERED x2 BEFORE NEXT ARG!
    else:
        create arg
    create store
```

When a function had `(s: string, pool: i64)`:
- arg0 = x0 (string ptr)
- arg1 = x1 (string len)
- slice_make emitted → could clobber x2
- arg2 = x2 (pool) → BUT x2 was already clobbered!

### Zig's 3-Phase Solution

**Phase 1: Create ALL Arg ops FIRST**
```zig
var phys_reg_idx: i32 = 0;  // Physical register index

for (ir_func.locals, 0..) |local, i| {
    if (local.is_param) {
        if (local.type_idx == TypeRegistry.STRING) {
            // String: TWO registers
            const ptr_val = func.newValue(.arg, TypeRegistry.I64, entry);
            ptr_val.aux_int = phys_reg_idx;
            entry.addValue(ptr_val);
            phys_reg_idx += 1;

            const len_val = func.newValue(.arg, TypeRegistry.I64, entry);
            len_val.aux_int = phys_reg_idx;
            entry.addValue(len_val);
            phys_reg_idx += 1;

            // Save for Phase 2 - DO NOT create slice_make yet!
            string_params.append(.{ .ptr = ptr_val, .len = len_val, .idx = i });
        } else {
            // Regular: ONE register
            const param_val = func.newValue(.arg, arg_type, entry);
            param_val.aux_int = phys_reg_idx;
            entry.addValue(param_val);
            phys_reg_idx += 1;

            param_values.append(param_val);
            param_indices.append(i);
        }
    }
}
```

**Phase 2: Create slice_make ops for string params (AFTER all args captured)**
```zig
for (string_params.items) |sp| {
    const string_val = func.newValue(.slice_make, TypeRegistry.STRING, entry);
    string_val.addArg2(sp.ptr, sp.len);
    entry.addValue(string_val);

    param_values.append(string_val);
    param_indices.append(sp.idx);
}
```

**Phase 3: Store all params to stack slots**
```zig
for (param_values.items, param_indices.items) |param_val, local_idx| {
    const local = ir_func.locals[local_idx];

    if (local.type_idx == TypeRegistry.STRING) {
        // String: store ptr and len separately
        const ptr_val = param_val.args[0];
        const len_val = param_val.args[1];

        // Store ptr at offset 0
        const addr_ptr = func.newValue(.local_addr, entry);
        addr_ptr.aux_int = local_idx;
        entry.addValue(addr_ptr);

        const store_ptr = func.newValue(.store, entry);
        store_ptr.addArg2(addr_ptr, ptr_val);
        entry.addValue(store_ptr);

        // Store len at offset 8
        const addr_len = func.newValue(.off_ptr, entry);
        addr_len.aux_int = 8;
        addr_len.addArg(addr_ptr);
        entry.addValue(addr_len);

        const store_len = func.newValue(.store, entry);
        store_len.addArg2(addr_len, len_val);
        entry.addValue(store_len);
    } else {
        // Regular param: single store
        const addr_val = func.newValue(.local_addr, entry);
        addr_val.aux_int = local_idx;
        entry.addValue(addr_val);

        const store_val = func.newValue(.store, entry);
        store_val.addArg2(addr_val, param_val);
        entry.addValue(store_val);
    }
}
```

### Key Design Decisions in Zig

1. **`phys_reg_idx` tracks physical register index** - separate from logical param index
   - String params consume 2 physical registers but are 1 logical param
   - `param_val.aux_int = phys_reg_idx` stores the ABI register index

2. **Temporary collections** - `param_values`, `param_indices`, `string_params`
   - These track params across phases
   - `param_values` holds the actual Value* to store
   - `param_indices` holds the local index for stack slot address

3. **Large struct handling** (>16B) - passed by reference
   - Creates Arg with type I64 (pointer)
   - Phase 3 uses OpMove to copy from source pointer to local

4. **Block ownership** - values are explicitly added to entry block
   - `func.newValue(.arg, type, entry)` - creates value associated with block
   - `entry.addValue(allocator, value)` - adds to block's value list

---

## Part 2: cot0's Current Implementation

### Location
`cot0/ssa/builder.cot` lines 931-958

### What cot0 Does (WRONG)

```cot
// Step 4: Store parameters to stack (BUG-049 fix)
var param_local_idx: i64 = 0;
while param_local_idx < b.func.locals_count {
    let param_local: *Local = Func_getLocal(b.func, param_local_idx);
    if param_local.is_param {
        // 1. Create Arg value
        let arg_val: *Value = Func_newValue(b.func, Op.Arg, TYPE_I64);
        arg_val.aux_int = param_local.param_idx;
        if param_local.param_idx < 8 {
            arg_val.reg = X0 + param_local.param_idx;
        }

        // 2. Create LocalAddr value
        let addr_val: *Value = Func_newValue(b.func, Op.LocalAddr, TYPE_I64);
        addr_val.aux_int = param_local_idx;

        // 3. Store Arg to stack slot
        let store_val: *Value = Func_newValue(b.func, Op.Store, TYPE_VOID);
        Value_addArg2(store_val, addr_val, arg_val);
    }
    param_local_idx = param_local_idx + 1;
}
```

### Problems

| Issue | Zig | cot0 |
|-------|-----|------|
| **Ordering** | ALL Args first, then slice_make, then stores | Interleaved: Arg→LocalAddr→Store for each param |
| **Physical vs logical index** | `phys_reg_idx` tracks ABI register | Uses `param_local.param_idx` directly |
| **String params** | Two Args + slice_make later | Not handled (no slice type yet) |
| **Large structs (>16B)** | Arg as I64 (ptr) + OpMove | Not handled |
| **Block value tracking** | Explicit `entry.addValue()` | Implicit via `Func_newValue()` |

### Result of cot0's Approach

For a function `fn foo(a: i64, b: i64, c: i64)`:

**cot0 emits:**
```
v0 = Arg(0)      // param 0
v1 = LocalAddr   // param 0 slot
v2 = Store v1, v0
v3 = Arg(1)      // param 1
v4 = LocalAddr   // param 1 slot
v5 = Store v4, v3
v6 = Arg(2)      // param 2
v7 = LocalAddr   // param 2 slot
v8 = Store v7, v6
```

**Zig emits:**
```
v0 = Arg(0)      // ALL Args first
v1 = Arg(1)
v2 = Arg(2)
v3 = LocalAddr   // Then LocalAddr+Store
v4 = Store v3, v0
v5 = LocalAddr
v6 = Store v5, v1
v7 = LocalAddr
v8 = Store v7, v2
```

**Why this matters:**
- In cot0's ordering, if LocalAddr or Store somehow clobbers a register, subsequent Arg values could get wrong data
- For 9+ args (stack-passed), the interleaving is even more problematic
- Register allocation sees values in different order, affecting spill decisions

---

## Part 3: Granular Task List for cot0

### Task 1: Add `phys_reg_idx` tracking

**File:** `cot0/ssa/builder.cot`

**Current:**
```cot
arg_val.aux_int = param_local.param_idx;
```

**Required:**
- Add `var phys_reg_idx: i64 = 0;` before param loop
- Use `arg_val.aux_int = phys_reg_idx;`
- Increment after each Arg created (not each param)
- For string params: increment twice (ptr + len)

### Task 2: Create temporary arrays for phase separation

**File:** `cot0/ssa/builder.cot`

**Required:**
- Add `var arg_values: [64]*Value;` - holds Arg values from Phase 1
- Add `var arg_local_indices: [64]i64;` - holds local indices for Phase 3
- Add `var arg_count: i64 = 0;`

### Task 3: Implement Phase 1 - Create ALL Arg ops first

**File:** `cot0/ssa/builder.cot`

**Required:**
```cot
// Phase 1: Create ALL Arg ops first
var phys_reg_idx: i64 = 0;
var param_local_idx: i64 = 0;
while param_local_idx < b.func.locals_count {
    let param_local: *Local = Func_getLocal(b.func, param_local_idx);
    if param_local.is_param {
        let arg_val: *Value = Func_newValue(b.func, Op.Arg, TYPE_I64);
        arg_val.aux_int = phys_reg_idx;
        if phys_reg_idx < 8 {
            arg_val.reg = X0 + phys_reg_idx;
        }
        // Stack args (phys_reg_idx >= 8) get reg=-1, will be assigned by regalloc

        arg_values[arg_count] = arg_val;
        arg_local_indices[arg_count] = param_local_idx;
        arg_count = arg_count + 1;
        phys_reg_idx = phys_reg_idx + 1;
    }
    param_local_idx = param_local_idx + 1;
}
```

### Task 4: Implement Phase 3 - Store all params to stack

**File:** `cot0/ssa/builder.cot`

**Required:**
```cot
// Phase 3: Store all params to stack
var i: i64 = 0;
while i < arg_count {
    let arg_val: *Value = arg_values[i];
    let local_idx: i64 = arg_local_indices[i];

    let addr_val: *Value = Func_newValue(b.func, Op.LocalAddr, TYPE_I64);
    addr_val.aux_int = local_idx;

    let store_val: *Value = Func_newValue(b.func, Op.Store, TYPE_VOID);
    Value_addArg2(store_val, addr_val, arg_val);

    i = i + 1;
}
```

### Task 5: Update regalloc for stack Args (param_idx >= 8)

**File:** `cot0/ssa/regalloc.cot`

**Current issue:** `Value_needsReg(Op.Arg)` returned false, so stack args never got registers

**Required:**
- Ensure `Value_needsReg(Op.Arg)` returns true
- In `RegAlloc_processValue`, check if `v.reg >= 0` before allocating new register
  - Pre-assigned registers (params 0-7) keep their register
  - Unassigned registers (params 8+) get allocated

### Task 6: Update codegen for stack Arg loading

**File:** `cot0/codegen/genssa.cot`

**Current:** Uses `encode_ldr(dest_reg, FP, byte_offset)` with wrong offset calculation

**Required:**
- Stack args at `[FP + frame_size + (arg_idx - 8) * 8]`
- Check Zig's arm64.zig:1842: `const byte_offset = self.frame_size + (arg_idx - 8) * 8;`
- cot0's GenState needs access to frame_size (currently only in stackalloc)

### Task 7: Future - String parameter support

**File:** `cot0/ssa/builder.cot`

**Required when strings are added:**
- Detect string params by type
- Create TWO Arg ops (ptr, len)
- Track in separate list for Phase 2
- Phase 2: Create SliceMake ops
- Phase 3: Store ptr at offset 0, len at offset 8

### Task 8: Future - Large struct support (>16B)

**File:** `cot0/ssa/builder.cot`

**Required when needed:**
- Detect large structs (>16B)
- Create Arg with type I64 (pointer to source)
- Phase 3: Use OpMove instead of Store to copy struct

---

## Part 4: Testing Requirements

### Test Case 1: 9 arguments
```cot
fn get9th(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64, i: i64) i64 {
    return i;  // 9th arg is on stack
}

fn main() i64 {
    return get9th(1, 2, 3, 4, 5, 6, 7, 8, 9);  // Should return 9
}
```

### Test Case 2: 10+ arguments
```cot
fn sum10(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64, i: i64, j: i64) i64 {
    return a + b + c + d + e + f + g + h + i + j;
}

fn main() i64 {
    return sum10(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);  // Should return 55
}
```

### Test Case 3: Verify ordering doesn't matter
```cot
fn test_order(a: i64, b: i64, c: i64) i64 {
    // Use params in different order than declared
    return c + a + b;
}

fn main() i64 {
    return test_order(100, 20, 3);  // Should return 123
}
```

---

## Part 5: Verification Checklist

After implementing, verify:

- [ ] `phys_reg_idx` used instead of `param_local.param_idx`
- [ ] All Arg ops emitted before any LocalAddr/Store
- [ ] Stack args (idx >= 8) have `reg = -1` initially
- [ ] Regalloc assigns registers to stack args
- [ ] Codegen loads stack args from correct offset
- [ ] 9-arg test passes
- [ ] 10-arg test passes
- [ ] Existing tests still pass

---

## Summary

cot0's SSA builder interleaves Arg→LocalAddr→Store for each param. Zig separates into 3 phases. This is a fundamental architectural difference that must be fixed for correctness with:
- 9+ arguments (stack-passed parameters)
- String parameters (multi-register)
- Large structs (pass-by-reference)

The fix requires restructuring `SSABuilder_build()` Step 4 to match Zig's Phase 1-2-3 pattern.

---

## Part 6: Additional Issues Found (2026-01-24)

During debugging, additional issues were discovered beyond the SSA builder architecture:

### Issue A: Callee - Stack Arg Loads into XZR (Zero Register)

**Symptom:** Disassembly shows `ldr xzr, [sp, #0x70]` - loading into zero register

**Location:** `cot0/codegen/genssa.cot` Op.Arg handling

**Root Cause:** When `v.reg` is -1 (unassigned), `encode_ldr(v.reg, ...)` encodes register 31, which is XZR in load context.

**Analysis:**
```
; get9th disassembly shows:
ldr xzr, [sp, #0x70]   ; <-- WRONG: loading into zero register
```

**Fix Required:** Regalloc must assign a real register to stack Args before codegen.
- Task 5 (regalloc) should handle this, but verify `Value_needsReg(Op.Arg)` returns true
- Verify `RegAlloc_processValue` allocates a register when `v.reg == -1`

**Status:** ⚠️ Partially fixed (regalloc changes made, but still failing)

---

### Issue B: Caller - Wrong Value Stored to Stack for 9th Arg

**Symptom:** Disassembly shows caller stores x1 (value 10) to stack instead of 9th arg (90)

**Location:** `cot0/codegen/genssa.cot` GenState_call()

**Analysis from disassembly:**
```asm
; main() calling get9th(10, 20, 30, 40, 50, 60, 70, 80, 90):
mov x1, #0xa        ; x1 = 10 (1st arg value)
mov x2, #0x14       ; x2 = 20
mov x3, #0x1e       ; x3 = 30
mov x4, #0x28       ; x4 = 40
mov x5, #0x32       ; x5 = 50
mov x6, #0x3c       ; x6 = 60
mov x7, #0x46       ; x7 = 70
mov x8, #0x50       ; x8 = 80
sub sp, sp, #0x8    ; allocate stack for 9th arg
str x1, [sp]        ; <-- WRONG: stores x1 (10), not 9th arg (90)!
mov x0, x1          ; shuffle: x1 -> x0
mov x1, x2          ; shuffle: x2 -> x1
...
```

**Problems identified:**
1. Constants 10-80 loaded into x1-x8 instead of directly into x0-x7
2. The 9th constant (90) is **NEVER generated**
3. x1 (value 10) is stored to stack as "9th arg" - completely wrong
4. Then registers are shuffled x1→x0, x2→x1, etc. (wasteful)

**Root Cause:** The call argument handling in GenState_call has multiple bugs:
1. Register allocation for call arguments doesn't place them in x0-x7 directly
2. The 9th argument's SSA value isn't being generated/emitted
3. The code that stores stack args uses wrong source register

**Files to investigate:**
- `cot0/codegen/genssa.cot` - GenState_call() lines 1512-1700+
- `cot0/ssa/builder.cot` - How call arguments are constructed
- `cot0/frontend/lower.cot` - How call IR nodes are created

**Status:** ❌ NOT FIXED - Major issue

---

### Issue C: Caller - 9th Argument SSA Value Not Generated

**Symptom:** The constant `90` never appears in the disassembly

**Analysis:** When lowering `get9th(10, 20, 30, 40, 50, 60, 70, 80, 90)`:
- Constants 10-80 are generated (visible as MOVZ instructions)
- Constant 90 is missing entirely

**Possible causes:**
1. IR lowering doesn't create IR node for 9th argument
2. SSA builder doesn't convert 9th argument to SSA value
3. Regalloc doesn't process 9th argument
4. Codegen skips 9th argument

**Investigation needed:** Trace through the pipeline for call with 9 args

**Status:** ❌ NOT FIXED - Requires investigation

---

### Task 9: Fix caller-side stack argument emission

**File:** `cot0/codegen/genssa.cot`

**Required:**
1. Ensure ALL call arguments get SSA values with registers
2. For args 0-7: emit directly to x0-x7 (avoid intermediate registers)
3. For args 8+:
   - Generate the constant/value into a register
   - Store that register to stack at correct offset
4. Compare with Zig's `setupCallArgs` in `src/codegen/arm64.zig`

### Task 10: Verify IR lowering creates all call arguments

**File:** `cot0/frontend/lower.cot`

**Required:**
1. Check `lowerCall` or equivalent function
2. Ensure all arguments (including 9+) are lowered to IR nodes
3. Compare with Zig's call lowering

### Task 11: Verify SSA builder converts all call arguments

**File:** `cot0/ssa/builder.cot`

**Required:**
1. Check `SSABuilder_convertCall` or equivalent
2. Ensure all argument IR nodes are converted to SSA values
3. Arguments should be added to the Call value's args array

---

## Updated Verification Checklist

After implementing all fixes, verify:

**Callee (function receiving args):**
- [ ] `phys_reg_idx` used instead of `param_local.param_idx`
- [ ] All Arg ops emitted before any LocalAddr/Store (3-phase)
- [ ] Stack args (idx >= 8) have `reg = -1` initially
- [ ] Regalloc assigns real registers to stack args (not -1)
- [ ] Codegen loads stack args from correct SP-relative offset
- [ ] No `ldr xzr, ...` in disassembly (XZR = bug)

**Caller (function making call):**
- [ ] All 9 constants appear in disassembly (including 90)
- [ ] Args 0-7 loaded directly into x0-x7
- [ ] Arg 8 (9th) stored to stack with correct value
- [ ] Stack allocated before storing stack args
- [ ] Stack cleaned up after call returns

**Integration:**
- [ ] 9-arg test returns 90 (not crash, not wrong value)
- [ ] 10-arg test passes
- [ ] Existing tests still pass

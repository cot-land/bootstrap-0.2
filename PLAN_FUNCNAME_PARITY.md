# Plan: Func Name String Parity with Zig

**Goal:** Change cot1 from storing source positions (`func_name_start/func_name_len`) to storing actual string pointers, matching Zig's approach.

**Why this matters:**
1. Brings cot1 architecture in line with Zig
2. Eliminates the fragile source-position-to-string lookup
3. May fix BUG-063 symbol corruption as a side effect

## Current State (cot1)

```
lower.cot:
  call_node.func_name_start = func_name_start;  // Source position
  call_node.func_name_len = func_name_len;

builder.cot:
  call_val.aux_int = ir_node.func_name_start;   // Passed through
  call_val.aux_ptr = ir_node.func_name_len;

genssa.cot:
  (source + cs.func_name_start + ext_name_idx).*  // Lookup at codegen time
```

## Target State (match Zig)

```
lower.cot:
  call_node.func_name_ptr = copy_string(source, name_start, name_len);
  call_node.func_name_len = func_name_len;

builder.cot:
  call_val.aux_int = ir_node.func_name_ptr;     // Pointer to owned string
  call_val.aux_ptr = ir_node.func_name_len;

genssa.cot:
  (cs.func_name_ptr + ext_name_idx).*            // Direct string access
```

## Implementation Steps

### Step 1: Add string copy helper to lower.cot

```cot
fn copy_func_name(source: *u8, start: i64, len: i64) i64 {
    let buf: *u8 = malloc_u8(len + 1);
    var i: i64 = 0;
    while i < len {
        (buf + i).* = (source + start + i).*;
        i = i + 1;
    }
    (buf + len).* = 0;  // Null terminate
    return buf;  // Return as i64 pointer
}
```

### Step 2: Update ir.cot IRNode struct

Change semantic meaning:
- `func_name_start` → `func_name_ptr` (stores *u8 cast to i64)
- `func_name_len` stays the same

No struct change needed - just reinterpret the field.

### Step 3: Update lower.cot Lowerer_lowerCall

```cot
// Before:
call_node.func_name_start = func_name_start;

// After:
call_node.func_name_start = copy_func_name(l.source, func_name_start, func_name_len);
```

### Step 4: Update builder.cot (if needed)

SSA builder already passes through aux_int/aux_ptr. If we're just reinterpreting, no change needed.

### Step 5: Update genssa.cot lookups

All locations that do `(source + func_name_start)` need to change to `func_name_ptr`:

```cot
// Before (line 2737):
let call_char: *u8 = source + cs.func_name_start + name_i;

// After:
let call_char: *u8 = cs.func_name_start + name_i;  // func_name_start IS the pointer
```

Key locations in genssa.cot:
- Line 2737: Call site name comparison
- Line 2812: Nested call site comparison
- Line 2854: External symbol name copy
- Line 2970: Far call site comparison
- Line 2991: Far external symbol copy

### Step 6: Test

1. Build cot1-stage1: `./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1`
2. Run tests: `/tmp/cot1-stage1 test/bootstrap/all_tests.cot -o /tmp/bt.o && zig cc /tmp/bt.o runtime/cot_runtime.o -o /tmp/bt -lSystem && /tmp/bt`
3. Build cot1-stage2: `/tmp/cot1-stage1 stages/cot1/main.cot -o /tmp/cot1-stage2.o`
4. Link: `zig cc /tmp/cot1-stage2.o runtime/cot_runtime.o -o /tmp/cot1-stage2 -lSystem`
5. Verify no more symbol corruption

## Risk Assessment

**Low risk:**
- The change is mechanical - swap source lookup for direct pointer
- No algorithm changes, just data representation
- Can be tested incrementally

**Rollback:**
- If issues arise, revert to source positions
- Git makes this trivial

## Estimated Effort

Small change - affects ~10 lines in lower.cot, ~10 lines in genssa.cot.

## Decision

**Proceed with implementation** - this is a clean parity fix that improves architecture and may resolve BUG-063.

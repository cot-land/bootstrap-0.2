# Codegen Parity Analysis: Zig vs cot1

## Summary

This document analyzes the machine code differences between the Zig compiler and cot1 compiler outputs. The goal is to identify patterns that can be fixed in cot1 to achieve closer parity.

## Pattern 1: Frame Setup (Prologue)

**Zig (efficient)**:
```asm
stp x29, x30, [sp, #-0x20]!    ; Save frame pointer and link register, allocate 32 bytes
mov x29, sp                     ; Set frame pointer
```

**cot1 (inefficient)**:
```asm
stp x29, x30, [sp, #-0x10]!    ; Save frame pointer and link register, allocate 16 bytes
sub sp, sp, #0x20              ; Allocate additional 32 bytes separately
```

**Fix**: Combine frame save and stack allocation into single `stp` with pre-indexed addressing.
**Location**: `stages/cot1/codegen/genssa.cot` - function prologue generation

---

## Pattern 2: Unnecessary mov Before Return

**Zig (efficient)**:
```asm
add x0, x1, x2                  ; Result already in x0
ldp x29, x30, [sp], #0x20       ; Restore and return
ret
```

**cot1 (inefficient)**:
```asm
add x3, x1, x2                  ; Result in x3
mov x0, x3                      ; Extra mov to x0
add sp, sp, #0x20               ; Separate stack cleanup
ldp x29, x30, [sp], #0x10       ; Restore
ret
```

**Fix**: Generate arithmetic results directly into x0 when it's the return value.
**Location**: `stages/cot1/ssa/regalloc.cot` or `genssa.cot` - register allocation for return values

---

## Pattern 3: Redundant Address Calculations

**Zig (efficient)**:
```asm
str x0, [sp, #0x10]             ; Direct offset addressing
ldr x1, [sp, #0x10]
```

**cot1 (inefficient)**:
```asm
add x2, sp, #0x10               ; Calculate address into register
str x0, [sp, #0x10]             ; Store (address in x2 unused!)
add x4, sp, #0x10               ; Recalculate same address
ldr x4, [sp, #0x10]             ; Load (address in x4 unused!)
```

**Fix**: Don't emit `add xN, sp, #offset` when the next instruction uses direct `[sp, #offset]` anyway.
**Location**: `stages/cot1/codegen/genssa.cot` - local variable access

---

## Pattern 4: Excessive Register Usage

**Zig**: Reuses registers efficiently, typically x0-x3 for most operations
**cot1**: Uses many registers (x1 through x14+), rarely reusing them

Example in fib function:
- Zig: uses x0, x1, x2, x3
- cot1: uses x1-x14 and x16

**Fix**: Improve register allocator to reuse dead registers more aggressively.
**Location**: `stages/cot1/ssa/regalloc.cot`

---

## Pattern 5: Redundant mov Before Function Call

**Zig (efficient)**:
```asm
mov x0, #0xa                    ; Single arg setup
bl _fib
```

**cot1 (inefficient)**:
```asm
mov x1, #0xa                    ; First set x1 (why?)
mov x0, #0xa                    ; Then set x0 (actual arg)
bl _fib
```

**Fix**: Don't emit redundant register loads before calls.
**Location**: `stages/cot1/codegen/genssa.cot` - call argument setup

---

## Pattern 6: Frame Teardown (Epilogue)

**Zig (efficient)**:
```asm
ldp x29, x30, [sp], #0x20       ; Restore and deallocate in one instruction
ret
```

**cot1 (inefficient)**:
```asm
add sp, sp, #0x20               ; Deallocate stack separately
ldp x29, x30, [sp], #0x10       ; Restore
ret
```

**Fix**: Combine stack deallocation into `ldp` post-indexed addressing.
**Location**: `stages/cot1/codegen/genssa.cot` - function epilogue generation

---

## Pattern 7: Duplicate Epilogues

**cot1** emits the full epilogue sequence for each return statement, while these could potentially be merged with jumps to a common exit block.

---

## Semantic Differences (Bugs, not style)

### ty_010_u8: u8 Load/Store Size
- **Bug**: cot1 uses 64-bit `ldr/str` for u8 types instead of `ldrb/strb`
- **Impact**: Memory corruption with overlapping byte operations
- **Fix**: Check type size in load/store generation

### fn_024_ackermann: Nested Recursive Calls
- **Bug**: Inner recursive call result corrupted before outer call
- **Impact**: Wrong results for patterns like `f(x, f(y, z))`
- **Fix**: Likely need to spill/restore around nested calls

### cf_046/fn_048: Missing Short-Circuit Evaluation for `and`
- **Bug**: cot1 evaluates all operands of `and` before combining results
- **Zig pattern**: Short-circuit with branches after each operand
  ```asm
  ; Zig: check each condition, branch to fail if any is false
  bl _fn1
  cmp x0, #expected1
  cset x2, eq
  cbz x2, .fail        ; Short-circuit!
  bl _fn2
  cmp x0, #expected2
  cset x2, eq
  cbz x2, .fail        ; Short-circuit!
  ...
  ```
- **cot1 pattern**: Evaluate all, store in registers, AND together
  ```asm
  ; cot1: call all functions, store results in caller-saved regs, AND
  bl _fn1
  cset x4, eq          ; Store in x4 (caller-saved!)
  bl _fn2              ; x4 may be clobbered!
  cset x8, eq
  and x9, x4, x8       ; x4 may be garbage
  ```
- **Impact**: 4+ function calls in `and` chain with multi-branch functions fail
- **Fix**: Generate proper short-circuit branches for `and`/`or` operators
- **Location**: `stages/cot1/ssa/builder.cot` - logical AND/OR lowering

### Zig Bug: Global Initialization
- Zig doesn't apply initializers to global variables
- cot1 correctly initializes globals

### Zig Bug: Forward References in Struct Definitions
- Zig doesn't support `struct Node { next: *Node }` (self-referential)
- cot1 correctly handles forward references
- **Workaround**: Tests with self-referential structs fail on both (parity maintained)

### Zig Bug: Nested Anonymous Block Statements Skipped
- **File**: `var_032_nested_scope.cot`
- **Bug**: Zig compiler completely skips code inside nested anonymous blocks
- **Code**:
  ```cot
  fn main() i64 {
      var a: i64 = 1;
      {
          var b: i64 = 2;
          {
              var c: i64 = 3;
              a = a + b + c;  // This line is NOT generated by Zig!
          }
      }
      if a == 6 { return 0; }  // Zig returns 1 (wrong), cot1 returns 0 (correct)
      return 1;
  }
  ```
- **Zig disassembly**: Only generates `var a = 1` then immediately compares with 6
- **cot1 disassembly**: Correctly generates all assignments and the computation
- **Impact**: Any code inside anonymous blocks `{}` is silently ignored
- **Severity**: CRITICAL - silent code deletion

### Zig vs cot1: Parameter Mutability
- Zig treats function parameters as const
- cot1 allows reassignment to parameters
- **Workaround**: Use local variables in tests

### Test Issue: malloc_struct Not Exported
- Tests using `extern fn malloc_struct(...)` fail at link time
- Runtime has type-specific malloc functions generated by Zig compiler
- Both compilers fail these tests (parity maintained)
- **Fix needed**: Update tests to use malloc_sized(bytes) and cast

---

## Priority Order for Fixes

### cot1 Bugs (Correctness)
1. **ty_010_u8** - u8 load/store using 64-bit instructions
2. **fn_024_ackermann** - Nested recursive call corruption
3. **cf_046/fn_048** - Missing short-circuit evaluation for `and`/`or`

### cot1 Optimizations (Code Quality)
4. **Pattern 1 & 6** - Prologue/epilogue, easy wins
5. **Pattern 2** - Return value in x0
6. **Pattern 5** - Redundant mov before calls
7. **Pattern 3** - Address calculation
8. **Pattern 4** - Register allocation (harder)

### Zig Bugs (Workaround in tests)
- Global variable initialization - Use runtime initialization
- Parameter mutability - Copy to local vars

---

## Testing Command

```bash
# Compare disassembly for any test
./zig-out/bin/cot test.cot -o /tmp/zig_test 2>/dev/null
/tmp/cot1-stage1 test.cot -o /tmp/cot1_test.o >/dev/null 2>&1
diff <(objdump -d /tmp/zig_test.o) <(objdump -d /tmp/cot1_test.o)
```

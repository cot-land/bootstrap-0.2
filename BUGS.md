# Bug Tracking

## Quick Reference

```bash
# Run inline tests
./zig-out/bin/cot -test stages/cot1/main.cot -o /tmp/t && /tmp/t

# Build stage1
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1
```

---

## Open Bugs

### BUG-063: cot1 stage2 compilation issues (META-BUG - MULTIPLE ROOT CAUSES)

**Status:** CLOSED - split into separate bugs
**Priority:** N/A (see individual bugs)
**Discovered:** 2026-01-25

This bug became a catch-all for multiple different issues preventing stage2 from working. The root causes have been identified and tracked separately:

**Fixed sub-issues:**
1. Parser infinite loops on incomplete structs/blocks (fixed 2026-01-28)
2. AMD64: Callee-saved register clobbering in struct copies (fixed 2026-01-28, see commit 7405902)
3. String field initialization in struct literals - Zig compiler (fixed 2026-01-28)

**Remaining sub-issues (tracked separately):**
- BUG-073: ARM64 stage2 scanner hang - string field in struct literal return not preserved

---

### BUG-073: ARM64 stage2 scanner hang - control flow bug with >16B struct returns

**Status:** OPEN (partially fixed)
**Priority:** HIGH
**Discovered:** 2026-01-28
**Platform:** ARM64 (macOS)

Stage2 (compiled by stage1) hangs during Scanner_init when processing even the simplest source files.

**Partial fix applied (2026-01-28):**
- Fixed sp_adjust_for_call bug in genssa.cot - when loading SliceLen or LocalAddr during call argument setup, the stack offset wasn't adjusted for prior SP changes (hidden return allocation + arg stack space)
- This fix ensures `len(s.source)` returns correct value after Scanner_init

**Remaining issue:**
When an if-statement follows a function call returning >16B struct, the control flow is broken. The "then" block's code executes unconditionally because the conditional branch is placed AFTER the return instruction (dead code).

**Working tests:**
- `return len(s.source)` → returns 3 correctly
- `s.getSourceLen()` (method call) → returns 3 correctly

**Failing tests:**
- `if len(s.source) != 3 { return 1; } return 42;` → returns 1 (wrong)
- `if s.pos >= len(s.source) { return 1; } return 42;` → returns 1 (wrong)

**Disassembly shows:**
```asm
// Block 0: setup, call, copy result, cset condition
11c: mov x14, #1
120: mov x0, x14
124-12c: epilogue + ret   // UNCONDITIONAL RETURN!
130: cbz x13, 0x148      // Dead code - branch AFTER return
```

**Root cause:**
The SSA or codegen in stage1 is placing the Return value from the "then" block into block 0 instead of the correct block. This causes blockValues to emit the return code before blockControl emits the conditional branch.

**Symptoms:**
- Stage2 binary builds successfully (1.8MB)
- Stage2 prints "Phase 1: Scanning..." then hangs
- isAtEnd() always returns true because the if-statement control flow is broken

**Reproduction:**
```bash
# Build stage1
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1

# Build stage2
/tmp/cot1-stage1 stages/cot1/main.cot -o /tmp/s2.o
zig cc /tmp/s2.o runtime/cot_runtime.o -o /tmp/cot1-stage2 -lSystem

# Test with simplest file - HANGS
echo 'fn main() i64 { return 42; }' > /tmp/simple.cot
/tmp/cot1-stage2 /tmp/simple.cot -o /tmp/out.o
```

**Key code path:**
- `stages/cot1/frontend/scanner.cot` - Scanner_init function
- `stages/cot1/frontend/lower.cot` - lowerStructLitToLocal (string field handling)
- `stages/cot1/codegen/genssa.cot` - SlicePtr/SliceLen codegen

**Investigation notes:**
- Zig compiler correctly generates code for this pattern (all 754 tests pass)
- The issue is in cot1's codegen for ARM64 specifically
- May be related to how struct literal returns with string fields are lowered

---

### BUG-074: []u8 slice as function parameter causes segfault

**Status:** FIXED
**Priority:** MEDIUM
**Discovered:** 2026-01-29
**Fixed:** 2026-01-29
**Platform:** Both AMD64 and ARM64

Using `[]u8` as a function parameter type caused a segfault when the function was called. The `string` type (which is semantically the same as `[]u8`) worked correctly.

**Root cause:**
The expand_calls pass and ssa_builder only checked for `TypeRegistry.STRING` (type_idx 17) when decomposing slice/string arguments into ptr+len pairs. When `[]u8` was used, it created a new slice type with a different type_idx, which wasn't recognized as needing decomposition.

**Fix:**
1. `src/ssa/passes/expand_calls.zig`: Added check for general slice types (`type_reg.get(type_idx) == .slice`) in addition to STRING constant
2. `src/frontend/ssa_builder.zig`: Added same slice type detection for function parameter handling (Phase 1, 2, 3)
3. `stages/cot1/ssa/passes/expand_calls.cot`: Added `TypeInfo_isSlice()` check for slice type detection

**Reproduction:**
```cot
fn count_char(s: []u8, target: u8) i64 {
    var count: i64 = 0
    for c in s {
        if c == target { count = count + 1 }
    }
    return count
}

fn main() i64 {
    var arr: [11]u8 = ['m', 'i', 's', 's', 'i', 's', 's', 'i', 'p', 'p', 'i']
    let s: []u8 = arr[0:11]
    let result: i64 = count_char(s, 's')
    if result == 4 { return 42 }
    return result
}
```

**Verification:**
```bash
./zig-out/bin/cot /tmp/slice_bug.cot -o /tmp/sb.o
zig cc /tmp/sb.o runtime/cot_runtime_linux.o -o /tmp/sb
/tmp/sb  # Returns 42 (success)
```

---

### BUG-075: cot1 stage1 crashes on Linux - hardcoded Mach-O format

**Status:** PARTIALLY FIXED
**Priority:** HIGH
**Discovered:** 2026-01-29
**Platform:** Linux (AMD64)

cot1 stage1 compiler crashes when compiling any file on Linux because it's hardcoded to produce Mach-O object files (macOS format) instead of ELF (Linux format).

**Fixed issues:**
1. Added platform detection (`get_target_arch()`)
2. Added `finalize_elf()` function for AMD64/ELF
3. Fixed file open flags for Linux (O_CREAT=64, O_TRUNC=512 vs macOS values)
4. Fixed `buildShstrtab()` writing to wrong offset in output buffer
5. Increased buffer capacities (16MB output, 1MB strings, 100K relocations)

**Remaining issues (tracked separately):**
- BUG-076: ELF symbol names missing in .strtab
- BUG-077: Stage1 crashes on programs with global variables

---

### BUG-076: ELF symbol names missing in .strtab

**Status:** FIXED (workaround applied)
**Priority:** HIGH
**Discovered:** 2026-01-29
**Fixed:** 2026-01-29
**Platform:** Linux (AMD64)

Stage1-generated ELF files have empty symbol names. The .strtab section only contains the null byte.

**Root cause:**
Register clobbering bug in Zig compiler's AMD64 codegen. When accessing struct fields through a pointer (like `ir_func.name_len`), the loaded value gets clobbered by subsequent operations before it's used.

**Symptoms:**
- `readelf -s` shows symbol with empty name
- Linking fails: "undefined symbol: main"
- Adding print statements "fixes" the bug by forcing register spilling

**Workaround applied:**
Added `print("")` calls between struct field loads in `finalize_elf()` to force register state flush:
```cot
let func_name_start: i64 = ir_func.name_start;
print("");  // Force register state flush
let func_name_len: i64 = ir_func.name_len;
print("");  // Force register state flush
```

**Note:** This is a bug in the Zig compiler's AMD64 codegen, not in the cot1 code itself. The workaround ensures stage1 produces valid ELF files.

---

### BUG-077: Stage1 crashes on programs with global variables

**Status:** OPEN
**Priority:** HIGH
**Discovered:** 2026-01-29
**Platform:** Linux (AMD64)

Stage1 crashes during Phase 3 (Lowering to IR) when compiling programs that have global variables.

**Symptoms:**
- SIGSEGV in Phase 3: Lowering to IR
- Crash on NULL pointer dereference
- Works fine for simple programs without globals

**Reproduction:**
```bash
echo 'var g: i64 = 0; fn main() i64 { return g; }' > /tmp/test.cot
/tmp/cot1-stage1 /tmp/test.cot -o /tmp/test.o
# Crashes in Phase 3
```

**Related:**
- Bootstrap tests crash on this same issue

---

### BUG-078: Stage1 AMD64 - Struct copy through pointer bug (FIXED)

**Status:** FIXED (2026-01-29)
**Priority:** CRITICAL
**Discovered:** 2026-01-29
**Platform:** Linux (AMD64)

**Root cause:** When copying a struct through a pointer dereference (`ptr.* = struct_value`), the Zig compiler's SSA builder emitted a `.store` operation which only handles up to 8 bytes. For structs > 8 bytes, only the first qword was copied.

**Fix:** Modified `src/frontend/ssa_builder.zig` to emit `.move` operations (bulk memory copy) instead of `.store` for struct types > 8 bytes in both:
1. `ptr_store_value` - storing through computed pointer (`ptr.* = value`)
2. `store_local` - storing to local variable (`local = value`)

The `.move` operation properly copies all bytes of the struct using 8-byte chunks.

**Test case:**
```cot
struct TestStruct { a: i64, b: i64, c: i64, d: i64, value: i64, f: i64, }
fn main() i64 {
    let ptr: *TestStruct = @ptrCast(*TestStruct, malloc_sized(1, 48));
    var s: TestStruct = undefined;
    s.a = 1; s.b = 2; s.c = 3; s.d = 4; s.value = 42; s.f = 6;
    ptr.* = s;  // Now correctly copies all 48 bytes
    return ptr.value;  // Returns 42 (was 0 before fix)
}
```

**Note:** Stage1 still has a separate crash during SSA/codegen (address 0xffffffffffffffff - likely a lookup returning -1). This is a different issue in the cot1 code itself, not the Zig compiler.

---

## Fixed Bugs Summary

| Bug | Description | Fixed |
|-----|-------------|-------|
| BUG-078 | Struct copy through pointer only copies 8 bytes | 2026-01-29 |
| BUG-074 | []u8 slice as function parameter causes segfault | 2026-01-29 |
| BUG-069 | i64 minimum literal parsing overflow | 2026-01-28 |
| BUG-068 | For-range over struct slices returns garbage | 2026-01-28 |
| BUG-066 | Multiple nested field access in single expression fails | 2026-01-28 |
| BUG-065 | Nested struct field copy fails | 2026-01-28 |
| BUG-071 | Assignment through computed slice fails | 2026-01-28 |
| BUG-070 | Variable shadowing in nested blocks fails | 2026-01-28 |
| BUG-067 | Array of structs with computed index crashes | 2026-01-28 |
| BUG-064 | Signed comparison for narrower integer types fails | 2026-01-28 |
| BUG-062 | Self-hosted compiler generates wrong constants for large array sizes | 2026-01-27 |
| BUG-061 | cot1 SSA builder stack overflow on self-compilation | 2026-01-27 |
| BUG-060 | slice_make on globals creates wrong results | 2026-01-27 |
| BUG-059 | Global array of structs causes "undefined" panic | 2026-01-27 |
| BUG-058 | Struct-typed global variables crash codegen | 2026-01-27 |
| BUG-057 | Global array variables not initialized | 2026-01-27 |
| BUG-056 | Global struct field store uses wrong offset | 2026-01-27 |
| BUG-055 | Global variable store values wrong | 2026-01-27 |
| BUG-054 | Global variable load/store uses wrong address | 2026-01-27 |
| BUG-053 | Global array index assigns to wrong location | 2026-01-27 |
| BUG-052 | Global array.field assignment uses wrong field offset | 2026-01-27 |
| BUG-051 | Global struct array initialization crashes | 2026-01-27 |
| BUG-050 | cot1 global variables not visible across files | 2026-01-26 |
| BUG-049 | Nested struct pointer field access wrong | 2026-01-26 |
| BUG-048 | For-range over slice returns wrong values | 2026-01-26 |
| BUG-047 | Method call on pointer receiver double-dereferences | 2026-01-26 |
| BUG-046 | Array element field access (arr[i].field) wrong | 2026-01-26 |
| BUG-045 | Pointer-to-struct field access wrong | 2026-01-26 |
| BUG-044 | Struct literal inside struct literal wrong | 2026-01-26 |
| BUG-043 | Array of struct initialization wrong | 2026-01-26 |
| BUG-042 | Struct with array field access wrong | 2026-01-26 |
| BUG-041 | Nested struct field assignment wrong offset | 2026-01-26 |
| BUG-040 | Struct return with 3+ fields corrupted | 2026-01-26 |
| BUG-039 | Binary ops on struct fields compute wrong | 2026-01-26 |
| BUG-038 | Field access on struct pointer wrong | 2026-01-26 |
| BUG-037 | Struct literal assignment to local wrong | 2026-01-26 |
| BUG-036 | Multi-field struct return only has first field | 2026-01-26 |
| BUG-035 | Zig compiler stage1 compilation produces corrupted binary | 2026-01-24 |
| BUG-034 | Zig compiler self-hosting failure at stage2 | 2026-01-23 |
| BUG-033 | Global array indexing uses wrong base address | 2026-01-22 |
| BUG-032 | Global variable referenced before definition | 2026-01-22 |
| BUG-031 | Break inside nested if in while exits wrong scope | 2026-01-22 |
| BUG-030 | Slice field (.ptr, .len) access returns garbage | 2026-01-22 |
| BUG-029 | Global struct variable field access wrong | 2026-01-21 |
| BUG-028 | Ternary in struct literal field crashes | 2026-01-21 |
| BUG-027 | Enum comparison always returns true | 2026-01-20 |
| BUG-026 | Integer literals > 2^31 not parsed correctly | 2026-01-20 |
| BUG-025 | String pointer becomes null after many accesses | 2026-01-19 |
| BUG-024 | String pointer becomes null in is_keyword | 2026-01-19 |
| BUG-023 | Stack slot reuse causes value corruption | 2026-01-19 |
| BUG-022 | Comparison operands use same register | 2026-01-19 |
| BUG-021 | Chained AND operator incorrectly true | 2026-01-18 |
| BUG-020 | Large struct argument passing segfault (ARM64) | 2026-01-28 |
| BUG-019 | Large struct (>16B) by-value not passed correctly | 2026-01-18 |
| BUG-017 | Imported constant in binary expr panics | 2026-01-17 |
| BUG-016 | Const identifier on right of comparison fails | 2026-01-17 |
| BUG-015 | Chained OR with 3+ conditions always true | 2026-01-17 |
| BUG-014 | Switch statements not supported | 2026-01-16 |
| BUG-013 | String concatenation in loops segfaults | 2026-01-16 |
| BUG-012 | ptr.*.field loads entire struct | 2026-01-16 |
| BUG-008 | Missing addr_global IR node | 2026-01-16 |
| BUG-006 | `not` keyword not recognized | 2026-01-15 |
| BUG-005 | Logical NOT uses bitwise NOT | 2026-01-15 |
| BUG-004 | Struct returns > 16 bytes fail | 2026-01-15 |
| BUG-003 | Struct layout with enum field wrong | 2026-01-15 |
| BUG-002 | Struct literal syntax not implemented | 2026-01-15 |
| BUG-001b | String literal arguments not decomposed | 2026-01-15 |
| BUG-001 | String parameter passing corrupts length | 2026-01-15 |

---

## Bug Fixing Workflow

1. **Run `COT_DEBUG=all`** to trace the value through the pipeline
2. **Add debug logging** if the bug location isn't obvious
3. **Check Go compiler** (`~/learning/go/src/cmd/compile/`) for the correct pattern
4. **Implement fix** adapting Go's pattern to Zig

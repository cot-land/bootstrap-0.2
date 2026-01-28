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

## Fixed Bugs Summary

| Bug | Description | Fixed |
|-----|-------------|-------|
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

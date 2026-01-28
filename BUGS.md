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

### BUG-063: cot1 stage2 compilation crashes during SSA building

**Status:** Partially fixed (parser loops fixed, crash remains)
**Priority:** HIGH
**Discovered:** 2026-01-25

When stage1 compiles the full cot1 codebase to produce stage2, it crashes during SSA building/codegen phase.

**Fixed (2026-01-28):**
- Parser infinite loops on incomplete structs/blocks - added position tracking and safety breaks

**Current symptoms:**
- Parser completes (with some warnings for incomplete imports)
- Type checking completes
- IR lowering completes (78122 nodes, 1552 functions, 176 globals)
- Crash with NULL pointer dereference during Phase 4/5 (SSA building)

**Remaining issues:**
- "Warning: Parse error in import" for some files (incomplete code at EOF?)
- NULL pointer crash during SSA building - needs investigation

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

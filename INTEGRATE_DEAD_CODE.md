# Dead Code Integration Plan

## INTEGRATION PATTERN - FOLLOW THIS EXACTLY

**CRITICAL: Functions must be USED, not just imported. An import without usage is still dead code.**

When integrating each dead code file:

1. **ADD THE IMPORT** to main.cot
   ```cot
   import "lib/whatever.cot"
   ```

2. **TRY TO COMPILE**
   ```bash
   ./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1
   ```

3. **IF IT FAILS - DO NOT COMMENT OUT AND MOVE ON**
   - Investigate the ROOT CAUSE of the failure
   - Check how Go handles it: `~/learning/go/src/cmd/compile/`
   - Fix the Zig compiler (`src/*.zig`) to match Go's approach
   - Rebuild: `zig build`
   - Test: `./zig-out/bin/cot test/e2e/all_tests.cot -o /tmp/t && /tmp/t`

4. **WIRE UP THE FUNCTIONS** - Find where each function should be called
   - Check the equivalent in Zig compiler (`src/*.zig`)
   - Replace raw calls with the safe/wrapper versions
   - Example: Replace `open()` with `safe_open_read()`, etc.

5. **VERIFY COT1-STAGE1 WORKS**
   ```bash
   /tmp/cot1-stage1 test/stages/cot1/all_tests.cot -o /tmp/t.o
   zig cc /tmp/t.o runtime/cot_runtime.o -o /tmp/t -lSystem && /tmp/t
   ```

6. **UPDATE THIS DOCUMENT** - mark functions as [x] USED (not just imported)

### Example: safe_io.cot Integration

**Problem:** Import caused panic "index out of bounds: index 4294967295"

**Root cause:** Cross-file globals not visible. Each file had its own IR Builder, so `g_debug_verbose` from error.cot wasn't visible to safe_io.cot.

**Go pattern:** All files in a package share a single `ir.Package` (`typecheck.Target`).

**Fix:** Modified `src/driver.zig` to use a shared IR Builder across all files (like Go's approach).

**Result:** safe_io.cot integrated, all 166 tests pass.

---

## Current Blockers

### @ptrToInt / @intFromPtr not supported

Files **lib/debug.cot**, **lib/debug_init.cot**, and **lib/safe_alloc.cot** use pointer-to-integer conversion for debug output (printing addresses). The cot1 compiler doesn't support this builtin yet.

**To unblock:** Add @ptrToInt support to the Zig compiler:
1. Add case in `src/frontend/lower.zig:lowerBuiltinCall` for "ptrToInt"
2. Add case in `src/frontend/checker.zig:checkBuiltinCall` for "ptrToInt"
3. Emit IR that converts pointer to i64

**Alternative:** Remove address printing from debug.cot (just print "(pointer)" instead of the hex address).

---

## Goal
Integrate ALL dead code files into cot1 so 100% of the codebase is used.
main.cot should be ~400 lines (matching main.zig's 420 lines).

## Current State

**main.zig (Zig bootstrap)**: 420 lines
- Clean imports of all modules
- Simple main() that calls Driver
- No inline logic

**main.cot (cot1)**: 2098 lines
- 150+ lines of inline error handling (copied from lib/error.cot)
- Inline string utilities
- Inline file I/O
- Inline driver logic
- Should be: imports + main() only

---

## Dead Files to Integrate

### PRIORITY 1: Core Infrastructure (lib/)

These provide the foundation - integrate first.

#### lib/error.cot (637 lines) - INTEGRATED
Status: **IMPORTED** - main.cot now imports lib/error.cot (deleted 128 lines of inline code)
Tests: 166/166 passing

| Function | Line | Status | Notes |
|----------|------|--------|-------|
| stderr_str | 34 | [x] | Imported - uses string type |
| stderr_ptr | 35 | [x] | Imported - for *u8 pointers |
| stderr_char | 43 | [x] | Imported |
| stderr_int | 49 | [x] | Imported |
| stderr_hex | 78 | [x] | Imported |
| stderr_newline | 105 | [x] | Imported |
| panic | 114 | [x] | Imported - used by assert |
| panic_int | 125 | [x] | Imported |
| panic_int2 | 138 | [x] | Imported |
| panic_ptr | 153 | [x] | Imported |
| assert | 170 | [x] | Imported - used throughout compiler |
| assert_int | 177 | [x] | Imported |
| assert_int2 | 184 | [x] | Imported |
| assert_eq | 191 | [x] | Imported |
| assert_ne | 208 | [x] | Imported |
| assert_lt | 223 | [x] | Imported |
| assert_le | 240 | [x] | Imported |
| assert_ge | 257 | [x] | Imported |
| assert_not_null | 277 | [x] | Imported |
| assert_not_null_i64 | 289 | [x] | Imported |
| check_ptr | 302 | [x] | Imported |
| check_ptr_i64 | 307 | [x] | Imported |
| assert_bounds | 316 | [x] | Imported |
| check_bounds | 344 | [x] | Imported |
| assert_range | 350 | [x] | Imported |
| assert_capacity | 394 | [x] | Imported |
| assert_space | 410 | [x] | Imported |
| unreachable | 434 | [x] | Imported |
| unreachable_int | 445 | [x] | Imported |
| trace_enter | 462 | [x] | Imported |
| trace_exit | 476 | [x] | Imported |
| trace_value | 490 | [x] | Imported |
| debug | 509 | [x] | Imported |
| debug_int | 516 | [x] | Imported |
| debug_int2 | 525 | [x] | Imported |
| debug_ptr | 536 | [x] | Imported |
| track_alloc | 549 | [x] | Imported |
| track_free | 554 | [x] | Imported |
| print_alloc_stats | 558 | [x] | Imported |
| push_context | 579 | [x] | Imported |
| pop_context | 586 | [x] | Imported |
| print_error_context | 592 | [x] | Imported |
| panic_with_context | 608 | [x] | Imported |
| error_init_debug_mode | 623 | [x] | Imported |

---

#### lib/debug.cot (590 lines) - NEEDS REWRITE
Status: **BLOCKED** - Cannot import: has @ptrToInt (unsupported), function name conflicts with error.cot
Maps to: Zig's src/pipeline_debug.zig
Action needed: Rewrite to match pipeline_debug.zig structure

| Function | Line | Status | Notes |
|----------|------|--------|-------|
| debug_enable_all | 42 | [x] | Imported |
| debug_enable_trace | 53 | [x] | Imported |
| debug_enable_verbose | 57 | [x] | Imported |
| debug_enable_phase | 61 | [x] | Imported |
| debug_disable_all | 65 | [x] | Imported |
| debug_str | 81 | [x] | Imported |
| debug_ptr | 95 | [x] | Imported |
| debug_int2 | 109 | [x] | Imported |
| debug_int3 | 125 | [x] | Imported |
| debug_bool | 145 | [x] | Imported |
| trace_enter_int | 163 | [x] | Imported |
| trace_enter_int2 | 188 | [x] | Imported |
| trace_enter_str | 217 | [x] | Imported |
| trace_exit_int | 246 | [x] | Imported |
| trace_exit_bool | 265 | [x] | Imported |
| phase_start | 294 | [x] | Imported |
| phase_end | 310 | [x] | Imported |
| phase_progress | 318 | [x] | Imported |
| phase_progress_int | 326 | [x] | Imported |
| debug_ir | 340 | [x] | Imported |
| debug_ir_int | 347 | [x] | Imported |
| debug_ssa | 356 | [x] | Imported |
| debug_ssa_int | 363 | [x] | Imported |
| debug_codegen | 372 | [x] | Imported |
| debug_codegen_int | 379 | [x] | Imported |
| debug_memory | 388 | [x] | Imported |
| debug_memory_int | 395 | [x] | Imported |
| debug_hexdump | 409 | [x] | Imported |
| debug_dump_i64_array | 481 | [x] | Imported |
| print_trace_stats | 522 | [x] | Imported |
| checkpoint | 550 | [x] | Imported |
| checkpoint_int | 562 | [x] | Imported |
| reached | 577 | [x] | Imported |
| reached_int | 583 | [x] | Imported |

---

#### lib/debug_init.cot (300 lines) - INTEGRATED & USED
Status: **FULLY INTEGRATED** - main.cot imports and calls debug_startup/debug_shutdown
Tests: All 166 tests passing

**Usage in main.cot:**
- `debug_startup(argc, argv)` called at start of main()
- `debug_shutdown()` called at end of main()

| Function | Line | Status | Notes |
|----------|------|--------|-------|
| streq_flag | 29 | [x] | Internal - used by parse_debug_flag |
| starts_with | 43 | [x] | Internal |
| parse_debug_flag | 56 | [x] | Used by parse_debug_flags |
| parse_debug_flags | 118 | [x] | Used by debug_startup |
| debug_init | 140 | [x] | Used by debug_startup |
| debug_print_config | 160 | [x] | Used by debug_startup |
| debug_print_summary | 203 | [x] | Used by debug_shutdown |
| debug_startup | 252 | [x] | USED in main() |
| debug_shutdown | 262 | [x] | USED in main() |
| compiler_phase_read | 272 | [ ] | Available - not yet wired |
| compiler_phase_parse | 276 | [ ] | Available - not yet wired |
| compiler_phase_lower | 280 | [ ] | Available - not yet wired |
| compiler_phase_ssa | 284 | [ ] | Available - not yet wired |
| compiler_phase_regalloc | 288 | [ ] | Available - not yet wired |
| compiler_phase_codegen | 292 | [ ] | Available - not yet wired |
| compiler_phase_link | 296 | [ ] | Available - not yet wired |
| compiler_phase_write | 300 | [ ] | Available - not yet wired |

---

#### lib/safe_io.cot (725 lines) - INTEGRATED & USED
Status: **FULLY INTEGRATED** - main.cot imports and USES safe_io functions
Fix required: Shared IR Builder (see driver.zig) - cross-file globals now visible
Tests: All 166 tests passing

**Usage in main.cot:**
- `read_file()` now calls: `safe_open_read`, `safe_read_all`, `safe_close`
- `write_file()` now calls: `safe_open_write`, `safe_write_all`, `safe_close`

| Function | Line | Status | Notes |
|----------|------|--------|-------|
| safe_open_read | 46 | [x] | USED in read_file() |
| safe_open_write | 111 | [x] | USED in write_file() |
| safe_open | 178 | [ ] | Not yet used - for custom flags |
| safe_read | 224 | [ ] | Not yet used - for partial reads |
| safe_read_all | 310 | [x] | USED in read_file() |
| safe_write | 374 | [ ] | Not yet used - for partial writes |
| safe_write_all | 481 | [x] | USED in write_file() |
| safe_close | 532 | [x] | USED in read_file(), write_file() |
| safe_lseek | 601 | [ ] | Not yet used |
| safe_get_file_size | 662 | [ ] | Not yet used |
| print_io_stats | 712 | [ ] | Not yet used - for debug output |

---

#### lib/safe_alloc.cot (290 lines) - IMPORTED
Status: **IMPORTED** - main.cot imports lib/safe_alloc.cot
Action: Wire up safe_malloc_u8 etc. to replace raw malloc calls
Tests: All 166 tests passing

| Function | Line | Status | Notes |
|----------|------|--------|-------|
| safe_malloc_u8 | 22 | [ ] | Not yet used - could replace malloc_u8 |
| safe_malloc_i64 | 80 | [ ] | Not yet used |
| safe_realloc_u8 | 145 | [ ] | Not yet used |
| safe_free_u8 | 209 | [ ] | Not yet used |
| safe_free_i64 | 227 | [ ] | Not yet used |
| safe_calloc_u8 | 248 | [ ] | Not yet used |
| safe_calloc_i64 | 261 | [ ] | Not yet used |
| calc_grow_capacity | 279 | [ ] | Not yet used |

---

#### lib/safe_array.cot (400 lines) - INTEGRATED & PARTIALLY USED
Status: **IMPORTED** - main.cot imports lib/safe_array.cot
Fixes applied: `stderr_str(name)` -> `stderr_ptr(name)`, `print_error_context_stack` -> `print_error_context`
Tests: All 166 tests passing

**Usage in main.cot:**
- `strlen()` now calls `safe_strlen` with 64KB max limit

| Function | Line | Status | Notes |
|----------|------|--------|-------|
| safe_get_i64 | 19 | [ ] | Not yet used |
| safe_set_i64 | 75 | [ ] | Not yet used |
| safe_get_u8 | 141 | [ ] | Not yet used |
| safe_set_u8 | 197 | [ ] | Not yet used |
| safe_memcpy | 265 | [ ] | Not yet used |
| safe_strlen | 361 | [x] | USED by strlen() in main.cot |
| safe_strcmp | 396 | [ ] | Not yet used |

---

#### lib/invariants.cot (687 lines) - INTEGRATED
Status: **IMPORTED** - main.cot imports lib/invariants.cot
Fixes applied: `print_error_context_stack` -> `print_error_context`, `stderr_str(context/name)` -> `stderr_ptr`, string literals to .ptr
Tests: All 166 tests passing

| Function | Line | Status | Notes |
|----------|------|--------|-------|
| Scanner_checkInvariants | 33 | [ ] | Available - call after scan |
| Parser_checkInvariants_pools | 107 | [ ] | Available - call after parse |
| Lowerer_checkInvariants | 167 | [ ] | Available - call after lower |
| SSABuilder_checkInvariants | 297 | [ ] | Available - call after SSA build |
| GenState_checkInvariants | 415 | [ ] | Available - call during codegen |
| Func_checkInvariants | 516 | [ ] | Available - call on SSA func |
| Buffer_checkInvariants | 588 | [ ] | Available |
| MachOWriter_checkInvariants | 644 | [ ] | Available - call before write |

---

#### lib/validate.cot (745 lines) - INTEGRATED
Status: **IMPORTED** - main.cot imports lib/validate.cot
Fixes applied: `print_error_context_stack` -> `print_error_context`, `stderr_str(context/name)` -> `stderr_ptr`, return strings to .ptr
Tests: All 166 tests passing

| Function | Line | Status | Notes |
|----------|------|--------|-------|
| NodeKind_name | 26 | [ ] | Available for debug output |
| IRNodeKind_name | 85 | [ ] | Available for debug output |
| Op_name | 145 | [ ] | Available for debug output |
| assert_node_kind | 230 | [ ] | Available |
| assert_node_kind_in | 254 | [ ] | Available |
| assert_is_expression | 289 | [ ] | Available |
| assert_is_statement | 316 | [ ] | Available |
| assert_is_declaration | 337 | [ ] | Available |
| assert_ir_kind | 362 | [ ] | Available |
| assert_ir_is_constant | 386 | [ ] | Available |
| assert_op | 411 | [ ] | Available |
| assert_op_valid | 435 | [ ] | Available |
| assert_op_is_constant | 450 | [ ] | Available |
| assert_op_is_arithmetic | 471 | [ ] | Available |
| assert_op_is_comparison | 492 | [ ] | Available |
| assert_block_index | 517 | [ ] | Available |
| assert_value_index | 550 | [ ] | Available |
| assert_local_index | 583 | [ ] | Available |
| assert_ir_node_index | 616 | [ ] | Available |
| assert_ast_node_index | 649 | [ ] | Available |
| assert_in_range | 686 | [ ] | Available |
| assert_positive | 709 | [ ] | Available |
| assert_non_negative | 728 | [ ] | |

---

### PRIORITY 2: Frontend (Critical Path)

#### frontend/checker.cot (883 lines) - DEAD
**THIS IS THE TYPE CHECKER - IT MUST BE IN THE PIPELINE**

Maps to: Zig's frontend/checker.zig (which IS used)

Currently: Parser output goes directly to Lowerer
Should be: Parser → **Checker** → Lowerer

| Function | Line | Status | Notes |
|----------|------|--------|-------|
| Symbol_new | 48 | [ ] | |
| Symbol_newConst | 61 | [ ] | |
| Symbol_newExtern | 74 | [ ] | |
| ScopePool_init | 112 | [ ] | |
| ScopePool_new | 117 | [ ] | |
| ScopePool_define | 129 | [ ] | |
| ScopePool_lookupType | 139 | [ ] | |
| ScopePool_isDefined | 163 | [ ] | |
| names_equal | 177 | [ ] | |
| Checker_init | 206 | [ ] | Call in main.cot |
| Checker_checkExpr | 223 | [ ] | |
| Checker_checkStmt | 433 | [ ] | |
| Checker_checkVarDecl | 540 | [ ] | |
| Checker_resolveTypeHandle | 571 | [ ] | |
| Checker_resolveTypeNode | 615 | [ ] | |
| Checker_checkStructDecl | 711 | [ ] | |
| Checker_checkEnumDecl | 779 | [ ] | |
| Checker_checkFnDecl | 804 | [ ] | |
| Checker_ok | 836 | [ ] | Check after Checker_checkFile |
| Checker_errors | 841 | [ ] | |
| Checker_checkTypeAliasDecl | 847 | [ ] | |
| Checker_checkFile | 868 | [ ] | Call in main.cot |

---

### PRIORITY 3: SSA Passes (Required for proper codegen)

#### ssa/liveness.cot (612 lines) - IMPORTED
Status: **IMPORTED** - main.cot imports ssa/liveness.cot
Maps to: Zig's ssa/liveness.zig (which IS used)
Tests: All 166 tests passing

| Function | Line | Status | Notes |
|----------|------|--------|-------|
| LiveInfo_new | 33 | [ ] | Available - not yet wired |
| LiveMap_init | 55 | [ ] | Available |
| LiveMap_clear | 61 | [ ] | Available |
| LiveMap_find | 66 | [ ] | Available |
| LiveMap_set | 79 | [ ] | Available |
| LiveMap_setForce | 101 | [ ] | Available |
| LiveMap_get | 120 | [ ] | Available |
| LiveMap_contains | 130 | [ ] | Available |
| LiveMap_remove | 135 | [ ] | Available |
| LiveMap_size | 151 | [ ] | Available |
| LiveMap_getInfo | 157 | [ ] | Available |
| LiveMap_addDistanceAll | 167 | [ ] | Available |
| LiveMap_items | 180 | [ ] | Available |
| BlockLiveness_init | 199 | [ ] | Available |
| BlockLiveness_update | 211 | [ ] | Available |
| BlockLiveness_contains | 226 | [ ] | Available |
| BlockLiveness_get | 239 | [ ] | Available |
| LivenessResult_init | 261 | [ ] | Available |
| LivenessResult_getBlock | 268 | [ ] | Available |
| LivenessResult_getLiveOut | 282 | [ ] | Available |
| Value_needsRegister | 291 | [ ] | Available |
| Op_isCallOp | 304 | [ ] | Available |
| Block_branchDistance | 312 | [ ] | Available |
| BlockLiveness_computeNextCall | 328 | [ ] | Available |
| Liveness_processSuccessorPhis | 353 | [ ] | Available |
| Liveness_processBlockLiveness | 388 | [ ] | Available |
| Liveness_compute | 532 | [ ] | Main entry point - not yet wired |
| LivenessResult_getDistance | 588 | [ ] | Available |
| LivenessResult_isLiveOut | 594 | [ ] | Available |
| LivenessResult_getNextCall | 600 | [ ] | Available |
| LivenessResult_hasCallAfter | 610 | [ ] | Available |

---

#### ssa/regalloc.cot (623 lines) - IMPORTED
Status: **IMPORTED** - main.cot imports ssa/regalloc.cot
Maps to: Zig's ssa/regalloc.zig (which IS used)
Tests: All 166 tests passing

| Function | Line | Status | Notes |
|----------|------|--------|-------|
| ValState_new | 70 | [ ] | Available |
| ValState_inReg | 80 | [ ] | Available |
| ValState_firstReg | 84 | [ ] | Available |
| RegState_new | 106 | [ ] | Available |
| RegState_isFree | 113 | [ ] | Available |
| RegState_clear | 117 | [ ] | Available |
| RegAlloc_init | 147 | [ ] | Available |
| RegAlloc_findFreeReg | 174 | [ ] | Available |
| RegAlloc_allocReg | 191 | [ ] | Available |
| RegAlloc_spillReg | 237 | [ ] | Available |
| RegAlloc_assignReg | 273 | [ ] | Available |
| RegAlloc_freeReg | 293 | [ ] | Available |
| RegAlloc_freeRegs | 309 | [ ] | Available |
| RegAlloc_ensureValState | 326 | [ ] | Available |
| Op_isRematerializable | 339 | [ ] | Available |
| Value_needsReg | 348 | [ ] | Available |
| RegAlloc_allocatePhis | 368 | [ ] | Available |
| ValState_firstReg_mask | 461 | [ ] | Available |
| RegAlloc_findFreeReg_mask | 474 | [ ] | Available |
| RegAlloc_processValue | 495 | [ ] | Available |
| RegAlloc_processBlock | 552 | [ ] | Available |
| RegAlloc_run | 579 | [ ] | Main entry point - not yet wired |
| RegAlloc_getReg | 599 | [ ] | Available |
| RegAlloc_getSpill | 608 | [ ] | Available |
| RegAlloc_inReg | 617 | [ ] | Available |

---

#### ssa/passes/decompose.cot - IMPORTED
Status: **IMPORTED** - main.cot imports ssa/passes/decompose.cot
Tests: All 166 tests passing

| Function | Line | Status | Notes |
|----------|------|--------|-------|
| decompose | 22 | [ ] | Available - not yet wired into pipeline |
| decomposeBlock | 45 | [ ] | Available |

---

#### ssa/passes/lower.cot - IMPORTED
Status: **IMPORTED** - main.cot imports ssa/passes/lower.cot
Tests: All 166 tests passing

| Function | Line | Status | Notes |
|----------|------|--------|-------|
| isPowerOf2 | 17 | [ ] | Available |
| log2 | 23 | [ ] | Available |
| fitsImm12 | 34 | [ ] | Available |
| lower | 40 | [ ] | Available - not yet wired into pipeline |
| lowerBlock | 50 | [ ] | Available |

---

#### ssa/passes/schedule.cot - IMPORTED
Status: **IMPORTED** - main.cot imports ssa/passes/schedule.cot
Tests: All 166 tests passing

| Function | Line | Status | Notes |
|----------|------|--------|-------|
| getScore | 29 | [ ] | Available |
| schedule | 40 | [ ] | Available - not yet wired into pipeline |
| scheduleBlock | 51 | [ ] | Available |
| valueUsesValue | 111 | [ ] | Available |
| swapValues | 124 | [ ] | Available |
| updateValueReferences | 148 | [ ] | Available |

---

## Integration Order

### Phase 1: Core Infrastructure
1. [x] Import lib/error.cot in main.cot (DONE)
2. [x] Delete all inline error functions from main.cot (~150 lines) (DONE)
3. [x] Import lib/debug.cot (DONE)
4. [x] Import lib/debug_init.cot (DONE)
5. [x] Add debug_startup()/debug_shutdown() calls to main() (DONE)

### Phase 2: Safe Wrappers
6. [x] Import lib/safe_io.cot (DONE - required shared IR Builder fix)
7. [x] Replace read_file/write_file with safe_* versions (DONE - uses safe_open_read, safe_read_all, safe_close)
8. [x] Import lib/safe_alloc.cot (DONE - imported, functions not yet wired)
9. [x] Import lib/safe_array.cot (DONE - strlen uses safe_strlen)

### Phase 3: Validation
10. [x] Import lib/validate.cot (DONE - imported, functions not yet wired)
11. [x] Import lib/invariants.cot (DONE - imported, functions not yet wired)
12. [ ] Add invariant checks at phase boundaries

### Phase 4: Type Checker (CRITICAL)
13. [ ] Import frontend/checker.cot
14. [ ] Add Checker between Parser and Lowerer in pipeline
15. [ ] Verify type checking is actually happening

### Phase 5: SSA Passes
16. [x] Import ssa/liveness.cot (DONE - imported, not yet wired)
17. [x] Import ssa/regalloc.cot (DONE - imported, not yet wired)
18. [x] Import ssa/passes/decompose.cot (DONE - imported, not yet wired)
19. [x] Import ssa/passes/lower.cot (DONE - imported, not yet wired)
20. [x] Import ssa/passes/schedule.cot (DONE - imported, not yet wired)
21. [ ] Wire up pass pipeline in proper order

### Phase 6: Cleanup
22. [ ] Move all remaining inline logic from main.cot to appropriate modules
23. [ ] Verify main.cot is ~400 lines
24. [ ] Run all tests
25. [ ] Verify stage2 builds

---

## Verification

After each phase:
```bash
zig build
./zig-out/bin/cot test/e2e/all_tests.cot -o /tmp/t && /tmp/t
```

After all phases:
```bash
# Build stage1
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1

# Build stage2 (self-hosting test)
/tmp/cot1-stage1 stages/cot1/main.cot -o /tmp/cot1-stage2.o
zig cc /tmp/cot1-stage2.o runtime/cot_runtime.o -o /tmp/cot1-stage2 -lSystem
```

---

## Summary

| Category | Files | Functions | Lines |
|----------|-------|-----------|-------|
| lib/ (infrastructure) | 9 | 134 | ~4,000 |
| frontend/checker.cot | 1 | 22 | 883 |
| ssa/ (passes) | 5 | 64 | ~2,000 |
| **TOTAL DEAD** | **15** | **220** | **~7,000** |

All 220 functions must be imported and used.
All ~7,000 lines must be reachable from main.cot.

# TODO Execution Plan

**Created:** 2026-01-15
**Goal:** Systematically address all TODOs in priority order

## Workflow for Each Task

1. **Research Go's implementation** in `~/learning/go`
2. **Write failing test** first
3. **Implement** following Go's pattern
4. **Run tests** - ensure no regressions
5. **Commit** with descriptive message

---

## HIGH PRIORITY - Features for Self-Hosting

### Task 1: For-In Loop Lowering
**File:** `src/frontend/lower.zig:625`
**TODO:** `implement proper iterator lowering`

**Current State:** Empty stub - `lowerFor()` does nothing

**Go Reference:**
- `~/learning/go/src/cmd/compile/internal/walk/range.go` - ORANGE handling
- `~/learning/go/src/cmd/compile/internal/ssagen/ssa.go` - range loop SSA generation

**Implementation Plan:**
1. Research Go's ORANGE (range) node handling
2. Desugar `for x in arr` to while loop with index
3. Handle array iteration: `for i in 0:len(arr)`
4. Handle slice iteration: `for item in slice`

**Tests Needed:**
- `test_for_array` - iterate over array
- `test_for_range` - iterate over 0:n range
- `test_for_slice` - iterate over slice
- `test_for_break` - break in for loop
- `test_for_continue` - continue in for loop

---

### Task 2: Implicit Slice End (arr[:] and arr[start:])
**File:** `src/frontend/ssa_builder.zig:931`
**TODO:** `For now, we need the array length from the type system`

**Current State:** Requires explicit end index, returns error otherwise

**Go Reference:**
- `~/learning/go/src/cmd/compile/internal/ssagen/ssa.go` - slice() function
- Lines 5713-5823 handle default indices

**Implementation Plan:**
1. When end is null, get array length from type
2. For arrays: use compile-time constant length
3. For slices: use OpSliceLen to get runtime length

**Tests Needed:**
- `test_slice_implicit_end` - `arr[0:]`
- `test_slice_implicit_start` - `arr[:3]`
- `test_slice_full` - `arr[:]`

---

### Task 3: Computed Base Index Assignment
**File:** `src/frontend/lower.zig:539`
**TODO:** `Handle computed base (index into expression)`

**Current State:** Only handles identifier bases in assignment

**Go Reference:**
- `~/learning/go/src/cmd/compile/internal/walk/assign.go`

**Implementation Plan:**
1. Lower the base expression to get address
2. Compute element address with index
3. Store to computed address

**Tests Needed:**
- `test_computed_index_assign` - `getArray()[0] = 42`

---

## MEDIUM PRIORITY - Robustness

### Task 4: Array Copy Semantics
**File:** `src/frontend/lower.zig:354`
**TODO:** `implement proper array copy`

**Current State:** Just stores value (reference copy, not element copy)

**Go Reference:**
- `~/learning/go/src/cmd/compile/internal/walk/assign.go` - OAS with array

**Implementation Plan:**
1. Detect array-to-array assignment
2. Emit loop to copy each element
3. Or use memmove for large arrays

**Tests Needed:**
- `test_array_copy` - `var b = a` copies elements
- `test_array_copy_modify` - modifying copy doesn't affect original

---

### Task 5: String Variable Assignment
**File:** `src/frontend/lower.zig:397`
**TODO:** `handle string variables properly`

**Current State:** Falls through to generic store

**Go Reference:**
- `~/learning/go/src/cmd/compile/internal/walk/assign.go` - string handling

**Implementation Plan:**
1. String is (ptr, len) pair like slice
2. Copy both components on assignment

**Tests Needed:**
- `test_string_assign` - `var s2 = s1`
- `test_string_reassign` - `s = "new"`

---

### Task 6: Pointer Field Store
**File:** `src/frontend/lower.zig:488`
**TODO:** `Handle pointer field store (PtrFieldStore)`

**Current State:** Comment only, may work via other paths

**Go Reference:**
- `~/learning/go/src/cmd/compile/internal/walk/assign.go`

**Implementation Plan:**
1. Load pointer from local
2. Add field offset
3. Store to computed address

**Tests Needed:**
- `test_ptr_field_store` - `ptr.field = value`

---

### Task 7: Function Return Type Lookup
**File:** `src/frontend/lower.zig:1014`
**TODO:** `look up in symbol table`

**Current State:** Uses VOID for all function return types

**Go Reference:**
- `~/learning/go/src/cmd/compile/internal/ssagen/ssa.go` - call handling

**Implementation Plan:**
1. Look up function in checker's symbol table
2. Get declared return type
3. Use for call node type

**Tests Needed:**
- Already works for most cases, verify with existing tests

---

### Task 8: Function Types in Checker
**File:** `src/frontend/checker.zig:1403`
**TODO:** `function types`

**Current State:** Comment placeholder

**Go Reference:**
- `~/learning/go/src/cmd/compile/internal/types2/` - function type handling

**Implementation Plan:**
1. Add function type representation
2. Support `fn(i64) i64` type syntax
3. Enable function pointers

**Tests Needed:**
- `test_fn_type` - function type declaration
- `test_fn_ptr` - function pointer usage

---

## LOW PRIORITY - Optimizations

### Task 9: Escape Analysis
**Files:** `src/frontend/ssa_builder.zig:402, 451`
**TODO:** `Add escape analysis to use SSA variables when safe`

**Current State:** Always uses memory for locals (conservative)

**Go Reference:**
- `~/learning/go/src/cmd/compile/internal/escape/`

**Implementation Plan:**
1. Track which variables have address taken
2. Use SSA registers for non-escaping variables
3. Skip memory stores for pure SSA vars

**Priority:** Optimization only, defer until needed

---

### Task 10: Timing Stats
**File:** `src/ssa/compile.zig:292`
**TODO:** `Accumulate timing stats`

**Current State:** Elapsed time computed but unused

**Implementation Plan:**
1. Add timing accumulator
2. Print phase timings on debug flag

**Priority:** Nice-to-have, defer

---

### Task 11: Rematerializable Values
**File:** `src/ssa/liveness.zig:446`
**TODO:** `Remove rematerializable values`

**Current State:** Spills all values

**Go Reference:**
- `~/learning/go/src/cmd/compile/internal/ssa/regalloc.go` - rematerialize

**Implementation Plan:**
1. Mark constants as rematerializable
2. Recompute instead of spill when needed

**Priority:** Optimization only, defer

---

### Task 12: Parallel Copy Cycle Breaking
**File:** `src/ssa/regalloc.zig:690`
**TODO:** `Implement proper parallel copy with cycle breaking`

**Current State:** May have issues with phi cycles

**Go Reference:**
- `~/learning/go/src/cmd/compile/internal/ssa/regalloc.go`

**Implementation Plan:**
1. Detect cycles in parallel copies
2. Break cycles with temporary register

**Priority:** Edge case, defer until bug found

---

### Task 13: Remaining SSA Ops
**File:** `src/frontend/ssa_builder.zig:1049`
**TODO:** `implement remaining ops`

**Current State:** Returns null for unhandled ops

**Implementation Plan:**
1. Add ops as needed when new features require them

**Priority:** Add as needed

---

## Execution Order

1. **Task 1: For-In Loops** - High impact for self-hosting
2. **Task 2: Implicit Slice End** - Completes slice feature
3. **Task 4: Array Copy** - Go semantics correctness
4. **Task 5: String Variable Assignment** - String completeness
5. **Task 7: Function Return Type** - Type safety
6. **Task 3: Computed Base Index** - Edge case
7. **Task 6: Pointer Field Store** - Edge case
8. **Task 8: Function Types** - Advanced feature
9. Tasks 9-13: Defer until needed

---

## Progress Tracking

| Task | Status | Tests | Commit |
|------|--------|-------|--------|
| 1. For-In Loops | DONE | test_for_array, test_for_break, test_for_continue, test_for_slice | |
| 2. Implicit Slice End | DONE | test_slice_implicit_end, test_slice_full, test_slice_implicit_start | |
| 3. Computed Base Index | TODO | | |
| 4. Array Copy | DONE | test_array_copy, test_array_copy_values | |
| 5. String Variable | DONE | test_string_var_copy, test_string_var_copy2 | |
| 6. Pointer Field Store | TODO | | |
| 7. Function Return Type | DONE | (existing tests verify correctness) | |
| 8. Function Types | TODO | | |
| 9-13. Optimizations | DEFERRED | | |

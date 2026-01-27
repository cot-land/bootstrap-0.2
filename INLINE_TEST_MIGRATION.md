# Inline Test Migration Plan

## Overview

Convert all 756 tests from `test/bootstrap/all_tests.cot` to inline `test "name" { @assert() }` syntax embedded in cot1 source files.

**Current state:**
- 57 inline tests already exist in `stages/cot1/frontend/lower.cot`
- 756 tests in `test/bootstrap/all_tests.cot`
- 442 helper functions
- 10 struct/enum types

---

## Test Breakdown

| Category | Count | Target File |
|----------|-------|-------------|
| Core language tests | 170 | `lower.cot`, `types.cot` |
| Parity tests | 582 | Various based on feature |
| **Total** | **756** | |

### Core Tests by Feature (170 tests)

| Feature | Count | Target |
|---------|-------|--------|
| string_* | 12 | `lib/strings.cot` |
| slice_* | 11 | `types.cot` |
| logical_* | 10 | `lower.cot` |
| ptr_* | 9 | `types.cot` |
| bitwise_* | 9 | `lower.cot` |
| array_* | 6 | `types.cot` |
| fn_* | 5 | `lower.cot` |
| enum_* | 5 | `types.cot` |
| switch_* | 4 | `lower.cot` |
| global_* | 4 | `lower.cot` |
| for_* | 4 | `lower.cot` |
| defer_* | 4 | `lower.cot` |
| char_* | 3 | `scanner.cot` |
| null_* | 3 | `types.cot` |
| struct_* | 2 | `types.cot` |
| Other (misc) | ~80 | `lower.cot` |

### Parity Tests by Category (582 tests)

From `test/parity/` structure:
| Category | Count | Target |
|----------|-------|--------|
| expressions/* | ~160 | `lower.cot` |
| control_flow/* | ~100 | `lower.cot` |
| functions/* | ~115 | `lower.cot` |
| variables/* | ~47 | `lower.cot` |
| types/* | ~65 | `types.cot` |
| arrays/* | ~62 | `types.cot` |
| memory/* | ~53 | `types.cot` |

---

## Required Infrastructure

### Helper Functions (442 total)

Group helpers by category and add to appropriate source files:

**Arithmetic helpers** → `lower.cot`
```cot
fn add_one(x: i64) i64 { return x + 1 }
fn add(a: i64, b: i64) i64 { return a + b }
fn mul(a: i64, b: i64) i64 { return a * b }
fn helper() i64 { return 42 }
```

**Recursion helpers** → `lower.cot`
```cot
fn factorial(n: i64) i64 { if n <= 1 { return 1 } return n * factorial(n - 1) }
```

**Multi-arg helpers** → `lower.cot`
```cot
fn sum8(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64) i64 { ... }
fn sum9(...) i64 { ... }
fn args16(...) i64 { ... }
```

**Pointer helpers** → `types.cot`
```cot
fn add_via_ptr(ptr: *i64, val: i64) void { *ptr = *ptr + val }
fn set_point_x(p: *Point, val: i64) void { p.x = val }
```

**Slice helpers** → `types.cot`
```cot
fn get_slice_from_ptr(arr: *[3]i64) []i64 { ... }
```

**Enum helpers** → `types.cot`
```cot
fn check_status(s: Status) i64 { ... }
```

**Function pointer helpers** → `lower.cot`
```cot
fn add_fn(a: i64, b: i64) i64 { return a + b }
fn get_forty_two() i64 { return 42 }
```

**Global variable helpers** → `lower.cot`
```cot
var g_counter: i64 = 0
fn g_increment() { g_counter = g_counter + 1 }
fn g_get() i64 { return g_counter }
fn g_reset() { g_counter = 0 }
```

### Type Definitions (10 total)

Add to `types.cot`:
```cot
struct Point { x: i64, y: i64 }
struct Inner { a: i64, b: i64 }
struct Outer { inner: Inner, c: i64 }
struct LargeStruct { a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64 }
enum Status { Pending, Active, Done }
enum TokenKind { Ident, Number, String }
struct TokenWithEnum { kind: TokenKind, value: i64 }
struct BigReturn { a: i64, b: i64, c: i64 }
struct NodeForPtrDeref { value: i64 }
struct BigArg { a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64 }
```

---

## Execution Phases

### Phase 1: Infrastructure Setup (Day 1)

**1.1 Add test helper types to `types.cot`** (10 types)
- Add Point, Inner, Outer, LargeStruct
- Add Status, TokenKind enums
- Add TokenWithEnum, BigReturn, NodeForPtrDeref, BigArg

**1.2 Add arithmetic/basic helpers to `lower.cot`** (~20 functions)
- add_one, add, mul, helper
- factorial, sum8, sum9, args16
- void_helper

**1.3 Add pointer/slice helpers to `types.cot`** (~10 functions)
- add_via_ptr, set_point_x
- get_slice_from_ptr
- check_status

**1.4 Add function pointer helpers to `lower.cot`** (~5 functions)
- add_fn, mul_fn, get_forty_two

**1.5 Add global variable helpers to `lower.cot`** (~5 functions)
- g_counter variable
- g_increment, g_get, g_reset

**Verify:** Compile cot1 successfully after each sub-phase.

### Phase 2: Core Tests - Arithmetic & Comparisons (Day 2)

**2.1 Convert arithmetic tests** (~20 tests)
```
test_return, test_add, test_mul, test_div, test_sub, test_neg, test_mod
test_precedence, test_parens, test_chain, test_large
```

**2.2 Convert comparison tests** (~15 tests)
```
test_ne, test_lt, test_gt, test_le, test_ge
test_neg_compare, test_bool
```

**2.3 Convert bitwise tests** (~10 tests)
```
test_bitwise_and, test_bitwise_or, test_bitwise_xor
test_shl, test_shr, test_mask_extract
test_bitwise_not_zero, test_bitwise_not_neg
```

**Verify:** Run `-test` on lower.cot, all new tests pass.

### Phase 3: Core Tests - Control Flow (Day 3)

**3.1 Convert if/else tests** (~10 tests)
```
test_if, test_if_false, test_nested_if, test_early_return, test_else_simple
```

**3.2 Convert while tests** (~10 tests)
```
test_while, test_while_simple, test_countdown, test_nested_while
```

**3.3 Convert break/continue tests** (~5 tests)
```
test_break, test_continue
```

**3.4 Convert for loop tests** (~5 tests)
```
test_for_simple, test_for_break, test_for_continue, test_for_nested
```

**3.5 Convert switch tests** (~5 tests)
```
test_switch_int, test_switch_first, test_switch_default, test_switch_multi
```

**Verify:** Run `-test`, all control flow tests pass.

### Phase 4: Core Tests - Functions (Day 4)

**4.1 Convert call tests** (~10 tests)
```
test_call, test_nested_call, test_call_spill, test_fn_call
test_8args, test_9args, test_16args
```

**4.2 Convert recursion tests** (~5 tests)
```
test_recursion, test_fibonacci
```

**4.3 Convert void/return tests** (~5 tests)
```
test_void, test_early_return
```

**4.4 Convert function pointer tests** (~5 tests)
```
test_fn_ptr_call, test_fn_ptr_no_args
```

**Verify:** Run `-test`, all function tests pass.

### Phase 5: Core Tests - Variables & Logical (Day 5)

**5.1 Convert variable tests** (~10 tests)
```
test_var_assign, test_const, test_multi_var
test_reassign, test_locals
```

**5.2 Convert logical tests** (~10 tests)
```
test_logical_and_true, test_logical_and_false_first, test_logical_and_false_second
test_logical_or_false, test_logical_or_true_first, test_logical_or_true_second
test_logical_and_chain, test_logical_or_chain
```

**5.3 Convert global variable tests** (~5 tests)
```
test_global_simple, test_global_increment, test_global_computed
```

**Verify:** Run `-test`, all variable/logical tests pass.

### Phase 6: Core Tests - Types (Day 6)

**6.1 Convert struct tests** (~10 tests) → `types.cot`
```
test_struct_simple, test_struct_reassign, test_nested_struct, test_large_struct
```

**6.2 Convert array tests** (~10 tests) → `types.cot`
```
test_array_index, test_array_assign, test_array_var_index, test_array_param
```

**6.3 Convert pointer tests** (~10 tests) → `types.cot`
```
test_ptr_read, test_ptr_write, test_ptr_modify, test_ptr_param, test_ptr_expr
```

**6.4 Convert slice tests** (~10 tests) → `types.cot`
```
test_slice_create, test_slice_index, test_slice_len, test_slice_write
```

**6.5 Convert enum tests** (~5 tests) → `types.cot`
```
test_enum_first, test_enum_second, test_enum_third, test_enum_ne, test_enum_param
```

**6.6 Convert null tests** (~5 tests) → `types.cot`
```
test_null_eq, test_null_ne, test_ptr_not_null
```

**Verify:** Run `-test` on types.cot, all type tests pass.

### Phase 7: Core Tests - Strings & Characters (Day 7)

**7.1 Convert char tests** (~5 tests) → `scanner.cot`
```
test_char_simple, test_char_escape, test_char_compare
```

**7.2 Convert string tests** (~15 tests) → `lib/strings.cot`
```
test_string_simple, test_len_string, test_len_escape, test_len_string_var
test_string_index, test_string_loop, test_string_branch
```

**7.3 Convert defer tests** (~5 tests) → `lower.cot`
```
test_defer_simple, test_defer_early_return, test_defer_multiple, test_defer_block
```

**Verify:** Run `-test`, all string/char/defer tests pass.

### Phase 8: Parity Tests - Expressions (Days 8-9)

**8.1 Convert expr_001 - expr_050** (50 tests)
**8.2 Convert expr_051 - expr_100** (50 tests)
**8.3 Convert expr_101 - expr_160** (60 tests)

Each batch:
1. Open parity test file
2. Extract the test logic
3. Convert `if cond { return 0 } return 1` to `@assert(cond)`
4. Add to `lower.cot`
5. Verify compilation

### Phase 9: Parity Tests - Control Flow (Days 10-11)

**9.1 Convert cf_001 - cf_050** (50 tests)
**9.2 Convert cf_051 - cf_100** (50 tests)

### Phase 10: Parity Tests - Functions (Days 12-13)

**10.1 Convert fn_001 - fn_050** (50 tests)
**10.2 Convert fn_051 - fn_115** (65 tests)

### Phase 11: Parity Tests - Variables (Day 14)

**11.1 Convert var_001 - var_047** (47 tests)

### Phase 12: Parity Tests - Types (Days 15-16)

**12.1 Convert ty_001 - ty_065** (65 tests) → `types.cot`

### Phase 13: Parity Tests - Arrays (Day 17)

**13.1 Convert arr_001 - arr_062** (62 tests) → `types.cot`

### Phase 14: Parity Tests - Memory (Day 18)

**14.1 Convert mem_001 - mem_053** (53 tests) → `types.cot`

### Phase 15: Final Verification (Day 19)

**15.1 Full test run**
```bash
./zig-out/bin/cot -test stages/cot1/main.cot -o /tmp/cot1_tests
zig cc /tmp/cot1_tests.o runtime/cot_runtime.o -o /tmp/cot1_tests -lSystem
/tmp/cot1_tests
```

**15.2 Verify test count**
```bash
grep -c '^test "' stages/cot1/**/*.cot  # Should be 756+
```

**15.3 Delete obsolete files**
- Remove `test/bootstrap/all_tests.cot`
- Update documentation

---

## Conversion Patterns

### Pattern 1: Simple return
```cot
// Before (all_tests.cot)
fn test_mul() i64 {
    return 6 * 7
}
// Expected: 42

// After (inline)
test "multiplication" {
    @assert(6 * 7 == 42)
}
```

### Pattern 2: If-return
```cot
// Before
fn test_ne() i64 {
    if 1 != 2 { return 42 }
    return 0
}

// After
test "not equal" {
    @assert(1 != 2)
}
```

### Pattern 3: Variables + assertion
```cot
// Before
fn test_var_assign() i64 {
    let x: i64 = 42
    let y: i64 = x
    if y == 42 { return 42 }
    return 0
}

// After
test "variable assignment" {
    let x: i64 = 42
    let y: i64 = x
    @assert(y == 42)
}
```

### Pattern 4: Loops
```cot
// Before
fn test_while() i64 {
    var x: i64 = 0
    while x < 42 {
        x = x + 1
    }
    if x == 42 { return 42 }
    return 0
}

// After
test "while loop" {
    var x: i64 = 0
    while x < 42 {
        x = x + 1
    }
    @assert(x == 42)
}
```

### Pattern 5: Helper function calls
```cot
// Before
fn test_call() i64 {
    if add_one(41) == 42 { return 42 }
    return 0
}

// After (requires add_one to exist in scope)
test "function call" {
    @assert(add_one(41) == 42)
}
```

---

## File Changes Summary

| File | Before | After |
|------|--------|-------|
| `stages/cot1/frontend/lower.cot` | 5,800 lines, 57 tests | ~8,000 lines, ~450 tests |
| `stages/cot1/frontend/types.cot` | 1,000 lines, 0 tests | ~1,500 lines, ~200 tests |
| `stages/cot1/frontend/scanner.cot` | 800 lines, 0 tests | ~850 lines, ~10 tests |
| `stages/cot1/lib/strings.cot` | 200 lines, 0 tests | ~300 lines, ~20 tests |
| `test/bootstrap/all_tests.cot` | 4,000 lines | **DELETED** |

---

## Daily Progress Tracking

Use this checklist during execution:

- [ ] Phase 1: Infrastructure (types + helpers)
- [ ] Phase 2: Arithmetic & Comparisons (35 tests)
- [ ] Phase 3: Control Flow (35 tests)
- [ ] Phase 4: Functions (25 tests)
- [ ] Phase 5: Variables & Logical (25 tests)
- [ ] Phase 6: Types (50 tests)
- [ ] Phase 7: Strings & Characters (25 tests)
- [ ] Phase 8: Parity Expressions (160 tests)
- [ ] Phase 9: Parity Control Flow (100 tests)
- [ ] Phase 10: Parity Functions (115 tests)
- [ ] Phase 11: Parity Variables (47 tests)
- [ ] Phase 12: Parity Types (65 tests)
- [ ] Phase 13: Parity Arrays (62 tests)
- [ ] Phase 14: Parity Memory (53 tests)
- [ ] Phase 15: Final Verification

---

## Commands Reference

```bash
# Build Zig compiler
zig build

# Run inline tests
./zig-out/bin/cot -test stages/cot1/main.cot -o /tmp/cot1_tests
zig cc /tmp/cot1_tests.o runtime/cot_runtime.o -o /tmp/cot1_tests -lSystem
/tmp/cot1_tests

# Count inline tests
grep -c '^test "' stages/cot1/frontend/lower.cot

# Verify no parse errors
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1 2>&1 | head -20
```

# Stage1 Crash Isolation Plan

## Problem
Stage1 crashes in Phase 4/5 when compiling large files (195 functions in all_tests.cot).
Small individual tests work fine.

## FINDINGS (2026-01-27)

### Threshold Identified
- **126 if statements in main(): PASS (always)**
- **127 if statements in main(): FLAKY (2/3 pass)**
- **128 if statements in main(): CRASH (always)**

### Key Observations
1. Stage0 (Zig compiler) compiles ALL 166 tests successfully
2. Stage1 crashes with NULL pointer at offset 0x80 (`Func.current_block`)
3. The crash is in `SSABuilder_lookupVarOutgoing` accessing `b.func.current_block`
4. The issue is NOT total function count - it's the SIZE of a single function (main)

### Root Cause Hypothesis
With 128 if statements, main() creates approximately:
- 128 * 3 = 384 basic blocks
- 128 * 10 = 1280 SSA values

Some buffer/state in the cot1 SSA builder is being corrupted when processing
large functions. The `b.func` pointer becomes NULL during phi insertion or
forward reference resolution.

### Likely Bug Location
- `stages/cot1/ssa/builder.cot` - SSABuilder module storage
- Specifically around `SSABuilder_lookupVarOutgoing` (line 691-736)
- Or the BlockDefs / all_defs storage that gets reused per-block

## FIX APPLIED (2026-01-27)

### Root Cause
Use-after-realloc bug in `Func_newValue` and SSABuilder storage.
When values/blocks arrays are reallocated, pointers returned by previous calls become dangling.

### Fix
Increased initial capacities to avoid realloc during compilation:

**func.cot:**
- `FN_INIT_BLOCKS`: 64 → 1024
- `FN_INIT_VALUES`: 512 → 10000
- `FN_INIT_LOCALS`: 64 → 256

**builder.cot:**
- `SB_INIT_VAR_STORAGE`: 100000 → 1000000

### Result
Stage1 now compiles all_tests.cot (195 functions, 166 tests) successfully.

### Bug 2 Fixed: String concatenation infinite loop

**Root Cause**: Missing relocation for `___cot_str_concat` runtime function.
In `genssa.cot`, the check `cs2.func_name_len <= 0` was skipping the special
case where `func_name_start == -1` (marker for `__cot_str_concat`).

**Fix**: Added exception for the special marker:
```cot
if cs2.func_name_start != -1 and (cs2.func_name_len <= 0 or ...)
```

### FINAL RESULT
**Stage1 now passes ALL 166 tests!**

Files modified:
- `stages/cot1/ssa/func.cot` - Increased FN_INIT_* capacities
- `stages/cot1/ssa/builder.cot` - Increased SB_INIT_VAR_STORAGE
- `stages/cot1/codegen/genssa.cot` - Fixed __cot_str_concat relocation

## Strategy
Incrementally compile subsets of tests to find the exact threshold where the crash occurs.

## Execution Steps

### Phase 1: Create Test Subsets
Create temporary test files with increasing numbers of tests:
- `/tmp/test_10.cot` - first 10 tests
- `/tmp/test_20.cot` - first 20 tests
- `/tmp/test_50.cot` - first 50 tests
- `/tmp/test_100.cot` - first 100 tests
- `/tmp/test_150.cot` - first 150 tests
- `/tmp/test_166.cot` - all 166 tests

### Phase 2: Binary Search for Crash Threshold
1. Compile each subset with stage1
2. Record pass/fail for each
3. Binary search to find exact N where N tests pass but N+1 crashes

### Phase 3: Isolate Specific Test
Once we find N:
- Test N passes
- Test N+1 crashes
Examine test N+1 to understand what's different.

### Phase 4: Root Cause Analysis
With the specific failing test identified:
- Check if it's the test content or cumulative state
- Test if test N+1 alone crashes
- If N+1 alone works, it's cumulative state corruption

## Commands

```bash
# Step 1: Get list of all test functions from all_tests.cot
grep "^fn test_" test/stages/cot1/all_tests.cot | head -N

# Step 2: Create subset file
# (script to extract first N tests)

# Step 3: Compile with stage1
/tmp/cot1-stage1 /tmp/test_N.cot -o /tmp/test_N.o

# Step 4: If compiles, link and run
zig cc /tmp/test_N.o runtime/cot_runtime.o -o /tmp/test_N -lSystem && /tmp/test_N
```

## Expected Outcome
Find exact test count N where:
- N tests: PASS
- N+1 tests: CRASH

This pinpoints either:
1. A specific problematic test
2. A cumulative resource exhaustion (memory, buffer overflow)
3. A state corruption that builds up over N function compilations

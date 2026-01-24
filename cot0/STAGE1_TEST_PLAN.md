# Stage1 Test Parity Plan

**Created: 2026-01-24**
**Updated: 2026-01-24**

## Goal

Make all 166 e2e tests that pass with the Zig compiler also pass when compiled with cot0-stage1.

## Current Status: 166/166 passing (100%) ✅ COMPLETE

| Category | Status |
|----------|--------|
| Basic return, arithmetic, locals | ✅ PASS |
| Function calls | ✅ PASS |
| If/else, while, break, continue | ✅ PASS |
| Structs, nested structs | ✅ PASS |
| Arrays | ✅ PASS |
| Pointer dereference | ✅ PASS |
| Defer | ✅ PASS |
| Comparisons, bitwise ops | ✅ PASS |
| Function pointers | ✅ PASS |
| String literals | ✅ PASS |
| String operations (copy, index, slice, concat) | ✅ PASS |
| Hex/binary/octal literals | ✅ PASS |
| Self-compilation | ✅ PASS |
| Global variables | ✅ PASS |
| Bitwise NOT | ✅ PASS |
| Large struct args (>16B) | ✅ PASS |
| Large struct returns (>16B) | ✅ PASS |
| 9+ argument function calls | ✅ PASS |
| else-if chains | ✅ PASS |

## All Issues Resolved

### Issue 1: Global Variables (BUG-058)
**Symptom**: Global variable reads return 0 instead of correct value

**Root Cause**: Unknown - global data section initialization or relocation issue

**Location**: `cot0/codegen/genssa.cot` or `cot0/obj/macho.cot`

### Issue 2: Bitwise NOT
**Symptom**: test_bitwise_not_zero, test_bitwise_not_neg fail

**Root Cause**: Bitwise NOT operation may not be implemented correctly

### Issue 3: Large Struct Arguments
**Symptom**: test_bug019_large_struct_arg, test_bug019b_large_struct_literal_arg fail

**Root Cause**: ARM64 ABI for passing large structs as arguments not fully implemented

### Issue 4: For Loops (by design)
**Symptom**: Parser error for `for i in 0..5` syntax

**Root Cause**: cot0 doesn't support range-based for loops

**Workaround**: Use while loops instead

## Fixed Issues

### ~~Issue 1: Function Pointers~~ FIXED
Function pointer calls now work correctly.

### ~~Issue 4: String Literals~~ FIXED (BUG-055)
String literals now work with proper escape sequence handling and s.ptr/s.len access.

## Execution Plan

### Phase 1: Fix Function Pointer Calls (Priority: CRITICAL)
1. Read how Zig handles `IRNodeKind.CallIndirect` in `src/ssa/ssa_builder.zig`
2. Check if cot0 has `CallIndirect` IR node type
3. Modify lowerer to emit `CallIndirect` for function pointer calls
4. Modify codegen to emit `BLR` instead of `BL` for indirect calls
5. Test function pointer calls work

### Phase 2: Fix Global Variables (Priority: HIGH)
1. Debug what value is being loaded for global variables
2. Check Mach-O symbol table entries for globals
3. Check relocation entries for global references
4. Compare with Zig compiler output using `nm` and `objdump`
5. Fix the issue in codegen or macho writer

### Phase 3: Fix String Literals (Priority: MEDIUM)
1. Debug what happens when a string literal is created
2. Check if ptr and len are both being stored
3. Check if len is being stored at the correct offset
4. Fix in lowerer or codegen

### Phase 4: Document For Loop Syntax (Priority: LOW)
1. Check if cot0 has for loop support
2. If not, document that tests should use while loops
3. Or add for-in-range parsing to match Zig

## Test Commands

```bash
# Build fresh stage1
./zig-out/bin/cot cot0/main.cot -o /tmp/cot0-stage1

# Test individual features
echo 'fn main() i64 { return 42 }' > /tmp/test.cot
/tmp/cot0-stage1 /tmp/test.cot -o /tmp/test.o
zig cc /tmp/test.o -o /tmp/test
/tmp/test; echo "Exit: $?"

# Check symbols
nm /tmp/test.o

# Compare with Zig compiler
./zig-out/bin/cot /tmp/test.cot -o /tmp/test_zig
nm /tmp/test_zig.o
```

## Success Criteria

All 166 tests from `test/e2e/all_tests.cot` must:
1. Compile successfully with cot0-stage1
2. Link successfully with zig cc
3. Run and produce the expected exit code

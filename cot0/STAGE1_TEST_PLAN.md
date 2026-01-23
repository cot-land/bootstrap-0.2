# Stage1 Test Parity Plan

**Created: 2026-01-24**

## Goal

Make all 166 e2e tests that pass with the Zig compiler also pass when compiled with cot0-stage1.

## Current Status

| Category | Status |
|----------|--------|
| Basic return, arithmetic, locals | PASS |
| Function calls | PASS |
| If/else, while, break, continue | PASS |
| Structs, nested structs | PASS |
| Arrays | PASS |
| Pointer dereference | PASS |
| Defer | PASS |
| Comparisons, bitwise ops | PASS |
| **Function pointers** | FAIL (link error) |
| **For loops** | FAIL (parser error) |
| **Global variables** | FAIL (wrong value) |
| **String literals** | FAIL (wrong value) |

## Identified Issues

### Issue 1: Function Pointers (CRITICAL)
**Symptom**: Linker error "undefined symbol: _f"

**Root Cause**: When calling through a function pointer variable like `f(20, 22)`, cot0 generates a call to external symbol `_f` instead of loading the function pointer from the local variable and calling indirectly through a register.

**Location**: Likely in `cot0/codegen/genssa.cot` or `cot0/ssa/builder.cot`

**Fix Required**: Detect when a call target is a local variable (function pointer type) and emit an indirect call (BLR instruction) instead of a direct call (BL instruction with relocation).

### Issue 2: For Loops (HIGH)
**Symptom**: "Parser error at position N"

**Root Cause**: cot0 parser doesn't recognize the `for i in 0..7` syntax.

**Location**: `cot0/frontend/parser.cot`

**Fix Required**: Add parsing support for for-in-range syntax, or document that cot0 uses a different for loop syntax.

### Issue 3: Global Variables (HIGH)
**Symptom**: Global variable reads return 0 instead of correct value

**Root Cause**: The global variable initial value is not being loaded correctly, or the symbol relocation is incorrect.

**Location**: Likely in `cot0/codegen/genssa.cot` (global load/store) or `cot0/obj/macho.cot` (relocations)

**Fix Required**: Debug global variable initialization and ensure relocations are correct.

### Issue 4: String Literals (MEDIUM)
**Symptom**: `s.len` returns 0 instead of string length

**Root Cause**: String slice is not being constructed properly, or the length field is not being set.

**Location**: Likely in `cot0/codegen/genssa.cot` or `cot0/frontend/lower.cot`

**Fix Required**: Debug string literal handling to ensure both ptr and len are correctly stored.

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

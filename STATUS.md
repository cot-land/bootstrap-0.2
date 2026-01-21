# Bootstrap 0.2 - Project Status

**Last Updated: 2026-01-21**

## ⚠️ CRITICAL: ALL 166 TESTS MUST PASS ON COT0 FIRST ⚠️

**THIS IS THE ONLY FOCUS. NOTHING ELSE MATTERS UNTIL THIS IS DONE.**

```
/tmp/cot0-stage1 test/e2e/all_tests.cot -o /tmp/tests && /tmp/tests
```

**DO NOT** attempt self-compilation.
**DO NOT** work on new features.
**DO NOT** do anything else.

**FIX COT0 UNTIL ALL 166 TESTS PASS.**

---

## Current State

| Component | Status |
|-----------|--------|
| Zig compiler (src/*.zig) | **COMPLETE** - 166 tests pass |
| cot0 compiler (cot0/*.cot) | **MATURING** - 35 tests pass (cot0-stage1) |
| cot0-stage1 simple programs | Works |
| cot0-stage1 test suite | **35 tests pass** (31 basic + 4 switch) |

### Test Progress

| Tier | Status | Test Functions |
|------|--------|----------------|
| 1-6.5 | ✅ PASS | Basic ops, control flow, loops, edge cases |
| 7 (Recursion) | ✅ PASS | factorial, fibonacci |
| 8 (Bool) | ✅ PASS | Boolean operations |
| 9 (Switch) | ✅ PASS | Switch expressions (4 tests) |
| External calls | ❌ BLOCKED | println needs relocations |
| Function types | ❌ BLOCKED | `var f: fn(...) -> T` not supported |

### Current Blockers

1. ~~**Slice syntax** - `arr[start:end]` not parsed~~ **COMPLETE**
2. ~~**For-in loops** - `for item in array { }` not supported~~ **COMPLETE**
3. ~~**Switch statements** - `switch x { }` not supported~~ **COMPLETE**
4. ~~**Recursion** - Return values not captured~~ **COMPLETE** (BUG-049)
5. **External function calls** - Need relocations for println, etc.
6. **Function type variables** - `var f: fn(...) -> T` not supported

### Recent Fixes (2026-01-21)

- **BUG-049: Recursion return values not captured** - Parameters now spilled to stack at function entry; left operand spilled before calls in binary expressions
- **BUG-050: ORN instruction encoding incorrect** - Fixed ARM64 ORN encoding (bits 28-24 = 01010, bit 21 = N)
- **Switch statements implemented** - Added full switch expression support: parsing, lowering to nested selects, CSEL codegen
- **BUG-046: For-in over slices** - Slice locals now store (ptr, len) at 16 bytes; for-in loads len from offset 8
- **For-in loops** - Added ForStmt to AST, parser, and lowerer (desugars to while loop like Zig compiler)
- **Modulo operator** - Fixed genssa_mod to compute `a - (a/b)*b` instead of just SDIV
- **BUG-043/BUG-044: Stack layout** - Fixed stack offset calculation to use actual local sizes instead of assuming 8 bytes per local
- **Slice syntax** - Parser handles `arr[start:end]`, slice type `[]T`, SliceExpr lowering, TYPE_SLICE for locals

### Tests Passing

| Feature | Status |
|---------|--------|
| Basic arithmetic | ✅ PASS |
| Function calls | ✅ PASS |
| Local variables | ✅ PASS |
| Comparisons | ✅ PASS |
| If/else | ✅ PASS |
| While loops | ✅ PASS |
| For-in (arrays) | ✅ PASS |
| For-in (slices) | ✅ PASS |
| Structs | ✅ PASS |
| Arrays | ✅ PASS |
| Pointers | ✅ PASS |
| Bitwise ops | ✅ PASS |
| Modulo | ✅ PASS |
| Slice indexing | ✅ PASS |
| Function types | ❌ FAIL |
| Switch | ❌ NOT IMPL |
- **null keyword** - Parser recognizes `null` literal (value 0)
- **Function type syntax** - `fn(i64, i64) -> i64` now parsed
- **Branch fixups** - Reset gs.branches_count between functions (following Zig pattern)
- **ARM64 scaled offset encoding** - LDR/STR with unsigned offset uses scaled immediates
- **Register clobbering** - Binary ops used X0 for results, clobbering parameters
- **Bitwise operators** - Added `&`, `|`, `^`, `<<`, `>>` support through all compiler layers

---

## The Goal

**cot0 must mature before self-hosting.**

Self-hosting (cot0 compiles itself) is the end goal, not the next step. cot0 needs significant work first.

---

## Maturation Path

### Phase 1: Make cot0 Robust (CURRENT)

- Add extensive debugging to cot0
- Copy logic from Zig compiler into cot0
- Fix bugs systematically using debug output

### Phase 2: Test Suite Passes with cot0-stage1

- Get cot0-stage1 to compile the 166-test suite
- All tests must pass when compiled BY cot0-stage1

### Phase 3: Build Confidence

- Compile increasingly complex programs
- Compare with Zig compiler output
- Fix discrepancies

### Phase 4: Self-Hosting (FUTURE)

- Only after phases 1-3 are complete
- cot0-stage1 compiles cot0/*.cot

---

## Zig Compiler Features (Complete)

- Integer literals, arithmetic, comparisons
- Boolean type, local variables
- Functions, recursion, if/else, while, for-in
- Structs, enums, switch
- Strings, arrays, slices
- Pointers, optionals
- Bitwise/logical operators
- Imports, globals, extern fn

---

## Documentation

| File | Purpose |
|------|---------|
| [CLAUDE.md](CLAUDE.md) | Architecture, maturation path |
| [SYNTAX.md](SYNTAX.md) | Language syntax |
| [BUGS.md](BUGS.md) | Bug tracking |
| [cot0/README.md](cot0/README.md) | cot0 overview |

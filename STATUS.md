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
| cot0 compiler (cot0/*.cot) | **MATURING** - 83/168 test functions compile |
| cot0-stage1 simple programs | Works |
| cot0-stage1 test suite | Partial - Tiers 1-13 work |

### Test Progress

| Tier | Status | Test Functions |
|------|--------|----------------|
| 1-14 | ✅ PASS | 88 functions (basic ops, control flow, structs, arrays, pointers, bitwise, null) |
| 15+ | ❌ BLOCKED | Needs slice syntax, for-in loops, switch statements |

### Current Blockers

1. **Slice syntax** - `arr[start:end]` not parsed
2. **For-in loops** - `for item in array { }` not supported
3. **Switch statements** - `switch x { }` not supported

### Recent Fixes (2026-01-21)

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

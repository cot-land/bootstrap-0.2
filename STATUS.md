# Bootstrap 0.2 - Project Status

**Last Updated: 2026-01-21**

## Current State

| Component | Status |
|-----------|--------|
| Zig compiler (src/*.zig) | **COMPLETE** - 166 tests pass |
| cot0 compiler (cot0/*.cot) | **MATURING** - compiles all 166 test functions |
| cot0-stage1 simple programs | Works |
| cot0-stage1 test suite | Parser crash on full main() - investigating |

### Test Progress

| Tier | Status | Test Functions |
|------|--------|----------------|
| 1-6.5 | PASS | Basic ops, control flow, loops, edge cases |
| 7-9 | PASS | Structs, arrays, pointers |
| 10-14 | PASS | Bitwise, logical, enums, null |
| 15 | PASS | Slices, string concat, @string |
| 16-17 | PASS | For-in loops, switch |
| 18 | BLOCKED | Function pointers (indirect calls broken) |
| 19-20 | PASS | Pointer arithmetic, bitwise NOT |
| 21-22 | PASS | Compound assignments, @intCast |
| 23-24 | PARTIAL | Defer (works), Globals (stale value bug) |
| 25-26 | PASS | Stress tests, bug regressions |

### Current Blockers

1. **Parser crash on full test file** - All 166 test functions compile, but parsing the full main() with 250+ statements causes crash (under investigation)
2. **Function pointer calls** - Indirect calls treated as external function calls
3. **Global variable stale value** - Multiple writes to same global use cached value

### Recent Fixes (2026-01-21)

- **BUG-053: Struct local stack allocation** - Struct locals now get proper size (16 bytes for Point, etc.)
- **BUG-052: Pointer-to-struct detection** - Disambiguates `Point` vs `*Point` by checking for `*` character
- **Pointer field access** - `ptr.*.x` and `ptr.*.y` now work correctly with proper offsets
- **Postfix ops on parenthesized expressions** - `(buf + 8).*` now works
- **Standalone block statements** - `{ ... }` inside functions now works
- **Nested parentheses** - `((a))` now works correctly
- **Statement buffer increase** - From 128 to 512 for larger functions
- **Compound assignments** - `+=`, `-=`, `*=`, `/=`, `&=`, `|=` now work
- **Void extern functions** - `extern fn free(ptr: *i64);` (no return type)
- **External function call relocations** - ARM64_RELOC_BRANCH26 for extern fn
- **BUG-049: Recursion return values** - Parameters spilled to stack at entry
- **BUG-050: ORN instruction encoding** - Fixed ARM64 ORN encoding

### Tests Passing

| Feature | Status |
|---------|--------|
| Basic arithmetic | PASS |
| Function calls | PASS |
| Local variables | PASS |
| Comparisons | PASS |
| If/else | PASS |
| While loops | PASS |
| For-in (arrays/slices) | PASS |
| Structs | PASS |
| Arrays | PASS |
| Pointers | PASS |
| Pointer field access (ptr.*.field) | PASS |
| Bitwise ops | PASS |
| Bitwise NOT (~) | PASS |
| Modulo | PASS |
| Slice indexing | PASS |
| Switch | PASS |
| External calls | PASS |
| Compound assign | PASS |
| Pointer arithmetic | PASS |
| Defer | PASS |
| Function pointers | FAIL (codegen) |
| Global variables | PARTIAL (stale value bug) |

---

## The Goal

**cot0 must mature before self-hosting.**

Self-hosting (cot0 compiles itself) is the end goal, not the next step.

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

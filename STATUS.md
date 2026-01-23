# Project Status

**Last Updated: 2026-01-24**

## Quick Status

| Component | Status |
|-----------|--------|
| Zig compiler | ✅ 166 tests pass |
| Stage 1 (Zig → cot0) | ⚠️ Most tests pass, 4 features broken |
| Stage 2 (cot0 → cot0) | ⏸️ Blocked (awaiting Stage 1 fixes) |
| Self-hosting | In progress |

## Current Priority: Stage1 Test Parity

**Goal**: Make all 166 e2e tests pass when compiled with cot0-stage1.

See [cot0/STAGE1_TEST_PLAN.md](cot0/STAGE1_TEST_PLAN.md) for detailed execution plan.

### Stage1 Test Results

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
| **Function pointers** | ❌ FAIL (link error: undefined `_f`) |
| **Global variables** | ❌ FAIL (returns 0) |
| **String literals** | ❌ FAIL (`s.len` returns 0) |
| **For loops** | ❌ FAIL (parser error) |

### Known Issues (Priority Order)

1. **Function Pointers** (CRITICAL)
   - Symptom: Linker error "undefined symbol: _f"
   - Cause: Generates direct call instead of indirect call through register

2. **Global Variables** (HIGH)
   - Symptom: Returns 0 instead of initialized value
   - Cause: Global data relocation issue

3. **String Literals** (MEDIUM)
   - Symptom: `s.len` returns 0 instead of string length
   - Cause: String slice construction issue

4. **For Loops** (LOW)
   - Symptom: Parser error on `for i in 0..7` syntax
   - Cause: Parser doesn't recognize range syntax

## What Works (with Zig Compiler)

- ✅ All 166 end-to-end tests pass
- ✅ Simple struct field access (`p.x = 10`)
- ✅ Nested struct field access (`o.inner.y = 20`)
- ✅ Array indexing with struct fields (`points[0].x`)
- ✅ Defer statements with proper scope handling
- ✅ Control flow (if/else, while, break, continue)
- ✅ Function calls with up to 8 arguments
- ✅ String literals and global variables
- ✅ DWARF debug info (source locations in crash reports)

## Recent Milestones

- **2026-01-24**: Identified Stage1 test failures, created test plan
- **2026-01-24**: Added SSABuilder_verify() for SSA validation/debugging
- **2026-01-24**: Added parser nesting depth protection (Parser_incNest/decNest)
- **2026-01-24**: Added node index validation in lowerBlockCheckTerminated
- **2026-01-24**: Added BlockStmt handling in lowerStmt
- **2026-01-24**: Fixed nested struct field assignment (TypeRegistry-based lookup)
- **2026-01-24**: SSA passes with full logic (schedule, lower, decompose, expand_calls)
- **2026-01-23**: Added defer statement support
- **2026-01-23**: Added FwdRef pattern to SSA builder
- **2026-01-23**: Added emitPhiMoves() for correct phi semantics
- **2026-01-23**: DWARF debug info implementation

## Documentation

| Document | Purpose |
|----------|---------|
| [README.md](README.md) | Project overview and vision |
| [CLAUDE.md](CLAUDE.md) | Development workflow |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Compiler design |
| [SELF_HOSTING.md](SELF_HOSTING.md) | Path to self-hosting |
| [cot0/COMPARISON.md](cot0/COMPARISON.md) | Function parity checklist |
| [cot0/STAGE1_TEST_PLAN.md](cot0/STAGE1_TEST_PLAN.md) | **Stage1 test parity plan** |

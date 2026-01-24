# Project Status

**Last Updated: 2026-01-24**

## Quick Status

| Component | Status |
|-----------|--------|
| Zig compiler | ✅ 166 tests pass |
| Stage 1 (Zig → cot0) | ⚠️ 21+ tests pass, 9+ arg calls fixed |
| Stage 2 (cot0 → cot0) | ⏸️ Blocked (crash during codegen) |
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
| Small structs (≤16 bytes) | ✅ PASS |
| Arrays | ✅ PASS |
| Pointer dereference/write | ✅ PASS |
| Comparisons, bitwise ops | ✅ PASS |
| Global variables | ✅ PASS |
| Crash handler integration | ✅ PASS |
| **9+ argument function calls** | ✅ PASS (fixed 2026-01-24) |
| **Large struct returns (>16B)** | ❌ FAIL (SIGSEGV - BUG-054) |
| **String literals** | ❌ FAIL (garbled output - BUG-055) |

### Known Issues (Priority Order)

1. **Self-compilation crash** (CRITICAL)
   - Symptom: cot0-stage1 crashes during Phase 4/5 (SSA/codegen) when compiling main.cot
   - Location: main.cot:1055 (during code generation)
   - Note: Same crash occurs with Zig-built cot0, indicating pre-existing issue
   - Investigating: Likely memory/pointer issue in SSA builder or codegen

2. **Large Struct Returns** (CRITICAL - BUG-054)
   - Symptom: SIGSEGV crash in programs returning structs >16 bytes
   - Cause: ARM64 ABI requires hidden pointer in x8 for large struct returns, not implemented in cot0
   - First failure: test_bug004_large_struct_return (line 1901 in all_tests.cot)

3. **String Literals** (HIGH - BUG-055)
   - Symptom: String content is garbled/wrong
   - Cause: String data relocation or slice construction issue in cot0

## What Works (with Zig Compiler)

- ✅ All 166 end-to-end tests pass
- ✅ Simple struct field access (`p.x = 10`)
- ✅ Nested struct field access (`o.inner.y = 20`)
- ✅ Array indexing with struct fields (`points[0].x`)
- ✅ Defer statements with proper scope handling
- ✅ Control flow (if/else, while, break, continue)
- ✅ Function calls with any number of arguments (9+ use stack)
- ✅ String literals and global variables
- ✅ DWARF debug info (source locations in crash reports)

## Recent Milestones

- **2026-01-24**: **Fixed 9+ argument function calls** - Parser extended to 16 args, ABI stack alignment fixed, genssa store handler updated
- **2026-01-24**: Converted all core fixed-size arrays to dynamic allocation (Value.args, Block.preds, local arrays in builder/genssa/lower/parser/regalloc/main)
- **2026-01-24**: Crash handler works in cot0-compiled programs (DWARF parsing, source location display)
- **2026-01-24**: Error reporting shows file:line:column with source context
- **2026-01-24**: 21+ basic tests verified passing (arithmetic, bitwise, control flow, functions, pointers, arrays, globals, small structs)
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

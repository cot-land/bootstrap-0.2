# Project Status

**Last Updated: 2026-01-24**

## Quick Status

| Component | Status |
|-----------|--------|
| Zig compiler | ✅ 166 tests pass |
| Stage 1 (Zig → cot0) | ⚠️ 146/166 tests pass (88%) |
| Stage 2 (cot0 → cot0) | ✅ Self-compilation works |
| Self-hosting | ✅ Achieved (2026-01-24) |

## Current Priority: Stage1 Test Parity

**Goal**: Make all 166 e2e tests pass when compiled with cot0-stage1.

**Progress**: 146 passing, 20 failing

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
| **String literals** | ✅ PASS (fixed BUG-055 2026-01-24) |
| **Self-compilation** | ✅ PASS (fixed BUG-057 2026-01-24) |
| **Hex literal parsing** | ✅ PASS (fixed 2026-01-24) |
| **Bitwise NOT** | ✅ PASS (fixed 2026-01-24) |
| **Global variable init** | ✅ PASS (fixed BUG-058 2026-01-24) |

### Known Issues (Priority Order)

1. **String operations** (10 tests failing)
   - Symptom: String copy, index, slice, concat not working
   - Cause: String type is a slice (ptr, len) - slice semantics need work

2. **@intCast truncation** (1 test failing)
   - Symptom: @intCast to smaller type doesn't truncate
   - Cause: cot0 lowerer passes through without conversion IR node

3. **Phi node tests** (2 tests failing)
   - test_phi_3way_driver, test_phi_4way_driver

4. **Large struct arguments** (2 tests failing)
   - test_bug019_large_struct_arg, test_bug019b_large_struct_literal_arg

### Recently Fixed

1. **Global variable initialization** (FIXED - BUG-058)
   - Cause: Globals written as zeros instead of initialized values
   - Fix: Added init_value/has_init to IRGlobal, write values to data section

2. **Bitwise NOT** (FIXED)
   - Cause: Op_fromIRUnaryOp expected enum values 0,1,2 but got IR_OP_* constants 18,19,20
   - Fix: Updated Op_fromIRUnaryOp in builder.cot

3. **Self-compilation crash** (FIXED - BUG-057)
   - Cause: malloc_IRLocal allocated only 32 bytes, but IRLocal is 80 bytes
   - Fix: Updated runtime/cot_runtime.zig malloc sizes

4. **String Literals** (FIXED - BUG-055)
   - Cause: TYPE_STRING not handled in FieldAccess, escape sequences not processed
   - Fix: Handle TYPE_STRING in lower.cot, process escapes in main.cot

5. **Hex Literals** (FIXED)
   - Cause: Scanner and parser didn't handle 0x prefix
   - Fix: Added hex/octal/binary literal support to scanner.cot and parser.cot

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

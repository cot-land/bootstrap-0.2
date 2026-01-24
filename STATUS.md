# Project Status

**Last Updated: 2026-01-24**

## Quick Status

| Component | Status |
|-----------|--------|
| Zig compiler | ✅ 166 tests pass |
| Stage 1 (Zig → cot0) | ✅ 166/166 tests pass (100%) |
| Stage 2 (cot0 → cot0) | ⚠️ Compiles with SSA errors |
| Self-hosting | ⚠️ Blocked by stage2 SSA errors |
| Fixed arrays removal | ✅ COMPLETE |

## Current Priority: Fix Stage 2 SSA Errors

**Goal**: Make stage2 produce correct code so stage3 = stage2.

**Issue**: When stage1 compiles cot0, there are SSA errors ("Invalid arg ir_rel=-1"). This is a separate bug from the fixed arrays issue (which is now resolved).

See [SELF_HOSTING.md](SELF_HOSTING.md) for details.

## Recent: Fixed Arrays Conversion (COMPLETE)

All accumulating fixed-size arrays have been converted to dynamic allocation:

- **IR Storage**: `ir_nodes`, `ir_locals`, `ir_funcs`, `constants`, `ir_globals` - all use realloc
- **Type Pool**: `types`, `params`, `fields` - all use realloc with capacity tracking
- **Node Pool**: Uses `capacity` field instead of hardcoded MAX_NODES

Remaining `MAX_*` constants are intentional per-function limits (SSA, codegen) that don't accumulate.

See [cot0/FIXED_ARRAYS_AUDIT.md](cot0/FIXED_ARRAYS_AUDIT.md) for full details.

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
| **Large struct returns (>16B)** | ✅ PASS |
| **String literals** | ✅ PASS (fixed BUG-055 2026-01-24) |
| **String operations** | ✅ PASS (copy, index, slice, concat all work) |
| **Large struct arguments (>16B)** | ✅ PASS (fixed BUG-019 2026-01-24) |
| **Self-compilation** | ✅ PASS (fixed BUG-057 2026-01-24) |
| **Hex literal parsing** | ✅ PASS (fixed 2026-01-24) |
| **Bitwise NOT** | ✅ PASS (fixed 2026-01-24) |
| **Global variable init** | ✅ PASS (fixed BUG-058 2026-01-24) |
| **else-if chains** | ✅ PASS (fixed 2026-01-24) |

### Known Issues (Priority Order)

None - all 166 tests pass!

### Recently Fixed

1. **Large struct arguments (BUG-019)** (FIXED - 2026-01-24)
   - Cause: ARM64 ABI requires pass-by-reference for >16B structs
   - Fix: Added expand_calls pass integration, updated SSA builder to emit Move for large struct params,
     updated FuncBuilder_addParam to take size parameter (following Zig pattern)
   - Files: expand_calls.cot, builder.cot, ir.cot, lower.cot, genssa.cot

2. **String concatenation** (FIXED - 2026-01-24)
   - Cause: GenState_call had argument placement bugs for calls returning strings
   - Fix: Added dedicated StringConcat SSA op (like Zig) with proper codegen handling
   - All string tests now pass: copy, index, slice, concat (literal+literal, var+literal, var+var)

2. **Global variable initialization** (FIXED - BUG-058)
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

- **2026-01-24**: **Completed fixed arrays removal** - All accumulating arrays (IR, types, nodes) now use dynamic allocation with realloc. Stage2 no longer crashes from capacity exhaustion.
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
| [cot0/FIXED_ARRAYS_AUDIT.md](cot0/FIXED_ARRAYS_AUDIT.md) | Dynamic allocation status (COMPLETE) |

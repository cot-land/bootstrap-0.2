# cot1 Gaps vs Zig Bootstrap Compiler

**Last Updated: 2026-01-26**

## Summary

Dead code analysis complete: **cot1 has zero dead code** in its compilation path.

### Recent Progress

| Module | Status | Notes |
|--------|--------|-------|
| ssa/compile.cot | **NEW** | Pass infrastructure (Pass, Config, PassStats, Phase) |
| ssa/debug.cot | **NEW** | SSA dump (Text/DOT) and verify() function |
| ssa/op.cot | **UPDATED** | Added Op_toString for debug output |
| lib/source.cot | **NEW** | Position tracking (Pos, Span, Source, Position) |
| lib/reporter.cot | **NEW** | ErrorReporter with error codes, accumulates errors |
| @ptrCast builtin | **NEW** | Two-argument pointer type conversion |
| eprint/eprintln | **NEW** | Polymorphic stderr printing (strings + integers) |

### Remaining Gaps

| Category | Zig Lines | Cot1 Lines | Gap |
|----------|-----------|------------|-----|
| Frontend | 14,643 | 14,036 | 4% smaller |
| SSA | 8,538 | 6,564 | 23% smaller |
| Codegen | 162,000+ | 3,832 | 97% smaller |

## Reachable Files (45 files, 100% function usage)

```
main.cot
├── lib/ (14 files)
│   ├── stdlib.cot, list.cot, strmap.cot
│   ├── error.cot, debug.cot, debug_init.cot
│   ├── safe_io.cot, safe_array.cot, safe_alloc.cot
│   ├── validate.cot, invariants.cot, import.cot
│   ├── source.cot, reporter.cot
├── frontend/ (8 files)
│   ├── token.cot, scanner.cot, ast.cot, types.cot
│   ├── parser.cot, checker.cot, ir.cot, lower.cot
├── ssa/ (15 files)
│   ├── value.cot, block.cot, func.cot, op.cot
│   ├── builder.cot, dom.cot, abi.cot
│   ├── stackalloc.cot, liveness.cot, regalloc.cot
│   ├── compile.cot, debug.cot
│   └── passes/ (4 files)
│       ├── expand_calls.cot, lower.cot
│       ├── decompose.cot, schedule.cot
├── codegen/ (2 files)
│   ├── genssa.cot, arm64.cot
├── arm64/ (2 files)
│   ├── asm.cot, regs.cot
└── obj/ (2 files)
    ├── macho.cot, dwarf.cot
```

## Critical Missing Modules

### 1. src/ssa/compile.zig - Pass Infrastructure (DONE)

**Purpose**: Orchestrates compiler passes over SSA
**Status**: Implemented in ssa/compile.cot
**Lines**: Zig 547 | Cot1 ~250

Implemented:
- `Pass` struct with name, required/disabled flags
- `PassId` enum for pass identification
- `Config` struct for optimization flags
- `PassStats` struct for timing/metrics
- `Phase` enum for compilation phases
- `VerifyResult` struct for verification feedback

### 2. src/ssa/debug.zig - SSA Verification (DONE)

**Purpose**: HTML/DOT visualization and invariant verification
**Status**: Implemented in ssa/debug.cot
**Lines**: Zig 645 | Cot1 ~350

Implemented:
- `DumpFormat` enum (Text, Dot)
- `Func_dumpText()` - human-readable dump
- `Func_dumpDot()` - Graphviz DOT format
- `Func_verify()` - SSA invariant verification
- `BlockKind_name()` helper
- Edge bidirectional invariant checks

### 3. src/frontend/source.zig - Position Tracking (DONE)

**Purpose**: Compact position representation and line/column computation
**Status**: Implemented in lib/source.cot
**Lines**: Zig 336 | Cot1 303

Implemented:
- `Pos` functions (byte-offset tracking)
- `Position` struct (line/column for display)
- `Span` struct (position ranges)
- `Source` struct with lazy line offset computation
- `Source_printErrorContext()` for caret indicators

### 4. src/frontend/errors.zig - Error Collection (DONE)

**Purpose**: Structured error handling without immediate panic
**Status**: Implemented in lib/reporter.cot
**Lines**: Zig 346 | Cot1 348

Implemented:
- `ErrorReporter` struct (accumulates up to 64 errors)
- Error codes (1xx scanner, 2xx parser, 3xx type, 4xx semantic)
- `ErrorReporter_hasErrors()`, `ErrorReporter_errorCount()`
- Convenience functions for common error patterns
- Source context printing with caret indicators

### 5. src/codegen/arm64.zig - ARM64 Codegen (1% complete)

**Purpose**: Complete ARM64 code generation
**Impact**: Most ARM64 features not implemented
**Lines in Zig**: 162,787 | **Cot1**: 299 (codegen/arm64.cot)

This is embedded in genssa.cot (~2000 lines) but still far from complete.

## Missing Optimization Passes

Zig has 8+ optimization passes not implemented in cot1:

| Pass | Purpose | Status |
|------|---------|--------|
| `earlyDeadcode` | Remove unused values | MISSING |
| `earlyCopyElim` | Eliminate trivial copies | MISSING |
| `opt` | Generic optimization rewrites | MISSING |
| `genericCSE` | Common subexpression elimination | MISSING |
| `prove` | Prove unreachable branches | MISSING |
| `nilCheckElim` | Eliminate redundant nil checks | MISSING |
| `critical` | Critical edge splitting | MISSING |
| `layout` | Block reordering for icache | MISSING |

## Module Completion Status

| Zig Module | Cot1 Equivalent | Status |
|------------|-----------------|--------|
| frontend/token.zig | frontend/token.cot | 95% |
| frontend/scanner.zig | frontend/scanner.cot | 95% |
| frontend/ast.zig | frontend/ast.cot | 95% |
| frontend/types.zig | frontend/types.cot | 95% |
| frontend/parser.zig | frontend/parser.cot | 95% |
| frontend/checker.zig | frontend/checker.cot | 95% |
| frontend/ir.zig | frontend/ir.cot | 95% |
| frontend/lower.zig | frontend/lower.cot | 95% |
| frontend/source.zig | lib/source.cot | 90% |
| frontend/errors.zig | lib/reporter.cot | 95% |
| frontend/ssa_builder.zig | ssa/builder.cot | 67% |
| ssa/value.zig | ssa/value.cot | 95% |
| ssa/block.zig | ssa/block.cot | 95% |
| ssa/func.zig | ssa/func.cot | 95% |
| ssa/op.zig | ssa/op.cot | 95% |
| ssa/dom.zig | ssa/dom.cot | 95% |
| ssa/liveness.zig | ssa/liveness.cot | 70% |
| ssa/regalloc.zig | ssa/regalloc.cot | 54% |
| ssa/stackalloc.zig | ssa/stackalloc.cot | 91% |
| ssa/compile.zig | ssa/compile.cot | 50% |
| ssa/debug.zig | ssa/debug.cot | 55% |
| ssa/passes/lower.zig | ssa/passes/lower.cot | 95% |
| ssa/passes/expand_calls.zig | ssa/passes/expand_calls.cot | 95% |
| ssa/passes/decompose.zig | ssa/passes/decompose.cot | 95% |
| ssa/passes/schedule.zig | ssa/passes/schedule.cot | 95% |
| arm64/asm.zig | arm64/asm.cot | 60% |
| arm64/regs.zig | arm64/regs.cot | 95% |
| codegen/arm64.zig | codegen/genssa.cot | 2% |
| obj/macho.zig | obj/macho.cot | 75% |
| dwarf.zig | obj/dwarf.cot | 30% |
| driver.zig | main.cot | 40% (modular vs monolithic) |

## Priority for Self-Hosting

### High Priority (Required for reliable self-hosting)
1. ~~**Error collection**~~ - DONE (lib/reporter.cot)
2. ~~**SSA verification**~~ - DONE (ssa/debug.cot with verify())
3. **Complete ARM64 codegen** - Current stub may have gaps (2% complete)

### Medium Priority (Improves reliability)
4. ~~**Pass infrastructure**~~ - DONE (ssa/compile.cot)
5. ~~**Position tracking**~~ - DONE (lib/source.cot)
6. **DWARF generation** - Debug support (30% complete)
7. **SSA builder** - IR to SSA conversion (67% complete)
8. **Register allocator** - Physical register assignment (54% complete)

### Low Priority (Optimizations)
9. **Optimization passes** - earlyDeadcode, CSE, etc. (all MISSING)
10. **Block layout** - Better cache behavior (MISSING)
11. **Debug HTML output** - Compiler development (DOT/text done, HTML missing)

## Test Files (Not Dead Code)

29 files (3,894 lines) are test files run independently:
- scanner_test.cot, parser_test.cot, lower_test.cot, etc.
- These are intentionally not imported by main.cot
- They are run through separate test harnesses

## Next Steps

1. **Verify self-hosting works** - BUG-063 SIGBUS crash needs resolution
2. **Add error collection** - ErrorReporter for multiple errors
3. **Add SSA verification** - verify() function to catch bugs
4. **Audit ARM64 codegen** - Ensure all needed instructions are encoded

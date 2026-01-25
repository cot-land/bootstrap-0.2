# cot1 Gaps vs Zig Bootstrap Compiler

**Last Updated: 2026-01-26**

## Summary

Dead code analysis complete: **cot1 has zero dead code** in its compilation path.

However, cot1 is missing significant functionality compared to the Zig bootstrap compiler:

| Category | Zig Lines | Cot1 Lines | Gap |
|----------|-----------|------------|-----|
| Frontend | 14,643 | 14,036 | 4% smaller |
| SSA | 8,538 | 6,564 | 23% smaller |
| Codegen | 162,000+ | 3,832 | 97% smaller |

## Reachable Files (41 files, 100% function usage)

```
main.cot
├── lib/ (12 files)
│   ├── stdlib.cot, list.cot, strmap.cot
│   ├── error.cot, debug.cot, debug_init.cot
│   ├── safe_io.cot, safe_array.cot, safe_alloc.cot
│   ├── validate.cot, invariants.cot, import.cot
├── frontend/ (8 files)
│   ├── token.cot, scanner.cot, ast.cot, types.cot
│   ├── parser.cot, checker.cot, ir.cot, lower.cot
├── ssa/ (13 files)
│   ├── value.cot, block.cot, func.cot, op.cot
│   ├── builder.cot, dom.cot, abi.cot
│   ├── stackalloc.cot, liveness.cot, regalloc.cot
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

### 1. src/ssa/compile.zig - Pass Infrastructure (MISSING)

**Purpose**: Orchestrates compiler passes over SSA
**Impact**: No systematic pass management; passes hardcoded in main.cot
**Lines in Zig**: 547

Key missing:
- `Pass` struct with dependencies and analysis invalidation
- `Config` struct for optimization flags
- `compile()` function for running pass sequence
- `runPass()` function for individual passes

### 2. src/ssa/debug.zig - SSA Verification (MISSING)

**Purpose**: HTML/DOT visualization and invariant verification
**Impact**: Cannot visualize SSA or verify correctness
**Lines in Zig**: 645

Key missing:
- `dump()` function for text/DOT/HTML output
- `verify()` function for SSA invariants
- `ValueSnapshot`, `BlockSnapshot` for tracking changes

### 3. src/frontend/source.zig - Position Tracking (MISSING)

**Purpose**: Compact position representation and line/column computation
**Impact**: Position tracking scattered across modules
**Lines in Zig**: 336

Key missing:
- `Pos` struct (compact byte-offset)
- `Position` struct (line/column)
- `Span` struct (position ranges)
- Line/column computation from byte offset

### 4. src/frontend/errors.zig - Error Collection (PARTIAL)

**Purpose**: Structured error handling without immediate panic
**Impact**: All errors are panics; cannot collect multiple errors
**Lines in Zig**: 346 | **Cot1**: ~200 (lib/error.cot)

Key missing:
- `ErrorReporter` struct (accumulates errors)
- `ErrorCode` enum (40+ structured codes)
- `hasErrors()`, `getErrors()` methods

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
| frontend/source.zig | None | 0% MISSING |
| frontend/errors.zig | lib/error.cot | 30% |
| frontend/ssa_builder.zig | ssa/builder.cot | 67% |
| ssa/value.zig | ssa/value.cot | 95% |
| ssa/block.zig | ssa/block.cot | 95% |
| ssa/func.zig | ssa/func.cot | 95% |
| ssa/op.zig | ssa/op.cot | 95% |
| ssa/dom.zig | ssa/dom.cot | 95% |
| ssa/liveness.zig | ssa/liveness.cot | 70% |
| ssa/regalloc.zig | ssa/regalloc.cot | 54% |
| ssa/stackalloc.zig | ssa/stackalloc.cot | 91% |
| ssa/compile.zig | None | 0% MISSING |
| ssa/debug.zig | None | 0% MISSING |
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
1. **Error collection** - Need to handle multiple errors without panic
2. **SSA verification** - Need to verify generated code is correct
3. **Complete ARM64 codegen** - Current stub may have gaps

### Medium Priority (Improves reliability)
4. **Pass infrastructure** - Organize passes systematically
5. **Position tracking** - Better error messages
6. **DWARF generation** - Debug support

### Low Priority (Optimizations)
7. **Optimization passes** - earlyDeadcode, CSE, etc.
8. **Block layout** - Better cache behavior
9. **Debug HTML output** - Compiler development

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

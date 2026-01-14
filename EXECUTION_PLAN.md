# Cot 0.2 Bootstrap Execution Plan

## Executive Summary

This document outlines a complete rewrite of the Cot bootstrap compiler using Go's proven compiler architecture. The goal is to eliminate the "whack-a-mole" debugging pattern that plagued previous attempts.

**This is Cot's third rewrite.** We will not need a fourth - but only if we follow Go's architecture faithfully.

**Key Insight:** Previous attempts failed in the BACKEND (register allocation, codegen), not the frontend. The frontend from bootstrap works. We must fix the backend FIRST.

See also:
- [CLAUDE.md](CLAUDE.md) - Development guidelines and Zig 0.15 API reference
- [IMPROVEMENTS.md](IMPROVEMENTS.md) - Honest assessment of current state
- [REGISTER_ALLOC.md](REGISTER_ALLOC.md) - Go's 6-phase regalloc algorithm (3,137 lines)
- [DATA_STRUCTURES.md](DATA_STRUCTURES.md) - Go-to-Zig data structure translations
- [TESTING_FRAMEWORK.md](TESTING_FRAMEWORK.md) - Comprehensive testing infrastructure

---

## Implementation Approach

**Zig → Zig with Go Patterns**

We are porting the working bootstrap compiler (`~/cot-land/bootstrap/src/*.zig`) to a new, cleaner implementation (`bootstrap-0.2/src/`) following Go's compiler architecture patterns from `~/learning/go/src/cmd/compile/`.

Key principles:
- Port **concepts**, not line-by-line code
- Follow Go's proven architecture (multi-phase, scope hierarchy, type interning)
- Use Zig 0.15 idioms (ArrayListUnmanaged, arena allocators)
- Write comprehensive tests as we go

---

## Why Backend First?

Bootstrap's bugs tell the story:

| Bug | Root Cause | Where |
|-----|------------|-------|
| BUG-019 | var declarations crash | Codegen |
| BUG-020 | enum usage crashes | Codegen |
| BUG-021 | switch returns wrong values | Codegen |
| BUG-008 | String field access | Codegen |
| BUG-009 | Field offset resolution | Codegen |
| BUG-010 | Large struct handling | Codegen |

The pattern is clear: **ALL the blocking bugs are in codegen/regalloc.**

The frontend (parser, type checker) works. Porting it is straightforward. What failed is the MCValue-based integrated codegen approach - we must replace it with Go's proper 6-phase register allocator.

---

## Source Material

All implementations reference:

**Go 1.22 compiler** at `~/learning/go/src/cmd/compile/`:
- `internal/ssa/regalloc.go` - 3,137 lines of register allocation
- `internal/ssa/lower.go` - Generic to arch-specific lowering
- `internal/arm64/ssa.go` - ARM64 code generation
- `internal/syntax/` - Scanner, parser
- `internal/types2/` - Type checking (go/types package)

**Bootstrap compiler** at `~/cot-land/bootstrap/src/`:
- `scanner.zig` - Working lexer
- `parser.zig` - Working parser
- `ast.zig` - AST definitions
- `check.zig` - Type checker
- `ir.zig` - IR definitions
- `lower.zig` - AST to IR lowering
- `driver.zig` - Compilation driver

---

## Current Status

### Phase 0: SSA Foundation - COMPLETE ✓

| Component | Status | Location | Go Reference |
|-----------|--------|----------|--------------|
| SSA Value | **DONE** | `src/ssa/value.zig` | `ssa/value.go` |
| SSA Block | **DONE** | `src/ssa/block.zig` | `ssa/block.go` |
| SSA Func | **DONE** | `src/ssa/func.zig` | `ssa/func.go` |
| SSA Op | **DONE** | `src/ssa/op.zig` | `ssa/op.go` |
| Dominator Tree | **DONE** | `src/ssa/dom.zig` | `ssa/dom.go` |
| Pass Infrastructure | **DONE** | `src/ssa/compile.zig` | `ssa/compile.go` |
| Debug/Verify | **DONE** | `src/ssa/debug.zig` | - |
| Test Helpers | **DONE** | `src/ssa/test_helpers.zig` | - |

### Phase 1: Liveness Analysis - COMPLETE ✓

| Component | Status | Location |
|-----------|--------|----------|
| LiveInfo structure | **DONE** | `src/ssa/liveness.zig` |
| LiveMap (block→live values) | **DONE** | `src/ssa/liveness.zig` |
| Backward dataflow | **DONE** | `src/ssa/liveness.zig` |

### Phase 2: Register Allocator - COMPLETE ✓

| Component | Status | Location |
|-----------|--------|----------|
| ValState/RegState | **DONE** | `src/ssa/regalloc.zig` |
| ARM64 register set | **DONE** | `src/ssa/regalloc.zig` |
| Linear scan allocation | **DONE** | `src/ssa/regalloc.zig` |
| Spill handling | **DONE** | `src/ssa/regalloc.zig` |

### Phase 3: Lowering Pass - COMPLETE ✓

| Component | Status | Location |
|-----------|--------|----------|
| Generic → ARM64 ops | **DONE** | `src/ssa/passes/lower.zig` |
| ARM64Op enum | **DONE** | `src/ssa/passes/lower.zig` |
| Lowering rules | **DONE** | `src/ssa/passes/lower.zig` |

### Phase 4: Code Generation - COMPLETE ✓

| Component | Status | Location |
|-----------|--------|----------|
| Generic codegen | **DONE** | `src/codegen/generic.zig` |
| ARM64 codegen | **DONE** | `src/codegen/arm64.zig` |
| ARM64 instruction encoding | **DONE** | `src/arm64/asm.zig` |

### Phase 5: Object Output - COMPLETE ✓

| Component | Status | Location |
|-----------|--------|----------|
| Mach-O writer | **DONE** | `src/obj/macho.zig` |

---

## Phase 6: Frontend Port - IN PROGRESS

Porting the working frontend from `bootstrap/src/` to `bootstrap-0.2/src/frontend/` following Go's architecture patterns.

### Phase 6.1: Token System - COMPLETE ✓

| Component | Status | Location | Reference |
|-----------|--------|----------|-----------|
| Token enum | **DONE** | `src/frontend/token.zig` | `go/token/token.go` |
| Precedence method | **DONE** | `src/frontend/token.zig` | `go/token/token.go` |
| Keyword lookup | **DONE** | `src/frontend/token.zig` | `go/token/token.go` |
| Token strings | **DONE** | `src/frontend/token.zig` | `go/token/token.go` |

### Phase 6.2: Source Management - COMPLETE ✓

| Component | Status | Location | Reference |
|-----------|--------|----------|-----------|
| Pos (offset) | **DONE** | `src/frontend/source.zig` | `go/token/position.go` |
| Position (line:col) | **DONE** | `src/frontend/source.zig` | `go/token/position.go` |
| Span (start:end) | **DONE** | `src/frontend/source.zig` | `go/token/position.go` |
| Source file | **DONE** | `src/frontend/source.zig` | `go/token/position.go` |

### Phase 6.3: Error Handling - COMPLETE ✓

| Component | Status | Location | Reference |
|-----------|--------|----------|-----------|
| ErrorCode enum | **DONE** | `src/frontend/errors.zig` | Go error patterns |
| Error struct | **DONE** | `src/frontend/errors.zig` | Go error patterns |
| ErrorReporter | **DONE** | `src/frontend/errors.zig` | Go error patterns |

### Phase 6.4: Scanner - COMPLETE ✓

| Component | Status | Location | Reference |
|-----------|--------|----------|-----------|
| Scanner struct | **DONE** | `src/frontend/scanner.zig` | `go/scanner/scanner.go` |
| Token scanning | **DONE** | `src/frontend/scanner.zig` | `go/scanner/scanner.go` |
| String literals | **DONE** | `src/frontend/scanner.zig` | - |
| Number literals | **DONE** | `src/frontend/scanner.zig` | - |
| Comments | **DONE** | `src/frontend/scanner.zig` | - |

### Phase 6.5: AST - COMPLETE ✓

| Component | Status | Location | Reference |
|-----------|--------|----------|-----------|
| Node types | **DONE** | `src/frontend/ast.zig` | `go/ast/ast.go` |
| Decl union | **DONE** | `src/frontend/ast.zig` | `go/ast/ast.go` |
| Expr union | **DONE** | `src/frontend/ast.zig` | `go/ast/ast.go` |
| Stmt union | **DONE** | `src/frontend/ast.zig` | `go/ast/ast.go` |
| Ast storage | **DONE** | `src/frontend/ast.zig` | - |

### Phase 6.6: Parser - COMPLETE ✓

| Component | Status | Location | Reference |
|-----------|--------|----------|-----------|
| Parser struct | **DONE** | `src/frontend/parser.zig` | `go/parser/parser.go` |
| Declaration parsing | **DONE** | `src/frontend/parser.zig` | `go/parser/parser.go` |
| Expression parsing | **DONE** | `src/frontend/parser.zig` | Pratt parsing |
| Statement parsing | **DONE** | `src/frontend/parser.zig` | `go/parser/parser.go` |
| Type parsing | **DONE** | `src/frontend/parser.zig` | `go/parser/parser.go` |

### Phase 6.7: Type System - COMPLETE ✓

| Component | Status | Location | Reference |
|-----------|--------|----------|-----------|
| BasicKind enum | **DONE** | `src/frontend/types.zig` | `go/types/basic.go` |
| Type union | **DONE** | `src/frontend/types.zig` | `go/types/type.go` |
| TypeRegistry | **DONE** | `src/frontend/types.zig` | `go/types/universe.go` |
| Composite types | **DONE** | `src/frontend/types.zig` | `go/types/` |
| Type predicates | **DONE** | `src/frontend/types.zig` | `go/types/predicates.go` |
| Type equality | **DONE** | `src/frontend/types.zig` | `go/types/typeterm.go` |
| Assignability | **DONE** | `src/frontend/types.zig` | `go/types/assignments.go` |

### Phase 6.8: Type Checker - COMPLETE ✓

| Component | Status | Location | Reference |
|-----------|--------|----------|-----------|
| Symbol struct | **DONE** | `src/frontend/checker.zig` | `go/types/object.go` |
| Scope struct | **DONE** | `src/frontend/checker.zig` | `go/types/scope.go` |
| Checker struct | **DONE** | `src/frontend/checker.zig` | `go/types/check.go` |
| Two-phase checking | **DONE** | `src/frontend/checker.zig` | `go/types/resolver.go` |
| Expression checking | **DONE** | `src/frontend/checker.zig` | `go/types/expr.go` |
| Statement checking | **DONE** | `src/frontend/checker.zig` | `go/types/stmt.go` |
| Type resolution | **DONE** | `src/frontend/checker.zig` | `go/types/typexpr.go` |
| Method registry | **DONE** | `src/frontend/checker.zig` | `go/types/methodset.go` |

### Phase 6.9: IR Definitions - TODO

| Component | Status | Location | Reference |
|-----------|--------|----------|-----------|
| IR Op enum | TODO | `src/frontend/ir.zig` | `bootstrap/ir.zig` |
| IR Instruction | TODO | `src/frontend/ir.zig` | `bootstrap/ir.zig` |
| IR Function | TODO | `src/frontend/ir.zig` | `bootstrap/ir.zig` |
| IR Block | TODO | `src/frontend/ir.zig` | `bootstrap/ir.zig` |

Key IR operations to support:
- Arithmetic: add, sub, mul, div, mod
- Comparison: eq, ne, lt, le, gt, ge
- Memory: load, store, alloca, get_field_ptr
- Control: br, br_cond, ret, call
- Constants: const_int, const_bool, const_string
- Aggregates: struct_init, array_init

### Phase 6.10: AST to IR Lowering - TODO

| Component | Status | Location | Reference |
|-----------|--------|----------|-----------|
| Lowerer struct | TODO | `src/frontend/lower.zig` | `bootstrap/lower.zig` |
| Expr lowering | TODO | `src/frontend/lower.zig` | `bootstrap/lower.zig` |
| Stmt lowering | TODO | `src/frontend/lower.zig` | `bootstrap/lower.zig` |
| Decl lowering | TODO | `src/frontend/lower.zig` | `bootstrap/lower.zig` |
| SSA conversion | TODO | `src/frontend/lower.zig` | Go's SSA builder |

Key lowering patterns:
- Binary ops → IR binary instructions
- If statements → conditional branches + merge blocks
- While loops → header + body + back-edge blocks
- Function calls → IR call instruction with ABI handling
- Struct access → get_field_ptr + load

### Phase 6.11: Compilation Driver - TODO

| Component | Status | Location | Reference |
|-----------|--------|----------|-----------|
| Driver struct | TODO | `src/frontend/driver.zig` | `bootstrap/driver.zig` |
| Pipeline orchestration | TODO | `src/frontend/driver.zig` | - |
| Debug output flags | TODO | `src/frontend/driver.zig` | - |

Pipeline stages:
1. Source → Scanner → Tokens
2. Tokens → Parser → AST
3. AST → Checker → Typed AST
4. Typed AST → Lowerer → IR
5. IR → SSA Builder → SSA
6. SSA → Passes → Optimized SSA
7. SSA → RegAlloc → Register-allocated SSA
8. SSA → Codegen → Machine code
9. Machine code → Object writer → .o file

---

## Phase 7: Integration & Testing

### Phase 7.1: End-to-End Pipeline - TODO

| Task | Status |
|------|--------|
| Connect frontend to SSA backend | TODO |
| Compile simple function | TODO |
| Run compiled binary | TODO |
| Verify correct output | TODO |

### Phase 7.2: Test Suite - TODO

| Task | Status |
|------|--------|
| Port bootstrap test cases | TODO |
| Golden file tests | TODO |
| Error message tests | TODO |
| Edge case tests | TODO |

### Phase 7.3: Self-Hosting Preparation - TODO

| Task | Status |
|------|--------|
| Compiler compiles simple .cot | TODO |
| Compiler compiles scanner.cot | TODO |
| Compiler compiles itself | TODO |

---

## File Structure (Current)

```
bootstrap-0.2/
├── build.zig
├── CLAUDE.md                    # Development guidelines
├── EXECUTION_PLAN.md            # This file
├── IMPROVEMENTS.md              # Honest assessment
├── REGISTER_ALLOC.md            # Go's regalloc algorithm
├── DATA_STRUCTURES.md           # Go-to-Zig translations
├── TESTING_FRAMEWORK.md         # Testing infrastructure
│
├── src/
│   ├── main.zig                 # Entry point, module exports
│   │
│   ├── core/                    # Foundation (DONE)
│   │   ├── types.zig            # ID, TypeInfo, RegMask
│   │   ├── errors.zig           # Error types
│   │   └── testing.zig          # Test utilities
│   │
│   ├── ssa/                     # SSA representation (DONE)
│   │   ├── value.zig            # SSA values
│   │   ├── block.zig            # Basic blocks
│   │   ├── func.zig             # SSA function
│   │   ├── op.zig               # Operations
│   │   ├── dom.zig              # Dominators
│   │   ├── compile.zig          # Pass infrastructure
│   │   ├── debug.zig            # Debug output
│   │   ├── test_helpers.zig     # Test fixtures
│   │   ├── liveness.zig         # Liveness analysis (DONE)
│   │   ├── regalloc.zig         # Register allocator (DONE)
│   │   │
│   │   └── passes/              # Optimization passes
│   │       └── lower.zig        # Lowering (DONE)
│   │
│   ├── codegen/                 # Code generation (DONE)
│   │   ├── generic.zig          # Reference implementation
│   │   └── arm64.zig            # ARM64 codegen
│   │
│   ├── arm64/                   # ARM64 specifics (DONE)
│   │   └── asm.zig              # Instruction encoding
│   │
│   ├── obj/                     # Object output (DONE)
│   │   └── macho.zig            # Mach-O format
│   │
│   └── frontend/                # Frontend (IN PROGRESS)
│       ├── token.zig            # Token types (DONE)
│       ├── source.zig           # Source positions (DONE)
│       ├── errors.zig           # Error handling (DONE)
│       ├── scanner.zig          # Lexer (DONE)
│       ├── ast.zig              # AST nodes (DONE)
│       ├── parser.zig           # Parser (DONE)
│       ├── types.zig            # Type system (DONE)
│       ├── checker.zig          # Type checker (DONE)
│       ├── ir.zig               # IR definitions (TODO)
│       ├── lower.zig            # AST to IR (TODO)
│       └── driver.zig           # Compilation driver (TODO)
│
└── test/
    ├── golden/                  # Golden file snapshots
    ├── cases/                   # Directive tests
    └── integration/             # Cross-module tests
```

---

## Success Criteria

Bootstrap-0.2 succeeds when:

1. **Frontend pipeline works:**
   - Source → AST (parser)
   - AST → Typed AST (checker)
   - Typed AST → IR (lowerer)

2. **Backend pipeline works:**
   - IR → SSA
   - SSA → Lowered SSA
   - SSA → Register-allocated SSA
   - SSA → Machine code
   - Machine code → Object file

3. **End-to-end works:**
   - Compile simple .cot programs
   - Run and get correct output
   - All bootstrap test cases pass

4. **Self-hosting works:**
   - Compiler compiles itself
   - No crashes, no wrong values

---

## What NOT to Do

These patterns killed previous attempts:

1. **Don't implement MCValue** - This integrated approach was tried and failed. Use Go's separated regalloc.

2. **Don't guess at register contents** - Track explicitly with ValState and RegState.

3. **Don't skip liveness analysis** - Required for correct spill selection.

4. **Don't port line-by-line** - Port concepts, adapt to Go patterns.

5. **Don't debug symptoms** - Understand the algorithm, then implement.

6. **Don't cut corners** - Implement all phases. Partial implementations create subtle bugs.

---

## Next Steps (Remaining Work)

### Immediate (Phase 6.9-6.11)

1. **Create IR definitions** (`src/frontend/ir.zig`)
   - Port IR Op enum from bootstrap
   - Create IR Instruction, Function, Block types
   - Match bootstrap's IR structure

2. **Create AST lowerer** (`src/frontend/lower.zig`)
   - Lower expressions to IR
   - Lower statements to IR
   - Handle control flow (if, while, for)
   - Handle function calls

3. **Create compilation driver** (`src/frontend/driver.zig`)
   - Connect all pipeline stages
   - Add debug output flags
   - Handle command-line arguments

### Then (Phase 7)

4. **Connect frontend to backend**
   - IR → SSA conversion
   - Run through backend pipeline
   - Emit object file

5. **Test end-to-end**
   - Port bootstrap test cases
   - Verify correct execution
   - Fix any integration bugs

### Finally (Self-hosting)

6. **Self-hosting**
   - Compile scanner.cot
   - Compile parser.cot
   - Compile the whole compiler

---

## Development Workflow

### For Frontend Components

1. **Read bootstrap source** - Understand what it does
2. **Read Go reference** - Understand Go's architecture
3. **Write tests first** - Define expected behavior
4. **Implement** - Follow Go patterns, adapted to Zig
5. **Run tests** - `zig build test`
6. **Update this doc** - Mark component complete

### Test Command

```bash
# Run all tests
zig build test

# Expected output: "Exit code: 0" with test output
```

---

## Test Counts

Current test status (as of Phase 6.8 completion):

- **154+ tests passing**
- Token tests: ~10
- Source tests: ~5
- Error tests: ~5
- Scanner tests: ~30
- AST tests: ~10
- Parser tests: ~40
- Types tests: ~10
- Checker tests: ~5
- SSA tests: ~30+
- Integration tests: ~10

All tests pass with `zig build test`.

# Cot 0.2 Bootstrap Execution Plan

## Executive Summary

This document outlines a complete rewrite of the Cot bootstrap compiler using Go's proven compiler architecture. The goal is to eliminate the "whack-a-mole" debugging pattern that plagued previous attempts.

**This is Cot's third rewrite.** We will not need a fourth.

See also:
- [CLAUDE.md](CLAUDE.md) - Development guidelines and Zig 0.15 API reference
- [IMPROVEMENTS.md](IMPROVEMENTS.md) - Go patterns implemented
- [TESTING_FRAMEWORK.md](TESTING_FRAMEWORK.md) - Comprehensive testing infrastructure

---

## Source Material

All implementations reference Go 1.22 compiler source at `~/learning/go/src/cmd/compile/`:
- `internal/ssa/` - SSA representation and passes
- `internal/syntax/` - Lexer and parser
- `internal/types2/` - Type checking
- `internal/ir/` - Intermediate representation
- `internal/ssagen/` - IR to SSA conversion
- `internal/arm64/` - ARM64 code generation
- `cmd/internal/obj/` - Object file generation

---

## Development Philosophy

### Test-Driven Development (TDD)

**Every feature follows this cycle:**

```
1. Write test → 2. Run test (fails) → 3. Implement → 4. Run test (passes) → 5. Commit
```

**Never:**
- Write code without a test first
- Fix a bug without a test that exposes it
- Commit code that doesn't pass all tests

### Why This Matters

Previous rewrites failed because:
- Cot 0.1: No tests. Bugs compounded.
- Bootstrap 1.0: Weak tests. Whack-a-mole debugging.

This time we have:
- 60+ unit tests in SSA infrastructure
- Golden file tests for output stability
- Integration tests for cross-module flows
- Table-driven tests for comprehensive coverage

---

## Current Status

### Phase 1: Foundation - COMPLETE

| Component | Status | Location | Tests |
|-----------|--------|----------|-------|
| Core types (ID, TypeRef) | **DONE** | `src/core/types.zig` | Unit tests |
| Error types | **DONE** | `src/core/errors.zig` | Unit tests |
| Test utilities | **DONE** | `src/core/testing.zig` | CountingAllocator |
| SSA Value | **DONE** | `src/ssa/value.zig` | 10+ tests |
| SSA Block | **DONE** | `src/ssa/block.zig` | Edge tests |
| SSA Func | **DONE** | `src/ssa/func.zig` | Integration tests |
| SSA Op | **DONE** | `src/ssa/op.zig` | Table-driven tests |
| Dominators | **DONE** | `src/ssa/dom.zig` | Algorithm tests |
| Pass infrastructure | **DONE** | `src/ssa/compile.zig` | Pass metadata |
| Debug output | **DONE** | `src/ssa/debug.zig` | text/dot/html |
| Phase snapshots | **DONE** | `src/ssa/debug.zig` | Comparison tests |
| Test helpers | **DONE** | `src/ssa/test_helpers.zig` | Fixtures, validators |
| Generic codegen | **DONE** | `src/codegen/generic.zig` | Golden files |
| ARM64 codegen stub | **DONE** | `src/codegen/arm64.zig` | Basic tests |

**Test Results:** `zig build test-all` - 60+ tests passing

---

## Remaining Phases

### Phase 2: Frontend

**Objective:** Parse Cot source to AST

| Component | File | Go Reference | Status |
|-----------|------|--------------|--------|
| Token types | `src/syntax/token.zig` | `syntax/token.go` | TODO |
| Scanner | `src/syntax/scanner.zig` | `syntax/scanner.go` | TODO |
| AST nodes | `src/syntax/nodes.zig` | `syntax/syntax.go` | TODO |
| Parser | `src/syntax/parser.zig` | `syntax/parser.go` | TODO |

**Tests to write first:**
- Scanner: tokenize all keywords, operators, literals
- Parser: parse minimal function, expressions, statements
- Golden files: AST dump format

### Phase 3: Type Checking

**Objective:** Semantic analysis and type inference

| Component | File | Go Reference | Status |
|-----------|------|--------------|--------|
| Type interface | `src/types/type.zig` | `types2/type.go` | TODO |
| Basic types | `src/types/basic.zig` | `types2/basic.go` | TODO |
| Scope | `src/types/scope.zig` | `types2/scope.go` | TODO |
| Checker | `src/types/checker.zig` | `types2/check.go` | TODO |

**Tests to write first:**
- Type checking expressions (arithmetic, comparisons)
- Error messages for type mismatches
- Scope resolution for nested blocks

### Phase 4: IR Lowering

**Objective:** AST to intermediate representation

| Component | File | Go Reference | Status |
|-----------|------|--------------|--------|
| IR nodes | `src/ir/node.zig` | `ir/node.go` | TODO |
| Expression IR | `src/ir/expr.zig` | `ir/expr.go` | TODO |
| Statement IR | `src/ir/stmt.zig` | `ir/stmt.go` | TODO |
| Walk phase | `src/walk/` | `walk/order.go` | TODO |

### Phase 5: SSA Construction

**Objective:** IR to SSA form

| Component | File | Go Reference | Status |
|-----------|------|--------------|--------|
| SSA builder | `src/ssagen/ssa.zig` | `ssagen/ssa.go` | TODO |
| Phi insertion | `src/ssagen/phi.zig` | `ssa/nilcheck.go` | TODO |

### Phase 6: Optimization Passes

**Objective:** Improve SSA quality

| Pass | File | Status |
|------|------|--------|
| Dead code elimination | `src/ssa/passes/deadcode.zig` | TODO |
| Common subexpression | `src/ssa/passes/cse.zig` | TODO |
| Phi elimination | `src/ssa/passes/phielim.zig` | TODO |
| Lower to machine ops | `src/ssa/passes/lower.zig` | TODO |

### Phase 7: Register Allocation

**Objective:** Assign registers to SSA values

| Component | File | Go Reference | Status |
|-----------|------|--------------|--------|
| Linear scan | `src/ssa/regalloc.zig` | `ssa/regalloc.go` | TODO |
| Stack slots | `src/ssa/stackalloc.zig` | `ssa/stackalloc.go` | TODO |

### Phase 8: Code Generation

**Objective:** SSA to machine code

| Component | File | Status |
|-----------|------|--------|
| ARM64 codegen | `src/codegen/arm64.zig` | Stub exists |
| Instruction encoding | `src/arm64/asm.zig` | TODO |
| ABI handling | `src/arm64/abi.zig` | TODO |

### Phase 9: Object Output

**Objective:** Emit executable

| Component | File | Status |
|-----------|------|--------|
| Mach-O output | `src/obj/macho.zig` | TODO |
| Symbol table | `src/obj/sym.zig` | TODO |
| Relocations | `src/obj/reloc.zig` | TODO |

---

## File Structure (Current)

```
bootstrap-0.2/
├── build.zig                    # Build configuration
├── CLAUDE.md                    # Development guidelines
├── EXECUTION_PLAN.md            # This file
├── IMPROVEMENTS.md              # Go patterns implemented
├── TESTING_FRAMEWORK.md         # Testing documentation
│
├── src/
│   ├── main.zig                 # Entry point, module exports
│   │
│   ├── core/                    # Foundation
│   │   ├── types.zig            # ID, TypeRef, shared types
│   │   ├── errors.zig           # CompileError, VerifyError
│   │   └── testing.zig          # CountingAllocator
│   │
│   ├── ssa/                     # SSA representation (Phase 1 - DONE)
│   │   ├── value.zig            # SSA values
│   │   ├── block.zig            # Basic blocks
│   │   ├── func.zig             # SSA function
│   │   ├── op.zig               # Operation definitions
│   │   ├── dom.zig              # Dominator tree
│   │   ├── compile.zig          # Pass infrastructure
│   │   ├── debug.zig            # Dump, verify, snapshots
│   │   └── test_helpers.zig     # Test fixtures
│   │
│   └── codegen/                 # Code generation
│       ├── generic.zig          # Reference implementation
│       └── arm64.zig            # ARM64 (stub)
│
├── test/                        # Test infrastructure
│   ├── golden/                  # Golden file snapshots
│   │   ├── ssa/                 # SSA dumps
│   │   └── codegen/             # Codegen output
│   ├── cases/                   # Directive tests
│   ├── integration/             # Cross-module tests
│   └── runners/                 # Test utilities
│
└── runtime/                     # Runtime library (TBD)
```

---

## Development Workflow

### For Each Component

1. **Read Go reference** - Understand the algorithm/data structure
2. **Write tests first** - Define expected behavior
3. **Implement** - Match Go's approach in Zig
4. **Run tests** - `zig build test-all`
5. **Add golden files** - Lock down output format
6. **Update docs** - Mark complete in this file
7. **Commit** - With descriptive message

### Daily Routine

```bash
# Start of session
zig build test-all           # Verify baseline

# After changes
zig build test               # Fast unit tests
zig build test-all           # Full suite before commit

# If golden files change
COT_UPDATE_GOLDEN=1 zig build test-golden
git diff test/golden/        # Review changes
```

---

## Success Criteria

1. **All tests pass** - Unit, integration, golden, directive
2. **No regressions** - Golden files catch unintended changes
3. **Clear error messages** - Error tests verify quality
4. **Go-equivalent architecture** - Each component matches reference
5. **Self-hosting ready** - Compiler can compile itself

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Zig 0.15 API surprises | Document all API differences in CLAUDE.md |
| Tests don't catch bugs | Golden files + table-driven tests |
| Architecture drift | Reference Go source for every component |
| Whack-a-mole debugging | Never fix without test first |
| Scope creep | Only Cot bootstrap features |

---

## Next Steps

1. **Parser** (`src/syntax/`)
   - Write scanner tests first
   - Implement scanner
   - Write parser tests
   - Implement parser
   - Add AST golden files

2. **Type checker** (`src/types/`)
   - Write type error tests first
   - Implement type system
   - Add error message golden files

The key is **test first, then implement**. No exceptions.

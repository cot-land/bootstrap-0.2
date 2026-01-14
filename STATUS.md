# Bootstrap 0.2 - Project Status

**Last Updated: 2026-01-14**

## Executive Summary

Bootstrap-0.2 is a clean-slate rewrite of the Cot compiler following Go's proven compiler architecture. The goal is to eliminate the "whack-a-mole" debugging pattern that killed previous attempts.

**Current State:** Frontend and IR→SSA pipeline COMPLETE. Ready for end-to-end compilation testing.

---

## Completed Components

### Backend (Phases 0-5) - COMPLETE

| Phase | Component | Location | Status |
|-------|-----------|----------|--------|
| 0 | SSA Value/Block/Func | `src/ssa/` | Done |
| 0 | SSA Op definitions | `src/ssa/op.zig` | Done |
| 0 | Dominator tree | `src/ssa/dom.zig` | Done |
| 0 | Pass infrastructure | `src/ssa/compile.zig` | Done |
| 1 | Liveness analysis | `src/ssa/liveness.zig` | Done |
| 2 | Register allocator | `src/ssa/regalloc.zig` | Done |
| 3 | Lowering pass | `src/ssa/passes/lower.zig` | Done |
| 4 | Generic codegen | `src/codegen/generic.zig` | Done |
| 4 | ARM64 codegen | `src/codegen/arm64.zig` | Done |
| 5 | Mach-O writer | `src/obj/macho.zig` | Done |

### Frontend (Phase 6) - COMPLETE

| Component | Location | Lines | Status |
|-----------|----------|-------|--------|
| Token system | `src/frontend/token.zig` | ~400 | Done |
| Source/Position | `src/frontend/source.zig` | ~200 | Done |
| Error handling | `src/frontend/errors.zig` | ~250 | Done |
| Scanner | `src/frontend/scanner.zig` | ~600 | Done |
| AST definitions | `src/frontend/ast.zig` | ~700 | Done |
| Parser | `src/frontend/parser.zig` | ~1200 | Done |
| Type system | `src/frontend/types.zig` | ~500 | Done |
| Type checker | `src/frontend/checker.zig` | ~1400 | Done |
| IR definitions | `src/frontend/ir.zig` | ~1300 | Done |
| AST lowering | `src/frontend/lower.zig` | ~800 | Done |
| IR→SSA builder | `src/frontend/ssa_builder.zig` | ~700 | Done |

### Testing Infrastructure - COMPLETE

- **172+ tests passing** as of 2026-01-14
- Table-driven tests for comprehensive coverage
- Golden file infrastructure ready
- Allocation tracking with CountingAllocator
- End-to-end pipeline test: Parse → Check → Lower → SSA

---

## Remaining Work

### Phase 7: End-to-End Integration

| Task | Status |
|------|--------|
| Connect frontend IR to SSA backend | **Ready** |
| Compile simple function (`return 42`) | TODO |
| Run compiled binary | TODO |
| Verify correct output | TODO |
| Port bootstrap test cases | TODO |

### Phase 8: Self-Hosting

| Task | Status |
|------|--------|
| Compiler compiles simple .cot | TODO |
| Compiler compiles scanner.cot | TODO |
| Compiler compiles itself | TODO |

---

## Architecture

```
Source → Scanner → Parser → AST
                              ↓
                         Type Checker
                              ↓
                         Lowerer → IR
                              ↓
                         SSABuilder → SSA Func
                              ↓
                    Passes (lower, regalloc)
                              ↓
                         Codegen → Machine Code
                              ↓
                         Object Writer → .o file
```

---

## File Structure

```
bootstrap-0.2/
├── src/
│   ├── main.zig              # Entry point, module exports
│   │
│   ├── core/                 # Foundation
│   │   ├── types.zig         # ID, TypeInfo, RegMask
│   │   ├── errors.zig        # Error types
│   │   └── testing.zig       # Test utilities
│   │
│   ├── ssa/                  # SSA representation
│   │   ├── value.zig         # SSA values
│   │   ├── block.zig         # Basic blocks
│   │   ├── func.zig          # SSA function
│   │   ├── op.zig            # Operations
│   │   ├── dom.zig           # Dominators
│   │   ├── compile.zig       # Pass infrastructure
│   │   ├── debug.zig         # Debug output
│   │   ├── test_helpers.zig  # Test fixtures
│   │   ├── liveness.zig      # Liveness analysis
│   │   ├── regalloc.zig      # Register allocator
│   │   └── passes/
│   │       └── lower.zig     # Lowering pass
│   │
│   ├── codegen/              # Code generation
│   │   ├── generic.zig       # Reference implementation
│   │   └── arm64.zig         # ARM64 codegen
│   │
│   ├── arm64/                # ARM64 specifics
│   │   └── asm.zig           # Instruction encoding
│   │
│   ├── obj/                  # Object output
│   │   └── macho.zig         # Mach-O format
│   │
│   └── frontend/             # Frontend
│       ├── token.zig         # Token types
│       ├── source.zig        # Source positions
│       ├── errors.zig        # Error handling
│       ├── scanner.zig       # Lexer
│       ├── ast.zig           # AST nodes
│       ├── parser.zig        # Parser
│       ├── types.zig         # Type system
│       ├── checker.zig       # Type checker
│       ├── ir.zig            # IR definitions
│       ├── lower.zig         # AST to IR
│       └── ssa_builder.zig   # IR to SSA
│
├── test/
│   ├── golden/               # Golden file snapshots
│   ├── cases/                # Directive tests
│   └── integration/          # Cross-module tests
│
├── CLAUDE.md                 # Development guidelines
├── STATUS.md                 # This file
├── REGISTER_ALLOC.md         # Go's regalloc algorithm
├── DATA_STRUCTURES.md        # Go-to-Zig translations
└── TESTING_FRAMEWORK.md      # Testing infrastructure
```

---

## Key Design Decisions

1. **Go's Architecture**: Following Go 1.22's compiler design exactly
2. **Separate Phases**: Frontend IR distinct from SSA backend
3. **FwdRef Pattern**: Deferred phi insertion for correct SSA construction
4. **Type Interning**: TypeRegistry with indices for efficient type comparison
5. **Arena Allocation**: Using Zig 0.15's ArrayListUnmanaged pattern

---

## Success Criteria

Bootstrap-0.2 succeeds when:

1. **Frontend pipeline works** - Parse → Check → Lower → SSA
2. **Backend pipeline works** - SSA → Lowered → RegAlloc → Codegen → Object
3. **End-to-end works** - Compile and run simple programs
4. **Self-hosting works** - Compiler compiles itself

---

## Running Tests

```bash
# Fast unit tests (run frequently)
zig build test

# All tests including integration
zig build test-all

# Golden file tests only
zig build test-golden

# Update golden files after intentional changes
COT_UPDATE_GOLDEN=1 zig build test-golden
```

---

## References

- Go compiler: `~/learning/go/src/cmd/compile/`
- Bootstrap (reference): `~/cot-land/bootstrap/src/`
- See also: [CLAUDE.md](CLAUDE.md), [REGISTER_ALLOC.md](REGISTER_ALLOC.md)

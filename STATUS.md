# Project Status

**Last Updated: 2026-01-25**

## Quick Status

| Component | Status |
|-----------|--------|
| Zig compiler (Stage 0) | ✅ 166 tests pass |
| cot1-stage1 (built by Zig) | ✅ 175 tests pass (166 bootstrap + 9 features) |
| cot1 self-hosting | ⏳ Blocked by lowerer bugs |
| Project restructure | ✅ Complete |

## Recent Progress (2026-01-25)

### cot1 Feature Implementation ✅
All cot1 Phase 1 features are now COMPLETE and passing tests:

| Feature | Status | Tests |
|---------|--------|-------|
| Type aliases (`type Name = T`) | ✅ Complete | 3 tests pass |
| Optional types (`?*T`) | ✅ Complete | 3 tests pass |
| String parameter passing | ✅ Fixed | All string tests pass |
| Bootstrap test parity | ✅ Complete | 166 tests pass |

**Total: 175 tests passing with cot1-stage1**

### Technical Fixes Applied
1. **String parameter passing** - Fixed SSA builder to create two Arg ops (ptr, len) for string parameters, combined with StringMake
2. **String codegen** - Fixed genssa.cot to handle StringPtr/StringLen in call argument processing
3. **Type aliases** - Parser, checker, and lowerer all handle `type Name = T` correctly
4. **Optional types** - Parser recognizes `?T` syntax, checker/lowerer treat as pointer type (sentinel optimization)

### Self-Hosting Status
- cot1-stage1 compiles cot1 source but encounters lowerer errors
- Errors: "Unhandled expr kind=UNKNOWN" and "ExprStmt passed to lowerExpr"
- Root cause: cot1's lowerer doesn't handle all node types when compiling itself
- Next step: Debug and fix lowerer to handle type expression nodes properly

## Major Update: New Bootstrap Architecture

**Decision (2026-01-25)**: Abandoned cot0 self-hosting attempts. The Zig compiler now serves as Stage 0 (trusted bootstrap) for the cot1→cot9 evolution chain.

See [BOOTSTRAP.md](BOOTSTRAP.md) for full documentation.

### Why This Change?

cot0 had blocking issues:
- DWARF relocation alignment on ARM64 macOS
- Struct pointer arithmetic bugs for large codebases

Rather than fix these, we recognized that the **Zig compiler already works perfectly** and can bootstrap all Cot stages.

### New Directory Structure

```
bootstrap-0.2/
├── src/                  # Stage 0: Zig compiler
├── stages/
│   └── cot1/            # Stage 1: First self-hosting target
├── runtime/              # Shared runtime
├── test/
│   ├── bootstrap/       # Zig compiler tests (166 tests)
│   └── stages/cot1/     # cot1 feature tests
└── archive/
    └── cot0/            # Historical reference (deprecated)
```

## Current Priority: cot1 Self-Hosting

**CRITICAL**: The goal is for cot1 to compile itself. This requires fixing lowerer bugs discovered during self-hosting attempts.

### Feature Status

| Feature | Zig Compiler | cot1 Source | Status |
|---------|-------------|-------------|--------|
| Type aliases | ✅ Complete | ✅ Complete | ✅ 3 tests pass |
| Optional types (?T) | ✅ Complete | ✅ Complete | ✅ 3 tests pass |
| Error unions (!T) | ✅ Complete | ✅ Complete | ✅ 3 tests pass (syntax, no error handling) |
| String parameters | ✅ Complete | ✅ Complete | ✅ Fixed in SSA builder & codegen |

### Self-Hosting Blockers

When cot1-stage1 compiles cot1 source, the lowerer encounters:
1. "Unhandled expr kind=UNKNOWN" - Type expression nodes not recognized
2. "ExprStmt passed to lowerExpr" - Statement nodes in expression context

These bugs in `stages/cot1/frontend/lower.cot` need to be fixed before self-hosting works.

### Development Workflow

1. Add feature to Zig compiler (src/*.zig)
2. Add tests to test/bootstrap/
3. Verify tests pass
4. Add feature to stages/cot1/*.cot
5. Add tests to test/stages/cot1/
6. Verify cot1 compiles and passes tests

## Commands

```bash
# Build Zig compiler
zig build

# Run bootstrap tests (166 tests)
./zig-out/bin/cot test/bootstrap/all_tests.cot -o /tmp/tests && /tmp/tests

# Build cot1
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1

# Run cot1 feature tests
./zig-out/bin/cot test/stages/cot1/cot1_features.cot -o /tmp/cot1_tests && /tmp/cot1_tests
```

## Stage Roadmap

| Stage | Focus | Key Features | Status |
|-------|-------|--------------|--------|
| cot1 | Error handling | Type aliases, optionals, error unions | In Progress |
| cot2 | Generics | Generic functions, generic structs | Not Started |
| cot3 | Traits | Interfaces, trait implementations | Not Started |
| cot4 | Memory | ARC, custom allocators | Not Started |
| cot5 | Modules | Module system, visibility | Not Started |
| cot6 | Metaprogramming | Comptime, reflection | Not Started |
| cot7 | Optimization | Inlining, DCE, constant folding | Not Started |
| cot8 | Tooling | LSP, formatter, docs | Not Started |
| cot9 | Production | Full optimization, stable ABI | Not Started |

## Historical Note

The `archive/cot0/` directory contains the original self-hosting attempt that demonstrated Cot could compile itself. It's preserved as historical reference but is no longer actively developed.

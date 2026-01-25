# Project Status

**Last Updated: 2026-01-25**

## Quick Status

| Component | Status |
|-----------|--------|
| Zig compiler (Stage 0) | ✅ 166 tests pass |
| cot1-stage1 (built by Zig) | ✅ **180 tests pass** (166 bootstrap + 14 features) |
| cot1 self-hosting | ✅ **Compiles successfully!** (459KB output) |
| Dogfooding | ✅ Started - type aliases in use |

## Recent Progress (2026-01-25)

### cot1 Self-Hosting Success! ✅
- **BUG-062 FIXED**: Parser 16+ args limitation fixed with dynamic I64List
- cot1-stage1 now compiles cot1 source successfully (459KB Mach-O object)
- All 166 bootstrap tests pass
- Labeled break/continue tests pass

### cot1 Feature Implementation ✅
All cot1 Phase 1 features are COMPLETE and passing tests:

| Feature | Status | Tests |
|---------|--------|-------|
| Type aliases (`type Name = T`) | ✅ Complete | 3 tests pass |
| Optional types (`?*T`) | ✅ Complete | 3 tests pass |
| Error unions (`!T` syntax) | ✅ Complete | 3 tests pass |
| Labeled break/continue | ✅ Complete | 3 tests pass |
| String parameter passing | ✅ Fixed | All string tests pass |
| Bootstrap test parity | ✅ Complete | 166 tests pass |
| Parser unlimited args | ✅ Fixed | Calls with 16+ args work |

**Total: 180+ tests passing with cot1-stage1**

### Dogfooding Initiative ✅
The compiler source now uses its own features:

| File | Type Aliases Added |
|------|-------------------|
| ast.cot | `NodeIndex`, `SourcePos` |
| types.cot | `TypeId` |
| ir.cot | `IRIndex`, `LocalIndex`, `BlockIndex` |
| checker.cot | `SymbolIndex` |

**Note:** Optional types (`?*T`) and error unions (`!T`) cannot be dogfooded yet because:
- The Zig bootstrap has stricter type checking than cot1's implementation
- cot1 treats `?T` and `!T` as just `T` (syntax only, no unwrapping required)
- Full dogfooding of these features requires cot1 self-hosting first

### Documentation Updates ✅
- Added "MANDATORY: DOGFOOD NEW FEATURES" to CLAUDE.md
- Added "Dogfood Every Feature" principle to LANGUAGE_EVOLUTION.md
- Updated all test paths and architecture diagrams

### Self-Hosting Status
- ✅ cot1-stage1 compiles cot1 source successfully (459KB Mach-O object)
- ✅ Output links successfully with zig cc
- ⚠️ cot1-stage2 crashes on startup with SIGBUS (BUG-063)
- Next step: Debug SIGBUS crash to complete self-hosting chain

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

**BUG-063: cot1-stage2 SIGBUS crash** - The self-hosted binary crashes immediately on startup with a bus error (misaligned access or bad address). This is the last blocker for full self-hosting.

Possible causes:
1. Pointer arithmetic generating misaligned addresses
2. Incorrect struct field offset calculations
3. Stack frame layout issues in generated code

See BUGS.md for full details and investigation steps.

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

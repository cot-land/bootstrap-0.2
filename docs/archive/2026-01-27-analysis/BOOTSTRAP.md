# Cot Bootstrap Architecture

## Overview

Cot uses a **staged bootstrap** approach where each stage adds language features while maintaining the ability to compile the previous stage. The Zig compiler serves as Stage 0 - the trusted foundation that compiles all subsequent stages.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         COT BOOTSTRAP CHAIN                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Stage 0: Zig Compiler (src/*.zig)                                          │
│  ─────────────────────────────────                                          │
│  • Written in Zig, external to bootstrap chain                              │
│  • Compiles ALL Cot code (cot1 through cot9)                                │
│  • Feature set defines the "baseline" Cot language                          │
│  • 166 end-to-end tests verify correctness                                  │
│  • cot1 must pass 175 tests (166 bootstrap + 9 features)                    │
│                                                                             │
│       │                                                                     │
│       │ compiles                                                            │
│       ▼                                                                     │
│                                                                             │
│  Stage 1: cot1 (stages/cot1/*.cot)                                          │
│  ─────────────────────────────────                                          │
│  • First self-hosting target                                                │
│  • Adds: type aliases, optional types, error unions                         │
│  • Can compile cot1 source (self-hosting milestone)                         │
│                                                                             │
│       │                                                                     │
│       │ compiles                                                            │
│       ▼                                                                     │
│                                                                             │
│  Stage 2-8: Progressive Enhancement                                         │
│  ───────────────────────────────────                                        │
│  • Each stage adds features while compiling previous stages                 │
│  • Features: generics, traits, better errors, optimizations                 │
│                                                                             │
│       │                                                                     │
│       │ compiles                                                            │
│       ▼                                                                     │
│                                                                             │
│  Stage 9: cot9 (stages/cot9/*.cot)                                          │
│  ─────────────────────────────────                                          │
│  • Production-ready, self-hosted compiler                                   │
│  • Near feature-parity with Zig compiler                                    │
│  • Becomes the "official" Cot compiler                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Design Principles

### 1. Zig Compiler is the Source of Truth

Every feature in a Cot stage must first be implemented in the Zig compiler. This ensures:
- Clean reference implementation to copy from
- Test suite validates the feature works
- No "inventing" features in Cot stages

### 2. Each Stage is a Complete Compiler

Each stage (cot1, cot2, etc.) is a full compiler that can:
- Compile itself (self-hosting)
- Compile all previous stages
- Run all tests for its feature set

### 3. Additive Feature Model

Features are only added, never removed:
- cot1 features ⊂ cot2 features ⊂ ... ⊂ cot9 features
- Any valid cot1 program is valid cot9 program
- Backward compatibility is mandatory

### 4. Test-Driven Development

For each new feature:
1. Add tests to `test/bootstrap/` (Zig compiler tests)
2. Implement in Zig compiler, verify tests pass
3. Add stage-specific tests to `test/stages/cotN/`
4. Implement in cotN source
5. Verify cotN passes when compiled by Zig
6. Verify cotN passes when compiled by itself (self-hosting)

## Stage Feature Roadmap

| Stage | Focus Area | Key Features |
|-------|------------|--------------|
| cot1 | Error Handling | Type aliases, optional types (?T), error unions (!T) |
| cot2 | Generics | Generic functions, generic structs |
| cot3 | Traits | Interface definitions, trait implementations |
| cot4 | Memory | ARC integration, custom allocators |
| cot5 | Modules | Module system, visibility controls |
| cot6 | Metaprogramming | Comptime evaluation, reflection |
| cot7 | Optimization | Inlining, constant folding, dead code elimination |
| cot8 | Tooling | LSP support, formatter, documentation generator |
| cot9 | Production | Full optimization, stable ABI, production hardening |

## Development Workflow

### Adding a Feature

```bash
# 1. Implement in Zig compiler
vim src/frontend/checker.zig  # Add type checking
vim src/frontend/lower.zig    # Add IR lowering

# 2. Add bootstrap tests
vim test/bootstrap/feature_test.cot

# 3. Verify Zig compiler
zig build && ./zig-out/bin/cot test/bootstrap/feature_test.cot -o /tmp/test && /tmp/test

# 4. Add to current stage source
vim stages/cot1/frontend/checker.cot
vim stages/cot1/frontend/lower.cot

# 5. Add stage tests
vim test/stages/cot1/feature_test.cot

# 6. Verify with Zig compiler
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1 && /tmp/cot1 test/stages/cot1/feature_test.cot -o /tmp/test && /tmp/test

# 7. Verify self-hosting
/tmp/cot1 stages/cot1/main.cot -o /tmp/cot1-stage2
```

### Advancing to Next Stage

When a stage is complete:
1. All stage tests pass (compiled by Zig)
2. Self-hosting works (stage compiles itself)
3. Copy stage source to next stage: `cp -r stages/cotN stages/cot(N+1)`
4. Begin adding next stage's features

## File Organization

```
bootstrap-0.2/
├── src/                      # Stage 0: Zig compiler
│   ├── main.zig
│   ├── frontend/
│   │   ├── scanner.zig
│   │   ├── parser.zig
│   │   ├── checker.zig
│   │   ├── lower.zig
│   │   └── ...
│   ├── ssa/
│   ├── codegen/
│   └── obj/
│
├── stages/                   # Cot compiler stages
│   ├── cot1/                 # Stage 1
│   │   ├── main.cot
│   │   ├── frontend/
│   │   ├── ssa/
│   │   ├── codegen/
│   │   └── obj/
│   ├── cot2/                 # Stage 2 (when ready)
│   └── ...
│
├── runtime/                  # Shared runtime (all stages)
│   └── cot_runtime.zig
│
├── lib/                      # Shared Cot libraries
│   ├── io.cot
│   └── list.cot
│
├── test/
│   ├── bootstrap/            # Zig compiler tests (baseline)
│   │   └── all_tests.cot     # 166+ tests
│   └── stages/               # Stage-specific tests
│       ├── cot1/
│       │   ├── all_tests.cot # Inherited from bootstrap
│       │   └── cot1_features.cot
│       └── ...
│
├── archive/                  # Historical/deprecated code
│   └── cot0/                 # Original self-hosting attempt
│
├── BOOTSTRAP.md              # This document
├── ROADMAP.md                # Detailed feature roadmap
└── STATUS.md                 # Current progress
```

## Historical Note: cot0

The `archive/cot0/` directory contains the original self-hosting compiler attempt. It successfully demonstrated that Cot could compile itself but had issues with:
- DWARF debug info alignment on ARM64 macOS
- Struct pointer arithmetic for large codebases

Rather than fix these issues, we chose to use the Zig compiler as a stable Stage 0 and focus on advancing the language through cot1-cot9. The cot0 code remains as historical reference.

## Commands Reference

```bash
# Build Zig compiler
zig build

# Run bootstrap tests
./zig-out/bin/cot test/bootstrap/all_tests.cot -o /tmp/tests && /tmp/tests

# Build cot1
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1

# Run cot1 tests (compiled by Zig)
./zig-out/bin/cot test/stages/cot1/all_tests.cot -o /tmp/cot1_tests && /tmp/cot1_tests

# Self-hosting test
/tmp/cot1 stages/cot1/main.cot -o /tmp/cot1-stage2
/tmp/cot1-stage2 test/stages/cot1/all_tests.cot -o /tmp/tests && /tmp/tests
```

## Success Criteria

The bootstrap is complete when:
1. cot9 compiles itself successfully
2. cot9-compiled-by-cot9 passes all tests
3. cot9 has feature parity with Zig compiler (minus Zig-specific internals)
4. cot9 can be used to develop real applications

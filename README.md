# Cot Programming Language

**A modern systems language with Zig-like syntax, Go-inspired compiler architecture, and automatic reference counting.**

## Vision

Cot is a new programming language designed for:

- **Simplicity**: Clean, readable syntax inspired by Zig
- **Safety**: Automatic Reference Counting (ARC) eliminates manual memory management
- **Performance**: Compiles to native ARM64 code with no runtime overhead
- **Productivity**: Fast compilation, clear error messages, practical tooling

### Long-Term Goals

| Feature | Status | Notes |
|---------|--------|-------|
| Native ARM64 compilation | Working | Mach-O object files |
| Zig-like syntax | Working | See [SYNTAX.md](SYNTAX.md) |
| Self-hosting compiler | In Progress | Stage 1 working, Stage 2 blocked |
| ARC memory management | Planned | Replace manual malloc/free |
| x86-64 backend | Planned | After self-hosting |
| Standard library | Planned | After self-hosting |

## Project Structure

```
bootstrap-0.2/
├── src/                    # Zig compiler (reference implementation)
│   ├── frontend/           # Scanner, Parser, AST, Type Checker
│   ├── ssa/                # SSA IR, Liveness, Register Allocation
│   ├── codegen/            # ARM64 code generation
│   └── obj/                # Mach-O object file writer
├── cot0/                   # Self-hosting compiler (in Cot)
│   ├── frontend/           # Mirrors src/frontend
│   ├── ssa/                # Mirrors src/ssa
│   ├── codegen/            # Mirrors src/codegen
│   └── obj/                # Mirrors src/obj
├── runtime/                # Runtime library (signal handlers, malloc)
└── test/                   # End-to-end tests (166 passing)
```

## Bootstrap Strategy

The compiler is being bootstrapped in stages:

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│   Go Compiler Patterns  ──►  Zig Implementation  ──►  Cot (cot0)   │
│   (cmd/compile)              (src/*.zig)             (cot0/*.cot)   │
│                                                                     │
│   Source of Truth            Reference Compiler      Self-Hosting   │
│   for Algorithms             (builds cot0-stage1)   Target          │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

1. **Stage 0**: Zig compiler (`src/*.zig`) - fully working, 166 tests pass
2. **Stage 1**: Zig compiles cot0 → `cot0-stage1` executable (working)
3. **Stage 2**: cot0-stage1 compiles cot0 → `cot0-stage2` (compiles, runtime crash)
4. **Stage 3+**: cot0-stageN compiles cot0 → identical binary (self-hosting achieved)

## Quick Start

```bash
# Build the Zig compiler
zig build

# Run all tests
./zig-out/bin/cot test/e2e/all_tests.cot -o /tmp/all_tests && /tmp/all_tests

# Compile a simple program
echo 'fn main() i64 { return 42 }' > /tmp/test.cot
./zig-out/bin/cot /tmp/test.cot -o /tmp/test
/tmp/test; echo "Exit code: $?"

# Build cot0-stage1 (self-hosting compiler)
./zig-out/bin/cot cot0/main.cot -o /tmp/cot0-stage1

# Use stage1 to compile a program
/tmp/cot0-stage1 /tmp/test.cot -o /tmp/test2
/tmp/test2; echo "Exit code: $?"
```

## Documentation

| Document | Purpose |
|----------|---------|
| [CLAUDE.md](CLAUDE.md) | Development workflow and principles |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Compiler design and key decisions |
| [SELF_HOSTING.md](SELF_HOSTING.md) | Path to self-hosting with milestones |
| [SYNTAX.md](SYNTAX.md) | Language syntax reference |
| [REFERENCE.md](REFERENCE.md) | Technical reference (data structures, algorithms) |
| [cot0/COMPARISON.md](cot0/COMPARISON.md) | Function parity checklist (cot0 vs Zig) |

## Current Status

**Self-hosting is blocked by a runtime crash in stage 2.**

- Stage 1 compiler works correctly
- Stage 2 compiles but crashes at runtime (SIGSEGV)
- DWARF debug info now shows crash source locations
- Root cause under investigation

See [SELF_HOSTING.md](SELF_HOSTING.md) for detailed status and next steps.

## Design Philosophy

### 1. Copy, Don't Invent

The compiler architecture is systematically copied from Go's `cmd/compile`. Every algorithm, data structure, and optimization comes from proven, production-tested code. This is intentional:

- Go's compiler has 10+ years of production hardening
- Zig's implementation provides clean, readable translation
- Cot0 mirrors Zig exactly (different syntax, same logic)

**When a bug appears, the fix comes from Go/Zig, not creative debugging.**

### 2. Function Parity

Every function in cot0 must have:
- **Same name** as its Zig counterpart (adapted to Cot naming)
- **Same logic** (identical algorithm, different syntax)
- **Same behavior** (identical outputs for identical inputs)

This is tracked in [cot0/COMPARISON.md](cot0/COMPARISON.md).

### 3. Incremental Progress

Self-hosting is achieved through systematic, incremental work:
1. Make all functions "Same" in COMPARISON.md
2. Fix bugs by finding the Go/Zig pattern that prevents them
3. Test continuously (166 e2e tests must stay green)
4. Never introduce new patterns not in Go/Zig

## License

[To be determined]

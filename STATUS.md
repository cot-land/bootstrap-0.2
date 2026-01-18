# Bootstrap 0.2 - Project Status

**Last Updated: 2026-01-18**

## Current State

**166 e2e tests passing.** Core language features complete.

### Self-Hosting Progress

See [cot0/ROADMAP.md](cot0/ROADMAP.md) for detailed self-hosting progress.

| Module | Status | Tests |
|--------|--------|-------|
| token.cot | Complete | 5/5 pass |
| scanner.cot | Complete | 18/18 pass |
| ast.cot | Complete | 7/7 pass |
| parser.cot | Complete | 22/22 pass |
| types.cot | Complete | 2/2 pass |
| checker.cot | Complete | 4/4 pass |
| ir.cot | Complete | passes |
| ssa/op.cot | Complete | passes |
| ssa/value.cot | Complete | passes |
| ssa/block.cot | Complete | passes |
| ssa/func.cot | Complete | passes |
| ssa/builder.cot | Complete | passes |
| ssa/liveness.cot | Complete | passes |
| ssa/regalloc.cot | Complete | passes |
| frontend/lower.cot | Complete | passes |
| arm64/asm.cot | Complete | 7/7 pass |
| arm64/regs.cot | Complete | 2/2 pass |
| codegen/arm64.cot | Complete | 4/4 pass |
| codegen/genssa.cot | Complete | 3/3 pass |
| obj/macho.cot | Complete | 4/4 pass |

### End-to-End Codegen Test

The `e2e_codegen_test.cot` demonstrates the full backend pipeline:
- SSA → genssa → 8 bytes machine code → MachOWriter → 319 byte .o file
- Links and runs: **Exit code: 42** ✅

### Recent Bug Fixes (2026-01-18)

- BUG-032: open() mode parameter ignored - ARM64 macOS variadic args must go on stack, not registers
- BUG-031: Array field in struct through pointer crashes - Arrays are inline like structs, return address not load
- BUG-030: Functions with >8 arguments fail - Implemented ARM64 AAPCS64 stack argument passing
- BUG-029: Reading struct pointer field through function parameter causes crash - Added global struct/array handling
- BUG-028: Taking address of local array element causes runtime crash - Skip init for undefined arrays
- BUG-027: Direct global array field access causes compiler panic - Fixed via BUG-029

### Earlier Bug Fixes (2026-01-17)

- BUG-026: Integer literals > 2^31 not parsed correctly - Fixed parseInt base from 10 to 0 for auto-detection
- BUG-025: String pointer becomes null after many accesses - Implemented Go's per-instruction use distance tracking in regalloc
- BUG-024: String pointer becomes null in string comparisons - Added slice_len/slice_ptr rewrite rules to decompose pass
- BUG-023: Stack slot reuse causes value corruption - Disabled slot reuse for store_reg values, fixed liveness propagation
- BUG-022: Comparison operands use same register - Fixed register allocation for comparisons in functions with many if statements
- BUG-021: Chained AND with 4+ conditions - Fixed conditional block predecessor counting
- BUG-020: Many nested if statements cause segfault - Fixed block edge management
- BUG-019: Large struct (>16B) by-value arguments - Pass by reference following ARM64 ABI
- BUG-017: Imported consts in binary expressions - Check checker's scope for imported constants in lowerIdent
- BUG-016: Const identifier on right side of comparison - Added proper 1-token lookahead to distinguish struct literals
- BUG-015: Chained OR (3+ conditions) - Pre-scan IR to skip logical operands in main loop

See [BUGS.md](BUGS.md) for complete bug history.

---

## Completed Features

### Core Language
- Integer literals, arithmetic, comparisons
- Boolean type, local variables
- Functions (0-8+ args), recursion
- If/else, while loops, break/continue, for-in
- Structs (simple, nested, >16B returns)
- Switch expressions and statements

### Data Types
- String literals, len(), string indexing
- String concatenation (requires runtime)
- Character literals, u8 type
- Fixed arrays, array literals, indexing
- Slices, slice from array

### Memory & Pointers
- Pointer types `*T`, address-of `&x`
- Dereference `ptr.*`, pointer arithmetic
- Optional types `?T`, null literal
- `@sizeOf(T)`, `@alignOf(T)` builtins
- `extern fn` for libc integration

### Operators
- Bitwise AND, OR, XOR, NOT, shifts
- Logical AND, OR with short-circuit
- Compound assignment (`+=`, `&=`, etc.)

### Modules & I/O
- Import statement for multi-file projects
- File I/O via extern fn (open, read, write, close)
- Global constants with compile-time evaluation
- Global variables

---

## Runtime Library

String concatenation uses `runtime/cot_runtime.o`. The compiler auto-links it when found.

```bash
# Just compile and run - runtime is auto-linked!
./zig-out/bin/cot program.cot -o program
./program
```

If you see `undefined symbol: ___cot_str_concat`, ensure runtime exists:
```bash
zig build-obj -OReleaseFast runtime/cot_runtime.zig -femit-bin=runtime/cot_runtime.o
```

---

## Technical Reference

- [CLAUDE.md](CLAUDE.md) - Development guidelines, Zig 0.15 API, bug workflow
- [SYNTAX.md](SYNTAX.md) - Cot language syntax reference
- [BUGS.md](BUGS.md) - Bug tracking with root cause analysis
- [DATA_STRUCTURES.md](DATA_STRUCTURES.md) - Go-to-Zig translations
- [REGISTER_ALLOC.md](REGISTER_ALLOC.md) - Register allocator algorithm
- [TESTING_FRAMEWORK.md](TESTING_FRAMEWORK.md) - Testing approach
- [cot0/ROADMAP.md](cot0/ROADMAP.md) - Self-hosting roadmap and progress

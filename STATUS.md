# Bootstrap 0.2 - Project Status

**Last Updated: 2026-01-16**

## Current State

**160 e2e tests passing.** Core language features complete.

### Self-Hosting Progress

See [cot0/TASKS.md](cot0/TASKS.md) for detailed self-hosting progress.

| Module | Status | Tests |
|--------|--------|-------|
| token.cot | Complete | 5/5 pass |
| scanner.cot | Complete | 11/11 pass |
| ast.cot | Complete | 7/7 pass |
| parser.cot | Complete | 10/10 pass |
| types.cot | In Progress | 2/2 pass |
| checker.cot | In Progress | 2/2 pass |

### Open Bugs (2026-01-16)

None currently.

### Recent Bug Fixes (2026-01-16)

- BUG-017: Imported consts in binary expressions - Check checker's scope for imported constants in lowerIdent
- BUG-016: Const identifier on right side of comparison - Added proper 1-token lookahead to distinguish struct literals
- BUG-015: Chained OR (3+ conditions) - Pre-scan IR to skip logical operands in main loop
- BUG-014: Switch statements - Now supports both expression and statement modes
- BUG-013: String concatenation in loops - Fixed use count tracking in expand_calls
- BUG-012: `ptr.*.field` codegen - Following Go's ODOTPTR pattern
- BUG-011: `off_ptr` register clobbering fix
- BUG-010: `slice_make` arg register clobbering fix

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
- [cot0/TASKS.md](cot0/TASKS.md) - Self-hosting roadmap and progress

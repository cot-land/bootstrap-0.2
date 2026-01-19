# Bootstrap 0.2 - Project Status

**Last Updated: 2026-01-19**

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
| **main.cot** | **Full pipeline** | **runs** |
| arm64/asm.cot | Complete | 7/7 pass |
| arm64/regs.cot | Complete | 2/2 pass |
| codegen/arm64.cot | Complete | 4/4 pass |
| codegen/genssa.cot | Complete | 3/3 pass |
| obj/macho.cot | Complete | 4/4 pass |

### Full Pipeline Test (main.cot)

The `main.cot` driver demonstrates the complete 7-phase compilation pipeline:
```
Phase 1: Scanning...     Tokens: 10
Phase 2: Parsing...      Nodes: 5
Phase 3: Lowering to IR... IR nodes: 2
Phase 4: Building SSA... Blocks: 1, Values: 2
Phase 5: Generating machine code... Code bytes: 8
Phase 6: Creating Mach-O object... Mach-O bytes: 319
Phase 7: Writing output... Wrote 319 bytes
```

**Full pipeline verified:** Compiles `fn main() i64 { return 42; }` to executable that returns 42.

**Remaining for self-hosting:** Extend lowerer for more complex functions, add command line argument parsing.

### End-to-End Codegen Test

The `e2e_codegen_test.cot` demonstrates the full backend pipeline:
- SSA → genssa → 8 bytes machine code → MachOWriter → 319 byte .o file
- Links and runs: **Exit code: 42** ✅

### Recent Changes (2026-01-19)

**cot0 Self-Hosting Enhancements:**
- Added const declaration support to cot0 lowerer (two-pass lowering: consts first, then functions)
- Added string literal support to cot0 lowerer (ConstString IR node)
- Added pointer support to cot0 lowerer:
  - Address-of operator (`&x`) via AddrLocal IR node
  - Dereference operator (`ptr.*`) via Load IR node
  - Store through pointer (`ptr.* = value`) via Store IR node
- Added struct field access support to cot0 lowerer:
  - FieldInfo struct for field name/type/offset storage
  - FieldLocal/FieldValue IR nodes for field read
  - StoreFieldLocal/StoreField IR nodes for field write
  - OffPtr SSA operation for field offset computation
  - TypePool extended with field management functions
- Added array indexing support to cot0:
  - IndexExpr AST node and parser support for `expr[index]`
  - IndexLocal/IndexValue IR nodes for array read
  - StoreIndexLocal/StoreIndexValue IR nodes for array write
  - AddPtr SSA operation for computed pointer offsets
- Added struct field assignment support to cot0 lowerer:
  - Field assignment via lower_field_assign (`s.x = value`)
  - Array element assignment via lower_index_assign (`arr[i] = value`)
- Added extern fn support for libc integration:
  - Extern token type and keyword recognition
  - ExternFnDecl AST node and parser support
  - Extern functions skipped in lowerer (linker resolves)
- Fixed executable permissions: added chmod(0o755) after linking in main.zig

### Bug Fixes (2026-01-18)

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

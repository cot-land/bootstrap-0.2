# Cot0 Self-Hosting Roadmap

**Goal:** Build a Cot compiler written in Cot that can compile itself.

**Last Updated:** 2026-01-18

---

## Current Status

| Milestone | Status |
|-----------|--------|
| Bootstrap compiler (Zig) | 166 e2e tests pass |
| cot0 frontend modules | Complete, all tests pass |
| cot0 can parse itself | **COMPLETE** (Sprint E) |
| cot0 SSA modules | **COMPLETE** (Sprint F) |
| cot0 backend modules | **COMPLETE** (Sprint G) |
| cot0 core transformations | **COMPLETE** (Sprint H) |
| cot0 self-compiles | Not started |

---

## Test Status

| Test File | Status |
|-----------|--------|
| `token_test.cot` | 5/5 pass |
| `scanner_test.cot` | 18/18 pass |
| `ast_test.cot` | 7/7 pass |
| `parser_test.cot` | 22/22 pass |
| `types_test.cot` | 2/2 pass |
| `checker_test.cot` | 4/4 pass |
| `ir_test.cot` | passes |
| `ssa/ssa_test.cot` | passes |
| `ssa/builder_test.cot` | passes |
| `ssa/liveness_test.cot` | passes |
| `ssa/regalloc_test.cot` | passes |
| `frontend/lower_test.cot` | passes |

---

## The Path to Self-Hosting

Self-hosting requires two parallel tracks:

### Track 1: Bootstrap Compiler Features
The Zig bootstrap compiler must support all features used in cot0 source files.

### Track 2: Cot0 Module Implementation
The cot0 compiler modules must be implemented in Cot.

**Current blocker:** cot0 uses features (structs, enums, pointers) that cot0's parser cannot yet parse. We must extend cot0's parser before we can self-host.

---

## Sprint B: Struct and Enum Declarations (COMPLETE 2026-01-17)

**Goal:** cot0 parser can parse `struct Name { ... }` and `enum Name { ... }`

**Verification:** parser_test.cot includes struct/enum tests (tests 11-14), all pass

### Tasks (all complete)

1. [x] **token.cot**: Add tokens for Struct, Enum, Dot
2. [x] **ast.cot**: Add node kinds: StructDecl, EnumDecl, FieldDecl, FieldAccess, EnumAccess
3. [x] **parser.cot**: Add parse_struct_decl(), parse_enum_decl(), parse_field_access()
4. [x] **types.cot**: Add type_make_struct(), type_make_enum() functions

### Test Cases
```cot
// Parser can now parse:
struct Point { x: i64, y: i64, }
enum Color { Red, Green, Blue, }
point.x                         // Field access
TokenType.Ident                 // Enum variant access
```

---

## Sprint E: Full Type Checking (COMPLETE 2026-01-17)

**Goal:** cot0 type checker validates all parsed constructs

**Verification:** Type checker passes on all cot0 files

### Tasks

1. [x] Scope management (define, lookup, parent chain)
2. [x] Variable declaration checking (check_var_decl)
3. [x] Control flow checking (if/while condition must be bool)
4. [x] Struct/enum type checking (check_struct_decl, check_enum_decl)
5. [x] Pointer operations checking (address-of, dereference)
6. [x] Comparison operators return bool
7. [x] Logical operators (and/or) require bool operands
8. [x] Unary operators (neg, not, bitnot) type checking
9. [x] Field access checking (struct.field, Enum.Variant, string.len/ptr)

---

## Sprint F: IR & SSA (COMPLETE 2026-01-17)

**Goal:** Implement IR and SSA modules in Cot

**Verification:** All SSA modules compile, ssa_test.cot passes

### Files implemented
- [x] `ir.cot` - IR node definitions and builder (already existed)
- [ ] `lower.cot` - AST to IR conversion (deferred)
- [x] `ssa/op.cot` - SSA operations enum with predicates
- [x] `ssa/value.cot` - SSA values with use tracking
- [x] `ssa/block.cot` - Basic blocks with edges
- [x] `ssa/func.cot` - Functions with locals
- [ ] `ssa/builder.cot` - IR to SSA conversion (deferred)

Note: Added `undefined` keyword to Cot bootstrap compiler to support
struct initialization pattern: `var v: Value = undefined;`

---

## Sprint G: Backend (COMPLETE 2026-01-17)

**Goal:** Implement code generation modules in Cot

### Files implemented
- [x] `arm64/asm.cot` - ARM64 instruction encoding (697 lines)
- [x] `arm64/regs.cot` - Register definitions and classification
- [x] `codegen/arm64.cot` - Code generation helpers
- [x] `obj/macho.cot` - Mach-O constants and structures

Tests: asm_test.cot (7 tests), regs_test.cot (2 tests), arm64_test.cot (4 tests), macho_test.cot (3 tests)

Also fixed: BUG-026 (integer literals > 2^31 not parsed correctly)

---

## Sprint H: Core Transformations (COMPLETE 2026-01-18)

**Goal:** Implement the transformation passes that connect frontend to backend

### Files implemented
- [x] `frontend/lower.cot` - AST to IR conversion
- [x] `ssa/builder.cot` - IR to SSA conversion
- [x] `ssa/liveness.cot` - Live range analysis
- [x] `ssa/regalloc.cot` - Register allocation

Tests: lower_test.cot, builder_test.cot, liveness_test.cot, regalloc_test.cot all pass

All core infrastructure working. BUG-027 through BUG-030 fixed on 2026-01-18.

---

## Sprint I: Integration (IN PROGRESS)

**Goal:** Complete compiler that can compile itself

### Progress (2026-01-18)
- [x] `main.cot` - Basic driver with file I/O (compiles, reads files, runs)
- [ ] Full codegen loop (walk SSA, emit all ops)
- [ ] Mach-O writer (actually write .o files)
- [ ] Module integration (resolve name collisions between imports)

### Blocker: Module Name Collisions
When importing all cot0 modules, there are name collisions (e.g., multiple `main` functions in test files, shared struct names). Need to either:
1. Add namespace support to imports
2. Remove test code from imported modules
3. Use include guards / conditional compilation

### Verification
```bash
# Compile cot0 with bootstrap compiler
./zig-out/bin/cot cot0/main.cot -o cot0-stage1

# Compile cot0 with stage1
./cot0-stage1 cot0/main.cot -o cot0-stage2

# Verify stage1 and stage2 produce identical output
diff cot0-stage1 cot0-stage2
```

---

## Completed Sprints

### Sprint H: Core Transformations (COMPLETE 2026-01-18)

Added to cot0:
- **frontend/lower.cot**: AST to IR lowering with Lowerer struct and FuncBuilder
- **ssa/builder.cot**: IR to SSA conversion with SSABuilder, BlockDefs, variable tracking
- **ssa/liveness.cot**: Live range analysis with LiveMap, BlockLiveness, fixed-point iteration
- **ssa/regalloc.cot**: Register allocation with ValState, RegState, spilling

Tests: 4 new test files all pass

---

### Sprint G: Backend (COMPLETE 2026-01-17)

Added to cot0:
- **arm64/asm.cot**: ARM64 instruction encoding (MOVZ, ADD, SUB, LDR, STR, B, BL, RET, etc.)
- **arm64/regs.cot**: Register definitions (X0-X30, SP, classification functions)
- **codegen/arm64.cot**: Code generation helpers (select_load, select_store, codegen_* functions)
- **obj/macho.cot**: Mach-O format constants and structures

Fixed in bootstrap compiler:
- **BUG-026**: Integer literals > 2^31 parsed incorrectly (changed parseInt base 10 → 0)

Tests: 16 backend tests pass

---

### Sprint F: IR & SSA (COMPLETE 2026-01-17)

Added to cot0:
- **ssa/op.cot**: SSA operations enum (Op) with predicates (is_constant, is_comparison, etc.)
- **ssa/value.cot**: Value struct with use tracking, argument management, ValuePool
- **ssa/block.cot**: Block struct with control flow, BlockKind enum, BlockPool
- **ssa/func.cot**: Func struct with locals, emission helpers

Added to bootstrap compiler:
- **undefined keyword**: Allows `var v: Type = undefined;` pattern for struct initialization
  - Token, AST node, parser, type checker, and lowering support

Tests: ssa_test.cot passes

---

### Sprint E: Full Type Checking (COMPLETE 2026-01-17)

Added to cot0:
- **checker.cot**: Extended check_expr with comparison/logical/unary operators
- **checker.cot**: Added check_struct_decl, check_enum_decl, check_var_decl
- **checker.cot**: Added if/while condition checking (must be bool)
- **checker.cot**: Added FieldAccess checking for struct/enum/string

Tests: checker_test.cot tests scope define/lookup (4 total tests pass)

Note: Full field-by-name lookup requires field name registry (deferred)

---

### Sprint D: Imports and Constants (COMPLETE 2026-01-17)

Added to cot0:
- **token.cot**: Import, Const tokens (already present)
- **ast.cot**: ImportDecl, ConstDecl node kinds + constructors
- **parser.cot**: parse_import(), parse_const_decl() functions

Tests: parser_test.cot tests 19-22 verify import/const parsing (22 total tests pass)

---

### Sprint C: Pointers and Strings (COMPLETE 2026-01-17)

Added to cot0:
- **ast.cot**: StringLit, AddressOf, DerefExpr node kinds + constructors
- **parser.cot**: String literal in parse_atom(), address-of in parse_unary(), dereference in postfix loop

Tests: parser_test.cot tests 15-18 verify pointer/string parsing (18 total tests pass)

---

### Sprint B: Struct and Enum Declarations (COMPLETE 2026-01-17)

Added to cot0:
- **token.cot**: Struct, Enum, Dot tokens (already present)
- **ast.cot**: StructDecl, EnumDecl, FieldDecl, FieldAccess nodes + constructors
- **parser.cot**: parse_struct_decl(), parse_enum_decl(), field access in parse_unary()
- **types.cot**: type_make_struct(), type_make_enum() functions

Tests: parser_test.cot tests 11-14 verify struct/enum parsing

---

### Sprint A: Core Parsing Infrastructure (COMPLETE 2026-01-17)

Added to cot0 parser:
- Tokens: Let, Var, If, Else, While, Bool, True, False, And, Or, Not, EqEq, NotEq, Less, LessEq, Greater, GreaterEq
- AST nodes: VarDecl, IfStmt, WhileStmt
- Parser: parse_type(), parse_var_decl(), parse_if_stmt(), parse_while_stmt()
- Operator precedence for comparisons and logical ops

Bug fixes during Sprint A:
- BUG-020 through BUG-025 (register allocation, stack slots, string handling)

---

## Feature Matrix

Features used by cot0 source files vs what cot0 can handle:

| Feature | Used in cot0? | cot0 can parse? | cot0 can check? |
|---------|--------------|-----------------|-----------------|
| `let`/`var` declarations | Yes | Yes (Sprint A) | Yes (Sprint E) |
| `if`/`else`/`while` | Yes | Yes (Sprint A) | Yes (Sprint E) |
| Comparisons/logical ops | Yes | Yes (Sprint A) | Yes (Sprint E) |
| `struct` declarations | Yes | Yes (Sprint B) | Yes (Sprint E) |
| `enum` declarations | Yes | Yes (Sprint B) | Yes (Sprint E) |
| Field access `s.field` | Yes | Yes (Sprint B) | Partial (Sprint E) |
| Pointer types `*T` | Yes | Yes (Sprint C) | Yes (Sprint E) |
| Address-of `&x` | Yes | Yes (Sprint C) | Yes (Sprint E) |
| Dereference `ptr.*` | Yes | Yes (Sprint C) | Yes (Sprint E) |
| String literals | Yes | Yes (Sprint C) | Yes (Sprint E) |
| `import` statements | Yes | Yes (Sprint D) | No |
| `const` declarations | Yes | Yes (Sprint D) | No |

---

## Recent Bug Fixes

- BUG-025: String pointer null after many accesses (Go's use distance tracking)
- BUG-024: String pointer null in string comparisons
- BUG-023: Stack slot reuse causes value corruption
- BUG-022: Comparison operands use same register
- BUG-021: Chained AND with 4+ conditions
- BUG-020: Many nested if statements segfault

See [../BUGS.md](../BUGS.md) for complete history.

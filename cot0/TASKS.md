# Cot0 Tasks

**Goal:** Minimal compiler for i64, arithmetic, functions, return.

**Last Updated:** 2026-01-16

---

## Current Status

**All 160 e2e tests pass.**

- `token_test.cot`: 5/5 tests pass
- `scanner_test.cot`: 11/11 tests pass
- `ast_test.cot`: 7/7 tests pass
- `parser_test.cot`: 10/10 tests pass
- `types_test.cot`: 2/2 tests pass
- `checker_test.cot`: 2/2 tests pass

**Recent Bug Fixes (2026-01-16):**
- BUG-017: Imported consts in binary expressions (OPEN) - workaround in place
- BUG-016: Const on right side of comparison (OPEN) - workaround in place
- BUG-015: Chained OR (3+ conditions) fixed - pre-scan IR to skip logical operands
- BUG-014: Switch statements now supported (both expression and statement modes)
- BUG-013: String concatenation in loops fixed (use count tracking)
- BUG-012: `ptr.*.field` codegen fixed
- BUG-004: Struct returns > 16 bytes fixed
- BUG-005/006: Logical NOT and `not` keyword fixed
- BUG-002: Struct literals implemented

**Sprint 1 COMPLETE!** Scanner.cot compiles and tests pass.
**Sprint 2 COMPLETE!** Parser.cot compiles and all 10 tests pass.
**Sprint 3 IN PROGRESS:** types.cot and checker.cot created with basic tests.
**Sprint 4 NEXT:** IR & SSA (ir.cot, lower.cot)

---

## Immediate Blockers for scanner.cot

### BUG-005: Logical NOT operator broken (P0) ✅ FIXED

**Status:** Fixed
**Fix:** For boolean types, uses `EOR Rd, Rm, #1` (XOR with 1) instead of MVN.

### BUG-006: `not` keyword not recognized (P0) ✅ FIXED

**Status:** Fixed
**Fix:** Added `not` as a keyword that parses as unary `!` operator.

### BUG-002: Struct literals not implemented (P0) ✅ FIXED

**Status:** Fixed
**Fix:** Implemented struct literal parsing following Go's composite literal pattern.

### @string(ptr, len) builtin (P0) ✅ FIXED

**Status:** Fixed (was already implemented)
**Implementation:** Following Go's `unsafe.String(ptr, len)` → `StringHeaderExpr` → `OpStringMake` pattern.

Parser, checker, and lowerer all handle `@string(ptr, len)`:
- Parser: `@string(expr, expr)` syntax
- Checker: validates ptr is `*u8`, len is integer, returns `string`
- Lowerer: emits `string_header` IR → `string_make` SSA op

---

## Execution Order (Priority)

### Sprint 1: Unblock scanner.cot (4 issues) ✅ COMPLETE

| Order | Issue | Effort | Status |
|-------|-------|--------|--------|
| 1 | BUG-005: Fix `!` for booleans | Small | ✅ Done |
| 2 | BUG-006: Add `not` keyword | Small | ✅ Done |
| 3 | BUG-002: Struct literals | Medium | ✅ Done |
| 4 | @string builtin | Medium | ✅ Done |

**Result:** scanner.cot compiles successfully to object file.

### Sprint 2: AST & Parser

| Order | File | Dependency |
|-------|------|------------|
| 1 | ast.cot | scanner.cot working |
| 2 | parser.cot | ast.cot |
| 3 | parser_test.cot | parser.cot |

### Sprint 3: Type Checking

| Order | File | Dependency |
|-------|------|------------|
| 1 | types.cot | parser.cot |
| 2 | checker.cot | types.cot |
| 3 | checker_test.cot | checker.cot |

### Sprint 4: IR & SSA

| Order | File | Dependency |
|-------|------|------------|
| 1 | ir.cot | checker.cot |
| 2 | lower.cot | ir.cot |
| 3 | ssa/*.cot | lower.cot |

### Sprint 5: Backend & Integration

| Order | File | Dependency |
|-------|------|------------|
| 1 | arm64/asm.cot | ssa working |
| 2 | codegen/arm64.cot | asm.cot |
| 3 | obj/macho.cot | codegen |
| 4 | main.cot | All above |

---

## Phase 1: Frontend

### token.cot ✅ COMPLETE
- [x] TokenType enum (Int, Ident, Fn, Return, I64, punctuation, operators)
- [x] Token struct (type, start, length)
- [x] token_new() constructor
- [x] is_keyword() for fn/return/i64

### token_test.cot ✅ COMPLETE (5/5 pass)
- [x] Test token creation
- [x] Test keyword recognition - 5/5 tests pass

### scanner.cot ✅ COMPLETE
- [x] Scanner struct (source, pos)
- [x] scanner_new(), scanner_next()
- [x] skip_whitespace(), skip_comments
- [x] scan_number() for integer literals
- [x] scan_ident() for identifiers/keywords
- [x] Compiles successfully to object file
- [x] All scanner_test.cot tests pass (11/11)

### scanner_test.cot ✅ COMPLETE (11/11 pass)
- [x] Test single tokens (int, ident, keywords)
- [x] Test whitespace handling
- [x] Test punctuation and operators
- [x] Test EOF token
- [x] Test multi-token sequences
- [x] Test full function tokenization

### ast.cot
- [ ] Node types: IntLit, Ident, BinaryOp, Call, Return, FnDecl, Block
- [ ] AST node struct with tagged union

### parser.cot
- [ ] Parser struct (scanner, current token)
- [ ] parse_expr(), parse_stmt(), parse_fn()
- [ ] Operator precedence for +, -, *, /

### parser_test.cot
- [ ] Test expression parsing
- [ ] Test function parsing

### types.cot
- [ ] Type enum (I64, Void, Fn)
- [ ] Type comparison

### checker.cot
- [ ] Symbol table (name -> type)
- [ ] check_expr(), check_fn()
- [ ] Type inference for literals
- [ ] Function call validation

---

## Phase 2: IR & SSA

### ir.cot
- [ ] IR node types matching ast.cot
- [ ] IR builder

### lower.cot
- [ ] AST to IR conversion

### ssa/op.cot
- [ ] Op enum (const_int, add, sub, mul, div, call, ret)

### ssa/value.cot
- [ ] Value struct (op, type, args, aux)

### ssa/block.cot
- [ ] Block struct (values, succs, preds)

### ssa/func.cot
- [ ] Func struct (blocks, name)

### ssa/builder.cot
- [ ] IR to SSA conversion

---

## Phase 3: Backend

### arm64/asm.cot
- [ ] Instruction encoding for: MOV, ADD, SUB, MUL, SDIV, BL, RET
- [ ] Register definitions (x0-x30)

### codegen/arm64.cot
- [ ] SSA to ARM64 conversion
- [ ] Register allocation (simple linear scan)
- [ ] Function prologue/epilogue

### obj/macho.cot
- [ ] Mach-O header
- [ ] __text section
- [ ] Symbol table
- [ ] Relocations

---

## Phase 4: Integration

### main.cot
- [ ] Read source file
- [ ] Run pipeline: scan -> parse -> check -> lower -> ssa -> codegen -> emit
- [ ] Write object file
- [ ] Invoke linker

---

## Verification Checklist

- [x] `token_test.cot` passes (5/5)
- [x] `scanner_test.cot` passes (11/11)
- [ ] `parser_test.cot` passes
- [x] Can compile: `fn main() i64 { return 42; }`
- [x] Can compile: `fn main() i64 { return 20 + 22; }`
- [x] Can compile: `fn add(a: i64, b: i64) i64 { return a + b; } fn main() i64 { return add(20, 22); }`

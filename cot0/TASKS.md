# Cot0 Tasks

**Goal:** Minimal compiler for i64, arithmetic, functions, return.

**Last Updated:** 2026-01-16

---

## Current Status

✅ **BUG-004 FIXED:** Struct returns > 16 bytes now work correctly.
✅ **BUG-005 FIXED:** Logical NOT operator now works for booleans.
✅ **BUG-006 FIXED:** `not` keyword added as synonym for `!`.
✅ **BUG-002 FIXED:** Struct literals implemented.
✅ **Unified ABI Analysis:** Following Go's pattern, ABI decisions centralized in `abi.zig`.

- `token_test.cot`: 5/5 tests pass
- All 142 e2e tests pass

**Next Blocker:** Scanner.cot requires `@string(ptr, len)` builtin.

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

### Missing: @string(ptr, len) builtin (P0) - BLOCKING

**Status:** Not implemented - BLOCKING
**File:** Would need `src/frontend/parser.zig`, `checker.zig`, `lower.zig`

**Problem:** `@string(s.source.ptr + start, s.pos - start)` creates string from ptr+len.

**Alternative:** Use `slice_make` pattern if available, or add this builtin.

---

## Execution Order (Priority)

### Sprint 1: Unblock scanner.cot (4 issues) - 3/4 DONE

| Order | Issue | Effort | Status |
|-------|-------|--------|--------|
| 1 | BUG-005: Fix `!` for booleans | Small | ✅ Done |
| 2 | BUG-006: Add `not` keyword | Small | ✅ Done |
| 3 | BUG-002: Struct literals | Medium | ✅ Done |
| 4 | @string builtin | Medium | **Remaining** |

**After Sprint 1:** scanner.cot should compile and run tests.

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

### scanner.cot - BLOCKED by Sprint 1 issues
- [x] Scanner struct (source, pos) - code written
- [x] scanner_new(), scanner_next() - code written
- [x] skip_whitespace(), skip_comments - code written
- [x] scan_number() for integer literals - code written
- [x] scan_ident() for identifiers/keywords - code written
- [ ] **BLOCKED:** Needs struct literals (BUG-002)
- [ ] **BLOCKED:** Needs `not` keyword (BUG-006)
- [ ] **BLOCKED:** Needs @string builtin

### scanner_test.cot
- [ ] Test single tokens
- [ ] Test whitespace handling
- [ ] Test full tokenization

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

- [ ] `token_test.cot` passes
- [ ] `scanner_test.cot` passes
- [ ] `parser_test.cot` passes
- [ ] Can compile: `fn main() i64 { return 42; }`
- [ ] Can compile: `fn main() i64 { return 20 + 22; }`
- [ ] Can compile: `fn add(a: i64, b: i64) i64 { return a + b; } fn main() i64 { return add(20, 22); }`

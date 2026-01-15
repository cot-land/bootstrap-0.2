# Cot0 Tasks

**Goal:** Minimal compiler for i64, arithmetic, functions, return.

**Last Updated:** 2026-01-16

---

## Current Status

**Blocking Issue:** Struct returns > 16 bytes don't work (BUG-004).

Token struct is 24 bytes (enum + 2x i64). ARM64 ABI requires:
- Structs <= 16B: returned in x0+x1 ✅ (BUG-003 fixed this)
- Structs > 16B: returned via hidden pointer ❌ (NOT IMPLEMENTED)

**Test Results:**
- `token_test.cot`: 4/5 pass (Test 1 fails - struct return)
- All 142 e2e tests pass (none use >16B struct returns)

---

## Phase 1: Frontend

### token.cot
- [x] TokenType enum (Int, Ident, Fn, Return, I64, punctuation, operators)
- [x] Token struct (type, start, length)
- [x] token_new() constructor - CODE WORKS, but blocked by BUG-004
- [x] is_keyword() for fn/return/i64

### token_test.cot
- [ ] Test token creation - BLOCKED by BUG-004 (24B struct return)
- [x] Test keyword recognition - 4/4 keyword tests pass

### scanner.cot
- [ ] Scanner struct (source, pos)
- [ ] scanner_new(), scanner_next()
- [ ] skip_whitespace(), skip_comments
- [ ] scan_number() for integer literals
- [ ] scan_ident() for identifiers/keywords

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

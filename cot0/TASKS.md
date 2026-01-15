# Cot0 Tasks

**Goal:** Minimal compiler for i64, arithmetic, functions, return.

---

## Phase 1: Frontend

### token.cot
- [ ] TokenType enum (Int, Ident, Fn, Return, I64, punctuation, operators)
- [ ] Token struct (type, start, length)
- [ ] token_new() constructor
- [ ] is_keyword() for fn/return/i64

### token_test.cot
- [ ] Test token creation
- [ ] Test keyword recognition

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

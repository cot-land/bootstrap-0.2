# Cot0 Tasks

**Goal:** Self-hosting Cot compiler written in Cot.

**Last Updated:** 2026-01-17

---

## Current Status

**All 166 e2e tests pass.**

| Test File | Status |
|-----------|--------|
| `token_test.cot` | 5/5 pass ✓ |
| `scanner_test.cot` | 11/11 pass ✓ |
| `ast_test.cot` | 7/7 pass ✓ |
| `parser_test.cot` | 10/10 pass ✓ |
| `types_test.cot` | 2/2 pass ✓ |
| `checker_test.cot` | 2/2 pass ✓ |

---

## Sprint Progress

| Sprint | Status | Files |
|--------|--------|-------|
| Sprint 1: Scanner | ✅ COMPLETE | token.cot, scanner.cot |
| Sprint 2: Parser | ✅ COMPLETE | ast.cot, parser.cot |
| Sprint 3: Type Checking | ✅ COMPLETE | types.cot, checker.cot |
| Sprint 4: IR & SSA | **NEXT** | ir.cot, lower.cot |
| Sprint 5: Backend | Pending | arm64/, codegen/, obj/ |

---

## Recent Bug Fixes (2026-01-17)

- BUG-019: Large struct (>16B) by-value args ✅ FIXED
- BUG-017: Imported consts in binary expressions ✅ FIXED
- BUG-016: Const on right side of comparison ✅ FIXED
- BUG-015: Chained OR (3+ conditions) ✅ FIXED
- BUG-014: Switch statements ✅ FIXED
- BUG-013: String concatenation in loops ✅ FIXED

---

## Phase 1: Frontend ✅ COMPLETE

### token.cot ✅ COMPLETE
- [x] TokenType enum (all tokens, keywords, operators)
- [x] Token struct (type, start, length)
- [x] token_new() constructor
- [x] is_keyword() for keyword lookup

### scanner.cot ✅ COMPLETE
- [x] Scanner struct (source, pos)
- [x] scanner_new(), scanner_next()
- [x] skip_whitespace(), skip_comments
- [x] scan_number(), scan_ident(), scan_string()
- [x] All 11 scanner tests pass

### ast.cot ✅ COMPLETE
- [x] NodeKind enum for all AST node types
- [x] Node struct with kind and fields
- [x] NodePool for memory management
- [x] All 7 ast tests pass

### parser.cot ✅ COMPLETE
- [x] Parser struct (scanner, current token)
- [x] parse_expr(), parse_stmt(), parse_fn()
- [x] Operator precedence (Pratt parsing)
- [x] All 10 parser tests pass

### types.cot ✅ COMPLETE
- [x] TypeKind enum (Bool, I8-I64, U8-U64, Void, Pointer, etc.)
- [x] Type struct with kind, elem, size, align
- [x] TypePool for type interning
- [x] TYPE_* constants (TYPE_I64, TYPE_BOOL, etc.)
- [x] Predicate functions (is_numeric, is_integer, etc.)
- [x] All 2 types tests pass

### checker.cot ✅ COMPLETE
- [x] Symbol struct (name, kind, type_idx)
- [x] SymbolKind enum (variable, constant, function, type)
- [x] Scope and ScopePool for name resolution
- [x] Checker struct with type_pool, scope_pool
- [x] check_expr(), check_stmt() scaffolding
- [x] All 2 checker tests pass

---

## Phase 2: IR & SSA (Sprint 4) - NEXT

### ir.cot
- [ ] IRNodeKind enum (const_int, binary, load, store, call, ret, etc.)
- [ ] IRNode struct with kind and operands
- [ ] IRFunc struct (name, blocks, locals)
- [ ] IRBuilder for constructing IR

### lower.cot
- [ ] AST to IR conversion
- [ ] Expression lowering
- [ ] Statement lowering
- [ ] Function lowering

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
- [ ] Phi node insertion

---

## Phase 3: Backend (Sprint 5)

### arm64/asm.cot
- [ ] Instruction encoding for: MOV, ADD, SUB, MUL, SDIV, BL, RET
- [ ] Register definitions (x0-x30)

### codegen/arm64.cot
- [ ] SSA to ARM64 conversion
- [ ] Register allocation
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
- [x] `ast_test.cot` passes (7/7)
- [x] `parser_test.cot` passes (10/10)
- [x] `types_test.cot` passes (2/2)
- [x] `checker_test.cot` passes (2/2)
- [x] Can compile: `fn main() i64 { return 42; }`
- [x] Can compile: `fn main() i64 { return 20 + 22; }`
- [x] Can compile: `fn add(a: i64, b: i64) i64 { return a + b; } fn main() i64 { return add(20, 22); }`
- [ ] ir.cot compiles and tests pass
- [ ] lower.cot compiles and tests pass
- [ ] Can self-compile minimal subset

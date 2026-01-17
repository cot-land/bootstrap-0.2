# Cot0 Self-Hosting Feature Requirements

**Created:** 2026-01-17

**Goal:** Identify all features that must be added to existing cot0 modules before they can compile themselves.

---

## Executive Summary

The current cot0 files **cannot self-host** because they use language features that they cannot parse or type-check. This document analyzes what features the cot0 source files actually use, and provides a prioritized implementation plan for each module.

### Critical Finding

The cot0 source files themselves use these features that cot0 cannot currently handle:

| Feature | Used In cot0? | Can cot0 Parse It? | Can cot0 Check It? |
|---------|--------------|-------------------|-------------------|
| `enum` declarations | Yes (5 enums) | No | No |
| `struct` declarations | Yes (12 structs) | No | No |
| Pointer types `*T` | Yes (heavily) | No | No |
| `let` declarations | Yes (frequent) | No | No |
| `var` declarations | Yes (frequent) | No | No |
| `const` declarations | Yes (12 consts) | No | No |
| `import` statements | Yes (every file) | No | No |
| `bool` type | Yes (many places) | No | Partial |
| `u8` type | Yes (scanner) | No | No |
| `string` type | Yes (frequent) | No | No |
| Comparison ops (`==`, `!=`, `<`, etc.) | Yes (frequent) | No | No |
| Logical ops (`and`, `or`, `not`) | Yes (frequent) | No | No |
| Control flow (`if`/`else`, `while`) | Yes (frequent) | No | No |
| Pointer dereference `ptr.*` | Yes (frequent) | No | No |
| Address-of `&x` | Yes (frequent) | No | No |
| Pointer arithmetic | Yes (checker.cot) | No | No |
| Field access `s.field` | Yes (frequent) | No | No |
| Indexing `arr[i]` | Yes (scanner.cot) | No | No |
| `@string()` builtin | Yes (scanner.cot) | No | No |
| `len()` builtin | Yes (scanner.cot) | No | No |
| Struct literals `T{ .f = v }` | Yes (frequent) | No | No |
| Enum access `E.Variant` | Yes (frequent) | No | No |

**Conclusion:** cot0 can only parse `fn name(params) i64 { return a + b; }` - it cannot parse its own source code.

---

## Module-by-Module Feature Requirements

### 1. token.cot - Token Definitions

**Current:** 17 token types (Int, Ident, Fn, Return, I64, punctuation, basic arithmetic)
**Required for self-hosting:** 80+ token types

#### Priority 1: Tokens Used by cot0 Files

| Token | Example | Used Where |
|-------|---------|------------|
| `Let` | `let x = ...` | All files |
| `Var` | `var x = ...` | All files |
| `Const` | `const MAX = ...` | types.cot, checker.cot |
| `Struct` | `struct Token { ... }` | All files |
| `Enum` | `enum TokenType { ... }` | token.cot, ast.cot, types.cot, checker.cot |
| `Import` | `import "token.cot"` | scanner.cot, parser.cot, checker.cot |
| `If` | `if condition { ... }` | All files |
| `Else` | `} else { ... }` | All files |
| `While` | `while condition { ... }` | scanner.cot, parser.cot, checker.cot |
| `Bool` | `bool` | scanner.cot, checker.cot |
| `U8` | `u8` | scanner.cot |
| `String` | `string` (slice type) | scanner.cot, parser.cot |
| `Dot` | `.field`, `.Variant` | All files |
| `Ampersand` | `&x` | parser.cot, checker.cot |
| `EqEq` | `==` | All files |
| `NotEq` | `!=` | scanner.cot, checker.cot |
| `Less` | `<` | scanner.cot |
| `LessEq` | `<=` | scanner.cot |
| `Greater` | `>` | Not used in cot0 |
| `GreaterEq` | `>=` | scanner.cot |
| `And` | `and` | scanner.cot |
| `Or` | `or` | scanner.cot |
| `Not` | `not` | scanner.cot, parser.cot |
| `True` | `true` | checker.cot |
| `False` | `false` | parser.cot |
| `LBracket` | `[` | Indexing |
| `RBracket` | `]` | Indexing |
| `At` | `@` | `@string`, `@sizeOf` |
| `Question` | `?` | Optional types (future) |
| `Void` | `void` | Return types |

**Total new tokens needed:** ~30 (just for self-hosting cot0)

#### Implementation Order for token.cot

```
Phase 1: Keywords for declarations
  Let, Var, Const, Struct, Enum, Import

Phase 2: Control flow keywords
  If, Else, While, True, False

Phase 3: Type keywords
  Bool, U8, Void, String

Phase 4: Operators
  EqEq, NotEq, Less, LessEq, Greater, GreaterEq
  And, Or, Not

Phase 5: Punctuation
  Dot, Ampersand, LBracket, RBracket, At

Phase 6: Extend is_keyword() for all new keywords
```

---

### 2. scanner.cot - Lexer

**Current:** Single-char tokens, decimal integers, identifiers, line comments
**Required for self-hosting:** Multi-char operators, all keywords, string literals

#### Features Needed

| Feature | Example | Priority |
|---------|---------|----------|
| Two-char operators | `==`, `!=`, `<=`, `>=` | 1 |
| Keyword recognition | `let`, `var`, `const`, `struct`, `enum`, `if`, `else`, `while`, `import` | 1 |
| String literals | `"token.cot"` | 1 |
| Dot operator | `.field` | 1 |
| Ampersand | `&x` | 1 |
| Brackets | `[`, `]` | 1 |
| At sign | `@string` | 1 |

#### Implementation Order for scanner.cot

```
Phase 1: Multi-character operators
  - Modify scanner_next() to peek ahead for ==, !=, <=, >=

Phase 2: Extend is_keyword() in token.cot
  - Add all control flow keywords
  - Add all type keywords

Phase 3: String literal scanning
  - scan_string() function
  - Handle escape sequences: \n, \t, \\, \"

Phase 4: Additional single-char tokens
  - Dot, Ampersand, LBracket, RBracket, At
```

---

### 3. ast.cot - AST Node Definitions

**Current:** 10 node kinds (IntLit, Ident, BinaryExpr, CallExpr, ReturnStmt, ExprStmt, BlockStmt, Param, FnDecl, plus one reserved)
**Required for self-hosting:** 40+ node kinds

#### Node Kinds Needed for cot0 Files

| Category | Node Kinds Needed |
|----------|-------------------|
| Literals | `StringLit`, `BoolLit` |
| Declarations | `VarDecl`, `ConstDecl`, `StructDecl`, `EnumDecl`, `ImportDecl`, `FieldDecl` |
| Types | `TypeIdent`, `PointerType`, `OptionalType`, `ArrayType` |
| Expressions | `UnaryExpr`, `FieldAccess`, `IndexExpr`, `StructLit`, `EnumAccess`, `DerefExpr`, `AddressOf`, `BuiltinCall` |
| Statements | `IfStmt`, `WhileStmt`, `AssignStmt` |

#### Implementation Order for ast.cot

```
Phase 1: Variable declarations
  VarDecl, ConstDecl with type annotation and initializer

Phase 2: Struct and enum declarations
  StructDecl, EnumDecl, FieldDecl

Phase 3: Control flow
  IfStmt, WhileStmt

Phase 4: Type nodes
  TypeIdent (named type), PointerType (*T)

Phase 5: Expression nodes
  UnaryExpr (-x, not x)
  FieldAccess (s.field)
  IndexExpr (arr[i])
  StructLit (T{ .x = 1 })
  EnumAccess (E.Variant)
  DerefExpr (ptr.*)
  AddressOf (&x)

Phase 6: Import
  ImportDecl with string path

Phase 7: Builtins
  BuiltinCall for @string, @sizeOf, len
```

---

### 4. parser.cot - Recursive Descent Parser

**Current:** Only parses `fn name(params) i64 { return expr; }` with basic arithmetic
**Required for self-hosting:** Full declaration/statement/expression grammar

#### Parsing Functions Needed

| Function | Parses |
|----------|--------|
| `parse_type` | Type syntax: `i64`, `bool`, `*T`, `string` |
| `parse_var_decl` | `let x: T = expr;` and `var x: T = expr;` |
| `parse_const_decl` | `const NAME = expr;` |
| `parse_struct_decl` | `struct Name { fields }` |
| `parse_enum_decl` | `enum Name { variants }` |
| `parse_import` | `import "path.cot"` |
| `parse_if_stmt` | `if cond { } else { }` |
| `parse_while_stmt` | `while cond { }` |
| `parse_assign_stmt` | `x = expr;` or `x.field = expr;` |
| `parse_field_access` | `expr.field` |
| `parse_index_expr` | `expr[index]` |
| `parse_unary` | `-expr`, `not expr`, `&expr` |
| `parse_deref` | `expr.*` |
| `parse_struct_lit` | `T{ .x = 1, .y = 2 }` |
| `parse_enum_access` | `EnumType.Variant` |
| `parse_builtin` | `@string(...)`, `@sizeOf(T)`, `len(x)` |

#### Operator Precedence Extension

Current precedence:
```
1: + -
2: * /
```

Required precedence (from SYNTAX.md):
```
1. Postfix: .field, [index], (args), .*
2. Unary: -, !, ~, &
3. Multiplicative: *, /, %, &, <<, >>
4. Additive: +, -, |, ^
5. Comparative: ==, !=, <, <=, >, >=
6. Logical AND: and, &&
7. Logical OR: or, ||
8. Assignment: =, +=, -=, etc.
```

#### Implementation Order for parser.cot

```
Phase 1: Type parsing
  parse_type() - handle i64, bool, u8, void, string, *T
  Update parse_param() to use parse_type()
  Update parse_fn_decl() to use parse_type() for return type

Phase 2: Variable declarations
  parse_var_decl() for let/var
  parse_const_decl() for const
  Update parse_stmt() to dispatch to these

Phase 3: Control flow
  parse_if_stmt() with else clause
  parse_while_stmt()
  Update parse_stmt() to handle If, While tokens

Phase 4: Comparison and logical operators
  Extend parser_prec() for ==, !=, <, <=, >, >=, and, or
  Extend parser_binop_int() for these operators
  Extend make_binary_node() for these operators

Phase 5: Postfix operators
  parse_postfix() for .field, [index], .*
  Integrate with parse_unary()

Phase 6: Unary operators
  Extend parse_unary() for -, not, &

Phase 7: Struct and enum declarations
  parse_struct_decl()
  parse_enum_decl()
  Update parse_decl() to handle Struct, Enum tokens

Phase 8: Import
  parse_import()
  Update parse_file() to handle imports first

Phase 9: Literals and constructors
  parse_struct_lit() for T{ .x = 1 }
  parse_string_lit() for "..."

Phase 10: Builtins
  parse_builtin() for @string, @sizeOf
  Integrate len() as builtin call
```

---

### 5. types.cot - Type System

**Current:** ~75% complete - has TypeKind, Type struct, TypePool, TYPE_* constants
**Missing:** Type construction for pointers, functions, arrays

#### Features Needed

| Feature | Used By |
|---------|---------|
| Pointer type construction | `*Scanner`, `*Parser`, `*Node`, etc. |
| Function type construction | Function signatures for type checking |
| Struct type construction | `Token`, `Scanner`, etc. |
| Enum type construction | `TokenType`, `NodeKind`, etc. |
| Array type construction | Not heavily used in cot0 |

#### Implementation Order for types.cot

```
Phase 1: Pointer types
  type_pointer(pool, elem_type) -> i64

Phase 2: Function types
  type_func(pool, params, ret_type) -> i64

Phase 3: Struct types
  type_struct(pool, name, fields) -> i64

Phase 4: Enum types
  type_enum(pool, name, variants) -> i64
```

---

### 6. checker.cot - Type Checker

**Current:** ~20% complete - only checks IntLit, Ident, BinaryExpr, CallExpr
**Required for self-hosting:** Full expression and statement checking

#### Expression Checking Needed

| Expression | Handler |
|------------|---------|
| `StringLit` | Return TYPE_STRING |
| `BoolLit` | Return TYPE_BOOL |
| `UnaryExpr` | Check operand, return appropriate type |
| `FieldAccess` | Check struct has field, return field type |
| `IndexExpr` | Check array/slice, return elem type |
| `StructLit` | Check all fields match struct definition |
| `EnumAccess` | Check variant exists, return enum type |
| `DerefExpr` | Check is pointer, return elem type |
| `AddressOf` | Return pointer to operand type |
| `BuiltinCall` | Handle @string, @sizeOf, len |

#### Statement Checking Needed

| Statement | Handler |
|-----------|---------|
| `VarDecl` | Add to scope, check initializer matches type |
| `ConstDecl` | Evaluate constant, add to scope |
| `IfStmt` | Check condition is bool, check both branches |
| `WhileStmt` | Check condition is bool, check body |
| `AssignStmt` | Check types match, check target is mutable |

#### Declaration Checking Needed

| Declaration | Handler |
|-------------|---------|
| `StructDecl` | Register struct type in scope |
| `EnumDecl` | Register enum type and variants |
| `ImportDecl` | Parse imported file, add symbols to scope |

#### Implementation Order for checker.cot

```
Phase 1: Variable declarations
  check_var_decl() - type annotation, initializer checking
  Add variables to scope

Phase 2: Control flow
  check_if_stmt() - condition must be bool
  check_while_stmt() - condition must be bool

Phase 3: Assignment
  check_assign_stmt() - types must match, target must be mutable

Phase 4: More expressions
  check_unary_expr() - negation, not, address-of
  check_field_access() - struct field lookup
  check_index_expr() - array/slice element access

Phase 5: User-defined types
  check_struct_decl() - register struct type
  check_enum_decl() - register enum type

Phase 6: Literals and constructors
  check_struct_lit() - field type matching
  check_enum_access() - variant lookup

Phase 7: Pointers
  check_deref_expr() - must be pointer
  check_address_of() - lvalue requirement

Phase 8: Import
  check_import() - parse and check imported file
```

---

## Implementation Priority Order

The overall order should be driven by **what blocks what**:

### Sprint A: Core Parsing Infrastructure ✅ COMPLETE (2026-01-17)
**Goal:** Parse `let x: T = expr;` and `if cond { }` and `while cond { }`

1. ✅ Add tokens: Let, Var, If, Else, While, EqEq, NotEq, Less, LessEq, Greater, GreaterEq, And, Or, Not
2. ✅ Extend scanner for two-char operators and new keywords
3. ✅ Add AST nodes: VarDecl, IfStmt, WhileStmt
4. ✅ Add parser: parse_type(), parse_var_decl(), parse_if_stmt(), parse_while_stmt()
5. ✅ Extend operator precedence for comparisons and logical ops

**Verification:** Can parse `scanner.cot`'s function bodies (they use if/while/let/var)

**Bug Fixes During Sprint A:**
- BUG-020: Many nested if statements cause segfault
- BUG-021: Chained AND with 4+ conditions incorrectly evaluates
- BUG-022: Comparison operands use same register
- BUG-023: Stack slot reuse causes value corruption
- BUG-024: String pointer becomes null in string comparisons

### Sprint B: Struct and Enum Declarations ← NEXT
**Goal:** Parse `struct Name { ... }` and `enum Name { ... }`

1. [ ] Add tokens: Struct, Enum, Dot
2. [ ] Add AST nodes: StructDecl, EnumDecl, FieldDecl, FieldAccess, EnumAccess
3. [ ] Add parser: parse_struct_decl(), parse_enum_decl(), parse_field_access()
4. [ ] Extend types.cot for struct/enum type construction

**Verification:** Can parse `token.cot` (defines TokenType enum, Token struct)

### Sprint C: Pointers and String
**Goal:** Parse `*T`, `&x`, `ptr.*`, string literals

1. Add tokens: Ampersand, String type keyword, StringLit
2. Add AST nodes: PointerType, AddressOf, DerefExpr, StringLit
3. Add parser: parse_pointer_type(), parse_address_of(), parse_deref()
4. Add scanner: scan_string()

**Verification:** Can parse `scanner.cot` (uses *Scanner, &s, s.*, "string")

### Sprint D: Imports and Constants
**Goal:** Parse `import "file.cot"` and `const NAME = value;`

1. Add tokens: Import, Const
2. Add AST nodes: ImportDecl, ConstDecl
3. Add parser: parse_import(), parse_const_decl()

**Verification:** Can parse cot0 file imports and constants

### Sprint E: Full Type Checking
**Goal:** Type check all parsed constructs

1. Implement scope management for structs/enums/functions
2. Implement variable declaration checking
3. Implement control flow checking
4. Implement struct/enum type checking
5. Implement pointer operations checking

**Verification:** Type checker passes on all cot0 files

---

## Metrics for Completion

**Last Updated:** 2026-01-17 (after Sprint A)

### Token Coverage
- Before Sprint A: 17 tokens
- After Sprint A: ~32 tokens (Let, Var, If, Else, While, Bool, True, False, And, Or, Not, EqEq, NotEq, Less, LessEq, Greater, GreaterEq + originals)
- Required for self-hosting: ~50 tokens
- Progress: **64%** ↑

### AST Node Coverage
- Before Sprint A: 10 node kinds
- After Sprint A: ~15 node kinds (+VarDecl, IfStmt, WhileStmt, CompareOp, LogicalOp)
- Required for self-hosting: ~35 node kinds
- Progress: **43%** ↑

### Parser Coverage
- Before Sprint A: Can parse `fn f(x: i64) i64 { return x + 1; }`
- After Sprint A: Can parse functions with let/var, if/else, while, comparisons, logical ops
- Required: Can parse any valid cot0 source file
- Progress: **~35%** ↑

### Checker Coverage
- Current: 4 expression types, 3 statement types
- Required: 15+ expression types, 8+ statement types
- Progress: ~20% (no change - checker not extended in Sprint A)

---

## Recommended Next Steps

1. ✅ ~~**Implement Sprint A** - Core parsing for control flow and variables~~
2. **Implement Sprint B** - Struct and enum declarations (NEXT)
3. **Test incrementally** - After each phase, verify that more of cot0 can be parsed
4. **Track progress** - Update this document with completion percentages
5. **Freeze new cot0 files** - Don't add ir.cot, lower.cot, etc. until existing files can self-host

The key insight is: **the existing cot0 files ARE the test cases**. When cot0 can parse itself, we know we've implemented enough.

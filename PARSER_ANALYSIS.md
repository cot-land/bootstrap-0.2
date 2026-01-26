# Parser Analysis: Zig vs cot1 Implementation

## Executive Summary

This document provides an **honest, accurate** comparison of the Zig parser (`src/frontend/parser.zig`, 1730 lines) and the cot1 parser (`stages/cot1/frontend/parser.cot`, 1980 lines).

**Status: DIFFERENT ARCHITECTURE, SIMILAR FUNCTIONALITY**

The parsers have **different structures** but parse the same language. They are NOT line-for-line translations.

---

## 1. FUNCTION MAPPING

### Zig Functions (38 functions)

| Line | Function | Purpose |
|------|----------|---------|
| 57 | `init` | Initialize parser |
| 82 | `pos` | Get current position |
| 87 | `advance` | Advance to next token |
| 98 | `peekToken` | Peek next token |
| 107 | `check` | Check token type |
| 114 | `peekNextIsPeriod` | Lookahead for `.` |
| 122 | `match` | Check and consume |
| 131 | `expect` | Require token |
| 141 | `unexpectedToken` | Error helper |
| 162 | `syntaxError` | Error helper |
| 167 | `incNest` | Increment nesting |
| 177 | `decNest` | Decrement nesting |
| 186 | `parseFile` | Entry point |
| 213 | `parseDecl` | Parse declaration |
| 232 | `parseExternFn` | Parse extern fn |
| 243 | `parseFnDecl` | Parse function |
| 293 | `parseFieldList` | Parse struct fields |
| 329 | `parseVarDecl` | Parse var/let |
| 364 | `parseStructDecl` | Parse struct |
| 387 | `parseEnumDecl` | Parse enum |
| 442 | `parseUnionDecl` | Parse union |
| 490 | `parseTypeAlias` | Parse type alias |
| 515 | `parseImportDecl` | Parse import |
| 543 | `parseType` | Parse type |
| 667 | `parseExpr` | Parse expression |
| 672 | `parseBinaryExpr` | Precedence climbing |
| 707 | `parseUnaryExpr` | Unary operators |
| 735 | `parsePrimaryExpr` | Primary + postfix |
| 904 | `parseOperand` | Atoms/literals |
| 1162 | `parseBlockExpr` | Block expression |
| 1189 | `parseIfExpr` | If expression |
| 1222 | `parseSwitchExpr` | Switch expression |
| 1300 | `parseBlock` | Statement block |
| 1324 | `parseStmt` | Parse statement |
| 1465 | `parseVarStmt` | Var statement |
| 1498 | `parseIfStmt` | If statement |
| 1529 | `parseWhileStmt` | While statement |
| 1550 | `parseForStmt` | For statement |

### cot1 Functions (48 functions)

| Line | Function | Zig Equivalent |
|------|----------|----------------|
| 39 | `Parser_init` | `init` |
| 57 | `Parser_advance` | `advance` |
| 62 | `Parser_check` | `check` |
| 67 | `Parser_got` | `match` |
| 76 | `Parser_want` | `expect` |
| 85 | `Parser_atEnd` | (none) |
| 95 | `Parser_incNest` | `incNest` |
| 105 | `Parser_decNest` | `decNest` |
| 111 | `Parser_peekNextIsDot` | `peekNextIsPeriod` |
| 136 | `Parser_prec` | (inline in Zig) |
| 141 | `Parser_binopInt` | (inline in Zig) |
| 152 | `Parser_resolveTypeNode` | (none - cot1 specific) |
| 208 | `Parser_parseType` | `parseType` |
| 377 | `Type_isPointer` | (none - cot1 helper) |
| 382 | `Type_pointee` | (none - cot1 helper) |
| 392 | `Parser_parseIntLit` | (inline in Zig) |
| 457 | `Parser_parseIdentOnly` | (inline in Zig) |
| 469 | `Parser_parseAtom` | `parseOperand` |
| 587 | `Parser_makeBinaryNode` | (inline in Zig) |
| 622 | `Parser_parseParenInner` | (inline in Zig) |
| 652 | `Parser_parseArgExpr` | (none - cot1 specific) |
| 679 | `Parser_parseUnary` | `parseUnaryExpr` + `parsePrimaryExpr` **MERGED** |
| 1060 | `Parser_parseBinaryExpr` | `parseBinaryExpr` |
| 1092 | `Parser_parseExpr` | `parseExpr` + assignment handling |
| 1146 | `Parser_parseReturnStmt` | (inline in Zig) |
| 1170 | `Parser_parseVarDecl` | `parseVarStmt` |
| 1213 | `Parser_parseSwitchExpr` | `parseSwitchExpr` |
| 1337 | `Parser_parseIfStmt` | `parseIfStmt` |
| 1367 | `Parser_parseWhileStmt` | `parseWhileStmt` |
| 1383 | `Parser_parseForStmt` | `parseForStmt` |
| 1406 | `Parser_parseExprStmt` | (inline in Zig) |
| 1415 | `Parser_parseStmt` | `parseStmt` |
| 1535 | `Parser_parseBlock` | `parseBlock` |
| 1570 | `Parser_parseParam` | (inline in Zig) |
| 1592 | `Parser_parseExternFnDecl` | `parseExternFn` |
| 1640 | `Parser_parseFnDecl` | `parseFnDecl` |
| 1694 | `Parser_parseStructField` | `parseFieldList` (different structure) |
| 1718 | `Parser_parseTypeAliasDecl` | `parseTypeAlias` |
| 1741 | `Parser_parseStructDecl` | `parseStructDecl` |
| 1774 | `Parser_parseEnumVariant` | (inline in Zig) |
| 1782 | `Parser_parseEnumDecl` | `parseEnumDecl` |
| 1818 | `Parser_parseImport` | `parseImportDecl` |
| 1844 | `Parser_parseConstDecl` | `parseVarDecl` (const=true) |
| 1871 | `Parser_parseGlobalVarDecl` | `parseVarDecl` |
| 1906 | `Parser_parseDecl` | `parseDecl` |
| 1951 | `Parser_parseFile` | `parseFile` |
| 1973 | `Parser_getSourceText` | (none - cot1 helper) |
| 1978 | `Parser_hadError` | (none - cot1 helper) |

---

## 2. STRUCTURAL DIFFERENCES

### 2.1 Expression Parsing Architecture

**Zig (4 levels):**
```
parseExpr
  └─> parseBinaryExpr(0)
        └─> parseUnaryExpr
              └─> parsePrimaryExpr
                    └─> parseOperand
```

**cot1 (3 levels - MERGED):**
```
parseExpr (+ assignment handling)
  └─> parseUnary (+ atom + postfix - ALL MERGED)
        └─> parseBinaryExpr
```

**CRITICAL DIFFERENCE**: cot1's `Parser_parseUnary` is ~400 lines and handles:
- Unary operators (-, !, ~, &)
- Atoms (literals, identifiers)
- Postfix operations (field access, calls, indexing)
- Builtins (@sizeOf, @intCast, etc.)
- Switch expressions

Zig separates these into `parseUnaryExpr` (~25 lines), `parsePrimaryExpr` (~170 lines), and `parseOperand` (~250 lines).

### 2.2 Binary Expression Differences

**Zig parseBinaryExpr:**
```zig
fn parseBinaryExpr(self: *Parser, min_prec: u8) ParseError!?NodeIndex {
    var left = try self.parseUnaryExpr() orelse return null;  // Parses left INSIDE
    while (true) {
        const prec = op.precedence();
        if (prec < min_prec or prec == 0) break;
        self.advance();
        const right = try self.parseBinaryExpr(prec + 1);  // prec + 1 for left-associativity
        left = ...;
    }
    return left;
}
```

**cot1 Parser_parseBinaryExpr:**
```cot
fn Parser_parseBinaryExpr(p: *Parser, left: i64, min_prec: i64) i64 {
    var x: i64 = left;  // Takes left as PARAMETER
    while bin_cur_prec > min_prec {
        Parser_advance(p);
        var right: i64 = Parser_parseUnary(p);
        right = Parser_parseBinaryExpr(p, right, bin_op_prec);  // Same prec, not prec+1
        x = Parser_makeBinaryNode(p, bin_op_int, x, right);
    }
    return x;
}
```

**Differences:**
1. Zig parses left inside; cot1 takes left as parameter
2. Zig uses `prec + 1` for recursion; cot1 uses same `bin_op_prec`
3. cot1 has separate `Parser_prec()` and `Parser_binopInt()` helpers

### 2.3 Assignment Handling

**Zig:** Assignment is NOT handled in parseExpr (handled in parseStmt)

**cot1:** Assignment IS handled in parseExpr:
```cot
fn Parser_parseExpr(p: *Parser) i64 {
    let left: i64 = Parser_parseUnary(p);
    let expr: i64 = Parser_parseBinaryExpr(p, left, 0);

    // Assignment: expr = value
    if Parser_got(p, TokenType.Eq) {
        let value: i64 = Parser_parseExpr(p);
        return Node_assign(p.pool, expr, value, start, end);
    }

    // Compound assignments: +=, -=, *=, /=, &=, |=
    if Parser_got(p, TokenType.PlusEq) { ... }
    // etc.
}
```

This is a **significant architectural difference**.

---

## 3. TOKEN HANDLING COMPARISON

| Aspect | Zig | cot1 | Match? |
|--------|-----|------|--------|
| Advance | `advance()` | `Parser_advance()` | YES |
| Check | `check(tok)` | `Parser_check(tok)` | YES |
| Match/consume | `match(tok)` | `Parser_got(tok)` | YES |
| Require | `expect(tok)` | `Parser_want(tok)` | YES |
| Peek | `peekToken()` | **MISSING** | NO |
| Error reporting | `ErrorReporter` | `had_error` flag | DIFFERENT |

**Missing in cot1:** Peek token support. Zig has 1-token lookahead via `peek_tok`.

---

## 4. NESTING DEPTH PROTECTION

**Zig:**
```zig
const max_nest_lev: u32 = 10000;

fn incNest(self: *Parser) bool {
    self.nest_lev += 1;
    if (self.nest_lev > max_nest_lev) {
        self.syntaxError("exceeded maximum nesting depth");
        return false;
    }
    return true;
}
```

**cot1:**
```cot
const LIMIT_NEST_LEV: i64 = 10000;

fn Parser_incNest(p: *Parser) bool {
    p.nest_lev = p.nest_lev + 1;
    if p.nest_lev > LIMIT_NEST_LEV {
        p.had_error = true;
        return false;
    }
    return true;
}
```

**Status: MATCHED** - Same logic, same limit.

---

## 5. SPECIFIC FUNCTION COMPARISONS

### 5.1 parseType

**Zig (lines 543-665):** ~120 lines, handles:
- Primitive types (i8, i16, i32, i64, u8, bool, void, string)
- Pointer types (*T)
- Optional types (?T)
- Array types ([N]T, []T)
- Function types (fn(...) T)
- Struct/enum type references

**cot1 (lines 208-375):** ~170 lines, handles:
- Same primitives
- Pointer types
- Optional types (different representation)
- Array types
- Function pointer types (slightly different syntax)

**Status: SIMILAR** - Both handle the same type syntax with minor implementation differences.

### 5.2 parseDecl

**Zig (lines 213-230):**
```zig
fn parseDecl(self: *Parser) ParseError!?NodeIndex {
    return switch (self.tok.tok) {
        .kw_fn => self.parseFnDecl(false),
        .kw_extern => self.parseExternFn(),
        .kw_struct => self.parseStructDecl(),
        .kw_enum => self.parseEnumDecl(),
        .kw_union => self.parseUnionDecl(),
        .kw_type => self.parseTypeAlias(),
        .kw_import => self.parseImportDecl(),
        .kw_const => self.parseVarDecl(true),
        .kw_var, .kw_let => self.parseVarDecl(false),
        else => null,
    };
}
```

**cot1 (lines 1906-1949):**
```cot
fn Parser_parseDecl(p: *Parser) i64 {
    let kind: TokenType = p.current.kind;
    if kind == TokenType.Fn { return Parser_parseFnDecl(p); }
    if kind == TokenType.Extern { return Parser_parseExternFnDecl(p); }
    if kind == TokenType.Struct { return Parser_parseStructDecl(p); }
    if kind == TokenType.Enum { return Parser_parseEnumDecl(p); }
    if kind == TokenType.Type { return Parser_parseTypeAliasDecl(p); }
    if kind == TokenType.Import { return Parser_parseImport(p); }
    if kind == TokenType.Const { return Parser_parseConstDecl(p); }
    if kind == TokenType.Var { return Parser_parseGlobalVarDecl(p); }
    if kind == TokenType.Let { return Parser_parseGlobalVarDecl(p); }
    // Error handling...
}
```

**Status: MATCHED** - Same dispatch logic, different syntax.

---

## 6. WHAT'S MISSING IN COT1

1. **`peekToken()`** - No lookahead support
2. **`parseUnionDecl()`** - No union type support
3. **`unexpectedToken()`** - No detailed error messages
4. **`syntaxError()`** - Minimal error reporting (just sets `had_error`)
5. **Span tracking** - cot1 tracks start/end positions but less structured

---

## 7. WHAT'S DIFFERENT IN COT1

1. **Merged parsing functions** - parseUnary handles atoms, postfix, builtins
2. **Assignment in parseExpr** - Zig handles in parseStmt
3. **Builtin detection** - cot1 does manual string comparison (checking ASCII values)
4. **Error handling** - cot1 uses simple `had_error` flag vs Zig's ErrorReporter

---

## 8. HONEST ASSESSMENT

**Is cot1 parser at "parity" with Zig?**

**NO.** They are different implementations that parse the same language.

**Similarities:**
- Same grammar/language being parsed
- Same nesting depth protection
- Same basic token handling pattern (advance, check, match/got, expect/want)
- Same overall structure (recursive descent with precedence climbing)

**Differences:**
- Different function decomposition (cot1 has larger, merged functions)
- Different assignment handling location
- Missing union support
- Missing peek token
- Different error reporting
- Binary expression recursion uses different precedence (prec vs prec+1)

**Does it work?**
- Stage1 compiles successfully
- 166 tests pass
- Stage2 crashes during **import processing**, not parsing

The crash at `main.cot:295` is in `Import_resolvePath`, not in the parser itself.

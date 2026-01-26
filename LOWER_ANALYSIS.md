# Lower Analysis - lower.zig vs lower.cot

## Summary

| Metric | Zig | cot1 | Status |
|--------|-----|------|--------|
| Lines of Code | 2815 | 4850 | cot1 72% larger |
| Functions | 54 | 99 | cot1 has ~2x more (finer-grained + helpers) |
| Core Lowering | 46 | ~60 | Similar coverage |

**Parity Status: ~85% - needs cleanup and missing ops**

---

## Function-by-Function Comparison

### 1. Initialization & State Management

| Zig Function | cot1 Function | Parity | Notes |
|--------------|---------------|--------|-------|
| `Lowerer.init` | `Lowerer_init` | Same | Both initialize with IR storage |
| `Lowerer.initWithBuilder` | - | **Gap** | cot1 lacks shared builder init |
| `Lowerer.deinit` | - | **Gap** | cot1 doesn't free (malloc-based) |
| `Lowerer.lower` | `Lowerer_lowerAll` | Same | Main entry, 6-pass lowering |
| `Lowerer.lowerToBuilder` | - | **Gap** | cot1 doesn't support shared builder |

### 2. Declaration Lowering

| Zig Function | cot1 Function | Parity | Notes |
|--------------|---------------|--------|-------|
| `lowerDecl` | (inline in lowerAll) | Same | Dispatch in lowerAll passes |
| `lowerFnDecl` | `Lowerer_lowerFnDecl` | Same | Params, body, implicit void return |
| `lowerGlobalVarDecl` | `Lowerer_registerGlobalVar` | Same | Type inference, const inlining |
| `lowerStructDecl` | `Lowerer_registerStructType` | Same | Field offset computation |

### 3. Statement Lowering

| Zig Function | cot1 Function | Parity | Notes |
|--------------|---------------|--------|-------|
| `lowerBlockNode` | `Lowerer_lowerBlock` / `Lowerer_lowerBlockCheckTerminated` | Same | Block with termination check |
| `lowerStmt` | `Lowerer_lowerStmt` | Same | Statement dispatch |
| `lowerReturn` | `Lowerer_lowerReturn` | Same | Defer cleanup before return |
| `emitDeferredExprs` | `Lowerer_emitDeferredExprs` | Same | LIFO defer emission |
| `lowerLocalVarDecl` | `Lowerer_lowerVarDecl` | Same | Type resolve, local add |
| `lowerArrayInit` | `Lowerer_lowerArrayLitToLocal` | Same | Element-by-element store |
| `lowerStructInit` | `Lowerer_lowerStructLitToLocal` | Same | Field-by-field store |
| `lowerStringInit` | (inline) | Same | ptr+len pair storage |
| `lowerAssign` | `Lowerer_lowerAssign` | Same | All target types |
| `lowerIf` | `Lowerer_lowerIf` | Same | Blocks + merge |
| `lowerWhile` | `Lowerer_lowerWhile` | Same | Loop context + labeled (cot1) |
| `lowerFor` | `Lowerer_lowerFor` | Same | Desugar to while + index |
| `lowerBreak` | `Lowerer_lowerBreak` | Same | Defer cleanup + labeled (cot1) |
| `lowerContinue` | `Lowerer_lowerContinue` | Same | Defer cleanup + labeled (cot1) |
| `findLabeledLoop` | `Lowerer_findLabel` | Same | Label stack search |

### 4. Expression Lowering

| Zig Function | cot1 Function | Parity | Notes |
|--------------|---------------|--------|-------|
| `lowerExprNode` | `Lowerer_lowerExpr` | Same | Expression dispatch |
| `lowerExpr` | `Lowerer_lowerExpr` | Same | Kind-based dispatch |
| `lowerStructInitExpr` | `Lowerer_lowerStructLit` | Same | Temp local + init |
| `lowerLiteral` | `Lowerer_lowerIntLit` / `Lowerer_lowerStringLit` | Same | Split into specialized |
| `lowerIdent` | `Lowerer_lowerIdent` | Same | Const/local/global/func |
| `lowerBinary` | `Lowerer_lowerBinary` | Same | + string concat special |
| `lowerUnary` | `Lowerer_lowerUnary` | Same | neg/not/bitnot |
| `lowerFieldAccess` | `Lowerer_lowerFieldAccess` | **Check** | Complex: 4 cases, enum variants |
| `lowerIndex` | `Lowerer_lowerIndex` | Same | Array/slice indexing |
| `lowerArrayLiteral` | `Lowerer_lowerArrayLitToLocal` | Same | Temp + element store |
| `lowerSliceExpr` | `Lowerer_lowerSliceExpr` | Same | arr[start:end] |
| `lowerCall` | `Lowerer_lowerCall` | Same | Two-pass args, indirect calls |
| `lowerMethodCall` | - | **Gap** | cot1 lacks method call support |
| `lowerBuiltinLen` | `Lowerer_lowerBuiltinLen` | Same | Arrays/strings/slices |
| `lowerBuiltinStringMake` | - | **Gap** | __string_make builtin |
| `lowerBuiltinPrint` | `Lowerer_lowerBuiltinPrint` | Same | write() dispatch |
| `lowerIfExpr` | - | **Gap** | Ternary-like if expression |
| `lowerSwitchExpr` | `Lowerer_lowerSwitchExpr` | Same | Nested selects |
| `lowerSwitchStatement` | - | **Gap** | Control-flow switch |
| `lowerSwitchAsSelect` | (inline in lowerSwitchExpr) | Same | Nested select building |
| `lowerBuiltinCall` | `Lowerer_lowerBuiltinCall` | Same | @sizeOf, @ptrCast, etc. |

### 5. Type Resolution

| Zig Function | cot1 Function | Parity | Notes |
|--------------|---------------|--------|-------|
| `resolveTypeNode` | `resolve_type_expr` | Same | AST type to index |
| `resolveTypeKind` | (inline in resolve_type_expr) | Same | Recursive type building |
| `inferExprType` | `Lowerer_inferExprType` | Same | Expression type inference |
| `inferBinaryType` | (inline) | Same | Comparison returns bool |

### 6. Helper Functions

| Zig Function | cot1 Function | Parity | Notes |
|--------------|---------------|--------|-------|
| `tokenToBinaryOp` | `ASTOp_toIROp` | Same | Binary op mapping |
| `tokenToUnaryOp` | `ASTUnaryOp_toIROp` | Same | Unary op mapping |
| `parseCharLiteral` | - | **Gap** | Char literal parsing |
| `parseStringLiteral` | `compute_escaped_length` | Partial | Length only, not full parse |

---

## Critical Gaps to Close

### 1. Missing Functions (Priority: High)

```
lowerMethodCall          - Method call lowering (obj.method(args))
lowerIfExpr              - If expression (ternary-like)
lowerSwitchStatement     - Switch as control flow (not select)
lowerBuiltinStringMake   - __string_make(ptr, len) builtin
parseCharLiteral         - Full char literal parsing with escapes
```

### 2. Empty Symbol Bug (Priority: Critical)

The linking error `undefined symbol: _` suggests somewhere a call is being emitted with an empty function name. This is likely in:
- `Lowerer_lowerFieldAccess` calling `Lowerer_lookupEnumVariant`
- Or `Lowerer_lowerCall` with a corrupted function name

**Investigation needed**: Check if `func_name_len` is 0 somewhere, or if `copy_func_name` is being called with invalid parameters.

### 3. Architecture Differences

| Aspect | Zig | cot1 | Notes |
|--------|-----|------|-------|
| Builder sharing | Supported | Not supported | Cross-file globals visibility |
| Memory management | Allocator | malloc/realloc | Intentional for bootstrap |
| Error handling | Error union | Return codes | Simplified |
| Type aliases | Checker handles | Lowerer handles | cot1 feature |
| Labeled loops | Zig-native | Manual label stack | cot1 feature |

---

## Recommendations

1. **Fix empty symbol bug first** - This blocks linking stage2
2. **Add lowerMethodCall** - Required for method syntax
3. **Add lowerIfExpr** - Common pattern in compiler code
4. **Clean up duplicated code** - cot1 is 72% larger due to inline helpers

---

## Performance Notes

- `Lowerer_findFuncRetType` - Now O(1) via func_ret_map (fixed)
- `Lowerer_lookupEnumVariant` - Still O(n) scan of AST nodes
- `Lowerer_lookupTypeAlias` - O(n) but small list
- `Lowerer_lookupConst` - O(n) but small list
- `Lowerer_lookupGlobal` - O(n), could use StrMap

---

## Verified Working

- 6-pass lowering order
- Struct field offset computation
- Defer stack (LIFO)
- Labeled break/continue (cot1)
- Type alias support (cot1)
- Two-pass call argument lowering
- String concatenation
- Slice expressions
- Switch expressions (as select)

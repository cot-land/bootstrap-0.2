# Phase 6: Frontend Implementation - Zig → Zig with Go Patterns

This document details the frontend implementation using Go's proven compiler architecture.

## Approach

**NOT** porting .cot files to .zig directly. Instead:
- Study Go's compiler architecture (`~/learning/go/src/cmd/compile/`)
- Study bootstrap's working implementations for reference
- Implement in idiomatic Zig 0.15 following Go's proven patterns

## Module Dependency Graph

```
Tier 0 (Foundation - no dependencies):
  Go: go/token         → src/frontend/token.zig      ✅ COMPLETE
  Go: go/token/position→ src/frontend/source.zig     ✅ COMPLETE

Tier 1 (Error Handling - depends on source):
  Go: errors + internal → src/frontend/errors.zig   ✅ COMPLETE

Tier 2 (Lexing - depends on token, errors):
  Go: go/scanner       → src/frontend/scanner.zig   ✅ COMPLETE

Tier 3 (AST - depends on source, token):
  Go: go/ast           → src/frontend/ast.zig       ✅ COMPLETE

Tier 4 (Parsing - depends on scanner, ast):
  Go: go/parser        → src/frontend/parser.zig    ✅ COMPLETE

Tier 5 (Type System - depends on ast):
  Go: go/types         → src/frontend/types.zig     ✅ COMPLETE
  Go: go/types/checker → src/frontend/checker.zig   ✅ COMPLETE

Tier 6 (IR - standalone):
  Go: internal/ir      → src/frontend/ir.zig        ✅ COMPLETE

Tier 7 (Lowering - depends on checker, ir):
  Go: gc/walk + ssagen → src/frontend/lower.zig     ✅ COMPLETE

Tier 8 (Driver - connects pipeline):
  Custom               → src/frontend/driver.zig     ⏳ TODO
```

---

## Completed Modules

### 6.1 Token Definitions (`src/frontend/token.zig`) ✅

**Lines:** ~300
**Features:**
- Token enum with 80+ token types (operators, keywords, literals)
- Precedence enum for Pratt parsing
- `lookupKeyword()` - string to keyword token
- `symbol()` - token to string representation
- `binaryPrecedence()` - operator precedence lookup

**Go Reference:** `go/token/token.go`

---

### 6.2 Source/Position (`src/frontend/source.zig`) ✅

**Lines:** ~200
**Features:**
- `Pos` - compact offset representation
- `Span` - start/end position range
- `Position` - decoded line:column info
- `Source` - file path + content storage
- Position arithmetic and span merging

**Go Reference:** `go/token/position.go`

---

### 6.3 Error Handling (`src/frontend/errors.zig`) ✅

**Lines:** ~250
**Features:**
- `ErrorCode` enum (E100-E104 scanner, E200-E209 parser, E300-E303 checker)
- `Error` struct with span, message, code
- `ErrorReporter` - collects and reports errors
- Contextual formatting with source snippets

**Go Reference:** `go/types/errors.go`, `cmd/compile/internal/syntax/error_test.go`

---

### 6.4 Scanner (`src/frontend/scanner.zig`) ✅

**Lines:** ~600
**Features:**
- `Scanner` struct with cursor tracking
- Character predicates (isAlpha, isDigit, etc.)
- Number scanning (hex, octal, binary, float)
- String/char literal scanning with escape sequences
- Comment handling (line and block)
- Comprehensive token recognition

**Go Reference:** `go/scanner/scanner.go`

---

### 6.5 AST Definitions (`src/frontend/ast.zig`) ✅

**Lines:** ~700
**Features:**
- `NodeIndex` type (u32 index into node pool)
- `Node` tagged union with 45+ node kinds
- Declaration nodes: fn_decl, var_decl, struct_decl, enum_decl
- Statement nodes: return, if, while, for, block, assign
- Expression nodes: binary, unary, call, index, field, literals
- `Ast` container with node storage and extra data

**Go Reference:** `go/ast/ast.go`

---

### 6.6 Parser (`src/frontend/parser.zig`) ✅

**Lines:** ~1500
**Features:**
- `Parser` struct with token stream
- Pratt parsing for expressions with precedence
- Declaration parsing (fn, var, struct, enum, union)
- Statement parsing (if, while, for, return, block)
- Type expression parsing (pointers, optionals, arrays, slices)
- Error recovery and synchronization

**Go Reference:** `go/parser/parser.go`

---

### 6.7 Type System (`src/frontend/types.zig`) ✅

**Lines:** ~450
**Features:**
- `TypeIndex` for type interning
- Pre-registered basic types (VOID, BOOL, I8-I64, U8-U64, F32, F64, STRING)
- Untyped literals (UNTYPED_INT, UNTYPED_FLOAT, UNTYPED_BOOL)
- `Type` union: basic, pointer, optional, array, slice, struct, enum, union, function
- `TypeRegistry` with registration, lookup, equality checking
- `sizeOf()`, `alignmentOf()`, `isAssignable()`

**Go Reference:** `go/types/type.go`, `go/types/basic.go`

---

### 6.8 Type Checker (`src/frontend/checker.zig`) ✅

**Lines:** ~1600
**Features:**
- `Symbol` with kind, type, node reference
- `Scope` with parent chain for lexical scoping
- Two-pass checking: collect declarations, then check bodies
- Expression type inference with caching
- Statement checking (return type, loop context)
- Method registry for user-defined types
- Untyped literal materialization

**Go Reference:** `go/types/checker.go`, `go/types/expr.go`, `go/types/stmt.go`

---

## Completed (cont.)

### 6.9 IR Definitions (`src/frontend/ir.zig`) ✅

**Lines:** ~1200 (estimated)
**Features to implement:**

1. **Distinct Index Types** (from bootstrap):
   - `NodeIndex` - index into node pool
   - `LocalIdx` - index into local variable table
   - `BlockIndex` - index into block pool
   - `ParamIdx`, `StringIdx`

2. **Operation Kinds**:
   - `BinaryOp` - add, sub, mul, div, mod, comparisons, logical, bitwise
   - `UnaryOp` - neg, not, bit_not

3. **Typed Payloads** (strongly typed, not generic args):
   - `ConstInt`, `ConstFloat`, `ConstBool`, `ConstSlice`
   - `LocalRef`, `Binary`, `Unary`
   - `StoreLocal`, `FieldLocal`, `StoreLocalField`
   - `IndexLocal`, `IndexValue`, `SliceLocal`, `SliceValue`
   - `PtrLoad`, `PtrStore`, `PtrField`, `PtrFieldStore`
   - `Call`, `Return`, `Jump`, `Branch`, `Phi`, `Select`

4. **Data Structures**:
   - `Node` - tagged union with type_idx, span, block, data
   - `Block` - basic block with preds, succs, nodes
   - `Local` - variable with name, type, size, offset
   - `Func` - function with locals, blocks, nodes, frame_size
   - `Global` - global variable/constant
   - `IR` - complete program

5. **Builders**:
   - `FuncBuilder` - convenience methods for emitting nodes
   - `Builder` - program construction

**Go Reference:** `cmd/compile/internal/ir/node.go`, `cmd/compile/internal/ir/func.go`

---

## TODO

### 6.10 AST Lowering (`src/frontend/lower.zig`) ⏳

**Estimated Lines:** ~1000
**Features:**

1. **Lowerer Struct**:
   - Current function builder
   - Loop context stack (break/continue targets)
   - String literal table
   - Type registry reference

2. **Declaration Lowering**:
   - `lowerFnDecl` - parameters, body, return
   - `lowerStructDecl` - register type
   - `lowerVarDecl` - global variables

3. **Statement Lowering**:
   - `lowerReturnStmt` - emit ret node
   - `lowerIfStmt` - branch + blocks
   - `lowerWhileStmt` - loop header + body + back edge
   - `lowerForStmt` - init + while transformation
   - `lowerAssignStmt` - store_local or ptr_store
   - `lowerBlockStmt` - sequence of statements

4. **Expression Lowering**:
   - `lowerExpr` - dispatch on node kind
   - `lowerIdentifier` - local_ref or global lookup
   - `lowerLiteral` - const_int, const_float, const_bool, const_slice
   - `lowerBinary` - binary op with operands
   - `lowerUnary` - unary op
   - `lowerCall` - call node with args
   - `lowerField` - field_local or field_value
   - `lowerIndex` - index_local or index_value
   - `lowerAddrOf` - addr_local or addr_offset
   - `lowerDeref` - ptr_load

**Go Reference:** `cmd/compile/internal/gc/walk.go`, `cmd/compile/internal/ssagen/ssa.go`

---

### 6.11 Compilation Driver (`src/frontend/driver.zig`) ⏳

**Estimated Lines:** ~300
**Features:**

1. **Pipeline Orchestration**:
   - Read source file
   - Create Scanner, parse with Parser
   - Type check with Checker
   - Lower to IR with Lowerer
   - Return IR or errors

2. **Error Aggregation**:
   - Collect scanner errors
   - Collect parser errors
   - Collect type checker errors
   - Format and report all

3. **Debug Output** (flags):
   - `--debug-ast` - dump parsed AST
   - `--debug-types` - dump type registry
   - `--debug-ir` - dump lowered IR

---

## Integration with Backend

After Phase 6, connect to existing backend:

### IR → SSA Conversion
- Convert frontend IR to `ssa.Func`
- Insert phi nodes at dominance frontiers
- Build proper CFG with edges

### SSA → Machine Code (existing)
- `src/ssa/passes/lower.zig` - generic → arch-specific
- `src/ssa/regalloc.zig` - register allocation
- `src/codegen/arm64.zig` - instruction emission
- `src/obj/macho.zig` - Mach-O output

---

## Test Status

**Current passing tests:** 164+

| Module | Tests | Status |
|--------|-------|--------|
| token.zig | 6 | ✅ |
| source.zig | 5 | ✅ |
| errors.zig | 4 | ✅ |
| scanner.zig | 12 | ✅ |
| ast.zig | 8 | ✅ |
| parser.zig | 15 | ✅ |
| types.zig | 10 | ✅ |
| checker.zig | 8 | ✅ |
| ir.zig | 7 | ✅ |
| lower.zig | 3 | ✅ |
| Backend (phases 1-5) | 86+ | ✅ |

---

## Key Differences from Original Plan

1. **No .cot files** - We implement directly in Zig
2. **Go patterns first** - Study Go source before implementing
3. **Strongly typed IR** - Following bootstrap's improved design
4. **Incremental testing** - Each module has unit tests
5. **Clean separation** - Frontend IR distinct from SSA backend

---

## Success Criteria

1. ✅ All unit tests pass
2. ✅ Can parse Cot source files
3. ✅ Can type check Cot programs
4. ⏳ Can lower AST to IR
5. ⏳ Can convert IR to SSA
6. ⏳ Can compile `fn main() { return 42; }`

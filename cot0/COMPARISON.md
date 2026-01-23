# cot0 vs Zig Function-by-Function Comparison

**Goal**: Every function should show "Same" - identical name and logic to Zig.

---

## Section 1: Main Entry Point (main.cot vs main.zig + driver.zig)

### 1.1 main.zig Functions

| Zig Function | cot0 Function | Status | Notes |
|--------------|---------------|--------|-------|
| `main()` | `main(argc, argv)` | Same | Entry point, arg parsing, calls Driver |
| `findRuntimePath()` | (not needed) | N/A | cot0 links runtime differently |

### 1.2 driver.zig Functions

| Zig Function | cot0 Function | Status | Notes |
|--------------|---------------|--------|-------|
| `Driver.init()` | `Driver_init()` | Same | Initialize driver state |
| `Driver.compileSource()` | `Driver_compileSource()` | Same | Compile source text |
| `Driver.compileFile()` | `Driver_compileFile()` | Same | Compile file with imports |
| `Driver.parseFileRecursive()` | `Driver_parseFileRecursive()` | Same | Recursive import parsing |
| `Driver.generateCode()` | (inlined) | Equivalent | Logic is in Driver_compileFile |
| `Driver.setDebugPhases()` | `Driver_setDebugPhases()` | Same | Stub for API parity |

### 1.3 Missing in cot0

| Zig | Purpose | Priority |
|-----|---------|----------|
| `CompileResult` struct | Return type for compilation | Low (cot0 uses i64) |
| `ParsedFile` struct | Track parsed files | Low (cot0 uses globals) |

---

## Section 2: Frontend

### 2.1 token.cot vs token.zig

| Zig Function/Type | cot0 Function/Type | Status | Notes |
|-------------------|-------------------|--------|-------|
| `Token` struct | `Token` struct | Same | Token kind + position |
| `TokenType` enum | `TokenType` enum | Same | All token kinds |

### 2.2 scanner.cot vs scanner.zig

| Zig Function | cot0 Function | Status | Notes |
|--------------|---------------|--------|-------|
| `Scanner.init()` | `Scanner_init()` | Same | |
| `Scanner.initWithErrors()` | (not needed) | N/A | cot0 uses panic |
| `Scanner.next()` | `Scanner_next()` | Same | Get next token |
| `Scanner.peek()` | `Scanner_peek()` | Same | Peek without advancing |
| `Scanner.scanToken()` | `Scanner_scanToken()` | Same | Main scanning logic |
| `Scanner.skipWhitespace()` | `Scanner_skipWhitespace()` | Same | |
| `Scanner.scanIdentifier()` | `Scanner_scanIdentifier()` | Same | |
| `Scanner.scanNumber()` | `Scanner_scanNumber()` | Same | |
| `Scanner.scanString()` | `Scanner_scanString()` | Same | |
| `Scanner.scanChar()` | `Scanner_scanChar()` | Same | |

### 2.3 ast.cot vs ast.zig

| Zig Function/Type | cot0 Function/Type | Status | Notes |
|-------------------|-------------------|--------|-------|
| `Node` tagged union | `Node` struct | Equivalent | cot0 uses field0-field5 |
| `NodeIndex` | `i64` | Same | Index into nodes array |
| `Ast` struct | `NodePool` struct | Same | Node storage |
| `Ast.init()` | `NodePool_init()` | Same | |
| `Ast.getImports()` | (in parser) | Equivalent | |

### 2.4 parser.cot vs parser.zig

| Zig Function | cot0 Function | Status | Notes |
|--------------|---------------|--------|-------|
| `Parser.init()` | `Parser_init()` | Same | |
| `Parser.parseFile()` | `Parser_parseFile()` | Same | |
| `Parser.parseDecl()` | `Parser_parseDecl()` | Same | |
| `Parser.parseFnDecl()` | `Parser_parseFnDecl()` | Same | |
| `Parser.parseStructDecl()` | `Parser_parseStructDecl()` | Same | |
| `Parser.parseConstDecl()` | `Parser_parseConstDecl()` | Same | |
| `Parser.parseVarDecl()` | `Parser_parseVarDecl()` | Same | |
| `Parser.parseBlock()` | `Parser_parseBlock()` | Same | |
| `Parser.parseStmt()` | `Parser_parseStmt()` | Same | |
| `Parser.parseExpr()` | `Parser_parseExpr()` | Same | |
| `Parser.parseType()` | `Parser_parseType()` | Same | Returns TypeExpr AST nodes |
| `Parser.expect()` | `Parser_expect()` | Same | |
| `Parser.check()` | `Parser_check()` | Same | |
| `Parser.advance()` | `Parser_advance()` | Same | |

### 2.5 types.cot vs types.zig

| Zig Function/Type | cot0 Function/Type | Status | Notes |
|-------------------|-------------------|--------|-------|
| `Type` struct | `Type` struct | Same | Type representation |
| `TypeKind` enum | `TypeKind` enum | Same | |
| `TypeRegistry` struct | `TypeRegistry` struct | Same | |
| `TypeRegistry.init()` | `TypeRegistry_init()` | Same | |
| `TypeRegistry.get()` | `TypeRegistry_get()` | Same | |
| `TypeRegistry.sizeOf()` | `TypeRegistry_sizeof()` | Same | |
| `TypeRegistry.makePointer()` | `TypeRegistry_makePointer()` | Same | |
| `TypeRegistry.makeArray()` | `TypeRegistry_makeArray()` | Same | |
| `TypeRegistry.makeSlice()` | `TypeRegistry_makeSlice()` | Same | |
| `TypeRegistry.makeStruct()` | `TypeRegistry_makeStruct()` | Same | |
| `TypeRegistry.lookupField()` | `TypeRegistry_lookupField()` | Same | |

### 2.6 checker.cot vs checker.zig

| Zig Function | cot0 Function | Status | Notes |
|--------------|---------------|--------|-------|
| `Checker.init()` | (not present) | Missing | cot0 skips full type checking |
| `Checker.checkFile()` | (not present) | Missing | |
| `Checker.resolveTypeExpr()` | `resolve_type_expr()` | Same | In lower.cot |

**Note**: cot0 does minimal type checking. Most type resolution is done in lowering phase.

### 2.7 ir.cot vs ir.zig

| Zig Function/Type | cot0 Function/Type | Status | Notes |
|-------------------|-------------------|--------|-------|
| `IR` struct | (globals) | Equivalent | cot0 uses g_ir_* globals |
| `Node` (IRNode) | `IRNode` struct | Same | |
| `Func` (IRFunc) | `IRFunc` struct | Same | |
| `Local` (IRLocal) | `IRLocal` struct | Same | |
| `Global` (IRGlobal) | `IRGlobal` struct | Same | |
| `FuncBuilder` struct | `FuncBuilder` struct | Same | |
| `FuncBuilder.init()` | `FuncBuilder_init()` | Same | |
| `FuncBuilder.emit*()` | `FuncBuilder_emit*()` | Same | All emit functions |

### 2.8 lower.cot vs lower.zig

| Zig Function | cot0 Function | Status | Notes |
|--------------|---------------|--------|-------|
| `Lowerer.init()` | `Lowerer_init()` | Same | |
| `Lowerer.lower()` | `Lowerer_lowerAll()` | Same | |
| `Lowerer.lowerFn()` | `Lowerer_lowerFn()` | Same | |
| `Lowerer.lowerStmt()` | `Lowerer_lowerStmt()` | Same | |
| `Lowerer.lowerExpr()` | `Lowerer_lowerExpr()` | Same | |
| `Lowerer.lowerBinary()` | `Lowerer_lowerBinary()` | Same | |
| `Lowerer.lowerCall()` | `Lowerer_lowerCall()` | Same | |
| `Lowerer.lowerFieldAccess()` | `Lowerer_lowerFieldAccess()` | Same | |
| `Lowerer.lowerIndex()` | `Lowerer_lowerIndex()` | Same | |
| `Lowerer.lowerAssign()` | `Lowerer_lowerAssign()` | Same | |

---

## Section 3: SSA

### 3.1 op.cot vs op.zig

| Zig | cot0 | Status |
|-----|------|--------|
| `Op` enum | `Op` enum | Same |
| `OpInfo` struct | (constants) | Equivalent |

### 3.2 value.cot vs value.zig

| Zig | cot0 | Status |
|-----|------|--------|
| `Value` struct | `Value` struct | Same |
| All Value fields | All Value fields | Same |

### 3.3 block.cot vs block.zig

| Zig | cot0 | Status |
|-----|------|--------|
| `Block` struct | `Block` struct | Same |
| `BlockKind` enum | `BlockKind` enum | Same |

### 3.4 func.cot vs func.zig

| Zig | cot0 | Status |
|-----|------|--------|
| `Func` struct | `Func` struct | Same |
| `Func.init()` | `Func_init()` | Same |
| `Func.newBlock()` | `Func_newBlock()` | Same |
| `Func.newValue()` | `Func_newValue()` | Same |

### 3.5 builder.cot vs ssa_builder.zig

| Zig | cot0 | Status |
|-----|------|--------|
| `SSABuilder.init()` | `SSABuilder_init()` | Same |
| `SSABuilder.build()` | `SSABuilder_build()` | Same |
| `SSABuilder.convertNode()` | `SSABuilder_convertNode()` | Same |

### 3.6-3.7 liveness.cot, regalloc.cot

| Zig | cot0 | Status |
|-----|------|--------|
| `computeLiveness()` | (in regalloc) | Equivalent |
| `regalloc()` | (in genssa) | Equivalent |

---

## Section 4: ARM64

### 4.1 arm64/asm.cot vs arm64/asm.zig

| Zig | cot0 | Status |
|-----|------|--------|
| All instruction encoders | All instruction encoders | Same |

---

## Section 5: Codegen

### 5.1 genssa.cot vs codegen/arm64.zig

| Zig | cot0 | Status |
|-----|------|--------|
| `ARM64CodeGen` struct | `GenState` struct | Same |
| `generateBinary()` | `GenState_generate()` | Same |
| `finalize()` | (in main) | Equivalent |

---

## Section 6: Object File

### 6.1 macho.cot vs obj/macho.zig

| Zig | cot0 | Status |
|-----|------|--------|
| `MachOWriter` struct | `MachOWriter` struct | Same |
| `MachOWriter.init()` | `MachOWriter_init()` | Same |
| `MachOWriter.write()` | `MachOWriter_write()` | Same |

---

## Priority Fixes

### Current Blockers - All Resolved

1. **Parser Type Resolution** - DONE
   - Added TypeExpr AST nodes
   - Parser returns AST nodes, lowerer resolves types
   - Pattern matches Zig's checker.zig

2. **Struct Array Field Access** - DONE
   - Issue: `points[0].x` stores at wrong offset
   - Fix: Added Case 4 in lowerFieldAssign/lowerFieldAccess for IndexExpr base
   - Added `TypeRegistry_sizeof()` to types.cot
   - Test passes: `var points: [2]Point; points[0].x = 10; points[0].y = 20;` returns 30

---

## CRITICAL LOGIC GAPS (2026-01-23)

These are missing implementations, not just naming differences.

### 1. Lowerer (lower.cot vs lower.zig)

| Feature | Zig | cot0 | Priority |
|---------|-----|------|----------|
| **defer_stack** | Full defer semantics | Missing entirely | HIGH |
| `emitDeferredExprs()` | Emit at scope/return/break | Missing | HIGH |
| **const_values** | Inlines compile-time constants | Missing | MEDIUM |
| `LoopContext.defer_depth` | Track defer depth for break/continue | Missing | HIGH |
| `inferExprType()` | Full type inference | Basic | MEDIUM |

**Impact**: Any code using `defer` won't work in cot0.

### 2. SSA Builder (builder.cot vs ssa_builder.zig)

| Feature | Zig | cot0 | Priority |
|---------|-----|------|----------|
| **FwdRef pattern** | Forward references for SSA | Missing | CRITICAL |
| `insertPhis()` | Iterative phi insertion | Missing | CRITICAL |
| `lookupVarOutgoing()` | Walk CFG for variable defs | Missing | CRITICAL |
| `reorderPhis()` | Ensure phis come first | Missing | HIGH |
| `defvars` per block | Track var→value per block | Basic `BlockDefs` | HIGH |
| `resolveFwdRefs()` | Replace FwdRefs with phis/copy | Missing | CRITICAL |

**Impact**: SSA form may be incorrect for complex control flow.

### 3. Codegen (genssa.cot vs codegen/arm64.zig)

| Feature | Zig | cot0 | Priority |
|---------|-----|------|----------|
| `emitPhiMoves()` | Parallel copy for phis | Missing | CRITICAL |
| Phi conflict detection | Handles src=dest conflicts | Missing | CRITICAL |
| Temp register for phi | Uses x16/x17 for conflicts | Missing | HIGH |
| Pre-allocate phi regs | Phase before codegen | Missing | MEDIUM |

**Impact**: Phi nodes may produce incorrect code.

### 4. SSA Passes (Missing entirely in cot0)

| Pass | Zig Location | Purpose |
|------|--------------|---------|
| `expand_calls` | ssa/passes/expand_calls.zig | Decompose aggregate call args |
| `decompose` | ssa/passes/decompose.zig | Split 16-byte values |
| `schedule` | ssa/passes/schedule.zig | Order values for codegen |
| `lower` | ssa/passes/lower.zig | Lower to machine ops |
| `stackalloc` | ssa/stackalloc.zig | Assign spill slots |

**Impact**: Missing optimization and correctness passes.

---

## Implementation Priority

1. **emitPhiMoves()** - Required for correct phi semantics
2. **insertPhis() + FwdRef** - Required for correct SSA
3. **defer_stack** - Required for defer statements
4. **SSA passes** - Required for larger programs

---

## Test Commands

```bash
# Build Zig compiler
zig build

# Build cot0-stage1
./zig-out/bin/cot cot0/main.cot -o /tmp/cot0-stage1

# Test cot0-stage1
echo 'fn main() i64 { return 42 }' > /tmp/test.cot
/tmp/cot0-stage1 /tmp/test.cot -o /tmp/test.o
zig cc /tmp/test.o -o /tmp/test && /tmp/test; echo "Exit: $?"
```

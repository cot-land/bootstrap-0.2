# cot0 vs Zig Function-by-Function Comparison

**Goal**: Logic parity - same algorithms and behavior, adapted for Cot syntax.

**Note**: cot0 uses different conventions than Zig:
- Function names: `Scanner_init()` vs `Scanner.init()` (Cot doesn't have methods)
- Naming style: PascalCase enums vs snake_case (Cot convention)
- No optionals: cot0 uses -1 or null checks instead of Zig's `?T` or `orelse`
- No slices: cot0 uses pointer + length pairs

**Status Legend**:
- **Same**: Logic matches Zig
- **Equivalent**: Same behavior, different implementation
- **N/A**: Not applicable to cot0's architecture

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
| `Parser.nest_lev` field | `Parser.nest_lev` field | Same | Nesting depth tracking |
| `Parser.incNest()` | `Parser_incNest()` | Same | Recursion limit protection |
| `Parser.decNest()` | `Parser_decNest()` | Same | |

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
| `SSABuilder.build()` | `SSABuilder_build()` | **⚠️ WRONG** |
| `SSABuilder.convertNode()` | `SSABuilder_convertNode()` | Same |
| `SSABuilder.verify()` | `SSABuilder_verify()` | Same | SSA verification for debugging |

#### ⚠️ CRITICAL ARCHITECTURAL DIFFERENCE: Parameter Handling

**See:** `cot0/SSA_BUILDER_ARCHITECTURE.md` for full details.

**Zig uses 3-phase parameter handling (ssa_builder.zig:111-242):**
1. **Phase 1:** Create ALL `Op.Arg` values first (captures x0-x7 before any clobbering)
2. **Phase 2:** Create `slice_make` ops for string params
3. **Phase 3:** Create `LocalAddr` + `Store` to save params to stack

**cot0 uses interleaved approach (builder.cot:931-958):**
- For each param: Arg → LocalAddr → Store (interleaved)

**Why this matters:**
- Interleaving can cause register clobbering before all params captured
- Breaks with 9+ arguments (stack-passed parameters)
- Breaks with string parameters (multi-register)
- Breaks with large structs (>16B, pass-by-reference)

**Additional differences:**
| Aspect | Zig | cot0 |
|--------|-----|------|
| Register index tracking | `phys_reg_idx` (physical ABI register) | `param_local.param_idx` (logical param) |
| String params | Two Args + slice_make | Not implemented |
| Large structs (>16B) | Arg as pointer + OpMove | Not implemented |

**Tasks to fix:** See `cot0/SSA_BUILDER_ARCHITECTURE.md` Part 3

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

| Feature | Zig | cot0 | Status |
|---------|-----|------|--------|
| **defer_stack** | Full defer semantics | ✅ Implemented | DONE |
| `emitDeferredExprs()` | Emit at scope/return/break | ✅ `Lowerer_emitDeferredExprs` | DONE |
| **const_values** | Inlines compile-time constants | ✅ `Lowerer_addConst/lookupConst` | DONE |
| `LoopContext.defer_depth` | Track defer depth for break/continue | ✅ `loop_defer_depth` | DONE |
| `inferExprType()` | Full type inference | ✅ `Lowerer_inferExprType` | DONE |

**Status**: Defer support implemented. Code using `defer` now works. Full type inference for all expression kinds.

### 2. SSA Builder (builder.cot vs ssa_builder.zig)

| Feature | Zig | cot0 | Status |
|---------|-----|------|--------|
| **FwdRef pattern** | Forward references for SSA | ✅ `Op.FwdRef` + `fwd_vars` | DONE |
| `insertPhis()` | Iterative phi insertion | ✅ `SSABuilder_insertPhis` | DONE |
| `lookupVarOutgoing()` | Walk CFG for variable defs | ✅ `SSABuilder_lookupVarOutgoing` | DONE |
| `reorderPhis()` | Ensure phis come first | ✅ `SSABuilder_reorderPhis` | DONE |
| `defvars` per block | Track var→value per block | ✅ Via `BlockDefs` | DONE |
| `resolveFwdRefs()` | Replace FwdRefs with phis/copy | ✅ In `insertPhis` | DONE |

**Status**: FwdRef pattern and phi insertion implemented.

### 3. Codegen (genssa.cot vs codegen/arm64.zig)

| Feature | Zig | cot0 | Status |
|---------|-----|------|--------|
| `emitPhiMoves()` | Parallel copy for phis | ✅ `GenState_emitPhiMoves` | DONE |
| Phi conflict detection | Handles src=dest conflicts | ✅ In emitPhiMoves | DONE |
| Temp register for phi | Uses x16/x17 for conflicts | ✅ Uses X16 | DONE |
| Pre-allocate phi regs | Phase before codegen | ✅ `RegAlloc_allocatePhis` | DONE |

**Status**: Phi moves implemented with conflict detection. Phi register allocation added.

### 4. SSA Passes

| Pass | Zig Location | cot0 Location | Status |
|------|--------------|---------------|--------|
| `expand_calls` | ssa/passes/expand_calls.zig | ssa/passes/expand_calls.cot | ✅ Same |
| `decompose` | ssa/passes/decompose.zig | ssa/passes/decompose.cot | ✅ Same |
| `schedule` | ssa/passes/schedule.zig | ssa/passes/schedule.cot | ✅ Same |
| `lower` | ssa/passes/lower.zig | ssa/passes/lower.cot | ✅ Same |
| `stackalloc` | ssa/stackalloc.zig | ssa/stackalloc.cot | ✅ Exists |

**Status**: All SSA passes implement actual transformations:
- **expand_calls**: Store of >16B → Move, >16B struct args → pass-by-reference (BUG-019 fix), dec.rules (string_ptr/len → copy)
- **decompose**: string_ptr/len(string_make) → copy with use count updates
- **schedule**: Value reordering via swapValues() - phis first, control last, dependency sort
- **lower**: Mul by 2^n → Shl, identity opts (add 0, mul 1, shift 0 → copy)

---

## Implementation Priority (Updated 2026-01-24)

1. ~~**emitPhiMoves()** - Required for correct phi semantics~~ ✅ DONE
2. ~~**insertPhis() + FwdRef** - Required for correct SSA~~ ✅ DONE
3. ~~**defer_stack** - Required for defer statements~~ ✅ DONE
4. ~~**SSA passes** - expand_calls, decompose, schedule, lower~~ ✅ DONE
5. ~~**const_values** - Already implemented via Lowerer_addConst~~ ✅ DONE
6. ~~**inferExprType** - Full type inference~~ ✅ DONE
7. ~~**allocatePhis** - Phi register allocation~~ ✅ DONE

**All critical logic gaps addressed!**

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

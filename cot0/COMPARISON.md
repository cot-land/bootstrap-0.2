# cot0 vs Zig Compiler Function Comparison

This document provides a complete comparison of all functions between the cot0 self-hosting compiler and the Zig bootstrap compiler.

## Legend
- **Same**: Same name, same logic
- **Equivalent**: Different name, same/similar logic
- **Missing in cot0**: Function exists in Zig but not in cot0
- **Missing in Zig**: Function exists in cot0 but not in Zig (cot0-specific)

---

## File Mapping

| cot0 File | Zig Counterpart |
|-----------|-----------------|
| `cot0/main.cot` | `src/main.zig`, `src/driver.zig` |
| `cot0/frontend/token.cot` | `src/frontend/token.zig` |
| `cot0/frontend/scanner.cot` | `src/frontend/scanner.zig` |
| `cot0/frontend/ast.cot` | `src/frontend/ast.zig` |
| `cot0/frontend/parser.cot` | `src/frontend/parser.zig` |
| `cot0/frontend/types.cot` | `src/frontend/types.zig` |
| `cot0/frontend/checker.cot` | `src/frontend/checker.zig` |
| `cot0/frontend/ir.cot` | `src/frontend/ir.zig` |
| `cot0/frontend/lower.cot` | `src/frontend/lower.zig` |
| `cot0/ssa/op.cot` | `src/ssa/op.zig` |
| `cot0/ssa/value.cot` | `src/ssa/value.zig` |
| `cot0/ssa/block.cot` | `src/ssa/block.zig` |
| `cot0/ssa/func.cot` | `src/ssa/func.zig` |
| `cot0/ssa/builder.cot` | `src/frontend/ssa_builder.zig` |
| `cot0/ssa/liveness.cot` | `src/ssa/liveness.zig` |
| `cot0/ssa/regalloc.cot` | `src/ssa/regalloc.zig` |
| `cot0/arm64/asm.cot` | `src/arm64/asm.zig` |
| `cot0/arm64/regs.cot` | (part of `src/arm64/asm.zig`) |
| `cot0/codegen/arm64.cot` | `src/codegen/arm64.zig` |
| `cot0/codegen/genssa.cot` | (part of `src/codegen/arm64.zig`) |
| `cot0/obj/macho.cot` | `src/obj/macho.zig` |

### Zig-only files (no cot0 counterpart yet)
- `src/core/errors.zig`
- `src/core/types.zig`
- `src/frontend/source.zig`
- `src/frontend/errors.zig`
- `src/ssa/dom.zig`
- `src/ssa/abi.zig`
- `src/ssa/debug.zig`
- `src/ssa/compile.zig`
- `src/ssa/stackalloc.zig`
- `src/ssa/passes/lower.zig`
- `src/ssa/passes/schedule.zig`
- `src/ssa/passes/expand_calls.zig`
- `src/ssa/passes/decompose.zig`
- `src/codegen/generic.zig`

### cot0-only files (utilities/helpers)
- `cot0/debug.cot`
- `cot0/lib/stdlib.cot`
- `cot0/lib/list.cot`

---

## 1. Main Entry Point

### cot0/main.cot vs src/main.zig + src/driver.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `main(argc, argv) i64` | `pub fn main() !void` | Same |
| `Driver_compileFile(source, out_path, len) i64` | `Driver.compileFile()` | Same |
| `Driver_compileSource(source, out_path, len) i64` | `Driver.compileSource()` | Same |
| `Driver_init() Driver` | `Driver.init()` | Same |
| `Driver_setDebugPhases(phases, len)` | `Driver.setDebugPhases()` | Same |
| `Driver_parseFileRecursive(pool)` | `parseFileRecursive()` | Same |
| `print_usage()` | Inline in main | Same |
| `ir_op_to_ssa_op(ir_op) Op` | SSA conversion in codegen | Equivalent |
| `ir_unary_op_to_ssa_op(ir_op) Op` | SSA conversion in codegen | Equivalent |
| `print_int(n)` | `std.debug.print()` | Equivalent |
| `read_file(path) i64` | `std.fs.cwd().readFileAlloc()` | Equivalent |
| `write_file(path, data, len) i64` | `std.fs.cwd().writeFile()` | Equivalent |
| `init_node_pool() *NodePool` | AST init in parser | Equivalent |
| `is_path_imported(path, len) bool` | `seen_files.contains()` | Equivalent |
| `add_imported_path(path, len)` | `seen_files.put()` | Equivalent |
| `extract_base_dir(path, len)` | `std.fs.path.dirname()` | Equivalent |
| `build_import_path(import_path, len) i64` | `std.fs.path.join()` | Equivalent |
| `adjust_node_positions(pool, start, end, offset)` | Position in Source | Equivalent |
| `parse_import_file(path, len, pool) i64` | parseFileRecursive loop | Equivalent |
| `strlen(s) i64` | Slice length | Equivalent |
| `streq(a, b) bool` | `std.mem.eql()` | Equivalent |
| `strcpy(dest, src, max) i64` | `allocator.dupe()` | Equivalent |
| — | `findRuntimePath()` | Missing in cot0 |

---

## 2. Frontend

### 2.1 cot0/frontend/token.cot vs src/frontend/token.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `Token_new(kind, start, end) Token` | Struct initialization | Same |
| `Token_lookup(text) TokenType` | `lookup(name) Token` | Same |
| `Token_precedence(t) i64` | `Token.precedence() u8` | Same |
| `Token_isLiteral(t) bool` | `Token.isLiteral() bool` | Same |
| `Token_isOperator(t) bool` | `Token.isOperator() bool` | Same |
| `Token_isKeyword(t) bool` | `Token.isKeyword() bool` | Same |
| `Token_isTypeKeyword(t) bool` | `Token.isTypeKeyword() bool` | Same |
| `Token_isAssignment(t) bool` | `Token.isAssignment() bool` | Same |
| `TokenType` enum (60+ variants) | `Token` enum (80+ variants) | Same |
| — | `Token.string() []const u8` | Missing in cot0 |

### 2.2 cot0/frontend/scanner.cot vs src/frontend/scanner.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `Scanner_init(source) Scanner` | `Scanner.init()` | Same |
| `Scanner_next(s) Token` | `Scanner.next()` | Same |
| `Scanner_peek(s) u8` | `Scanner.peek()` | Same |
| `Scanner_peekNext(s) u8` | `Scanner.peek(1)` | Same |
| `Scanner_advance(s) u8` | `Scanner.advance()` | Same |
| `Scanner_isAtEnd(s) bool` | EOF check | Same |
| `Scanner_skipWhitespace(s)` | `skipWhitespaceAndComments()` | Same |
| `Scanner_scanNumber(s) Token` | `scanNumber()` | Same |
| `Scanner_scanIdentifier(s) Token` | `scanIdentifier()` | Same |
| `Scanner_scanChar(s) Token` | `scanChar()` | Same |
| `Scanner_scanString(s) Token` | `scanString()` | Same |
| `isAlpha(c) bool` | `isAlpha()` | Same |
| `isDigit(c) bool` | `isDigit()` | Same |
| `isAlphaNumeric(c) bool` | `isAlphaNumeric()` | Same |
| — | `isHexDigit()` | Missing in cot0 |
| — | `Scanner.scanOperator()` | Inline in cot0 |
| — | `Scanner.skipLineComment()` | Inline in cot0 |
| — | `Scanner.skipBlockComment()` | Missing in cot0 |

### 2.3 cot0/frontend/ast.cot vs src/frontend/ast.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `node_pool_init() NodePool` | `AST.init()` | Equivalent |
| `alloc_node(pool) *Node` | `allocNode()` | Equivalent |
| `make_binary(pool, op, left, right) *Node` | `makeBinary()` | Same |
| `make_unary(pool, op, operand) *Node` | `makeUnary()` | Same |
| `make_literal(pool, value) *Node` | `makeLiteral()` | Same |
| `make_string_literal(pool, str, len) *Node` | `makeStringLiteral()` | Same |
| `make_identifier(pool, name, len) *Node` | `makeIdentifier()` | Same |
| `make_call(pool, callee, args, count) *Node` | `makeCall()` | Same |
| `make_index(pool, array, index) *Node` | `makeIndex()` | Same |
| `make_field_access(pool, obj, field, len) *Node` | `makeFieldAccess()` | Same |
| `make_if(pool, cond, then_b, else_b) *Node` | `makeIf()` | Same |
| `make_while(pool, cond, body) *Node` | `makeWhile()` | Same |
| `make_for(pool, init, cond, inc, body) *Node` | `makeFor()` | Same |
| `make_for_in(pool, iter, range, body) *Node` | `makeForIn()` | Same |
| `make_return(pool, value) *Node` | `makeReturn()` | Same |
| `make_var_decl(pool, name, type, init) *Node` | `makeVarDecl()` | Same |
| `make_func_decl(pool, name, params, ret, body) *Node` | `makeFuncDecl()` | Same |
| `make_struct_decl(pool, name, fields) *Node` | `makeStructDecl()` | Same |
| `make_block(pool, stmts, count) *Node` | `makeBlock()` | Same |
| `make_assign(pool, target, value) *Node` | `makeAssign()` | Same |
| `make_type_node(pool, kind, inner) *Node` | `makeTypeNode()` | Same |
| `make_array_type(pool, elem, size) *Node` | `makeArrayType()` | Same |
| `make_array_literal(pool, elems, count) *Node` | `makeArrayLiteral()` | Same |
| `make_cast(pool, expr, target) *Node` | `makeCast()` | Same |
| `make_import(pool, path, len) *Node` | `makeImport()` | Same |
| `make_switch(pool, expr, cases, count) *Node` | `makeSwitch()` | Same |
| — | `AST.deinit()` | Missing in cot0 |
| — | `AST.getNode()` | Missing in cot0 |

### 2.4 cot0/frontend/parser.cot vs src/frontend/parser.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `Parser_init(source, pool) Parser` | `Parser.init()` | Same |
| `Parser_parseFile(p) i64` | `Parser.parse()` | Same |
| `Parser_parseDecl(p) i64` | `declaration()` | Same |
| `Parser_parseFnDecl(p) i64` | `fnDeclaration()` | Same |
| `Parser_parseStructDecl(p) i64` | `structDeclaration()` | Same |
| `Parser_parseVarDecl(p) i64` | `varDeclaration()` | Same |
| `Parser_parseStmt(p) i64` | `statement()` | Same |
| `Parser_parseIfStmt(p) i64` | `ifStatement()` | Same |
| `Parser_parseWhileStmt(p) i64` | `whileStatement()` | Same |
| `Parser_parseForStmt(p) i64` | `forStatement()` | Same |
| `Parser_parseReturnStmt(p) i64` | `returnStatement()` | Same |
| `Parser_parseSwitchExpr(p) i64` | `switchStatement()` | Same |
| `Parser_parseBlock(p) i64` | `block()` | Same |
| `Parser_parseExpr(p) i64` | `expression()` | Same |
| `Parser_parseBinaryExpr(p, left, prec) i64` | `binaryExpr()` | Same |
| `Parser_parseUnary(p) i64` | `unary()` | Same |
| `Parser_parseAtom(p) i64` | `primary()` | Same |
| `Parser_parseType(p) i64` | `parseType()` | Same |
| `Parser_advance(p)` | `advance()` | Same |
| `Parser_want(p, type) bool` | `consume()` | Same |
| `Parser_check(p, type) bool` | `check()` | Same |
| `Parser_got(p, type) bool` | `match()` | Same |
| `Parser_atEnd(p) bool` | `atEnd()` | Same |
| `Parser_hadError(p) bool` | `hadError()` | Same |
| `Parser_prec(p) i64` | `precedence()` | Same |
| `Parser_binopInt(p) i64` | `binaryOp()` | Same |
| `Parser_parseParam(p) i64` | `parseParam()` | Same |
| `Parser_parseExternFnDecl(p) i64` | `externFnDecl()` | Same |
| `Parser_parseEnumDecl(p) i64` | `enumDecl()` | Same |
| `Parser_parseImport(p) i64` | `importDecl()` | Same |
| `Parser_parseConstDecl(p) i64` | `constDecl()` | Same |
| `Parser_parseGlobalVarDecl(p) i64` | `globalVarDecl()` | Same |
| `Type_isPointer(handle) bool` | `TypeInfo.isPointer()` | Same |
| `Type_pointee(handle) i64` | `TypeInfo.pointee()` | Same |

### 2.5 cot0/frontend/types.cot vs src/frontend/types.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `TypePool_init(pool)` | `TypeRegistry.init()` | Same |
| `TypePool_initWithStorage(pool, types, params, fields)` | `TypeRegistry.initWithStorage()` | Same |
| `TypePool_get(pool, idx) *Type` | `getType()` | Same |
| `TypePool_findByName(pool, name_start, name_len) i64` | `findTypeByName()` | Same |
| `TypePool_registerBasic(pool, kind, size, align) i64` | `registerBasic()` | Same |
| `TypePool_makePointer(pool, elem) i64` | `makePointer()` | Same |
| `TypePool_makeArray(pool, elem, len) i64` | `makeArray()` | Same |
| `TypePool_makeSlice(pool, elem) i64` | `makeSlice()` | Same |
| `TypePool_makeStruct(pool, name, len, fields, count, size, align) i64` | `makeStruct()` | Same |
| `TypePool_makeFunc(pool, params_start, params_count, ret) i64` | `makeFunction()` | Same |
| `TypePool_makeEnum(pool, name, len, variants) i64` | `makeEnum()` | Same |
| `TypePool_addParam(pool, param_type) i64` | `addParam()` | Same |
| `TypePool_getParam(pool, start, offset) i64` | `getParam()` | Same |
| `TypePool_addField(pool, name, len, type, offset) i64` | `addField()` | Same |
| `TypePool_getField(pool, idx) *FieldInfo` | `getField()` | Same |
| `TypePool_setSource(pool, source, len)` | `setSource()` | Same |
| `TypePool_lookupField(pool, type_idx, name, len) *FieldInfo` | `lookupField()` | Same |
| `TypeInfo_valid(idx) bool` | `TypeInfo.isValid()` | Same |
| `TypeInfo_size(pool, idx) i64` | `TypeInfo.size()` | Same |
| `TypeInfo_alignment(pool, idx) i64` | `TypeInfo.alignment()` | Same |
| `TypeInfo_elem(pool, idx) i64` | `TypeInfo.elem()` | Same |
| `TypeInfo_arrayLen(pool, idx) i64` | `TypeInfo.arrayLen()` | Same |
| `TypeInfo_ret(pool, idx) i64` | `TypeInfo.ret()` | Same |
| `TypeInfo_paramCount(pool, idx) i64` | `TypeInfo.paramCount()` | Same |
| `TypeInfo_equal(pool, a, b) bool` | `typesEqual()` | Same |
| `TypeInfo_isInteger(pool, idx) bool` | `TypeInfo.isInteger()` | Same |
| `TypeInfo_isSigned(pool, idx) bool` | `TypeInfo.isSigned()` | Same |
| `TypeInfo_isUnsigned(pool, idx) bool` | `TypeInfo.isUnsigned()` | Same |
| `TypeInfo_isFloat(pool, idx) bool` | `TypeInfo.isFloat()` | Same |
| `TypeInfo_isNumeric(pool, idx) bool` | `TypeInfo.isNumeric()` | Same |
| `TypeInfo_isBool(pool, idx) bool` | `TypeInfo.isBool()` | Same |
| `TypeInfo_isVoid(pool, idx) bool` | `TypeInfo.isVoid()` | Same |
| `TypeInfo_isPointer(pool, idx) bool` | `TypeInfo.isPointer()` | Same |
| `TypeInfo_isSlice(pool, idx) bool` | `TypeInfo.isSlice()` | Same |
| `TypeInfo_isArray(pool, idx) bool` | `TypeInfo.isArray()` | Same |
| `TypeInfo_isFunc(pool, idx) bool` | `TypeInfo.isFunc()` | Same |
| `TypeInfo_isString(pool, idx) bool` | `TypeInfo.isString()` | Same |
| `TypeInfo_isStruct(pool, idx) bool` | `TypeInfo.isStruct()` | Same |
| `TypeInfo_isEnum(pool, idx) bool` | `TypeInfo.isEnum()` | Same |
| `TypeInfo_isAssignable(pool, from, to) bool` | `isAssignable()` | Same |
| `TypeInfo_getPointee(pool, ptr_type) i64` | `TypeInfo.pointee()` | Same |
| `TypeInfo_lookupBasic(source, name, len) i64` | `lookupBasic()` | Same |
| `PType_registerArray(elem, size) i64` | `registerArray()` | Same |
| `PType_arrayElem(ptype) i64` | `arrayElem()` | Same |
| `PType_arraySize(ptype) i64` | `arraySize()` | Same |
| `PType_registerSlice(elem) i64` | `registerSlice()` | Same |
| `PType_sliceElem(ptype) i64` | `sliceElem()` | Same |
| `PType_isSlice(ptype) bool` | `isSlice()` | Same |
| — | `TypeRegistry.deinit()` | Missing in cot0 |

### 2.6 cot0/frontend/checker.cot vs src/frontend/checker.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `Checker_init(chk, type_pool, scope_pool, ...)` | `Checker.init()` | Same |
| `Checker_checkFile(chk)` | `checkProgram()` | Same |
| `Checker_checkFnDecl(chk, node_idx)` | `checkFunction()` | Same |
| `Checker_checkStructDecl(chk, node_idx)` | `checkStruct()` | Same |
| `Checker_checkEnumDecl(chk, node_idx)` | `checkEnum()` | Same |
| `Checker_checkStmt(chk, node_idx) bool` | `checkStatement()` | Same |
| `Checker_checkExpr(chk, node_idx) i64` | `checkExpression()` | Same |
| `Checker_checkVarDecl(chk, node_idx)` | `checkVarDecl()` | Same |
| `Checker_resolveTypeHandle(chk, type_handle) i64` | `resolveType()` | Same |
| `Checker_ok(chk) bool` | `Checker.ok()` | Same |
| `Checker_errors(chk) i64` | `Checker.errors()` | Same |
| `Symbol_new(name, len, kind, type, node, mutable) Symbol` | `Symbol.init()` | Same |
| `Symbol_newConst(name, len, type, node, value) Symbol` | `Symbol.initConst()` | Same |
| `Symbol_newExtern(name, len, kind, type, node) Symbol` | `Symbol.initExtern()` | Same |
| `ScopePool_init(pool)` | `ScopePool.init()` | Same |
| `ScopePool_new(pool, parent) i64` | `ScopePool.new()` | Same |
| `ScopePool_define(pool, scope, sym)` | `ScopePool.define()` | Same |
| `ScopePool_lookupType(pool, scope, src, name, len) i64` | `ScopePool.lookupType()` | Same |
| — | `Checker.deinit()` | Missing in cot0 |

### 2.7 cot0/frontend/ir.cot vs src/frontend/ir.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `IRNodePool_init(pool, nodes, cap)` | `IR.init()` | Same |
| `IRNodePool_add(pool, node) i64` | `addInstr()` | Same |
| `IRNodePool_get(pool, idx) *IRNode` | `getInstr()` | Same |
| `IRNodePool_addConstInt(pool, value, type) i64` | `addConst()` | Same |
| `IRNodePool_addBinary(pool, op, left, right, type) i64` | `addBinary()` | Same |
| `IRNode_new(kind, type_idx) IRNode` | `IRNode.init()` | Same |
| `IRNode_isTerminator(node) bool` | `IRNode.isTerminator()` | Same |
| `IRNode_isConstant(node) bool` | `IRNode.isConstant()` | Same |
| `IR_isComparison(op) bool` | `Op.isComparison()` | Same |
| `IR_isArithmetic(op) bool` | `Op.isArithmetic()` | Same |
| `IR_isLogical(op) bool` | `Op.isLogical()` | Same |
| `IR_isBitwise(op) bool` | `Op.isBitwise()` | Same |
| `IRLocal_new(name, len, type, mutable) IRLocal` | `IRLocal.init()` | Same |
| `IRLocal_newParam(name, len, type, param_idx) IRLocal` | `IRLocal.initParam()` | Same |
| `IRFunc_new(name, len, ret_type, ...) IRFunc` | `IRFunc.init()` | Same |
| IR opcodes (30+) | `IROpcode` enum | Same |
| — | `IR.deinit()` | Missing in cot0 |
| — | `IR.deinit()` | Missing in cot0 |

### 2.8 cot0/frontend/lower.cot vs src/frontend/lower.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `lower_init(ir, types) Lowerer` | `Lowerer.init()` | Same |
| `lower_program(l, node)` | `lowerProgram()` | Same |
| `lower_function(l, node)` | `lowerFunction()` | Same |
| `lower_statement(l, node)` | `lowerStatement()` | Same |
| `lower_expression(l, node) i64` | `lowerExpression()` | Same |
| `lower_binary(l, node) i64` | `lowerBinary()` | Same |
| `lower_unary(l, node) i64` | `lowerUnary()` | Same |
| `lower_call(l, node) i64` | `lowerCall()` | Same |
| `lower_index(l, node) i64` | `lowerIndex()` | Same |
| `lower_field(l, node) i64` | `lowerField()` | Same |
| `lower_if(l, node)` | `lowerIf()` | Same |
| `lower_while(l, node)` | `lowerWhile()` | Same |
| `lower_for(l, node)` | `lowerFor()` | Same |
| `lower_return(l, node)` | `lowerReturn()` | Same |
| `lower_assign(l, node)` | `lowerAssign()` | Same |
| `lower_var_decl(l, node)` | `lowerVarDecl()` | Same |
| `lower_block(l, node)` | `lowerBlock()` | Same |
| `lower_lvalue(l, node) i64` | `lowerLvalue()` | Same |
| `emit_load(l, addr, type) i64` | `emitLoad()` | Same |
| `emit_store(l, addr, val, type)` | `emitStore()` | Same |
| — | `Lowerer.deinit()` | Missing in cot0 |
| — | `lowerSwitch()` | Missing in cot0 |

---

## 3. SSA

### 3.1 cot0/ssa/op.cot vs src/ssa/op.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `op_name(op) *u8` | `Op.name()` | Equivalent |
| `op_is_commutative(op) bool` | `Op.isCommutative()` | Equivalent |
| `op_is_comparison(op) bool` | `Op.isComparison()` | Equivalent |
| `op_has_side_effects(op) bool` | `Op.hasSideEffects()` | Equivalent |
| Op constants (50+) | `Op` enum | Same |
| — | `Op.isTerminator()` | Missing in cot0 |
| — | `Op.isBranch()` | Missing in cot0 |
| — | `Op.numArgs()` | Missing in cot0 |

### 3.2 cot0/ssa/value.cot vs src/ssa/value.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `value_init(op, type) Value` | `Value.init()` | Same |
| `value_set_arg(v, idx, arg)` | `Value.setArg()` | Same |
| `value_get_arg(v, idx) *Value` | `Value.getArg()` | Same |
| `value_num_args(v) i64` | `Value.numArgs()` | Same |
| `value_set_aux_int(v, n)` | `Value.setAuxInt()` | Same |
| `value_get_aux_int(v) i64` | `Value.getAuxInt()` | Same |
| `value_add_use(v, user)` | `Value.addUse()` | Same |
| `value_remove_use(v, user)` | `Value.removeUse()` | Same |
| `value_replace_uses(v, new)` | `Value.replaceUses()` | Same |
| `value_is_const(v) bool` | `Value.isConst()` | Same |
| — | `Value.deinit()` | Missing in cot0 |
| — | `Value.dump()` | Missing in cot0 |
| — | `Value.format()` | Missing in cot0 |

### 3.3 cot0/ssa/block.cot vs src/ssa/block.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `block_init(id) Block` | `Block.init()` | Same |
| `block_add_value(b, v)` | `Block.addValue()` | Same |
| `block_add_pred(b, pred)` | `Block.addPred()` | Same |
| `block_add_succ(b, succ)` | `Block.addSucc()` | Same |
| `block_set_control(b, v)` | `Block.setControl()` | Same |
| `block_get_control(b) *Value` | `Block.getControl()` | Same |
| `block_num_preds(b) i64` | `Block.numPreds()` | Same |
| `block_num_succs(b) i64` | `Block.numSuccs()` | Same |
| `block_get_pred(b, idx) *Block` | `Block.getPred()` | Same |
| `block_get_succ(b, idx) *Block` | `Block.getSucc()` | Same |
| — | `Block.deinit()` | Missing in cot0 |
| — | `Block.dump()` | Missing in cot0 |
| — | `Block.removeValue()` | Missing in cot0 |

### 3.4 cot0/ssa/func.cot vs src/ssa/func.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `func_init(name) Func` | `Func.init()` | Same |
| `func_add_block(f, b)` | `Func.addBlock()` | Same |
| `func_new_block(f) *Block` | `Func.newBlock()` | Same |
| `func_new_value(f, op, type) *Value` | `Func.newValue()` | Same |
| `func_entry_block(f) *Block` | `Func.entryBlock()` | Same |
| `func_num_blocks(f) i64` | `Func.numBlocks()` | Same |
| `func_get_block(f, idx) *Block` | `Func.getBlock()` | Same |
| `func_set_entry(f, b)` | `Func.setEntry()` | Same |
| — | `Func.deinit()` | Missing in cot0 |
| — | `Func.dump()` | Missing in cot0 |
| — | `Func.verify()` | Missing in cot0 |
| — | `Func.computeDominators()` | Missing in cot0 |

### 3.5 cot0/ssa/builder.cot vs src/frontend/ssa_builder.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `builder_init(func) Builder` | `SSABuilder.init()` | Same |
| `builder_set_block(b, block)` | `setCurrentBlock()` | Equivalent |
| `builder_current_block(b) *Block` | `currentBlock()` | Same |
| `build_const_int(b, val, type) *Value` | `buildConstInt()` | Same |
| `build_const_bool(b, val) *Value` | `buildConstBool()` | Same |
| `build_const_string(b, str, len) *Value` | `buildConstString()` | Same |
| `build_add(b, l, r) *Value` | `buildAdd()` | Same |
| `build_sub(b, l, r) *Value` | `buildSub()` | Same |
| `build_mul(b, l, r) *Value` | `buildMul()` | Same |
| `build_div(b, l, r) *Value` | `buildDiv()` | Same |
| `build_mod(b, l, r) *Value` | `buildMod()` | Same |
| `build_and(b, l, r) *Value` | `buildAnd()` | Same |
| `build_or(b, l, r) *Value` | `buildOr()` | Same |
| `build_xor(b, l, r) *Value` | `buildXor()` | Same |
| `build_shl(b, l, r) *Value` | `buildShl()` | Same |
| `build_shr(b, l, r) *Value` | `buildShr()` | Same |
| `build_neg(b, v) *Value` | `buildNeg()` | Same |
| `build_not(b, v) *Value` | `buildNot()` | Same |
| `build_eq(b, l, r) *Value` | `buildEq()` | Same |
| `build_ne(b, l, r) *Value` | `buildNe()` | Same |
| `build_lt(b, l, r) *Value` | `buildLt()` | Same |
| `build_le(b, l, r) *Value` | `buildLe()` | Same |
| `build_gt(b, l, r) *Value` | `buildGt()` | Same |
| `build_ge(b, l, r) *Value` | `buildGe()` | Same |
| `build_load(b, ptr, type) *Value` | `buildLoad()` | Same |
| `build_store(b, ptr, val)` | `buildStore()` | Same |
| `build_call(b, func, args, count) *Value` | `buildCall()` | Same |
| `build_phi(b, type) *Value` | `buildPhi()` | Same |
| `build_select(b, cond, t, f) *Value` | `buildSelect()` | Same |
| `build_branch(b, target)` | `buildBranch()` | Same |
| `build_cond_branch(b, cond, t, f)` | `buildCondBranch()` | Same |
| `build_return(b, val)` | `buildReturn()` | Same |
| `build_local_addr(b, slot) *Value` | `buildLocalAddr()` | Same |
| `build_off_ptr(b, base, off) *Value` | `buildOffPtr()` | Same |
| — | `SSABuilder.deinit()` | Missing in cot0 |
| — | `buildCast()` | Missing in cot0 |
| — | `buildAlloca()` | Missing in cot0 |

### 3.6 cot0/ssa/liveness.cot vs src/ssa/liveness.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `liveness_init(func) Liveness` | `Liveness.init()` | Same |
| `liveness_compute(l)` | `compute()` | Same |
| `liveness_is_live_at(l, v, b) bool` | `isLiveAt()` | Same |
| `liveness_live_in(l, b) *ValueSet` | `liveIn()` | Same |
| `liveness_live_out(l, b) *ValueSet` | `liveOut()` | Same |
| `compute_local_liveness(l, b)` | `computeLocal()` | Equivalent |
| `propagate_liveness(l) bool` | `propagate()` | Equivalent |
| — | `Liveness.deinit()` | Missing in cot0 |
| — | `Liveness.dump()` | Missing in cot0 |
| — | `computeInterference()` | Missing in cot0 |

### 3.7 cot0/ssa/regalloc.cot vs src/ssa/regalloc.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `regalloc_init(func, liveness) RegAlloc` | `RegAlloc.init()` | Same |
| `regalloc_allocate(r)` | `allocate()` | Same |
| `regalloc_get_reg(r, v) i64` | `getReg()` | Same |
| `regalloc_get_spill_slot(r, v) i64` | `getSpillSlot()` | Same |
| `regalloc_is_spilled(r, v) bool` | `isSpilled()` | Same |
| `build_interference(r)` | `buildInterference()` | Same |
| `color_graph(r)` | `colorGraph()` | Same |
| `spill_value(r, v)` | `spillValue()` | Same |
| `select_spill(r) *Value` | `selectSpill()` | Same |
| `assign_registers(r)` | `assignRegisters()` | Same |
| — | `RegAlloc.deinit()` | Missing in cot0 |
| — | `RegAlloc.dump()` | Missing in cot0 |
| — | `coalesce()` | Missing in cot0 |
| — | `simplify()` | Missing in cot0 |

---

## 4. ARM64 Backend

### 4.1 cot0/arm64/asm.cot vs src/arm64/asm.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `encode_add_reg(rd, rn, rm)` | `encodeADDReg()` | Same |
| `encode_add_imm(rd, rn, imm12)` | `encodeADDImm()` | Same |
| `encode_add_ext_reg(rd, rn, rm)` | `encodeADDExtReg()` | Same |
| `encode_sub_reg(rd, rn, rm)` | `encodeSUBReg()` | Same |
| `encode_sub_imm(rd, rn, imm12)` | `encodeSUBImm()` | Same |
| `encode_and_reg(rd, rn, rm)` | `encodeAND()` | Same |
| `encode_orr_reg(rd, rn, rm)` | `encodeORR()` | Same |
| `encode_eor_reg(rd, rn, rm)` | `encodeEOR()` | Same |
| `encode_lsl_reg(rd, rn, rm)` | `encodeLSL()` | Same |
| `encode_lsr_reg(rd, rn, rm)` | `encodeLSR()` | Same |
| `encode_asr_reg(rd, rn, rm)` | `encodeASR()` | Same |
| `encode_mul(rd, rn, rm)` | `encodeMUL()` | Same |
| `encode_sdiv(rd, rn, rm)` | `encodeSDIV()` | Same |
| `encode_udiv(rd, rn, rm)` | `encodeUDIV()` | Same |
| `encode_mvn(rd, rm)` | `encodeMVN()` | Same |
| `encode_cmp_reg(rn, rm)` | `encodeCMPReg()` | Same |
| `encode_cmp_imm(rn, imm12)` | `encodeCMPImm()` | Same |
| `encode_csel(rd, rn, rm, cond)` | `encodeCSEL()` | Same |
| `encode_cset(rd, cond)` | `encodeCSET()` | Same |
| `encode_b(imm26)` | `encodeB()` | Same |
| `encode_bl(imm26)` | `encodeBL()` | Same |
| `encode_br(rn)` | `encodeBR()` | Same |
| `encode_blr(rn)` | `encodeBLR()` | Same |
| `encode_ret(rn)` | `encodeRET()` | Same |
| `encode_b_cond(imm19, cond)` | `encodeBCond()` | Same |
| `encode_cbz(rt, imm19)` | `encodeCBZ()` | Same |
| `encode_cbnz(rt, imm19)` | `encodeCBNZ()` | Same |
| `encode_ldr(rt, rn, offset)` | `encodeLDR()` | Same |
| `encode_str(rt, rn, offset)` | `encodeSTR()` | Same |
| `encode_ldrb(rt, rn, offset)` | `encodeLDRB()` | Same |
| `encode_strb(rt, rn, offset)` | `encodeSTRB()` | Same |
| `encode_ldrh(rt, rn, offset)` | `encodeLDRH()` | Same |
| `encode_strh(rt, rn, offset)` | `encodeSTRH()` | Same |
| `encode_ldp(rt1, rt2, rn, imm7)` | `encodeLdpStp()` | Equivalent |
| `encode_stp(rt1, rt2, rn, imm7)` | `encodeLdpStp()` | Equivalent |
| `encode_stp_pre(rt1, rt2, rn, imm7)` | `encodeSTPPre()` | Same |
| `encode_ldp_post(rt1, rt2, rn, imm7)` | `encodeLDPPost()` | Same |
| `encode_movz(rd, imm16, shift)` | `encodeMOVZ()` | Same |
| `encode_movk(rd, imm16, shift)` | `encodeMOVK()` | Same |
| `encode_movn(rd, imm16, shift)` | `encodeMOVN()` | Same |
| `encode_adr(rd, imm21, is_page)` | `encodeADR()/encodeADRP()` | Equivalent |
| `encode_nop()` | `encodeNOP()` | Same |
| `encode_csinc(rd, rn, rm, cond)` | — | Missing in Zig |
| `encode_orn(rd, rn, rm)` | — | Missing in Zig |
| `encode_neg(rd, rm)` | — | Missing in Zig |
| `encode_ldrw(rt, rn, offset)` | — | Missing in Zig |
| `encode_strw(rt, rn, offset)` | — | Missing in Zig |
| — | `encodeSXTB32/64()` | Missing in cot0 |
| — | `encodeSXTH32/64()` | Missing in cot0 |
| — | `encodeSXTW()` | Missing in cot0 |
| — | `encodeUXTB32/64()` | Missing in cot0 |
| — | `encodeUXTH32/64()` | Missing in cot0 |
| — | `encodeTST()` | Missing in cot0 |
| — | `invertCond()` | Missing in cot0 |

### 4.2 cot0/arm64/regs.cot (cot0-only)

| cot0 Function | Purpose |
|---------------|---------|
| `is_arg_reg(reg) bool` | Check if register is argument register (X0-X7) |
| `is_callee_saved(reg) bool` | Check if register is callee-saved (X19-X28) |
| `is_caller_saved(reg) bool` | Check if register is caller-saved (X0-X15) |
| `is_scratch_reg(reg) bool` | Check if register is scratch (X16-X17) |
| `is_allocatable(reg) bool` | Check if register is allocatable |

---

## 5. Code Generation

### 5.1 cot0/codegen/arm64.cot vs src/codegen/arm64.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `emitter_init() Emitter` | `ARM64CodeGen.init()` | Equivalent |
| `codegen_add(rd, rn, rm)` | `generateValueBinary()` | Equivalent |
| `codegen_sub(rd, rn, rm)` | `generateValueBinary()` | Equivalent |
| `codegen_and(rd, rn, rm)` | `generateValueBinary()` | Equivalent |
| `codegen_or(rd, rn, rm)` | `generateValueBinary()` | Equivalent |
| `codegen_xor(rd, rn, rm)` | `generateValueBinary()` | Equivalent |
| `codegen_cmp(rn, rm)` | `generateValueBinary()` | Equivalent |
| `codegen_setcc(rd, cond)` | `generateValueBinary()` | Equivalent |
| `codegen_select(rd, rn, rm, cond)` | `generateValueBinary()` | Equivalent |
| `codegen_branch(offset)` | `generateValueBinary()` | Equivalent |
| `codegen_branch_cond(offset, cond)` | `generateValueBinary()` | Equivalent |
| `codegen_call(offset)` | `generateValueBinary()` | Equivalent |
| `codegen_return()` | `generateValueBinary()` | Equivalent |
| `codegen_load64(rd, base, offset)` | `generateValueBinary()` | Equivalent |
| `codegen_store64(rt, base, offset)` | `generateValueBinary()` | Equivalent |
| `codegen_load8(rd, base, offset)` | `generateValueBinary()` | Equivalent |
| `codegen_store8(rt, base, offset)` | `generateValueBinary()` | Equivalent |
| `encode_prologue(frame_size)` | `emitPrologue()` | Equivalent |
| `encode_epilogue(frame_size)` | `emitEpilogue()` | Equivalent |
| `encode_mov_reg(rd, rm)` | inline | Equivalent |
| `encode_mov_imm(rd, imm)` | `emitLoadImmediate()` | Equivalent |
| `get_cond_for_signed_lt()` | constant COND_LT | Equivalent |
| `get_cond_for_signed_gt()` | constant COND_GT | Equivalent |
| `get_cond_for_signed_le()` | constant COND_LE | Equivalent |
| `get_cond_for_signed_ge()` | constant COND_GE | Equivalent |
| `get_cond_for_eq()` | constant COND_EQ | Equivalent |
| `get_cond_for_ne()` | constant COND_NE | Equivalent |
| — | `ARM64CodeGen.deinit()` | Missing in cot0 |
| — | `generateBinary()` | Missing in cot0 |
| — | `generateBlockBinary()` | Missing in cot0 |
| — | `generateValueBinary()` | Missing in cot0 |
| — | `ensureInReg()` | Missing in cot0 |
| — | `getRegForValue()` | Missing in cot0 |
| — | `getDestRegForValue()` | Missing in cot0 |
| — | `setupCallArgs()` | Missing in cot0 |
| — | `applyBranchFixups()` | Missing in cot0 |
| — | `emitPhiMoves()` | Missing in cot0 |
| — | `setRegAllocState()` | Missing in cot0 |
| — | `setFrameSize()` | Missing in cot0 |
| — | `setTypeRegistry()` | Missing in cot0 |

### 5.2 cot0/codegen/genssa.cot (cot0-only)

| cot0 Function | Purpose |
|---------------|---------|
| `genstate_init(gs, f, code, ...)` | Initialize GenState with buffers |
| `emit_inst(gs, inst)` | Emit 32-bit instruction |
| `add_branch(gs, target, is_cond, cond)` | Record branch for resolution |
| `add_branch_cbz(gs, target, reg, is_nonzero)` | Record CBZ/CBNZ branch |
| `genssa(gs) i64` | Main SSA code generation |
| `genssa_block_values(gs, block)` | Generate code for block |
| `genssa_value(gs, v)` | Dispatch for single value |
| `genssa_const_int(gs, v)` | Generate integer constant |
| `genssa_const_bool(gs, v)` | Generate boolean constant |
| `genssa_const_string(gs, v)` | Generate string constant |
| `genssa_string_make(gs, v)` | Generate string construction |
| `genssa_slice_make(gs, v)` | Generate slice construction |
| `genssa_slice_ptr(gs, v)` | Extract slice pointer |
| `genssa_slice_len(gs, v)` | Extract slice length |
| `genssa_add(gs, v)` | Generate addition |
| `genssa_sub(gs, v)` | Generate subtraction |
| `genssa_mul(gs, v)` | Generate multiplication |
| `genssa_div(gs, v)` | Generate division |
| `genssa_mod(gs, v)` | Generate modulo |
| `genssa_and(gs, v)` | Generate bitwise AND |
| `genssa_or(gs, v)` | Generate bitwise OR |
| `genssa_xor(gs, v)` | Generate bitwise XOR |
| `genssa_shl(gs, v)` | Generate shift left |
| `genssa_shr(gs, v)` | Generate shift right |
| `genssa_neg(gs, v)` | Generate negation |
| `genssa_not(gs, v)` | Generate bitwise NOT |
| `genssa_compare(gs, v, cond)` | Generate comparison |
| `genssa_select(gs, v)` | Generate ternary select |
| `genssa_load(gs, v)` | Generate memory load |
| `genssa_store(gs, v)` | Generate memory store |
| `genssa_local_addr(gs, v)` | Generate local address |
| `genssa_off_ptr(gs, v)` | Generate pointer offset |
| `genssa_call(gs, v)` | Generate function call |
| `genssa_return(gs, v)` | Generate return |
| `genssa_copy(gs, v)` | Generate register copy |
| `genssa_block_control(gs, block, next)` | Generate block control flow |
| `resolve_branches(gs)` | Resolve branch targets |
| `patch_b(gs, offset, rel)` | Patch B instruction |
| `patch_b_cond(gs, offset, rel, cond)` | Patch B.cond instruction |
| `patch_cbz(gs, offset, rel, reg, is_nz)` | Patch CBZ/CBNZ instruction |

---

## 6. Object File Generation

### 6.1 cot0/obj/macho.cot vs src/obj/macho.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `macho_writer_init(w, ...)` | `MachOWriter.init()` | Equivalent |
| `macho_add_code(w, bytes, len)` | `MachOWriter.addCode()` | Same |
| `macho_add_string(w, s, len) i64` | `MachOWriter.addString()` | Same |
| `macho_add_symbol(w, name, len, val, sect, ext) i64` | `MachOWriter.addSymbol()` | Same |
| `macho_add_reloc(w, offset, sym, type, pcrel)` | — | Missing in Zig |
| `write_macho(w) i64` | `MachOWriter.write()` | Same |
| `make_reloc_info(sym, pcrel, len, ext, type) i64` | `RelocationInfo.makeInfo()` | Equivalent |
| `is_macho_magic(magic) bool` | — | Missing in Zig |
| `is_valid_file_type(type) bool` | — | Missing in Zig |
| `padding_for_align(offset, align) i64` | `alignTo()` | Equivalent |
| `align_up(offset, align) i64` | — | Missing in Zig |
| `out_byte(w, b)` | — | Missing in Zig (writer abstraction) |
| `out_u32(w, val)` | — | Missing in Zig (writer abstraction) |
| `out_u64(w, val)` | — | Missing in Zig (writer abstraction) |
| `out_zeros(w, n)` | — | Missing in Zig (writer abstraction) |
| `out_bytes(w, src, len)` | — | Missing in Zig (writer abstraction) |
| `write_mach_header(w, ncmds, size)` | — | Missing in Zig (integrated) |
| `write_segment_cmd(w, vmsize, ...)` | — | Missing in Zig (integrated) |
| `write_section(w, name, ...)` | — | Missing in Zig (integrated) |
| `write_symtab_cmd(w, ...)` | — | Missing in Zig (integrated) |
| `write_reloc(w, r)` | — | Missing in Zig (integrated) |
| `write_nlist64(w, sym)` | — | Missing in Zig (integrated) |
| — | `MachOWriter.deinit()` | Missing in cot0 |
| — | `MachOWriter.addData()` | Missing in cot0 |
| — | `MachOWriter.addStringLiteral()` | Missing in cot0 |
| — | `MachOWriter.addDataRelocation()` | Missing in cot0 |
| — | `MachOWriter.addGlobalVariable()` | Missing in cot0 |
| — | `MachOWriter.writeToFile()` | Missing in cot0 |

---

## 7. Zig-Only Files

These files exist in the Zig compiler but have no cot0 counterpart yet.

### 7.1 src/core/errors.zig

| Function | Purpose |
|----------|---------|
| `CompileError.init(kind, context)` | Create error with kind and context |
| `CompileError.withBlock(self, block_id)` | Add block context |
| `CompileError.withValue(self, value_id)` | Add value context |
| `CompileError.withPos(self, pos)` | Add source position |
| `CompileError.withPass(self, pass_name)` | Add pass name |
| `CompileError.format(...)` | Format error for display |
| `CompileError.toError(self)` | Convert to simple error |
| `Result(T).unwrap(self)` | Unwrap result value |
| `Result(T).getError(self)` | Get error from result |
| `VerifyError.format(...)` | Format verification error |

### 7.2 src/core/types.zig

| Function | Purpose |
|----------|---------|
| `TypeInfo.sizeOf(self)` | Get size in bytes |
| `TypeInfo.alignOf(self)` | Get alignment in bytes |
| `TypeInfo.fitsInRegs(self)` | Check if fits in registers |
| `TypeInfo.isPrimitive(self)` | Check if primitive type |
| `TypeInfo.isString(self)` | Check if string type |
| `TypeInfo.isSlice(self)` | Check if slice type |
| `TypeInfo.isPointer(self)` | Check if pointer type |
| `TypeInfo.isStruct(self)` | Check if struct type |
| `TypeInfo.isMemory(self)` | Check if SSA memory type |
| `TypeInfo.isVoid(self)` | Check if void type |
| `TypeInfo.isFlags(self)` | Check if flags type |
| `TypeInfo.isTuple(self)` | Check if tuple type |
| `TypeInfo.isResults(self)` | Check if results type |
| `TypeInfo.isFloat(self)` | Check if float type |
| `TypeInfo.isInteger(self)` | Check if integer type |
| `TypeInfo.isSigned(self)` | Check if signed integer |
| `TypeInfo.isUnsigned(self)` | Check if unsigned integer |
| `TypeInfo.needsReg(self)` | Check if needs register |
| `TypeInfo.registerCount(self)` | Get register count needed |
| `TypeInfo.getField(self, name)` | Get struct field by name |
| `TypeInfo.getFieldByIndex(self, idx)` | Get struct field by index |
| `IDAllocator.next(self)` | Allocate next ID |
| `IDAllocator.reset(self)` | Reset allocator |
| `regMaskSet(mask, reg)` | Set bit in register mask |
| `regMaskClear(mask, reg)` | Clear bit in register mask |
| `regMaskContains(mask, reg)` | Check if bit set |
| `regMaskCount(mask)` | Count set bits |
| `regMaskFirst(mask)` | Get first set bit |
| `RegMaskIterator.next(self)` | Iterate register mask |
| `regMaskIterator(mask)` | Create iterator |

### 7.3 src/frontend/source.zig

| Function | Purpose |
|----------|---------|
| `Pos.advance(self, n)` | Advance position by n bytes |
| `Pos.isValid(self)` | Check if position valid |
| `Position.format(...)` | Format as "file:line:col" |
| `Position.toString(self, alloc)` | Convert to string |
| `Span.init(start, end)` | Create span |
| `Span.fromPos(pos)` | Create zero-width span |
| `Span.merge(self, other)` | Merge two spans |
| `Span.len(self)` | Get span length |
| `Source.init(alloc, filename, content)` | Initialize source |
| `Source.deinit(self)` | Free source resources |
| `Source.at(self, pos)` | Get byte at position |
| `Source.slice(self, start, end)` | Get slice of content |
| `Source.spanText(self, span)` | Get text for span |
| `Source.position(self, pos)` | Convert to line/column |
| `Source.getLine(self, pos)` | Get line containing pos |
| `Source.lineCount(self)` | Get total line count |

### 7.4 src/frontend/errors.zig

| Function | Purpose |
|----------|---------|
| `ErrorCode.code(self)` | Get numeric error code |
| `ErrorCode.description(self)` | Get error description |
| `Error.at(pos, msg)` | Create error at position |
| `Error.withCode(pos, code, msg)` | Create error with code |
| `Error.atSpan(span, msg)` | Create error at span |
| `ErrorReporter.init(src, handler)` | Initialize reporter |
| `ErrorReporter.errorAt(self, pos, msg)` | Report error at pos |
| `ErrorReporter.errorWithCode(...)` | Report error with code |
| `ErrorReporter.errorAtSpan(...)` | Report error at span |
| `ErrorReporter.report(self, err)` | Report error (internal) |
| `ErrorReporter.hasErrors(self)` | Check if errors exist |
| `ErrorReporter.errorCount(self)` | Get error count |
| `ErrorReporter.firstError(self)` | Get first error |

### 7.5 src/ssa/dom.zig

| Function | Purpose |
|----------|---------|
| `computeDominators(f)` | Compute dominator tree |
| `computeDominanceFrontier(dom, f, alloc)` | Compute dominance frontier |
| `freeDominanceFrontier(frontier, alloc)` | Free frontier data |
| `DomTree.init(alloc, max_id)` | Initialize dominator tree |
| `DomTree.deinit(self)` | Free allocations |
| `DomTree.getIdom(self, b)` | Get immediate dominator |
| `DomTree.getChildren(self, b)` | Get children in tree |
| `DomTree.getDepth(self, b)` | Get depth in tree |
| `DomTree.dominates(self, a, b)` | Check if a dominates b |
| `DomTree.strictlyDominates(self, a, b)` | Check strict domination |

### 7.6 src/ssa/abi.zig

| Function | Purpose |
|----------|---------|
| `ARM64.regIndexToArm64(idx)` | Convert to ARM64 reg number |
| `ARM64.arm64ToRegIndex(reg)` | Convert from ARM64 reg |
| `ARM64.regMask(reg)` | Get register mask |
| `ABIParamAssignment.inRegs(type, regs)` | Create register param |
| `ABIParamAssignment.onStack(type, offset, size)` | Create stack param |
| `ABIParamAssignment.isRegister(self)` | Check if register |
| `ABIParamAssignment.isStack(self)` | Check if stack |
| `ABIParamResultInfo.inParam(self, n)` | Get input param N |
| `ABIParamResultInfo.outParam(self, n)` | Get output param N |
| `ABIParamResultInfo.regsOfArg(self, n)` | Get regs for input N |
| `ABIParamResultInfo.regsOfResult(self, n)` | Get regs for output N |
| `ABIParamResultInfo.offsetOfArg(self, n)` | Get stack offset for arg N |
| `ABIParamResultInfo.offsetOfResult(self, n)` | Get stack offset for result N |
| `ABIParamResultInfo.typeOfArg(self, n)` | Get type of arg N |
| `ABIParamResultInfo.typeOfResult(self, n)` | Get type of result N |
| `ABIParamResultInfo.numArgs(self)` | Number of inputs |
| `ABIParamResultInfo.numResults(self)` | Number of outputs |
| `ABIParamResultInfo.argWidth(self)` | Total stack width |
| `ABIParamResultInfo.dump(self)` | Debug print |
| `buildCallRegInfo(alloc, abi_info)` | Build RegInfo from ABI |
| `analyzeFunc(func_type, type_reg, alloc)` | Analyze function ABI |
| `analyzeFuncType(type_idx, type_reg, alloc)` | Analyze by TypeIndex |
| `formatRegMask(mask)` | Format mask as string |

### 7.7 src/ssa/debug.zig

| Function | Purpose |
|----------|---------|
| `dump(f, format, writer)` | Dump function to writer |
| `dumpText(f, writer)` | Dump as text |
| `dumpDot(f, writer)` | Dump as DOT for Graphviz |
| `dumpHtml(f, writer)` | Dump as interactive HTML |
| `dumpToFile(f, format, path)` | Dump to file |
| `verify(f, alloc)` | Verify SSA invariants |
| `freeErrors(errors, alloc)` | Free error list |
| `PhaseSnapshot.capture(alloc, f, name)` | Capture function state |
| `PhaseSnapshot.deinit(self)` | Free snapshot |
| `PhaseSnapshot.compare(before, after)` | Compare snapshots |
| `ChangeStats.hasChanges(self)` | Check for changes |
| `ChangeStats.format(...)` | Format stats |

### 7.8 src/ssa/compile.zig

| Function | Purpose |
|----------|---------|
| `compile(f, config)` | Compile through all passes |
| `runPass(f, pass_name)` | Run specific pass by name |
| `PassStats.printSummary(self, writer)` | Print compilation stats |
| `HTMLWriter.init(alloc, path)` | Initialize HTML writer |
| `HTMLWriter.deinit(self)` | Close HTML writer |
| `HTMLWriter.writeHeader(self, func_name)` | Write HTML header |
| `HTMLWriter.writePass(self, name, f)` | Write pass results |
| `HTMLWriter.writeFooter(self)` | Write HTML footer |

### 7.9 src/ssa/stackalloc.zig

| Function | Purpose |
|----------|---------|
| `stackalloc(f, spill_live)` | Assign stack offsets |
| `StackAllocState.init(alloc, f)` | Initialize state |
| `StackAllocState.deinit(self)` | Free state |

### 7.10 src/ssa/passes/lower.zig

| Function | Purpose |
|----------|---------|
| `lowerOp(op, aux_int)` | Map generic op to ARM64 op |
| `canEncodeImm12(value)` | Check 12-bit immediate |
| `canEncodeImm12Shifted(value)` | Check shifted immediate |
| `lower(alloc, f)` | Lower all ops in function |

### 7.11 src/ssa/passes/schedule.zig

| Function | Purpose |
|----------|---------|
| `getScore(v, is_control)` | Compute scheduling priority |
| `schedule(f)` | Schedule values before regalloc |
| `scheduleBlock(alloc, block, f)` | Schedule single block |

### 7.12 src/ssa/passes/expand_calls.zig

| Function | Purpose |
|----------|---------|
| `expandCalls(f, type_reg)` | Decompose aggregates |
| `handleWideSelect(f, sel, store, reg)` | Handle >32B select |
| `rewriteWideArgStore(f, arg, store, size)` | Rewrite >16B struct store |
| `handleNormalSelect(f, sel, reg)` | Handle ≤32B select |
| `expandCallArgs(f, call, reg)` | Expand call arguments |
| `expandCallResults(f, call, reg)` | Expand call results |
| `insertValueAfter(blk, alloc, new, after)` | Insert value after another |
| `rewriteFuncResults(f, block, reg)` | Rewrite function returns |
| `getStringPtrComponent(str)` | Extract string ptr |
| `getStringLenComponent(str)` | Extract string len |
| `applyDecRules(f)` | Apply decomposition rules |

### 7.13 src/ssa/passes/decompose.zig

| Function | Purpose |
|----------|---------|
| `decompose(f, type_reg)` | Transform 16-byte to 8-byte values |
| `decomposeBlock(f, block, reg)` | Process single block |
| `decomposeConstString(f, block, idx, v)` | Decompose const_string |
| `decomposeLoad(f, block, idx, v)` | Decompose 16-byte load |
| `decomposeStringPhi(f, block, idx, v)` | Decompose string phi |
| `decomposeStore(f, block, idx, v)` | Decompose 16-byte store |
| `getTypeSize(type_idx, type_reg)` | Get type size in bytes |

### 7.14 src/codegen/generic.zig

| Function | Purpose |
|----------|---------|
| `GenericCodeGen.init(alloc)` | Initialize generic codegen |
| `GenericCodeGen.deinit(self)` | Clean up resources |
| `GenericCodeGen.generate(self, f, writer)` | Generate pseudo-assembly |

---

## Summary Statistics

| Category | cot0 Functions | Zig Functions | Notes |
|----------|----------------|---------------|-------|
| Main/Driver | 19 | 8+ | cot0 procedural, Zig OOP |
| Frontend (8 files) | ~180 | ~200 | Very similar |
| SSA (7 files) | ~80 | ~100 | cot0 missing deinit/dump |
| ARM64 (2 files) | ~95 | ~60 | cot0 has more helpers |
| Codegen (2 files) | ~65 | ~40 | cot0 split into genssa.cot |
| Obj/MachO | 22 | 10 | cot0 has explicit helpers |
| **Zig-only files** | 0 | ~150 | Major infrastructure gap |

### Key Findings

1. **cot0 frontend is nearly complete** - Parser, scanner, checker, lowerer all closely match Zig
2. **cot0 SSA is functional but missing infrastructure** - No deinit, dump, verify, or dominator analysis
3. **cot0 arm64/asm.cot has MORE encoding functions** than Zig - cot0 extracts helpers that Zig keeps inline
4. **cot0 is missing critical SSA passes**:
   - Dominator analysis (dom.zig)
   - ABI handling (abi.zig)
   - All optimization passes (lower, schedule, expand_calls, decompose)
   - Stack allocation (stackalloc.zig)
   - Pass infrastructure (compile.zig)
5. **cot0 uses procedural design** - Global state vs Zig's struct-based design with allocators
6. **cot0 is NOT ready for self-hosting** - Missing too much infrastructure

### Path to Self-Hosting

To become self-hosting, cot0 needs:
1. Error handling infrastructure (errors.zig equivalent)
2. Source tracking (source.zig equivalent)
3. SSA passes (lower, schedule, expand_calls, decompose)
4. ABI handling for proper calling conventions
5. Dominator analysis for phi node insertion
6. Stack allocation pass
7. Better register allocation with coalescing

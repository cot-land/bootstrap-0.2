# cot0 vs Zig Compiler Function Comparison

> **WORK MODE**: Continue working on parity improvements without pausing for summaries.
> The user will stop you when enough progress has been made. Just keep working.

This document provides a comparison of functions between the cot0 self-hosting compiler and the Zig bootstrap compiler.

## ⚠️ AUDIT WARNING

**This document has NOT been thoroughly verified.** Many entries marked "Same" have not been
actually compared line-by-line. During a partial audit (2026-01-22), several functions marked
"Same" were found to be significantly DIFFERENT:

- `lower_binary`: cot0 has 60-line BUG-049 spill workaround, Zig is 20 lines
- `lower_call`: cot0 has manual 8-arg tracking + two-pass spill, Zig uses ArrayList
- `lower_index`: cot0 missing pointer type check via TypeRegistry
- `lower_var_decl`: cot0 uses PTYPE encoding vs Zig's type registry

**DO NOT TRUST "Same" STATUS without verification.**

## Legend
- **Same**: Same name, same logic (UNVERIFIED - may actually differ)
- **DIFFERENT**: Verified to have different logic/implementation
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
| `cot0/ssa/dom.cot` | `src/ssa/dom.zig` |
| `cot0/ssa/abi.cot` | `src/ssa/abi.zig` |
| `cot0/ssa/stackalloc.cot` | `src/ssa/stackalloc.zig` |
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
- `src/ssa/debug.zig`
- `src/ssa/compile.zig`
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

**AUDIT COMPLETED: SIGNIFICANT DIFFERENCES FOUND**

| cot0 Function | Zig Function | Status | Comment |
|---------------|--------------|--------|---------|
| `main(argc, argv) i64` | `pub fn main() !void` | DIFFERENT | cot0 uses C-style argc/argv with i64 return; Zig uses error union !void with GeneralPurposeAllocator |
| `Driver_compileFile(source, out_path, len) i64` | `Driver.compileFile()` | DIFFERENT | cot0 uses global buffers (g_source, g_nodes, g_types); Zig uses allocator with proper cleanup (defer/errdefer) |
| `Driver_compileSource(source, out_path, len) i64` | `Driver.compileSource()` | DIFFERENT | cot0 procedural; Zig method on Driver struct with allocator |
| `Driver_init() Driver` | `Driver.init()` | DIFFERENT | cot0 returns empty struct; Zig takes allocator and initializes properly |
| `Driver_setDebugPhases(phases, len)` | `Driver.setDebugPhases()` | DIFFERENT | cot0 has basic support; Zig uses pipeline_debug with category-based logging |
| `Driver_parseFileRecursive(pool)` | `parseFileRecursive()` | DIFFERENT | cot0 iterative using global g_source, no cycle detection; Zig recursive with StringHashMap for cycles, uses allocator, proper error handling |
| `print_usage()` | Inline in main | Equivalent | Both print usage info |
| `ir_op_to_ssa_op(ir_op) Op` | SSA conversion in codegen | Equivalent | Both convert IR ops to SSA ops |
| `ir_unary_op_to_ssa_op(ir_op) Op` | SSA conversion in codegen | Equivalent | Both convert unary ops |
| `print_int(n)` | `std.debug.print()` | DIFFERENT | cot0 uses syscall write(1,...); Zig uses std.debug.print |
| `read_file(path) i64` | `std.fs.cwd().readFileAlloc()` | DIFFERENT | cot0 uses open/read syscalls into global buffer; Zig allocates and returns slice |
| `write_file(path, data, len) i64` | `std.fs.cwd().writeFile()` | DIFFERENT | cot0 uses open/write syscalls; Zig uses std.fs |
| `init_node_pool() *NodePool` | AST init in parser | DIFFERENT | cot0 returns ptr to global; Zig initializes with allocator |
| `is_path_imported(path, len) bool` | `seen_files.contains()` | DIFFERENT | cot0 uses global array; Zig uses StringHashMap |
| `add_imported_path(path, len)` | `seen_files.put()` | DIFFERENT | cot0 appends to global array; Zig inserts into HashMap |
| `extract_base_dir(path, len)` | `std.fs.path.dirname()` | DIFFERENT | cot0 manual string scanning; Zig uses stdlib |
| `build_import_path(import_path, len) i64` | `std.fs.path.join()` | DIFFERENT | cot0 manual string concat into global; Zig uses stdlib with allocator |
| `adjust_node_positions(pool, start, end, offset)` | Position in Source | DIFFERENT | cot0 manual; Zig has Source.position() method |
| `parse_import_file(path, len, pool) i64` | parseFileRecursive loop | DIFFERENT | cot0 uses global buffers; Zig allocates per-file Source |
| `strlen(s) i64` | Slice length | DIFFERENT | cot0 loops null-terminated; Zig uses .len |
| `streq(a, b) bool` | `std.mem.eql()` | DIFFERENT | cot0 loops byte-by-byte; Zig uses std.mem.eql |
| `strcpy(dest, src, max) i64` | `allocator.dupe()` | DIFFERENT | cot0 manual copy; Zig allocates new slice |
| — | `findRuntimePath()` | Missing in cot0 | cot0 has no runtime path discovery |
| — | `pipeline_debug.initGlobal()` | Missing in cot0 | cot0 has no debug infrastructure |
| — | `TypeRegistry.init()` | Missing in cot0 | cot0 uses TypeRegistry with global arrays instead |
| — | `Scope.init()` | Missing in cot0 | cot0 has no scope management like Zig |
| — | `ErrorReporter` | Missing in cot0 | cot0 uses print() directly |

**Key architectural difference:** cot0 uses ~1000 lines of global static arrays (g_source, g_nodes, g_types, g_ir_nodes, etc.) while Zig uses allocator-based memory management throughout. This is a fundamental design difference, not just "same logic different syntax."

---

## 2. Frontend

### 2.1 cot0/frontend/token.cot vs src/frontend/token.zig

**AUDIT COMPLETED: 273 lines cot0 vs 460 lines Zig (59%)**

| cot0 Function | Zig Function | Status | Comment |
|---------------|--------------|--------|---------|
| `Token_new(kind, start, end) Token` | Struct initialization | Same | Both create Token struct |
| `Token_lookup(text) TokenType` | `lookup(name) Token` | DIFFERENT | cot0 manually checks char codes (`text[0] == 102`); Zig uses `StaticStringMap.initComptime()` |
| `Token_precedence(t) i64` | `Token.precedence() u8` | DIFFERENT | cot0 uses if-chain; Zig uses switch. Logic same but cot0 returns i64, Zig returns u8 |
| `Token_isLiteral(t) bool` | `Token.isLiteral() bool` | DIFFERENT | cot0 checks each literal manually; Zig uses enum range check (literal_beg..literal_end) |
| `Token_isOperator(t) bool` | `Token.isOperator() bool` | DIFFERENT | cot0 has 20-line if-chain; Zig uses enum range check (operator_beg..operator_end) |
| `Token_isKeyword(t) bool` | `Token.isKeyword() bool` | DIFFERENT | cot0 has 15-line if-chain; Zig uses enum range check (keyword_beg..keyword_end) |
| `Token_isTypeKeyword(t) bool` | `Token.isTypeKeyword() bool` | DIFFERENT | cot0 checks 6 types; Zig checks 16 types (has more sized types) |
| `Token_isAssignment(t) bool` | `Token.isAssignment() bool` | Same | Both check same assignment operators |
| `TokenType` enum (60 variants) | `Token` enum(u8) (80+ variants) | DIFFERENT | Zig has float_lit, string_interp_*, coalesce, optional_chain, period_star, period_question, kw_defer, kw_new, kw_undefined, kw_union, kw_type, more sized types |
| `Token_string(t) string` | `Token.string() []const u8` | Same | Added 2026-01-22 |
| — | `token_strings` comptime array | Missing in cot0 | No compile-time generated strings |
| — | Tests (60+ lines) | Missing in cot0 | cot0 has no tests |

**Key difference:** cot0 Token_lookup (lines 211-272) manually checks ASCII codes byte-by-byte, while Zig uses `std.StaticStringMap.initComptime()` which is O(1) hash lookup. This pattern continues throughout cot0 - manual implementations instead of stdlib.

### 2.2 cot0/frontend/scanner.cot vs src/frontend/scanner.zig

**AUDIT COMPLETED: 338 lines cot0 vs 753 lines Zig (45%)**

| cot0 Function | Zig Function | Status | Comment |
|---------------|--------------|--------|---------|
| `Scanner_init(source) Scanner` | `Scanner.init()` | DIFFERENT | cot0 takes string; Zig takes *Source + optional ErrorReporter |
| `Scanner_next(s) Token` | `Scanner.next()` | DIFFERENT | cot0 returns bare Token; Zig returns TokenInfo{tok, span, text} |
| `Scanner_peek(s) u8` | peek via self.ch | DIFFERENT | cot0 returns 0 at EOF; Zig uses ?u8 optional |
| `Scanner_peekNext(s) u8` | no direct equivalent | cot0-only | Zig handles differently |
| `Scanner_advance(s) u8` | `advance()` | DIFFERENT | cot0 returns u8; Zig updates self.ch optional |
| `Scanner_isAtEnd(s) bool` | `self.ch == null` | DIFFERENT | cot0 explicit check; Zig uses optional |
| `Scanner_skipWhitespace(s)` | `skipWhitespaceAndComments()` | DIFFERENT | cot0 inline line comments only; Zig has separate methods for line/block |
| `Scanner_scanNumber(s) Token` | `scanNumber()` | DIFFERENT | cot0 decimal only; Zig has hex, octal, binary, float support |
| `Scanner_scanIdentifier(s) Token` | `scanIdentifier()` | Same | Both check keywords |
| `Scanner_scanChar(s) Token` | `scanChar()` | Same | Both handle escape sequences |
| `Scanner_scanString(s) Token` | `scanString()` | DIFFERENT | cot0 basic; Zig has interpolation support (in_interp_string, interp_brace_depth) |
| `isAlpha(c) bool` | `isAlpha()` | Same | Both check A-Z, a-z, _ |
| `isDigit(c) bool` | `isDigit()` | Same | Both check 0-9 |
| `isAlphaNumeric(c) bool` | `isAlphaNumeric()` | Same | Both combine alpha+digit |
| — | `TokenInfo` struct | Missing in cot0 | cot0 has no span tracking |
| — | `Source` class integration | Missing in cot0 | cot0 uses raw string |
| — | `ErrorReporter` integration | Missing in cot0 | cot0 returns Error token, no reporting |
| `isHexDigit(c)` | `isHexDigit()` | Same | Added 2026-01-22 |
| — | `skipBlockComment()` | Missing in cot0 | No block comment support |
| — | String interpolation | Missing in cot0 | No ${...} interpolation |
| — | Tests (~100 lines) | Missing in cot0 | cot0 has no tests |

**Key difference:** cot0 Scanner_next (lines 150-338) is a 188-line if-chain using ASCII codes (`if c == 40`), while Zig uses switch statements and has proper error reporting via ErrorReporter. cot0 has no position tracking (Span), no error infrastructure.

### 2.3 cot0/frontend/ast.cot vs src/frontend/ast.zig

**AUDIT COMPLETED: 1131 lines cot0 vs 743 lines Zig (152%) - More lines but LESS type safety**

| cot0 Function | Zig Function | Status | Comment |
|---------------|--------------|--------|---------|
| `struct Node { field0-field5 }` | `Decl/Expr/Stmt union(enum)` | DIFFERENT | cot0 uses one Node struct with generic field0-field5 interpreted by kind; Zig uses tagged unions with named fields |
| `node_pool_init() NodePool` | `AST.init()` | DIFFERENT | cot0 uses global array pools with hardcoded limits; Zig uses allocator |
| `alloc_node(pool) *Node` | allocNode() | DIFFERENT | cot0 increments pool.count; Zig allocates from arena |
| `make_binary(pool, op, left, right) *Node` | Uses Expr.binary struct | DIFFERENT | cot0 sets field0/field1/field2; Zig uses {.lhs, .rhs, .op} struct |
| `make_unary(pool, op, operand) *Node` | Uses Expr.unary struct | DIFFERENT | cot0 sets field0/field1; Zig uses {.operand, .op} struct |
| `make_literal(pool, value) *Node` | Uses Expr.int_lit struct | DIFFERENT | cot0 sets field0; Zig uses {.value, .span} struct |
| `make_string_literal(pool, str, len) *Node` | Uses Expr.string_lit struct | DIFFERENT | cot0 sets field0/field1 (ptr/len); Zig uses []const u8 slice |
| `make_identifier(pool, name, len) *Node` | Uses Expr.ident struct | DIFFERENT | cot0 sets field0/field1 (start/len); Zig uses []const u8 slice |
| `make_call(pool, callee, args, count) *Node` | Uses Expr.call struct | DIFFERENT | cot0 uses separate args_start/args_count in global array; Zig uses []const NodeIndex |
| `make_index(pool, array, index) *Node` | Uses Expr.index struct | Same | Both store base and index expressions |
| `make_field_access(pool, obj, field, len) *Node` | Uses Expr.field struct | DIFFERENT | cot0 stores field name as start/len; Zig stores []const u8 |
| `make_if(pool, cond, then_b, else_b) *Node` | Uses Stmt.@"if" struct | DIFFERENT | cot0 uses field0/field1/field2; Zig uses {.cond, .then_body, .else_body} |
| `make_while(pool, cond, body) *Node` | Uses Stmt.@"while" struct | Same | Both store condition and body |
| `make_for(pool, init, cond, inc, body) *Node` | Uses Stmt.@"for" struct | Same | Both store init/cond/inc/body |
| `make_for_in(pool, iter, range, body) *Node` | Uses Stmt.for_in struct | Same | Both store iterator/range/body |
| `make_return(pool, value) *Node` | Uses Stmt.@"return" struct | Same | Both store optional value |
| `make_var_decl(pool, name, type, init) *Node` | Uses Decl.var_decl struct | DIFFERENT | cot0 uses field indices; Zig uses named fields |
| `make_func_decl(pool, name, params, ret, body) *Node` | Uses Decl.fn_decl struct | DIFFERENT | cot0 uses field0-field5; Zig uses FnDecl{name, params[], return_type, body} |
| `make_struct_decl(pool, name, fields) *Node` | Uses Decl.struct_decl struct | DIFFERENT | cot0 uses field indices; Zig uses StructDecl{name, fields[]} |
| `make_block(pool, stmts, count) *Node` | Uses Stmt.block struct | DIFFERENT | cot0 uses stmts_start/stmts_count; Zig uses []const NodeIndex |
| `make_assign(pool, target, value) *Node` | Uses Stmt.assign struct | Same | Both store target and value |
| `make_type_node(pool, kind, inner) *Node` | Uses TypeExpr union | DIFFERENT | cot0 uses field0/field1; Zig uses tagged union |
| `make_switch(pool, expr, cases, count) *Node` | Uses Expr.@"switch" struct | DIFFERENT | cot0 uses field0/field1/field2; Zig uses {.expr, .cases[]} |
| `NodePool` + `ChildList` | AST struct | DIFFERENT | cot0 has separate NodePool (1131 lines) with global arrays; Zig uses simple allocator-based AST |
| — | Tagged unions (Decl, Expr, Stmt, TypeExpr) | Missing in cot0 | cot0 uses single Node struct for all node types |
| — | Span on every node | Missing in cot0 | cot0 has start/end but no Span type integration |
| — | []const u8 for names | Missing in cot0 | cot0 stores name_start/name_len indices into source |
| — | AST.deinit() | Missing in cot0 | cot0 uses global pools, no cleanup |

**Key architectural difference:** Zig AST uses proper tagged unions with type safety - `Decl.fn_decl` has named fields like `name`, `params`, `return_type`. cot0 uses a single `Node` struct with `field0` through `field5` that are reinterpreted based on `NodeKind`. This is why cot0 has MORE lines but LESS type safety and readability.

### 2.4 cot0/frontend/parser.cot vs src/frontend/parser.zig

**AUDIT COMPLETED: 1659 lines cot0 vs 1644 lines Zig (101%) - Similar size but key differences**

| cot0 Function | Zig Function | Status | Comment |
|---------------|--------------|--------|---------|
| `Parser_init(source, pool) Parser` | `Parser.init()` | DIFFERENT | cot0 takes string + *NodePool; Zig takes allocator + *Scanner + *Ast + *ErrorReporter |
| `Parser_parseFile(p) i64` | `Parser.parse()` | Same | Both parse top-level declarations |
| `Parser_parseDecl(p) i64` | `declaration()` | Same | Both dispatch to specific declaration parsers |
| `Parser_parseFnDecl(p) i64` | `fnDeclaration()` | Same | Both parse function declarations |
| `Parser_parseStructDecl(p) i64` | `structDeclaration()` | Same | Both parse struct declarations |
| `Parser_parseVarDecl(p) i64` | `varDeclaration()` | Same | Both parse var/let declarations |
| `Parser_parseStmt(p) i64` | `statement()` | Same | Both dispatch to specific statement parsers |
| `Parser_parseIfStmt(p) i64` | `ifStatement()` | Same | Both parse if statements |
| `Parser_parseWhileStmt(p) i64` | `whileStatement()` | Same | Both parse while statements |
| `Parser_parseForStmt(p) i64` | `forStatement()` | Same | Both parse for statements |
| `Parser_parseReturnStmt(p) i64` | `returnStatement()` | Same | Both parse return statements |
| `Parser_parseSwitchExpr(p) i64` | `switchStatement()` | Same | Both parse switch expressions |
| `Parser_parseBlock(p) i64` | `block()` | Same | Both parse blocks |
| `Parser_parseExpr(p) i64` | `expression()` | DIFFERENT | cot0 has 50-line inline assignment handling; Zig is 2 lines calling binaryExpr |
| `Parser_parseBinaryExpr(p, left, prec) i64` | `binaryExpr()` | Same | Both use precedence climbing |
| `Parser_parseUnary(p) i64` | `unary()` | Same | Both parse unary expressions |
| `Parser_parseAtom(p) i64` | `primary()` | Same | Both parse primary expressions |
| `Parser_parseType(p) i64` | `parseType()` | Same | Both parse type expressions |
| `Parser_advance(p)` | `advance()` | Same | Both advance to next token |
| `Parser_want(p, type) bool` | `expect()` | DIFFERENT | cot0 sets had_error bool; Zig calls ErrorReporter |
| `Parser_check(p, type) bool` | `check()` | Same | Both check current token type |
| `Parser_got(p, type) bool` | `match()` | Same | Both consume if matches |
| `Parser_atEnd(p) bool` | `atEnd()` | Same | Both check for EOF |
| `Parser_hadError(p) bool` | via ErrorReporter | DIFFERENT | cot0 uses bool flag; Zig queries ErrorReporter |
| `Parser struct` | `Parser struct` | DIFFERENT | cot0 missing: allocator, peek_tok lookahead, nest_lev recursion limit |
| — | `peek_tok: ?TokenInfo` | Missing in cot0 | No 1-token lookahead |
| — | `nest_lev: u32` | Missing in cot0 | No recursion limit (max_nest_lev = 10000 in Zig) |
| — | ErrorReporter integration | Missing in cot0 | cot0 just sets had_error = true |
| — | Span tracking | Missing in cot0 | cot0 returns node index, no span |

**Key difference:** cot0 Parser struct lacks: allocator, ErrorReporter, peek lookahead, and recursion depth limit. Error handling is a single bool flag instead of proper error infrastructure.

### 2.5 cot0/frontend/types.cot vs src/frontend/types.zig

**AUDIT COMPLETED: 870 lines cot0 vs 835 lines Zig (104%) - Similar but different architecture**

| cot0 Function | Zig Function | Status | Comment |
|---------------|--------------|--------|---------|
| `TypeRegistry struct` | `TypeRegistry struct` | DIFFERENT | cot0 uses pointers to global arrays (*Type, *i64, *FieldInfo); Zig uses allocator with ArrayListUnmanaged |
| `TypeRegistry_init(pool)` | `TypeRegistry.init()` | DIFFERENT | cot0 sets up pointers to global arrays; Zig allocates with allocator |
| `TypeRegistry_get(pool, idx) *Type` | `getType()` | Same | Both return Type by index |
| `TypeRegistry_findByName(pool, name_start, name_len) i64` | `findTypeByName()` | DIFFERENT | cot0 uses name_start/len indices; Zig uses []const u8 slice |
| `TypeRegistry_makePointer(pool, elem) i64` | `makePointer()` | Same | Both create pointer types |
| `TypeRegistry_makeArray(pool, elem, len) i64` | `makeArray()` | Same | Both create array types |
| `TypeRegistry_makeStruct(pool, name, len, fields, count, size, align) i64` | `makeStruct()` | DIFFERENT | cot0 takes name as start/len; Zig takes []const u8 |
| `TypeRegistry_makeFunc(pool, params_start, params_count, ret) i64` | `makeFunction()` | Same | Both create function types |
| `TypeRegistry_setSource(pool, source, len)` | `setSource()` | DIFFERENT | cot0 stores raw pointer; Zig has no equivalent (uses slices) |
| `TypeInfo_*` functions | `TypeInfo.*` methods | DIFFERENT | cot0 takes (pool, idx); Zig has methods on TypeInfo struct |
| `PType_*` functions | No direct equivalent | cot0-only | cot0 uses PTYPE encoding (ranges like PTYPE_PTR_BASE=10, PTYPE_ARRAY_BASE=10000) |
| — | `TypeRegistry.deinit()` | Missing in cot0 | cot0 uses global arrays, no cleanup |
| — | `TypeRegistry.sizeOf()` | Different in cot0 | cot0 uses separate TypeInfo_size taking pool + idx |
| — | `TypeIndex = u32` | Different in cot0 | cot0 uses i64 everywhere |
| `TypeInfo_isPrimitive(pool, idx)` | `TypeInfo.isPrimitive()` | Same | Added 2026-01-22 |
| `TypeInfo_fitsInRegs(pool, idx)` | `TypeInfo.fitsInRegs()` | Same | Added 2026-01-22 |
| `TypeInfo_needsReg(pool, idx)` | `TypeInfo.needsReg()` | Same | Added 2026-01-22 |
| `TypeInfo_registerCount(pool, idx)` | `TypeInfo.registerCount()` | Same | Added 2026-01-22 |

**Key architectural difference:** cot0 uses PTYPE encoding where type indices encode information in ranges:
- 0-9: basic types (i64, bool, void, etc.)
- 10-99: pointer types (PTYPE_PTR_BASE=10)
- 100-9999: user-defined types (PTYPE_USER_BASE=100)
- 10000-99999: array types (PTYPE_ARRAY_BASE=10000)
- 100000+: slice types (PTYPE_SLICE_BASE=100000)

This encoding allows quick type classification without TypeRegistry lookup, but is fragile and limits type count. Zig uses proper TypeRegistry with TypeIndex lookups.

### 2.6 cot0/frontend/checker.cot vs src/frontend/checker.zig

**AUDIT COMPLETED: 745 lines cot0 vs 1990 lines Zig (37%) - SIGNIFICANTLY SMALLER**

| cot0 Function | Zig Function | Status | Comment |
|---------------|--------------|--------|---------|
| `Checker struct` | `Checker struct` | DIFFERENT | cot0 has ~10 fields with pointers to global arrays; Zig has allocator, TypeRegistry*, Ast*, ErrorReporter* |
| `Checker_init(chk, type_pool, scope_pool, ...)` | `Checker.init()` | DIFFERENT | cot0 sets up pointers; Zig takes allocator and proper module references |
| `Checker_checkFile(chk)` | `checkProgram()` | DIFFERENT | cot0 is ~50 lines; Zig is ~150 lines with more comprehensive checks |
| `Checker_checkFnDecl(chk, node_idx)` | `checkFunction()` | DIFFERENT | cot0 ~80 lines basic checks; Zig ~200 lines with return type analysis, parameter validation |
| `Checker_checkStructDecl(chk, node_idx)` | `checkStruct()` | DIFFERENT | cot0 ~40 lines; Zig ~100 lines with field offset calculation |
| `Checker_checkEnumDecl(chk, node_idx)` | `checkEnum()` | Same | Both register enum variants |
| `Checker_checkStmt(chk, node_idx) bool` | `checkStatement()` | DIFFERENT | cot0 ~100 lines; Zig ~300 lines with break/continue validation |
| `Checker_checkExpr(chk, node_idx) i64` | `checkExpression()` | DIFFERENT | cot0 ~200 lines; Zig ~500 lines with expression type caching |
| `Checker_checkVarDecl(chk, node_idx)` | `checkVarDecl()` | DIFFERENT | cot0 basic; Zig has type inference, const evaluation |
| `Checker_resolveTypeHandle(chk, type_handle) i64` | `resolveType()` | DIFFERENT | cot0 returns i64; Zig returns TypeIndex with validation |
| `Checker_ok(chk) bool` | via ErrorReporter | DIFFERENT | cot0 checks error_count; Zig queries ErrorReporter.hasErrors() |
| `Symbol struct` | `Symbol struct` | DIFFERENT | cot0 uses name_start/name_len; Zig uses []const u8 + ?i64 optional for const_value |
| `ScopePool struct` | `Scope struct` | DIFFERENT | cot0 uses MAX_SYMBOLS=5000, MAX_SCOPES=500 limits; Zig uses allocator |
| `ScopePool_define(pool, scope, sym)` | `Scope.define()` | DIFFERENT | cot0 appends to array; Zig uses StringHashMap |
| `ScopePool_lookup*` | `Scope.lookup()` | DIFFERENT | cot0 linear search; Zig uses hash lookup |
| — | `Checker.deinit()` | Missing in cot0 | cot0 uses global arrays |
| — | `expr_types` cache | Missing in cot0 | Zig caches expression types to avoid redundant checking |
| — | `checkReturnType()` | Missing in cot0 | Zig validates return statement types |
| — | `checkArrayInit()` | Missing in cot0 | Zig validates array initializer types |
| — | `checkStructInit()` | Missing in cot0 | Zig validates struct field initializers |
| — | Break/continue in loop check | Missing in cot0 | Zig tracks loop nesting |

**Key difference:** cot0 checker is 37% the size of Zig's because it's missing:
1. Expression type caching (expr_types HashMap)
2. Break/continue validation (loop nesting tracking)
3. Comprehensive type compatibility checks
4. Return statement type validation
5. Array/struct initializer validation
6. Proper scope lookup (linear search vs hash)

### 2.7 cot0/frontend/ir.cot vs src/frontend/ir.zig

**AUDIT COMPLETED: 715 lines cot0 vs 1705 lines Zig (42%) - SIGNIFICANTLY SMALLER**

| cot0 Function | Zig Function | Status | Comment |
|---------------|--------------|--------|---------|
| `IRNode struct` | `Instr struct` | DIFFERENT | cot0 uses generic field0-field5; Zig uses union(InstrData) with typed variants |
| `IRNodePool struct` | `IR struct` | DIFFERENT | cot0 uses pointer to global array; Zig uses allocator with ArrayListUnmanaged |
| `IRNodePool_init(pool, nodes, cap)` | `IR.init()` | DIFFERENT | cot0 sets up pointers; Zig allocates |
| `IRNodePool_add(pool, node) i64` | `addInstr()` | Same | Both append instruction |
| `IRNodePool_get(pool, idx) *IRNode` | `getInstr()` | Same | Both return instruction by index |
| `IRNodePool_addConstInt(pool, value, type) i64` | `addConst()` | Same | Both add constant |
| `IRNodePool_addBinary(pool, op, left, right, type) i64` | `addBinary()` | Same | Both add binary op |
| `IRNode_isTerminator(node) bool` | `Instr.isTerminator()` | Same | Both check for branch/return |
| `IRNode_isConstant(node) bool` | `Instr.isConstant()` | Same | Both check for constant |
| `IRLocal struct` | `Local struct` | DIFFERENT | cot0 uses name_start/name_len; Zig uses []const u8 name |
| `IRFunc struct` | `Func struct` | DIFFERENT | cot0 uses indices into global arrays; Zig uses slices |
| `IROpcode enum` | `Opcode enum` | Same | Both have ~30 opcodes |
| — | `InstrData union` | Missing in cot0 | cot0 uses generic fields, Zig has typed union |
| — | `IR.deinit()` | Missing in cot0 | cot0 uses global arrays |
| — | `IR.dump()` | Missing in cot0 | No IR debug printing |
| — | `IR.verify()` | Missing in cot0 | No IR verification |
| — | `BlockBuilder` | Missing in cot0 | Zig has proper block building infrastructure |
| — | Control flow graph | Missing in cot0 | Zig builds CFG, cot0 uses flat list |
| — | Phi nodes | Missing in cot0 | Zig has proper phi handling in IR |

**Key difference:** cot0 IR is 42% the size because:
1. No InstrData union - uses generic field0-field5 interpreted by opcode
2. No control flow graph - just flat list of instructions with block_id field
3. No phi node infrastructure
4. No IR verification or debug output
5. No proper block builder

### 2.8 cot0/frontend/lower.cot vs src/frontend/lower.zig

**AUDIT COMPLETED: 2622 lines cot0 vs 2684 lines Zig (98%) - Similar size but FUNDAMENTALLY DIFFERENT logic**

| cot0 Function | Zig Function | Status | Comment |
|---------------|--------------|--------|---------|
| `Lowerer struct` | `Lowerer struct` | DIFFERENT | cot0 uses ~20 pointers to global arrays; Zig uses allocator + TypeRegistry* + proper modules |
| `Lowerer_init(...)` | `Lowerer.init()` | DIFFERENT | cot0 takes 15+ pointer params to global arrays; Zig takes allocator + AST + TypeRegistry |
| `Lowerer_lowerAll(l) i64` | `lowerProgram()` | Same | Both lower entire program |
| `Lowerer_lowerFunction(l, node)` | `lowerFunction()` | DIFFERENT | cot0 manual param handling with param_count field; Zig uses type_reg.getParams() |
| `Lowerer_lowerStmt(l, node)` | `lowerStatement()` | Same | Both dispatch to specific lowerers |
| `Lowerer_lowerExpr(l, node) i64` | `lowerExpression()` | Same | Both dispatch by expression kind |
| `Lowerer_lowerBinary(l, node) i64` | `lowerBinary()` | **DIFFERENT - BUG-049** | cot0 has 60-line spill workaround (lines 1150-1210); Zig is 20 lines - proper SSA handles spilling |
| `Lowerer_lowerUnary(l, node) i64` | `lowerUnary()` | Same | Both handle negation, not, etc. |
| `Lowerer_lowerCall(l, node) i64` | `lowerCall()` | **DIFFERENT - WORKAROUND** | cot0 has manual 8-arg tracking (MAX_CALL_ARGS_TRACKED=8), two-pass spill logic (~150 lines); Zig uses ArrayList (~50 lines) |
| `Lowerer_lowerIndex(l, node) i64` | `lowerIndex()` | Same | Both use TypeRegistry to check pointer/array/slice types |
| `Lowerer_lowerField(l, node) i64` | `lowerField()` | DIFFERENT | cot0 scans source for field names; Zig uses type_reg.getField() |
| `Lowerer_lowerIf(l, node)` | `lowerIf()` | Same | Both lower if statements |
| `Lowerer_lowerWhile(l, node)` | `lowerWhile()` | Same | Both lower while loops |
| `Lowerer_lowerFor(l, node)` | `lowerFor()` | Same | Both lower for loops |
| `Lowerer_lowerForIn(l, node)` | `lowerForIn()` | Same | Both lower for-in loops |
| `Lowerer_lowerReturn(l, node)` | `lowerReturn()` | Same | Both lower return statements |
| `Lowerer_lowerAssign(l, node)` | `lowerAssign()` | DIFFERENT | cot0 missing compound assignment (+=, -=, etc.) lowering to binary+store |
| `Lowerer_lowerVarDecl(l, node)` | `lowerVarDecl()` | **DIFFERENT - PTYPE** | cot0 uses PTYPE encoding for size (added array fix); Zig uses type_reg.sizeOf() properly |
| `Lowerer_lowerSwitch(l, node)` | `lowerSwitch()` | DIFFERENT | cot0 has switch support but with nested select codegen; Zig has cleaner jump table approach |
| `func_builder_*` functions | FuncBuilder methods | DIFFERENT | cot0 uses static func builder with global arrays; Zig uses allocator-based builder |
| — | `Lowerer.deinit()` | Missing in cot0 | cot0 uses global arrays |
| — | `lowerMethodCall()` | Missing in cot0 | No method call support |
| — | `lowerIndirectCall()` | Missing in cot0 | No function pointer calls |
| — | `lowerSliceOp()` | Missing in cot0 | Incomplete slice operations |

**Critical workaround code in cot0 lower.cot:**

1. **BUG-049 spill workaround (lines ~1150-1210)**: 60+ lines of manual register spilling in `lowerBinary` because cot0's regalloc doesn't handle interference properly. Zig's SSA passes (regalloc, stackalloc) handle this automatically.

2. **Call argument workaround (lines ~800-950)**: 150+ lines of manual tracking with `MAX_CALL_ARGS_TRACKED=8` constant and two-pass spilling. This exists because cot0 doesn't have proper ABI handling passes.

3. **PTYPE encoding (throughout)**: Instead of calling `type_reg.sizeOf(type_idx)`, cot0 checks PTYPE ranges like `if type_handle >= PTYPE_ARRAY_BASE and type_handle < PTYPE_SLICE_BASE`. This is fragile and led to the array sizing bug.

**The line count is similar (98%) but the logic is COMPLETELY different** - cot0 has workaround code where Zig has proper SSA infrastructure.

---

## 3. SSA

### 3.1 cot0/ssa/op.cot vs src/ssa/op.zig

**AUDIT COMPLETED: 283 lines cot0 vs 1569 lines Zig (18%) - MASSIVELY SMALLER**

| cot0 Function | Zig Function | Status | Comment |
|---------------|--------------|--------|---------|
| `Op enum` | `Op enum` | DIFFERENT | cot0 has ~30 ops; Zig has ~150 ops including ARM64-specific, memory, phi, etc. |
| `op_name(op) *u8` | `Op.name()` | DIFFERENT | cot0 returns *u8 (null-terminated); Zig returns []const u8 |
| `op_is_commutative(op) bool` | `Op.isCommutative()` | Same | Both check for commutative ops |
| `op_is_comparison(op) bool` | `Op.isComparison()` | Same | Both check for comparison ops |
| `op_has_side_effects(op) bool` | `Op.hasSideEffects()` | Same | Both check for side effect ops |
| — | `OpInfo struct` | Missing in cot0 | Zig has comprehensive OpInfo with arg counts, result type, flags |
| `Op_isTerminator(op)` | `Op.isTerminator()` | Same | Already present |
| `Op_isBranch(op)` | `Op.isBranch()` | Same | Added 2026-01-22 |
| `Op_numArgs(op)` | `Op.numArgs()` | Same | Renamed from Op_argCount |
| `Op_isCall(op)` | `Op.isCall()` | Same | Added 2026-01-22 |
| — | `Op.resultType()` | Missing in cot0 | No result type inference |
| — | ARM64-specific ops | Missing in cot0 | Zig has ADDShifted, SUBShifted, MADD, CSEL, etc. |
| — | Memory ops | Missing in cot0 | Zig has LDRPost, STRPre, LDP, STP, etc. |

**Key difference:** cot0 op.cot is 18% the size because it lacks:
1. ARM64-specific operation encoding
2. OpInfo metadata (arg counts, types, flags)
3. ~120 additional ops for proper codegen

### 3.2 cot0/ssa/value.cot vs src/ssa/value.zig

**AUDIT COMPLETED: 240 lines cot0 vs 673 lines Zig (36%)**

| cot0 Function | Zig Function | Status | Comment |
|---------------|--------------|--------|---------|
| `Value struct` | `Value struct` | DIFFERENT | cot0 has ~15 fields; Zig has Aux union, SymbolOff, AuxCall, ~30 fields |
| `Value_init(op, type) Value` | `Value.init()` | Same | Both initialize value |
| `Value_setArg(v, idx, arg)` | `Value.setArg()` | Same | Both set argument |
| `Value_getArg(v, idx) *Value` | `Value.getArg()` | Same | Both get argument |
| `Value_numArgs(v) i64` | `Value.numArgs()` | Same | Both return arg count |
| `Value_setAuxInt(v, n)` | `Value.setAuxInt()` | DIFFERENT | cot0 sets i64 field; Zig uses Aux union |
| `Value_getAuxInt(v) i64` | `Value.getAuxInt()` | DIFFERENT | cot0 returns i64; Zig extracts from Aux union |
| `Value_addUse(v, user)` | Use tracking | DIFFERENT | cot0 basic; Zig has use chain management |
| `Value_replaceUses(v, new)` | `Value.replaceUses()` | Same | Both replace all uses |
| `Value_isConst(v) bool` | `Value.isConst()` | Same | Both check for constant |
| — | `Aux union` | Missing in cot0 | Zig has union{ int, sym, call, cond } |
| — | `SymbolOff struct` | Missing in cot0 | Zig tracks symbol + offset |
| — | `AuxCall struct` | Missing in cot0 | Zig has call argument tracking |
| — | `CondCode enum` | Missing in cot0 | Zig has condition code tracking |
| — | `Value.deinit()` | Missing in cot0 | cot0 uses global arrays |
| — | `Value.dump()` | Missing in cot0 | No debug output |
| — | `Value.format()` | Missing in cot0 | No formatting |
| — | Register hint/assignment | Missing in cot0 | Zig tracks register allocation state |

**Key difference:** cot0 value.cot is 36% the size because it lacks:
1. Aux union for typed auxiliary data
2. Symbol/offset tracking
3. Call argument infrastructure
4. Debug/dump functionality
5. Register allocation state tracking

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

**AUDIT COMPLETED: 366 lines cot0 vs 650 lines Zig (56%)**

| cot0 Function | Zig Function | Status | Comment |
|---------------|--------------|--------|---------|
| `Func struct` | `Func struct` | DIFFERENT | cot0 has pointers to global arrays (blocks*, values*, locals*); Zig uses ArrayListUnmanaged with allocator |
| `Func_init(...)` | `Func.init()` | DIFFERENT | cot0 takes ~10 pointers to global arrays; Zig takes allocator |
| `Func_newBlock(f) i64` | `Func.newBlock()` | DIFFERENT | cot0 returns index, has MAX_SSA_BLOCKS limit; Zig returns *Block, growable |
| `Func_newValue(f, op, type) i64` | `Func.newValue()` | DIFFERENT | cot0 returns index, has MAX_SSA_VALUES limit; Zig has value pooling |
| `Func_newEntryBlock(f) i64` | `Func.entryBlock()` | Same | Both return entry block |
| `Func_numBlocks(f) i64` | `Func.numBlocks()` | Same | Both return block count |
| `Func_getBlock(f, idx) *Block` | `Func.getBlock()` | Same | Both get block by index |
| `Func_getLocal(f, idx) *Local` | `Func.getLocal()` | Same | Both get local by index |
| `Func_addParam(f, ...)` | `Func.addParam()` | Same | Both add function parameter |
| `Func_addLocal(f, ...)` | `Func.addLocal()` | Same | Both add local variable |
| `Local struct` | `Local struct` | DIFFERENT | cot0 uses name_start/name_len; Zig uses []const u8 slice |
| — | `Func.deinit()` | Missing in cot0 | cot0 uses global arrays |
| — | `Func.dump()` | Missing in cot0 | No debug output |
| — | `Func.verify()` | Missing in cot0 | No SSA verification |
| — | `Func.constInt()` | Missing in cot0 | No cached constant pool |
| — | `Func.freeValue()` | Missing in cot0 | No value pooling/reuse |
| — | `Location union` | Missing in cot0 | Zig has {.reg, .stack, .const} for codegen |
| — | Frame size tracking | Missing in cot0 | Zig tracks stack frame size |

**Key difference:** cot0 func.cot is 56% the size because:
1. Uses static global arrays with hardcoded limits (MAX_SSA_BLOCKS=5000, MAX_SSA_VALUES=50000)
2. No value pooling - can't reuse freed values
3. No cached constant pool
4. No Location tracking for register/stack allocation
5. No debug/dump functionality

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
| — | `SSABuilder.deinit()` | Missing in cot0 | cot0 uses global arrays |
| `SSABuilder_emitCast()` | `buildCast()` | Same | Added 2026-01-22 |
| `SSABuilder_emitAlloca()` | `buildAlloca()` | Same | Added 2026-01-22 |

### 3.6 cot0/ssa/liveness.cot vs src/ssa/liveness.zig

**AUDIT COMPLETED: 590 lines cot0 vs 938 lines Zig (63%)**

| cot0 Function | Zig Function | Status | Comment |
|---------------|--------------|--------|---------|
| `Liveness struct` | `LivenessResult struct` | DIFFERENT | cot0 uses MAX_SSA_VALUES/MAX_SSA_BLOCKS limits; Zig uses AutoHashMap |
| `Liveness_init(l, f)` | `computeLiveness()` | DIFFERENT | cot0 takes preallocated arrays; Zig takes allocator and returns result |
| `Liveness_compute(l)` | `computeLiveness()` | DIFFERENT | cot0 basic dataflow; Zig uses iterative worklist algorithm |
| `Liveness_isLiveAt(l, val_id, block_id) bool` | `isLiveAt()` | Same | Both check if value live at block |
| `Liveness_liveIn(l, block_id) *LiveSet` | via LiveInfo | DIFFERENT | cot0 returns LiveSet pointer; Zig uses LiveInfo with AutoHashMap |
| `Liveness_liveOut(l, block_id) *LiveSet` | via LiveInfo | DIFFERENT | cot0 returns LiveSet pointer; Zig uses LiveInfo with AutoHashMap |
| `computeLocalLiveness(l, block_id)` | per-block computation | Equivalent | Both compute gen/kill sets |
| `propagateLiveness(l) bool` | iterative computation | Equivalent | Both iterate until fixpoint |
| `LiveSet struct` | `LiveMap = AutoHashMap` | DIFFERENT | cot0 uses fixed array with bitmap; Zig uses hash map |
| `LiveSet_init/add/remove/contains` | AutoHashMap methods | DIFFERENT | cot0 manual bitmap; Zig uses stdlib |
| — | `LivenessResult.deinit()` | Missing in cot0 | cot0 uses global arrays |
| — | `LiveInfo struct` | Missing in cot0 | Zig has per-block live in/out/defs/uses |
| — | `computeInterference()` | Missing in cot0 | No interference graph building |
| — | `LiveInterval struct` | Missing in cot0 | No live range tracking |
| — | Debug output | Missing in cot0 | No liveness debugging |

**Key difference:** cot0 liveness.cot is 63% the size because:
1. Uses fixed-size LiveSet with MAX_SSA_VALUES limit instead of hash maps
2. No interference graph computation (needed for proper regalloc)
3. No live interval tracking (needed for linear scan regalloc)
4. Basic dataflow only - no advanced optimizations

### 3.7 cot0/ssa/regalloc.cot vs src/ssa/regalloc.zig

**AUDIT COMPLETED: ~500 lines cot0 vs 1184 lines Zig (42%) - SPILL/RELOAD NOW WORKING**

| cot0 Function | Zig Function | Status | Comment |
|---------------|--------------|--------|---------|
| `RegAlloc struct` | `RegAllocState struct` | DIFFERENT | cot0 has ~10 fields; Zig has ValState[], RegState[], interference matrix, etc. |
| `RegAlloc_init(ra, f)` | `regalloc()` | DIFFERENT | cot0 takes preallocated arrays; Zig takes allocator + func + liveness |
| `RegAlloc_run(ra, f)` | `regalloc()` | DIFFERENT | cot0 basic greedy; Zig uses linear scan with splitting |
| `RegAlloc_allocateBlock(ra, f, block)` | per-block allocation | DIFFERENT | cot0 simple loop; Zig has instruction-level tracking |
| `RegAlloc_allocateValue(ra, f, v)` | `allocateValue()` | DIFFERENT | cot0 simple; Zig considers constraints, hints, interference |
| `assign_reg()` | `assignReg()` | **FIXED** | Now sets Value.reg for codegen |
| `spill_reg()` | `spillValue()` | **FIXED** | Now sets Value.spill_slot for codegen |
| `RegAlloc_getReg(ra, val_id) i64` | `ValState.reg` | Same | Both return allocated register |
| `RegAlloc_isSpilled(ra, val_id) bool` | `ValState.spilled` | Same | Both check spill status |
| `RegAlloc_getSpillSlot(ra, val_id) i64` | `ValState.slot` | Same | Both return spill slot |
| `ValState struct` | `ValState struct` | Same | cot0 has regs, spill, spill_used, needs_reg, rematerializable |
| `RegState struct` | `RegState struct` | Same | cot0 has value_id, dirty |
| `emit_reload()` (genssa) | `insertReloadCode()` | **IMPLEMENTED** | genssa emits LDR for spilled args |
| `emit_spill()` (genssa) | `insertSpillCode()` | **IMPLEMENTED** | genssa emits STR after computing spilled values |
| — | `handlePhiCopies()` | Missing in cot0 | No parallel copy handling for phi resolution |
| — | `coalesce()` | Missing in cot0 | No copy coalescing optimization |
| — | `simplify()` | Missing in cot0 | No Chaitin-Briggs simplification |
| — | `computeLiveRanges()` | Missing in cot0 | No live range computation |
| — | `splitLiveRange()` | Missing in cot0 | No live range splitting |
| — | Debug output | Missing in cot0 | No regalloc debugging |

**Key difference:** cot0 regalloc.cot is 42% the size because:
1. **Spill code insertion FIXED** - regalloc sets Value.spill_slot, genssa emits STR
2. **Reload code FIXED** - genssa emits LDR for spilled arguments
3. **No phi copy handling** - phi nodes not properly resolved
4. **No coalescing** - copies not eliminated
5. **No live range splitting** - can't handle complex interference

**Recent fixes (2026-01-22):**
- `assign_reg()` now sets `Value.reg` so codegen can read it
- `spill_reg()` now sets `Value.spill_slot` for codegen to emit stores
- `stackalloc.cot` now converts spill slot numbers to actual stack offsets
- `genssa.cot` now has `emit_reload()` and `emit_spill()` helpers
- Tests passing: spill_test (20 variables), recursion (fib(10)), simple arithmetic

### 3.8 cot0/ssa/dom.cot vs src/ssa/dom.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `DomTree_init(dt)` | `DomTree.init()` | Same |
| `DomTree_compute(dt, f)` | `computeDominators()` | Same |
| `DomTree_computeRPO(dt, f)` | `reversePostorder()` | Same |
| `DomTree_postorderDFS(dt, f, bid)` | `postorderDFS()` | Same |
| `DomTree_intersect(dt, f, b1, b2, entry)` | `intersect()` | Same |
| `DomTree_getRPONum(dt, bid, entry)` | `getRPONum()` | Same |
| `DomTree_buildChildren(dt, f)` | (inline in computeDominators) | Same |
| `DomTree_computeDepths(dt, f)` | `computeDepths()` | Same |
| `DomTree_getIdom(f, bid)` | `DomTree.getIdom()` | Same |
| `DomTree_getDepth(f, bid)` | `DomTree.getDepth()` | Same |
| `DomTree_dominates(f, a, b)` | `DomTree.dominates()` | Same |
| `DomTree_strictlyDominates(f, a, b)` | `DomTree.strictlyDominates()` | Same |
| `DomTree_computeFrontier(dt, f)` | `computeDominanceFrontier()` | Same |
| `DomTree_addToFrontier(dt, bid, fb)` | (inline) | Same |
| `DomTree_getFrontier(dt, bid, out, cap)` | (array access) | Same |
| `DomTree_dump(dt, f)` | (via debug.zig) | Same |
| — | `DomTree.deinit()` | Missing in cot0 |
| — | `DomTree.getChildren()` | Missing in cot0 |
| — | `freeDominanceFrontier()` | Missing in cot0 |

### 3.9 cot0/ssa/abi.cot vs src/ssa/abi.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `ABIParamAssignment_init()` | (struct literal) | Same |
| `ABIParamAssignment_inRegs(type, r0, r1, cnt)` | `ABIParamAssignment.inRegs()` | Same |
| `ABIParamAssignment_onStack(type, off, size)` | `ABIParamAssignment.onStack()` | Same |
| `ABIParamAssignment_isRegister(a)` | `ABIParamAssignment.isRegister()` | Same |
| `ABIParamAssignment_isStack(a)` | `ABIParamAssignment.isStack()` | Same |
| `ABIParamResultInfo_init()` | (struct literal) | Same |
| `ABIParamResultInfo_inParam(info, n)` | `ABIParamResultInfo.inParam()` | Same |
| `ABIParamResultInfo_outParam(info, n)` | `ABIParamResultInfo.outParam()` | Same |
| `ABIParamResultInfo_argReg(info, n)` | `ABIParamResultInfo.regsOfArg()` | Same |
| `ABIParamResultInfo_resultReg(info, n)` | `ABIParamResultInfo.regsOfResult()` | Same |
| `ABIParamResultInfo_argOffset(info, n)` | `ABIParamResultInfo.offsetOfArg()` | Same |
| `ABIParamResultInfo_resultOffset(info, n)` | `ABIParamResultInfo.offsetOfResult()` | Same |
| `ABIParamResultInfo_numArgs(info)` | `ABIParamResultInfo.numArgs()` | Same |
| `ABIParamResultInfo_numResults(info)` | `ABIParamResultInfo.numResults()` | Same |
| `ABIAssignState_init()` | `AssignState.init()` | Same |
| `ABIAssignState_resetRegs(state)` | `AssignState.resetRegs()` | Same |
| `ABIAssignState_tryAllocRegs(state, size, out)` | `AssignState.tryAllocRegs()` | Same |
| `ABIAssignState_allocStack(state, size, align)` | `AssignState.allocStack()` | Same |
| `ABI_getTypeSize(type_idx)` | `TypeRegistry.sizeOf()` | Equivalent |
| `ABI_getTypeAlignment(type_idx)` | `TypeRegistry.alignmentOf()` | Equivalent |
| `ABI_analyzeFunc(info, params, cnt, ret)` | `analyzeFunc()` | Same |
| `ABI_getStrConcatABI(info)` | `str_concat_abi` (const) | Same |
| `ABI_getPrintlnABI(info)` | (not present) | cot0-only |
| `ABI_alignUp(val, align)` | `alignUp()` | Same |
| `ABI_regMask(reg)` | `ARM64.regMask()` | Same |
| `ABI_regIndexToARM64(idx)` | `ARM64.regIndexToArm64()` | Same |
| `ABI_arm64ToRegIndex(reg)` | `ARM64.arm64ToRegIndex()` | Same |
| `ABI_dumpInfo(info)` | `ABIParamResultInfo.dump()` | Same |
| — | `analyzeFuncType()` | Missing in cot0 |
| — | `buildCallRegInfo()` | Missing in cot0 |
| — | `formatRegMask()` | Missing in cot0 |

### 3.10 cot0/ssa/stackalloc.cot vs src/ssa/stackalloc.zig

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `StackAllocResult_init()` | (struct literal) | Same |
| `StackValState_init()` | (struct literal) | Same |
| `SlotInfo_init()` | (struct literal) | Same |
| `StackAllocState_init(state)` | `StackAllocState.init()` | Same |
| `StackAllocState_setLiveOut(state, b, v)` | `pushLive()` | Equivalent |
| `StackAllocState_isLiveOut(state, b, v)` | `live.get()` | Equivalent |
| `StackAlloc_markValues(state, f)` | `initValues()` | Same |
| `StackAlloc_computeLiveness(state, f)` | `computeLive()` | Same |
| `StackAlloc_propagateLiveness(state, f, v, use, def)` | (in computeLive) | Same |
| `StackAlloc_buildInterference(state, f)` | `buildInterference()` | Same |
| `StackAlloc_addInterference(state, a, b)` | `addInterference()` | Same |
| `StackAlloc_checkInterference(state, a, b, f)` | (in buildInterference) | Same |
| `StackAlloc_allocateLocals(state, f, result)` | (in stackalloc) | Same |
| `StackAlloc_allocateSpillSlots(state, f, result)` | (in stackalloc) | Same |
| `StackAlloc_run(f)` | `stackalloc()` | Same |
| `StackAlloc_dump(f, result)` | (via debug logging) | Same |
| — | `StackAllocState.deinit()` | Missing in cot0 |

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
| `encode_sxtb(rd, rn)` | `encodeSXTB32/64()` | Same | Added 2026-01-22 (64-bit only) |
| `encode_sxth(rd, rn)` | `encodeSXTH32/64()` | Same | Added 2026-01-22 (64-bit only) |
| `encode_sxtw(rd, rn)` | `encodeSXTW()` | Same | Added 2026-01-22 |
| `encode_uxtb(rd, rn)` | `encodeUXTB32/64()` | Same | Added 2026-01-22 (64-bit only) |
| `encode_uxth(rd, rn)` | `encodeUXTH32/64()` | Same | Added 2026-01-22 (64-bit only) |
| `encode_tst_reg(rn, rm)` | `encodeTST()` | Same | Added 2026-01-22 |
| `invert_cond(cond)` | `invertCond()` | Same | Added 2026-01-22 |

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

### 5.1 cot0/codegen/arm64.cot + genssa.cot vs src/codegen/arm64.zig

**NAMING PARITY COMPLETE (2026-01-22)** - Functions renamed to ARM64_*, GenState_*, Emitter_*, Instruction_*, Cond_* patterns.

**AUDIT COMPLETED: 1295 lines cot0 (299+996) vs 3529 lines Zig (3221+308) = 37%**

| cot0 Function | Zig Function | Status | Comment |
|---------------|--------------|--------|---------|
| `GenState struct` | `ARM64CodeGen struct` | DIFFERENT | cot0 uses pointers to global arrays; Zig uses allocator + TypeRegistry* + RegAllocState* |
| `GenState_init(gs, ...)` | `ARM64CodeGen.init()` | DIFFERENT | cot0 takes ~15 pointer params; Zig takes allocator |
| `genssa(gs) i64` | `generateBinary()` | DIFFERENT | cot0 single function; Zig has multi-pass codegen |
| `genssa_block_values(gs, block)` | `generateBlockBinary()` | DIFFERENT | cot0 simple loop; Zig handles phi moves, spills |
| `genssa_value(gs, v)` | `generateValueBinary()` | DIFFERENT | cot0 switch on op; Zig has register tracking, spill handling |
| `genssa_add/sub/mul/div/...` | via generateValueBinary | DIFFERENT | cot0 raw encoding; Zig considers regalloc state |
| `genssa_load(gs, v)` | inline in generateValueBinary | DIFFERENT | cot0 simple; Zig handles spilled source |
| `genssa_store(gs, v)` | inline in generateValueBinary | DIFFERENT | cot0 simple; Zig handles spilled destination |
| `genssa_call(gs, v)` | via generateValueBinary | DIFFERENT | cot0 basic; Zig uses ABI module for arg passing |
| `genssa_return(gs, v)` | via generateValueBinary | Same | Both encode return sequence |
| `genssa_block_control(gs, block, next)` | `emitBlockTerminator()` | DIFFERENT | cot0 basic jumps; Zig handles fall-through optimization |
| `resolve_branches(gs)` | `applyBranchFixups()` | Same | Both patch branch offsets |
| `encode_prologue(gs, frame_size)` | `emitPrologue()` | DIFFERENT | cot0 fixed pattern; Zig calculates from frame layout |
| `encode_epilogue(gs, frame_size)` | `emitEpilogue()` | DIFFERENT | cot0 fixed pattern; Zig matches prologue |
| `emit_inst(gs, inst)` | inline emit | Same | Both append 32-bit instruction |
| — | `ensureInReg()` | DIFFERENT | cot0 directly accesses v.reg and uses move instructions |
| — | `getRegForValue()` | DIFFERENT | cot0 directly accesses v.reg set by regalloc |
| — | `getDestRegForValue()` | DIFFERENT | cot0 directly accesses v.reg set by regalloc |
| — | `setupCallArgs()` | Missing in cot0 | Zig uses ABI to place args in correct regs |
| — | `emitPhiMoves()` | Missing in cot0 | No phi resolution in cot0 |
| `GenState_emitSpill(gs, v)` | `handleSpill()` | Same | Both emit store to spill slot |
| `GenState_emitReload(gs, v)` | `handleReload()` | Same | Both emit load from spill slot |
| — | `setRegAllocState()` | DIFFERENT | cot0 uses v.reg/v.spill_slot directly |
| — | `setTypeRegistry()` | Missing in cot0 | No type-aware sizing |

**Key difference:** cot0 genssa.cot is smaller because:
1. **Simpler register access** - directly uses v.reg instead of getter functions
2. **Spill/reload handled** - GenState_emitSpill/GenState_emitReload work with v.spill_slot
3. **No ABI integration** - call args placed manually instead of via ABI module
4. **No phi resolution** - phi nodes not properly converted to copies
5. **No fall-through optimization** - always emits explicit branches

**THIS IS WHY cot0 has so many bugs** - The codegen assumes regalloc works perfectly, but regalloc doesn't emit spill/reload code, leading to crashes on anything that spills.

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

**NAMING PARITY COMPLETE (2026-01-22)** - All functions renamed to MachOWriter_* pattern.

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `macho_writer_init(w, ...)` | `MachOWriter.init()` | Same |
| `macho_add_code(w, bytes, len)` | `MachOWriter.addCode()` | Same |
| `macho_add_string(w, s, len) i64` | `MachOWriter.addString()` | Same |
| `macho_add_symbol(w, name, len, val, sect, ext) i64` | `MachOWriter.addSymbol()` | Same |
| `macho_add_reloc(w, offset, sym, type, pcrel)` | — | cot0-only |
| `MachOWriter_write(w) i64` | `MachOWriter.write()` | Same |
| `RelocInfo_make(sym, pcrel, len, ext, type) i64` | `RelocationInfo.makeInfo()` | Same |
| `MachO_isMagic(magic) bool` | — | cot0-only |
| `MachO_isValidFileType(type) bool` | — | cot0-only |
| `MachO_paddingForAlign(offset, align) i64` | `alignTo()` | Same |
| `MachO_alignUp(offset, align) i64` | — | cot0-only |
| `MachOWriter_outByte(w, b)` | — | cot0-only (writer abstraction) |
| `MachOWriter_outU32(w, val)` | — | cot0-only (writer abstraction) |
| `MachOWriter_outU64(w, val)` | — | cot0-only (writer abstraction) |
| `MachOWriter_outZeros(w, n)` | — | cot0-only (writer abstraction) |
| `MachOWriter_outBytes(w, src, len)` | — | cot0-only (writer abstraction) |
| `MachOWriter_writeMachHeader(w, ncmds, size)` | — | cot0-only (integrated in Zig) |
| `MachOWriter_writeSegmentCmd(w, vmsize, ...)` | — | cot0-only (integrated in Zig) |
| `MachOWriter_writeSection(w, name, ...)` | — | cot0-only (integrated in Zig) |
| `MachOWriter_writeSymtabCmd(w, ...)` | — | cot0-only (integrated in Zig) |
| `MachOWriter_writeReloc(w, r)` | — | cot0-only (integrated in Zig) |
| `MachOWriter_writeNlist64(w, sym)` | — | cot0-only (integrated in Zig) |
| — | `MachOWriter.deinit()` | Missing in cot0 (uses global arrays) |
| `MachOWriter_addData()` | `MachOWriter.addData()` | Same |
| `MachOWriter_addStringLiteral()` | `MachOWriter.addStringLiteral()` | Same |
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

### 7.5 src/ssa/debug.zig

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

### 7.6 src/ssa/compile.zig

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

### 7.7 src/ssa/passes/lower.zig

| Function | Purpose |
|----------|---------|
| `lowerOp(op, aux_int)` | Map generic op to ARM64 op |
| `canEncodeImm12(value)` | Check 12-bit immediate |
| `canEncodeImm12Shifted(value)` | Check shifted immediate |
| `lower(alloc, f)` | Lower all ops in function |

### 7.8 src/ssa/passes/schedule.zig

| Function | Purpose |
|----------|---------|
| `getScore(v, is_control)` | Compute scheduling priority |
| `schedule(f)` | Schedule values before regalloc |
| `scheduleBlock(alloc, block, f)` | Schedule single block |

### 7.9 src/ssa/passes/expand_calls.zig

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

### 7.10 src/ssa/passes/decompose.zig

| Function | Purpose |
|----------|---------|
| `decompose(f, type_reg)` | Transform 16-byte to 8-byte values |
| `decomposeBlock(f, block, reg)` | Process single block |
| `decomposeConstString(f, block, idx, v)` | Decompose const_string |
| `decomposeLoad(f, block, idx, v)` | Decompose 16-byte load |
| `decomposeStringPhi(f, block, idx, v)` | Decompose string phi |
| `decomposeStore(f, block, idx, v)` | Decompose 16-byte store |
| `getTypeSize(type_idx, type_reg)` | Get type size in bytes |

### 7.11 src/codegen/generic.zig

| Function | Purpose |
|----------|---------|
| `GenericCodeGen.init(alloc)` | Initialize generic codegen |
| `GenericCodeGen.deinit(self)` | Clean up resources |
| `GenericCodeGen.generate(self, f, writer)` | Generate pseudo-assembly |

---

## Summary Statistics

**⚠️ AUDIT COMPLETED 2026-01-22 - Line counts reveal MASSIVE gaps:**

| File | cot0 Lines | Zig Lines | Ratio | Notes |
|------|------------|-----------|-------|-------|
| main.cot | ~1500 | ~400 | 375% | cot0 has 1000+ lines of global array declarations |
| token.cot/zig | 280 | 460 | 61% | Has Token_string(); Missing StaticStringMap |
| scanner.cot/zig | 338 | 753 | 45% | Missing interpolation, error reporting, block comments |
| ast.cot/zig | 1131 | 743 | 152% | MORE lines but LESS type safety (generic fields) |
| parser.cot/zig | 1659 | 1644 | 101% | Similar but missing lookahead, recursion limit |
| types.cot/zig | 930 | 835 | 111% | Added TypeInfo_isPrimitive/fitsInRegs/needsReg/registerCount |
| checker.cot/zig | 745 | 1990 | **37%** | Missing expression caching, validation |
| ir.cot/zig | 715 | 1705 | **42%** | Missing CFG, phi infrastructure |
| lower.cot/zig | 2622 | 2684 | 98% | BUT has BUG-049 workaround code |
| op.cot/zig | 283 | 1569 | **18%** | Missing 120+ ARM64 ops |
| value.cot/zig | 240 | 673 | **36%** | Missing Aux union, Location |
| func.cot/zig | 366 | 650 | **56%** | Missing pooling, verification |
| liveness.cot/zig | 590 | 938 | **63%** | Missing interference, live ranges |
| regalloc.cot/zig | ~500 | 1184 | **42%** | **FIXED**: Now emits spill/reload code via genssa |
| codegen | ~1350 | 3529 | **38%** | **IMPROVED**: Has emit_reload/emit_spill helpers |
| macho.cot/zig | 726 | 641 | 113% | Added addData, addStringLiteral |

**TOTAL cot0: ~12,000 lines vs Zig: ~20,000 lines = 60%**

| Category | Status | Critical Issues |
|----------|--------|-----------------|
| Frontend | DIFFERENT | Uses PTYPE encoding hack, global arrays, workaround code in lower.cot |
| SSA | **IMPROVED** | 42% of regalloc, spill/reload NOW WORKING, still missing coalescing |
| Codegen | **IMPROVED** | 38% of codegen, has emit_reload/emit_spill, still missing some ops |
| Infrastructure | **MISSING** | No passes (lower, schedule, expand_calls, decompose), no debug |

### Key Findings (2026-01-22 FULL AUDIT)

**⚠️ CRITICAL: cot0 is NOT the same as Zig compiler - it's a HACKED TOGETHER APPROXIMATION ⚠️**

1. **cot0 uses FUNDAMENTALLY different architecture:**
   - Global arrays with hardcoded limits vs Zig's allocator-based design
   - PTYPE encoding hack (10=ptr, 10000=array, 100000=slice) vs proper TypeRegistry
   - Generic field0-field5 structs vs tagged unions with named fields
   - Procedural functions vs methods on structs

2. **cot0 SSA infrastructure status (partially fixed 2026-01-22):**
   - **FIXED: regalloc now emits spill/reload code** via genssa helpers
   - **FIXED: codegen has emit_reload/emit_spill** for spilled values
   - Still missing: interference graph, phi resolution, live range splitting
   - Tests passing: spill test (20 vars), recursion (fib(10)), basic arithmetic

3. **cot0 has WORKAROUND code instead of proper SSA passes:**
   - `lower_binary`: 60+ lines of BUG-049 manual spilling
   - `lower_call`: 150+ lines of manual arg tracking + two-pass spill
   - `lower_var_decl`: PTYPE range checks instead of type_reg.sizeOf()
   - `lower_index`: Wrong pointer type check (PTYPE_PTR_BASE vs TypeRegistry)

4. **cot0 is missing entire subsystems:**
   - No SSA passes: lower.zig, schedule.zig, expand_calls.zig, decompose.zig
   - No debug infrastructure: debug.zig, compile.zig
   - No error reporting: ErrorReporter, ErrorCode
   - No source tracking: Source, Span, Pos

5. **Line count comparison is MISLEADING:**
   - cot0 lower.cot is 98% of Zig's size BUT has 200+ lines of workaround code
   - cot0 ast.cot is 152% of Zig's size BUT has LESS type safety
   - cot0 main.cot is 375% of Zig's size due to global array declarations

**CONCLUSION: cot0 is approximately 60% complete but missing the most important 40%** - the register allocation and codegen infrastructure that makes compiled code actually work.

### To Fix cot0

**The solution is NOT to keep adding workarounds. The solution is to copy Zig's architecture.**

#### Priority 1: Fix Register Allocation ✅ DONE (2026-01-22)
```
Problem: regalloc.cot didn't emit spill/reload code
Fix APPLIED:
  - assign_reg() now sets Value.reg
  - spill_reg() now sets Value.spill_slot
  - stackalloc.cot converts slot numbers to offsets
  - genssa.cot has emit_reload() and emit_spill() helpers
Result: Tests passing - spill_test (20 vars), recursion, basic arithmetic
```

#### Priority 2: Fix External Function Calls (NEXT BLOCKER)
```
Problem: println and other external calls crash
Likely cause: External function relocations or string handling in cot0
Next: Debug why println calls cause segfault
Result: Spilled values will be loaded before use
```

#### Priority 3: Remove Workaround Code
```
Problem: lower.cot has BUG-049 manual spilling (200+ lines)
Fix: Delete manual spill code in lowerBinary, lowerCall
Result: Cleaner code, proper SSA handling
```

#### Priority 4: Fix Type System
```
Problem: Uses PTYPE encoding hack instead of TypeRegistry
Fix: Change `if type_handle >= PTYPE_PTR_BASE` to `TypeRegistry_isPointer(pool, type_handle)`
Result: Correct type handling for pointers, arrays, slices
```

#### Priority 5: Add Missing SSA Passes
```
Problem: No lower.zig, schedule.zig, expand_calls.zig, decompose.zig
Fix: Copy these passes from src/ssa/passes/
Result: Proper SSA transformations before codegen
```

**DO NOT:**
- Add more workaround code to lower.cot
- Skip features because they're broken
- Guess at fixes without reading Zig's implementation first

### Path to Self-Hosting

Completed:
- Dominator analysis (dom.cot)
- ABI handling for calling conventions (abi.cot)
- Stack allocation pass (stackalloc.cot)

Still needed:
1. Error handling infrastructure (errors.zig equivalent)
2. Source tracking (source.zig equivalent)
3. SSA passes (lower, schedule, expand_calls, decompose)
4. Pass infrastructure (compile.zig, debug.zig)
5. Better register allocation with coalescing
6. Integration of new modules into compilation pipeline

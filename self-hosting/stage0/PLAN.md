# Stage 0: Minimal Self-Hosting Compiler

**Goal**: The absolute minimum cot code that can compile itself.

---

## Architecture Overview

Stage 0 follows bootstrap-0.2's **separated pass** architecture:

```
Source (.cot)
    │
    ▼ scanner_s0.cot
Tokens
    │
    ▼ parser_s0.cot
AST (minimal nodes)
    │
    ▼ checker_s0.cot
Typed AST
    │
    ▼ lower_s0.cot
IR (simple ops)
    │
    ▼ ssagen_s0.cot
SSA (values, blocks)
    │
    ▼ regalloc_s0.cot  ← SEPARATE PASS (key difference from bootstrap)
SSA with locations
    │
    ▼ codegen_s0.cot
Machine code bytes
    │
    ▼ object_s0.cot
Mach-O executable
```

---

## File Inventory

### Core Data Types (shared)

#### `types_s0.cot`
Minimal type system.

```cot
// Type indices (interned)
type TypeIndex = i64

// Basic types only for stage 0
const TYPE_VOID: TypeIndex = 0
const TYPE_BOOL: TypeIndex = 1
const TYPE_I64: TypeIndex = 2
const TYPE_U8: TypeIndex = 3
const TYPE_STRING: TypeIndex = 4  // ptr + len

// Type info structure
struct TypeInfo {
    kind: u8,        // 0=basic, 1=ptr, 2=array, 3=struct, 4=enum, 5=func
    size: i64,       // Size in bytes
    align: i64,      // Alignment
    aux: i64,        // Extra info (element type for ptr/array, field count for struct)
}
```

**Complexity**: ~100 lines

---

### Frontend

#### `token_s0.cot`
Token types and structure.

```cot
enum TokenKind: u8 {
    // Literals
    int_lit,
    string_lit,
    char_lit,

    // Identifiers and keywords
    ident,
    kw_fn,
    kw_var,
    kw_const,
    kw_if,
    kw_else,
    kw_while,
    kw_return,
    kw_struct,
    kw_enum,
    kw_true,
    kw_false,
    kw_and,
    kw_or,
    kw_not,

    // Operators
    plus,
    minus,
    star,
    slash,
    percent,
    amp,
    pipe,
    caret,
    tilde,
    lt,
    gt,
    eq,
    bang,
    lshift,
    rshift,

    // Multi-char operators
    eq_eq,
    bang_eq,
    lt_eq,
    gt_eq,
    arrow,
    colon,

    // Delimiters
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    comma,
    semicolon,
    dot,

    // Special
    eof,
    invalid,
}

struct Token {
    kind: TokenKind,
    start: i64,      // Offset in source
    len: i64,        // Length
    line: i64,       // Line number
}
```

**Complexity**: ~80 lines

---

#### `scanner_s0.cot`
Tokenizer.

```cot
struct Scanner {
    source: string,
    pos: i64,
    line: i64,
}

fn scannerInit(source: string) Scanner { ... }
fn scannerNext(s: *Scanner) Token { ... }
fn scannerPeek(s: *Scanner) Token { ... }

// Internal helpers
fn isDigit(c: u8) bool { ... }
fn isAlpha(c: u8) bool { ... }
fn isAlnum(c: u8) bool { ... }
fn scanNumber(s: *Scanner) Token { ... }
fn scanIdent(s: *Scanner) Token { ... }
fn scanString(s: *Scanner) Token { ... }
fn scanChar(s: *Scanner) Token { ... }
fn skipWhitespace(s: *Scanner) void { ... }
fn skipComment(s: *Scanner) void { ... }
fn matchKeyword(text: string) TokenKind { ... }
```

**Source**: Adapt from `bootstrap/src/bootstrap/scanner_boot.cot`
**Complexity**: ~300 lines

---

#### `ast_s0.cot`
Minimal AST nodes.

```cot
type NodeIndex = i64
const NULL_NODE: NodeIndex = -1

enum NodeKind: u8 {
    // Literals
    int_lit,
    string_lit,
    bool_lit,

    // Expressions
    ident,
    binary,
    unary,
    call,
    field,
    index,

    // Statements
    var_decl,
    assign,
    if_stmt,
    while_stmt,
    return_stmt,
    block,
    expr_stmt,

    // Declarations
    fn_decl,
    struct_decl,
    enum_decl,

    // Types
    type_basic,
    type_ptr,
    type_array,
}

struct AstNode {
    kind: NodeKind,
    // Payload varies by kind - use aux fields
    aux0: i64,       // First aux (e.g., int value, string index)
    aux1: i64,       // Second aux
    aux2: i64,       // Third aux
    left: NodeIndex, // Left child
    right: NodeIndex,// Right child
    type_idx: TypeIndex,
    span_start: i64,
    span_end: i64,
}
```

**Complexity**: ~150 lines

---

#### `parser_s0.cot`
Recursive descent parser.

```cot
struct Parser {
    scanner: Scanner,
    current: Token,
    nodes: [4096]AstNode,  // Fixed-size for stage 0
    node_count: i64,
    source: string,
    // String table for identifiers
    strings: [1024]string,
    string_count: i64,
}

fn parserInit(source: string) Parser { ... }
fn parse(p: *Parser) NodeIndex { ... }  // Returns root (file node)

// Declarations
fn parseDecl(p: *Parser) NodeIndex { ... }
fn parseFnDecl(p: *Parser) NodeIndex { ... }
fn parseStructDecl(p: *Parser) NodeIndex { ... }
fn parseEnumDecl(p: *Parser) NodeIndex { ... }

// Statements
fn parseStmt(p: *Parser) NodeIndex { ... }
fn parseVarDecl(p: *Parser) NodeIndex { ... }
fn parseIfStmt(p: *Parser) NodeIndex { ... }
fn parseWhileStmt(p: *Parser) NodeIndex { ... }
fn parseReturnStmt(p: *Parser) NodeIndex { ... }
fn parseBlock(p: *Parser) NodeIndex { ... }

// Expressions
fn parseExpr(p: *Parser) NodeIndex { ... }
fn parseBinaryExpr(p: *Parser, min_prec: i64) NodeIndex { ... }
fn parseUnaryExpr(p: *Parser) NodeIndex { ... }
fn parsePrimaryExpr(p: *Parser) NodeIndex { ... }
fn parseCallExpr(p: *Parser, callee: NodeIndex) NodeIndex { ... }

// Types
fn parseType(p: *Parser) NodeIndex { ... }

// Helpers
fn advance(p: *Parser) void { ... }
fn expect(p: *Parser, kind: TokenKind) bool { ... }
fn match(p: *Parser, kind: TokenKind) bool { ... }
fn addNode(p: *Parser, node: AstNode) NodeIndex { ... }
fn internString(p: *Parser, s: string) i64 { ... }
```

**Source**: Adapt from `bootstrap/src/bootstrap/parser_boot.cot`
**Complexity**: ~600 lines

---

#### `checker_s0.cot`
Minimal type checking.

```cot
struct Checker {
    nodes: *[4096]AstNode,
    node_count: i64,
    // Symbol table
    symbols: [256]Symbol,
    symbol_count: i64,
    // Type registry
    types: [256]TypeInfo,
    type_count: i64,
    // Scope stack (simple for stage 0)
    scope_depth: i64,
}

struct Symbol {
    name: string,
    type_idx: TypeIndex,
    kind: u8,        // 0=local, 1=param, 2=global, 3=func
    slot: i64,       // Local slot or param index
    scope: i64,      // Scope depth where declared
}

fn checkerInit(nodes: *[4096]AstNode, count: i64) Checker { ... }
fn check(c: *Checker, root: NodeIndex) bool { ... }

fn checkDecl(c: *Checker, idx: NodeIndex) bool { ... }
fn checkStmt(c: *Checker, idx: NodeIndex) bool { ... }
fn checkExpr(c: *Checker, idx: NodeIndex) TypeIndex { ... }
fn resolveIdent(c: *Checker, name: string) *Symbol { ... }
fn declareSymbol(c: *Checker, name: string, type_idx: TypeIndex, kind: u8) i64 { ... }
fn enterScope(c: *Checker) void { ... }
fn exitScope(c: *Checker) void { ... }
```

**Complexity**: ~400 lines

---

### Middle-End

#### `ir_s0.cot`
Intermediate representation.

```cot
enum IROp: u8 {
    // Constants
    const_int,
    const_bool,
    const_string,

    // Memory
    load_local,
    store_local,
    load_param,
    addr_local,
    load_field,
    store_field,
    load_index,
    store_index,

    // Arithmetic
    add,
    sub,
    mul,
    div,
    mod,
    neg,

    // Bitwise
    bit_and,
    bit_or,
    bit_xor,
    bit_not,
    shl,
    shr,

    // Comparison
    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    // Logical
    log_and,
    log_or,
    log_not,

    // Control flow
    call,
    ret,
    jump,
    branch,
}

struct IRNode {
    op: IROp,
    type_idx: TypeIndex,
    args: [4]i64,    // Node indices or immediate values
    arg_count: i64,
    aux: i64,        // Extra data (local idx, field offset, etc.)
    aux_str: string, // String data (function name, etc.)
}

struct IRFunc {
    name: string,
    nodes: [1024]IRNode,
    node_count: i64,
    locals: [64]Local,
    local_count: i64,
    param_count: i64,
    return_type: TypeIndex,
    frame_size: i64,
}

struct Local {
    name: string,
    type_idx: TypeIndex,
    offset: i64,
    size: i64,
}
```

**Complexity**: ~200 lines

---

#### `lower_s0.cot`
AST → IR lowering.

```cot
struct Lowerer {
    ast_nodes: *[4096]AstNode,
    checker: *Checker,
    func: IRFunc,
    current_block: i64,
}

fn lowererInit(nodes: *[4096]AstNode, checker: *Checker) Lowerer { ... }
fn lowerFunc(l: *Lowerer, fn_idx: NodeIndex) IRFunc { ... }

fn lowerStmt(l: *Lowerer, idx: NodeIndex) void { ... }
fn lowerExpr(l: *Lowerer, idx: NodeIndex) i64 { ... }  // Returns IR node index
fn lowerVarDecl(l: *Lowerer, idx: NodeIndex) void { ... }
fn lowerAssign(l: *Lowerer, idx: NodeIndex) void { ... }
fn lowerIf(l: *Lowerer, idx: NodeIndex) void { ... }
fn lowerWhile(l: *Lowerer, idx: NodeIndex) void { ... }
fn lowerReturn(l: *Lowerer, idx: NodeIndex) void { ... }
fn lowerCall(l: *Lowerer, idx: NodeIndex) i64 { ... }

fn emit(l: *Lowerer, node: IRNode) i64 { ... }
fn addLocal(l: *Lowerer, name: string, type_idx: TypeIndex, size: i64) i64 { ... }
```

**Complexity**: ~400 lines

---

### Backend

#### `ssa_s0.cot`
SSA data structures.

```cot
type ValueID = i64
type BlockID = i64

const NULL_VALUE: ValueID = -1
const NULL_BLOCK: BlockID = -1

enum SSAOp: u8 {
    // Same as IROp but with phi
    const_int,
    const_bool,
    const_string,

    phi,  // SSA phi node

    // ... (same ops as IR)

    // ARM64-specific (added by lowering pass)
    arm_mov,
    arm_add,
    arm_sub,
    arm_mul,
    arm_sdiv,
    arm_cmp,
    arm_cset,
    arm_b,
    arm_bl,
    arm_ret,
}

struct Value {
    id: ValueID,
    op: SSAOp,
    type_idx: TypeIndex,
    args: [4]ValueID,
    arg_count: i64,
    aux_int: i64,
    aux_str: string,
    uses: i64,           // Use count for DCE
    loc: Location,       // Assigned by regalloc
}

struct Location {
    kind: u8,            // 0=none, 1=reg, 2=stack, 3=imm
    reg: u8,             // Register number (if kind=reg)
    offset: i64,         // Stack offset (if kind=stack)
    imm: i64,            // Immediate value (if kind=imm)
}

struct Block {
    id: BlockID,
    values: [256]Value,
    value_count: i64,
    succs: [2]BlockID,
    succ_count: i64,
    preds: [8]BlockID,
    pred_count: i64,
}

struct SSAFunc {
    name: string,
    blocks: [64]Block,
    block_count: i64,
    entry: BlockID,
    frame_size: i64,
    params: [8]TypeIndex,
    param_count: i64,
    return_type: TypeIndex,
}
```

**Complexity**: ~250 lines

---

#### `ssagen_s0.cot`
IR → SSA conversion.

```cot
struct SSAGen {
    ir_func: *IRFunc,
    ssa_func: SSAFunc,
    current_block: BlockID,
    // Maps IR node indices to SSA values
    value_map: [1024]ValueID,
}

fn ssagenInit(ir: *IRFunc) SSAGen { ... }
fn convert(g: *SSAGen) SSAFunc { ... }

fn convertNode(g: *SSAGen, ir_idx: i64) ValueID { ... }
fn emitValue(g: *SSAGen, v: Value) ValueID { ... }
fn newBlock(g: *SSAGen) BlockID { ... }
fn sealBlock(g: *SSAGen, b: BlockID) void { ... }
fn addPhi(g: *SSAGen, b: BlockID, type_idx: TypeIndex) ValueID { ... }
```

**Complexity**: ~300 lines

---

#### `regalloc_s0.cot`
**KEY FILE**: Separate register allocation pass.

This is what makes bootstrap-0.2 cleaner - regalloc is independent of codegen.

```cot
struct RegAlloc {
    func: *SSAFunc,
    // Liveness info
    live_in: [64][32]bool,   // live_in[block][value] - simplified
    live_out: [64][32]bool,
    // Register state
    reg_contents: [32]ValueID,  // What value is in each reg
    reg_free: [32]bool,         // Is register available
    // Spill slots
    next_spill: i64,
}

// ARM64 registers for stage 0
const REG_X0: u8 = 0
const REG_X1: u8 = 1
// ... up to REG_X28
const REG_FP: u8 = 29
const REG_LR: u8 = 30
const REG_SP: u8 = 31

// Caller-saved: x0-x15
// Callee-saved: x19-x28

fn regallocInit(func: *SSAFunc) RegAlloc { ... }
fn allocate(r: *RegAlloc) void { ... }

// Core allocation
fn allocateBlock(r: *RegAlloc, b: BlockID) void { ... }
fn allocateValue(r: *RegAlloc, v: *Value) void { ... }

// Liveness
fn computeLiveness(r: *RegAlloc) void { ... }
fn isLiveOut(r: *RegAlloc, b: BlockID, v: ValueID) bool { ... }

// Register management
fn allocReg(r: *RegAlloc) u8 { ... }
fn freeReg(r: *RegAlloc, reg: u8) void { ... }
fn spillReg(r: *RegAlloc, reg: u8) void { ... }
fn getValueLoc(r: *RegAlloc, v: ValueID) Location { ... }
```

**Source**: Based on `bootstrap-0.2/src/ssa/regalloc.zig` (784 lines in Zig)
**Complexity**: ~400 lines in cot

---

#### `codegen_s0.cot`
SSA → Machine code.

With regalloc separate, codegen is simpler - just emit instructions.

```cot
struct CodeGen {
    func: *SSAFunc,
    code: [16384]u8,   // Output buffer
    code_len: i64,
    // Relocations for calls
    relocs: [64]Reloc,
    reloc_count: i64,
}

struct Reloc {
    offset: i64,
    target: string,
}

fn codegenInit(func: *SSAFunc) CodeGen { ... }
fn generate(cg: *CodeGen) void { ... }

fn genBlock(cg: *CodeGen, b: BlockID) void { ... }
fn genValue(cg: *CodeGen, v: *Value) void { ... }

// ARM64 instruction emission (simplified)
fn emitMov(cg: *CodeGen, rd: u8, imm: i64) void { ... }
fn emitMovReg(cg: *CodeGen, rd: u8, rm: u8) void { ... }
fn emitAdd(cg: *CodeGen, rd: u8, rn: u8, rm: u8) void { ... }
fn emitSub(cg: *CodeGen, rd: u8, rn: u8, rm: u8) void { ... }
fn emitMul(cg: *CodeGen, rd: u8, rn: u8, rm: u8) void { ... }
fn emitSDiv(cg: *CodeGen, rd: u8, rn: u8, rm: u8) void { ... }
fn emitLdr(cg: *CodeGen, rt: u8, base: u8, offset: i64) void { ... }
fn emitStr(cg: *CodeGen, rt: u8, base: u8, offset: i64) void { ... }
fn emitCmp(cg: *CodeGen, rn: u8, rm: u8) void { ... }
fn emitCset(cg: *CodeGen, rd: u8, cond: u8) void { ... }
fn emitB(cg: *CodeGen, offset: i64) void { ... }
fn emitBCond(cg: *CodeGen, cond: u8, offset: i64) void { ... }
fn emitBl(cg: *CodeGen, offset: i64) void { ... }
fn emitRet(cg: *CodeGen) void { ... }

// Helpers
fn emit32(cg: *CodeGen, inst: i64) void { ... }
fn loadToReg(cg: *CodeGen, reg: u8, loc: Location) void { ... }
```

**Complexity**: ~500 lines

---

#### `object_s0.cot`
Mach-O output.

```cot
struct ObjectFile {
    text: [65536]u8,      // Code section
    text_len: i64,
    data: [4096]u8,       // Data section (strings)
    data_len: i64,
    symbols: [128]Symbol,
    sym_count: i64,
    relocs: [256]Reloc,
    reloc_count: i64,
}

struct MachOSymbol {
    name: string,
    section: u8,
    offset: i64,
    size: i64,
    external: bool,
}

fn objectInit() ObjectFile { ... }
fn addText(obj: *ObjectFile, code: *[16384]u8, len: i64) i64 { ... }
fn addData(obj: *ObjectFile, data: string) i64 { ... }
fn addSymbol(obj: *ObjectFile, name: string, sec: u8, offset: i64) void { ... }
fn addReloc(obj: *ObjectFile, offset: i64, target: string) void { ... }
fn writeMachO(obj: *ObjectFile, path: string) bool { ... }

// Mach-O structure helpers
fn writeMachOHeader(obj: *ObjectFile, buf: *[65536]u8, pos: *i64) void { ... }
fn writeLoadCommands(obj: *ObjectFile, buf: *[65536]u8, pos: *i64) void { ... }
fn writeSections(obj: *ObjectFile, buf: *[65536]u8, pos: *i64) void { ... }
fn writeSymtab(obj: *ObjectFile, buf: *[65536]u8, pos: *i64) void { ... }
fn writeRelocations(obj: *ObjectFile, buf: *[65536]u8, pos: *i64) void { ... }
```

**Source**: Adapt from `bootstrap/src/bootstrap/codegen/object_boot.cot`
**Complexity**: ~400 lines

---

### Entry Point

#### `main_s0.cot`
Driver and CLI.

```cot
fn main() i64 {
    // Get input file from args
    var argc: i64 = @argsCount()
    if argc < 2 {
        return 1
    }

    var input_path: string = @argsGet(1)
    var output_path: string = "a.out"

    // Check for -o flag
    if argc >= 4 {
        if @argsGet(2) == "-o" {
            output_path = @argsGet(3)
        }
    }

    // Read source
    var source: string = @fileRead(input_path)
    if len(source) == 0 {
        return 2
    }

    // Parse
    var parser: Parser = parserInit(source)
    var root: NodeIndex = parse(&parser)
    if root == NULL_NODE {
        return 3
    }

    // Type check
    var checker: Checker = checkerInit(&parser.nodes, parser.node_count)
    if not check(&checker, root) {
        return 4
    }

    // Generate code for each function
    var obj: ObjectFile = objectInit()

    // TODO: iterate functions, lower, convert to SSA, regalloc, codegen

    // Write output
    if not writeMachO(&obj, output_path) {
        return 5
    }

    return 0
}
```

**Complexity**: ~200 lines

---

## Total Complexity Estimate

| File | Lines |
|------|-------|
| types_s0.cot | ~100 |
| token_s0.cot | ~80 |
| scanner_s0.cot | ~300 |
| ast_s0.cot | ~150 |
| parser_s0.cot | ~600 |
| checker_s0.cot | ~400 |
| ir_s0.cot | ~200 |
| lower_s0.cot | ~400 |
| ssa_s0.cot | ~250 |
| ssagen_s0.cot | ~300 |
| regalloc_s0.cot | ~400 |
| codegen_s0.cot | ~500 |
| object_s0.cot | ~400 |
| main_s0.cot | ~200 |
| **TOTAL** | **~4,280 lines** |

This is significantly smaller than the current bootstrap (~10,000+ lines) because:
1. No error messages (just return codes)
2. No x86_64 support
3. Fixed-size arrays instead of dynamic lists
4. Minimal features
5. Cleaner architecture (separated regalloc)

---

## Language Features Needed Before Stage 0

Before we can write these files, bootstrap-0.2 needs:

| Feature | Status | Priority |
|---------|--------|----------|
| Arrays [N]T | TODO | **P0** |
| Array indexing | TODO | **P0** |
| Enums | TODO | **P0** |
| Pointers | TODO | **P0** |
| Bitwise ops | TODO | **P0** |
| Logical and/or | TODO | **P0** |
| Strings (done) | ✅ | - |
| Structs (done) | ✅ | - |

Once Tier 2-5 from bootstrap-0.2's STATUS.md are complete, we can start writing stage0 files.

---

## Validation Strategy

1. **Unit test each file** in isolation using bootstrap-0.2 compiler
2. **Integration test** the pipeline end-to-end
3. **Bootstrap test**: cot0 compiles itself
4. **Fixpoint test**: cot0-compiled-by-cot0 produces identical binary

```bash
# The ultimate test
./zig-out/bin/cot stage0/*.cot -o cot0
./cot0 stage0/*.cot -o cot0_v2
./cot0_v2 stage0/*.cot -o cot0_v3
diff cot0_v2 cot0_v3  # Must be identical!
```

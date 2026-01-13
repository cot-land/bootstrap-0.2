# Data Structures - Go to Zig Translation

This document provides exact Zig equivalents of Go's compiler data structures.
Every field is documented with its purpose and Go source reference.

## 1. SSA Value (Go: ssa/value.go)

```zig
/// SSA Value - represents a single operation's result.
/// Go reference: cmd/compile/internal/ssa/value.go lines 20-50
pub const Value = struct {
    /// Unique ID within function, densely allocated starting at 1
    id: ID,

    /// Operation type - defines what this value computes
    op: Op,

    /// Result type - CRITICAL for instruction selection
    /// Use type.size() to select ldrb/ldrh/ldr/etc.
    type_idx: TypeIndex,

    /// Integer auxiliary data:
    /// - For constants: the constant value (floats via @bitCast)
    /// - For loads/stores: offset
    /// - For calls: stack adjustment
    /// Sign-extended even for unsigned values
    aux_int: i64 = 0,

    /// Generic auxiliary data:
    /// - For OpConstString: string value
    /// - For OpAddr/OpLoad: symbol reference
    /// - For OpCall: AuxCall with ABI info
    aux: ?*Aux = null,

    /// Arguments to this operation (values this depends on)
    /// Length determined by Op's argLen property
    args: []const *Value = &.{},

    /// Inline storage for first 3 args (optimization)
    /// Slice into this for small arg lists
    args_storage: [3]?*Value = .{ null, null, null },

    /// Containing basic block
    block: *Block,

    /// Source position for debugging/error messages
    pos: Pos = .{},

    /// Usage count - CRITICAL for optimization
    /// Incremented when added to Args or Block.Controls
    /// When 0, value can be eliminated
    uses: i32 = 0,

    /// True if in function's constant cache
    /// Must clear before modifying value
    in_cache: bool = false,

    // Methods

    /// Add argument, incrementing its use count
    pub fn addArg(self: *Value, arg: *Value) void {
        arg.uses += 1;
        // Append to args (use inline storage if possible)
    }

    /// Reset all arguments, decrementing use counts
    pub fn resetArgs(self: *Value) void {
        for (self.args) |arg| {
            arg.uses -= 1;
        }
        self.args = &.{};
    }

    /// Check if value is a constant
    pub fn isConst(self: *const Value) bool {
        return switch (self.op) {
            .const_int, .const_bool, .const_string, .const_nil => true,
            else => false,
        };
    }
};

pub const ID = u32;
pub const TypeIndex = u32;
```

## 2. SSA Block (Go: ssa/block.go)

```zig
/// Basic block in the control flow graph.
/// Go reference: cmd/compile/internal/ssa/block.go lines 15-65
pub const Block = struct {
    /// Unique ID within function
    id: ID,

    /// Block kind - determines control flow semantics
    kind: BlockKind,

    /// Successor edges (CFG out-edges)
    /// BlockPlain: 1 successor
    /// BlockIf: 2 successors (true, false)
    /// BlockRet: 0 successors
    succs: []Edge = &.{},

    /// Predecessor edges (CFG in-edges)
    preds: []Edge = &.{},

    /// Control values (up to 2)
    /// BlockIf: controls[0] = condition
    /// BlockRet: controls[0] = memory value (optional)
    controls: [2]?*Value = .{ null, null },

    /// All values computed in this block
    /// Unordered until schedule pass runs
    values: std.ArrayList(*Value),

    /// Containing function
    func: *Func,

    /// Position of control statement
    pos: Pos = .{},

    /// Branch prediction hint
    /// 1 = likely take first successor
    /// -1 = likely take second successor
    /// 0 = unknown
    likely: i8 = 0,

    /// Are flags live at block end?
    /// Set by flagalloc pass
    flags_live_at_end: bool = false,

    /// Inline storage for small edge lists
    succs_storage: [2]Edge = undefined,
    preds_storage: [4]Edge = undefined,
    vals_storage: [9]?*Value = .{null} ** 9,

    // Methods

    /// Number of non-nil controls
    pub fn numControls(self: *const Block) usize {
        if (self.controls[1] != null) return 2;
        if (self.controls[0] != null) return 1;
        return 0;
    }

    /// Set single control value
    pub fn setControl(self: *Block, v: *Value) void {
        if (self.controls[0]) |old| old.uses -= 1;
        if (self.controls[1]) |old| old.uses -= 1;
        self.controls[0] = v;
        self.controls[1] = null;
        v.uses += 1;
    }

    /// Add edge to successor block
    pub fn addEdgeTo(self: *Block, succ: *Block) void {
        const succ_idx = succ.preds.len;
        const self_idx = self.succs.len;
        // Add edge in both directions with back-references
        self.succs = append(self.succs, Edge{ .b = succ, .i = succ_idx });
        succ.preds = append(succ.preds, Edge{ .b = self, .i = self_idx });
    }
};

/// CFG edge with bidirectional reference.
/// Maintains invariant: b.Succs[i] = {target, j} ⟺ target.Preds[j] = {b, i}
pub const Edge = struct {
    b: *Block,
    i: usize,  // Index of reverse edge
};

pub const BlockKind = enum {
    invalid,
    plain,      // Unconditional jump to single successor
    if_,        // Conditional branch based on controls[0]
    ret,        // Return from function
    exit,       // Function exit (panic, etc.)
    // Architecture-specific block kinds added here
    arm64_cbz,  // Compare and branch if zero
    arm64_cbnz, // Compare and branch if not zero
    // ... etc
};
```

## 3. SSA Function (Go: ssa/func.go)

```zig
/// SSA function representation.
/// Go reference: cmd/compile/internal/ssa/func.go lines 15-100
pub const Func = struct {
    /// Architecture configuration (shared across functions)
    config: *const Config,

    /// Function name (e.g., "main", "(*Foo).Bar")
    name: []const u8,

    /// Function type signature
    type_idx: TypeIndex,

    /// All basic blocks
    blocks: std.ArrayList(*Block),

    /// Entry block (first in blocks list)
    entry: *Block,

    /// Block ID allocator
    bid: IDAllocator = .{},

    /// Value ID allocator
    vid: IDAllocator = .{},

    /// Register allocation results (filled by regalloc pass)
    /// Indexed by Value.id
    reg_alloc: []Location = &.{},

    /// Named values for debugging
    /// Maps LocalSlot -> list of SSA values
    named_values: std.AutoHashMap(LocalSlot, std.ArrayList(*Value)),

    /// Free value pool (for reuse)
    free_values: ?*Value = null,

    /// Free block pool (for reuse)
    free_blocks: ?*Block = null,

    /// Constant cache: aux_int -> list of constant values
    /// Prevents duplicate constants
    constants: std.AutoHashMap(i64, std.ArrayList(*Value)),

    /// Cached analysis results (invalidate on CFG changes)
    cached_postorder: ?[]*Block = null,
    cached_idom: ?[]*Block = null,

    /// Compilation state
    scheduled: bool = false,  // Values in final order?
    laidout: bool = false,    // Blocks ordered?

    // Methods

    /// Allocate new value (reuses from pool if available)
    pub fn newValue(self: *Func, op: Op, type_idx: TypeIndex, block: *Block, pos: Pos) *Value {
        var v: *Value = undefined;
        if (self.free_values) |fv| {
            v = fv;
            self.free_values = @ptrCast(fv.args_storage[0]);
            v.* = .{};
        } else {
            v = self.allocator.create(Value) catch unreachable;
        }
        v.id = self.vid.next();
        v.op = op;
        v.type_idx = type_idx;
        v.block = block;
        v.pos = pos;
        return v;
    }

    /// Allocate new block
    pub fn newBlock(self: *Func, kind: BlockKind) *Block {
        // Similar pool-based allocation
    }

    /// Return value to pool
    pub fn freeValue(self: *Func, v: *Value) void {
        v.args_storage[0] = @ptrCast(self.free_values);
        self.free_values = v;
    }

    /// Invalidate cached CFG analysis (call after modifying edges)
    pub fn invalidateCFG(self: *Func) void {
        self.cached_postorder = null;
        self.cached_idom = null;
    }

    /// Get postorder traversal (cached)
    pub fn postorder(self: *Func) []*Block {
        if (self.cached_postorder) |po| return po;
        // Compute and cache postorder traversal
        self.cached_postorder = computePostorder(self);
        return self.cached_postorder.?;
    }

    /// Get immediate dominators (cached)
    pub fn idom(self: *Func) []*Block {
        if (self.cached_idom) |idom_| return idom_;
        // Compute using Lengauer-Tarjan algorithm
        self.cached_idom = computeIdom(self);
        return self.cached_idom.?;
    }
};

pub const IDAllocator = struct {
    next_id: ID = 1,

    pub fn next(self: *IDAllocator) ID {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};
```

## 4. Operation Definition (Go: ssa/op.go)

```zig
/// SSA operation type.
/// Each operation has associated metadata in op_info table.
pub const Op = enum(u16) {
    // Generic operations (machine-independent)
    invalid,

    // Constants
    const_bool,
    const_int,
    const_float,
    const_string,
    const_nil,

    // Arithmetic
    add,
    sub,
    mul,
    div,
    mod,
    neg,

    // Bitwise
    and_,
    or_,
    xor,
    not,
    shl,
    shr,

    // Comparison
    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    // Memory
    load,
    store,
    addr,
    local_addr,

    // Control flow
    phi,
    copy,
    arg,
    call,
    tail_call,

    // ARM64-specific operations (lowered form)
    arm64_add,
    arm64_sub,
    arm64_mul,
    arm64_movd,
    arm64_movd_load,
    arm64_movd_store,
    arm64_cmp,
    arm64_bl,
    // ... more ARM64 ops

    pub fn info(self: Op) OpInfo {
        return op_info_table[@intFromEnum(self)];
    }
};

/// Operation metadata.
/// Go reference: cmd/compile/internal/ssa/op.go lines 35-75
pub const OpInfo = struct {
    /// Display name
    name: []const u8,

    /// Register constraints
    reg: RegInfo,

    /// What aux/aux_int mean
    aux_type: AuxType,

    /// Number of arguments (-1 = variable)
    arg_len: i8,

    /// Target assembler opcode (for lowered ops)
    asm_op: ?AsmOp = null,

    /// Flags
    generic: bool = false,           // Machine-independent?
    rematerializable: bool = false,  // Can recompute cheaply?
    commutative: bool = false,       // Arg order doesn't matter?
    result_in_arg0: bool = false,    // Output in same reg as arg[0]?
    clobber_flags: bool = false,     // Modifies flags register?
    call: bool = false,              // Is function call?
    has_side_effects: bool = false,  // Can't eliminate?
};

/// Register constraints for an operation.
pub const RegInfo = struct {
    /// Input register constraints
    inputs: []const InputInfo = &.{},

    /// Output register constraints
    outputs: []const OutputInfo = &.{},

    /// Registers clobbered by this operation
    clobbers: RegMask = 0,
};

pub const InputInfo = struct {
    idx: usize,      // Argument index
    regs: RegMask,   // Allowed registers
};

pub const OutputInfo = struct {
    idx: usize,      // Output index (usually 0)
    regs: RegMask,   // Allowed registers
};

pub const AuxType = enum {
    none,
    bool_,
    int8,
    int16,
    int32,
    int64,
    float32,
    float64,
    string,
    sym,         // Symbol reference
    sym_off,     // Symbol + offset
    call,        // AuxCall for function calls
    type_,       // Type reference
};
```

## 5. Register Allocation Structures (Go: ssa/regalloc.go)

```zig
/// Location where a value lives.
/// Go reference: cmd/compile/internal/ssa/location.go
pub const Location = union(enum) {
    register: Register,
    stack: LocalSlot,
    pair: LocPair,
    none,

    pub fn format(self: Location) []const u8 {
        return switch (self) {
            .register => |r| r.name,
            .stack => |s| s.format(),
            .pair => |p| p.format(),
            .none => "none",
        };
    }
};

/// Physical register.
pub const Register = struct {
    num: u8,       // Dense numbering (0, 1, 2, ...)
    obj_num: i16,  // Architecture-specific number
    name: []const u8,
};

/// Stack slot for a local variable.
pub const LocalSlot = struct {
    name: []const u8,
    type_idx: TypeIndex,
    offset: i64,
    /// If decomposed from larger value
    split_of: ?*LocalSlot = null,
    split_offset: i64 = 0,
};

/// Register mask - bit i set means register i is in the set.
pub const RegMask = u64;

/// Value state during register allocation.
/// Go reference: cmd/compile/internal/ssa/regalloc.go lines 155-180
pub const ValState = struct {
    /// Registers currently holding this value
    regs: RegMask = 0,

    /// Use count remaining
    uses: i32 = 0,

    /// Spill slot (if spilled)
    spill: ?*Value = null,

    /// Spill is used?
    spill_used: bool = false,

    /// Restore destinations (registers to load into)
    restore_min: i32 = 0,
    restore_max: i32 = 0,
};

/// Per-register state during allocation.
/// Go reference: cmd/compile/internal/ssa/regalloc.go lines 200-220
pub const RegState = struct {
    /// Value currently in this register (null if free)
    v: ?*Value = null,

    /// Copy of value (for moves between registers)
    c: ?*Value = null,

    /// Is this a temporary allocation?
    tmp: bool = false,
};

/// Use record for a value.
/// Forms decreasing-distance linked list (critical for spilling!).
/// Go reference: cmd/compile/internal/ssa/regalloc.go lines 250-270
pub const Use = struct {
    /// Distance from start of block (decreasing in list)
    dist: i32,

    /// Position in block's value list
    pos: Pos,

    /// Next use record (closer to current position)
    next: ?*Use = null,
};

/// Register allocator state.
/// Go reference: cmd/compile/internal/ssa/regalloc.go lines 300-400
pub const RegAllocState = struct {
    /// SSA function being allocated
    f: *Func,

    /// Per-value state
    values: []ValState,

    /// Per-register state
    regs: [NUM_REGS]RegState = .{.{}} ** NUM_REGS,

    /// Desired registers for values (propagated hints)
    desired: std.AutoHashMap(ID, RegMask),

    /// Use chains per value
    uses: std.AutoHashMap(ID, *Use),

    /// Live values at current point
    live: std.AutoHashMap(ID, void),

    /// Current block being processed
    cur_block: ?*Block = null,

    /// Allocator for Use records
    use_allocator: std.mem.Allocator,

    // Methods defined in regalloc.zig
};
```

## 6. Frontend Structures

### Token (Go: syntax/tokens.go)

```zig
/// Token types.
/// Go reference: cmd/compile/internal/syntax/tokens.go
pub const Token = enum(u8) {
    // Literals and identifiers
    eof,
    name,       // Identifier
    literal,    // Number, string, char

    // Operators
    add,        // +
    sub,        // -
    mul,        // *
    div,        // /
    mod,        // %
    and_,       // &
    or_,        // |
    xor,        // ^
    shl,        // <<
    shr,        // >>
    add_assign, // +=
    sub_assign, // -=
    // ... etc

    // Comparison
    eq,         // ==
    ne,         // !=
    lt,         // <
    le,         // <=
    gt,         // >
    ge,         // >=

    // Delimiters
    lparen,     // (
    rparen,     // )
    lbrace,     // {
    rbrace,     // }
    lbracket,   // [
    rbracket,   // ]
    comma,      // ,
    semicolon,  // ;
    colon,      // :
    dot,        // .

    // Keywords
    kw_fn,
    kw_struct,
    kw_enum,
    kw_union,
    kw_if,
    kw_else,
    kw_while,
    kw_for,
    kw_return,
    kw_var,
    kw_const,
    kw_true,
    kw_false,
    kw_null,
    kw_and,
    kw_or,
    // ... etc
};

pub const LitKind = enum {
    int,
    float,
    string,
    char,
};
```

### AST Nodes (Go: syntax/nodes.go)

```zig
/// AST node interface.
/// All nodes have a position and can be visited.
pub const Node = union(enum) {
    // Expressions
    literal: *LiteralExpr,
    name: *NameExpr,
    binary: *BinaryExpr,
    unary: *UnaryExpr,
    call: *CallExpr,
    index: *IndexExpr,
    field: *FieldExpr,

    // Statements
    expr_stmt: *ExprStmt,
    assign: *AssignStmt,
    if_stmt: *IfStmt,
    while_stmt: *WhileStmt,
    for_stmt: *ForStmt,
    return_stmt: *ReturnStmt,
    block: *BlockStmt,

    // Declarations
    var_decl: *VarDecl,
    fn_decl: *FnDecl,
    struct_decl: *StructDecl,

    pub fn pos(self: Node) Pos {
        return switch (self) {
            inline else => |n| n.pos,
        };
    }
};

/// Expression: binary operation.
pub const BinaryExpr = struct {
    pos: Pos,
    op: Token,
    left: *Node,
    right: *Node,
};

/// Statement: if/else.
pub const IfStmt = struct {
    pos: Pos,
    cond: *Node,
    then_body: []Node,
    else_body: ?[]Node,
};

/// Declaration: function.
pub const FnDecl = struct {
    pos: Pos,
    name: []const u8,
    params: []Param,
    return_type: ?TypeExpr,
    body: ?[]Node,  // null for extern declarations
};
```

### Scope (Go: types2/scope.go)

```zig
/// Hierarchical scope for name resolution.
/// Go reference: cmd/compile/internal/types2/scope.go
pub const Scope = struct {
    /// Parent scope (null for universe scope)
    parent: ?*Scope,

    /// Child scopes
    children: std.ArrayList(*Scope),

    /// Named objects in this scope
    elems: std.StringHashMap(*Object),

    /// Scope extent in source
    pos: Pos,
    end: Pos,

    /// Is this a function scope?
    is_func: bool = false,

    /// Insert object, return existing if duplicate
    pub fn insert(self: *Scope, obj: *Object) ?*Object {
        const result = self.elems.getOrPut(obj.name) catch unreachable;
        if (result.found_existing) {
            return result.value_ptr.*;
        }
        result.value_ptr.* = obj;
        return null;
    }

    /// Lookup in this scope only (not parent)
    pub fn lookup(self: *const Scope, name: []const u8) ?*Object {
        return self.elems.get(name);
    }

    /// Lookup in scope chain
    pub fn lookupParent(self: *const Scope, name: []const u8) ?*Object {
        var s: ?*const Scope = self;
        while (s) |scope| {
            if (scope.lookup(name)) |obj| return obj;
            s = scope.parent;
        }
        return null;
    }
};

/// Named entity (variable, function, type, etc.).
pub const Object = struct {
    name: []const u8,
    kind: ObjectKind,
    type_idx: TypeIndex,
    pos: Pos,
    scope: *Scope,  // Scope containing this object

    /// For variables: stack offset
    /// For functions: nothing (use symbol)
    data: ObjectData = .{ .none = {} },
};

pub const ObjectKind = enum {
    variable,
    constant,
    func,
    type_name,
    param,
};

pub const ObjectData = union(enum) {
    none,
    var_offset: i64,
    const_value: i64,
};
```

## 7. IR Structures (Go: ir/node.go, expr.go, stmt.go)

```zig
/// IR operation type (different from SSA ops - higher level).
pub const IROp = enum {
    // Expressions
    literal,
    name,
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_,
    or_,
    addr_of,
    deref,
    index,
    field,
    call,

    // Statements
    assign,
    if_,
    for_,
    while_,
    switch_,
    return_,
    block,
    decl,
};

/// IR node (tree-based, not SSA).
/// Go reference: cmd/compile/internal/ir/node.go
pub const IRNode = struct {
    op: IROp,
    type_idx: TypeIndex,
    pos: Pos,

    /// Init statements (side effects before expression)
    init: []IRNode = &.{},

    /// Operation-specific data
    data: IRData,
};

pub const IRData = union(enum) {
    /// Binary operation: add, sub, cmp, etc.
    binary: struct {
        left: *IRNode,
        right: *IRNode,
    },

    /// Unary operation: neg, not, addr, deref
    unary: struct {
        operand: *IRNode,
    },

    /// Literal value
    literal: struct {
        value: i64,
        kind: LitKind,
    },

    /// Variable/function name
    name: struct {
        obj: *Object,
    },

    /// Function call
    call: struct {
        func: *IRNode,
        args: []*IRNode,
    },

    /// Assignment: x = y
    assign: struct {
        lhs: *IRNode,
        rhs: *IRNode,
        is_def: bool,  // := vs =
    },

    /// If statement
    if_: struct {
        cond: *IRNode,
        then_body: []IRNode,
        else_body: ?[]IRNode,
    },

    /// For loop
    for_: struct {
        init: ?*IRNode,
        cond: ?*IRNode,
        post: ?*IRNode,
        body: []IRNode,
    },

    /// Return statement
    return_: struct {
        values: []*IRNode,
    },

    /// Block
    block: struct {
        stmts: []IRNode,
    },
};
```

## 8. Architecture Configuration (Go: ssa/config.go)

```zig
/// Architecture-specific configuration.
/// Go reference: cmd/compile/internal/ssa/config.go
pub const Config = struct {
    /// Architecture name ("arm64", "amd64", etc.)
    arch: []const u8,

    /// Pointer size in bytes (4 or 8)
    ptr_size: u8,

    /// Register size in bytes
    reg_size: u8,

    /// All registers for this architecture
    registers: []const Register,

    /// General-purpose register mask
    gp_reg_mask: RegMask,

    /// Floating-point register mask
    fp_reg_mask: RegMask,

    /// Frame pointer register (-1 if none)
    fp_reg: i8,

    /// Link register (-1 if not GP)
    link_reg: i8,

    /// Integer parameter registers
    int_param_regs: []const u8,

    /// Float parameter registers
    float_param_regs: []const u8,

    /// Block lowering function
    lower_block: *const fn (*Block) void,

    /// Value lowering function
    lower_value: *const fn (*Value) void,

    /// Flags
    big_endian: bool = false,
    unaligned_ok: bool = false,
};

/// ARM64 configuration
pub const arm64_config = Config{
    .arch = "arm64",
    .ptr_size = 8,
    .reg_size = 8,
    .registers = &arm64_registers,
    .gp_reg_mask = 0x7FFFFFFF,  // x0-x30
    .fp_reg_mask = 0xFFFFFFFF00000000,  // v0-v31
    .fp_reg = 29,   // x29 = frame pointer
    .link_reg = 30, // x30 = link register
    .int_param_regs = &.{ 0, 1, 2, 3, 4, 5, 6, 7 },  // x0-x7
    .float_param_regs = &.{ 0, 1, 2, 3, 4, 5, 6, 7 },  // v0-v7
    .lower_block = arm64LowerBlock,
    .lower_value = arm64LowerValue,
};

const arm64_registers = [_]Register{
    .{ .num = 0, .obj_num = 0, .name = "x0" },
    .{ .num = 1, .obj_num = 1, .name = "x1" },
    // ... x2-x28
    .{ .num = 29, .obj_num = 29, .name = "fp" },
    .{ .num = 30, .obj_num = 30, .name = "lr" },
    .{ .num = 31, .obj_num = 31, .name = "sp" },
};
```

## Usage Patterns

### Creating SSA Values

```zig
// In SSA conversion
fn buildAdd(state: *State, left: *Value, right: *Value) *Value {
    const v = state.func.newValue(.add, left.type_idx, state.cur_block, state.pos);
    v.addArg(left);
    v.addArg(right);
    return v;
}
```

### Building Control Flow

```zig
// Building an if statement
fn buildIf(state: *State, cond: *Value, then_body: []IRNode, else_body: ?[]IRNode) void {
    const b_then = state.func.newBlock(.plain);
    const b_else = state.func.newBlock(.plain);
    const b_end = state.func.newBlock(.plain);

    // Emit conditional branch
    state.curBlock().kind = .if_;
    state.curBlock().setControl(cond);
    state.curBlock().addEdgeTo(b_then);
    state.curBlock().addEdgeTo(b_else);

    // Generate then branch
    state.startBlock(b_then);
    for (then_body) |stmt| state.stmt(stmt);
    state.curBlock().addEdgeTo(b_end);

    // Generate else branch
    state.startBlock(b_else);
    if (else_body) |stmts| {
        for (stmts) |stmt| state.stmt(stmt);
    }
    state.curBlock().addEdgeTo(b_end);

    // Continue after both branches
    state.startBlock(b_end);
}
```

### Register Allocation Spilling

```zig
// When we need a register but all are occupied
fn spillValue(state: *RegAllocState, reg: u8) void {
    const v = state.regs[reg].v orelse return;
    const vs = &state.values[v.id];

    // Create spill slot if needed
    if (vs.spill == null) {
        vs.spill = state.f.newValue(.store_reg, v.type_idx, v.block, v.pos);
        vs.spill.?.addArg(v);
    }

    vs.spill_used = true;
    vs.regs &= ~(@as(RegMask, 1) << reg);
    state.regs[reg].v = null;
}
```

This document provides the foundation for implementing Go's exact compiler architecture in Zig.

//! Strongly Typed Intermediate Representation
//!
//! This IR follows Go's cmd/compile/internal/ir patterns combined with
//! bootstrap's strongly-typed design. Each operation has explicit, named
//! fields rather than generic args arrays - eliminating bugs where args
//! are misinterpreted between pipeline phases.
//!
//! Design principles (from Go + bootstrap):
//! 1. Op discriminator drives type switching
//! 2. Every operation has explicit, named fields
//! 3. Distinct index types prevent mixing (LocalIdx vs NodeIndex)
//! 4. Compile-time errors for wrong field access
//!
//! Reference: ~/learning/go/src/cmd/compile/internal/ir/

const std = @import("std");
const types = @import("types.zig");
const source = @import("source.zig");

const TypeIndex = types.TypeIndex;
const TypeRegistry = types.TypeRegistry;
const Span = source.Span;
const Pos = source.Pos;
const Allocator = std.mem.Allocator;

// ============================================================================
// Distinct Index Types - Prevents Mixing (from bootstrap's design)
// ============================================================================

/// Index into the node pool. Represents a computed value (result of an operation).
pub const NodeIndex = u32;
pub const null_node: NodeIndex = std.math.maxInt(NodeIndex);

/// Index into the local variable table. NOT a computed value.
pub const LocalIdx = u32;
pub const null_local: LocalIdx = std.math.maxInt(LocalIdx);

/// Index into the block pool.
pub const BlockIndex = u32;
pub const null_block: BlockIndex = std.math.maxInt(BlockIndex);

/// Index into the function's parameter list.
pub const ParamIdx = u32;

/// Index into the string literal table.
pub const StringIdx = u32;

/// Index into the global variable table.
pub const GlobalIdx = u32;

// ============================================================================
// Binary and Unary Operation Kinds (mirrors Go's Op granularity)
// ============================================================================

/// Binary arithmetic and comparison operations.
/// Corresponds to Go's OADD, OSUB, OEQ, etc.
pub const BinaryOp = enum(u8) {
    // Arithmetic
    add,
    sub,
    mul,
    div,
    mod,

    // Comparison
    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    // Logical
    @"and",
    @"or",

    // Bitwise
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,

    /// Check if this is a comparison operation (returns bool).
    pub fn isComparison(self: BinaryOp) bool {
        return switch (self) {
            .eq, .ne, .lt, .le, .gt, .ge => true,
            else => false,
        };
    }

    /// Check if this is an arithmetic operation.
    pub fn isArithmetic(self: BinaryOp) bool {
        return switch (self) {
            .add, .sub, .mul, .div, .mod => true,
            else => false,
        };
    }

    /// Check if this is a logical operation.
    pub fn isLogical(self: BinaryOp) bool {
        return switch (self) {
            .@"and", .@"or" => true,
            else => false,
        };
    }

    /// Check if this is a bitwise operation.
    pub fn isBitwise(self: BinaryOp) bool {
        return switch (self) {
            .bit_and, .bit_or, .bit_xor, .shl, .shr => true,
            else => false,
        };
    }
};

/// Unary operations.
/// Corresponds to Go's ONEG, ONOT, etc.
pub const UnaryOp = enum(u8) {
    neg, // Arithmetic negation: -x
    not, // Logical not: !x
    bit_not, // Bitwise not: ~x
};

// ============================================================================
// Typed Operation Payloads (from bootstrap's strongly-typed design)
// Following Go's pattern of concrete node types with named fields
// ============================================================================

/// Payload for integer constant. (Go: BasicLit with Kind=INT)
pub const ConstInt = struct {
    value: i64,
};

/// Payload for float constant. (Go: BasicLit with Kind=FLOAT)
pub const ConstFloat = struct {
    value: f64,
};

/// Payload for boolean constant. (Go: OTRUE/OFALSE)
pub const ConstBool = struct {
    value: bool,
};

/// Payload for string literal reference. (Go: BasicLit with Kind=STRING)
pub const ConstSlice = struct {
    string_index: StringIdx,
};

/// Reference to a local variable by index. (Go: ONAME for locals)
pub const LocalRef = struct {
    local_idx: LocalIdx,
};

/// Reference to a global variable. (Go: ONAME for globals)
pub const GlobalRef = struct {
    global_idx: GlobalIdx,
    name: []const u8, // For debug/linking
};

/// Binary operation with two operands. (Go: BinaryExpr)
pub const Binary = struct {
    op: BinaryOp,
    left: NodeIndex,
    right: NodeIndex,
};

/// Unary operation with one operand. (Go: UnaryExpr)
pub const Unary = struct {
    op: UnaryOp,
    operand: NodeIndex,
};

/// Store to a local variable. (Go: OASSIGN to local)
pub const StoreLocal = struct {
    local_idx: LocalIdx,
    value: NodeIndex,
};

/// Load field from local struct variable. (Go: ODOT on local)
pub const FieldLocal = struct {
    local_idx: LocalIdx,
    field_idx: u32,
    offset: i64,
};

/// Store to field in local struct variable. (Go: OASSIGN to field)
pub const StoreLocalField = struct {
    local_idx: LocalIdx,
    field_idx: u32,
    offset: i64,
    value: NodeIndex,
};

/// Store to field through computed struct address.
pub const StoreField = struct {
    base: NodeIndex, // Address of struct
    field_idx: u32,
    offset: i64, // Field offset from base
    value: NodeIndex,
};

/// Load field from computed struct value. (Go: ODOT on expression)
pub const FieldValue = struct {
    base: NodeIndex,
    field_idx: u32,
    offset: i64,
};

/// Index into local array/slice. (Go: OINDEX on local)
pub const IndexLocal = struct {
    local_idx: LocalIdx,
    index: NodeIndex,
    elem_size: u32,
};

/// Index into computed array/slice value. (Go: OINDEX on expression)
pub const IndexValue = struct {
    base: NodeIndex,
    index: NodeIndex,
    elem_size: u32,
};

/// Store to local array element. (Go: arr[i] = x)
pub const StoreIndexLocal = struct {
    local_idx: LocalIdx,
    index: NodeIndex,
    value: NodeIndex,
    elem_size: u32,
};

/// Store to array element through computed address. (Go: arr[i] = x where arr is pointer)
pub const StoreIndexValue = struct {
    base: NodeIndex,
    index: NodeIndex,
    value: NodeIndex,
    elem_size: u32,
};

/// Slice operation on local. (Go: OSLICE on local)
pub const SliceLocal = struct {
    local_idx: LocalIdx,
    start: ?NodeIndex,
    end: ?NodeIndex,
    elem_size: u32,
};

/// Slice operation on computed value. (Go: OSLICE on expression)
pub const SliceValue = struct {
    base: NodeIndex,
    start: ?NodeIndex,
    end: ?NodeIndex,
    elem_size: u32,
};

/// Load through pointer stored in local. (Go: ODEREF on local ptr)
pub const PtrLoad = struct {
    ptr_local: LocalIdx,
};

/// Store through pointer stored in local. (Go: OASSIGN via ptr)
pub const PtrStore = struct {
    ptr_local: LocalIdx,
    value: NodeIndex,
};

/// Load field through pointer stored in local. (Go: ODOT via ptr)
pub const PtrField = struct {
    ptr_local: LocalIdx,
    field_idx: u32,
    offset: i64,
};

/// Store to field through pointer stored in local.
pub const PtrFieldStore = struct {
    ptr_local: LocalIdx,
    field_idx: u32,
    offset: i64,
    value: NodeIndex,
};

/// Load through computed pointer value. (Go: ODEREF)
pub const PtrLoadValue = struct {
    ptr: NodeIndex,
};

/// Store through computed pointer value.
pub const PtrStoreValue = struct {
    ptr: NodeIndex,
    value: NodeIndex,
};

/// Get address of local variable. (Go: OADDR)
pub const AddrLocal = struct {
    local_idx: LocalIdx,
};

/// Add constant offset to base address. (Go: ptr arithmetic)
pub const AddrOffset = struct {
    base: NodeIndex,
    offset: i64,
};

/// Compute array element address. (Go: &arr[i])
pub const AddrIndex = struct {
    base: NodeIndex,
    index: NodeIndex,
    elem_size: u32,
};

/// Function call. (Go: CallExpr / OCALL)
pub const Call = struct {
    /// Function name (for linking)
    func_name: []const u8,
    /// Arguments to the function
    args: []const NodeIndex,
    /// Is this a builtin call?
    is_builtin: bool,
};

/// Return from function. (Go: ReturnStmt)
pub const Return = struct {
    /// Value to return, or null for void return
    value: ?NodeIndex,
};

/// Unconditional jump. (Go: goto / generated)
pub const Jump = struct {
    target: BlockIndex,
};

/// Conditional branch. (Go: IfStmt lowered)
pub const Branch = struct {
    condition: NodeIndex,
    then_block: BlockIndex,
    else_block: BlockIndex,
};

/// Phi node source (value from a predecessor block).
pub const PhiSource = struct {
    block: BlockIndex,
    value: NodeIndex,
};

/// Phi node for SSA. (Go: generated during SSA)
pub const Phi = struct {
    sources: []const PhiSource,
};

/// Ternary select operation. (Go: OSELECT / conditional expr)
pub const Select = struct {
    condition: NodeIndex,
    then_value: NodeIndex,
    else_value: NodeIndex,
};

/// Type conversion. (Go: OCONV)
pub const Convert = struct {
    operand: NodeIndex,
    from_type: TypeIndex,
    to_type: TypeIndex,
};

/// List operations (dynamic arrays)
pub const ListNew = struct {
    elem_type: TypeIndex,
};

pub const ListPush = struct {
    handle: NodeIndex,
    value: NodeIndex,
};

pub const ListGet = struct {
    handle: NodeIndex,
    index: NodeIndex,
};

pub const ListSet = struct {
    handle: NodeIndex,
    index: NodeIndex,
    value: NodeIndex,
};

pub const ListLen = struct {
    handle: NodeIndex,
};

/// Map operations
pub const MapNew = struct {
    key_type: TypeIndex,
    value_type: TypeIndex,
};

pub const MapSet = struct {
    handle: NodeIndex,
    key: NodeIndex,
    value: NodeIndex,
};

pub const MapGet = struct {
    handle: NodeIndex,
    key: NodeIndex,
};

pub const MapHas = struct {
    handle: NodeIndex,
    key: NodeIndex,
};

/// String concatenation
pub const StrConcat = struct {
    left: NodeIndex,
    right: NodeIndex,
};

/// Union initialization
pub const UnionInit = struct {
    variant_idx: u32,
    payload: ?NodeIndex,
};

/// Get union tag
pub const UnionTag = struct {
    value: NodeIndex,
};

/// Get union payload
pub const UnionPayload = struct {
    variant_idx: u32,
    value: NodeIndex,
};

// ============================================================================
// The Node: A Tagged Union with Typed Payloads
// Following Go's Node interface pattern adapted to Zig's tagged union
// ============================================================================

/// An IR node represents a single operation with strongly typed operands.
/// The Data union ensures each operation can only access its own fields.
/// This is analogous to Go's Node interface with concrete implementations.
pub const Node = struct {
    /// Result type of this operation.
    type_idx: TypeIndex,
    /// Source location for error messages.
    span: Span,
    /// Block this node belongs to.
    block: BlockIndex,
    /// The operation and its typed payload.
    data: Data,

    /// The tagged union of all possible operations.
    /// Corresponds to Go's Op enum + concrete node types.
    pub const Data = union(enum) {
        // ========== Constants (Go: BasicLit) ==========
        const_int: ConstInt,
        const_float: ConstFloat,
        const_bool: ConstBool,
        const_null: void,
        const_slice: ConstSlice,

        // ========== Variable Access (Go: ONAME) ==========
        /// Reference to local variable value.
        local_ref: LocalRef,
        /// Reference to global variable.
        global_ref: GlobalRef,
        /// Get address of local variable.
        addr_local: AddrLocal,
        /// Load value from local.
        load_local: LocalRef,
        /// Store value to local.
        store_local: StoreLocal,

        // ========== Binary and Unary Operations ==========
        binary: Binary,
        unary: Unary,

        // ========== Struct Field Access (Go: ODOT) ==========
        /// Load field from local struct.
        field_local: FieldLocal,
        /// Store to field in local struct.
        store_local_field: StoreLocalField,
        /// Store to field through computed struct address.
        store_field: StoreField,
        /// Load field from computed struct value.
        field_value: FieldValue,

        // ========== Array/Slice Indexing (Go: OINDEX, OSLICE) ==========
        /// Index into local array/slice.
        index_local: IndexLocal,
        /// Index into computed array/slice.
        index_value: IndexValue,
        /// Store to local array element.
        store_index_local: StoreIndexLocal,
        /// Store to array element through computed address.
        store_index_value: StoreIndexValue,
        /// Create slice from local.
        slice_local: SliceLocal,
        /// Create slice from computed value.
        slice_value: SliceValue,

        // ========== Pointer Operations (Go: ODEREF, OADDR) ==========
        /// Load through pointer in local.
        ptr_load: PtrLoad,
        /// Store through pointer in local.
        ptr_store: PtrStore,
        /// Load field through pointer in local.
        ptr_field: PtrField,
        /// Store to field through pointer in local.
        ptr_field_store: PtrFieldStore,
        /// Load through computed pointer value.
        ptr_load_value: PtrLoadValue,
        /// Store through computed pointer value.
        ptr_store_value: PtrStoreValue,

        // ========== Address Arithmetic ==========
        /// Add constant offset to address.
        addr_offset: AddrOffset,
        /// Compute array element address.
        addr_index: AddrIndex,

        // ========== Control Flow (Go: statements) ==========
        call: Call,
        ret: Return,
        jump: Jump,
        branch: Branch,
        phi: Phi,
        select: Select,

        // ========== Conversions (Go: OCONV) ==========
        convert: Convert,

        // ========== List Operations ==========
        list_new: ListNew,
        list_push: ListPush,
        list_get: ListGet,
        list_set: ListSet,
        list_len: ListLen,
        list_free: ListLen,

        // ========== Map Operations ==========
        map_new: MapNew,
        map_set: MapSet,
        map_get: MapGet,
        map_has: MapHas,
        map_free: ListLen, // Uses handle field

        // ========== String Operations ==========
        str_concat: StrConcat,

        // ========== Union Operations ==========
        union_init: UnionInit,
        union_tag: UnionTag,
        union_payload: UnionPayload,

        // ========== Misc ==========
        nop: void,
    };

    /// Create a new node with the given data. (Go: New* constructors)
    pub fn init(data: Data, type_idx: TypeIndex, span: Span) Node {
        return .{
            .type_idx = type_idx,
            .span = span,
            .block = null_block,
            .data = data,
        };
    }

    /// Set the block for this node.
    pub fn withBlock(self: Node, block: BlockIndex) Node {
        var n = self;
        n.block = block;
        return n;
    }

    /// Check if this node is a terminator (ends a basic block).
    pub fn isTerminator(self: *const Node) bool {
        return switch (self.data) {
            .ret, .jump, .branch => true,
            else => false,
        };
    }

    /// Check if this node has side effects.
    pub fn hasSideEffects(self: *const Node) bool {
        return switch (self.data) {
            .store_local,
            .ptr_store,
            .ptr_store_value,
            .ptr_field_store,
            .store_local_field,
            .call,
            .ret,
            .jump,
            .branch,
            .list_new,
            .list_push,
            .list_set,
            .list_free,
            .map_new,
            .map_set,
            .map_free,
            => true,
            else => false,
        };
    }

    /// Check if this is a constant node.
    pub fn isConstant(self: *const Node) bool {
        return switch (self.data) {
            .const_int, .const_float, .const_bool, .const_null, .const_slice => true,
            else => false,
        };
    }
};

// ============================================================================
// Basic Block (Go: implicit in Func.Body, explicit during SSA)
// ============================================================================

/// A basic block is a sequence of operations with single entry/exit.
pub const Block = struct {
    /// Block index (for identification).
    index: BlockIndex,
    /// Predecessor blocks.
    preds: []BlockIndex,
    /// Successor blocks.
    succs: []BlockIndex,
    /// Nodes in this block (in order).
    nodes: []NodeIndex,
    /// Optional label for debugging.
    label: []const u8,

    pub fn init(index: BlockIndex) Block {
        return .{
            .index = index,
            .preds = &.{},
            .succs = &.{},
            .nodes = &.{},
            .label = "",
        };
    }
};

// ============================================================================
// Local Variable (Go: Name with Class=PAUTO/PPARAM)
// ============================================================================

/// A local variable in a function.
pub const Local = struct {
    /// Variable name.
    name: []const u8,
    /// Variable type.
    type_idx: TypeIndex,
    /// Is this variable mutable?
    mutable: bool,
    /// Is this a parameter?
    is_param: bool,
    /// Parameter index (if is_param).
    param_idx: ParamIdx,
    /// Size in bytes (computed from type).
    size: u32,
    /// Alignment requirement.
    alignment: u32,
    /// Stack frame offset (assigned during frame layout).
    offset: i32,

    pub fn init(name: []const u8, type_idx: TypeIndex, mutable: bool) Local {
        return .{
            .name = name,
            .type_idx = type_idx,
            .mutable = mutable,
            .is_param = false,
            .param_idx = 0,
            .size = 8,
            .alignment = 8,
            .offset = 0,
        };
    }

    pub fn initParam(name: []const u8, type_idx: TypeIndex, param_idx: ParamIdx, size: u32) Local {
        return .{
            .name = name,
            .type_idx = type_idx,
            .mutable = false,
            .is_param = true,
            .param_idx = param_idx,
            .size = size,
            .alignment = @min(size, 8),
            .offset = 0,
        };
    }

    pub fn initWithSize(name: []const u8, type_idx: TypeIndex, mutable: bool, size: u32) Local {
        return .{
            .name = name,
            .type_idx = type_idx,
            .mutable = mutable,
            .is_param = false,
            .param_idx = 0,
            .size = size,
            .alignment = @min(size, 8),
            .offset = 0,
        };
    }
};

// ============================================================================
// Function (Go: Func struct from func.go)
// ============================================================================

/// A function in the IR.
pub const Func = struct {
    /// Function name.
    name: []const u8,
    /// Function type (for signature).
    type_idx: TypeIndex,
    /// Return type.
    return_type: TypeIndex,
    /// Parameters (subset of locals).
    params: []const Local,
    /// Local variables (includes parameters).
    locals: []const Local,
    /// Basic blocks.
    blocks: []const Block,
    /// Entry block index.
    entry: BlockIndex,
    /// All nodes in the function.
    nodes: []const Node,
    /// Source span.
    span: Span,
    /// Stack frame size (computed during layout).
    frame_size: i32,
    /// String literals used by this function.
    string_literals: []const []const u8,

    pub fn getNode(self: *const Func, idx: NodeIndex) *const Node {
        return &self.nodes[idx];
    }

    pub fn getLocal(self: *const Func, idx: LocalIdx) *const Local {
        return &self.locals[idx];
    }

    pub fn getBlock(self: *const Func, idx: BlockIndex) *const Block {
        return &self.blocks[idx];
    }
};

// ============================================================================
// Function Builder (Go: implicit construction, we make it explicit)
// ============================================================================

/// Builder for constructing functions with proper ownership.
/// Provides convenience methods following Go's New* pattern.
pub const FuncBuilder = struct {
    allocator: Allocator,
    name: []const u8,
    type_idx: TypeIndex,
    return_type: TypeIndex,
    span: Span,

    locals: std.ArrayListUnmanaged(Local),
    blocks: std.ArrayListUnmanaged(Block),
    nodes: std.ArrayListUnmanaged(Node),
    string_literals: std.ArrayListUnmanaged([]const u8),
    current_block: BlockIndex,

    // Name to local index mapping
    local_map: std.StringHashMap(LocalIdx),

    pub fn init(allocator: Allocator, name: []const u8, type_idx: TypeIndex, return_type: TypeIndex, span: Span) FuncBuilder {
        var fb = FuncBuilder{
            .allocator = allocator,
            .name = name,
            .type_idx = type_idx,
            .return_type = return_type,
            .span = span,
            .locals = .{},
            .blocks = .{},
            .nodes = .{},
            .string_literals = .{},
            .current_block = 0,
            .local_map = std.StringHashMap(LocalIdx).init(allocator),
        };

        // Create entry block (block 0)
        fb.blocks.append(allocator, Block.init(0)) catch {};

        return fb;
    }

    pub fn deinit(self: *FuncBuilder) void {
        self.locals.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.string_literals.deinit(self.allocator);
        self.local_map.deinit();
    }

    // ========================================================================
    // Local Variable Management
    // ========================================================================

    /// Add a local variable, return its index.
    pub fn addLocal(self: *FuncBuilder, local: Local) !LocalIdx {
        const idx: LocalIdx = @intCast(self.locals.items.len);
        try self.locals.append(self.allocator, local);
        try self.local_map.put(local.name, idx);
        return idx;
    }

    /// Add a parameter with explicit size.
    pub fn addParam(self: *FuncBuilder, name: []const u8, type_idx: TypeIndex, size: u32) !LocalIdx {
        const idx: LocalIdx = @intCast(self.locals.items.len);
        const param_idx: ParamIdx = idx;
        try self.locals.append(self.allocator, Local.initParam(name, type_idx, param_idx, size));
        try self.local_map.put(name, idx);
        return idx;
    }

    /// Add a local variable with explicit size.
    pub fn addLocalWithSize(self: *FuncBuilder, name: []const u8, type_idx: TypeIndex, mutable: bool, size: u32) !LocalIdx {
        const idx: LocalIdx = @intCast(self.locals.items.len);
        try self.locals.append(self.allocator, Local.initWithSize(name, type_idx, mutable, size));
        try self.local_map.put(name, idx);
        return idx;
    }

    /// Look up a local by name.
    pub fn lookupLocal(self: *const FuncBuilder, name: []const u8) ?LocalIdx {
        return self.local_map.get(name);
    }

    // ========================================================================
    // Block Management
    // ========================================================================

    /// Create a new basic block.
    pub fn newBlock(self: *FuncBuilder, label: []const u8) !BlockIndex {
        const idx: BlockIndex = @intCast(self.blocks.items.len);
        var block = Block.init(idx);
        block.label = label;
        try self.blocks.append(self.allocator, block);
        return idx;
    }

    /// Set current block for emitting nodes.
    pub fn setBlock(self: *FuncBuilder, block: BlockIndex) void {
        self.current_block = block;
    }

    /// Get current block index.
    pub fn currentBlock(self: *const FuncBuilder) BlockIndex {
        return self.current_block;
    }

    /// Check if the current block needs a terminator instruction.
    /// Returns true if the block is empty or doesn't end with a terminator.
    pub fn needsTerminator(self: *const FuncBuilder) bool {
        const block_idx = self.current_block;
        const block = &self.blocks.items[block_idx];

        // Get nodes in this block
        var last_node_in_block: ?NodeIndex = null;
        for (self.nodes.items, 0..) |node, i| {
            if (node.block == block_idx) {
                last_node_in_block = @intCast(i);
            }
        }

        if (last_node_in_block) |idx| {
            const node = &self.nodes.items[idx];
            return !node.isTerminator();
        }

        // Empty block needs terminator
        _ = block;
        return true;
    }

    // ========================================================================
    // String Literals
    // ========================================================================

    /// Add a string literal, return its index.
    pub fn addStringLiteral(self: *FuncBuilder, str: []const u8) !StringIdx {
        const idx: StringIdx = @intCast(self.string_literals.items.len);
        try self.string_literals.append(self.allocator, str);
        return idx;
    }

    // ========================================================================
    // Node Emission
    // ========================================================================

    /// Emit a node to the current block.
    pub fn emit(self: *FuncBuilder, node: Node) !NodeIndex {
        const idx: NodeIndex = @intCast(self.nodes.items.len);
        var n = node;
        n.block = self.current_block;
        try self.nodes.append(self.allocator, n);

        // Add to current block's node list
        var block = &self.blocks.items[self.current_block];

        // Build new nodes list
        var nodes_list = std.ArrayListUnmanaged(NodeIndex){};
        defer nodes_list.deinit(self.allocator);
        for (block.nodes) |ni| {
            try nodes_list.append(self.allocator, ni);
        }
        try nodes_list.append(self.allocator, idx);

        // Free old block.nodes before replacing (if it was allocated)
        if (block.nodes.len > 0) {
            self.allocator.free(block.nodes);
        }

        block.nodes = try nodes_list.toOwnedSlice(self.allocator);

        return idx;
    }

    // ========================================================================
    // Convenience emit methods (Go's New* pattern)
    // ========================================================================

    /// Emit integer constant.
    pub fn emitConstInt(self: *FuncBuilder, value: i64, type_idx: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .const_int = .{ .value = value } }, type_idx, span));
    }

    /// Emit float constant.
    pub fn emitConstFloat(self: *FuncBuilder, value: f64, type_idx: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .const_float = .{ .value = value } }, type_idx, span));
    }

    /// Emit boolean constant.
    pub fn emitConstBool(self: *FuncBuilder, value: bool, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .const_bool = .{ .value = value } }, TypeRegistry.BOOL, span));
    }

    /// Emit null constant.
    pub fn emitConstNull(self: *FuncBuilder, type_idx: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .const_null = {} }, type_idx, span));
    }

    /// Emit string literal reference.
    pub fn emitConstSlice(self: *FuncBuilder, string_index: StringIdx, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .const_slice = .{ .string_index = string_index } }, TypeRegistry.STRING, span));
    }

    /// Emit load from local variable.
    pub fn emitLoadLocal(self: *FuncBuilder, local_idx: LocalIdx, type_idx: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .load_local = .{ .local_idx = local_idx } }, type_idx, span));
    }

    /// Emit store to local variable.
    pub fn emitStoreLocal(self: *FuncBuilder, local_idx: LocalIdx, value: NodeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .store_local = .{ .local_idx = local_idx, .value = value } }, TypeRegistry.VOID, span));
    }

    /// Emit address of local.
    pub fn emitAddrLocal(self: *FuncBuilder, local_idx: LocalIdx, type_idx: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .addr_local = .{ .local_idx = local_idx } }, type_idx, span));
    }

    /// Emit binary operation.
    pub fn emitBinary(self: *FuncBuilder, op: BinaryOp, left: NodeIndex, right: NodeIndex, type_idx: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .binary = .{ .op = op, .left = left, .right = right } }, type_idx, span));
    }

    /// Emit unary operation.
    pub fn emitUnary(self: *FuncBuilder, op: UnaryOp, operand: NodeIndex, type_idx: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .unary = .{ .op = op, .operand = operand } }, type_idx, span));
    }

    /// Emit field access from local struct.
    pub fn emitFieldLocal(self: *FuncBuilder, local_idx: LocalIdx, field_idx: u32, offset: i64, type_idx: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .field_local = .{ .local_idx = local_idx, .field_idx = field_idx, .offset = offset } }, type_idx, span));
    }

    /// Emit store to field in local struct.
    pub fn emitStoreLocalField(self: *FuncBuilder, local_idx: LocalIdx, field_idx: u32, offset: i64, value: NodeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .store_local_field = .{ .local_idx = local_idx, .field_idx = field_idx, .offset = offset, .value = value } }, TypeRegistry.VOID, span));
    }

    /// Emit store to field through computed address (for nested field access).
    pub fn emitStoreField(self: *FuncBuilder, base: NodeIndex, field_idx: u32, offset: i64, value: NodeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .store_field = .{ .base = base, .field_idx = field_idx, .offset = offset, .value = value } }, TypeRegistry.VOID, span));
    }

    /// Emit field access from computed value.
    pub fn emitFieldValue(self: *FuncBuilder, base: NodeIndex, field_idx: u32, offset: i64, type_idx: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .field_value = .{ .base = base, .field_idx = field_idx, .offset = offset } }, type_idx, span));
    }

    /// Emit index into local array/slice.
    pub fn emitIndexLocal(self: *FuncBuilder, local_idx: LocalIdx, index: NodeIndex, elem_size: u32, type_idx: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .index_local = .{ .local_idx = local_idx, .index = index, .elem_size = elem_size } }, type_idx, span));
    }

    /// Emit index into computed array/slice.
    pub fn emitIndexValue(self: *FuncBuilder, base: NodeIndex, index: NodeIndex, elem_size: u32, type_idx: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .index_value = .{ .base = base, .index = index, .elem_size = elem_size } }, type_idx, span));
    }

    /// Emit store to local array element.
    pub fn emitStoreIndexLocal(self: *FuncBuilder, local_idx: LocalIdx, index: NodeIndex, value: NodeIndex, elem_size: u32, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .store_index_local = .{ .local_idx = local_idx, .index = index, .value = value, .elem_size = elem_size } }, TypeRegistry.VOID, span));
    }

    /// Emit store to array element through computed address (for array parameters).
    pub fn emitStoreIndexValue(self: *FuncBuilder, base: NodeIndex, index: NodeIndex, value: NodeIndex, elem_size: u32, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .store_index_value = .{ .base = base, .index = index, .value = value, .elem_size = elem_size } }, TypeRegistry.VOID, span));
    }

    /// Emit slice from local array.
    pub fn emitSliceLocal(self: *FuncBuilder, local_idx: LocalIdx, start: ?NodeIndex, end: ?NodeIndex, elem_size: u32, type_idx: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .slice_local = .{ .local_idx = local_idx, .start = start, .end = end, .elem_size = elem_size } }, type_idx, span));
    }

    /// Emit slice from computed value.
    pub fn emitSliceValue(self: *FuncBuilder, base: NodeIndex, start: ?NodeIndex, end: ?NodeIndex, elem_size: u32, type_idx: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .slice_value = .{ .base = base, .start = start, .end = end, .elem_size = elem_size } }, type_idx, span));
    }

    /// Emit pointer load through local.
    pub fn emitPtrLoad(self: *FuncBuilder, ptr_local: LocalIdx, type_idx: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .ptr_load = .{ .ptr_local = ptr_local } }, type_idx, span));
    }

    /// Emit pointer store through local.
    pub fn emitPtrStore(self: *FuncBuilder, ptr_local: LocalIdx, value: NodeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .ptr_store = .{ .ptr_local = ptr_local, .value = value } }, TypeRegistry.VOID, span));
    }

    /// Emit pointer load through computed pointer value.
    pub fn emitPtrLoadValue(self: *FuncBuilder, ptr: NodeIndex, type_idx: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .ptr_load_value = .{ .ptr = ptr } }, type_idx, span));
    }

    /// Emit pointer store through computed pointer value.
    pub fn emitPtrStoreValue(self: *FuncBuilder, ptr: NodeIndex, value: NodeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .ptr_store_value = .{ .ptr = ptr, .value = value } }, TypeRegistry.VOID, span));
    }

    /// Emit function call.
    pub fn emitCall(self: *FuncBuilder, func_name: []const u8, args: []const NodeIndex, is_builtin: bool, type_idx: TypeIndex, span: Span) !NodeIndex {
        const duped_args = try self.allocator.dupe(NodeIndex, args);
        return self.emit(Node.init(.{ .call = .{ .func_name = func_name, .args = duped_args, .is_builtin = is_builtin } }, type_idx, span));
    }

    /// Emit return.
    pub fn emitRet(self: *FuncBuilder, value: ?NodeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .ret = .{ .value = value } }, TypeRegistry.VOID, span));
    }

    /// Emit unconditional jump.
    pub fn emitJump(self: *FuncBuilder, target: BlockIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .jump = .{ .target = target } }, TypeRegistry.VOID, span));
    }

    /// Emit conditional branch.
    pub fn emitBranch(self: *FuncBuilder, condition: NodeIndex, then_block: BlockIndex, else_block: BlockIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .branch = .{ .condition = condition, .then_block = then_block, .else_block = else_block } }, TypeRegistry.VOID, span));
    }

    /// Emit select (ternary).
    pub fn emitSelect(self: *FuncBuilder, condition: NodeIndex, then_value: NodeIndex, else_value: NodeIndex, type_idx: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .select = .{ .condition = condition, .then_value = then_value, .else_value = else_value } }, type_idx, span));
    }

    /// Emit type conversion.
    pub fn emitConvert(self: *FuncBuilder, operand: NodeIndex, from_type: TypeIndex, to_type: TypeIndex, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .convert = .{ .operand = operand, .from_type = from_type, .to_type = to_type } }, to_type, span));
    }

    /// Emit nop.
    pub fn emitNop(self: *FuncBuilder, span: Span) !NodeIndex {
        return self.emit(Node.init(.{ .nop = {} }, TypeRegistry.VOID, span));
    }

    // ========================================================================
    // Build
    // ========================================================================

    /// Build the final function.
    /// Computes stack frame layout: assigns offsets to locals and calculates total frame size.
    pub fn build(self: *FuncBuilder) !Func {
        // Collect parameters
        var params = std.ArrayListUnmanaged(Local){};
        defer params.deinit(self.allocator);
        for (self.locals.items) |local| {
            if (local.is_param) {
                try params.append(self.allocator, local);
            }
        }

        // Compute stack frame layout
        var frame_offset: i32 = 0;
        for (self.locals.items) |*local| {
            // Round up to alignment
            const local_align: i32 = @intCast(local.alignment);
            frame_offset = roundUp(frame_offset, local_align);
            // Assign offset (negative for stack-relative)
            local.offset = -frame_offset - @as(i32, @intCast(local.size));
            // Advance by variable size
            frame_offset += @as(i32, @intCast(local.size));
        }

        // Round total frame size to 16-byte alignment (ABI requirement)
        // Add 96 bytes for saved registers: fp/lr (16) + callee-saved (80)
        const frame_size: i32 = roundUp(frame_offset + 96, 16);

        return Func{
            .name = self.name,
            .type_idx = self.type_idx,
            .return_type = self.return_type,
            .params = try self.allocator.dupe(Local, params.items),
            .locals = try self.locals.toOwnedSlice(self.allocator),
            .blocks = try self.blocks.toOwnedSlice(self.allocator),
            .entry = 0,
            .nodes = try self.nodes.toOwnedSlice(self.allocator),
            .span = self.span,
            .frame_size = frame_size,
            .string_literals = try self.string_literals.toOwnedSlice(self.allocator),
        };
    }

    /// Round up to alignment (must be power of 2).
    fn roundUp(offset: i32, alignment: i32) i32 {
        return (offset + alignment - 1) & ~(alignment - 1);
    }
};

// ============================================================================
// Global Variable (Go: Name with Class=PEXTERN)
// ============================================================================

/// A global variable or constant.
pub const Global = struct {
    /// Name.
    name: []const u8,
    /// Type.
    type_idx: TypeIndex,
    /// Is this a constant?
    is_const: bool,
    /// Source span.
    span: Span,
    /// Size in bytes.
    size: u32,

    pub fn init(name: []const u8, type_idx: TypeIndex, is_const: bool, span: Span) Global {
        return .{
            .name = name,
            .type_idx = type_idx,
            .is_const = is_const,
            .span = span,
            .size = 8,
        };
    }
};

// ============================================================================
// Struct Definition
// ============================================================================

/// A struct type definition in IR.
pub const StructDef = struct {
    /// Struct name.
    name: []const u8,
    /// Type index in registry.
    type_idx: TypeIndex,
    /// Source span.
    span: Span,
};

// ============================================================================
// IR Program (entire compilation unit)
// ============================================================================

/// Complete IR for a program/module.
pub const IR = struct {
    /// All functions.
    funcs: []const Func,
    /// All global variables/constants.
    globals: []const Global,
    /// All struct definitions.
    structs: []const StructDef,
    /// Type registry (shared with checker).
    types: *TypeRegistry,
    /// Memory allocator.
    allocator: Allocator,

    pub fn init(allocator: Allocator, type_reg: *TypeRegistry) IR {
        return .{
            .funcs = &.{},
            .globals = &.{},
            .structs = &.{},
            .types = type_reg,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IR) void {
        // Free all internal function data
        for (self.funcs) |*f| {
            // Free each block's nodes
            for (f.blocks) |*block| {
                if (block.nodes.len > 0) {
                    self.allocator.free(block.nodes);
                }
            }
            // Free function-level slices
            if (f.params.len > 0) self.allocator.free(f.params);
            if (f.locals.len > 0) self.allocator.free(f.locals);
            if (f.blocks.len > 0) self.allocator.free(f.blocks);
            if (f.nodes.len > 0) self.allocator.free(f.nodes);
            if (f.string_literals.len > 0) self.allocator.free(f.string_literals);
        }

        // Free top-level slices
        if (self.funcs.len > 0) {
            self.allocator.free(self.funcs);
        }
        if (self.globals.len > 0) {
            self.allocator.free(self.globals);
        }
        if (self.structs.len > 0) {
            self.allocator.free(self.structs);
        }
    }

    /// Get a function by name.
    pub fn getFunc(self: *const IR, name: []const u8) ?*const Func {
        for (self.funcs) |*f| {
            if (std.mem.eql(u8, f.name, name)) {
                return f;
            }
        }
        return null;
    }

    /// Get a global by name.
    pub fn getGlobal(self: *const IR, name: []const u8) ?*const Global {
        for (self.globals) |*g| {
            if (std.mem.eql(u8, g.name, name)) {
                return g;
            }
        }
        return null;
    }
};

// ============================================================================
// IR Builder (program-level construction)
// ============================================================================

/// Helper for building IR from checked AST.
pub const Builder = struct {
    ir: IR,
    allocator: Allocator,

    // Current function being built
    current_func: ?FuncBuilder,

    // All completed functions
    funcs: std.ArrayListUnmanaged(Func),
    globals: std.ArrayListUnmanaged(Global),
    structs: std.ArrayListUnmanaged(StructDef),

    pub fn init(allocator: Allocator, type_reg: *TypeRegistry) Builder {
        return .{
            .ir = IR.init(allocator, type_reg),
            .allocator = allocator,
            .current_func = null,
            .funcs = .{},
            .globals = .{},
            .structs = .{},
        };
    }

    pub fn deinit(self: *Builder) void {
        self.funcs.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        self.structs.deinit(self.allocator);
        if (self.current_func) |*fb| {
            fb.deinit();
        }
    }

    /// Start building a new function.
    pub fn startFunc(self: *Builder, name: []const u8, type_idx: TypeIndex, return_type: TypeIndex, span: Span) void {
        self.current_func = FuncBuilder.init(self.allocator, name, type_idx, return_type, span);
    }

    /// Get current function builder.
    pub fn func(self: *Builder) ?*FuncBuilder {
        if (self.current_func) |*fb| {
            return fb;
        }
        return null;
    }

    /// Finish the current function and add to IR.
    pub fn endFunc(self: *Builder) !void {
        if (self.current_func) |*fb| {
            const f = try fb.build();
            try self.funcs.append(self.allocator, f);
            self.current_func = null;
        }
    }

    /// Add a global variable.
    pub fn addGlobal(self: *Builder, g: Global) !void {
        try self.globals.append(self.allocator, g);
    }

    /// Add a struct definition.
    pub fn addStruct(self: *Builder, s: StructDef) !void {
        try self.structs.append(self.allocator, s);
    }

    /// Get the built IR. Transfers ownership of all data to the IR.
    pub fn getIR(self: *Builder) !IR {
        // Use toOwnedSlice to transfer ownership - the ArrayLists become empty after this
        self.ir.funcs = try self.funcs.toOwnedSlice(self.allocator);
        self.ir.globals = try self.globals.toOwnedSlice(self.allocator);
        self.ir.structs = try self.structs.toOwnedSlice(self.allocator);
        return self.ir;
    }
};

// ============================================================================
// Debug Printing
// ============================================================================

pub fn debugPrintNode(node: *const Node, writer: anytype) !void {
    switch (node.data) {
        .const_int => |c| try writer.print("const_int {d}", .{c.value}),
        .const_float => |c| try writer.print("const_float {d}", .{c.value}),
        .const_bool => |c| try writer.print("const_bool {}", .{c.value}),
        .const_null => try writer.print("const_null", .{}),
        .const_slice => |c| try writer.print("const_slice idx={d}", .{c.string_index}),

        .local_ref => |l| try writer.print("local_ref local={d}", .{l.local_idx}),
        .global_ref => |g| try writer.print("global_ref {s}", .{g.name}),
        .addr_local => |l| try writer.print("addr_local local={d}", .{l.local_idx}),
        .load_local => |l| try writer.print("load_local local={d}", .{l.local_idx}),
        .store_local => |s| try writer.print("store_local local={d} value={d}", .{ s.local_idx, s.value }),

        .binary => |b| try writer.print("binary {s} left={d} right={d}", .{ @tagName(b.op), b.left, b.right }),
        .unary => |u| try writer.print("unary {s} operand={d}", .{ @tagName(u.op), u.operand }),

        .field_local => |f| try writer.print("field_local local={d} offset={d}", .{ f.local_idx, f.offset }),
        .field_value => |f| try writer.print("field_value base={d} offset={d}", .{ f.base, f.offset }),
        .store_local_field => |s| try writer.print("store_local_field local={d} offset={d} value={d}", .{ s.local_idx, s.offset, s.value }),

        .index_local => |i| try writer.print("index_local local={d} index={d}", .{ i.local_idx, i.index }),
        .index_value => |i| try writer.print("index_value base={d} index={d}", .{ i.base, i.index }),
        .store_index_local => |s| try writer.print("store_index_local local={d} index={d} value={d}", .{ s.local_idx, s.index, s.value }),

        .ptr_load => |p| try writer.print("ptr_load local={d}", .{p.ptr_local}),
        .ptr_store => |p| try writer.print("ptr_store local={d} value={d}", .{ p.ptr_local, p.value }),
        .ptr_load_value => |p| try writer.print("ptr_load_value ptr={d}", .{p.ptr}),
        .ptr_store_value => |p| try writer.print("ptr_store_value ptr={d} value={d}", .{ p.ptr, p.value }),

        .addr_offset => |a| try writer.print("addr_offset base={d} offset={d}", .{ a.base, a.offset }),

        .call => |c| {
            try writer.print("call {s} args=[", .{c.func_name});
            for (c.args, 0..) |arg, i| {
                if (i > 0) try writer.print(",", .{});
                try writer.print("{d}", .{arg});
            }
            try writer.print("]", .{});
        },
        .ret => |r| {
            if (r.value) |v| {
                try writer.print("ret value={d}", .{v});
            } else {
                try writer.print("ret void", .{});
            }
        },
        .jump => |j| try writer.print("jump block={d}", .{j.target}),
        .branch => |b| try writer.print("branch cond={d} then={d} else={d}", .{ b.condition, b.then_block, b.else_block }),
        .select => |s| try writer.print("select cond={d} then={d} else={d}", .{ s.condition, s.then_value, s.else_value }),
        .convert => |c| try writer.print("convert operand={d}", .{c.operand}),

        else => try writer.print("{s}", .{@tagName(node.data)}),
    }
}

// ============================================================================
// Tests
// ============================================================================

test "strongly typed node creation" {
    // Create a const_int node
    const int_node = Node.init(
        .{ .const_int = .{ .value = 42 } },
        TypeRegistry.INT,
        Span.fromPos(Pos.zero),
    );
    try std.testing.expectEqual(@as(i64, 42), int_node.data.const_int.value);

    // Create a binary add node
    const add_node = Node.init(
        .{ .binary = .{ .op = .add, .left = 0, .right = 1 } },
        TypeRegistry.INT,
        Span.fromPos(Pos.zero),
    );
    try std.testing.expectEqual(BinaryOp.add, add_node.data.binary.op);
    try std.testing.expectEqual(@as(NodeIndex, 0), add_node.data.binary.left);
    try std.testing.expectEqual(@as(NodeIndex, 1), add_node.data.binary.right);

    // Create a store_local node - demonstrates type safety
    const store_node = Node.init(
        .{ .store_local = .{ .local_idx = 5, .value = 10 } },
        TypeRegistry.VOID,
        Span.fromPos(Pos.zero),
    );
    // local_idx is LocalIdx (u32), value is NodeIndex (u32) - but semantically distinct
    try std.testing.expectEqual(@as(LocalIdx, 5), store_node.data.store_local.local_idx);
    try std.testing.expectEqual(@as(NodeIndex, 10), store_node.data.store_local.value);
}

test "binary op predicates" {
    try std.testing.expect(BinaryOp.add.isArithmetic());
    try std.testing.expect(!BinaryOp.add.isComparison());
    try std.testing.expect(BinaryOp.eq.isComparison());
    try std.testing.expect(!BinaryOp.eq.isArithmetic());
    try std.testing.expect(BinaryOp.@"and".isLogical());
    try std.testing.expect(BinaryOp.bit_and.isBitwise());
}

test "node properties" {
    const ret_node = Node.init(
        .{ .ret = .{ .value = null } },
        TypeRegistry.VOID,
        Span.fromPos(Pos.zero),
    );
    try std.testing.expect(ret_node.isTerminator());
    try std.testing.expect(ret_node.hasSideEffects());
    try std.testing.expect(!ret_node.isConstant());

    const const_node = Node.init(
        .{ .const_int = .{ .value = 42 } },
        TypeRegistry.INT,
        Span.fromPos(Pos.zero),
    );
    try std.testing.expect(!const_node.isTerminator());
    try std.testing.expect(!const_node.hasSideEffects());
    try std.testing.expect(const_node.isConstant());
}

test "function builder basic" {
    // Use arena to avoid tracking intermediate allocations
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fb = FuncBuilder.init(allocator, "test", 0, TypeRegistry.INT, Span.fromPos(Pos.zero));

    // Add a local
    const local_idx = try fb.addLocal(Local.init("x", TypeRegistry.INT, true));
    try std.testing.expectEqual(@as(LocalIdx, 0), local_idx);

    // Create a block
    const block_idx = try fb.newBlock("then");
    try std.testing.expectEqual(@as(BlockIndex, 1), block_idx); // 0 is entry

    fb.setBlock(block_idx);

    // Emit nodes using convenience methods
    const const_node = try fb.emitConstInt(42, TypeRegistry.INT, Span.fromPos(Pos.zero));
    try std.testing.expectEqual(@as(NodeIndex, 0), const_node);

    _ = try fb.emitStoreLocal(local_idx, const_node, Span.fromPos(Pos.zero));
    _ = try fb.emitRet(const_node, Span.fromPos(Pos.zero));

    // Build the function
    const func = try fb.build();
    try std.testing.expectEqual(@as(usize, 1), func.locals.len);
    try std.testing.expectEqual(@as(usize, 3), func.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), func.blocks.len);
}

test "function builder with parameters" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fb = FuncBuilder.init(allocator, "add", 0, TypeRegistry.INT, Span.fromPos(Pos.zero));

    // Add parameters
    const a = try fb.addParam("a", TypeRegistry.INT, 8);
    const b = try fb.addParam("b", TypeRegistry.INT, 8);

    try std.testing.expectEqual(@as(LocalIdx, 0), a);
    try std.testing.expectEqual(@as(LocalIdx, 1), b);

    // Lookup works
    try std.testing.expectEqual(a, fb.lookupLocal("a").?);
    try std.testing.expectEqual(b, fb.lookupLocal("b").?);
    try std.testing.expectEqual(@as(?LocalIdx, null), fb.lookupLocal("c"));

    const func = try fb.build();
    try std.testing.expectEqual(@as(usize, 2), func.params.len);
    try std.testing.expect(func.params[0].is_param);
    try std.testing.expect(func.params[1].is_param);
}

test "IR builder" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var type_reg = try TypeRegistry.init(allocator);

    var builder = Builder.init(allocator, &type_reg);
    defer builder.deinit();

    // Build a function
    builder.startFunc("main", 0, TypeRegistry.INT, Span.fromPos(Pos.zero));
    if (builder.func()) |fb| {
        _ = try fb.emitConstInt(42, TypeRegistry.INT, Span.fromPos(Pos.zero));
        _ = try fb.emitRet(0, Span.fromPos(Pos.zero));
    }
    try builder.endFunc();

    // Add a global
    try builder.addGlobal(Global.init("counter", TypeRegistry.INT, false, Span.fromPos(Pos.zero)));

    const ir = try builder.getIR();
    try std.testing.expectEqual(@as(usize, 1), ir.funcs.len);
    try std.testing.expectEqual(@as(usize, 1), ir.globals.len);
    try std.testing.expect(ir.getFunc("main") != null);
    try std.testing.expect(ir.getGlobal("counter") != null);
}

test "local variable layout" {
    const local = Local.initWithSize("x", TypeRegistry.INT, true, 8);
    try std.testing.expectEqual(@as(u32, 8), local.size);
    try std.testing.expectEqual(@as(u32, 8), local.alignment);
    try std.testing.expect(local.mutable);
    try std.testing.expect(!local.is_param);

    const param = Local.initParam("arg", TypeRegistry.I32, 0, 4);
    try std.testing.expectEqual(@as(u32, 4), param.size);
    try std.testing.expectEqual(@as(u32, 4), param.alignment);
    try std.testing.expect(param.is_param);
    try std.testing.expectEqual(@as(ParamIdx, 0), param.param_idx);
}

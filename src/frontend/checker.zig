//! Type checker for Cot.
//!
//! Architecture modeled on Go's go/types package:
//! - Multi-phase checking: collect declarations, then check bodies
//! - Scope hierarchy with parent chain for name lookup
//! - Expression type caching to avoid redundant work
//! - Symbol objects tracking declared names
//!
//! Go reference: cmd/compile/internal/types2/

const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");
const source = @import("source.zig");
const token = @import("token.zig");

const Ast = ast.Ast;
const Node = ast.Node;
const NodeIndex = ast.NodeIndex;
const null_node = ast.null_node;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Decl = ast.Decl;
const TypeKind = ast.TypeKind;
const LiteralKind = ast.LiteralKind;
const Token = token.Token;

const Type = types.Type;
const TypeIndex = types.TypeIndex;
const TypeRegistry = types.TypeRegistry;
const BasicKind = types.BasicKind;
const invalid_type = types.invalid_type;

const ErrorReporter = errors.ErrorReporter;
const ErrorCode = errors.ErrorCode;
const Pos = source.Pos;
const Span = source.Span;

// =========================================
// Check Error
// =========================================

pub const CheckError = error{OutOfMemory};

// =========================================
// Symbol (Go's Object)
// =========================================

/// Kind of symbol.
pub const SymbolKind = enum {
    variable,
    constant,
    function,
    type_name,
    parameter,
};

/// A symbol in a scope (variable, function, type, etc.)
/// Corresponds to Go's types.Object interface.
pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    type_idx: TypeIndex,
    node: NodeIndex, // AST node where defined
    mutable: bool, // var vs const

    pub fn init(name: []const u8, kind: SymbolKind, type_idx: TypeIndex, node: NodeIndex, mutable: bool) Symbol {
        return .{
            .name = name,
            .kind = kind,
            .type_idx = type_idx,
            .node = node,
            .mutable = mutable,
        };
    }
};

// =========================================
// Scope (Go's Scope)
// =========================================

/// Lexical scope for name resolution.
/// Scopes form a tree with parent pointers.
/// Corresponds to Go's types.Scope.
pub const Scope = struct {
    parent: ?*Scope,
    symbols: std.StringHashMap(Symbol),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) Scope {
        return .{
            .parent = parent,
            .symbols = std.StringHashMap(Symbol).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scope) void {
        self.symbols.deinit();
    }

    /// Define a symbol in this scope.
    pub fn define(self: *Scope, sym: Symbol) !void {
        try self.symbols.put(sym.name, sym);
    }

    /// Look up a symbol in this scope only.
    pub fn lookupLocal(self: *const Scope, name: []const u8) ?Symbol {
        return self.symbols.get(name);
    }

    /// Look up a symbol in this scope or any parent scope.
    pub fn lookup(self: *const Scope, name: []const u8) ?Symbol {
        if (self.symbols.get(name)) |sym| {
            return sym;
        }
        if (self.parent) |p| {
            return p.lookup(name);
        }
        return null;
    }

    /// Check if a name is already defined in this scope (not parent).
    pub fn isDefined(self: *const Scope, name: []const u8) bool {
        return self.symbols.contains(name);
    }
};

// =========================================
// Method Info
// =========================================

/// Information about a method attached to a type.
pub const MethodInfo = struct {
    name: []const u8,
    func_name: []const u8,
    func_type: TypeIndex,
    receiver_is_ptr: bool,
};

// =========================================
// Checker (Go's Checker)
// =========================================

/// Type checker state.
/// Corresponds to Go's types.Checker.
pub const Checker = struct {
    /// Type registry for type interning and lookup.
    types: *TypeRegistry,
    /// Current scope.
    scope: *Scope,
    /// Error reporter.
    err: *ErrorReporter,
    /// AST being checked.
    tree: *const Ast,
    /// Memory allocator.
    allocator: std.mem.Allocator,
    /// Expression type cache: NodeIndex -> TypeIndex
    expr_types: std.AutoHashMap(NodeIndex, TypeIndex),
    /// Current function return type (for checking return statements).
    current_return_type: TypeIndex,
    /// Are we inside a loop? (for break/continue)
    in_loop: bool,
    /// Method registry: maps type name -> list of methods
    method_registry: std.StringHashMap(std.ArrayListUnmanaged(MethodInfo)),

    pub fn init(
        allocator: std.mem.Allocator,
        tree: *const Ast,
        type_reg: *TypeRegistry,
        reporter: *ErrorReporter,
        global_scope: *Scope,
    ) Checker {
        return .{
            .types = type_reg,
            .scope = global_scope,
            .err = reporter,
            .tree = tree,
            .allocator = allocator,
            .expr_types = std.AutoHashMap(NodeIndex, TypeIndex).init(allocator),
            .current_return_type = TypeRegistry.VOID,
            .in_loop = false,
            .method_registry = std.StringHashMap(std.ArrayListUnmanaged(MethodInfo)).init(allocator),
        };
    }

    pub fn deinit(self: *Checker) void {
        self.expr_types.deinit();
        // Deinit all method lists in the registry
        var it = self.method_registry.valueIterator();
        while (it.next()) |methods| {
            methods.deinit(self.allocator);
        }
        self.method_registry.deinit();
    }

    // ========================================================================
    // Expression type lookup
    // ========================================================================

    /// Get the cached type of an expression node.
    pub fn getExprType(self: *const Checker, node: NodeIndex) TypeIndex {
        return self.expr_types.get(node) orelse invalid_type;
    }

    // ========================================================================
    // File checking (main entry point)
    // ========================================================================

    /// Type check an entire file.
    /// Two-phase approach like Go's Checker:
    /// 1. Collect all declarations (add to scope)
    /// 2. Check all declarations (type-check bodies)
    pub fn checkFile(self: *Checker) CheckError!void {
        const file = self.tree.file orelse return;

        // Phase 1: Collect all top-level declarations
        for (file.decls) |decl_idx| {
            try self.collectDecl(decl_idx);
        }

        // Phase 2: Check all declarations
        for (file.decls) |decl_idx| {
            try self.checkDecl(decl_idx);
        }
    }

    /// Collect a declaration (add to scope without checking body).
    fn collectDecl(self: *Checker, idx: NodeIndex) CheckError!void {
        const node = self.tree.getNode(idx) orelse return;
        const decl = node.asDecl() orelse return;

        switch (decl) {
            .fn_decl => |f| {
                if (self.scope.isDefined(f.name)) {
                    self.errRedefined(f.span.start, f.name);
                    return;
                }
                // Build function type
                const func_type = try self.buildFuncType(f.params, f.return_type);
                try self.scope.define(Symbol.init(
                    f.name,
                    .function,
                    func_type,
                    idx,
                    false,
                ));

                // Check if this is a method (first param named "self")
                if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "self")) {
                    try self.registerMethod(f.name, f.params[0].type_expr, func_type);
                }
            },
            .var_decl => |v| {
                if (self.scope.isDefined(v.name)) {
                    self.errRedefined(v.span.start, v.name);
                    return;
                }
                try self.scope.define(Symbol.init(
                    v.name,
                    if (v.is_const) .constant else .variable,
                    invalid_type, // Type determined in checkDecl
                    idx,
                    !v.is_const,
                ));
            },
            .struct_decl => |s| {
                if (self.scope.isDefined(s.name)) {
                    self.errRedefined(s.span.start, s.name);
                    return;
                }
                const struct_type = try self.buildStructType(s.name, s.fields);
                try self.scope.define(Symbol.init(
                    s.name,
                    .type_name,
                    struct_type,
                    idx,
                    false,
                ));
                // Register in type registry for lookup by name
                try self.types.registerNamed(s.name, struct_type);
            },
            .enum_decl => |e| {
                if (self.scope.isDefined(e.name)) {
                    self.errRedefined(e.span.start, e.name);
                    return;
                }
                const enum_type = try self.buildEnumType(e);
                try self.scope.define(Symbol.init(
                    e.name,
                    .type_name,
                    enum_type,
                    idx,
                    false,
                ));
                try self.types.registerNamed(e.name, enum_type);
            },
            .union_decl => |u| {
                if (self.scope.isDefined(u.name)) {
                    self.errRedefined(u.span.start, u.name);
                    return;
                }
                const union_type = try self.buildUnionType(u);
                try self.scope.define(Symbol.init(
                    u.name,
                    .type_name,
                    union_type,
                    idx,
                    false,
                ));
                try self.types.registerNamed(u.name, union_type);
            },
            .type_alias => |t| {
                if (self.scope.isDefined(t.name)) {
                    self.errRedefined(t.span.start, t.name);
                    return;
                }
                const target_type = self.resolveTypeExpr(t.target) catch invalid_type;
                try self.scope.define(Symbol.init(
                    t.name,
                    .type_name,
                    target_type,
                    idx,
                    false,
                ));
                try self.types.registerNamed(t.name, target_type);
            },
            .import_decl, .bad_decl => {},
        }
    }

    /// Register a method for a type.
    fn registerMethod(self: *Checker, func_name: []const u8, self_type_expr: NodeIndex, func_type: TypeIndex) CheckError!void {
        const node = self.tree.getNode(self_type_expr) orelse return;
        const expr = node.asExpr() orelse return;
        if (expr != .type_expr) return;

        const te = expr.type_expr;
        var receiver_name: []const u8 = undefined;
        var is_ptr = false;

        switch (te.kind) {
            .named => |name| {
                receiver_name = name;
                is_ptr = false;
            },
            .pointer => |ptr_elem| {
                const elem_node = self.tree.getNode(ptr_elem) orelse return;
                const elem_expr = elem_node.asExpr() orelse return;
                if (elem_expr != .type_expr) return;
                const elem_te = elem_expr.type_expr;
                if (elem_te.kind != .named) return;
                receiver_name = elem_te.kind.named;
                is_ptr = true;
            },
            else => return,
        }

        const gop = try self.method_registry.getOrPut(receiver_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }

        try gop.value_ptr.append(self.allocator, MethodInfo{
            .name = func_name,
            .func_name = func_name,
            .func_type = func_type,
            .receiver_is_ptr = is_ptr,
        });
    }

    /// Look up a method for a type by name.
    pub fn lookupMethod(self: *const Checker, type_name: []const u8, method_name: []const u8) ?MethodInfo {
        if (self.method_registry.get(type_name)) |methods| {
            for (methods.items) |method| {
                if (std.mem.eql(u8, method.name, method_name)) {
                    return method;
                }
            }
        }
        return null;
    }

    // ========================================================================
    // Declaration checking
    // ========================================================================

    /// Check a declaration.
    fn checkDecl(self: *Checker, idx: NodeIndex) CheckError!void {
        const node = self.tree.getNode(idx) orelse return;
        const decl = node.asDecl() orelse return;

        switch (decl) {
            .fn_decl => |f| try self.checkFnDecl(f, idx),
            .var_decl => |v| try self.checkVarDecl(v, idx),
            .struct_decl, .enum_decl, .union_decl, .type_alias => {}, // Already processed
            .import_decl, .bad_decl => {},
        }
    }

    /// Check function declaration.
    fn checkFnDecl(self: *Checker, f: ast.FnDecl, idx: NodeIndex) CheckError!void {
        const sym = self.scope.lookup(f.name) orelse return;
        const func_type = self.types.get(sym.type_idx);
        const return_type = switch (func_type) {
            .func => |ft| ft.return_type,
            else => TypeRegistry.VOID,
        };

        // Create new scope for function body
        var func_scope = Scope.init(self.allocator, self.scope);
        defer func_scope.deinit();

        // Add parameters to function scope
        for (f.params) |param| {
            const param_type = try self.resolveTypeExpr(param.type_expr);
            try func_scope.define(Symbol.init(
                param.name,
                .parameter,
                param_type,
                idx,
                false,
            ));
        }

        // Save state
        const old_scope = self.scope;
        const old_return = self.current_return_type;

        // Set up for function body
        self.scope = &func_scope;
        self.current_return_type = return_type;

        // Check body if present
        if (f.body != null_node) {
            try self.checkBlockExpr(f.body);
        }

        // Restore state
        self.scope = old_scope;
        self.current_return_type = old_return;
    }

    /// Check variable declaration.
    fn checkVarDecl(self: *Checker, v: ast.VarDecl, idx: NodeIndex) CheckError!void {
        var var_type: TypeIndex = invalid_type;

        if (v.type_expr != null_node) {
            var_type = try self.resolveTypeExpr(v.type_expr);
        }

        if (v.value != null_node) {
            const val_type = try self.checkExpr(v.value);

            if (var_type == invalid_type) {
                var_type = self.materializeType(val_type);
            } else {
                if (!self.types.isAssignable(val_type, var_type)) {
                    self.errTypeMismatch(v.span.start, var_type, val_type);
                }
            }
        }

        // Update symbol with resolved type
        if (self.scope.lookupLocal(v.name)) |_| {
            try self.scope.define(Symbol.init(
                v.name,
                if (v.is_const) .constant else .variable,
                var_type,
                idx,
                !v.is_const,
            ));
        }
    }

    // ========================================================================
    // Expression checking
    // ========================================================================

    /// Check an expression and return its type.
    pub fn checkExpr(self: *Checker, idx: NodeIndex) CheckError!TypeIndex {
        if (idx == null_node) return invalid_type;

        // Check cache first
        if (self.expr_types.get(idx)) |t| {
            return t;
        }

        const result = try self.checkExprInner(idx);
        try self.expr_types.put(idx, result);
        return result;
    }

    fn checkExprInner(self: *Checker, idx: NodeIndex) CheckError!TypeIndex {
        const node = self.tree.getNode(idx) orelse return invalid_type;
        const expr = node.asExpr() orelse return invalid_type;

        return switch (expr) {
            .ident => |id| self.checkIdentifier(id),
            .literal => |lit| self.checkLiteral(lit),
            .binary => |bin| try self.checkBinary(bin),
            .unary => |un| try self.checkUnary(un),
            .call => |c| try self.checkCall(c),
            .index => |i| try self.checkIndex(i),
            .slice_expr => |se| try self.checkSliceExpr(se),
            .field_access => |f| try self.checkFieldAccess(f),
            .array_literal => |al| try self.checkArrayLiteral(al),
            .paren => |p| try self.checkExpr(p.inner),
            .if_expr => |ie| try self.checkIfExpr(ie),
            .switch_expr => |se| try self.checkSwitchExpr(se),
            .block_expr => |b| try self.checkBlock(b),
            .struct_init => |si| try self.checkStructInit(si),
            .new_expr => |ne| try self.resolveTypeExpr(ne.type_node),
            .string_interp => |si| try self.checkStringInterp(si),
            .addr_of => |ao| try self.checkAddrOf(ao),
            .deref => |d| try self.checkDeref(d),
            .type_expr => invalid_type,
            .bad_expr => invalid_type,
        };
    }

    /// Check identifier expression.
    fn checkIdentifier(self: *Checker, id: ast.Ident) TypeIndex {
        if (self.scope.lookup(id.name)) |sym| {
            return sym.type_idx;
        }
        self.errUndefined(id.span.start, id.name);
        return invalid_type;
    }

    /// Check literal expression.
    fn checkLiteral(self: *Checker, lit: ast.Literal) TypeIndex {
        _ = self;
        return switch (lit.kind) {
            .int => TypeRegistry.UNTYPED_INT,
            .float => TypeRegistry.UNTYPED_FLOAT,
            .string => TypeRegistry.STRING,
            .char => TypeRegistry.U8,
            .true_lit, .false_lit => TypeRegistry.UNTYPED_BOOL,
            .null_lit => invalid_type,
        };
    }

    /// Check binary expression.
    fn checkBinary(self: *Checker, bin: ast.Binary) CheckError!TypeIndex {
        const left_type = try self.checkExpr(bin.left);
        const right_type = try self.checkExpr(bin.right);

        const left = self.types.get(left_type);
        const right = self.types.get(right_type);

        switch (bin.op) {
            .add => {
                // Allow string + string (concatenation)
                if (left_type == TypeRegistry.STRING and right_type == TypeRegistry.STRING) {
                    return TypeRegistry.STRING;
                }
                if (!types.isNumeric(left) or !types.isNumeric(right)) {
                    self.errInvalidOp(bin.span.start, "arithmetic", left_type, right_type);
                    return invalid_type;
                }
                return self.materializeType(left_type);
            },
            .sub, .mul, .quo, .rem => {
                if (!types.isNumeric(left) or !types.isNumeric(right)) {
                    self.errInvalidOp(bin.span.start, "arithmetic", left_type, right_type);
                    return invalid_type;
                }
                return self.materializeType(left_type);
            },
            .eql, .neq, .lss, .leq, .gtr, .geq => {
                if (!self.isComparable(left_type, right_type)) {
                    self.errInvalidOp(bin.span.start, "comparison", left_type, right_type);
                    return invalid_type;
                }
                return TypeRegistry.BOOL;
            },
            .kw_and, .kw_or => {
                if (!types.isBool(left) or !types.isBool(right)) {
                    self.errInvalidOp(bin.span.start, "logical", left_type, right_type);
                    return invalid_type;
                }
                return TypeRegistry.BOOL;
            },
            .@"and", .@"or", .xor => {
                if (!types.isInteger(left) or !types.isInteger(right)) {
                    self.errInvalidOp(bin.span.start, "bitwise", left_type, right_type);
                    return invalid_type;
                }
                return self.materializeType(left_type);
            },
            .coalesce => {
                if (left == .optional) {
                    return left.optional.elem;
                }
                return left_type;
            },
            else => return invalid_type,
        }
    }

    /// Check unary expression.
    fn checkUnary(self: *Checker, un: ast.Unary) CheckError!TypeIndex {
        const operand_type = try self.checkExpr(un.operand);
        const operand = self.types.get(operand_type);

        switch (un.op) {
            .sub => {
                if (!types.isNumeric(operand)) {
                    self.err.errorWithCode(un.span.start, .e303, "unary '-' requires numeric operand");
                    return invalid_type;
                }
                return operand_type;
            },
            .not, .kw_not => {
                if (!types.isBool(operand)) {
                    self.err.errorWithCode(un.span.start, .e303, "unary '!' requires bool operand");
                    return invalid_type;
                }
                return TypeRegistry.BOOL;
            },
            else => return invalid_type,
        }
    }

    /// Check function call.
    fn checkCall(self: *Checker, c: ast.Call) CheckError!TypeIndex {
        // Check for builtin functions first
        if (self.tree.getNode(c.callee)) |callee_node| {
            if (callee_node.asExpr()) |callee_expr| {
                if (callee_expr == .ident) {
                    const name = callee_expr.ident.name;
                    if (std.mem.eql(u8, name, "len")) {
                        return self.checkBuiltinLen(c);
                    }
                    if (std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "println")) {
                        return self.checkBuiltinPrint(c);
                    }
                }
            }
        }

        const callee_type = try self.checkExpr(c.callee);
        const callee = self.types.get(callee_type);

        const is_method_call = self.isMethodCall(c.callee);

        switch (callee) {
            .func => |ft| {
                const expected_args = if (is_method_call and ft.params.len > 0)
                    ft.params.len - 1
                else
                    ft.params.len;

                if (c.args.len != expected_args) {
                    self.err.errorWithCode(c.span.start, .e300, "wrong number of arguments");
                    return invalid_type;
                }

                const param_offset: usize = if (is_method_call) 1 else 0;
                for (c.args, 0..) |arg_idx, i| {
                    const arg_type = try self.checkExpr(arg_idx);
                    const param_type = ft.params[i + param_offset].type_idx;
                    if (!self.types.isAssignable(arg_type, param_type)) {
                        self.errTypeMismatch(c.span.start, param_type, arg_type);
                    }
                }

                return ft.return_type;
            },
            else => {
                self.err.errorWithCode(c.span.start, .e300, "cannot call non-function");
                return invalid_type;
            },
        }
    }

    /// Check if a callee expression is a method call.
    fn isMethodCall(self: *Checker, callee_idx: NodeIndex) bool {
        const callee_node = self.tree.getNode(callee_idx) orelse return false;
        const callee_expr = callee_node.asExpr() orelse return false;
        if (callee_expr != .field_access) return false;

        const fa = callee_expr.field_access;
        const base_type_idx = self.expr_types.get(fa.base) orelse return false;
        const base_type = self.types.get(base_type_idx);

        const struct_name = switch (base_type) {
            .struct_type => |st| st.name,
            .pointer => |ptr| blk: {
                const elem = self.types.get(ptr.elem);
                if (elem == .struct_type) {
                    break :blk elem.struct_type.name;
                }
                return false;
            },
            else => return false,
        };

        return self.lookupMethod(struct_name, fa.field) != null;
    }

    /// Check builtin len() function.
    fn checkBuiltinLen(self: *Checker, c: ast.Call) CheckError!TypeIndex {
        if (c.args.len != 1) {
            self.err.errorWithCode(c.span.start, .e300, "len() expects exactly one argument");
            return invalid_type;
        }

        const arg_type = try self.checkExpr(c.args[0]);
        const arg = self.types.get(arg_type);

        switch (arg) {
            .array, .slice, .list => return TypeRegistry.INT,
            else => {},
        }

        self.err.errorWithCode(c.span.start, .e300, "len() argument must be array, slice, or list");
        return invalid_type;
    }

    /// Check builtin print()/println() functions.
    fn checkBuiltinPrint(self: *Checker, c: ast.Call) CheckError!TypeIndex {
        if (c.args.len != 1) {
            self.err.errorWithCode(c.span.start, .e300, "print() expects exactly one argument");
            return TypeRegistry.VOID;
        }

        _ = try self.checkExpr(c.args[0]);
        return TypeRegistry.VOID;
    }

    /// Check index expression.
    fn checkIndex(self: *Checker, i: ast.Index) CheckError!TypeIndex {
        const base_type = try self.checkExpr(i.base);
        const index_type = try self.checkExpr(i.idx);
        const base = self.types.get(base_type);

        const index = self.types.get(index_type);
        if (!types.isInteger(index)) {
            self.err.errorWithCode(i.span.start, .e300, "index must be integer");
            return invalid_type;
        }

        return switch (base) {
            .array => |a| a.elem,
            .slice => |s| s.elem,
            .list => |l| l.elem,
            else => blk: {
                self.err.errorWithCode(i.span.start, .e300, "cannot index this type");
                break :blk invalid_type;
            },
        };
    }

    /// Check slice expression.
    fn checkSliceExpr(self: *Checker, se: ast.SliceExpr) CheckError!TypeIndex {
        const base_type = try self.checkExpr(se.base);
        const base = self.types.get(base_type);

        if (se.start != null_node) {
            const start_type = try self.checkExpr(se.start);
            if (!types.isInteger(self.types.get(start_type))) {
                self.err.errorWithCode(se.span.start, .e300, "slice start must be integer");
                return invalid_type;
            }
        }

        if (se.end != null_node) {
            const end_type = try self.checkExpr(se.end);
            if (!types.isInteger(self.types.get(end_type))) {
                self.err.errorWithCode(se.span.start, .e300, "slice end must be integer");
                return invalid_type;
            }
        }

        return switch (base) {
            .array => |a| try self.types.makeSlice(a.elem),
            .slice => base_type,
            else => blk: {
                self.err.errorWithCode(se.span.start, .e300, "cannot slice this type");
                break :blk invalid_type;
            },
        };
    }

    /// Check field access.
    fn checkFieldAccess(self: *Checker, f: ast.FieldAccess) CheckError!TypeIndex {
        // Handle inferred variant literals (.variant) for enums/unions in switch
        if (f.base == null_node) {
            // Inferred type - will be resolved in context (e.g., switch case)
            return invalid_type;
        }

        const base_type = try self.checkExpr(f.base);
        const base = self.types.get(base_type);

        switch (base) {
            .struct_type => |st| {
                for (st.fields) |field| {
                    if (std.mem.eql(u8, field.name, f.field)) {
                        return field.type_idx;
                    }
                }
                if (self.lookupMethod(st.name, f.field)) |method| {
                    return method.func_type;
                }
                self.errUndefined(f.span.start, f.field);
                return invalid_type;
            },
            .enum_type => |et| {
                for (et.variants) |variant| {
                    if (std.mem.eql(u8, variant.name, f.field)) {
                        return base_type;
                    }
                }
                self.errUndefined(f.span.start, f.field);
                return invalid_type;
            },
            .union_type => |ut| {
                for (ut.variants) |variant| {
                    if (std.mem.eql(u8, variant.name, f.field)) {
                        if (variant.payload_type == invalid_type) {
                            return base_type;
                        }
                        // Create function type for variant constructor
                        const params = try self.allocator.alloc(types.FuncParam, 1);
                        params[0] = .{
                            .name = "payload",
                            .type_idx = variant.payload_type,
                        };
                        return try self.types.add(.{ .func = .{
                            .params = params,
                            .return_type = base_type,
                        } });
                    }
                }
                self.errUndefined(f.span.start, f.field);
                return invalid_type;
            },
            .pointer => |ptr| {
                const elem = self.types.get(ptr.elem);
                if (elem == .struct_type) {
                    const st = elem.struct_type;
                    for (st.fields) |field| {
                        if (std.mem.eql(u8, field.name, f.field)) {
                            return field.type_idx;
                        }
                    }
                    if (self.lookupMethod(st.name, f.field)) |method| {
                        return method.func_type;
                    }
                }
                self.err.errorWithCode(f.span.start, .e300, "cannot access field on this type");
                return invalid_type;
            },
            .map => |mt| {
                if (std.mem.eql(u8, f.field, "set")) {
                    const params = try self.allocator.alloc(types.FuncParam, 2);
                    params[0] = .{ .name = "key", .type_idx = mt.key };
                    params[1] = .{ .name = "value", .type_idx = mt.value };
                    return try self.types.add(.{ .func = .{
                        .params = params,
                        .return_type = TypeRegistry.VOID,
                    } });
                } else if (std.mem.eql(u8, f.field, "get")) {
                    const params = try self.allocator.alloc(types.FuncParam, 1);
                    params[0] = .{ .name = "key", .type_idx = mt.key };
                    return try self.types.add(.{ .func = .{
                        .params = params,
                        .return_type = mt.value,
                    } });
                } else if (std.mem.eql(u8, f.field, "has")) {
                    const params = try self.allocator.alloc(types.FuncParam, 1);
                    params[0] = .{ .name = "key", .type_idx = mt.key };
                    return try self.types.add(.{ .func = .{
                        .params = params,
                        .return_type = TypeRegistry.BOOL,
                    } });
                }
                self.errUndefined(f.span.start, f.field);
                return invalid_type;
            },
            .list => |lt| {
                if (std.mem.eql(u8, f.field, "push")) {
                    const params = try self.allocator.alloc(types.FuncParam, 1);
                    params[0] = .{ .name = "value", .type_idx = lt.elem };
                    return try self.types.add(.{ .func = .{
                        .params = params,
                        .return_type = TypeRegistry.VOID,
                    } });
                } else if (std.mem.eql(u8, f.field, "get")) {
                    const params = try self.allocator.alloc(types.FuncParam, 1);
                    params[0] = .{ .name = "index", .type_idx = TypeRegistry.INT };
                    return try self.types.add(.{ .func = .{
                        .params = params,
                        .return_type = lt.elem,
                    } });
                } else if (std.mem.eql(u8, f.field, "len")) {
                    return try self.types.add(.{ .func = .{
                        .params = &.{},
                        .return_type = TypeRegistry.INT,
                    } });
                }
                self.errUndefined(f.span.start, f.field);
                return invalid_type;
            },
            else => {
                self.err.errorWithCode(f.span.start, .e300, "cannot access field on this type");
                return invalid_type;
            },
        }
    }

    /// Check struct initialization.
    fn checkStructInit(self: *Checker, si: ast.StructInit) CheckError!TypeIndex {
        const sym = self.scope.lookup(si.type_name) orelse {
            self.errUndefined(si.span.start, si.type_name);
            return invalid_type;
        };

        const struct_type = self.types.get(sym.type_idx);
        switch (struct_type) {
            .struct_type => |st| {
                for (si.fields) |field_init| {
                    var found = false;
                    for (st.fields) |struct_field| {
                        if (std.mem.eql(u8, struct_field.name, field_init.name)) {
                            found = true;
                            const value_type = try self.checkExpr(field_init.value);
                            if (!self.types.isAssignable(value_type, struct_field.type_idx)) {
                                self.err.errorWithCode(field_init.span.start, .e300, "type mismatch in field initializer");
                            }
                            break;
                        }
                    }
                    if (!found) {
                        self.err.errorWithCode(field_init.span.start, .e301, "unknown field in struct initializer");
                    }
                }
                return sym.type_idx;
            },
            else => {
                self.err.errorWithCode(si.span.start, .e300, "not a struct type");
                return invalid_type;
            },
        }
    }

    /// Check array literal.
    fn checkArrayLiteral(self: *Checker, al: ast.ArrayLiteral) CheckError!TypeIndex {
        if (al.elements.len == 0) {
            self.err.errorWithCode(al.span.start, .e300, "cannot infer type of empty array literal");
            return invalid_type;
        }

        const first_type = try self.checkExpr(al.elements[0]);
        if (first_type == invalid_type) {
            return invalid_type;
        }

        for (al.elements[1..]) |elem_idx| {
            const elem_type = try self.checkExpr(elem_idx);
            if (!self.types.equal(first_type, elem_type)) {
                self.err.errorWithCode(al.span.start, .e300, "array elements must have same type");
                return invalid_type;
            }
        }

        return self.types.makeArray(self.materializeType(first_type), al.elements.len) catch invalid_type;
    }

    /// Check if expression.
    fn checkIfExpr(self: *Checker, ie: ast.IfExpr) CheckError!TypeIndex {
        const cond_type = try self.checkExpr(ie.condition);
        if (!types.isBool(self.types.get(cond_type))) {
            self.err.errorWithCode(ie.span.start, .e300, "condition must be bool");
        }

        const then_type = try self.checkExpr(ie.then_branch);

        if (ie.else_branch != null_node) {
            const else_type = try self.checkExpr(ie.else_branch);
            if (!self.types.equal(then_type, else_type)) {
                self.err.errorWithCode(ie.span.start, .e300, "if branches have different types");
                return invalid_type;
            }
            return then_type;
        }

        return TypeRegistry.VOID;
    }

    /// Check switch expression.
    fn checkSwitchExpr(self: *Checker, se: ast.SwitchExpr) CheckError!TypeIndex {
        const subject_type = try self.checkExpr(se.subject);

        var result_type: TypeIndex = TypeRegistry.VOID;
        var first_case = true;

        for (se.cases) |case| {
            for (case.patterns) |val_idx| {
                const val_type = try self.checkExpr(val_idx);
                if (val_type != invalid_type and !self.isComparable(subject_type, val_type)) {
                    self.err.errorWithCode(case.span.start, .e300, "case value not comparable to switch subject");
                }
            }

            const body_type = try self.checkExpr(case.body);

            if (first_case) {
                result_type = self.materializeType(body_type);
                first_case = false;
            }
        }

        if (se.else_body != null_node) {
            _ = try self.checkExpr(se.else_body);
        }

        return result_type;
    }

    /// Check block expression.
    fn checkBlock(self: *Checker, b: ast.BlockExpr) CheckError!TypeIndex {
        var block_scope = Scope.init(self.allocator, self.scope);
        defer block_scope.deinit();

        const old_scope = self.scope;
        self.scope = &block_scope;

        for (b.stmts) |stmt_idx| {
            try self.checkStmt(stmt_idx);
        }

        self.scope = old_scope;

        if (b.expr != null_node) {
            return try self.checkExpr(b.expr);
        }
        return TypeRegistry.VOID;
    }

    /// Check block expression (from function body).
    fn checkBlockExpr(self: *Checker, idx: NodeIndex) CheckError!void {
        const node = self.tree.getNode(idx) orelse return;
        const expr = node.asExpr() orelse return;
        if (expr == .block_expr) {
            _ = try self.checkBlock(expr.block_expr);
        }
    }

    /// Check string interpolation.
    fn checkStringInterp(self: *Checker, si: ast.StringInterp) CheckError!TypeIndex {
        for (si.segments) |segment| {
            switch (segment) {
                .text => {},
                .expr => |expr_idx| {
                    _ = try self.checkExpr(expr_idx);
                },
            }
        }
        return TypeRegistry.STRING;
    }

    /// Check address-of expression.
    fn checkAddrOf(self: *Checker, ao: ast.AddrOf) CheckError!TypeIndex {
        const operand_type = try self.checkExpr(ao.operand);
        return try self.types.makePointer(operand_type);
    }

    /// Check dereference expression.
    fn checkDeref(self: *Checker, d: ast.Deref) CheckError!TypeIndex {
        const operand_type = try self.checkExpr(d.operand);

        if (self.types.isPointer(operand_type)) {
            return self.types.pointerElem(operand_type);
        }

        self.err.errorWithCode(d.span.start, .e300, "cannot dereference non-pointer type");
        return invalid_type;
    }

    // ========================================================================
    // Statement checking
    // ========================================================================

    /// Check a statement.
    fn checkStmt(self: *Checker, idx: NodeIndex) CheckError!void {
        const node = self.tree.getNode(idx) orelse return;
        const stmt = node.asStmt() orelse return;

        switch (stmt) {
            .expr_stmt => |es| {
                _ = try self.checkExpr(es.expr);
            },
            .return_stmt => |rs| try self.checkReturn(rs),
            .var_stmt => |vs| try self.checkVarStmt(vs, idx),
            .assign_stmt => |as_stmt| try self.checkAssign(as_stmt),
            .if_stmt => |is| try self.checkIfStmt(is),
            .while_stmt => |ws| try self.checkWhileStmt(ws),
            .for_stmt => |fs| try self.checkForStmt(fs),
            .block_stmt => |bs| try self.checkBlockStmt(bs),
            .break_stmt => |bs| {
                if (!self.in_loop) {
                    self.err.errorWithCode(bs.span.start, .e300, "break outside of loop");
                }
            },
            .continue_stmt => |cs| {
                if (!self.in_loop) {
                    self.err.errorWithCode(cs.span.start, .e300, "continue outside of loop");
                }
            },
            .defer_stmt => |ds| {
                _ = try self.checkExpr(ds.expr);
            },
            .bad_stmt => {},
        }
    }

    /// Check return statement.
    fn checkReturn(self: *Checker, rs: ast.ReturnStmt) CheckError!void {
        if (rs.value != null_node) {
            const val_type = try self.checkExpr(rs.value);
            if (self.current_return_type == TypeRegistry.VOID) {
                self.err.errorWithCode(rs.span.start, .e300, "void function should not return a value");
            } else if (!self.types.isAssignable(val_type, self.current_return_type)) {
                self.errTypeMismatch(rs.span.start, self.current_return_type, val_type);
            }
        } else {
            if (self.current_return_type != TypeRegistry.VOID) {
                self.err.errorWithCode(rs.span.start, .e300, "non-void function must return a value");
            }
        }
    }

    /// Check var statement (local variable).
    fn checkVarStmt(self: *Checker, vs: ast.VarStmt, idx: NodeIndex) CheckError!void {
        if (self.scope.isDefined(vs.name)) {
            self.errRedefined(vs.span.start, vs.name);
            return;
        }

        var var_type: TypeIndex = invalid_type;

        if (vs.type_expr != null_node) {
            var_type = try self.resolveTypeExpr(vs.type_expr);
        }

        if (vs.value != null_node) {
            const val_type = try self.checkExpr(vs.value);
            if (var_type == invalid_type) {
                var_type = self.materializeType(val_type);
            } else if (!self.types.isAssignable(val_type, var_type)) {
                self.errTypeMismatch(vs.span.start, var_type, val_type);
            }
        }

        try self.scope.define(Symbol.init(
            vs.name,
            if (vs.is_const) .constant else .variable,
            var_type,
            idx,
            !vs.is_const,
        ));
    }

    /// Check assignment statement.
    fn checkAssign(self: *Checker, as_stmt: ast.AssignStmt) CheckError!void {
        const target_type = try self.checkExpr(as_stmt.target);
        const value_type = try self.checkExpr(as_stmt.value);

        // Check target is assignable (lvalue)
        const target_node = self.tree.getNode(as_stmt.target) orelse return;
        const target = target_node.asExpr() orelse return;

        switch (target) {
            .ident => |id| {
                if (self.scope.lookup(id.name)) |sym| {
                    if (!sym.mutable) {
                        self.err.errorWithCode(as_stmt.span.start, .e300, "cannot assign to constant");
                        return;
                    }
                }
            },
            .index, .field_access, .deref => {},
            else => {
                self.err.errorWithCode(as_stmt.span.start, .e300, "invalid assignment target");
                return;
            },
        }

        if (!self.types.isAssignable(value_type, target_type)) {
            self.errTypeMismatch(as_stmt.span.start, target_type, value_type);
        }
    }

    /// Check if statement.
    fn checkIfStmt(self: *Checker, is: ast.IfStmt) CheckError!void {
        const cond_type = try self.checkExpr(is.condition);
        if (!types.isBool(self.types.get(cond_type))) {
            self.err.errorWithCode(is.span.start, .e300, "condition must be bool");
        }

        try self.checkStmt(is.then_branch);

        if (is.else_branch != null_node) {
            try self.checkStmt(is.else_branch);
        }
    }

    /// Check while statement.
    fn checkWhileStmt(self: *Checker, ws: ast.WhileStmt) CheckError!void {
        const cond_type = try self.checkExpr(ws.condition);
        if (!types.isBool(self.types.get(cond_type))) {
            self.err.errorWithCode(ws.span.start, .e300, "condition must be bool");
        }

        const old_in_loop = self.in_loop;
        self.in_loop = true;
        try self.checkStmt(ws.body);
        self.in_loop = old_in_loop;
    }

    /// Check for statement.
    fn checkForStmt(self: *Checker, fs: ast.ForStmt) CheckError!void {
        const iter_type = try self.checkExpr(fs.iterable);
        const iter = self.types.get(iter_type);

        const elem_type: TypeIndex = switch (iter) {
            .array => |a| a.elem,
            .slice => |s| s.elem,
            else => blk: {
                self.err.errorWithCode(fs.span.start, .e300, "cannot iterate over this type");
                break :blk invalid_type;
            },
        };

        var loop_scope = Scope.init(self.allocator, self.scope);
        defer loop_scope.deinit();

        try loop_scope.define(Symbol.init(fs.binding, .variable, elem_type, null_node, false));

        const old_scope = self.scope;
        const old_in_loop = self.in_loop;
        self.scope = &loop_scope;
        self.in_loop = true;

        try self.checkStmt(fs.body);

        self.scope = old_scope;
        self.in_loop = old_in_loop;
    }

    /// Check block statement.
    fn checkBlockStmt(self: *Checker, bs: ast.BlockStmt) CheckError!void {
        var block_scope = Scope.init(self.allocator, self.scope);
        defer block_scope.deinit();

        const old_scope = self.scope;
        self.scope = &block_scope;

        for (bs.stmts) |stmt_idx| {
            try self.checkStmt(stmt_idx);
        }

        self.scope = old_scope;
    }

    // ========================================================================
    // Type resolution
    // ========================================================================

    /// Resolve a type expression to a TypeIndex.
    fn resolveTypeExpr(self: *Checker, idx: NodeIndex) CheckError!TypeIndex {
        if (idx == null_node) return invalid_type;

        const node = self.tree.getNode(idx) orelse return invalid_type;
        const expr = node.asExpr() orelse return invalid_type;
        if (expr != .type_expr) return invalid_type;

        return self.resolveType(expr.type_expr);
    }

    /// Resolve a TypeExpr to TypeIndex.
    fn resolveType(self: *Checker, te: ast.TypeExpr) CheckError!TypeIndex {
        return switch (te.kind) {
            .named => |name| {
                if (self.types.lookupBasic(name)) |idx| {
                    return idx;
                }
                if (self.scope.lookup(name)) |sym| {
                    if (sym.kind == .type_name) {
                        return sym.type_idx;
                    }
                }
                self.errUndefined(te.span.start, name);
                return invalid_type;
            },
            .pointer => |elem_idx| {
                const elem = try self.resolveTypeExpr(elem_idx);
                return try self.types.makePointer(elem);
            },
            .optional => |elem_idx| {
                const elem = try self.resolveTypeExpr(elem_idx);
                return try self.types.makeOptional(elem);
            },
            .slice => |elem_idx| {
                const elem = try self.resolveTypeExpr(elem_idx);
                return try self.types.makeSlice(elem);
            },
            .array => |a| {
                const elem = try self.resolveTypeExpr(a.elem);
                const size_node = self.tree.getNode(a.size) orelse return invalid_type;
                const size_expr = size_node.asExpr() orelse return invalid_type;
                const size: u64 = if (size_expr == .literal and size_expr.literal.kind == .int)
                    std.fmt.parseInt(u64, size_expr.literal.value, 0) catch 0
                else
                    0;
                return try self.types.makeArray(elem, size);
            },
            .map => |m| {
                const key = try self.resolveTypeExpr(m.key);
                const value = try self.resolveTypeExpr(m.value);
                return try self.types.makeMap(key, value);
            },
            .list => |elem_idx| {
                const elem = try self.resolveTypeExpr(elem_idx);
                return try self.types.makeList(elem);
            },
            .function => {
                // TODO: function types
                return invalid_type;
            },
        };
    }

    /// Build a function type from parameters and return type.
    fn buildFuncType(self: *Checker, params: []const ast.Field, return_type_idx: NodeIndex) CheckError!TypeIndex {
        var func_params = std.ArrayListUnmanaged(types.FuncParam){};
        defer func_params.deinit(self.allocator);

        for (params) |param| {
            const param_type = try self.resolveTypeExpr(param.type_expr);
            try func_params.append(self.allocator, .{
                .name = param.name,
                .type_idx = param_type,
            });
        }

        const ret_type: TypeIndex = if (return_type_idx != null_node)
            try self.resolveTypeExpr(return_type_idx)
        else
            TypeRegistry.VOID;

        return try self.types.add(.{ .func = .{
            .params = try self.allocator.dupe(types.FuncParam, func_params.items),
            .return_type = ret_type,
        } });
    }

    /// Build a struct type from fields.
    fn buildStructType(self: *Checker, name: []const u8, fields: []const ast.Field) CheckError!TypeIndex {
        var struct_fields = std.ArrayListUnmanaged(types.StructField){};
        defer struct_fields.deinit(self.allocator);

        var offset: u32 = 0;
        for (fields) |field| {
            const field_type = try self.resolveTypeExpr(field.type_expr);
            const field_size = self.types.sizeOf(field_type);
            const field_align = self.types.alignmentOf(field_type);

            if (field_align > 0) {
                offset = (offset + field_align - 1) & ~(field_align - 1);
            }

            try struct_fields.append(self.allocator, .{
                .name = field.name,
                .type_idx = field_type,
                .offset = offset,
            });
            offset += field_size;
        }

        offset = (offset + 7) & ~@as(u32, 7);

        return try self.types.add(.{ .struct_type = .{
            .name = name,
            .fields = try self.allocator.dupe(types.StructField, struct_fields.items),
            .size = offset,
            .alignment = 8,
        } });
    }

    /// Build an enum type from an AST enum declaration.
    fn buildEnumType(self: *Checker, e: ast.EnumDecl) CheckError!TypeIndex {
        var backing_type: TypeIndex = TypeRegistry.I32;
        if (e.backing_type != null_node) {
            backing_type = try self.resolveTypeExpr(e.backing_type);
        }

        var enum_variants = std.ArrayListUnmanaged(types.EnumVariant){};
        defer enum_variants.deinit(self.allocator);

        var next_value: i64 = 0;
        for (e.variants) |variant| {
            var value = next_value;
            if (variant.value != null_node) {
                const val_node = self.tree.getNode(variant.value);
                if (val_node) |node| {
                    if (node.asExpr()) |expr| {
                        if (expr == .literal and expr.literal.kind == .int) {
                            value = std.fmt.parseInt(i64, expr.literal.value, 0) catch 0;
                        }
                    }
                }
            }
            try enum_variants.append(self.allocator, .{
                .name = variant.name,
                .value = value,
            });
            next_value = value + 1;
        }

        return try self.types.add(.{ .enum_type = .{
            .name = e.name,
            .backing_type = backing_type,
            .variants = try self.allocator.dupe(types.EnumVariant, enum_variants.items),
        } });
    }

    /// Build a union type from a union declaration.
    fn buildUnionType(self: *Checker, u: ast.UnionDecl) CheckError!TypeIndex {
        var union_variants = std.ArrayListUnmanaged(types.UnionVariant){};
        defer union_variants.deinit(self.allocator);

        for (u.variants) |variant| {
            var payload_type: TypeIndex = invalid_type;
            if (variant.type_expr != null_node) {
                payload_type = try self.resolveTypeExpr(variant.type_expr);
            }
            try union_variants.append(self.allocator, .{
                .name = variant.name,
                .payload_type = payload_type,
            });
        }

        const tag_type: TypeIndex = if (u.variants.len <= 256) TypeRegistry.U8 else TypeRegistry.U16;

        return try self.types.add(.{ .union_type = .{
            .name = u.name,
            .variants = try self.allocator.dupe(types.UnionVariant, union_variants.items),
            .tag_type = tag_type,
        } });
    }

    // ========================================================================
    // Type utilities
    // ========================================================================

    /// Materialize an untyped type to a concrete type.
    fn materializeType(self: *Checker, idx: TypeIndex) TypeIndex {
        const t = self.types.get(idx);
        return switch (t) {
            .basic => |k| switch (k) {
                .untyped_int => TypeRegistry.INT,
                .untyped_float => TypeRegistry.FLOAT,
                .untyped_bool => TypeRegistry.BOOL,
                else => idx,
            },
            else => idx,
        };
    }

    /// Check if two types are comparable.
    fn isComparable(self: *Checker, a: TypeIndex, b: TypeIndex) bool {
        if (self.types.equal(a, b)) return true;

        const ta = self.types.get(a);
        const tb = self.types.get(b);
        if (types.isNumeric(ta) and types.isNumeric(tb)) return true;

        // Byte slices ([]u8) are comparable
        if (ta == .slice and tb == .slice) {
            if (ta.slice.elem == TypeRegistry.U8 and tb.slice.elem == TypeRegistry.U8) {
                return true;
            }
        }

        return false;
    }

    // ========================================================================
    // Error helpers
    // ========================================================================

    fn errUndefined(self: *Checker, pos: Pos, name: []const u8) void {
        _ = name;
        self.err.errorWithCode(pos, .e301, "undefined identifier");
    }

    fn errRedefined(self: *Checker, pos: Pos, name: []const u8) void {
        _ = name;
        self.err.errorWithCode(pos, .e302, "redefined identifier");
    }

    fn errTypeMismatch(self: *Checker, pos: Pos, expected: TypeIndex, got: TypeIndex) void {
        _ = expected;
        _ = got;
        self.err.errorWithCode(pos, .e300, "type mismatch");
    }

    fn errInvalidOp(self: *Checker, pos: Pos, op_kind: []const u8, left: TypeIndex, right: TypeIndex) void {
        _ = op_kind;
        _ = left;
        _ = right;
        self.err.errorWithCode(pos, .e300, "invalid operation");
    }
};

// =========================================
// Tests
// =========================================

test "Scope define and lookup" {
    var scope = Scope.init(std.testing.allocator, null);
    defer scope.deinit();

    try scope.define(Symbol.init("x", .variable, TypeRegistry.INT, 0, true));

    const sym = scope.lookup("x");
    try std.testing.expect(sym != null);
    try std.testing.expectEqualStrings("x", sym.?.name);
    try std.testing.expectEqual(TypeRegistry.INT, sym.?.type_idx);
}

test "Scope parent lookup" {
    var parent = Scope.init(std.testing.allocator, null);
    defer parent.deinit();

    try parent.define(Symbol.init("x", .variable, TypeRegistry.INT, 0, true));

    var child = Scope.init(std.testing.allocator, &parent);
    defer child.deinit();

    try child.define(Symbol.init("y", .variable, TypeRegistry.BOOL, 1, false));

    // Child can find its own symbols
    try std.testing.expect(child.lookup("y") != null);

    // Child can find parent symbols
    try std.testing.expect(child.lookup("x") != null);

    // Parent cannot find child symbols
    try std.testing.expect(parent.lookup("y") == null);
}

test "Scope isDefined only checks local" {
    var parent = Scope.init(std.testing.allocator, null);
    defer parent.deinit();

    try parent.define(Symbol.init("x", .variable, TypeRegistry.INT, 0, true));

    var child = Scope.init(std.testing.allocator, &parent);
    defer child.deinit();

    // x is not defined locally in child
    try std.testing.expect(!child.isDefined("x"));

    // but x can be looked up through parent
    try std.testing.expect(child.lookup("x") != null);
}

test "Symbol init" {
    const sym = Symbol.init("foo", .function, TypeRegistry.VOID, 42, false);
    try std.testing.expectEqualStrings("foo", sym.name);
    try std.testing.expectEqual(SymbolKind.function, sym.kind);
    try std.testing.expectEqual(TypeRegistry.VOID, sym.type_idx);
    try std.testing.expectEqual(@as(NodeIndex, 42), sym.node);
    try std.testing.expect(!sym.mutable);
}

test "checker type registry lookup" {
    var type_reg = try TypeRegistry.init(std.testing.allocator);
    defer type_reg.deinit();

    // Verify basic type lookup works
    try std.testing.expectEqual(TypeRegistry.INT, type_reg.lookupBasic("int").?);
    try std.testing.expectEqual(TypeRegistry.BOOL, type_reg.lookupBasic("bool").?);
    try std.testing.expectEqual(TypeRegistry.STRING, type_reg.lookupBasic("string").?);
}

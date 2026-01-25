//! Abstract Syntax Tree node definitions.
//!
//! Architecture modeled on Go's go/ast package:
//! - Tagged unions for node variants (Decl, Expr, Stmt)
//! - NodeIndex as u32 for compact arena storage
//! - Span tracking on all nodes for error messages
//!
//! Derived from working bootstrap AST.

const std = @import("std");
const source = @import("source.zig");
const token = @import("token.zig");

const Span = source.Span;
const Pos = source.Pos;
const Token = token.Token;

// =========================================
// Core Types
// =========================================

/// Index into node pool. Using indices instead of pointers allows
/// arena allocation and compact storage.
pub const NodeIndex = u32;

/// Sentinel for missing/null nodes.
pub const null_node: NodeIndex = std.math.maxInt(NodeIndex);

/// List of node indices.
pub const NodeList = []const NodeIndex;

// =========================================
// File (top-level)
// =========================================

/// A source file containing declarations.
pub const File = struct {
    filename: []const u8,
    decls: []const NodeIndex,
    span: Span,
};

// =========================================
// Declarations
// =========================================

pub const Decl = union(enum) {
    fn_decl: FnDecl,
    var_decl: VarDecl,
    struct_decl: StructDecl,
    enum_decl: EnumDecl,
    union_decl: UnionDecl,
    type_alias: TypeAlias,
    import_decl: ImportDecl,
    bad_decl: BadDecl,

    pub fn span(self: Decl) Span {
        return switch (self) {
            inline else => |d| d.span,
        };
    }
};

/// fn name(params) return_type { body }
/// extern fn name(params) return_type;
pub const FnDecl = struct {
    name: []const u8,
    params: []const Field,
    return_type: NodeIndex, // null_node = void
    body: NodeIndex, // null_node = forward declaration or extern
    is_extern: bool, // true for extern fn declarations
    span: Span,
};

/// var/const name: type = value
pub const VarDecl = struct {
    name: []const u8,
    type_expr: NodeIndex, // null_node = inferred
    value: NodeIndex, // null_node = uninitialized
    is_const: bool,
    span: Span,
};

/// struct Name { fields }
pub const StructDecl = struct {
    name: []const u8,
    fields: []const Field,
    span: Span,
};

/// enum Name { variants } or enum Name: BackingType { variants }
pub const EnumDecl = struct {
    name: []const u8,
    backing_type: NodeIndex, // null_node = default
    variants: []const EnumVariant,
    span: Span,
};

/// union Name { variants }
pub const UnionDecl = struct {
    name: []const u8,
    variants: []const UnionVariant,
    span: Span,
};

/// type Name = TargetType
pub const TypeAlias = struct {
    name: []const u8,
    target: NodeIndex,
    span: Span,
};

/// import "path"
pub const ImportDecl = struct {
    path: []const u8,
    span: Span,
};

/// Placeholder for malformed declaration
pub const BadDecl = struct {
    span: Span,
};

/// Field in struct or function parameter
pub const Field = struct {
    name: []const u8,
    type_expr: NodeIndex,
    default_value: NodeIndex, // null_node = no default
    span: Span,
};

/// Enum variant
pub const EnumVariant = struct {
    name: []const u8,
    value: NodeIndex, // null_node = auto
    span: Span,
};

/// Union variant
pub const UnionVariant = struct {
    name: []const u8,
    type_expr: NodeIndex, // null_node = no payload
    span: Span,
};

// =========================================
// Expressions
// =========================================

pub const Expr = union(enum) {
    ident: Ident,
    literal: Literal,
    binary: Binary,
    unary: Unary,
    call: Call,
    index: Index,
    slice_expr: SliceExpr,
    field_access: FieldAccess,
    array_literal: ArrayLiteral,
    paren: Paren,
    if_expr: IfExpr,
    switch_expr: SwitchExpr,
    block_expr: BlockExpr,
    struct_init: StructInit,
    new_expr: NewExpr,
    builtin_call: BuiltinCall,
    string_interp: StringInterp,
    type_expr: TypeExpr,
    addr_of: AddrOf,
    deref: Deref,
    bad_expr: BadExpr,

    pub fn span(self: Expr) Span {
        return switch (self) {
            inline else => |e| e.span,
        };
    }
};

/// Identifier
pub const Ident = struct {
    name: []const u8,
    span: Span,
};

/// Literal value
pub const Literal = struct {
    kind: LiteralKind,
    value: []const u8,
    span: Span,
};

pub const LiteralKind = enum {
    int,
    float,
    string,
    char,
    true_lit,
    false_lit,
    null_lit,
    undefined_lit,
};

/// Binary operation (x op y)
pub const Binary = struct {
    op: Token,
    left: NodeIndex,
    right: NodeIndex,
    span: Span,
};

/// Unary operation (op x)
pub const Unary = struct {
    op: Token,
    operand: NodeIndex,
    span: Span,
};

/// Function call (callee(args))
pub const Call = struct {
    callee: NodeIndex,
    args: []const NodeIndex,
    span: Span,
};

/// Index expression (base[index])
pub const Index = struct {
    base: NodeIndex,
    idx: NodeIndex,
    span: Span,
};

/// Slice expression (base[start:end])
pub const SliceExpr = struct {
    base: NodeIndex,
    start: NodeIndex, // null_node = from beginning
    end: NodeIndex, // null_node = to end
    span: Span,
};

/// Field access (base.field)
pub const FieldAccess = struct {
    base: NodeIndex,
    field: []const u8,
    span: Span,
};

/// Array literal ([elem1, elem2, ...])
pub const ArrayLiteral = struct {
    elements: []const NodeIndex,
    span: Span,
};

/// Parenthesized expression
pub const Paren = struct {
    inner: NodeIndex,
    span: Span,
};

/// If expression
pub const IfExpr = struct {
    condition: NodeIndex,
    then_branch: NodeIndex,
    else_branch: NodeIndex, // null_node if no else
    span: Span,
};

/// Switch expression
pub const SwitchExpr = struct {
    subject: NodeIndex,
    cases: []const SwitchCase,
    else_body: NodeIndex, // null_node if no else
    span: Span,
};

/// Switch case arm
pub const SwitchCase = struct {
    patterns: []const NodeIndex,
    capture: []const u8, // empty if no capture
    body: NodeIndex,
    span: Span,
};

/// Block expression { stmts; expr }
pub const BlockExpr = struct {
    stmts: []const NodeIndex,
    expr: NodeIndex, // final expression, null_node if none
    span: Span,
};

/// Struct initialization: Type{ .field = value }
pub const StructInit = struct {
    type_name: []const u8,
    fields: []const FieldInit,
    span: Span,
};

/// Field initializer
pub const FieldInit = struct {
    name: []const u8,
    value: NodeIndex,
    span: Span,
};

/// new Type()
pub const NewExpr = struct {
    type_node: NodeIndex,
    span: Span,
};

/// Builtin call: @sizeOf(T), @alignOf(T), @string(ptr, len), etc.
pub const BuiltinCall = struct {
    name: []const u8, // "sizeOf", "alignOf", "string", etc.
    type_arg: NodeIndex, // Type argument (for @sizeOf, @alignOf)
    args: [2]NodeIndex, // Expression arguments (for @string(ptr, len))
    span: Span,
};

/// String interpolation segment
pub const StringSegment = union(enum) {
    text: []const u8,
    expr: NodeIndex,
};

/// Interpolated string
pub const StringInterp = struct {
    segments: []const StringSegment,
    span: Span,
};

/// Type expression
pub const TypeExpr = struct {
    kind: TypeKind,
    span: Span,
};

pub const TypeKind = union(enum) {
    named: []const u8,
    pointer: NodeIndex,
    optional: NodeIndex,
    error_union: NodeIndex, // !T - can be T or error
    slice: NodeIndex,
    array: struct { size: NodeIndex, elem: NodeIndex },
    map: struct { key: NodeIndex, value: NodeIndex },
    list: NodeIndex,
    function: struct { params: []const NodeIndex, ret: NodeIndex },
};

/// Address-of (&expr)
pub const AddrOf = struct {
    operand: NodeIndex,
    span: Span,
};

/// Dereference (expr.*)
pub const Deref = struct {
    operand: NodeIndex,
    span: Span,
};

/// Placeholder for malformed expression
pub const BadExpr = struct {
    span: Span,
};

// =========================================
// Statements
// =========================================

pub const Stmt = union(enum) {
    expr_stmt: ExprStmt,
    return_stmt: ReturnStmt,
    var_stmt: VarStmt,
    assign_stmt: AssignStmt,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    for_stmt: ForStmt,
    block_stmt: BlockStmt,
    break_stmt: BreakStmt,
    continue_stmt: ContinueStmt,
    defer_stmt: DeferStmt,
    bad_stmt: BadStmt,

    pub fn span(self: Stmt) Span {
        return switch (self) {
            inline else => |s| s.span,
        };
    }
};

/// Expression statement
pub const ExprStmt = struct {
    expr: NodeIndex,
    span: Span,
};

/// return expr
pub const ReturnStmt = struct {
    value: NodeIndex, // null_node if void return
    span: Span,
};

/// var/const name: type = value (local variable)
pub const VarStmt = struct {
    name: []const u8,
    type_expr: NodeIndex, // null_node = inferred
    value: NodeIndex, // null_node = uninitialized
    is_const: bool,
    span: Span,
};

/// name = value or name op= value
pub const AssignStmt = struct {
    target: NodeIndex,
    op: Token, // .assign for simple, .add_assign etc for compound
    value: NodeIndex,
    span: Span,
};

/// if condition { then } else { else }
pub const IfStmt = struct {
    condition: NodeIndex,
    then_branch: NodeIndex,
    else_branch: NodeIndex, // null_node if no else
    span: Span,
};

/// while condition { body }
pub const WhileStmt = struct {
    condition: NodeIndex,
    body: NodeIndex,
    span: Span,
};

/// for item in iterable { body }
pub const ForStmt = struct {
    binding: []const u8,
    iterable: NodeIndex,
    body: NodeIndex,
    span: Span,
};

/// { statements }
pub const BlockStmt = struct {
    stmts: []const NodeIndex,
    span: Span,
};

/// break
pub const BreakStmt = struct {
    span: Span,
};

/// continue
pub const ContinueStmt = struct {
    span: Span,
};

/// defer expr
pub const DeferStmt = struct {
    expr: NodeIndex,
    span: Span,
};

/// Placeholder for malformed statement
pub const BadStmt = struct {
    span: Span,
};

// =========================================
// Node (unified storage)
// =========================================

/// Unified node that can be any AST element.
pub const Node = union(enum) {
    decl: Decl,
    expr: Expr,
    stmt: Stmt,

    pub fn span(self: Node) Span {
        return switch (self) {
            .decl => |d| d.span(),
            .expr => |e| e.span(),
            .stmt => |s| s.span(),
        };
    }

    pub fn asDecl(self: Node) ?Decl {
        return switch (self) {
            .decl => |d| d,
            else => null,
        };
    }

    pub fn asExpr(self: Node) ?Expr {
        return switch (self) {
            .expr => |e| e,
            else => null,
        };
    }

    pub fn asStmt(self: Node) ?Stmt {
        return switch (self) {
            .stmt => |s| s,
            else => null,
        };
    }
};

// =========================================
// Ast (storage container)
// =========================================

/// Storage for all AST nodes.
pub const Ast = struct {
    nodes: std.ArrayListUnmanaged(Node),
    allocator: std.mem.Allocator,
    file: ?File,

    pub fn init(allocator: std.mem.Allocator) Ast {
        return .{
            .nodes = .{},
            .allocator = allocator,
            .file = null,
        };
    }

    pub fn deinit(self: *Ast) void {
        // Free file.decls if it was allocated
        if (self.file) |file| {
            if (file.decls.len > 0) {
                self.allocator.free(file.decls);
            }
        }

        // Free all internal slices allocated by the parser
        for (self.nodes.items) |node| {
            switch (node) {
                .decl => |decl| switch (decl) {
                    .fn_decl => |fn_d| {
                        if (fn_d.params.len > 0) self.allocator.free(fn_d.params);
                    },
                    .struct_decl => |s| {
                        if (s.fields.len > 0) self.allocator.free(s.fields);
                    },
                    .enum_decl => |e| {
                        if (e.variants.len > 0) self.allocator.free(e.variants);
                    },
                    .union_decl => |u| {
                        if (u.variants.len > 0) self.allocator.free(u.variants);
                    },
                    else => {},
                },
                .expr => |expr| switch (expr) {
                    .type_expr => |t| switch (t.kind) {
                        .function => |f| {
                            if (f.params.len > 0) self.allocator.free(f.params);
                        },
                        else => {},
                    },
                    .call => |c| {
                        if (c.args.len > 0) self.allocator.free(c.args);
                    },
                    .array_literal => |a| {
                        if (a.elements.len > 0) self.allocator.free(a.elements);
                    },
                    .block_expr => |b| {
                        if (b.stmts.len > 0) self.allocator.free(b.stmts);
                    },
                    .switch_expr => |s| {
                        // Free each case's patterns
                        for (s.cases) |case| {
                            if (case.patterns.len > 0) self.allocator.free(case.patterns);
                        }
                        if (s.cases.len > 0) self.allocator.free(s.cases);
                    },
                    else => {},
                },
                .stmt => |stmt| switch (stmt) {
                    .block_stmt => |b| {
                        if (b.stmts.len > 0) self.allocator.free(b.stmts);
                    },
                    else => {},
                },
            }
        }

        self.nodes.deinit(self.allocator);
    }

    /// Add a node and return its index.
    pub fn addNode(self: *Ast, node: Node) !NodeIndex {
        const idx: NodeIndex = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, node);
        return idx;
    }

    /// Add an expression node.
    pub fn addExpr(self: *Ast, expr: Expr) !NodeIndex {
        return self.addNode(.{ .expr = expr });
    }

    /// Add a statement node.
    pub fn addStmt(self: *Ast, stmt: Stmt) !NodeIndex {
        return self.addNode(.{ .stmt = stmt });
    }

    /// Add a declaration node.
    pub fn addDecl(self: *Ast, decl: Decl) !NodeIndex {
        return self.addNode(.{ .decl = decl });
    }

    /// Get a node by index.
    pub fn getNode(self: *const Ast, idx: NodeIndex) ?Node {
        if (idx == null_node) return null;
        if (idx >= self.nodes.items.len) return null;
        return self.nodes.items[idx];
    }

    /// Get node count.
    pub fn nodeCount(self: *const Ast) usize {
        return self.nodes.items.len;
    }

    /// Get root declarations (top-level).
    pub fn getRootDecls(self: *const Ast) []const NodeIndex {
        if (self.file) |file| {
            return file.decls;
        }
        return &.{};
    }

    /// Get all import paths from this AST.
    /// Returns a slice of import paths (must be freed by caller).
    pub fn getImports(self: *const Ast, allocator: std.mem.Allocator) ![]const []const u8 {
        var imports = std.ArrayListUnmanaged([]const u8){};
        errdefer imports.deinit(allocator);

        for (self.getRootDecls()) |decl_idx| {
            if (self.getNode(decl_idx)) |node| {
                if (node.asDecl()) |decl| {
                    if (decl == .import_decl) {
                        try imports.append(allocator, decl.import_decl.path);
                    }
                }
            }
        }

        return imports.toOwnedSlice(allocator);
    }
};

// =========================================
// Tests
// =========================================

test "null_node is max value" {
    try std.testing.expectEqual(std.math.maxInt(u32), null_node);
}

test "Ast add and get nodes" {
    var tree = Ast.init(std.testing.allocator);
    defer tree.deinit();

    // Add an identifier expression
    const expr = Expr{ .ident = .{
        .name = "x",
        .span = Span.zero,
    } };
    const idx = try tree.addExpr(expr);

    try std.testing.expectEqual(@as(NodeIndex, 0), idx);
    try std.testing.expectEqual(@as(usize, 1), tree.nodeCount());

    const node = tree.getNode(idx).?;
    try std.testing.expectEqualStrings("x", node.asExpr().?.ident.name);
}

test "Ast null_node returns null" {
    var tree = Ast.init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expect(tree.getNode(null_node) == null);
}

test "Node span accessors" {
    const span = Span.init(Pos{ .offset = 5 }, Pos{ .offset = 10 });

    const decl_node = Node{ .decl = .{ .bad_decl = .{ .span = span } } };
    try std.testing.expectEqual(@as(u32, 5), decl_node.span().start.offset);

    const expr_node = Node{ .expr = .{ .bad_expr = .{ .span = span } } };
    try std.testing.expectEqual(@as(u32, 5), expr_node.span().start.offset);

    const stmt_node = Node{ .stmt = .{ .bad_stmt = .{ .span = span } } };
    try std.testing.expectEqual(@as(u32, 5), stmt_node.span().start.offset);
}

test "Decl span accessor" {
    const span = Span.init(Pos{ .offset = 0 }, Pos{ .offset = 10 });

    const fn_decl = Decl{ .fn_decl = .{
        .name = "main",
        .params = &.{},
        .return_type = null_node,
        .body = null_node,
        .is_extern = false,
        .span = span,
    } };
    try std.testing.expectEqual(@as(u32, 0), fn_decl.span().start.offset);
}

test "Expr span accessor" {
    const span = Span.init(Pos{ .offset = 0 }, Pos{ .offset = 5 });

    const ident = Expr{ .ident = .{
        .name = "foo",
        .span = span,
    } };
    try std.testing.expectEqual(@as(u32, 0), ident.span().start.offset);
}

test "Stmt span accessor" {
    const span = Span.init(Pos{ .offset = 0 }, Pos{ .offset = 10 });

    const return_stmt = Stmt{ .return_stmt = .{
        .value = null_node,
        .span = span,
    } };
    try std.testing.expectEqual(@as(u32, 0), return_stmt.span().start.offset);
}

test "LiteralKind enum" {
    try std.testing.expectEqual(LiteralKind.int, LiteralKind.int);
    try std.testing.expectEqual(LiteralKind.string, LiteralKind.string);
}

test "TypeKind union" {
    const named = TypeKind{ .named = "int" };
    try std.testing.expectEqualStrings("int", named.named);

    const ptr = TypeKind{ .pointer = 0 };
    try std.testing.expectEqual(@as(NodeIndex, 0), ptr.pointer);
}

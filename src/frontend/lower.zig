//! AST-to-IR Lowering Pass
//!
//! Transforms type-checked AST into flat IR suitable for SSA construction.
//! Following Go's cmd/compile/internal/walk patterns for AST simplification.
//!
//! Design principles:
//! 1. Walk AST in dependency order (declarations first, then expressions)
//! 2. Emit IR nodes using FuncBuilder for proper block management
//! 3. Track loop context for break/continue targets
//! 4. Handle control flow with explicit block creation
//!
//! Reference: ~/learning/go/src/cmd/compile/internal/walk/

const std = @import("std");
const ast = @import("ast.zig");
const ir = @import("ir.zig");
const types = @import("types.zig");
const source = @import("source.zig");
const errors = @import("errors.zig");
const checker = @import("checker.zig");
const token = @import("token.zig");
const debug = @import("../pipeline_debug.zig");

const Allocator = std.mem.Allocator;
const Ast = ast.Ast;
const NodeIndex = ast.NodeIndex;
const null_node = ast.null_node;
const TypeIndex = types.TypeIndex;
const TypeRegistry = types.TypeRegistry;
const Span = source.Span;
const Pos = source.Pos;
const ErrorReporter = errors.ErrorReporter;
const Token = token.Token;

// ============================================================================
// Lowerer Context
// ============================================================================

pub const Lowerer = struct {
    allocator: Allocator,
    tree: *const Ast,
    type_reg: *TypeRegistry,
    err: *ErrorReporter,
    builder: ir.Builder,
    chk: *const checker.Checker,

    // Current function context (like Go's Curfn)
    current_func: ?*ir.FuncBuilder = null,

    // Counter for generating unique names (for-loop desugaring, temps)
    temp_counter: u32 = 0,

    // Loop context stack for break/continue
    loop_stack: std.ArrayListUnmanaged(LoopContext),

    // Defer stack for pending defer expressions (Zig-style scope tracking)
    // When entering a block, record the current depth. On block exit, emit
    // defers from current depth down to recorded depth in LIFO order.
    defer_stack: std.ArrayListUnmanaged(NodeIndex),

    // Compile-time constant values
    const_values: std.StringHashMap(i64),

    /// Error type for lowering operations
    pub const Error = error{OutOfMemory};

    const LoopContext = struct {
        cond_block: ir.BlockIndex, // Jump target for continue
        exit_block: ir.BlockIndex, // Jump target for break
        defer_depth: usize, // Defer stack depth at loop entry (for break/continue)
    };

    pub fn init(
        allocator: Allocator,
        tree: *const Ast,
        type_reg: *TypeRegistry,
        err: *ErrorReporter,
        chk: *const checker.Checker,
    ) Lowerer {
        return .{
            .allocator = allocator,
            .tree = tree,
            .type_reg = type_reg,
            .err = err,
            .builder = ir.Builder.init(allocator, type_reg),
            .chk = chk,
            .loop_stack = .{},
            .defer_stack = .{},
            .const_values = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *Lowerer) void {
        self.loop_stack.deinit(self.allocator);
        self.defer_stack.deinit(self.allocator);
        self.const_values.deinit();
        self.builder.deinit();
    }

    /// Lower entire AST to IR.
    pub fn lower(self: *Lowerer) !ir.IR {
        // Process root declarations
        const root_nodes = self.tree.getRootDecls();
        for (root_nodes) |decl_idx| {
            try self.lowerDecl(decl_idx);
        }

        return try self.builder.getIR();
    }

    // ========================================================================
    // Declaration Lowering
    // ========================================================================

    fn lowerDecl(self: *Lowerer, idx: NodeIndex) !void {
        const node = self.tree.getNode(idx) orelse return;
        const decl = node.asDecl() orelse return;

        switch (decl) {
            .fn_decl => |fn_d| try self.lowerFnDecl(fn_d),
            .var_decl => |var_d| try self.lowerGlobalVarDecl(var_d),
            .struct_decl => |struct_d| try self.lowerStructDecl(struct_d),
            .enum_decl, .union_decl, .type_alias => {}, // Type-only, no codegen
            .import_decl, .bad_decl => {},
        }
    }

    fn lowerFnDecl(self: *Lowerer, fn_decl: ast.FnDecl) !void {
        // Skip extern functions - they have no body, resolved by linker
        if (fn_decl.is_extern) {
            debug.log(.lower, "Skipping extern function: {s}", .{fn_decl.name});
            return;
        }

        // Resolve return type
        const return_type = if (fn_decl.return_type != null_node)
            self.resolveTypeNode(fn_decl.return_type)
        else
            TypeRegistry.VOID;

        // Start building function
        self.builder.startFunc(fn_decl.name, TypeRegistry.VOID, return_type, fn_decl.span);

        if (self.builder.func()) |fb| {
            self.current_func = fb;

            // Clear defer stack for new function scope
            self.defer_stack.clearRetainingCapacity();

            // Add parameters
            for (fn_decl.params) |param| {
                const param_type = self.resolveTypeNode(param.type_expr);
                const param_size = self.type_reg.sizeOf(param_type);
                _ = try fb.addParam(param.name, param_type, param_size);
            }

            // Lower function body
            if (fn_decl.body != null_node) {
                _ = try self.lowerBlockNode(fn_decl.body);

                // Add implicit return for void functions
                if (return_type == TypeRegistry.VOID) {
                    const needs_ret = fb.needsTerminator();
                    if (needs_ret) {
                        // Emit any pending defers before implicit return
                        try self.emitDeferredExprs(0);
                        _ = try fb.emitRet(null, fn_decl.span);
                    }
                }
            }

            self.current_func = null;
        }

        try self.builder.endFunc();
    }

    fn lowerGlobalVarDecl(self: *Lowerer, var_decl: ast.VarDecl) !void {
        // Resolve type
        var type_idx = TypeRegistry.VOID;
        if (var_decl.type_expr != null_node) {
            type_idx = self.resolveTypeNode(var_decl.type_expr);
        } else if (var_decl.value != null_node) {
            type_idx = self.inferExprType(var_decl.value);
        }

        // For constants with compile-time values, store in const_values map
        // Following Go's pattern: constants are inlined, no runtime storage
        if (var_decl.is_const) {
            if (self.chk.scope.lookup(var_decl.name)) |sym| {
                if (sym.const_value) |value| {
                    debug.log(.lower, "Inlining constant '{s}' = {d}", .{ var_decl.name, value });
                    try self.const_values.put(var_decl.name, value);
                    return; // Don't create a global - value will be inlined
                }
            }
        }

        // Add as global (for non-constant or non-evaluatable constants)
        // Compute actual type size for proper memory allocation
        const type_size: u32 = @intCast(self.type_reg.sizeOf(type_idx));
        const global = ir.Global.initWithSize(var_decl.name, type_idx, var_decl.is_const, var_decl.span, type_size);
        try self.builder.addGlobal(global);
    }

    fn lowerStructDecl(self: *Lowerer, struct_decl: ast.StructDecl) !void {
        // Look up struct type
        const struct_type_idx = self.type_reg.lookupByName(struct_decl.name) orelse TypeRegistry.VOID;

        const struct_def = ir.StructDef{
            .name = struct_decl.name,
            .type_idx = struct_type_idx,
            .span = struct_decl.span,
        };
        try self.builder.addStruct(struct_def);
    }

    // ========================================================================
    // Statement Lowering
    // ========================================================================

    /// Lower a block node, returning true if it ends with a terminator
    fn lowerBlockNode(self: *Lowerer, idx: NodeIndex) Error!bool {
        const node = self.tree.getNode(idx) orelse return false;

        // Handle both block statements and block expressions
        if (node.asStmt()) |stmt| {
            return try self.lowerStmt(stmt);
        } else if (node.asExpr()) |expr| {
            switch (expr) {
                .block_expr => |block| {
                    var terminated = false;
                    for (block.stmts) |stmt_idx| {
                        const stmt_node = self.tree.getNode(stmt_idx) orelse continue;
                        if (stmt_node.asStmt()) |s| {
                            if (try self.lowerStmt(s)) {
                                terminated = true;
                                break; // Don't lower dead code
                            }
                        }
                    }
                    // Handle final expression if present
                    if (!terminated and block.expr != null_node) {
                        _ = try self.lowerExprNode(block.expr);
                    }
                    return terminated;
                },
                else => {
                    _ = try self.lowerExpr(expr);
                    return false;
                },
            }
        }

        return false;
    }

    fn lowerStmt(self: *Lowerer, stmt: ast.Stmt) Error!bool {
        switch (stmt) {
            .return_stmt => |ret| {
                try self.lowerReturn(ret);
                return true;
            },
            .var_stmt => |var_s| {
                try self.lowerLocalVarDecl(var_s);
                return false;
            },
            .assign_stmt => |assign| {
                try self.lowerAssign(assign);
                return false;
            },
            .if_stmt => |if_s| {
                try self.lowerIf(if_s);
                return false;
            },
            .while_stmt => |while_s| {
                try self.lowerWhile(while_s);
                return false;
            },
            .for_stmt => |for_s| {
                try self.lowerFor(for_s);
                return false;
            },
            .block_stmt => |block| {
                // Track defer depth for block scope
                const defer_depth = self.defer_stack.items.len;

                for (block.stmts) |stmt_idx| {
                    const stmt_node = self.tree.getNode(stmt_idx) orelse continue;
                    if (stmt_node.asStmt()) |s| {
                        if (try self.lowerStmt(s)) {
                            // Terminated by return/break/continue - they handle defers
                            return true;
                        }
                    }
                }

                // Normal block exit: emit block-scoped defers
                try self.emitDeferredExprs(defer_depth);
                return false;
            },
            .break_stmt => {
                try self.lowerBreak();
                return true;
            },
            .continue_stmt => {
                try self.lowerContinue();
                return true;
            },
            .expr_stmt => |expr_s| {
                _ = try self.lowerExprNode(expr_s.expr);
                return false;
            },
            .defer_stmt => |ds| {
                // Push deferred expression onto stack - will be emitted at scope exit
                try self.defer_stack.append(self.allocator, ds.expr);
                debug.log(.lower, "lowerDefer: pushed expr to defer stack (depth: {d})", .{self.defer_stack.items.len});
                return false;
            },
            .bad_stmt => return false,
        }
    }

    fn lowerReturn(self: *Lowerer, ret: ast.ReturnStmt) !void {
        const fb = self.current_func orelse return;

        // Evaluate return value BEFORE defers (value computed, then defers run)
        var value_node: ?ir.NodeIndex = null;
        if (ret.value != null_node) {
            value_node = try self.lowerExprNode(ret.value);
        }

        // Emit all deferred expressions in LIFO order (Zig semantics)
        try self.emitDeferredExprs(0);

        // Now emit the return with the pre-computed value
        _ = try fb.emitRet(value_node, ret.span);
    }

    /// Emit deferred expressions from current stack depth down to target depth.
    /// Emits in LIFO order (last defer first) and pops the stack.
    fn emitDeferredExprs(self: *Lowerer, target_depth: usize) Error!void {
        while (self.defer_stack.items.len > target_depth) {
            // pop() returns ?T in Zig 0.15, but we've checked length so it's safe
            const defer_expr = self.defer_stack.pop() orelse break;
            debug.log(.lower, "emitDeferredExprs: emitting defer (remaining: {d})", .{self.defer_stack.items.len});
            _ = try self.lowerExprNode(defer_expr);
        }
    }

    fn lowerLocalVarDecl(self: *Lowerer, var_stmt: ast.VarStmt) !void {
        const fb = self.current_func orelse return;

        // Resolve type
        var type_idx = TypeRegistry.VOID;
        if (var_stmt.type_expr != null_node) {
            type_idx = self.resolveTypeNode(var_stmt.type_expr);
        } else if (var_stmt.value != null_node) {
            type_idx = self.inferExprType(var_stmt.value);
        }

        const size = self.type_reg.sizeOf(type_idx);
        const local_idx = try fb.addLocalWithSize(var_stmt.name, type_idx, !var_stmt.is_const, size);

        // Initialize if there's a value
        if (var_stmt.value != null_node) {
            const is_array = self.type_reg.isArray(type_idx);
            debug.log(.lower, "lowerLocalVarDecl var='{s}' type={d} isArray={}", .{ var_stmt.name, type_idx, is_array });

            // Check if value is a struct literal
            const value_node_ast = self.tree.getNode(var_stmt.value);
            const value_expr = if (value_node_ast) |n| n.asExpr() else null;
            const is_struct_literal = if (value_expr) |e| e == .struct_init else false;

            // Special handling for string type: store (ptr, len) pair
            if (type_idx == TypeRegistry.STRING) {
                debug.log(.lower, "  -> string path", .{});
                try self.lowerStringInit(local_idx, var_stmt.value, var_stmt.span);
            } else if (is_array) {
                debug.log(.lower, "  -> array path", .{});
                // Special handling for array literals: initialize directly into variable storage
                try self.lowerArrayInit(local_idx, var_stmt.value, var_stmt.span);
            } else if (is_struct_literal) {
                debug.log(.lower, "  -> struct literal path", .{});
                // Special handling for struct literals: initialize field-by-field
                try self.lowerStructInit(local_idx, var_stmt.value, var_stmt.span);
            } else {
                debug.log(.lower, "  -> default path", .{});
                const value_node = try self.lowerExprNode(var_stmt.value);
                _ = try fb.emitStoreLocal(local_idx, value_node, var_stmt.span);
            }
        }
    }

    /// Lower array initialization: store elements directly into local variable storage.
    /// Following Go's pattern from cmd/compile/internal/walk/complit.go:
    /// Array literals are initialized element-by-element directly into the destination.
    fn lowerArrayInit(self: *Lowerer, local_idx: ir.LocalIdx, value_idx: NodeIndex, span: source.Span) !void {
        debug.log(.lower, "lowerArrayInit local_idx={d}", .{local_idx});

        const fb = self.current_func orelse return;

        const value_node = self.tree.getNode(value_idx) orelse return;
        const value_expr = value_node.asExpr() orelse return;

        debug.log(.lower, "  value_expr tag={s}", .{@tagName(value_expr)});

        // Check if it's an array literal using switch (more reliable than == comparison)
        switch (value_expr) {
            .array_literal => |al| {
                if (al.elements.len == 0) return;

                // CRITICAL: Get element type and size from the LOCAL variable's type,
                // not from the array literal. This handles untyped -> typed conversion.
                // E.g., var buf: [4]u8 = [0, 0, 0, 0] needs elem_size=1 (u8), not 8 (untyped_int).
                const local = fb.locals.items[local_idx];
                const local_type = self.type_reg.get(local.type_idx);
                const elem_type = if (local_type == .array) local_type.array.elem else self.inferExprType(al.elements[0]);
                const elem_size = self.type_reg.sizeOf(elem_type);
                debug.log(.lower, "  elem_type={d} elem_size={d} count={d}", .{ elem_type, elem_size, al.elements.len });

                // Initialize each element directly into the destination local
                // This follows Go's fixedlit pattern: var[index] = value for each element
                for (al.elements, 0..) |elem_idx, i| {
                    const elem_node = try self.lowerExprNode(elem_idx);
                    const idx_node = try fb.emitConstInt(@intCast(i), TypeRegistry.I64, span);
                    _ = try fb.emitStoreIndexLocal(local_idx, idx_node, elem_node, elem_size, span);
                }
            },
            else => {
                // Array copy: var b: [N]T = a
                // Following Go's pattern from ssagen/ssa.go: arrays use memory operations
                // For multi-element arrays, copy element-by-element: b[i] = a[i] for i in 0..N
                // This follows Go's moveWhichMayOverlap pattern

                // Get array type info for element size and count
                const local = fb.locals.items[local_idx];
                const arr_type = self.type_reg.get(local.type_idx);
                if (arr_type == .array) {
                    const elem_type = arr_type.array.elem;
                    const elem_size = self.type_reg.sizeOf(elem_type);
                    const arr_len = arr_type.array.length;

                    // Check if source is a local identifier (most common case)
                    if (value_expr == .ident) {
                        if (fb.lookupLocal(value_expr.ident.name)) |src_local_idx| {
                            // Copy each element: dst[i] = src[i]
                            for (0..arr_len) |i| {
                                const idx_node = try fb.emitConstInt(@intCast(i), TypeRegistry.I64, span);
                                // Load src[i]
                                const src_elem = try fb.emitIndexLocal(src_local_idx, idx_node, elem_size, elem_type, span);
                                // Store to dst[i]
                                _ = try fb.emitStoreIndexLocal(local_idx, idx_node, src_elem, elem_size, span);
                            }
                            return;
                        }
                    }

                    // Fallback: evaluate expression once, treat result as base address
                    // This handles cases like: var b = getArray()
                    const src_val = try self.lowerExprNode(value_idx);
                    for (0..arr_len) |i| {
                        const idx_node = try fb.emitConstInt(@intCast(i), TypeRegistry.I64, span);
                        // Index into the computed value
                        const src_elem = try fb.emitIndexValue(src_val, idx_node, elem_size, elem_type, span);
                        // Store to dst[i]
                        _ = try fb.emitStoreIndexLocal(local_idx, idx_node, src_elem, elem_size, span);
                    }
                } else {
                    // Not an array type, use default store
                    const value_node_ir = try self.lowerExprNode(value_idx);
                    _ = try fb.emitStoreLocal(local_idx, value_node_ir, span);
                }
            },
        }
    }

    /// Lower struct literal initialization: store fields directly into local variable storage.
    /// Following Go's pattern from cmd/compile/internal/walk/complit.go:
    /// Struct literals generate: var.field = value for each field initializer.
    fn lowerStructInit(self: *Lowerer, local_idx: ir.LocalIdx, value_idx: NodeIndex, span: source.Span) !void {
        debug.log(.lower, "lowerStructInit local_idx={d}", .{local_idx});

        const fb = self.current_func orelse return;

        const value_node = self.tree.getNode(value_idx) orelse return;
        const value_expr = value_node.asExpr() orelse return;

        // Get struct literal
        if (value_expr != .struct_init) return;
        const struct_init = value_expr.struct_init;

        // Look up the struct type
        const struct_type_idx = self.type_reg.lookupByName(struct_init.type_name) orelse {
            debug.log(.lower, "  struct type '{s}' not found", .{struct_init.type_name});
            return;
        };

        const type_info = self.type_reg.get(struct_type_idx);
        const struct_type = switch (type_info) {
            .struct_type => |s| s,
            else => {
                debug.log(.lower, "  type '{s}' is not a struct", .{struct_init.type_name});
                return;
            },
        };

        debug.log(.lower, "  struct '{s}' has {d} fields, initializer has {d} fields", .{
            struct_init.type_name,
            struct_type.fields.len,
            struct_init.fields.len,
        });

        // Store each field value
        for (struct_init.fields) |field_init| {
            // Find the field in the struct type
            var found = false;
            for (struct_type.fields, 0..) |struct_field, i| {
                if (std.mem.eql(u8, struct_field.name, field_init.name)) {
                    const field_idx: u32 = @intCast(i);
                    const field_offset: i64 = @intCast(struct_field.offset);

                    // Lower the field value
                    const value_node_ir = try self.lowerExprNode(field_init.value);

                    // Store to the field
                    _ = try fb.emitStoreLocalField(local_idx, field_idx, field_offset, value_node_ir, span);

                    debug.log(.lower, "  stored field '{s}' at offset {d}", .{ field_init.name, field_offset });
                    found = true;
                    break;
                }
            }

            if (!found) {
                debug.log(.lower, "  WARNING: field '{s}' not found in struct", .{field_init.name});
            }
        }
    }

    /// Lower string initialization: store (ptr, len) pair to local variable.
    /// Following Go's pattern: string = struct { ptr *byte, len int }
    fn lowerStringInit(self: *Lowerer, local_idx: ir.LocalIdx, value_idx: NodeIndex, span: source.Span) !void {
        const fb = self.current_func orelse return;

        const value_node = self.tree.getNode(value_idx) orelse return;
        const value_expr = value_node.asExpr() orelse return;

        // Check if it's a string literal
        if (value_expr == .literal and value_expr.literal.kind == .string) {
            const lit = value_expr.literal;

            // Parse the string to get unescaped content and length
            var buf: [4096]u8 = undefined;
            const unescaped = parseStringLiteral(lit.value, &buf);
            const str_len: i64 = @intCast(unescaped.len);

            // Allocate copy of string data
            const copied = try self.allocator.dupe(u8, unescaped);

            // Store in string table and get index
            const str_idx = try fb.addStringLiteral(copied);

            // Emit const_slice for the address
            const ptr_node = try fb.emitConstSlice(str_idx, span);

            // Emit const_int for the length
            const len_node = try fb.emitConstInt(str_len, TypeRegistry.I64, span);

            // Store ptr at offset 0 (field 0)
            _ = try fb.emitStoreLocalField(local_idx, 0, 0, ptr_node, span);

            // Store len at offset 8 (field 1)
            _ = try fb.emitStoreLocalField(local_idx, 1, 8, len_node, span);
        } else if (value_expr == .ident) {
            // String variable copy: var s2 = s1
            // Strings are (ptr, len) pairs - copy both fields
            // Following Go's pattern: string = struct { ptr *byte, len int }
            if (fb.lookupLocal(value_expr.ident.name)) |src_local_idx| {
                // Load source ptr (field 0, offset 0)
                const src_ptr = try fb.emitFieldLocal(src_local_idx, 0, 0, TypeRegistry.I64, span);
                // Load source len (field 1, offset 8)
                const src_len = try fb.emitFieldLocal(src_local_idx, 1, 8, TypeRegistry.I64, span);

                // Store ptr to destination field 0
                _ = try fb.emitStoreLocalField(local_idx, 0, 0, src_ptr, span);
                // Store len to destination field 1
                _ = try fb.emitStoreLocalField(local_idx, 1, 8, src_len, span);
                return;
            }

            // Fallback for unknown identifiers
            const value_node_ir = try self.lowerExprNode(value_idx);
            _ = try fb.emitStoreLocal(local_idx, value_node_ir, span);
        } else {
            // Other expressions - lower normally
            const value_node_ir = try self.lowerExprNode(value_idx);
            _ = try fb.emitStoreLocal(local_idx, value_node_ir, span);
        }
    }

    fn lowerAssign(self: *Lowerer, assign: ast.AssignStmt) !void {
        const fb = self.current_func orelse return;

        // Get target expression
        const target_node = self.tree.getNode(assign.target) orelse return;
        const target_expr = target_node.asExpr() orelse return;

        switch (target_expr) {
            .ident => |ident| {
                // Try local variable first
                if (fb.lookupLocal(ident.name)) |local_idx| {
                    const local_type = fb.locals.items[local_idx].type_idx;

                    // Handle compound assignment
                    const value_node = if (assign.op != .assign) blk: {
                        // Load current value
                        const current = try fb.emitLoadLocal(local_idx, local_type, assign.span);
                        // Lower RHS
                        const rhs = try self.lowerExprNode(assign.value);
                        // Emit binary operation
                        const bin_op = tokenToBinaryOp(assign.op);
                        break :blk try fb.emitBinary(bin_op, current, rhs, local_type, assign.span);
                    } else blk: {
                        break :blk try self.lowerExprNode(assign.value);
                    };

                    _ = try fb.emitStoreLocal(local_idx, value_node, assign.span);
                    return;
                }

                // Try global variable
                if (self.builder.lookupGlobal(ident.name)) |g| {
                    debug.log(.lower, "lowerAssign: found global '{s}' at idx {d}", .{ ident.name, g.idx });

                    // Handle compound assignment
                    const value_node = if (assign.op != .assign) blk: {
                        // Load current value from global
                        const current = try fb.emitGlobalRef(g.idx, ident.name, g.global.type_idx, assign.span);
                        // Lower RHS
                        const rhs = try self.lowerExprNode(assign.value);
                        // Emit binary operation
                        const bin_op = tokenToBinaryOp(assign.op);
                        break :blk try fb.emitBinary(bin_op, current, rhs, g.global.type_idx, assign.span);
                    } else blk: {
                        break :blk try self.lowerExprNode(assign.value);
                    };

                    _ = try fb.emitGlobalStore(g.idx, ident.name, value_node, assign.span);
                    return;
                }
            },
            .field_access => |fa| {
                // Field assignment: struct.field = value
                // Following Go's pattern for OASSIGN to field

                // Get the base type
                const base_type_idx = self.inferExprType(fa.base);
                const base_type = self.type_reg.get(base_type_idx);

                // Must be a struct type
                const struct_type = switch (base_type) {
                    .struct_type => |st| st,
                    .pointer => |ptr| blk: {
                        const elem_type = self.type_reg.get(ptr.elem);
                        break :blk switch (elem_type) {
                            .struct_type => |st| st,
                            else => return,
                        };
                    },
                    else => return,
                };

                // Find the field
                var field_idx: u32 = 0;
                var field_offset: i64 = 0;
                for (struct_type.fields, 0..) |field, i| {
                    if (std.mem.eql(u8, field.name, fa.field)) {
                        field_idx = @intCast(i);
                        field_offset = @intCast(field.offset);
                        break;
                    }
                }

                // Lower the value being assigned
                const value_node = try self.lowerExprNode(assign.value);

                // Check if base is a local variable (direct access)
                const base_node = self.tree.getNode(fa.base) orelse return;
                const base_expr = base_node.asExpr() orelse return;

                if (base_expr == .ident) {
                    if (fb.lookupLocal(base_expr.ident.name)) |local_idx| {
                        const local = fb.locals.items[local_idx];
                        const local_type = self.type_reg.get(local.type_idx);

                        // Check if local is a POINTER to struct (ptr.field = val)
                        // Following Go's ODOTPTR pattern: load ptr, add offset, store
                        if (local_type == .pointer) {
                            // Load the pointer value from local
                            const ptr_val = try fb.emitLoadLocal(local_idx, local.type_idx, assign.span);
                            // Store value at ptr + field_offset using store_field
                            _ = try fb.emitStoreField(ptr_val, field_idx, field_offset, value_node, assign.span);
                            return;
                        }

                        // Emit StoreLocalField for direct store to struct local
                        _ = try fb.emitStoreLocalField(local_idx, field_idx, field_offset, value_node, assign.span);
                        return;
                    }

                    // Try global variable (g_pool.field = value)
                    if (self.builder.lookupGlobal(base_expr.ident.name)) |g| {
                        // Get address of global struct
                        const global_type = g.global.type_idx;
                        const ptr_type = self.type_reg.makePointer(global_type) catch TypeRegistry.VOID;
                        const global_addr = try fb.emitAddrGlobal(g.idx, base_expr.ident.name, ptr_type, assign.span);
                        // Store to field at offset
                        _ = try fb.emitStoreField(global_addr, field_idx, field_offset, value_node, assign.span);
                        return;
                    }
                }

                // Handle nested field access (e.g., o.inner.field = value)
                // The base is itself a field access, lower it to get an address
                if (base_expr == .field_access) {
                    // Lower the base field access - this returns an address for struct fields
                    const base_addr = try self.lowerFieldAccess(base_expr.field_access);
                    // Emit store to nested field
                    _ = try fb.emitStoreField(base_addr, field_idx, field_offset, value_node, assign.span);
                    return;
                }

                // Pointer field store handled above via ident check
            },
            .index => |idx| {
                // Array index assignment: arr[i] = x
                // Get array type info
                const base_type_idx = self.inferExprType(idx.base);
                const base_type = self.type_reg.get(base_type_idx);

                const elem_type: TypeIndex = switch (base_type) {
                    .array => |a| a.elem,
                    .slice => |s| s.elem,
                    else => return,
                };
                const elem_size = self.type_reg.sizeOf(elem_type);

                // Lower the index and value
                const index_node = try self.lowerExprNode(idx.idx);
                const value_node = try self.lowerExprNode(assign.value);

                // Check if base is a local variable
                const base_node = self.tree.getNode(idx.base) orelse return;
                const base_expr = base_node.asExpr() orelse return;

                if (base_expr == .ident) {
                    if (fb.lookupLocal(base_expr.ident.name)) |local_idx| {
                        const local = fb.locals.items[local_idx];
                        const local_type = self.type_reg.get(local.type_idx);

                        // Slice variables: load slice, extract ptr, store through ptr
                        // Following Go's pattern: slice element assignment
                        if (local_type == .slice) {
                            // Load the slice value (ptr + len)
                            const slice_val = try fb.emitLoadLocal(local_idx, local.type_idx, assign.span);
                            // Extract pointer from slice
                            const ptr_type = self.type_reg.makePointer(elem_type) catch TypeRegistry.I64;
                            const ptr_val = try fb.emitSlicePtr(slice_val, ptr_type, assign.span);
                            // Store through the pointer
                            _ = try fb.emitStoreIndexValue(ptr_val, index_node, value_node, elem_size, assign.span);
                            return;
                        }

                        // Array parameters are passed by reference - the local contains a pointer
                        if (local.is_param and self.type_reg.isArray(local.type_idx)) {
                            const ptr_val = try fb.emitLoadLocal(local_idx, local.type_idx, assign.span);
                            _ = try fb.emitStoreIndexValue(ptr_val, index_node, value_node, elem_size, assign.span);
                            return;
                        }
                        _ = try fb.emitStoreIndexLocal(local_idx, index_node, value_node, elem_size, assign.span);
                        return;
                    }
                }
                // Handle computed base (index into expression like getSlice()[0] = x)
                // Following Go's pattern: evaluate base, get address, store through it
                switch (base_type) {
                    .slice => {
                        // For slice expressions: lower base, extract ptr, store through
                        const base_val = try self.lowerExprNode(idx.base);
                        const ptr_type = self.type_reg.makePointer(elem_type) catch TypeRegistry.I64;
                        const ptr_val = try fb.emitSlicePtr(base_val, ptr_type, assign.span);
                        _ = try fb.emitStoreIndexValue(ptr_val, index_node, value_node, elem_size, assign.span);
                        return;
                    },
                    .pointer => {
                        // For pointer expressions: lower base, store through pointer
                        const base_val = try self.lowerExprNode(idx.base);
                        _ = try fb.emitStoreIndexValue(base_val, index_node, value_node, elem_size, assign.span);
                        return;
                    },
                    else => {
                        // For array expressions returned by value, we'd need to store to temp first
                        // This is rare - typically arrays are accessed through locals or pointers
                    },
                }
            },
            .deref => |d| {
                // Dereference assignment: ptr.* = value
                // Lower the pointer expression, then emit ptr_store_value
                const ptr_node = try self.lowerExprNode(d.operand);
                const value_node = try self.lowerExprNode(assign.value);
                _ = try fb.emitPtrStoreValue(ptr_node, value_node, assign.span);
            },
            else => {},
        }
    }

    fn lowerIf(self: *Lowerer, if_stmt: ast.IfStmt) !void {
        const fb = self.current_func orelse return;

        // Create blocks
        const then_block = try fb.newBlock("then");
        const else_block = if (if_stmt.else_branch != null_node)
            try fb.newBlock("else")
        else
            null;
        const merge_block = try fb.newBlock("if.end");

        // Lower condition
        const cond_node = try self.lowerExprNode(if_stmt.condition);
        _ = try fb.emitBranch(cond_node, then_block, else_block orelse merge_block, if_stmt.span);

        // Lower then branch
        fb.setBlock(then_block);
        const then_terminated = try self.lowerBlockNode(if_stmt.then_branch);
        if (!then_terminated) {
            _ = try fb.emitJump(merge_block, if_stmt.span);
        }

        // Lower else branch if present
        if (else_block) |eb| {
            fb.setBlock(eb);
            const else_terminated = try self.lowerBlockNode(if_stmt.else_branch);
            if (!else_terminated) {
                _ = try fb.emitJump(merge_block, if_stmt.span);
            }
        }

        // Continue in merge block
        fb.setBlock(merge_block);
    }

    fn lowerWhile(self: *Lowerer, while_stmt: ast.WhileStmt) !void {
        const fb = self.current_func orelse return;

        // Create blocks
        const cond_block = try fb.newBlock("while.cond");
        const body_block = try fb.newBlock("while.body");
        const exit_block = try fb.newBlock("while.end");

        // Jump to condition
        _ = try fb.emitJump(cond_block, while_stmt.span);

        // Condition block
        fb.setBlock(cond_block);
        const cond_node = try self.lowerExprNode(while_stmt.condition);
        _ = try fb.emitBranch(cond_node, body_block, exit_block, while_stmt.span);

        // Push loop context for break/continue (record defer depth for cleanup)
        try self.loop_stack.append(self.allocator, .{
            .cond_block = cond_block,
            .exit_block = exit_block,
            .defer_depth = self.defer_stack.items.len,
        });

        // Body block
        fb.setBlock(body_block);
        const body_terminated = try self.lowerBlockNode(while_stmt.body);
        if (!body_terminated) {
            _ = try fb.emitJump(cond_block, while_stmt.span);
        }

        // Pop loop context
        _ = self.loop_stack.pop();

        // Continue in exit block
        fb.setBlock(exit_block);
    }

    /// Lower for-in loop by desugaring to while loop.
    /// Following Go's cmd/compile/internal/walk/range.go pattern:
    ///
    /// for item in arr { body }
    ///
    /// Desugars to:
    ///   var __idx: i64 = 0;
    ///   var __len: i64 = len(arr);  // compile-time for arrays, runtime for slices
    ///   while __idx < __len {
    ///       let item = arr[__idx];
    ///       body
    ///       __idx = __idx + 1;
    ///   }
    fn lowerFor(self: *Lowerer, for_stmt: ast.ForStmt) !void {
        const fb = self.current_func orelse return;

        // Get iterable type and element type
        const iter_type = self.inferExprType(for_stmt.iterable);
        const iter_info = self.type_reg.get(iter_type);

        const elem_type: TypeIndex = switch (iter_info) {
            .array => |a| a.elem,
            .slice => |s| s.elem,
            else => TypeRegistry.VOID,
        };

        if (elem_type == TypeRegistry.VOID) {
            // Type checker should have caught this
            return;
        }

        const elem_size = self.type_reg.sizeOf(elem_type);

        // Generate unique names for temp variables
        const idx_name = try std.fmt.allocPrint(self.allocator, "__for_idx_{d}", .{self.temp_counter});
        self.temp_counter += 1;
        const len_name = try std.fmt.allocPrint(self.allocator, "__for_len_{d}", .{self.temp_counter});
        self.temp_counter += 1;

        // Create index variable: var __idx: i64 = 0;
        const idx_local = try fb.addLocalWithSize(idx_name, TypeRegistry.I64, true, 8);
        const zero = try fb.emitConstInt(0, TypeRegistry.I64, for_stmt.span);
        _ = try fb.emitStoreLocal(idx_local, zero, for_stmt.span);

        // Create length variable based on iterable type
        const len_local = try fb.addLocalWithSize(len_name, TypeRegistry.I64, false, 8);

        switch (iter_info) {
            .array => |a| {
                // For arrays, length is compile-time constant
                const len_val = try fb.emitConstInt(@intCast(a.length), TypeRegistry.I64, for_stmt.span);
                _ = try fb.emitStoreLocal(len_local, len_val, for_stmt.span);
            },
            .slice => {
                // For slices, call len() at runtime
                // First load the slice, then get its length
                const iter_node = self.tree.getNode(for_stmt.iterable) orelse return;
                const iter_expr = iter_node.asExpr() orelse return;

                if (iter_expr == .ident) {
                    if (fb.lookupLocal(iter_expr.ident.name)) |slice_local| {
                        const slice_val = try fb.emitLoadLocal(slice_local, iter_type, for_stmt.span);
                        const len_val = try fb.emitSliceLen(slice_val, for_stmt.span);
                        _ = try fb.emitStoreLocal(len_local, len_val, for_stmt.span);
                    }
                }
            },
            else => return,
        }

        // Create loop blocks
        const cond_block = try fb.newBlock("for.cond");
        const body_block = try fb.newBlock("for.body");
        const incr_block = try fb.newBlock("for.incr");
        const exit_block = try fb.newBlock("for.end");

        // Jump to condition
        _ = try fb.emitJump(cond_block, for_stmt.span);

        // Condition block: __idx < __len
        fb.setBlock(cond_block);
        const idx_val = try fb.emitLoadLocal(idx_local, TypeRegistry.I64, for_stmt.span);
        const len_val_cond = try fb.emitLoadLocal(len_local, TypeRegistry.I64, for_stmt.span);
        const cond = try fb.emitBinary(.lt, idx_val, len_val_cond, TypeRegistry.BOOL, for_stmt.span);
        _ = try fb.emitBranch(cond, body_block, exit_block, for_stmt.span);

        // Push loop context for break/continue
        // Note: continue goes to incr_block (increment then check), break goes to exit_block
        try self.loop_stack.append(self.allocator, .{
            .cond_block = incr_block, // continue -> increment
            .exit_block = exit_block, // break -> exit
            .defer_depth = self.defer_stack.items.len,
        });

        // Body block
        fb.setBlock(body_block);

        // Create binding variable: let item = arr[__idx];
        const binding_local = try fb.addLocalWithSize(for_stmt.binding, elem_type, false, elem_size);

        // Load current index
        const cur_idx = try fb.emitLoadLocal(idx_local, TypeRegistry.I64, for_stmt.span);

        // Get element at index based on iterable type
        switch (iter_info) {
            .array => {
                // For arrays: arr[__idx]
                const iter_node = self.tree.getNode(for_stmt.iterable) orelse return;
                const iter_expr = iter_node.asExpr() orelse return;

                if (iter_expr == .ident) {
                    if (fb.lookupLocal(iter_expr.ident.name)) |arr_local| {
                        const elem_val = try fb.emitIndexLocal(arr_local, cur_idx, elem_size, elem_type, for_stmt.span);
                        _ = try fb.emitStoreLocal(binding_local, elem_val, for_stmt.span);
                    }
                }
            },
            .slice => {
                // For slices: load slice, get ptr, index through ptr
                const iter_node = self.tree.getNode(for_stmt.iterable) orelse return;
                const iter_expr = iter_node.asExpr() orelse return;

                if (iter_expr == .ident) {
                    if (fb.lookupLocal(iter_expr.ident.name)) |slice_local| {
                        const slice_val = try fb.emitLoadLocal(slice_local, iter_type, for_stmt.span);
                        const ptr_type = self.type_reg.makePointer(elem_type) catch TypeRegistry.I64;
                        const ptr_val = try fb.emitSlicePtr(slice_val, ptr_type, for_stmt.span);
                        const elem_val = try fb.emitIndexValue(ptr_val, cur_idx, elem_size, elem_type, for_stmt.span);
                        _ = try fb.emitStoreLocal(binding_local, elem_val, for_stmt.span);
                    }
                }
            },
            else => {},
        }

        // Lower body
        const body_terminated = try self.lowerBlockNode(for_stmt.body);
        if (!body_terminated) {
            _ = try fb.emitJump(incr_block, for_stmt.span);
        }

        // Increment block: __idx = __idx + 1
        fb.setBlock(incr_block);
        const idx_before_incr = try fb.emitLoadLocal(idx_local, TypeRegistry.I64, for_stmt.span);
        const one = try fb.emitConstInt(1, TypeRegistry.I64, for_stmt.span);
        const idx_after_incr = try fb.emitBinary(.add, idx_before_incr, one, TypeRegistry.I64, for_stmt.span);
        _ = try fb.emitStoreLocal(idx_local, idx_after_incr, for_stmt.span);
        _ = try fb.emitJump(cond_block, for_stmt.span);

        // Pop loop context
        _ = self.loop_stack.pop();

        // Continue in exit block
        fb.setBlock(exit_block);
    }

    fn lowerBreak(self: *Lowerer) !void {
        const fb = self.current_func orelse return;
        if (self.loop_stack.items.len > 0) {
            const ctx = self.loop_stack.items[self.loop_stack.items.len - 1];
            // Emit defers from current depth down to loop entry
            try self.emitDeferredExprs(ctx.defer_depth);
            _ = try fb.emitJump(ctx.exit_block, Span.fromPos(Pos.zero));
        }
    }

    fn lowerContinue(self: *Lowerer) !void {
        const fb = self.current_func orelse return;
        if (self.loop_stack.items.len > 0) {
            const ctx = self.loop_stack.items[self.loop_stack.items.len - 1];
            // Emit defers from current depth down to loop entry
            try self.emitDeferredExprs(ctx.defer_depth);
            _ = try fb.emitJump(ctx.cond_block, Span.fromPos(Pos.zero));
        }
    }

    // ========================================================================
    // Expression Lowering
    // ========================================================================

    fn lowerExprNode(self: *Lowerer, idx: NodeIndex) Error!ir.NodeIndex {
        const node = self.tree.getNode(idx) orelse return ir.null_node;
        const expr = node.asExpr() orelse return ir.null_node;
        return try self.lowerExpr(expr);
    }

    fn lowerExpr(self: *Lowerer, expr: ast.Expr) Error!ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;

        switch (expr) {
            .literal => |lit| return try self.lowerLiteral(lit),
            .ident => |ident| return try self.lowerIdent(ident),
            .binary => |bin| return try self.lowerBinary(bin),
            .unary => |un| return try self.lowerUnary(un),
            .call => |call| return try self.lowerCall(call),
            .paren => |p| return try self.lowerExprNode(p.inner),
            .if_expr => |if_e| return try self.lowerIfExpr(if_e),
            .addr_of => |addr| {
                // Get local index if operand is identifier
                const operand_node = self.tree.getNode(addr.operand) orelse return ir.null_node;
                const operand_expr = operand_node.asExpr() orelse return ir.null_node;

                // Handle &arr[idx] - address of array element
                if (operand_expr == .index) {
                    const idx = operand_expr.index;
                    // Get element type from base array type
                    const base_type_idx = self.inferExprType(idx.base);
                    const base_type = self.type_reg.get(base_type_idx);
                    const elem_type: TypeIndex = switch (base_type) {
                        .array => |a| a.elem,
                        .slice => |s| s.elem,
                        else => return ir.null_node,
                    };
                    const elem_size = self.type_reg.sizeOf(elem_type);
                    const ptr_type = self.type_reg.makePointer(elem_type) catch TypeRegistry.VOID;

                    // Lower the index expression
                    const index_node = try self.lowerExprNode(idx.idx);

                    // Check if base is a local or global variable
                    const base_node = self.tree.getNode(idx.base) orelse return ir.null_node;
                    const base_expr = base_node.asExpr() orelse return ir.null_node;
                    if (base_expr == .ident) {
                        // Try local variable first
                        if (fb.lookupLocal(base_expr.ident.name)) |local_idx| {
                            // Get address of local array, then compute element address
                            const local_type = fb.locals.items[local_idx].type_idx;
                            const base_ptr_type = self.type_reg.makePointer(local_type) catch TypeRegistry.VOID;
                            const base_addr = try fb.emitAddrLocal(local_idx, base_ptr_type, addr.span);
                            return try fb.emitAddrIndex(base_addr, index_node, elem_size, ptr_type, addr.span);
                        }
                        // Try global variable
                        if (self.builder.lookupGlobal(base_expr.ident.name)) |g| {
                            // Get address of global array, then compute element address
                            const base_ptr_type = self.type_reg.makePointer(g.global.type_idx) catch TypeRegistry.VOID;
                            const base_addr = try fb.emitAddrGlobal(g.idx, base_expr.ident.name, base_ptr_type, addr.span);
                            return try fb.emitAddrIndex(base_addr, index_node, elem_size, ptr_type, addr.span);
                        }
                    }
                    // For computed base (e.g., slice), lower it and compute element address
                    const base_val = try self.lowerExprNode(idx.base);
                    return try fb.emitAddrIndex(base_val, index_node, elem_size, ptr_type, addr.span);
                }

                // Handle &x - address of simple identifier
                if (operand_expr == .ident) {
                    // Try local variable first
                    if (fb.lookupLocal(operand_expr.ident.name)) |local_idx| {
                        const local_type = fb.locals.items[local_idx].type_idx;
                        const ptr_type = self.type_reg.makePointer(local_type) catch TypeRegistry.VOID;
                        return try fb.emitAddrLocal(local_idx, ptr_type, addr.span);
                    }
                    // Try global variable
                    if (self.builder.lookupGlobal(operand_expr.ident.name)) |g| {
                        const ptr_type = self.type_reg.makePointer(g.global.type_idx) catch TypeRegistry.VOID;
                        return try fb.emitAddrGlobal(g.idx, operand_expr.ident.name, ptr_type, addr.span);
                    }
                }

                // Handle &local.field - address of struct field
                if (operand_expr == .field_access) {
                    const fa = operand_expr.field_access;
                    // Get base (should be an identifier)
                    const base_node = self.tree.getNode(fa.base) orelse return ir.null_node;
                    const base_expr = base_node.asExpr() orelse return ir.null_node;

                    if (base_expr == .ident) {
                        // Try local variable
                        if (fb.lookupLocal(base_expr.ident.name)) |local_idx| {
                            const local_type = fb.locals.items[local_idx].type_idx;

                            // Get field info
                            const type_data = self.type_reg.get(local_type);
                            if (type_data == .struct_type) {
                                const struct_type = type_data.struct_type;
                                // Find the field
                                for (struct_type.fields) |field| {
                                    if (std.mem.eql(u8, field.name, fa.field)) {
                                        // Get pointer to local, then add field offset
                                        // Result type is pointer to field type
                                        const struct_ptr_type = self.type_reg.makePointer(local_type) catch TypeRegistry.VOID;
                                        const local_addr = try fb.emitAddrLocal(local_idx, struct_ptr_type, addr.span);
                                        const field_ptr_type = self.type_reg.makePointer(field.type_idx) catch TypeRegistry.VOID;
                                        return try fb.emitAddrOffset(local_addr, @intCast(field.offset), field_ptr_type, addr.span);
                                    }
                                }
                            }

                            // Handle &ptr.field - pointer to struct case
                            // Load the pointer, then add field offset
                            if (type_data == .pointer) {
                                const elem_type = self.type_reg.get(type_data.pointer.elem);
                                if (elem_type == .struct_type) {
                                    const struct_type = elem_type.struct_type;
                                    for (struct_type.fields) |field| {
                                        if (std.mem.eql(u8, field.name, fa.field)) {
                                            // Load the pointer value from local
                                            const ptr_val = try fb.emitLoadLocal(local_idx, local_type, addr.span);
                                            // Add field offset
                                            const field_ptr_type = self.type_reg.makePointer(field.type_idx) catch TypeRegistry.VOID;
                                            return try fb.emitAddrOffset(ptr_val, @intCast(field.offset), field_ptr_type, addr.span);
                                        }
                                    }
                                }
                            }
                        }
                        // Try global variable
                        if (self.builder.lookupGlobal(base_expr.ident.name)) |g| {
                            const global_type = g.global.type_idx;

                            // Get field info
                            const type_data = self.type_reg.get(global_type);
                            if (type_data == .struct_type) {
                                const struct_type = type_data.struct_type;
                                // Find the field
                                for (struct_type.fields) |field| {
                                    if (std.mem.eql(u8, field.name, fa.field)) {
                                        // Get pointer to global, then add field offset
                                        const struct_ptr_type = self.type_reg.makePointer(global_type) catch TypeRegistry.VOID;
                                        const global_addr = try fb.emitAddrGlobal(g.idx, base_expr.ident.name, struct_ptr_type, addr.span);
                                        const field_ptr_type = self.type_reg.makePointer(field.type_idx) catch TypeRegistry.VOID;
                                        return try fb.emitAddrOffset(global_addr, @intCast(field.offset), field_ptr_type, addr.span);
                                    }
                                }
                            }
                        }
                    }
                }

                return ir.null_node;
            },
            .deref => |d| {
                const ptr_node = try self.lowerExprNode(d.operand);
                const ptr_type = self.inferExprType(d.operand);
                const elem_type = self.type_reg.pointerElem(ptr_type);
                const final_elem = if (elem_type == types.invalid_type) TypeRegistry.VOID else elem_type;
                return try fb.emitPtrLoadValue(ptr_node, final_elem, d.span);
            },
            .field_access => |fa| {
                return try self.lowerFieldAccess(fa);
            },
            .index => |idx| {
                return try self.lowerIndex(idx);
            },
            .array_literal => |al| {
                return try self.lowerArrayLiteral(al);
            },
            .slice_expr => |se| {
                return try self.lowerSliceExpr(se);
            },
            .builtin_call => |bc| {
                return try self.lowerBuiltinCall(bc);
            },
            .switch_expr => |se| {
                return try self.lowerSwitchExpr(se);
            },
            .struct_init => |si| {
                // Struct literals as expressions (e.g., return Point{ .x = 1, .y = 2 })
                // Strategy: Create a temporary local, initialize it, and return a load of it
                return try self.lowerStructInitExpr(si);
            },
            else => return ir.null_node,
        }
    }

    /// Lower a struct literal expression (not in a variable declaration).
    /// Creates a temporary local, initializes it field-by-field, and returns a load.
    fn lowerStructInitExpr(self: *Lowerer, si: ast.StructInit) Error!ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;

        // Look up the struct type
        const struct_type_idx = self.type_reg.lookupByName(si.type_name) orelse {
            debug.log(.lower, "lowerStructInitExpr: type '{s}' not found", .{si.type_name});
            return ir.null_node;
        };

        const type_info = self.type_reg.get(struct_type_idx);
        const struct_type = switch (type_info) {
            .struct_type => |s| s,
            else => {
                debug.log(.lower, "lowerStructInitExpr: '{s}' is not a struct", .{si.type_name});
                return ir.null_node;
            },
        };

        debug.log(.lower, "lowerStructInitExpr: struct '{s}' ({d} fields)", .{ si.type_name, struct_type.fields.len });

        // Create a temporary local for the struct
        const size = self.type_reg.sizeOf(struct_type_idx);
        const temp_name = "__struct_tmp";
        const temp_idx = try fb.addLocalWithSize(temp_name, struct_type_idx, true, size);

        // Initialize each field
        for (si.fields) |field_init| {
            // Find the field in the struct type
            var found = false;
            for (struct_type.fields, 0..) |struct_field, i| {
                if (std.mem.eql(u8, struct_field.name, field_init.name)) {
                    const field_idx: u32 = @intCast(i);
                    const field_offset: i64 = @intCast(struct_field.offset);

                    // Lower the value expression
                    const value_node = try self.lowerExprNode(field_init.value);

                    // Store to field offset (same as lowerStructInit)
                    _ = try fb.emitStoreLocalField(temp_idx, field_idx, field_offset, value_node, si.span);
                    debug.log(.lower, "  field '{s}' at offset {d}", .{ field_init.name, field_offset });
                    found = true;
                    break;
                }
            }
            if (!found) {
                debug.log(.lower, "  field '{s}' not found in struct", .{field_init.name});
            }
        }

        // Return a load of the temporary - the struct value
        return try fb.emitLoadLocal(temp_idx, struct_type_idx, si.span);
    }

    fn lowerLiteral(self: *Lowerer, lit: ast.Literal) Error!ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;

        switch (lit.kind) {
            .int => {
                const value = std.fmt.parseInt(i64, lit.value, 10) catch 0;
                return try fb.emitConstInt(value, TypeRegistry.I64, lit.span);
            },
            .float => {
                const value = std.fmt.parseFloat(f64, lit.value) catch 0.0;
                return try fb.emitConstFloat(value, TypeRegistry.F64, lit.span);
            },
            .true_lit => return try fb.emitConstBool(true, lit.span),
            .false_lit => return try fb.emitConstBool(false, lit.span),
            .null_lit => return try fb.emitConstNull(TypeRegistry.UNTYPED_NULL, lit.span),
            .string => {
                // String literals become const_slice nodes.
                // The string data is stored in the function's string table.
                // Following Go's pattern: string = (ptr, len) pair.
                //
                // Process escape sequences and strip quotes
                var buf: [4096]u8 = undefined;
                const unescaped = parseStringLiteral(lit.value, &buf);

                // Need to allocate a copy since buf is temporary
                const copied = try self.allocator.dupe(u8, unescaped);

                // Store in string table and get index
                const str_idx = try fb.addStringLiteral(copied);
                return try fb.emitConstSlice(str_idx, lit.span);
            },
            .char => {
                // Parse char literal: 'a' or '\n' etc.
                const value = parseCharLiteral(lit.value);
                return try fb.emitConstInt(@intCast(value), TypeRegistry.U8, lit.span);
            },
        }
    }

    fn lowerIdent(self: *Lowerer, ident: ast.Ident) Error!ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;

        // Check for compile-time constant
        if (self.const_values.get(ident.name)) |value| {
            return try fb.emitConstInt(value, TypeRegistry.I64, ident.span);
        }

        // Look up local variable
        if (fb.lookupLocal(ident.name)) |local_idx| {
            const local_type = fb.locals.items[local_idx].type_idx;
            // Arrays are passed by reference - emit address instead of load
            // Following Go's pattern: arrays decay to pointers when used as values
            if (self.type_reg.isArray(local_type)) {
                return try fb.emitAddrLocal(local_idx, local_type, ident.span);
            }
            return try fb.emitLoadLocal(local_idx, local_type, ident.span);
        }

        // Check if it's a function name (for function pointers)
        if (self.chk.scope.lookup(ident.name)) |sym| {
            if (sym.kind == .function) {
                return try fb.emitFuncAddr(ident.name, sym.type_idx, ident.span);
            }
        }

        // Check for global variable
        if (self.builder.lookupGlobal(ident.name)) |g| {
            debug.log(.lower, "lowerIdent: found global '{s}' at idx {d}", .{ ident.name, g.idx });
            return try fb.emitGlobalRef(g.idx, ident.name, g.global.type_idx, ident.span);
        }

        return ir.null_node;
    }

    fn lowerBinary(self: *Lowerer, bin: ast.Binary) Error!ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;

        const left = try self.lowerExprNode(bin.left);
        const right = try self.lowerExprNode(bin.right);
        const result_type = self.inferBinaryType(bin.op, bin.left, bin.right);

        // Special case: string + string → str_concat
        if (result_type == TypeRegistry.STRING and bin.op == .add) {
            debug.log(.lower, "lowerBinary: string concatenation", .{});
            return try fb.emit(ir.Node.init(
                .{ .str_concat = .{ .left = left, .right = right } },
                result_type,
                bin.span,
            ));
        }

        const op = tokenToBinaryOp(bin.op);

        return try fb.emitBinary(op, left, right, result_type, bin.span);
    }

    fn lowerUnary(self: *Lowerer, un: ast.Unary) Error!ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;

        const operand = try self.lowerExprNode(un.operand);
        const result_type = self.inferExprType(un.operand);
        const op = tokenToUnaryOp(un.op);

        return try fb.emitUnary(op, operand, result_type, un.span);
    }

    /// Lower field access expression (struct.field).
    /// Following Go's ODOT pattern - distinguish local struct vs computed value.
    fn lowerFieldAccess(self: *Lowerer, fa: ast.FieldAccess) Error!ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;

        // Get the base type from the checker's cached types
        const base_type_idx = self.inferExprType(fa.base);
        const base_type = self.type_reg.get(base_type_idx);

        // Check for enum type first (e.g., Color.Red)
        if (base_type == .enum_type) {
            const enum_type = base_type.enum_type;
            // Find the variant by name and return its value as a constant
            for (enum_type.variants) |variant| {
                if (std.mem.eql(u8, variant.name, fa.field)) {
                    return try fb.emitConstInt(variant.value, base_type_idx, fa.span);
                }
            }
            return ir.null_node; // Variant not found
        }

        // Check for slice type (s.ptr, s.len)
        if (base_type == .slice) {
            const slice_elem = base_type.slice.elem;
            const base_val = try self.lowerExprNode(fa.base);

            if (std.mem.eql(u8, fa.field, "ptr")) {
                // Return pointer to element type
                const ptr_type = try self.type_reg.add(.{ .pointer = .{ .elem = slice_elem } });
                return try fb.emitSlicePtr(base_val, ptr_type, fa.span);
            } else if (std.mem.eql(u8, fa.field, "len")) {
                return try fb.emitSliceLen(base_val, fa.span);
            }
            return ir.null_node;
        }

        // Check for string type (s.ptr, s.len) - string is (ptr, len) like slice
        if (base_type_idx == TypeRegistry.STRING) {
            const base_val = try self.lowerExprNode(fa.base);

            if (std.mem.eql(u8, fa.field, "ptr")) {
                // Return pointer to u8
                const ptr_type = try self.type_reg.add(.{ .pointer = .{ .elem = TypeRegistry.U8 } });
                return try fb.emitSlicePtr(base_val, ptr_type, fa.span);
            } else if (std.mem.eql(u8, fa.field, "len")) {
                return try fb.emitSliceLen(base_val, fa.span);
            }
            return ir.null_node;
        }

        // Must be a struct type
        const struct_type = switch (base_type) {
            .struct_type => |st| st,
            .pointer => |ptr| blk: {
                // Pointer to struct - auto-dereference (like Go's ODOTPTR)
                const elem_type = self.type_reg.get(ptr.elem);
                break :blk switch (elem_type) {
                    .struct_type => |st| st,
                    else => return ir.null_node,
                };
            },
            else => return ir.null_node,
        };

        // Find the field by name
        var field_idx: u32 = 0;
        var field_offset: i64 = 0;
        var field_type: TypeIndex = TypeRegistry.VOID;
        for (struct_type.fields, 0..) |field, i| {
            if (std.mem.eql(u8, field.name, fa.field)) {
                field_idx = @intCast(i);
                field_offset = @intCast(field.offset);
                field_type = field.type_idx;
                break;
            }
        }

        // Check if base is a local variable (optimized path)
        // BUG-005: Only use optimized path for direct struct locals, NOT pointer-to-struct.
        // When base_type is a pointer, we must dereference first via lowerExprNode.
        // This is Go's ODOT vs ODOTPTR distinction.
        const base_is_pointer = switch (base_type) {
            .pointer => true,
            else => false,
        };

        const base_node = self.tree.getNode(fa.base) orelse return ir.null_node;
        const base_expr = base_node.asExpr() orelse return ir.null_node;

        if (base_expr == .ident and !base_is_pointer) {
            // Base is an identifier AND a direct struct - check if it's a local variable
            if (fb.lookupLocal(base_expr.ident.name)) |local_idx| {
                // Emit FieldLocal for direct access to struct local
                return try fb.emitFieldLocal(local_idx, field_idx, field_offset, field_type, fa.span);
            }
        }

        // Base is a computed expression - lower it and emit FieldValue
        const base_val = try self.lowerExprNode(fa.base);
        return try fb.emitFieldValue(base_val, field_idx, field_offset, field_type, fa.span);
    }

    /// Lower array index expression: arr[i]
    /// Following Go's pattern: compute element address, then load
    fn lowerIndex(self: *Lowerer, idx: ast.Index) Error!ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;

        // Get array type info
        const base_type_idx = self.inferExprType(idx.base);
        const base_type = self.type_reg.get(base_type_idx);

        // Get element type and size
        // Handle string type specially - it's like []u8
        const elem_type: TypeIndex = if (base_type_idx == TypeRegistry.STRING)
            TypeRegistry.U8
        else switch (base_type) {
            .array => |a| a.elem,
            .slice => |s| s.elem,
            else => return ir.null_node,
        };
        const elem_size = self.type_reg.sizeOf(elem_type);

        // For strings, load ptr from the string local and index into it
        if (base_type_idx == TypeRegistry.STRING) {
            const index_node = try self.lowerExprNode(idx.idx);
            const base_node = self.tree.getNode(idx.base) orelse return ir.null_node;
            const base_expr = base_node.asExpr() orelse return ir.null_node;

            if (base_expr == .ident) {
                if (fb.lookupLocal(base_expr.ident.name)) |local_idx| {
                    // Load the string value
                    const str_val = try fb.emitLoadLocal(local_idx, TypeRegistry.STRING, idx.span);
                    // Extract pointer from string (ptr to u8)
                    const ptr_type = self.type_reg.makePointer(TypeRegistry.U8) catch TypeRegistry.I64;
                    const ptr_val = try fb.emitSlicePtr(str_val, ptr_type, idx.span);
                    // Index through the pointer
                    return try fb.emitIndexValue(ptr_val, index_node, elem_size, elem_type, idx.span);
                }
            }
            // Computed base - lower it and extract ptr
            const base_val = try self.lowerExprNode(idx.base);
            const ptr_type = self.type_reg.makePointer(TypeRegistry.U8) catch TypeRegistry.I64;
            const ptr_val = try fb.emitSlicePtr(base_val, ptr_type, idx.span);
            return try fb.emitIndexValue(ptr_val, index_node, elem_size, elem_type, idx.span);
        }

        // Lower the index expression
        const index_node = try self.lowerExprNode(idx.idx);

        // Check if base is a local variable (optimized path)
        const base_node = self.tree.getNode(idx.base) orelse return ir.null_node;
        const base_expr = base_node.asExpr() orelse return ir.null_node;

        if (base_expr == .ident) {
            if (fb.lookupLocal(base_expr.ident.name)) |local_idx| {
                const local = fb.locals.items[local_idx];
                const local_type = self.type_reg.get(local.type_idx);

                // Slice variables: load slice, extract ptr, then index
                // Following Go's pattern: OpSlicePtr extracts pointer from slice
                if (local_type == .slice) {
                    // Load the slice value (ptr + len)
                    const slice_val = try fb.emitLoadLocal(local_idx, local.type_idx, idx.span);
                    // Extract pointer from slice (ptr_type is pointer to element)
                    const ptr_type = self.type_reg.makePointer(elem_type) catch TypeRegistry.I64;
                    const ptr_val = try fb.emitSlicePtr(slice_val, ptr_type, idx.span);
                    // Index through the pointer
                    return try fb.emitIndexValue(ptr_val, index_node, elem_size, elem_type, idx.span);
                }

                // Array parameters are passed by reference - the local contains a pointer
                // We need to load the pointer and use index_value instead of index_local
                if (local.is_param and self.type_reg.isArray(local.type_idx)) {
                    const ptr_val = try fb.emitLoadLocal(local_idx, local.type_idx, idx.span);
                    return try fb.emitIndexValue(ptr_val, index_node, elem_size, elem_type, idx.span);
                }
                // Regular local array - emit index_local for direct access
                return try fb.emitIndexLocal(local_idx, index_node, elem_size, elem_type, idx.span);
            }
        }

        // Base is a computed expression - lower it and emit IndexValue
        const base_val = try self.lowerExprNode(idx.base);
        return try fb.emitIndexValue(base_val, index_node, elem_size, elem_type, idx.span);
    }

    /// Lower array literal: [a, b, c]
    /// Creates a temp local, stores each element, returns the local
    fn lowerArrayLiteral(self: *Lowerer, al: ast.ArrayLiteral) Error!ir.NodeIndex {
        debug.log(.lower, "lowerArrayLiteral count={d}", .{al.elements.len});

        const fb = self.current_func orelse return ir.null_node;

        if (al.elements.len == 0) {
            return ir.null_node;
        }

        // Get element type from first element
        const first_elem_type = self.inferExprType(al.elements[0]);
        const elem_size = self.type_reg.sizeOf(first_elem_type);

        // Create array type
        const array_type = self.type_reg.makeArray(first_elem_type, al.elements.len) catch return ir.null_node;
        const array_size = self.type_reg.sizeOf(array_type);

        // Create temp local for the array
        const temp_name = try std.fmt.allocPrint(self.allocator, "__arr_{d}", .{fb.locals.items.len});
        const local_idx = try fb.addLocalWithSize(temp_name, array_type, false, array_size);

        // Store each element
        for (al.elements, 0..) |elem_idx, i| {
            const elem_node = try self.lowerExprNode(elem_idx);
            const idx_node = try fb.emitConstInt(@intCast(i), TypeRegistry.I64, al.span);
            _ = try fb.emitStoreIndexLocal(local_idx, idx_node, elem_node, elem_size, al.span);
        }

        // Return the local address (arrays are passed by reference)
        return try fb.emitAddrLocal(local_idx, array_type, al.span);
    }

    /// Lower slice expression: arr[start..end]
    /// Lower slice expression following Go's pattern from ssagen/ssa.go slice() function.
    /// Default indices: start defaults to 0, end defaults to len(base).
    fn lowerSliceExpr(self: *Lowerer, se: ast.SliceExpr) Error!ir.NodeIndex {
        debug.log(.lower, "lowerSliceExpr", .{});

        const fb = self.current_func orelse return ir.null_node;

        // Get base type to find element type
        const base_type_idx = self.inferExprType(se.base);
        const base_type = self.type_reg.get(base_type_idx);

        // Determine element type and size
        const elem_type_idx: TypeIndex = switch (base_type) {
            .array => |a| a.elem,
            .slice => |s| s.elem,
            else => return ir.null_node,
        };
        const elem_size = self.type_reg.sizeOf(elem_type_idx);

        // Create slice type
        const slice_type = self.type_reg.makeSlice(elem_type_idx) catch return ir.null_node;

        // Lower start index (defaults to 0 if not specified)
        // Following Go: if i == nil { i = s.constInt(types.Types[types.TINT], 0) }
        var start_node: ?ir.NodeIndex = null;
        if (se.start != null_node) {
            start_node = try self.lowerExprNode(se.start);
        }

        // Lower end index
        // Following Go: if j == nil { j = len }
        var end_node: ?ir.NodeIndex = null;
        if (se.end != null_node) {
            end_node = try self.lowerExprNode(se.end);
        } else {
            // End not specified - use length of base
            switch (base_type) {
                .array => |a| {
                    // For arrays, length is compile-time constant
                    end_node = try fb.emitConstInt(@intCast(a.length), TypeRegistry.I64, se.span);
                },
                .slice => {
                    // For slices, need to get runtime length via SliceLen
                    const base_node = self.tree.getNode(se.base) orelse return ir.null_node;
                    const base_expr = base_node.asExpr() orelse return ir.null_node;

                    if (base_expr == .ident) {
                        if (fb.lookupLocal(base_expr.ident.name)) |slice_local| {
                            const slice_val = try fb.emitLoadLocal(slice_local, base_type_idx, se.span);
                            end_node = try fb.emitSliceLen(slice_val, se.span);
                        }
                    }
                },
                else => {},
            }
        }

        // Check if base is local identifier
        const base_node = self.tree.getNode(se.base) orelse return ir.null_node;
        const base_expr = base_node.asExpr() orelse return ir.null_node;

        if (base_expr == .ident) {
            if (fb.lookupLocal(base_expr.ident.name)) |local_idx| {
                return try fb.emitSliceLocal(local_idx, start_node, end_node, elem_size, slice_type, se.span);
            }
        }

        // Handle deref base specially: arr.*[:] needs the POINTER value, not a load through it
        // Following Go's pattern: for slicing, we need the address of the data, not the data itself
        if (base_expr == .deref) {
            // Lower the operand (the pointer) without dereferencing
            const ptr_val = try self.lowerExprNode(base_expr.deref.operand);
            return try fb.emitSliceValue(ptr_val, start_node, end_node, elem_size, slice_type, se.span);
        }

        // Base is a computed expression
        const base_val = try self.lowerExprNode(se.base);
        return try fb.emitSliceValue(base_val, start_node, end_node, elem_size, slice_type, se.span);
    }

    fn lowerCall(self: *Lowerer, call: ast.Call) Error!ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;

        // Get function name from callee
        const callee_node = self.tree.getNode(call.callee) orelse return ir.null_node;
        const callee_expr = callee_node.asExpr() orelse return ir.null_node;

        const func_name = if (callee_expr == .ident)
            callee_expr.ident.name
        else
            return ir.null_node;

        // Handle builtin functions
        if (std.mem.eql(u8, func_name, "len")) {
            return try self.lowerBuiltinLen(call);
        }
        if (std.mem.eql(u8, func_name, "__string_make")) {
            return try self.lowerBuiltinStringMake(call);
        }
        if (std.mem.eql(u8, func_name, "print") or std.mem.eql(u8, func_name, "println")) {
            return try self.lowerBuiltinPrint(call, std.mem.eql(u8, func_name, "println"));
        }

        // Lower arguments
        var args = std.ArrayListUnmanaged(ir.NodeIndex){};
        defer args.deinit(self.allocator);

        for (call.args) |arg_idx| {
            const arg_node = try self.lowerExprNode(arg_idx);
            try args.append(self.allocator, arg_node);
        }

        // Determine direct vs indirect call (Go: ClosureCall vs OCALL):
        // - Direct call: callee is a function name
        // - Indirect call: callee is a local variable holding a function pointer
        //
        // Check FuncBuilder's locals first (scope lookup fails after checker completes)
        if (fb.lookupLocal(func_name)) |local_idx| {
            // Found as a local variable - this is an indirect call
            const local = fb.locals.items[local_idx];
            const local_type = self.type_reg.get(local.type_idx);

            if (local_type == .func) {
                // It's a function pointer variable - emit indirect call
                debug.log(.lower, "lowerCall: indirect call through variable '{s}' (local {d})", .{ func_name, local_idx });
                const return_type = local_type.func.return_type;
                const ptr_val = try fb.emitLoadLocal(local_idx, local.type_idx, call.span);
                return try fb.emitCallIndirect(ptr_val, args.items, return_type, call.span);
            }
        }

        // Not a local variable - must be a direct function call
        // Look up function return type from symbol table
        var return_type: TypeIndex = TypeRegistry.VOID;
        if (self.chk.scope.lookup(func_name)) |sym| {
            const func_type = self.type_reg.get(sym.type_idx);
            if (func_type == .func) {
                return_type = func_type.func.return_type;
                debug.log(.lower, "lowerCall: '{s}' return_type={d} (size={d}B)", .{
                    func_name,
                    return_type,
                    self.type_reg.sizeOf(return_type),
                });
            } else {
                debug.log(.lower, "lowerCall: '{s}' found but not a func type", .{func_name});
            }
        } else {
            debug.log(.lower, "lowerCall: '{s}' NOT FOUND in scope", .{func_name});
        }

        // Direct call to named function
        return try fb.emitCall(func_name, args.items, false, return_type, call.span);
    }

    /// Lower builtin len() function.
    /// For string literals, returns compile-time constant length.
    fn lowerBuiltinLen(self: *Lowerer, call: ast.Call) Error!ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;

        if (call.args.len != 1) return ir.null_node;

        const arg_idx = call.args[0];
        const arg_node = self.tree.getNode(arg_idx) orelse return ir.null_node;
        const arg_expr = arg_node.asExpr() orelse return ir.null_node;

        // Check if argument is a string literal
        if (arg_expr == .literal) {
            const lit = arg_expr.literal;
            if (lit.kind == .string) {
                // Parse the string literal to get its actual length
                var buf: [4096]u8 = undefined;
                const unescaped = parseStringLiteral(lit.value, &buf);
                const length: i64 = @intCast(unescaped.len);
                return try fb.emitConstInt(length, TypeRegistry.INT, call.span);
            }
        }

        // For string variables, access length field directly from local (like struct field access)
        // String is stored as: [offset 0] ptr (8 bytes), [offset 8] len (8 bytes)
        if (arg_expr == .ident) {
            const ident = arg_expr.ident;
            if (fb.lookupLocal(ident.name)) |local_idx| {
                const local_type_idx = fb.locals.items[local_idx].type_idx;
                const local_type = self.type_reg.get(local_type_idx);

                if (local_type_idx == TypeRegistry.STRING) {
                    // Use field_local to access length at offset 8 (field index 1)
                    return try fb.emitFieldLocal(local_idx, 1, 8, TypeRegistry.I64, call.span);
                }

                // Slice variables: load slice and extract length
                // Following Go's pattern: len(slice) -> OpSliceLen
                if (local_type == .slice) {
                    const slice_val = try fb.emitLoadLocal(local_idx, local_type_idx, call.span);
                    return try fb.emitSliceLen(slice_val, call.span);
                }

                // Array variables: return compile-time constant length
                if (local_type == .array) {
                    const arr_len: i64 = @intCast(local_type.array.length);
                    return try fb.emitConstInt(arr_len, TypeRegistry.INT, call.span);
                }
            }
        }

        // Handle field access (e.g., s.source where s is a struct with string field)
        if (arg_expr == .field_access) {
            const arg_type = self.inferExprType(arg_idx);
            if (arg_type == TypeRegistry.STRING) {
                // Lower the field access to get the string value
                const str_val = try self.lowerFieldAccess(arg_expr.field_access);
                // Extract length from the string
                return try fb.emitSliceLen(str_val, call.span);
            }
        }

        // General case: evaluate the expression and extract length
        const arg_type = self.inferExprType(arg_idx);
        if (arg_type == TypeRegistry.STRING) {
            const str_val = try self.lowerExprNode(arg_idx);
            return try fb.emitSliceLen(str_val, call.span);
        }

        // Other types not yet implemented
        return ir.null_node;
    }

    /// Lower builtin __string_make(ptr, len) function.
    /// Constructs a string from raw ptr and len components.
    /// Following Go's unsafe.String(ptr, len) pattern.
    fn lowerBuiltinStringMake(self: *Lowerer, call: ast.Call) Error!ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;

        if (call.args.len != 2) return ir.null_node;

        // Lower ptr and len arguments
        const ptr_val = try self.lowerExprNode(call.args[0]);
        const len_val = try self.lowerExprNode(call.args[1]);

        // Emit string_header IR node (like Go's OSTRINGHEADER)
        return try fb.emit(ir.Node.init(
            .{ .string_header = .{ .ptr = ptr_val, .len = len_val } },
            TypeRegistry.STRING,
            call.span,
        ));
    }

    /// Lower builtin print(s) and println(s) functions.
    /// Transforms to write(1, s.ptr, s.len) syscall.
    /// Following Go's pattern of lowering print to runtime calls.
    fn lowerBuiltinPrint(self: *Lowerer, call: ast.Call, is_println: bool) Error!ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;

        if (call.args.len != 1) return ir.null_node;

        // Lower the string argument
        const str_val = try self.lowerExprNode(call.args[0]);

        // Extract ptr and len from the string
        const ptr_type = try self.type_reg.makePointer(TypeRegistry.U8);
        const ptr_val = try fb.emitSlicePtr(str_val, ptr_type, call.span);
        const len_val = try fb.emitSliceLen(str_val, call.span);

        // Create fd=1 (stdout) constant
        const fd_val = try fb.emitConstInt(1, TypeRegistry.I32, call.span);

        // Call write(fd, ptr, len) - returns i64
        var write_args = [_]ir.NodeIndex{ fd_val, ptr_val, len_val };
        _ = try fb.emitCall("write", &write_args, false, TypeRegistry.I64, call.span);

        // For println, also write a newline
        if (is_println) {
            // Create newline string literal
            const nl_idx = try fb.addStringLiteral("\n");
            const nl_str = try fb.emit(ir.Node.init(
                .{ .const_slice = .{ .string_index = nl_idx } },
                TypeRegistry.STRING,
                call.span,
            ));
            const nl_ptr = try fb.emitSlicePtr(nl_str, ptr_type, call.span);
            const nl_len = try fb.emitConstInt(1, TypeRegistry.I64, call.span);
            var nl_args = [_]ir.NodeIndex{ fd_val, nl_ptr, nl_len };
            _ = try fb.emitCall("write", &nl_args, false, TypeRegistry.I64, call.span);
        }

        // print/println returns void
        return ir.null_node;
    }

    fn lowerIfExpr(self: *Lowerer, if_expr: ast.IfExpr) Error!ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;

        const cond = try self.lowerExprNode(if_expr.condition);
        const then_val = try self.lowerExprNode(if_expr.then_branch);
        const else_val = if (if_expr.else_branch != null_node)
            try self.lowerExprNode(if_expr.else_branch)
        else
            ir.null_node;

        const result_type = self.inferExprType(if_expr.then_branch);
        return try fb.emitSelect(cond, then_val, else_val, result_type, if_expr.span);
    }

    /// Lower switch expression to chained select operations.
    /// Following Go's pattern: convert switch to if-else chain (nested selects).
    ///
    /// switch x { 1 => "one", 2, 3 => "multi", else => "other" }
    /// becomes: select(eq(x,1), "one", select(or(eq(x,2),eq(x,3)), "multi", "other"))
    fn lowerSwitchExpr(self: *Lowerer, se: ast.SwitchExpr) Error!ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;

        debug.log(.lower, "lowerSwitchExpr: {d} cases", .{se.cases.len});

        // Lower the switch subject once
        const subject = try self.lowerExprNode(se.subject);

        // Determine result type from first case body
        const result_type = if (se.cases.len > 0)
            self.inferExprType(se.cases[0].body)
        else if (se.else_body != null_node)
            self.inferExprType(se.else_body)
        else
            TypeRegistry.VOID;

        // Start with else value (or null if no else)
        var current_result: ir.NodeIndex = if (se.else_body != null_node)
            try self.lowerExprNode(se.else_body)
        else
            ir.null_node;

        // Process cases in reverse order to build nested selects
        // Last case wraps else, then each preceding case wraps that result
        var i: usize = se.cases.len;
        while (i > 0) {
            i -= 1;
            const case = se.cases[i];

            // Build condition: OR together all patterns for this case
            var case_cond: ir.NodeIndex = ir.null_node;

            for (case.patterns) |pattern_idx| {
                // Lower the pattern value
                const pattern_val = try self.lowerExprNode(pattern_idx);

                // Emit comparison: subject == pattern
                const pattern_cond = try fb.emitBinary(.eq, subject, pattern_val, TypeRegistry.BOOL, se.span);

                // OR with previous patterns (if any)
                if (case_cond == ir.null_node) {
                    case_cond = pattern_cond;
                } else {
                    case_cond = try fb.emitBinary(.@"or", case_cond, pattern_cond, TypeRegistry.BOOL, se.span);
                }
            }

            // Lower the case body
            const case_body = try self.lowerExprNode(case.body);

            // Emit select: if case_cond then case_body else current_result
            if (case_cond != ir.null_node) {
                current_result = try fb.emitSelect(case_cond, case_body, current_result, result_type, se.span);
            }
        }

        return current_result;
    }

    /// Lower builtin calls: @sizeOf(T), @alignOf(T), @string(ptr, len), etc.
    fn lowerBuiltinCall(self: *Lowerer, bc: ast.BuiltinCall) Error!ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;

        if (std.mem.eql(u8, bc.name, "sizeOf")) {
            // @sizeOf(T) - return size of type T in bytes as a compile-time constant
            const type_idx = self.resolveTypeNode(bc.type_arg);
            const size = self.type_reg.sizeOf(type_idx);
            debug.log(.lower, "@sizeOf({d}) = {d}", .{ type_idx, size });
            return try fb.emitConstInt(@intCast(size), TypeRegistry.I64, bc.span);
        } else if (std.mem.eql(u8, bc.name, "alignOf")) {
            // @alignOf(T) - return alignment of type T in bytes as a compile-time constant
            const type_idx = self.resolveTypeNode(bc.type_arg);
            const alignment = self.type_reg.alignmentOf(type_idx);
            debug.log(.lower, "@alignOf({d}) = {d}", .{ type_idx, alignment });
            return try fb.emitConstInt(@intCast(alignment), TypeRegistry.I64, bc.span);
        } else if (std.mem.eql(u8, bc.name, "string")) {
            // @string(ptr, len) - construct string from ptr and len
            const ptr_node = try self.lowerExprNode(bc.args[0]);
            const len_node = try self.lowerExprNode(bc.args[1]);
            debug.log(.lower, "@string(ptr, len) -> string_header", .{});
            return try fb.emit(ir.Node.init(
                .{ .string_header = .{ .ptr = ptr_node, .len = len_node } },
                TypeRegistry.STRING,
                bc.span,
            ));
        } else if (std.mem.eql(u8, bc.name, "intCast")) {
            // @intCast(Type, value) - integer type conversion
            const target_type = self.resolveTypeNode(bc.type_arg);
            const operand = try self.lowerExprNode(bc.args[0]);
            const from_type = self.inferExprType(bc.args[0]);
            debug.log(.lower, "@intCast({d}, expr) from_type={d} to_type={d}", .{ target_type, from_type, target_type });
            return try fb.emitConvert(operand, from_type, target_type, bc.span);
        }

        return ir.null_node;
    }

    // ========================================================================
    // Type Resolution
    // ========================================================================

    fn resolveTypeNode(self: *Lowerer, idx: NodeIndex) TypeIndex {
        const node = self.tree.getNode(idx) orelse return TypeRegistry.VOID;
        const expr = node.asExpr() orelse return TypeRegistry.VOID;

        switch (expr) {
            .type_expr => |te| return self.resolveTypeKind(te.kind),
            .ident => |ident| {
                const result = self.type_reg.lookupByName(ident.name) orelse TypeRegistry.VOID;
                debug.log(.lower, "resolveTypeNode ident '{s}' -> type_idx={d}", .{ ident.name, result });
                return result;
            },
            else => return TypeRegistry.VOID,
        }
    }

    fn resolveTypeKind(self: *Lowerer, kind: ast.TypeKind) TypeIndex {
        switch (kind) {
            .named => |name| {
                const result = self.type_reg.lookupByName(name) orelse TypeRegistry.VOID;
                debug.log(.lower, "resolveTypeKind named '{s}' -> type_idx={d}", .{ name, result });
                return result;
            },
            .pointer => |inner| {
                const inner_type = self.resolveTypeNode(inner);
                return self.type_reg.makePointer(inner_type) catch TypeRegistry.VOID;
            },
            .optional => |inner| {
                const inner_type = self.resolveTypeNode(inner);
                return self.type_reg.makeOptional(inner_type) catch TypeRegistry.VOID;
            },
            .slice => |inner| {
                const inner_type = self.resolveTypeNode(inner);
                return self.type_reg.makeSlice(inner_type) catch TypeRegistry.VOID;
            },
            .array => |arr| {
                // Array type: [size]elem
                const elem_type = self.resolveTypeNode(arr.elem);
                // Get size from the literal node
                const size_node = self.tree.getNode(arr.size) orelse return TypeRegistry.VOID;
                const size_expr = size_node.asExpr() orelse return TypeRegistry.VOID;
                if (size_expr == .literal and size_expr.literal.kind == .int) {
                    const length = std.fmt.parseInt(u64, size_expr.literal.value, 10) catch return TypeRegistry.VOID;
                    return self.type_reg.makeArray(elem_type, length) catch TypeRegistry.VOID;
                }
                return TypeRegistry.VOID;
            },
            .function => |fn_type| {
                // Function type: fn(params) -> ret
                var param_types = std.ArrayListUnmanaged(types.FuncParam){};
                defer param_types.deinit(self.allocator);
                for (fn_type.params) |param_idx| {
                    const param_type = self.resolveTypeNode(param_idx);
                    param_types.append(self.allocator, .{ .name = "", .type_idx = param_type }) catch return TypeRegistry.VOID;
                }
                const ret_type = self.resolveTypeNode(fn_type.ret);
                return self.type_reg.makeFunc(param_types.items, ret_type) catch TypeRegistry.VOID;
            },
            else => return TypeRegistry.VOID,
        }
    }

    fn inferExprType(self: *Lowerer, idx: NodeIndex) TypeIndex {
        // Use checker's cached types
        if (self.chk.expr_types.get(idx)) |t| {
            return t;
        }
        return TypeRegistry.VOID;
    }

    fn inferBinaryType(self: *Lowerer, op: Token, left: NodeIndex, right: NodeIndex) TypeIndex {
        _ = right;
        // For comparisons, result is bool
        const is_comparison = switch (op) {
            .eql, .neq, .lss, .leq, .gtr, .geq => true,
            else => false,
        };
        if (is_comparison) {
            return TypeRegistry.BOOL;
        }
        // For arithmetic/logical, use left operand type
        return self.inferExprType(left);
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    fn tokenToBinaryOp(tok: Token) ir.BinaryOp {
        return switch (tok) {
            .add, .add_assign => .add,
            .sub, .sub_assign => .sub,
            .mul, .mul_assign => .mul,
            .quo, .quo_assign => .div,
            .rem, .rem_assign => .mod,
            .eql => .eq,
            .neq => .ne,
            .lss => .lt,
            .leq => .le,
            .gtr => .gt,
            .geq => .ge,
            .land, .kw_and => .@"and",
            .lor, .kw_or => .@"or",
            .@"and", .and_assign => .bit_and,
            .@"or", .or_assign => .bit_or,
            .xor, .xor_assign => .bit_xor,
            .shl => .shl,
            .shr => .shr,
            else => .add,
        };
    }

    fn tokenToUnaryOp(tok: Token) ir.UnaryOp {
        return switch (tok) {
            .sub => .neg,
            .lnot, .kw_not => .not,
            .not => .bit_not,
            else => .neg,
        };
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Parse a character literal string (e.g., "'a'" or "'\n'") and return its u8 value.
fn parseCharLiteral(text: []const u8) u8 {
    // Expect format: 'x' or '\x'
    if (text.len < 3) return 0;
    if (text[0] != '\'' or text[text.len - 1] != '\'') return 0;

    const inner = text[1 .. text.len - 1];
    if (inner.len == 0) return 0;

    // Simple character
    if (inner[0] != '\\') {
        return inner[0];
    }

    // Escape sequence
    if (inner.len < 2) return 0;
    return switch (inner[1]) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '\\' => '\\',
        '\'' => '\'',
        '"' => '"',
        '0' => 0,
        'x' => blk: {
            // Hex escape \xNN
            if (inner.len >= 4) {
                break :blk std.fmt.parseInt(u8, inner[2..4], 16) catch 0;
            }
            break :blk 0;
        },
        else => inner[1],
    };
}

/// Parse a string literal and return its unescaped content.
/// Handles escape sequences like \n, \t, \r, \\, \", etc.
fn parseStringLiteral(text: []const u8, out_buf: []u8) []const u8 {
    // Expect format: "content" - skip opening and closing quotes
    if (text.len < 2) return "";
    if (text[0] != '"' or text[text.len - 1] != '"') return text;

    const inner = text[1 .. text.len - 1];
    var out_idx: usize = 0;
    var i: usize = 0;

    while (i < inner.len and out_idx < out_buf.len) {
        if (inner[i] == '\\' and i + 1 < inner.len) {
            const escaped = switch (inner[i + 1]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '"' => '"',
                '\'' => '\'',
                '0' => @as(u8, 0),
                'x' => blk: {
                    // Hex escape \xNN
                    if (i + 3 < inner.len) {
                        const val = std.fmt.parseInt(u8, inner[i + 2 .. i + 4], 16) catch 0;
                        i += 2; // skip extra chars
                        break :blk val;
                    }
                    break :blk inner[i + 1];
                },
                else => inner[i + 1],
            };
            out_buf[out_idx] = escaped;
            out_idx += 1;
            i += 2;
        } else {
            out_buf[out_idx] = inner[i];
            out_idx += 1;
            i += 1;
        }
    }

    return out_buf[0..out_idx];
}

// ============================================================================
// Tests
// ============================================================================

test "Lowerer basic init" {
    const allocator = std.testing.allocator;

    var tree = Ast.init(allocator);
    defer tree.deinit();

    var type_reg = try TypeRegistry.init(allocator);
    defer type_reg.deinit();

    var src = source.Source.init(allocator, "test.cot", "");
    defer src.deinit();

    var err = ErrorReporter.init(&src, null);
    var scope = checker.Scope.init(allocator, null);
    defer scope.deinit();

    var chk = checker.Checker.init(allocator, &tree, &type_reg, &err, &scope);
    defer chk.deinit();

    var lowerer = Lowerer.init(allocator, &tree, &type_reg, &err, &chk);
    defer lowerer.deinit();

    // Empty AST should produce empty IR
    var ir_result = try lowerer.lower();
    defer ir_result.deinit();

    try std.testing.expectEqual(@as(usize, 0), ir_result.funcs.len);
}

test "End-to-end pipeline: parse -> check -> lower -> SSA" {
    const allocator = std.testing.allocator;
    const ssa_builder = @import("ssa_builder.zig");
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");

    // Very simple function that returns a constant (avoid parameter issues)
    const code =
        \\fn answer() i64 {
        \\    return 42;
        \\}
    ;

    // Set up source and scanner
    var src = source.Source.init(allocator, "test.cot", code);
    defer src.deinit();

    var err = ErrorReporter.init(&src, null);

    var scan = scanner.Scanner.initWithErrors(&src, &err);

    // Parse
    var tree = Ast.init(allocator);
    defer tree.deinit();

    var parse = parser.Parser.init(allocator, &scan, &tree, &err);
    try parse.parseFile();

    // Check for parse errors
    if (err.hasErrors()) {
        std.debug.print("Parse error: {s}\n", .{err.firstError().?.msg});
        return error.ParseError;
    }

    // Type check
    var type_reg = try TypeRegistry.init(allocator);
    defer type_reg.deinit();

    var global_scope = checker.Scope.init(allocator, null);
    defer global_scope.deinit();

    var chk = checker.Checker.init(allocator, &tree, &type_reg, &err, &global_scope);
    defer chk.deinit();

    try chk.checkFile();

    // Check for type errors
    if (err.hasErrors()) {
        if (err.firstError()) |first| {
            std.debug.print("Type error: {s}\n", .{first.msg});
        }
        return error.TypeError;
    }

    // Lower to IR
    var lowerer = Lowerer.init(allocator, &tree, &type_reg, &err, &chk);
    defer lowerer.deinit();

    var ir_result = try lowerer.lower();
    defer ir_result.deinit();

    // Verify we have one function
    try std.testing.expectEqual(@as(usize, 1), ir_result.funcs.len);

    const func = &ir_result.funcs[0];
    try std.testing.expectEqualStrings("answer", func.name);

    // Convert to SSA
    var ssa = try ssa_builder.SSABuilder.init(allocator, func, &type_reg);
    defer ssa.deinit();

    const ssa_func = try ssa.build();
    defer {
        ssa_func.deinit();
        allocator.destroy(ssa_func);
    }

    // Verify SSA function structure
    try std.testing.expectEqualStrings("answer", ssa_func.name);
    try std.testing.expect(ssa_func.numBlocks() >= 1);
}

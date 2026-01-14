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

    // Compile-time constant values
    const_values: std.StringHashMap(i64),

    /// Error type for lowering operations
    pub const Error = error{OutOfMemory};

    const LoopContext = struct {
        cond_block: ir.BlockIndex, // Jump target for continue
        exit_block: ir.BlockIndex, // Jump target for break
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
            .const_values = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *Lowerer) void {
        self.loop_stack.deinit(self.allocator);
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
        // Resolve return type
        const return_type = if (fn_decl.return_type != null_node)
            self.resolveTypeNode(fn_decl.return_type)
        else
            TypeRegistry.VOID;

        // Start building function
        self.builder.startFunc(fn_decl.name, TypeRegistry.VOID, return_type, fn_decl.span);

        if (self.builder.func()) |fb| {
            self.current_func = fb;

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

        // Add as global
        const global = ir.Global.init(var_decl.name, type_idx, var_decl.is_const, var_decl.span);
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
                for (block.stmts) |stmt_idx| {
                    const stmt_node = self.tree.getNode(stmt_idx) orelse continue;
                    if (stmt_node.asStmt()) |s| {
                        if (try self.lowerStmt(s)) return true;
                    }
                }
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
            .defer_stmt, .bad_stmt => return false,
        }
    }

    fn lowerReturn(self: *Lowerer, ret: ast.ReturnStmt) !void {
        const fb = self.current_func orelse return;

        if (ret.value != null_node) {
            const value_node = try self.lowerExprNode(ret.value);
            _ = try fb.emitRet(value_node, ret.span);
        } else {
            _ = try fb.emitRet(null, ret.span);
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
            const value_node = try self.lowerExprNode(var_stmt.value);
            _ = try fb.emitStoreLocal(local_idx, value_node, var_stmt.span);
        }
    }

    fn lowerAssign(self: *Lowerer, assign: ast.AssignStmt) !void {
        const fb = self.current_func orelse return;

        // Get target expression
        const target_node = self.tree.getNode(assign.target) orelse return;
        const target_expr = target_node.asExpr() orelse return;

        switch (target_expr) {
            .ident => |ident| {
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
                        // Emit StoreLocalField for direct store to struct local
                        _ = try fb.emitStoreLocalField(local_idx, field_idx, field_offset, value_node, assign.span);
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

                // TODO: Handle pointer field store (PtrFieldStore)
            },
            .index => |idx| {
                // TODO: implement index assignment
                _ = idx;
            },
            .deref => |d| {
                // TODO: implement deref assignment
                _ = d;
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

        // Push loop context for break/continue
        try self.loop_stack.append(self.allocator, .{
            .cond_block = cond_block,
            .exit_block = exit_block,
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

    fn lowerFor(self: *Lowerer, for_stmt: ast.ForStmt) !void {
        // For-loop desugaring: for x in iter => while loop with iterator
        // TODO: implement proper iterator lowering
        _ = self;
        _ = for_stmt;
    }

    fn lowerBreak(self: *Lowerer) !void {
        const fb = self.current_func orelse return;
        if (self.loop_stack.items.len > 0) {
            const ctx = self.loop_stack.items[self.loop_stack.items.len - 1];
            _ = try fb.emitJump(ctx.exit_block, Span.fromPos(Pos.zero));
        }
    }

    fn lowerContinue(self: *Lowerer) !void {
        const fb = self.current_func orelse return;
        if (self.loop_stack.items.len > 0) {
            const ctx = self.loop_stack.items[self.loop_stack.items.len - 1];
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
                if (operand_expr == .ident) {
                    if (fb.lookupLocal(operand_expr.ident.name)) |local_idx| {
                        const local_type = fb.locals.items[local_idx].type_idx;
                        const ptr_type = self.type_reg.makePointer(local_type) catch TypeRegistry.VOID;
                        return try fb.emitAddrLocal(local_idx, ptr_type, addr.span);
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
                // TODO: implement index expression
                _ = idx;
                return ir.null_node;
            },
            else => return ir.null_node,
        }
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
            return try fb.emitLoadLocal(local_idx, local_type, ident.span);
        }

        return ir.null_node;
    }

    fn lowerBinary(self: *Lowerer, bin: ast.Binary) Error!ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;

        const left = try self.lowerExprNode(bin.left);
        const right = try self.lowerExprNode(bin.right);
        const result_type = self.inferBinaryType(bin.op, bin.left, bin.right);
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
        const base_node = self.tree.getNode(fa.base) orelse return ir.null_node;
        const base_expr = base_node.asExpr() orelse return ir.null_node;

        if (base_expr == .ident) {
            // Base is an identifier - check if it's a local variable
            if (fb.lookupLocal(base_expr.ident.name)) |local_idx| {
                // Emit FieldLocal for direct access to struct local
                return try fb.emitFieldLocal(local_idx, field_idx, field_offset, field_type, fa.span);
            }
        }

        // Base is a computed expression - lower it and emit FieldValue
        const base_val = try self.lowerExprNode(fa.base);
        return try fb.emitFieldValue(base_val, field_idx, field_offset, field_type, fa.span);
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

        // Lower arguments
        var args = std.ArrayListUnmanaged(ir.NodeIndex){};
        defer args.deinit(self.allocator);

        for (call.args) |arg_idx| {
            const arg_node = try self.lowerExprNode(arg_idx);
            try args.append(self.allocator, arg_node);
        }

        // Determine return type (TODO: look up in symbol table)
        const return_type = TypeRegistry.VOID;

        return try fb.emitCall(func_name, args.items, false, return_type, call.span);
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

    // ========================================================================
    // Type Resolution
    // ========================================================================

    fn resolveTypeNode(self: *Lowerer, idx: NodeIndex) TypeIndex {
        const node = self.tree.getNode(idx) orelse return TypeRegistry.VOID;
        const expr = node.asExpr() orelse return TypeRegistry.VOID;

        switch (expr) {
            .type_expr => |te| return self.resolveTypeKind(te.kind),
            .ident => |ident| return self.type_reg.lookupByName(ident.name) orelse TypeRegistry.VOID,
            else => return TypeRegistry.VOID,
        }
    }

    fn resolveTypeKind(self: *Lowerer, kind: ast.TypeKind) TypeIndex {
        switch (kind) {
            .named => |name| return self.type_reg.lookupByName(name) orelse TypeRegistry.VOID,
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
            .@"and" => .bit_and,
            .@"or" => .bit_or,
            .xor => .bit_xor,
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

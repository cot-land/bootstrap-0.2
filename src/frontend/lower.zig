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
        // Process root nodes
        const root_nodes = self.tree.getRootDecls();
        for (root_nodes) |decl_idx| {
            try self.lowerDecl(decl_idx);
        }

        return self.builder.getIR();
    }

    // ========================================================================
    // Declaration Lowering
    // ========================================================================

    fn lowerDecl(self: *Lowerer, idx: NodeIndex) !void {
        const node = self.tree.getNode(idx);
        switch (node.tag) {
            .fn_decl => try self.lowerFnDecl(idx),
            .var_decl => try self.lowerVarDecl(idx, true),
            .const_decl => try self.lowerConstDecl(idx),
            .struct_decl => try self.lowerStructDecl(idx),
            .enum_decl, .union_decl, .type_alias => {}, // Type-only, no codegen
            else => {},
        }
    }

    fn lowerFnDecl(self: *Lowerer, idx: NodeIndex) !void {
        const node = self.tree.getNode(idx);
        const data = node.data.fn_decl;

        // Get function name
        const name_token = self.tree.getToken(data.name);
        const name = self.tree.getTokenSlice(name_token);

        // Resolve return type
        const return_type = if (data.return_type != null_node)
            self.resolveTypeNode(data.return_type)
        else
            TypeRegistry.VOID;

        const span = self.tree.getNodeSpan(idx);

        // Start building function
        self.builder.startFunc(name, TypeRegistry.VOID, return_type, span);

        if (self.builder.func()) |fb| {
            self.current_func = fb;

            // Add parameters
            const params = self.tree.getExtraSlice(data.params_start, data.params_end);
            for (params) |param_idx| {
                const param_node = self.tree.getNode(param_idx);
                const param_data = param_node.data.param;
                const param_name_tok = self.tree.getToken(param_data.name);
                const param_name = self.tree.getTokenSlice(param_name_tok);
                const param_type = self.resolveTypeNode(param_data.type_node);
                const param_size = self.type_reg.sizeOf(param_type);
                _ = try fb.addParam(param_name, param_type, param_size);
            }

            // Lower function body
            if (data.body != null_node) {
                _ = try self.lowerBlock(data.body);

                // Add implicit return for void functions
                if (return_type == TypeRegistry.VOID) {
                    const nodes = fb.nodes.items;
                    const needs_ret = nodes.len == 0 or !nodes[nodes.len - 1].isTerminator();
                    if (needs_ret) {
                        _ = try fb.emitRet(null, Span.fromPos(Pos.zero));
                    }
                }
            }

            self.current_func = null;
        }

        try self.builder.endFunc();
    }

    fn lowerVarDecl(self: *Lowerer, idx: NodeIndex, is_global: bool) !void {
        const node = self.tree.getNode(idx);
        const data = node.data.var_decl;

        // Get name
        const name_token = self.tree.getToken(data.name);
        const name = self.tree.getTokenSlice(name_token);

        // Resolve type
        var type_idx = TypeRegistry.VOID;
        if (data.type_node != null_node) {
            type_idx = self.resolveTypeNode(data.type_node);
        } else if (data.value != null_node) {
            type_idx = self.inferExprType(data.value);
        }

        if (is_global) {
            // Global variable
            const span = self.tree.getNodeSpan(idx);
            const global = ir.Global.init(name, type_idx, false, span);
            try self.builder.addGlobal(global);
        } else if (self.current_func) |fb| {
            // Local variable
            const size = self.type_reg.sizeOf(type_idx);
            const local_idx = try fb.addLocalWithSize(name, type_idx, data.is_mutable, size);

            // Initialize if there's a value
            if (data.value != null_node) {
                const value_node = try self.lowerExpr(data.value);
                _ = try fb.emitStoreLocal(local_idx, value_node, Span.fromPos(Pos.zero));
            }
        }
    }

    fn lowerConstDecl(self: *Lowerer, idx: NodeIndex) !void {
        const node = self.tree.getNode(idx);
        const data = node.data.const_decl;

        // Get name
        const name_token = self.tree.getToken(data.name);
        const name = self.tree.getTokenSlice(name_token);

        // Resolve type
        var type_idx = TypeRegistry.VOID;
        if (data.type_node != null_node) {
            type_idx = self.resolveTypeNode(data.type_node);
        } else if (data.value != null_node) {
            type_idx = self.inferExprType(data.value);
        }

        // Try to evaluate at compile time
        if (data.value != null_node) {
            if (self.evalConstExpr(data.value)) |value| {
                try self.const_values.put(name, value);
            }
        }

        // Add as global constant
        const span = self.tree.getNodeSpan(idx);
        const global = ir.Global.init(name, type_idx, true, span);
        try self.builder.addGlobal(global);
    }

    fn lowerStructDecl(self: *Lowerer, idx: NodeIndex) !void {
        const node = self.tree.getNode(idx);
        const data = node.data.struct_decl;

        // Get name
        const name_token = self.tree.getToken(data.name);
        const name = self.tree.getTokenSlice(name_token);

        // Look up struct type
        const struct_type_idx = self.type_reg.lookupByName(name) orelse TypeRegistry.VOID;
        const span = self.tree.getNodeSpan(idx);

        const struct_def = ir.StructDef{
            .name = name,
            .type_idx = struct_type_idx,
            .span = span,
        };
        try self.builder.addStruct(struct_def);
    }

    // ========================================================================
    // Statement Lowering
    // ========================================================================

    /// Lower a block, returning true if it ends with a terminator
    fn lowerBlock(self: *Lowerer, idx: NodeIndex) !bool {
        const node = self.tree.getNode(idx);
        var terminated = false;

        switch (node.tag) {
            .block => {
                const stmts = self.tree.getExtraSlice(node.data.block.stmts_start, node.data.block.stmts_end);
                for (stmts) |stmt_idx| {
                    const did_terminate = try self.lowerStmt(stmt_idx);
                    if (did_terminate) {
                        terminated = true;
                        break; // Don't lower dead code
                    }
                }
            },
            else => {
                terminated = try self.lowerStmt(idx);
            },
        }

        return terminated;
    }

    fn lowerStmt(self: *Lowerer, idx: NodeIndex) !bool {
        const node = self.tree.getNode(idx);

        switch (node.tag) {
            .return_stmt => {
                try self.lowerReturn(idx);
                return true;
            },
            .var_decl => {
                try self.lowerVarDecl(idx, false);
                return false;
            },
            .assign => {
                try self.lowerAssign(idx);
                return false;
            },
            .if_stmt => {
                try self.lowerIf(idx);
                return false;
            },
            .while_stmt => {
                try self.lowerWhile(idx);
                return false;
            },
            .for_stmt => {
                try self.lowerFor(idx);
                return false;
            },
            .block => {
                return try self.lowerBlock(idx);
            },
            .break_stmt => {
                try self.lowerBreak();
                return true;
            },
            .continue_stmt => {
                try self.lowerContinue();
                return true;
            },
            .expr_stmt => {
                _ = try self.lowerExpr(node.data.expr_stmt.expr);
                return false;
            },
            else => return false,
        }
    }

    fn lowerReturn(self: *Lowerer, idx: NodeIndex) !void {
        const fb = self.current_func orelse return;
        const node = self.tree.getNode(idx);
        const data = node.data.return_stmt;

        if (data.value != null_node) {
            const value_node = try self.lowerExpr(data.value);
            _ = try fb.emitRet(value_node, Span.fromPos(Pos.zero));
        } else {
            _ = try fb.emitRet(null, Span.fromPos(Pos.zero));
        }
    }

    fn lowerAssign(self: *Lowerer, idx: NodeIndex) !void {
        const fb = self.current_func orelse return;
        const node = self.tree.getNode(idx);
        const data = node.data.assign;

        // Get target
        const target_node = self.tree.getNode(data.target);

        switch (target_node.tag) {
            .identifier => {
                const ident_token = self.tree.getToken(target_node.data.identifier);
                const name = self.tree.getTokenSlice(ident_token);

                if (fb.lookupLocal(name)) |local_idx| {
                    const local_type = fb.locals.items[local_idx].type_idx;

                    // Handle compound assignment
                    const value_node = if (data.op != .equal) blk: {
                        // Load current value
                        const current = try fb.emitLoadLocal(local_idx, local_type, Span.fromPos(Pos.zero));
                        // Lower RHS
                        const rhs = try self.lowerExpr(data.value);
                        // Emit binary operation
                        const bin_op = tokenToBinaryOp(data.op);
                        break :blk try fb.emitBinary(bin_op, current, rhs, local_type, Span.fromPos(Pos.zero));
                    } else blk: {
                        break :blk try self.lowerExpr(data.value);
                    };

                    _ = try fb.emitStoreLocal(local_idx, value_node, Span.fromPos(Pos.zero));
                }
            },
            .field_access => {
                const fa_data = target_node.data.field_access;
                const chain = try self.resolveFieldChain(fa_data.base);
                if (chain.local_idx) |local_idx| {
                    const value_node = try self.lowerExpr(data.value);
                    const field_offset = chain.offset + self.getFieldOffset(chain.type_idx, fa_data.field);
                    _ = try fb.emitStoreLocalField(local_idx, 0, @intCast(field_offset), value_node, Span.fromPos(Pos.zero));
                }
            },
            .index => {
                const index_data = target_node.data.index;
                const base_node = try self.lowerExpr(index_data.base);
                const index_node = try self.lowerExpr(index_data.index);
                const value_node = try self.lowerExpr(data.value);

                // Determine if list or array
                const base_type_idx = self.inferExprType(index_data.base);
                const base_type = self.type_reg.get(base_type_idx);

                if (base_type == .list) {
                    _ = try fb.emit(ir.Node.init(
                        .{ .list_set = .{ .handle = base_node, .index = index_node, .value = value_node } },
                        TypeRegistry.VOID,
                        Span.fromPos(Pos.zero),
                    ));
                }
            },
            .deref => {
                const deref_data = target_node.data.deref;
                const ptr_node = try self.lowerExpr(deref_data.operand);
                const value_node = try self.lowerExpr(data.value);
                _ = try fb.emit(ir.Node.init(
                    .{ .ptr_store_value = .{ .ptr = ptr_node, .value = value_node } },
                    TypeRegistry.VOID,
                    Span.fromPos(Pos.zero),
                ));
            },
            else => {},
        }
    }

    fn lowerIf(self: *Lowerer, idx: NodeIndex) !void {
        const fb = self.current_func orelse return;
        const node = self.tree.getNode(idx);
        const data = node.data.if_stmt;

        // Lower condition
        const cond_node = try self.lowerExpr(data.condition);

        // Create blocks
        const then_block = try fb.newBlock("if.then");
        const else_block = if (data.else_branch != null_node) try fb.newBlock("if.else") else null;
        const merge_block = try fb.newBlock("if.merge");

        // Emit branch
        _ = try fb.emitBranch(cond_node, then_block, else_block orelse merge_block, Span.fromPos(Pos.zero));

        // Lower then block
        fb.setBlock(then_block);
        const then_terminated = try self.lowerBlock(data.then_branch);
        if (!then_terminated) {
            _ = try fb.emitJump(merge_block, Span.fromPos(Pos.zero));
        }

        // Lower else block if present
        if (data.else_branch != null_node) {
            fb.setBlock(else_block.?);
            const else_terminated = try self.lowerBlock(data.else_branch);
            if (!else_terminated) {
                _ = try fb.emitJump(merge_block, Span.fromPos(Pos.zero));
            }
        }

        // Continue in merge block
        fb.setBlock(merge_block);
    }

    fn lowerWhile(self: *Lowerer, idx: NodeIndex) !void {
        const fb = self.current_func orelse return;
        const node = self.tree.getNode(idx);
        const data = node.data.while_stmt;

        // Create blocks
        const cond_block = try fb.newBlock("while.cond");
        const body_block = try fb.newBlock("while.body");
        const exit_block = try fb.newBlock("while.exit");

        // Push loop context
        try self.loop_stack.append(self.allocator, .{
            .cond_block = cond_block,
            .exit_block = exit_block,
        });

        // Jump to condition
        _ = try fb.emitJump(cond_block, Span.fromPos(Pos.zero));

        // Condition block
        fb.setBlock(cond_block);
        const cond_node = try self.lowerExpr(data.condition);
        _ = try fb.emitBranch(cond_node, body_block, exit_block, Span.fromPos(Pos.zero));

        // Body block
        fb.setBlock(body_block);
        const body_terminated = try self.lowerBlock(data.body);
        if (!body_terminated) {
            _ = try fb.emitJump(cond_block, Span.fromPos(Pos.zero));
        }

        // Pop loop context
        _ = self.loop_stack.pop();

        // Continue in exit block
        fb.setBlock(exit_block);
    }

    fn lowerFor(self: *Lowerer, idx: NodeIndex) !void {
        const fb = self.current_func orelse return;
        const node = self.tree.getNode(idx);
        const data = node.data.for_stmt;

        // Get binding name
        const binding_token = self.tree.getToken(data.binding);
        const binding_name = self.tree.getTokenSlice(binding_token);

        // Get iterable type
        const iter_type_idx = self.inferExprType(data.iterable);
        const iter_type = self.type_reg.get(iter_type_idx);

        // Determine element type and if it's a slice
        var elem_type: TypeIndex = TypeRegistry.INT;
        var arr_len: ?usize = null;
        var is_slice = false;

        switch (iter_type) {
            .array => |a| {
                elem_type = a.elem;
                arr_len = a.len;
            },
            .slice => |s| {
                elem_type = s.elem;
                is_slice = true;
            },
            else => return,
        }

        // Generate unique index variable name
        var idx_name_buf: [32]u8 = undefined;
        const idx_name = std.fmt.bufPrint(&idx_name_buf, "__for_idx_{d}", .{self.temp_counter}) catch "__for_idx";
        self.temp_counter += 1;

        // Create index variable
        const idx_local = try fb.addLocalWithSize(idx_name, TypeRegistry.INT, true, 8);
        const zero = try fb.emitConstInt(0, TypeRegistry.INT, Span.fromPos(Pos.zero));
        _ = try fb.emitStoreLocal(idx_local, zero, Span.fromPos(Pos.zero));

        // Create loop variable
        const elem_size = self.type_reg.sizeOf(elem_type);
        const item_local = try fb.addLocalWithSize(binding_name, elem_type, true, elem_size);

        // Create blocks
        const cond_block = try fb.newBlock("for.cond");
        const body_block = try fb.newBlock("for.body");
        const incr_block = try fb.newBlock("for.incr");
        const exit_block = try fb.newBlock("for.exit");

        // Push loop context (continue -> incr)
        try self.loop_stack.append(self.allocator, .{
            .cond_block = incr_block,
            .exit_block = exit_block,
        });

        // Jump to condition
        _ = try fb.emitJump(cond_block, Span.fromPos(Pos.zero));

        // Condition block
        fb.setBlock(cond_block);
        const idx_val = try fb.emitLoadLocal(idx_local, TypeRegistry.INT, Span.fromPos(Pos.zero));

        // Get length
        const len_val = if (arr_len) |len|
            try fb.emitConstInt(@intCast(len), TypeRegistry.INT, Span.fromPos(Pos.zero))
        else if (is_slice) blk: {
            // For slices, load length from the slice structure
            const iter_node = self.tree.getNode(data.iterable);
            if (iter_node.tag == .identifier) {
                const ident_token = self.tree.getToken(iter_node.data.identifier);
                const iter_name = self.tree.getTokenSlice(ident_token);
                if (fb.lookupLocal(iter_name)) |iter_local| {
                    break :blk try fb.emitFieldLocal(iter_local, 0, 8, TypeRegistry.INT, Span.fromPos(Pos.zero));
                }
            }
            break :blk try fb.emitConstInt(0, TypeRegistry.INT, Span.fromPos(Pos.zero));
        } else try fb.emitConstInt(0, TypeRegistry.INT, Span.fromPos(Pos.zero));

        const cmp = try fb.emitBinary(.lt, idx_val, len_val, TypeRegistry.BOOL, Span.fromPos(Pos.zero));
        _ = try fb.emitBranch(cmp, body_block, exit_block, Span.fromPos(Pos.zero));

        // Body block
        fb.setBlock(body_block);

        // Load element at current index
        const idx_val2 = try fb.emitLoadLocal(idx_local, TypeRegistry.INT, Span.fromPos(Pos.zero));
        const iter_node = self.tree.getNode(data.iterable);
        if (iter_node.tag == .identifier) {
            const ident_token = self.tree.getToken(iter_node.data.identifier);
            const iter_name = self.tree.getTokenSlice(ident_token);
            if (fb.lookupLocal(iter_name)) |iter_local| {
                const elem_val = try fb.emitIndexLocal(iter_local, idx_val2, @intCast(elem_size), elem_type, Span.fromPos(Pos.zero));
                _ = try fb.emitStoreLocal(item_local, elem_val, Span.fromPos(Pos.zero));
            }
        }

        // Execute body
        const body_terminated = try self.lowerBlock(data.body);
        if (!body_terminated) {
            _ = try fb.emitJump(incr_block, Span.fromPos(Pos.zero));
        }

        // Increment block
        fb.setBlock(incr_block);
        const idx_val3 = try fb.emitLoadLocal(idx_local, TypeRegistry.INT, Span.fromPos(Pos.zero));
        const one = try fb.emitConstInt(1, TypeRegistry.INT, Span.fromPos(Pos.zero));
        const new_idx = try fb.emitBinary(.add, idx_val3, one, TypeRegistry.INT, Span.fromPos(Pos.zero));
        _ = try fb.emitStoreLocal(idx_local, new_idx, Span.fromPos(Pos.zero));
        _ = try fb.emitJump(cond_block, Span.fromPos(Pos.zero));

        // Pop loop context
        _ = self.loop_stack.pop();

        // Exit block
        fb.setBlock(exit_block);
    }

    fn lowerBreak(self: *Lowerer) !void {
        const fb = self.current_func orelse return;
        if (self.loop_stack.items.len == 0) return;

        const loop_ctx = self.loop_stack.items[self.loop_stack.items.len - 1];
        _ = try fb.emitJump(loop_ctx.exit_block, Span.fromPos(Pos.zero));
    }

    fn lowerContinue(self: *Lowerer) !void {
        const fb = self.current_func orelse return;
        if (self.loop_stack.items.len == 0) return;

        const loop_ctx = self.loop_stack.items[self.loop_stack.items.len - 1];
        _ = try fb.emitJump(loop_ctx.cond_block, Span.fromPos(Pos.zero));
    }

    // ========================================================================
    // Expression Lowering
    // ========================================================================

    fn lowerExpr(self: *Lowerer, idx: NodeIndex) !ir.NodeIndex {
        if (idx == null_node) return ir.null_node;

        const node = self.tree.getNode(idx);
        const span = self.tree.getNodeSpan(idx);

        return switch (node.tag) {
            .identifier => self.lowerIdentifier(idx),
            .int_literal => self.lowerIntLiteral(idx),
            .float_literal => self.lowerFloatLiteral(idx),
            .string_literal => self.lowerStringLiteral(idx),
            .bool_literal => self.lowerBoolLiteral(idx),
            .binary => self.lowerBinary(idx),
            .unary => self.lowerUnary(idx),
            .call => self.lowerCall(idx),
            .index => self.lowerIndex(idx),
            .field_access => self.lowerFieldAccess(idx),
            .if_expr => self.lowerIfExpr(idx),
            .grouped => self.lowerExpr(node.data.grouped.inner),
            .struct_init => self.lowerStructInit(idx),
            .array_init => self.lowerArrayInit(idx),
            .addr_of => self.lowerAddrOf(idx),
            .deref => self.lowerDeref(idx),
            else => blk: {
                // Emit nop for unsupported expressions
                if (self.current_func) |fb| {
                    break :blk try fb.emitNop(span);
                }
                break :blk ir.null_node;
            },
        };
    }

    fn lowerIdentifier(self: *Lowerer, idx: NodeIndex) !ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;
        const node = self.tree.getNode(idx);
        const ident_token = self.tree.getToken(node.data.identifier);
        const name = self.tree.getTokenSlice(ident_token);
        const span = self.tree.getNodeSpan(idx);

        // Check for compile-time constant
        if (self.const_values.get(name)) |value| {
            return try fb.emitConstInt(value, TypeRegistry.INT, span);
        }

        // Check for local variable
        if (fb.lookupLocal(name)) |local_idx| {
            const local_type = fb.locals.items[local_idx].type_idx;
            return try fb.emitLoadLocal(local_idx, local_type, span);
        }

        // Check for boolean literals
        if (std.mem.eql(u8, name, "true")) {
            return try fb.emitConstBool(true, span);
        }
        if (std.mem.eql(u8, name, "false")) {
            return try fb.emitConstBool(false, span);
        }
        if (std.mem.eql(u8, name, "null")) {
            return try fb.emitConstNull(TypeRegistry.VOID, span);
        }

        return ir.null_node;
    }

    fn lowerIntLiteral(self: *Lowerer, idx: NodeIndex) !ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;
        const node = self.tree.getNode(idx);
        const lit_token = self.tree.getToken(node.data.int_literal);
        const text = self.tree.getTokenSlice(lit_token);
        const span = self.tree.getNodeSpan(idx);

        const value = std.fmt.parseInt(i64, text, 0) catch 0;
        return try fb.emitConstInt(value, TypeRegistry.INT, span);
    }

    fn lowerFloatLiteral(self: *Lowerer, idx: NodeIndex) !ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;
        const node = self.tree.getNode(idx);
        const lit_token = self.tree.getToken(node.data.float_literal);
        const text = self.tree.getTokenSlice(lit_token);
        const span = self.tree.getNodeSpan(idx);

        const value = std.fmt.parseFloat(f64, text) catch 0.0;
        return try fb.emitConstFloat(value, TypeRegistry.F64, span);
    }

    fn lowerStringLiteral(self: *Lowerer, idx: NodeIndex) !ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;
        const node = self.tree.getNode(idx);
        const lit_token = self.tree.getToken(node.data.string_literal);
        var text = self.tree.getTokenSlice(lit_token);
        const span = self.tree.getNodeSpan(idx);

        // Strip quotes
        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
            text = text[1 .. text.len - 1];
        }

        const string_idx = try fb.addStringLiteral(text);
        return try fb.emitConstSlice(string_idx, span);
    }

    fn lowerBoolLiteral(self: *Lowerer, idx: NodeIndex) !ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;
        const node = self.tree.getNode(idx);
        const span = self.tree.getNodeSpan(idx);

        return try fb.emitConstBool(node.data.bool_literal, span);
    }

    fn lowerBinary(self: *Lowerer, idx: NodeIndex) !ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;
        const node = self.tree.getNode(idx);
        const data = node.data.binary;
        const span = self.tree.getNodeSpan(idx);

        const left = try self.lowerExpr(data.lhs);
        const right = try self.lowerExpr(data.rhs);

        const op = tokenToBinaryOp(data.op);
        const result_type = if (op.isComparison()) TypeRegistry.BOOL else self.inferExprType(idx);

        return try fb.emitBinary(op, left, right, result_type, span);
    }

    fn lowerUnary(self: *Lowerer, idx: NodeIndex) !ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;
        const node = self.tree.getNode(idx);
        const data = node.data.unary;
        const span = self.tree.getNodeSpan(idx);

        const operand = try self.lowerExpr(data.operand);

        const op: ir.UnaryOp = switch (data.op) {
            .minus => .neg,
            .bang => .not,
            .tilde => .bit_not,
            else => .neg,
        };

        const result_type = self.inferExprType(idx);
        return try fb.emitUnary(op, operand, result_type, span);
    }

    fn lowerCall(self: *Lowerer, idx: NodeIndex) !ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;
        const node = self.tree.getNode(idx);
        const data = node.data.call;
        const span = self.tree.getNodeSpan(idx);

        // Get function name
        const callee_node = self.tree.getNode(data.callee);
        var func_name: []const u8 = "unknown";
        var is_builtin = false;

        if (callee_node.tag == .identifier) {
            const ident_token = self.tree.getToken(callee_node.data.identifier);
            func_name = self.tree.getTokenSlice(ident_token);
            is_builtin = func_name.len > 0 and func_name[0] == '@';
        }

        // Lower arguments
        const args = self.tree.getExtraSlice(data.args_start, data.args_end);
        var lowered_args = std.ArrayListUnmanaged(ir.NodeIndex){};
        defer lowered_args.deinit(self.allocator);

        for (args) |arg_idx| {
            const arg_node = try self.lowerExpr(arg_idx);
            try lowered_args.append(self.allocator, arg_node);
        }

        const result_type = self.inferExprType(idx);
        return try fb.emitCall(func_name, lowered_args.items, is_builtin, result_type, span);
    }

    fn lowerIndex(self: *Lowerer, idx: NodeIndex) !ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;
        const node = self.tree.getNode(idx);
        const data = node.data.index;
        const span = self.tree.getNodeSpan(idx);

        const base_type_idx = self.inferExprType(data.base);
        const base_type = self.type_reg.get(base_type_idx);

        // Determine element type and size
        var elem_type: TypeIndex = TypeRegistry.INT;
        var elem_size: u32 = 8;

        switch (base_type) {
            .array => |a| {
                elem_type = a.elem;
                elem_size = self.type_reg.sizeOf(elem_type);
            },
            .slice => |s| {
                elem_type = s.elem;
                elem_size = self.type_reg.sizeOf(elem_type);
            },
            .list => |l| {
                elem_type = l.elem;
                elem_size = self.type_reg.sizeOf(elem_type);

                // List indexing - emit list_get
                const handle = try self.lowerExpr(data.base);
                const index_val = try self.lowerExpr(data.index);
                return try fb.emit(ir.Node.init(
                    .{ .list_get = .{ .handle = handle, .index = index_val } },
                    elem_type,
                    span,
                ));
            },
            else => {},
        }

        // Array/slice indexing - check if base is a local
        const base_node = self.tree.getNode(data.base);
        if (base_node.tag == .identifier) {
            const ident_token = self.tree.getToken(base_node.data.identifier);
            const name = self.tree.getTokenSlice(ident_token);
            if (fb.lookupLocal(name)) |local_idx| {
                const index_val = try self.lowerExpr(data.index);
                return try fb.emitIndexLocal(local_idx, index_val, elem_size, elem_type, span);
            }
        }

        // Fallback: computed index
        const base_val = try self.lowerExpr(data.base);
        const index_val = try self.lowerExpr(data.index);
        return try fb.emitIndexValue(base_val, index_val, elem_size, elem_type, span);
    }

    fn lowerFieldAccess(self: *Lowerer, idx: NodeIndex) !ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;
        const node = self.tree.getNode(idx);
        const data = node.data.field_access;
        const span = self.tree.getNodeSpan(idx);

        // Try to resolve to a local field access
        const chain = try self.resolveFieldChain(data.base);
        const field_type = self.inferExprType(idx);

        if (chain.local_idx) |local_idx| {
            const field_offset = chain.offset + self.getFieldOffset(chain.type_idx, data.field);
            return try fb.emitFieldLocal(local_idx, 0, @intCast(field_offset), field_type, span);
        }

        // Fallback: computed field access
        const base_val = try self.lowerExpr(data.base);
        const field_offset = self.getFieldOffset(self.inferExprType(data.base), data.field);
        return try fb.emitFieldValue(base_val, 0, @intCast(field_offset), field_type, span);
    }

    fn lowerIfExpr(self: *Lowerer, idx: NodeIndex) !ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;
        const node = self.tree.getNode(idx);
        const data = node.data.if_expr;
        const span = self.tree.getNodeSpan(idx);

        const cond = try self.lowerExpr(data.condition);
        const then_val = try self.lowerExpr(data.then_expr);
        const else_val = try self.lowerExpr(data.else_expr);
        const result_type = self.inferExprType(idx);

        return try fb.emitSelect(cond, then_val, else_val, result_type, span);
    }

    fn lowerStructInit(self: *Lowerer, idx: NodeIndex) !ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;
        const node = self.tree.getNode(idx);
        const data = node.data.struct_init;
        const span = self.tree.getNodeSpan(idx);

        // Get struct type
        const type_name_token = self.tree.getToken(data.type_name);
        const type_name = self.tree.getTokenSlice(type_name_token);
        const struct_type_idx = self.type_reg.lookupByName(type_name) orelse TypeRegistry.VOID;
        const struct_size = self.type_reg.sizeOf(struct_type_idx);

        // Allocate temporary
        var tmp_name_buf: [32]u8 = undefined;
        const tmp_name = std.fmt.bufPrint(&tmp_name_buf, "__struct_tmp_{d}", .{self.temp_counter}) catch "__struct_tmp";
        self.temp_counter += 1;

        const tmp_local = try fb.addLocalWithSize(tmp_name, struct_type_idx, false, struct_size);

        // Initialize fields
        const fields = self.tree.getExtraSlice(data.fields_start, data.fields_end);
        for (fields) |field_idx| {
            const field_node = self.tree.getNode(field_idx);
            const field_data = field_node.data.field_init;

            const field_name_token = self.tree.getToken(field_data.name);
            const field_name = self.tree.getTokenSlice(field_name_token);
            const field_offset = self.getFieldOffset(struct_type_idx, field_name_token);

            const value = try self.lowerExpr(field_data.value);
            _ = try fb.emitStoreLocalField(tmp_local, 0, @intCast(field_offset), value, span);
            _ = field_name;
        }

        // Return loaded struct
        return try fb.emitLoadLocal(tmp_local, struct_type_idx, span);
    }

    fn lowerArrayInit(self: *Lowerer, idx: NodeIndex) !ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;
        const node = self.tree.getNode(idx);
        const data = node.data.array_init;
        const span = self.tree.getNodeSpan(idx);

        // Get array type
        const array_type_idx = self.inferExprType(idx);
        const array_size = self.type_reg.sizeOf(array_type_idx);

        // Allocate temporary
        var tmp_name_buf: [32]u8 = undefined;
        const tmp_name = std.fmt.bufPrint(&tmp_name_buf, "__array_tmp_{d}", .{self.temp_counter}) catch "__array_tmp";
        self.temp_counter += 1;

        const tmp_local = try fb.addLocalWithSize(tmp_name, array_type_idx, false, array_size);

        // Get element info
        const array_type = self.type_reg.get(array_type_idx);
        var elem_type: TypeIndex = TypeRegistry.INT;
        var elem_size: u32 = 8;
        if (array_type == .array) {
            elem_type = array_type.array.elem;
            elem_size = self.type_reg.sizeOf(elem_type);
        }

        // Initialize elements
        const elements = self.tree.getExtraSlice(data.elements_start, data.elements_end);
        for (elements, 0..) |elem_idx, i| {
            const value = try self.lowerExpr(elem_idx);
            const offset: i64 = @intCast(i * elem_size);
            _ = try fb.emitStoreLocalField(tmp_local, 0, offset, value, span);
        }

        // Return loaded array
        return try fb.emitLoadLocal(tmp_local, array_type_idx, span);
    }

    fn lowerAddrOf(self: *Lowerer, idx: NodeIndex) !ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;
        const node = self.tree.getNode(idx);
        const data = node.data.addr_of;
        const span = self.tree.getNodeSpan(idx);

        // Get operand - must be addressable
        const operand_node = self.tree.getNode(data.operand);
        if (operand_node.tag == .identifier) {
            const ident_token = self.tree.getToken(operand_node.data.identifier);
            const name = self.tree.getTokenSlice(ident_token);
            if (fb.lookupLocal(name)) |local_idx| {
                const ptr_type = self.inferExprType(idx);
                return try fb.emitAddrLocal(local_idx, ptr_type, span);
            }
        }

        return ir.null_node;
    }

    fn lowerDeref(self: *Lowerer, idx: NodeIndex) !ir.NodeIndex {
        const fb = self.current_func orelse return ir.null_node;
        const node = self.tree.getNode(idx);
        const data = node.data.deref;
        const span = self.tree.getNodeSpan(idx);

        // Check if operand is a local pointer
        const operand_node = self.tree.getNode(data.operand);
        if (operand_node.tag == .identifier) {
            const ident_token = self.tree.getToken(operand_node.data.identifier);
            const name = self.tree.getTokenSlice(ident_token);
            if (fb.lookupLocal(name)) |local_idx| {
                const result_type = self.inferExprType(idx);
                return try fb.emitPtrLoad(local_idx, result_type, span);
            }
        }

        // General case: computed pointer
        const ptr_val = try self.lowerExpr(data.operand);
        const result_type = self.inferExprType(idx);
        return try fb.emit(ir.Node.init(
            .{ .ptr_load_value = .{ .ptr = ptr_val } },
            result_type,
            span,
        ));
    }

    // ========================================================================
    // Helper Functions
    // ========================================================================

    fn resolveTypeNode(self: *Lowerer, idx: NodeIndex) TypeIndex {
        if (idx == null_node) return TypeRegistry.VOID;

        const node = self.tree.getNode(idx);
        switch (node.tag) {
            .type_name => {
                const name_token = self.tree.getToken(node.data.type_name);
                const name = self.tree.getTokenSlice(name_token);
                return self.type_reg.lookupByName(name) orelse self.type_reg.lookupBasic(name) orelse TypeRegistry.VOID;
            },
            .pointer_type => {
                const pointee = self.resolveTypeNode(node.data.pointer_type.pointee);
                return self.type_reg.makePointer(pointee) catch TypeRegistry.VOID;
            },
            .array_type => {
                const elem = self.resolveTypeNode(node.data.array_type.elem_type);
                return self.type_reg.makeArray(elem, node.data.array_type.len) catch TypeRegistry.VOID;
            },
            .slice_type => {
                const elem = self.resolveTypeNode(node.data.slice_type.elem_type);
                return self.type_reg.makeSlice(elem) catch TypeRegistry.VOID;
            },
            else => return TypeRegistry.VOID,
        }
    }

    fn inferExprType(self: *Lowerer, idx: NodeIndex) TypeIndex {
        // Use checker's type cache if available
        if (self.chk.expr_types.get(idx)) |type_idx| {
            return type_idx;
        }

        // Fallback inference
        const node = self.tree.getNode(idx);
        return switch (node.tag) {
            .int_literal => TypeRegistry.INT,
            .float_literal => TypeRegistry.F64,
            .string_literal => TypeRegistry.STRING,
            .bool_literal => TypeRegistry.BOOL,
            .identifier => blk: {
                if (self.current_func) |fb| {
                    const ident_token = self.tree.getToken(node.data.identifier);
                    const name = self.tree.getTokenSlice(ident_token);
                    if (fb.lookupLocal(name)) |local_idx| {
                        break :blk fb.locals.items[local_idx].type_idx;
                    }
                }
                break :blk TypeRegistry.VOID;
            },
            else => TypeRegistry.VOID,
        };
    }

    fn evalConstExpr(self: *Lowerer, idx: NodeIndex) ?i64 {
        const node = self.tree.getNode(idx);

        return switch (node.tag) {
            .int_literal => blk: {
                const lit_token = self.tree.getToken(node.data.int_literal);
                const text = self.tree.getTokenSlice(lit_token);
                break :blk std.fmt.parseInt(i64, text, 0) catch null;
            },
            .identifier => blk: {
                const ident_token = self.tree.getToken(node.data.identifier);
                const name = self.tree.getTokenSlice(ident_token);
                break :blk self.const_values.get(name);
            },
            .binary => blk: {
                const data = node.data.binary;
                const left = self.evalConstExpr(data.lhs) orelse break :blk null;
                const right = self.evalConstExpr(data.rhs) orelse break :blk null;

                break :blk switch (data.op) {
                    .plus => left +% right,
                    .minus => left -% right,
                    .star => left *% right,
                    .slash => if (right != 0) @divTrunc(left, right) else null,
                    .percent, .rem => if (right != 0) @rem(left, right) else null,
                    else => null,
                };
            },
            .unary => blk: {
                const data = node.data.unary;
                const operand = self.evalConstExpr(data.operand) orelse break :blk null;
                break :blk switch (data.op) {
                    .minus => -%operand,
                    else => null,
                };
            },
            .grouped => self.evalConstExpr(node.data.grouped.inner),
            else => null,
        };
    }

    const FieldChain = struct {
        local_idx: ?ir.LocalIdx,
        offset: i64,
        type_idx: TypeIndex,
    };

    fn resolveFieldChain(self: *Lowerer, idx: NodeIndex) !FieldChain {
        const node = self.tree.getNode(idx);

        if (node.tag == .identifier) {
            if (self.current_func) |fb| {
                const ident_token = self.tree.getToken(node.data.identifier);
                const name = self.tree.getTokenSlice(ident_token);
                if (fb.lookupLocal(name)) |local_idx| {
                    return .{
                        .local_idx = local_idx,
                        .offset = 0,
                        .type_idx = fb.locals.items[local_idx].type_idx,
                    };
                }
            }
        } else if (node.tag == .field_access) {
            const data = node.data.field_access;
            var chain = try self.resolveFieldChain(data.base);
            chain.offset += self.getFieldOffset(chain.type_idx, data.field);
            chain.type_idx = self.inferExprType(idx);
            return chain;
        }

        return .{ .local_idx = null, .offset = 0, .type_idx = TypeRegistry.VOID };
    }

    fn getFieldOffset(self: *Lowerer, type_idx: TypeIndex, field_token: u32) i64 {
        const t = self.type_reg.get(type_idx);
        if (t != .struct_type) return 0;

        const field_name = self.tree.getTokenSlice(self.tree.getToken(field_token));
        for (t.struct_type.fields) |f| {
            if (std.mem.eql(u8, f.name, field_name)) {
                return @intCast(f.offset);
            }
        }
        return 0;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

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
        .land => .@"and",
        .lor => .@"or",
        .@"and", .and_assign => .bit_and,
        .@"or", .or_assign => .bit_or,
        .xor, .xor_assign => .bit_xor,
        .shl => .shl,
        .shr => .shr,
        else => .add,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "lowerer loop context management" {
    // Test loop stack operations without full lowerer setup
    const allocator = std.testing.allocator;

    var loop_stack = std.ArrayListUnmanaged(Lowerer.LoopContext){};
    defer loop_stack.deinit(allocator);

    // Push a loop context
    try loop_stack.append(allocator, .{
        .cond_block = 1,
        .exit_block = 2,
    });
    try std.testing.expectEqual(@as(usize, 1), loop_stack.items.len);

    // Push another
    try loop_stack.append(allocator, .{
        .cond_block = 3,
        .exit_block = 4,
    });
    try std.testing.expectEqual(@as(usize, 2), loop_stack.items.len);

    // Pop
    _ = loop_stack.pop();
    try std.testing.expectEqual(@as(usize, 1), loop_stack.items.len);

    // Verify innermost is correct
    const ctx = loop_stack.items[0];
    try std.testing.expectEqual(@as(ir.BlockIndex, 1), ctx.cond_block);
    try std.testing.expectEqual(@as(ir.BlockIndex, 2), ctx.exit_block);
}

test "tokenToBinaryOp" {
    try std.testing.expectEqual(ir.BinaryOp.add, tokenToBinaryOp(.add));
    try std.testing.expectEqual(ir.BinaryOp.sub, tokenToBinaryOp(.sub));
    try std.testing.expectEqual(ir.BinaryOp.mul, tokenToBinaryOp(.mul));
    try std.testing.expectEqual(ir.BinaryOp.div, tokenToBinaryOp(.quo));
    try std.testing.expectEqual(ir.BinaryOp.eq, tokenToBinaryOp(.eql));
    try std.testing.expectEqual(ir.BinaryOp.ne, tokenToBinaryOp(.neq));
    try std.testing.expectEqual(ir.BinaryOp.lt, tokenToBinaryOp(.lss));
    try std.testing.expectEqual(ir.BinaryOp.@"and", tokenToBinaryOp(.land));
    try std.testing.expectEqual(ir.BinaryOp.@"or", tokenToBinaryOp(.lor));
}

test "binary op predicates in lowering context" {
    // Test that binary ops from lowering have correct properties
    const add_op = tokenToBinaryOp(.add);
    try std.testing.expect(add_op.isArithmetic());
    try std.testing.expect(!add_op.isComparison());

    const eq_op = tokenToBinaryOp(.eql);
    try std.testing.expect(eq_op.isComparison());
    try std.testing.expect(!eq_op.isArithmetic());

    const and_op = tokenToBinaryOp(.land);
    try std.testing.expect(and_op.isLogical());
    try std.testing.expect(!and_op.isBitwise());

    const bit_and_op = tokenToBinaryOp(.@"and");
    try std.testing.expect(bit_and_op.isBitwise());
    try std.testing.expect(!bit_and_op.isLogical());
}

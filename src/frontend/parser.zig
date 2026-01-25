//! Recursive descent parser for Cot source files.
//!
//! Architecture modeled on Go's go/parser package:
//! - Parser struct with scanner, current token, AST, error reporter
//! - next() advances scanner, expect() validates and consumes
//! - Nesting level tracking to prevent stack overflow
//! - Pratt parsing / precedence climbing for expressions
//!
//! Improvements over bootstrap:
//! - Exhaustive switch handling where possible
//! - Clearer error recovery strategy
//! - Go-style parsing patterns

const std = @import("std");
const source = @import("source.zig");
const token = @import("token.zig");
const scanner = @import("scanner.zig");
const ast = @import("ast.zig");
const errors = @import("errors.zig");

const Token = token.Token;
const Pos = source.Pos;
const Span = source.Span;
const Scanner = scanner.Scanner;
const TokenInfo = scanner.TokenInfo;
const Ast = ast.Ast;
const NodeIndex = ast.NodeIndex;
const null_node = ast.null_node;
const ErrorReporter = errors.ErrorReporter;
const ErrorCode = errors.ErrorCode;

// =========================================
// Parser
// =========================================

/// Parser holds the parser's internal state.
pub const Parser = struct {
    allocator: std.mem.Allocator,
    scan: *Scanner,
    tree: *Ast,
    err: *ErrorReporter,

    /// Current token.
    tok: TokenInfo,

    /// Peek token for 1-token lookahead (null if not yet peeked).
    peek_tok: ?TokenInfo,

    /// Nesting depth for recursion limit.
    nest_lev: u32,

    /// Maximum nesting level (Go uses 1e5, we use something reasonable).
    const max_nest_lev: u32 = 10000;

    pub const ParseError = error{OutOfMemory};

    pub fn init(
        allocator: std.mem.Allocator,
        scan: *Scanner,
        tree: *Ast,
        err: *ErrorReporter,
    ) Parser {
        var p = Parser{
            .allocator = allocator,
            .scan = scan,
            .tree = tree,
            .err = err,
            .tok = undefined,
            .peek_tok = null,
            .nest_lev = 0,
        };
        // Prime the parser with first token
        p.advance();
        return p;
    }

    // ========================================================================
    // Token handling
    // ========================================================================

    /// Get current position.
    fn pos(self: *const Parser) Pos {
        return self.tok.span.start;
    }

    /// Advance to next token.
    fn advance(self: *Parser) void {
        // Use peek token if available, otherwise scan next
        if (self.peek_tok) |peek| {
            self.tok = peek;
            self.peek_tok = null;
        } else {
            self.tok = self.scan.next();
        }
    }

    /// Peek at the next token without consuming it.
    fn peekToken(self: *Parser) TokenInfo {
        if (self.peek_tok) |peek| {
            return peek;
        }
        self.peek_tok = self.scan.next();
        return self.peek_tok.?;
    }

    /// Check if current token matches.
    fn check(self: *const Parser, t: Token) bool {
        return self.tok.tok == t;
    }

    /// Check if the next token after '{' is '.' (period).
    /// Used to distinguish struct literals (Type{ .field = ... }) from blocks.
    /// This uses proper 1-token lookahead without consuming.
    fn peekNextIsPeriod(self: *Parser) bool {
        if (!self.check(.lbrace)) return false;
        // Peek at the token AFTER the current '{' without consuming
        const next = self.peekToken();
        return next.tok == .period;
    }

    /// Match and consume if current token matches.
    fn match(self: *Parser, t: Token) bool {
        if (self.check(t)) {
            self.advance();
            return true;
        }
        return false;
    }

    /// Expect token or report error.
    fn expect(self: *Parser, t: Token) bool {
        if (self.check(t)) {
            self.advance();
            return true;
        }
        self.unexpectedToken(t);
        return false;
    }

    /// Report unexpected token error.
    fn unexpectedToken(self: *Parser, expected: Token) void {
        const msg = switch (expected) {
            .ident => "expected identifier",
            .lbrace => "expected '{'",
            .rbrace => "expected '}'",
            .lparen => "expected '('",
            .rparen => "expected ')'",
            .lbrack => "expected '['",
            .rbrack => "expected ']'",
            .semicolon => "expected ';'",
            .colon => "expected ':'",
            .comma => "expected ','",
            .assign => "expected '='",
            .fat_arrow => "expected '=>'",
            .kw_in => "expected 'in'",
            else => "unexpected token",
        };
        self.err.errorAt(self.pos(), msg);
    }

    /// Report a syntax error.
    fn syntaxError(self: *Parser, msg: []const u8) void {
        self.err.errorAt(self.pos(), msg);
    }

    /// Increment nesting level (with overflow protection).
    fn incNest(self: *Parser) bool {
        self.nest_lev += 1;
        if (self.nest_lev > max_nest_lev) {
            self.err.errorAt(self.pos(), "exceeded maximum nesting depth");
            return false;
        }
        return true;
    }

    /// Decrement nesting level.
    fn decNest(self: *Parser) void {
        self.nest_lev -= 1;
    }

    // ========================================================================
    // File parsing
    // ========================================================================

    /// Parse a complete source file.
    pub fn parseFile(self: *Parser) ParseError!void {
        const start = self.pos();

        var decls = std.ArrayListUnmanaged(NodeIndex){};
        defer decls.deinit(self.allocator);

        while (!self.check(.eof)) {
            if (try self.parseDecl()) |decl_idx| {
                try decls.append(self.allocator, decl_idx);
            } else {
                // Error recovery: skip to next declaration
                self.advance();
            }
        }

        self.tree.file = .{
            .filename = self.scan.src.filename,
            .decls = try self.allocator.dupe(NodeIndex, decls.items),
            .span = Span.init(start, self.pos()),
        };
    }

    // ========================================================================
    // Declaration parsing
    // ========================================================================

    /// Parse a top-level declaration.
    fn parseDecl(self: *Parser) ParseError!?NodeIndex {
        return switch (self.tok.tok) {
            .kw_extern => self.parseExternFn(),
            .kw_fn => self.parseFnDecl(false),
            .kw_var => self.parseVarDecl(false),
            .kw_const => self.parseVarDecl(true),
            .kw_struct => self.parseStructDecl(),
            .kw_enum => self.parseEnumDecl(),
            .kw_union => self.parseUnionDecl(),
            .kw_type => self.parseTypeAlias(),
            .kw_import => self.parseImportDecl(),
            else => {
                self.syntaxError("expected declaration");
                return null;
            },
        };
    }

    /// Parse extern function declaration: extern fn name(params) return_type;
    fn parseExternFn(self: *Parser) ParseError!?NodeIndex {
        self.advance(); // consume 'extern'
        if (!self.check(.kw_fn)) {
            self.err.errorAt(self.pos(), "expected 'fn' after 'extern'");
            return null;
        }
        return self.parseFnDecl(true);
    }

    /// Parse function declaration: fn name(params) return_type { body }
    /// If is_extern is true, expects no body and requires semicolon.
    fn parseFnDecl(self: *Parser, is_extern: bool) ParseError!?NodeIndex {
        const start = self.pos();
        self.advance(); // consume 'fn'

        // Function name
        if (!self.check(.ident)) {
            self.err.errorWithCode(self.pos(), .e203, "expected function name");
            return null;
        }
        const name = self.tok.text;
        self.advance();

        // Parameters
        if (!self.expect(.lparen)) return null;
        const params = try self.parseFieldList(.rparen);
        if (!self.expect(.rparen)) return null;

        // Return type (optional for regular, required-ish for extern)
        var return_type: NodeIndex = null_node;
        if (!self.check(.lbrace) and !self.check(.semicolon) and !self.check(.eof)) {
            return_type = try self.parseType() orelse null_node;
        }

        // Body handling
        var body: NodeIndex = null_node;
        if (is_extern) {
            // Extern functions must not have a body, require semicolon
            if (self.check(.lbrace)) {
                self.err.errorAt(self.pos(), "extern functions cannot have a body");
                return null;
            }
            if (!self.expect(.semicolon)) return null;
        } else {
            // Regular function - body is optional (forward declaration)
            if (self.check(.lbrace)) {
                body = try self.parseBlock() orelse return null;
            }
        }

        return try self.tree.addDecl(.{ .fn_decl = .{
            .name = name,
            .params = params,
            .return_type = return_type,
            .body = body,
            .is_extern = is_extern,
            .span = Span.init(start, self.pos()),
        } });
    }

    /// Parse field list (for function params or struct fields).
    fn parseFieldList(self: *Parser, end_tok: Token) ParseError![]const ast.Field {
        var fields = std.ArrayListUnmanaged(ast.Field){};
        defer fields.deinit(self.allocator);

        while (!self.check(end_tok) and !self.check(.eof)) {
            const field_start = self.pos();

            // Field name
            if (!self.check(.ident)) break;
            const field_name = self.tok.text;
            self.advance();

            // Type
            if (!self.expect(.colon)) break;
            const type_expr = try self.parseType() orelse break;

            // Default value (optional)
            var default_value: NodeIndex = null_node;
            if (self.match(.assign)) {
                default_value = try self.parseExpr() orelse break;
            }

            try fields.append(self.allocator, .{
                .name = field_name,
                .type_expr = type_expr,
                .default_value = default_value,
                .span = Span.init(field_start, self.pos()),
            });

            if (!self.match(.comma)) break;
        }

        return try self.allocator.dupe(ast.Field, fields.items);
    }

    /// Parse variable declaration: var/const name: type = value
    fn parseVarDecl(self: *Parser, is_const: bool) ParseError!?NodeIndex {
        const start = self.pos();
        self.advance(); // consume var/const

        if (!self.check(.ident)) {
            self.err.errorWithCode(self.pos(), .e203, "expected variable name");
            return null;
        }
        const name = self.tok.text;
        self.advance();

        // Type (optional)
        var type_expr: NodeIndex = null_node;
        if (self.match(.colon)) {
            type_expr = try self.parseType() orelse null_node;
        }

        // Value (optional)
        var value: NodeIndex = null_node;
        if (self.match(.assign)) {
            value = try self.parseExpr() orelse null_node;
        }

        _ = self.match(.semicolon);

        return try self.tree.addDecl(.{ .var_decl = .{
            .name = name,
            .type_expr = type_expr,
            .value = value,
            .is_const = is_const,
            .span = Span.init(start, self.pos()),
        } });
    }

    /// Parse struct declaration: struct Name { fields }
    fn parseStructDecl(self: *Parser) ParseError!?NodeIndex {
        const start = self.pos();
        self.advance(); // consume 'struct'

        if (!self.check(.ident)) {
            self.err.errorWithCode(self.pos(), .e203, "expected struct name");
            return null;
        }
        const name = self.tok.text;
        self.advance();

        if (!self.expect(.lbrace)) return null;
        const fields = try self.parseFieldList(.rbrace);
        if (!self.expect(.rbrace)) return null;

        return try self.tree.addDecl(.{ .struct_decl = .{
            .name = name,
            .fields = fields,
            .span = Span.init(start, self.pos()),
        } });
    }

    /// Parse enum declaration: enum Name { variants } or enum Name: Type { variants }
    fn parseEnumDecl(self: *Parser) ParseError!?NodeIndex {
        const start = self.pos();
        self.advance(); // consume 'enum'

        if (!self.check(.ident)) {
            self.err.errorWithCode(self.pos(), .e203, "expected enum name");
            return null;
        }
        const name = self.tok.text;
        self.advance();

        // Optional backing type
        var backing_type: NodeIndex = null_node;
        if (self.match(.colon)) {
            backing_type = try self.parseType() orelse null_node;
        }

        if (!self.expect(.lbrace)) return null;

        var variants = std.ArrayListUnmanaged(ast.EnumVariant){};
        defer variants.deinit(self.allocator);

        while (!self.check(.rbrace) and !self.check(.eof)) {
            const var_start = self.pos();

            if (!self.check(.ident)) break;
            const var_name = self.tok.text;
            self.advance();

            // Optional explicit value
            var value: NodeIndex = null_node;
            if (self.match(.assign)) {
                value = try self.parseExpr() orelse break;
            }

            try variants.append(self.allocator, .{
                .name = var_name,
                .value = value,
                .span = Span.init(var_start, self.pos()),
            });

            if (!self.match(.comma)) break;
        }

        if (!self.expect(.rbrace)) return null;

        return try self.tree.addDecl(.{ .enum_decl = .{
            .name = name,
            .backing_type = backing_type,
            .variants = try self.allocator.dupe(ast.EnumVariant, variants.items),
            .span = Span.init(start, self.pos()),
        } });
    }

    /// Parse union declaration: union Name { variants }
    fn parseUnionDecl(self: *Parser) ParseError!?NodeIndex {
        const start = self.pos();
        self.advance(); // consume 'union'

        if (!self.check(.ident)) {
            self.err.errorWithCode(self.pos(), .e203, "expected union name");
            return null;
        }
        const name = self.tok.text;
        self.advance();

        if (!self.expect(.lbrace)) return null;

        var variants = std.ArrayListUnmanaged(ast.UnionVariant){};
        defer variants.deinit(self.allocator);

        while (!self.check(.rbrace) and !self.check(.eof)) {
            const var_start = self.pos();

            if (!self.check(.ident)) break;
            const var_name = self.tok.text;
            self.advance();

            // Optional type for payload
            var type_expr: NodeIndex = null_node;
            if (self.match(.colon)) {
                type_expr = try self.parseType() orelse break;
            }

            try variants.append(self.allocator, .{
                .name = var_name,
                .type_expr = type_expr,
                .span = Span.init(var_start, self.pos()),
            });

            if (!self.match(.comma)) break;
        }

        if (!self.expect(.rbrace)) return null;

        return try self.tree.addDecl(.{ .union_decl = .{
            .name = name,
            .variants = try self.allocator.dupe(ast.UnionVariant, variants.items),
            .span = Span.init(start, self.pos()),
        } });
    }

    /// Parse type alias: type Name = Type
    fn parseTypeAlias(self: *Parser) ParseError!?NodeIndex {
        const start = self.pos();
        self.advance(); // consume 'type'

        if (!self.check(.ident)) {
            self.err.errorWithCode(self.pos(), .e203, "expected type name");
            return null;
        }
        const name = self.tok.text;
        self.advance();

        if (!self.expect(.assign)) return null;

        const target = try self.parseType() orelse return null;

        _ = self.match(.semicolon);

        return try self.tree.addDecl(.{ .type_alias = .{
            .name = name,
            .target = target,
            .span = Span.init(start, self.pos()),
        } });
    }

    /// Parse import declaration: import "path"
    fn parseImportDecl(self: *Parser) ParseError!?NodeIndex {
        const start = self.pos();
        self.advance(); // consume 'import'

        if (!self.check(.string_lit)) {
            self.syntaxError("expected import path string");
            return null;
        }
        const raw_path = self.tok.text;
        self.advance();

        // Strip quotes from path: "math.cot" -> math.cot
        const path = if (raw_path.len >= 2 and raw_path[0] == '"' and raw_path[raw_path.len - 1] == '"')
            raw_path[1 .. raw_path.len - 1]
        else
            raw_path;

        return try self.tree.addDecl(.{ .import_decl = .{
            .path = path,
            .span = Span.init(start, self.pos()),
        } });
    }

    // ========================================================================
    // Type parsing
    // ========================================================================

    /// Parse a type expression.
    fn parseType(self: *Parser) ParseError!?NodeIndex {
        const start = self.pos();

        // Optional modifier (?, *, [])
        if (self.match(.question)) {
            // Optional type: ?T
            const inner = try self.parseType() orelse return null;
            return try self.tree.addExpr(.{ .type_expr = .{
                .kind = .{ .optional = inner },
                .span = Span.init(start, self.pos()),
            } });
        }

        if (self.match(.lnot)) {
            // Error union type: !T
            const inner = try self.parseType() orelse return null;
            return try self.tree.addExpr(.{ .type_expr = .{
                .kind = .{ .error_union = inner },
                .span = Span.init(start, self.pos()),
            } });
        }

        if (self.match(.mul)) {
            // Pointer type: *T
            const inner = try self.parseType() orelse return null;
            return try self.tree.addExpr(.{ .type_expr = .{
                .kind = .{ .pointer = inner },
                .span = Span.init(start, self.pos()),
            } });
        }

        if (self.match(.lbrack)) {
            if (self.match(.rbrack)) {
                // Slice type: []T
                const elem = try self.parseType() orelse return null;
                return try self.tree.addExpr(.{ .type_expr = .{
                    .kind = .{ .slice = elem },
                    .span = Span.init(start, self.pos()),
                } });
            } else {
                // Array type: [N]T
                const size = try self.parseExpr() orelse return null;
                if (!self.expect(.rbrack)) return null;
                const elem = try self.parseType() orelse return null;
                return try self.tree.addExpr(.{ .type_expr = .{
                    .kind = .{ .array = .{ .size = size, .elem = elem } },
                    .span = Span.init(start, self.pos()),
                } });
            }
        }

        // Named type or generic
        if (self.check(.ident) or self.tok.tok.isTypeKeyword()) {
            // For identifiers, use tok.text. For type keywords, text is empty - use tok.string()
            const type_name = if (self.tok.text.len > 0) self.tok.text else self.tok.tok.string();
            self.advance();

            // Check for generic: Map<K, V> or List<T>
            if (self.match(.lss)) {
                if (std.mem.eql(u8, type_name, "Map")) {
                    const key_type = try self.parseType() orelse return null;
                    if (!self.expect(.comma)) return null;
                    const val_type = try self.parseType() orelse return null;
                    if (!self.expect(.gtr)) return null;
                    return try self.tree.addExpr(.{ .type_expr = .{
                        .kind = .{ .map = .{ .key = key_type, .value = val_type } },
                        .span = Span.init(start, self.pos()),
                    } });
                } else if (std.mem.eql(u8, type_name, "List")) {
                    const elem_type = try self.parseType() orelse return null;
                    if (!self.expect(.gtr)) return null;
                    return try self.tree.addExpr(.{ .type_expr = .{
                        .kind = .{ .list = elem_type },
                        .span = Span.init(start, self.pos()),
                    } });
                } else {
                    self.syntaxError("unknown generic type");
                    return null;
                }
            }

            return try self.tree.addExpr(.{ .type_expr = .{
                .kind = .{ .named = type_name },
                .span = Span.init(start, self.pos()),
            } });
        }

        // Function type: fn(params) -> ret
        if (self.match(.kw_fn)) {
            if (!self.expect(.lparen)) return null;

            var params = std.ArrayListUnmanaged(NodeIndex){};
            defer params.deinit(self.allocator);

            while (!self.check(.rparen) and !self.check(.eof)) {
                const param_type = try self.parseType() orelse break;
                try params.append(self.allocator, param_type);
                if (!self.match(.comma)) break;
            }

            if (!self.expect(.rparen)) return null;

            var ret: NodeIndex = null_node;
            if (self.match(.arrow)) {
                ret = try self.parseType() orelse null_node;
            }

            return try self.tree.addExpr(.{ .type_expr = .{
                .kind = .{ .function = .{
                    .params = try self.allocator.dupe(NodeIndex, params.items),
                    .ret = ret,
                } },
                .span = Span.init(start, self.pos()),
            } });
        }

        return null;
    }

    // ========================================================================
    // Expression parsing (Pratt / precedence climbing)
    // ========================================================================

    /// Parse an expression.
    pub fn parseExpr(self: *Parser) ParseError!?NodeIndex {
        return self.parseBinaryExpr(0);
    }

    /// Parse binary expression with precedence climbing.
    fn parseBinaryExpr(self: *Parser, min_prec: u8) ParseError!?NodeIndex {
        if (!self.incNest()) return null;
        defer self.decNest();

        var left = try self.parseUnaryExpr() orelse return null;

        while (true) {
            const op = self.tok.tok;
            const prec = op.precedence();
            if (prec < min_prec or prec == 0) break;

            const op_start = self.pos();
            self.advance(); // consume operator

            const right = try self.parseBinaryExpr(prec + 1) orelse {
                self.err.errorWithCode(self.pos(), .e201, "expected expression after operator");
                return null;
            };

            const left_span = self.tree.getNode(left).?.span();
            const right_span = self.tree.getNode(right).?.span();

            left = try self.tree.addExpr(.{ .binary = .{
                .op = op,
                .left = left,
                .right = right,
                .span = Span.init(left_span.start, right_span.end),
            } });
            _ = op_start;
        }

        return left;
    }

    /// Parse unary expression.
    fn parseUnaryExpr(self: *Parser) ParseError!?NodeIndex {
        const start = self.pos();

        switch (self.tok.tok) {
            .@"and" => {
                // Address-of: &expr
                self.advance();
                const operand = try self.parseUnaryExpr() orelse return null;
                return try self.tree.addExpr(.{ .addr_of = .{
                    .operand = operand,
                    .span = Span.init(start, self.pos()),
                } });
            },
            .sub, .lnot, .not, .kw_not => {
                const op = self.tok.tok;
                self.advance();
                const operand = try self.parseUnaryExpr() orelse return null;
                return try self.tree.addExpr(.{ .unary = .{
                    .op = op,
                    .operand = operand,
                    .span = Span.init(start, self.pos()),
                } });
            },
            else => return self.parsePrimaryExpr(),
        }
    }

    /// Parse primary expression with postfix operators.
    fn parsePrimaryExpr(self: *Parser) ParseError!?NodeIndex {
        var expr = try self.parseOperand() orelse return null;

        // Parse postfix operators: .field, [index], (args), .*, .?
        while (true) {
            if (self.match(.period_star)) {
                // Dereference: expr.*
                const expr_span = self.tree.getNode(expr).?.span();
                expr = try self.tree.addExpr(.{ .deref = .{
                    .operand = expr,
                    .span = Span.init(expr_span.start, self.pos()),
                } });
            } else if (self.match(.period_question)) {
                // Optional unwrap: expr.?
                const expr_span = self.tree.getNode(expr).?.span();
                expr = try self.tree.addExpr(.{ .unary = .{
                    .op = .question,
                    .operand = expr,
                    .span = Span.init(expr_span.start, self.pos()),
                } });
            } else if (self.match(.period)) {
                // Field access or method call
                if (self.check(.ident)) {
                    // Field access: expr.field
                    const field = self.tok.text;
                    self.advance();
                    const expr_span = self.tree.getNode(expr).?.span();
                    expr = try self.tree.addExpr(.{ .field_access = .{
                        .base = expr,
                        .field = field,
                        .span = Span.init(expr_span.start, self.pos()),
                    } });
                } else {
                    self.syntaxError("expected field name after '.'");
                    return null;
                }
            } else if (self.match(.lbrack)) {
                // Index or slice
                const expr_span = self.tree.getNode(expr).?.span();

                if (self.match(.colon)) {
                    // Slice from beginning: expr[:end]
                    var slice_end: NodeIndex = null_node;
                    if (!self.check(.rbrack)) {
                        slice_end = try self.parseExpr() orelse return null;
                    }
                    if (!self.expect(.rbrack)) return null;
                    expr = try self.tree.addExpr(.{ .slice_expr = .{
                        .base = expr,
                        .start = null_node,
                        .end = slice_end,
                        .span = Span.init(expr_span.start, self.pos()),
                    } });
                } else {
                    const start_or_idx = try self.parseExpr() orelse return null;

                    if (self.match(.colon)) {
                        // Slice: expr[start:end] or expr[start:]
                        var slice_end: NodeIndex = null_node;
                        if (!self.check(.rbrack)) {
                            slice_end = try self.parseExpr() orelse return null;
                        }
                        if (!self.expect(.rbrack)) return null;
                        expr = try self.tree.addExpr(.{ .slice_expr = .{
                            .base = expr,
                            .start = start_or_idx,
                            .end = slice_end,
                            .span = Span.init(expr_span.start, self.pos()),
                        } });
                    } else {
                        // Index: expr[index]
                        if (!self.expect(.rbrack)) return null;
                        expr = try self.tree.addExpr(.{ .index = .{
                            .base = expr,
                            .idx = start_or_idx,
                            .span = Span.init(expr_span.start, self.pos()),
                        } });
                    }
                }
            } else if (self.match(.lparen)) {
                // Function call: expr(args)
                const expr_span = self.tree.getNode(expr).?.span();

                var args = std.ArrayListUnmanaged(NodeIndex){};
                defer args.deinit(self.allocator);

                while (!self.check(.rparen) and !self.check(.eof)) {
                    const arg = try self.parseExpr() orelse break;
                    try args.append(self.allocator, arg);
                    if (!self.match(.comma)) break;
                }

                if (!self.expect(.rparen)) return null;

                expr = try self.tree.addExpr(.{ .call = .{
                    .callee = expr,
                    .args = try self.allocator.dupe(NodeIndex, args.items),
                    .span = Span.init(expr_span.start, self.pos()),
                } });
            } else if (self.check(.lbrace)) {
                // Struct literal: Type{ .field = value, ... }
                // Only if base is an identifier that looks like a type name (uppercase first letter)
                // AND the content inside braces starts with '.' (field initializer)
                const node = self.tree.getNode(expr);
                if (node) |n| {
                    if (n.asExpr()) |e| {
                        if (e == .ident) {
                            const type_name = e.ident.name;

                            // Heuristic: Types start with uppercase (Cot/Go convention)
                            // Variables like 'b' start with lowercase
                            // This distinguishes Point{ ... } from b { ... }
                            // ALSO: Struct literals must have .field initializers, so peek
                            // to see if content starts with '.' - if not, it's not a struct literal
                            // (e.g., `if a == B { return 1; }` - B is const, not type)
                            if (type_name.len > 0 and std.ascii.isUpper(type_name[0]) and self.peekNextIsPeriod()) {
                                const expr_span = self.tree.getNode(expr).?.span();
                                self.advance(); // consume '{'

                                // Parse struct literal fields
                                var fields = std.ArrayListUnmanaged(ast.FieldInit){};
                                defer fields.deinit(self.allocator);

                                while (!self.check(.rbrace) and !self.check(.eof)) {
                                    // Expect .field = value
                                    if (!self.expect(.period)) return null;
                                    if (!self.check(.ident)) {
                                        self.syntaxError("expected field name after '.'");
                                        return null;
                                    }
                                    const field_name = self.tok.text;
                                    const field_start = self.pos();
                                    self.advance();

                                    if (!self.expect(.assign)) return null;

                                    const value = try self.parseExpr() orelse return null;

                                    try fields.append(self.allocator, .{
                                        .name = field_name,
                                        .value = value,
                                        .span = Span.init(field_start, self.pos()),
                                    });

                                    if (!self.match(.comma)) break;
                                }

                                if (!self.expect(.rbrace)) return null;

                                expr = try self.tree.addExpr(.{ .struct_init = .{
                                    .type_name = type_name,
                                    .fields = try self.allocator.dupe(ast.FieldInit, fields.items),
                                    .span = Span.init(expr_span.start, self.pos()),
                                } });
                                continue;
                            }
                        }
                    }
                }
                break;
            } else {
                break;
            }
        }

        return expr;
    }

    /// Parse operand (literals, identifiers, parenthesized expressions).
    fn parseOperand(self: *Parser) ParseError!?NodeIndex {
        const start = self.pos();

        switch (self.tok.tok) {
            .ident => {
                const name = self.tok.text;
                self.advance();
                return try self.tree.addExpr(.{ .ident = .{
                    .name = name,
                    .span = Span.init(start, self.pos()),
                } });
            },
            .int_lit => {
                const value = self.tok.text;
                self.advance();
                return try self.tree.addExpr(.{ .literal = .{
                    .kind = .int,
                    .value = value,
                    .span = Span.init(start, self.pos()),
                } });
            },
            .float_lit => {
                const value = self.tok.text;
                self.advance();
                return try self.tree.addExpr(.{ .literal = .{
                    .kind = .float,
                    .value = value,
                    .span = Span.init(start, self.pos()),
                } });
            },
            .string_lit => {
                const value = self.tok.text;
                self.advance();
                return try self.tree.addExpr(.{ .literal = .{
                    .kind = .string,
                    .value = value,
                    .span = Span.init(start, self.pos()),
                } });
            },
            .char_lit => {
                const value = self.tok.text;
                self.advance();
                return try self.tree.addExpr(.{ .literal = .{
                    .kind = .char,
                    .value = value,
                    .span = Span.init(start, self.pos()),
                } });
            },
            .kw_true => {
                self.advance();
                return try self.tree.addExpr(.{ .literal = .{
                    .kind = .true_lit,
                    .value = "true",
                    .span = Span.init(start, self.pos()),
                } });
            },
            .kw_false => {
                self.advance();
                return try self.tree.addExpr(.{ .literal = .{
                    .kind = .false_lit,
                    .value = "false",
                    .span = Span.init(start, self.pos()),
                } });
            },
            .kw_null => {
                self.advance();
                return try self.tree.addExpr(.{ .literal = .{
                    .kind = .null_lit,
                    .value = "null",
                    .span = Span.init(start, self.pos()),
                } });
            },
            .kw_undefined => {
                self.advance();
                return try self.tree.addExpr(.{ .literal = .{
                    .kind = .undefined_lit,
                    .value = "undefined",
                    .span = Span.init(start, self.pos()),
                } });
            },
            .lparen => {
                self.advance();
                const inner = try self.parseExpr() orelse return null;
                if (!self.expect(.rparen)) return null;
                return try self.tree.addExpr(.{ .paren = .{
                    .inner = inner,
                    .span = Span.init(start, self.pos()),
                } });
            },
            .lbrack => {
                // Array literal: [elem1, elem2, ...]
                self.advance();

                var elements = std.ArrayListUnmanaged(NodeIndex){};
                defer elements.deinit(self.allocator);

                while (!self.check(.rbrack) and !self.check(.eof)) {
                    const elem = try self.parseExpr() orelse break;
                    try elements.append(self.allocator, elem);
                    if (!self.match(.comma)) break;
                }

                if (!self.expect(.rbrack)) return null;

                return try self.tree.addExpr(.{ .array_literal = .{
                    .elements = try self.allocator.dupe(NodeIndex, elements.items),
                    .span = Span.init(start, self.pos()),
                } });
            },
            .lbrace => {
                return self.parseBlockExpr();
            },
            .kw_if => {
                return self.parseIfExpr();
            },
            .kw_switch => {
                return self.parseSwitchExpr();
            },
            .kw_new => {
                // new Type()
                self.advance();
                const type_node = try self.parseType() orelse {
                    self.err.errorWithCode(self.pos(), .e202, "expected type after 'new'");
                    return null;
                };
                if (!self.expect(.lparen)) return null;
                if (!self.expect(.rparen)) return null;
                return try self.tree.addExpr(.{ .new_expr = .{
                    .type_node = type_node,
                    .span = Span.init(start, self.pos()),
                } });
            },
            .period => {
                // Inferred variant: .variant_name
                self.advance();
                if (!self.check(.ident)) {
                    self.syntaxError("expected variant name after '.'");
                    return null;
                }
                const name = self.tok.text;
                self.advance();
                // Represent as field_access with null_node base
                return try self.tree.addExpr(.{ .field_access = .{
                    .base = null_node,
                    .field = name,
                    .span = Span.init(start, self.pos()),
                } });
            },
            .at => {
                // Builtin call: @sizeOf(Type), @alignOf(Type), @string(ptr, len), etc.
                self.advance();
                // Accept identifier OR kw_string (since "string" is a keyword)
                if (!self.check(.ident) and !self.check(.kw_string)) {
                    self.syntaxError("expected builtin name after '@'");
                    return null;
                }
                // Note: For keywords like kw_string, tok.text is "", so we need to check token type
                const is_string_builtin = self.check(.kw_string);
                const builtin_name = if (is_string_builtin) "string" else self.tok.text;
                self.advance();

                if (!self.expect(.lparen)) return null;

                // Check builtin type to determine argument parsing
                if (is_string_builtin) {
                    // @string(ptr, len) - two expression arguments
                    const ptr_arg = try self.parseExpr() orelse {
                        self.err.errorWithCode(self.pos(), .e202, "expected pointer argument");
                        return null;
                    };

                    if (!self.expect(.comma)) return null;

                    const len_arg = try self.parseExpr() orelse {
                        self.err.errorWithCode(self.pos(), .e202, "expected length argument");
                        return null;
                    };

                    if (!self.expect(.rparen)) return null;

                    return try self.tree.addExpr(.{ .builtin_call = .{
                        .name = builtin_name,
                        .type_arg = null_node,
                        .args = .{ ptr_arg, len_arg },
                        .span = Span.init(start, self.pos()),
                    } });
                } else if (std.mem.eql(u8, builtin_name, "intCast")) {
                    // @intCast(Type, value) - type argument and expression argument
                    const type_arg = try self.parseType() orelse {
                        self.err.errorWithCode(self.pos(), .e202, "expected type argument");
                        return null;
                    };

                    if (!self.expect(.comma)) return null;

                    const value_arg = try self.parseExpr() orelse {
                        self.err.errorWithCode(self.pos(), .e202, "expected value argument");
                        return null;
                    };

                    if (!self.expect(.rparen)) return null;

                    return try self.tree.addExpr(.{ .builtin_call = .{
                        .name = builtin_name,
                        .type_arg = type_arg,
                        .args = .{ value_arg, null_node },
                        .span = Span.init(start, self.pos()),
                    } });
                } else {
                    // @sizeOf(Type), @alignOf(Type) - type argument
                    const type_arg = try self.parseType() orelse {
                        self.err.errorWithCode(self.pos(), .e202, "expected type argument");
                        return null;
                    };

                    if (!self.expect(.rparen)) return null;

                    return try self.tree.addExpr(.{ .builtin_call = .{
                        .name = builtin_name,
                        .type_arg = type_arg,
                        .args = .{ null_node, null_node },
                        .span = Span.init(start, self.pos()),
                    } });
                }
            },
            else => {
                // Check for type keywords used as expressions (for builtins)
                if (self.tok.tok.isTypeKeyword()) {
                    const name = self.tok.text;
                    self.advance();
                    return try self.tree.addExpr(.{ .ident = .{
                        .name = name,
                        .span = Span.init(start, self.pos()),
                    } });
                }

                self.err.errorWithCode(self.pos(), .e201, "expected expression");
                return null;
            },
        }
    }

    /// Parse block expression: { stmts; expr }
    fn parseBlockExpr(self: *Parser) ParseError!?NodeIndex {
        const start = self.pos();
        if (!self.expect(.lbrace)) return null;

        var stmts = std.ArrayListUnmanaged(NodeIndex){};
        defer stmts.deinit(self.allocator);

        const final_expr: NodeIndex = null_node;

        while (!self.check(.rbrace) and !self.check(.eof)) {
            if (try self.parseStmt()) |stmt_idx| {
                try stmts.append(self.allocator, stmt_idx);
            } else {
                self.advance(); // Error recovery
            }
        }

        if (!self.expect(.rbrace)) return null;

        return try self.tree.addExpr(.{ .block_expr = .{
            .stmts = try self.allocator.dupe(NodeIndex, stmts.items),
            .expr = final_expr,
            .span = Span.init(start, self.pos()),
        } });
    }

    /// Parse if expression: if cond { then } else { else }
    fn parseIfExpr(self: *Parser) ParseError!?NodeIndex {
        const start = self.pos();
        self.advance(); // consume 'if'

        const condition = try self.parseExpr() orelse return null;

        if (!self.check(.lbrace)) {
            self.err.errorWithCode(self.pos(), .e204, "expected '{' after if condition");
            return null;
        }
        const then_branch = try self.parseBlockExpr() orelse return null;

        var else_branch: NodeIndex = null_node;
        if (self.match(.kw_else)) {
            if (self.check(.kw_if)) {
                else_branch = try self.parseIfExpr() orelse return null;
            } else if (self.check(.lbrace)) {
                else_branch = try self.parseBlockExpr() orelse return null;
            } else {
                self.syntaxError("expected '{' or 'if' after 'else'");
                return null;
            }
        }

        return try self.tree.addExpr(.{ .if_expr = .{
            .condition = condition,
            .then_branch = then_branch,
            .else_branch = else_branch,
            .span = Span.init(start, self.pos()),
        } });
    }

    /// Parse switch expression: switch expr { cases }
    fn parseSwitchExpr(self: *Parser) ParseError!?NodeIndex {
        const start = self.pos();
        self.advance(); // consume 'switch'

        const subject = try self.parseOperand() orelse return null;

        if (!self.expect(.lbrace)) return null;

        var cases = std.ArrayListUnmanaged(ast.SwitchCase){};
        defer cases.deinit(self.allocator);
        var else_body: NodeIndex = null_node;

        while (!self.check(.rbrace) and !self.check(.eof)) {
            const case_start = self.pos();

            if (self.match(.kw_else)) {
                if (!self.expect(.fat_arrow)) return null;
                else_body = try self.parseExpr() orelse return null;
                _ = self.match(.comma);
                continue;
            }

            // Parse case patterns
            var patterns = std.ArrayListUnmanaged(NodeIndex){};
            defer patterns.deinit(self.allocator);

            const first_pattern = try self.parsePrimaryExpr() orelse return null;
            try patterns.append(self.allocator, first_pattern);

            while (self.check(.comma) and !self.check(.fat_arrow)) {
                self.advance();
                if (self.check(.fat_arrow) or self.check(.kw_else)) break;
                const pattern = try self.parsePrimaryExpr() orelse return null;
                try patterns.append(self.allocator, pattern);
            }

            // Optional payload capture: .ok |val| =>
            var capture: []const u8 = "";
            if (self.match(.@"or")) {
                if (self.check(.ident)) {
                    capture = self.tok.text;
                    self.advance();
                } else {
                    self.syntaxError("expected identifier for payload capture");
                    return null;
                }
                if (!self.expect(.@"or")) return null;
            }

            if (!self.expect(.fat_arrow)) return null;

            const body = try self.parseExpr() orelse return null;

            try cases.append(self.allocator, .{
                .patterns = try self.allocator.dupe(NodeIndex, patterns.items),
                .capture = capture,
                .body = body,
                .span = Span.init(case_start, self.pos()),
            });

            _ = self.match(.comma);
        }

        if (!self.expect(.rbrace)) return null;

        return try self.tree.addExpr(.{ .switch_expr = .{
            .subject = subject,
            .cases = try self.allocator.dupe(ast.SwitchCase, cases.items),
            .else_body = else_body,
            .span = Span.init(start, self.pos()),
        } });
    }

    // ========================================================================
    // Statement parsing
    // ========================================================================

    /// Parse a block as statement.
    fn parseBlock(self: *Parser) ParseError!?NodeIndex {
        const start = self.pos();
        if (!self.expect(.lbrace)) return null;

        var stmts = std.ArrayListUnmanaged(NodeIndex){};
        defer stmts.deinit(self.allocator);

        while (!self.check(.rbrace) and !self.check(.eof)) {
            if (try self.parseStmt()) |stmt_idx| {
                try stmts.append(self.allocator, stmt_idx);
            } else {
                self.advance(); // Error recovery
            }
        }

        if (!self.expect(.rbrace)) return null;

        return try self.tree.addStmt(.{ .block_stmt = .{
            .stmts = try self.allocator.dupe(NodeIndex, stmts.items),
            .span = Span.init(start, self.pos()),
        } });
    }

    /// Parse a statement.
    fn parseStmt(self: *Parser) ParseError!?NodeIndex {
        const start = self.pos();

        switch (self.tok.tok) {
            .kw_return => {
                self.advance();
                var value: NodeIndex = null_node;
                if (!self.check(.rbrace) and !self.check(.semicolon) and !self.check(.eof)) {
                    value = try self.parseExpr() orelse null_node;
                }
                _ = self.match(.semicolon);
                return try self.tree.addStmt(.{ .return_stmt = .{
                    .value = value,
                    .span = Span.init(start, self.pos()),
                } });
            },
            .kw_var, .kw_let => {
                return self.parseVarStmt(false);
            },
            .kw_const => {
                return self.parseVarStmt(true);
            },
            .kw_if => {
                return self.parseIfStmt();
            },
            .kw_while => {
                return self.parseWhileStmt();
            },
            .kw_for => {
                return self.parseForStmt();
            },
            .kw_break => {
                self.advance();
                _ = self.match(.semicolon);
                return try self.tree.addStmt(.{ .break_stmt = .{
                    .span = Span.init(start, self.pos()),
                } });
            },
            .kw_continue => {
                self.advance();
                _ = self.match(.semicolon);
                return try self.tree.addStmt(.{ .continue_stmt = .{
                    .span = Span.init(start, self.pos()),
                } });
            },
            .kw_defer => {
                self.advance();
                const expr = try self.parseExpr() orelse return null;
                _ = self.match(.semicolon);
                return try self.tree.addStmt(.{ .defer_stmt = .{
                    .expr = expr,
                    .span = Span.init(start, self.pos()),
                } });
            },
            else => {
                // Expression statement or assignment
                const expr = try self.parseExpr() orelse return null;

                // Check for assignment
                if (self.tok.tok == .assign or self.tok.tok.isAssignment()) {
                    const op = self.tok.tok;
                    self.advance();
                    const value = try self.parseExpr() orelse return null;
                    _ = self.match(.semicolon);
                    return try self.tree.addStmt(.{ .assign_stmt = .{
                        .target = expr,
                        .op = op,
                        .value = value,
                        .span = Span.init(start, self.pos()),
                    } });
                }

                _ = self.match(.semicolon);
                return try self.tree.addStmt(.{ .expr_stmt = .{
                    .expr = expr,
                    .span = Span.init(start, self.pos()),
                } });
            },
        }
    }

    /// Parse local variable statement.
    fn parseVarStmt(self: *Parser, is_const: bool) ParseError!?NodeIndex {
        const start = self.pos();
        self.advance(); // consume var/let/const

        if (!self.check(.ident)) {
            self.err.errorWithCode(self.pos(), .e203, "expected variable name");
            return null;
        }
        const name = self.tok.text;
        self.advance();

        var type_expr: NodeIndex = null_node;
        if (self.match(.colon)) {
            type_expr = try self.parseType() orelse null_node;
        }

        var value: NodeIndex = null_node;
        if (self.match(.assign)) {
            value = try self.parseExpr() orelse null_node;
        }

        _ = self.match(.semicolon);

        return try self.tree.addStmt(.{ .var_stmt = .{
            .name = name,
            .type_expr = type_expr,
            .value = value,
            .is_const = is_const,
            .span = Span.init(start, self.pos()),
        } });
    }

    /// Parse if statement.
    fn parseIfStmt(self: *Parser) ParseError!?NodeIndex {
        const start = self.pos();
        self.advance(); // consume 'if'

        const condition = try self.parseExpr() orelse return null;

        const then_branch = if (self.check(.lbrace))
            try self.parseBlock() orelse return null
        else
            try self.parseStmt() orelse return null;

        var else_branch: NodeIndex = null_node;
        if (self.match(.kw_else)) {
            if (self.check(.kw_if)) {
                else_branch = try self.parseIfStmt() orelse return null;
            } else if (self.check(.lbrace)) {
                else_branch = try self.parseBlock() orelse return null;
            } else {
                else_branch = try self.parseStmt() orelse return null;
            }
        }

        return try self.tree.addStmt(.{ .if_stmt = .{
            .condition = condition,
            .then_branch = then_branch,
            .else_branch = else_branch,
            .span = Span.init(start, self.pos()),
        } });
    }

    /// Parse while statement.
    fn parseWhileStmt(self: *Parser) ParseError!?NodeIndex {
        const start = self.pos();
        self.advance(); // consume 'while'

        const condition = try self.parseExpr() orelse return null;

        if (!self.check(.lbrace)) {
            self.err.errorWithCode(self.pos(), .e204, "expected '{' after while condition");
            return null;
        }
        const body = try self.parseBlock() orelse return null;

        return try self.tree.addStmt(.{ .while_stmt = .{
            .condition = condition,
            .body = body,
            .span = Span.init(start, self.pos()),
        } });
    }

    /// Parse for statement: for x in iter { body }
    fn parseForStmt(self: *Parser) ParseError!?NodeIndex {
        const start = self.pos();
        self.advance(); // consume 'for'

        if (!self.check(.ident)) {
            self.err.errorWithCode(self.pos(), .e203, "expected loop variable");
            return null;
        }
        const binding = self.tok.text;
        self.advance();

        if (!self.expect(.kw_in)) {
            self.syntaxError("expected 'in' in for loop");
            return null;
        }

        const iterable = try self.parseExpr() orelse return null;

        if (!self.check(.lbrace)) {
            self.err.errorWithCode(self.pos(), .e204, "expected '{' after for clause");
            return null;
        }
        const body = try self.parseBlock() orelse return null;

        return try self.tree.addStmt(.{ .for_stmt = .{
            .binding = binding,
            .iterable = iterable,
            .body = body,
            .span = Span.init(start, self.pos()),
        } });
    }
};

// =========================================
// Tests
// =========================================

// Helper to create test parser with arena (parsers allocate many small slices)
fn testParse(content: []const u8) !struct { Ast, *ErrorReporter, std.heap.ArenaAllocator } {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();

    const src = try allocator.create(source.Source);
    src.* = source.Source.init(allocator, "test.cot", content);
    const err_reporter = try allocator.create(ErrorReporter);
    err_reporter.* = ErrorReporter.init(src, null);
    const scan_ptr = try allocator.create(Scanner);
    scan_ptr.* = Scanner.init(src);
    var tree = Ast.init(allocator);

    var parser = Parser.init(allocator, scan_ptr, &tree, err_reporter);
    try parser.parseFile();

    return .{ tree, err_reporter, arena };
}

test "parser simple function" {
    const tree, const err_reporter, var arena = try testParse("fn main() { return 42 }");
    defer arena.deinit();

    try std.testing.expect(tree.file != null);
    try std.testing.expectEqual(@as(usize, 1), tree.file.?.decls.len);
    try std.testing.expect(!err_reporter.hasErrors());
}

test "parser variable declaration" {
    const tree, const err_reporter, var arena = try testParse("var x: int = 42");
    defer arena.deinit();
    _ = err_reporter;

    try std.testing.expect(tree.file != null);
    try std.testing.expectEqual(@as(usize, 1), tree.file.?.decls.len);

    const node = tree.getNode(tree.file.?.decls[0]);
    try std.testing.expect(node != null);
    const decl = node.?.asDecl();
    try std.testing.expect(decl != null);
    try std.testing.expect(decl.? == .var_decl);
    try std.testing.expectEqualStrings("x", decl.?.var_decl.name);
}

test "parser binary expression precedence" {
    const tree, const err_reporter, var arena = try testParse("var x = 1 + 2 * 3");
    defer arena.deinit();

    try std.testing.expect(tree.file != null);
    try std.testing.expect(!err_reporter.hasErrors());

    // Should parse as: 1 + (2 * 3)
    const node = tree.getNode(tree.file.?.decls[0]);
    const decl = node.?.asDecl().?.var_decl;
    const value_node = tree.getNode(decl.value);
    try std.testing.expect(value_node != null);
    const expr = value_node.?.asExpr();
    try std.testing.expect(expr != null);
    try std.testing.expect(expr.? == .binary);
    try std.testing.expectEqual(Token.add, expr.?.binary.op);
}

test "parser struct declaration" {
    const tree, const err_reporter, var arena = try testParse("struct Point { x: int, y: int }");
    defer arena.deinit();

    try std.testing.expect(tree.file != null);
    try std.testing.expect(!err_reporter.hasErrors());

    const node = tree.getNode(tree.file.?.decls[0]);
    const decl = node.?.asDecl();
    try std.testing.expect(decl.? == .struct_decl);
    try std.testing.expectEqualStrings("Point", decl.?.struct_decl.name);
    try std.testing.expectEqual(@as(usize, 2), decl.?.struct_decl.fields.len);
}

test "parser enum declaration" {
    const tree, const err_reporter, var arena = try testParse("enum Color { red, green, blue }");
    defer arena.deinit();

    try std.testing.expect(tree.file != null);
    try std.testing.expect(!err_reporter.hasErrors());

    const node = tree.getNode(tree.file.?.decls[0]);
    const decl = node.?.asDecl();
    try std.testing.expect(decl.? == .enum_decl);
    try std.testing.expectEqualStrings("Color", decl.?.enum_decl.name);
    try std.testing.expectEqual(@as(usize, 3), decl.?.enum_decl.variants.len);
}

test "parser union declaration" {
    const tree, const err_reporter, var arena = try testParse("union Result { ok: int, err: string }");
    defer arena.deinit();

    try std.testing.expect(tree.file != null);
    try std.testing.expect(!err_reporter.hasErrors());

    const node = tree.getNode(tree.file.?.decls[0]);
    const decl = node.?.asDecl();
    try std.testing.expect(decl.? == .union_decl);
    try std.testing.expectEqualStrings("Result", decl.?.union_decl.name);
    try std.testing.expectEqual(@as(usize, 2), decl.?.union_decl.variants.len);
}

test "parser if statement" {
    const tree, const err_reporter, var arena = try testParse("fn test() { if x == 1 { return 1 } else { return 2 } }");
    defer arena.deinit();

    try std.testing.expect(tree.file != null);
    try std.testing.expect(!err_reporter.hasErrors());
}

test "parser while loop" {
    const tree, const err_reporter, var arena = try testParse("fn test() { var i = 0; while i < 10 { i = i + 1 } }");
    defer arena.deinit();

    try std.testing.expect(tree.file != null);
    try std.testing.expect(!err_reporter.hasErrors());
}

test "parser for loop" {
    const tree, const err_reporter, var arena = try testParse("fn test() { for x in items { print(x) } }");
    defer arena.deinit();

    try std.testing.expect(tree.file != null);
    try std.testing.expect(!err_reporter.hasErrors());
}

test "parser array literal" {
    const tree, const err_reporter, var arena = try testParse("var arr = [1, 2, 3]");
    defer arena.deinit();

    try std.testing.expect(tree.file != null);
    try std.testing.expect(!err_reporter.hasErrors());
}

test "parser error recovery" {
    const tree, const err_reporter, var arena = try testParse("fn () { }"); // missing function name
    defer arena.deinit();
    _ = tree;

    // Should have reported an error
    try std.testing.expect(err_reporter.hasErrors());
}

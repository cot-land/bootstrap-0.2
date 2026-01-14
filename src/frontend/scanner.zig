//! Lexical scanner for cot.
//!
//! Architecture modeled on Go's go/scanner package:
//! - Scanner struct with source and position state
//! - next() returns TokenInfo with token, span, text
//! - Comment handling (line and block)
//! - String interpolation support
//!
//! Derived from working bootstrap scanner.

const std = @import("std");
const token = @import("token.zig");
const source = @import("source.zig");
const errors = @import("errors.zig");

const Token = token.Token;
const Pos = source.Pos;
const Span = source.Span;
const Source = source.Source;
const ErrorReporter = errors.ErrorReporter;
const ErrorCode = errors.ErrorCode;

// =========================================
// TokenInfo - scanned token with context
// =========================================

/// A scanned token with position and text.
pub const TokenInfo = struct {
    tok: Token,
    span: Span,
    /// For identifiers and literals, the text of the token.
    /// For keywords and operators, this is empty (use tok.string()).
    text: []const u8,
};

// =========================================
// Scanner
// =========================================

/// Scanner tokenizes source code.
pub const Scanner = struct {
    src: *Source,
    pos: Pos,
    ch: ?u8,
    err: ?*ErrorReporter,
    /// Track if we're inside an interpolated string
    in_interp_string: bool,
    /// Track brace depth for nested expressions in interpolated strings
    interp_brace_depth: u32,

    /// Initialize scanner with source.
    pub fn init(src: *Source) Scanner {
        return initWithErrors(src, null);
    }

    /// Initialize scanner with source and error reporter.
    pub fn initWithErrors(src: *Source, err: ?*ErrorReporter) Scanner {
        var s = Scanner{
            .src = src,
            .pos = Pos.zero,
            .ch = null,
            .err = err,
            .in_interp_string = false,
            .interp_brace_depth = 0,
        };
        s.ch = src.at(s.pos);
        return s;
    }

    /// Report an error at position.
    fn errorAt(self: *Scanner, pos: Pos, err_code: ErrorCode, msg: []const u8) void {
        if (self.err) |reporter| {
            reporter.errorWithCode(pos, err_code, msg);
        }
    }

    /// Scan and return the next token.
    pub fn next(self: *Scanner) TokenInfo {
        self.skipWhitespaceAndComments();

        const start = self.pos;

        if (self.ch == null) {
            return .{ .tok = .eof, .span = Span.fromPos(start), .text = "" };
        }

        const c = self.ch.?;

        // Identifier or keyword
        if (isAlpha(c) or c == '_') {
            return self.scanIdentifier(start);
        }

        // Number
        if (isDigit(c)) {
            return self.scanNumber(start);
        }

        // String literal
        if (c == '"') {
            return self.scanString(start);
        }

        // Character literal
        if (c == '\'') {
            return self.scanChar(start);
        }

        // Operators and delimiters
        return self.scanOperator(start);
    }

    /// Skip whitespace and comments.
    fn skipWhitespaceAndComments(self: *Scanner) void {
        while (self.ch) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.advance();
            } else if (c == '/') {
                if (self.peek(1) == '/') {
                    self.skipLineComment();
                } else if (self.peek(1) == '*') {
                    self.skipBlockComment();
                } else {
                    break;
                }
            } else {
                break;
            }
        }
    }

    fn skipLineComment(self: *Scanner) void {
        self.advance(); // skip /
        self.advance(); // skip /
        while (self.ch) |c| {
            if (c == '\n') {
                self.advance();
                break;
            }
            self.advance();
        }
    }

    fn skipBlockComment(self: *Scanner) void {
        self.advance(); // skip /
        self.advance(); // skip *
        while (self.ch != null) {
            if (self.ch == '*' and self.peek(1) == '/') {
                self.advance();
                self.advance();
                break;
            }
            self.advance();
        }
    }

    /// Scan an identifier or keyword.
    fn scanIdentifier(self: *Scanner, start: Pos) TokenInfo {
        while (self.ch) |c| {
            if (isAlphaNumeric(c) or c == '_') {
                self.advance();
            } else {
                break;
            }
        }

        const text = self.src.content[start.offset..self.pos.offset];

        // Check if it's a keyword
        const kw = token.lookup(text);
        if (kw != .ident) {
            return .{
                .tok = kw,
                .span = Span.init(start, self.pos),
                .text = "",
            };
        }

        return .{
            .tok = .ident,
            .span = Span.init(start, self.pos),
            .text = text,
        };
    }

    /// Scan a number literal.
    fn scanNumber(self: *Scanner, start: Pos) TokenInfo {
        var is_float = false;

        // Handle hex, octal, binary
        if (self.ch == '0') {
            self.advance();
            if (self.ch) |c| {
                if (c == 'x' or c == 'X') {
                    self.advance();
                    self.scanHexDigits();
                    return self.makeNumberToken(start, false);
                } else if (c == 'o' or c == 'O') {
                    self.advance();
                    self.scanOctalDigits();
                    return self.makeNumberToken(start, false);
                } else if (c == 'b' or c == 'B') {
                    self.advance();
                    self.scanBinaryDigits();
                    return self.makeNumberToken(start, false);
                }
            }
        }

        // Decimal digits
        self.scanDecimalDigits();

        // Fractional part
        if (self.ch == '.' and self.peek(1) != '.') {
            is_float = true;
            self.advance();
            self.scanDecimalDigits();
        }

        // Exponent
        if (self.ch) |c| {
            if (c == 'e' or c == 'E') {
                is_float = true;
                self.advance();
                if (self.ch == '+' or self.ch == '-') {
                    self.advance();
                }
                self.scanDecimalDigits();
            }
        }

        return self.makeNumberToken(start, is_float);
    }

    fn makeNumberToken(self: *Scanner, start: Pos, is_float: bool) TokenInfo {
        const text = self.src.content[start.offset..self.pos.offset];
        return .{
            .tok = if (is_float) .float_lit else .int_lit,
            .span = Span.init(start, self.pos),
            .text = text,
        };
    }

    fn scanDecimalDigits(self: *Scanner) void {
        while (self.ch) |c| {
            if (isDigit(c) or c == '_') {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn scanHexDigits(self: *Scanner) void {
        while (self.ch) |c| {
            if (isHexDigit(c) or c == '_') {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn scanOctalDigits(self: *Scanner) void {
        while (self.ch) |c| {
            if ((c >= '0' and c <= '7') or c == '_') {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn scanBinaryDigits(self: *Scanner) void {
        while (self.ch) |c| {
            if (c == '0' or c == '1' or c == '_') {
                self.advance();
            } else {
                break;
            }
        }
    }

    /// Scan a string literal (may be interpolated).
    fn scanString(self: *Scanner, start: Pos) TokenInfo {
        self.advance(); // consume opening "

        var terminated = false;
        var found_interp = false;

        while (self.ch) |c| {
            if (c == '"') {
                self.advance();
                terminated = true;
                break;
            } else if (c == '\\') {
                self.advance();
                if (self.ch != null) self.advance();
            } else if (c == '$') {
                if (self.peek(1) == '{') {
                    self.advance(); // $
                    self.advance(); // {
                    found_interp = true;
                    self.in_interp_string = true;
                    self.interp_brace_depth = 1;
                    break;
                } else {
                    self.advance();
                }
            } else if (c == '\n') {
                break;
            } else {
                self.advance();
            }
        }

        if (!terminated and !found_interp) {
            self.errorAt(start, .e100, "string literal not terminated");
        }

        const text = self.src.content[start.offset..self.pos.offset];
        if (found_interp) {
            return .{ .tok = .string_interp_start, .span = Span.init(start, self.pos), .text = text };
        }
        return .{ .tok = .string_lit, .span = Span.init(start, self.pos), .text = text };
    }

    /// Continue scanning after interpolated expression.
    fn scanStringContinuation(self: *Scanner, start: Pos) TokenInfo {
        var terminated = false;
        var found_interp = false;

        while (self.ch) |c| {
            if (c == '"') {
                self.advance();
                terminated = true;
                self.in_interp_string = false;
                break;
            } else if (c == '\\') {
                self.advance();
                if (self.ch != null) self.advance();
            } else if (c == '$') {
                if (self.peek(1) == '{') {
                    self.advance();
                    self.advance();
                    found_interp = true;
                    self.interp_brace_depth = 1;
                    break;
                } else {
                    self.advance();
                }
            } else if (c == '\n') {
                break;
            } else {
                self.advance();
            }
        }

        if (!terminated and !found_interp) {
            self.errorAt(start, .e100, "string literal not terminated");
        }

        const text = self.src.content[start.offset..self.pos.offset];
        if (found_interp) {
            return .{ .tok = .string_interp_mid, .span = Span.init(start, self.pos), .text = text };
        }
        return .{ .tok = .string_interp_end, .span = Span.init(start, self.pos), .text = text };
    }

    /// Scan a character literal.
    fn scanChar(self: *Scanner, start: Pos) TokenInfo {
        self.advance(); // consume opening '

        if (self.ch == '\\') {
            self.advance();
            if (self.ch != null) self.advance();
        } else if (self.ch != null and self.ch != '\'') {
            self.advance();
        }

        var terminated = false;
        if (self.ch == '\'') {
            self.advance();
            terminated = true;
        }

        if (!terminated) {
            self.errorAt(start, .e101, "character literal not terminated");
        }

        const text = self.src.content[start.offset..self.pos.offset];
        return .{ .tok = .char_lit, .span = Span.init(start, self.pos), .text = text };
    }

    /// Scan operators and delimiters.
    fn scanOperator(self: *Scanner, start: Pos) TokenInfo {
        const c = self.ch.?;
        self.advance();

        // Handle braces in interpolated strings
        if (c == '{' and self.in_interp_string) {
            self.interp_brace_depth += 1;
            return .{ .tok = .lbrace, .span = Span.init(start, self.pos), .text = "" };
        }

        if (c == '}' and self.in_interp_string) {
            self.interp_brace_depth -= 1;
            if (self.interp_brace_depth == 0) {
                return self.scanStringContinuation(start);
            }
            return .{ .tok = .rbrace, .span = Span.init(start, self.pos), .text = "" };
        }

        const tok: Token = switch (c) {
            '(' => .lparen,
            ')' => .rparen,
            '[' => .lbrack,
            ']' => .rbrack,
            '{' => .lbrace,
            '}' => .rbrace,
            ',' => .comma,
            ';' => .semicolon,
            ':' => .colon,
            '~' => .not,
            '@' => .at,

            '+' => if (self.ch == '=') blk: {
                self.advance();
                break :blk .add_assign;
            } else .add,

            '-' => if (self.ch == '=') blk: {
                self.advance();
                break :blk .sub_assign;
            } else if (self.ch == '>') blk: {
                self.advance();
                break :blk .arrow;
            } else .sub,

            '*' => if (self.ch == '=') blk: {
                self.advance();
                break :blk .mul_assign;
            } else .mul,

            '/' => if (self.ch == '=') blk: {
                self.advance();
                break :blk .quo_assign;
            } else .quo,

            '%' => if (self.ch == '=') blk: {
                self.advance();
                break :blk .rem_assign;
            } else .rem,

            '&' => if (self.ch == '=') blk: {
                self.advance();
                break :blk .and_assign;
            } else .@"and",

            '|' => if (self.ch == '=') blk: {
                self.advance();
                break :blk .or_assign;
            } else .@"or",

            '^' => if (self.ch == '=') blk: {
                self.advance();
                break :blk .xor_assign;
            } else .xor,

            '=' => if (self.ch == '=') blk: {
                self.advance();
                break :blk .eql;
            } else if (self.ch == '>') blk: {
                self.advance();
                break :blk .fat_arrow;
            } else .assign,

            '!' => if (self.ch == '=') blk: {
                self.advance();
                break :blk .neq;
            } else .lnot,

            '<' => if (self.ch == '=') blk: {
                self.advance();
                break :blk .leq;
            } else if (self.ch == '<') blk: {
                self.advance();
                break :blk .shl;
            } else .lss,

            '>' => if (self.ch == '=') blk: {
                self.advance();
                break :blk .geq;
            } else if (self.ch == '>') blk: {
                self.advance();
                break :blk .shr;
            } else .gtr,

            '.' => if (self.ch == '*') blk: {
                self.advance();
                break :blk .period_star;
            } else if (self.ch == '?') blk: {
                self.advance();
                break :blk .period_question;
            } else .period,

            '?' => if (self.ch == '?') blk: {
                self.advance();
                break :blk .coalesce;
            } else if (self.ch == '.') blk: {
                self.advance();
                break :blk .optional_chain;
            } else .question,

            else => .illegal,
        };

        if (tok == .illegal) {
            self.errorAt(start, .e104, "unexpected character");
        }

        return .{ .tok = tok, .span = Span.init(start, self.pos), .text = "" };
    }

    /// Advance to next character.
    fn advance(self: *Scanner) void {
        self.pos = self.pos.advance(1);
        self.ch = self.src.at(self.pos);
    }

    /// Peek ahead n characters.
    fn peek(self: *Scanner, n: u32) ?u8 {
        return self.src.at(self.pos.advance(n));
    }
};

// =========================================
// Character classification
// =========================================

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isAlphaNumeric(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

// =========================================
// Tests
// =========================================

test "scanner basics" {
    const content = "fn main() { return 42 }";
    var src = Source.init(std.testing.allocator, "test.cot", content);
    defer src.deinit();

    var scanner = Scanner.init(&src);

    try std.testing.expectEqual(Token.kw_fn, scanner.next().tok);

    var tok = scanner.next();
    try std.testing.expectEqual(Token.ident, tok.tok);
    try std.testing.expectEqualStrings("main", tok.text);

    try std.testing.expectEqual(Token.lparen, scanner.next().tok);
    try std.testing.expectEqual(Token.rparen, scanner.next().tok);
    try std.testing.expectEqual(Token.lbrace, scanner.next().tok);
    try std.testing.expectEqual(Token.kw_return, scanner.next().tok);

    tok = scanner.next();
    try std.testing.expectEqual(Token.int_lit, tok.tok);
    try std.testing.expectEqualStrings("42", tok.text);

    try std.testing.expectEqual(Token.rbrace, scanner.next().tok);
    try std.testing.expectEqual(Token.eof, scanner.next().tok);
}

test "scanner operators" {
    const content = "== != <= >= << >> .* .? ?? ?.";
    var src = Source.init(std.testing.allocator, "test.cot", content);
    defer src.deinit();

    var scanner = Scanner.init(&src);

    try std.testing.expectEqual(Token.eql, scanner.next().tok);
    try std.testing.expectEqual(Token.neq, scanner.next().tok);
    try std.testing.expectEqual(Token.leq, scanner.next().tok);
    try std.testing.expectEqual(Token.geq, scanner.next().tok);
    try std.testing.expectEqual(Token.shl, scanner.next().tok);
    try std.testing.expectEqual(Token.shr, scanner.next().tok);
    try std.testing.expectEqual(Token.period_star, scanner.next().tok);
    try std.testing.expectEqual(Token.period_question, scanner.next().tok);
    try std.testing.expectEqual(Token.coalesce, scanner.next().tok);
    try std.testing.expectEqual(Token.optional_chain, scanner.next().tok);
    try std.testing.expectEqual(Token.eof, scanner.next().tok);
}

test "scanner strings" {
    const content =
        \\"hello world" "with \"escape\""
    ;
    var src = Source.init(std.testing.allocator, "test.cot", content);
    defer src.deinit();

    var scanner = Scanner.init(&src);

    var tok = scanner.next();
    try std.testing.expectEqual(Token.string_lit, tok.tok);
    try std.testing.expectEqualStrings("\"hello world\"", tok.text);

    tok = scanner.next();
    try std.testing.expectEqual(Token.string_lit, tok.tok);
}

test "scanner numbers" {
    const content = "42 3.14 0xFF 0b1010 0o777 1_000_000";
    var src = Source.init(std.testing.allocator, "test.cot", content);
    defer src.deinit();

    var scanner = Scanner.init(&src);

    var tok = scanner.next();
    try std.testing.expectEqual(Token.int_lit, tok.tok);
    try std.testing.expectEqualStrings("42", tok.text);

    tok = scanner.next();
    try std.testing.expectEqual(Token.float_lit, tok.tok);
    try std.testing.expectEqualStrings("3.14", tok.text);

    tok = scanner.next();
    try std.testing.expectEqual(Token.int_lit, tok.tok);
    try std.testing.expectEqualStrings("0xFF", tok.text);

    tok = scanner.next();
    try std.testing.expectEqual(Token.int_lit, tok.tok);
    try std.testing.expectEqualStrings("0b1010", tok.text);

    tok = scanner.next();
    try std.testing.expectEqual(Token.int_lit, tok.tok);
    try std.testing.expectEqualStrings("0o777", tok.text);

    tok = scanner.next();
    try std.testing.expectEqual(Token.int_lit, tok.tok);
    try std.testing.expectEqualStrings("1_000_000", tok.text);
}

test "scanner comments" {
    const content =
        \\// line comment
        \\x /* block */ y
    ;
    var src = Source.init(std.testing.allocator, "test.cot", content);
    defer src.deinit();

    var scanner = Scanner.init(&src);

    var tok = scanner.next();
    try std.testing.expectEqual(Token.ident, tok.tok);
    try std.testing.expectEqualStrings("x", tok.text);

    tok = scanner.next();
    try std.testing.expectEqual(Token.ident, tok.tok);
    try std.testing.expectEqualStrings("y", tok.text);

    try std.testing.expectEqual(Token.eof, scanner.next().tok);
}

test "scanner keywords" {
    const content = "fn var const if else while for return";
    var src = Source.init(std.testing.allocator, "test.cot", content);
    defer src.deinit();

    var scanner = Scanner.init(&src);

    try std.testing.expectEqual(Token.kw_fn, scanner.next().tok);
    try std.testing.expectEqual(Token.kw_var, scanner.next().tok);
    try std.testing.expectEqual(Token.kw_const, scanner.next().tok);
    try std.testing.expectEqual(Token.kw_if, scanner.next().tok);
    try std.testing.expectEqual(Token.kw_else, scanner.next().tok);
    try std.testing.expectEqual(Token.kw_while, scanner.next().tok);
    try std.testing.expectEqual(Token.kw_for, scanner.next().tok);
    try std.testing.expectEqual(Token.kw_return, scanner.next().tok);
}

test "scanner type keywords" {
    const content = "int float bool string i64 u8";
    var src = Source.init(std.testing.allocator, "test.cot", content);
    defer src.deinit();

    var scanner = Scanner.init(&src);

    try std.testing.expectEqual(Token.kw_int, scanner.next().tok);
    try std.testing.expectEqual(Token.kw_float, scanner.next().tok);
    try std.testing.expectEqual(Token.kw_bool, scanner.next().tok);
    try std.testing.expectEqual(Token.kw_string, scanner.next().tok);
    try std.testing.expectEqual(Token.kw_i64, scanner.next().tok);
    try std.testing.expectEqual(Token.kw_u8, scanner.next().tok);
}

test "scanner character literals" {
    const content = "'a' '\\n' '\\\\'";
    var src = Source.init(std.testing.allocator, "test.cot", content);
    defer src.deinit();

    var scanner = Scanner.init(&src);

    var tok = scanner.next();
    try std.testing.expectEqual(Token.char_lit, tok.tok);
    try std.testing.expectEqualStrings("'a'", tok.text);

    tok = scanner.next();
    try std.testing.expectEqual(Token.char_lit, tok.tok);

    tok = scanner.next();
    try std.testing.expectEqual(Token.char_lit, tok.tok);
}

test "scanner compound assignment" {
    const content = "+= -= *= /= %= &= |= ^=";
    var src = Source.init(std.testing.allocator, "test.cot", content);
    defer src.deinit();

    var scanner = Scanner.init(&src);

    try std.testing.expectEqual(Token.add_assign, scanner.next().tok);
    try std.testing.expectEqual(Token.sub_assign, scanner.next().tok);
    try std.testing.expectEqual(Token.mul_assign, scanner.next().tok);
    try std.testing.expectEqual(Token.quo_assign, scanner.next().tok);
    try std.testing.expectEqual(Token.rem_assign, scanner.next().tok);
    try std.testing.expectEqual(Token.and_assign, scanner.next().tok);
    try std.testing.expectEqual(Token.or_assign, scanner.next().tok);
    try std.testing.expectEqual(Token.xor_assign, scanner.next().tok);
}

test "scanner arrows" {
    const content = "-> =>";
    var src = Source.init(std.testing.allocator, "test.cot", content);
    defer src.deinit();

    var scanner = Scanner.init(&src);

    try std.testing.expectEqual(Token.arrow, scanner.next().tok);
    try std.testing.expectEqual(Token.fat_arrow, scanner.next().tok);
}

//! Token definitions for cot.
//!
//! Architecture modeled on Go's go/token package:
//! - Token as enum with defined ranges for predicates
//! - Precedence method on token type
//! - Keyword lookup via compile-time string map
//!
//! Token set derived from working bootstrap compiler.

const std = @import("std");

/// Token represents a lexical token in the cot language.
pub const Token = enum(u8) {
    // =========================================
    // Special tokens
    // =========================================
    illegal,
    eof,
    comment,

    // =========================================
    // Literals (literal_beg..literal_end)
    // =========================================
    literal_beg,
    ident,
    int_lit,
    float_lit,
    string_lit,
    string_interp_start, // "text ${
    string_interp_mid, // } text ${
    string_interp_end, // } text"
    char_lit,
    literal_end,

    // =========================================
    // Operators and delimiters (operator_beg..operator_end)
    // =========================================
    operator_beg,

    // Arithmetic
    add, // +
    sub, // -
    mul, // *
    quo, // /
    rem, // %

    // Bitwise
    @"and", // &
    @"or", // |
    xor, // ^
    shl, // <<
    shr, // >>
    not, // ~

    // Compound assignment
    add_assign, // +=
    sub_assign, // -=
    mul_assign, // *=
    quo_assign, // /=
    rem_assign, // %=
    and_assign, // &=
    or_assign, // |=
    xor_assign, // ^=

    // Comparison
    eql, // ==
    neq, // !=
    lss, // <
    leq, // <=
    gtr, // >
    geq, // >=

    // Logical
    land, // and (keyword)
    lor, // or (keyword)
    lnot, // ! or not

    // Assignment and special
    assign, // =
    arrow, // ->
    fat_arrow, // =>
    coalesce, // ??
    optional_chain, // ?.

    // Punctuation
    lparen, // (
    rparen, // )
    lbrack, // [
    rbrack, // ]
    lbrace, // {
    rbrace, // }
    comma, // ,
    period, // .
    period_star, // .*
    period_question, // .?
    semicolon, // ;
    colon, // :
    at, // @
    question, // ?

    operator_end,

    // =========================================
    // Keywords (keyword_beg..keyword_end)
    // =========================================
    keyword_beg,

    // Declarations
    kw_fn,
    kw_var,
    kw_let,
    kw_const,
    kw_struct,
    kw_impl,
    kw_enum,
    kw_union,
    kw_type,
    kw_import,
    kw_extern,

    // Control flow
    kw_if,
    kw_else,
    kw_switch,
    kw_while,
    kw_for,
    kw_in,
    kw_return,
    kw_break,
    kw_continue,
    kw_defer,

    // Literals
    kw_true,
    kw_false,
    kw_null,
    kw_new,
    kw_undefined,

    // Logical operators as keywords
    kw_and,
    kw_or,
    kw_not,

    // Built-in types
    kw_int,
    kw_float,
    kw_bool,
    kw_string,
    kw_byte,
    kw_void,

    // Sized types
    kw_i8,
    kw_i16,
    kw_i32,
    kw_i64,
    kw_u8,
    kw_u16,
    kw_u32,
    kw_u64,
    kw_f32,
    kw_f64,

    keyword_end,

    // =========================================
    // Methods
    // =========================================

    /// Returns string representation of token.
    pub fn string(self: Token) []const u8 {
        return token_strings[@intFromEnum(self)];
    }

    /// Returns operator precedence (0 = non-operator).
    /// Higher values bind tighter.
    pub fn precedence(self: Token) u8 {
        return switch (self) {
            .coalesce => 1, // ?? (lowest binary)
            .lor, .kw_or => 2,
            .land, .kw_and => 3,
            .eql, .neq, .lss, .leq, .gtr, .geq => 4,
            .add, .sub, .@"or", .xor => 5,
            .mul, .quo, .rem, .@"and", .shl, .shr => 6,
            else => 0,
        };
    }

    /// Returns true for literal tokens (ident, int_lit, etc.)
    pub fn isLiteral(self: Token) bool {
        const v = @intFromEnum(self);
        return v > @intFromEnum(Token.literal_beg) and v < @intFromEnum(Token.literal_end);
    }

    /// Returns true for operator/delimiter tokens.
    pub fn isOperator(self: Token) bool {
        const v = @intFromEnum(self);
        return v > @intFromEnum(Token.operator_beg) and v < @intFromEnum(Token.operator_end);
    }

    /// Returns true for keyword tokens.
    pub fn isKeyword(self: Token) bool {
        const v = @intFromEnum(self);
        return v > @intFromEnum(Token.keyword_beg) and v < @intFromEnum(Token.keyword_end);
    }

    /// Returns true for type keywords (int, string, i64, etc.)
    pub fn isTypeKeyword(self: Token) bool {
        return switch (self) {
            .kw_int, .kw_float, .kw_bool, .kw_string, .kw_byte, .kw_void,
            .kw_i8, .kw_i16, .kw_i32, .kw_i64,
            .kw_u8, .kw_u16, .kw_u32, .kw_u64,
            .kw_f32, .kw_f64,
            => true,
            else => false,
        };
    }

    /// Returns true for assignment operators (=, +=, -=, etc.)
    pub fn isAssignment(self: Token) bool {
        return switch (self) {
            .assign, .add_assign, .sub_assign, .mul_assign, .quo_assign,
            .rem_assign, .and_assign, .or_assign, .xor_assign,
            => true,
            else => false,
        };
    }
};

/// Token string representations.
const token_strings = blk: {
    var strings: [std.meta.fields(Token).len][]const u8 = undefined;
    for (std.meta.fields(Token)) |field| {
        strings[field.value] = field.name;
    }
    // Override with readable strings
    strings[@intFromEnum(Token.illegal)] = "ILLEGAL";
    strings[@intFromEnum(Token.eof)] = "EOF";
    strings[@intFromEnum(Token.comment)] = "COMMENT";
    strings[@intFromEnum(Token.ident)] = "IDENT";
    strings[@intFromEnum(Token.int_lit)] = "INT";
    strings[@intFromEnum(Token.float_lit)] = "FLOAT";
    strings[@intFromEnum(Token.string_lit)] = "STRING";
    strings[@intFromEnum(Token.char_lit)] = "CHAR";
    strings[@intFromEnum(Token.add)] = "+";
    strings[@intFromEnum(Token.sub)] = "-";
    strings[@intFromEnum(Token.mul)] = "*";
    strings[@intFromEnum(Token.quo)] = "/";
    strings[@intFromEnum(Token.rem)] = "%";
    strings[@intFromEnum(Token.@"and")] = "&";
    strings[@intFromEnum(Token.@"or")] = "|";
    strings[@intFromEnum(Token.xor)] = "^";
    strings[@intFromEnum(Token.shl)] = "<<";
    strings[@intFromEnum(Token.shr)] = ">>";
    strings[@intFromEnum(Token.not)] = "~";
    strings[@intFromEnum(Token.add_assign)] = "+=";
    strings[@intFromEnum(Token.sub_assign)] = "-=";
    strings[@intFromEnum(Token.mul_assign)] = "*=";
    strings[@intFromEnum(Token.quo_assign)] = "/=";
    strings[@intFromEnum(Token.rem_assign)] = "%=";
    strings[@intFromEnum(Token.and_assign)] = "&=";
    strings[@intFromEnum(Token.or_assign)] = "|=";
    strings[@intFromEnum(Token.xor_assign)] = "^=";
    strings[@intFromEnum(Token.eql)] = "==";
    strings[@intFromEnum(Token.neq)] = "!=";
    strings[@intFromEnum(Token.lss)] = "<";
    strings[@intFromEnum(Token.leq)] = "<=";
    strings[@intFromEnum(Token.gtr)] = ">";
    strings[@intFromEnum(Token.geq)] = ">=";
    strings[@intFromEnum(Token.land)] = "&&";
    strings[@intFromEnum(Token.lor)] = "||";
    strings[@intFromEnum(Token.lnot)] = "!";
    strings[@intFromEnum(Token.assign)] = "=";
    strings[@intFromEnum(Token.arrow)] = "->";
    strings[@intFromEnum(Token.fat_arrow)] = "=>";
    strings[@intFromEnum(Token.coalesce)] = "??";
    strings[@intFromEnum(Token.optional_chain)] = "?.";
    strings[@intFromEnum(Token.lparen)] = "(";
    strings[@intFromEnum(Token.rparen)] = ")";
    strings[@intFromEnum(Token.lbrack)] = "[";
    strings[@intFromEnum(Token.rbrack)] = "]";
    strings[@intFromEnum(Token.lbrace)] = "{";
    strings[@intFromEnum(Token.rbrace)] = "}";
    strings[@intFromEnum(Token.comma)] = ",";
    strings[@intFromEnum(Token.period)] = ".";
    strings[@intFromEnum(Token.period_star)] = ".*";
    strings[@intFromEnum(Token.period_question)] = ".?";
    strings[@intFromEnum(Token.semicolon)] = ";";
    strings[@intFromEnum(Token.colon)] = ":";
    strings[@intFromEnum(Token.at)] = "@";
    strings[@intFromEnum(Token.question)] = "?";
    strings[@intFromEnum(Token.kw_fn)] = "fn";
    strings[@intFromEnum(Token.kw_var)] = "var";
    strings[@intFromEnum(Token.kw_let)] = "let";
    strings[@intFromEnum(Token.kw_const)] = "const";
    strings[@intFromEnum(Token.kw_struct)] = "struct";
    strings[@intFromEnum(Token.kw_impl)] = "impl";
    strings[@intFromEnum(Token.kw_enum)] = "enum";
    strings[@intFromEnum(Token.kw_union)] = "union";
    strings[@intFromEnum(Token.kw_type)] = "type";
    strings[@intFromEnum(Token.kw_import)] = "import";
    strings[@intFromEnum(Token.kw_extern)] = "extern";
    strings[@intFromEnum(Token.kw_if)] = "if";
    strings[@intFromEnum(Token.kw_else)] = "else";
    strings[@intFromEnum(Token.kw_switch)] = "switch";
    strings[@intFromEnum(Token.kw_while)] = "while";
    strings[@intFromEnum(Token.kw_for)] = "for";
    strings[@intFromEnum(Token.kw_in)] = "in";
    strings[@intFromEnum(Token.kw_return)] = "return";
    strings[@intFromEnum(Token.kw_break)] = "break";
    strings[@intFromEnum(Token.kw_continue)] = "continue";
    strings[@intFromEnum(Token.kw_defer)] = "defer";
    strings[@intFromEnum(Token.kw_true)] = "true";
    strings[@intFromEnum(Token.kw_false)] = "false";
    strings[@intFromEnum(Token.kw_null)] = "null";
    strings[@intFromEnum(Token.kw_new)] = "new";
    strings[@intFromEnum(Token.kw_undefined)] = "undefined";
    strings[@intFromEnum(Token.kw_and)] = "and";
    strings[@intFromEnum(Token.kw_or)] = "or";
    strings[@intFromEnum(Token.kw_not)] = "not";
    strings[@intFromEnum(Token.kw_int)] = "int";
    strings[@intFromEnum(Token.kw_float)] = "float";
    strings[@intFromEnum(Token.kw_bool)] = "bool";
    strings[@intFromEnum(Token.kw_string)] = "string";
    strings[@intFromEnum(Token.kw_byte)] = "byte";
    strings[@intFromEnum(Token.kw_void)] = "void";
    strings[@intFromEnum(Token.kw_i8)] = "i8";
    strings[@intFromEnum(Token.kw_i16)] = "i16";
    strings[@intFromEnum(Token.kw_i32)] = "i32";
    strings[@intFromEnum(Token.kw_i64)] = "i64";
    strings[@intFromEnum(Token.kw_u8)] = "u8";
    strings[@intFromEnum(Token.kw_u16)] = "u16";
    strings[@intFromEnum(Token.kw_u32)] = "u32";
    strings[@intFromEnum(Token.kw_u64)] = "u64";
    strings[@intFromEnum(Token.kw_f32)] = "f32";
    strings[@intFromEnum(Token.kw_f64)] = "f64";
    break :blk strings;
};

/// Keyword lookup table.
pub const keywords = std.StaticStringMap(Token).initComptime(.{
    .{ "fn", .kw_fn },
    .{ "var", .kw_var },
    .{ "let", .kw_let },
    .{ "const", .kw_const },
    .{ "struct", .kw_struct },
    .{ "impl", .kw_impl },
    .{ "enum", .kw_enum },
    .{ "union", .kw_union },
    .{ "type", .kw_type },
    .{ "import", .kw_import },
    .{ "extern", .kw_extern },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "switch", .kw_switch },
    .{ "while", .kw_while },
    .{ "for", .kw_for },
    .{ "in", .kw_in },
    .{ "return", .kw_return },
    .{ "break", .kw_break },
    .{ "continue", .kw_continue },
    .{ "defer", .kw_defer },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "null", .kw_null },
    .{ "new", .kw_new },
    .{ "undefined", .kw_undefined },
    .{ "and", .kw_and },
    .{ "or", .kw_or },
    .{ "not", .kw_not },
    .{ "int", .kw_int },
    .{ "float", .kw_float },
    .{ "bool", .kw_bool },
    .{ "string", .kw_string },
    .{ "byte", .kw_byte },
    .{ "void", .kw_void },
    .{ "i8", .kw_i8 },
    .{ "i16", .kw_i16 },
    .{ "i32", .kw_i32 },
    .{ "i64", .kw_i64 },
    .{ "u8", .kw_u8 },
    .{ "u16", .kw_u16 },
    .{ "u32", .kw_u32 },
    .{ "u64", .kw_u64 },
    .{ "f32", .kw_f32 },
    .{ "f64", .kw_f64 },
});

/// Lookup maps an identifier to its keyword token or .ident.
pub fn lookup(name: []const u8) Token {
    return keywords.get(name) orelse .ident;
}

// =========================================
// Tests
// =========================================

test "token string" {
    try std.testing.expectEqualStrings("+", Token.add.string());
    try std.testing.expectEqualStrings("fn", Token.kw_fn.string());
    try std.testing.expectEqualStrings("==", Token.eql.string());
    try std.testing.expectEqualStrings("EOF", Token.eof.string());
}

test "keyword lookup" {
    try std.testing.expectEqual(Token.kw_fn, lookup("fn"));
    try std.testing.expectEqual(Token.kw_var, lookup("var"));
    try std.testing.expectEqual(Token.kw_and, lookup("and"));
    try std.testing.expectEqual(Token.kw_i64, lookup("i64"));
    try std.testing.expectEqual(Token.ident, lookup("notakeyword"));
    try std.testing.expectEqual(Token.ident, lookup("main"));
}

test "precedence" {
    try std.testing.expectEqual(@as(u8, 6), Token.mul.precedence());
    try std.testing.expectEqual(@as(u8, 5), Token.add.precedence());
    try std.testing.expectEqual(@as(u8, 4), Token.eql.precedence());
    try std.testing.expectEqual(@as(u8, 3), Token.kw_and.precedence());
    try std.testing.expectEqual(@as(u8, 2), Token.kw_or.precedence());
    try std.testing.expectEqual(@as(u8, 1), Token.coalesce.precedence());
    try std.testing.expectEqual(@as(u8, 0), Token.lparen.precedence());
}

test "isLiteral" {
    try std.testing.expect(Token.ident.isLiteral());
    try std.testing.expect(Token.int_lit.isLiteral());
    try std.testing.expect(Token.string_lit.isLiteral());
    try std.testing.expect(!Token.add.isLiteral());
    try std.testing.expect(!Token.kw_fn.isLiteral());
}

test "isOperator" {
    try std.testing.expect(Token.add.isOperator());
    try std.testing.expect(Token.eql.isOperator());
    try std.testing.expect(Token.lparen.isOperator());
    try std.testing.expect(!Token.ident.isOperator());
    try std.testing.expect(!Token.kw_fn.isOperator());
}

test "isKeyword" {
    try std.testing.expect(Token.kw_fn.isKeyword());
    try std.testing.expect(Token.kw_and.isKeyword());
    try std.testing.expect(Token.kw_i64.isKeyword());
    try std.testing.expect(!Token.add.isKeyword());
    try std.testing.expect(!Token.ident.isKeyword());
}

test "isTypeKeyword" {
    try std.testing.expect(Token.kw_int.isTypeKeyword());
    try std.testing.expect(Token.kw_i64.isTypeKeyword());
    try std.testing.expect(Token.kw_string.isTypeKeyword());
    try std.testing.expect(!Token.kw_fn.isTypeKeyword());
    try std.testing.expect(!Token.kw_if.isTypeKeyword());
}

test "isAssignment" {
    try std.testing.expect(Token.assign.isAssignment());
    try std.testing.expect(Token.add_assign.isAssignment());
    try std.testing.expect(!Token.add.isAssignment());
    try std.testing.expect(!Token.eql.isAssignment());
}

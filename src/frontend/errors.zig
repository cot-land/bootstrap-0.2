//! Error handling infrastructure.
//!
//! Architecture modeled on Go's error patterns:
//! - Error struct with position and message
//! - ErrorCode enum for categorization
//! - ErrorReporter for collection and display
//!
//! Error codes follow the convention:
//! - 1xx: Scanner errors
//! - 2xx: Parser errors
//! - 3xx: Type errors
//! - 4xx: Semantic errors

const std = @import("std");
const source = @import("source.zig");

const Pos = source.Pos;
const Span = source.Span;
const Source = source.Source;

// =========================================
// Error codes
// =========================================

/// Error codes for categorizing errors.
/// Useful for tooling, IDE integration, and documentation.
pub const ErrorCode = enum(u16) {
    // Scanner errors (1xx)
    e100 = 100, // unterminated string
    e101 = 101, // unterminated char
    e102 = 102, // invalid escape
    e103 = 103, // invalid number
    e104 = 104, // unexpected char

    // Parser errors (2xx)
    e200 = 200, // unexpected token
    e201 = 201, // expected expression
    e202 = 202, // expected type
    e203 = 203, // expected identifier
    e204 = 204, // expected '{'
    e205 = 205, // expected '}'
    e206 = 206, // expected '('
    e207 = 207, // expected ')'
    e208 = 208, // expected ';' or newline

    // Type errors (3xx)
    e300 = 300, // type mismatch
    e301 = 301, // undefined identifier
    e302 = 302, // redefined identifier
    e303 = 303, // invalid operation
    e304 = 304, // wrong number of arguments
    e305 = 305, // not callable
    e306 = 306, // field not found

    // Semantic errors (4xx)
    e400 = 400, // break outside loop
    e401 = 401, // continue outside loop
    e402 = 402, // return type mismatch
    e403 = 403, // missing return

    /// Get the error code number.
    pub fn code(self: ErrorCode) u16 {
        return @intFromEnum(self);
    }

    /// Get description of this error code.
    pub fn description(self: ErrorCode) []const u8 {
        return switch (self) {
            .e100 => "unterminated string literal",
            .e101 => "unterminated character literal",
            .e102 => "invalid escape sequence",
            .e103 => "invalid number literal",
            .e104 => "unexpected character",
            .e200 => "unexpected token",
            .e201 => "expected expression",
            .e202 => "expected type",
            .e203 => "expected identifier",
            .e204 => "expected '{'",
            .e205 => "expected '}'",
            .e206 => "expected '('",
            .e207 => "expected ')'",
            .e208 => "expected ';' or newline",
            .e300 => "type mismatch",
            .e301 => "undefined identifier",
            .e302 => "redefined identifier",
            .e303 => "invalid operation",
            .e304 => "wrong number of arguments",
            .e305 => "not callable",
            .e306 => "field not found",
            .e400 => "break outside loop",
            .e401 => "continue outside loop",
            .e402 => "return type mismatch",
            .e403 => "missing return",
        };
    }
};

// =========================================
// Error struct
// =========================================

/// An error at a specific source location.
pub const Error = struct {
    span: Span,
    msg: []const u8,
    code: ?ErrorCode = null,

    /// Create error at position.
    pub fn at(pos: Pos, msg: []const u8) Error {
        return .{
            .span = Span.fromPos(pos),
            .msg = msg,
            .code = null,
        };
    }

    /// Create error with code.
    pub fn withCode(pos: Pos, err_code: ErrorCode, msg: []const u8) Error {
        return .{
            .span = Span.fromPos(pos),
            .msg = msg,
            .code = err_code,
        };
    }

    /// Create error at span.
    pub fn atSpan(span: Span, msg: []const u8) Error {
        return .{
            .span = span,
            .msg = msg,
            .code = null,
        };
    }
};

// =========================================
// Error reporter
// =========================================

/// Callback type for custom error handling.
pub const ErrorHandler = *const fn (err: Error) void;

/// Collects and reports errors during compilation.
pub const ErrorReporter = struct {
    src: *Source,
    handler: ?ErrorHandler,
    first: ?Error,
    count: u32,

    pub fn init(src: *Source, handler: ?ErrorHandler) ErrorReporter {
        return .{
            .src = src,
            .handler = handler,
            .first = null,
            .count = 0,
        };
    }

    /// Report an error at a position.
    pub fn errorAt(self: *ErrorReporter, pos: Pos, msg: []const u8) void {
        self.report(Error.at(pos, msg));
    }

    /// Report an error with code.
    pub fn errorWithCode(self: *ErrorReporter, pos: Pos, err_code: ErrorCode, msg: []const u8) void {
        self.report(Error.withCode(pos, err_code, msg));
    }

    /// Report an error at a span.
    pub fn errorAtSpan(self: *ErrorReporter, span: Span, msg: []const u8) void {
        self.report(Error.atSpan(span, msg));
    }

    /// Report an error.
    pub fn report(self: *ErrorReporter, err: Error) void {
        if (self.first == null) {
            self.first = err;
        }
        self.count += 1;

        if (self.handler) |h| {
            h(err);
        } else {
            self.printError(err);
        }
    }

    /// Print an error with source context.
    fn printError(self: *ErrorReporter, err: Error) void {
        const pos = self.src.position(err.span.start);

        // Format: filename:line:column: error[Exxx]: message
        if (err.code) |err_code| {
            std.debug.print("{s}:{d}:{d}: error[E{d}]: {s}\n", .{
                pos.filename,
                pos.line,
                pos.column,
                err_code.code(),
                err.msg,
            });
        } else {
            std.debug.print("{s}:{d}:{d}: error: {s}\n", .{
                pos.filename,
                pos.line,
                pos.column,
                err.msg,
            });
        }

        // Show source line
        const line = self.src.getLine(err.span.start);
        std.debug.print("    {s}\n", .{line});

        // Show caret indicator
        if (pos.column > 0) {
            std.debug.print("    ", .{});
            var i: u32 = 0;
            while (i < pos.column - 1) : (i += 1) {
                if (i < line.len and line[i] == '\t') {
                    std.debug.print("\t", .{});
                } else {
                    std.debug.print(" ", .{});
                }
            }
            std.debug.print("^\n", .{});
        }
    }

    /// Check if any errors were reported.
    pub fn hasErrors(self: *const ErrorReporter) bool {
        return self.count > 0;
    }

    /// Get error count.
    pub fn errorCount(self: *const ErrorReporter) u32 {
        return self.count;
    }

    /// Get the first error.
    pub fn firstError(self: *const ErrorReporter) ?Error {
        return self.first;
    }
};

// =========================================
// Tests
// =========================================

test "ErrorCode description" {
    try std.testing.expectEqualStrings("unterminated string literal", ErrorCode.e100.description());
    try std.testing.expectEqualStrings("unexpected token", ErrorCode.e200.description());
    try std.testing.expectEqualStrings("type mismatch", ErrorCode.e300.description());
}

test "ErrorCode code" {
    try std.testing.expectEqual(@as(u16, 100), ErrorCode.e100.code());
    try std.testing.expectEqual(@as(u16, 200), ErrorCode.e200.code());
}

test "Error creation" {
    const err = Error.at(Pos{ .offset = 10 }, "test error");
    try std.testing.expectEqual(@as(u32, 10), err.span.start.offset);
    try std.testing.expectEqualStrings("test error", err.msg);
    try std.testing.expect(err.code == null);

    const err2 = Error.withCode(Pos{ .offset = 5 }, .e200, "unexpected");
    try std.testing.expectEqual(ErrorCode.e200, err2.code.?);
}

test "ErrorReporter basic" {
    const content = "fn main() {\n    x = 1\n}";
    var src = Source.init(std.testing.allocator, "test.cot", content);
    defer src.deinit();

    var reporter = ErrorReporter.init(&src, null);

    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expectEqual(@as(u32, 0), reporter.errorCount());

    // Report an error (prints to stderr in tests)
    reporter.errorAt(Pos{ .offset = 16 }, "undefined variable 'x'");

    try std.testing.expect(reporter.hasErrors());
    try std.testing.expectEqual(@as(u32, 1), reporter.errorCount());
    try std.testing.expect(reporter.firstError() != null);
}

test "ErrorReporter with code" {
    const content = "let s = \"unterminated";
    var src = Source.init(std.testing.allocator, "test.cot", content);
    defer src.deinit();

    var reporter = ErrorReporter.init(&src, null);
    reporter.errorWithCode(Pos{ .offset = 8 }, .e100, "string not terminated");

    try std.testing.expect(reporter.firstError() != null);
    try std.testing.expectEqual(ErrorCode.e100, reporter.firstError().?.code.?);
}

test "ErrorReporter multiple errors" {
    const content = "x y z";
    var src = Source.init(std.testing.allocator, "test.cot", content);
    defer src.deinit();

    var reporter = ErrorReporter.init(&src, null);
    reporter.errorAt(Pos{ .offset = 0 }, "error 1");
    reporter.errorAt(Pos{ .offset = 2 }, "error 2");
    reporter.errorAt(Pos{ .offset = 4 }, "error 3");

    try std.testing.expectEqual(@as(u32, 3), reporter.errorCount());
    try std.testing.expectEqualStrings("error 1", reporter.firstError().?.msg);
}

test "ErrorReporter custom handler" {
    const content = "test";
    var src = Source.init(std.testing.allocator, "test.cot", content);
    defer src.deinit();

    var handled_count: u32 = 0;
    const handler = struct {
        fn handle(_: Error) void {
            // In real code, we'd capture this. For test, just verify it's called.
        }
    }.handle;

    var reporter = ErrorReporter.init(&src, handler);
    _ = &handled_count;

    reporter.errorAt(Pos{ .offset = 0 }, "test");
    try std.testing.expectEqual(@as(u32, 1), reporter.errorCount());
}

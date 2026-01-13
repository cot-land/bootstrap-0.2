//! Compilation error types with context.
//!
//! Go reference: [errors package] error wrapping patterns
//!
//! Provides structured errors that include context for debugging:
//! - Error kind (what went wrong)
//! - Context string (where/why)
//! - Optional block/value IDs
//! - Source position
//!
//! ## Related Modules
//!
//! - [compile.zig] - Uses CompileError for pass failures
//! - [debug.zig] - Uses VerifyError for invariant violations
//!
//! ## Example
//!
//! ```zig
//! return CompileError.init(
//!     .use_count_mismatch,
//!     "during dead code elimination",
//! ).withValue(v.id).withBlock(b.id);
//! ```

const std = @import("std");
const types = @import("types.zig");

const ID = types.ID;
const Pos = types.Pos;

/// Compilation error with context.
///
/// Provides rich error information following Go's error wrapping pattern.
/// Use the builder methods to add context incrementally.
pub const CompileError = struct {
    /// What kind of error occurred
    kind: ErrorKind,

    /// Human-readable context explaining the error
    context: []const u8,

    /// Block where error occurred (if applicable)
    block_id: ?ID = null,

    /// Value where error occurred (if applicable)
    value_id: ?ID = null,

    /// Source position (if available)
    source_pos: ?Pos = null,

    /// Pass name where error occurred (if applicable)
    pass_name: ?[]const u8 = null,

    pub const ErrorKind = enum {
        // SSA structure errors
        invalid_block_id,
        invalid_value_id,
        edge_invariant_violated,
        use_count_mismatch,
        block_membership_error,

        // Type errors
        type_mismatch,
        invalid_type,

        // Pass errors
        pass_failed,
        pass_not_found,
        dependency_not_satisfied,

        // Resource errors
        out_of_memory,
        allocation_failed,

        // Codegen errors
        invalid_instruction,
        register_allocation_failed,
        unsupported_operation,
    };

    /// Create a new error with kind and context.
    pub fn init(kind: ErrorKind, context: []const u8) CompileError {
        return .{
            .kind = kind,
            .context = context,
        };
    }

    /// Add block context to error (builder pattern).
    pub fn withBlock(self: CompileError, block_id: ID) CompileError {
        var e = self;
        e.block_id = block_id;
        return e;
    }

    /// Add value context to error (builder pattern).
    pub fn withValue(self: CompileError, value_id: ID) CompileError {
        var e = self;
        e.value_id = value_id;
        return e;
    }

    /// Add source position to error (builder pattern).
    pub fn withPos(self: CompileError, pos: Pos) CompileError {
        var e = self;
        e.source_pos = pos;
        return e;
    }

    /// Add pass name to error (builder pattern).
    pub fn withPass(self: CompileError, pass_name: []const u8) CompileError {
        var e = self;
        e.pass_name = pass_name;
        return e;
    }

    /// Format error for display.
    pub fn format(
        self: CompileError,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{s}: {s}", .{ @tagName(self.kind), self.context });

        if (self.pass_name) |name| {
            try writer.print(" [pass: {s}]", .{name});
        }
        if (self.block_id) |bid| {
            try writer.print(" (block b{d})", .{bid});
        }
        if (self.value_id) |vid| {
            try writer.print(" (value v{d})", .{vid});
        }
        if (self.source_pos) |pos| {
            if (pos.line > 0) {
                try writer.print(" at line {d}", .{pos.line});
                if (pos.col > 0) {
                    try writer.print(":{d}", .{pos.col});
                }
            }
        }
    }

    /// Convert to simple error for compatibility.
    pub fn toError(self: CompileError) Error {
        return switch (self.kind) {
            .invalid_block_id => error.InvalidBlockId,
            .invalid_value_id => error.InvalidValueId,
            .edge_invariant_violated => error.EdgeInvariantViolated,
            .use_count_mismatch => error.UseCountMismatch,
            .block_membership_error => error.BlockMembershipError,
            .type_mismatch => error.TypeMismatch,
            .invalid_type => error.InvalidType,
            .pass_failed => error.PassFailed,
            .pass_not_found => error.PassNotFound,
            .dependency_not_satisfied => error.DependencyNotSatisfied,
            .out_of_memory => error.OutOfMemory,
            .allocation_failed => error.AllocationFailed,
            .invalid_instruction => error.InvalidInstruction,
            .register_allocation_failed => error.RegisterAllocationFailed,
            .unsupported_operation => error.UnsupportedOperation,
        };
    }
};

/// Simple error set for compatibility with Zig error handling.
pub const Error = error{
    InvalidBlockId,
    InvalidValueId,
    EdgeInvariantViolated,
    UseCountMismatch,
    BlockMembershipError,
    TypeMismatch,
    InvalidType,
    PassFailed,
    PassNotFound,
    DependencyNotSatisfied,
    OutOfMemory,
    AllocationFailed,
    InvalidInstruction,
    RegisterAllocationFailed,
    UnsupportedOperation,
};

/// Result type that can hold either a value or an error with context.
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: CompileError,

        const Self = @This();

        pub fn unwrap(self: Self) Error!T {
            return switch (self) {
                .ok => |v| v,
                .err => |e| e.toError(),
            };
        }

        pub fn getError(self: Self) ?CompileError {
            return switch (self) {
                .ok => null,
                .err => |e| e,
            };
        }
    };
}

/// Verification error for SSA invariant violations.
pub const VerifyError = struct {
    /// Description of what invariant was violated
    message: []const u8,

    /// Block where violation occurred
    block_id: ?ID = null,

    /// Value where violation occurred
    value_id: ?ID = null,

    /// Expected value (for mismatches)
    expected: ?[]const u8 = null,

    /// Actual value (for mismatches)
    actual: ?[]const u8 = null,

    pub fn format(
        self: VerifyError,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("verification failed: {s}", .{self.message});

        if (self.block_id) |bid| {
            try writer.print(" (block b{d})", .{bid});
        }
        if (self.value_id) |vid| {
            try writer.print(" (value v{d})", .{vid});
        }
        if (self.expected) |exp| {
            try writer.print(" expected: {s}", .{exp});
        }
        if (self.actual) |act| {
            try writer.print(" actual: {s}", .{act});
        }
    }
};

// =========================================
// Tests
// =========================================

test "CompileError formatting" {
    const err = CompileError.init(.use_count_mismatch, "during dead code elimination")
        .withBlock(5)
        .withValue(10)
        .withPass("early deadcode");

    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try err.format("", .{}, stream.writer());

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "use_count_mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "dead code elimination") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "b5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "v10") != null);
}

test "CompileError to simple error" {
    const err = CompileError.init(.pass_not_found, "unknown pass");
    const simple = err.toError();
    try std.testing.expectEqual(error.PassNotFound, simple);
}

test "Result type" {
    const ResultInt = Result(i32);

    const ok_result = ResultInt{ .ok = 42 };
    try std.testing.expectEqual(@as(i32, 42), try ok_result.unwrap());

    const err_result = ResultInt{ .err = CompileError.init(.out_of_memory, "allocation failed") };
    try std.testing.expectError(error.OutOfMemory, err_result.unwrap());
}

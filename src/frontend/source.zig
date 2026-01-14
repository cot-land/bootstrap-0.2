//! Source text handling and position tracking.
//!
//! Architecture modeled on Go's go/token/position.go:
//! - Pos: compact offset-based position
//! - Position: expanded line/column for display
//! - Span: range with start/end positions
//! - Source: file content with lazy line offset computation
//!
//! Simplified from Go: single file at a time (no FileSet).

const std = @import("std");

// =========================================
// Pos - Compact source position
// =========================================

/// A position in source code (byte offset from start of file).
/// Compact representation - line/column computed on demand.
pub const Pos = struct {
    offset: u32,

    pub const zero = Pos{ .offset = 0 };

    /// Advance by n bytes.
    pub fn advance(self: Pos, n: u32) Pos {
        return .{ .offset = self.offset + n };
    }

    /// Check if position is valid (not zero for error cases).
    pub fn isValid(_: Pos) bool {
        return true; // All positions are valid in our simple model
    }
};

// =========================================
// Position - Expanded for display
// =========================================

/// Human-readable source position (for error messages).
/// Line and column are 1-based.
pub const Position = struct {
    filename: []const u8,
    offset: u32, // 0-based byte offset
    line: u32, // 1-based line number
    column: u32, // 1-based column number

    /// Format as "file:line:column" or "file:line" if column is 0.
    pub fn format(
        self: Position,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        if (self.filename.len > 0) {
            try writer.print("{s}:", .{self.filename});
        }
        try writer.print("{d}", .{self.line});
        if (self.column > 0) {
            try writer.print(":{d}", .{self.column});
        }
    }

    /// Convert to string (allocates).
    pub fn toString(self: Position, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        try self.format("", .{}, buf.writer());
        return buf.toOwnedSlice();
    }
};

// =========================================
// Span - Range in source
// =========================================

/// A range in source code (start and end positions).
/// Used for AST nodes and error messages.
pub const Span = struct {
    start: Pos,
    end: Pos,

    pub const zero = Span{ .start = Pos.zero, .end = Pos.zero };

    pub fn init(start: Pos, end: Pos) Span {
        return .{ .start = start, .end = end };
    }

    /// Create span from a single position (zero-width).
    pub fn fromPos(pos: Pos) Span {
        return .{ .start = pos, .end = pos };
    }

    /// Merge two spans (union).
    pub fn merge(self: Span, other: Span) Span {
        return .{
            .start = if (self.start.offset < other.start.offset) self.start else other.start,
            .end = if (self.end.offset > other.end.offset) self.end else other.end,
        };
    }

    /// Length in bytes.
    pub fn len(self: Span) u32 {
        return self.end.offset - self.start.offset;
    }
};

// =========================================
// Source - File content with line tracking
// =========================================

/// Source holds the content of a source file.
pub const Source = struct {
    /// File name (for error messages).
    filename: []const u8,

    /// Source content (UTF-8).
    content: []const u8,

    /// Byte offsets of line starts (computed lazily).
    line_offsets: ?[]u32,

    /// Allocator for line offset computation.
    allocator: std.mem.Allocator,

    /// Initialize a source from content.
    pub fn init(allocator: std.mem.Allocator, filename: []const u8, content: []const u8) Source {
        return .{
            .filename = filename,
            .content = content,
            .line_offsets = null,
            .allocator = allocator,
        };
    }

    /// Free resources.
    pub fn deinit(self: *Source) void {
        if (self.line_offsets) |offsets| {
            self.allocator.free(offsets);
        }
    }

    /// Get the byte at a position, or null if past end.
    pub fn at(self: *const Source, pos: Pos) ?u8 {
        if (pos.offset >= self.content.len) return null;
        return self.content[pos.offset];
    }

    /// Get a slice of source content.
    pub fn slice(self: *const Source, start: Pos, end: Pos) []const u8 {
        const s = @min(start.offset, @as(u32, @intCast(self.content.len)));
        const e = @min(end.offset, @as(u32, @intCast(self.content.len)));
        return self.content[s..e];
    }

    /// Get the text for a span.
    pub fn spanText(self: *const Source, span: Span) []const u8 {
        return self.slice(span.start, span.end);
    }

    /// Convert a position to a full Position with line/column.
    pub fn position(self: *Source, pos: Pos) Position {
        self.ensureLineOffsets();

        const offsets = self.line_offsets.?;
        const offset = pos.offset;

        // Binary search for the line containing this offset
        var line: u32 = 0;
        var lo: usize = 0;
        var hi: usize = offsets.len;

        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (offsets[mid] <= offset) {
                line = @intCast(mid);
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        const line_start = offsets[line];
        const column = offset - line_start;

        return .{
            .filename = self.filename,
            .offset = offset,
            .line = line + 1, // 1-based
            .column = column + 1, // 1-based
        };
    }

    /// Get the line containing a position (for error context).
    pub fn getLine(self: *Source, pos: Pos) []const u8 {
        self.ensureLineOffsets();
        const loc = self.position(pos);
        const offsets = self.line_offsets.?;

        const line_idx = loc.line - 1;
        const start = offsets[line_idx];

        var end = start;
        while (end < self.content.len and self.content[end] != '\n') {
            end += 1;
        }

        return self.content[start..end];
    }

    /// Get total line count.
    pub fn lineCount(self: *Source) usize {
        self.ensureLineOffsets();
        return self.line_offsets.?.len;
    }

    /// Compute line offsets if not already done.
    fn ensureLineOffsets(self: *Source) void {
        if (self.line_offsets != null) return;

        // Count newlines first
        var count: usize = 1; // Line 1 starts at offset 0
        for (self.content) |c| {
            if (c == '\n') count += 1;
        }

        // Allocate and fill
        const offsets = self.allocator.alloc(u32, count) catch return;
        offsets[0] = 0;
        var idx: usize = 1;
        for (self.content, 0..) |c, i| {
            if (c == '\n') {
                offsets[idx] = @intCast(i + 1);
                idx += 1;
            }
        }

        self.line_offsets = offsets;
    }
};

// =========================================
// Tests
// =========================================

test "Pos advance" {
    const pos = Pos{ .offset = 5 };
    const next = pos.advance(3);
    try std.testing.expectEqual(@as(u32, 8), next.offset);
}

test "Span merge" {
    const a = Span.init(Pos{ .offset = 5 }, Pos{ .offset = 10 });
    const b = Span.init(Pos{ .offset = 8 }, Pos{ .offset = 15 });
    const merged = a.merge(b);
    try std.testing.expectEqual(@as(u32, 5), merged.start.offset);
    try std.testing.expectEqual(@as(u32, 15), merged.end.offset);
}

test "Span len" {
    const span = Span.init(Pos{ .offset = 5 }, Pos{ .offset = 10 });
    try std.testing.expectEqual(@as(u32, 5), span.len());
}

test "Source position and location" {
    const content = "fn main() {\n    return 0\n}";
    var source = Source.init(std.testing.allocator, "test.cot", content);
    defer source.deinit();

    // First character
    const pos0 = source.position(Pos{ .offset = 0 });
    try std.testing.expectEqual(@as(u32, 1), pos0.line);
    try std.testing.expectEqual(@as(u32, 1), pos0.column);

    // 'm' in 'main'
    const pos3 = source.position(Pos{ .offset = 3 });
    try std.testing.expectEqual(@as(u32, 1), pos3.line);
    try std.testing.expectEqual(@as(u32, 4), pos3.column);

    // 'r' in 'return' (second line)
    const pos16 = source.position(Pos{ .offset = 16 });
    try std.testing.expectEqual(@as(u32, 2), pos16.line);
    try std.testing.expectEqual(@as(u32, 5), pos16.column);
}

test "Source slice and spanText" {
    const content = "hello world";
    var source = Source.init(std.testing.allocator, "test.cot", content);
    defer source.deinit();

    const span = Span.init(Pos{ .offset = 0 }, Pos{ .offset = 5 });
    try std.testing.expectEqualStrings("hello", source.spanText(span));
}

test "Source getLine" {
    const content = "line one\nline two\nline three";
    var source = Source.init(std.testing.allocator, "test.cot", content);
    defer source.deinit();

    try std.testing.expectEqualStrings("line one", source.getLine(Pos{ .offset = 0 }));
    try std.testing.expectEqualStrings("line two", source.getLine(Pos{ .offset = 10 }));
    try std.testing.expectEqualStrings("line three", source.getLine(Pos{ .offset = 20 }));
}

test "Source at" {
    const content = "abc";
    var source = Source.init(std.testing.allocator, "test.cot", content);
    defer source.deinit();

    try std.testing.expectEqual(@as(?u8, 'a'), source.at(Pos{ .offset = 0 }));
    try std.testing.expectEqual(@as(?u8, 'b'), source.at(Pos{ .offset = 1 }));
    try std.testing.expectEqual(@as(?u8, 'c'), source.at(Pos{ .offset = 2 }));
    try std.testing.expectEqual(@as(?u8, null), source.at(Pos{ .offset = 3 }));
}

test "Source lineCount" {
    const content = "line 1\nline 2\nline 3";
    var source = Source.init(std.testing.allocator, "test.cot", content);
    defer source.deinit();

    try std.testing.expectEqual(@as(usize, 3), source.lineCount());
}

test "Position format" {
    const pos = Position{
        .filename = "test.cot",
        .offset = 10,
        .line = 2,
        .column = 5,
    };

    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try pos.format("", .{}, stream.writer());
    try std.testing.expectEqualStrings("test.cot:2:5", stream.getWritten());
}

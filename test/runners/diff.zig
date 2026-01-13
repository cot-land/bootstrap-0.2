//! Diff utility for golden file comparison.
//!
//! Provides readable diff output when golden tests fail.
//! Go reference: Uses similar approach to Go's diff packages.

const std = @import("std");

/// A single difference between expected and actual output.
pub const Difference = struct {
    line: usize,
    expected: ?[]const u8,
    actual: ?[]const u8,
};

/// Result of comparing two strings.
pub const DiffResult = struct {
    differences: std.ArrayListUnmanaged(Difference),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DiffResult {
        return .{
            .differences = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DiffResult) void {
        self.differences.deinit(self.allocator);
    }

    pub fn addDifference(self: *DiffResult, line: usize, expected: ?[]const u8, actual: ?[]const u8) void {
        self.differences.append(self.allocator, .{
            .line = line,
            .expected = expected,
            .actual = actual,
        }) catch {};
    }

    pub fn hasDifferences(self: *const DiffResult) bool {
        return self.differences.items.len > 0;
    }

    /// Format diff output for display.
    pub fn format(self: *const DiffResult, writer: anytype) !void {
        if (self.differences.items.len == 0) {
            try writer.writeAll("No differences\n");
            return;
        }

        try writer.print("Found {d} difference(s):\n\n", .{self.differences.items.len});

        for (self.differences.items) |d| {
            try writer.print("Line {d}:\n", .{d.line});
            if (d.expected) |exp| {
                try writer.print("  - {s}\n", .{exp});
            } else {
                try writer.writeAll("  - (missing)\n");
            }
            if (d.actual) |act| {
                try writer.print("  + {s}\n", .{act});
            } else {
                try writer.writeAll("  + (missing)\n");
            }
            try writer.writeAll("\n");
        }
    }
};

/// Compare two strings line by line.
pub fn diff(allocator: std.mem.Allocator, expected: []const u8, actual: []const u8) DiffResult {
    var result = DiffResult.init(allocator);

    var exp_lines = std.mem.splitSequence(u8, expected, "\n");
    var act_lines = std.mem.splitSequence(u8, actual, "\n");

    var line_num: usize = 1;
    while (true) {
        const exp = exp_lines.next();
        const act = act_lines.next();

        if (exp == null and act == null) break;

        const exp_line = exp orelse "";
        const act_line = act orelse "";

        if (!std.mem.eql(u8, exp_line, act_line)) {
            result.addDifference(line_num, exp, act);
        }
        line_num += 1;
    }

    return result;
}

/// Compare strings ignoring trailing whitespace on each line.
pub fn diffIgnoreTrailingWhitespace(allocator: std.mem.Allocator, expected: []const u8, actual: []const u8) DiffResult {
    var result = DiffResult.init(allocator);

    var exp_lines = std.mem.splitSequence(u8, expected, "\n");
    var act_lines = std.mem.splitSequence(u8, actual, "\n");

    var line_num: usize = 1;
    while (true) {
        const exp = exp_lines.next();
        const act = act_lines.next();

        if (exp == null and act == null) break;

        const exp_trimmed = std.mem.trimRight(u8, exp orelse "", " \t\r");
        const act_trimmed = std.mem.trimRight(u8, act orelse "", " \t\r");

        if (!std.mem.eql(u8, exp_trimmed, act_trimmed)) {
            result.addDifference(line_num, exp, act);
        }
        line_num += 1;
    }

    return result;
}

// =========================================
// Tests
// =========================================

test "diff detects no differences" {
    const allocator = std.testing.allocator;
    const text = "line 1\nline 2\nline 3";

    var result = diff(allocator, text, text);
    defer result.deinit();

    try std.testing.expect(!result.hasDifferences());
}

test "diff detects changed line" {
    const allocator = std.testing.allocator;
    const expected = "line 1\nline 2\nline 3";
    const actual = "line 1\nLINE 2\nline 3";

    var result = diff(allocator, expected, actual);
    defer result.deinit();

    try std.testing.expect(result.hasDifferences());
    try std.testing.expectEqual(@as(usize, 1), result.differences.items.len);
    try std.testing.expectEqual(@as(usize, 2), result.differences.items[0].line);
}

test "diff detects added line" {
    const allocator = std.testing.allocator;
    const expected = "line 1\nline 2";
    const actual = "line 1\nline 2\nline 3";

    var result = diff(allocator, expected, actual);
    defer result.deinit();

    try std.testing.expect(result.hasDifferences());
    try std.testing.expectEqual(@as(usize, 1), result.differences.items.len);
}

test "diff detects removed line" {
    const allocator = std.testing.allocator;
    const expected = "line 1\nline 2\nline 3";
    const actual = "line 1\nline 2";

    var result = diff(allocator, expected, actual);
    defer result.deinit();

    try std.testing.expect(result.hasDifferences());
}

test "diffIgnoreTrailingWhitespace ignores trailing spaces" {
    const allocator = std.testing.allocator;
    const expected = "line 1  \nline 2\t\nline 3";
    const actual = "line 1\nline 2\nline 3";

    var result = diffIgnoreTrailingWhitespace(allocator, expected, actual);
    defer result.deinit();

    try std.testing.expect(!result.hasDifferences());
}

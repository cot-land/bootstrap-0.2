//! Directive-based test runner.
//!
//! Parses source files with special comments that specify expected behavior.
//! Go reference: go/test/run.go
//!
//! ## Directives
//!
//! - `// run` - Compile and run, expect exit code 0
//! - `// compile` - Compile only, expect success
//! - `// errorcheck` - Expect specific compile errors
//! - `// build-error` - Expect compilation failure
//! - `// skip` - Skip this test
//!
//! ## Error Expectations
//!
//! In errorcheck tests, use `// ERROR "pattern"` comments:
//!
//! ```cot
//! // errorcheck
//! fn main() {
//!     let x = y; // ERROR "undefined"
//! }
//! ```

const std = @import("std");

/// Test directive type.
pub const Directive = enum {
    run, // Compile, run, expect exit 0
    compile, // Compile only, expect success
    errorcheck, // Compile, expect specific errors
    build_error, // Compile, expect failure
    skip, // Skip this test
    unknown, // No directive found
};

/// An expected error at a specific location.
pub const ErrorExpectation = struct {
    line: usize,
    pattern: []const u8,
};

/// Parsed test specification.
pub const TestSpec = struct {
    directive: Directive = .unknown,
    errors: std.ArrayListUnmanaged(ErrorExpectation),
    description: []const u8 = "",
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TestSpec {
        return .{
            .errors = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestSpec) void {
        self.errors.deinit(self.allocator);
    }
};

/// Parse directives from source code.
pub fn parseDirectives(allocator: std.mem.Allocator, source: []const u8) !TestSpec {
    var spec = TestSpec.init(allocator);
    errdefer spec.deinit();

    var lines = std.mem.splitSequence(u8, source, "\n");
    var line_num: usize = 1;
    var in_header = true;

    while (lines.next()) |line| {
        defer line_num += 1;

        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Parse header directives (before any code)
        if (in_header and std.mem.startsWith(u8, trimmed, "//")) {
            if (std.mem.startsWith(u8, trimmed, "// run")) {
                spec.directive = .run;
            } else if (std.mem.startsWith(u8, trimmed, "// compile")) {
                spec.directive = .compile;
            } else if (std.mem.startsWith(u8, trimmed, "// errorcheck")) {
                spec.directive = .errorcheck;
            } else if (std.mem.startsWith(u8, trimmed, "// build-error")) {
                spec.directive = .build_error;
            } else if (std.mem.startsWith(u8, trimmed, "// skip")) {
                spec.directive = .skip;
            }
            continue;
        }

        // Non-comment line ends header
        if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "//")) {
            in_header = false;
        }

        // Parse ERROR expectations anywhere in the file
        if (std.mem.indexOf(u8, line, "// ERROR")) |idx| {
            const rest = line[idx + 8 ..]; // Skip "// ERROR"
            if (extractQuotedPattern(rest)) |pattern| {
                try spec.errors.append(allocator, .{
                    .line = line_num,
                    .pattern = pattern,
                });
            }
        }
    }

    return spec;
}

/// Extract pattern from `"pattern"` syntax.
fn extractQuotedPattern(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len < 2) return null;

    if (trimmed[0] != '"') return null;

    // Find closing quote
    if (std.mem.indexOfScalar(u8, trimmed[1..], '"')) |end| {
        return trimmed[1 .. end + 1];
    }

    return null;
}

/// Run a directive-based test.
pub fn runDirectiveTest(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    source: []const u8,
) !TestResult {
    var spec = try parseDirectives(allocator, source);
    defer spec.deinit();

    return switch (spec.directive) {
        .skip => .{ .status = .skipped, .message = "test marked as skip" },
        .unknown => .{ .status = .skipped, .message = "no directive found" },
        .run => runTest(allocator, source_path, &spec),
        .compile => compileTest(allocator, source_path, &spec),
        .errorcheck => errorcheckTest(allocator, source_path, &spec),
        .build_error => buildErrorTest(allocator, source_path, &spec),
    };
}

pub const TestResult = struct {
    status: Status,
    message: []const u8 = "",

    pub const Status = enum {
        passed,
        failed,
        skipped,
    };
};

fn runTest(allocator: std.mem.Allocator, source_path: []const u8, spec: *TestSpec) TestResult {
    _ = allocator;
    _ = source_path;
    _ = spec;
    // TODO: Implement when we have a working compiler
    return .{ .status = .skipped, .message = "compiler not yet implemented" };
}

fn compileTest(allocator: std.mem.Allocator, source_path: []const u8, spec: *TestSpec) TestResult {
    _ = allocator;
    _ = source_path;
    _ = spec;
    // TODO: Implement when we have a working compiler
    return .{ .status = .skipped, .message = "compiler not yet implemented" };
}

fn errorcheckTest(allocator: std.mem.Allocator, source_path: []const u8, spec: *TestSpec) TestResult {
    _ = allocator;
    _ = source_path;
    _ = spec;
    // TODO: Implement when we have a working compiler
    return .{ .status = .skipped, .message = "compiler not yet implemented" };
}

fn buildErrorTest(allocator: std.mem.Allocator, source_path: []const u8, spec: *TestSpec) TestResult {
    _ = allocator;
    _ = source_path;
    _ = spec;
    // TODO: Implement when we have a working compiler
    return .{ .status = .skipped, .message = "compiler not yet implemented" };
}

// =========================================
// Tests
// =========================================

test "parseDirectives recognizes run directive" {
    const allocator = std.testing.allocator;
    const source =
        \\// run
        \\// Test description
        \\fn main() {
        \\    print("hello")
        \\}
    ;

    var spec = try parseDirectives(allocator, source);
    defer spec.deinit();

    try std.testing.expectEqual(Directive.run, spec.directive);
}

test "parseDirectives recognizes errorcheck directive" {
    const allocator = std.testing.allocator;
    const source =
        \\// errorcheck
        \\fn main() {
        \\    let x = y; // ERROR "undefined"
        \\}
    ;

    var spec = try parseDirectives(allocator, source);
    defer spec.deinit();

    try std.testing.expectEqual(Directive.errorcheck, spec.directive);
    try std.testing.expectEqual(@as(usize, 1), spec.errors.items.len);
    try std.testing.expectEqualStrings("undefined", spec.errors.items[0].pattern);
    try std.testing.expectEqual(@as(usize, 3), spec.errors.items[0].line);
}

test "parseDirectives handles multiple errors" {
    const allocator = std.testing.allocator;
    const source =
        \\// errorcheck
        \\fn main() {
        \\    let x = a; // ERROR "undefined: a"
        \\    let y = b; // ERROR "undefined: b"
        \\}
    ;

    var spec = try parseDirectives(allocator, source);
    defer spec.deinit();

    try std.testing.expectEqual(@as(usize, 2), spec.errors.items.len);
    try std.testing.expectEqualStrings("undefined: a", spec.errors.items[0].pattern);
    try std.testing.expectEqualStrings("undefined: b", spec.errors.items[1].pattern);
}

test "parseDirectives recognizes skip directive" {
    const allocator = std.testing.allocator;
    const source =
        \\// skip
        \\// This test is broken
        \\fn main() {}
    ;

    var spec = try parseDirectives(allocator, source);
    defer spec.deinit();

    try std.testing.expectEqual(Directive.skip, spec.directive);
}

test "extractQuotedPattern extracts pattern" {
    try std.testing.expectEqualStrings("hello", extractQuotedPattern(" \"hello\"").?);
    try std.testing.expectEqualStrings("undefined", extractQuotedPattern("\"undefined\"").?);
    try std.testing.expect(extractQuotedPattern("no quotes") == null);
    try std.testing.expect(extractQuotedPattern("") == null);
}

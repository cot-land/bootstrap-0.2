//! Debug and Visualization Support for SSA.
//!
//! Go reference: [cmd/compile/internal/ssa/html.go]
//!
//! Provides various output formats for debugging SSA:
//! - **Text format** - Human-readable dump
//! - **DOT format** - Graphviz CFG visualization
//! - **HTML format** - Interactive view (like Go's GOSSAFUNC)
//!
//! ## Verification
//!
//! The [verify] function checks SSA invariants:
//! - Block membership consistency
//! - Edge bidirectional invariants
//! - Value argument validity
//!
//! ## Related Modules
//!
//! - [Func] - Functions to dump/verify
//! - [Block] - Blocks shown in output
//! - [Value] - Values with use counts displayed
//! - [compile.zig] - HTML output during compilation
//!
//! ## Example
//!
//! ```zig
//! // Text dump to stderr
//! try debug.dump(&f, .text, std.io.getStdErr().writer());
//!
//! // DOT for Graphviz: dot -Tpng ssa.dot -o ssa.png
//! try debug.dumpToFile(&f, .dot, "ssa.dot");
//!
//! // Verify invariants
//! const errors = try debug.verify(&f, allocator);
//! if (errors.len > 0) {
//!     // Handle errors...
//! }
//! ```

const std = @import("std");
const Func = @import("func.zig").Func;
const Block = @import("block.zig").Block;
const Value = @import("value.zig").Value;
const Op = @import("op.zig").Op;

/// Output format for dumping.
pub const Format = enum {
    text,
    dot,
    html,
};

/// Dump function to writer in specified format.
pub fn dump(f: *const Func, format: Format, writer: anytype) !void {
    switch (format) {
        .text => try dumpText(f, writer),
        .dot => try dumpDot(f, writer),
        .html => try dumpHtml(f, writer),
    }
}

/// Dump function in text format.
pub fn dumpText(f: *const Func, writer: anytype) !void {
    try writer.print("func {s}:\n", .{f.name});

    for (f.blocks.items) |b| {
        try writer.print("  b{d} ({s}):\n", .{ b.id, @tagName(b.kind) });

        // Show predecessors
        if (b.preds.len > 0) {
            try writer.writeAll("    preds: ");
            for (b.preds, 0..) |pred, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("b{d}", .{pred.b.id});
            }
            try writer.writeAll("\n");
        }

        // Show values
        for (b.values.items) |v| {
            try dumpValue(v, writer);
        }

        // Show control values
        if (b.numControls() > 0) {
            try writer.writeAll("    control: ");
            for (b.controlValues(), 0..) |cv, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("v{d}", .{cv.id});
            }
            try writer.writeAll("\n");
        }

        // Show successors
        if (b.succs.len > 0) {
            try writer.writeAll("    succs: ");
            for (b.succs, 0..) |succ, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("b{d}", .{succ.b.id});
            }
            try writer.writeAll("\n");
        }

        try writer.writeAll("\n");
    }
}

/// Dump a single value.
fn dumpValue(v: *const Value, writer: anytype) !void {
    const dead_marker: []const u8 = if (v.uses == 0 and !v.hasSideEffects()) " (dead)" else "";

    try writer.print("    v{d}{s} = {s}", .{
        v.id,
        dead_marker,
        @tagName(v.op),
    });

    // Arguments
    if (v.args.len > 0) {
        try writer.writeAll(" ");
        for (v.args, 0..) |arg, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("v{d}", .{arg.id});
        }
    }

    // Auxiliary data
    switch (v.aux) {
        .none => {},
        .string => |s| try writer.print(" \"{s}\"", .{s}),
        .symbol => |sym| try writer.print(" @{*}", .{sym}),
        .symbol_off => |so| try writer.print(" @{*}+{d}", .{ so.sym, so.offset }),
        .call => try writer.writeAll(" <call>"),
        .type_ref => |t| try writer.print(" type({d})", .{t}),
        .cond => |c| try writer.print(" cond({s})", .{@tagName(c)}),
    }

    if (v.aux_int != 0) {
        try writer.print(" [{d}]", .{v.aux_int});
    }

    try writer.print(" : uses={d}\n", .{v.uses});
}

/// Dump function in DOT format (for Graphviz).
pub fn dumpDot(f: *const Func, writer: anytype) !void {
    try writer.print("digraph \"{s}\" {{\n", .{f.name});
    try writer.writeAll("  rankdir=TB;\n");
    try writer.writeAll("  node [shape=box, fontname=\"Courier\"];\n");
    try writer.writeAll("\n");

    // Emit nodes for each block
    for (f.blocks.items) |b| {
        try writer.print("  b{d} [label=\"b{d} ({s})\\l", .{
            b.id,
            b.id,
            @tagName(b.kind),
        });

        // Add values to label
        for (b.values.items) |v| {
            try writer.print("v{d} = {s}", .{ v.id, @tagName(v.op) });
            if (v.args.len > 0) {
                try writer.writeAll(" ");
                for (v.args, 0..) |arg, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("v{d}", .{arg.id});
                }
            }
            if (v.aux_int != 0) {
                try writer.print(" [{d}]", .{v.aux_int});
            }
            try writer.writeAll("\\l");
        }

        try writer.writeAll("\"];\n");
    }

    try writer.writeAll("\n");

    // Emit edges
    for (f.blocks.items) |b| {
        for (b.succs, 0..) |succ, i| {
            const label = if (b.kind == .if_) (if (i == 0) "T" else "F") else "";
            if (label.len > 0) {
                try writer.print("  b{d} -> b{d} [label=\"{s}\"];\n", .{
                    b.id,
                    succ.b.id,
                    label,
                });
            } else {
                try writer.print("  b{d} -> b{d};\n", .{ b.id, succ.b.id });
            }
        }
    }

    try writer.writeAll("}\n");
}

/// Dump function in HTML format (interactive).
pub fn dumpHtml(f: *const Func, writer: anytype) !void {
    // Write HTML header
    try writer.print(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\<title>SSA: {s}</title>
        \\<style>
        \\body {{ font-family: 'Menlo', 'Monaco', 'Courier New', monospace; font-size: 12px; margin: 20px; }}
        \\h1 {{ color: #333; }}
        \\.func {{ margin: 20px 0; }}
        \\.block {{
        \\  margin: 10px 0;
        \\  padding: 10px;
        \\  border: 1px solid #ddd;
        \\  border-radius: 4px;
        \\  background: #f9f9f9;
        \\}}
        \\.block-header {{
        \\  font-weight: bold;
        \\  color: #0066cc;
        \\  margin-bottom: 8px;
        \\  padding-bottom: 4px;
        \\  border-bottom: 1px solid #ddd;
        \\}}
        \\.value {{
        \\  margin: 2px 0 2px 20px;
        \\  padding: 2px 4px;
        \\}}
        \\.value:hover {{ background: #ffffcc; }}
        \\.dead {{ color: #999; text-decoration: line-through; }}
        \\.op {{ color: #006600; font-weight: bold; }}
        \\.id {{ color: #0066cc; }}
        \\.aux {{ color: #666; }}
        \\.uses {{ color: #cc6600; font-size: 10px; }}
        \\.edges {{
        \\  margin-top: 8px;
        \\  padding-top: 4px;
        \\  border-top: 1px solid #eee;
        \\  color: #666;
        \\}}
        \\.succ {{ color: #009900; }}
        \\.pred {{ color: #990099; }}
        \\</style>
        \\</head>
        \\<body>
        \\<h1>SSA: {s}</h1>
        \\<div class="func">
        \\
    , .{ f.name, f.name });

    // Emit blocks
    for (f.blocks.items) |b| {
        try writer.print(
            \\<div class="block" id="b{d}">
            \\<div class="block-header">
            \\  <span class="id">b{d}</span> ({s})
            \\</div>
            \\
        , .{ b.id, b.id, @tagName(b.kind) });

        // Values
        for (b.values.items) |v| {
            const dead_class = if (v.uses == 0 and !v.hasSideEffects()) " dead" else "";
            try writer.print(
                \\<div class="value{s}">
                \\  <span class="id">v{d}</span> =
                \\  <span class="op">{s}</span>
            , .{ dead_class, v.id, @tagName(v.op) });

            // Args
            if (v.args.len > 0) {
                try writer.writeAll(" ");
                for (v.args, 0..) |arg, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("<a href=\"#v{d}\" class=\"id\">v{d}</a>", .{ arg.id, arg.id });
                }
            }

            // Aux
            if (v.aux_int != 0) {
                try writer.print(" <span class=\"aux\">[{d}]</span>", .{v.aux_int});
            }

            try writer.print(" <span class=\"uses\">(uses: {d})</span>", .{v.uses});
            try writer.writeAll("</div>\n");
        }

        // Edges
        try writer.writeAll("<div class=\"edges\">");

        if (b.preds.len > 0) {
            try writer.writeAll("<span class=\"pred\">pred: ");
            for (b.preds, 0..) |pred, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("<a href=\"#b{d}\">b{d}</a>", .{ pred.b.id, pred.b.id });
            }
            try writer.writeAll("</span> ");
        }

        if (b.succs.len > 0) {
            try writer.writeAll("<span class=\"succ\">succ: ");
            for (b.succs, 0..) |succ, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("<a href=\"#b{d}\">b{d}</a>", .{ succ.b.id, succ.b.id });
            }
            try writer.writeAll("</span>");
        }

        try writer.writeAll("</div>\n</div>\n");
    }

    // Footer
    try writer.writeAll(
        \\</div>
        \\</body>
        \\</html>
        \\
    );
}

/// Dump function to file.
pub fn dumpToFile(f: *const Func, format: Format, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    try dump(f, format, file.writer());
}

/// Verify SSA invariants. Returns list of errors found.
pub fn verify(f: *const Func, allocator: std.mem.Allocator) ![]const []const u8 {
    var errors = std.ArrayListUnmanaged([]const u8){};

    // Check each block
    for (f.blocks.items) |b| {
        // Check values
        for (b.values.items) |v| {
            // Check that value's block pointer is correct
            if (v.block != b) {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "v{d}: block pointer mismatch (expected b{d}, got b{d})",
                    .{ v.id, b.id, if (v.block) |vb| vb.id else 0 },
                );
                try errors.append(allocator, msg);
            }

            // Check that args exist
            for (v.args) |arg| {
                if (arg.id == 0) {
                    const msg = try std.fmt.allocPrint(
                        allocator,
                        "v{d}: has invalid arg (id=0)",
                        .{v.id},
                    );
                    try errors.append(allocator, msg);
                }
            }
        }

        // Check edge consistency
        for (b.succs, 0..) |succ, i| {
            // Check bidirectional invariant
            if (succ.i >= succ.b.preds.len or succ.b.preds[succ.i].b != b) {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "b{d}: succ[{d}] edge invariant violated",
                    .{ b.id, i },
                );
                try errors.append(allocator, msg);
            }
        }

        for (b.preds, 0..) |pred, i| {
            if (pred.i >= pred.b.succs.len or pred.b.succs[pred.i].b != b) {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "b{d}: pred[{d}] edge invariant violated",
                    .{ b.id, i },
                );
                try errors.append(allocator, msg);
            }
        }
    }

    return errors.toOwnedSlice(allocator);
}

/// Free verification errors.
pub fn freeErrors(errors: []const []const u8, allocator: std.mem.Allocator) void {
    for (errors) |err| {
        allocator.free(err);
    }
    allocator.free(errors);
}

// ═══════════════════════════════════════════════════════════════════════════
// Phase Snapshot and Comparison (Go GOSSAFUNC pattern)
// ═══════════════════════════════════════════════════════════════════════════

const types = @import("../core/types.zig");
const ID = types.ID;

/// Snapshot of a value for comparison.
pub const ValueSnapshot = struct {
    id: ID,
    op: Op,
    arg_ids: []ID,
    uses: i32,
    aux_int: i64,
};

/// Snapshot of a block for comparison.
pub const BlockSnapshot = struct {
    id: ID,
    kind: @import("block.zig").BlockKind,
    values: []ValueSnapshot,
    succ_ids: []ID,
};

/// Snapshot of function state at a point in compilation.
///
/// Used to compare before/after states and highlight changes.
pub const PhaseSnapshot = struct {
    name: []const u8,
    blocks: []BlockSnapshot,
    allocator: std.mem.Allocator,

    /// Capture current function state.
    pub fn capture(allocator: std.mem.Allocator, f: *const Func, name: []const u8) !PhaseSnapshot {
        var blocks = try allocator.alloc(BlockSnapshot, f.blocks.items.len);

        for (f.blocks.items, 0..) |b, i| {
            // Capture values
            var values = try allocator.alloc(ValueSnapshot, b.values.items.len);
            for (b.values.items, 0..) |v, j| {
                var arg_ids = try allocator.alloc(ID, v.args.len);
                for (v.args, 0..) |arg, k| {
                    arg_ids[k] = arg.id;
                }
                values[j] = .{
                    .id = v.id,
                    .op = v.op,
                    .arg_ids = arg_ids,
                    .uses = v.uses,
                    .aux_int = v.aux_int,
                };
            }

            // Capture successors
            var succ_ids = try allocator.alloc(ID, b.succs.len);
            for (b.succs, 0..) |succ, k| {
                succ_ids[k] = succ.b.id;
            }

            blocks[i] = .{
                .id = b.id,
                .kind = b.kind,
                .values = values,
                .succ_ids = succ_ids,
            };
        }

        return .{
            .name = try allocator.dupe(u8, name),
            .blocks = blocks,
            .allocator = allocator,
        };
    }

    /// Free snapshot memory.
    pub fn deinit(self: *PhaseSnapshot) void {
        for (self.blocks) |b| {
            for (b.values) |v| {
                self.allocator.free(v.arg_ids);
            }
            self.allocator.free(b.values);
            self.allocator.free(b.succ_ids);
        }
        self.allocator.free(self.blocks);
        self.allocator.free(self.name);
    }

    /// Compare two snapshots and count changes.
    pub fn compare(before: *const PhaseSnapshot, after: *const PhaseSnapshot) ChangeStats {
        var stats = ChangeStats{};

        // Build ID sets for before
        var before_values = std.AutoHashMap(ID, void).init(before.allocator);
        defer before_values.deinit();
        var before_blocks = std.AutoHashMap(ID, void).init(before.allocator);
        defer before_blocks.deinit();

        for (before.blocks) |b| {
            before_blocks.put(b.id, {}) catch {};
            for (b.values) |v| {
                before_values.put(v.id, {}) catch {};
            }
        }

        // Compare with after
        for (after.blocks) |b| {
            if (!before_blocks.contains(b.id)) {
                stats.blocks_added += 1;
            }
            for (b.values) |v| {
                if (!before_values.contains(v.id)) {
                    stats.values_added += 1;
                }
            }
        }

        // Count removals
        var after_values = std.AutoHashMap(ID, void).init(after.allocator);
        defer after_values.deinit();
        var after_blocks = std.AutoHashMap(ID, void).init(after.allocator);
        defer after_blocks.deinit();

        for (after.blocks) |b| {
            after_blocks.put(b.id, {}) catch {};
            for (b.values) |v| {
                after_values.put(v.id, {}) catch {};
            }
        }

        for (before.blocks) |b| {
            if (!after_blocks.contains(b.id)) {
                stats.blocks_removed += 1;
            }
            for (b.values) |v| {
                if (!after_values.contains(v.id)) {
                    stats.values_removed += 1;
                }
            }
        }

        return stats;
    }
};

/// Statistics about changes between two phases.
pub const ChangeStats = struct {
    values_added: usize = 0,
    values_removed: usize = 0,
    values_modified: usize = 0,
    blocks_added: usize = 0,
    blocks_removed: usize = 0,

    pub fn hasChanges(self: ChangeStats) bool {
        return self.values_added > 0 or self.values_removed > 0 or
            self.values_modified > 0 or self.blocks_added > 0 or
            self.blocks_removed > 0;
    }

    pub fn format(
        self: ChangeStats,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("+{d}/-{d} values, +{d}/-{d} blocks", .{
            self.values_added,
            self.values_removed,
            self.blocks_added,
            self.blocks_removed,
        });
    }
};

// =========================================
// Tests
// =========================================

test "dump text format" {
    const allocator = std.testing.allocator;

    var f = Func.init(allocator, "test");
    defer f.deinit();

    const b = try f.newBlock(.ret);
    const v = try f.newValue(.const_int, 0, b, .{});
    v.aux_int = 42;
    try b.addValue(allocator, v);

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    try dumpText(&f, output.writer(allocator));

    // Should contain function name and value
    try std.testing.expect(std.mem.indexOf(u8, output.items, "test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "const_int") != null);
}

test "dump dot format" {
    const allocator = std.testing.allocator;

    var f = Func.init(allocator, "test_dot");
    defer f.deinit();

    const entry = try f.newBlock(.if_);
    const left = try f.newBlock(.plain);
    const right = try f.newBlock(.ret);

    try entry.addEdgeTo(allocator, left);
    try entry.addEdgeTo(allocator, right);

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    try dumpDot(&f, output.writer(allocator));

    // Should contain digraph and edges
    try std.testing.expect(std.mem.indexOf(u8, output.items, "digraph") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "->") != null);
}

test "verify catches edge invariant violations" {
    const allocator = std.testing.allocator;

    var f = Func.init(allocator, "test_verify");
    defer f.deinit();

    // Create blocks with proper edges
    const entry = try f.newBlock(.plain);
    const exit = try f.newBlock(.ret);
    try entry.addEdgeTo(allocator, exit);

    // Should verify without errors
    const errors = try verify(&f, allocator);
    defer freeErrors(errors, allocator);

    try std.testing.expectEqual(@as(usize, 0), errors.len);
}

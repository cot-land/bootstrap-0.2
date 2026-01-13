//! SSA Compilation Pass Infrastructure.
//!
//! Go reference: [cmd/compile/internal/ssa/compile.go]
//!
//! Manages the sequence of compilation passes that transform SSA.
//! Each pass runs a specific transformation or analysis on a [Func].
//!
//! ## Pass Categories
//!
//! 1. **Early passes** - deadcode, copyelim (cleanup before optimization)
//! 2. **Optimization passes** - opt, cse, prove (value-level transforms)
//! 3. **Lowering passes** - lower, late_lower (generic → arch-specific)
//! 4. **Late passes** - critical, layout, schedule (prepare for codegen)
//! 5. **Register allocation** - regalloc (assign physical registers)
//!
//! ## Related Modules
//!
//! - [Func] - Functions that passes transform
//! - [Value] - Values that passes optimize
//! - [Block] - Blocks that passes reorder
//! - [Op] - Operations before/after lowering
//! - [debug.zig] - Debug output including HTML visualization
//!
//! ## Example
//!
//! ```zig
//! var f = Func.init(allocator, "test");
//! // ... build SSA ...
//!
//! // Run all passes with default config
//! try compile.compile(&f, .{});
//!
//! // Or run specific pass
//! try compile.runPass(&f, "early deadcode");
//! ```

const std = @import("std");
const Func = @import("func.zig").Func;
const Block = @import("block.zig").Block;
const Value = @import("value.zig").Value;

/// Pass function signature.
pub const PassFn = *const fn (*Func) anyerror!void;

/// Cached analysis types that passes can invalidate.
///
/// Go reference: [cmd/compile/internal/ssa/compile.go] analysis tracking
pub const AnalysisKind = enum {
    /// Dominator tree - [dom.zig]
    dominators,
    /// Postorder block traversal
    postorder,
    /// Loop information
    loop_info,
    /// Value liveness information
    liveness,
};

/// Compilation pass definition.
///
/// Go reference: [cmd/compile/internal/ssa/compile.go] pass struct
///
/// Enhanced with:
/// - Dependency tracking (requires)
/// - Analysis invalidation (invalidates)
/// - CFG/use preservation flags
pub const Pass = struct {
    /// Pass name for debugging and lookup
    name: []const u8,

    /// Pass function
    fn_: PassFn,

    /// Is this pass required (cannot be disabled)?
    required: bool = false,

    /// Is this pass currently disabled?
    disabled: bool = false,

    /// Passes that must run before this one
    requires: []const []const u8 = &.{},

    /// Cached analyses this pass invalidates.
    /// Passes that modify CFG should invalidate dominators/postorder.
    invalidates: []const AnalysisKind = &.{},

    /// Does this pass preserve the CFG structure?
    /// If false, dominators and postorder are invalidated.
    preserves_cfg: bool = true,

    /// Does this pass preserve value use counts?
    /// Most optimization passes should preserve uses.
    preserves_uses: bool = true,

    /// Time spent in this pass (for profiling)
    time_ns: u64 = 0,

    /// Number of times this pass has run
    run_count: u64 = 0,
};

/// Compiler configuration.
pub const Config = struct {
    /// Enable optimization passes
    optimize: bool = true,

    /// Debug output after each pass
    debug_passes: bool = false,

    /// HTML output file (null = disabled)
    html_output: ?[]const u8 = null,

    /// Specific function to dump (null = all)
    dump_func: ?[]const u8 = null,

    /// Verify SSA invariants after each pass (slow, for debugging)
    verify_after_passes: bool = false,
};

/// Pass execution statistics.
///
/// Tracks timing and transformation metrics across compilation.
pub const PassStats = struct {
    /// Total time spent compiling (nanoseconds)
    total_time_ns: i64 = 0,

    /// Per-pass timing (indexed by pass order)
    pass_times: [MAX_PASSES]i64 = [_]i64{0} ** MAX_PASSES,

    /// Number of values before/after compilation
    values_before: usize = 0,
    values_after: usize = 0,

    /// Number of blocks before/after compilation
    blocks_before: usize = 0,
    blocks_after: usize = 0,

    const MAX_PASSES = 32;

    /// Print summary of compilation statistics.
    pub fn printSummary(self: *const PassStats, writer: anytype) !void {
        try writer.print("Compilation Statistics:\n", .{});
        try writer.print("  Total time: {d:.3}ms\n", .{@as(f64, @floatFromInt(self.total_time_ns)) / 1_000_000.0});
        try writer.print("  Values: {d} -> {d}\n", .{ self.values_before, self.values_after });
        try writer.print("  Blocks: {d} -> {d}\n", .{ self.blocks_before, self.blocks_after });
    }
};

/// Compilation phases.
/// Go reference: cmd/compile/internal/ssa/compile.go passes slice
pub const Phase = enum {
    // Early phases
    early_deadcode,
    early_copyelim,

    // Optimization phases
    opt,
    cse,
    prove,
    nilcheck_elim,

    // Lowering
    lower,
    late_lower,

    // Late phases
    critical,
    layout,
    schedule,

    // Register allocation
    regalloc,

    // Count
    count,
};

/// Pass registry.
const passes = [_]Pass{
    // Early passes
    .{
        .name = "early deadcode",
        .fn_ = earlyDeadcode,
        .required = false,
    },
    .{
        .name = "early copyelim",
        .fn_ = earlyCopyElim,
        .required = false,
    },

    // Optimization passes
    .{
        .name = "opt",
        .fn_ = opt,
        .required = true,
    },
    .{
        .name = "generic cse",
        .fn_ = genericCSE,
        .required = false,
    },
    .{
        .name = "prove",
        .fn_ = prove,
        .required = false,
    },
    .{
        .name = "nilcheckelim",
        .fn_ = nilCheckElim,
        .required = false,
    },

    // Lowering
    .{
        .name = "lower",
        .fn_ = lower,
        .required = true,
    },
    .{
        .name = "late lower",
        .fn_ = lateLower,
        .required = true,
    },

    // Late passes
    .{
        .name = "critical",
        .fn_ = critical,
        .required = true,
    },
    .{
        .name = "layout",
        .fn_ = layout,
        .required = true,
    },
    .{
        .name = "schedule",
        .fn_ = schedule,
        .required = true,
    },

    // Register allocation
    .{
        .name = "regalloc",
        .fn_ = regalloc,
        .required = true,
    },
};

/// Compile function through all passes.
/// Go reference: cmd/compile/internal/ssa/compile.go Compile function
pub fn compile(f: *Func, config: Config) !void {
    var html_writer: ?HTMLWriter = null;
    defer if (html_writer) |*w| w.deinit();

    if (config.html_output) |path| {
        // Check if we should dump this function
        if (config.dump_func) |name| {
            if (!std.mem.eql(u8, f.name, name)) {
                // Skip HTML output for this function
            } else {
                html_writer = try HTMLWriter.init(f.allocator, path);
                if (html_writer) |*w| try w.writeHeader(f.name);
            }
        } else {
            html_writer = try HTMLWriter.init(f.allocator, path);
            if (html_writer) |*w| try w.writeHeader(f.name);
        }
    }

    // Run each pass
    for (passes) |pass| {
        if (pass.disabled) continue;
        if (!config.optimize and !pass.required) continue;

        const start = std.time.nanoTimestamp();

        try pass.fn_(f);

        const elapsed = std.time.nanoTimestamp() - start;

        if (config.debug_passes) {
            std.debug.print("=== After {s} ===\n", .{pass.name});
            try f.dump(std.io.getStdErr().writer());
        }

        if (html_writer) |*w| {
            try w.writePass(pass.name, f);
        }

        _ = elapsed; // TODO: Accumulate timing stats
    }

    if (html_writer) |*w| {
        try w.writeFooter();
    }
}

/// Run a specific pass by name.
pub fn runPass(f: *Func, pass_name: []const u8) !void {
    for (passes) |pass| {
        if (std.mem.eql(u8, pass.name, pass_name)) {
            try pass.fn_(f);
            return;
        }
    }
    return error.PassNotFound;
}

// =========================================
// Pass Implementations (stubs for now)
// =========================================

fn earlyDeadcode(f: *Func) !void {
    // Remove values with zero uses (unless they have side effects)
    for (f.blocks.items) |b| {
        var i: usize = 0;
        while (i < b.values.items.len) {
            const v = b.values.items[i];
            if (v.uses == 0 and !v.hasSideEffects()) {
                // Remove from block
                _ = b.values.swapRemove(i);
                // Decrement use counts of args
                v.resetArgs();
                f.freeValue(v);
            } else {
                i += 1;
            }
        }
    }
}

fn earlyCopyElim(f: *Func) !void {
    // Eliminate trivial copies: if v = copy(w), replace all uses of v with w
    for (f.blocks.items) |b| {
        for (b.values.items) |v| {
            if (v.op == .copy and v.args.len == 1) {
                const src = v.args[0];
                // Would need to rewrite all uses of v to use src
                // This is a placeholder - full implementation needs use tracking
                _ = src;
            }
        }
    }
}

fn opt(f: *Func) !void {
    // Generic optimization pass - applies rewrite rules
    // This is where constant folding, strength reduction, etc. happen
    _ = f;
}

fn genericCSE(f: *Func) !void {
    // Common subexpression elimination
    // Find identical computations and reuse them
    _ = f;
}

fn prove(f: *Func) !void {
    // Prove bounds and other facts to eliminate checks
    _ = f;
}

fn nilCheckElim(f: *Func) !void {
    // Eliminate redundant nil checks
    _ = f;
}

fn lower(f: *Func) !void {
    // Lower generic ops to architecture-specific ops
    // This is where Add becomes ARM64ADD, etc.
    _ = f;
}

fn lateLower(f: *Func) !void {
    // Late lowering - addressing modes, etc.
    _ = f;
}

fn critical(f: *Func) !void {
    // Insert critical edge splits
    // A critical edge is from a block with multiple successors
    // to a block with multiple predecessors
    _ = f;
}

fn layout(f: *Func) !void {
    // Order blocks for emission
    f.laidout = true;
}

fn schedule(f: *Func) !void {
    // Order values within blocks for emission
    f.scheduled = true;
}

fn regalloc(f: *Func) !void {
    // Register allocation - assign physical registers to values
    // This is a complex pass - see REGISTER_ALLOC.md for algorithm
    _ = f;
}

// =========================================
// HTML Writer for Debug Output
// =========================================

pub const HTMLWriter = struct {
    file: std.fs.File,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !HTMLWriter {
        const file = try std.fs.cwd().createFile(path, .{});
        return .{
            .file = file,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HTMLWriter) void {
        self.file.close();
    }

    pub fn writeHeader(self: *HTMLWriter, func_name: []const u8) !void {
        const writer = self.file.writer();
        try writer.print(
            \\<!DOCTYPE html>
            \\<html>
            \\<head>
            \\<title>SSA: {s}</title>
            \\<style>
            \\body {{ font-family: monospace; }}
            \\.pass {{ margin: 20px 0; padding: 10px; border: 1px solid #ccc; }}
            \\.pass-name {{ font-weight: bold; background: #eee; padding: 5px; }}
            \\.block {{ margin: 10px 0; }}
            \\.block-header {{ color: blue; }}
            \\.value {{ margin-left: 20px; }}
            \\.dead {{ color: #999; text-decoration: line-through; }}
            \\</style>
            \\</head>
            \\<body>
            \\<h1>SSA: {s}</h1>
            \\
        , .{ func_name, func_name });
    }

    pub fn writePass(self: *HTMLWriter, pass_name: []const u8, f: *const Func) !void {
        const writer = self.file.writer();
        try writer.print(
            \\<div class="pass">
            \\<div class="pass-name">{s}</div>
            \\
        , .{pass_name});

        for (f.blocks.items) |b| {
            try writer.print(
                \\<div class="block">
                \\<div class="block-header">b{d} ({s})</div>
                \\
            , .{ b.id, @tagName(b.kind) });

            for (b.values.items) |v| {
                const dead_class = if (v.uses == 0 and !v.hasSideEffects()) " dead" else "";
                try writer.print(
                    \\<div class="value{s}">v{d} = {s}
                , .{ dead_class, v.id, @tagName(v.op) });

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
                try writer.writeAll("</div>\n");
            }

            // Show successors
            if (b.succs.len > 0) {
                try writer.writeAll("<div class=\"value\">→ ");
                for (b.succs, 0..) |succ, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("b{d}", .{succ.b.id});
                }
                try writer.writeAll("</div>\n");
            }

            try writer.writeAll("</div>\n");
        }

        try writer.writeAll("</div>\n");
    }

    pub fn writeFooter(self: *HTMLWriter) !void {
        const writer = self.file.writer();
        try writer.writeAll("</body>\n</html>\n");
    }
};

// =========================================
// Tests
// =========================================

test "compile passes exist" {
    try std.testing.expect(passes.len > 0);

    // Check required passes
    var has_lower = false;
    var has_regalloc = false;
    for (passes) |pass| {
        if (std.mem.eql(u8, pass.name, "lower")) has_lower = true;
        if (std.mem.eql(u8, pass.name, "regalloc")) has_regalloc = true;
    }
    try std.testing.expect(has_lower);
    try std.testing.expect(has_regalloc);
}

test "early deadcode removes unused values" {
    const allocator = std.testing.allocator;

    var f = Func.init(allocator, "test");
    defer f.deinit();

    const b = try f.newBlock(.plain);

    // Create a value with no uses
    const v1 = try f.newValue(.const_int, 0, b, .{});
    v1.aux_int = 42;
    try b.addValue(allocator, v1);

    // Create a value with side effects (should not be removed)
    const v2 = try f.newValue(.store, 0, b, .{});
    try b.addValue(allocator, v2);

    // Before: 2 values
    try std.testing.expectEqual(@as(usize, 2), b.values.items.len);

    // Run deadcode elimination
    try earlyDeadcode(&f);

    // After: only store remains (const was removed)
    try std.testing.expectEqual(@as(usize, 1), b.values.items.len);
    try std.testing.expectEqual(@import("op.zig").Op.store, b.values.items[0].op);
}

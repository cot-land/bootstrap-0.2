//! Pipeline Debug Infrastructure
//!
//! Go reference: cmd/compile/internal/ssa/compile.go
//!
//! This module provides systematic debugging output for the compilation pipeline.
//! Inspired by Go's GOSSAFUNC/GOSSADEBUG environment variables, this allows
//! developers to trace values through each compilation phase.
//!
//! ## Usage
//!
//! ```zig
//! var driver = Driver.init(allocator);
//! driver.setDebugPhases(.{
//!     .parse = true,
//!     .lower = true,
//!     .ssa = true,
//! });
//! ```
//!
//! Or set environment variable: COT_DEBUG=parse,lower,ssa,regalloc

const std = @import("std");
const ast_mod = @import("frontend/ast.zig");
const ir_mod = @import("frontend/ir.zig");
const ssa_func_mod = @import("ssa/func.zig");
const ssa_debug = @import("ssa/debug.zig");

const Allocator = std.mem.Allocator;

/// Which phases to output debug info for.
/// Similar to Go's GOSSAFUNC which filters by function name,
/// and GOSSADEBUG which enables phase-specific output.
pub const DebugPhases = struct {
    parse: bool = false,
    check: bool = false,
    lower: bool = false,
    ssa: bool = false,
    regalloc: bool = false,
    codegen: bool = false,
    strings: bool = false,
    all: bool = false,

    /// Parse from environment variable COT_DEBUG
    pub fn fromEnv() DebugPhases {
        const env = std.posix.getenv("COT_DEBUG") orelse return .{};
        return parseStr(env);
    }

    fn parseStr(str: []const u8) DebugPhases {
        var result = DebugPhases{};
        var iter = std.mem.splitScalar(u8, str, ',');
        while (iter.next()) |phase| {
            const trimmed = std.mem.trim(u8, phase, " \t");
            if (std.mem.eql(u8, trimmed, "all")) result.all = true;
            if (std.mem.eql(u8, trimmed, "parse")) result.parse = true;
            if (std.mem.eql(u8, trimmed, "check")) result.check = true;
            if (std.mem.eql(u8, trimmed, "lower")) result.lower = true;
            if (std.mem.eql(u8, trimmed, "ssa")) result.ssa = true;
            if (std.mem.eql(u8, trimmed, "regalloc")) result.regalloc = true;
            if (std.mem.eql(u8, trimmed, "codegen")) result.codegen = true;
            if (std.mem.eql(u8, trimmed, "strings")) result.strings = true;
        }
        return result;
    }

    fn isEnabled(self: DebugPhases, phase: Phase) bool {
        if (self.all) return true;
        return switch (phase) {
            .parse => self.parse,
            .check => self.check,
            .lower => self.lower,
            .ssa => self.ssa,
            .regalloc => self.regalloc,
            .codegen => self.codegen,
            .strings => self.strings,
        };
    }
};

pub const Phase = enum {
    parse,
    check,
    lower,
    ssa,
    regalloc,
    codegen,
    strings, // String literal handling through the pipeline
};

// ============================================================================
// Global Debug State
// Go reference: s.f.pass.debug in regalloc.go
//
// This provides a simple way for passes to check debug levels without
// threading PipelineDebug through every function. Initialized once from
// COT_DEBUG environment variable.
// ============================================================================

var global_phases: ?DebugPhases = null;

/// Initialize global debug state. Call once at startup.
pub fn initGlobal() void {
    global_phases = DebugPhases.fromEnv();
}

/// Check if a phase has debug output enabled.
/// Returns false if not initialized.
pub fn isEnabled(phase: Phase) bool {
    const phases = global_phases orelse return false;
    return phases.isEnabled(phase);
}

/// Log a message if the phase is enabled.
/// Usage: debug.log(.regalloc, "spilling v{d} to stack", .{v.id});
pub fn log(phase: Phase, comptime fmt: []const u8, args: anytype) void {
    if (!isEnabled(phase)) return;
    std.debug.print("[{s}] " ++ fmt ++ "\n", .{@tagName(phase)} ++ args);
}

/// Log without phase prefix (for continuation lines).
pub fn logRaw(phase: Phase, comptime fmt: []const u8, args: anytype) void {
    if (!isEnabled(phase)) return;
    std.debug.print(fmt, args);
}

/// Pipeline debugger - outputs intermediate representations after each phase.
/// Go reference: f.Logf() and printFunc() in compile.go
pub const PipelineDebug = struct {
    allocator: Allocator,
    phases: DebugPhases,

    pub fn init(allocator: Allocator) PipelineDebug {
        return .{
            .allocator = allocator,
            .phases = DebugPhases.fromEnv(),
        };
    }

    /// Log output after parsing phase.
    pub fn afterParse(self: *PipelineDebug, tree: *const ast_mod.Ast) void {
        if (!self.phases.isEnabled(.parse)) return;

        std.debug.print("\n=== AFTER PARSE ===\n", .{});
        dumpAST(tree);
    }

    /// Log output after type checking phase.
    pub fn afterCheck(self: *PipelineDebug, tree: *const ast_mod.Ast) void {
        if (!self.phases.isEnabled(.check)) return;

        std.debug.print("\n=== AFTER CHECK ===\n", .{});
        // AST is same but now has type annotations
        dumpAST(tree);
    }

    /// Log output after lowering to IR.
    pub fn afterLower(self: *PipelineDebug, ir_result: *const ir_mod.IR) void {
        if (!self.phases.isEnabled(.lower)) return;

        std.debug.print("\n=== AFTER LOWER ===\n", .{});
        dumpIR(ir_result);
    }

    /// Log output after SSA pass (build, regalloc, etc).
    pub fn afterSSA(self: *PipelineDebug, func: *const ssa_func_mod.Func, pass_name: []const u8) void {
        const phase: Phase = if (std.mem.eql(u8, pass_name, "regalloc")) .regalloc else .ssa;
        if (!self.phases.isEnabled(phase)) return;

        std.debug.print("\n=== AFTER SSA PASS: {s} ===\n", .{pass_name});

        // Use our existing SSA debug dumper
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(self.allocator);
        ssa_debug.dumpText(func, buf.writer(self.allocator)) catch return;
        std.debug.print("{s}\n", .{buf.items});
    }
};

// ============================================================================
// Dump Helpers
// ============================================================================

fn dumpAST(tree: *const ast_mod.Ast) void {
    std.debug.print("AST: {} nodes\n", .{tree.nodes.items.len});

    // Count different node types and dump key information
    var decl_count: usize = 0;
    var expr_count: usize = 0;
    var stmt_count: usize = 0;

    for (tree.nodes.items, 0..) |node, i| {
        switch (node) {
            .decl => |decl| {
                decl_count += 1;
                switch (decl) {
                    .fn_decl => |fn_d| {
                        std.debug.print("  node[{}]: fn_decl '{s}' params={}\n", .{ i, fn_d.name, fn_d.params.len });
                    },
                    else => {
                        std.debug.print("  node[{}]: decl.{s}\n", .{ i, @tagName(decl) });
                    },
                }
            },
            .expr => |expr| {
                expr_count += 1;
                switch (expr) {
                    .literal => |lit| {
                        std.debug.print("  node[{}]: literal kind={s} value='{s}'\n", .{ i, @tagName(lit.kind), lit.value });
                    },
                    .binary => |bin| {
                        std.debug.print("  node[{}]: binary op={s} left={} right={}\n", .{ i, @tagName(bin.op), bin.left, bin.right });
                    },
                    .ident => |id| {
                        std.debug.print("  node[{}]: ident name='{s}'\n", .{ i, id.name });
                    },
                    else => {
                        std.debug.print("  node[{}]: expr.{s}\n", .{ i, @tagName(expr) });
                    },
                }
            },
            .stmt => |stmt| {
                stmt_count += 1;
                switch (stmt) {
                    .return_stmt => |ret| {
                        std.debug.print("  node[{}]: return value={}\n", .{ i, ret.value });
                    },
                    else => {
                        std.debug.print("  node[{}]: stmt.{s}\n", .{ i, @tagName(stmt) });
                    },
                }
            },
        }
    }

    std.debug.print("  Summary: {} decls, {} exprs, {} stmts\n", .{ decl_count, expr_count, stmt_count });
}

fn dumpIR(ir_result: *const ir_mod.IR) void {
    for (ir_result.funcs, 0..) |*func, fi| {
        std.debug.print("func[{}] {s}:\n", .{ fi, func.name });

        for (func.blocks, 0..) |block, bi| {
            std.debug.print("  block[{}]:\n", .{bi});

            for (block.nodes) |node_idx| {
                const node = func.getNode(node_idx);
                std.debug.print("    n{}: ", .{node_idx});

                switch (node.data) {
                    .const_int => |c| std.debug.print("const_int {}\n", .{c.value}),
                    .const_float => |c| std.debug.print("const_float {}\n", .{c.value}),
                    .const_bool => |c| std.debug.print("const_bool {}\n", .{c.value}),
                    .binary => |b| std.debug.print("binary {s} n{} n{}\n", .{ @tagName(b.op), b.left, b.right }),
                    .unary => |u| std.debug.print("unary {s} n{}\n", .{ @tagName(u.op), u.operand }),
                    .load_local => |l| std.debug.print("load_local {}\n", .{l.local_idx}),
                    .store_local => |s| std.debug.print("store_local {} = n{}\n", .{ s.local_idx, s.value }),
                    .ret => |r| {
                        if (r.value) |v| {
                            std.debug.print("ret n{}\n", .{v});
                        } else {
                            std.debug.print("ret void\n", .{});
                        }
                    },
                    else => std.debug.print("{s}\n", .{@tagName(node.data)}),
                }
            }
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "DebugPhases.parseStr" {
    const phases = DebugPhases.parseStr("parse,ssa,regalloc");
    try std.testing.expect(phases.parse);
    try std.testing.expect(!phases.check);
    try std.testing.expect(!phases.lower);
    try std.testing.expect(phases.ssa);
    try std.testing.expect(phases.regalloc);
}

test "DebugPhases.all" {
    const phases = DebugPhases.parseStr("all");
    try std.testing.expect(phases.isEnabled(.parse));
    try std.testing.expect(phases.isEnabled(.check));
    try std.testing.expect(phases.isEnabled(.lower));
    try std.testing.expect(phases.isEnabled(.ssa));
    try std.testing.expect(phases.isEnabled(.regalloc));
}

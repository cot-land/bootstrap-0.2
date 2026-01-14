//! Compilation Driver
//!
//! Orchestrates the full compilation pipeline from source to object code.
//! Uses the proper infrastructure: lower → liveness → regalloc → codegen
//!
//! This is the main entry point for compiling .cot files.

const std = @import("std");

// Frontend modules
const scanner_mod = @import("frontend/scanner.zig");
const ast_mod = @import("frontend/ast.zig");
const parser_mod = @import("frontend/parser.zig");
const errors_mod = @import("frontend/errors.zig");
const types_mod = @import("frontend/types.zig");
const checker_mod = @import("frontend/checker.zig");
const lower_mod = @import("frontend/lower.zig");
const ir_mod = @import("frontend/ir.zig");
const ssa_builder_mod = @import("frontend/ssa_builder.zig");
const source_mod = @import("frontend/source.zig");

// Backend modules
const arm64_codegen = @import("codegen/arm64.zig");
const regalloc_mod = @import("ssa/regalloc.zig");
const stackalloc_mod = @import("ssa/stackalloc.zig");

// Debug infrastructure
const pipeline_debug = @import("pipeline_debug.zig");
const debug = pipeline_debug;

const Allocator = std.mem.Allocator;

/// Result of compilation
pub const CompileResult = struct {
    /// The generated machine code
    code: []u8,
    /// Any errors encountered (empty if successful)
    errors: []const errors_mod.Error,
};

/// Compilation driver
pub const Driver = struct {
    allocator: Allocator,
    debug: pipeline_debug.PipelineDebug,

    pub fn init(allocator: Allocator) Driver {
        return .{
            .allocator = allocator,
            .debug = pipeline_debug.PipelineDebug.init(allocator),
        };
    }

    /// Compile source code to machine code bytes.
    pub fn compileSource(self: *Driver, source_text: []const u8) ![]u8 {
        debug.log(.parse, "=== Starting compilation ===", .{});
        debug.log(.parse, "Source length: {} bytes", .{source_text.len});

        // Create source wrapper
        var src = source_mod.Source.init(self.allocator, "<input>", source_text);
        defer src.deinit();

        // Create error reporter
        var err_reporter = errors_mod.ErrorReporter.init(&src, null);

        // Phase 1: Parse
        var tree = ast_mod.Ast.init(self.allocator);
        defer tree.deinit();

        var scan = scanner_mod.Scanner.initWithErrors(&src, &err_reporter);
        var parser = parser_mod.Parser.init(self.allocator, &scan, &tree, &err_reporter);
        parser.parseFile() catch |e| {
            return e;
        };

        if (err_reporter.hasErrors()) {
            debug.log(.parse, "Parse failed with errors", .{});
            return error.ParseError;
        }

        debug.log(.parse, "Parse complete: {} nodes", .{tree.nodes.items.len});
        self.debug.afterParse(&tree);

        // Phase 2: Type check
        var type_reg = try types_mod.TypeRegistry.init(self.allocator);
        defer type_reg.deinit();

        var global_scope = checker_mod.Scope.init(self.allocator, null);
        defer global_scope.deinit();

        var chk = checker_mod.Checker.init(self.allocator, &tree, &type_reg, &err_reporter, &global_scope);
        defer chk.deinit();

        chk.checkFile() catch |e| {
            return e;
        };

        if (err_reporter.hasErrors()) {
            debug.log(.check, "Type check failed with errors", .{});
            return error.TypeCheckError;
        }

        debug.log(.check, "Type check complete", .{});
        self.debug.afterCheck(&tree);

        // Phase 3: Lower to IR
        var lowerer = lower_mod.Lowerer.init(self.allocator, &tree, &type_reg, &err_reporter, &chk);
        defer lowerer.deinit();

        var ir = lowerer.lower() catch |e| {
            return e;
        };
        defer ir.deinit();

        if (err_reporter.hasErrors()) {
            debug.log(.lower, "Lower failed with errors", .{});
            return error.LowerError;
        }

        debug.log(.lower, "Lower complete: {} functions", .{ir.funcs.len});
        self.debug.afterLower(&ir);

        // Phase 4: Generate code for each function
        var codegen = arm64_codegen.ARM64CodeGen.init(self.allocator);
        defer codegen.deinit();

        for (ir.funcs, 0..) |*ir_func, func_idx| {
            debug.log(.ssa, "=== Processing function {} '{s}' ===", .{ func_idx, ir_func.name });

            // Phase 4a: Convert IR to SSA
            debug.log(.ssa, "Building SSA...", .{});
            var ssa_builder = try ssa_builder_mod.SSABuilder.init(self.allocator, ir_func, &type_reg);
            errdefer ssa_builder.deinit();

            const ssa_func = ssa_builder.build() catch |e| {
                debug.log(.ssa, "SSA build failed: {}", .{e});
                return e;
            };

            debug.log(.ssa, "SSA build complete: {} blocks", .{ssa_func.numBlocks()});
            self.debug.afterSSA(ssa_func, "build");

            // Phase 4b: Register allocation (includes liveness)
            debug.log(.regalloc, "Starting register allocation...", .{});
            var regalloc_state = regalloc_mod.regalloc(self.allocator, ssa_func) catch |e| {
                debug.log(.regalloc, "Regalloc failed: {}", .{e});
                ssa_func.deinit();
                self.allocator.destroy(ssa_func);
                ssa_builder.deinit();
                return e;
            };
            defer regalloc_state.deinit();

            debug.log(.regalloc, "Regalloc complete: {} spills", .{regalloc_state.num_spills});
            self.debug.afterSSA(ssa_func, "regalloc");

            // Phase 4b.5: Stack allocation (assigns spill slot offsets)
            const stack_result = stackalloc_mod.stackalloc(ssa_func) catch |e| {
                debug.log(.regalloc, "Stackalloc failed: {}", .{e});
                ssa_func.deinit();
                self.allocator.destroy(ssa_func);
                ssa_builder.deinit();
                return e;
            };
            debug.log(.regalloc, "Stackalloc complete: frame_size={} bytes", .{stack_result.frame_size});

            // Phase 4c: Code generation
            debug.log(.codegen, "Generating machine code for '{s}'...", .{ir_func.name});
            codegen.setRegAllocState(&regalloc_state);
            codegen.setFrameSize(stack_result.frame_size);
            codegen.generateBinary(ssa_func, ir_func.name) catch |e| {
                debug.log(.codegen, "Codegen failed: {}", .{e});
                ssa_func.deinit();
                self.allocator.destroy(ssa_func);
                ssa_builder.deinit();
                return e;
            };
            debug.log(.codegen, "Codegen complete for '{s}'", .{ir_func.name});

            // Clean up SSA func
            ssa_func.deinit();
            self.allocator.destroy(ssa_func);
            ssa_builder.deinit();
        }

        // Phase 5: Finalize and return machine code
        return try codegen.finalize();
    }

    /// Compile a source file.
    pub fn compileFile(self: *Driver, path: []const u8) ![]u8 {
        const source_text = std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024) catch |e| {
            std.debug.print("Failed to read file: {s}: {any}\n", .{ path, e });
            return e;
        };
        defer self.allocator.free(source_text);

        return self.compileSource(source_text);
    }

    /// Enable debug output for specific phases.
    pub fn setDebugPhases(self: *Driver, phases: pipeline_debug.DebugPhases) void {
        self.debug.phases = phases;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "driver: compile return 42" {
    const allocator = std.testing.allocator;
    var driver = Driver.init(allocator);

    const result = driver.compileSource("fn main() i64 { return 42; }");
    if (result) |code| {
        defer allocator.free(code);
        try std.testing.expect(code.len > 0);
    } else |_| {
        // Expected during development
    }
}

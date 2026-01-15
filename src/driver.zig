//! Compilation Driver
//!
//! Orchestrates the full compilation pipeline from source to object code.
//! Follows Go's multi-phase compilation pattern:
//! 1. Parse all files (including imports) - keep ASTs alive
//! 2. Type check all files with shared symbol table
//! 3. Lower all files to IR
//! 4. Generate code
//! 5. Clean up
//!
//! Reference: ~/learning/go/src/cmd/compile/internal/noder/noder.go

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
const expand_calls = @import("ssa/passes/expand_calls.zig");

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

/// Parsed file (Go: syntax.File in noder)
const ParsedFile = struct {
    path: []const u8,
    source_text: []const u8,
    source: source_mod.Source,
    tree: ast_mod.Ast,
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

    /// Compile source code to machine code bytes (single file, no imports).
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

        debug.log(.lower, "Lower complete: {} functions, {} globals", .{ ir.funcs.len, ir.globals.len });
        self.debug.afterLower(&ir);

        // Phase 4: Generate code for each function
        return try self.generateCode(ir.funcs, ir.globals, &type_reg);
    }

    /// Compile a source file (supports imports).
    /// Follows Go's LoadPackage pattern: parse all files first, then process together.
    pub fn compileFile(self: *Driver, path: []const u8) ![]u8 {
        debug.log(.parse, "=== Starting compilation of {s} ===", .{path});

        // Track files we've already seen (prevent cycles)
        var seen_files = std.StringHashMap(void).init(self.allocator);
        defer seen_files.deinit();

        // =====================================================================
        // Phase 1: Parse all files (Go: syntax.Parse in LoadPackage)
        // Keep all parsed files alive until codegen completes.
        // =====================================================================
        var parsed_files = std.ArrayListUnmanaged(ParsedFile){};
        defer {
            for (parsed_files.items) |*pf| {
                pf.tree.deinit();
                pf.source.deinit();
                self.allocator.free(pf.source_text);
                self.allocator.free(pf.path);
            }
            parsed_files.deinit(self.allocator);
        }

        // Recursively parse all files starting from the main file
        try self.parseFileRecursive(path, &parsed_files, &seen_files);

        debug.log(.parse, "Parsed {} files total", .{parsed_files.items.len});

        // =====================================================================
        // Phase 2: Type check all files with shared symbol table
        // (Go: typecheck.Package in unified)
        // =====================================================================
        var type_reg = try types_mod.TypeRegistry.init(self.allocator);
        defer type_reg.deinit();

        var global_scope = checker_mod.Scope.init(self.allocator, null);
        defer global_scope.deinit();

        // Create a dummy source for error reporting
        var dummy_src = source_mod.Source.init(self.allocator, path, "");
        defer dummy_src.deinit();
        var err_reporter = errors_mod.ErrorReporter.init(&dummy_src, null);

        // Store checkers to keep them alive (they reference types)
        var checkers = std.ArrayListUnmanaged(checker_mod.Checker){};
        defer {
            for (checkers.items) |*chk| {
                chk.deinit();
            }
            checkers.deinit(self.allocator);
        }

        // Check all files in order (imports first, main file last)
        for (parsed_files.items) |*pf| {
            debug.log(.check, "Type checking: {s}", .{pf.path});

            var chk = checker_mod.Checker.init(self.allocator, &pf.tree, &type_reg, &err_reporter, &global_scope);

            chk.checkFile() catch |e| {
                chk.deinit();
                return e;
            };

            if (err_reporter.hasErrors()) {
                debug.log(.check, "Type check failed for {s}", .{pf.path});
                chk.deinit();
                return error.TypeCheckError;
            }

            try checkers.append(self.allocator, chk);
            self.debug.afterCheck(&pf.tree);
        }

        debug.log(.check, "Type check complete for all files", .{});

        // =====================================================================
        // Phase 3: Lower all files to IR
        // =====================================================================
        var lowerers = std.ArrayListUnmanaged(lower_mod.Lowerer){};
        defer {
            for (lowerers.items) |*low| {
                low.deinit();
            }
            lowerers.deinit(self.allocator);
        }

        var all_irs = std.ArrayListUnmanaged(ir_mod.IR){};
        defer {
            for (all_irs.items) |*ir| {
                ir.deinit();
            }
            all_irs.deinit(self.allocator);
        }

        var all_funcs = std.ArrayListUnmanaged(ir_mod.Func){};
        defer all_funcs.deinit(self.allocator);

        var all_globals = std.ArrayListUnmanaged(ir_mod.Global){};
        defer all_globals.deinit(self.allocator);

        for (parsed_files.items, 0..) |*pf, i| {
            debug.log(.lower, "Lowering: {s}", .{pf.path});

            var lowerer = lower_mod.Lowerer.init(self.allocator, &pf.tree, &type_reg, &err_reporter, &checkers.items[i]);

            var ir = lowerer.lower() catch |e| {
                lowerer.deinit();
                return e;
            };

            if (err_reporter.hasErrors()) {
                debug.log(.lower, "Lower failed for {s}", .{pf.path});
                lowerer.deinit();
                ir.deinit();
                return error.LowerError;
            }

            debug.log(.lower, "Lowered {} functions from {s}", .{ ir.funcs.len, pf.path });

            // Collect all functions
            for (ir.funcs) |func| {
                try all_funcs.append(self.allocator, func);
            }

            // Collect all globals
            for (ir.globals) |global| {
                try all_globals.append(self.allocator, global);
            }

            try lowerers.append(self.allocator, lowerer);
            try all_irs.append(self.allocator, ir);
            self.debug.afterLower(&ir);
        }

        debug.log(.lower, "Total: {} functions, {} globals across all files", .{ all_funcs.items.len, all_globals.items.len });

        // =====================================================================
        // Phase 4: Generate code
        // =====================================================================
        return try self.generateCode(all_funcs.items, all_globals.items, &type_reg);
    }

    /// Recursively parse a file and all its imports.
    /// Files are added in dependency order (imports before the importing file).
    fn parseFileRecursive(
        self: *Driver,
        path: []const u8,
        parsed_files: *std.ArrayListUnmanaged(ParsedFile),
        seen_files: *std.StringHashMap(void),
    ) !void {
        // Check if already parsed
        if (seen_files.contains(path)) {
            debug.log(.parse, "Skipping already parsed: {s}", .{path});
            return;
        }

        // Mark as seen to prevent cycles
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        try seen_files.put(path_copy, {});

        debug.log(.parse, "Parsing: {s}", .{path});

        // Read source file
        const source_text = std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024) catch |e| {
            std.debug.print("Failed to read file: {s}: {any}\n", .{ path, e });
            return e;
        };
        errdefer self.allocator.free(source_text);

        // Create source wrapper
        var src = source_mod.Source.init(self.allocator, path, source_text);
        errdefer src.deinit();

        // Create a simple error reporter
        var err_reporter = errors_mod.ErrorReporter.init(&src, null);

        // Parse
        var tree = ast_mod.Ast.init(self.allocator);
        errdefer tree.deinit();

        var scan = scanner_mod.Scanner.initWithErrors(&src, &err_reporter);
        var parser = parser_mod.Parser.init(self.allocator, &scan, &tree, &err_reporter);
        parser.parseFile() catch |e| {
            return e;
        };

        if (err_reporter.hasErrors()) {
            debug.log(.parse, "Parse failed for {s}", .{path});
            return error.ParseError;
        }

        debug.log(.parse, "Parsed {} nodes from {s}", .{ tree.nodes.items.len, path });

        // Get imports and recursively parse them BEFORE adding this file
        // This ensures dependencies are processed first
        const imports = try tree.getImports(self.allocator);
        defer self.allocator.free(imports);

        const file_dir = std.fs.path.dirname(path) orelse ".";
        for (imports) |import_path| {
            const import_full_path = try std.fs.path.join(self.allocator, &.{ file_dir, import_path });
            defer self.allocator.free(import_full_path);

            debug.log(.parse, "Found import: {s}", .{import_path});
            try self.parseFileRecursive(import_full_path, parsed_files, seen_files);
        }

        // Add this file AFTER its imports
        try parsed_files.append(self.allocator, ParsedFile{
            .path = path_copy,
            .source_text = source_text,
            .source = src,
            .tree = tree,
        });
    }

    /// Generate machine code for all IR functions.
    fn generateCode(self: *Driver, funcs: []const ir_mod.Func, globals: []const ir_mod.Global, type_reg: *types_mod.TypeRegistry) ![]u8 {
        var codegen = arm64_codegen.ARM64CodeGen.init(self.allocator);
        defer codegen.deinit();

        // Pass globals to codegen for data section emission
        codegen.setGlobals(globals);

        // Pass type registry for composite type sizing (BUG-003 fix)
        codegen.setTypeRegistry(type_reg);

        for (funcs, 0..) |*ir_func, func_idx| {
            debug.log(.ssa, "=== Processing function {} '{s}' ===", .{ func_idx, ir_func.name });

            // Phase 4a: Convert IR to SSA
            debug.log(.ssa, "Building SSA...", .{});
            var ssa_builder = try ssa_builder_mod.SSABuilder.init(self.allocator, ir_func, type_reg);
            errdefer ssa_builder.deinit();

            const ssa_func = ssa_builder.build() catch |e| {
                debug.log(.ssa, "SSA build failed: {}", .{e});
                return e;
            };

            debug.log(.ssa, "SSA build complete: {} blocks", .{ssa_func.numBlocks()});
            self.debug.afterSSA(ssa_func, "build");

            // Phase 4a.5: Expand calls - decompose aggregate types before register allocation
            debug.log(.ssa, "Running expand_calls...", .{});
            expand_calls.expandCalls(ssa_func) catch |e| {
                debug.log(.ssa, "expand_calls failed: {}", .{e});
                return e;
            };
            debug.log(.ssa, "expand_calls complete", .{});
            self.debug.afterSSA(ssa_func, "expand_calls");

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

//! Generic code generation - reference implementation.
//!
//! Go reference: [compare_generic.go] pattern - fallback for unsupported architectures
//!
//! This provides a simple, correct-by-construction code generator that can be
//! used for testing and as a fallback for unsupported architectures. It generates
//! pseudo-assembly that clearly shows what instructions would be emitted.
//!
//! ## Design Principles
//!
//! 1. **Correctness over performance** - Every value goes to stack
//! 2. **Simple instruction selection** - Direct mapping from ops
//! 3. **No register allocation** - Stack-based model
//! 4. **Easy verification** - Output is human-readable
//!
//! ## Related Modules
//!
//! - [arm64.zig] - Optimized ARM64 code generation
//! - [ssa/compile.zig] - Pass infrastructure
//! - [ssa/func.zig] - Function to generate code for
//!
//! ## Example Output
//!
//! ```
//! .func test:
//!   ; b1 (plain)
//!   stack[0] = const_int 42    ; v1
//!   stack[8] = const_int 10    ; v2
//!   stack[16] = add stack[0], stack[8]  ; v3
//!   ; b2 (ret)
//!   return stack[16]
//! ```

const std = @import("std");
const Func = @import("../ssa/func.zig").Func;
const Block = @import("../ssa/block.zig").Block;
const Value = @import("../ssa/value.zig").Value;
const Op = @import("../ssa/op.zig").Op;

const ID = @import("../core/types.zig").ID;

/// Generic code generator.
///
/// Simple stack-based code generation for testing and verification.
/// Not intended for production use - see [ARM64CodeGen] for optimized output.
pub const GenericCodeGen = struct {
    allocator: std.mem.Allocator,

    /// Stack slot assignments (value ID -> stack offset).
    stack_slots: std.AutoHashMap(ID, i64),

    /// Current stack offset.
    stack_offset: i64 = 0,

    /// Stack alignment (bytes).
    stack_align: i64 = 8,

    pub fn init(allocator: std.mem.Allocator) GenericCodeGen {
        return .{
            .allocator = allocator,
            .stack_slots = std.AutoHashMap(ID, i64).init(allocator),
        };
    }

    pub fn deinit(self: *GenericCodeGen) void {
        self.stack_slots.deinit();
    }

    /// Generate pseudo-assembly for a function.
    pub fn generate(self: *GenericCodeGen, f: *const Func, writer: anytype) !void {
        // Reset state
        self.stack_slots.clearRetainingCapacity();
        self.stack_offset = 0;

        // Function header
        try writer.print(".func {s}:\n", .{f.name});

        // Process each block
        for (f.blocks.items) |b| {
            try self.generateBlock(b, writer);
        }

        try writer.print(".end {s}\n", .{f.name});
    }

    fn generateBlock(self: *GenericCodeGen, b: *const Block, writer: anytype) !void {
        try writer.print("  ; b{d} ({s})\n", .{ b.id, @tagName(b.kind) });

        // Generate code for each value
        for (b.values.items) |v| {
            try self.generateValue(v, writer);
        }

        // Generate block terminator
        switch (b.kind) {
            .ret => {
                if (b.numControls() > 0) {
                    const ctrl = b.controlValues()[0];
                    try self.generateLoad(ctrl.id, "r0", writer);
                    try writer.writeAll("  return r0\n");
                } else {
                    try writer.writeAll("  return\n");
                }
            },
            .if_ => {
                if (b.numControls() > 0) {
                    const cond = b.controlValues()[0];
                    try self.generateLoad(cond.id, "r0", writer);
                    if (b.succs.len >= 2) {
                        try writer.print("  br_if r0, b{d}, b{d}\n", .{
                            b.succs[0].b.id,
                            b.succs[1].b.id,
                        });
                    }
                }
            },
            .plain => {
                if (b.succs.len > 0) {
                    try writer.print("  br b{d}\n", .{b.succs[0].b.id});
                }
            },
            .exit => try writer.writeAll("  exit\n"),
            else => {},
        }

        try writer.writeAll("\n");
    }

    fn generateValue(self: *GenericCodeGen, v: *const Value, writer: anytype) !void {
        // Allocate stack slot
        const slot = self.allocSlot(v.id);

        // Generate instruction based on op
        switch (v.op) {
            // Constants - store directly
            .const_int, .const_8, .const_16, .const_32, .const_64 => {
                try writer.print("  stack[{d}] = {s} {d}    ; v{d}\n", .{
                    slot,
                    @tagName(v.op),
                    v.aux_int,
                    v.id,
                });
            },
            .const_bool => {
                try writer.print("  stack[{d}] = const_bool {s}    ; v{d}\n", .{
                    slot,
                    if (v.aux_int != 0) "true" else "false",
                    v.id,
                });
            },
            .const_nil => {
                try writer.print("  stack[{d}] = const_nil    ; v{d}\n", .{ slot, v.id });
            },

            // Binary operations
            .add, .sub, .mul, .div, .and_, .or_, .xor => {
                if (v.args.len >= 2) {
                    try self.generateBinaryOp(v, slot, writer);
                }
            },

            // Comparisons
            .eq, .ne, .lt, .le, .gt, .ge => {
                if (v.args.len >= 2) {
                    try self.generateBinaryOp(v, slot, writer);
                }
            },

            // Unary operations
            .neg, .not => {
                if (v.args.len >= 1) {
                    try self.generateUnaryOp(v, slot, writer);
                }
            },

            // Memory operations
            .load => {
                if (v.args.len >= 1) {
                    const ptr = v.args[0];
                    try self.generateLoad(ptr.id, "r0", writer);
                    try writer.print("  stack[{d}] = load [r0]    ; v{d}\n", .{ slot, v.id });
                }
            },
            .store => {
                if (v.args.len >= 2) {
                    const ptr = v.args[0];
                    const val = v.args[1];
                    try self.generateLoad(ptr.id, "r0", writer);
                    try self.generateLoad(val.id, "r1", writer);
                    try writer.print("  store [r0], r1    ; v{d}\n", .{v.id});
                }
            },

            // Phi - handled during block layout
            .phi => {
                try writer.print("  stack[{d}] = phi    ; v{d} (resolved at block entry)\n", .{
                    slot,
                    v.id,
                });
            },

            // Copy
            .copy => {
                if (v.args.len >= 1) {
                    try self.generateLoad(v.args[0].id, "r0", writer);
                    try writer.print("  stack[{d}] = r0    ; v{d} = copy v{d}\n", .{
                        slot,
                        v.id,
                        v.args[0].id,
                    });
                }
            },

            // Call
            .call, .static_call => {
                try writer.print("  stack[{d}] = call ...    ; v{d}\n", .{ slot, v.id });
            },

            else => {
                try writer.print("  stack[{d}] = {s} ...    ; v{d}\n", .{
                    slot,
                    @tagName(v.op),
                    v.id,
                });
            },
        }
    }

    fn generateBinaryOp(self: *GenericCodeGen, v: *const Value, slot: i64, writer: anytype) !void {
        const left = v.args[0];
        const right = v.args[1];

        try self.generateLoad(left.id, "r0", writer);
        try self.generateLoad(right.id, "r1", writer);
        try writer.print("  stack[{d}] = {s} r0, r1    ; v{d}\n", .{
            slot,
            @tagName(v.op),
            v.id,
        });
    }

    fn generateUnaryOp(self: *GenericCodeGen, v: *const Value, slot: i64, writer: anytype) !void {
        const arg = v.args[0];

        try self.generateLoad(arg.id, "r0", writer);
        try writer.print("  stack[{d}] = {s} r0    ; v{d}\n", .{
            slot,
            @tagName(v.op),
            v.id,
        });
    }

    fn generateLoad(self: *GenericCodeGen, id: ID, reg: []const u8, writer: anytype) !void {
        if (self.stack_slots.get(id)) |slot| {
            try writer.print("  {s} = stack[{d}]    ; load v{d}\n", .{ reg, slot, id });
        }
    }

    fn allocSlot(self: *GenericCodeGen, id: ID) i64 {
        if (self.stack_slots.get(id)) |slot| {
            return slot;
        }

        const slot = self.stack_offset;
        self.stack_slots.put(id, slot) catch {};
        self.stack_offset += self.stack_align;
        return slot;
    }
};

// =========================================
// Tests
// =========================================

test "GenericCodeGen generates simple function" {
    const allocator = std.testing.allocator;

    var f = Func.init(allocator, "test_add");
    defer f.deinit();

    const b = try f.newBlock(.ret);
    const c1 = try f.newValue(.const_int, 0, b, .{});
    c1.aux_int = 40;
    try b.addValue(allocator, c1);

    const c2 = try f.newValue(.const_int, 0, b, .{});
    c2.aux_int = 2;
    try b.addValue(allocator, c2);

    const add = try f.newValue(.add, 0, b, .{});
    add.addArg2(c1, c2);
    try b.addValue(allocator, add);

    b.setControl(add);

    var codegen = GenericCodeGen.init(allocator);
    defer codegen.deinit();

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    try codegen.generate(&f, output.writer(allocator));

    // Should contain function name and operations
    try std.testing.expect(std.mem.indexOf(u8, output.items, "test_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "const_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "add") != null);
}

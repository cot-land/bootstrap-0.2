//! SSA Basic Block representation.
//!
//! Go reference: [cmd/compile/internal/ssa/block.go]
//!
//! A Block represents a basic block in the control flow graph.
//! Each block contains a list of [Value]s and has edges to successor blocks.
//!
//! ## Critical Invariants
//!
//! **Bidirectional edges**: Each edge maintains a back-reference so that
//! CFG modifications are O(1). The invariant is:
//!
//! ```
//! b.succs[i] = {target, j} ⟺ target.preds[j] = {b, i}
//! ```
//!
//! Always use [Block.addEdgeTo] and [Block.removeEdgeTo] to modify edges!
//!
//! ## Related Modules
//!
//! - [Value] - Instructions contained in blocks
//! - [Func] - Contains all blocks in a function
//! - [BlockKind] - Determines control flow semantics
//! - [dom.zig] - Dominator tree computation over blocks
//!
//! ## Example
//!
//! ```zig
//! // Create an if-else diamond
//! const entry = try func.newBlock(.if_);
//! const then_block = try func.newBlock(.plain);
//! const else_block = try func.newBlock(.plain);
//! const merge = try func.newBlock(.ret);
//!
//! try entry.addEdgeTo(allocator, then_block);  // True branch
//! try entry.addEdgeTo(allocator, else_block);  // False branch
//! try then_block.addEdgeTo(allocator, merge);
//! try else_block.addEdgeTo(allocator, merge);
//! ```

const std = @import("std");
const types = @import("../core/types.zig");
const Value = @import("value.zig").Value;

const ID = types.ID;
const Pos = types.Pos;
const INVALID_ID = types.INVALID_ID;

/// Block kind - determines control flow semantics.
/// Go reference: cmd/compile/internal/ssa/block.go BlockKind
pub const BlockKind = enum(u8) {
    invalid,

    /// Unconditional jump to single successor
    plain,

    /// Conditional branch based on controls[0]
    /// Succs[0] = true branch, Succs[1] = false branch
    if_,

    /// Return from function
    ret,

    /// Function exit (panic, etc.)
    exit,

    /// Defer block - special handling for defer statements
    /// Go reference: BlockDefer
    defer_,

    /// First block marker (entry point)
    first,

    /// Switch/jump table (multiple successors)
    jump_table,

    // ARM64-specific block kinds
    arm64_cbz, // Compare and branch if zero
    arm64_cbnz, // Compare and branch if not zero
    arm64_tbz, // Test bit and branch if zero
    arm64_tbnz, // Test bit and branch if not zero

    // x86_64-specific block kinds
    x86_64_eq, // Jump if equal (ZF=1)
    x86_64_ne, // Jump if not equal (ZF=0)
    x86_64_lt, // Jump if less (SF!=OF)
    x86_64_le, // Jump if less or equal (ZF=1 or SF!=OF)
    x86_64_gt, // Jump if greater (ZF=0 and SF=OF)
    x86_64_ge, // Jump if greater or equal (SF=OF)
    x86_64_ult, // Jump if below (unsigned, CF=1)
    x86_64_ule, // Jump if below or equal (unsigned, CF=1 or ZF=1)
    x86_64_ugt, // Jump if above (unsigned, CF=0 and ZF=0)
    x86_64_uge, // Jump if above or equal (unsigned, CF=0)

    /// Returns the number of successors this block kind has.
    /// -1 means variable (e.g., jump_table).
    pub fn numSuccs(self: BlockKind) i8 {
        return switch (self) {
            .invalid => 0,
            .plain, .defer_, .first => 1,
            .if_, .arm64_cbz, .arm64_cbnz, .arm64_tbz, .arm64_tbnz => 2,
            .x86_64_eq, .x86_64_ne, .x86_64_lt, .x86_64_le => 2,
            .x86_64_gt, .x86_64_ge, .x86_64_ult, .x86_64_ule => 2,
            .x86_64_ugt, .x86_64_uge => 2,
            .ret, .exit => 0,
            .jump_table => -1, // Variable
        };
    }

    /// Returns the number of control values this block kind requires.
    pub fn numControls(self: BlockKind) u8 {
        return switch (self) {
            .invalid, .plain, .first, .exit => 0,
            .if_, .ret, .defer_ => 1,
            .arm64_cbz, .arm64_cbnz, .arm64_tbz, .arm64_tbnz => 1,
            .x86_64_eq, .x86_64_ne, .x86_64_lt, .x86_64_le => 0, // Use flags
            .x86_64_gt, .x86_64_ge, .x86_64_ult, .x86_64_ule => 0,
            .x86_64_ugt, .x86_64_uge => 0,
            .jump_table => 1,
        };
    }

    /// Is this a conditional branch?
    pub fn isConditional(self: BlockKind) bool {
        return switch (self) {
            .if_ => true,
            .arm64_cbz, .arm64_cbnz, .arm64_tbz, .arm64_tbnz => true,
            .x86_64_eq, .x86_64_ne, .x86_64_lt, .x86_64_le => true,
            .x86_64_gt, .x86_64_ge, .x86_64_ult, .x86_64_ule => true,
            .x86_64_ugt, .x86_64_uge => true,
            else => false,
        };
    }
};

/// CFG edge with bidirectional reference.
///
/// Maintains invariant: b.succs[i] = {target, j} ⟺ target.preds[j] = {b, i}
///
/// Go reference: cmd/compile/internal/ssa/block.go Edge type
pub const Edge = struct {
    /// Target block
    b: *Block,
    /// Index of reverse edge in target's preds/succs array
    i: usize,

    pub fn format(self: Edge, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("b{d}", .{self.b.id});
    }
};

/// Branch prediction hint.
pub const BranchPrediction = enum(i8) {
    unlikely = -1, // Succs[1] is likely
    unknown = 0,
    likely = 1, // Succs[0] is likely
};

/// Basic block in the control flow graph.
///
/// Go reference: cmd/compile/internal/ssa/block.go lines 15-65
pub const Block = struct {
    /// Unique ID within function
    id: ID = INVALID_ID,

    /// Block kind - determines control flow semantics
    kind: BlockKind = .invalid,

    /// Successor edges (CFG out-edges)
    succs: []Edge = &.{},

    /// Predecessor edges (CFG in-edges)
    preds: []Edge = &.{},

    /// Control values (up to 2)
    /// BlockIf: controls[0] = condition
    /// BlockRet: controls[0] = return value (optional)
    controls: [2]?*Value = .{ null, null },

    /// All values computed in this block.
    /// Unordered until schedule pass runs.
    values: std.ArrayListUnmanaged(*Value),

    /// Containing function
    func: *Func,

    /// Position of control statement (for error messages)
    pos: Pos = .{},

    /// Branch prediction hint
    likely: BranchPrediction = .unknown,

    /// Are CPU flags live at block end?
    /// Set by flagalloc pass.
    flags_live_at_end: bool = false,

    /// Inline storage for small edge lists
    succs_storage: [4]Edge = undefined,
    preds_storage: [4]Edge = undefined,

    /// For free list linking when block is recycled
    next_free: ?*Block = null,

    // =========================================
    // Methods
    // =========================================

    /// Initialize block
    pub fn init(id: ID, kind: BlockKind, func: *Func) Block {
        return .{
            .id = id,
            .kind = kind,
            .func = func,
            .values = .{},
        };
    }

    /// Deinitialize block
    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        self.values.deinit(allocator);
    }

    /// Number of non-nil control values
    pub fn numControls(self: *const Block) usize {
        if (self.controls[1] != null) return 2;
        if (self.controls[0] != null) return 1;
        return 0;
    }

    /// Get slice of control values
    pub fn controlValues(self: *const Block) []const *Value {
        const n = self.numControls();
        if (n == 0) return &.{};
        // Safe because controls[0..n] are guaranteed non-null
        const ptr: [*]const *Value = @ptrCast(&self.controls);
        return ptr[0..n];
    }

    /// Set single control value, handling use counts
    pub fn setControl(self: *Block, v: *Value) void {
        // Decrement old use counts
        if (self.controls[0]) |old| old.uses -= 1;
        if (self.controls[1]) |old| old.uses -= 1;

        // Set new control
        self.controls[0] = v;
        self.controls[1] = null;
        v.uses += 1;
    }

    /// Add control value (for blocks with 2 controls)
    pub fn addControl(self: *Block, v: *Value) void {
        const n = self.numControls();
        if (n >= 2) @panic("block already has 2 controls");

        self.controls[n] = v;
        v.uses += 1;
    }

    /// Clear all control values
    pub fn resetControls(self: *Block) void {
        if (self.controls[0]) |v| v.uses -= 1;
        if (self.controls[1]) |v| v.uses -= 1;
        self.controls = .{ null, null };
    }

    /// Add edge to successor block.
    /// Maintains bidirectional invariant.
    pub fn addEdgeTo(self: *Block, allocator: std.mem.Allocator, succ: *Block) !void {
        const succ_pred_idx = succ.preds.len;
        const self_succ_idx = self.succs.len;

        // Create forward edge
        const fwd_edge = Edge{ .b = succ, .i = succ_pred_idx };

        // Create backward edge
        const bwd_edge = Edge{ .b = self, .i = self_succ_idx };

        // Add edges (use inline storage if possible)
        self.succs = try appendEdge(allocator, self.succs, &self.succs_storage, fwd_edge);
        succ.preds = try appendEdge(allocator, succ.preds, &succ.preds_storage, bwd_edge);
    }

    /// Remove edge to successor block.
    /// Maintains bidirectional invariant.
    pub fn removeEdgeTo(self: *Block, succ: *Block) void {
        // Find edge index
        for (self.succs, 0..) |edge, i| {
            if (edge.b == succ) {
                const pred_idx = edge.i;

                // Remove from both sides
                _ = removeEdgeAt(&self.succs, i);
                _ = removeEdgeAt(&succ.preds, pred_idx);

                // Update back-references for moved edges
                if (i < self.succs.len) {
                    // Edge at i was moved from end, update its target's back-ref
                    self.succs[i].b.preds[self.succs[i].i].i = i;
                }
                if (pred_idx < succ.preds.len) {
                    // Edge at pred_idx was moved from end, update its target's back-ref
                    succ.preds[pred_idx].b.succs[succ.preds[pred_idx].i].i = pred_idx;
                }
                return;
            }
        }
    }

    /// Add value to this block
    pub fn addValue(self: *Block, allocator: std.mem.Allocator, v: *Value) !void {
        v.block = self;
        try self.values.append(allocator, v);
    }

    /// Format for debugging
    pub fn format(
        self: *const Block,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("b{d} ({s})", .{ self.id, @tagName(self.kind) });

        if (self.succs.len > 0) {
            try writer.writeAll(" -> ");
            for (self.succs, 0..) |succ, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("b{d}", .{succ.b.id});
            }
        }
    }
};

/// Forward declaration for Func
pub const Func = @import("func.zig").Func;

// =========================================
// Helper functions
// =========================================

fn appendEdge(
    allocator: std.mem.Allocator,
    slice: []Edge,
    storage: *[4]Edge,
    edge: Edge,
) ![]Edge {
    const new_len = slice.len + 1;

    // Can use inline storage?
    if (new_len <= storage.len and slice.ptr == @as([*]Edge, storage)) {
        storage[slice.len] = edge;
        return storage[0..new_len];
    }

    // First use of inline storage?
    if (slice.len == 0 and new_len <= storage.len) {
        storage[0] = edge;
        return storage[0..1];
    }

    // Need dynamic allocation
    var new_slice = try allocator.alloc(Edge, new_len);
    @memcpy(new_slice[0..slice.len], slice);
    new_slice[slice.len] = edge;
    return new_slice;
}

fn removeEdgeAt(slice: *[]Edge, idx: usize) Edge {
    const removed = slice.*[idx];
    slice.*[idx] = slice.*[slice.len - 1];
    slice.len -= 1;
    return removed;
}

// =========================================
// Tests
// =========================================

test "Block creation" {
    const allocator = std.testing.allocator;
    var func: Func = undefined; // Minimal init for test

    var b = Block.init(1, .plain, &func);
    defer b.deinit(allocator);

    try std.testing.expectEqual(@as(ID, 1), b.id);
    try std.testing.expectEqual(BlockKind.plain, b.kind);
    try std.testing.expectEqual(@as(usize, 0), b.numControls());
}

test "Block control values" {
    const allocator = std.testing.allocator;
    var func: Func = undefined;

    var b = Block.init(1, .if_, &func);
    defer b.deinit(allocator);

    var v = Value.init(1, .const_bool, 0, &b, .{});

    b.setControl(&v);
    try std.testing.expectEqual(@as(usize, 1), b.numControls());
    try std.testing.expectEqual(@as(i32, 1), v.uses);

    b.resetControls();
    try std.testing.expectEqual(@as(usize, 0), b.numControls());
    try std.testing.expectEqual(@as(i32, 0), v.uses);
}

test "Block edge management" {
    const allocator = std.testing.allocator;
    var func: Func = undefined;

    var b1 = Block.init(1, .plain, &func);
    defer b1.deinit(allocator);
    var b2 = Block.init(2, .plain, &func);
    defer b2.deinit(allocator);

    // Add edge b1 -> b2
    try b1.addEdgeTo(allocator, &b2);

    try std.testing.expectEqual(@as(usize, 1), b1.succs.len);
    try std.testing.expectEqual(@as(usize, 1), b2.preds.len);
    try std.testing.expectEqual(&b2, b1.succs[0].b);
    try std.testing.expectEqual(&b1, b2.preds[0].b);

    // Verify bidirectional invariant
    try std.testing.expectEqual(@as(usize, 0), b1.succs[0].i);
    try std.testing.expectEqual(@as(usize, 0), b2.preds[0].i);
}

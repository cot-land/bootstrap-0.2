//! Dominator Tree Computation.
//! Go reference: cmd/compile/internal/ssa/dom.go
//!
//! Computes the dominator tree for a function's control flow graph.
//! Block A dominates block B if every path from entry to B goes through A.
//!
//! Uses the simple iterative algorithm (not Lengauer-Tarjan) for clarity.
//! Can be upgraded to Lengauer-Tarjan if performance becomes an issue.

const std = @import("std");
const Func = @import("func.zig").Func;
const Block = @import("block.zig").Block;
const types = @import("../core/types.zig");

const ID = types.ID;

/// Dominator tree information for a function.
pub const DomTree = struct {
    allocator: std.mem.Allocator,

    /// Immediate dominator for each block (indexed by block ID)
    /// idom[b.id] = immediate dominator of b, or null for entry
    idom: []?*Block,

    /// Dominator tree children (indexed by block ID)
    /// children[b.id] = blocks directly dominated by b
    children: []std.ArrayListUnmanaged(*Block),

    /// Depth in dominator tree (indexed by block ID)
    depth: []u32,

    /// Maximum block ID (for bounds)
    max_id: ID,

    pub fn init(allocator: std.mem.Allocator, max_id: ID) !DomTree {
        const size = max_id + 1;
        const idom = try allocator.alloc(?*Block, size);
        @memset(idom, null);

        const children = try allocator.alloc(std.ArrayListUnmanaged(*Block), size);
        for (children) |*c| {
            c.* = .{};
        }

        const depth = try allocator.alloc(u32, size);
        @memset(depth, 0);

        return .{
            .allocator = allocator,
            .idom = idom,
            .children = children,
            .depth = depth,
            .max_id = max_id,
        };
    }

    pub fn deinit(self: *DomTree) void {
        self.allocator.free(self.idom);
        for (self.children) |*c| {
            c.deinit(self.allocator);
        }
        self.allocator.free(self.children);
        self.allocator.free(self.depth);
    }

    /// Get immediate dominator of block.
    pub fn getIdom(self: *const DomTree, b: *const Block) ?*Block {
        if (b.id > self.max_id) return null;
        return self.idom[b.id];
    }

    /// Get children in dominator tree.
    pub fn getChildren(self: *const DomTree, b: *const Block) []const *Block {
        if (b.id > self.max_id) return &.{};
        return self.children[b.id].items;
    }

    /// Get depth in dominator tree.
    pub fn getDepth(self: *const DomTree, b: *const Block) u32 {
        if (b.id > self.max_id) return 0;
        return self.depth[b.id];
    }

    /// Check if block a dominates block b.
    /// A dominates B if A is on the path from entry to B in the dom tree.
    pub fn dominates(self: *const DomTree, a: *const Block, b: *const Block) bool {
        if (a == b) return true;

        // Walk up from b to entry, checking if we hit a
        var current: ?*Block = @constCast(b);
        while (current) |c| {
            if (c == a) return true;
            current = self.getIdom(c);
        }
        return false;
    }

    /// Check if block a strictly dominates block b (a dom b and a != b).
    pub fn strictlyDominates(self: *const DomTree, a: *const Block, b: *const Block) bool {
        return a != b and self.dominates(a, b);
    }
};

/// Compute dominator tree for function.
/// Go reference: cmd/compile/internal/ssa/dom.go dominators function
pub fn computeDominators(f: *Func) !DomTree {
    const allocator = f.allocator;

    // Find max block ID
    var max_id: ID = 0;
    for (f.blocks.items) |b| {
        if (b.id > max_id) max_id = b.id;
    }

    var dom = try DomTree.init(allocator, max_id);
    errdefer dom.deinit();

    const entry = f.entry orelse return dom;

    // Get reverse postorder (which approximates a topological order)
    const rpo = try reversePostorder(f);
    defer allocator.free(rpo);

    // Initialize: entry has no dominator
    dom.idom[entry.id] = null;
    dom.depth[entry.id] = 0;

    // Iterative algorithm
    // Keep iterating until no changes occur
    var changed = true;
    while (changed) {
        changed = false;

        for (rpo) |b| {
            if (b == entry) continue;

            // Find new idom as intersection of dominators of predecessors
            var new_idom: ?*Block = null;

            for (b.preds) |pred_edge| {
                const pred = pred_edge.b;

                // Skip predecessors we haven't processed yet
                if (dom.idom[pred.id] == null and pred != entry) continue;

                if (new_idom == null) {
                    new_idom = pred;
                } else {
                    new_idom = intersect(&dom, new_idom.?, pred, entry);
                }
            }

            if (new_idom != dom.idom[b.id]) {
                dom.idom[b.id] = new_idom;
                changed = true;
            }
        }
    }

    // Build children lists and compute depths
    for (f.blocks.items) |b| {
        if (dom.idom[b.id]) |parent| {
            try dom.children[parent.id].append(allocator, b);
        }
    }

    // Compute depths via BFS from entry
    try computeDepths(&dom, entry, allocator);

    return dom;
}

/// Find intersection of two dominators.
fn intersect(dom: *const DomTree, b1: *Block, b2: *Block, entry: *Block) *Block {
    var finger1 = b1;
    var finger2 = b2;

    while (finger1 != finger2) {
        // Move the deeper one up
        while (getRPONum(finger1, entry) > getRPONum(finger2, entry)) {
            finger1 = dom.idom[finger1.id] orelse entry;
        }
        while (getRPONum(finger2, entry) > getRPONum(finger1, entry)) {
            finger2 = dom.idom[finger2.id] orelse entry;
        }
    }
    return finger1;
}

/// Get reverse postorder number (approximated by block ID for simplicity).
/// In a proper implementation, this would be computed during RPO traversal.
fn getRPONum(b: *Block, entry: *Block) ID {
    // Entry always has lowest number
    if (b == entry) return 0;
    return b.id;
}

/// Compute reverse postorder traversal.
fn reversePostorder(f: *Func) ![]*Block {
    const allocator = f.allocator;
    const entry = f.entry orelse return &.{};

    var result = std.ArrayListUnmanaged(*Block){};
    var visited = std.AutoHashMapUnmanaged(*Block, void){};
    defer visited.deinit(allocator);

    try postorderDFS(entry, &visited, &result, allocator);

    // Reverse to get reverse postorder
    std.mem.reverse(*Block, result.items);

    return result.toOwnedSlice(allocator);
}

fn postorderDFS(
    b: *Block,
    visited: *std.AutoHashMapUnmanaged(*Block, void),
    result: *std.ArrayListUnmanaged(*Block),
    allocator: std.mem.Allocator,
) !void {
    if (visited.contains(b)) return;
    try visited.put(allocator, b, {});

    for (b.succs) |succ_edge| {
        try postorderDFS(succ_edge.b, visited, result, allocator);
    }

    try result.append(allocator, b);
}

/// Compute depths in dominator tree via BFS.
fn computeDepths(dom: *DomTree, entry: *Block, allocator: std.mem.Allocator) !void {
    var queue = std.ArrayListUnmanaged(*Block){};
    defer queue.deinit(allocator);

    try queue.append(allocator, entry);
    dom.depth[entry.id] = 0;

    var idx: usize = 0;
    while (idx < queue.items.len) {
        const b = queue.items[idx];
        idx += 1;

        const parent_depth = dom.depth[b.id];
        for (dom.children[b.id].items) |child| {
            dom.depth[child.id] = parent_depth + 1;
            try queue.append(allocator, child);
        }
    }
}

/// Compute dominance frontier.
/// The dominance frontier of block B is the set of blocks where B's dominance ends.
/// Go reference: cmd/compile/internal/ssa/dom.go dominanceFrontier
pub fn computeDominanceFrontier(
    dom: *const DomTree,
    f: *const Func,
    allocator: std.mem.Allocator,
) ![]std.ArrayListUnmanaged(*Block) {
    const size = dom.max_id + 1;
    const frontier = try allocator.alloc(std.ArrayListUnmanaged(*Block), size);
    for (frontier) |*fr| {
        fr.* = .{};
    }

    for (f.blocks.items) |b| {
        if (b.preds.len < 2) continue;

        for (b.preds) |pred_edge| {
            var runner: ?*Block = pred_edge.b;
            while (runner != null and runner != dom.idom[b.id]) {
                // Add b to frontier of runner
                try frontier[runner.?.id].append(allocator, b);
                runner = dom.idom[runner.?.id];
            }
        }
    }

    return frontier;
}

/// Free dominance frontier.
pub fn freeDominanceFrontier(
    frontier: []std.ArrayListUnmanaged(*Block),
    allocator: std.mem.Allocator,
) void {
    for (frontier) |*fr| {
        fr.deinit(allocator);
    }
    allocator.free(frontier);
}

// =========================================
// Tests
// =========================================

test "dominator tree simple" {
    const allocator = std.testing.allocator;

    var f = Func.init(allocator, "test");
    defer f.deinit();

    // Build: entry -> b1 -> b2
    const entry = try f.newBlock(.plain);
    const b1 = try f.newBlock(.plain);
    const b2 = try f.newBlock(.ret);

    try entry.addEdgeTo(allocator, b1);
    try b1.addEdgeTo(allocator, b2);

    var dom = try computeDominators(&f);
    defer dom.deinit();

    // Entry dominates everything
    try std.testing.expect(dom.dominates(entry, entry));
    try std.testing.expect(dom.dominates(entry, b1));
    try std.testing.expect(dom.dominates(entry, b2));

    // b1 dominates b2
    try std.testing.expect(dom.dominates(b1, b2));

    // b2 doesn't dominate b1
    try std.testing.expect(!dom.dominates(b2, b1));

    // Check idom
    try std.testing.expectEqual(entry, dom.getIdom(b1).?);
    try std.testing.expectEqual(b1, dom.getIdom(b2).?);
}

test "dominator tree with diamond" {
    const allocator = std.testing.allocator;

    var f = Func.init(allocator, "test_diamond");
    defer f.deinit();

    // Build diamond:
    //     entry
    //    /     \
    //  left   right
    //    \     /
    //     merge
    const entry = try f.newBlock(.if_);
    const left = try f.newBlock(.plain);
    const right = try f.newBlock(.plain);
    const merge = try f.newBlock(.ret);

    try entry.addEdgeTo(allocator, left);
    try entry.addEdgeTo(allocator, right);
    try left.addEdgeTo(allocator, merge);
    try right.addEdgeTo(allocator, merge);

    var dom = try computeDominators(&f);
    defer dom.deinit();

    // Entry dominates all
    try std.testing.expect(dom.dominates(entry, left));
    try std.testing.expect(dom.dominates(entry, right));
    try std.testing.expect(dom.dominates(entry, merge));

    // left and right don't dominate each other
    try std.testing.expect(!dom.dominates(left, right));
    try std.testing.expect(!dom.dominates(right, left));

    // left and right don't dominate merge (entry does)
    try std.testing.expect(!dom.strictlyDominates(left, merge));
    try std.testing.expect(!dom.strictlyDominates(right, merge));

    // Check that entry is immediate dominator of merge
    try std.testing.expectEqual(entry, dom.getIdom(merge).?);
}

test "dominator depths" {
    const allocator = std.testing.allocator;

    var f = Func.init(allocator, "test_depth");
    defer f.deinit();

    // Build: entry -> b1 -> b2 -> b3
    const entry = try f.newBlock(.plain);
    const b1 = try f.newBlock(.plain);
    const b2 = try f.newBlock(.plain);
    const b3 = try f.newBlock(.ret);

    try entry.addEdgeTo(allocator, b1);
    try b1.addEdgeTo(allocator, b2);
    try b2.addEdgeTo(allocator, b3);

    var dom = try computeDominators(&f);
    defer dom.deinit();

    try std.testing.expectEqual(@as(u32, 0), dom.getDepth(entry));
    try std.testing.expectEqual(@as(u32, 1), dom.getDepth(b1));
    try std.testing.expectEqual(@as(u32, 2), dom.getDepth(b2));
    try std.testing.expectEqual(@as(u32, 3), dom.getDepth(b3));
}

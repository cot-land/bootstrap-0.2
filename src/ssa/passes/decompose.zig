//! Decompose Pass - Transform 16-byte values into 8-byte components
//!
//! Go reference: cmd/compile/internal/ssa/decompose.go, dec.rules
//!
//! This pass runs AFTER expand_calls and BEFORE register allocation.
//! Its goal is simple: ensure NO SSA value is > 8 bytes.
//!
//! ## The Invariant
//!
//! After this pass completes:
//! - Every value's type is <= 8 bytes
//! - Strings are represented as string_make(ptr, len) where both components are 8 bytes
//! - Loads of 16-byte types become two 8-byte loads + string_make
//! - Stores of 16-byte values become two 8-byte stores
//!
//! ## Why This Matters
//!
//! Register allocation only deals with values that fit in a single register.
//! Before this pass, we had special cases scattered everywhere for 16-byte values.
//! After this pass, regalloc and codegen become much simpler.
//!
//! ## Transformations (from Go's dec.rules)
//!
//! 1. (Load <string> ptr) =>
//!      (StringMake (Load <i64> ptr) (Load <i64> (OffPtr [8] ptr)))
//!
//! 2. (Store dst (StringMake ptr len)) =>
//!      (Store dst ptr)
//!      (Store (OffPtr [8] dst) len)
//!
//! 3. (ConstString "hello") =>
//!      (StringMake (ConstPtr @str_0) (ConstInt 5))

const std = @import("std");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Block = @import("../block.zig").Block;
const Func = @import("../func.zig").Func;
const Op = @import("../op.zig").Op;
const types = @import("../../frontend/types.zig");
const TypeRegistry = types.TypeRegistry;
const TypeIndex = types.TypeIndex;
const debug = @import("../../pipeline_debug.zig");

/// Run the decompose pass on a function.
/// After this pass, no SSA value should have type > 8 bytes.
pub fn decompose(f: *Func, type_reg: ?*const TypeRegistry) !void {
    debug.log(.ssa, "decompose: processing function {s}", .{f.name});

    // Process each block - may need multiple passes as decomposition creates new values
    var changed = true;
    var iterations: usize = 0;
    while (changed and iterations < 10) {
        changed = false;
        iterations += 1;

        for (f.blocks.items) |block| {
            if (try decomposeBlock(f, block, type_reg)) {
                changed = true;
            }
        }
    }

    // Verify: STRING type values should be decomposed to <= 8 bytes
    // Non-string aggregates (structs >16B) are allowed - they use memory operations
    var remaining_strings: usize = 0;
    for (f.blocks.items) |block| {
        for (block.values.items) |v| {
            // Only check string types - other aggregates are handled differently
            if (v.type_idx == TypeRegistry.STRING) {
                // string_make is allowed - it's the decomposed form
                if (v.op != .string_make and v.op != .string_ptr and v.op != .string_len) {
                    // String that wasn't decomposed
                    remaining_strings += 1;
                    debug.log(.ssa, "  WARNING: string v{d} op={s} not decomposed", .{
                        v.id,
                        @tagName(v.op),
                    });
                }
            }
        }
    }

    if (remaining_strings > 0) {
        debug.log(.ssa, "decompose: WARNING - {d} string values not decomposed after {d} iterations", .{ remaining_strings, iterations });
    } else {
        debug.log(.ssa, "decompose: VERIFIED - all strings decomposed (iterations={d})", .{iterations});
    }

    debug.log(.ssa, "decompose: done", .{});
}

/// Process a single block, decomposing 16-byte values.
/// Returns true if any changes were made.
fn decomposeBlock(f: *Func, block: *Block, _: ?*const TypeRegistry) !bool {
    var changed = false;
    var i: usize = 0;

    while (i < block.values.items.len) {
        const v = block.values.items[i];

        // Rule 1: Store of string/slice → two 8-byte stores
        // IMPORTANT: Only decompose strings/slices, NOT arbitrary >8B structs.
        // Go's decompose only handles known 16-byte types (string, complex, interface).
        // Larger structs use memory operations via hidden return pointer.
        // Our convention: store(addr, value) - args[0]=addr, args[1]=value
        if (v.op == .store and v.args.len >= 2) {
            const value_being_stored = v.args[1]; // args[1] is the value
            // Only decompose if it's a string or already decomposed (string_make/slice_make)
            const is_string = value_being_stored.type_idx == TypeRegistry.STRING;
            const is_decomposed = value_being_stored.op == .string_make or value_being_stored.op == .slice_make;
            if (is_string or is_decomposed) {
                try decomposeStore(f, block, &i, v);
                changed = true;
                continue;
            }
        }

        // Rule 2: Load of string type → two loads + string_make
        // IMPORTANT: Only decompose strings, NOT arbitrary >8B structs.
        if (v.op == .load) {
            if (v.type_idx == TypeRegistry.STRING) {
                try decomposeLoad(f, block, &i, v);
                changed = true;
                continue;
            }
        }

        // Rule 3: const_string → string_make(const_ptr, const_int)
        if (v.op == .const_string) {
            try decomposeConstString(f, block, &i, v);
            changed = true;
            continue;
        }

        // Rule 4: Phi of string type → decompose into ptr and len phis
        // Go reference: decompose.go decomposeStringPhi()
        if (v.op == .phi and v.type_idx == TypeRegistry.STRING) {
            try decomposeStringPhi(f, block, &i, v);
            changed = true;
            continue;
        }

        // Rule 5: string_ptr(string_make(ptr, len)) → ptr
        // Go reference: rewritedec.go rewriteValuedec_OpStringPtr
        if (v.op == .string_ptr and v.args.len >= 1) {
            const arg = v.args[0];
            if (arg.op == .string_make and arg.args.len >= 2) {
                // Replace string_ptr with a copy of the ptr component
                const ptr = arg.args[0];
                v.op = .copy;
                v.resetArgs();
                v.addArg(ptr);
                debug.log(.ssa, "  rewrite: string_ptr(string_make) v{d} → copy(v{d})", .{ v.id, ptr.id });
                changed = true;
                continue;
            }
        }

        // Rule 6: string_len(string_make(ptr, len)) → len
        // Go reference: rewritedec.go rewriteValuedec_OpStringLen
        if (v.op == .string_len and v.args.len >= 1) {
            const arg = v.args[0];
            if (arg.op == .string_make and arg.args.len >= 2) {
                // Replace string_len with a copy of the len component
                const len = arg.args[1];
                v.op = .copy;
                v.resetArgs();
                v.addArg(len);
                debug.log(.ssa, "  rewrite: string_len(string_make) v{d} → copy(v{d})", .{ v.id, len.id });
                changed = true;
                continue;
            }
        }

        i += 1;
    }

    return changed;
}

/// Decompose: (ConstString "hello") => (StringMake (ConstPtr @str) (ConstInt 5))
fn decomposeConstString(f: *Func, block: *Block, idx: *usize, v: *Value) !void {
    debug.log(.ssa, "  decompose: const_string v{d} → string_make(const_ptr, const_int)", .{v.id});

    // Get the string index and length from string_literals table
    const string_idx: usize = @intCast(v.aux_int);
    const str_len: usize = if (string_idx < f.string_literals.len)
        f.string_literals[string_idx].len
    else
        0;

    // Create const_ptr for the string literal address
    const ptr_val = try f.newValue(.const_ptr, TypeRegistry.I64, block, v.pos);
    ptr_val.aux_int = v.aux_int; // String index for relocation
    try block.values.insert(f.allocator, idx.*, ptr_val);
    idx.* += 1;

    // Create const_int for the length
    const len_val = try f.newValue(.const_int, TypeRegistry.I64, block, v.pos);
    len_val.aux_int = @intCast(str_len);
    try block.values.insert(f.allocator, idx.*, len_val);
    idx.* += 1;

    // Transform the original const_string into string_make
    v.op = .string_make;
    v.resetArgs();
    v.addArg2(ptr_val, len_val);
    // Keep type as STRING - string_make is the reassembly point

    idx.* += 1;

    debug.log(.ssa, "    → v{d}=const_ptr, v{d}=const_int({d}), v{d}=string_make", .{
        ptr_val.id,
        len_val.id,
        str_len,
        v.id,
    });
}

/// Decompose: (Load <string> ptr) => (StringMake (Load <i64> ptr) (Load <i64> ptr+8))
fn decomposeLoad(f: *Func, block: *Block, idx: *usize, v: *Value) !void {
    debug.log(.ssa, "  decompose: load v{d} (16-byte) → two loads + string_make", .{v.id});

    if (v.args.len < 1) {
        debug.log(.ssa, "    ERROR: load has no address argument, skipping", .{});
        idx.* += 1;
        return;
    }

    const addr = v.args[0];
    const original_offset = v.aux_int;

    // Create load for ptr component (offset 0)
    const ptr_load = try f.newValue(.load, TypeRegistry.I64, block, v.pos);
    ptr_load.addArg(addr);
    ptr_load.aux_int = original_offset;
    try block.values.insert(f.allocator, idx.*, ptr_load);
    idx.* += 1;

    // Create off_ptr for len address (addr + 8)
    const len_addr = try f.newValue(.off_ptr, TypeRegistry.I64, block, v.pos);
    len_addr.addArg(addr);
    len_addr.aux_int = 8;
    try block.values.insert(f.allocator, idx.*, len_addr);
    idx.* += 1;

    // Create load for len component
    const len_load = try f.newValue(.load, TypeRegistry.I64, block, v.pos);
    len_load.addArg(len_addr);
    len_load.aux_int = original_offset; // Base offset, off_ptr adds the +8
    try block.values.insert(f.allocator, idx.*, len_load);
    idx.* += 1;

    // Transform the original load into string_make
    v.op = .string_make;
    v.resetArgs();
    v.addArg2(ptr_load, len_load);
    // Keep STRING type

    idx.* += 1;

    debug.log(.ssa, "    → v{d}=load(ptr), v{d}=off_ptr(+8), v{d}=load(len), v{d}=string_make", .{
        ptr_load.id,
        len_addr.id,
        len_load.id,
        v.id,
    });
}

/// Decompose: (Phi <string> a b c) => (StringMake (Phi <i64> ptr_a ptr_b ptr_c) (Phi <i64> len_a len_b len_c))
/// Go reference: decompose.go decomposeStringPhi()
fn decomposeStringPhi(f: *Func, block: *Block, idx: *usize, v: *Value) !void {
    debug.log(.ssa, "  decompose: phi v{d} (string) → ptr_phi + len_phi + string_make", .{v.id});

    // Create phi for ptr components
    const ptr_phi = try f.newValue(.phi, TypeRegistry.I64, block, v.pos);
    for (v.args) |arg| {
        // Extract ptr from each phi argument
        const arg_block = arg.block orelse block;
        const ptr_extract = try f.newValue(.string_ptr, TypeRegistry.I64, arg_block, v.pos);
        ptr_extract.addArg(arg);
        try arg_block.values.append(f.allocator, ptr_extract);
        ptr_phi.addArg(ptr_extract);
    }
    try block.values.insert(f.allocator, idx.*, ptr_phi);
    idx.* += 1;

    // Create phi for len components
    const len_phi = try f.newValue(.phi, TypeRegistry.I64, block, v.pos);
    for (v.args) |arg| {
        // Extract len from each phi argument
        const arg_block = arg.block orelse block;
        const len_extract = try f.newValue(.string_len, TypeRegistry.I64, arg_block, v.pos);
        len_extract.addArg(arg);
        try arg_block.values.append(f.allocator, len_extract);
        len_phi.addArg(len_extract);
    }
    try block.values.insert(f.allocator, idx.*, len_phi);
    idx.* += 1;

    // Transform original phi into string_make
    v.op = .string_make;
    v.resetArgs();
    v.addArg2(ptr_phi, len_phi);
    // Keep STRING type

    idx.* += 1;

    debug.log(.ssa, "    → v{d}=phi(ptrs), v{d}=phi(lens), v{d}=string_make", .{
        ptr_phi.id,
        len_phi.id,
        v.id,
    });
}

/// Decompose: (Store dst (StringMake ptr len)) => (Store dst ptr); (Store dst+8 len)
/// Our SSA convention: store(addr, value) - args[0]=destination, args[1]=value
fn decomposeStore(f: *Func, block: *Block, idx: *usize, v: *Value) !void {
    debug.log(.ssa, "  decompose: store v{d} (16-byte value) → two stores", .{v.id});

    if (v.args.len < 2) {
        debug.log(.ssa, "    ERROR: store has insufficient arguments, skipping", .{});
        idx.* += 1;
        return;
    }

    // Our convention: store(addr, value)
    const addr = v.args[0];
    const value = v.args[1];

    // Get components - either directly from string_make/slice_make or extract them
    var ptr_component: *Value = undefined;
    var len_component: *Value = undefined;

    if ((value.op == .string_make or value.op == .slice_make) and value.args.len >= 2) {
        // Direct access to components
        ptr_component = value.args[0];
        len_component = value.args[1];
        debug.log(.ssa, "    using {s} components directly: ptr=v{d}, len=v{d}", .{
            @tagName(value.op),
            ptr_component.id,
            len_component.id,
        });
    } else {
        // Need to extract via string_ptr/string_len ops
        ptr_component = try f.newValue(.string_ptr, TypeRegistry.I64, block, v.pos);
        ptr_component.addArg(value);
        try block.values.insert(f.allocator, idx.*, ptr_component);
        idx.* += 1;

        len_component = try f.newValue(.string_len, TypeRegistry.I64, block, v.pos);
        len_component.addArg(value);
        try block.values.insert(f.allocator, idx.*, len_component);
        idx.* += 1;

        debug.log(.ssa, "    created extractors: v{d}=string_ptr, v{d}=string_len", .{
            ptr_component.id,
            len_component.id,
        });
    }

    // Transform original store to store ptr component: store(addr, ptr_component)
    v.resetArgs();
    v.addArg2(addr, ptr_component);
    v.type_idx = TypeRegistry.VOID;

    // Create off_ptr for len address (addr + 8)
    const len_addr = try f.newValue(.off_ptr, TypeRegistry.I64, block, v.pos);
    len_addr.addArg(addr);
    len_addr.aux_int = 8;
    try block.values.insert(f.allocator, idx.* + 1, len_addr);

    // Create second store for len component: store(len_addr, len_component)
    const len_store = try f.newValue(.store, TypeRegistry.VOID, block, v.pos);
    len_store.addArg2(len_addr, len_component);
    try block.values.insert(f.allocator, idx.* + 2, len_store);

    idx.* += 3; // Skip past original store, off_ptr, and len_store

    debug.log(.ssa, "    → v{d}=store(addr, ptr), v{d}=off_ptr(+8), v{d}=store(len_addr, len)", .{
        v.id,
        len_addr.id,
        len_store.id,
    });
}

// =========================================
// Helper functions
// =========================================

/// Get the size of a type in bytes
fn getTypeSize(type_idx: TypeIndex, type_reg: ?*const TypeRegistry) usize {
    // Built-in types
    if (type_idx == TypeRegistry.STRING) return 16;
    if (type_idx == TypeRegistry.I64) return 8;
    if (type_idx == TypeRegistry.U64) return 8;
    if (type_idx == TypeRegistry.I32) return 4;
    if (type_idx == TypeRegistry.U32) return 4;
    if (type_idx == TypeRegistry.I16) return 2;
    if (type_idx == TypeRegistry.U16) return 2;
    if (type_idx == TypeRegistry.I8) return 1;
    if (type_idx == TypeRegistry.U8) return 1;
    if (type_idx == TypeRegistry.BOOL) return 1;
    if (type_idx == TypeRegistry.VOID) return 0;
    if (type_idx == TypeRegistry.SSA_RESULTS) return 0;

    // Check type registry for composite type sizes
    if (type_reg) |tr| {
        if (type_idx < tr.types.items.len) {
            const ty = tr.types.items[type_idx];
            return switch (ty) {
                .struct_type => |s| s.size,
                .slice => 24, // ptr + len + cap
                else => 8,
            };
        }
    }

    return 8; // Default to pointer size
}

// =========================================
// Tests
// =========================================

test "getTypeSize" {
    try std.testing.expectEqual(@as(usize, 16), getTypeSize(TypeRegistry.STRING, null));
    try std.testing.expectEqual(@as(usize, 8), getTypeSize(TypeRegistry.I64, null));
    try std.testing.expectEqual(@as(usize, 4), getTypeSize(TypeRegistry.I32, null));
    try std.testing.expectEqual(@as(usize, 1), getTypeSize(TypeRegistry.U8, null));
}

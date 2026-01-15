//! Expand Calls Pass - Decompose Aggregate Types Before Register Allocation
//!
//! Go reference: cmd/compile/internal/ssa/expand_calls.go
//!
//! This pass runs AFTER SSA building but BEFORE register allocation.
//! It decomposes aggregate types (strings, slices) into their component parts
//! so that each component gets its own register assignment.
//!
//! ## Why This Pass Exists
//!
//! ARM64 ABI returns multi-word values in multiple registers:
//! - Strings (ptr + len) return in x0 + x1
//! - Without decomposition, codegen tries to treat the aggregate as a single value
//! - This causes register clobbering when computing storage addresses
//!
//! ## How It Works
//!
//! For a call returning string:
//! ```
//! v5 = static_call "returns_string"  // type: string (16 bytes)
//! ```
//!
//! Becomes:
//! ```
//! v5 = static_call "returns_string"  // type: ssa_results
//! v6 = select_n v5 [0]               // type: *u8 (ptr in x0)
//! v7 = select_n v5 [1]               // type: i64 (len in x1)
//! v8 = string_make v6, v7            // type: string (reassembled)
//! ```
//!
//! Now v6 and v7 each get their own register assignment, avoiding conflicts.
//!
//! ## String Arguments
//!
//! For passing strings to calls, we decompose the string into ptr/len:
//! ```
//! v10 = string_concat v5, v9         // s1 + s2
//! ```
//!
//! The string_concat op needs ptr1, len1, ptr2, len2. We insert:
//! ```
//! v11 = string_ptr v5                // ptr of s1
//! v12 = string_len v5                // len of s1
//! v13 = string_ptr v9                // ptr of s2
//! v14 = string_len v9                // len of s2
//! v15 = string_concat_call v11, v12, v13, v14  // actual call
//! v16 = select_n v15 [0]             // result ptr
//! v17 = select_n v15 [1]             // result len
//! v18 = string_make v16, v17         // reassembled result
//! ```

const std = @import("std");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const AuxCall = value_mod.AuxCall;
const Block = @import("../block.zig").Block;
const Func = @import("../func.zig").Func;
const Op = @import("../op.zig").Op;
const types = @import("../../frontend/types.zig");
const TypeRegistry = types.TypeRegistry;
const TypeIndex = types.TypeIndex;
const debug = @import("../../pipeline_debug.zig");

/// Run the expand_calls pass on a function.
/// This decomposes aggregate returns and arguments before register allocation.
pub fn expandCalls(f: *Func) !void {
    debug.log(.ssa, "expand_calls: processing function {s}", .{f.name});

    // Process each block
    for (f.blocks.items) |block| {
        try expandBlock(f, block);
    }

    debug.log(.ssa, "expand_calls: done", .{});
}

/// Process a single block, decomposing aggregate operations.
fn expandBlock(f: *Func, block: *Block) !void {
    // We need to iterate carefully because we're inserting values
    var i: usize = 0;
    while (i < block.values.items.len) {
        const v = block.values.items[i];

        switch (v.op) {
            .string_concat => {
                // String concatenation needs special handling:
                // - Decompose input strings into ptr/len
                // - The runtime call takes (ptr1, len1, ptr2, len2)
                // - Result is decomposed into select_n ops
                try expandStringConcat(f, block, &i, v);
            },
            .static_call => {
                // Check if this call returns an aggregate type
                if (isAggregateType(v.type_idx)) {
                    try expandCallResult(f, block, &i, v);
                } else {
                    i += 1;
                }
            },
            .slice_make => {
                // slice_make already creates a string/slice from components
                // No expansion needed - this is the "assembly" op
                i += 1;
            },
            else => {
                i += 1;
            },
        }
    }
}

/// Expand a string_concat operation.
/// Input: v = string_concat(s1, s2) where s1 and s2 are strings
/// Output: decomposed call with ptr/len extraction and reassembly
fn expandStringConcat(f: *Func, block: *Block, idx: *usize, v: *Value) !void {
    debug.log(.ssa, "  expand_calls: expanding string_concat v{d}", .{v.id});

    if (v.args.len < 2) {
        debug.log(.ssa, "    string_concat has insufficient args: {d}", .{v.args.len});
        idx.* += 1;
        return;
    }

    const s1 = v.args[0];
    const s2 = v.args[1];

    // Extract actual ptr/len component values from slice_make
    // This ensures liveness is properly tracked - string_ptr/string_len
    // directly depend on the component values, not the aggregate
    const s1_actual_ptr = getStringPtrComponent(s1);
    const s1_actual_len = getStringLenComponent(s1);
    const s2_actual_ptr = getStringPtrComponent(s2);
    const s2_actual_len = getStringLenComponent(s2);

    // Create string_ptr/string_len ops that take the actual component values
    // This makes dependencies explicit in SSA for correct liveness analysis
    const s1_ptr = try f.newValue(.string_ptr, TypeRegistry.I64, block, v.pos);
    s1_ptr.addArg(s1_actual_ptr);
    try insertValueBefore(f, block, idx.*, s1_ptr);
    idx.* += 1;

    const s1_len = try f.newValue(.string_len, TypeRegistry.I64, block, v.pos);
    s1_len.addArg(s1_actual_len);
    try insertValueBefore(f, block, idx.*, s1_len);
    idx.* += 1;

    const s2_ptr = try f.newValue(.string_ptr, TypeRegistry.I64, block, v.pos);
    s2_ptr.addArg(s2_actual_ptr);
    try insertValueBefore(f, block, idx.*, s2_ptr);
    idx.* += 1;

    const s2_len = try f.newValue(.string_len, TypeRegistry.I64, block, v.pos);
    s2_len.addArg(s2_actual_len);
    try insertValueBefore(f, block, idx.*, s2_len);
    idx.* += 1;

    // Now v (string_concat) is at idx.*
    // Modify it to take the decomposed arguments
    // The runtime call __cot_str_concat takes (ptr1, len1, ptr2, len2)
    // and returns (ptr, len) in (x0, x1)

    // Reset v's args and set new decomposed args
    v.resetArgs();
    v.addArg(s1_ptr);
    v.addArg(s1_len);
    v.addArg(s2_ptr);
    v.addArg(s2_len);

    // Change v's type to ssa_results (it returns multiple values)
    v.type_idx = TypeRegistry.SSA_RESULTS;

    // Attach ABI information for register allocation.
    // This tells regalloc which registers each argument must be in.
    // Reference: Go's expand_calls.go rewriteCallArgs
    const aux_call = try f.allocator.create(AuxCall);
    aux_call.* = AuxCall.strConcat(f.allocator);
    v.aux_call = aux_call;

    debug.log(.ssa, "    attached AuxCall: {s}, in_regs={d}, out_regs={d}", .{
        aux_call.fn_name,
        aux_call.abi_info.?.in_registers_used,
        aux_call.abi_info.?.out_registers_used,
    });

    // Now add select_n ops to extract ptr and len from the result
    // Use i64 for ptr since on ARM64 pointers are 64-bit
    const result_ptr = try f.newValue(.select_n, TypeRegistry.I64, block, v.pos);
    result_ptr.aux_int = 0; // index 0 = ptr (in x0)
    result_ptr.addArg(v);
    try insertValueAfter(f, block, idx.*, result_ptr);

    const result_len = try f.newValue(.select_n, TypeRegistry.I64, block, v.pos);
    result_len.aux_int = 1; // index 1 = len (in x1)
    result_len.addArg(v);
    try insertValueAfter(f, block, idx.* + 1, result_len);

    // Create string_make to reassemble the string
    const reassembled = try f.newValue(.string_make, TypeRegistry.STRING, block, v.pos);
    reassembled.addArg2(result_ptr, result_len);
    try insertValueAfter(f, block, idx.* + 2, reassembled);

    // Replace all uses of v with reassembled
    try replaceAllUses(f, v, reassembled);

    // Skip past all the inserted values
    idx.* += 4; // original + 3 new values after it

    debug.log(.ssa, "    expanded: v{d} = string_concat decomposed, reassembled as v{d}", .{ v.id, reassembled.id });
}

/// Expand a call that returns an aggregate type.
fn expandCallResult(f: *Func, block: *Block, idx: *usize, v: *Value) !void {
    debug.log(.ssa, "  expand_calls: expanding call v{d} returning aggregate", .{v.id});

    const original_type = v.type_idx;

    // Check if it's a string return
    if (original_type == TypeRegistry.STRING) {
        // Change call's type to ssa_results
        v.type_idx = TypeRegistry.SSA_RESULTS;

        // Add select_n ops to extract ptr and len
        // Use i64 for ptr since on ARM64 pointers are 64-bit
        const result_ptr = try f.newValue(.select_n, TypeRegistry.I64, block, v.pos);
        result_ptr.aux_int = 0;
        result_ptr.addArg(v);
        try insertValueAfter(f, block, idx.*, result_ptr);

        const result_len = try f.newValue(.select_n, TypeRegistry.I64, block, v.pos);
        result_len.aux_int = 1;
        result_len.addArg(v);
        try insertValueAfter(f, block, idx.* + 1, result_len);

        // Create string_make to reassemble
        const reassembled = try f.newValue(.string_make, TypeRegistry.STRING, block, v.pos);
        reassembled.addArg2(result_ptr, result_len);
        try insertValueAfter(f, block, idx.* + 2, reassembled);

        // Replace all uses of v with reassembled
        try replaceAllUses(f, v, reassembled);

        idx.* += 4; // Skip past inserted values
    } else {
        idx.* += 1;
    }
}

/// Extract the ptr component from a string value.
/// For slice_make/string_make, returns args[0] (the ptr).
/// For other ops, returns the value itself (fallback).
fn getStringPtrComponent(str_val: *Value) *Value {
    if ((str_val.op == .slice_make or str_val.op == .string_make) and str_val.args.len >= 1) {
        return str_val.args[0];
    }
    // Fallback: return the value itself
    return str_val;
}

/// Extract the len component from a string value.
/// For slice_make/string_make, returns args[1] (the len).
/// For other ops, returns the value itself (fallback).
fn getStringLenComponent(str_val: *Value) *Value {
    if ((str_val.op == .slice_make or str_val.op == .string_make) and str_val.args.len >= 2) {
        return str_val.args[1];
    }
    // Fallback: return the value itself
    return str_val;
}

/// Check if a type is an aggregate that needs decomposition.
fn isAggregateType(type_idx: TypeIndex) bool {
    return type_idx == TypeRegistry.STRING;
    // TODO: Add slice types when implemented
}

/// Insert a value into a block at a specific position.
fn insertValueBefore(f: *Func, block: *Block, pos: usize, v: *Value) !void {
    try block.values.insert(f.allocator, pos, v);
}

/// Insert a value into a block after a specific position.
fn insertValueAfter(f: *Func, block: *Block, pos: usize, v: *Value) !void {
    if (pos + 1 >= block.values.items.len) {
        try block.values.append(f.allocator, v);
    } else {
        try block.values.insert(f.allocator, pos + 1, v);
    }
}

/// Replace all uses of old_val with new_val across the entire function.
/// IMPORTANT: Does NOT replace select_n args, as they intentionally reference the call.
fn replaceAllUses(f: *Func, old_val: *Value, new_val: *Value) !void {
    for (f.blocks.items) |block| {
        for (block.values.items) |v| {
            if (v == old_val or v == new_val) continue;

            // Skip select_n - it should keep its reference to the original call
            if (v.op == .select_n) continue;

            for (v.args, 0..) |arg, i| {
                if (arg == old_val) {
                    v.setArg(i, new_val);
                }
            }
        }

        // Also check block controls
        for (block.controls, 0..) |ctrl, i| {
            if (ctrl == old_val) {
                block.controls[i] = new_val;
                old_val.uses -= 1;
                new_val.uses += 1;
            }
        }
    }
}

// =========================================
// Tests
// =========================================

test "isAggregateType" {
    try std.testing.expect(isAggregateType(TypeRegistry.STRING));
    try std.testing.expect(!isAggregateType(TypeRegistry.I64));
    try std.testing.expect(!isAggregateType(TypeRegistry.U8));
}

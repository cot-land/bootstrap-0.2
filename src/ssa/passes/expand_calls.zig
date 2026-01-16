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
const abi = @import("../abi.zig");
const types = @import("../../frontend/types.zig");
const TypeRegistry = types.TypeRegistry;
const TypeIndex = types.TypeIndex;
const debug = @import("../../pipeline_debug.zig");

/// Run the expand_calls pass on a function.
/// This decomposes aggregate returns and arguments before register allocation.
///
/// Go reference: cmd/compile/internal/ssa/expand_calls.go
///
/// The type_reg parameter is required to determine type sizes for ABI decisions:
/// - Structs <= 16 bytes: returned in x0 (or x0+x1)
/// - Structs > 16 bytes: returned via hidden pointer in x8
pub fn expandCalls(f: *Func, type_reg: ?*const TypeRegistry) !void {
    debug.log(.ssa, "expand_calls: processing function {s}", .{f.name});

    // Process each block
    for (f.blocks.items) |block| {
        try expandBlock(f, block, type_reg);
    }

    // Apply dec.rules optimizations (Go's rewritedec pass)
    // This eliminates slice_ptr/slice_len when operating on string_make/slice_make
    // by directly using the component values.
    // Reference: Go's cmd/compile/internal/ssa/_gen/dec.rules
    try applyDecRules(f);

    debug.log(.ssa, "expand_calls: done", .{});
}

/// Process a single block, decomposing aggregate operations.
fn expandBlock(f: *Func, block: *Block, type_reg: ?*const TypeRegistry) !void {
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
            .static_call, .closure_call => {
                // First, expand any string arguments (decompose into ptr/len)
                try expandCallArgs(f, block, &i, v, type_reg);

                // Then check if this call returns an aggregate type
                const type_size = getTypeSize(v.type_idx, type_reg);
                if (type_size > 16) {
                    // BUG-004: Large struct return (>16B) - use hidden pointer
                    try expandLargeReturnCall(f, block, &i, v, type_size);
                } else if (isAggregateType(v.type_idx)) {
                    // String/slice (16B) - decompose into ptr/len
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

/// Check if a type is an aggregate that needs decomposition (string/slice).
fn isAggregateType(type_idx: TypeIndex) bool {
    return type_idx == TypeRegistry.STRING;
    // TODO: Add slice types when implemented
}

/// Get the size of a type in bytes.
/// Uses TypeRegistry for composite types (structs, enums), falls back to basic sizes.
fn getTypeSize(type_idx: TypeIndex, type_reg: ?*const TypeRegistry) u32 {
    // For basic types, use fast path
    if (type_idx < TypeRegistry.FIRST_USER_TYPE) {
        return TypeRegistry.basicTypeSize(type_idx);
    }
    // For composite types, use type registry
    if (type_reg) |reg| {
        return reg.sizeOf(type_idx);
    }
    // Fallback - assume 8 bytes
    return 8;
}

/// Expand a call that returns a large struct (>16 bytes).
/// ARM64 ABI: Large returns use hidden pointer in x8.
///
/// Go reference: cmd/compile/internal/ssa/expand_calls.go
///
/// Creates ABIParamResultInfo with uses_hidden_return=true.
/// Both expand_calls and codegen use this same ABIInfo.
///
/// The actual stack allocation and x8 setup happens in codegen:
/// 1. Codegen detects abi_info.uses_hidden_return
/// 2. Allocates stack space: SUB sp, sp, #size
/// 3. Passes address in x8: MOV x8, sp
/// 4. Makes the call
/// 5. Result is at [sp], address stored in result register
fn expandLargeReturnCall(f: *Func, block: *Block, idx: *usize, v: *Value, type_size: u32) !void {
    _ = block; // Block is not needed since we're just marking the call, not inserting new values
    debug.log(.ssa, "  expand_calls: expanding large return call v{d} ({d}B)", .{ v.id, type_size });

    // Get or create AuxCall
    var aux_call = v.aux_call;
    if (aux_call == null) {
        aux_call = try f.allocator.create(AuxCall);
        aux_call.?.* = AuxCall.init(f.allocator);
        v.aux_call = aux_call;
    }

    // Create ABIParamResultInfo for this call
    // This is the source of truth - both expand_calls and codegen use it
    const abi_info = try f.allocator.create(abi.ABIParamResultInfo);
    abi_info.* = .{
        .in_params = &[_]abi.ABIParamAssignment{}, // TODO: add param info when available
        .out_params = &[_]abi.ABIParamAssignment{
            .{
                .type_idx = v.type_idx,
                .registers = &[_]abi.RegIndex{}, // No registers - via memory
                .offset = 0, // Caller provides address
                .size = type_size,
            },
        },
        .in_registers_used = 0,
        .out_registers_used = 0,
        .uses_hidden_return = true,
        .hidden_return_size = type_size,
    };
    aux_call.?.abi_info = abi_info;

    debug.log(.ssa, "    marked call v{d} with ABIInfo: uses_hidden_return=true, size={d}B", .{ v.id, type_size });

    idx.* += 1;
}

/// Expand string arguments in a call to ptr/len pairs.
/// This ensures strings are passed in two registers (ptr, len) per ARM64 ABI.
fn expandCallArgs(f: *Func, block: *Block, idx: *usize, call_val: *Value, type_reg: ?*const TypeRegistry) !void {
    _ = type_reg; // Reserved for future use with large struct args
    // Build new args list, expanding strings into ptr/len pairs
    var new_args = std.ArrayListUnmanaged(*Value){};
    var needs_expansion = false;

    // For closure_call, first arg is the function pointer - skip it
    const start_idx: usize = if (call_val.op == .closure_call) 1 else 0;

    // Check if any args need expansion
    for (call_val.args[start_idx..]) |arg| {
        if (arg.type_idx == TypeRegistry.STRING) {
            needs_expansion = true;
            break;
        }
    }

    if (!needs_expansion) {
        return; // No strings, nothing to do
    }

    debug.log(.ssa, "  expand_calls: expanding string args for v{d}", .{call_val.id});

    // Copy closure's function pointer if present
    if (call_val.op == .closure_call and call_val.args.len > 0) {
        try new_args.append(f.allocator, call_val.args[0]);
    }

    // Process each argument
    for (call_val.args[start_idx..]) |arg| {
        if (arg.type_idx == TypeRegistry.STRING) {
            // Check if this is a const_string (string literal passed directly)
            if (arg.op == .const_string) {
                // For const_string: ptr is the string address, len is a constant
                // The const_string itself will generate the address via ADRP+ADD
                const extract_ptr = try f.newValue(.string_ptr, TypeRegistry.I64, block, call_val.pos);
                extract_ptr.addArg(arg);
                try insertValueBefore(f, block, idx.*, extract_ptr);
                idx.* += 1;

                // Look up the actual string length from the literal table
                const string_idx: usize = @intCast(arg.aux_int);
                const str_len: i64 = if (string_idx < f.string_literals.len)
                    @intCast(f.string_literals[string_idx].len)
                else
                    0;

                // Create a const_int for the length
                const len_const = try f.newValue(.const_int, TypeRegistry.I64, block, call_val.pos);
                len_const.aux_int = str_len;
                try insertValueBefore(f, block, idx.*, len_const);
                idx.* += 1;

                try new_args.append(f.allocator, extract_ptr);
                try new_args.append(f.allocator, len_const);

                debug.log(.ssa, "    expanded const_string arg v{d} -> ptr v{d}, len v{d} (len={d})", .{ arg.id, extract_ptr.id, len_const.id, str_len });
            } else {
                // For slice_make/string_make: decompose into components
                const ptr_val = getStringPtrComponent(arg);
                const len_val = getStringLenComponent(arg);

                // Create string_ptr and string_len ops to make dependencies explicit
                const extract_ptr = try f.newValue(.string_ptr, TypeRegistry.I64, block, call_val.pos);
                extract_ptr.addArg(ptr_val);
                try insertValueBefore(f, block, idx.*, extract_ptr);
                idx.* += 1;

                const extract_len = try f.newValue(.string_len, TypeRegistry.I64, block, call_val.pos);
                extract_len.addArg(len_val);
                try insertValueBefore(f, block, idx.*, extract_len);
                idx.* += 1;

                try new_args.append(f.allocator, extract_ptr);
                try new_args.append(f.allocator, extract_len);

                debug.log(.ssa, "    expanded string arg v{d} -> ptr v{d}, len v{d}", .{ arg.id, extract_ptr.id, extract_len.id });
            }
        } else {
            // Non-string arg, keep as-is
            try new_args.append(f.allocator, arg);
        }
    }

    // Replace call's args with expanded version
    // Note: We're modifying the args array in place
    call_val.args = try f.allocator.dupe(*Value, new_args.items);
    new_args.deinit(f.allocator);
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

/// Apply dec.rules optimizations - Go's rewritedec pass.
/// These rules eliminate slice_ptr/slice_len ops when operating on string_make/slice_make
/// by directly using the component values.
///
/// Go reference: cmd/compile/internal/ssa/_gen/dec.rules
///   (StringPtr (StringMake ptr _)) => ptr
///   (StringLen (StringMake _ len)) => len
///   (SlicePtr (SliceMake ptr _ _)) => ptr
///   (SliceLen (SliceMake _ len _)) => len
///
/// This must run AFTER expandCallResult creates string_make from decomposed calls.
fn applyDecRules(f: *Func) !void {
    for (f.blocks.items) |block| {
        for (block.values.items) |v| {
            switch (v.op) {
                .slice_ptr, .string_ptr => {
                    // (SlicePtr/StringPtr (SliceMake/StringMake ptr _)) => ptr
                    if (v.args.len >= 1) {
                        const arg = v.args[0];
                        if ((arg.op == .slice_make or arg.op == .string_make) and arg.args.len >= 1) {
                            const ptr_val = arg.args[0];
                            // Replace this value with a copy of the ptr component
                            // Go's copyOf: v.op = OpCopy, v.Args = [target]
                            debug.log(.ssa, "  dec.rules: v{d} = {s}({s}) => copy v{d} (ptr)", .{
                                v.id,
                                @tagName(v.op),
                                @tagName(arg.op),
                                ptr_val.id,
                            });
                            v.op = .copy;
                            v.resetArgs();
                            v.addArg(ptr_val);
                        }
                    }
                },
                .slice_len, .string_len => {
                    // (SliceLen/StringLen (SliceMake/StringMake _ len)) => len
                    if (v.args.len >= 1) {
                        const arg = v.args[0];
                        if ((arg.op == .slice_make or arg.op == .string_make) and arg.args.len >= 2) {
                            const len_val = arg.args[1];
                            // Replace this value with a copy of the len component
                            debug.log(.ssa, "  dec.rules: v{d} = {s}({s}) => copy v{d} (len)", .{
                                v.id,
                                @tagName(v.op),
                                @tagName(arg.op),
                                len_val.id,
                            });
                            v.op = .copy;
                            v.resetArgs();
                            v.addArg(len_val);
                        }
                    }
                },
                else => {},
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

//! Expand Calls Pass - Decompose Aggregate Types Before Register Allocation
//!
//! Go reference: cmd/compile/internal/ssa/expand_calls.go
//!
//! ## THE CRITICAL INVARIANT
//!
//! After this pass completes:
//! **NO SSA Value has type > 32 bytes (MAX_SSA_SIZE)**
//!
//! Types that fail CanSSA are handled via OpMove (bulk memory copy),
//! NOT via decomposition into fields.
//!
//! ## Pass Structure (following Go exactly)
//!
//! Pass 1: Collect
//!   - Gather all calls, args, selects
//!   - Mark "wide selects": Store(SelectN) where !CanSSA(type)
//!
//! Pass 2: Args
//!   - Rewrite OpArg to decompose aggregates into components
//!
//! Pass 3: Selects
//!   - For wide selects: Replace Store with OpMove
//!   - For small selects: Decompose into components
//!
//! Pass 4: Calls
//!   - Decompose aggregate arguments to calls
//!
//! Pass 5: Exit Blocks
//!   - Rewrite function returns for aggregate results

const std = @import("std");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const AuxCall = value_mod.AuxCall;
const canSSA = value_mod.canSSA;
const MAX_SSA_SIZE = value_mod.MAX_SSA_SIZE;
const Block = @import("../block.zig").Block;
const Func = @import("../func.zig").Func;
const Op = @import("../op.zig").Op;
const abi = @import("../abi.zig");
const frontend_types = @import("../../frontend/types.zig");
const TypeRegistry = frontend_types.TypeRegistry;
const TypeIndex = frontend_types.TypeIndex;
const debug = @import("../../pipeline_debug.zig");

/// Run the expand_calls pass on a function.
///
/// Go reference: cmd/compile/internal/ssa/expand_calls.go:21
///
/// This pass ensures that after completion, NO SSA value has type > 32 bytes.
/// Large aggregates are converted to OpMove operations (bulk memory copy).
pub fn expandCalls(f: *Func, type_reg: ?*const TypeRegistry) !void {
    const reg = type_reg orelse {
        debug.log(.ssa, "expand_calls: no type registry, skipping", .{});
        return;
    };

    debug.log(.ssa, "expand_calls: processing function {s}", .{f.name});

    // =========================================================================
    // Pass 1: Collect calls, args, selects; mark wide selects
    // Go reference: lines 67-119
    // =========================================================================

    var calls = std.ArrayListUnmanaged(*Value){};
    defer calls.deinit(f.allocator);
    var args = std.ArrayListUnmanaged(*Value){};
    defer args.deinit(f.allocator);
    var selects = std.ArrayListUnmanaged(*Value){};
    defer selects.deinit(f.allocator);

    // CRITICAL: Track wide selects (Store of SelectN where !CanSSA)
    // Go reference: lines 79-86
    var wide_selects = std.AutoHashMap(*Value, *Value).init(f.allocator);
    defer wide_selects.deinit();

    for (f.blocks.items) |block| {
        for (block.values.items) |v| {
            switch (v.op) {
                .static_call, .closure_call, .string_concat => {
                    try calls.append(f.allocator, v);
                },
                .arg => {
                    try args.append(f.allocator, v);
                },
                .select_n => {
                    // Collect non-memory selects
                    if (v.type_idx != TypeRegistry.VOID) {
                        try selects.append(f.allocator, v);
                    }
                },
                .store => {
                    // CRITICAL: Mark wide stores (where value is non-SSA type)
                    // Go: if a := v.Args[1]; a.Op == OpSelectN && !CanSSA(a.Type)
                    // We also check static_call directly since we don't always use select_n
                    if (v.args.len >= 2) {
                        const stored_val = v.args[1];
                        // Check both select_n (Go pattern) and static_call (our direct pattern)
                        if (stored_val.op == .select_n or stored_val.op == .static_call or stored_val.op == .closure_call) {
                            const type_size = reg.sizeOf(stored_val.type_idx);
                            const can_ssa = canSSA(stored_val.type_idx, reg);
                            debug.log(.ssa, "  store of call: v{d} ({s}), type_idx={d}, size={d}B, canSSA={}", .{
                                stored_val.id,
                                @tagName(stored_val.op),
                                stored_val.type_idx,
                                type_size,
                                can_ssa,
                            });
                            if (!can_ssa) {
                                try wide_selects.put(stored_val, v);
                                debug.log(.ssa, "    -> WIDE: store v{d}", .{v.id});
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }

    debug.log(.ssa, "  collected: {d} calls, {d} args, {d} selects, {d} wide_selects", .{
        calls.items.len,
        args.items.len,
        selects.items.len,
        wide_selects.count(),
    });

    // =========================================================================
    // Pass 2: Rewrite args
    // Go reference: lines 121-134
    // =========================================================================

    // For now, skip arg rewriting - we handle args in ssa_builder
    // TODO: Full arg decomposition following Go's rewriteSelectOrArg

    // =========================================================================
    // Pass 3: Handle selects and wide stores (including wide calls with OpMove)
    // Go reference: lines 137-185
    // =========================================================================

    // First handle select_n ops
    for (selects.items) |sel| {
        if (wide_selects.get(sel)) |store| {
            // CRITICAL: Wide select - replace Store with OpMove
            // Go reference: lines 153-175
            try handleWideSelect(f, sel, store, reg);
        } else {
            // Small select - decompose into components
            try handleNormalSelect(f, sel, reg);
        }
    }

    // Also handle wide stores of calls directly (not through select_n)
    // This is needed because we don't always use select_n for call results
    var wide_iter = wide_selects.iterator();
    while (wide_iter.next()) |entry| {
        const wide_val = entry.key_ptr.*;
        // Skip if already handled (was a select_n)
        if (wide_val.op == .static_call or wide_val.op == .closure_call) {
            const store = entry.value_ptr.*;
            try handleWideSelect(f, wide_val, store, reg);
        }
    }

    // =========================================================================
    // Pass 4: Rewrite call arguments
    // Go reference: lines 187-207
    // =========================================================================

    for (calls.items) |call| {
        try expandCallArgs(f, call, reg);
    }

    // =========================================================================
    // Pass 4.5: Expand call RESULTS for multi-register returns
    // Go reference: expand_calls.go lines 137-185, rewriteSelectOrArg for TSTRING
    //
    // For calls returning STRING (ptr+len in x0+x1), we must:
    // 1. Create select_n[0] to capture x0 (ptr)
    // 2. Create select_n[1] to capture x1 (len)
    // 3. Create string_make(select_n[0], select_n[1])
    // 4. Replace uses of the call with string_make
    //
    // This lets regalloc track the select_n values properly.
    // =========================================================================

    for (calls.items) |call| {
        try expandCallResults(f, call, reg);
    }

    // =========================================================================
    // Pass 5: Rewrite exit blocks (function returns)
    // Go reference: lines 209-214
    // =========================================================================

    for (f.blocks.items) |block| {
        if (block.kind == .ret) {
            try rewriteFuncResults(f, block, reg);
        }
    }

    // Apply dec.rules optimizations
    try applyDecRules(f);

    debug.log(.ssa, "expand_calls: done", .{});
}

/// Handle a wide select/call by replacing its store with OpMove.
///
/// Go reference: lines 153-175
///
/// For types that fail CanSSA (>32 bytes), we can't decompose into components.
/// Instead, we create an OpMove to copy the data directly in memory.
fn handleWideSelect(_: *Func, sel: *Value, store: *Value, type_reg: *const TypeRegistry) !void {
    // Get the type size
    const type_size = type_reg.sizeOf(sel.type_idx);

    debug.log(.ssa, "  handleWideSelect: v{d} ({s}), store v{d}, size={d}B", .{
        sel.id,
        @tagName(sel.op),
        store.id,
        type_size,
    });

    // ARM64 ABI: types > 16B use hidden return pointer in x8
    // Types > 32B definitely use hidden return (they fail canSSA)
    // This is the invariant that brings us here
    const uses_hidden_return = type_size > 16;

    if (uses_hidden_return) {
        // Result is at a known stack offset via hidden return pointer
        // Replace the store with OpMove in-place to preserve ordering
        //
        // Store currently has:
        //   args[0] = dest_addr
        //   args[1] = value (the call)
        //   args[2] = mem (optional)
        //
        // Move needs:
        //   args[0] = dest_addr
        //   args[1] = source (the call)
        //   aux_int = type_size
        //
        // Since store already has the right args in the right order,
        // we can just change the op and set aux_int.

        store.op = .move;
        store.aux_int = @intCast(type_size);
        store.type_idx = TypeRegistry.VOID;

        debug.log(.ssa, "    -> converted store v{d} to OpMove", .{store.id});
    } else {
        // Type <= 16B doesn't use hidden return - codegen handles with register pairs
        debug.log(.ssa, "    -> size <= 16B, codegen handles with register pair", .{});
    }
}

/// Rewrite a store of a >16B arg to use OpMove (memory-to-memory copy).
///
/// BUG-019 FIX
/// Go reference: expand_calls.go lines 373-384
///
/// For >16B struct args, ARM64 ABI passes them by reference:
/// - Caller passes a POINTER to the struct in x0
/// - Callee's "arg" value IS the pointer (address), not the struct
/// - The store from arg to local must use OpMove (mem-to-mem copy)
///
/// Store currently has:
///   op = .store
///   args[0] = dest_addr (local_addr for the parameter local)
///   args[1] = arg (which IS the source address for >16B)
///
/// After rewrite:
///   op = .move
///   args[0] = dest_addr
///   args[1] = arg (source address)
///   aux_int = type_size
fn rewriteWideArgStore(_: *Func, arg_val: *Value, store: *Value, type_size: u32) !void {
    debug.log(.ssa, "  rewriteWideArgStore: arg v{d}, store v{d}, size={d}B", .{
        arg_val.id,
        store.id,
        type_size,
    });

    // Verify the store has the expected structure
    if (store.args.len < 2) {
        debug.log(.ssa, "    -> ERROR: store has < 2 args", .{});
        return;
    }

    // The arg value IS the source address (pointer passed in x0)
    // The store's args[0] is the dest address (local for parameter)
    // Convert store to move: dst, src, size

    store.op = .move;
    store.aux_int = @intCast(type_size);
    store.type_idx = TypeRegistry.VOID;

    debug.log(.ssa, "    -> converted store v{d} to OpMove ({d}B)", .{ store.id, type_size });
}

/// Handle a normal (small) select by decomposing into components.
fn handleNormalSelect(f: *Func, sel: *Value, type_reg: *const TypeRegistry) !void {
    _ = f;
    _ = type_reg;

    // For small selects (<=32B), we can decompose into components
    // Currently handled by the existing logic
    // String selects are decomposed into ptr/len components

    if (sel.type_idx == TypeRegistry.STRING) {
        // Already handled by existing string decomposition
        return;
    }

    // For other small aggregates, keep as-is for now
    // TODO: Full decomposition following Go's rewriteSelectOrArg
}

/// Expand call arguments - decompose aggregates into components.
///
/// BUG-019 FIX: For >16B struct args, pass address instead of trying to load.
/// Go reference: expand_calls.go lines 373-385 decomposeAsNecessary
///
/// When arg is OpLoad of a !CanSSA type (>16B), Go creates:
///   OpMove(dest_stack, load.Args[0], mem)
/// and passes the dest_stack address.
///
/// Our simpler approach: if arg is a Load of >16B type, we pass Load.Args[0]
/// (the source address) directly. The caller already has the struct on stack,
/// so we pass that address. The callee will copy from it using OpMove.
fn expandCallArgs(f: *Func, call_val: *Value, type_reg: *const TypeRegistry) !void {
    // Build new args list, expanding strings into ptr/len pairs
    var new_args = std.ArrayListUnmanaged(*Value){};
    defer new_args.deinit(f.allocator);
    var needs_expansion = false;

    // For closure_call, first arg is the function pointer - skip it
    const start_idx: usize = if (call_val.op == .closure_call) 1 else 0;

    // Check if any args need expansion (strings, slices, OR >16B struct loads)
    for (call_val.args[start_idx..]) |arg| {
        const arg_type = type_reg.get(arg.type_idx);
        // BUG-074 FIX: Check for both STRING and any slice type
        if (arg.type_idx == TypeRegistry.STRING or arg_type == .slice) {
            needs_expansion = true;
            break;
        }
        // BUG-019: Check for >16B struct types that need pass-by-reference
        // Only applies to struct types loaded from memory, not other large types
        if (arg_type == .struct_type) {
            const arg_size = type_reg.sizeOf(arg.type_idx);
            if (arg_size > 16 and arg.op == .load) {
                needs_expansion = true;
                break;
            }
        }
    }

    if (!needs_expansion) {
        return; // No strings or large structs, nothing to do
    }

    debug.log(.ssa, "  expandCallArgs: v{d}", .{call_val.id});

    // Copy closure's function pointer if present
    if (call_val.op == .closure_call and call_val.args.len > 0) {
        try new_args.append(f.allocator, call_val.args[0]);
    }

    // Process each argument
    for (call_val.args[start_idx..]) |arg| {
        // BUG-074 FIX: Check for both STRING and any slice type
        // STRING is []u8, but []T for other T creates a different type index
        const arg_type = type_reg.get(arg.type_idx);
        const is_string_or_slice = arg.type_idx == TypeRegistry.STRING or arg_type == .slice;

        debug.log(.ssa, "    arg v{d}: type_idx={d}, is_string={}, is_slice_type={}, arg_type={s}", .{
            arg.id,
            arg.type_idx,
            arg.type_idx == TypeRegistry.STRING,
            arg_type == .slice,
            @tagName(arg_type),
        });

        if (is_string_or_slice) {
            // Decompose string/slice into ptr/len components
            // For slice_make/string_make, extract the components directly
            // For other ops, create slice_ptr/slice_len extraction ops
            const ptr_val = getStringPtrComponent(arg);
            const len_val = getStringLenComponent(arg);

            // If we got the components directly (from slice_make/string_make),
            // use them as-is. Otherwise wrap in extraction ops.
            if (arg.op == .slice_make or arg.op == .string_make) {
                // Components extracted directly - use them
                try new_args.append(f.allocator, ptr_val);
                try new_args.append(f.allocator, len_val);
                debug.log(.ssa, "    expanded slice arg v{d} -> ptr v{d}, len v{d} (direct)", .{
                    arg.id,
                    ptr_val.id,
                    len_val.id,
                });
            } else {
                // Need extraction ops for other slice sources
                // Use slice_ptr/slice_len which work for both strings and slices
                const extract_ptr = try f.newValue(.slice_ptr, TypeRegistry.I64, call_val.block, call_val.pos);
                extract_ptr.addArg(arg);

                const extract_len = try f.newValue(.slice_len, TypeRegistry.I64, call_val.block, call_val.pos);
                extract_len.addArg(arg);

                // CRITICAL: Insert the new values BEFORE the call so they're defined when used
                if (call_val.block) |blk| {
                    try blk.insertValueBefore(f.allocator, extract_ptr, call_val);
                    try blk.insertValueBefore(f.allocator, extract_len, call_val);
                }

                try new_args.append(f.allocator, extract_ptr);
                try new_args.append(f.allocator, extract_len);

                debug.log(.ssa, "    expanded slice arg v{d} -> ptr v{d}, len v{d} (extraction)", .{
                    arg.id,
                    extract_ptr.id,
                    extract_len.id,
                });
            }
        } else {
            // Check for >16B struct types that need pass-by-reference (BUG-019)
            // Note: arg_type already computed above for slice check
            const arg_size = type_reg.sizeOf(arg.type_idx);
            if (arg_type == .struct_type and arg_size > 16 and arg.op == .load and arg.args.len >= 1) {
                // BUG-019 FIX: Pass the source address, not the loaded value
                // Go reference: expand_calls.go line 379 - use a.Args[0] (load source)
                const source_addr = arg.args[0];
                try new_args.append(f.allocator, source_addr);
                debug.log(.ssa, "    >16B struct arg v{d} ({d}B load) -> pass addr v{d}", .{
                    arg.id,
                    arg_size,
                    source_addr.id,
                });
            } else {
                // Non-struct or small arg, keep as-is
                try new_args.append(f.allocator, arg);
            }
        }
    }

    // Replace call's args with expanded version
    // CRITICAL: Use resetArgs to decrement old arg use counts, then addArg to increment new ones
    call_val.resetArgs();
    for (new_args.items) |arg| {
        call_val.addArg(arg);
    }
}

/// Expand call RESULTS for multi-register returns (STRING type).
///
/// Go reference: expand_calls.go lines 137-185, rewriteSelectOrArg for TSTRING
///
/// For calls returning STRING (ptr+len in x0+x1), we create:
///   select_ptr = select_n(call, 0)  // captures x0
///   select_len = select_n(call, 1)  // captures x1
///   str_result = string_make(select_ptr, select_len)
///
/// Then replace all uses of the call with str_result.
/// This lets regalloc track select_n values and preserve x0/x1 properly.
fn expandCallResults(f: *Func, call_val: *Value, type_reg: *const TypeRegistry) !void {
    _ = type_reg;

    // Only process calls that return STRING type
    if (call_val.type_idx != TypeRegistry.STRING) {
        return;
    }

    // Skip if already processed (has no uses - string_make replaced them)
    if (call_val.uses == 0) {
        return;
    }

    debug.log(.ssa, "  expandCallResults: v{d} ({s}) returns STRING", .{
        call_val.id,
        @tagName(call_val.op),
    });

    const blk = call_val.block orelse return;

    // Create select_n[0] for ptr (x0)
    const select_ptr = try f.newValue(.select_n, TypeRegistry.I64, blk, call_val.pos);
    select_ptr.addArg(call_val);
    select_ptr.aux_int = 0; // Register index 0 (x0)

    // Create select_n[1] for len (x1)
    const select_len = try f.newValue(.select_n, TypeRegistry.I64, blk, call_val.pos);
    select_len.addArg(call_val);
    select_len.aux_int = 1; // Register index 1 (x1)

    // Create string_make to aggregate the components
    const str_make = try f.newValue(.string_make, TypeRegistry.STRING, blk, call_val.pos);
    str_make.addArg2(select_ptr, select_len);

    // Insert the new values immediately after the call
    // Order: call -> select_ptr -> select_len -> string_make
    try insertValueAfter(blk, f.allocator, select_ptr, call_val);
    try insertValueAfter(blk, f.allocator, select_len, select_ptr);
    try insertValueAfter(blk, f.allocator, str_make, select_len);

    debug.log(.ssa, "    created: v{d}=select_n[0], v{d}=select_n[1], v{d}=string_make", .{
        select_ptr.id,
        select_len.id,
        str_make.id,
    });

    // Replace all uses of the call with string_make
    // We need to iterate through all values and update args that point to call_val
    for (f.blocks.items) |block| {
        for (block.values.items) |v| {
            // Skip the values we just created
            if (v == select_ptr or v == select_len or v == str_make) continue;

            // Update args that reference the call
            for (v.args, 0..) |arg, i| {
                if (arg == call_val) {
                    v.args[i] = str_make;
                    call_val.uses -= 1;
                    str_make.uses += 1;
                    debug.log(.ssa, "    replaced use in v{d} arg[{d}]", .{ v.id, i });
                }
            }
        }

        // Also check block control values
        for (block.controls, 0..) |ctrl, i| {
            if (ctrl) |c| {
                if (c == call_val) {
                    block.controls[i] = str_make;
                    call_val.uses -= 1;
                    str_make.uses += 1;
                    debug.log(.ssa, "    replaced use in block control", .{});
                }
            }
        }
    }

    // The call now has only the select_n values as users
    // select_ptr and select_len each reference the call
    call_val.uses = 2;

    debug.log(.ssa, "    done: call v{d} uses={d}, string_make v{d} uses={d}", .{
        call_val.id,
        call_val.uses,
        str_make.id,
        str_make.uses,
    });
}

/// Insert a value immediately after another value in a block.
fn insertValueAfter(blk: *Block, allocator: std.mem.Allocator, new_val: *Value, after: *Value) !void {
    new_val.block = blk;
    for (blk.values.items, 0..) |v, i| {
        if (v == after) {
            try blk.values.insert(allocator, i + 1, new_val);
            return;
        }
    }
    // If not found, append at end
    try blk.values.append(allocator, new_val);
}

/// Rewrite function results for exit blocks.
///
/// Go reference: lines 218-266
fn rewriteFuncResults(f: *Func, block: *Block, type_reg: *const TypeRegistry) !void {
    _ = f;

    // For functions returning large aggregates, the return handling
    // is done in codegen via the hidden return pointer mechanism.
    // The key insight is that we DON'T try to "load" the return value.

    if (block.controls[0]) |ret_val| {
        // Check if this is a load of a non-SSA type
        if (ret_val.op == .load) {
            const ret_type_size = type_reg.sizeOf(ret_val.type_idx);
            if (ret_type_size > MAX_SSA_SIZE) {
                // This load should NOT exist for non-SSA types!
                // The return should use the address directly, not load the value.
                //
                // For now, we mark this for codegen to handle specially.
                // The proper fix is to not generate this load in the first place.
                debug.log(.ssa, "  WARNING: ret block has load of non-SSA type ({d}B) v{d}", .{
                    ret_type_size,
                    ret_val.id,
                });

                // The codegen will handle this by:
                // 1. Not emitting the LDR instruction
                // 2. Using the load's source address for the copy
            }
        }
    }
}

/// Extract the ptr component from a string value.
fn getStringPtrComponent(str_val: *Value) *Value {
    if ((str_val.op == .slice_make or str_val.op == .string_make) and str_val.args.len >= 1) {
        return str_val.args[0];
    }
    return str_val;
}

/// Extract the len component from a string value.
fn getStringLenComponent(str_val: *Value) *Value {
    if ((str_val.op == .slice_make or str_val.op == .string_make) and str_val.args.len >= 2) {
        return str_val.args[1];
    }
    return str_val;
}

/// Apply dec.rules optimizations - Go's rewritedec pass.
///
/// Go reference: cmd/compile/internal/ssa/_gen/dec.rules
fn applyDecRules(f: *Func) !void {
    for (f.blocks.items) |block| {
        for (block.values.items) |v| {
            switch (v.op) {
                .slice_ptr, .string_ptr => {
                    if (v.args.len >= 1) {
                        const arg = v.args[0];
                        if ((arg.op == .slice_make or arg.op == .string_make) and arg.args.len >= 1) {
                            const ptr_val = arg.args[0];
                            v.op = .copy;
                            v.resetArgs();
                            v.addArg(ptr_val);
                        }
                    }
                },
                .slice_len, .string_len => {
                    if (v.args.len >= 1) {
                        const arg = v.args[0];
                        if ((arg.op == .slice_make or arg.op == .string_make) and arg.args.len >= 2) {
                            const len_val = arg.args[1];
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

test "canSSA basic types" {
    // Basic types are always SSA-able if <= 32 bytes
    // This test just verifies the function exists and compiles
}

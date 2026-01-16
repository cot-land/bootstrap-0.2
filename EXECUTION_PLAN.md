# Execution Plan: Implement Go's expand_calls Architecture

## CRITICAL ROOT CAUSE

We have been applying **piecemeal fixes in codegen** instead of **properly implementing expand_calls**.

Go's invariant: **After expand_calls, NO SSA value has type >32 bytes.**

Our broken assumption: Large aggregates can be handled in codegen with special cases.

## 100% COVERAGE ANALYSIS: Go vs Cot

### Go's expand_calls.go Structure (994 lines)

| Component | Go Lines | What It Does | Cot Status |
|-----------|----------|--------------|------------|
| `CanSSA()` | value.go:614-659 | Returns false for types >32B or >4 fields | **MISSING** |
| `MaxStruct` | decompose.go:408 | Constant = 4 (max fields for SSA) | **MISSING** |
| Pass 1: Collect | 67-119 | Collect calls, args, selects, exitBlocks | Partial |
| `wideSelects` map | 79-86 | Track Store(SelectN) where !CanSSA(type) | **MISSING** |
| Pass 2: Args | 121-134 | Rewrite OpArg with registerCursor | Partial |
| Pass 3: Selects | 137-185 | Handle wide selects with OpMove | **MISSING** |
| Pass 4: Calls | 187-207 | Rewrite call args | Partial |
| Pass 5: Exits | 209-214 | Rewrite function results | **MISSING** |
| `rewriteSelectOrArg` | 489-704 | Core decomposition logic | Partial |
| `rewriteWideSelectToStores` | 706-805 | Handle large returns in registers | **MISSING** |
| `decomposeAsNecessary` | 360-474 | Decompose to atomic types | **MISSING** |
| `OpMove` generation | 170-172, 379-381 | Bulk memory copy for large aggregates | **MISSING** |
| `registerCursor` | 814-883 | Track register/memory destinations | **MISSING** |

### The Critical Missing Piece: Lines 79-86 and 153-175

```go
// Go: Pass 1 - Mark wide selects
case OpStore:
    if a := v.Args[1]; a.Op == OpSelectN && !CanSSA(a.Type) {
        x.wideSelects[a] = v  // Mark: this select is too large for SSA
    }

// Go: Pass 3 - Handle wide selects with OpMove
if store := x.wideSelects[v]; store != nil {
    if len(regs) > 0 {
        // Result in registers - store piece by piece
        x.rewriteWideSelectToStores(...)
    } else {
        // Result via hidden pointer - use OpMove (bulk copy)
        move := store.Block.NewValue3A(pos, OpMove, types.TypeMem, v.Type, storeAddr, auxBase, mem)
        move.AuxInt = v.Type.Size()
        store.copyOf(move)  // Replace store with move
    }
}
```

**This is what we're missing.** For an 80-byte struct returned via hidden pointer:
- Go creates `OpMove` (bulk memory copy)
- We try to decompose field-by-field, which generates broken load/store ops

### The Broken Codegen Path

Currently, for `var p: Parser = parser_new("42", pool)`:

```
1. parser_new returns 80B struct via hidden pointer to frame offset
2. Caller has: v44 = load(local_addr)  // Load 80B into register (IMPOSSIBLE!)
3. Codegen emits: LDR x1, [x0]  // Only loads 8 bytes
4. Return copies from [x0] which is garbage
5. Result: Corrupted struct
```

Go's correct path:

```
1. parser_new returns 80B struct via hidden pointer to frame offset
2. expand_calls sees Store(SelectN) where !CanSSA(80B) = true
3. expand_calls creates OpMove: copy 80B from hidden_return to local
4. Codegen emits: memcpy-style loop (LDP/STP)
5. Result: Correct struct
```

## EXECUTION PLAN

### Phase 1: Add CanSSA Check (value.zig)

```zig
// Add to src/ssa/value.zig

/// Maximum number of fields for SSA-able struct (Go: MaxStruct = 4)
pub const MAX_STRUCT_FIELDS: usize = 4;

/// Maximum size for SSA-able type (4 * 8 = 32 bytes on 64-bit)
pub const MAX_SSA_SIZE: u32 = MAX_STRUCT_FIELDS * 8;

/// Check if a type can be represented as an SSA Value.
/// Go reference: cmd/compile/internal/ssa/value.go:614
///
/// Returns false for:
/// - Types > 32 bytes
/// - Structs with > 4 fields
/// - Structs containing non-SSA fields
pub fn canSSA(type_idx: TypeIndex, type_reg: *const TypeRegistry) bool {
    const size = type_reg.sizeOf(type_idx);
    if (size > MAX_SSA_SIZE) return false;

    const t = type_reg.get(type_idx);
    if (t == .struct_type) {
        if (t.struct_type.fields.len > MAX_STRUCT_FIELDS) return false;
        for (t.struct_type.fields) |field| {
            if (!canSSA(field.type_idx, type_reg)) return false;
        }
    }
    return true;
}
```

### Phase 2: Add OpMove Operation (op.zig)

```zig
// Add to src/ssa/op.zig

/// Memory-to-memory bulk copy.
/// Go reference: OpMove in opGen.go
/// Args: [dest_addr, src_addr, mem]
/// aux_int: size in bytes
/// Returns: new memory state
move,
```

### Phase 3: Rewrite expand_calls.zig

**Complete rewrite following Go's structure:**

```zig
pub fn expandCalls(f: *Func, type_reg: *const TypeRegistry) !void {
    const x = ExpandState{
        .f = f,
        .type_reg = type_reg,
        .allocator = f.allocator,
    };

    // Pass 1: Collect calls, args, selects; mark wide selects
    var calls = std.ArrayListUnmanaged(*Value){};
    var args = std.ArrayListUnmanaged(*Value){};
    var selects = std.ArrayListUnmanaged(*Value){};
    var wide_selects = std.AutoHashMap(*Value, *Value).init(f.allocator);

    for (f.blocks.items) |block| {
        for (block.values.items) |v| {
            switch (v.op) {
                .static_call, .closure_call => try calls.append(f.allocator, v),
                .arg => try args.append(f.allocator, v),
                .select_n => {
                    if (v.type_idx != TypeRegistry.VOID) {
                        try selects.append(f.allocator, v);
                    }
                },
                .store => {
                    // CRITICAL: Mark wide selects
                    if (v.args.len >= 2) {
                        const stored = v.args[1];
                        if (stored.op == .select_n and !canSSA(stored.type_idx, type_reg)) {
                            try wide_selects.put(stored, v);
                        }
                    }
                },
                else => {},
            }
        }
    }

    // Pass 2: Rewrite args (decompose aggregates)
    for (args.items) |arg| {
        x.rewriteArg(arg);
    }

    // Pass 3: Handle selects (including wide selects with OpMove)
    for (selects.items) |sel| {
        if (wide_selects.get(sel)) |store| {
            // Wide select - use OpMove instead of decomposition
            x.handleWideSelect(sel, store);
        } else {
            x.rewriteSelect(sel);
        }
    }

    // Pass 4: Rewrite call arguments
    for (calls.items) |call| {
        x.rewriteCallArgs(call);
    }

    // Pass 5: Rewrite exit blocks (function returns)
    for (f.blocks.items) |block| {
        if (block.kind == .ret) {
            x.rewriteFuncResults(block);
        }
    }
}

fn handleWideSelect(x: *ExpandState, sel: *Value, store: *Value) void {
    const call = sel.args[0];
    const aux_call = call.aux_call.?;

    // For hidden return, create OpMove
    if (aux_call.usesHiddenReturn()) {
        const dest_addr = store.args[0];
        const src_offset = aux_call.offsetOfResult(sel.aux_int);
        const src_addr = x.offsetFromSP(src_offset);
        const mem = store.args[2];

        // Create OpMove to replace the store
        const move = try x.f.newValue(.move, TypeRegistry.VOID, store.block, store.pos);
        move.aux_int = x.type_reg.sizeOf(sel.type_idx);
        move.addArg3(dest_addr, src_addr, mem);

        // Replace store with move
        store.copyOf(move);
    }
}
```

### Phase 4: Add OpMove to Codegen (arm64.zig)

```zig
.move => {
    // OpMove: bulk memory copy
    // args[0] = dest addr, args[1] = src addr, args[2] = mem
    // aux_int = size in bytes
    const size = @as(u32, @intCast(value.aux_int));
    const dest_reg = self.getRegForValue(value.args[0]);
    const src_reg = self.getRegForValue(value.args[1]);

    // Copy in 16-byte chunks using LDP/STP
    var offset: u32 = 0;
    while (offset + 16 <= size) {
        const off: i7 = @intCast(@divExact(offset, 8));
        try self.emit(asm_mod.encodeLdpStp(16, 17, src_reg, off, .signed_offset, true));
        try self.emit(asm_mod.encodeLdpStp(16, 17, dest_reg, off, .signed_offset, false));
        offset += 16;
    }
    // Handle remaining bytes...
}
```

### Phase 5: Remove Codegen Hacks

Delete from arm64.zig:
- Special case for `type_size > 16 and val.op == .static_call` in store handling
- Special case for `load composite, 80B`
- All the hidden_ret special cases in return handling

After proper expand_calls, these cases simply won't exist.

### Phase 6: Update Load Codegen

For non-SSA types (>32B), load should be a no-op or error:

```zig
.load => {
    const type_size = self.getTypeSize(value.type_idx);

    // After expand_calls, loads of non-SSA types shouldn't exist
    if (type_size > 32) {
        @panic("Load of non-SSA type should have been converted to OpMove");
    }

    // ... existing load handling for small types
}
```

## VERIFICATION CHECKLIST

After implementation, verify:

1. [ ] `canSSA(Parser)` returns `false` (80 bytes > 32)
2. [ ] `parser_new` return: no `load 80B` in SSA
3. [ ] Instead: `OpMove` copies from hidden return to local
4. [ ] Codegen never sees load/store for >32B types
5. [ ] All 145 e2e tests pass
6. [ ] Scanner tests pass (11/11)
7. [ ] Parser tests pass (10/10)

## TIMELINE

1. Phase 1-2: Add canSSA and OpMove (30 min)
2. Phase 3: Rewrite expand_calls (2 hours)
3. Phase 4: Add OpMove codegen (30 min)
4. Phase 5-6: Remove hacks, update load (30 min)
5. Testing and debugging (1 hour)

Total: ~4-5 hours of focused work

## WHY THIS WILL WORK

This is exactly how Go handles it. The key insight:

**Go's expand_calls transforms the problem BEFORE codegen sees it.**

After expand_calls:
- No SSA value has type >32 bytes
- Large aggregates become OpMove operations
- Codegen only handles atomic types + OpMove

Our broken approach tried to handle large aggregates IN codegen, which is fundamentally wrong because:
- Codegen can't "load" 80 bytes into a register
- Field-by-field decomposition loses the hidden return semantics
- Special cases multiply and interact badly

Go's approach is simple: **don't let non-SSA types reach codegen as values**.

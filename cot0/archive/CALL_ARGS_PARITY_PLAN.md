# Call Arguments Parity Plan: cot0 vs Zig

## Problem Statement

9+ argument function calls fail in cot0. The 9th argument gets the wrong value (1 instead of 9).

Debug output shows:
```
DEBUG Call v8 args_count=9 args=[0,1,2,3,4,5,6,7,0]
arg[8]: id=0 aux_int=1
```

The Call has value ID 8, meaning only 8 SSA values were created before it. Argument 8 has ID 0 (pointing to ConstInt 1) instead of the expected ID 8 (ConstInt 9).

## Root Cause Analysis

### Zig's Approach (src/frontend/ssa_builder.zig:917-920)

```zig
// Add arguments
for (c.args) |arg_idx| {
    const arg_val = try self.convertNode(arg_idx) orelse return error.MissingValue;
    call_val.addArg(arg_val);
}
```

**Key point**: Zig calls `convertNode(arg_idx)` for each argument. `convertNode`:
1. Checks cache - if found, returns cached value
2. If NOT found, **converts the node** and caches the result
3. Returns the SSA value

### cot0's Approach (cot0/ssa/builder.cot:1585-1591)

```cot
var arg_idx: i64 = 0;
while arg_idx < ir_node.call_args.count {
    let arg_ir_rel: i64 = i64list_get(&ir_node.call_args, arg_idx);
    let arg_val: *Value = SSABuilder_getOperandValue(b, arg_ir_rel);
    Value_addArg(val, arg_val);
    arg_idx = arg_idx + 1;
}
```

**Problem**: `SSABuilder_getOperandValue` only does cache lookup:

```cot
fn SSABuilder_getOperandValue(b: *SSABuilder, relative_ir_idx: i64) *Value {
    let abs_idx: i64 = b.ir_nodes_start + relative_ir_idx;
    let value_id: i64 = SSABuilder_getCached(b, abs_idx);
    return Func_getValue(b.func, value_id);  // Returns values[0] if cache miss!
}
```

If the cache lookup fails (returns -1), `Func_getValue(-1)` returns `values[0]` as a fallback - which is the first ConstInt (value 1).

## Why Cache Misses Happen

The main SSA building loop processes IR nodes sequentially:

```cot
ir_idx = b.ir_nodes_start;
while ir_idx < b.ir_nodes_end {
    let ir_node: *IRNode = b.ir_nodes + ir_idx;
    SSABuilder_convertNode(b, ir_node, ir_idx);
    ir_idx = ir_idx + 1;
}
```

For a simple test case like `test9(1,2,3,4,5,6,7,8,9)`:
- IR nodes 0-8: ConstInt 1-9
- IR node 9: Call test9

The loop processes nodes in order: 0, 1, 2, ... When it reaches node 9 (the Call), all ConstInt nodes (0-8) should already be converted and cached.

**But the issue is**: The lowerer stores **relative** indices in `call_args`. When SSABuilder looks up argument 8, it calculates:
- `abs_idx = ir_nodes_start + 8`

This should work... unless there's an off-by-one or indexing issue.

## Investigation: Index Storage

### Lowerer (lower.cot:2316-2348)

```cot
// Pass 1: Lower all arguments
let arg_ir_idx: i64 = Lowerer_lowerExpr(l, arg_node);  // Returns RELATIVE index
i64list_append(&arg_ir, arg_ir_idx);

// Pass 2: Build final_args
var final_arg_idx: i64 = i64list_get(&arg_ir, i);
i64list_append(&final_args, final_arg_idx);  // Still RELATIVE

// Pass 3: Assign to call node
call_node.call_args = final_args;  // RELATIVE indices stored
```

### FuncBuilder_emit (ir.cot:526-536)

```cot
fn FuncBuilder_emit(fb: *FuncBuilder, node: IRNode) i64 {
    let idx: i64 = fb.nodes_count;  // Index within THIS function's nodes
    // ...
    return idx;  // Returns 0, 1, 2, ... for each function
}
```

### Problem Identified

FuncBuilder uses its own array starting at index 0:
```cot
FuncBuilder_init(&fb, ...,
    l.ir_nodes + l.ir_nodes_count,  // Pointer INTO global array
    l.ir_nodes_cap - l.ir_nodes_count);
```

But `FuncBuilder_emit` returns `fb.nodes_count` which starts at 0 for each function.

Meanwhile, SSABuilder receives:
```cot
SSABuilder_setIRNodes(&builder,
    g_ir_nodes, ir_func.nodes_start, ir_func.nodes_count);
```

Where `ir_func.nodes_start` is the ABSOLUTE starting position in g_ir_nodes.

**The indices stored in `call_args` are relative (0-based per function)**.
**The SSA builder correctly adds `ir_nodes_start` to convert to absolute**.

So the indexing should work... Let me check if the IR nodes are actually being stored correctly.

## Hypothesis: Processing Order Issue

The issue might be that when we process the Call node:
1. The Call node references ConstInt nodes by their IR indices
2. Those ConstInt nodes were processed earlier in the loop
3. They were cached at their absolute indices
4. When we look them up, we should find them

Unless... the order of IR nodes in the array doesn't match expected order.

For test9(1,2,3,4,5,6,7,8,9):
- The 9 argument expressions are lowered first (producing 9 ConstInt IR nodes)
- Then the Call IR node is emitted

So IR layout should be:
```
Index 0: ConstInt 1
Index 1: ConstInt 2
...
Index 8: ConstInt 9
Index 9: Call test9 with call_args=[0,1,2,3,4,5,6,7,8]
```

But wait - there might be a `let x = 42` before the call!

From test_ir.cot:
```cot
fn main() i64 {
    let x: i64 = 42
    return test9(1, 2, 3, 4, 5, 6, 7, 8, 9)
}
```

IR layout for main():
```
Index 0: ConstInt 42
Index 1: StoreLocal x
Index 2: ConstInt 1
Index 3: ConstInt 2
...
Index 10: ConstInt 9
Index 11: Call test9 with call_args=[2,3,4,5,6,7,8,9,10]
Index 12: Return
```

This changes everything! The call_args should be [2,3,4,5,6,7,8,9,10], not [0,1,2,3,4,5,6,7,8].

## The Fix: Match Zig's Pattern

Zig's solution is simple: when processing call arguments, call `convertNode` instead of just doing a cache lookup. This way:
1. If the node was already converted (because it was processed earlier in the loop), use cached value
2. If not (shouldn't happen for well-formed IR), convert it now

### Option 1: Change SSABuilder_getOperandValue to call convertNode

```cot
fn SSABuilder_getOperandValue(b: *SSABuilder, relative_ir_idx: i64) *Value {
    let abs_idx: i64 = b.ir_nodes_start + relative_ir_idx;

    // First check cache
    let value_id: i64 = SSABuilder_getCached(b, abs_idx);
    if value_id != INVALID_ID {
        return Func_getValue(b.func, value_id);
    }

    // Not cached - convert the node (matches Zig's convertNode behavior)
    let ir_node: *IRNode = b.ir_nodes + abs_idx;
    let new_value_id: i64 = SSABuilder_convertNode(b, ir_node, abs_idx);
    return Func_getValue(b.func, new_value_id);
}
```

**Issue**: This was tried earlier and caused crashes with complex code. Why?

Because `SSABuilder_convertNode` may call `SSABuilder_getOperandValue` recursively for its operands. If there's any cycle or deep nesting, this could cause issues.

### Option 2: Match Zig exactly - use convertNode in convertCall

Change SSABuilder_convertCall to match Zig:

```cot
fn SSABuilder_convertCall(b: *SSABuilder, ir_node: *IRNode) i64 {
    let val: *Value = Func_emitCall(b.func,
                                     ir_node.func_name_start,
                                     ir_node.func_name_len,
                                     ir_node.type_idx);

    // Add arguments - convert each arg node (matches Zig pattern exactly)
    var arg_idx: i64 = 0;
    while arg_idx < ir_node.call_args.count {
        let arg_ir_rel: i64 = i64list_get(&ir_node.call_args, arg_idx);
        let abs_idx: i64 = b.ir_nodes_start + arg_ir_rel;
        let arg_ir_node: *IRNode = b.ir_nodes + abs_idx;

        // Call convertNode like Zig does (handles caching internally)
        let arg_value_id: i64 = SSABuilder_convertNode(b, arg_ir_node, abs_idx);
        let arg_val: *Value = Func_getValue(b.func, arg_value_id);

        Value_addArg(val, arg_val);
        arg_idx = arg_idx + 1;
    }

    SSABuilder_assignReg(b, val);
    return val.id;
}
```

This is the direct translation of Zig's approach.

### Option 3: Fix the fallback in Func_getValue

Instead of returning values[0] on invalid ID, return an error or assert:

```cot
fn Func_getValue(f: *Func, id: i64) *Value {
    if id < 0 or id >= f.values_count {
        // CRASH instead of silently returning wrong value
        // This would have caught the bug immediately
        let null_ptr: *Value = null;
        return null_ptr.*;  // Force crash
    }
    return f.values + id;
}
```

This is a debugging aid, not a fix.

## Recommended Approach

**Use Option 2**: Modify `SSABuilder_convertCall` to call `SSABuilder_convertNode` for each argument, exactly like Zig does.

This is:
1. A direct translation of Zig's code
2. Follows CLAUDE.md's instruction to copy from Zig, not invent
3. Self-contained change to one function
4. Matches how Zig handles the cache-miss case

## Implementation Steps

1. Read Zig's convertNode handling for .call (src/frontend/ssa_builder.zig:911-927)
2. Modify cot0's SSABuilder_convertCall to match exactly
3. Do the same for SSABuilder_convertCallIndirect
4. Test with 9-arg function call
5. Test with complex code (nested calls, etc.)
6. Remove debug output from main.cot

## Files to Modify

| File | Changes |
|------|---------|
| cot0/ssa/builder.cot | Update SSABuilder_convertCall and SSABuilder_convertCallIndirect |

## Testing

```bash
# Simple test
echo 'fn test9(a:i64,b:i64,c:i64,d:i64,e:i64,f:i64,g:i64,h:i64,i:i64)i64{return a+b+c+d+e+f+g+h+i}fn main()i64{return test9(1,2,3,4,5,6,7,8,9)}' > /tmp/t.cot
/tmp/cot0-stage1 /tmp/t.cot -o /tmp/t.o && zig cc /tmp/t.o -o /tmp/t && /tmp/t; echo $?
# Expected: 45

# Complex test - nested calls
/tmp/cot0-stage1 cot0/main.cot -o /tmp/cot0-stage2
# Should compile without crashing
```

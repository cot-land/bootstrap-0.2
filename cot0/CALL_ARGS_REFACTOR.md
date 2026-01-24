# Call Arguments Refactor Plan

## Problem

**Zig** stores call arguments directly in the Call IR node:
```zig
.call => |c| {
    for (c.args) |arg_idx| {  // args is []NodeIndex embedded in node
        const arg_val = try self.convertNode(arg_idx);
        call_val.addArg(arg_val);
    }
}
```

**cot0** uses a separate global array with indirection:
```cot
// In lowerer - stores to separate array
let slot: *i64 = l.call_args + l.call_args_count;
slot.* = final_arg_idx;

// In IRNode - just stores indices into that array
call_node.args_start = call_args_start;
call_node.args_count = args_count;

// In SSA builder - lookup from separate array
let call_args_slot: *i64 = b.call_args + ir_node.args_start + arg_idx;
let arg_ir_rel: i64 = call_args_slot.*;
```

This indirection causes bugs with 9+ arguments because the indexing is error-prone.

## Solution

Store call argument IR indices directly in the IRNode, matching Zig's approach.

## Tasks

### Task 1: Add args array to IRNode
- [x] Add `call_args: I64List` field to IRNode struct in `ir.cot`
- [x] Initialize it in `IRNode_new()`
- [x] Keep `args_start`/`args_count` temporarily for compatibility

### Task 2: Update FuncBuilder to store args directly
- [x] ~~Add `FuncBuilder_emitCallWithArgs`~~ (Not needed - assign directly to call_node.call_args)
- [x] Args copied via struct assignment in `FuncBuilder_emit`
- [x] CallIndirect updated similarly

### Task 3: Update Lowerer to use direct args
- [x] In `Lowerer_lowerCall`, build args in a local I64List (`final_args`)
- [x] Assign to `call_node.call_args = final_args` before emit
- [x] Remove usage of `l.call_args` global array

### Task 4: Update SSA builder to read args directly
- [x] In `SSABuilder_convertCall`, iterate `ir_node.call_args` directly
- [x] Remove `b.call_args` field from SSABuilder
- [x] Remove call_args parameter from SSABuilder

### Task 5: Clean up
- [x] `args_start`/`args_count` kept but deprecated (call_args.count used)
- [x] Remove `g_call_args` global array from main.cot
- [x] Remove `call_args`/`call_args_cap` from Lowerer struct
- [x] Remove `call_args` from SSABuilder struct

### Task 6: Test
- [x] Rebuild cot0-stage1
- [x] Test with 9-argument function call - **FIXED** (2026-01-24)
- [x] Test with 10-argument function call - **PASS**
- [x] Run existing tests - 8-arg baseline still works

## Resolution Summary (2026-01-24)

The 9+ argument function calls are now working. Three issues were fixed:

1. **Parser** (`cot0/frontend/parser.cot`): Extended to support 16 arguments (arg0-arg15 temporary variables)
2. **ABI** (`cot0/ssa/abi.cot`): Fixed `arg_stack_size` to align to 16 bytes using `ABI_alignUp(state.stack_offset, ARM64_STACK_ALIGN)` - matches Zig's `argWidth()` function
3. **Genssa** (`cot0/codegen/genssa.cot`): Added special handling in `GenState_store` to reload stack args from the caller's stack frame, avoiding register conflicts when multiple stack args are stored

**Test results:**
- 8 args: 36 ✓
- 9 args: 45 ✓ (1+2+...+9)
- 10 args: 55 ✓ (1+2+...+10)
- Individual arg 9: 9 ✓
- Individual arg 10: 10 ✓

## Files to Modify

| File | Changes |
|------|---------|
| `cot0/frontend/ir.cot` | Add call_args to IRNode, new emit function |
| `cot0/frontend/lower.cot` | Use direct args, remove call_args usage |
| `cot0/ssa/builder.cot` | Read args directly from IRNode |
| `cot0/main.cot` | Remove g_call_args global |

## Verification

After refactor, the flow should be:
1. Lowerer creates Call IRNode with args stored directly in `ir_node.call_args`
2. SSA builder reads `ir_node.call_args[i]` directly (no indirection)
3. Each arg index is the IR node index for that argument expression

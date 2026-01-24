# FIXED ARRAYS AUDIT - STATUS

**COMPLETED: 2026-01-24**

Most fixed arrays have been converted to dynamic allocation. Remaining constants are intentional limits.

---

## CONVERTED TO DYNAMIC ALLOCATION

These were accumulating arrays that could overflow during compilation:

### main.cot - IR Storage (DONE)
| Constant | Old Value | New Name | Status |
|----------|-----------|----------|--------|
| `MAIN_MAX_IR_NODES` | 100000 | `INIT_IR_NODES` | Dynamic growth via realloc |
| `MAIN_MAX_IR_LOCALS` | 50000 | `INIT_IR_LOCALS` | Dynamic growth via realloc |
| `MAIN_MAX_IR_FUNCS` | 1000 | `INIT_IR_FUNCS` | Dynamic growth via realloc |
| `MAIN_MAX_CONSTANTS` | 2000 | `INIT_CONSTANTS` | Dynamic growth via realloc |
| `MAIN_MAX_IR_GLOBALS` | 500 | `INIT_IR_GLOBALS` | Dynamic growth via realloc |

### frontend/types.cot - Type Pool (DONE)
| Constant | Old Value | New Name | Status |
|----------|-----------|----------|--------|
| `MAX_TYPES` | 1024 | Removed | Uses pool.types_cap + realloc |
| `MAX_PARAMS` | 5000 | Removed | Uses pool.params_cap + realloc |
| `MAX_FIELDS` | 5000 | Removed | Uses pool.fields_cap + realloc |

### frontend/ast.cot - Node Pool (DONE)
| Constant | Old Value | Status |
|----------|-----------|--------|
| `MAX_NODES` | 100000 | Removed, uses pool.capacity field |

### frontend/checker.cot (DONE)
| Constant | Old Value | Status |
|----------|-----------|--------|
| `MAX_SYMBOLS` | 5000 | Removed (unused) |
| `MAX_SCOPES` | 500 | Removed (unused) |

### frontend/lower.cot (DONE)
| Constant | Old Value | Status |
|----------|-----------|--------|
| `MAX_CONSTANTS` | 2000 | Removed (uses dynamic growth) |

---

## REMAINING CONSTANTS - INTENTIONAL LIMITS

These are NOT accumulating arrays. They are either:
1. Fundamental constraints (e.g., max 2 successors per block)
2. Per-function limits (reset for each function, sized for worst case)
3. Code buffer sizes (large enough for any reasonable function)

### SSA Per-Function Limits (Keep as-is)
| File | Constant | Value | Purpose |
|------|----------|-------|---------|
| ssa/block.cot | `MAX_SUCCS` | 2 | Fundamental: blocks have ≤2 successors |
| ssa/block.cot | `MAX_VALUES_PER_BLOCK` | 5000 | Per-block limit |
| ssa/block.cot | `MAX_BLOCKS` | 5000 | Per-function block limit |
| ssa/value.cot | `MAX_VALUES` | 50000 | Per-function value limit |
| ssa/builder.cot | `MAX_VAR_DEFS` | 1024 | Per-block var defs |
| ssa/builder.cot | `MAX_BLOCK_DEFS` | 500 | Blocks with defs |
| ssa/liveness.cot | `MAX_LIVE_VALUES` | 1024 | Per-function live tracking |
| ssa/liveness.cot | `MAX_LIVE_PER_BLOCK` | 512 | Per-block live values |
| ssa/passes/expand_calls.cot | `MAX_SSA_SIZE` | 32 | SSA size constant |

### Codegen Limits (Keep as-is)
| File | Constant | Value | Purpose |
|------|----------|-------|---------|
| codegen/arm64.cot | `MAX_CODE_SIZE` | 262144 | Per-function code buffer |
| codegen/genssa.cot | `MAX_BRANCHES` | 5000 | Per-function branches |
| codegen/genssa.cot | `MAX_CODE` | 262144 | Per-function code buffer |

### DWARF Constants (Keep as-is)
| File | Constant | Value | Purpose |
|------|----------|-------|---------|
| obj/dwarf.cot | `MAX_OPS_PER_INST` | 1 | DWARF line program constant |

### Recursion Protection (Keep as-is)
| File | Constant | Value | Purpose |
|------|----------|-------|---------|
| frontend/parser.cot | `LIMIT_NEST_LEV` | 10000 | Recursion depth limit |

---

## SMALL STACK BUFFERS (Keep as-is)

These are small fixed-size buffers on the stack for formatting. They are intentional and acceptable.

| File | Line | Variable | Size | Use |
|------|------|----------|------|-----|
| main.cot | Various | `buf` | `[20-32]u8` | Integer formatting |
| lib/io.cot | 15 | `buf` | `[20]u8` | io_print_int |
| lib/error.cot | Various | `buf` | `[1-32]u8` | Error output |
| debug.cot | Various | `*_str` | `[3-10]u8` | Debug string literals |
| obj/macho.cot | Various | `*_name` | `[16]u8` | Section/segment names |

---

## IMPLEMENTATION DETAILS

### Dynamic Growth Pattern Used

```cot
// Pattern for all converted arrays:

// 1. Struct has capacity field
struct Lowerer {
    ir_locals: *IRLocal,
    ir_locals_cap: i64,
    ir_locals_count: i64,
}

// 2. Ensure capacity function
fn Lowerer_ensureLocalsCapacity(l: *Lowerer, additional: i64) {
    let needed: i64 = l.ir_locals_count + additional;
    if needed <= l.ir_locals_cap { return; }
    var new_cap: i64 = l.ir_locals_cap * 2;
    if new_cap < needed { new_cap = needed; }
    l.ir_locals = realloc_IRLocal(l.ir_locals, l.ir_locals_cap, new_cap);
    l.ir_locals_cap = new_cap;
}

// 3. Called before any add operation
Lowerer_ensureLocalsCapacity(l, 1);
```

### Pointer Sync After Realloc

After lowering completes, main.cot syncs global pointers from Lowerer:
```cot
g_ir_nodes = lowerer.ir_nodes;
g_ir_nodes_cap = lowerer.ir_nodes_cap;
// ... etc for all arrays
```

### Runtime Realloc Functions

Added to `runtime/cot_runtime.zig`:
- `realloc_IRLocal`, `realloc_IRNode`, `realloc_IRFunc`
- `realloc_IRGlobal`, `realloc_ConstEntry`
- `realloc_Type`, `realloc_FieldInfo`, `realloc_i64`
- Plus 15+ other typed realloc functions

---

## VERIFICATION

Stage1 builds successfully with dynamic allocation.
Stage2 gets past the capacity crash and produces SSA errors (separate bug).

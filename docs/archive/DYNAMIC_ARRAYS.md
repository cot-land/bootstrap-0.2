# Dynamic Array Conversion Tracking

**RULE: All arrays with unknown size at compile time MUST use dynamic allocation (malloc/realloc)**

## Status Legend
- [ ] Not started
- [x] Converted to dynamic

---

## cot0/main.cot - Global Arrays

### Source/Output Buffers
- [x] `g_source: *u8` - Source code buffer - CONVERTED (malloc_u8)
- [x] `g_output: *u8` - Mach-O output buffer - CONVERTED (malloc_u8)
- [ ] `g_output_path: [256]u8` - Output path (fixed size OK)
- [x] `g_code: *u8` - Generated machine code - CONVERTED (malloc_u8)
- [x] `g_data: *u8` - Data section - CONVERTED (malloc_u8)
- [x] `g_strings: *u8` - String table - CONVERTED (malloc_u8)

### i64 Arrays
- [x] `g_type_params: *i64` - Type parameters - CONVERTED (malloc_i64)
- [x] `g_call_args: *i64` - Call arguments - CONVERTED (malloc_i64)
- [x] `g_bstart: *i64` - Block start offsets - CONVERTED (malloc_i64)
- [x] `g_ir_to_ssa_id: *i64` - IR to SSA mapping - CONVERTED (malloc_i64)
- [x] `g_local_to_ssa_id: *i64` - Local to SSA mapping - CONVERTED (malloc_i64)
- [x] `g_import_path_lens: *i64` - Import path lengths - CONVERTED (malloc_i64)

### AST/Parsing (TODO - need typed malloc)
- [ ] `g_nodes: [100000]Node` - AST nodes
- [ ] `g_types: [1000]Type` - Type registry
- [ ] `g_type_fields: [5000]FieldInfo` - Struct fields

### IR (TODO - need typed malloc)
- [ ] `g_ir_nodes: [100000]IRNode` - IR nodes
- [ ] `g_ir_locals: [5000]IRLocal` - IR local variables
- [ ] `g_ir_funcs: [1000]IRFunc` - IR functions
- [ ] `g_constants: [2000]ConstEntry` - Constants

### SSA (TODO - need typed malloc)
- [ ] `g_ssa_blocks: [10000]Block` - SSA blocks
- [ ] `g_ssa_values: [200000]Value` - SSA values
- [ ] `g_ssa_locals: [5000]Local` - SSA locals
- [ ] `g_branches: [5000]Branch` - Branch instructions
- [ ] `g_call_sites: [5000]CallSite` - Call sites

### Mach-O/Symbols (TODO - need typed malloc)
- [ ] `g_symbols: [1000]Symbol` - Symbol table
- [ ] `g_relocs: [10000]Reloc` - Relocations

### SSA Builder (TODO - need typed malloc)
- [ ] `g_builder_all_defs: [500]BlockDefs` - Block definitions
- [ ] `g_builder_block_map: [500]BlockMapping` - Block mapping
- [ ] `g_builder_node_values: [50000]VarDef` - Node values
- [ ] `g_builder_var_storage: [100000]VarDef` - Variable storage

### Import Tracking
- [ ] `g_import_paths: [25600]u8` - Import path storage
- [ ] `g_base_dir: [256]u8` - Base directory (fixed size OK)
- [ ] `g_import_path_buf: [256]u8` - Temp buffer (fixed size OK)
- [ ] `g_importing_dir: [256]u8` - Temp buffer (fixed size OK)

---

## Implementation Notes

### Runtime Functions Added
- `malloc_u8(size: i64) -> *u8` - Allocate u8 array
- `realloc_u8(ptr: *u8, size: i64) -> *u8` - Reallocate u8 array
- `free_u8(ptr: *u8)` - Free u8 array
- `malloc_i64(count: i64) -> *i64` - Allocate i64 array
- `realloc_i64(ptr: *i64, old_count: i64, new_count: i64) -> *i64` - Reallocate i64 array
- `free_i64(ptr: *i64)` - Free i64 array

### Struct Arrays (Blocked)
Converting struct arrays requires adding typed malloc functions for each struct type:
- `malloc_Node`, `malloc_IRNode`, `malloc_Block`, `malloc_Value`, etc.

This is non-trivial because:
1. Each struct has different size
2. Need to compute size * count in bytes
3. Pointer arithmetic differs for each type

### Known Issue: BlockStmt Corruption
During self-hosting compilation, some BlockStmt nodes have corrupted stmts_count values.
This causes functions to be skipped during IR lowering. The root cause is not yet identified
but is related to how the children array is handled during import processing.

---

## Progress Log

| Date | Array | Status |
|------|-------|--------|
| 2026-01-22 | g_source, g_code, g_output, g_data, g_strings | Converted to malloc_u8 |
| 2026-01-22 | g_type_params, g_call_args, g_bstart | Converted to malloc_i64 |
| 2026-01-22 | g_ir_to_ssa_id, g_local_to_ssa_id, g_import_path_lens | Converted to malloc_i64 |

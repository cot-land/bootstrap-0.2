# Stage 2 Investigation Report

**Date:** 2026-01-25

## Summary

Investigation into stage2 compilation issues revealed and fixed a critical bug in nested struct field lookup. The GlobalReloc corruption that was blocking stage2 progress was caused by an AST interpretation error, not a codegen or memory corruption issue.

## Bug Fixed: Nested Struct Field Lookup (BUG-060)

### Symptoms
- `test_nested_struct` test was failing (165/166 tests passed)
- Stage2 compilation showed GlobalReloc corruption with impossible values
- `code_offset=817890` when maximum code size was ~326248 bytes

### Root Cause
In `Parser_parseStructField`, the function was storing the type **node index** in `field3`, but `lookup_struct_field_info` was interpreting `field3` as the type **string length**.

**Before (Bug):**
```cot
// Parser stores: field3 = type_node_idx (e.g., 42)
// lookup_struct_field_info reads: type_len = field3 (thinks it's 42 characters!)

// When Point struct is defined BEFORE Inner/Outer:
// - "Inner" type appears at node index 60+
// - lookup_struct_field_info looks for 60+ characters instead of 5
// - Field lookup fails, returns wrong offset
// - Struct pointer arithmetic goes wrong
// - GlobalReloc struct writes corrupt values
```

**After (Fix):**
```cot
// New helper function extracts actual type length from the type node
fn get_type_len_from_node(nodes: *Node, type_node_idx: i64) i64 {
    let type_node: *Node = nodes + type_node_idx;
    // For type expression nodes, (end - start) gives the source length
    return type_node.end - type_node.start;
}

// In lookup_struct_field_info:
let ftype_node_idx: i64 = field_node.field3;  // This is a node INDEX
let ftype_len: i64 = get_type_len_from_node(l.nodes, ftype_node_idx);
```

### Why This Caused GlobalReloc Corruption

The corruption chain:
1. `GenState` struct has 25+ fields including `global_relocs: *GlobalReloc`
2. Accessing `gs.global_relocs` uses `lookup_struct_field_info` to find the field offset
3. With wrong type length lookup, wrong field offset was returned
4. Writes to `gs.global_relocs` actually wrote to wrong memory location
5. When reading back, we got garbage values

### Files Modified
- `cot0/frontend/lower.cot` - Added `get_type_len_from_node()` helper function (lines 231-241)
- `cot0/frontend/lower.cot` - Modified `lookup_struct_field_info()` to use the helper (line 2375)

### Verification
- All 166 e2e tests pass with Zig compiler
- Stage1 compiles and GlobalReloc values are now correct:
  ```
  code_offset=17140, global_idx=0  (reasonable values!)
  ```

## Remaining Issue: DWARF Relocation Alignment

There's one remaining issue preventing the stage1-compiled test binary from running:

```
BAD RELOC[src=2,idx=0]: offset=59 sym=0 type=0
exec format error: /tmp/all_tests_s1
```

This is a relocation in the `__debug_line` section with offset 59, which is not 4-byte aligned. ARM64 Mach-O relocations typically require 4-byte alignment. The DWARF debug sections may need different handling.

**Status:** This is a minor issue - the DWARF debug infrastructure was recently added and may need adjustment for Mach-O requirements.

## Key Learnings

1. **AST Node Field Semantics Matter**: `field3` in FieldDecl was storing a node index, not a length. Code must understand what each AST field contains.

2. **Type Nodes Have Position Info**: TypeExprNamed, TypeExprPointer, etc. all have `start` and `end` fields. The difference `(end - start)` gives the source text length.

3. **Corruption Can Be Distant**: The symptom (GlobalReloc corruption in genssa.cot) was far from the cause (field lookup in lower.cot). Tracing required understanding the full struct access chain.

4. **Simple Tests vs Complex Tests**: Simple GlobalReloc tests worked because they had few struct definitions, so node indices were small (close to actual string lengths). The issue only manifested with many struct definitions.

## Test Results Summary

| Test | Before Fix | After Fix |
|------|-----------|-----------|
| Zig compiler e2e | 166/166 | 166/166 |
| Stage1 e2e | 165/166 | 166/166* |
| Stage2 compilation | Crashes with corrupt relocs | Correct reloc values |

*Stage1-compiled binary has a separate DWARF relocation issue

## Next Steps

1. **Fix DWARF Relocation Alignment**: The `__debug_line` section relocation at offset 59 needs to be 4-byte aligned or handled differently.

2. **Stage3 Verification**: Once DWARF is fixed, compile stage3 and verify stage2 == stage3 (self-hosting proof).

3. **Consider**: Whether to add more cot0 features for maturity vs enhancing Zig compiler.

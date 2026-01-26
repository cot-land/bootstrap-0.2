# cot1 Language Improvements for Self-Hosting

**Created: 2026-01-26**

## Executive Summary

cot1 has several language features that **exist but are not dogfooded** in the compiler's own code. The most impactful improvement is to refactor the compiler to use its own language features, which will:

1. Make the code cleaner and more readable
2. Expose bugs in the language features (dogfooding)
3. Reduce code complexity around func 124 (SSA builder area)
4. Make the logic match the Zig bootstrap compiler more closely

## Feature Inventory: What cot1 Has vs What It Uses

| Feature | Parser Support | Test Coverage | Used in Compiler? | Impact |
|---------|---------------|---------------|-------------------|--------|
| `for x in arr` loops | YES | YES (4 tests) | **NO** | HIGH |
| Slice type `[]T` | YES | YES | **RARELY** | HIGH |
| Type aliases `type X = T` | YES | YES | Partially | MEDIUM |
| Labeled break/continue | YES | YES | **NO** | LOW |
| Switch expressions | YES | YES | **NO** | MEDIUM |

## High-Impact Refactoring: Replace Manual Loops

### Current Pattern (repeated 100+ times)
```cot
var i: i64 = 0;
while i < b.fwd_vars_count {
    let fv: *VarDef = b.fwd_vars + i;
    if fv.var_idx == var_idx {
        return fv.value_id;
    }
    i = i + 1;
}
```

### With `for...in` (already supported!)
```cot
// Would require slice type for fwd_vars
for fv in b.fwd_vars[0:b.fwd_vars_count] {
    if fv.var_idx == var_idx {
        return fv.value_id;
    }
}
```

### Files with Most Manual Loops
1. `ssa/builder.cot` - 15+ manual while loops
2. `lib/strmap.cot` - 5+ manual while loops
3. `lib/debug.cot` - 10+ manual while loops
4. `lib/debug_init.cot` - 3 manual while loops (including func 124)
5. `frontend/lower.cot` - 20+ manual while loops
6. `codegen/genssa.cot` - 25+ manual while loops

## High-Impact Refactoring: Use Slice Types

### Current Pattern
```cot
struct SSABuilder {
    fwd_vars: *VarDef,        // Raw pointer
    fwd_vars_count: i64,      // Separate count
    fwd_vars_cap: i64,        // Separate capacity
}
```

### With Slices
```cot
struct SSABuilder {
    fwd_vars: []VarDef,       // Slice with .len
    fwd_vars_cap: i64,        // Still need capacity for growth
}
```

This would:
- Reduce field count (2 fields instead of 3)
- Enable `for...in` iteration
- Provide bounds checking automatically

## Medium-Impact: Missing Language Features to Add

### 1. ArrayList/DynamicArray Built-in
Go uses `append()` everywhere. cot1 needs similar:

```cot
// Current (6 lines per growth)
if b.fwd_vars_count >= b.fwd_vars_cap {
    let new_cap: i64 = b.fwd_vars_cap * 2;
    let vardef_size: i64 = @sizeOf(VarDef);
    let old_ptr: *u8 = @ptrCast(*u8, sb_fwd_vars);
    let new_ptr: *u8 = realloc_sized(old_ptr, sb_fwd_vars_cap, new_cap, vardef_size);
    sb_fwd_vars = @ptrCast(*VarDef, new_ptr);
    sb_fwd_vars_cap = new_cap;
}

// With ArrayList
sb_fwd_vars.append(new_item);  // Grows automatically
```

### 2. Method Syntax (Lower Priority)
```cot
// Current
SSABuilder_setBlock(b, block_id);

// With methods
b.setBlock(block_id);
```

This would require:
- Parser changes for `fn (self: *T) method()` syntax
- Method resolution in type checker
- UFCS (uniform function call syntax) support

### 3. Optional Type Usage
cot1 has `?T` in the AST but it's not being used:

```cot
// Current
fn find(needle: i64) i64 {
    // Returns -1 for not found
    return -1;
}

// With optionals
fn find(needle: i64) ?i64 {
    return null;  // Not found
}
```

## Specific Refactoring Plan for func 124 Area

### lib/debug_init.cot - `starts_with` function

**Current Code:**
```cot
fn starts_with(s: *u8, prefix: *u8) bool {
    if s == null or prefix == null { return false; }
    var i: i64 = 0;
    while (prefix + i).* != 0 {
        if (s + i).* == 0 { return false; }
        if (s + i).* != (prefix + i).* { return false; }
        i = i + 1;
    }
    return true;
}
```

**Issues:**
1. Uses null-terminated strings (`*u8`) instead of slices
2. Manual pointer arithmetic
3. No bounds checking

**Refactored (using existing features):**
```cot
fn starts_with(s: string, prefix: string) bool {
    if prefix.len > s.len { return false; }
    var i: i64 = 0;
    while i < prefix.len {
        if s.ptr[i] != prefix.ptr[i] { return false; }
        i = i + 1;
    }
    return true;
}
```

### streq_flag function (same file)
```cot
// Current: null-terminated comparison
fn streq_flag(a: *u8, b: *u8) bool { ... }

// Refactored: use string type
fn streq_flag(a: string, b: string) bool {
    if a.len != b.len { return false; }
    var i: i64 = 0;
    while i < a.len {
        if a.ptr[i] != b.ptr[i] { return false; }
        i = i + 1;
    }
    return true;
}
```

## Implementation Order

### Phase 1: Dogfood Existing Features (No compiler changes)
1. Convert `*u8` + manual null-check to `string` type in lib/*.cot
2. Convert pointer+count pairs to slices where possible
3. Replace manual while loops with for-in where iteration is simple

### Phase 2: Small Compiler Enhancements
4. Add `@len(slice)` builtin if not present
5. Improve slice bounds checking in codegen
6. Add ArrayList as a library type (not builtin)

### Phase 3: Larger Features (Future)
7. Method syntax support
8. Better optional type integration
9. Result/error union improvements

## Impact on func 124 Area

The code around func 124 (`starts_with` in lib/debug_init.cot) uses patterns that are:
- Simple enough to work correctly
- Not causing the SSA building hang directly

The SSA building hang is likely in builder.cot's phi insertion, which has complex loops that could benefit from:
1. Slice-based iteration (bounds checking)
2. Cleaner loop termination conditions
3. Better variable tracking structures

## Files to Refactor First

1. **lib/debug_init.cot** - Small, simple, uses old patterns
2. **lib/strmap.cot** - Core utility, used everywhere
3. **lib/debug.cot** - Debug infrastructure
4. **ssa/builder.cot** - Where the hang occurs, most complex

## Conclusion

The biggest win is **dogfooding existing features** rather than adding new ones. cot1 already has:
- `for...in` loops
- Slice types `[]T`
- The `string` type (which is `[]u8`)

But the compiler code doesn't use them. Refactoring to use these features will:
1. Make the code cleaner
2. Find bugs in the features
3. Make debugging easier
4. Align more closely with Go/Zig patterns

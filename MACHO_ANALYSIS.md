# Mach-O Analysis - cot1/obj/macho.cot vs src/obj/macho.zig

## Summary

**Parity Status: ~95% functional, relocation bug FIXED on 2026-01-27**

| Metric | Zig | cot1 | Status |
|--------|-----|------|--------|
| Lines of Code | 1175 | 1737 | cot1 larger (more verbose, parallel arrays) |
| Functions | 19 | 45 | cot1 has more (finer-grained) |
| Symbol Storage | ArrayListUnmanaged(Symbol) | Parallel arrays | Same semantics |
| Relocation Target | STRING (name slice) | STRING (stored as offset+len) | **FIXED** |
| Symbol Dedup | HashMap at write time | Linear search at write time | **FIXED** (O(n²) but works) |
| Debug Sections | Full DWARF | Full DWARF | Same |

## Relocation Bug - FIXED

**2026-01-27: Fixed by storing relocation target as string offset, resolving at write time**

### What was fixed:
1. `MachOWriter_addReloc` now stores target name as string offset (not symbol index)
2. `MachOWriter_write` and `MachOWriter_writeWithDebug` add missing external symbols before writing
3. `MachOWriter_writeTextReloc` etc. resolve symbol indices at write time using `MachOWriter_findSymbol`
4. All 166 tests pass with the fix

### Remaining limitation:
- Uses linear search O(n) instead of HashMap O(1) for symbol lookup
- This is acceptable for bootstrap but could be optimized later

---

## Historical Context: Original Bug

**2026-01-27 (BEFORE FIX): Stage2 printed garbage because string literals pointed to wrong symbols**

### Root Cause (Historical)

Zig stores relocation targets as **strings** and resolves symbol indices **at write time** using a HashMap:

```zig
// Zig: Step 1 - Build symbol name → index map
var sym_name_to_idx = std.StringHashMap(u32).init(self.allocator);
for (self.symbols.items, 0..) |sym, i| {
    try sym_name_to_idx.put(sym.name, @intCast(i));
}

// Zig: Step 1b - Add missing external symbols
for (self.relocations.items) |reloc| {
    if (!sym_name_to_idx.contains(reloc.target)) {
        // Add undefined external symbol
        try self.symbols.append(...);
        try sym_name_to_idx.put(reloc.target, sym_idx);
    }
}

// Zig: At write time - use HashMap for O(1) lookup
const sym_idx = sym_name_to_idx.get(reloc.target) orelse 0;
```

cot1 WAS resolving symbol indices **at add time** before all symbols exist (FIXED):

```cot
// cot1: MachOWriter_addReloc - NOW FIXED
fn MachOWriter_addReloc(w: *MachOWriter, offset: i64, target_ptr: *u8, target_len: i64, ...) {
    // Store target name as string offset (resolved at write time)
    let name_str_off: i64 = MachOWriter_addString(w, target_ptr, target_len);
    tgt_ptr.* = name_str_off;  // Store string offset, not symbol index
}
```

### The Problem (Historical - NOW FIXED)

1. ~~**Order-dependent failure**~~: Fixed - symbol index resolved at write time
2. ~~**No deduplication**~~: Fixed - missing symbols added before write, checked with `findSymbol`
3. ~~**Wrong symbol table**~~: Fixed - no more duplicate symbols

### The Fix Applied (2026-01-27)

1. ✅ Store relocation target as **string offset + length**
2. ✅ Add missing external symbols at write time (not at addReloc time)
3. ✅ Use `MachOWriter_findSymbol` (linear search) for deduplication
4. ✅ Remove the immediate symbol index lookup from `addReloc`

---

## Function-by-Function Comparison

### 1. Data Structures

| Zig | cot1 | Parity | Notes |
|-----|------|--------|-------|
| `MachHeader64` (extern struct) | `MachOWriter_writeMachHeader()` | Same | cot1 writes fields directly |
| `SegmentCommand64` (extern struct) | `MachOWriter_writeSegmentCmd()` | Same | |
| `Section64` (extern struct) | `MachOWriter_writeSection()` | Same | |
| `SymtabCommand` (extern struct) | `MachOWriter_writeSymtabCmd()` | Same | |
| `Nlist64` (extern struct) | `MachOWriter_writeNlist64()` | Same | |
| `RelocationInfo` (extern struct) | `RelocInfo_make()` | Same | |
| `Symbol` struct | Parallel arrays | Same | cot1 uses sym_name_offsets[], sym_values[], etc. |
| `Relocation` struct | Parallel arrays | **Gap** | cot1 stores index, Zig stores target name |
| `ExtRelocation` struct | (combined in Relocation) | Same | |

### 2. Initialization

| Zig Function | cot1 Function | Parity | Notes |
|--------------|---------------|--------|-------|
| `MachOWriter.init()` | `MachOWriter_init()` | Same | String table starts with null byte |
| `MachOWriter.deinit()` | N/A (no dealloc in cot1) | Acceptable | Bootstrap doesn't need cleanup |
| - | `MachOWriter_allocateStorage()` | cot1 only | Module-level storage allocation |

### 3. Symbol Management

| Zig Function | cot1 Function | Parity | Notes |
|--------------|---------------|--------|-------|
| `addSymbol()` | `MachOWriter_addSymbol()` | Same | Adds to symbols + string table |
| (implicit in write()) | `MachOWriter_findSymbol()` | **Gap** | cot1 has O(n) linear search |
| (StringHashMap at write) | (none) | **Critical Gap** | cot1 has no HashMap for symbol lookup |

### 4. Relocation Management

| Zig Function | cot1 Function | Parity | Notes |
|--------------|---------------|--------|-------|
| `addRelocation()` | `MachOWriter_addReloc()` | **Critical Gap** | Zig stores name, cot1 stores index |
| `addDataRelocation()` | `MachOWriter_addDataReloc()` | Same | Wrapper function |
| (in write(): sym lookup) | (in addReloc: sym lookup) | **Critical Gap** | Wrong timing |

### 5. Code/Data Section Management

| Zig Function | cot1 Function | Parity | Notes |
|--------------|---------------|--------|-------|
| `addCode()` | `MachOWriter_addCode()` | Same | Append to text section |
| `addData()` | `MachOWriter_addData()` | Same | Append to data section |
| `addStringLiteral()` | `MachOWriter_addStringLiteral()` | Same | Add null-terminated string |
| `addGlobalVariable()` | `MachOWriter_addDataZeros()` | Same | Zero-filled allocation |

### 6. Output Helpers

| Zig Function | cot1 Function | Parity | Notes |
|--------------|---------------|--------|-------|
| (writer interface) | `MachOWriter_outByte()` | Same | Write single byte |
| (writer interface) | `MachOWriter_outU32()` | Same | Little-endian 32-bit |
| (writer interface) | `MachOWriter_outU64()` | Same | Little-endian 64-bit |
| (writer interface) | `MachOWriter_outZeros()` | Same | Write n zeros |
| (writer interface) | `MachOWriter_outBytes()` | Same | Write byte slice |

### 7. Header/Section Writers

| Zig Function | cot1 Function | Parity | Notes |
|--------------|---------------|--------|-------|
| (inline in write) | `MachOWriter_writeMachHeader()` | Same | Magic, CPU type, flags |
| (inline in write) | `MachOWriter_writeSegmentCmd()` | Same | VM size, file offset |
| (inline in write) | `MachOWriter_writeSection()` | Same | 16-byte names, flags |
| (inline in write) | `MachOWriter_writeSymtabCmd()` | Same | Symbol/string table offsets |

### 8. Main Write Function

| Zig Function | cot1 Function | Parity | Notes |
|--------------|---------------|--------|-------|
| `write()` | `MachOWriter_write()` | **Gap** | Zig builds HashMap first |
| - | `MachOWriter_writeWithDebug()` | Same | Extended version with DWARF |

### 9. DWARF Debug Info

| Zig Function | cot1 Function | Parity | Notes |
|--------------|---------------|--------|-------|
| `generateDebugSections()` | `MachOWriter_generateDebugLine()` | Same | Line number program |
| `generateDebugAbbrev()` | (in genssa.cot) | Same | Abbreviation table |
| `generateDebugInfo()` | (in genssa.cot) | Same | Compilation unit |
| `writeULEB128()` | `DebugLineWriter_writeULEB128()` | Same | LEB128 encoding |
| `writeSLEB128()` | `DebugLineWriter_writeSLEB128()` | Same | Signed LEB128 |
| `sourceOffsetToLine()` | (in genssa.cot) | Same | Byte offset → line number |

---

## Gaps to Close for 95% Parity

### 1. Symbol Index Resolution (CRITICAL)

**Current cot1 approach:**
```cot
fn MachOWriter_addReloc(w: *MachOWriter, ..., target_ptr: *u8, target_len: i64, ...) {
    var sym_idx: i64 = MachOWriter_findSymbol(w, target_ptr, target_len);
    if sym_idx < 0 { sym_idx = 0; }  // WRONG!
    tgt_ptr.* = sym_idx;
}
```

**Required Zig approach:**
```cot
// In addReloc: store the TARGET NAME, not index
fn MachOWriter_addReloc(w: *MachOWriter, ..., target_ptr: *u8, target_len: i64, ...) {
    // Store string offset into strings table (NOT symbol index)
    let name_str_off: i64 = MachOWriter_addString(w, target_ptr, target_len);
    tgt_ptr.* = name_str_off;  // Store name offset
    len_ptr.* = target_len;    // Store name length
}

// In write(): build symbol lookup, add missing externs, THEN resolve indices
fn MachOWriter_write(w: *MachOWriter) i64 {
    // Step 1: Build name → index map (or sorted array)
    // Step 2: For each relocation, if target not in symbols, add as undefined extern
    // Step 3: Write relocations using the lookup
}
```

### 2. External Symbol Deduplication (CRITICAL)

**Current:** Each call to an extern function can create duplicate symbol entries
**Required:** Only add each extern symbol ONCE, at write time

### 3. StringHashMap or Equivalent (HIGH)

**Current:** O(n) linear search in `MachOWriter_findSymbol`
**Required:** O(1) HashMap or sorted array with binary search

cot1 doesn't have std.StringHashMap, but can use:
- StrMap from lib/strmap.cot
- Or sorted parallel arrays with binary search

### 4. Relocation Struct Definition Mismatch (MEDIUM)

The `Reloc` struct in cot1 already defines `target_ptr: *u8` and `target_len: i64`, but `MachOWriter_addReloc` stores a symbol index in `reloc_target_str_offs` instead of the string offset. This is confusing and should be fixed.

---

## Architecture Comparison

### Zig (MachOWriter)
```
MachOWriter struct:
├── allocator: std.mem.Allocator
├── text_data: ArrayListUnmanaged(u8)
├── data: ArrayListUnmanaged(u8)
├── cstring_data: ArrayListUnmanaged(u8)
├── string_literals: ArrayListUnmanaged(StringLiteral)
├── symbols: ArrayListUnmanaged(Symbol)
│   └── Symbol { name: []const u8, value: u64, section: u8, external: bool }
├── relocations: ArrayListUnmanaged(Relocation)
│   └── Relocation { offset: u32, target: []const u8 }  ← STRING, not index
├── data_relocations: ArrayListUnmanaged(ExtRelocation)
├── strings: ArrayListUnmanaged(u8)
├── string_counter: u32
├── line_entries: ArrayListUnmanaged(LineEntry)
├── debug_*_data: ArrayListUnmanaged(u8)
└── debug_*_relocs: ArrayListUnmanaged(DebugReloc)
```

### cot1 (MachOWriter)
```
MachOWriter struct:
├── code: *u8, code_count, code_cap
├── data: *u8, data_count, data_cap
├── sym_name_offsets: *i64       ┐
├── sym_values: *i64             │ Parallel arrays for symbols
├── sym_sections: *i64           │ (avoids struct pointer arithmetic)
├── sym_is_externals: *i64       ┘
├── symbols_count, symbols_cap
├── strings: *u8, strings_count, strings_cap
├── reloc_offsets: *i64          ┐
├── reloc_target_str_offs: *i64  │ Currently stores SYMBOL INDEX (BUG!)
├── reloc_target_lens: *i64      │ Should store string offset + len
├── reloc_types: *i64            │ Parallel arrays for relocations
├── reloc_is_pcrels: *i64        │
├── reloc_lengths: *i64          ┘
├── relocs_count, relocs_cap
├── debug_line: *u8, debug_line_count, debug_line_cap
├── dbg_line_reloc_*: *i64       (parallel arrays)
├── debug_abbrev: *u8, ...
├── debug_info: *u8, ...
├── dbg_info_reloc_*: *i64       (parallel arrays)
└── output: *u8, output_count, output_cap
```

**Key Architecture Difference:** cot1 uses parallel arrays instead of struct arrays to avoid complex pointer arithmetic. This is intentional for bootstrap simplicity but requires careful management.

---

## Testing

### Current Status
- All 166 e2e tests pass (Zig compiler)
- Stage1 compiles stage2 successfully (links without errors)
- **Stage2 produces GARBAGE output** (wrong relocation symbol indices)

### Verification Commands
```bash
# Build stage1 with Zig compiler
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1

# Build stage2 with stage1
/tmp/cot1-stage1 stages/cot1/main.cot -o /tmp/cot1-stage2.o
zig cc /tmp/cot1-stage2.o runtime/cot_runtime.o -o /tmp/cot1-stage2 -lSystem

# Test stage2 (CURRENTLY FAILS - prints garbage)
/tmp/cot1-stage2

# Inspect symbol table for duplicates
nm /tmp/cot1-stage2.o | grep "_write" | wc -l   # Should be 1, is 252
nm /tmp/cot1-stage2.o | grep "_exit" | wc -l    # Should be 1, is 103
```

### Expected After Fix
- Stage2 prints "Cot0 Self-Hosting Compiler v0.2\n"
- Stage3 = Stage2 (identical binaries)

---

## Fix Plan

### Step 1: Change reloc storage to store string offset (not symbol index)

```cot
fn MachOWriter_addReloc(w: *MachOWriter, offset: i64, target_ptr: *u8, target_len: i64,
                   reloc_type: i64, is_pcrel: i64) {
    // Store string into strings table and save offset
    let name_str_off: i64 = MachOWriter_addString(w, target_ptr, target_len);

    let idx: i64 = w.relocs_count;
    (w.reloc_offsets + idx).* = offset;
    (w.reloc_target_str_offs + idx).* = name_str_off;  // String offset, NOT symbol index
    (w.reloc_target_lens + idx).* = target_len;
    (w.reloc_types + idx).* = reloc_type;
    (w.reloc_is_pcrels + idx).* = is_pcrel;
    (w.reloc_lengths + idx).* = 2;

    w.relocs_count = w.relocs_count + 1;
}
```

### Step 2: At write time, collect all relocation targets and add missing extern symbols

```cot
fn MachOWriter_write(w: *MachOWriter) i64 {
    // Step A: Collect all unique extern symbol names from relocations
    // Step B: For each unique name, if not in symbols, add as undefined extern
    // Step C: Build a lookup table (or use StrMap) for name → index
    // Step D: When writing relocations, use lookup to get symbol index
    ...
}
```

### Step 3: Use StrMap or sorted array for O(1) symbol lookup

```cot
// Option A: Use lib/strmap.cot
import "lib/strmap.cot"

fn MachOWriter_write(w: *MachOWriter) i64 {
    var sym_map: StrMap = undefined;
    StrMap_init(&sym_map, 256);

    // Populate map with existing symbols
    var i: i64 = 0;
    while i < w.symbols_count {
        let name_off: i64 = (w.sym_name_offsets + i).*;
        let name_ptr: *u8 = w.strings + name_off;
        let name_len: i64 = strlen(name_ptr);
        StrMap_put(&sym_map, name_ptr, name_len, i);
        i = i + 1;
    }

    // Add missing externs from relocations
    ...
}
```

### Step 4: Fix MachOWriter_writeTextReloc to resolve at write time

```cot
fn MachOWriter_writeTextReloc(w: *MachOWriter, idx: i64, sym_map: *StrMap) {
    let offset: i64 = (w.reloc_offsets + idx).*;
    let target_str_off: i64 = (w.reloc_target_str_offs + idx).*;
    let target_len: i64 = (w.reloc_target_lens + idx).*;
    let target_ptr: *u8 = w.strings + target_str_off;

    // Lookup symbol index using map
    let sym_idx: i64 = StrMap_get(sym_map, target_ptr, target_len);

    MachOWriter_outU32(w, offset);
    let info: i64 = RelocInfo_make(sym_idx, ...);
    MachOWriter_outU32(w, info);
}
```

---

## Recommendations for 95% Parity

1. **Fix relocation symbol resolution** (CRITICAL) - Store target name, resolve at write time
2. **Add extern symbol deduplication** (CRITICAL) - Build set of unique externs
3. **Add HashMap/StrMap for symbol lookup** (HIGH) - O(1) instead of O(n)
4. **Clean up struct vs parallel array comments** (LOW) - Document intentional choices

Current estimate: **~70% parity**, can reach **95%** with relocation fix.

---

## Root Cause Summary

| Issue | Zig Approach | cot1 Approach | Impact |
|-------|--------------|---------------|--------|
| Relocation target storage | String slice | Symbol index | CRITICAL: wrong indices |
| Symbol lookup timing | At write time | At addReloc time | CRITICAL: externs not found |
| Symbol deduplication | HashMap check | None | HIGH: duplicate symbols |
| Symbol lookup algorithm | HashMap O(1) | Linear O(n) | MEDIUM: slow for large files |

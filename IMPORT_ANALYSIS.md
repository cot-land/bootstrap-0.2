# Import Resolution Analysis: Zig vs cot1 Implementation

## Executive Summary

This document provides a detailed comparison of import/path resolution between the Zig driver (`src/driver.zig`, 519 lines) and cot1's import module (`stages/cot1/lib/import.cot`, 388 lines).

**Status: SIGNIFICANT GAPS - NOT AT PARITY**

The cot1 import module is a **manual reimplementation** that lacks key features the Zig version uses.

---

## 1. FUNCTION MAPPING

### Zig driver.zig (7 functions)

| Line | Function | Purpose |
|------|----------|---------|
| 62 | `init` | Initialize driver |
| 70 | `compileSource` | Compile from string |
| 144 | `compileFile` | Compile from path |
| 285 | `normalizePath` | **Canonicalize path via OS** |
| 295 | `parseFileRecursive` | **Recursive import parsing** |
| 375 | `generateCode` | Code generation |
| 499 | `setDebugPhases` | Debug settings |

### cot1 import.cot (12 functions)

| Line | Function | Zig Equivalent |
|------|----------|----------------|
| 61 | `Import_allocateStorage` | (none - manual memory) |
| 85 | `Import_init` | (part of Driver.init) |
| 97 | `Import_isPathImported` | `seen_files.contains()` |
| 125 | `Import_addPath` | `seen_files.put()` |
| 147 | `Import_extractBaseDir` | `std.fs.path.dirname` |
| 176 | `Import_getBaseDir` | (none - global state) |
| 180 | `Import_getBaseDirLen` | (none - global state) |
| 186 | `Import_buildPath` | `std.fs.path.join` |
| 213 | `Import_resolvePath` | **`normalizePath` - DIFFERENT** |
| 282 | `Import_getPathBuf` | (none - global state) |
| 288 | `Import_getDirFromPath` | `std.fs.path.dirname` |
| 321 | `Import_adjustNodePositions` | (none - cot1 specific) |

---

## 2. CRITICAL DIFFERENCE: PATH NORMALIZATION

### Zig normalizePath (line 285-290)

```zig
fn normalizePath(self: *Driver, path: []const u8) ![]const u8 {
    return std.fs.cwd().realpathAlloc(self.allocator, path) catch {
        // If realpath fails, return a copy of the original
        return try self.allocator.dupe(u8, path);
    };
}
```

**What this does:**
- Calls the **operating system's realpath()** function
- Resolves ALL symbolic links
- Canonicalizes ".." and "." components
- Returns absolute path
- Handles edge cases the OS already handles

### cot1 Import_resolvePath (line 213-279)

```cot
fn Import_resolvePath(base_dir: *u8, base_len: i64, rel_path: *u8, rel_len: i64) i64 {
    // Copy base_dir to result buffer first
    var result_len: i64 = 0;
    var i: i64 = 0;
    while i < base_len and result_len < IMPORT_MAX_PATH_LEN {
        let c: *u8 = base_dir + i;
        (im_path_buf + result_len).* = c.*;
        result_len = result_len + 1;
        i = i + 1;
    }

    // Process rel_path, handling ".." by removing last directory component
    i = 0;
    while i < rel_len {
        // Check for "../" at current position
        if i + 2 < rel_len {
            let c0: *u8 = rel_path + i;
            let c1: *u8 = rel_path + i + 1;
            let c2: *u8 = rel_path + i + 2;
            if c0.* == 46 and c1.* == 46 and c2.* == 47 {  // "../"
                // Go up one directory: remove trailing slash first
                if result_len > 0 {
                    result_len = result_len - 1;
                }
                // Remove chars back to previous '/'
                while result_len > 0 {
                    let rc: *u8 = im_path_buf + (result_len - 1);
                    if rc.* == 47 {  // '/'
                        break;
                    }
                    result_len = result_len - 1;
                }
                i = i + 3;  // Skip "../"
                continue;
            }
        }
        // ... more manual string manipulation
    }
}
```

**What this does:**
- Manual character-by-character string manipulation
- Only handles "../" pattern (not "./" or other edge cases)
- Does NOT call OS realpath
- Does NOT resolve symlinks
- Does NOT produce absolute paths
- Has off-by-one risk in bounds checking

### PARITY STATUS: **NO**

| Feature | Zig | cot1 |
|---------|-----|------|
| OS realpath call | YES | NO |
| Symlink resolution | YES | NO |
| Absolute path output | YES | NO |
| Handle "./" | YES (via OS) | NO |
| Handle "/../" edge cases | YES (via OS) | PARTIAL |
| Buffer overflow protection | YES (allocator) | MANUAL (IMPORT_MAX_PATH_LEN) |

---

## 3. CYCLE DETECTION COMPARISON

### Zig (uses StringHashMap)

```zig
fn parseFileRecursive(
    self: *Driver,
    path: []const u8,
    parsed_files: *std.ArrayListUnmanaged(ParsedFile),
    seen_files: *std.StringHashMap(void),  // O(1) lookup
) anyerror!void {
    const canonical_path = try self.normalizePath(path);

    // Check if already parsed (using canonical path)
    if (seen_files.contains(canonical_path)) {
        return;  // Skip
    }

    // Mark as seen
    try seen_files.put(path_copy, {});
    // ...
}
```

### cot1 (uses linear array scan)

```cot
fn Import_isPathImported(path: *u8, path_len: i64) bool {
    var i: i64 = 0;
    while i < im_count {  // O(n) scan
        let stored_len_ptr: *i64 = im_path_lens + i;
        let stored_len: i64 = stored_len_ptr.*;
        if stored_len == path_len {
            // Compare paths character by character
            let stored_path: *u8 = im_paths + (i * IMPORT_MAX_PATH_LEN);
            var match: bool = true;
            var j: i64 = 0;
            while j < path_len {
                // ... O(m) string comparison
            }
        }
        i = i + 1;
    }
    return false;
}
```

### PARITY STATUS: **FUNCTIONAL BUT SLOWER**

| Feature | Zig | cot1 |
|---------|-----|------|
| Lookup complexity | O(1) hash | O(n*m) linear scan |
| Max paths | Unlimited | IMPORT_MAX_PATHS (100) |
| Path comparison | Hash equality | Character-by-character |
| Uses canonical paths | YES | NO (uses raw paths) |

---

## 4. PATH JOINING COMPARISON

### Zig

```zig
const import_full_path = try std.fs.path.join(self.allocator, &.{ file_dir, import_path });
```

Uses standard library path joining that handles:
- Multiple slashes
- Empty components
- Platform-specific separators

### cot1

```cot
fn Import_buildPath(import_path: *u8, import_path_len: i64) i64 {
    var result_len: i64 = 0;
    var i: i64 = 0;

    // Copy base_dir
    while i < im_base_dir_len and result_len < IMPORT_MAX_PATH_LEN {
        let c: *u8 = im_base_dir + i;
        (im_path_buf + result_len).* = c.*;
        result_len = result_len + 1;
        i = i + 1;
    }

    // Copy import_path
    i = 0;
    while i < import_path_len and result_len < IMPORT_MAX_PATH_LEN {
        let c: *u8 = import_path + i;
        (im_path_buf + result_len).* = c.*;
        result_len = result_len + 1;
        i = i + 1;
    }

    return result_len;
}
```

Manual concatenation that:
- Does NOT add separator between components
- Does NOT handle double slashes
- Fixed buffer size limit

### PARITY STATUS: **NO**

---

## 5. DIRECTORY EXTRACTION COMPARISON

### Zig

```zig
const file_dir = std.fs.path.dirname(canonical_path) orelse ".";
```

Standard library function that handles all edge cases.

### cot1

```cot
fn Import_getDirFromPath(path: *u8, path_len: i64, out_dir: *u8, max_len: i64) i64 {
    var last_slash: i64 = -1;
    var i: i64 = 0;
    while i < path_len {
        let c: *u8 = path + i;
        if c.* == 47 {  // '/'
            last_slash = i;
        }
        i = i + 1;
    }

    if last_slash < 0 {
        return 0;  // No directory
    }

    // Copy up to and including the slash
    i = 0;
    while i <= last_slash and i < max_len {
        let c: *u8 = path + i;
        let d: *u8 = out_dir + i;
        d.* = c.*;
        i = i + 1;
    }
    return last_slash + 1;
}
```

Manual implementation that:
- Only handles '/' separator (not Windows '\')
- Returns empty for paths without '/'
- Includes trailing slash (Zig's dirname doesn't)

### PARITY STATUS: **PARTIAL**

---

## 6. MEMORY MANAGEMENT

### Zig

```zig
// Uses allocator throughout
const path_copy = try self.allocator.dupe(u8, canonical_path);
errdefer self.allocator.free(path_copy);
```

- Proper allocator with error handling
- Automatic cleanup via errdefer
- No fixed limits

### cot1

```cot
// Uses global module storage
var im_paths: *u8 = null;           // Flat buffer for all paths
var im_path_buf: *u8 = null;        // Temp buffer for building paths

const IMPORT_MAX_PATHS: i64 = 100;
const IMPORT_MAX_PATH_LEN: i64 = 256;

fn Import_allocateStorage() {
    im_paths = malloc_u8(im_paths_cap);
    // ... no null check!
}
```

- Global mutable state
- Fixed limits (100 paths max, 256 chars max)
- **NO NULL CHECK** after malloc_u8 - potential crash source!

### PARITY STATUS: **NO**

---

## 7. THE CRASH

The crash occurs at:
```
stages/cot1/main.cot:295
let full_path_len: i64 = Import_resolvePath(base_dir, base_dir_len, import_path, import_path_len);
```

After successfully importing 26+ files:
```
Imported: ../ssa/func.cot (4997 nodes)
CRASH: SIGSEGV - NULL pointer dereference at address 0x0
```

### Potential causes:

1. **malloc_u8 returns null, not checked:**
   ```cot
   fn u8list_init_cap(list: *U8List, initial_cap: i64) {
       list.items = malloc_u8(initial_cap);  // Could be null!
   }
   ```
   Then `this_file_dir.items` (which is passed as `base_dir`) could be null.

2. **Buffer overflow in im_path_buf:**
   If path exceeds IMPORT_MAX_PATH_LEN (256), writes go out of bounds.

3. **im_path_buf not initialized:**
   If Import_init() wasn't called, im_path_buf is null.

4. **Corrupted global state:**
   Multiple imports using same global buffers could corrupt state.

---

## 8. HONEST ASSESSMENT

### Is cot1 import at parity with Zig?

**NO.** Major gaps:

| Gap | Impact |
|-----|--------|
| No OS realpath | Paths not canonicalized, duplicates possible |
| No symlink resolution | Same file via symlink treated as different |
| O(n) cycle detection | Slow with many imports |
| Fixed buffer limits | 100 paths max, 256 chars max |
| No null checks | Crashes on allocation failure |
| Global mutable state | Not thread-safe, state corruption risk |
| Manual string handling | Off-by-one bugs, edge cases |

### What would be needed for parity:

1. **Add realpath call** - Need `extern fn realpath(...)` and use it
2. **Add null checks** - After every malloc_u8 call
3. **Use hash map** - For O(1) cycle detection
4. **Remove fixed limits** - Use dynamic allocation
5. **Handle edge cases** - "./", multiple slashes, Windows paths

### Why it "worked" until now:

Stage1 compiling small test files doesn't hit the edge cases. Stage2 compiling cot1 itself (69+ files with complex "../" paths) exposes the bugs.

---

## 9. RECOMMENDED IMMEDIATE FIX

Add null check in main.cot:307:

```cot
var this_file_dir: U8List = undefined;
u8list_init_cap(&this_file_dir, 256);

// ADD THIS CHECK:
if this_file_dir.items == null {
    print("  Error: Failed to allocate memory for import directory\n");
    return 0;
}
```

And in Import_resolvePath, check im_path_buf:

```cot
fn Import_resolvePath(base_dir: *u8, base_len: i64, rel_path: *u8, rel_len: i64) i64 {
    // ADD THIS CHECK:
    if im_path_buf == null or base_dir == null {
        return 0;
    }
    // ...
}
```

This won't achieve parity, but will prevent the crash.

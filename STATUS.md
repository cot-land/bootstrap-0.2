# Bootstrap 0.2 - Self-Hosting Roadmap

**Last Updated: 2026-01-15**

## Current State

**110 e2e tests passing.** Core language features complete. Now focused on features required for self-hosting.

---

## Self-Hosting Requirements Analysis

A self-hosting Cot compiler needs to:
1. **Read source files** from disk
2. **Tokenize** source into tokens (Scanner)
3. **Parse** tokens into AST (Parser)
4. **Type check** the AST (Checker)
5. **Generate code** (Lowerer → SSA → ARM64)
6. **Write object files** to disk

### Language Features Needed

| Category | Feature | Status | Priority | Notes |
|----------|---------|--------|----------|-------|
| **I/O** | Read file | ❌ TODO | P0 | Can't compile without reading source |
| **I/O** | Write file | ❌ TODO | P0 | Can't emit object files |
| **Memory** | Heap allocation | ✅ Done | P0 | `malloc()` via extern fn |
| **Memory** | Free/deallocation | ✅ Done | P0 | `free()` via extern fn |
| **Memory** | @sizeOf builtin | ✅ Done | P0 | Compile-time type sizes |
| **Strings** | String comparison | ✅ Done | P0 | `s1 == s2` for keywords |
| **Strings** | String indexing | ✅ Done | P0 | `s[i]` for char access |
| **Strings** | String concatenation | ❌ TODO | P1 | Error messages |
| **Control** | Switch statement | ❌ TODO | P1 | Token/AST dispatch |
| **Data** | Global constants | ❌ TODO | P1 | `const EOF = 0;` |
| **Modules** | Import statement | ❌ TODO | P1 | Split code into files |
| **Functions** | Indirect calls | 🔶 Partial | P1 | `f(x)` where f is variable |
| **Types** | Integer casts | ❌ TODO | P2 | `@intCast(u8, x)` |
| **Operators** | Bitwise NOT | ❌ TODO | P2 | `~x` |
| **Operators** | Compound assign | ❌ TODO | P3 | `x += 1` |
| **Control** | Defer | ❌ TODO | P3 | Cleanup on scope exit |

---

## Execution Plan

### Phase 1: Verify String Operations ✅ COMPLETE

**Completed:**
- ✅ String comparison (`s1 == s2`, `s1 != s2`) - Fixed deduplication bug in MachO writer
- ✅ String indexing (`s[0]`, `s[i]`) - Fixed type-sized load bug in codegen
- ✅ Added `COT_DEBUG=strings` for tracing strings through pipeline
- ✅ Enhanced debug framework with type information

**Implementation Notes:**
- Strings are `[]u8` slices (ptr + len, 16 bytes)
- Comparison: check lengths first, then compare pointers (Go's pattern)
- String literals deduplicated at IR level AND MachO symbol level
- SSA builder directly accesses slice_make args to avoid slice_ptr/slice_len codegen issues
- Codegen uses `TypeRegistry.basicTypeSize()` to emit correct load/store sizes (LDRB for u8, etc.)

**Key Bug Fixes (2026-01-15):**
- Load/store always used 64-bit LDR/STR regardless of type
- Added `LdStSize` enum and `encodeLdrStrSized()` to asm.zig
- Debug output now shows types: `v18: u8(1B) = load` and `LDRb w1, [x0] (load u8, 1B)`
- String slicing: `slice_local` must handle slices (load ptr first) vs arrays (inline data)

**All tests added to all_tests.cot:**
- `test_string_index_first/middle` - verify `s[i]` returns correct byte
- `test_string_slice` - verify `s[0:3]` has correct length
- `test_string_slice_content` - verify slice content is correct

---

### Phase 2: File I/O via System Calls (P0) - COMPLETE

**Goal:** Read source files, write object files.

**Approach:** Use libc via `extern fn` declarations (resolved by linker)

**Completed (2026-01-15):**
- ✅ `extern fn` syntax for declaring external functions
- ✅ Slice field access: `s.ptr` and `s.len` for accessing slice internals
- ✅ Can call libc functions: `write(1, msg.ptr, msg.len)` prints to stdout
- ✅ `open()`, `read()`, `close()` wrappers working
- ✅ Address-of array element: `&buf[0]` for passing buffer pointers

**Implementation Notes:**
- `extern fn name(args) ret;` - declares function resolved by linker
- Compiler adds `_` prefix for Darwin C ABI automatically
- Extern functions skip lowering - no IR/SSA generated
- Symbol marked as extern in checker, linker resolves from libSystem
- Added `addr_index` IR node for `&arr[i]` address computation

```cot
// Example: Read file contents
extern fn open(path: *u8, flags: i32, mode: i32) i32;
extern fn read(fd: i32, buf: *i64, count: i64) i64;
extern fn close(fd: i32) i32;

fn main() i64 {
    let path: string = "/tmp/test.txt";
    let fd: i32 = open(path.ptr, 0, 0);
    if fd < 0 { return 1; }

    var buf: [8]i64 = [0, 0, 0, 0, 0, 0, 0, 0];
    let n: i64 = read(fd, &buf[0], 64);
    close(fd);
    return n;
}
```

**Remaining for high-level file API:**
- Helper functions: `readFile(path) -> string`, `writeFile(path, data)`
- These require memory allocation (Phase 3)

**Go Reference:** `~/learning/go/src/syscall/` for syscall patterns

---

### Phase 3: Memory Allocation (P0) - COMPLETE

**Goal:** Dynamic allocation for AST nodes, tokens, strings.

**Completed (2026-01-15):**
- ✅ `@sizeOf(T)` builtin - compile-time type size computation
- ✅ `@alignOf(T)` builtin - compile-time type alignment
- ✅ `extern fn malloc/free` - links to libc for memory management
- ✅ Pointer dereferencing - `ptr.*` for read/write through pointers

**Implementation Notes:**
- `@sizeOf(T)` evaluates at compile-time (no runtime cost), following Go's pattern
- Uses `TypeRegistry.sizeOf()` to compute sizes
- Emits `const_int` IR node with computed size
- Memory allocation via libc: `extern fn malloc(size: i64) *T;`

```cot
// Dynamic allocation pattern
extern fn malloc(size: i64) *i64;
extern fn free(ptr: *i64);

fn main() i64 {
    let ptr: *i64 = malloc(@sizeOf(i64));
    ptr.* = 42;
    let val: i64 = ptr.*;
    free(ptr);
    return val;  // 42
}
```

**Supported by @sizeOf:**
- Primitive types: `i64` (8), `i32` (4), `u8` (1), `bool` (1)
- Pointer types: `*T` (8 bytes on 64-bit)
- Array types: `[N]T` (N × sizeof(T))
- Struct types: computed based on fields

**Go Reference:** `~/learning/go/src/cmd/compile/internal/types2/builtins.go` for sizeof/alignof pattern

---

### Phase 4: Global Constants (P1)

**Goal:** Define constants at file scope.

```cot
const MAX_TOKENS: i64 = 10000;
const EOF: i64 = 0;

fn main() i64 {
    return MAX_TOKENS;  // Use constant
}
```

**Implementation Steps:**
1. Parser: Handle `const` declarations at top level
2. Checker: Register constants in global scope
3. Lowerer: Inline constant values (no runtime storage)

**Tests:**
- `test_const_int` - Integer constant
- `test_const_use` - Use constant in expression
- `test_const_in_array_size` - `var arr: [MAX_SIZE]i64`

---

### Phase 5: Switch Statement (P1)

**Goal:** Efficient dispatch on values.

```cot
switch tok.kind {
    .ident => return handleIdent(),
    .number => return handleNumber(),
    .lparen, .rparen => return handleParen(),
    else => return handleOther(),
}
```

**Implementation Steps:**
1. Parser: Parse switch expression and cases
2. Checker: Verify case types match switch expression
3. Lowerer: Convert to chained branches or jump table
4. Consider: Start with if-else lowering, optimize later

**Tests:**
- `test_switch_int` - Switch on integer
- `test_switch_enum` - Switch on enum value
- `test_switch_default` - Default case
- `test_switch_multi` - Multiple values per case

---

### Phase 6: Indirect Function Calls (P1)

**Goal:** Call functions through variables.

```cot
fn add(a: i64, b: i64) i64 { return a + b; }

fn main() i64 {
    var f: fn(i64, i64) -> i64 = add;
    return f(20, 22);  // Indirect call - NOT YET WORKING
}
```

**Current State:** Function types work, assignment works, but calling through variable fails.

**Implementation Steps:**
1. Modify `lowerCall` to detect if callee is a variable
2. For variables: emit `load` of function pointer, then indirect call
3. Add `call_indirect` IR node (or modify existing call)
4. Codegen: Use `BLR` (branch-link-register) instead of `BL`

**Tests:**
- `test_fn_ptr_call` - Call through function pointer
- `test_fn_ptr_param` - Pass function as parameter
- `test_fn_ptr_return` - Return function from function

---

### Phase 7: Import/Multiple Files (P1)

**Goal:** Split compiler into multiple source files.

```cot
// scanner.cot
fn scan(source: string) []Token { ... }

// parser.cot
import "scanner.cot";
fn parse(tokens: []Token) Ast { ... }

// main.cot
import "parser.cot";
fn main() i64 { ... }
```

**Implementation Steps:**
1. Parser: Handle `import "path"` declarations
2. Driver: Track imported files, avoid double-import
3. Checker: Merge symbol tables from imports
4. Compilation order: Topological sort by dependencies

**Tests:**
- `test_import_simple` - Import and use function
- `test_import_type` - Import and use struct type
- `test_import_chain` - A imports B imports C

---

### Phase 8: Type Casts (P2)

**Goal:** Convert between numeric types.

```cot
let big: i64 = 1000;
let small: u8 = @intCast(u8, big);  // Truncate to u8
let unsigned: u64 = @bitCast(u64, signed);  // Reinterpret bits
```

**Implementation Steps:**
1. Parser: Handle `@intCast(Type, expr)` syntax
2. Checker: Validate cast is reasonable
3. Lowerer: Emit appropriate conversion ops
4. Codegen: Emit truncation/extension instructions

---

## Milestone Targets

| Milestone | Features | Goal |
|-----------|----------|------|
| **M1: Strings verified** | String ops work | Confidence to proceed |
| **M2: Can read files** | File I/O | Read source.cot |
| **M3: Dynamic memory** | Allocation | Build data structures |
| **M4: Language complete** | Constants, switch, imports | Write compiler in Cot |
| **M5: Self-hosting** | Compile self | Victory! |

---

## Completed Features (Reference)

### Tier 1: Core Language ✅
- Integer literals, arithmetic, comparisons
- Boolean type, local variables
- Functions (0-8+ args), recursion
- If/else, while loops, break/continue
- Structs (simple, nested, large)

### Tier 2: Data Types ✅
- String literals and type, len() builtin
- Character literals, u8 type
- Fixed arrays, array literals, indexing
- Slices, slice from array, implicit end

### Tier 3: Memory & Pointers ✅
- Pointer types *T, address-of &x
- Dereference ptr.*, pointer parameters
- Optional types ?T, null literal

### Tier 4: Enums ✅
- Enum declaration, value access
- Enum comparison, enum parameters

### Tier 5: Operators ✅
- Bitwise AND, OR, XOR, shifts
- Logical AND, OR with short-circuit

### Tier 6: Control Flow ✅
- For-in loops (array, slice, range)
- Else-if chains

---

## Technical Reference Docs

- [CLAUDE.md](CLAUDE.md) - Development guidelines, Zig 0.15 API
- [SYNTAX.md](SYNTAX.md) - Cot language syntax reference
- [DATA_STRUCTURES.md](DATA_STRUCTURES.md) - Go-to-Zig translations
- [REGISTER_ALLOC.md](REGISTER_ALLOC.md) - Register allocator algorithm
- [TESTING_FRAMEWORK.md](TESTING_FRAMEWORK.md) - Testing approach

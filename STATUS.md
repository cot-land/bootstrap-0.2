# Bootstrap 0.2 - Self-Hosting Roadmap

**Last Updated: 2026-01-16**

## Current State

**158 e2e tests passing.** Core language features complete.

### Cot0 Self-Hosting Progress

| Module | Status | Tests |
|--------|--------|-------|
| token.cot | ✅ Complete | N/A (data only) |
| scanner.cot | ✅ Complete | 11/11 pass |
| ast.cot | ✅ Complete | 7/7 pass |
| parser.cot | 🔧 In Progress | Compiles, tests failing |

### Recent Bug Fixes (2026-01-16)

**Compiler Bugs Fixed:**
- BUG-014: Switch statements - Switch could only be used as expression returning a value. Now supports statement mode with side effects in branches. Fix: detect void result type and generate if-else control flow instead of nested selects (following Go's walk/switch.go pattern). ✅
- BUG-013: String concatenation in loops - Segfault when doing `s = s + "x"` in loops. Root cause: `expand_calls.zig` directly assigned to `call_val.args` without updating use counts. Fix: use `resetArgs()` and `addArg()` to properly maintain use counts (following Go's AddArg pattern). ✅
- BUG-012: `ptr.*.field` codegen - Was loading entire struct via LDP then treating first 8 bytes as pointer. Fix: detect `.deref` in `lowerFieldAccess` and pass pointer directly to `emitFieldValue` (following Go's ODOTPTR pattern). ✅
- BUG-011: `off_ptr` register clobbering - When regalloc assigned the same register to both `local_addr` and a subsequent `load`, the `off_ptr` would use the clobbered value. Fix: `off_ptr` codegen now regenerates `local_addr` directly from `self.func.local_offsets` when the base is a `local_addr` op. ✅
- BUG-010: `slice_make` clobbering arg registers - When a string param was followed by other params, `slice_make` was emitted BEFORE the subsequent `arg` ops. This allowed regalloc to assign `slice_make` to x2, overwriting the pool argument before it was captured. Fix: 3-phase param init - create ALL `arg` ops first, THEN `slice_make`, THEN stores. ✅
- BUG-007: Struct literal type lookup - `checkStructInit` was using `scope.lookup()` instead of `types.lookupBasic()`. Types come from the type registry, not the symbol table. ✅
- BUG-008: `&ptr.field` pattern - Added handling for address-of when base is pointer-to-struct (e.g., `&p.scanner` where `p: *Parser`) ✅
- BUG-009: Pointer arithmetic scaling - Was already working; follows Zig's design (auto-scales by element size). ✅

**Previous Bug Fixes:**
- BUG-005: Logical NOT (EOR vs MVN for booleans) ✅
- BUG-006: `not` keyword as synonym for `!` ✅
- BUG-002: Struct literals (`Point{ .x = 10, .y = 20 }`) ✅
- BUG-004: Large struct returns (>16B via hidden pointer) ✅
- String indexing (`s[i]` returns u8) ✅
- `len()` on field access (`len(s.source)`) ✅
- `string_make` decomposition for SSA storage ✅
- `@string(ptr, len)` builtin for string construction ✅
- 3-way register cycle resolution in function call argument passing ✅

**Runtime Library:** String concatenation uses the runtime library at `runtime/cot_runtime.o`. The compiler auto-links it when found. See [Runtime Library](#runtime-library) section below.

**Self-Hosting:** Bootstrapping via staged compilers in `cot0/` through `cot9/`. See [cot0/README.md](cot0/README.md) for the plan.

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
| **I/O** | Read file | ✅ Done | P0 | `stdlib/io.cot:readFile()` |
| **I/O** | Write file | ✅ Done | P0 | `stdlib/io.cot:writeFile()` |
| **Memory** | Heap allocation | ✅ Done | P0 | `malloc()` via extern fn |
| **Memory** | Free/deallocation | ✅ Done | P0 | `free()` via extern fn |
| **Memory** | @sizeOf builtin | ✅ Done | P0 | Compile-time type sizes |
| **Strings** | String comparison | ✅ Done | P0 | `s1 == s2` for keywords |
| **Strings** | String indexing | ✅ Done | P0 | `s[i]` for char access |
| **Strings** | String concatenation | ✅ Done | P1 | Requires runtime library |
| **Control** | Switch statement | ✅ Done | P1 | Token/AST dispatch |
| **Data** | Global constants | ✅ Done | P1 | Compile-time evaluation + inlining |
| **Modules** | Import statement | ✅ Done | P1 | Split code into files |
| **Functions** | Indirect calls | ✅ Done | P1 | `f(x)` where f is variable |
| **Types** | Integer casts | ✅ Done | P2 | `@intCast(u8, x)` |
| **Operators** | Bitwise NOT | ✅ Done | P2 | `~x` |
| **Operators** | Compound assign | ✅ Done | P3 | `x += 1`, `x &= y`, etc. |
| **I/O** | print/println | ✅ Done | P2 | `print("msg")`, `println("msg")` |
| **Control** | Defer | ✅ Done | P3 | Cleanup on scope exit |
| **Data** | Global variables | ✅ Done | P2 | Mutable global state |

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

**High-level API (stdlib/io.cot):**
- ✅ `readFile(path: string, buf: *u8, buf_size: i64) i64` - read file into buffer
- ✅ `writeFile(path: string, data: *u8, len: i64) i64` - write buffer to file
- Test: `test/e2e/test_file_io.cot` - Exit 5 (reads "hello")

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

### Phase 4: Global Constants (P1) - COMPLETE

**Goal:** Define constants at file scope.

**Completed (2026-01-15):**
- ✅ Compile-time constant evaluation following Go's `constant.Value` pattern
- ✅ Constant expressions (arithmetic, comparisons, references to other constants)
- ✅ Inlining: constants are not stored at runtime, values baked into code

**Implementation Notes:**
- Checker: `evalConstExpr()` recursively evaluates constant expressions
- Symbol stores `const_value: ?i64` for evaluated constants
- Lowerer: `const_values` map stores constants, inlined via `const_int` IR node
- No runtime storage needed - values directly embedded in generated code

```cot
const MAX_TOKENS = 10000;
const BUFFER_SIZE = MAX_TOKENS * 2;  // Constant expressions work

fn main() i64 {
    return BUFFER_SIZE;  // Inlined as: mov x0, #20000
}
```

**Go Reference:** `~/learning/go/src/cmd/compile/internal/types2/decl.go` for constant evaluation

---

### Phase 5: Switch Statement (P1) - COMPLETE

**Goal:** Efficient dispatch on values.

**Completed (2026-01-15, updated 2026-01-16):**
- ✅ Parser: `parseSwitchExpr()` handles all cases including multi-pattern
- ✅ Checker: `checkSwitchExpr()` verifies case types match subject
- ✅ Lowerer: `lowerSwitchExpr()` supports both expression and statement modes
- ✅ SSA Builder: `cond_select` op for conditional value selection
- ✅ Codegen: ARM64 CSEL instruction for efficient conditional select

**Implementation Notes:**
- **Expression mode** (non-void result): Nested select operations using ARM64 CSEL
- **Statement mode** (void result): If-else control flow blocks (following Go's walk/switch.go)
- Multiple patterns per case combined with OR: `1, 2 => x` becomes `(x == 1) or (x == 2)`

```cot
// Expression mode - returns a value
let result: i64 = switch x {
    1 => 10,
    2 => 20,
    else => 99,
};

// Statement mode - side effects in branches
var result: i64 = 0;
switch x {
    1 => { result = 10; }
    2 => { result = 20; }
    else => { result = 99; }
}
```

**Tests:**
- `test_switch_int` - Switch on integer
- `test_switch_default` - Default (else) case
- `test_switch_multi` - Multiple values per case
- `test_switch_first` - First case match

---

### Phase 6: Indirect Function Calls (P1) - COMPLETE

**Goal:** Call functions through variables.

**Completed (2026-01-15):**
- ✅ `call_indirect` IR node for indirect calls
- ✅ `closure_call` SSA op (Go's ClosureCall pattern)
- ✅ ARM64 BLR instruction for indirect branch
- ✅ Function type resolution in lowerer

**Implementation Notes:**
- Lowerer detects if callee name is a local variable with function type
- Emits `load_local` to get function pointer, then `call_indirect`
- SSA builder converts to `closure_call` with function pointer as first arg
- Codegen uses BLR (Branch Link Register) instead of BL

```cot
fn add(a: i64, b: i64) i64 { return a + b; }

fn main() i64 {
    var f: fn(i64, i64) -> i64 = add;
    return f(20, 22);  // 42 - indirect call works!
}
```

**Tests:**
- `test_fn_ptr_call` - Call through function pointer
- `test_fn_ptr_reassign` - Reassign and call
- `test_fn_ptr_no_args` - Function pointer with no args

---

### Phase 6.5: String Concatenation (P1) - COMPLETE

**Goal:** Concatenate strings with `+` operator.

**Completed (2026-01-15):**
- ✅ Type checker accepts `string + string` → `string`
- ✅ SSA `string_concat` operation
- ✅ `expand_calls` pass decomposes strings into ptr/len components
- ✅ ARM64 codegen calls `__cot_str_concat` runtime function
- ✅ `select_n` extracts ptr/len from call result
- ✅ `string_make` reassembles string from components

**Implementation Notes:**
- String concatenation requires the runtime library (`runtime/cot_runtime.zig`)
- The `expand_calls` pass (following Go's pattern) decomposes aggregate types
- `__cot_str_concat(ptr1, len1, ptr2, len2)` returns `(ptr, len)` in `(x0, x1)`
- `expandCallResults()` creates `select_n[0]` (x0/ptr) and `select_n[1]` (x1/len) immediately after call
- `string_make` aggregates the select_n values back into a string type
- After BL, x1 is saved to x8 to prevent clobbering when select_n writes to x1

**Runtime Library:**
The compiler generates calls to `___cot_str_concat` which must be linked:
```bash
# Compile runtime (once)
zig build-obj -OReleaseFast runtime/cot_runtime.zig -femit-bin=runtime/cot_runtime.o

# Compile Cot program
./zig-out/bin/cot myprogram.cot -o myprogram

# Link with runtime (linker error without this!)
zig cc myprogram.o runtime/cot_runtime.o -o myprogram -lSystem
```

**Tests:**
- `test_str_concat_basic` - `len("hello" + " world")` = 11
- `test_str_concat_empty` - Concatenation with empty string
- `test_str_concat_multi` - Multiple concatenations

**Go Reference:** `~/learning/go/src/cmd/compile/internal/ssa/expand_calls.go`

**Key Bug Fix (2026-01-16) - BUG-004: Large Struct Returns:**
- Structs > 16 bytes now correctly returned via hidden pointer (ARM64 AAPCS64)
- Go's pattern: pre-allocate hidden return space in frame, not dynamic SP adjustment
- Caller: pass frame-relative address in x8
- Callee: save x8 to x19, copy result to [x19] on return
- Test: `cot0/frontend/token_test.cot` - 5/5 tests pass

**Unified ABI Analysis (2026-01-16):**
Following Go's pattern, ABI decisions are now computed once and shared by all phases:
- `ABIParamResultInfo` in `src/ssa/abi.zig` is the single source of truth
- Added `uses_hidden_return` and `hidden_return_size` fields
- `AuxCall` accessor methods: `usesHiddenReturn()`, `hiddenReturnSize()`, `offsetOfArg()`, `offsetOfResult()`
- Removed old `hidden_ret_ptr` and `hidden_ret_size` fields from `AuxCall`
- Both `expand_calls` and codegen use the same ABI analysis - no more guesswork

---

### Phase 7: Import/Multiple Files (P1) - COMPLETE

**Goal:** Split compiler into multiple source files.

**Completed (2026-01-15):**
- ✅ Parser: `import "path"` declarations
- ✅ Driver: Multi-phase compilation following Go's LoadPackage pattern
- ✅ Shared global scope: Symbols from imports available to importing file
- ✅ Cycle prevention: Track imported files to prevent infinite loops
- ✅ Dependency ordering: Imports processed before importing file

**Implementation Notes:**
- Follows Go's `~/learning/go/src/cmd/compile/internal/noder/noder.go` pattern
- Parse all files first (keeping ASTs alive), then type check, then lower
- Files processed in dependency order: imports before importer
- All IR functions collected and generated together

```cot
// math.cot
fn add(a: i64, b: i64) i64 { return a + b; }

// main.cot
import "math.cot"
fn main() i64 { return add(10, 20); }  // 30
```

**Tests (manual verification):**
- ✅ `test_import_simple` - Import and use function (Exit: 72)
- ✅ `test_import_chain` - A imports B imports C (Exit: 40)

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

## Runtime Library

The Cot compiler requires a small runtime library for certain operations. This is `runtime/cot_runtime.zig`.

### Functions Provided

| Function | Signature | Purpose |
|----------|-----------|---------|
| `__cot_str_concat` | `(ptr1, len1, ptr2, len2) -> (ptr, len)` | String concatenation |

### Auto-Linking (Default)

The compiler automatically links the runtime library when it can find it:

```bash
# Just compile and run - runtime is auto-linked!
./zig-out/bin/cot program.cot -o program
./program
```

The compiler searches for `runtime/cot_runtime.o` in:
1. Current working directory (`./runtime/cot_runtime.o`)
2. Relative to the compiler binary (`../../runtime/cot_runtime.o`)

### Manual Linking (If Auto-Link Fails)

If the runtime isn't found, you'll see a warning. Build and link manually:

```bash
# 1. Compile the runtime (once)
zig build-obj -OReleaseFast runtime/cot_runtime.zig -femit-bin=runtime/cot_runtime.o

# 2. Compile your Cot program
./zig-out/bin/cot program.cot -o program

# 3. Link together manually
zig cc program.o runtime/cot_runtime.o -o program -lSystem
```

### Common Error

If you see:
```
error: undefined symbol: ___cot_str_concat
```

This means the runtime library wasn't linked. Either:
1. Ensure `runtime/cot_runtime.o` exists and is findable
2. Use manual linking as shown above

---

## Technical Reference Docs

- [CLAUDE.md](CLAUDE.md) - Development guidelines, Zig 0.15 API
- [SYNTAX.md](SYNTAX.md) - Cot language syntax reference
- [DATA_STRUCTURES.md](DATA_STRUCTURES.md) - Go-to-Zig translations
- [REGISTER_ALLOC.md](REGISTER_ALLOC.md) - Register allocator algorithm
- [TESTING_FRAMEWORK.md](TESTING_FRAMEWORK.md) - Testing approach

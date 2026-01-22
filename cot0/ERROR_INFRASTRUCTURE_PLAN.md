# cot0 Comprehensive Error Infrastructure Plan

## Overview
Transform cot0 from a compiler that silently segfaults into one that provides clear, actionable error messages for every failure mode. This is a foundational investment that will pay dividends for all future development.

---

## Phase 1: Core Error Primitives (lib/error.cot)

### 1.1 Basic Panic Function
```cot
fn panic(msg: *u8) {
    write(2, "PANIC: ", 7);  // stderr
    // Calculate msg length
    var len: i64 = 0;
    while (msg + len).* != 0 { len = len + 1; }
    write(2, msg, len);
    write(2, "\n", 1);
    exit(1);
}
```

### 1.2 Panic with Context
```cot
fn panic_at(msg: *u8, file: *u8, line: i64, func: *u8) {
    write(2, "PANIC at ", 9);
    print_str(file);
    write(2, ":", 1);
    print_int_stderr(line);
    write(2, " in ", 4);
    print_str(func);
    write(2, ": ", 2);
    print_str(msg);
    write(2, "\n", 1);
    exit(1);
}
```

### 1.3 Assert Function
```cot
fn assert(condition: bool, msg: *u8) {
    if not condition {
        panic(msg);
    }
}
```

### 1.4 Assert with Context
```cot
fn assert_at(condition: bool, msg: *u8, file: *u8, line: i64, func: *u8) {
    if not condition {
        panic_at(msg, file, line, func);
    }
}
```

### 1.5 Null Check
```cot
fn assert_not_null(ptr: *u8, name: *u8) {
    if ptr == null {
        write(2, "NULL POINTER: ", 14);
        print_str(name);
        write(2, " is null\n", 9);
        exit(1);
    }
}

fn assert_not_null_i64(ptr: *i64, name: *u8) {
    if ptr == null {
        write(2, "NULL POINTER: ", 14);
        print_str(name);
        write(2, " is null\n", 9);
        exit(1);
    }
}
```

### 1.6 Bounds Check
```cot
fn assert_bounds(index: i64, length: i64, name: *u8) {
    if index < 0 or index >= length {
        write(2, "BOUNDS ERROR: ", 14);
        print_str(name);
        write(2, "[", 1);
        print_int_stderr(index);
        write(2, "] out of bounds (length=", 24);
        print_int_stderr(length);
        write(2, ")\n", 2);
        exit(1);
    }
}
```

### 1.7 Unreachable
```cot
fn unreachable(msg: *u8) {
    write(2, "UNREACHABLE: ", 13);
    print_str(msg);
    write(2, "\n", 1);
    exit(1);
}
```

### 1.8 stderr Helpers
```cot
fn print_str_stderr(s: *u8) {
    var len: i64 = 0;
    while (s + len).* != 0 { len = len + 1; }
    write(2, s, len);
}

fn print_int_stderr(n: i64) {
    // Convert int to string and write to stderr
    var buf: [32]u8;
    var i: i64 = 31;
    var is_neg: bool = n < 0;
    if is_neg { n = 0 - n; }
    if n == 0 {
        buf[i] = 48; // '0'
        i = i - 1;
    }
    while n > 0 {
        buf[i] = 48 + (n % 10);
        n = n / 10;
        i = i - 1;
    }
    if is_neg {
        buf[i] = 45; // '-'
        i = i - 1;
    }
    write(2, &buf[i + 1], 31 - i);
}
```

---

## Phase 2: Safe Memory Allocation (lib/safe_alloc.cot)

### 2.1 Safe malloc_u8
```cot
var g_alloc_count: i64 = 0;
var g_alloc_bytes: i64 = 0;

fn safe_malloc_u8(size: i64, name: *u8) *u8 {
    if size <= 0 {
        write(2, "ALLOC ERROR: ", 13);
        print_str(name);
        write(2, " requested invalid size ", 24);
        print_int_stderr(size);
        write(2, "\n", 1);
        exit(1);
    }
    let ptr: *u8 = malloc_u8(size);
    if ptr == null {
        write(2, "ALLOC FAILED: ", 14);
        print_str(name);
        write(2, " could not allocate ", 20);
        print_int_stderr(size);
        write(2, " bytes\n", 7);
        exit(1);
    }
    g_alloc_count = g_alloc_count + 1;
    g_alloc_bytes = g_alloc_bytes + size;
    return ptr;
}
```

### 2.2 Safe malloc_i64
```cot
fn safe_malloc_i64(count: i64, name: *u8) *i64 {
    if count <= 0 {
        write(2, "ALLOC ERROR: ", 13);
        print_str(name);
        write(2, " requested invalid count ", 25);
        print_int_stderr(count);
        write(2, "\n", 1);
        exit(1);
    }
    let ptr: *i64 = malloc_i64(count);
    if ptr == null {
        write(2, "ALLOC FAILED: ", 14);
        print_str(name);
        write(2, " could not allocate ", 20);
        print_int_stderr(count);
        write(2, " i64 elements\n", 14);
        exit(1);
    }
    g_alloc_count = g_alloc_count + 1;
    g_alloc_bytes = g_alloc_bytes + (count * 8);
    return ptr;
}
```

### 2.3 Allocation Stats
```cot
fn print_alloc_stats() {
    print("Allocations: ");
    print_int(g_alloc_count);
    print(", Total bytes: ");
    print_int(g_alloc_bytes);
    print("\n");
}
```

---

## Phase 3: Safe Array Access Helpers

### 3.1 Safe Array Get (i64)
```cot
fn safe_get_i64(arr: *i64, index: i64, length: i64, name: *u8) i64 {
    assert_not_null_i64(arr, name);
    assert_bounds(index, length, name);
    return (arr + index).*;
}
```

### 3.2 Safe Array Set (i64)
```cot
fn safe_set_i64(arr: *i64, index: i64, length: i64, value: i64, name: *u8) {
    assert_not_null_i64(arr, name);
    assert_bounds(index, length, name);
    let ptr: *i64 = arr + index;
    ptr.* = value;
}
```

### 3.3 Safe Array Get (u8)
```cot
fn safe_get_u8(arr: *u8, index: i64, length: i64, name: *u8) u8 {
    assert_not_null(arr, name);
    assert_bounds(index, length, name);
    return (arr + index).*;
}
```

### 3.4 Safe Array Set (u8)
```cot
fn safe_set_u8(arr: *u8, index: i64, length: i64, value: u8, name: *u8) {
    assert_not_null(arr, name);
    assert_bounds(index, length, name);
    let ptr: *u8 = arr + index;
    ptr.* = value;
}
```

---

## Phase 4: Debug Tracing Infrastructure

### 4.1 Global Debug Flag
```cot
var g_debug_trace: bool = false;
var g_debug_verbose: bool = false;
var g_trace_depth: i64 = 0;
```

### 4.2 Trace Function Entry
```cot
fn trace_enter(func_name: *u8) {
    if not g_debug_trace { return; }
    var i: i64 = 0;
    while i < g_trace_depth {
        write(2, "  ", 2);
        i = i + 1;
    }
    write(2, "-> ", 3);
    print_str_stderr(func_name);
    write(2, "\n", 1);
    g_trace_depth = g_trace_depth + 1;
}
```

### 4.3 Trace Function Exit
```cot
fn trace_exit(func_name: *u8) {
    if not g_debug_trace { return; }
    g_trace_depth = g_trace_depth - 1;
    var i: i64 = 0;
    while i < g_trace_depth {
        write(2, "  ", 2);
        i = i + 1;
    }
    write(2, "<- ", 3);
    print_str_stderr(func_name);
    write(2, "\n", 1);
}
```

### 4.4 Debug Print
```cot
fn debug(msg: *u8) {
    if not g_debug_verbose { return; }
    write(2, "[DEBUG] ", 8);
    print_str_stderr(msg);
    write(2, "\n", 1);
}

fn debug_int(msg: *u8, value: i64) {
    if not g_debug_verbose { return; }
    write(2, "[DEBUG] ", 8);
    print_str_stderr(msg);
    write(2, ": ", 2);
    print_int_stderr(value);
    write(2, "\n", 1);
}
```

---

## Phase 5: Type/Kind Validation Helpers

### 5.1 NodeKind Validation
```cot
fn assert_node_kind(node: *Node, expected: NodeKind, context: *u8) {
    if node == null {
        write(2, "NODE ERROR: null node in ", 25);
        print_str_stderr(context);
        write(2, "\n", 1);
        exit(1);
    }
    if node.kind != expected {
        write(2, "NODE KIND ERROR in ", 19);
        print_str_stderr(context);
        write(2, ": expected kind ", 16);
        print_int_stderr(@intCast(i64, expected));
        write(2, ", got ", 6);
        print_int_stderr(@intCast(i64, node.kind));
        write(2, "\n", 1);
        exit(1);
    }
}
```

### 5.2 IRNodeKind Validation
```cot
fn assert_ir_kind(node: *IRNode, expected: IRNodeKind, context: *u8) {
    if node == null {
        write(2, "IR ERROR: null node in ", 23);
        print_str_stderr(context);
        write(2, "\n", 1);
        exit(1);
    }
    if node.kind != expected {
        write(2, "IR KIND ERROR in ", 17);
        print_str_stderr(context);
        write(2, ": expected kind ", 16);
        print_int_stderr(@intCast(i64, expected));
        write(2, ", got ", 6);
        print_int_stderr(@intCast(i64, node.kind));
        write(2, "\n", 1);
        exit(1);
    }
}
```

### 5.3 Op Validation
```cot
fn assert_op(value: *Value, expected: Op, context: *u8) {
    if value == null {
        write(2, "VALUE ERROR: null value in ", 27);
        print_str_stderr(context);
        write(2, "\n", 1);
        exit(1);
    }
    if value.op != expected {
        write(2, "OP ERROR in ", 12);
        print_str_stderr(context);
        write(2, ": expected op ", 14);
        print_int_stderr(@intCast(i64, expected));
        write(2, ", got ", 6);
        print_int_stderr(@intCast(i64, value.op));
        write(2, "\n", 1);
        exit(1);
    }
}
```

---

## Phase 6: File I/O Safety

### 6.1 Safe File Open
```cot
fn safe_open(path: *u8, flags: i32, mode: i32, context: *u8) i32 {
    assert_not_null(path, "path");
    let fd: i32 = open(path, flags, mode);
    if fd < 0 {
        write(2, "FILE ERROR: cannot open '", 25);
        print_str_stderr(path);
        write(2, "' for ", 6);
        print_str_stderr(context);
        write(2, "\n", 1);
        exit(1);
    }
    return fd;
}
```

### 6.2 Safe File Read
```cot
fn safe_read(fd: i32, buf: *u8, count: i64, context: *u8) i64 {
    assert_not_null(buf, "read buffer");
    if count <= 0 {
        write(2, "READ ERROR: invalid count in ", 29);
        print_str_stderr(context);
        write(2, "\n", 1);
        exit(1);
    }
    let result: i64 = read(fd, buf, count);
    if result < 0 {
        write(2, "READ ERROR: read failed in ", 27);
        print_str_stderr(context);
        write(2, "\n", 1);
        exit(1);
    }
    return result;
}
```

### 6.3 Safe File Write
```cot
fn safe_write(fd: i32, buf: *u8, count: i64, context: *u8) i64 {
    assert_not_null(buf, "write buffer");
    let result: i64 = write(fd, buf, count);
    if result != count {
        write(2, "WRITE ERROR: incomplete write in ", 33);
        print_str_stderr(context);
        write(2, " (wrote ", 8);
        print_int_stderr(result);
        write(2, " of ", 4);
        print_int_stderr(count);
        write(2, ")\n", 2);
        exit(1);
    }
    return result;
}
```

---

## Phase 7: Compiler-Specific Invariant Checks

### 7.1 Scanner Invariants
```cot
fn Scanner_checkInvariants(s: *Scanner) {
    assert_not_null(s.source, "Scanner.source");
    assert(s.pos >= 0, "Scanner.pos < 0");
    assert(s.pos <= s.source_len, "Scanner.pos > source_len");
    assert(s.line >= 1, "Scanner.line < 1");
}
```

### 7.2 Parser Invariants
```cot
fn Parser_checkInvariants(p: *Parser) {
    assert_not_null(p.pool, "Parser.pool");
    assert_not_null(p.pool.nodes, "Parser.pool.nodes");
    assert(p.pool.count >= 0, "Parser.pool.count < 0");
    assert(p.pool.count <= p.pool.cap, "Parser.pool overflow");
}
```

### 7.3 Lowerer Invariants
```cot
fn Lowerer_checkInvariants(l: *Lowerer) {
    assert_not_null(l.nodes, "Lowerer.nodes");
    assert_not_null(l.source, "Lowerer.source");
    assert(l.nodes_count >= 0, "Lowerer.nodes_count < 0");
    if l.current_func != null {
        assert(l.current_func.nodes_count >= 0, "func.nodes_count < 0");
    }
}
```

### 7.4 SSA Builder Invariants
```cot
fn SSABuilder_checkInvariants(b: *SSABuilder) {
    assert_not_null(b.func, "SSABuilder.func");
    assert_not_null(b.func.blocks, "SSABuilder.func.blocks");
    assert_not_null(b.func.values, "SSABuilder.func.values");
    assert(b.func.blocks_count >= 0, "blocks_count < 0");
    assert(b.func.values_count >= 0, "values_count < 0");
}
```

### 7.5 GenState Invariants
```cot
fn GenState_checkInvariants(gs: *GenState) {
    assert_not_null(gs.code, "GenState.code");
    assert(gs.code_count >= 0, "code_count < 0");
    assert(gs.code_count <= gs.code_cap, "code buffer overflow");
}
```

---

## Phase 8: Integration Into Main Pipeline

### 8.1 Add Debug Flags to main()
- Parse `-d` or `--debug` for verbose mode
- Parse `-t` or `--trace` for function tracing
- Parse `-c` or `--check` for extra invariant checks

### 8.2 Add Phase Markers
```cot
fn phase_start(name: *u8) {
    print("Phase: ");
    print(name);
    print("...\n");
}

fn phase_end(name: *u8) {
    if g_debug_verbose {
        print("  Completed: ");
        print(name);
        print("\n");
    }
}
```

### 8.3 Wrap Critical Operations
- Every malloc call -> safe_malloc
- Every array index -> bounds check
- Every pointer deref -> null check
- Every file operation -> safe I/O

---

## Phase 9: Systematic Instrumentation

### 9.1 main.cot
- [ ] Replace all malloc_u8 with safe_malloc_u8
- [ ] Replace all malloc_i64 with safe_malloc_i64
- [ ] Add null checks after all pointer globals are used
- [ ] Add bounds checks on all array accesses
- [ ] Add invariant checks at phase boundaries

### 9.2 frontend/scanner.cot
- [ ] Add Scanner_checkInvariants calls
- [ ] Add bounds checks on source access
- [ ] Add position validation

### 9.3 frontend/parser.cot
- [ ] Add Parser_checkInvariants calls
- [ ] Add bounds checks on node pool access
- [ ] Validate node indices before use

### 9.4 frontend/lower.cot
- [ ] Add Lowerer_checkInvariants calls
- [ ] Add bounds checks on node access
- [ ] Add bounds checks on local/IR arrays
- [ ] Validate node kinds before field access

### 9.5 ssa/builder.cot
- [ ] Add SSABuilder_checkInvariants calls
- [ ] Add bounds checks on IR node access
- [ ] Add bounds checks on SSA value arrays
- [ ] Validate IR node kinds

### 9.6 codegen/genssa.cot
- [ ] Add GenState_checkInvariants calls
- [ ] Add bounds checks on code buffer
- [ ] Add bounds checks on block/value access
- [ ] Validate SSA value ops

### 9.7 obj/macho.cot
- [ ] Add bounds checks on output buffer
- [ ] Add bounds checks on symbol/reloc arrays
- [ ] Validate section indices

---

## Phase 10: Testing the Error System

### 10.1 Create test/error_tests.cot
- Test that panic() works
- Test that assert() catches failures
- Test that bounds checks catch OOB
- Test that null checks catch null ptrs

### 10.2 Deliberate Failure Tests
- Create inputs that trigger each error path
- Verify error messages are clear and helpful

---

## Execution Checklist

### Immediate (Phase 1-3):
- [x] Create lib/error.cot with core primitives
- [x] Create lib/safe_alloc.cot
- [x] Create lib/safe_array.cot
- [ ] Test basic error functions work

### Foundation (Phase 4-6):
- [x] Add debug tracing infrastructure (lib/debug.cot)
- [x] Add type/kind validation helpers (lib/validate.cot)
- [x] Add safe file I/O wrappers (lib/safe_io.cot)

### Instrumentation (Phase 7-9):
- [x] Add compiler-specific invariant checks (lib/invariants.cot)
- [x] Create debug initialization (lib/debug_init.cot)
- [x] Create master import file (lib/safe.cot)
- [ ] Integrate into main.cot (BLOCKED - see below)
- [ ] Systematically instrument each source file

### Validation (Phase 10):
- [ ] Create error system tests
- [ ] Verify all error paths work
- [ ] Document error codes and meanings

---

## Current Status (2026-01-22)

**Files Created:**
- `lib/error.cot` - Core error primitives (panic, assert, bounds checks, tracing)
- `lib/safe_alloc.cot` - Safe memory allocation wrappers
- `lib/safe_array.cot` - Safe array access with bounds checking
- `lib/safe_io.cot` - Safe file I/O wrappers
- `lib/debug.cot` - Debug tracing infrastructure
- `lib/validate.cot` - Type/kind validation helpers
- `lib/invariants.cot` - Compiler-specific invariant checks
- `lib/debug_init.cot` - Initialization and flag parsing
- `lib/safe.cot` - Master import file
- `lib/externs.cot` - Shared extern declarations

**BLOCKED: Integration into main.cot**

The cot0 import system processes imports by concatenating source files in place.
When `import "lib/safe.cot"` is processed, the library code is inserted at that
position in the source. However, the library code references `write`, `exit`,
`malloc_u8`, etc. which are declared as externs in main.cot.

The problem: Even if externs are declared BEFORE the import statement in main.cot,
the import processing happens during parsing, before type checking sees the externs.
So the library code sees `write` as undefined.

**Options to fix:**
1. Copy needed functions directly into main.cot (works but duplicates code)
2. Modify the import system to support declaration ordering
3. Have lib files declare their own externs (causes duplicate symbol conflicts)

**Next Steps:**
- Either fix the import system or use workaround option 1
- Once integrated, instrument all source files with error checks
- Test with actual self-hosting to catch the stage2 crash

---

## Success Criteria

When complete, cot0 should:
1. **Never silently segfault** - always print what went wrong
2. **Pinpoint error location** - tell us file, line, function
3. **Explain the error** - not just "error" but "array index 500 out of bounds (length=100)"
4. **Be debuggable** - trace mode shows execution flow
5. **Catch errors early** - invariant checks catch corruption before it propagates
6. **Be maintainable** - error infrastructure is reusable for future code

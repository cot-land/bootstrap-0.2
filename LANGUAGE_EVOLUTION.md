# Cot Language Evolution Roadmap

**Created:** 2026-01-25
**Status:** Active Planning

---

## ⛔ MANDATORY: COPY FROM GO AND ZIG - NEVER INVENT ⛔

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   WHEN IMPLEMENTING NEW LANGUAGE FEATURES:                                    ║
║                                                                               ║
║   1. FIRST read how Go implements it:                                         ║
║      ~/learning/go/src/cmd/compile/internal/                                  ║
║                                                                               ║
║   2. THEN read how Zig implements it:                                         ║
║      ~/learning/zig/src/                                                      ║
║                                                                               ║
║   3. COPY the pattern - adapt syntax only                                     ║
║                                                                               ║
║   NEVER invent new approaches. Go and Zig are battle-tested.                  ║
║   If you're writing code that doesn't exist in Go or Zig, STOP.               ║
║                                                                               ║
║   Reference commands:                                                         ║
║   grep -r "ErrorUnion" ~/learning/zig/src/                                    ║
║   grep -r "optional" ~/learning/go/src/cmd/compile/                           ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## ⛔ MANDATORY: TEST-DRIVEN FEATURE DEVELOPMENT ⛔

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   EVERY NEW LANGUAGE FEATURE REQUIRES:                                        ║
║                                                                               ║
║   1. 3-5 tests written BEFORE implementing the feature                        ║
║   2. Tests in test/stages/cot1/, test/stages/cot2/, etc. directories          ║
║   3. ALL existing tests must continue to pass (754 e2e + new feature tests)   ║
║   4. Feature is not complete until all its tests pass                         ║
║                                                                               ║
║   Test Pattern:                                                               ║
║   ┌─────────────────────────────────────────────────────────────────────────┐ ║
║   │  test/bootstrap/all_tests.cot        # 166 baseline tests               │ ║
║   │  test/stages/cot1/cot1_features.cot  # 14 cot1 feature tests            │ ║
║   │  test/stages/cot2/cot2_features.cot  # (future) cot2 feature tests      │ ║
║   └─────────────────────────────────────────────────────────────────────────┘ ║
║                                                                               ║
║   Validation commands:                                                        ║
║   # Bootstrap tests with Zig compiler                                         ║
║   ./zig-out/bin/cot test/bootstrap/all_tests.cot -o /tmp/t && /tmp/t         ║
║                                                                               ║
║   # cot1 feature tests (must use cot1-stage1, not Zig bootstrap!)            ║
║   ./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1                 ║
║   /tmp/cot1-stage1 test/stages/cot1/cot1_features.cot -o /tmp/ft.o           ║
║   zig cc /tmp/ft.o runtime/cot_runtime.o -o /tmp/ft && /tmp/ft               ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## Vision

Cot is a systems programming language designed for self-hosting compiler development. The language evolves through numbered stages (cot0 through cot9), where each stage:

1. **Is compiled by the previous stage** - proving the previous compiler works
2. **Adds new language features** - making the language more expressive
3. **Compiles itself** - maintaining the self-hosting property

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          COT EVOLUTION PATH                                 │
│                                                                             │
│   Zig Compiler (bootstrap)                                                  │
│        │                                                                    │
│        ▼                                                                    │
│   cot0 ──── Minimal self-hosting (current)                                  │
│        │    - Basic types, structs, arrays, pointers                        │
│        │    - Functions, control flow                                       │
│        │    - Manual memory management                                      │
│        ▼                                                                    │
│   cot1 ──── Error handling & safety                                         │
│        │    - Error unions, optionals                                       │
│        │    - Improved strings, type aliases                                │
│        ▼                                                                    │
│   cot2 ──── Basic generics & abstractions                                   │
│        │    - Generic types, interfaces                                     │
│        │    - Pattern matching, ranges                                      │
│        ▼                                                                    │
│   cot3 ──── Advanced type system                                            │
│        │    - Comptime, inline functions                                    │
│        │    - Algebraic data types                                          │
│        ▼                                                                    │
│   ...                                                                       │
│        ▼                                                                    │
│   cot9 ──── Full-featured language                                          │
│             - On par with Zig/Rust expressiveness                           │
│             - Production-ready compiler                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Current Status: cot1 In Development

### Bootstrap Architecture

The Zig compiler serves as Stage 0 (trusted bootstrap) for all Cot stages:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   Zig Compiler (src/*.zig) ─── Stage 0, trusted bootstrap                   │
│        │                                                                    │
│        ├── compiles stages/cot1/main.cot → cot1-stage1                      │
│        │        │                                                           │
│        │        └── cot1-stage1 compiles cot1 source (in progress)          │
│        │                                                                    │
│        └── compiles test/bootstrap/all_tests.cot (166 tests)                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Test Status

| Compiler | Bootstrap Tests | Feature Tests | Total |
|----------|-----------------|---------------|-------|
| Zig bootstrap | 166 | - | 166 |
| cot1-stage1 | 166 | 11 | **177** |

### cot1 Feature Progress

| Feature | Status | Tests |
|---------|--------|-------|
| Type aliases (`type Name = T`) | ✅ DONE | 3 pass |
| Optional types (`?*T`) | ✅ DONE | 3 pass |
| Error unions (`!T` syntax) | ✅ DONE | 3 pass |
| String parameter passing | ✅ FIXED | All string tests pass |
| errdefer | Planned | - |
| Labeled break/continue | Planned | - |
| Struct init shorthand | Planned | - |

### Self-Hosting Status

- **cot1-stage1** (Zig → cot1): ✅ 177 tests pass
- **cot1-stage2** (cot1 → cot1): ⏳ Blocked by lowerer bugs
  - Error: TypeExpr* nodes passed to lowerExpr instead of resolve_type_expr
  - Needs investigation in `stages/cot1/frontend/lower.cot`

### Historical Note

cot0 self-hosting was abandoned due to DWARF relocation issues. The archive/cot0/ directory is preserved for reference but is no longer actively developed.

---

## cot1: Error Handling & Safety

**Goal:** Make cot1 a language where errors are explicit and null-safety is enforced.

**Compiled by:** Zig Bootstrap (Stage 0)
**Compiles:** Test programs, working toward self-hosting

**Current Status:** Phase 1 complete (type aliases, optionals, error union syntax)

### Feature 1: Error Union Types

```cot
// Error set definition
const FileError = error {
    NotFound,
    PermissionDenied,
    IoError,
};

// Function that can fail
fn readFile(path: string) FileError!string {
    let fd: i64 = open(path);
    if fd < 0 {
        return error.NotFound;
    }
    // ... read file ...
    return contents;
}

// Usage with try
fn processFile(path: string) FileError!void {
    let contents: string = try readFile(path);  // Propagates error
    process(contents);
}

// Usage with catch
fn safeRead(path: string) string {
    return readFile(path) catch |err| {
        return "default";
    };
}
```

**Why:** Compilers need robust error handling. Currently cot0 uses return codes which are easy to ignore.

### Feature 2: Optional Types

```cot
// Optional type syntax
fn findItem(items: []Item, key: i64) ?*Item {
    var i: i64 = 0;
    while i < items.len {
        if items[i].key == key {
            return &items[i];
        }
        i = i + 1;
    }
    return null;
}

// Usage with if-unwrap
if findItem(items, 42) |item| {
    // item is *Item here, guaranteed non-null
    print(item.name);
} else {
    print("not found");
}

// Usage with orelse
let item: *Item = findItem(items, 42) orelse &default_item;
```

**Why:** Eliminates null pointer bugs. The compiler deals with many lookups that can fail.

### Feature 3: Type Aliases

```cot
// Simple type alias
type NodeIndex = i64;
type SymbolId = i64;

// Now these are distinct in documentation but compatible
fn getNode(idx: NodeIndex) *Node { ... }
fn getSymbol(id: SymbolId) *Symbol { ... }

// Alias for complex types
type TokenList = []Token;
type ErrorSet = error { A, B, C };
```

**Why:** Improves code readability. `NodeIndex` is clearer than `i64`.

### Feature 4: errdefer

```cot
fn allocateResources() Error!*Resource {
    let a: *A = try allocA();
    errdefer freeA(a);  // Only runs if function returns error

    let b: *B = try allocB();
    errdefer freeB(b);

    let c: *C = try allocC();  // If this fails, a and b are freed

    return makeResource(a, b, c);
}
```

**Why:** Critical for proper resource cleanup in error paths.

### Feature 5: Labeled Break/Continue

```cot
fn findInMatrix(matrix: [][]i64, target: i64) ?Point {
    outer: for matrix, 0.. |row, y| {
        for row, 0.. |val, x| {
            if val == target {
                return Point{ .x = x, .y = y };
            }
            if val > target {
                continue :outer;  // Skip to next row
            }
        }
    }
    return null;
}
```

**Why:** Useful for nested loop control, common in compiler algorithms.

### Feature 6: String Improvements

```cot
// Multi-line strings
let sql: string =
    \\SELECT * FROM users
    \\WHERE id = ?
    \\ORDER BY name
    ;

// String interpolation (basic)
let msg: string = @fmt("Error at line {}: {}", line, message);

// Raw strings (no escape processing)
let regex: string = @raw"^\d+\.\d+$";
```

**Why:** Compilers generate lots of text output. Better string handling reduces bugs.

### Feature 7: Struct Initialization Shorthand

```cot
fn makeToken(kind: TokenKind, start: i64, end: i64) Token {
    // Shorthand: .field means .field = field
    return Token{ .kind, .start, .end };
}

// Equivalent to:
// return Token{ .kind = kind, .start = start, .end = end };
```

**Why:** Reduces boilerplate in struct-heavy code.

### Feature 8: Default Parameter Values

```cot
fn emit(opcode: u8, operand: i64 = 0, comment: string = "") {
    // ...
}

// Can call as:
emit(OP_RET);
emit(OP_LOAD, 42);
emit(OP_ADD, 0, "add values");
```

**Why:** Convenience for functions with many optional parameters.

### Feature 9: Const Pointers

```cot
// Pointer to const data (can't modify through this pointer)
fn printItems(items: *const []Item) void {
    // items[0].x = 5;  // COMPILE ERROR
    print(items[0].name);  // OK - reading
}

// Const pointer (pointer itself can't change)
fn process(ptr: *Item const) void {
    ptr.x = 5;  // OK - modifying pointee
    // ptr = other;  // COMPILE ERROR - can't reassign
}
```

**Why:** Better express intent, catch bugs at compile time.

### Feature 10: Improved Switch

```cot
// Switch as expression (already exists, but improved)
let category: Category = switch token.kind {
    .Plus, .Minus, .Star, .Slash => .Operator,
    .LParen, .RParen => .Punctuation,
    .Number => .Literal,
    .Ident => .Identifier,
    else => .Unknown,
};

// Range patterns
switch char {
    'a'...'z', 'A'...'Z' => handleLetter(char),
    '0'...'9' => handleDigit(char),
    else => handleOther(char),
}
```

**Why:** Pattern matching is essential for compiler switch statements.

### cot1 Implementation Priority

| Priority | Feature | Effort | Impact | Status |
|----------|---------|--------|--------|--------|
| P0 | Error unions (syntax) | High | Critical for robust code | ✅ DONE |
| P0 | Optional types | Medium | Eliminates null bugs | ✅ DONE |
| P1 | Type aliases | Low | Code clarity | ✅ DONE |
| P1 | errdefer | Medium | Resource safety | Planned |
| P1 | Const pointers | Medium | Better type checking | Planned |
| P2 | Labeled break | Low | Convenience | Planned |
| P2 | Struct shorthand | Low | Less boilerplate | Planned |
| P2 | Default params | Medium | API convenience | Planned |
| P2 | String improvements | Medium | Better ergonomics | Planned |
| P2 | Improved switch | Medium | Pattern matching | Planned |

**Note:** Error unions currently use simplified semantics where `!T` is treated as `T`. Full error handling (try/catch/errdefer) is planned for later phases.

---

## cot2: Basic Generics & Abstractions

**Goal:** Add generic programming and basic abstraction mechanisms.

**Compiled by:** cot1
**Compiles:** Itself (cot2)

### Feature 1: Generic Types

```cot
// Generic struct
struct ArrayList(T) {
    items: []T,
    len: i64,
    cap: i64,
}

fn ArrayList_init(T)(allocator: *Allocator) ArrayList(T) {
    return ArrayList(T){
        .items = allocator.alloc(T, 16),
        .len = 0,
        .cap = 16,
    };
}

fn ArrayList_append(T)(self: *ArrayList(T), item: T) void {
    if self.len >= self.cap {
        self.grow();
    }
    self.items[self.len] = item;
    self.len = self.len + 1;
}

// Usage
var nodes: ArrayList(Node) = ArrayList_init(Node)(allocator);
ArrayList_append(Node)(&nodes, new_node);
```

**Why:** The compiler has many homogeneous collections. Generics eliminate code duplication.

### Feature 2: Interfaces (Basic)

```cot
// Interface definition
interface Writer {
    fn write(self: *Self, bytes: []const u8) Error!usize;
    fn flush(self: *Self) Error!void;
}

// Implementation
struct FileWriter {
    fd: i64,

    impl Writer {
        fn write(self: *FileWriter, bytes: []const u8) Error!usize {
            return syscall_write(self.fd, bytes.ptr, bytes.len);
        }

        fn flush(self: *FileWriter) Error!void {
            return syscall_fsync(self.fd);
        }
    }
}

// Usage with interface type
fn writeAll(w: *Writer, data: []const u8) Error!void {
    var written: usize = 0;
    while written < data.len {
        written = written + try w.write(data[written..]);
    }
}
```

**Why:** Allows abstraction over I/O, enabling testing with mock writers.

### Feature 3: For Loops with Ranges

```cot
// Range-based for
for 0..10 |i| {
    print(i);  // 0, 1, 2, ... 9
}

// Iterate with index
for items, 0.. |item, idx| {
    print(idx, item);
}

// Reverse iteration
for items.reverse() |item| {
    process(item);
}
```

**Why:** More readable than while loops for simple iteration.

### Feature 4: Slices as First-Class

```cot
// Slice methods
let numbers: []i64 = &[_]i64{1, 2, 3, 4, 5};

let first3: []i64 = numbers[0..3];
let last2: []i64 = numbers[numbers.len-2..];

// Slice operations
if numbers.contains(3) { ... }
let sum: i64 = numbers.sum();
let sorted: []i64 = numbers.sorted();
```

**Why:** Slices are fundamental; methods make them more ergonomic.

### Feature 5: Anonymous Structs

```cot
// Return multiple values with anonymous struct
fn divmod(a: i64, b: i64) struct { quot: i64, rem: i64 } {
    return .{ .quot = a / b, .rem = a % b };
}

let result = divmod(17, 5);
print(result.quot);  // 3
print(result.rem);   // 2
```

**Why:** Lightweight way to return multiple related values.

### Feature 6: Tuple Types

```cot
// Tuple type
type Point = (i64, i64);

fn getPosition() (i64, i64) {
    return (x, y);
}

// Destructuring
let (x, y) = getPosition();
```

**Why:** Simpler than anonymous structs for positional data.

### Feature 7: Pattern Matching in Switch

```cot
switch node {
    .Binary => |bin| {
        process(bin.left);
        process(bin.right);
    },
    .Unary => |un| {
        process(un.operand);
    },
    .Literal => |lit| if lit.value > 0 {
        handlePositive(lit);
    },
    else => {},
}
```

**Why:** Essential for compiler AST traversal.

### Feature 8: Inline Functions

```cot
inline fn max(a: i64, b: i64) i64 {
    return if a > b then a else b;
}
```

**Why:** Performance-critical paths need guaranteed inlining.

### Feature 9: Comptime Basics

```cot
// Compile-time evaluation
comptime {
    const TABLE_SIZE: i64 = 1 << 16;
    var lookup_table: [TABLE_SIZE]u8 = undefined;
    // Initialize at compile time
    for 0..TABLE_SIZE |i| {
        lookup_table[i] = computeEntry(i);
    }
}

fn lookup(idx: u16) u8 {
    return lookup_table[idx];  // Zero runtime cost
}
```

**Why:** Enables compile-time computation for tables, constants.

### Feature 10: Method Syntax Sugar

```cot
// Methods on any type
fn (self: *ArrayList(T)) append(item: T) void {
    // ...
}

// Called as:
list.append(item);
// Instead of:
ArrayList_append(T)(&list, item);
```

**Why:** More readable code, especially for chained operations.

---

## Future Stages (Preview)

### cot3: Advanced Type System
- Union types (tagged unions with payloads)
- Comptime type reflection
- Comptime string operations
- @TypeOf, @typeInfo builtins

### cot4: Memory Safety
- Basic borrow checking (optional)
- Automatic reference counting (ARC)
- Arena allocators as language feature

### cot5: Metaprogramming
- Macros (hygienic)
- Code generation builtins
- AST manipulation at comptime

### cot6: Concurrency
- Async/await
- Channels
- Atomic types

### cot7: Modules & Packages
- Proper module system
- Package manager integration
- Semantic versioning

### cot8: Optimizations
- Optimizer passes in the language
- Profile-guided optimization hooks
- SIMD intrinsics

### cot9: Production Ready
- Full standard library
- Documentation generation
- IDE integration (LSP)
- Comprehensive error messages

---

## Development Principles

### 1. Each Stage Must Self-Host
Every cot version must be able to compile itself. This ensures:
- The language is expressive enough for real programs
- The compiler is correct (it produces working code)
- Regressions are caught immediately

### 2. Incremental Complexity
Features are added gradually:
- Simpler features first (they're needed to build complex ones)
- Each feature is tested by using it in the next compiler version
- No feature is added until the previous stage is stable

### 3. Compatibility Within Major Version
- cot1.0 code should work on cot1.9
- Breaking changes only at major version boundaries
- Deprecation warnings before removal

### 4. Bootstrap Chain as Test Suite
```
cot0 (Zig-compiled) → cot1 source → cot1 binary
cot1 binary → cot1 source → cot1' binary
cot1 binary == cot1' binary  ← PROOF OF CORRECTNESS
```

### 5. Learn from Zig and Go
Both languages have successful bootstrap stories:
- Zig: Started in C++, now self-hosted
- Go: Started in C, now self-hosted

We follow their patterns while making Cot's unique choices.

### 6. Dogfood Every Feature

**A feature is NOT complete until the compiler uses it.**

When a new language feature is implemented:
1. Parser, checker, lowerer all handle the syntax
2. Test suite has 3+ passing tests
3. **The compiler source must be updated to USE the feature**

This ensures:
- Features work in real-world code (not just minimal tests)
- Self-hosting exercises all features
- The compiler becomes production-quality, not minimal
- Each stage N+1 is written using stage N features

**Examples:**
```cot
// Type aliases - used in ast.cot
type NodeIndex = i64
type SourcePos = i64

// Optional types - used in parser.cot
fn findSymbol(name: string) ?*Symbol { ... }

// Error unions - used in checker.cot
fn resolveType(node: NodeIndex) !TypeId { ... }
```

---

## Immediate Next Steps

1. ~~**Create cot1 directory** with initial structure~~ ✅ Done (stages/cot1/)
2. ~~**Implement type aliases**~~ ✅ Done (3 tests pass)
3. ~~**Implement optional types**~~ ✅ Done (3 tests pass)
4. ~~**Implement error union syntax**~~ ✅ Done (3 tests pass)
5. **Fix self-hosting lowerer bugs** - TypeExpr* nodes not routed correctly
6. **Achieve cot1 self-hosting** - cot1 compiles itself
7. **Implement errdefer** - Critical for resource safety
8. **Implement full error handling** - try/catch semantics

---

## File Structure (Current)

```
bootstrap-0.2/
├── src/                      # Stage 0: Zig compiler (bootstrap)
│   └── frontend/
│       ├── parser.zig
│       ├── checker.zig
│       ├── lower.zig
│       └── ...
├── stages/
│   └── cot1/                 # Stage 1: First self-hosting target
│       ├── main.cot
│       ├── frontend/
│       │   ├── parser.cot
│       │   ├── checker.cot
│       │   ├── lower.cot
│       │   └── ...
│       ├── ssa/
│       ├── codegen/
│       └── obj/
├── runtime/                  # Shared runtime
│   ├── cot_runtime.zig
│   └── cot_runtime.o
├── test/
│   ├── bootstrap/            # Zig compiler tests (166 tests)
│   │   └── all_tests.cot
│   └── stages/
│       └── cot1/             # cot1 feature tests (11 tests)
│           └── cot1_features.cot
├── archive/
│   └── cot0/                 # Historical reference (deprecated)
└── docs/
    └── LANGUAGE_EVOLUTION.md # This document
```

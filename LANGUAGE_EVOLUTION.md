# Cot Language Evolution Roadmap

**Created:** 2026-01-25
**Status:** Active Planning

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

## Current Status: cot0

### What cot0 Has

| Feature | Status | Notes |
|---------|--------|-------|
| Basic types (i64, u8, bool) | ✅ | Working |
| Structs | ✅ | Value types, field access |
| Arrays | ✅ | Fixed-size, stack allocated |
| Pointers | ✅ | Raw pointers, arithmetic |
| Functions | ✅ | Up to 16 arguments |
| Control flow | ✅ | if/else, while, break/continue |
| Strings | ✅ | Slice-based (ptr + len) |
| Imports | ✅ | Single-file imports |
| Constants | ✅ | Compile-time integers |
| Defer | ✅ | Basic defer statements |
| DWARF debug info | ⚠️ | Relocation alignment issue |

### Self-Hosting Status

- **Stage 1** (Zig → cot0): ✅ 166/166 tests pass
- **Stage 2** (cot0 → cot0): ✅ Compiles with correct code
- **Stage 3** verification: ⏳ Blocked by DWARF issue (non-critical)

### Decision: Move Forward

The DWARF debug info issue (BUG-061) is a polish problem, not a correctness problem. We will:

1. Optionally disable DWARF generation to prove stage2 = stage3
2. Begin cot1 development with improved language features
3. Fix DWARF when convenient (possibly easier with cot1 features)

---

## cot1: Error Handling & Safety

**Goal:** Make cot1 a language where errors are explicit and null-safety is enforced.

**Compiled by:** cot0
**Compiles:** Itself (cot1)

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

| Priority | Feature | Effort | Impact |
|----------|---------|--------|--------|
| P0 | Error unions | High | Critical for robust code |
| P0 | Optional types | Medium | Eliminates null bugs |
| P1 | Type aliases | Low | Code clarity |
| P1 | errdefer | Medium | Resource safety |
| P1 | Const pointers | Medium | Better type checking |
| P2 | Labeled break | Low | Convenience |
| P2 | Struct shorthand | Low | Less boilerplate |
| P2 | Default params | Medium | API convenience |
| P2 | String improvements | Medium | Better ergonomics |
| P2 | Improved switch | Medium | Pattern matching |

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

---

## Immediate Next Steps

1. **Disable DWARF temporarily** in cot0 to prove stage2 = stage3
2. **Create cot1 directory** with initial structure
3. **Implement error unions** (highest impact feature)
4. **Port cot0 to use cot1 features** as they're implemented
5. **Achieve cot1 self-hosting**

---

## File Structure (Proposed)

```
bootstrap-0.2/
├── src/                    # Zig compiler (bootstrap)
├── cot0/                   # cot0 compiler source
│   ├── main.cot
│   ├── frontend/
│   ├── ssa/
│   ├── codegen/
│   └── obj/
├── cot1/                   # cot1 compiler source (NEW)
│   ├── main.cot
│   ├── frontend/
│   │   ├── error.cot       # Error handling module
│   │   ├── optional.cot    # Optional type support
│   │   └── ...
│   ├── ssa/
│   ├── codegen/
│   └── obj/
├── test/
│   ├── e2e/                # End-to-end tests
│   ├── cot1/               # cot1-specific tests
│   └── ...
└── docs/
    ├── LANGUAGE_EVOLUTION.md  # This document
    └── cot1/
        └── FEATURES.md     # cot1 feature specifications
```

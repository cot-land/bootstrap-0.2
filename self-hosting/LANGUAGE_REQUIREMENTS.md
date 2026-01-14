# Language Features Required for Stage 0 Self-Hosting

This document lists the **exact** language features needed to compile the stage0 self-hosting compiler. Each feature includes:
- Syntax specification
- Usage example from stage0 code
- Test case to verify it works

**Target audience**: The Claude session working on bootstrap-0.2 language features.

---

## Priority Legend

- **P0 - BLOCKING**: Stage0 files cannot compile without this
- **P1 - REQUIRED**: Needed for self-hosting but can write workarounds temporarily
- **P2 - NICE TO HAVE**: Makes code cleaner but not strictly required

---

## Feature Status Summary

| Feature | Priority | Status | Needed By |
|---------|----------|--------|-----------|
| Enums with backing type | P0 | TODO | token_s0.cot |
| Enum comparison (==) | P0 | TODO | token_s0.cot |
| Enum in struct fields | P0 | TODO | token_s0.cot |
| Fixed arrays [N]T | P0 | TODO | scanner_s0.cot |
| Array indexing arr[i] | P0 | TODO | scanner_s0.cot |
| Array assignment arr[i] = x | P0 | TODO | scanner_s0.cot |
| Pointer types *T | P0 | TODO | parser_s0.cot |
| Address-of &x | P0 | TODO | parser_s0.cot |
| Dereference ptr.* | P0 | TODO | parser_s0.cot |
| Bitwise AND & | P0 | TODO | codegen_s0.cot |
| Bitwise OR \| | P0 | TODO | codegen_s0.cot |
| Bitwise XOR ^ | P1 | TODO | codegen_s0.cot |
| Bitwise NOT ~ | P1 | TODO | codegen_s0.cot |
| Left shift << | P0 | TODO | codegen_s0.cot |
| Right shift >> | P0 | TODO | codegen_s0.cot |
| Logical and | P0 | TODO | parser_s0.cot |
| Logical or | P0 | TODO | parser_s0.cot |
| @intFromEnum | P1 | TODO | token_s0.cot |
| @enumFromInt | P1 | TODO | scanner_s0.cot |

---

## P0 BLOCKING FEATURES

### 1. Enums with Backing Type

**Priority**: P0 - BLOCKING
**Needed by**: `token_s0.cot` (first file in stage0)

**Syntax**:
```cot
enum Name: BackingType {
    variant1,    // = 0
    variant2,    // = 1
    variant3,    // = 2
}
```

**Stage0 usage**:
```cot
enum TokenKind: u8 {
    invalid,
    eof,
    int_lit,
    string_lit,
    ident,
    kw_fn,
    plus,
    minus,
    // ... more variants
}
```

**Test case**:
```cot
fn test_enum() i64 {
    // Create enum value
    var k: TokenKind = TokenKind.plus

    // Compare enum values
    if k == TokenKind.plus {
        return 42
    }
    return 1
}
```

**Expected behavior**:
- `TokenKind.plus` evaluates to a u8 value (the index)
- Enum comparison uses integer comparison under the hood
- Enums can be stored in variables and struct fields

---

### 2. Enum in Struct Fields

**Priority**: P0 - BLOCKING
**Needed by**: `token_s0.cot`

**Syntax**:
```cot
struct StructName {
    field: EnumType,
    // ...
}
```

**Stage0 usage**:
```cot
struct Token {
    kind: TokenKind,    // Enum field
    start: i64,
    length: i64,
    line: i64,
}
```

**Test case**:
```cot
fn test_enum_in_struct() i64 {
    var tok: Token = Token{
        .kind = TokenKind.plus,
        .start = 0,
        .length = 1,
        .line = 1,
    }

    if tok.kind == TokenKind.plus {
        return 42
    }
    return 1
}
```

---

### 3. Fixed-Size Arrays

**Priority**: P0 - BLOCKING
**Needed by**: `scanner_s0.cot`, `parser_s0.cot`

**Syntax**:
```cot
var arr: [N]T = [value1, value2, ...]  // Array literal
var arr: [N]T = undefined              // Uninitialized (or zeroed)
```

**Stage0 usage**:
```cot
// In scanner - buffer for current token text
var buffer: [256]u8

// In parser - fixed-size AST node storage
var nodes: [4096]AstNode

// In codegen - instruction buffer
var code: [16384]u8
```

**Test case**:
```cot
fn test_array() i64 {
    var arr: [5]i64 = [10, 20, 30, 40, 50]

    // Read element
    if arr[0] != 10 {
        return 1
    }
    if arr[4] != 50 {
        return 2
    }

    // Write element
    arr[2] = 99
    if arr[2] != 99 {
        return 3
    }

    return 42
}
```

---

### 4. Array Indexing (Read and Write)

**Priority**: P0 - BLOCKING
**Needed by**: `scanner_s0.cot`, `parser_s0.cot`

**Syntax**:
```cot
var x: T = arr[index]     // Read
arr[index] = value        // Write
```

**Stage0 usage**:
```cot
// Read from source
var ch: u8 = source[pos]

// Store AST node
nodes[node_count] = node
node_count = node_count + 1

// Read AST node
var n: AstNode = nodes[idx]
```

---

### 5. Pointer Types

**Priority**: P0 - BLOCKING
**Needed by**: `parser_s0.cot`, `lower_s0.cot`

**Syntax**:
```cot
var ptr: *T              // Pointer to T
fn foo(p: *T) void       // Pointer parameter
```

**Stage0 usage**:
```cot
// Parser passes arrays by pointer
fn parseExpr(p: *Parser) NodeIndex {
    // Access through pointer
    var tok: Token = p.*.current
    // ...
}

// Scanner modifies itself
fn scannerNext(s: *Scanner) Token {
    s.*.pos = s.*.pos + 1
    // ...
}
```

---

### 6. Address-of Operator

**Priority**: P0 - BLOCKING
**Needed by**: `main_s0.cot`

**Syntax**:
```cot
var ptr: *T = &value
```

**Stage0 usage**:
```cot
fn main() i64 {
    var parser: Parser = parserInit(source)
    var root: NodeIndex = parse(&parser)  // Pass by pointer
    // ...
}
```

---

### 7. Dereference Operator

**Priority**: P0 - BLOCKING
**Needed by**: `parser_s0.cot`, `scanner_s0.cot`

**Syntax**:
```cot
var value: T = ptr.*           // Read through pointer
ptr.* = new_value              // Write through pointer
var field: F = ptr.*.field     // Access field through pointer
ptr.*.field = value            // Assign field through pointer
```

**Stage0 usage**:
```cot
fn advance(p: *Parser) void {
    // Read through pointer, call function, write through pointer
    p.*.current = scannerNext(&p.*.scanner)
}
```

---

### 8. Bitwise Left Shift

**Priority**: P0 - BLOCKING
**Needed by**: `codegen_s0.cot`

**Syntax**:
```cot
var result: i64 = value << shift_amount
```

**Stage0 usage**:
```cot
// ARM64 instruction encoding
fn encodeMovImm(rd: u8, imm: i64) i64 {
    // MOV Rd, #imm encoding: 1101_0010_100x_xxxx_xxxx_xxxx_xxxd_dddd
    var inst: i64 = 0xD2800000
    inst = inst | (imm << 5)        // Immediate in bits 20:5
    inst = inst | rd                 // Destination register in bits 4:0
    return inst
}
```

---

### 9. Bitwise Right Shift

**Priority**: P0 - BLOCKING
**Needed by**: `codegen_s0.cot`, `object_s0.cot`

**Syntax**:
```cot
var result: i64 = value >> shift_amount
```

**Stage0 usage**:
```cot
// Extract bytes from instruction
fn writeLittleEndian32(buf: *[16384]u8, pos: i64, value: i64) void {
    buf.*[pos] = value % 256
    buf.*[pos + 1] = (value >> 8) % 256
    buf.*[pos + 2] = (value >> 16) % 256
    buf.*[pos + 3] = (value >> 24) % 256
}
```

---

### 10. Bitwise AND

**Priority**: P0 - BLOCKING
**Needed by**: `codegen_s0.cot`

**Syntax**:
```cot
var result: i64 = a & b
```

**Stage0 usage**:
```cot
// Mask bits in instruction encoding
fn encodeRegister(inst: i64, rd: u8) i64 {
    return (inst & 0xFFFFFFE0) | (rd & 0x1F)
}
```

---

### 11. Bitwise OR

**Priority**: P0 - BLOCKING
**Needed by**: `codegen_s0.cot`

**Syntax**:
```cot
var result: i64 = a | b
```

**Stage0 usage**:
```cot
// Combine fields in instruction encoding
fn encodeAdd(rd: u8, rn: u8, rm: u8) i64 {
    var inst: i64 = 0x8B000000  // ADD X, X, X base
    inst = inst | rd
    inst = inst | (rn << 5)
    inst = inst | (rm << 16)
    return inst
}
```

---

### 12. Logical AND (Short-Circuit)

**Priority**: P0 - BLOCKING
**Needed by**: `scanner_s0.cot`, `parser_s0.cot`

**Syntax**:
```cot
if condition1 and condition2 { ... }
```

**Stage0 usage**:
```cot
fn isAlnum(c: u8) bool {
    return isAlpha(c) or isDigit(c)
}

fn scanNumber(s: *Scanner) Token {
    while s.*.pos < len(s.*.source) and isDigit(s.*.source[s.*.pos]) {
        s.*.pos = s.*.pos + 1
    }
    // ...
}
```

---

### 13. Logical OR (Short-Circuit)

**Priority**: P0 - BLOCKING
**Needed by**: `scanner_s0.cot`

**Syntax**:
```cot
if condition1 or condition2 { ... }
```

**Stage0 usage**:
```cot
fn isAlpha(c: u8) bool {
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95
}
```

---

## P1 REQUIRED FEATURES

### 14. @intFromEnum

**Priority**: P1 - REQUIRED (can work around)
**Needed by**: `token_s0.cot`

**Syntax**:
```cot
var n: u8 = @intFromEnum(enum_value)
```

**Workaround if missing**: Compare each enum value individually (verbose but works).

---

### 15. @enumFromInt

**Priority**: P1 - REQUIRED (can work around)
**Needed by**: `scanner_s0.cot`

**Syntax**:
```cot
var e: EnumType = @enumFromInt(int_value)
```

**Workaround if missing**: Don't convert integers back to enums; use integers where needed.

---

## Test Program for All Features

When implementing these features, this single program tests them all:

```cot
// test_stage0_features.cot

enum Status: u8 {
    pending,
    running,
    done,
}

struct Task {
    id: i64,
    status: Status,
}

fn test_all() i64 {
    // 1. Enum creation and comparison
    var s: Status = Status.running
    if s != Status.running {
        return 1
    }

    // 2. Enum in struct
    var task: Task = Task{ .id = 1, .status = Status.pending }
    if task.status != Status.pending {
        return 2
    }

    // 3. Arrays
    var arr: [4]i64 = [10, 20, 30, 40]
    if arr[0] != 10 {
        return 3
    }
    arr[1] = 99
    if arr[1] != 99 {
        return 4
    }

    // 4. Pointers
    var x: i64 = 42
    var ptr: *i64 = &x
    if ptr.* != 42 {
        return 5
    }
    ptr.* = 100
    if x != 100 {
        return 6
    }

    // 5. Bitwise operations
    var a: i64 = 0xFF
    var b: i64 = 0x0F
    if (a & b) != 0x0F {
        return 7
    }
    if (a | 0x100) != 0x1FF {
        return 8
    }
    if (1 << 4) != 16 {
        return 9
    }
    if (16 >> 2) != 4 {
        return 10
    }

    // 6. Logical operators with short-circuit
    var t: bool = true
    var f: bool = false
    if not (t and t) {
        return 11
    }
    if t and f {
        return 12
    }
    if not (t or f) {
        return 13
    }
    if f or f {
        return 14
    }

    return 42  // All tests passed
}

fn main() i64 {
    return test_all()
}
```

---

## Implementation Order Recommendation

To unblock stage0 files incrementally:

1. **Enums** (P0) → Unblocks `token_s0.cot`
2. **Arrays** (P0) → Unblocks `scanner_s0.cot`
3. **Pointers** (P0) → Unblocks `parser_s0.cot`
4. **Logical and/or** (P0) → Required throughout
5. **Bitwise ops** (P0) → Unblocks `codegen_s0.cot`

Once these are done, ALL stage0 files can be written and tested.

---

## Verification

After implementing a feature, run:

```bash
# Build compiler
zig build

# Test with single-feature test file
./zig-out/bin/cot test/e2e/test_enum.cot -o test_enum
./test_enum
echo "Exit: $?"  # Should be 42
```

Then update this document to mark the feature as DONE.

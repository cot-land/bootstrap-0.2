# Bootstrap 0.2 - Project Status

**Last Updated: 2026-01-14**

## Executive Summary

Bootstrap-0.2 is a clean-slate rewrite of the Cot compiler following Go's proven compiler architecture. The goal is to eliminate the "whack-a-mole" debugging pattern that killed previous attempts.

**Current State:** Phase 8 in progress. 50 e2e tests passing! Working toward self-hosting.

---

## Self-Hosting Feature Checklist

**Goal:** Compiler compiles itself. All features below are required.

### Tier 1: Core Language (COMPLETE)

These features are working with 43+ e2e tests:

| Feature | Status | Tests |
|---------|--------|-------|
| Integer literals (decimal, hex, binary, octal) | ✅ DONE | test_return, test_large_number |
| Arithmetic (+, -, *, /, %) | ✅ DONE | test_add, test_sub, test_mul, test_div, test_mod |
| Unary minus (-x) | ✅ DONE | test_unary_minus |
| Comparison operators (==, !=, <, <=, >, >=) | ✅ DONE | test_eq, test_ne, test_lt, etc. |
| Boolean type (true, false) | ✅ DONE | test_bool_* |
| Local variables (let, var) | ✅ DONE | test_let, test_var_mutation |
| Function declarations | ✅ DONE | All tests |
| Function calls (0-8 args) | ✅ DONE | test_call, test_fibonacci |
| Function calls (9+ args) | ✅ DONE | test_many_args |
| If/else conditionals | ✅ DONE | test_if_*, test_else_if |
| While loops | ✅ DONE | test_while_*, test_nested_while |
| Break/continue | ✅ DONE | test_break, test_continue |
| Void functions | ✅ DONE | test_void_* |
| Recursive functions | ✅ DONE | test_factorial, test_fibonacci |
| Structs (simple) | ✅ DONE | test_struct_simple |
| Structs (nested) | ✅ DONE | test_struct_nested |
| Structs (large, 64+ bytes) | ✅ DONE | test_struct_large |

### Tier 2: Data Types (IN PROGRESS)

Required for handling source text, tokens, and AST nodes:

| Feature | Status | Priority | Notes |
|---------|--------|----------|-------|
| **String literals** | ✅ DONE | P0 | "hello", escape sequences |
| **String type** | ✅ DONE | P0 | Pointer + length pair |
| **len() builtin** | ✅ DONE | P0 | Works on literals and variables |
| **Character literals** | ✅ DONE | P0 | 'a', '\n', '\\' |
| **u8 type** | ✅ DONE | P0 | For characters/bytes |
| **Fixed arrays [N]T** | ❌ TODO | P0 | [256]u8 for buffers |
| **Array literals** | ❌ TODO | P0 | [1, 2, 3] |
| **Array indexing arr[i]** | ❌ TODO | P0 | Read and write |
| **Slices []T** | ❌ TODO | P1 | Dynamic arrays |
| **Slice from array** | ❌ TODO | P1 | arr[start..end] |

### Tier 3: Memory & Pointers (TODO)

Required for tree structures and dynamic allocation:

| Feature | Status | Priority | Notes |
|---------|--------|----------|-------|
| **Pointer types *T** | ❌ TODO | P0 | *i64, *Node |
| **Address-of &x** | ❌ TODO | P0 | Get pointer to value |
| **Dereference ptr.*** | ❌ TODO | P0 | Read through pointer |
| **Pointer arithmetic** | ❌ TODO | P2 | ptr + offset (maybe) |
| **Optional types ?T** | ❌ TODO | P1 | Nullable values |
| **null literal** | ❌ TODO | P1 | For optionals |

### Tier 4: Enums & Pattern Matching (TODO)

Required for token types, AST node kinds:

| Feature | Status | Priority | Notes |
|---------|--------|----------|-------|
| **Enum declaration** | ❌ TODO | P0 | enum Color { Red, Green } |
| **Enum value access** | ❌ TODO | P0 | Color.Red |
| **Enum as integer** | ❌ TODO | P1 | @enumToInt |
| **Switch statement** | ❌ TODO | P1 | Or use if/else chains |

### Tier 5: Operators (TODO)

Required for bit manipulation, flags:

| Feature | Status | Priority | Notes |
|---------|--------|----------|-------|
| **Bitwise AND &** | ❌ TODO | P0 | Flags, masks |
| **Bitwise OR \|** | ❌ TODO | P0 | Combining flags |
| **Bitwise XOR ^** | ❌ TODO | P1 | |
| **Bitwise NOT ~** | ❌ TODO | P1 | |
| **Left shift <<** | ❌ TODO | P0 | Bit manipulation |
| **Right shift >>** | ❌ TODO | P0 | Bit manipulation |
| **Logical AND (and)** | ❌ TODO | P0 | Short-circuit |
| **Logical OR (or)** | ❌ TODO | P0 | Short-circuit |
| **Logical NOT (not)** | ❌ TODO | P0 | !x already works |
| **Compound assign +=, -=** | ❌ TODO | P2 | Convenience |

### Tier 6: Control Flow (TODO)

| Feature | Status | Priority | Notes |
|---------|--------|----------|-------|
| **For-in loops** | ❌ TODO | P1 | for item in items { } |
| **Else-if chains** | ✅ DONE | - | Already working |
| **Defer statement** | ❌ TODO | P2 | Cleanup on scope exit |

### Tier 7: Module System (TODO)

| Feature | Status | Priority | Notes |
|---------|--------|----------|-------|
| **Global constants** | ❌ TODO | P1 | const MAX = 100; |
| **Import statement** | ❌ TODO | P2 | import "file.cot" |
| **Multiple files** | ❌ TODO | P2 | Compile multiple .cot |

---

## Implementation Order

Based on dependencies and self-hosting needs:

### Sprint 1: Strings & Characters ✅ COMPLETE
1. ✅ u8 type support
2. ✅ Character literals ('a', '\n')
3. ✅ String type (ptr + len pair)
4. ✅ String literals ("hello") - compiles, ADRP/ADD relocation works
5. ✅ String escape sequences (in parser)
6. ✅ len() builtin for string literals (compile-time)
7. ✅ len() builtin for string variables (runtime)

### Sprint 2: Arrays
1. ❌ Fixed array types [N]T
2. ❌ Array literals [1, 2, 3]
3. ❌ Array indexing arr[i]
4. ❌ Array assignment arr[i] = x

### Sprint 3: Pointers
1. ❌ Pointer types *T
2. ❌ Address-of operator &x
3. ❌ Dereference operator ptr.*
4. ❌ Pointer to struct fields

### Sprint 4: Bitwise & Logical
1. ❌ Bitwise operators (&, |, ^, ~, <<, >>)
2. ❌ Logical operators (and, or, not)
3. ❌ Short-circuit evaluation

### Sprint 5: Enums
1. ❌ Enum declarations
2. ❌ Enum value access
3. ❌ Enum in conditionals

### Sprint 6: Advanced
1. ❌ Optional types ?T
2. ❌ Slices []T
3. ❌ For-in loops
4. ❌ Global constants

---

## Test Requirements

**Each feature must have comprehensive tests before implementation is complete.**

### Test Categories Per Feature:

1. **Basic functionality** - Does it work at all?
2. **Edge cases** - Empty, zero, max values
3. **Interaction** - With other features (structs, functions, loops)
4. **Large scale** - Many elements, deep nesting
5. **Error cases** - Invalid inputs (parser/checker tests)

### Example: Array Feature Tests
```
test_array_literal_empty        - []
test_array_literal_one          - [42]
test_array_literal_many         - [1, 2, 3, 4, 5]
test_array_index_first          - arr[0]
test_array_index_last           - arr[len-1]
test_array_index_middle         - arr[2]
test_array_assign               - arr[0] = 99
test_array_in_struct            - struct { data: [10]i64 }
test_array_as_param             - fn foo(arr: [5]i64)
test_array_as_return            - fn bar() [3]i64
test_array_nested               - [[1,2], [3,4]]
test_array_of_structs           - [Point{}, Point{}]
test_array_large                - [100]i64
```

---

## Recent Milestones (2026-01-14)

- ✅ `fn main() i64 { return 42; }` compiles and runs correctly
- ✅ `fn main() i64 { return 20 + 22; }` compiles and runs (returns 42)
- ✅ **Function calls work!** `add_one(41)` returns 42
- ✅ **Local variables work!** `let x: i64 = 42; return x;`
- ✅ **Comparisons work!** `==, !=, <, <=, >, >=` with CMP + CSET
- ✅ **Conditionals work!** `if 1 == 2 { return 0; } else { return 42; }`
- ✅ **While loops with phi nodes work!** Variable mutation in loops
- ✅ **Fibonacci compiles and returns 55!** (10th Fibonacci number)
- ✅ **Nested function calls work!** Register allocator properly spills
- ✅ **Unary minus (-x)** - NEG instruction via SUB Rd, XZR, Rm
- ✅ **Modulo operator (%)** - Implemented as a - (a/b)*b
- ✅ **Recursive functions** - factorial(5) returns 120
- ✅ **Boolean type** - `let b: bool = true; if b { ... }`
- ✅ **9+ function arguments** - Stack argument passing beyond x0-x7
- ✅ **Nested while loops** - Multiple loop nesting works
- ✅ **Break/continue** - Loop control flow statements
- ✅ **Void functions** - Functions with no return value
- ✅ **Structs!** - Simple, nested, and large structs (64+ bytes) all working
- ✅ **43 e2e tests passing** - Comprehensive test suite

### Regalloc Fixes (2026-01-14)
- Fixed register freeing for live-out values (Go's pattern)
- Fixed use-count based register freeing
- Found by investigating Go's regalloc.go implementation

---

## Completed Components

### Backend (Phases 0-5) - COMPLETE

| Phase | Component | Location | Status |
|-------|-----------|----------|--------|
| 0 | SSA Value/Block/Func | `src/ssa/` | Done |
| 0 | SSA Op definitions | `src/ssa/op.zig` | Done |
| 0 | Dominator tree | `src/ssa/dom.zig` | Done |
| 0 | Pass infrastructure | `src/ssa/compile.zig` | Done |
| 1 | Liveness analysis | `src/ssa/liveness.zig` | Done |
| 2 | Register allocator | `src/ssa/regalloc.zig` | Done |
| 3 | Lowering pass | `src/ssa/passes/lower.zig` | Done |
| 4 | Generic codegen | `src/codegen/generic.zig` | Done |
| 4 | ARM64 codegen | `src/codegen/arm64.zig` | Done |
| 5 | Mach-O writer | `src/obj/macho.zig` | Done |

### Frontend (Phase 6) - COMPLETE

| Component | Location | Status |
|-----------|----------|--------|
| Token system | `src/frontend/token.zig` | Done |
| Scanner | `src/frontend/scanner.zig` | Done |
| Parser | `src/frontend/parser.zig` | Done |
| Type checker | `src/frontend/checker.zig` | Done |
| IR definitions | `src/frontend/ir.zig` | Done |
| AST lowering | `src/frontend/lower.zig` | Done |
| IR→SSA builder | `src/frontend/ssa_builder.zig` | Done |

### Testing Infrastructure - COMPLETE

- **185+ unit tests passing**
- **43 e2e tests passing**
- Table-driven tests for comprehensive coverage
- Golden file infrastructure ready

---

## Architecture

```
Source → Scanner → Parser → AST
                              ↓
                         Type Checker
                              ↓
                         Lowerer → IR
                              ↓
                         SSABuilder → SSA Func
                              ↓
                    Passes (lower, regalloc)
                              ↓
                         Codegen → Machine Code
                              ↓
                         Object Writer → .o file
                              ↓
                         Linker (zig cc) → Executable
```

### Debug Infrastructure

```bash
COT_DEBUG=all ./zig-out/bin/cot input.cot -o output
COT_DEBUG=parse,lower,ssa ./zig-out/bin/cot input.cot -o output
```

Available phases: `parse`, `check`, `lower`, `ssa`, `regalloc`, `codegen`

---

## Running Tests

```bash
# Fast unit tests (run frequently)
zig build test

# All tests including integration
zig build test-all

# Run e2e tests
cd test/e2e && ./run_tests.sh
```

---

## References

- Go compiler: `~/learning/go/src/cmd/compile/`
- See also: [CLAUDE.md](CLAUDE.md), [REGISTER_ALLOC.md](REGISTER_ALLOC.md)

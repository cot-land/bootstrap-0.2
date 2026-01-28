# Testing Strategy

## Current State

- **754 bootstrap tests** in `test/bootstrap/all_tests.cot`
- **185 inline tests** distributed across cot1 source files
- All tests pass with Zig compiler
- Stage 1 (cot1-stage1) compiles and runs tests correctly

## Test Types

### 1. Bootstrap Tests (754 tests)
End-to-end tests that verify compiled code produces correct results.

Located in: `test/bootstrap/all_tests.cot`

Categories:
- Arithmetic operations
- Function calls (1-9+ args, recursion)
- Control flow (if/else, while, break/continue)
- Structs and nested structs
- Pointers and arrays
- Strings and characters
- Bitwise operations
- Enums and defer

### 2. Inline Tests (185 tests)
Unit tests for compiler internal functions, embedded in cot1 source files.

Distribution:
```
84  lower.cot     - IR lowering logic
16  scanner.cot   - tokenization
15  types.cot     - type system
12  op.cot        - SSA operations
12  strmap.cot    - hash map
10  list.cot      - dynamic lists
9   ast.cot       - AST nodes
8   value.cot     - SSA values
7   block.cot     - SSA blocks
6   abi.cot       - ARM64 ABI
6   token.cot     - tokens
6   func.cot      - SSA functions
2   stdlib.cot    - stdlib
1   dom.cot       - dominators
```

## Running Tests

### Bootstrap Tests
```bash
zig build
./zig-out/bin/cot test/bootstrap/all_tests.cot -o /tmp/t && /tmp/t
```

### Build and Test Stage 1
```bash
# Build cot1-stage1
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1

# Test stage1 with bootstrap tests
/tmp/cot1-stage1 test/bootstrap/all_tests.cot -o /tmp/bt.o
zig cc /tmp/bt.o runtime/cot_runtime.o -o /tmp/bt -lSystem && /tmp/bt
```

## Known Issues

See [BUGS.md](BUGS.md) for active bug tracking.

## Test Quality Guidelines

Good inline tests:
- Test function behavior with multiple inputs
- Test edge cases (empty, boundary values)
- Test algorithms (alignment, hashing)

Avoid:
- Tests that just check constants equal themselves
- Tests that check global variable defaults
- Trivial initialization tests

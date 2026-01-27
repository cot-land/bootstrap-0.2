# Testing Strategy

## Current Problem

The 166 bootstrap tests have been passing for weeks, yet stage1 (cot1 compiled by Zig) has serious bugs that cause non-deterministic crashes when attempting self-hosting. **This proves the tests are too simple.**

Even a trivial 2-function test produces different machine code between Zig and cot1:
- Zig: 852 bytes, 10 instructions for `add()`
- cot1: 922 bytes, 13 instructions for `add()`

## New Strategy: Compiler Parity First

**Do NOT attempt self-hosting until Zig and cot1 produce identical output on comprehensive tests.**

```
Phase 1: Expand Tests (166 → 1000+)
    ├── Simple expressions → Complex expressions
    ├── Single functions → Multiple functions with calls
    ├── Basic types → All type combinations
    └── Trivial control flow → Nested loops/conditionals

Phase 2: Verify Parity
    ├── Compare object files byte-by-byte
    ├── Compare disassembly instruction-by-instruction
    └── Fix ALL differences before proceeding

Phase 3: Self-Hosting (only after 100% parity)
    └── Then stage1 should compile stage2 deterministically
```

## Test Categories to Add

### 1. Expression Complexity (Target: 200 tests)
```
Level 1: a + b
Level 2: a + b * c
Level 3: (a + b) * (c - d) / e
Level 4: Nested function calls: f(g(h(x)))
Level 5: Mixed: f(a + b, g(c * d))
```

### 2. Control Flow Complexity (Target: 200 tests)
```
Level 1: Single if/else
Level 2: Nested if/else (2-3 deep)
Level 3: If inside while
Level 4: While inside if
Level 5: Break/continue in nested loops
```

### 3. Function Patterns (Target: 200 tests)
```
Level 1: No args, simple return
Level 2: 1-2 args
Level 3: 3-8 args (register pressure)
Level 4: 9+ args (stack spill)
Level 5: Recursive functions
Level 6: Mutually recursive functions
```

### 4. Type Combinations (Target: 200 tests)
```
- All primitive types: i64, u8, bool
- Pointer types: *T, **T
- Array access patterns
- Struct field access chains
- Mixed pointer/struct combinations
```

### 5. Memory Patterns (Target: 200 tests)
```
- Local variables (various counts)
- Pointer arithmetic
- Address-of and dereference chains
- Array indexing patterns
- Struct layout and alignment
```

## Verification Process

For EVERY test, run this comparison:

```bash
# 1. Compile with Zig
./zig-out/bin/cot test.cot -o /tmp/zig.o

# 2. Compile with cot1
/tmp/cot1-stage1 test.cot -o /tmp/cot1.o

# 3. Compare
diff <(objdump -d /tmp/zig.o) <(objdump -d /tmp/cot1.o)

# 4. If different → FIX before adding more tests
```

## Test Organization

```
test/
├── bootstrap/           # Current 166 tests (keep as baseline)
│   └── all_tests.cot
├── parity/              # NEW: Compiler parity tests
│   ├── expressions/     # Expression complexity tests
│   ├── control_flow/    # Control flow tests
│   ├── functions/       # Function pattern tests
│   ├── types/           # Type combination tests
│   └── memory/          # Memory pattern tests
└── stages/
    └── cot1/            # cot1-specific feature tests
```

## Running Tests

### Bootstrap Tests (must pass first)
```bash
zig build
./zig-out/bin/cot test/bootstrap/all_tests.cot -o /tmp/t && /tmp/t
```

### Parity Verification (the new focus)
```bash
# Build stage1
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1

# Compare outputs on a test
./scripts/verify_parity.sh test/parity/expressions/test_001.cot
```

## Success Criteria

1. **All 1000+ tests pass** with both compilers
2. **Zero byte differences** in generated code for all tests
3. **Stage2 compiles deterministically** (100% success rate)
4. **Stage2 = Stage3** (byte-for-byte identical)

Only then is the compiler ready for self-hosting.

## Current Status (2026-01-27)

| Metric | Value | Target |
|--------|-------|--------|
| Bootstrap tests | 166 | 166 (baseline) |
| Parity tests | 172 | 1000+ |
| Functional parity | 170/172 (98.8%) | 100% |
| Byte-exact parity | 0/172 (0%) | 100% |

### Known Bugs Found by Parity Tests

**ty_010_u8: cot1 uses 64-bit load for u8 comparison**
- cot1 generates `ldr x, [addr]` instead of `ldrb w, [addr]`
- This causes 64-bit load to include garbage from overlapping 64-bit stores
- Zig compiler correctly uses `ldrb` for u8 loads
- Fix needed in `stages/cot1/codegen/genssa.cot` to use byte-sized load/store ops

**fn_024_ackermann: cot1 bug with nested recursive calls**
- Pattern: `return ack(m - 1, ack(m, n - 1));`
- The inner recursive call result is corrupted before outer call
- ack(2,3) returns 6 in cot1, should be 9
- Likely register spill/restore issue in codegen

**Zig compiler bug: Global variable initialization broken**
- `var g_value: i64 = 100;` results in g_value being 0, not 100
- cot1 correctly initializes globals
- Workaround: initialize globals in main() instead of declaratively
- Tests ty_015, ty_016 use this workaround

### Scripts

```bash
# Run all parity tests
./scripts/run_all_parity.sh

# Run single parity test with details
./scripts/verify_parity.sh test/parity/expressions/expr_001_add.cot --verbose
```

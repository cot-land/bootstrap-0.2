# Test Architecture

## Overview

The Cot compiler uses a staged bootstrap architecture where each stage must pass all tests from previous stages plus its own new feature tests.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  TEST HIERARCHY                                                             │
│                                                                             │
│  Zig Bootstrap (zig-out/bin/cot)                                            │
│       │                                                                     │
│       ├── compiles test/bootstrap/all_tests.cot (166 tests)                 │
│       │                                                                     │
│       └── compiles stages/cot1/main.cot → /tmp/cot1-stage1                  │
│                │                                                            │
│                ├── compiles test/bootstrap/all_tests.cot (166 tests)        │
│                │   ✅ MUST PASS - proves cot1 has baseline parity           │
│                │                                                            │
│                ├── compiles test/stages/cot1/cot1_features.cot (9 tests)    │
│                │   ✅ MUST PASS - proves cot1 features work                 │
│                │                                                            │
│                └── TOTAL: 175 tests for cot1                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Test Directories

| Directory | Compiler | Description |
|-----------|----------|-------------|
| `test/bootstrap/` | Zig bootstrap | 166 baseline tests |
| `test/stages/cot1/` | cot1-stage1 | 9 cot1 feature tests |
| `test/stages/cot2/` | cot2-stage1 | (Future) cot2 feature tests |

## Test Counts

| Compiler | Bootstrap Tests | Feature Tests | Total |
|----------|-----------------|---------------|-------|
| Zig bootstrap | 166 | - | 166 |
| cot1-stage1 | 166 | 11 | **177** |
| cot2-stage1 | 166 | 11 + N | 177+ |

## Running Tests

### Bootstrap Tests (Zig Compiler)
```bash
# Build Zig compiler
zig build

# Run bootstrap tests
./zig-out/bin/cot test/bootstrap/all_tests.cot -o /tmp/all_tests && /tmp/all_tests
# Expected: All 166 tests passed!
```

### cot1 Tests
```bash
# Build cot1-stage1 with Zig
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1

# Run bootstrap tests with cot1 (proves parity)
/tmp/cot1-stage1 test/bootstrap/all_tests.cot -o /tmp/bootstrap.o
cp /tmp/bootstrap.o /tmp/bootstrap_test.o
zig cc /tmp/bootstrap_test.o runtime/cot_runtime.o -o /tmp/bootstrap_test && /tmp/bootstrap_test
# Expected: All 166 tests passed!

# Run cot1 feature tests
/tmp/cot1-stage1 test/stages/cot1/cot1_features.cot -o /tmp/cot1_features.o
cp /tmp/cot1_features.o /tmp/cot1_features_test.o
zig cc /tmp/cot1_features_test.o runtime/cot_runtime.o -o /tmp/cot1_features_test && /tmp/cot1_features_test
# Expected: All 9 tests passed!
```

### Quick Test Script
```bash
# One-liner for cot1 validation
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1 && \
/tmp/cot1-stage1 test/bootstrap/all_tests.cot -o /tmp/b.o && \
cp /tmp/b.o /tmp/bt.o && zig cc /tmp/bt.o runtime/cot_runtime.o -o /tmp/bt && /tmp/bt && \
/tmp/cot1-stage1 test/stages/cot1/cot1_features.cot -o /tmp/f.o && \
cp /tmp/f.o /tmp/ft.o && zig cc /tmp/ft.o runtime/cot_runtime.o -o /tmp/ft && /tmp/ft
```

## cot1 Features Tested

| Feature | Tests | Status |
|---------|-------|--------|
| Type aliases (`type Name = T`) | 3 | ✅ Pass |
| Optional types (`?*T`) | 3 | ✅ Pass |
| Error unions (`!T`) | 3 | ✅ Pass (syntax only, no real error handling) |
| Labeled break (placeholder) | 1 | ✅ Pass (placeholder) |
| Struct shorthand (placeholder) | 1 | ✅ Pass (placeholder) |

## Adding New Features

When adding a feature to cot1:

1. **Write tests first** in `test/stages/cot1/cot1_features.cot`
2. **Implement in Zig compiler** (`src/frontend/*.zig`)
3. **Verify Zig compiler passes tests**
4. **Implement in cot1** (`stages/cot1/frontend/*.cot`)
5. **Verify cot1-stage1 passes ALL tests** (166 + features)

## Key Principle

**Every stage must pass ALL tests from previous stages.**

This ensures:
1. No feature regressions
2. Full backward compatibility
3. Clear progression path through stages

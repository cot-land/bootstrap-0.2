# cot1 - Error Handling & Safety

**Status:** In Development (Phase 1 Complete)
**Compiled by:** Zig Bootstrap (Stage 0)
**Compiles:** Test programs, working toward self-hosting

## Overview

cot1 extends the baseline Cot language with error handling and safety features. The primary additions are error unions, optional types, and type aliases.

## Architecture (2026-01-26)

The cot1 compiler follows a modular architecture aligned with Zig's driver.zig pattern:

| Module | Responsibility | Lines |
|--------|----------------|-------|
| main.cot | Driver, compilation pipeline | ~900 |
| lib/import.cot | Path tracking, cycle detection | 389 |
| frontend/checker.cot | Type checking | 883 |
| codegen/genssa.cot | SSA codegen + finalization | ~2000 |

**Recent refactoring (48% reduction in main.cot):**
- GenState_finalize handles all linking/finalization
- lib/import.cot handles path resolution
- Checker wired into compilation pipeline (Phase 2.6)

## Current Progress

**180 tests pass** (166 bootstrap + 14 feature tests)

| Feature | Status | Tests |
|---------|--------|-------|
| **Type aliases** | ✅ DONE | 3 tests pass |
| **Optional types (`?T`)** | ✅ DONE | 3 tests pass |
| **Error unions (`!T`)** | ✅ DONE (syntax) | 3 tests pass |
| **Labeled break/continue** | ✅ DONE | 3 tests pass |
| String parameters | ✅ FIXED | All string tests pass |
| Parser 16+ args | ✅ FIXED | Large calls work |
| errdefer | Planned | - |
| Struct init shorthand | Planned | - |

## Building

```bash
# Build cot1-stage1 with Zig bootstrap
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1

# Self-hosting (in progress - has lowerer bugs)
/tmp/cot1-stage1 stages/cot1/main.cot -o /tmp/cot1-stage2
```

## Testing

```bash
# Build cot1-stage1
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1

# Run bootstrap tests (166 tests)
/tmp/cot1-stage1 test/bootstrap/all_tests.cot -o /tmp/bt.o
cp /tmp/bt.o /tmp/bootstrap_test.o
zig cc /tmp/bootstrap_test.o runtime/cot_runtime.o -o /tmp/bootstrap_test
/tmp/bootstrap_test

# Run cot1 feature tests (11 tests)
/tmp/cot1-stage1 test/stages/cot1/cot1_features.cot -o /tmp/ft.o
cp /tmp/ft.o /tmp/feature_test.o
zig cc /tmp/feature_test.o runtime/cot_runtime.o -o /tmp/feature_test
/tmp/feature_test
```

## Self-Hosting Status

**cot1-stage1 successfully compiles cot1 source** (459KB Mach-O object).

Current blocker: **BUG-063 SIGBUS crash** - The self-hosted binary crashes on startup with a bus error. Possible causes:
- Pointer arithmetic generating misaligned addresses
- Incorrect struct field offset calculations
- Stack frame layout issues in generated code

See BUGS.md for investigation details.

## Development Rules

1. **Copy from Zig** - All features follow Zig's patterns (src/frontend/*.zig)
2. **Test first** - Write 3-5 tests before implementing
3. **All 180 tests must pass** - No regressions (166 bootstrap + 14 features)
4. **Self-hosting** - Ultimate goal: cot1 compiles itself

## Current Feature Implementation

### Type Aliases (DONE)
```cot
type Index = i64
type Offset = i64
let x: Index = 42;
```

### Optional Types (DONE)
```cot
let ptr: ?*Item = null;
if ptr == null { ... }
ptr = &item;
```

### Error Unions (DONE - syntax only)
```cot
fn getValue() !i64 {
    return 42;
}
let result: !i64 = getValue();
```

Note: Error unions use simplified semantics (`!T` treated as `T`).
Full error handling (try/catch/errdefer) planned for future.

### Labeled Break/Continue (DONE)
```cot
:outer while i < 10 {
    while j < 10 {
        if condition {
            break :outer;  // Break outer loop
        }
        continue :outer;   // Continue outer loop
    }
}
```

See [LANGUAGE_EVOLUTION.md](../LANGUAGE_EVOLUTION.md) for complete roadmap.

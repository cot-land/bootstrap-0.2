# cot1 - Error Handling & Safety

**Status:** In Development (Phase 1 Complete)
**Compiled by:** Zig Bootstrap (Stage 0)
**Compiles:** Test programs, working toward self-hosting

## Overview

cot1 extends the baseline Cot language with error handling and safety features. The primary additions are error unions, optional types, and type aliases.

## Current Progress

**177 tests pass** (166 bootstrap + 11 feature tests)

| Feature | Status | Tests |
|---------|--------|-------|
| **Type aliases** | ✅ DONE | 3 tests pass |
| **Optional types (`?T`)** | ✅ DONE | 3 tests pass |
| **Error unions (`!T`)** | ✅ DONE (syntax) | 3 tests pass |
| String parameters | ✅ FIXED | All string tests pass |
| errdefer | Planned | - |
| Labeled break/continue | Planned | - |
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

## Self-Hosting Blocker

When cot1-stage1 tries to compile its own source, it encounters lowerer errors:
- TypeExpr* nodes passed to `lowerExpr` (should go to `resolve_type_expr`)
- ExprStmt nodes in expression context

This needs investigation in `stages/cot1/frontend/lower.cot`.

## Development Rules

1. **Copy from Zig** - All features follow Zig's patterns (src/frontend/*.zig)
2. **Test first** - Write 3-5 tests before implementing
3. **All 177 tests must pass** - No regressions (166 bootstrap + 11 features)
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

See [LANGUAGE_EVOLUTION.md](../LANGUAGE_EVOLUTION.md) for complete roadmap.

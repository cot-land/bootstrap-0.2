# cot1 - Error Handling & Safety

**Status:** In Development
**Compiled by:** cot0
**Compiles:** Itself (self-hosting target)

## Overview

cot1 extends cot0 with error handling and safety features that make writing robust code easier. The primary additions are error unions and optional types.

## Features

| Feature | Status | Tests |
|---------|--------|-------|
| Error unions (`Error!T`) | Planned | test/cot1/test_error_union_*.cot |
| **Optional types (`?T`)** | **DONE** | test/cot1/test_optional_*.cot (4 tests) |
| **Type aliases** | **DONE** | test/cot1/test_type_alias_*.cot (3 tests) |
| errdefer | Planned | test/cot1/test_errdefer_*.cot |
| Const pointers | Planned | test/cot1/test_const_ptr_*.cot |
| Labeled break/continue | Planned | test/cot1/test_labeled_*.cot |
| String improvements | Planned | test/cot1/test_string_*.cot |
| Struct init shorthand | Planned | test/cot1/test_struct_short_*.cot |
| Default parameters | Planned | test/cot1/test_default_param_*.cot |
| Improved switch | Planned | test/cot1/test_switch_*.cot |

## Building

```bash
# Build cot1 with cot0 (stage1)
/tmp/cot0-stage1 cot1/main.cot -o /tmp/cot1-stage1

# Build cot1 with itself (stage2) - self-hosting proof
/tmp/cot1-stage1 cot1/main.cot -o /tmp/cot1-stage2

# Verify stage1 == stage2
diff <(xxd /tmp/cot1-stage1) <(xxd /tmp/cot1-stage2)
```

## Testing

```bash
# Run all cot1 feature tests
./zig-out/bin/cot test/cot1/all_cot1_tests.cot -o /tmp/cot1_tests && /tmp/cot1_tests

# Ensure cot0 tests still pass (no regressions)
./zig-out/bin/cot test/e2e/all_tests.cot -o /tmp/all_tests && /tmp/all_tests
```

## Development Rules

1. **3-5 tests per feature** - Write tests before implementing
2. **All tests must pass** - No regressions allowed
3. **Copy from Zig** - Error unions follow Zig's design
4. **Self-hosting** - cot1 must compile itself

## Feature Specifications

### Error Unions

```cot
// Error set definition
const FileError = error {
    NotFound,
    PermissionDenied,
};

// Function returning error union
fn readFile(path: string) FileError!string {
    if not exists(path) {
        return error.NotFound;
    }
    return contents;
}

// Using try
fn process() FileError!void {
    let data: string = try readFile("config.txt");
    // ...
}

// Using catch
let data: string = readFile("config.txt") catch |err| "default";
```

### Optional Types

```cot
// Optional type
fn find(items: []Item, key: i64) ?*Item {
    // ...
    return null;
}

// If-unwrap
if find(items, 42) |item| {
    use(item);
}

// Orelse
let item: *Item = find(items, 42) orelse &default;
```

See [LANGUAGE_EVOLUTION.md](../LANGUAGE_EVOLUTION.md) for complete specifications.

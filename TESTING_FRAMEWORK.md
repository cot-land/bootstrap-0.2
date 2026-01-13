# Bootstrap 0.2 Testing Framework Design

A comprehensive testing framework modeled after Go 1.22's proven compiler testing infrastructure.

See also:
- [CLAUDE.md](CLAUDE.md) - Development guidelines and Zig 0.15 API reference
- [IMPROVEMENTS.md](IMPROVEMENTS.md) - Go patterns implemented

---

## Lessons Learned from Previous Rewrites

This is **Cot's third rewrite**. Here's what killed the previous attempts:

### What Went Wrong

1. **Cot 0.1**: 200k lines in 2 weeks. No tests. Bugs compounded faster than fixes.
2. **Bootstrap 1.0**: Tests existed but were weak (exit code only). "Whack-a-mole" debugging.

### The Whack-a-Mole Pattern

```
Fix bug A → Introduces bug B → Fix bug B → Reintroduces bug A → ...
```

This happens when:
- Tests don't cover enough cases
- Fixing one test breaks another (no regression detection)
- Error messages aren't tested (bugs hide in "error occurred" checks)
- Output format isn't locked down (changes slip through)

### How This Framework Prevents It

| Problem | Solution |
|---------|----------|
| Tests don't cover enough | Table-driven tests with many cases |
| Fixing one test breaks another | Golden files detect regressions |
| Error messages not tested | Directive tests with `// ERROR "pattern"` |
| Output changes slip through | Golden files lock down format |
| Tests pass but behavior wrong | Integration tests verify end-to-end |
| Performance regresses | Allocation tracking tests |

---

## Philosophy

**"If it's not tested, it's broken."** - Go proverb

The old bootstrap had crude tests that only checked exit codes. This framework ensures:

1. **Correctness** - Every compiler feature has corresponding tests
2. **Regression prevention** - Golden files catch unintended changes
3. **Error quality** - Error messages are tested, not just error occurrence
4. **Performance tracking** - Allocation and timing tests prevent regressions
5. **Self-hosting readiness** - Comprehensive tests before attempting self-host

## Test Categories

### 1. Unit Tests (per-module)

Location: Inline in each `.zig` file

These test individual functions and types in isolation.

```zig
// In src/ssa/op.zig
test "Op.info returns correct metadata" {
    const info = Op.add.info();
    try std.testing.expect(info.commutative);
    try std.testing.expectEqual(@as(i8, 2), info.arg_len);
}
```

**Pattern: Table-Driven Tests** (Already implemented in op.zig)

```zig
const TestCase = struct {
    input: Input,
    expected: Expected,
    name: []const u8,  // For debugging failures
};

const test_cases = [_]TestCase{
    .{ .input = ..., .expected = ..., .name = "basic case" },
    .{ .input = ..., .expected = ..., .name = "edge case" },
};

test "feature behaves correctly" {
    for (test_cases) |tc| {
        const result = feature(tc.input);
        std.testing.expectEqual(tc.expected, result) catch |err| {
            std.debug.print("FAILED: {s}\n", .{tc.name});
            return err;
        };
    }
}
```

### 2. Integration Tests (cross-module)

Location: `src/main.zig` test block and `test/integration/`

These test multiple modules working together.

```zig
test "SSA integration: build and verify diamond CFG" {
    var builder = ssa.TestFuncBuilder.init(allocator);
    defer builder.deinit();

    const cfg = try builder.createDiamondCFG();
    const errors = try ssa.test_helpers.validateInvariants(cfg.func, allocator);
    try std.testing.expectEqual(@as(usize, 0), errors.len);
}
```

### 3. Golden File Tests

Location: `test/golden/`

Compare compiler output against known-good snapshots.

```
test/golden/
├── ssa/
│   ├── simple_add.ssa.golden      # Expected SSA dump
│   ├── diamond_cfg.ssa.golden
│   └── loop.ssa.golden
├── codegen/
│   ├── simple_add.arm64.golden    # Expected assembly
│   └── simple_add.generic.golden
└── errors/
    ├── undefined_var.stderr.golden
    └── type_mismatch.stderr.golden
```

**Golden Test Runner:**

```zig
// test/golden_test.zig
const GoldenTest = struct {
    name: []const u8,
    input: []const u8,
    golden_path: []const u8,
    phase: Phase,

    const Phase = enum { parse, ssa, codegen, full };
};

fn runGoldenTest(t: GoldenTest, allocator: Allocator) !void {
    const actual = try compileToPhase(t.input, t.phase, allocator);
    defer allocator.free(actual);

    const expected = try readFile(t.golden_path, allocator);
    defer allocator.free(expected);

    if (!std.mem.eql(u8, actual, expected)) {
        // Write actual output for comparison
        try writeFile(t.golden_path ++ ".actual", actual);
        return error.GoldenMismatch;
    }
}
```

**Updating Goldens:**

```bash
# Regenerate all golden files (use sparingly)
COT_UPDATE_GOLDEN=1 zig build test

# Review changes before committing
git diff test/golden/
```

### 4. Directive-Based Tests (Go Pattern)

Location: `test/cases/`

Source files with special comments that specify expected behavior.

```
test/cases/
├── run/           # Should compile and run successfully
├── compile/       # Should compile (no run)
├── errorcheck/    # Should produce specific errors
└── codegen/       # Check generated assembly
```

**Directive Comments:**

```cot
// run
// Tests that basic arithmetic works.
fn main() {
    let x = 40 + 2;
    assert(x == 42);
}
```

```cot
// errorcheck
// Tests undefined variable error.
fn main() {
    let x = y; // ERROR "undefined: y"
}
```

```cot
// compile
// Just verify this compiles.
fn complex_generics[T, U](a: T, b: U) -> T { ... }
```

**Directive Test Runner:**

```zig
// test/directive_runner.zig
const Directive = enum {
    run,           // Compile, run, expect exit 0
    compile,       // Compile only, expect success
    errorcheck,    // Compile, expect specific errors
    build_error,   // Compile, expect build failure
    skip,          // Skip this test
};

const ErrorExpectation = struct {
    line: usize,
    pattern: []const u8,  // Regex or substring
};

fn parseDirectives(source: []const u8) !TestSpec {
    var spec = TestSpec{};
    var lines = std.mem.split(u8, source, "\n");

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "// run")) {
            spec.directive = .run;
        } else if (std.mem.startsWith(u8, line, "// errorcheck")) {
            spec.directive = .errorcheck;
        } else if (std.mem.indexOf(u8, line, "// ERROR")) |idx| {
            const pattern = extractPattern(line[idx..]);
            try spec.errors.append(.{ .line = lineNum, .pattern = pattern });
        }
        // ... more directives
    }
    return spec;
}
```

### 5. Script Tests (txtar format)

Location: `test/script/`

Multi-file test scenarios in a single file.

```
-- test/script/module_import.txt --
Test that module imports work correctly.

-- main.cot --
import "helper"

fn main() {
    helper.greet()
}

-- helper.cot --
pub fn greet() {
    print("Hello")
}

-- stdout --
Hello

-- exit --
0
```

**Script Test Runner:**

```zig
// test/script_runner.zig
const TxtarArchive = struct {
    comment: []const u8,
    files: std.StringHashMap([]const u8),

    fn parse(content: []const u8) !TxtarArchive { ... }
};

fn runScriptTest(archive: TxtarArchive, allocator: Allocator) !void {
    // Create temp directory
    const tmp = try createTempDir();
    defer deleteTempDir(tmp);

    // Extract files
    for (archive.files) |name, content| {
        try writeFile(tmp ++ "/" ++ name, content);
    }

    // Run compiler
    const result = try runCompiler(tmp ++ "/main.cot");

    // Check expectations
    if (archive.files.get("stdout")) |expected| {
        try expectEqual(expected, result.stdout);
    }
    if (archive.files.get("exit")) |expected| {
        try expectEqual(parseInt(expected), result.exit_code);
    }
}
```

### 6. Error Message Tests

Location: `test/errors/`

Dedicated tests for error message quality.

```zig
// test/error_test.zig
const ErrorTest = struct {
    name: []const u8,
    source: []const u8,
    expected_error: ExpectedError,
};

const ExpectedError = struct {
    kind: core.errors.ErrorKind,
    line: ?usize = null,
    column: ?usize = null,
    contains: []const u8,  // Message must contain this
};

const error_tests = [_]ErrorTest{
    .{
        .name = "undefined variable shows name",
        .source = "fn main() { x }",
        .expected_error = .{
            .kind = .undefined_name,
            .line = 1,
            .contains = "'x'",
        },
    },
    .{
        .name = "type mismatch shows both types",
        .source = "fn main() { let x: int = \"hello\" }",
        .expected_error = .{
            .kind = .type_mismatch,
            .contains = "int",  // Should mention expected type
        },
    },
};
```

### 7. Allocation Tests

Location: Inline using `CountingAllocator` (already implemented)

```zig
test "SSA pass is allocation-efficient" {
    var counting = core.CountingAllocator.init(std.testing.allocator);
    const allocator = counting.allocator();

    var f = ssa.Func.init(allocator, "test");
    defer f.deinit();

    // Run optimization pass
    try ssa.compile.runPass(&f, .deadcode);

    // Verify allocation bounds
    try std.testing.expect(counting.alloc_count < 100);
}
```

### 8. Fuzz Tests

Location: `test/fuzz/`

Random input generation to find edge cases.

```zig
// test/fuzz/parser_fuzz.zig
pub fn fuzzParser(input: []const u8) void {
    // Should never crash, only return errors
    _ = Parser.parse(input) catch return;
}

test "fuzz parser with random input" {
    var prng = std.rand.DefaultPrng.init(0);

    for (0..10000) |_| {
        const len = prng.random().intRangeAtMost(usize, 0, 1000);
        var buf: [1000]u8 = undefined;
        prng.random().bytes(buf[0..len]);

        fuzzParser(buf[0..len]);
    }
}
```

### 9. Generated Exhaustive Tests

Location: `test/generated/`

Programmatically generated tests for exhaustive coverage.

```zig
// test/gen_op_tests.zig
// Generates tests for all Op combinations

fn generateOpTests(writer: anytype) !void {
    for (std.enums.values(Op)) |op| {
        const info = op.info();

        try writer.print(
            \\test "Op.{s} has valid metadata" {{
            \\    const info = Op.{s}.info();
            \\    try std.testing.expect(info.arg_len >= -1);
            \\    try std.testing.expect(info.arg_len <= 4);
            \\}}
            \\
        , .{ @tagName(op), @tagName(op) });
    }
}
```

### 10. SSA Pass Tests

Location: `test/ssa/passes/`

Verify each optimization pass independently.

```zig
// test/ssa/passes/deadcode_test.zig
test "deadcode removes unused values" {
    var builder = ssa.TestFuncBuilder.init(allocator);
    defer builder.deinit();

    // Build: v1 = const 1; v2 = const 2 (unused); return v1
    const b = try builder.func.newBlock(.ret);
    const v1 = try builder.addConst(b, 1);
    const v2 = try builder.addConst(b, 2);  // Unused
    _ = v2;
    b.setControl(v1);

    // Snapshot before
    const before = try ssa.debug.PhaseSnapshot.capture(allocator, builder.func, "before");

    // Run pass
    try ssa.compile.runPass(builder.func, .deadcode);

    // Snapshot after
    const after = try ssa.debug.PhaseSnapshot.capture(allocator, builder.func, "after");

    // Verify
    const stats = before.compare(&after);
    try std.testing.expect(stats.values_removed >= 1);
}
```

## Directory Structure

```
bootstrap-0.2/
├── src/
│   ├── main.zig              # Contains inline unit tests
│   ├── core/
│   │   ├── types.zig         # Unit tests inline
│   │   ├── errors.zig        # Unit tests inline
│   │   └── testing.zig       # CountingAllocator, test utilities
│   ├── ssa/
│   │   ├── test_helpers.zig  # TestFuncBuilder, validateInvariants
│   │   └── *.zig             # Unit tests inline
│   └── codegen/
│       └── *.zig             # Unit tests inline
│
├── test/
│   ├── golden/               # Golden file snapshots
│   │   ├── ssa/
│   │   ├── codegen/
│   │   └── errors/
│   │
│   ├── cases/                # Directive-based tests
│   │   ├── run/              # // run tests
│   │   ├── compile/          # // compile tests
│   │   ├── errorcheck/       # // errorcheck tests
│   │   └── codegen/          # Assembly verification
│   │
│   ├── script/               # Multi-file txtar tests
│   │   ├── imports.txt
│   │   ├── modules.txt
│   │   └── linking.txt
│   │
│   ├── errors/               # Error message quality tests
│   │   └── error_messages_test.zig
│   │
│   ├── fuzz/                 # Fuzz testing
│   │   ├── parser_fuzz.zig
│   │   └── ssa_fuzz.zig
│   │
│   ├── generated/            # Auto-generated exhaustive tests
│   │   └── all_ops_test.zig
│   │
│   ├── integration/          # Cross-module integration tests
│   │   └── full_pipeline_test.zig
│   │
│   └── runners/              # Test infrastructure
│       ├── golden_runner.zig
│       ├── directive_runner.zig
│       └── script_runner.zig
│
├── build.zig                 # Build configuration with test targets
├── TESTING_FRAMEWORK.md      # This document
└── IMPROVEMENTS.md           # Implementation improvements
```

## Test Infrastructure Components

### 1. Test Runner Configuration

```zig
// build.zig
pub fn build(b: *std.Build) void {
    // Unit tests (fast, run frequently)
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
    });

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_source_file = b.path("test/integration/full_pipeline_test.zig"),
    });

    // Golden tests
    const golden_tests = b.addTest(.{
        .root_source_file = b.path("test/runners/golden_runner.zig"),
    });

    // Test steps
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const test_all_step = b.step("test-all", "Run all tests");
    test_all_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_all_step.dependOn(&b.addRunArtifact(integration_tests).step);
    test_all_step.dependOn(&b.addRunArtifact(golden_tests).step);

    const test_golden_step = b.step("test-golden", "Run golden file tests");
    test_golden_step.dependOn(&b.addRunArtifact(golden_tests).step);
}
```

### 2. Test Utilities Module

```zig
// src/core/testing.zig (extend existing)
pub const TestContext = struct {
    allocator: std.mem.Allocator,
    temp_dir: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) TestContext {
        return .{ .allocator = allocator };
    }

    pub fn createTempDir(self: *TestContext) ![]const u8 {
        // Create isolated temp directory for test
    }

    pub fn cleanup(self: *TestContext) void {
        // Remove temp directory
    }
};

pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("Expected to contain: {s}\nActual: {s}\n", .{ needle, haystack });
        return error.TestExpectationFailed;
    }
}

pub fn expectError(expected: anyerror, actual: anyerror!void) !void {
    if (actual) |_| {
        return error.ExpectedError;
    } else |err| {
        try std.testing.expectEqual(expected, err);
    }
}
```

### 3. Diff Utility for Golden Tests

```zig
// test/runners/diff.zig
pub fn diff(expected: []const u8, actual: []const u8) DiffResult {
    var result = DiffResult{};

    var exp_lines = std.mem.split(u8, expected, "\n");
    var act_lines = std.mem.split(u8, actual, "\n");

    var line_num: usize = 1;
    while (true) {
        const exp = exp_lines.next();
        const act = act_lines.next();

        if (exp == null and act == null) break;

        if (!std.mem.eql(u8, exp orelse "", act orelse "")) {
            result.addDifference(line_num, exp, act);
        }
        line_num += 1;
    }

    return result;
}

pub const DiffResult = struct {
    differences: std.ArrayList(Difference),

    pub fn format(self: DiffResult, writer: anytype) !void {
        for (self.differences.items) |d| {
            try writer.print("Line {d}:\n", .{d.line});
            try writer.print("  - {s}\n", .{d.expected orelse "(missing)"});
            try writer.print("  + {s}\n", .{d.actual orelse "(missing)"});
        }
    }
};
```

## Test Coverage Goals

### Phase 1: Core Infrastructure (Before Parsing)
- [x] SSA Value/Block/Func unit tests
- [x] Op metadata table-driven tests
- [x] Error type unit tests
- [x] Test helpers (TestFuncBuilder, validateInvariants)
- [x] Allocation tracking (CountingAllocator)
- [ ] Golden test runner
- [ ] Diff utility

### Phase 2: Frontend (Parsing)
- [ ] Lexer unit tests (token by token)
- [ ] Parser unit tests (AST structure)
- [ ] Parser error tests (all error paths)
- [ ] Parser golden tests (AST dumps)
- [ ] Parser fuzz tests

### Phase 3: Middle-end (Type Checking, Lowering)
- [ ] Type checker unit tests
- [ ] Type error message tests
- [ ] IR lowering tests
- [ ] SSA construction tests

### Phase 4: Backend (Optimization, Codegen)
- [ ] Per-pass optimization tests
- [ ] Codegen golden tests (assembly output)
- [ ] End-to-end run tests
- [ ] Performance regression tests

### Phase 5: Self-Hosting Preparation
- [ ] Compiler compiles itself test
- [ ] Output binary matches test
- [ ] Full test suite passes with self-compiled compiler

## Running Tests

```bash
# Fast unit tests (run frequently during development)
zig build test

# All tests including integration
zig build test-all

# Just golden file tests
zig build test-golden

# Update golden files after intentional changes
COT_UPDATE_GOLDEN=1 zig build test-golden

# Verbose output for debugging
zig build test -- --verbose

# Run specific test
zig build test -- --test-filter "SSA integration"

# With allocation tracking
zig build test -Dtrack-allocations
```

## Test Writing Guidelines

### 1. Name Tests Descriptively

```zig
// BAD
test "test1" { ... }

// GOOD
test "parser rejects unterminated string literal" { ... }
```

### 2. One Assertion Per Concept

```zig
// BAD - unclear what failed
test "value is correct" {
    try std.testing.expect(v.op == .add and v.uses == 2 and v.args.len == 2);
}

// GOOD - clear failure messages
test "add value has correct properties" {
    try std.testing.expectEqual(Op.add, v.op);
    try std.testing.expectEqual(@as(i32, 2), v.uses);
    try std.testing.expectEqual(@as(usize, 2), v.args.len);
}
```

### 3. Test Error Paths

```zig
// Don't just test success
test "parser handles invalid syntax" {
    const result = Parser.parse("fn {{{");
    try std.testing.expectError(error.SyntaxError, result);
}
```

### 4. Use Test Fixtures

```zig
// Use TestFuncBuilder for consistent setup
test "optimization pass" {
    var builder = ssa.TestFuncBuilder.init(allocator);
    defer builder.deinit();

    const cfg = try builder.createDiamondCFG();
    // ... test using cfg
}
```

### 5. Document Non-Obvious Tests

```zig
// If the test isn't self-explanatory, add a comment
test "phi nodes require predecessor order match" {
    // Phi arguments must correspond to block predecessor order.
    // This test verifies the verifier catches mismatches.
    // See Go's cmd/compile/internal/ssa/check.go:checkFunc
    ...
}
```

## Continuous Integration

```yaml
# .github/workflows/test.yml
name: Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: goto-bus-stop/setup-zig@v2

      - name: Unit Tests
        run: zig build test

      - name: Integration Tests
        run: zig build test-all

      - name: Check Golden Files
        run: |
          zig build test-golden
          # Fail if any .actual files were created
          ! find test/golden -name "*.actual" | grep .
```

## References

- Go compiler tests: `go/test/` directory
- Go SSA tests: `go/src/cmd/compile/internal/ssa/*_test.go`
- txtar format: `go/src/cmd/go/internal/txtar/`
- Test directives: `go/test/run.go`

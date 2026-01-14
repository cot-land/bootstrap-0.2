# Execution Plan: Basic Cot App → Comprehensive Test Suite

This document outlines the path from compiling a basic `.cot` application to having a fully-featured, single-file test suite.

---

## Architecture Decision (2026-01-14)

**We use Go-influenced design with pragmatic simplifications.**

After comprehensive analysis of Go's compiler (cmd/compile), we identified 10 major divergences. Our strategic decision:

| Divergence | Go Has | We Have | Decision |
|------------|--------|---------|----------|
| Walk/Order phase | ~2000 lines | None | Add LATER when needed |
| Escape analysis | Full package | None | Add LATER for stack alloc |
| SSA passes | ~30 passes | Minimal | Add LATER for performance |
| Node storage | Pointers + GC | Indices + arena | **KEEP OURS** (better for self-hosting) |
| FwdRef pattern | Yes | Yes | **ALIGNED** |
| Use count tracking | Automatic | Manual | Add assertions, audit calls |

**Key principle:** Correctness first, performance later. A slow self-hosting compiler is infinitely better than a fast broken one.

**Claude-friendly debugging:** Every phase traceable via `COT_DEBUG=parse,lower,ssa,regalloc,codegen` environment variable.

---

## Current State (Updated 2026-01-14)

**Phase 1 MVP: COMPLETE**
- [x] Compilation Driver (`src/driver.zig`)
- [x] Frontend SSA → Backend integration
- [x] Basic ARM64 codegen (const_int, add, ret)
- [x] Mach-O output + linker integration
- [x] **`fn main() i64 { return 42; }` compiles and runs**
- [x] **`fn main() i64 { return 20 + 22; }` compiles and runs (returns 42)**
- [x] Pipeline debug infrastructure (`src/pipeline_debug.zig`)
- [x] Node caching in SSA builder (fixed duplicate value bug)

**Phase 2 Function Calls: COMPLETE**
- [x] static_call codegen with ARM64 ABI (args in x0-x7)
- [x] Mach-O relocations for BL instructions (ARM64_RELOC_BRANCH26)
- [x] **`add_one(41)` compiles and returns 42**
- [x] Redesigned asm.zig with Go-style parameterized encoding (fixed LDP/STP bug)
- [x] E2E test suite created (`test/e2e/all_tests.cot`) - 5/113 tests passing

**What's Working:**
- Full pipeline: Scanner → Parser → Checker → Lower → IR → SSA → Regalloc → Codegen → Mach-O → Link
- Function calls between functions in the same file
- Debug tracing via `COT_DEBUG=all`
- Unit tests passing

**What's Next (Phase 2 continued):**
1. Local variables (var/let stack allocation)
2. Comparison operators (==, !=, <, <=, >, >=)
3. Conditionals (if/else)
4. Loops (while)

---

## Phase 1: Minimal Viable Compiler (MVP) ✅ COMPLETE

**Goal:** Compile `fn main() i64 { return 42; }` to native ARM64 executable.

**Status:** DONE - both `return 42` and `return 20 + 22` work correctly.

### Step 1.1: Compilation Driver (`src/driver.zig`)

Create a single entry point that orchestrates the full pipeline.

```zig
pub const Driver = struct {
    allocator: Allocator,

    pub fn compile(self: *Driver, source: []const u8) !CompiledOutput {
        // 1. Parse
        var parser = Parser.init(self.allocator, source);
        const ast = try parser.parse();

        // 2. Type check
        var checker = Checker.init(self.allocator, &ast);
        try checker.check();

        // 3. Lower to IR
        var lowerer = Lowerer.init(self.allocator, &ast, &checker);
        const ir = try lowerer.lower();

        // 4. Convert IR to SSA
        var funcs: std.ArrayList(*ssa.Func) = .{};
        for (ir.funcs) |ir_func| {
            var builder = SSABuilder.init(self.allocator, ir_func, checker.types);
            const ssa_func = try builder.build();
            try funcs.append(self.allocator, ssa_func);
        }

        // 5. Run backend passes (lower, regalloc)
        for (funcs.items) |f| {
            try ssa.lower.run(f);
            try ssa.regalloc.run(f);
        }

        // 6. Generate machine code
        var code = std.ArrayList(u8).init(self.allocator);
        for (funcs.items) |f| {
            try arm64.generate(f, &code);
        }

        // 7. Write Mach-O
        return CompiledOutput{ .code = code.toOwnedSlice() };
    }
};
```

**Deliverable:** `zig build` produces `cot` binary that can read `.cot` files.

### Step 1.2: Frontend SSA → Backend Pass Integration

The SSABuilder creates `ssa.Func` but uses frontend ops. Need to:
1. Map frontend IR ops to SSA ops
2. Ensure SSA Func has all required fields for backend passes

**Key changes:**
- SSABuilder should emit backend-compatible ops (const_int, add, etc.)
- Ensure type indices are consistent between frontend and backend

### Step 1.3: Complete Minimal ARM64 Codegen

For MVP, support these ops only:
- `const_int` → `mov` immediate
- `add`, `sub`, `mul`, `div` → arithmetic instructions
- `ret` → return sequence

**Minimal function prologue/epilogue:**
```asm
_main:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ; ... body ...
    ldp x29, x30, [sp], #16
    ret
```

### Step 1.4: Mach-O Output + Linking

1. Write proper Mach-O with `_main` symbol exported
2. Shell out to `ld` or `zig cc` for linking:
   ```bash
   zig cc -o output output.o
   ```

**Deliverable:** `./cot tests/test_return.cot -o test && ./test` returns 42.

---

## Phase 2: Expand Language Support 🔄 IN PROGRESS

**Goal:** Support enough language features for meaningful tests.

**Go Alignment Notes:**
- Function calls: ✅ Following Go's ABI conventions (args in x0-x7)
- Conditionals: Use Go's `BlockIf` pattern from `ssagen/ssa.go`
- Loops: Follow Go's loop lowering from `walk/order.go`
- Variables: Use Go's `defvars` pattern (already implemented in SSABuilder)

### Step 2.1: Function Calls ✅ COMPLETE

- [x] `static_call` instruction with ABI-compliant register assignment
- [x] Mach-O relocations (ARM64_RELOC_BRANCH26 for BL instructions)
- [x] Go-style parameterized encoding in asm.zig (prevents bit-forgetting bugs)
- [ ] Caller-saved register handling (deferred - not needed for simple calls)
- [ ] Stack arguments for >8 parameters (deferred)

### Step 2.2: Conditionals

- `branch` → compare + conditional branch
- `if_` blocks with proper edge fixup

### Step 2.3: Loops

- `while` → condition block + body + back edge
- `for` → desugared to while

### Step 2.4: Local Variables

- Stack frame allocation
- `load_local` / `store_local` codegen

### Step 2.5: Comparison Operators

- `eq`, `ne`, `lt`, `le`, `gt`, `ge`
- Condition codes → set register

**Deliverable:** Can compile:
```cot
fn fib(n: i64) i64 {
    if n <= 1 { return n; }
    return fib(n - 1) + fib(n - 2);
}
fn main() i64 { return fib(10); }  // Returns 55
```

---

## Phase 3: Single-File Test Suite

**Goal:** Replace 100+ separate test files with one comprehensive test file.

### The Problem with Old Approach

```bash
# Old: Run 100 separate compiles (SLOW)
for test in tests/*.cot; do
    ./cot $test -o out && ./out
done
# Takes 30+ seconds, hard to debug failures
```

### The New Approach: Embedded Test Framework

All tests defined in a single Zig file, compiled once, run in-memory.

**Design Principles:**
1. **Single compilation** - One test binary runs all tests
2. **In-memory parsing** - Parse test cases from strings, no file I/O
3. **Parallel execution** - Run tests concurrently where possible
4. **Comprehensive reporting** - One summary at the end
5. **Easy test addition** - Add test = add a struct entry

### Step 3.1: Test Case Structure

```zig
// test/e2e/test_suite.zig

const TestCase = struct {
    name: []const u8,
    source: []const u8,
    kind: TestKind,
    expected: Expected,
};

const TestKind = enum {
    run,           // Compile + run, check exit code
    compile,       // Just compile, expect success
    compile_fail,  // Compile, expect specific error
    output,        // Compile + run, check stdout
};

const Expected = union(enum) {
    exit_code: u8,
    error_msg: []const u8,
    stdout: []const u8,
};
```

### Step 3.2: Test Definitions

```zig
const tests = [_]TestCase{
    // === Basic Expressions ===
    .{
        .name = "return literal",
        .source = "fn main() i64 { return 42; }",
        .kind = .run,
        .expected = .{ .exit_code = 42 },
    },
    .{
        .name = "addition",
        .source = "fn main() i64 { return 20 + 22; }",
        .kind = .run,
        .expected = .{ .exit_code = 42 },
    },
    .{
        .name = "subtraction",
        .source = "fn main() i64 { return 50 - 8; }",
        .kind = .run,
        .expected = .{ .exit_code = 42 },
    },

    // === Function Calls ===
    .{
        .name = "simple call",
        .source =
            \\fn add_one(x: i64) i64 { return x + 1; }
            \\fn main() i64 { return add_one(41); }
        ,
        .kind = .run,
        .expected = .{ .exit_code = 42 },
    },

    // === Control Flow ===
    .{
        .name = "if true",
        .source =
            \\fn main() i64 {
            \\    if true { return 42; }
            \\    return 0;
            \\}
        ,
        .kind = .run,
        .expected = .{ .exit_code = 42 },
    },
    .{
        .name = "if false",
        .source =
            \\fn main() i64 {
            \\    if false { return 0; }
            \\    return 42;
            \\}
        ,
        .kind = .run,
        .expected = .{ .exit_code = 42 },
    },

    // === Loops ===
    .{
        .name = "while loop",
        .source =
            \\fn main() i64 {
            \\    var sum: i64 = 0;
            \\    var i: i64 = 0;
            \\    while i < 10 {
            \\        sum = sum + i;
            \\        i = i + 1;
            \\    }
            \\    return sum;  // 0+1+2+...+9 = 45
            \\}
        ,
        .kind = .run,
        .expected = .{ .exit_code = 45 },
    },

    // === Error Cases ===
    .{
        .name = "undefined variable",
        .source = "fn main() i64 { return x; }",
        .kind = .compile_fail,
        .expected = .{ .error_msg = "undefined" },
    },
    .{
        .name = "type mismatch",
        .source = "fn main() i64 { return true; }",
        .kind = .compile_fail,
        .expected = .{ .error_msg = "type mismatch" },
    },

    // ... 50+ more tests covering all features ...
};
```

### Step 3.3: Test Runner

```zig
const TestRunner = struct {
    allocator: Allocator,
    driver: Driver,
    passed: usize = 0,
    failed: usize = 0,
    failures: std.ArrayList(Failure) = .{},

    const Failure = struct {
        name: []const u8,
        expected: Expected,
        actual: ActualResult,
    };

    pub fn runAll(self: *TestRunner) void {
        for (tests) |tc| {
            self.runOne(tc);
        }
        self.printSummary();
    }

    fn runOne(self: *TestRunner, tc: TestCase) void {
        const result = switch (tc.kind) {
            .run => self.compileAndRun(tc.source),
            .compile => self.compileOnly(tc.source),
            .compile_fail => self.expectCompileError(tc.source),
            .output => self.compileRunCheckOutput(tc.source),
        };

        if (self.matches(tc.expected, result)) {
            self.passed += 1;
        } else {
            self.failed += 1;
            try self.failures.append(.{
                .name = tc.name,
                .expected = tc.expected,
                .actual = result,
            });
        }
    }

    fn printSummary(self: *TestRunner) void {
        std.debug.print("\n=== Test Results ===\n", .{});
        std.debug.print("Passed: {d}\n", .{self.passed});
        std.debug.print("Failed: {d}\n", .{self.failed});

        if (self.failures.items.len > 0) {
            std.debug.print("\nFailures:\n", .{});
            for (self.failures.items) |f| {
                std.debug.print("  {s}: expected {}, got {}\n",
                    .{f.name, f.expected, f.actual});
            }
        }
    }
};
```

### Step 3.4: Integration with Build System

```zig
// build.zig
const e2e_tests = b.addTest(.{
    .root_source_file = b.path("test/e2e/test_suite.zig"),
    .target = target,
    .optimize = optimize,
});

// Add as dependency on compiler sources
e2e_tests.root_module.addImport("cot", main_module);

const e2e_step = b.step("test-e2e", "Run end-to-end tests");
e2e_step.dependOn(&b.addRunArtifact(e2e_tests).step);

// Main test step runs both unit and e2e
const test_step = b.step("test", "Run all tests");
test_step.dependOn(unit_tests_step);
test_step.dependOn(e2e_step);
```

### Step 3.5: In-Process Compilation

For maximum speed, compile and run in-process without spawning:

```zig
fn compileAndRun(self: *TestRunner, source: []const u8) ActualResult {
    // 1. Compile to machine code in memory
    const code = self.driver.compileToCode(source) catch |err| {
        return .{ .compile_error = @errorName(err) };
    };

    // 2. mmap as executable
    const executable = try mmap(code, PROT_READ | PROT_EXEC);
    defer munmap(executable);

    // 3. Cast to function and call
    const main_fn: *fn() i64 = @ptrCast(executable);
    const result = main_fn();

    return .{ .exit_code = @truncate(result) };
}
```

**Benefits:**
- No file I/O
- No process spawning
- Runs in <1 second for 100+ tests
- Easy debugging (breakpoints in test code)

---

## Phase 4: Test Categories

Once the framework is in place, organize tests by feature:

### 4.1: Expression Tests
- Literals (int, bool, string)
- Arithmetic (+, -, *, /, %)
- Comparison (==, !=, <, <=, >, >=)
- Logical (and, or, not)
- Unary (-, !)

### 4.2: Statement Tests
- Return
- If/else
- While
- For
- Block scope
- Variable declaration/assignment

### 4.3: Function Tests
- Simple calls
- Multiple parameters
- Recursion
- Mutual recursion

### 4.4: Type Tests
- Integer types (i8, i16, i32, i64, u8, u16, u32, u64)
- Booleans
- Strings (future)
- Structs (future)
- Enums (future)

### 4.5: Error Tests
- Undefined variable
- Type mismatch
- Missing return
- Duplicate definition
- Invalid syntax

---

## Implementation Timeline

### Week 1: MVP Compiler ✅ COMPLETE (Day 1)
- [x] Create `src/driver.zig` with full pipeline
- [x] Connect SSABuilder output to backend passes
- [x] Minimal ARM64 codegen (const_int, add, ret)
- [x] Mach-O output with linker integration
- [x] Pipeline debug infrastructure (COT_DEBUG env var)
- [x] **Milestone: `fn main() { return 42; }` compiles and runs**
- [x] **Milestone: `fn main() { return 20 + 22; }` compiles and runs**

### Week 2: Language Expansion
- [ ] Function calls with proper ABI
- [ ] Conditionals (if/else)
- [ ] Loops (while)
- [ ] Local variables
- [ ] **Milestone: Fibonacci function works**

### Week 3: Test Framework
- [ ] Create `test/e2e/test_suite.zig` structure
- [ ] Implement TestRunner with in-memory compilation
- [ ] Port first 20 tests from old framework
- [ ] Add to build.zig as `test-e2e` step
- [ ] **Milestone: `zig build test-e2e` runs 20+ tests in <2 seconds**

### Week 4: Full Test Coverage
- [ ] Port remaining tests from old framework
- [ ] Add error case tests
- [ ] Document test patterns
- [ ] **Milestone: 50+ tests, comprehensive coverage**

---

## Success Criteria

1. **MVP Works:** `./cot test.cot -o test && ./test` returns correct value
2. **Speed:** Full test suite runs in <5 seconds
3. **Single File:** All tests defined in one `test_suite.zig`
4. **Reporting:** Single summary shows all pass/fail with details
5. **Easy Extension:** Adding a test = adding one struct literal

---

## References

- Go test framework: `go/test/run.go`
- Zig's test runner: `lib/std/testing.zig`
- Old bootstrap tests: `~/cot-land/bootstrap/tests/`

# Bootstrap 0.2 - Development Guidelines

## THIS IS OUR THIRD REWRITE - READ THIS FIRST

Cot has been through **three rewrites**:
1. **Cot 0.1** - Failed. 200k lines in 2 weeks. Bugs compounded faster than fixes.
2. **Bootstrap 1.0** - Got far but hit "whack-a-mole" mode. Fix one bug, create another.
3. **Bootstrap 0.2** (this project) - Clean slate with PROVEN PATTERNS from Go.

**The pattern that killed previous attempts:**
```
Write code → Find bug → Fix bug → Create new bug → Fix that → Create two more → ...
```

**The pattern we MUST follow:**
```
Write test → Write code → Test passes → Commit → Next feature
```

If you find yourself debugging without a test that exposes the bug, **STOP**. Write the test first.

---

## ⚠️ ZIG 0.15 API - CRITICAL

This project uses **Zig 0.15.2**. The API is DIFFERENT from tutorials and examples online.

### ArrayList - THE MOST COMMON MISTAKE

```zig
// ❌ WRONG - Will NOT compile in Zig 0.15:
var list = std.ArrayList(u32).init(allocator);
list.append(item);
list.deinit();

// ✅ CORRECT - Zig 0.15 ArrayListUnmanaged:
var list = std.ArrayListUnmanaged(u32){};
try list.append(allocator, item);   // allocator on EVERY method call
list.deinit(allocator);             // allocator on deinit too
```

**Memory rule:** Every `ArrayList` method takes `allocator` as first parameter:
- `list.append(allocator, item)`
- `list.appendSlice(allocator, slice)`
- `list.deinit(allocator)`
- `list.toOwnedSlice(allocator)`

### AutoHashMap - Same Pattern

```zig
// ✅ CORRECT for Zig 0.15:
var map = std.AutoHashMap(K, V).init(allocator);  // init is OK here
defer map.deinit();
try map.put(key, value);  // no allocator needed on put
```

### Build System

```zig
// ✅ CORRECT for Zig 0.15:
const exe = b.addExecutable(.{
    .name = "cot",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});

// ❌ WRONG (old API - root_source_file was top-level):
const exe = b.addExecutable(.{
    .name = "cot",
    .root_source_file = b.path("src/main.zig"),  // WRONG
});
```

### Allocator VTable

```zig
// ✅ CORRECT for Zig 0.15 custom allocators:
const vtable = std.mem.Allocator.VTable{
    .alloc = myAlloc,
    .resize = myResize,
    .free = myFree,
    .remap = myRemap,  // NEW in 0.15 - required!
};
```

### Quick Reference Card

| What | Old API | Zig 0.15 API |
|------|---------|--------------|
| ArrayList init | `.init(allocator)` | `{}` (empty struct) |
| ArrayList append | `.append(item)` | `.append(allocator, item)` |
| ArrayList deinit | `.deinit()` | `.deinit(allocator)` |
| Build exe | `.root_source_file` at top | Inside `.root_module = b.createModule(...)` |
| Print | `std.io.getStdOut()` | `std.debug.print()` |
| Allocator VTable | 3 functions | 4 functions (add `remap`) |

---

## TEST-DRIVEN DEVELOPMENT - NON-NEGOTIABLE

### Before Writing Code

1. **Identify** what you're implementing
2. **Write a test** that will pass when it works
3. **Run test** - it should fail (proves test works)
4. **Implement** the feature
5. **Run test** - it should pass
6. **Commit**

### Test Categories We Use

| Category | Location | When to Use |
|----------|----------|-------------|
| Unit tests | Inline in `.zig` files | Every function |
| Table-driven tests | Inline with `TestCase` structs | Multiple inputs/outputs |
| Integration tests | `test/integration/` | Cross-module flows |
| Golden file tests | `test/golden/` | Output stability |
| Directive tests | `test/cases/` | End-to-end compilation |

### Running Tests

```bash
# Fast unit tests (run after every change)
zig build test

# All tests including integration
zig build test-all

# Golden file tests only
zig build test-golden

# Update golden files after intentional changes
COT_UPDATE_GOLDEN=1 zig build test-golden
```

### Table-Driven Test Pattern (from Go)

```zig
const TestCase = struct {
    name: []const u8,
    input: Input,
    expected: Expected,
};

const test_cases = [_]TestCase{
    .{ .name = "empty input", .input = .{}, .expected = .{} },
    .{ .name = "single item", .input = .{.x = 1}, .expected = .{.y = 2} },
    // ... more cases
};

test "feature works correctly" {
    for (test_cases) |tc| {
        const actual = myFunction(tc.input);
        std.testing.expectEqual(tc.expected, actual) catch |err| {
            std.debug.print("FAILED: {s}\n", .{tc.name});
            return err;
        };
    }
}
```

---

## ARCHITECTURE - GO-INSPIRED

We follow Go 1.22's compiler architecture. See `~/learning/go` for reference implementations.

### Pipeline Phases

```
Source → Parse → Type Check → Lower to IR → Convert to SSA → Optimize → Codegen → Object
```

### Key Modules

| Module | Purpose | Go Reference |
|--------|---------|--------------|
| `src/ssa/value.zig` | SSA values with use counting | `cmd/compile/internal/ssa/value.go` |
| `src/ssa/block.zig` | Basic blocks with edges | `cmd/compile/internal/ssa/block.go` |
| `src/ssa/func.zig` | Functions as block containers | `cmd/compile/internal/ssa/func.go` |
| `src/ssa/op.zig` | Operation definitions | `cmd/compile/internal/ssa/op.go` |
| `src/ssa/dom.zig` | Dominator tree computation | `cmd/compile/internal/ssa/dom.go` |
| `src/ssa/compile.zig` | Pass infrastructure | `cmd/compile/internal/ssa/compile.go` |
| `src/codegen/generic.zig` | Reference codegen | Stack-based, correct by construction |
| `src/codegen/arm64.zig` | Optimized ARM64 codegen | `cmd/compile/internal/arm64/ssa.go` |

### Design Patterns We Use

1. **Export test pattern** - `test_helpers.zig` exposes internals for testing
2. **Table-driven tests** - Struct arrays with name, input, expected
3. **Phase snapshots** - Capture before/after to verify pass effects
4. **Golden files** - Known-good output for regression detection
5. **Directive comments** - `// run`, `// errorcheck` for test specification
6. **Allocation tracking** - `CountingAllocator` for performance tests

---

## AVOIDING WHACK-A-MOLE MODE

### Symptoms of Whack-a-Mole

- Fixing a bug creates a new bug elsewhere
- Tests that passed yesterday now fail
- "It worked before I changed X" but you don't know why
- Multiple debugging sessions without progress

### Prevention Strategies

1. **Never fix a bug without a test first**
   - Write a test that exposes the bug
   - Verify the test fails
   - Fix the bug
   - Verify the test passes
   - If test suite has regressions, the fix was wrong

2. **Use the verification pass**
   ```zig
   const errors = try ssa.test_helpers.validateInvariants(&f, allocator);
   try std.testing.expectEqual(@as(usize, 0), errors.len);
   ```

3. **Snapshot before/after**
   ```zig
   var before = try ssa.debug.PhaseSnapshot.capture(allocator, &f, "before");
   defer before.deinit();

   // ... run optimization pass ...

   var after = try ssa.debug.PhaseSnapshot.capture(allocator, &f, "after");
   defer after.deinit();

   const stats = before.compare(&after);
   // Now you can see exactly what changed
   ```

4. **Golden file testing**
   - Commit golden files for stable output
   - If output changes unexpectedly, investigation is required
   - Use `COT_UPDATE_GOLDEN=1` only after verifying change is correct

### When Stuck

1. **Stop** - Don't keep trying random fixes
2. **Write a minimal test case** that exposes the problem
3. **Use debug output** - `try ssa.dump(&f, .text, writer)`
4. **Compare with Go** - How does Go handle this case?
5. **Ask** - It's better to clarify than to dig deeper into the wrong hole

---

## BUG TRACKING PROCESS

When you encounter a bug:

1. **Document** - Add to `BUGLIST.md` with:
   - Location (file:line)
   - Description (what happens vs what should happen)
   - Reproduction steps

2. **Test** - Create a test that exposes it:
   ```zig
   test "regression: issue #123 - phi node args wrong order" {
       // This test catches the bug from BUGLIST.md #123
       var builder = try ssa.TestFuncBuilder.init(allocator, "regression_123");
       defer builder.deinit();
       // ... setup that triggers the bug ...
       // Assert the correct behavior
   }
   ```

3. **Fix** - Implement the fix

4. **Verify** - Run full test suite, not just the new test

5. **Mark fixed** - Update `BUGLIST.md`

---

## FILE ORGANIZATION

```
bootstrap-0.2/
├── src/
│   ├── main.zig              # Entry point, module exports
│   ├── core/
│   │   ├── types.zig         # ID, TypeRef, shared types
│   │   ├── errors.zig        # CompileError, VerifyError
│   │   └── testing.zig       # CountingAllocator, test utils
│   ├── ssa/
│   │   ├── value.zig         # SSA Value type
│   │   ├── block.zig         # Basic blocks
│   │   ├── func.zig          # Functions
│   │   ├── op.zig            # Operations enum
│   │   ├── dom.zig           # Dominators
│   │   ├── compile.zig       # Pass infrastructure
│   │   ├── debug.zig         # Dump, verify, snapshots
│   │   └── test_helpers.zig  # TestFuncBuilder, validators
│   └── codegen/
│       ├── generic.zig       # Reference implementation
│       └── arm64.zig         # ARM64 optimized
├── test/
│   ├── golden/               # Golden file snapshots
│   ├── cases/                # Directive-based tests
│   ├── integration/          # Cross-module tests
│   └── runners/              # Test infrastructure
├── CLAUDE.md                 # This file
├── TESTING_FRAMEWORK.md      # Detailed test documentation
├── IMPROVEMENTS.md           # Go patterns implemented
└── EXECUTION_PLAN.md         # Implementation roadmap
```

---

## DEVELOPMENT WORKFLOW

### For Each Feature

1. **Update todo list** - Mark as in_progress
2. **Reference Go** - Find equivalent in `~/learning/go`
3. **Write tests first** - What should this feature do?
4. **Implement** - Match Go's approach, adapted to Zig
5. **Run tests** - `zig build test-all`
6. **Update documentation** - STATUS.md, IMPROVEMENTS.md
7. **Mark complete** - Update todo list

### For Each Bug Fix

1. **Write failing test** - Proves the bug exists
2. **Fix the bug** - Minimal change
3. **Run full suite** - No regressions
4. **Update BUGLIST.md** - Mark as fixed

### For Each Commit

```bash
# Before committing
zig build test-all

# If adding new golden output
COT_UPDATE_GOLDEN=1 zig build test-golden
git diff test/golden/  # Review changes

# Commit with descriptive message
git commit -m "Fix phi node predecessor ordering

Fixes issue where phi args didn't match block pred order.
Added regression test in test_helpers.zig.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## WHEN IN DOUBT

1. **Check Go source** - `~/learning/go/src/cmd/compile/internal/ssa/`
2. **Check existing tests** - How do we test similar things?
3. **Check Zig 0.15 docs** - API may differ from examples online
4. **Ask John** - Better to clarify than guess wrong

---

## CRITICAL: BACKEND FIRST

**Previous attempts failed in the BACKEND, not the frontend.**

Bootstrap's blocking bugs (BUG-019, BUG-020, BUG-021) are ALL in codegen/regalloc. The frontend (parser, type checker) works.

**Implementation Order:**
1. **Liveness Analysis** - Required for spill selection
2. **Register Allocator** - Go's 6-phase linear scan (see [REGISTER_ALLOC.md](REGISTER_ALLOC.md))
3. **Lowering Pass** - Generic → arch-specific ops
4. **Instruction Emission** - Real ARM64 encoding
5. **Object Output** - Mach-O files
6. **Frontend (last)** - Port from bootstrap after backend works

**DO NOT:**
- Implement MCValue (Zig's integrated approach) - This was tried and FAILED
- Skip liveness analysis - Required for correct spilling
- Implement frontend first - Backend is the blocker

See [EXECUTION_PLAN.md](EXECUTION_PLAN.md) for detailed phase breakdown.

---

## CURRENT GOAL

Build a solid foundation of **tested, verified infrastructure** before implementing the full compiler. The SSA framework is done. Now we need liveness, regalloc, lowering, and codegen.

The goal is not speed. The goal is **never having to rewrite again**.

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

**Current Status:** See [STATUS.md](STATUS.md)

---

## Zig 0.15 API - CRITICAL

This project uses **Zig 0.15.2**. The API is DIFFERENT from tutorials and examples online.

### ArrayList - THE MOST COMMON MISTAKE

```zig
// WRONG - Will NOT compile in Zig 0.15:
var list = std.ArrayList(u32).init(allocator);
list.append(item);
list.deinit();

// CORRECT - Zig 0.15 ArrayListUnmanaged:
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
// CORRECT for Zig 0.15:
var map = std.AutoHashMap(K, V).init(allocator);  // init is OK here
defer map.deinit();
try map.put(key, value);  // no allocator needed on put
```

### Build System

```zig
// CORRECT for Zig 0.15:
const exe = b.addExecutable(.{
    .name = "cot",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});

// WRONG (old API - root_source_file was top-level):
const exe = b.addExecutable(.{
    .name = "cot",
    .root_source_file = b.path("src/main.zig"),  // WRONG
});
```

### Allocator VTable

```zig
// CORRECT for Zig 0.15 custom allocators:
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
| `src/frontend/ir.zig` | Typed IR definitions | `cmd/compile/internal/ir/` |
| `src/frontend/ssa_builder.zig` | IR→SSA with FwdRef pattern | `cmd/compile/internal/ssagen/` |

### Design Patterns We Use

1. **FwdRef pattern** - Deferred phi insertion for correct SSA
2. **Table-driven tests** - Struct arrays with name, input, expected
3. **Phase snapshots** - Capture before/after to verify pass effects
4. **Golden files** - Known-good output for regression detection
5. **Type interning** - TypeRegistry with indices for fast comparison
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

### When Stuck

1. **Stop** - Don't keep trying random fixes
2. **Write a minimal test case** that exposes the problem
3. **Use debug output** - `try ssa.dump(&f, .text, writer)`
4. **Compare with Go** - How does Go handle this case?
5. **Ask** - It's better to clarify than to dig deeper into the wrong hole

---

## DEVELOPMENT WORKFLOW

### For Each Feature

1. **Reference Go** - Find equivalent in `~/learning/go`
2. **Write tests first** - What should this feature do?
3. **Implement** - Match Go's approach, adapted to Zig
4. **Run tests** - `zig build test`
5. **Update documentation** - STATUS.md if major milestone

### For Each Bug Fix

1. **Write failing test** - Proves the bug exists
2. **Fix the bug** - Minimal change
3. **Run full suite** - No regressions

### For Each Commit

```bash
# Before committing
zig build test

# Commit with descriptive message
git commit -m "Fix phi node predecessor ordering

Fixes issue where phi args didn't match block pred order.
Added regression test in ssa_builder.zig.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## WHEN IN DOUBT

1. **Check Go source** - `~/learning/go/src/cmd/compile/internal/ssa/`
2. **Check existing tests** - How do we test similar things?
3. **Check Zig 0.15 docs** - API may differ from examples online
4. **Ask John** - Better to clarify than guess wrong

---

## DOCUMENTATION

| Document | Purpose |
|----------|---------|
| [STATUS.md](STATUS.md) | Current project status and remaining work |
| [REGISTER_ALLOC.md](REGISTER_ALLOC.md) | Go's 6-phase regalloc algorithm |
| [DATA_STRUCTURES.md](DATA_STRUCTURES.md) | Go-to-Zig data structure translations |
| [TESTING_FRAMEWORK.md](TESTING_FRAMEWORK.md) | Testing philosophy and patterns |

---

## CURRENT GOAL

The frontend and IR→SSA pipeline are complete. The goal now is **end-to-end testing**: compile simple programs and verify they run correctly.

The goal is not speed. The goal is **never having to rewrite again**.

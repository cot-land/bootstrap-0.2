# Bootstrap 0.2 - Development Guidelines

## DEBUGGING INFRASTRUCTURE FIRST - HIGHEST PRIORITY

**When encountering a bug, ALWAYS extend the debug infrastructure BEFORE attempting to fix it.**

This is the most important rule in this codebase. The pattern that wastes time:
```
1. See bug → 2. Grep through source → 3. Read code → 4. Guess location → 5. Fix → 6. Repeat for next bug
```

The pattern that scales:
```
1. See bug → 2. Ask "why didn't debug output reveal this?" → 3. Add debug logging that WOULD have revealed it → 4. Re-run with debug → 5. Bug location is now obvious → 6. Fix
```

**Why this matters:**
- Fixing one bug helps one bug. Better debugging helps ALL future bugs.
- As features get more complex, debugging becomes the bottleneck.
- If `COT_DEBUG=all` doesn't immediately pinpoint the problem, the debug framework is insufficient.

**What good debug output looks like:**
- Shows **types** on every SSA value: `v14: u8 = load ptr=v11`
- Shows **codegen decisions**: `v14: load u8 → LDRB w1, [x0]` (not just "load")
- Shows **mismatches**: `WARNING: emitting 64-bit LDR for 8-bit type`
- Makes the bug **obvious from output alone** without reading source code

**Before fixing any bug, ask:**
1. Why didn't `COT_DEBUG=all` show me exactly where this failed?
2. What logging would have made this obvious?
3. Add that logging FIRST, verify it reveals the bug, THEN fix.

---

## USE BUILT-IN TOOLS FOR TEST FILES

**ALWAYS use Edit/Write tools for creating and updating test files** - never use bash `cat` or heredocs to write test code. This ensures:
1. The test code is visible in Claude Code CLI output
2. The code is properly formatted and not truncated
3. Changes can be reviewed before committing

**For debugging tests:**
- Create temporary test files with `Write` tool at `/tmp/test_*.cot`
- Update `test/e2e/all_tests.cot` with `Edit` tool
- Run tests with `Bash` to execute the compiled binary

---

## REFRESH YOUR KNOWLEDGE REGULARLY

**Before implementing ANY feature, re-read [SYNTAX.md](SYNTAX.md)** to ensure you understand the exact Cot syntax. This prevents implementing wrong syntax or missing edge cases.

**Use `COT_DEBUG=all`** to trace values through the pipeline when debugging.

---

## INVESTIGATE GO'S IMPLEMENTATION FOR NON-TRIVIAL BUGS

**When debugging is not straightforward, ALWAYS check `~/learning/go` first.**

On 2026-01-14 we had a critical bug where the register allocator was spilling values incorrectly. After investigating Go's implementation, we found the key pattern:

**Go's pattern (from `regalloc.go`):**
```go
// AFTER using an arg, decrement its use count
// If use count reaches 0, FREE the register immediately
for (v.args) |arg| {
    vs.uses -= 1;
    if (vs.uses == 0) {
        freeReg(vs.firstReg());
    }
}
```

**The fix:** Added use count tracking to our ValState and decremented/freed after each value processes its args.

**RULE:** When a bug is not a simple/obvious fix:
1. **Search `~/learning/go`** for how Go handles the same scenario
2. **Read the Go implementation** - they've solved these problems before
3. **Adapt their pattern** to our Zig codebase
4. Checking Go's approach prevents reinventing the wheel with subtle bugs

---

## CRITICAL LESSON: FOLLOW GO'S PARAMETERIZED PATTERNS

On 2026-01-14 we had a bug where `encodeLDPPost` emitted STP (store) instead of LDP (load) because we wrote separate functions and forgot to set bit 22. This caused crashes.

**Go's pattern (from `asm7.go`):**
```go
// ONE function handles both LDP and STP
// The load/store bit is an EXPLICIT parameter - impossible to forget
o1 = c.opldpstp(p, o, v, rf, rt1, rt2, 1)  // 1 = load
o1 = c.opldpstp(p, o, v, rt, rf1, rf2, 0)  // 0 = store
```

**Our fix:** All related ARM64 instructions now share ONE parameterized function in `src/arm64/asm.zig`:
- `encodeLdpStp(..., is_load: bool)` - LDP/STP share one function
- `encodeAddSubReg(..., is_sub: bool)` - ADD/SUB share one function
- `encodeLdrStr(..., is_load: bool)` - LDR/STR share one function

**RULE:** When adding new instruction encodings, NEVER create separate functions for related instructions. Use ONE function with explicit parameters for the critical bits.

---

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

## RUNTIME LIBRARY

**String concatenation uses the runtime library, which is auto-linked by the compiler.**

The Cot compiler generates calls to `___cot_str_concat` for string `+` operations. The compiler automatically finds and links `runtime/cot_runtime.o` when it exists.

**To compile and run programs (auto-linking):**
```bash
# Just compile and run - runtime is auto-linked!
./zig-out/bin/cot program.cot -o program
./program
```

**The e2e tests use string concatenation:**
```bash
./zig-out/bin/cot test/e2e/all_tests.cot -o /tmp/all_tests
/tmp/all_tests  # Expected exit: 0
```

**If you see "undefined symbol: ___cot_str_concat"**, the runtime wasn't found. Build it:
```bash
zig build-obj -OReleaseFast runtime/cot_runtime.zig -femit-bin=runtime/cot_runtime.o
```

See [STATUS.md](STATUS.md) for more details on the runtime library.

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

**Self-hosting:** Implement remaining language features so the compiler can compile itself.

See STATUS.md for the detailed checklist. Current sprint: **Strings & Characters**

**Implementation order:**
1. Sprint 1: Strings & Characters (u8, char literals, string type, string literals)
2. Sprint 2: Arrays (fixed arrays, literals, indexing)
3. Sprint 3: Pointers (*T, &x, ptr.*)
4. Sprint 4: Bitwise & Logical operators
5. Sprint 5: Enums
6. Sprint 6: Advanced (optionals, slices, for-in)

**ALWAYS check `~/learning/go` before implementing a feature.** The Go compiler has solved these problems already.

The goal is not speed. The goal is **never having to rewrite again**.

# Bootstrap 0.2 - Development Guidelines

## ⚠️ CRITICAL: READ THIS ENTIRE SECTION BEFORE DOING ANYTHING ⚠️

### THE GOAL (DO NOT LOSE SIGHT OF THIS)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│   GOAL: cot0-stage1 must pass ALL 166 tests                             │
│                                                                         │
│   Command to test:                                                      │
│   /tmp/cot0-stage1 test/e2e/all_tests.cot -o /tmp/tests && /tmp/tests   │
│                                                                         │
│   cot0 is a REPLICA of the Zig compiler. Same features. Same tests.    │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### PRIORITY ORDER (NEVER DEVIATE)

1. **FIX BUGS IN ZIG COMPILER** - The Zig compiler (`src/*.zig`) must work perfectly
2. **COPY ZIG PATTERNS TO COT0** - cot0 (`cot0/*.cot`) replicates the Zig compiler
3. **PASS ALL 166 TESTS** - Both compilers must pass `test/e2e/all_tests.cot`

### ⚠️ MANDATORY BUG FIXING WORKFLOW ⚠️

**EVERY bug fix MUST follow these steps. NO EXCEPTIONS. NO WORKAROUNDS.**

```
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 1: Investigate Go source code FIRST                               │
│                                                                         │
│  grep -r "relevant_term" ~/learning/go/src/cmd/compile/internal/        │
│                                                                         │
│  Go's compiler is the REFERENCE IMPLEMENTATION. Find how Go handles     │
│  the equivalent scenario. Read and understand their pattern.            │
│                                                                         │
│  Key Go directories:                                                    │
│  - ~/learning/go/src/cmd/compile/internal/ssa/       (SSA passes)       │
│  - ~/learning/go/src/cmd/compile/internal/ssagen/    (SSA generation)   │
│  - ~/learning/go/src/cmd/compile/internal/types2/    (type checking)    │
│  - ~/learning/go/src/cmd/compile/internal/walk/      (AST walking)      │
│  - ~/learning/go/src/cmd/compile/internal/abi/       (calling conv)     │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 2: Run COT_DEBUG=all to trace the bug                             │
│                                                                         │
│  COT_DEBUG=all ./zig-out/bin/cot /tmp/bugtest.cot -o /tmp/bugtest       │
│                                                                         │
│  If debug output doesn't reveal the bug, ADD MORE DEBUG FIRST.          │
│  Do NOT guess at fixes.                                                 │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 3: Implement the fix by copying Go's pattern                      │
│                                                                         │
│  - Log the bug in BUGS.md with full details                             │
│  - Adapt Go's pattern to Zig                                            │
│  - NEVER workaround bugs - FIX THEM                                     │
│  - NEVER skip features - IMPLEMENT THEM                                 │
└─────────────────────────────────────────────────────────────────────────┘
```

### WHAT "NO WORKAROUNDS" MEANS

- ❌ DO NOT revert code to avoid a bug
- ❌ DO NOT disable features because they're broken
- ❌ DO NOT use simpler alternatives to avoid fixing the real issue
- ✅ DO log the bug in BUGS.md
- ✅ DO investigate Go's implementation
- ✅ DO fix the actual bug

---

## ZIG 0.15 API CHANGES (MEMORIZE THIS)

```zig
// Zig 0.15 requires allocator on EVERY ArrayList method
var list = std.ArrayListUnmanaged(u32){};
try list.append(allocator, item);      // allocator required!
list.deinit(allocator);                // allocator required!

// HashMap too
var map = std.StringHashMapUnmanaged(u32){};
try map.put(allocator, key, value);    // allocator required!
map.deinit(allocator);                 // allocator required!
```

---

## PROJECT ARCHITECTURE

### The Two Compilers

```
┌─────────────────────────────────────────────────────────────────┐
│                    ZIG BOOTSTRAP COMPILER                        │
│  Source: src/*.zig                                               │
│  Binary: ./zig-out/bin/cot                                       │
│  Purpose: Compiles ANY Cot source code                          │
│  Status: COMPLETE - 166 e2e tests pass                          │
└─────────────────────────────────────────────────────────────────┘
                              │
              compiles        │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         COT0 COMPILER                            │
│  Source: cot0/*.cot (written in Cot)                            │
│  Binary: /tmp/cot0-stage1                                       │
│  Status: IMMATURE - compiles simple programs only               │
│                                                                 │
│  cot0 needs significant maturation before self-hosting.         │
└─────────────────────────────────────────────────────────────────┘
```

### Current State (2026-01-21)

| Component | Status |
|-----------|--------|
| Zig compiler | **COMPLETE** - 166 tests pass |
| cot0-stage1 simple programs | Works |
| cot0-stage1 test suite | **35 tests pass** (basic + switch) |
| cot0 maturity | **IMPROVING** - recursion, switch working |

**Recent Progress:**
- Switch statements implemented (nested select codegen)
- Recursion fixed (BUG-049: parameter spilling)
- ORN encoding fixed (BUG-050)

**Next Blocker:** External function calls (println) - need relocations

---

## THE PATH FORWARD - MATURATION BEFORE SELF-HOSTING

**Self-hosting is NOT the next step.** cot0 must mature first.

### Phase 1: Make cot0 Robust (CURRENT)

1. **Add extensive debugging to cot0**
   - COT_DEBUG=all should trace every phase
   - Parser should log what it's parsing
   - Each phase should have visibility

2. **Copy logic from Zig compiler (src/*.zig) into cot0**
   - The Zig compiler works. cot0 should match its patterns.
   - When cot0 has a bug, find how Zig handles it and copy that.

3. **Fix bugs systematically**
   - Don't guess at fixes
   - Use debug output to find root cause
   - Copy the working pattern from Zig

### Phase 2: Test Suite Passes with cot0-stage1

1. **Get cot0-stage1 to compile the 166-test suite**
   - Currently hangs - parser needs debugging/fixing
   - Run each test individually to find which ones fail

2. **All 166 tests must pass when compiled BY cot0-stage1**
   - Not just compiled by Zig compiler
   - cot0-stage1 must produce working binaries

### Phase 3: Build Confidence

1. **Compile increasingly complex programs with cot0-stage1**
2. **Compare output with Zig compiler output**
3. **Fix any discrepancies**

### Phase 4: Self-Hosting (FUTURE)

Only after phases 1-3:
- cot0-stage1 compiles cot0/*.cot → cot0-stage2
- Verify stage1 and stage2 produce identical output

---

## WORKING ON COT0

### When cot0-stage1 has a bug:

1. **Add debug output to cot0** that would reveal the bug
2. **Rebuild cot0-stage1** with the Zig compiler
3. **Run with debug** to see what's happening
4. **Find the equivalent code in src/*.zig** - the Zig compiler works
5. **Copy the Zig pattern** into cot0

### Commands

```bash
# Build Zig compiler
zig build

# Test Zig compiler (should pass)
./zig-out/bin/cot test/e2e/all_tests.cot -o /tmp/all_tests && /tmp/all_tests

# Build cot0-stage1
./zig-out/bin/cot cot0/main.cot -o /tmp/cot0-stage1

# Test cot0-stage1 with simple program
echo 'fn main() i64 { return 42 }' > /tmp/test.cot
/tmp/cot0-stage1 /tmp/test.cot -o /tmp/test.o
zig cc /tmp/test.o -o /tmp/test && /tmp/test; echo "Exit: $?"

# Test cot0-stage1 with test suite (currently hangs)
/tmp/cot0-stage1 cot0/test/all_tests.cot -o /tmp/cot0_tests
```

---

## FILE STRUCTURE

```
bootstrap-0.2/
├── src/                    # Zig bootstrap compiler (WORKING - reference this)
├── cot0/                   # Cot compiler in Cot (MATURING)
│   ├── main.cot
│   ├── debug.cot          # Debug logging
│   ├── frontend/          # Parser, types, lowering
│   ├── ssa/               # SSA modules
│   ├── codegen/           # Code generation
│   └── test/              # Test suite for cot0-stage1
├── test/e2e/              # Test suite (166 tests)
└── runtime/               # Runtime library
```

---

## KEY POINTS

1. **cot0 is immature.** It needs work before self-hosting.
2. **The Zig compiler is the reference.** When cot0 has bugs, look at src/*.zig.
3. **Add debugging first.** Don't guess at fixes.
4. **Test suite must pass with cot0-stage1** before attempting self-hosting.
5. **Self-hosting is the end goal, not the next step.**

---

## ZIG 0.15 API

```zig
// ArrayList - allocator on EVERY method
var list = std.ArrayListUnmanaged(u32){};
try list.append(allocator, item);
list.deinit(allocator);
```

---

## RUNTIME LIBRARY

```bash
# If "undefined symbol: ___cot_str_concat":
zig build-obj -OReleaseFast runtime/cot_runtime.zig -femit-bin=runtime/cot_runtime.o
```

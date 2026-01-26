# Claude Development Guidelines

## DEAD CODE INTEGRATION PATTERN - FOLLOW THIS EXACTLY

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   CRITICAL: Functions must be USED, not just imported.                        ║
║   An import without usage is STILL DEAD CODE.                                 ║
║                                                                               ║
║   WHEN INTEGRATING DEAD CODE FILES, FOLLOW THIS PATTERN:                      ║
║                                                                               ║
║   1. ADD THE IMPORT to main.cot                                               ║
║      import "lib/whatever.cot"                                                ║
║                                                                               ║
║   2. TRY TO COMPILE                                                           ║
║      ./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1               ║
║                                                                               ║
║   3. IF IT FAILS - DO NOT COMMENT OUT AND MOVE ON                             ║
║      Instead:                                                                 ║
║      a) Investigate the ROOT CAUSE of the failure                             ║
║      b) Check how Go handles it: ~/learning/go/src/cmd/compile/               ║
║      c) Fix the Zig compiler (src/*.zig) to match Go's approach               ║
║      d) Rebuild: zig build                                                    ║
║      e) Test the fix compiles cot1                                            ║
║      f) Run tests: ./zig-out/bin/cot test/bootstrap/all_tests.cot -o /tmp/t && /tmp/t║
║                                                                               ║
║   4. WIRE UP THE FUNCTIONS - Find where each function should be called        ║
║      - Check the equivalent in Zig compiler (src/*.zig)                       ║
║      - Replace raw calls with the safe/wrapper versions                       ║
║      - Example: Replace open() with safe_open_read(), etc.                    ║
║                                                                               ║
║   5. VERIFY COT1-STAGE1 WORKS                                                 ║
║      /tmp/cot1-stage1 test/stages/cot1/all_tests.cot -o /tmp/t.o              ║
║      zig cc /tmp/t.o runtime/cot_runtime.o -o /tmp/t -lSystem && /tmp/t       ║
║                                                                               ║
║   6. UPDATE TRACKING - mark functions as USED in INTEGRATE_DEAD_CODE.md       ║
║                                                                               ║
║   EXAMPLE: safe_io.cot integration                                            ║
║   - Import caused panic: "index out of bounds: index 4294967295"              ║
║   - Root cause: cross-file globals not visible (each file had own IR Builder) ║
║   - Go pattern: all files share single ir.Package (typecheck.Target)          ║
║   - Fix: modified driver.zig to use shared IR Builder across all files        ║
║   - Wired up: read_file() now calls safe_open_read, safe_read_all, safe_close ║
║   - Wired up: write_file() now calls safe_open_write, safe_write_all, safe_close║
║   - Result: safe_io.cot functions now USED, all 166 tests pass                ║
║                                                                               ║
║   NEVER comment out imports and move on. Fix the compiler.                    ║
║   NEVER just import - ensure functions are actually CALLED.                   ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## CURRENT STATUS: 95% OF COT1 IS LIVE CODE

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   STATUS AS OF 2026-01-26 (after dead code cleanup)                           ║
║                                                                               ║
║   Total .cot files in cot1:     48                                            ║
║   Reachable from main.cot:      48 (100%)                                     ║
║   Dead files:                   0                                             ║
║                                                                               ║
║   Total lines in cot1:          ~32,000                                       ║
║   Live code:                    ~95%                                          ║
║                                                                               ║
║   REMAINING ISSUE: 4 files imported but functions never called                ║
║   - lib/safe_alloc.cot   (283 lines) - safe allocation wrappers               ║
║   - lib/invariants.cot   (264 lines) - compiler invariant checks              ║
║   - lib/reporter.cot     (332 lines) - structured error reporting             ║
║   - lib/source.cot       (419 lines) - source location tracking               ║
║                                                                               ║
║   These files were written but never integrated into the pipeline.            ║
║   Decision needed: wire them up or delete them.                               ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## LESSON LEARNED: IMPORT != USAGE

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   Claude previously wrote ~11,000 lines of dead code including:               ║
║   - 22 test files that were never run (deleted 2026-01-26)                    ║
║   - 7 debug/trace files that were never imported (deleted 2026-01-26)         ║
║   - 4 lib files that are imported but functions never called                  ║
║                                                                               ║
║   ROOT CAUSE: Claude would write infrastructure code, import it,              ║
║   then move on without actually CALLING the functions.                        ║
║                                                                               ║
║   VERIFICATION REQUIRED:                                                      ║
║   1. After adding import, grep for actual function CALLS                      ║
║   2. An import without function calls is STILL DEAD CODE                      ║
║   3. Before working on any file, verify its functions are called              ║
║                                                                               ║
║   Example check:                                                              ║
║   $ grep -rn "safe_malloc_u8(" stages/cot1 --include="*.cot"                  ║
║   (If only shows definition in safe_alloc.cot, it's dead code)                ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## THE ONE RULE - COPY FROM GO/ZIG, NEVER INVENT

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   BEFORE WRITING ANY CODE, YOU MUST:                                          ║
║                                                                               ║
║   1. FIRST read how Go implements it:                                         ║
║      ~/learning/go/src/cmd/compile/internal/                                  ║
║                                                                               ║
║   2. THEN read how Zig implements it:                                         ║
║      ~/learning/zig/src/                                                      ║
║                                                                               ║
║   3. COPY the pattern - adapt syntax only, NEVER invent new approaches        ║
║                                                                               ║
║   ┌─────────────────────────────────────────────────────────────────────┐     ║
║   │   Go Compiler          Zig Compiler           Cot Compiler         │     ║
║   │   (cmd/compile)   →    (src/*.zig)    →       (cotN/*.cot)         │     ║
║   │                                                                     │     ║
║   │   Source of Truth      Reference Impl         Self-Hosting         │     ║
║   │   for Algorithms       (builds cot)           Target               │     ║
║   └─────────────────────────────────────────────────────────────────────┘     ║
║                                                                               ║
║   If you're writing code that doesn't exist in Go or Zig, STOP.               ║
║                                                                               ║
║   Reference commands:                                                         ║
║   grep -r "keyword" ~/learning/go/src/cmd/compile/                            ║
║   grep -r "keyword" ~/learning/zig/src/                                       ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## NEVER USE FIXED-SIZE ARRAYS IN COT CODE

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   NEVER EVER EVER EVER EVER USE FIXED-SIZE ARRAYS IN COT0/COT1                ║
║                                                                               ║
║   ❌ var arr: [64]*Value = undefined;      <- NEVER DO THIS                   ║
║   ❌ const MAX_ITEMS: i64 = 500000;        <- NEVER DO THIS                   ║
║   ❌ var g_array: *Thing = null;           <- NEVER DO THIS (global array)    ║
║                                                                               ║
║   ✓ Use malloc() for dynamic allocation                                       ║
║   ✓ Use realloc() to grow arrays                                              ║
║   ✓ Copy Zig's ArrayList/ArrayListUnmanaged patterns                          ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## MANDATORY: TEST-DRIVEN FEATURE DEVELOPMENT

When adding new language features (cot1, cot2, etc.):

1. Write 3-5 tests FIRST for the feature
2. Tests go in test/cot1/, test/cot2/, etc.
3. ALL existing tests must continue to pass
4. New feature tests must pass before moving on

Test naming: `test_<feature>_<case>.cot`

Run ALL tests after each change:
```bash
./zig-out/bin/cot test/bootstrap/all_tests.cot -o /tmp/t && /tmp/t
```

---

## MANDATORY: DOGFOOD NEW FEATURES

A feature is NOT complete until the compiler itself uses it.

Example: When implementing type aliases for cot1:
1. Parser parses `type Name = T`
2. Checker validates type aliases
3. Lowerer generates correct code
4. Test suite has 3+ tests passing
5. **MUST ALSO:** Update cot1/*.cot to USE type aliases

---

## STAGE1 TESTING - ALWAYS USE ALL_TESTS

When testing stage1 hasn't regressed, ALWAYS run all_tests:

```bash
./zig-out/bin/cot test/bootstrap/all_tests.cot -o /tmp/t && /tmp/t
```

Verify ALL tests pass. Never use trivial "return 42" tests.

---

## Current Priority: Fix Stage 2 Crash

cot1-stage2 compiles successfully but crashes at startup (SIGBUS). Suspected causes:
1. Stack overflow during SSA building (8MB stack limit at scale)
2. Performance: O(n) function lookup causing slowdown (1.6 seconds in lowering)
3. Incorrect struct field offset calculations in codegen

**Investigation approach:** Add timing instrumentation, replace linear scans with StrMap lookups.

---

## Long-term Goal

Make every function in cot1 match the Zig compiler (`src/*.zig`):
- Same name (adapted to Cot naming: `Scanner_init` not `scanner_init`)
- Same logic (identical algorithm, different syntax)
- Same behavior (identical outputs for identical inputs)

---

## Workflow

```
1. READ ZIG FIRST
   Find the function in src/*.zig
   Understand its logic completely

2. IF UNCLEAR, READ GO
   Find equivalent in ~/learning/go/src/cmd/compile/
   Go is the source of truth

3. TRANSLATE
   Copy the logic exactly
   Only change syntax (Zig → Cot)

4. TEST
   zig build
   ./zig-out/bin/cot test/bootstrap/all_tests.cot -o /tmp/t && /tmp/t
```

---

## Bug Handling

```
❌ DON'T                              ✓ DO
─────────────────────────────────────────────────────────────────────
Debug creatively                     Ask: "How does Zig handle this?"
Invent a fix                         Find the Zig/Go code
Add a null check                     Copy that code to cot1
Try a different approach             If missing infrastructure, note
                                     it and move on
Add debug prints endlessly           Make a code change and test
Create test files to "investigate"   Use existing test suite
Read code for 30+ minutes            Make a fix attempt within 5 min
```

**Bugs = missing Go/Zig patterns, not puzzles to solve creatively.**

---

## Memory Management

| Current State | Future State |
|---------------|--------------|
| Global arrays with malloc/realloc | Automatic Reference Counting (ARC) |
| Temporary bootstrap scaffolding | Will replace globals later |

**Do NOT add Zig-style allocators. ARC comes after self-hosting.**

---

## Commands

```bash
# Build and test Zig compiler
zig build
./zig-out/bin/cot test/bootstrap/all_tests.cot -o /tmp/t && /tmp/t

# Build cot1-stage1
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1

# Test stage1 with bootstrap tests
/tmp/cot1-stage1 test/bootstrap/all_tests.cot -o /tmp/bt.o
zig cc /tmp/bt.o runtime/cot_runtime.o -o /tmp/bt -lSystem && /tmp/bt

# Test stage1 with cot1 feature tests
/tmp/cot1-stage1 test/stages/cot1/cot1_features.cot -o /tmp/ft.o
zig cc /tmp/ft.o runtime/cot_runtime.o -o /tmp/ft -lSystem && /tmp/ft

# Build cot1-stage2 (currently crashes at startup)
/tmp/cot1-stage1 stages/cot1/main.cot -o /tmp/cot1-stage2.o
zig cc /tmp/cot1-stage2.o runtime/cot_runtime.o -o /tmp/cot1-stage2 -lSystem
```

---

## Key Documents

| Document | Purpose |
|----------|---------|
| [SELF_HOSTING.md](SELF_HOSTING.md) | Path to self-hosting with milestones |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Compiler design and key decisions |
| [REFERENCE.md](REFERENCE.md) | Technical reference (data structures, algorithms) |
| [COT1_GAPS.md](COT1_GAPS.md) | Functional coverage analysis (95% complete) |

---

## The Anti-Pattern to Avoid

```
1. Start working on a feature/fix systematically
2. A bug appears during testing
3. Get fixated on the bug
4. Invent creative solutions not from Zig/Go
5. Go in circles, make no progress
6. Hours pass with no results

THIS IS WRONG. The task is TRANSLATION, not ENGINEERING.
```

---

## When Stuck

1. Read the Zig code in `src/*.zig`
2. Read the Go code if Zig is unclear
3. Copy the pattern exactly
4. Ask rather than guess

> **Continue working without pausing for summaries. The user will stop you when done.**

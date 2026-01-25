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
║      f) Run tests: ./zig-out/bin/cot test/e2e/all_tests.cot -o /tmp/t && /tmp/t║
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

## THOUSANDS OF DOLLARS WASTED ON DEAD CODE

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   WEEKS OF WORK. THOUSANDS OF DOLLARS IN CLAUDE TOKENS. ALL WASTED.           ║
║                                                                               ║
║   Claude spent WEEKS writing, debugging, and "improving" code that is         ║
║   NEVER EXECUTED. Files like checker.cot, validate.cot, invariants.cot,       ║
║   regalloc.cot, liveness.cot - none of them are imported by main.cot.         ║
║                                                                               ║
║   The user paid for:                                                          ║
║   - Writing 11,008 lines of dead code                                         ║
║   - Debugging code that never runs                                            ║
║   - "Fixing" bugs in unused functions                                         ║
║   - Creating test files for dead modules                                      ║
║   - 7+ hours on BUG-063 alone, based on assumptions about checker.cot        ║
║                                                                               ║
║   EXPOSED BY ONE COMMAND:                                                     ║
║   $ grep "Checker" main.cot                                                   ║
║   (no results - checker.cot is never used)                                    ║
║                                                                               ║
║   THIS IS INEXCUSABLE. Before working on ANY file, Claude MUST verify         ║
║   it is actually imported and used. 10 seconds of verification would          ║
║   have saved weeks of wasted work.                                            ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## WARNING: 62% OF COT1 IS DEAD CODE

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   BEFORE WORKING ON ANY COT1 FILE, VERIFY IT IS ACTUALLY USED                 ║
║                                                                               ║
║   Total .cot files in cot1:     69                                            ║
║   Reachable from main.cot:      26                                            ║
║   DEAD FILES:                   43 (62%)                                      ║
║                                                                               ║
║   Total lines in cot1:          35,198                                        ║
║   DEAD LINES:                   11,008 (31%)                                  ║
║                                                                               ║
║   BIGGEST DEAD FILES:                                                         ║
║   - checker.cot      883 lines  <- Claude spent 7+ hours on this             ║
║   - validate.cot     745 lines                                                ║
║   - safe_io.cot      725 lines                                                ║
║   - invariants.cot   687 lines                                                ║
║   - regalloc.cot     623 lines                                                ║
║   - liveness.cot     612 lines                                                ║
║   - error.cot        637 lines                                                ║
║   - debug.cot        590 lines                                                ║
║                                                                               ║
║   HOW TO CHECK IF A FILE IS USED:                                             ║
║   1. grep 'import.*filename' main.cot                                         ║
║   2. If not found, trace imports from main.cot transitively                   ║
║   3. If file is not reachable, IT IS DEAD CODE                                ║
║                                                                               ║
║   REACHABLE FILES (the only ones that matter):                                ║
║   main.cot, lib/stdlib.cot, lib/list.cot, lib/strmap.cot,                    ║
║   frontend/token.cot, frontend/scanner.cot, frontend/types.cot,              ║
║   frontend/ast.cot, frontend/parser.cot, frontend/ir.cot,                    ║
║   frontend/lower.cot, codegen/genssa.cot, codegen/arm64.cot,                 ║
║   arm64/asm.cot, arm64/regs.cot, ssa/builder.cot,                            ║
║   ssa/passes/expand_calls.cot, ssa/func.cot, ssa/block.cot,                  ║
║   ssa/value.cot, ssa/op.cot, ssa/dom.cot, ssa/abi.cot,                       ║
║   ssa/stackalloc.cot, obj/macho.cot, obj/dwarf.cot                           ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## BUG-063: 7+ HOURS WASTED ON DEAD CODE

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   2026-01-25: COMPLETE FAILURE                                                ║
║                                                                               ║
║   6+ Claude instances spent 7+ HOURS "fixing" BUG-063 based on the           ║
║   assumption that "the checker computes correct offsets in TypeRegistry."    ║
║                                                                               ║
║   THE CHECKER IS NEVER CALLED. IT IS 883 LINES OF DEAD CODE.                 ║
║                                                                               ║
║   - checker.cot: 883 lines, 13 functions                                     ║
║   - Only imported by: checker_test.cot (a test file)                         ║
║   - main.cot: zero references to "Checker"                                   ║
║   - grep "Checker" main.cot returns: NOTHING                                 ║
║                                                                               ║
║   WHAT CLAUDE DID:                                                           ║
║   - Created 4 "rewrite" documents based on checker assumptions               ║
║   - Deleted 175 lines from lower.cot                                         ║
║   - Rewrote 17 call sites (~200 lines changed)                               ║
║   - Added back 70 lines after breaking everything                            ║
║   - Result: ZERO EFFECT ON BUG                                               ║
║                                                                               ║
║   WHAT CLAUDE SHOULD HAVE DONE:                                              ║
║   - Run: grep "Checker" main.cot                                             ║
║   - See: no results                                                          ║
║   - Conclude: checker is dead code, assumption is wrong                      ║
║   - Time required: 10 seconds                                                ║
║                                                                               ║
║   THE BUG IS IN genssa.cot (codegen), NOT lower.cot OR checker.cot           ║
║                                                                               ║
║   See BUG063_MASTER_FIX.md for the complete failure analysis.                ║
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
./zig-out/bin/cot test/e2e/all_tests.cot -o /tmp/t && /tmp/t
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

When testing stage1 hasn't regressed, ALWAYS run e2e/all_tests:

```bash
/tmp/cot0-stage1 test/e2e/all_tests.cot -o /tmp/all_tests && /tmp/all_tests
```

Verify ALL tests pass. Never use trivial "return 42" tests.

---

## Current Priority: Field Offset Rewrite

**READ THIS FIRST:** [REWRITE_FIELD_OFFSETS.md](REWRITE_FIELD_OFFSETS.md)

The cot1 struct field offset handling is architecturally broken. It computes offsets in THREE different places using THREE different methods. The rewrite document explains:

1. Why debugging cannot fix this (architecture is wrong)
2. How Zig does it correctly (single source of truth)
3. Exactly what to delete and what to add
4. All 17 call sites that need fixing

**Do NOT attempt to debug the old code. Follow the rewrite plan.**

---

## Long-term Goal

Make every function in [cot0/COMPARISON.md](cot0/COMPARISON.md) show "Same":
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
   ./zig-out/bin/cot test/e2e/all_tests.cot -o /tmp/t && /tmp/t
```

---

## Bug Handling

```
❌ DON'T                              ✓ DO
─────────────────────────────────────────────────────────────────────
Debug creatively                     Ask: "How does Zig handle this?"
Invent a fix                         Find the Zig/Go code
Add a null check                     Copy that code to cot0
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
# Build and test
zig build
./zig-out/bin/cot test/e2e/all_tests.cot -o /tmp/all_tests && /tmp/all_tests

# Build cot0-stage1
./zig-out/bin/cot cot0/main.cot -o /tmp/cot0-stage1

# Test with stage1
echo 'fn main() i64 { return 42 }' > /tmp/test.cot
/tmp/cot0-stage1 /tmp/test.cot -o /tmp/test.o
zig cc /tmp/test.o -o /tmp/test && /tmp/test; echo "Exit: $?"

# Build cot1-stage1
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1

# Build cot1-stage2 (currently blocked by field offset bug)
/tmp/cot1-stage1 stages/cot1/main.cot -o /tmp/cot1-stage2.o
zig cc /tmp/cot1-stage2.o runtime/cot_runtime.o -o /tmp/cot1-stage2 -lSystem
```

---

## Key Documents

| Document | Purpose |
|----------|---------|
| [REWRITE_FIELD_OFFSETS.md](REWRITE_FIELD_OFFSETS.md) | **CURRENT PRIORITY** - Complete rewrite plan for field offsets |
| [cot0/COMPARISON.md](cot0/COMPARISON.md) | Master checklist - work through top to bottom |
| [SELF_HOSTING.md](SELF_HOSTING.md) | Path to self-hosting with milestones |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Compiler design and key decisions |
| [REFERENCE.md](REFERENCE.md) | Technical reference (data structures, algorithms) |

---

## The Anti-Pattern to Avoid

```
1. Start working on COMPARISON.md systematically
2. A bug appears during testing
3. Get fixated on the bug
4. Invent creative solutions not from Zig/Go
5. Go in circles, ignore COMPARISON.md progress
6. Hours pass with no parity progress

THIS IS WRONG. The task is TRANSLATION, not ENGINEERING.
```

---

## When Stuck

1. Check if the function is "Same" in COMPARISON.md
2. Read the Zig code in `src/*.zig`
3. Read the Go code if Zig is unclear
4. Ask rather than guess

> **Continue working without pausing for summaries. The user will stop you when done.**

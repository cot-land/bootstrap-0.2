# Claude Development Guidelines

## ⛔⛔⛔ THE ONE RULE - COPY FROM GO/ZIG, NEVER INVENT ⛔⛔⛔

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

## ⛔ MANDATORY: TEST-DRIVEN FEATURE DEVELOPMENT ⛔

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   WHEN ADDING NEW LANGUAGE FEATURES (cot1, cot2, etc.):                       ║
║                                                                               ║
║   1. Write 3-5 tests FIRST for the feature                                    ║
║   2. Tests go in test/cot1/, test/cot2/, etc.                                 ║
║   3. ALL existing tests must continue to pass                                 ║
║   4. New feature tests must pass before moving on                             ║
║                                                                               ║
║   Test naming: test_<feature>_<case>.cot                                      ║
║   Example: test_error_union_basic.cot                                         ║
║            test_error_union_catch.cot                                         ║
║            test_error_union_try.cot                                           ║
║                                                                               ║
║   Run ALL tests after each change:                                            ║
║   ./zig-out/bin/cot test/e2e/all_tests.cot -o /tmp/t && /tmp/t                ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## ⛔ STAGE1 TESTING - ALWAYS USE ALL_TESTS ⛔

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   When testing stage1 hasn't regressed, ALWAYS run e2e/all_tests:             ║
║                                                                               ║
║   /tmp/cot0-stage1 test/e2e/all_tests.cot -o /tmp/all_tests && /tmp/all_tests ║
║                                                                               ║
║   Verify ALL 166 TESTS PASS. Never use trivial "return 42" tests.             ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## ⛔⛔⛔ NEVER USE FIXED-SIZE ARRAYS IN COT0 ⛔⛔⛔

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   NEVER EVER EVER EVER EVER USE FIXED-SIZE ARRAYS IN COT0                     ║
║                                                                               ║
║   ❌ var arr: [64]*Value = undefined;      <- NEVER DO THIS                   ║
║   ❌ const MAX_ITEMS: i64 = 500000;        <- NEVER DO THIS                   ║
║   ❌ var g_array: *Thing = null;           <- NEVER DO THIS (global array)    ║
║                                                                               ║
║   ✓ Use malloc() for dynamic allocation                                       ║
║   ✓ Use realloc() to grow arrays                                              ║
║   ✓ Copy Zig's ArrayList/ArrayListUnmanaged patterns                          ║
║                                                                               ║
║   The user has requested this HUNDREDS OF TIMES. STOP ADDING FIXED ARRAYS.    ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## SHAME LOG - READ THIS FIRST

**2026-01-25** - Claude marked cot1 features (type aliases, optional types) as "COMPLETED" when they were NOT complete. Claude only added PARSING to cot1/frontend/parser.cot, but did NOT implement semantic handling in checker.cot or lower.cot. Then Claude tested using the WRONG COMPILER - the Zig bootstrap (`./zig-out/bin/cot`) which already supports these features, instead of the cot1 self-hosting compiler (`/tmp/cot1-stage1`). When tests passed with the Zig bootstrap, Claude declared victory.

**THE ACTUAL RESULT:** When compiled with the cot1 compiler (which is what matters), 6/9 tests FAILED because cot1 can parse the syntax but generates garbage code.

**WHAT CLAUDE DID WRONG:**
1. Only implemented parsing, forgot checker/lowerer need updates too
2. Tested with wrong compiler (Zig bootstrap instead of cot1)
3. Marked features "completed" without verifying they work in the self-hosting compiler
4. Wasted user's time with false progress reports

**THE RULE:** A feature is ONLY complete when:
- Parser parses it ✓
- Checker validates it ✓
- Lowerer generates correct code ✓
- Tests pass when compiled BY THE SELF-HOSTING COMPILER ✓

---

**2026-01-24** - User asked Claude to bring SSA passes (expand_calls.cot, decompose.cot, schedule.cot, lower.cot) up to parity with Zig. Claude initially wrote ~400 lines of garbage code that pattern-matched conditions but said "For bootstrap, codegen handles this" without doing anything.

**CORRECTED:** Rewrote all four passes with actual transformations:
- decompose.cot: string_ptr/string_len(string_make) → copy, with proper use count updates
- expand_calls.cot: Store of >16B type → Move, plus dec.rules optimizations
- schedule.cot: Actual value reordering using swapValues() with reference updates
- lower.cot: Mul by 2^n → Shl, identity optimizations (add 0, mul 1, etc.)

---

**2026-01-23 ~10:30 AM** - Claude invented `PTYPE_PENDING_ARRAY_BASE = 200000000` garbage hack instead of implementing proper type resolution like Zig. User asked for parser type resolution fix. Instead of:
- Reading how Zig stores type expressions as AST nodes
- Reading how Zig's checker resolves types after all declarations are registered
- Implementing the same pattern in cot0

Claude invented a magic number encoding scheme that doesn't exist anywhere in Zig. This is EXACTLY what CLAUDE.md says NOT to do. The user has asked for proper dynamic memory and AST node storage like Zig multiple times. Claude keeps avoiding "larger changes" and adding hacks instead.

**WHAT CLAUDE SHOULD HAVE DONE:** Read src/frontend/parser.zig and src/frontend/checker.zig, understand how Zig stores TypeExpr AST nodes and resolves them in resolveTypeExpr(), then implement the same pattern in cot0.

---

> **Continue working without pausing for summaries. The user will stop you when done.**

## Current Priority: cot1 Language Evolution

**Make all 166 e2e tests pass when compiled with cot0-stage1.**

See [cot0/STAGE1_TEST_PLAN.md](cot0/STAGE1_TEST_PLAN.md) for the detailed execution plan.

**Known Issues (in priority order):**
1. **Function Pointers** - Link error, generates `_f` symbol instead of indirect call
2. **Global Variables** - Returns 0 instead of correct value
3. **String Literals** - `s.len` returns 0 instead of string length
4. **For Loops** - Parser doesn't recognize `for i in 0..7` syntax

## Long-term Goal

Make every function in [cot0/COMPARISON.md](cot0/COMPARISON.md) show "Same":
- Same name (adapted to Cot naming: `Scanner_init` not `scanner_init`)
- Same logic (identical algorithm, different syntax)
- Same behavior (identical outputs for identical inputs)

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

## Bug Handling

```
❌ DON'T                              ✓ DO
─────────────────────────────────────────────────────────────────────
Debug creatively                     Ask: "How does Zig handle this?"
Invent a fix                         Find the Zig/Go code
Add a null check                     Copy that code to cot0
Try a different approach             If missing infrastructure, note
                                     it and move on
```

**Bugs = missing Go/Zig patterns, not puzzles to solve creatively.**

## Memory Management

| Current State | Future State |
|---------------|--------------|
| Global arrays with malloc/realloc | Automatic Reference Counting (ARC) |
| Temporary bootstrap scaffolding | Will replace globals later |

**Do NOT add Zig-style allocators. ARC comes after self-hosting.**

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
```

## Key Documents

| Document | Purpose |
|----------|---------|
| [cot0/COMPARISON.md](cot0/COMPARISON.md) | Master checklist - work through top to bottom |
| [SELF_HOSTING.md](SELF_HOSTING.md) | Path to self-hosting with milestones |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Compiler design and key decisions |
| [REFERENCE.md](REFERENCE.md) | Technical reference (data structures, algorithms) |

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

## When Stuck

1. Check if the function is "Same" in COMPARISON.md
2. Read the Zig code in `src/*.zig`
3. Read the Go code if Zig is unclear
4. Ask rather than guess

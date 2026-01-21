# Bootstrap 0.2 - Development Guidelines

## STOP. READ THIS FIRST. EVERY SESSION.

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   BEFORE YOU WRITE ANY CODE, YOU MUST:                                        ║
║                                                                               ║
║   1. Run: /tmp/cot0-stage1 /tmp/simple.cot -o /tmp/t.o &&                    ║
║          zig cc /tmp/t.o -o /tmp/t && /tmp/t; echo $?                        ║
║      (where simple.cot is: fn main() i64 { return 42 })                      ║
║      Expected output: 42                                                      ║
║                                                                               ║
║   2. If cot0-stage1 doesn't exist or test fails, BUILD IT FIRST:             ║
║      ./zig-out/bin/cot cot0/main.cot -o /tmp/cot0-stage1                     ║
║                                                                               ║
║   3. VERIFY IT WORKS before making ANY changes                                ║
║                                                                               ║
║   IF YOU SKIP THIS, YOU WILL WASTE HOURS DEBUGGING PROBLEMS YOU CREATED.     ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## THE CODE COPYING HIERARCHY

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   Go compiler (~/learning/go/src/cmd/compile/)                              │
│         │                                                                   │
│         │  Zig compiler copies patterns from Go                             │
│         ▼                                                                   │
│   Zig compiler (src/*.zig) ─── WORKS, passes 166 tests                      │
│         │                                                                   │
│         │  cot0 copies patterns from Zig                                    │
│         ▼                                                                   │
│   cot0 (cot0/*.cot) ─── MUST MATCH ZIG, never invent                        │
│         │                                                                   │
│         │  After self-hosting works                                         │
│         ▼                                                                   │
│   cot1 through cot9 ─── Future: add new features                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

CRITICAL RULES:
- cot0 is a REPLICA of src/*.zig. It has NO new features.
- When cot0 needs functionality, FIND IT IN src/*.zig and COPY IT.
- NEVER write new code from scratch. ALWAYS copy from Zig first.
- If Zig doesn't have it, check Go. If neither has it, ASK THE USER.
```

---

## WHAT YOU MUST NEVER DO

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   ❌ NEVER write code for cot0 without first finding the equivalent          ║
║      in src/*.zig                                                             ║
║                                                                               ║
║   ❌ NEVER add features to cot0 that don't exist in src/*.zig                ║
║                                                                               ║
║   ❌ NEVER "invent" solutions - the Zig compiler already has them            ║
║                                                                               ║
║   ❌ NEVER make large changes without testing after EACH small change        ║
║                                                                               ║
║   ❌ NEVER assume something is broken without first verifying the            ║
║      ORIGINAL code works                                                      ║
║                                                                               ║
║   ❌ NEVER trust context summaries - VERIFY current state first              ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## MANDATORY WORKFLOW FOR ANY COT0 CHANGE

### Step 1: Verify Current State
```bash
# Build cot0-stage1 from CURRENT code
./zig-out/bin/cot cot0/main.cot -o /tmp/cot0-stage1

# Test it works
echo 'fn main() i64 { return 42 }' > /tmp/test.cot
/tmp/cot0-stage1 /tmp/test.cot -o /tmp/test.o
zig cc /tmp/test.o -o /tmp/test && /tmp/test
# MUST output: 42
```

### Step 2: Find the Zig Pattern
```bash
# Search Zig compiler for the feature/fix you need
grep -r "relevant_term" src/

# Key files:
# - src/frontend/lower.zig    (AST to IR)
# - src/frontend/parser.zig   (parsing)
# - src/ssa/*.zig             (SSA construction)
# - src/codegen/arm64.zig     (code generation)
```

### Step 3: Copy the Pattern to cot0
- Find the EXACT equivalent location in cot0/*.cot
- Copy the Zig pattern, adapting syntax only
- Make ONE small change

### Step 4: Test Immediately
```bash
# Rebuild and test after EVERY change
./zig-out/bin/cot cot0/main.cot -o /tmp/cot0-stage1
/tmp/cot0-stage1 /tmp/test.cot -o /tmp/test.o
zig cc /tmp/test.o -o /tmp/test && /tmp/test
# Still outputs 42? Good. Continue.
# Broken? REVERT immediately and try again.
```

---

## CURRENT STATUS (2026-01-21)

| Component | Status |
|-----------|--------|
| Zig compiler (src/*.zig) | **COMPLETE** - 166 tests pass |
| cot0-stage1 basic programs | **WORKS** - return 42 works |
| cot0-stage1 test suite | **PARTIAL** - some tests pass |

### What Works in cot0:
- Basic arithmetic, comparisons, control flow
- Function calls, recursion
- Local variables, arrays
- Switch statements

### What May Need Work:
- Global variables (check if Zig has this)
- External function calls with complex args
- Full test suite compilation

---

## WHEN YOU START A NEW SESSION

1. **READ THIS ENTIRE FILE** - not just the summary
2. **VERIFY** cot0-stage1 works with the simple test above
3. **CHECK** git status - are there uncommitted changes?
4. **ASK** the user what they want before doing anything
5. **FIND** the Zig pattern before writing any cot0 code

---

## FILE STRUCTURE

```
bootstrap-0.2/
├── src/                    # Zig compiler - THE REFERENCE (copy FROM here)
│   ├── frontend/           # Parser, checker, lowerer
│   ├── ssa/                # SSA construction
│   └── codegen/            # ARM64 code generation
├── cot0/                   # Cot compiler in Cot (copy TO here)
│   ├── main.cot            # Entry point
│   ├── frontend/           # Parser, types, lowering
│   ├── ssa/                # SSA modules
│   └── codegen/            # Code generation
├── test/e2e/               # Test suite (166 tests)
└── runtime/                # Runtime library
```

---

## THE GOAL

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   GOAL: Self-hosting                                                        │
│                                                                             │
│   1. cot0-stage1 (compiled by Zig) compiles cot0/*.cot → cot0-stage2       │
│   2. cot0-stage2 produces identical output to cot0-stage1                   │
│   3. Then: cot1 adds features, cot2 adds more, ... cot9 is advanced         │
│                                                                             │
│   But first: cot0 must be a PERFECT REPLICA of the Zig compiler.           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## COMMANDS REFERENCE

```bash
# Build Zig compiler
zig build

# Test Zig compiler (MUST pass)
./zig-out/bin/cot test/e2e/all_tests.cot -o /tmp/all_tests && /tmp/all_tests

# Build cot0-stage1
./zig-out/bin/cot cot0/main.cot -o /tmp/cot0-stage1

# Test cot0-stage1
echo 'fn main() i64 { return 42 }' > /tmp/test.cot
/tmp/cot0-stage1 /tmp/test.cot -o /tmp/test.o
zig cc /tmp/test.o -o /tmp/test && /tmp/test; echo "Exit: $?"

# Debug Zig compiler
COT_DEBUG=all ./zig-out/bin/cot /tmp/test.cot -o /tmp/test
```

---

## IF SOMETHING IS BROKEN

1. **STOP** - don't add more code
2. **CHECK** - did YOUR changes break it? (git diff)
3. **REVERT** - if your changes broke it, revert them
4. **FIND** - look at src/*.zig for how Zig handles it
5. **COPY** - replicate the Zig pattern in cot0
6. **TEST** - verify after each small change

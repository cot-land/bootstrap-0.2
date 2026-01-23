# Claude Development Guidelines

> **Continue working without pausing for summaries. The user will stop you when done.**

## The One Rule

**Copy from Go/Zig. Never invent.**

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│   Go Compiler          Zig Compiler           Cot Compiler         │
│   (cmd/compile)   →    (src/*.zig)    →       (cot0/*.cot)         │
│                                                                     │
│   Source of Truth      Reference Impl         Self-Hosting         │
│   for Algorithms       (builds cot0)          Target               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

Every function in cot0 must trace back to Go or Zig.
If you're writing code that doesn't exist in these sources, STOP.
```

## The Goal

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

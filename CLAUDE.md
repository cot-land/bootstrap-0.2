# Bootstrap 0.2 - Development Guidelines

> **WORK MODE**: Continue working on parity improvements without pausing for summaries.
> The user will stop you when enough progress has been made. Just keep working.

## THE NEW PRIORITY (2026-01-21)

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   GOAL: Make EVERY function in cot0/COMPARISON.md show "Same"                 ║
║                                                                               ║
║   - Same name                                                                 ║
║   - Same logic                                                                ║
║   - Same signature (adapted for Cot syntax)                                   ║
║                                                                               ║
║   Work systematically: TOP TO BOTTOM through COMPARISON.md                    ║
║                                                                               ║
║   Current file: Start at Section 1 (Main Entry Point)                         ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## ⛔ MANDATORY WORKFLOW - READ THIS BEFORE EVERY CHANGE ⛔

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  BEFORE TOUCHING ANY COT0 CODE, YOU MUST:                                   │
│                                                                             │
│  1. READ THE ZIG FUNCTION FIRST                                             │
│     - Find the equivalent function in src/*.zig                             │
│     - Read and understand its logic completely                              │
│                                                                             │
│  2. IF ZIG IS UNCLEAR, READ THE GO FUNCTION                                 │
│     - Find equivalent in ~/learning/go/src/cmd/compile/                     │
│     - Zig copied from Go, so Go is the source of truth                      │
│                                                                             │
│  3. TRANSLATE, DO NOT INVENT                                                │
│     - Copy the logic exactly                                                │
│     - Only change syntax (Zig → Cot)                                        │
│     - If you're writing logic that isn't in Zig/Go, STOP                    │
│                                                                             │
│  4. ONE FUNCTION AT A TIME                                                  │
│     - Complete one function                                                 │
│     - Update COMPARISON.md                                                  │
│     - Then move to next                                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

## ⛔ BUG HANDLING PROTOCOL ⛔

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  WHEN A BUG APPEARS:                                                        │
│                                                                             │
│  ❌ DO NOT debug creatively                                                 │
│  ❌ DO NOT invent a fix                                                     │
│  ❌ DO NOT write code that isn't in Zig/Go                                  │
│  ❌ DO NOT get distracted from the current COMPARISON.md task               │
│                                                                             │
│  ✓ ASK: "How does Zig handle this?"                                         │
│  ✓ ASK: "How does Go handle this?"                                          │
│  ✓ FIND the Zig/Go code that prevents this bug                              │
│  ✓ COPY that code to cot0                                                   │
│                                                                             │
│  IF THE BUG EXISTS BECAUSE COT0 IS MISSING ZIG INFRASTRUCTURE:              │
│  ✓ NOTE the dependency in COMPARISON.md                                     │
│  ✓ MOVE ON to the next function                                             │
│  ✓ DO NOT invent workarounds                                                │
│                                                                             │
│  BUGS = MISSING ZIG PATTERNS, NOT PUZZLES TO SOLVE CREATIVELY               │
└─────────────────────────────────────────────────────────────────────────────┘
```

## ⛔ WHAT CLAUDE KEEPS DOING WRONG ⛔

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  PATTERN TO AVOID:                                                          │
│                                                                             │
│  1. Claude starts working on COMPARISON.md systematically                   │
│  2. A bug appears during testing                                            │
│  3. Claude gets fixated on the bug                                          │
│  4. Claude invents creative solutions not from Zig/Go                       │
│  5. Claude goes in circles, ignores COMPARISON.md progress                  │
│  6. Hours pass with no actual parity progress                               │
│                                                                             │
│  THIS IS WRONG. The task is TRANSLATION, not ENGINEERING.                   │
│                                                                             │
│  If you find yourself writing code that doesn't exist in Zig or Go,         │
│  you are doing it wrong. STOP and re-read this section.                     │
└─────────────────────────────────────────────────────────────────────────────┘
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
│   Zig compiler (src/*.zig) ─── THE REFERENCE                                │
│         │                                                                   │
│         │  cot0 MUST MATCH Zig exactly                                      │
│         ▼                                                                   │
│   cot0 (cot0/*.cot) ─── IDENTICAL to Zig, just different syntax             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

THE RULE: Every function in cot0 must have the SAME NAME and SAME LOGIC
          as its Zig counterpart. No exceptions. No "equivalent" - only "Same".
```

---

## SYSTEMATIC APPROACH

### The Process

1. **Open cot0/COMPARISON.md**
2. **Start at Section 1** (Main Entry Point)
3. **For each row in each table:**
   - If status is "Same" → Move to next row
   - If status is "Equivalent" → Rename cot0 function to match Zig name
   - If status is "Missing in cot0" → Copy function from Zig to cot0
   - If status is "Missing in Zig" → Evaluate if cot0 function is needed
4. **After completing a section** → Update COMPARISON.md status
5. **Move to next section**
6. **Repeat until ALL rows show "Same"**

### File Order (from COMPARISON.md)

| Section | cot0 File | Zig Counterpart | Priority |
|---------|-----------|-----------------|----------|
| 1 | main.cot | main.zig + driver.zig | **CURRENT** |
| 2.1 | frontend/token.cot | frontend/token.zig | Next |
| 2.2 | frontend/scanner.cot | frontend/scanner.zig | |
| 2.3 | frontend/ast.cot | frontend/ast.zig | |
| 2.4 | frontend/parser.cot | frontend/parser.zig | |
| 2.5 | frontend/types.cot | frontend/types.zig | |
| 2.6 | frontend/checker.cot | frontend/checker.zig | |
| 2.7 | frontend/ir.cot | frontend/ir.zig | |
| 2.8 | frontend/lower.cot | frontend/lower.zig | |
| 3.1 | ssa/op.cot | ssa/op.zig | |
| 3.2 | ssa/value.cot | ssa/value.zig | |
| 3.3 | ssa/block.cot | ssa/block.zig | |
| 3.4 | ssa/func.cot | ssa/func.zig | |
| 3.5 | ssa/builder.cot | frontend/ssa_builder.zig | |
| 3.6 | ssa/liveness.cot | ssa/liveness.zig | |
| 3.7 | ssa/regalloc.cot | ssa/regalloc.zig | |
| 4.1 | arm64/asm.cot | arm64/asm.zig | |
| 4.2 | arm64/regs.cot | (cot0-only) | |
| 5.1 | codegen/arm64.cot | codegen/arm64.zig | |
| 5.2 | codegen/genssa.cot | (cot0-only) | |
| 6.1 | obj/macho.cot | obj/macho.zig | |
| 7.* | (create new files) | Zig-only files | Last |

---

## WHAT "SAME" MEANS

### Function Names
```
Zig:  pub fn Scanner.init(...)
cot0: fn scanner_init(...)        ← WRONG ("Equivalent")
cot0: fn Scanner_init(...)        ← CORRECT ("Same")
```

### Function Signatures
```
Zig:  pub fn init(allocator: Allocator) Scanner
cot0: fn init(allocator: *Allocator) Scanner    ← Adapted for Cot syntax, still "Same"
```

### Function Logic
```
The implementation must follow the same algorithm.
Copy the Zig code and translate to Cot syntax.
```

---

## COMMANDS

```bash
# Build Zig compiler
zig build

# Test Zig compiler
./zig-out/bin/cot test/e2e/all_tests.cot -o /tmp/all_tests && /tmp/all_tests

# Build cot0-stage1
./zig-out/bin/cot cot0/main.cot -o /tmp/cot0-stage1

# Test cot0-stage1
echo 'fn main() i64 { return 42 }' > /tmp/test.cot
/tmp/cot0-stage1 /tmp/test.cot -o /tmp/test.o
zig cc /tmp/test.o -o /tmp/test && /tmp/test; echo "Exit: $?"
```

---

## KEY DOCUMENTS

| Document | Purpose |
|----------|---------|
| **cot0/COMPARISON.md** | Master checklist - work through this top to bottom |
| **STATUS.md** | Track progress on making functions "Same" |
| **cot0/ROADMAP.md** | Detailed plan for each file |
| **BUGS.md** | Bug tracking |

---

## RULES

1. **Never invent** - Only copy from Zig
2. **Same names** - Rename cot0 functions to match Zig
3. **Same logic** - Copy the algorithm exactly
4. **Test after each change** - Rebuild and verify
5. **Update COMPARISON.md** - Mark as "Same" when done
6. **Work top to bottom** - Don't skip ahead

---

## CURRENT PROGRESS

See STATUS.md for detailed progress tracking.
See cot0/COMPARISON.md for the master checklist.

---

## PROJECT ARCHITECTURE - DO NOT MISUNDERSTAND

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  THIS PROJECT IS:                                                           │
│  - Copying compiler PATTERNS from Go → Zig → cot0                           │
│  - Using Cot language syntax (similar to Zig but different language)        │
│  - Planning to use ARC (Automatic Reference Counting) for memory            │
│  - Using global arrays as TEMPORARY bootstrap scaffolding                   │
│                                                                             │
│  THIS PROJECT IS NOT:                                                       │
│  - Porting Zig's allocator system to cot0                                   │
│  - Making cot0 identical to Zig's memory management                         │
│  - Fixing architectural differences with creative workarounds               │
│                                                                             │
│  The global arrays in cot0 will be replaced with ARC later.                 │
│  Do not suggest adding Zig-style allocators. That's not the plan.           │
└─────────────────────────────────────────────────────────────────────────────┘
```

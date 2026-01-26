# COT1 Performance Investigation

## Problem Statement

cot1-stage1 takes **minutes** to compile cot1, while the Zig bootstrap compiler does it in **~3 seconds**. This makes debugging impossible - each iteration takes minutes instead of seconds.

**Target**: Under 5 seconds for cot1-stage1 to compile cot1.

---

## Current Architecture

```
main.cot
├── Phase 1: Scanning (scanner.cot)
├── Phase 2: Parsing (parser.cot)
├── Phase 2.5: Import Processing (lib/import.cot)
├── Phase 2.6: Type Checking (frontend/checker.cot)
├── Phase 3: Lowering to IR (frontend/lower.cot)
├── Phase 4/5: SSA Building + Codegen (ssa/builder.cot, codegen/genssa.cot)
└── Phase 6: Mach-O Output (obj/macho.cot)
```

---

## Task List

### Task 1: Add Timing Infrastructure
- [ ] Add `clock_gettime` extern to runtime/cot_runtime.zig
- [ ] Add `get_time_ns()` wrapper function in lib/stdlib.cot
- [ ] Test timing works with simple program

### Task 2: Instrument main.cot Phases
- [ ] Add timing around Phase 1 (Scanning)
- [ ] Add timing around Phase 2 (Parsing)
- [ ] Add timing around Phase 2.5 (Import Processing)
- [ ] Add timing around Phase 2.6 (Type Checking)
- [ ] Add timing around Phase 3 (Lowering)
- [ ] Add timing around Phase 4/5 (SSA + Codegen)
- [ ] Add timing around Phase 6 (Mach-O)

### Task 3: Run Baseline Measurement
- [ ] Compile cot1 with instrumented stage1
- [ ] Record time for each phase
- [ ] Identify which phase(s) take >1 second

### Task 4: Analyze Slow Phase(s)
- [ ] Add sub-phase timing within slow phase
- [ ] Identify specific function(s) causing slowness
- [ ] Document the algorithmic complexity (O(n), O(n²), etc.)

### Task 5: Fix Performance Issues
- [ ] Replace linear scans with hash lookups where needed
- [ ] Build indices once instead of scanning repeatedly
- [ ] Verify fix reduces time

### Task 6: Verify Target Met
- [ ] cot1-stage1 compiles cot1 in under 5 seconds
- [ ] All tests still pass

---

## Suspected Bottlenecks (To Verify)

### 1. Function Lookup in lower.cot

**Location**: `Lowerer_resolveCall()` or similar
**Pattern**: For each call site, scan all functions to find target
**Complexity**: O(calls × functions) = O(5000 × 1256) = 6.28M operations
**Fix**: Build StrMap of function names → indices once at start

### 2. Function Lookup in genssa.cot

**Location**: Call site resolution during codegen
**Pattern**: Same linear scan pattern
**Fix**: Reuse function index from lowering phase

### 3. Type Comparison

**Location**: checker.cot or types.cot
**Pattern**: Deep structural comparison of types
**Fix**: Use type indices for comparison instead of structural walk

### 4. Symbol Table Lookup

**Location**: Various places doing `find symbol by name`
**Pattern**: Linear scan through symbol list
**Fix**: Use StrMap for symbol tables

---

## How Zig Does It Fast

The Zig bootstrap compiler (src/*.zig) uses:

1. **Hash maps everywhere** - `std.StringHashMap` for symbol lookup
2. **Interned strings** - String comparison is pointer equality
3. **Single-pass where possible** - Don't re-scan data structures
4. **Arena allocation** - Fast allocation, no individual frees

---

## Progress Log

### [Date: 2026-01-26]

**Baseline Timing Results:**
- Phase 1 (Scanning): 0ms
- Phase 2 (Parsing): 0ms
- Phase 2.5 (Imports): 26ms
- Phase 2.6 (Type checking): 0ms
- **Phase 3 (Lowering): 1675ms** <- BOTTLENECK
- Phase 4/5: Crashes before timing

**Root cause identified:** Phase 3 (lower.cot) is doing O(n²) function resolution.

**Fix required:** Replace linear function lookup with StrMap-based O(1) lookup.


# Path to Self-Hosting

## Current Status

| Stage | Status | Description |
|-------|--------|-------------|
| Stage 0 | Complete | Zig compiler (`src/*.zig`) - 166 tests pass |
| Stage 1 | Complete | Zig compiles cot1 → `cot1-stage1` works, 180 tests pass |
| Stage 2 | Partial | cot1-stage1 compiles cot1 → `cot1-stage2` links but crashes at runtime |
| Stage 3+ | Blocked | Self-hosting blocked by stage 2 crash |

**Status**: cot1-stage1 works correctly (180 tests pass: 166 bootstrap + 14 feature tests). cot1-stage2 compiles and links successfully (~763KB Mach-O) but crashes at startup (SIGSEGV - likely remaining struct size mismatches in generated code).

## What Works

- All 166 bootstrap end-to-end tests pass
- All 14 cot1 feature tests pass (type aliases, optionals, error unions, labeled break/continue)
- Simple and nested struct field access
- Array indexing with struct fields
- Defer statements with scope handling
- Control flow (if/else, while, for, break, continue)
- Function calls with multiple arguments (16+ args supported)
- String literals and global variables
- DWARF debug info in crash reports

## The Path Forward

### Phase 1: Logic Parity - COMPLETE

Copy algorithms and patterns from Zig compiler to cot1, adapting for Cot syntax.

| Section | File | Status |
|---------|------|--------|
| 1 | main.cot | Complete |
| 2.7 | frontend/ir.cot | Complete |
| 2.8 | frontend/lower.cot | Complete |
| 3.3 | ssa/block.cot | Complete |
| 3.4 | ssa/func.cot | Complete |
| 3.5 | ssa/builder.cot | Complete |
| 3.7 | ssa/regalloc.cot | Complete |
| 5.1 | codegen/arm64.cot | Complete |
| 5.2 | codegen/genssa.cot | Complete |
| 6.1 | obj/macho.cot | Complete |

### Phase 2: Fix Stage 2 Crash - IN PROGRESS

**Current Issue**: cot1-stage2 crashes at startup with SIGBUS.

**Suspected causes**:
1. Stack overflow during SSA building (8MB stack limit at scale)
2. Misaligned memory access in generated code
3. Incorrect struct field offset calculations

**Investigation approach**:
- Profile which phase takes too long (lowering is O(n) function lookup)
- Add timing instrumentation to identify bottlenecks
- Replace linear scans with hash map lookups (StrMap)

### Phase 3: Verify Self-Hosting

```bash
# Build stage1
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1

# Build stage2
/tmp/cot1-stage1 stages/cot1/main.cot -o /tmp/cot1-stage2.o
zig cc /tmp/cot1-stage2.o runtime/cot_runtime.o -o /tmp/cot1-stage2 -lSystem

# Build stage3
/tmp/cot1-stage2 stages/cot1/main.cot -o /tmp/cot1-stage3.o
zig cc /tmp/cot1-stage3.o runtime/cot_runtime.o -o /tmp/cot1-stage3 -lSystem

# Compare (should be identical)
diff /tmp/cot1-stage2 /tmp/cot1-stage3
```

### Phase 4: Post Self-Hosting

After self-hosting is achieved:

1. **ARC Memory Management** - Replace global arrays with automatic reference counting
2. **Language Features** - Generics, interfaces, better error handling
3. **Additional Targets** - x86-64, Linux, Windows
4. **Standard Library** - I/O, collections, networking

## Key Milestones

| Milestone | Criteria | Status |
|-----------|----------|--------|
| Zig compiler complete | 166 tests pass | Complete |
| Stage 1 works | Compiles simple programs | Complete |
| Stage 1 compiles cot1 | Produces executable | Complete |
| Stage 1 test parity | 180 tests pass | Complete |
| Stage 2 compiles | Produces object file | Complete |
| Stage 2 runs | No crash | **In Progress** |
| Stage 2 = Stage 3 | Self-hosting | Blocked |

## Verification Commands

```bash
# Full test suite with Zig compiler
zig build && ./zig-out/bin/cot test/bootstrap/all_tests.cot -o /tmp/t && /tmp/t

# Build and test stage1
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1

# Run bootstrap tests with stage1
/tmp/cot1-stage1 test/bootstrap/all_tests.cot -o /tmp/bt.o
zig cc /tmp/bt.o runtime/cot_runtime.o -o /tmp/bt -lSystem && /tmp/bt

# Run cot1 feature tests with stage1
/tmp/cot1-stage1 test/stages/cot1/cot1_features.cot -o /tmp/ft.o
zig cc /tmp/ft.o runtime/cot_runtime.o -o /tmp/ft -lSystem && /tmp/ft

# Attempt stage2 build
/tmp/cot1-stage1 stages/cot1/main.cot -o /tmp/cot1-stage2.o
zig cc /tmp/cot1-stage2.o runtime/cot_runtime.o -o /tmp/cot1-stage2 -lSystem
```

## Recent Progress

### 2026-01-26 (evening)
- **@sizeOf builtin fixed**: Now computes actual struct sizes via TypeRegistry
- **Generic sized allocation**: Added `malloc_sized`/`realloc_sized` to runtime
- **func.cot uses @sizeOf**: Block, Value, Local allocations use computed sizes
- **Struct size fixes**: CallSite (16→24), Reloc realloc (24→48)
- **Stage2 now links**: Previously failed with corrupted symbols, now links successfully
- **Stage2 crashes at runtime**: SIGSEGV at startup, likely more struct size mismatches

### 2026-01-26
- main.cot reduced from 1751 to ~900 lines (48% reduction)
- Import processing moved to lib/import.cot
- Checker wired into compilation pipeline

### 2026-01-25
- cot1-stage1 compiles cot1 successfully (459KB Mach-O object)
- Parser 16+ args limitation fixed
- All 166 bootstrap + 14 feature tests pass
- Labeled break/continue implemented

### 2026-01-24
- Type aliases, optionals, error unions implemented
- String parameter passing fixed
- Dogfooding: type aliases now used in cot1 source

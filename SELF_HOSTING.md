# Path to Self-Hosting

## Current Status

| Stage | Status | Description |
|-------|--------|-------------|
| Stage 0 | ✅ Complete | Zig compiler (`src/*.zig`) - 166 tests pass |
| Stage 1 | ✅ Complete | Zig compiles cot0 → `cot0-stage1` works |
| Stage 2 | ⚠️ Blocked | Stage1 compiles cot0 → crashes at runtime |
| Stage 3+ | Pending | Self-hosting achieved when stageN = stageN+1 |

**Blocker**: Stage 2 crashes with SIGSEGV. Root cause: BlockStmt corruption during import processing causes some functions to be skipped during IR lowering.

## The Path Forward

### Phase 1: Function Parity (Current)

Make every function in [cot0/COMPARISON.md](cot0/COMPARISON.md) show "Same".

**Why this matters**: Bugs exist because cot0 is missing patterns from Zig. Achieving parity eliminates these bugs systematically.

**Progress**: 7 of 21 sections marked "DONE"

| Section | File | Status |
|---------|------|--------|
| 1 | main.cot | Reviewed (architectural diff OK) |
| 2.1 | frontend/token.cot | Pending |
| 2.2 | frontend/scanner.cot | Pending |
| 2.3 | frontend/ast.cot | Pending |
| 2.4 | frontend/parser.cot | Pending |
| 2.5 | frontend/types.cot | Pending |
| 2.6 | frontend/checker.cot | Pending |
| 2.7 | frontend/ir.cot | **DONE** |
| 2.8 | frontend/lower.cot | **DONE** |
| 3.1 | ssa/op.cot | Pending |
| 3.2 | ssa/value.cot | Pending |
| 3.3 | ssa/block.cot | **DONE** |
| 3.4 | ssa/func.cot | **DONE** |
| 3.5 | ssa/builder.cot | **DONE** |
| 3.6 | ssa/liveness.cot | Pending |
| 3.7 | ssa/regalloc.cot | **DONE** |
| 4.1 | arm64/asm.cot | Pending |
| 5.1 | codegen/arm64.cot | **DONE** |
| 5.2 | codegen/genssa.cot | **DONE** |
| 6.1 | obj/macho.cot | **DONE** |

### Phase 2: Fix the Stage 2 Crash

Once parity is complete, the crash should either:
1. Be fixed (missing pattern was the cause)
2. Be obvious (clear which remaining difference causes it)

**Debug tools available**:
- DWARF debug info shows crash source location
- Runtime crash handler shows registers and stack trace
- lldb works with source code

### Phase 3: Verify Self-Hosting

```bash
# Build stage1
./zig-out/bin/cot cot0/main.cot -o /tmp/cot0-stage1

# Build stage2
/tmp/cot0-stage1 cot0/main.cot -o /tmp/cot0-stage2

# Build stage3
/tmp/cot0-stage2 cot0/main.cot -o /tmp/cot0-stage3

# Compare (should be identical)
diff /tmp/cot0-stage2 /tmp/cot0-stage3
```

### Phase 4: Post Self-Hosting

After self-hosting is achieved:

1. **ARC Memory Management**
   - Replace global arrays with ARC
   - Compiler inserts retain/release
   - No manual memory management

2. **Language Features**
   - Generics
   - Interfaces/Traits
   - Better error handling

3. **Additional Targets**
   - x86-64 backend
   - Linux support
   - Windows support

4. **Standard Library**
   - I/O
   - Collections
   - Networking

## Key Milestones

| Milestone | Criteria | Status |
|-----------|----------|--------|
| Zig compiler complete | 166 tests pass | ✅ |
| Stage 1 works | Compiles simple programs | ✅ |
| Stage 1 compiles cot0 | Produces executable | ✅ |
| Stage 2 runs | No crash | ⚠️ Blocked |
| Stage 2 = Stage 3 | Self-hosting | Pending |
| ARC implemented | No globals | Planned |

## Current Blockers

### 1. BlockStmt Corruption

During import processing, some `BlockStmt` nodes have corrupted `stmts_count` values. This causes functions to be skipped during IR lowering.

**Symptoms**:
- Stage 2 crashes (SIGSEGV)
- Some functions have 0 IR nodes

**Likely cause**: Missing or incorrect pattern in import handling that exists in Zig but not cot0.

**Fix approach**: Compare import handling in cot0 vs Zig line by line.

## Verification Commands

```bash
# Full test suite
zig build && ./zig-out/bin/cot test/e2e/all_tests.cot -o /tmp/t && /tmp/t

# Build and test stage1
./zig-out/bin/cot cot0/main.cot -o /tmp/cot0-stage1
echo 'fn main() i64 { return 42 }' > /tmp/test.cot
/tmp/cot0-stage1 /tmp/test.cot -o /tmp/test.o
zig cc /tmp/test.o -o /tmp/test && /tmp/test

# Attempt stage2 (currently crashes)
/tmp/cot0-stage1 cot0/main.cot -o /tmp/cot0-stage2
```

## Recent Progress

### 2026-01-23
- DWARF debug info implementation complete
- Crash handler shows source locations
- lldb integration working

### 2026-01-22
- Dynamic array conversion
- Runtime malloc/realloc functions
- Function naming parity improvements

# Path to Self-Hosting

## Current Status

| Stage | Status | Description |
|-------|--------|-------------|
| Stage 0 | ✅ Complete | Zig compiler (`src/*.zig`) - 166 tests pass |
| Stage 1 | ✅ Complete | Zig compiles cot0 → `cot0-stage1` works, 166/166 tests pass |
| Stage 2 | ⚠️ Partial | Stage1 compiles cot0 → `cot0-stage2` compiles but has bugs |
| Stage 3+ | ⚠️ Blocked | Self-hosting blocked by stage2 issues |

**Status**: Stage1 works correctly (166/166 tests pass). Stage2 compiles but has SSA errors causing incorrect code generation (argc/argv not read correctly).

## What Works

- All 166 end-to-end tests pass
- Simple and nested struct field access
- Array indexing with struct fields
- Defer statements with scope handling
- Control flow (if/else, while, for, break, continue)
- Function calls with multiple arguments
- String literals and global variables
- DWARF debug info in crash reports

## The Path Forward

### Phase 1: Logic Parity (Current)

Copy algorithms and patterns from Zig compiler to cot0, adapting for Cot syntax.

**Approach**: Focus on logic, not syntax. cot0 uses different naming conventions (PascalCase vs snake_case) and doesn't have all Zig language features. The goal is equivalent behavior.

| Section | File | Status |
|---------|------|--------|
| 1 | main.cot | ✅ Complete |
| 2.7 | frontend/ir.cot | ✅ Complete |
| 2.8 | frontend/lower.cot | ✅ Complete |
| 3.3 | ssa/block.cot | ✅ Complete |
| 3.4 | ssa/func.cot | ✅ Complete |
| 3.5 | ssa/builder.cot | ✅ Complete |
| 3.7 | ssa/regalloc.cot | ✅ Complete |
| 5.1 | codegen/arm64.cot | ✅ Complete |
| 5.2 | codegen/genssa.cot | ✅ Complete |
| 6.1 | obj/macho.cot | ✅ Complete |

### Phase 2: Fix the Stage 2 Crash - COMPLETE

**Fixed 2026-01-24!** The issues were:
1. Large struct arguments (>16B) needed ARM64 ABI pass-by-reference via `expand_calls` pass
2. String concatenation needed dedicated `StringConcat` SSA op
3. malloc sizes in runtime were too small for cot0's larger structs
4. Various codegen fixes for LocalAddr handling in call arguments

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

1. **ARC Memory Management** - Replace global arrays with automatic reference counting
2. **Language Features** - Generics, interfaces, better error handling
3. **Additional Targets** - x86-64, Linux, Windows
4. **Standard Library** - I/O, collections, networking

## Key Milestones

| Milestone | Criteria | Status |
|-----------|----------|--------|
| Zig compiler complete | 166 tests pass | ✅ |
| Stage 1 works | Compiles simple programs | ✅ |
| Stage 1 compiles cot0 | Produces executable | ✅ |
| Stage 1 test parity | 166/166 tests pass | ✅ |
| Stage 2 runs | No crash | ⚠️ Runs but buggy |
| Stage 2 = Stage 3 | Self-hosting | ⚠️ Blocked |

## Verification Commands

```bash
# Full test suite
zig build && ./zig-out/bin/cot test/e2e/all_tests.cot -o /tmp/t && /tmp/t

# Build and test stage1
./zig-out/bin/cot cot0/main.cot -o /tmp/cot0-stage1
echo 'fn main() i64 { return 42 }' > /tmp/test.cot
/tmp/cot0-stage1 /tmp/test.cot -o /tmp/test.o
zig cc /tmp/test.o -o /tmp/test && /tmp/test

# Test nested struct (should return 20)
echo 'struct Inner { x: i64, y: i64 }
struct Outer { inner: Inner }
fn main() i64 { var o: Outer; o.inner.x = 10; o.inner.y = 20; return o.inner.y; }' > /tmp/nested.cot
/tmp/cot0-stage1 /tmp/nested.cot -o /tmp/nested.o
zig cc /tmp/nested.o -o /tmp/nested && /tmp/nested

# Attempt stage2 (currently crashes)
/tmp/cot0-stage1 cot0/main.cot -o /tmp/cot0-stage2
```

## Recent Progress

### 2026-01-24
- Fixed nested struct field assignment (TypeRegistry-based lookup)
- Added BlockStmt handling in lowerStmt
- Added node index validation in lowerBlockCheckTerminated
- SSA passes with full logic

### 2026-01-23
- DWARF debug info implementation complete
- Defer statement support
- FwdRef pattern in SSA builder
- emitPhiMoves for phi semantics

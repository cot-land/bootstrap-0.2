# Project Status

**Last Updated: 2026-01-24**

## Quick Status

| Component | Status |
|-----------|--------|
| Zig compiler | ✅ 166 tests pass |
| Stage 1 (Zig → cot0) | ✅ Working |
| Stage 2 (cot0 → cot0) | ⚠️ Blocked (SSA crash during self-compilation) |
| Self-hosting | In progress |

## Current Goal

Achieve logic parity between cot0 and Zig compiler - same algorithms and patterns, adapted for Cot syntax.

**Progress**: Core compiler pipeline complete. Stage 2 blocked by crash during SSA building when processing large codebases.

## What Works

- ✅ All 166 end-to-end tests pass
- ✅ Simple struct field access (`p.x = 10`)
- ✅ Nested struct field access (`o.inner.y = 20`)
- ✅ Array indexing with struct fields (`points[0].x`)
- ✅ Defer statements with proper scope handling
- ✅ Control flow (if/else, while, for, break, continue)
- ✅ Function calls with up to 8 arguments
- ✅ String literals and global variables
- ✅ DWARF debug info (source locations in crash reports)

## Stage 2 Blocker

The cot0 compiler crashes during SSA building when compiling itself. The crash occurs in `SSABuilder_build` with a SIGBUS error. Root cause appears related to how imported files are merged into a single AST/node pool.

## Recent Milestones

- **2026-01-24**: Added SSABuilder_verify() for SSA validation/debugging
- **2026-01-24**: Added parser nesting depth protection (Parser_incNest/decNest)
- **2026-01-24**: Added node index validation in lowerBlockCheckTerminated
- **2026-01-24**: Added BlockStmt handling in lowerStmt (nested blocks as statements)
- **2026-01-24**: Fixed nested struct field assignment (TypeRegistry-based lookup)
- **2026-01-24**: SSA passes with full logic (schedule, lower, decompose, expand_calls)
- **2026-01-24**: Added allocatePhis() to regalloc for phi register allocation
- **2026-01-24**: Enhanced inferExprType() with full type inference
- **2026-01-23**: Added defer statement support (defer_stack, emitDeferredExprs)
- **2026-01-23**: Added FwdRef pattern to SSA builder (insertPhis, lookupVarOutgoing)
- **2026-01-23**: Added emitPhiMoves() for correct phi semantics
- **2026-01-23**: Struct array field access fix
- **2026-01-23**: DWARF debug info implementation

## Documentation

| Document | Purpose |
|----------|---------|
| [README.md](README.md) | Project overview and vision |
| [CLAUDE.md](CLAUDE.md) | Development workflow |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Compiler design |
| [SELF_HOSTING.md](SELF_HOSTING.md) | Path to self-hosting |
| [cot0/COMPARISON.md](cot0/COMPARISON.md) | Function parity checklist |

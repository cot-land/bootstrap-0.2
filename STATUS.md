# Project Status

**Last Updated: 2026-01-23**

## Quick Status

| Component | Status |
|-----------|--------|
| Zig compiler | ✅ 166 tests pass |
| Stage 1 (Zig → cot0) | ✅ Working |
| Stage 2 (cot0 → cot0) | ✅ Compiles successfully |
| Self-hosting | In progress |

## Current Goal

Make every function in [cot0/COMPARISON.md](cot0/COMPARISON.md) show "Same".

**Progress**: All frontend, SSA, codegen, and object file sections complete.

See [SELF_HOSTING.md](SELF_HOSTING.md) for detailed progress and path forward.

## Recent Milestones

- **2026-01-23**: Struct array field access fix - `points[0].x` now works correctly
- **2026-01-23**: Added TypeExpr AST nodes for proper type resolution
- **2026-01-23**: Added `TypeRegistry_sizeof()` function
- **2026-01-23**: COMPARISON.md rewritten with detailed function comparisons
- **2026-01-23**: DWARF debug info - crash handler shows source locations
- **2026-01-22**: Dynamic array conversion for larger codebases
- **2026-01-21**: Function naming parity improvements across all sections

## Documentation

| Document | Purpose |
|----------|---------|
| [README.md](README.md) | Project overview and vision |
| [CLAUDE.md](CLAUDE.md) | Development workflow |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Compiler design |
| [SELF_HOSTING.md](SELF_HOSTING.md) | Path to self-hosting |
| [REFERENCE.md](REFERENCE.md) | Technical reference |
| [cot0/COMPARISON.md](cot0/COMPARISON.md) | Function parity checklist |

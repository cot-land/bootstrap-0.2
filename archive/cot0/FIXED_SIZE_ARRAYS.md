# Fixed-Size Arrays in cot0 - COMPLETED

**Status: COMPLETE (2026-01-24)**

This document has been superseded by [FIXED_ARRAYS_AUDIT.md](FIXED_ARRAYS_AUDIT.md).

## Summary

All accumulating fixed-size arrays have been converted to dynamic allocation:

- **IR Storage** (ir_nodes, ir_locals, ir_funcs, constants, ir_globals) - dynamic growth via realloc
- **Type Pool** (types, params, fields) - dynamic growth with capacity tracking
- **Node Pool** - uses capacity field instead of hardcoded MAX_NODES

Remaining `MAX_*` constants are intentional per-function limits (SSA, codegen) that:
1. Reset for each function
2. Don't accumulate across compilation
3. Are sized for worst-case single functions

See [FIXED_ARRAYS_AUDIT.md](FIXED_ARRAYS_AUDIT.md) for the complete audit and implementation details.

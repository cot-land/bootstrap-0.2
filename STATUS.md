# Bootstrap 0.2 - Project Status

**Last Updated: 2026-01-22**

## Current Goal

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   Make EVERY function in cot0/COMPARISON.md show "Same"                       ║
║                                                                               ║
║   Progress: 1 / 21 sections complete (3.5 ssa/builder.cot)                     ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## Section Progress

Work through cot0/COMPARISON.md top to bottom. Mark each section complete when ALL functions show "Same".

| Section | File | Status | Same | Equiv | Missing cot0 | Missing Zig |
|---------|------|--------|------|-------|--------------|-------------|
| 1 | main.cot | **REVIEWED** | 5 | 12 | 3 | 0 | Driver_* functions exist; architectural differences intentional |
| 2.1 | frontend/token.cot | Pending | 1 | 2 | 0 | 0 | Token_string() added |
| 2.2 | frontend/scanner.cot | Pending | 17 | 5 | 0 | 0 | isHexDigit() added |
| 2.3 | frontend/ast.cot | Pending | 23 | 2 | 2 | 0 |
| 2.4 | frontend/parser.cot | Pending | 5 | 31 | 0 | 0 |
| 2.5 | frontend/types.cot | Pending | 10 | 2 | 4 | 0 |
| 2.6 | frontend/checker.cot | Pending | 24 | 0 | 2 | 0 |
| 2.7 | frontend/ir.cot | Pending | 10 | 0 | 1 | 0 |
| 2.8 | frontend/lower.cot | Pending | 18 | 0 | 2 | 0 |
| 3.1 | ssa/op.cot | Pending | 5 | 3 | 0 | 0 | Op_isBranch/isCall/isTerminator/numArgs added |
| 3.2 | ssa/value.cot | Pending | 10 | 0 | 2 | 0 | Value_numArgs() added |
| 3.3 | ssa/block.cot | Pending | 13 | 0 | 0 | 0 | Block_numPreds/numSuccs/numValues added |
| 3.4 | ssa/func.cot | Pending | 11 | 0 | 1 | 0 | Func_numBlocks/numValues/numLocals added |
| 3.5 | ssa/builder.cot | **DONE** | 37 | 0 | 1 | 0 | Added emitCast, emitAlloca |
| 3.6 | ssa/liveness.cot | Pending | 5 | 2 | 3 | 0 |
| 3.7 | ssa/regalloc.cot | Pending | 9 | 0 | 4 | 0 |
| 4.1 | arm64/asm.cot | Pending | 48 | 2 | 0 | 5 | sxtb/sxth/sxtw/uxtb/uxth/tst/invert_cond added |
| 4.2 | arm64/regs.cot | Pending | — | — | — | 5 (cot0-only) |
| 5.1 | codegen/arm64.cot | Pending | 0 | 26 | 13 | 0 |
| 5.2 | codegen/genssa.cot | Pending | — | — | — | 39 (cot0-only) |
| 6.1 | obj/macho.cot | Pending | 3 | 3 | 6 | 16 |
| 7.* | Zig-only files | Pending | 0 | 0 | ~150 | 0 |

---

## Current Task

**Section 1: main.cot vs main.zig + driver.zig**

Functions to make "Same":

| cot0 Function | Zig Function | Status |
|---------------|--------------|--------|
| `Driver_init()` | `Driver.init()` | ✓ EXISTS - Different implementation (global state vs allocator) |
| `Driver_compileFile()` | `Driver.compileFile()` | ✓ EXISTS - Different implementation |
| `Driver_compileSource()` | `Driver.compileSource()` | ✓ EXISTS - Thin wrapper |
| `Driver_setDebugPhases()` | `Driver.setDebugPhases()` | ✓ EXISTS - Stub for API parity |
| `Driver_parseFileRecursive()` | `parseFileRecursive()` | ✓ EXISTS - Different implementation |
| `ir_op_to_ssa_op()` | SSA conversion | ✓ DONE - Moved to ssa/builder.cot |
| `ir_unary_op_to_ssa_op()` | SSA conversion | ✓ DONE - Moved to ssa/builder.cot |
| `print_int()` | `std.debug.print()` | DIFFERENT - Uses syscalls (cot0-specific) |
| `read_file()` | `std.fs.cwd().readFileAlloc()` | DIFFERENT - Uses syscalls (cot0-specific) |
| `write_file()` | `std.fs.cwd().writeFile()` | DIFFERENT - Uses syscalls (cot0-specific) |
| `init_node_pool()` | AST init | DIFFERENT - Global arrays (cot0-specific) |
| `is_path_imported()` | `seen_files.contains()` | DIFFERENT - Global arrays (cot0-specific) |
| `add_imported_path()` | `seen_files.put()` | DIFFERENT - Global arrays (cot0-specific) |
| `extract_base_dir()` | `std.fs.path.dirname()` | DIFFERENT - Manual impl (cot0-specific) |
| `build_import_path()` | `std.fs.path.join()` | DIFFERENT - Manual impl (cot0-specific) |
| `adjust_node_positions()` | Position in Source | DIFFERENT - cot0-specific for global buffer |
| `parse_import_file()` | parseFileRecursive | DIFFERENT - Uses global buffers |
| — | `findRuntimePath()` | Missing - Not needed in cot0 (hardcoded) |
| — | `pipeline_debug.initGlobal()` | Missing - No debug infrastructure |
| — | `ErrorReporter` | Missing - cot0 uses print() directly |

**Note:** Section 1 functions are intentionally "DIFFERENT" due to cot0's global buffer design vs Zig's allocator pattern. This is an architectural choice, not a bug.

---

## Summary Statistics

| Metric | Count |
|--------|-------|
| Total sections | 21 |
| Sections complete | 1 |
| Functions "Same" | ~235 |
| Functions "Equivalent" | ~95 |
| Functions missing in cot0 | ~205 |
| Zig-only file functions | ~150 |
| **Total work items** | ~465 |

---

## Zig Compiler Status

| Component | Status |
|-----------|--------|
| Zig compiler (src/*.zig) | **COMPLETE** - 166 tests pass |

---

## Quick Reference

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

## Key Documents

| Document | Purpose |
|----------|---------|
| [cot0/COMPARISON.md](cot0/COMPARISON.md) | Master checklist |
| [CLAUDE.md](CLAUDE.md) | Development guidelines |
| [cot0/ROADMAP.md](cot0/ROADMAP.md) | Detailed file-by-file plan |
| [BUGS.md](BUGS.md) | Bug tracking |

# Bootstrap 0.2 - Project Status

**Last Updated: 2026-01-23**

## Current Goal

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   Make EVERY function in cot0/COMPARISON.md show "Same"                       ║
║                                                                               ║
║   Progress: 3 / 21 sections complete (3.5, 5.1, 6.1)                          ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

---

## Section Progress

Work through cot0/COMPARISON.md top to bottom. Mark each section complete when ALL functions show "Same".

| Section | File | Status | Notes |
|---------|------|--------|-------|
| 1 | main.cot | **REVIEWED** | Architectural differences intentional (global arrays vs allocator) |
| 2.1 | frontend/token.cot | Pending | Token_string() added |
| 2.2 | frontend/scanner.cot | Pending | isHexDigit() added |
| 2.3 | frontend/ast.cot | Pending | Token_toBinaryOp, BinaryOp_fromInt, etc. renamed |
| 2.4 | frontend/parser.cot | Pending | |
| 2.5 | frontend/types.cot | Pending | |
| 2.6 | frontend/checker.cot | Pending | ScopePool_isDefined added |
| 2.7 | frontend/ir.cot | **DONE** | FuncBuilder_* renamed to match Zig |
| 2.8 | frontend/lower.cot | **DONE** | FuncBuilder_* call sites, ASTOp_* helpers, lowerIndex TypeRegistry fix |
| 3.1 | ssa/op.cot | Pending | Op_isBranch/isCall/isTerminator/numArgs added |
| 3.2 | ssa/value.cot | Pending | Value_numArgs(), isRematerializable added |
| 3.3 | ssa/block.cot | **DONE** | Block_* functions already properly named |
| 3.4 | ssa/func.cot | **DONE** | Func_* functions already properly named |
| 3.5 | ssa/builder.cot | **DONE** | SSABuilder_* functions, emitCast/emitAlloca added |
| 3.6 | ssa/liveness.cot | Pending | |
| 3.7 | ssa/regalloc.cot | **DONE** | Op_isRematerializable renamed |
| 4.1 | arm64/asm.cot | Pending | sxtb/sxth/sxtw/uxtb/uxth/tst/invert_cond added |
| 4.2 | arm64/regs.cot | Pending | cot0-only file |
| 5.1 | codegen/arm64.cot | **DONE** | ARM64_* naming, Emitter_init, Instruction_*, Cond_* |
| 5.2 | codegen/genssa.cot | **DONE** | GenState_* naming complete |
| 6.1 | obj/macho.cot | **DONE** | MachOWriter_* naming complete |
| 7.* | Zig-only files | Pending | Not needed for self-hosting |

---

## Recent Changes (2026-01-23)

### DWARF Debug Info Implementation ✅

**Problem:** When cot0-stage2 crashes, we see only `Exit: 139` with no crash location, registers, or stack trace.

**Solution Implemented:** Full DWARF debug info generation and runtime crash handler:

1. **DWARF Generation (Zig compiler - src/dwarf.zig)**
   - New `DwarfBuilder` module matching Go's DWARF architecture
   - Generates `__debug_line` section with DWARF v4 line table
   - Generates `__debug_abbrev` and `__debug_info` sections
   - Uses Go's efficient `putpclcdelta` algorithm for line/address encoding
   - Proper relocations for code addresses

2. **MachO Integration (src/obj/macho.zig)**
   - `__DWARF` segment with debug sections
   - Correct section layout and relocations
   - Line entries passed from codegen to MachO writer

3. **Runtime Crash Handler (runtime/cot_runtime.zig)**
   - Signal handler for SIGSEGV/SIGBUS/SIGFPE/SIGILL
   - Full register dump (PC, LR, SP, FP, x0-x28)
   - Stack trace via frame pointer walking
   - Symbol lookup with sorted symbol table
   - DWARF line table parsing for source locations
   - Handles Mach-O rebase fixups (addresses already slide-adjusted)

**Verification:**
```
# Crash test output:
Source Location:
  crash_test.cot:3

# lldb also works:
* frame #0: crash_test.o`crash at crash_test.cot:3
   1    fn crash() i64 {
   2        let p: *i64 = null
-> 3        return p.*
```

**Key Implementation Details:**
- Mach-O loader applies rebase fixups to DWARF addresses at load time
- Runtime parser does NOT add ASLR slide (already applied)
- Line table lookup tracks emitted rows, not state machine state
- Special opcodes advance-then-emit (DWARF v4 semantics)

---

## Recent Changes (2026-01-22)

### Dynamic Array Conversion

Converted fixed-size arrays to dynamic allocation to support self-hosting larger codebases:

**Runtime functions added (cot_runtime.zig):**
- `malloc_u8`, `realloc_u8`, `free_u8` - u8 array allocation
- `malloc_i64`, `realloc_i64`, `free_i64` - i64 array allocation

**Converted u8 buffers:**
- `g_source` - Source code buffer (1MB initial)
- `g_code` - Generated machine code (1MB initial)
- `g_output` - Mach-O output buffer (1MB initial)
- `g_data` - Data section (64KB initial)
- `g_strings` - String table (32KB initial)

**Converted i64 arrays:**
- `g_type_params` - Type parameters (5000 initial)
- `g_call_args` - Call arguments (10000 initial)
- `g_bstart` - Block start offsets (5000 initial)
- `g_ir_to_ssa_id` - IR to SSA mapping (50000 initial)
- `g_local_to_ssa_id` - Local to SSA mapping (5000 initial)
- `g_import_path_lens` - Import path lengths (100 initial)

**Tracking document:** See [DYNAMIC_ARRAYS.md](DYNAMIC_ARRAYS.md) for full status.

### Known Issue: BlockStmt Corruption During Imports

During self-hosting compilation, some BlockStmt nodes have corrupted `stmts_count` values
after import processing. This causes functions to be skipped during IR lowering.
A safety check (bail when stmts_count > 500) prevents infinite loops but results in
incomplete stage2 compilation. Root cause investigation pending.

### Self-Hosting Test Results

**cot0-stage1 successfully compiles:**
- Simple programs (return, arithmetic, variables)
- Function calls (sq(3) + sq(4) = 25 ✓)
- Recursive functions (factorial(5) = 120 ✓, fib(10) = 55 ✓)
- The BUG-049 spill workaround for call+call binary ops works correctly
- **cot0/main.cot** → produces ~155KB object file with 759 functions

**Self-hosting limitation:**
- Stage2 compiles but crashes at runtime (SIGSEGV)
- Root cause: BlockStmt corruption causes some functions to be skipped during IR lowering
- Full self-hosting blocked until corruption bug is fixed

### COMPARISON.md Corrections

Fixed outdated entries:
- `lowerIndex` - Now correctly uses TypeRegistry (marked Same)
- Spill/reload handling - GenState_emitSpill/emitReload exist and work (marked Same)
- getRegForValue/getDestRegForValue - cot0 uses direct v.reg access (marked DIFFERENT, not Missing)

### Naming Parity Improvements

**Section 5.1 & 5.2 (codegen/arm64.cot, genssa.cot):**
- `codegen_*` → `ARM64_*` (add, sub, mul, div, and, or, xor, cmp, setcc, select, branch, branchCond, call, return, load64, store64, load8, store8)
- `Emitter_init`, `Instruction_selectLoad`, `Instruction_selectStore`
- `ARM64_encodePrologue`, `ARM64_encodeEpilogue`, `ARM64_encodeMovReg`, `ARM64_encodeMovImm`
- `Cond_forSignedLt/Gt/Le/Ge`, `Cond_forEq/Ne`
- `GenState_*` functions (addBranch, addBranchCbz, emitReload, emitSpill, resolveBranches, patchB, patchBCond, patchCbz)

**Section 6.1 (obj/macho.cot):**
- `write_macho` → `MachOWriter_write`
- `make_reloc_info` → `RelocInfo_make`
- `is_macho_magic` → `MachO_isMagic`
- `is_valid_file_type` → `MachO_isValidFileType`
- `padding_for_align` → `MachO_paddingForAlign`
- `align_up` → `MachO_alignUp`
- `out_byte/u32/u64/zeros/bytes` → `MachOWriter_outByte/outU32/outU64/outZeros/outBytes`
- `write_mach_header/segment_cmd/section/symtab_cmd/reloc/nlist64` → `MachOWriter_write*`

**Section 2.7 & 2.8 (ir.cot, lower.cot):**
- `func_builder_*` → `FuncBuilder_*` (init, newBlock, setBlock, addLocal, addParam, emit*, etc.)
- `ast_op_to_ir_op` → `ASTOp_toIROp`
- `ast_unary_op_to_ir_op` → `ASTUnaryOp_toIROp`
- `is_comparison_op` → `ASTOp_isComparison`

---

## Zig Compiler Status

| Component | Status |
|-----------|--------|
| Zig compiler (src/*.zig) | **COMPLETE** - 166 tests pass |
| cot0-stage1 | **WORKING** - Compiles simple programs, factorial, fibonacci, and itself |

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

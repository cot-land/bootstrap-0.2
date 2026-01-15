# Call ABI Implementation Plan

## Goal
Implement Go-style ABI-aware register allocation for function calls, following `~/learning/go/src/cmd/compile/internal/ssa/`.

## Reference Files in Go
- `expand_calls.go` - Decomposition and ABI info attachment
- `op.go` - AuxCall structure (lines 118-262)
- `regalloc.go` - Dynamic regspec lookup (lines 964-990)
- `cmd/compile/internal/abi/` - ABI parameter info

---

## Phase 1: ABI Structures [COMPLETE]

### 1.1 Create src/ssa/abi.zig
- [x] Define `RegIndex` as u8 for register indices
- [x] Define `RegMask` as u32 bitmask
- [x] Define `ABIParamAssignment` struct (type, registers, stack_offset)
- [x] Define `ABIParamResultInfo` struct (in_params, out_params, register counts)
- [x] Add ARM64 calling convention constants (caller-save mask, etc.)
- [x] Add helper: `buildCallRegInfo()` to generate regalloc constraints
- [x] Add pre-built `str_concat_abi` for __cot_str_concat

### 1.2 Update src/ssa/value.zig (AuxCall integrated here)
- [x] Update `AuxCall` struct with fn_name, abi_info, reg_info fields
- [x] Implement `getRegInfo()` method (lazy computation like Go)
- [x] Add `regsOfArg()` and `regsOfResult()` helpers
- [x] Add `strConcat()` factory method
- [x] Add `aux_call: ?*AuxCall` field to Value struct

### 1.3 Update src/ssa/op.zig
- [x] Add `isCall()` method to Op enum

---

## Phase 2: Expand Calls Integration [COMPLETE]

### 2.1 Update src/ssa/passes/expand_calls.zig
- [x] Import new abi and aux_call modules
- [x] In `expandStringConcat()`: create ABICallInfo for __cot_str_concat
- [x] In `expandStringConcat()`: create AuxCall and attach to value
- [x] Add debug logging showing ABI info attached

### 2.2 Generalize for other calls (FUTURE)
- [ ] Create helper `createCallABI()` that builds ABICallInfo from function signature
- [ ] Apply to `static_call` operations
- [ ] Apply to extern function calls

---

## Phase 3: Register Allocator Integration [DEFERRED]

**Note:** Deferred for now - using workaround in codegen (see Phase 4 notes).

### 3.1 Update src/ssa/op.zig
- [x] Add `isCall()` method to Op enum (done in Phase 1)
- [ ] Define `InputInfo` struct (idx, regs mask)
- [ ] Define `RegInfo` struct (inputs, outputs, clobbers)
- [ ] Add static RegInfo for non-call ops (or update existing)

### 3.2 Update src/ssa/regalloc.zig (or create if doesn't exist)
- [ ] Add `getRegSpec(v: *Value) RegInfo` function
- [ ] For calls: query `v.aux_call.getRegInfo()`
- [ ] For non-calls: use static op table
- [ ] Implement input allocation with constraint satisfaction
- [ ] Handle register conflicts (Go's pattern: lines 1588-1656)
- [ ] Add detailed debug logging

### 3.3 Emit register moves
- [ ] When value not in required register, emit copy
- [ ] Handle circular dependencies (a in x0, b in x1, need a->x1, b->x0)
- [ ] Use scratch registers for breaking cycles

---

## Phase 4: Codegen Cleanup [PARTIAL - WORKAROUND IN PLACE]

**Note:** Full cleanup deferred. Instead, we implemented a workaround:
- Call results are saved to x8/x9 immediately after BL instruction
- Store codegen for string_make uses x8/x9 directly (preserved registers)
- This avoids register clobbering without full ABI-aware regalloc

### 4.1 Remove ad-hoc shuffling from src/codegen/arm64.zig
- [x] string_concat: uses scratch registers x10-x13 for parallel assignment
- [x] store for string_make: uses x8/x9 directly (preserved call results)
- [ ] Full cleanup pending Phase 3 completion

### 4.2 Update codegen to use AuxCall info
- [x] Read function name from aux_call.fn_name for relocations
- [x] Log ABI info for debugging (in_regs, out_regs, arg registers)
- [ ] Full integration pending Phase 3 completion

---

## Phase 5: Testing & Validation [COMPLETE]

### 5.1 Unit tests
- [x] Zig build test passes (exit code 0)
- [ ] Test ABICallInfo construction (future)
- [ ] Test regInfo generation (future)
- [ ] Test register conflict resolution (future)

### 5.2 Integration tests
- [x] Compile test_concat_debug.cot - single concat -> Exit 11 ✓
- [x] Compile test_multi_concat.cot - chained concat -> Exit 11 ✓
- [x] Compile test_chain_concat.cot - inline chained (a+b+c) -> Exit 6 ✓
- [x] Run all_tests.cot with C runtime -> Exit 122 ✓

### 5.3 Debug output verification
- [x] Enable COT_DEBUG=codegen shows ABI info
- [x] Verify ABI info logged for each call (in_regs=4, out_regs=2)
- [x] Verify register assignments logged (arg[0]->x0, etc.)

---

## Phase 6: Documentation & Cleanup

### 6.1 Update documentation
- [ ] Update CLAUDE.md with ABI architecture description
- [ ] Update STATUS.md with completion status
- [ ] Document debug flags for call ABI tracing

### 6.2 Code cleanup
- [ ] Remove any dead code from old approach
- [ ] Ensure consistent naming with Go conventions
- [ ] Add comments referencing Go source locations

---

## Current Progress

**Phase 1**: COMPLETE - ABI structures created (abi.zig, AuxCall in value.zig)
**Phase 2**: COMPLETE - AuxCall attached to string_concat ops
**Phase 3**: DEFERRED - Using workaround instead of full regalloc integration
**Phase 4**: PARTIAL - Workaround using x8/x9 preserved registers
**Phase 5**: COMPLETE - All tests pass (122/122)
**Phase 6**: Not started

### Workaround Details
Instead of full ABI-aware register allocation (Phase 3), we implemented a simpler workaround:
1. `string_concat` saves call results to x8/x9 immediately after BL
2. `select_n` reads from x8/x9 (the preserved locations)
3. Store codegen for `string_make` uses x8/x9 directly

This works because x8/x9 are preserved across the intervening instructions that may clobber x1/x2.

### Future Work
When we hit more complex calling scenarios, we'll need to implement Phase 3 (ABI-aware regalloc).
For now, the workaround is sufficient for string concatenation.

---

## Notes

- Go reference: `~/learning/go/src/cmd/compile/internal/ssa/`
- ARM64 calling convention: x0-x7 args, x0-x1 returns, x0-x17 caller-save
- Key insight from Go: regspec is computed DYNAMICALLY per-call via AuxCall.Reg()

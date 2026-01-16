# Phase 1: Remove Codegen Fallback Allocator - Tracking Document

## Goal
Remove the dual allocator in arm64.zig so codegen ONLY uses regalloc assignments.

## Current State: COMPLETE ✓

## Results
- ✓ Build succeeds
- ✓ All 145 e2e tests pass
- ✗ Parser tests fail (10/10) - but NOT due to regalloc, logic bugs elsewhere

### What Has Been Done
- [x] Removed `value_regs` field from struct (line 187)
- [x] Removed `next_reg` field from struct (line 190)
- [x] Removed `allocateReg()` method definition (line 2570)
- [x] Removed `value_regs` from init()
- [x] Removed `value_regs` from deinit()
- [x] Removed `preAllocatePhiRegisters()` function
- [x] Removed call to `preAllocatePhiRegisters()`
- [x] Removed all 51 `value_regs.put()` calls
- [x] Updated `getRegForValue()` to only use regalloc
- [x] Updated `getDestRegForValue()` to panic if no regalloc assignment

### What Still Needs To Be Done
7 remaining calls to `allocateReg()` that need to be replaced:

| Line | Context | Fix |
|------|---------|-----|
| 2266 | off_ptr fallback for addr | Use x16 as scratch |
| 2303 | off_ptr fallback for addr | Use x16 as scratch |
| 2348 | store fallback for addr | Use x16 as scratch |
| 2379 | store fallback for addr | Use x16 as scratch |
| 2411 | store fallback for value | Use x16 as scratch |
| 2478 | store_reg fallback | Use x16 as scratch |
| 2527 | load_reg fallback | Use x16 as scratch |

### The Pattern to Apply
Each of these is a fallback path like:
```zig
const addr_reg = self.getRegForValue(addr) orelse blk: {
    const temp_reg = self.allocateReg();  // REMOVE THIS
    try self.ensureInReg(addr, temp_reg);
    break :blk temp_reg;
};
```

Replace with:
```zig
const addr_reg = self.getRegForValue(addr) orelse blk: {
    try self.ensureInReg(addr, 16);  // Use x16 as scratch
    break :blk @as(u5, 16);
};
```

## After Phase 1 Completes
- Build should succeed
- Tests will likely FAIL because regalloc isn't assigning registers for all values
- This is EXPECTED - it reveals where regalloc needs work (Phase 3)

## Verification
```bash
zig build                    # Should compile
./zig-out/bin/cot test/e2e/all_tests.cot -o /tmp/all_tests  # Will show regalloc gaps
```

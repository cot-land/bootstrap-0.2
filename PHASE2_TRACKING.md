# Phase 2: Implement Schedule Pass - Tracking Document

## Goal
Establish deterministic value order BEFORE regalloc (Go's pattern).

## Reference
`~/learning/go/src/cmd/compile/internal/ssa/schedule.go`

## Tasks
- [x] Study Go's schedule.go implementation
- [x] Create src/ssa/passes/schedule.zig
- [x] Implement priority scoring (ScorePhi, ScoreArg, ScoreDefault, ScoreControl)
- [x] Sort values within each block by score
- [x] Add memory ordering edges (store -> load dependencies)
- [x] Preserve original order as tiebreaker (Go's pattern)
- [x] Wire into driver.zig pipeline BEFORE regalloc
- [x] Verify build succeeds
- [x] Verify all 145 e2e tests pass

## Status: COMPLETE ✓

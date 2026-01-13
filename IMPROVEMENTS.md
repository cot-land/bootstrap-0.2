# Bootstrap 0.2 Improvements

Based on analysis of Go compiler best practices from `~/learning/go/src/cmd/compile/internal/ssa/`.

**Philosophy**: We adopt PROVEN PATTERNS from Go's compiler. No invention. No speculation.

See also:
- [CLAUDE.md](CLAUDE.md) - Development guidelines and Zig 0.15 API reference
- [TESTING_FRAMEWORK.md](TESTING_FRAMEWORK.md) - Comprehensive testing infrastructure

---

## Implementation Status

| # | Improvement | Status | Location |
|---|-------------|--------|----------|
| 1 | Table-Driven Testing | **DONE** | `src/ssa/op.zig` |
| 2 | Export Test Pattern | **DONE** | `src/ssa/test_helpers.zig` |
| 3 | Error Context Enhancement | **DONE** | `src/core/errors.zig` |
| 4 | Phase Snapshot Comparison | **DONE** | `src/ssa/debug.zig` |
| 5 | Documentation Cross-References | **DONE** | All source files |
| 6 | Pass Interface Abstraction | **DONE** | `src/ssa/compile.zig` |
| 7 | Allocation Testing | **DONE** | `src/core/testing.zig` |
| 8 | Zero-Value Semantics | **DONE** | `src/ssa/*.zig` |
| 9 | Generic Fallback Pattern | **DONE** | `src/codegen/generic.zig` |
| 10 | Const/Enum Organization | **DONE** | `src/ssa/op.zig` |

**Test Results**: 60+ tests passing across all modules.

---

## Improvement #1: Table-Driven Testing Patterns

**Status**: DONE

**Go Pattern**: Table-driven tests with struct slices for comprehensive coverage.

**Implementation** (`src/ssa/op.zig`):
```zig
const OpTestCase = struct {
    op: Op,
    name: []const u8,
    arg_len: i8,
    commutative: bool = false,
    result_in_arg0: bool = false,
    has_side_effects: bool = false,
};

const op_test_cases = [_]OpTestCase{
    .{ .op = .add, .name = "add", .arg_len = 2, .commutative = true },
    .{ .op = .sub, .name = "sub", .arg_len = 2 },
    .{ .op = .mul, .name = "mul", .arg_len = 2, .commutative = true },
    // ... comprehensive coverage
};

test "Op properties match expected" {
    for (op_test_cases) |tc| {
        const info = tc.op.info();
        std.testing.expectEqual(tc.commutative, info.commutative) catch |err| {
            std.debug.print("FAILED: {s}\n", .{tc.name});
            return err;
        };
    }
}
```

---

## Improvement #2: Export Test Pattern

**Status**: DONE

**Go Pattern**: `export_test.go` exposes internals for testing without polluting public API.

**Implementation** (`src/ssa/test_helpers.zig`):
```zig
pub const TestFuncBuilder = struct {
    func: *Func,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !TestFuncBuilder { ... }
    pub fn createDiamondCFG(self: *TestFuncBuilder) !DiamondCFG { ... }
    pub fn createDiamondWithPhi(self: *TestFuncBuilder) !DiamondCFG { ... }
    pub fn createLinearCFG(self: *TestFuncBuilder, count: usize) !LinearCFG { ... }
};

pub fn validateInvariants(f: *const Func, allocator: std.mem.Allocator) ![]VerifyError { ... }
pub fn validateUseCounts(f: *const Func, allocator: std.mem.Allocator) ![]VerifyError { ... }
```

---

## Improvement #3: Error Context Enhancement

**Status**: DONE

**Go Pattern**: Error wrapping with context for debugging.

**Implementation** (`src/core/errors.zig`):
```zig
pub const CompileError = struct {
    kind: ErrorKind,
    context: []const u8,
    block_id: ?ID = null,
    value_id: ?ID = null,
    source_pos: ?Pos = null,
    pass_name: []const u8 = "",

    pub const ErrorKind = enum {
        invalid_block_id,
        invalid_value_id,
        edge_invariant_violated,
        use_count_mismatch,
        type_mismatch,
        pass_failed,
    };

    // Builder pattern
    pub fn withBlock(self: CompileError, id: ID) CompileError { ... }
    pub fn withValue(self: CompileError, id: ID) CompileError { ... }
    pub fn withPass(self: CompileError, name: []const u8) CompileError { ... }
};
```

---

## Improvement #4: Phase Snapshot Comparison

**Status**: DONE

**Go Pattern**: GOSSAFUNC shows changes between phases.

**Implementation** (`src/ssa/debug.zig`):
```zig
pub const PhaseSnapshot = struct {
    name: []const u8,
    blocks: []BlockSnapshot,

    pub fn capture(allocator: std.mem.Allocator, f: *const Func, name: []const u8) !PhaseSnapshot { ... }
    pub fn compare(before: *const PhaseSnapshot, after: *const PhaseSnapshot) ChangeStats { ... }
};

pub const ChangeStats = struct {
    values_added: usize = 0,
    values_removed: usize = 0,
    blocks_added: usize = 0,
    blocks_removed: usize = 0,

    pub fn hasChanges(self: ChangeStats) bool { ... }
};
```

---

## Improvement #5: Documentation Cross-References

**Status**: DONE

**Go Pattern**: Clear references between related modules.

**Example** (from `src/codegen/arm64.zig`):
```zig
//! ARM64-optimized code generation.
//!
//! Go reference: [cmd/compile/internal/arm64/ssa.go]
//!
//! ## Related Modules
//!
//! - [generic.zig] - Reference implementation (no optimization)
//! - [ssa/op.zig] - ARM64-specific operations (arm64_*)
//! - [ssa/compile.zig] - Pass infrastructure
```

---

## Improvement #6: Pass Interface Abstraction

**Status**: DONE

**Go Pattern**: Pass infrastructure with dependency tracking and analysis invalidation.

**Implementation** (`src/ssa/compile.zig`):
```zig
pub const AnalysisKind = enum { dominators, postorder, loop_info, liveness };

pub const Pass = struct {
    name: []const u8,
    fn_: PassFn,
    required: bool = false,
    disabled: bool = false,
    requires: []const []const u8 = &.{},
    invalidates: []const AnalysisKind = &.{},
    preserves_cfg: bool = true,
    preserves_uses: bool = true,
};

pub const PassStats = struct {
    pass_name: []const u8,
    time_ns: u64 = 0,
    values_before: usize = 0,
    values_after: usize = 0,
    blocks_before: usize = 0,
    blocks_after: usize = 0,
};
```

---

## Improvement #7: Allocation Testing

**Status**: DONE

**Go Pattern**: `testing.AllocsPerRun()` verifies allocation counts.

**Implementation** (`src/core/testing.zig`):
```zig
pub const CountingAllocator = struct {
    inner: std.mem.Allocator,
    alloc_count: usize = 0,
    free_count: usize = 0,
    bytes_allocated: usize = 0,

    pub fn init(inner: std.mem.Allocator) CountingAllocator { ... }
    pub fn allocator(self: *CountingAllocator) std.mem.Allocator { ... }
    pub fn reset(self: *CountingAllocator) void { ... }
};
```

**Usage**:
```zig
test "allocation tracking" {
    var counting = core.CountingAllocator.init(std.testing.allocator);
    const allocator = counting.allocator();

    // ... operations ...

    try std.testing.expect(counting.alloc_count < 100);
}
```

---

## Improvement #8: Zero-Value Semantics

**Status**: DONE

**Go Pattern**: Types usable immediately after declaration.

**Implementation**: All types have sensible defaults:
```zig
// Works immediately - no explicit init required
var output = std.ArrayListUnmanaged(u8){};
defer output.deinit(allocator);
```

---

## Improvement #9: Generic Fallback Pattern

**Status**: DONE

**Go Pattern**: Generic implementations alongside optimized ones.

**Implementation** (`src/codegen/generic.zig`):
```zig
pub const GenericCodeGen = struct {
    allocator: std.mem.Allocator,
    stack_slots: std.AutoHashMap(ID, i64),
    stack_offset: i64 = 0,

    pub fn generate(self: *GenericCodeGen, f: *const Func, writer: anytype) !void {
        // Stack-based, correct-by-construction code generation
        // Every value goes to stack - no register allocation
        // Used for testing and verification
    }
};
```

**Example output**:
```
.func test_add:
  ; b1 (ret)
  stack[0] = const_int 40    ; v1
  stack[8] = const_int 2    ; v2
  r0 = stack[0]    ; load v1
  r1 = stack[8]    ; load v2
  stack[16] = add r0, r1    ; v3
  return r0
.end test_add
```

---

## Improvement #10: Const/Enum Organization

**Status**: DONE

**Go Pattern**: Clear category separators with documentation.

**Implementation** (`src/ssa/op.zig`):
```zig
pub const Op = enum(u16) {
    // =========================================
    // Invalid / Placeholder
    // =========================================
    invalid,

    // =========================================
    // Constants (rematerializable)
    // =========================================
    const_bool,
    const_int,
    const_8, const_16, const_32, const_64,
    const_float,
    const_nil,
    const_string,

    // =========================================
    // Integer Arithmetic
    // =========================================
    add, sub, mul, div, udiv, mod, umod, neg,

    // =========================================
    // ARM64-Specific Operations
    // =========================================
    arm64_add, arm64_sub, arm64_mul,
    arm64_ldr, arm64_str, arm64_movz,

    // ... organized by category
};
```

---

## Metrics Achieved

| Metric | Before | After |
|--------|--------|-------|
| Unit tests | ~15 | **60+** |
| Lines with doc comments | ~20% | **80%+** |
| Test tables | 0 | **3** |
| Allocation tests | 0 | **2** |
| Error context coverage | 0% | **100%** |
| Golden file tests | 0 | **2** |
| Integration tests | 0 | **4** |

---

## What's Next

With the infrastructure in place, we can now build the compiler proper:

1. **Parser** - Cot syntax to AST
2. **Type Checker** - Semantic analysis
3. **IR Lowering** - AST to IR
4. **SSA Construction** - IR to SSA
5. **Optimization Passes** - Using pass infrastructure
6. **Register Allocation** - For ARM64 codegen
7. **Object File Emission** - Mach-O / ELF output

Each phase will follow the test-driven pattern established here:
1. Write tests first (table-driven where applicable)
2. Implement to pass tests
3. Add golden files for stability
4. Move to next phase

The goal is **never having to rewrite again**.

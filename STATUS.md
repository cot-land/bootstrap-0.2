# Bootstrap 0.2 - Project Status

**Last Updated: 2026-01-14**

## Executive Summary

Bootstrap-0.2 is a clean-slate rewrite of the Cot compiler following Go's proven compiler architecture. The goal is to eliminate the "whack-a-mole" debugging pattern that killed previous attempts.

**Current State:** Phase 8 NEARLY COMPLETE. All core language features working, Fibonacci compiles correctly!

### Recent Milestones (2026-01-14)
- ✅ `fn main() i64 { return 42; }` compiles and runs correctly
- ✅ `fn main() i64 { return 20 + 22; }` compiles and runs (returns 42)
- ✅ **Function calls work!** `add_one(41)` returns 42
- ✅ Mach-O relocations for inter-function calls
- ✅ ARM64 asm.zig redesigned following Go's parameterized patterns
- ✅ **Local variables work!** `let x: i64 = 42; return x;`
- ✅ **Comparisons work!** `==, !=, <, <=, >, >=` with CMP + CSET
- ✅ **Conditionals work!** `if 1 == 2 { return 0; } else { return 42; }`
- ✅ **While loops with phi nodes work!** Variable mutation in loops now supported
- ✅ **Fibonacci compiles and returns 55!** (10th Fibonacci number)
- ✅ Parallel copy algorithm for phi moves prevents register clobbering
- ✅ Go-inspired iterative phi insertion using work list pattern
- ✅ **Nested function calls work!** Register allocator properly spills values across calls
- ✅ Complete rewrite of regalloc following Go's Use linked list + nextCall pattern
- ✅ Debug infrastructure with COT_DEBUG environment variable (zero-cost when disabled)

---

## Completed Components

### Backend (Phases 0-5) - COMPLETE

| Phase | Component | Location | Status |
|-------|-----------|----------|--------|
| 0 | SSA Value/Block/Func | `src/ssa/` | Done |
| 0 | SSA Op definitions | `src/ssa/op.zig` | Done |
| 0 | Dominator tree | `src/ssa/dom.zig` | Done |
| 0 | Pass infrastructure | `src/ssa/compile.zig` | Done |
| 1 | Liveness analysis | `src/ssa/liveness.zig` | Done |
| 2 | Register allocator | `src/ssa/regalloc.zig` | Done |
| 3 | Lowering pass | `src/ssa/passes/lower.zig` | Done |
| 4 | Generic codegen | `src/codegen/generic.zig` | Done |
| 4 | ARM64 codegen | `src/codegen/arm64.zig` | Done |
| 5 | Mach-O writer | `src/obj/macho.zig` | Done |

### Frontend (Phase 6) - COMPLETE

| Component | Location | Lines | Status |
|-----------|----------|-------|--------|
| Token system | `src/frontend/token.zig` | ~400 | Done |
| Source/Position | `src/frontend/source.zig` | ~200 | Done |
| Error handling | `src/frontend/errors.zig` | ~250 | Done |
| Scanner | `src/frontend/scanner.zig` | ~600 | Done |
| AST definitions | `src/frontend/ast.zig` | ~700 | Done |
| Parser | `src/frontend/parser.zig` | ~1200 | Done |
| Type system | `src/frontend/types.zig` | ~500 | Done |
| Type checker | `src/frontend/checker.zig` | ~1400 | Done |
| IR definitions | `src/frontend/ir.zig` | ~1300 | Done |
| AST lowering | `src/frontend/lower.zig` | ~800 | Done |
| IR→SSA builder | `src/frontend/ssa_builder.zig` | ~700 | Done |

### Testing Infrastructure - COMPLETE

- **185+ tests passing** as of 2026-01-14
- Table-driven tests for comprehensive coverage
- Golden file infrastructure ready
- Allocation tracking with CountingAllocator
- End-to-end pipeline test: Parse → Check → Lower → SSA

---

## Remaining Work

### Phase 7: End-to-End Integration ✅ COMPLETE

| Task | Status |
|------|--------|
| Connect frontend IR to SSA backend | ✅ Done |
| Compile simple function (`return 42`) | ✅ Done |
| Run compiled binary | ✅ Done |
| Verify correct output | ✅ Done |
| Port bootstrap test cases | TODO |

### Phase 8: Language Expansion (Current)

| Task | Status |
|------|--------|
| Function calls with ABI | ✅ DONE |
| Local variables (let/var/const) | ✅ DONE |
| Comparison operators (==, !=, <, <=, >, >=) | ✅ DONE |
| Conditionals (if/else) | ✅ DONE |
| Simple while loops (no variable mutation) | ✅ DONE |
| While loops with variable mutation | ✅ DONE (phi nodes implemented) |
| Parallel copy for phi moves | ✅ DONE |
| Structs | TODO |

### Phase 9: Self-Hosting

| Task | Status |
|------|--------|
| Compiler compiles simple .cot | ✅ Done |
| Compiler compiles fibonacci | ✅ DONE (returns 55 correctly!) |
| Compiler compiles scanner.cot | TODO |
| Compiler compiles itself | TODO |

---

## Architecture

```
Source → Scanner → Parser → AST
                              ↓
                         Type Checker
                              ↓
                         Lowerer → IR
                              ↓
                         SSABuilder → SSA Func
                              ↓
                    Passes (lower, regalloc)
                              ↓
                         Codegen → Machine Code
                              ↓
                         Object Writer → .o file
                              ↓
                         Linker (zig cc) → Executable
```

### Debug Infrastructure

Set `COT_DEBUG` environment variable to trace pipeline:

```bash
# Trace all phases
COT_DEBUG=all ./zig-out/bin/cot input.cot -o output

# Trace specific phases
COT_DEBUG=parse,lower,ssa ./zig-out/bin/cot input.cot -o output
```

Available phases: `parse`, `check`, `lower`, `ssa`, `regalloc`, `codegen`

---

## File Structure

```
bootstrap-0.2/
├── src/
│   ├── main.zig              # Entry point, CLI
│   ├── driver.zig            # Compilation pipeline orchestration
│   ├── pipeline_debug.zig    # Debug infrastructure (COT_DEBUG)
│   │
│   ├── core/                 # Foundation
│   │   ├── types.zig         # ID, TypeInfo, RegMask
│   │   ├── errors.zig        # Error types
│   │   └── testing.zig       # Test utilities
│   │
│   ├── ssa/                  # SSA representation
│   │   ├── value.zig         # SSA values
│   │   ├── block.zig         # Basic blocks
│   │   ├── func.zig          # SSA function
│   │   ├── op.zig            # Operations
│   │   ├── dom.zig           # Dominators
│   │   ├── compile.zig       # Pass infrastructure
│   │   ├── debug.zig         # Debug output
│   │   ├── test_helpers.zig  # Test fixtures
│   │   ├── liveness.zig      # Liveness analysis
│   │   ├── regalloc.zig      # Register allocator
│   │   ├── stackalloc.zig    # Stack slot assignment
│   │   └── passes/
│   │       └── lower.zig     # Lowering pass
│   │
│   ├── codegen/              # Code generation
│   │   ├── generic.zig       # Reference implementation
│   │   └── arm64.zig         # ARM64 codegen
│   │
│   ├── arm64/                # ARM64 specifics
│   │   └── asm.zig           # Instruction encoding
│   │
│   ├── obj/                  # Object output
│   │   └── macho.zig         # Mach-O format
│   │
│   └── frontend/             # Frontend
│       ├── token.zig         # Token types
│       ├── source.zig        # Source positions
│       ├── errors.zig        # Error handling
│       ├── scanner.zig       # Lexer
│       ├── ast.zig           # AST nodes
│       ├── parser.zig        # Parser
│       ├── types.zig         # Type system
│       ├── checker.zig       # Type checker
│       ├── ir.zig            # IR definitions
│       ├── lower.zig         # AST to IR
│       └── ssa_builder.zig   # IR to SSA
│
├── test/
│   ├── golden/               # Golden file snapshots
│   ├── cases/                # Directive tests
│   └── integration/          # Cross-module tests
│
├── CLAUDE.md                 # Development guidelines
├── STATUS.md                 # This file
├── REGISTER_ALLOC.md         # Go's regalloc algorithm
├── DATA_STRUCTURES.md        # Go-to-Zig translations
└── TESTING_FRAMEWORK.md      # Testing infrastructure
```

---

## Key Design Decisions

1. **Go-Influenced Architecture**: Following Go 1.22's compiler patterns with pragmatic simplifications
2. **Index-Based IR**: Using indices instead of pointers (better for self-hosting, no GC needed)
3. **FwdRef Pattern**: Go's deferred phi insertion for correct SSA construction
4. **Type Interning**: TypeRegistry with indices for efficient type comparison
5. **Arena Allocation**: Using Zig 0.15's ArrayListUnmanaged pattern
6. **Pipeline Debugging**: Go-inspired phase tracing via environment variable
7. **Parameterized Encoding**: Following Go's `opldpstp()` pattern - related instructions share ONE function with explicit parameters for critical bits

### Lesson Learned: Parameterized Encoding (2026-01-14)

We had a bug where `encodeLDPPost` emitted STP (store) instead of LDP (load) because we forgot to set bit 22. This corrupted the stack and caused crashes.

**Root cause:** We wrote separate functions for LDP and STP, making it easy to forget a bit.

**Go's solution:** One function `opldpstp()` with an explicit `ldp` parameter:
```go
// Go: impossible to forget the load/store bit
o1 = c.opldpstp(p, o, v, rf, rt1, rt2, 1)  // 1 = load
o1 = c.opldpstp(p, o, v, rt, rf1, rf2, 0)  // 0 = store
```

**Our fix:** Rewrote `asm.zig` with parameterized functions:
```zig
// New: explicit is_load parameter makes it impossible to forget
pub fn encodeLdpStp(..., is_load: bool) u32 {
    const load_bit: u32 = if (is_load) 1 else 0;
    return ... | (load_bit << 22) | ...;
}
```

**Lesson:** When encoding instructions, related variants should share ONE function with explicit parameters. Never trust implicit defaults for critical bits.

### Lesson Learned: Phi Insertion and Parallel Copy (2026-01-14)

Implementing proper phi insertion for loops with variable mutation required two key insights from Go:

**1. Iterative FwdRef Resolution:**
Instead of a single pass, use a work list that processes FwdRef values iteratively. When resolving a FwdRef creates a new phi that needs more arguments, those new FwdRefs are added to the work list. This naturally handles complex control flow.

**2. Parallel Copy Algorithm:**
When multiple phi nodes need to be resolved at block boundaries, naive sequential moves can clobber registers. If phi1 writes to x1 and phi2 reads from x1, emitting phi1's move first destroys phi2's source.

**Solution:** Two-phase parallel copy:
```zig
// Phase 1: Save conflicting sources to temp registers
for (moves) |m| if (m.needs_temp) emit(mov temp, m.src);
// Phase 2: Emit actual moves (from temps or sources)
for (moves) |m| emit(mov m.dest, m.temp_or_src);
```

**Result:** Fibonacci now compiles correctly, returning 55 (10th Fibonacci number).

### Lesson Learned: Register Allocator LoadReg Integration (2026-01-14)

When a value is spilled before a call and later reloaded, we create a `load_reg` SSA value that represents the reloaded value. Initially we made the mistake of assigning the register to the original value, not the load_reg.

**The bug:**
```zig
// WRONG: Assigned register to original value v3, not to load_reg v12
fn loadValue(self: *Self, v: *Value, block: *Block) void {
    const load = self.f.newValue(.load_reg, ...);
    self.assignReg(v, reg);  // BUG: v has no register after this!
}
```

**What happened:** When codegen asked for v12's register, it found nothing (regs mask=0x0) and fell back to naive allocation.

**The fix:**
```zig
// CORRECT: Assign register to the load_reg value and update control references
fn loadValue(self: *Self, v: *Value, block: *Block) *Value {
    const load = self.f.newValue(.load_reg, ...);
    self.assignReg(load, reg);  // The load_reg has the register
    return load;                 // Return so caller can update references
}

// Caller updates block control to point to load_reg
const loaded = try self.loadValue(ctrl, block);
if (loaded != ctrl) block.setControl(loaded);
```

**Key insight:** The `load_reg` instruction is what produces the value in the register. The original value (v3) is still "in memory" via its spill slot. All references that need the register value must use the load_reg.

### Lesson Learned: Regalloc Value Ordering and Arg Updates (2026-01-14)

Implementing proper register allocation for recursive functions (fibonacci) revealed several critical issues:

**1. ARM64 LDR/STR Offset Scaling:**
ARM64 LDR/STR with unsigned immediate scales the offset by operand size. For 64-bit operations, the encoding expects `offset/8`, not the raw byte offset.
```zig
// WRONG: Passing byte offset directly
const spill_off: u12 = @intCast(loc.stackOffset());  // 16 bytes
// Encodes as [sp, #128] because 16*8 = 128!

// CORRECT: Scale for 64-bit operand
const byte_off = loc.stackOffset();
const spill_off: u12 = @intCast(@divExact(byte_off, 8));  // Now encodes as [sp, #16]
```

**2. Instruction Ordering with Spills/Loads:**
Spills and loads must be inserted at the correct position in the instruction stream, not appended to the end of the block.
```zig
// WRONG: Appending to end - spills/loads happen after values that need them
try block.values.append(self.allocator, load);

// CORRECT: Build a new list with correct ordering
var new_values = std.ArrayListUnmanaged(*Value){};
// Insert loads BEFORE the value that needs the loaded arg
// Insert spills BEFORE the call instruction
```

**3. Updating Value Args to Point to Reloads:**
When a spilled value is reloaded, the value that uses it must have its arg updated to point to the `load_reg`, not the original value.
```zig
// WRONG: Original arg still points to spilled value
const loaded = try self.loadValue(arg, block);  // Created load_reg
// But v.args[i] still points to original, which has stale register

// CORRECT: Update arg to point to reload
const loaded = try self.loadValue(arg, block);
if (loaded != arg) {
    v.args[i] = loaded;  // Now points to load_reg with valid register
}
```

**4. Pending Spills from allocReg:**
When `loadValue` calls `allocReg` and allocReg needs to spill a value to free a register, that spill must also be inserted at the correct position.
```zig
// Track spills that occur during allocation
pending_spills: std.ArrayListUnmanaged(*Value) = .{},

// In allocReg, add spills to pending list
if (try self.spillReg(reg, block)) |spill| {
    try self.pending_spills.append(self.allocator, spill);
}

// In allocBlock, drain pending spills before inserting loads
for (self.pending_spills.items) |spill| {
    try new_values.append(self.allocator, spill);
}
self.pending_spills.clearRetainingCapacity();
```

**Result:** Fibonacci now returns correct result (55) with proper spill/reload ordering.

### Go Divergences (Intentional)

| Go Feature | Our Decision | Rationale |
|------------|--------------|-----------|
| Walk/Order phase | Deferred | Add when we need expression optimization |
| Escape analysis | Deferred | Add when we need stack allocation |
| 30 SSA passes | Minimal | Add incrementally for performance |
| Pointer-based nodes | Index-based | Better for self-hosting without GC |

---

## Success Criteria

Bootstrap-0.2 succeeds when:

1. **Frontend pipeline works** - Parse → Check → Lower → SSA
2. **Backend pipeline works** - SSA → Lowered → RegAlloc → Codegen → Object
3. **End-to-end works** - Compile and run simple programs
4. **Self-hosting works** - Compiler compiles itself

---

## Running Tests

```bash
# Fast unit tests (run frequently)
zig build test

# All tests including integration
zig build test-all

# Golden file tests only
zig build test-golden

# Update golden files after intentional changes
COT_UPDATE_GOLDEN=1 zig build test-golden
```

---

## References

- Go compiler: `~/learning/go/src/cmd/compile/`
- Bootstrap (reference): `~/cot-land/bootstrap/src/`
- See also: [CLAUDE.md](CLAUDE.md), [REGISTER_ALLOC.md](REGISTER_ALLOC.md)

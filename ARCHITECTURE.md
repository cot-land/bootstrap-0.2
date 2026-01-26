# Compiler Architecture

## Overview

The Cot compiler follows Go's `cmd/compile` architecture, translated to Zig (reference implementation) and Cot (self-hosting target).

```
Source Code (.cot)
       │
       ▼
┌──────────────────┐
│    Scanner       │  Tokenizes source into tokens
│  (scanner.zig)   │  Go: cmd/compile/internal/syntax/scanner.go
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│    Parser        │  Builds AST from tokens
│  (parser.zig)    │  Go: cmd/compile/internal/syntax/parser.go
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  Type Checker    │  Type inference and validation
│  (checker.zig)   │  Go: cmd/compile/internal/types2/
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│    Lowering      │  AST → IR (intermediate representation)
│   (lower.zig)    │  Go: cmd/compile/internal/ssagen/
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  SSA Builder     │  IR → SSA form
│(ssa_builder.zig) │  Go: cmd/compile/internal/ssa/
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│   Liveness       │  Live variable analysis
│ (liveness.zig)   │  Go: cmd/compile/internal/ssa/
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ Register Alloc   │  Linear scan allocation
│ (regalloc.zig)   │  Go: cmd/compile/internal/ssa/regalloc.go
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│   Code Gen       │  SSA → ARM64 machine code
│   (arm64.zig)    │  Go: cmd/compile/internal/ssa/gen/ARM64.go
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  Object Writer   │  Machine code → Mach-O object file
│   (macho.zig)    │  Go: cmd/link/internal/ld/macho.go
└────────┬─────────┘
         │
         ▼
Object File (.o)
```

## Directory Structure

```
src/                          stages/cot1/
├── main.zig                  ├── main.cot
├── driver.zig                │
├── frontend/                 ├── frontend/
│   ├── token.zig             │   ├── token.cot
│   ├── scanner.zig           │   ├── scanner.cot
│   ├── ast.zig               │   ├── ast.cot
│   ├── parser.zig            │   ├── parser.cot
│   ├── types.zig             │   ├── types.cot
│   ├── checker.zig           │   ├── checker.cot
│   ├── ir.zig                │   ├── ir.cot
│   ├── lower.zig             │   ├── lower.cot
│   └── ssa_builder.zig       │   └── builder.cot
├── ssa/                      ├── ssa/
│   ├── op.zig                │   ├── op.cot
│   ├── value.zig             │   ├── value.cot
│   ├── block.zig             │   ├── block.cot
│   ├── func.zig              │   ├── func.cot
│   ├── liveness.zig          │   ├── liveness.cot
│   └── regalloc.zig          │   └── regalloc.cot
├── codegen/                  ├── codegen/
│   └── arm64.zig             │   ├── arm64.cot
│                             │   └── genssa.cot
├── arm64/                    ├── arm64/
│   └── asm.zig               │   ├── asm.cot
│                             │   └── regs.cot
├── obj/                      └── obj/
│   └── macho.zig                 ├── macho.cot
└── dwarf.zig                     └── dwarf.cot
```

## Key Data Structures

### SSA Value

Represents a single computation in SSA form:

```
Value {
    id: u32           // Unique identifier
    op: Op            // Operation type (Add, Load, Call, etc.)
    type: Type        // Result type
    args: []Value     // Input values
    block: *Block     // Containing block
    reg: ?Register    // Allocated register (after regalloc)
    pos: u32          // Source position (for debug info)
}
```

### SSA Block

Basic block in control flow graph:

```
Block {
    id: u32           // Unique identifier
    values: []Value   // Instructions in this block
    succs: []Block    // Successor blocks
    preds: []Block    // Predecessor blocks
    control: ?Value   // Branch condition (if any)
}
```

### SSA Function

Complete function in SSA form:

```
Func {
    name: []u8
    entry: *Block     // Entry block
    blocks: []Block   // All blocks
    num_values: u32   // Total value count
}
```

## Register Allocation

Uses Go's linear scan algorithm (not graph coloring):

1. **Liveness Analysis**: Compute live-in/live-out sets for each block
2. **Block Allocation**: Greedy assignment with farthest-next-use spilling
3. **Spill Handling**: Insert spills/reloads at optimal points
4. **Edge Fixup**: Handle phi nodes at block boundaries

See [REFERENCE.md](REFERENCE.md) for detailed algorithm.

## Memory Model

### Current (Bootstrap Phase)

Global arrays with malloc/realloc:
- `g_source` - Source code buffer
- `g_code` - Machine code output
- `g_values` - SSA values
- `g_blocks` - SSA blocks
- etc.

### Future (Post Self-Hosting)

Automatic Reference Counting (ARC):
- No manual malloc/free
- Compiler inserts retain/release
- Cycle detection for reference cycles

## DWARF Debug Info

Generated for crash diagnostics:

```
__debug_line    Line number table (address → source location)
__debug_abbrev  Abbreviation definitions
__debug_info    Compilation unit information
```

Uses Go's `putpclcdelta` algorithm for efficient encoding.

## Calling Convention (ARM64)

```
Arguments:   x0-x7 (first 8 args)
Return:      x0
Callee-save: x19-x28, sp, fp
Caller-save: x0-x18, x30 (lr)
Frame ptr:   x29
Link reg:    x30
Stack ptr:   sp
```

## Key Design Decisions

### 1. Copy Don't Invent

Every algorithm comes from Go's production compiler. No novel optimizations, no creative solutions. This ensures correctness through inheritance of 10+ years of testing.

### 2. SSA Everywhere

All optimization and register allocation happens on SSA form. The IR is close to SSA to minimize transformation complexity.

### 3. Linear Scan

Register allocation uses linear scan (not graph coloring) because:
- Simpler to implement correctly
- Good enough performance for bootstrap
- What Go uses

### 4. Mach-O Only

Initial target is macOS ARM64 only. Other targets after self-hosting.

### 5. No Generics (Yet)

Generics deferred until after self-hosting. Current type system is simple: primitives, pointers, arrays, structs, enums, functions.

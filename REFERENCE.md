# Technical Reference

This document consolidates technical details about the compiler's data structures and algorithms. All patterns are copied from Go's `cmd/compile`.

## SSA Data Structures

### Value

Represents a single computation in SSA form.

```
Value {
    id: u32              // Unique ID within function
    op: Op               // Operation type (Add, Load, Call, etc.)
    type_idx: u32        // Result type index
    aux_int: i64         // Integer auxiliary (constants, offsets)
    args: []*Value       // Input values
    block: *Block        // Containing block
    pos: u32             // Source position
    uses: i32            // Reference count
}
```

Go reference: `cmd/compile/internal/ssa/value.go`

### Block

Basic block in control flow graph.

```
Block {
    id: u32              // Unique ID within function
    kind: BlockKind      // Plain, If, Ret
    succs: []Edge        // Successor blocks
    preds: []Edge        // Predecessor blocks
    controls: [2]?*Value // Branch conditions
    values: []*Value     // Instructions in this block
    func: *Func          // Containing function
}
```

Go reference: `cmd/compile/internal/ssa/block.go`

### Func

Complete function in SSA form.

```
Func {
    name: []u8           // Function name
    entry: *Block        // Entry block
    blocks: []*Block     // All blocks in function
    num_values: u32      // Total value count
}
```

Go reference: `cmd/compile/internal/ssa/func.go`

## Register Allocation

Uses Go's linear scan algorithm (not graph coloring).

### Algorithm Overview

1. **Liveness Analysis**: Compute live-in/live-out for each block
2. **Block Allocation**: Greedy allocation with farthest-next-use spilling
3. **Spill Placement**: Insert spills at optimal points
4. **Restore Placement**: Insert reloads where needed
5. **Edge Fixup**: Handle phi nodes at block boundaries

### Per-Value State

```
ValState {
    regs: RegMask        // Registers holding this value
    uses: i32            // Remaining use count
    spill: ?*Value       // Spill instruction if spilled
    spill_used: bool     // Whether spill was actually used
}
```

### Per-Register State

```
RegState {
    v: ?*Value           // Value in this register
    tmp: bool            // Temporary allocation?
}
```

### Spilling Decision

When a register is needed but none are free:
1. Find value with farthest next use
2. Spill that value (create StoreReg to stack)
3. Use freed register

Go reference: `cmd/compile/internal/ssa/regalloc.go`

## ARM64 Calling Convention

```
Arguments:   x0-x7     (first 8 integer/pointer arguments)
Return:      x0        (integer return value)
Callee-save: x19-x28, sp, fp
Caller-save: x0-x18, x30 (lr)
Frame ptr:   x29 (fp)
Link reg:    x30 (lr)
Stack ptr:   sp
Zero reg:    xzr (hardwired zero)
```

### Stack Frame Layout

```
High addresses
    ┌──────────────────┐
    │   Return addr    │  ← caller's LR saved
    ├──────────────────┤
    │   Saved FP       │  ← caller's FP saved
    ├──────────────────┤  ← FP points here
    │  Saved callee    │
    │  save regs       │
    ├──────────────────┤
    │  Spill slots     │
    ├──────────────────┤
    │  Local variables │
    ├──────────────────┤  ← SP points here
Low addresses
```

## DWARF Debug Info

### Line Table Encoding

Uses Go's `putpclcdelta` algorithm for compact encoding.

Constants (DWARF v4):
```
LINE_BASE  = -4      // Minimum line increment
LINE_RANGE = 10      // Range of line increments
OPCODE_BASE = 11     // First special opcode
```

Special opcode formula:
```
opcode = (line_delta - LINE_BASE) + (LINE_RANGE * addr_delta) + OPCODE_BASE
```

If opcode > 255, use DW_LNS_advance_pc followed by special opcode.

Go reference: `cmd/internal/obj/dwarf.go`

### Sections Generated

| Section | Purpose |
|---------|---------|
| `__debug_line` | Address → line number mapping |
| `__debug_abbrev` | Abbreviation table |
| `__debug_info` | Compilation unit info |

## Token Types

```
// Keywords
fn, let, return, if, else, while, for, struct, enum, null, true, false

// Operators
+, -, *, /, %, ==, !=, <, >, <=, >=, =, +=, -=

// Punctuation
(, ), {, }, [, ], ,, :, ;, ->

// Literals
123        // Integer
"hello"    // String
'c'        // Character
```

## Type System

```
Primitive:   i8, i16, i32, i64, u8, u16, u32, u64, bool, void
Pointer:     *T, *const T
Array:       [N]T
Slice:       []T
Function:    fn(T1, T2) -> T3
Struct:      struct { field: T }
Enum:        enum { variant1, variant2 }
```

## Mach-O Object Format

### Load Commands

```
LC_SEGMENT_64    Segment with sections
LC_SYMTAB        Symbol table
LC_DYSYMTAB      Dynamic symbol table
```

### Sections

```
__TEXT,__text        Code section
__DATA,__data        Data section
__DWARF,__debug_*    Debug sections
```

### Relocations

```
ARM64_RELOC_BRANCH26     BL/B instructions (26-bit offset)
ARM64_RELOC_PAGE21       ADRP instruction (21-bit page offset)
ARM64_RELOC_PAGEOFF12    LDR/STR instruction (12-bit page offset)
ARM64_RELOC_UNSIGNED     Absolute 64-bit address
```

## Common Patterns

### Creating an SSA Value

```
fn newValue(block: *Block, op: Op, ty: Type, args: []*Value) *Value {
    const v = allocValue();
    v.id = nextID();
    v.op = op;
    v.type_idx = ty.index;
    v.block = block;
    for (args) |arg| {
        arg.uses += 1;
    }
    v.args = args;
    return v;
}
```

### Building Control Flow

```
// Create blocks
entry = newBlock(.plain);
then_block = newBlock(.plain);
else_block = newBlock(.plain);
exit = newBlock(.plain);

// Connect edges
entry.kind = .If;
entry.succs = [then_block, else_block];
entry.controls[0] = condition;
then_block.succs = [exit];
else_block.succs = [exit];
```

### Instruction Selection

```
switch (v.op) {
    .add => emit ADD reg1, reg2, reg3
    .sub => emit SUB reg1, reg2, reg3
    .load => emit LDR reg, [base, offset]
    .store => emit STR reg, [base, offset]
    .call => emit BL target
    ...
}
```

## See Also

- [ARCHITECTURE.md](ARCHITECTURE.md) - Compiler pipeline overview
- [SYNTAX.md](SYNTAX.md) - Language syntax reference

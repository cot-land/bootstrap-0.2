# cot0 - Self-Hosting Compiler

The Cot compiler written in Cot, targeting self-hosting.

## Status

| Stage | Status |
|-------|--------|
| Stage 1 (Zig builds cot0) | ✅ Working - 166/166 tests pass |
| Stage 2 (cot0-stage1 builds cot0) | ⚠️ Compiles with SSA errors |
| Stage 3+ (self-hosting) | ⚠️ Blocked by stage2 bugs |

See [SELF_HOSTING.md](../SELF_HOSTING.md) for details.

## Structure

Mirrors the Zig compiler (`src/*.zig`):

```
cot0/
├── main.cot              Entry point
├── frontend/
│   ├── token.cot         Token definitions
│   ├── scanner.cot       Lexer
│   ├── ast.cot           AST nodes
│   ├── parser.cot        Parser
│   ├── types.cot         Type system
│   ├── checker.cot       Type checker
│   ├── ir.cot            IR definitions
│   ├── lower.cot         AST → IR
│   └── builder.cot       IR → SSA
├── ssa/
│   ├── op.cot            SSA operations
│   ├── value.cot         SSA values
│   ├── block.cot         Basic blocks
│   ├── func.cot          SSA functions
│   ├── liveness.cot      Liveness analysis
│   └── regalloc.cot      Register allocation
├── codegen/
│   ├── arm64.cot         ARM64 codegen
│   └── genssa.cot        SSA → machine code
├── arm64/
│   ├── asm.cot           Instruction encoding
│   └── regs.cot          Register definitions
└── obj/
    ├── macho.cot         Mach-O writer
    └── dwarf.cot         DWARF debug info
```

## Building

```bash
# Build stage 1 (Zig compiles cot0)
./zig-out/bin/cot cot0/main.cot -o /tmp/cot0-stage1

# Test stage 1
echo 'fn main() i64 { return 42 }' > /tmp/test.cot
/tmp/cot0-stage1 /tmp/test.cot -o /tmp/test.o
zig cc /tmp/test.o -o /tmp/test && /tmp/test
```

## Key Principle

Every function in cot0 must match its Zig counterpart exactly (same name, same logic). Track progress in [COMPARISON.md](COMPARISON.md).

## Documentation

| Document | Purpose |
|----------|---------|
| [COMPARISON.md](COMPARISON.md) | Function parity checklist |
| [../ARCHITECTURE.md](../ARCHITECTURE.md) | Compiler design |
| [../REFERENCE.md](../REFERENCE.md) | Technical reference |
| [../CLAUDE.md](../CLAUDE.md) | Development workflow |

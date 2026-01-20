# Cot0 - Minimal Self-Hosting Compiler

**Stage 0 of the Cot bootstrapping chain.**

---

## CRITICAL: COT0 IS COT

**cot0 IS Cot code.** It is NOT a different language or a "bootstrap hack."

- All cot0 code MUST be valid Cot that compiles with the bootstrap compiler
- Use built-in functions (`print`, `println`) - do NOT redefine them
- Follow SYNTAX.md exactly - no "cot0-specific" conventions
- cot0 is a **simplified subset** of Cot, not a different language

**Rule:** If it wouldn't compile as normal Cot code, it doesn't belong in cot0.

---

## Goal

Write a minimal Cot compiler in Cot that can compile trivial programs.

## Supported Features (cot0 only)

| Feature | Example |
|---------|---------|
| i64 type | `let x: i64 = 42;` |
| Integer literals | `42`, `0xFF`, `0b1010` |
| Arithmetic | `+`, `-`, `*`, `/` |
| Functions | `fn add(a: i64, b: i64) i64 { ... }` |
| Return | `return x + y;` |

## Bootstrap Chain

```
cot0.cot ──compiled by──> Zig compiler ──produces──> cot0 binary
cot1.cot ──compiled by──> cot0 binary  ──produces──> cot1 binary
...
cot9.cot ──compiled by──> cot8 binary  ──produces──> cot9 binary
cot9.cot ──compiled by──> cot9 binary  ──produces──> cot9' (self-hosting!)
```

## File Structure

Mirrors the Zig compiler structure:

```
cot0/
├── README.md           # This file
├── ROADMAP.md          # Self-hosting roadmap and progress
├── frontend/
│   ├── token.cot       # Token definitions
│   ├── token_test.cot  # Tests for token.cot
│   ├── scanner.cot     # Lexer
│   ├── scanner_test.cot
│   ├── ast.cot         # AST node types
│   ├── parser.cot      # Parser
│   ├── types.cot       # Type system
│   ├── checker.cot     # Type checker
│   ├── ir.cot          # Intermediate representation
│   └── lower.cot       # AST to IR lowering
├── ssa/
│   ├── op.cot          # SSA operations
│   ├── value.cot       # SSA values
│   ├── block.cot       # Basic blocks
│   ├── func.cot        # SSA functions
│   └── builder.cot     # IR to SSA conversion
├── codegen/
│   └── arm64.cot       # ARM64 code generation
├── arm64/
│   └── asm.cot         # ARM64 instruction encoding
├── obj/
│   └── macho.cot       # Mach-O object file writer
└── main.cot            # Entry point / driver
```

## Testing Pattern

Following Go's `_test.go` convention:
- Each module `foo.cot` has a corresponding `foo_test.cot`
- Test files import the module and exercise its functions
- Run: `./zig-out/bin/cot cot0/frontend/token_test.cot -o /tmp/test && /tmp/test`

## Stage Progression

| Stage | New Features | Files Affected |
|-------|--------------|----------------|
| cot0 | i64, arithmetic, functions, return | All (minimal) |
| cot1 | + if/else, while, comparisons | parser, checker, lower, codegen |
| cot2 | + local variables, assignment | parser, checker, lower, codegen |
| cot3 | + strings, len(), print | scanner, parser, types, codegen |
| cot4 | + arrays, indexing | parser, types, lower, codegen |
| cot5 | + structs | parser, types, checker, lower |
| cot6 | + pointers, malloc/free | types, lower, codegen |
| cot7 | + switch, enums | parser, lower, codegen |
| cot8 | + imports, file I/O | driver, all |
| cot9 | Full language | Complete self-hosting |

## Verification

Each stage must pass:
1. **Unit tests**: `foo_test.cot` passes for each module
2. **Integration test**: Stage N compiles a test program correctly
3. **Bootstrap test**: Stage N compiles Stage N+1 successfully

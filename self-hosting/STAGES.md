# Self-Hosting Stages: Stage 0 → Stage 10

**Philosophy**: Start with the absolute minimum compiler that can compile itself (Stage 0), then incrementally add features until we reach full parity with the Zig reference compiler (Stage 10).

---

## Stage Overview

| Stage | Goal | Key Features Added |
|-------|------|-------------------|
| **0** | Minimal self-hosting | Core subset: enough to compile cot0 |
| **1** | Usable compiler | Error messages, basic diagnostics |
| **2** | Complete language | All language features |
| **3** | Multi-file support | Imports, modules |
| **4** | x86_64 backend | Cross-platform |
| **5** | Optimizations | Basic opts, dead code elimination |
| **6** | Debug info | DWARF, source maps |
| **7** | Windows support | PE/COFF output |
| **8** | Advanced features | Generics hints, traits prep |
| **9** | Production ready | Performance, polish |
| **10** | Full parity | Everything the Zig compiler has |

---

## Stage 0: Minimal Self-Hosting (THE GOAL)

**Objective**: The smallest possible compiler that can compile itself.

### Language Features Required

These are the features needed to write a compiler in cot:

| Feature | Why Needed | Example |
|---------|-----------|---------|
| **i64, u8, bool** | Basic types | `var count: i64 = 0` |
| **Strings** | Source code, identifiers | `var name: string = "main"` |
| **Arrays [N]T** | Token lists, byte buffers | `var buffer: [256]u8` |
| **Structs** | AST nodes, tokens | `struct Token { kind: u8, ... }` |
| **Enums** | Token types, Op kinds | `enum TokenKind: u8 { plus, minus, ... }` |
| **Pointers *T** | Tree structures | `var left: *Node` |
| **Functions** | All compiler passes | `fn parse() *AST` |
| **If/else/while** | Control flow | Standard control flow |
| **Logical ops** | Conditions | `if a and b { ... }` |
| **Bitwise ops** | Flags, instruction encoding | `inst = op | (rd << 5)` |

### Compiler Components for Stage 0

```
┌─────────────────────────────────────────────────────────────┐
│                      STAGE 0 COMPILER                       │
├─────────────────────────────────────────────────────────────┤
│  scanner_s0.cot    - Tokenize cot source                    │
│  parser_s0.cot     - Build AST (minimal node types)         │
│  checker_s0.cot    - Type checking (minimal)                │
│  ir_s0.cot         - IR definitions                         │
│  lower_s0.cot      - AST → IR                               │
│  ssa_s0.cot        - SSA value/block/func types             │
│  ssagen_s0.cot     - IR → SSA                               │
│  regalloc_s0.cot   - Register allocation                    │
│  codegen_s0.cot    - SSA → ARM64 machine code               │
│  object_s0.cot     - Mach-O output                          │
│  main_s0.cot       - Entry point, CLI                       │
└─────────────────────────────────────────────────────────────┘
```

### What Stage 0 Does NOT Have

- ❌ Good error messages (just "error" or crash)
- ❌ x86_64 support (ARM64 only)
- ❌ Windows support
- ❌ Optimizations
- ❌ Debug info
- ❌ Tagged unions
- ❌ Generics
- ❌ Optional types
- ❌ For-in loops (use while)
- ❌ Import system (single file or concatenated)

### Success Criteria

```bash
# Stage 0 is complete when:
./cot0 self-hosting/stage0/*.cot -o cot0_new
./cot0_new self-hosting/stage0/*.cot -o cot0_new2
diff cot0_new cot0_new2  # Identical binaries!
```

---

## Stage 1: Usable Compiler

**Objective**: Add enough polish that developers can actually use it.

### Features Added

| Feature | Description |
|---------|-------------|
| **Error messages** | Line numbers, context, suggestions |
| **Source positions** | Track Span through all phases |
| **Multiple errors** | Continue after first error |
| **Warnings** | Unused variables, etc. |

### New Files

```
errors_s1.cot      - Error reporting system
source_s1.cot      - Position tracking
```

---

## Stage 2: Complete Language

**Objective**: All cot language features.

### Features Added

| Feature | Description |
|---------|-------------|
| **Tagged unions** | `union Result { ok: T, err: string }` |
| **Optional types** | `?T`, null coalescing `??` |
| **Slices** | `[]T`, dynamic views into arrays |
| **For-in loops** | `for item in items { ... }` |
| **Switch** | Pattern matching on enums/unions |
| **Defer** | Cleanup on scope exit |
| **Compound assign** | `+=`, `-=`, `*=`, `/=` |

---

## Stage 3: Multi-File Support

**Objective**: Real projects with multiple files.

### Features Added

| Feature | Description |
|---------|-------------|
| **Import** | `import "file.cot"` |
| **Transitive imports** | Import chains resolved |
| **Duplicate detection** | Don't import same file twice |
| **Global constants** | `const MAX = 100` |

---

## Stage 4: x86_64 Backend

**Objective**: Cross-platform compilation.

### New Files

```
codegen_x64_s4.cot  - x86_64 code generation
amd64_s4.cot        - x86_64 instruction encoding
elf_s4.cot          - ELF object file format
```

### Features Added

- Linux support via ELF
- Cross-compilation from ARM64 Mac to Linux x86_64

---

## Stage 5: Optimizations

**Objective**: Generated code is efficient.

### Optimizations Added

| Optimization | Description |
|--------------|-------------|
| **Dead code elimination** | Remove unused values |
| **Constant folding** | `2 + 3` → `5` at compile time |
| **Copy propagation** | Eliminate redundant copies |
| **Strength reduction** | `x * 2` → `x << 1` |
| **Common subexpr** | Reuse computed values |

---

## Stage 6: Debug Info

**Objective**: Debuggers can step through cot code.

### Features Added

| Feature | Description |
|---------|-------------|
| **DWARF output** | Debug info for lldb/gdb |
| **Source maps** | Map machine code to source lines |
| **Variable info** | See local variables in debugger |

---

## Stage 7: Windows Support

**Objective**: Native Windows executables.

### New Files

```
pe_coff_s7.cot     - PE/COFF object format
win_s7.cot         - Windows-specific codegen
```

---

## Stage 8: Advanced Features

**Objective**: Prepare for post-bootstrap language features.

### Features Added

| Feature | Description |
|---------|-------------|
| **Comptime hints** | Mark functions as compile-time |
| **Trait prep** | Interface definitions (not impl yet) |
| **Generic hints** | Type parameters (not impl yet) |

---

## Stage 9: Production Ready

**Objective**: Ready for real-world use.

### Polish Added

| Area | Improvements |
|------|--------------|
| **Performance** | Faster compilation |
| **Memory** | Efficient allocator usage |
| **CLI** | Full command-line interface |
| **Help** | `--help`, documentation |

---

## Stage 10: Full Parity

**Objective**: Everything the Zig reference compiler has.

### Full Feature List

- All language features from Zig compiler
- All platforms (ARM64, x86_64, Windows)
- All optimizations
- Full error messages with suggestions
- Debug info
- IDE support (LSP prep)
- Fast compilation
- Small binaries

---

## Implementation Strategy

### Parallel Development

While another Claude session builds out bootstrap-0.2's language features (Tier 2-7), we can:

1. **Design Stage 0 files** - Plan the minimal .cot files
2. **Port frontend from bootstrap** - scanner, parser are reusable
3. **Design new backend** - Match bootstrap-0.2's separated architecture

### File Reuse from bootstrap

These files from `/Users/johnc/cot-land/bootstrap/src/bootstrap/` can be adapted:

| bootstrap file | Stage 0 file | Changes needed |
|---------------|--------------|----------------|
| `token_boot.cot` | `token_s0.cot` | Minimal, mostly reusable |
| `source_boot.cot` | `source_s0.cot` | Minimal, mostly reusable |
| `scanner_boot.cot` | `scanner_s0.cot` | Minimal changes |
| `parser_boot.cot` | `parser_s0.cot` | Simplify for subset |
| `ast_boot.cot` | (inline) | Merge into parser |
| `ir_boot.cot` | `ir_s0.cot` | Redesign for new arch |
| `lower_boot.cot` | `lower_s0.cot` | Adapt to new IR |
| `driver_boot.cot` | `main_s0.cot` | New pass structure |
| `arm64_boot.cot` | `codegen_s0.cot` | Simpler (no regalloc) |
| (none) | `regalloc_s0.cot` | NEW: separate pass |

### New Files Needed

| File | Purpose |
|------|---------|
| `regalloc_s0.cot` | Separate register allocation pass |
| `ssa_s0.cot` | SSA data structures |
| `ssagen_s0.cot` | IR → SSA conversion |
| `liveness_s0.cot` | Liveness analysis |

---

## Dependencies Map

```
              ┌─────────────┐
              │  main_s0    │
              └──────┬──────┘
                     │
         ┌───────────┼───────────┐
         ▼           ▼           ▼
    ┌─────────┐ ┌─────────┐ ┌─────────┐
    │ scanner │ │ parser  │ │ checker │
    └────┬────┘ └────┬────┘ └────┬────┘
         │           │           │
         └───────────┼───────────┘
                     ▼
              ┌─────────────┐
              │   lower     │
              └──────┬──────┘
                     ▼
              ┌─────────────┐
              │   ssagen    │
              └──────┬──────┘
                     ▼
              ┌─────────────┐
              │  regalloc   │
              └──────┬──────┘
                     ▼
              ┌─────────────┐
              │  codegen    │
              └──────┬──────┘
                     ▼
              ┌─────────────┐
              │   object    │
              └─────────────┘
```

---

## Timeline Estimate

| Stage | Effort | Dependencies |
|-------|--------|--------------|
| 0 | 3-5 days | Language Tier 2-5 complete |
| 1 | 1 day | Stage 0 |
| 2 | 2 days | Stage 1 |
| 3 | 1 day | Stage 2 |
| 4 | 2 days | Stage 3 |
| 5 | 2 days | Stage 4 |
| 6 | 2 days | Stage 5 |
| 7 | 2 days | Stage 6 |
| 8 | 1 day | Stage 7 |
| 9 | 2 days | Stage 8 |
| 10 | 1 day | Stage 9 |

**Total: ~20 days from language ready to full parity**

---

## Next Steps

1. Create `stage0/` directory structure
2. Design minimal AST node types needed
3. Design minimal IR operations needed
4. Design minimal SSA operations needed
5. Start porting scanner_boot.cot → scanner_s0.cot

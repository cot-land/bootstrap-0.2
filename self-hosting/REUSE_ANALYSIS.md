# Bootstrap File Reuse Analysis

**Goal**: Identify which files from `/Users/johnc/cot-land/bootstrap/src/bootstrap/` can be reused for stage0.

---

## Reuse Categories

### Category A: Directly Reusable (Frontend)
These files are architecture-agnostic and can be adapted with minimal changes.

| bootstrap file | stage0 file | Changes needed |
|---------------|-------------|----------------|
| `token_boot.cot` | `token_s0.cot` | Remove unused token types |
| `source_boot.cot` | (merge into scanner) | Simplify span tracking |
| `scanner_boot.cot` | `scanner_s0.cot` | Remove workarounds (BUG-022) |
| `parser_boot.cot` | `parser_s0.cot` | Remove tagged unions, simplify |

**Estimated reuse**: 70-80%

---

### Category B: Partially Reusable (Middle-end)
These files have useful patterns but need structural changes.

| bootstrap file | stage0 file | Changes needed |
|---------------|-------------|----------------|
| `ast_boot.cot` | `ast_s0.cot` | Simplify node types |
| `types_boot.cot` | `types_s0.cot` | Remove complex types |
| `ir_boot.cot` | `ir_s0.cot` | Different IR structure |
| `lower_boot.cot` | `lower_s0.cot` | Adapt to new IR |

**Estimated reuse**: 40-60%

---

### Category C: Redesign Required (Backend)
These files need significant redesign due to architecture differences.

| bootstrap file | stage0 file | Why redesign |
|---------------|-------------|--------------|
| `driver_boot.cot` | `main_s0.cot` | New pass structure |
| `arm64_boot.cot` | `codegen_s0.cot` | Regalloc is now separate |
| `codegen/object_boot.cot` | `object_s0.cot` | Simplify for minimal output |

**Estimated reuse**: 20-30%

---

### Category D: New Files Required
These files don't exist in bootstrap but are needed for stage0.

| New file | Purpose | Based on |
|----------|---------|----------|
| `regalloc_s0.cot` | Separate register allocation | `bootstrap-0.2/src/ssa/regalloc.zig` |
| `ssa_s0.cot` | SSA data structures | `bootstrap-0.2/src/ssa/value.zig` |
| `ssagen_s0.cot` | IR → SSA conversion | `bootstrap-0.2/src/frontend/ssa_builder.zig` |
| `liveness_s0.cot` | Liveness analysis | `bootstrap-0.2/src/ssa/liveness.zig` |

---

## Specific Bug Avoidance

The following bugs from bootstrap should NOT be carried forward:

| Bug | Root Cause | stage0 Prevention |
|-----|-----------|-------------------|
| BUG-036 | Copy vs reference in `irFuncBuilderEmit` | Use indexed assignment |
| BUG-022 | Long if-else chains | Avoid workarounds, use simpler code |
| BUG-031 | elem_size not passed | Design IR to always include size |
| BUG-030 | Large struct by value | Pass pointers, not values |
| BUG-033 | Struct argument passing | Simple ABI, max 8 args in regs |

---

## Recommended Order

1. **Start with token_s0.cot** - simplest, most reusable
2. **Then scanner_s0.cot** - well-tested logic
3. **Then types_s0.cot** - minimal type system
4. **Then ast_s0.cot + parser_s0.cot** - frontend complete
5. **Then checker_s0.cot** - can test parsing
6. **Then ir_s0.cot + lower_s0.cot** - middle-end
7. **Then ssa_s0.cot + ssagen_s0.cot** - SSA conversion
8. **Then regalloc_s0.cot** - NEW architecture
9. **Then codegen_s0.cot** - much simpler with separate regalloc
10. **Finally object_s0.cot + main_s0.cot** - complete pipeline

---

## Blockers from bootstrap-0.2

Stage0 files cannot be written until these features work in bootstrap-0.2:

| Feature | Current Status | Needed For |
|---------|---------------|------------|
| **Arrays [N]T** | TODO | Scanner buffers, AST nodes |
| **Array indexing** | TODO | Everything |
| **Enums** | TODO | TokenKind, NodeKind, Op |
| **Pointers** | TODO | Tree structures |
| **Bitwise ops** | TODO | Instruction encoding |
| **Logical and/or** | TODO | Conditions |

Once bootstrap-0.2 completes Tier 2-5, we can start porting.

---

## Quick Start Template

When ready to start, here's the order:

```bash
# 1. Copy and simplify token
cp bootstrap/src/bootstrap/token_boot.cot bootstrap-0.2/self-hosting/stage0/token_s0.cot
# Edit: remove unused tokens, simplify

# 2. Copy and simplify scanner
cp bootstrap/src/bootstrap/scanner_boot.cot bootstrap-0.2/self-hosting/stage0/scanner_s0.cot
# Edit: remove BUG-022 workarounds, use arrays

# 3. Design new types (don't copy - too different)
# Write types_s0.cot from scratch based on PLAN.md

# ... etc
```

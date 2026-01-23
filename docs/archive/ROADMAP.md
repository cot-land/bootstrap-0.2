# cot0 Roadmap: Function Parity with Zig

**Last Updated: 2026-01-21**

## Goal

Make EVERY function in cot0 have the SAME name and SAME logic as its Zig counterpart.

Work through COMPARISON.md systematically, top to bottom, until all rows show "Same".

---

## Master Checklist

Reference: [COMPARISON.md](COMPARISON.md)

| Section | Status | Priority |
|---------|--------|----------|
| 1. main.cot | **IN PROGRESS** | Current |
| 2.1 frontend/token.cot | Pending | Next |
| 2.2 frontend/scanner.cot | Pending | |
| 2.3 frontend/ast.cot | Pending | |
| 2.4 frontend/parser.cot | Pending | |
| 2.5 frontend/types.cot | Pending | |
| 2.6 frontend/checker.cot | Pending | |
| 2.7 frontend/ir.cot | Pending | |
| 2.8 frontend/lower.cot | Pending | |
| 3.1 ssa/op.cot | Pending | |
| 3.2 ssa/value.cot | Pending | |
| 3.3 ssa/block.cot | Pending | |
| 3.4 ssa/func.cot | Pending | |
| 3.5 ssa/builder.cot | Pending | |
| 3.6 ssa/liveness.cot | Pending | |
| 3.7 ssa/regalloc.cot | Pending | |
| 4.1 arm64/asm.cot | Pending | |
| 4.2 arm64/regs.cot | Pending | |
| 5.1 codegen/arm64.cot | Pending | |
| 5.2 codegen/genssa.cot | Pending | |
| 6.1 obj/macho.cot | Pending | |
| 7.1-7.14 Zig-only files | Pending | Last |

---

## Section 1: main.cot

**Target**: Match `src/main.zig` + `src/driver.zig`

### Step 1.1: Restructure to Driver Pattern

Zig uses a `Driver` struct. cot0 should match:

```cot
struct Driver {
    allocator: *Allocator,
    source: *Source,
    seen_files: *StringHashMap,
    // ...
}

fn Driver_init(allocator: *Allocator) Driver { ... }
fn Driver_compileFile(self: *Driver, path: string) i64 { ... }
fn Driver_compileSource(self: *Driver, source: string) i64 { ... }
fn Driver_parseFileRecursive(self: *Driver, path: string) i64 { ... }
fn Driver_setDebugPhases(self: *Driver, phases: i64) { ... }
```

### Step 1.2: Rename Functions

| Current cot0 | Target Name | Notes |
|--------------|-------------|-------|
| `compile()` | `Driver_compileFile()` | Restructure as method |
| `process_all_imports()` | `Driver_parseFileRecursive()` | Rename |
| `parse_import_file()` | (inline in parseFileRecursive) | Merge |
| `is_path_imported()` | (use seen_files.contains()) | Remove |
| `add_imported_path()` | (use seen_files.put()) | Remove |

### Step 1.3: Add Missing Functions

| Function | Source | Notes |
|----------|--------|-------|
| `findRuntimePath()` | main.zig:42 | Locate runtime library |
| `Driver_init()` | driver.zig:15 | Constructor |
| `Driver_compileSource()` | driver.zig:48 | Single-file compilation |
| `Driver_setDebugPhases()` | driver.zig:92 | Debug control |

### Step 1.4: Remove/Refactor Helpers

These don't have Zig counterparts - use stdlib instead:

| Remove | Replace With |
|--------|--------------|
| `strlen()` | `str.len` (slice length) |
| `streq()` | `mem_eql()` |
| `strcpy()` | slice copy |
| `print_int()` | `println()` |

---

## Section 2.1: frontend/token.cot

**Target**: Match `src/frontend/token.zig`

### Changes Needed

| Current cot0 | Target Name |
|--------------|-------------|
| `token_type_name()` | `Token_typeName()` |

---

## Section 2.2: frontend/scanner.cot

**Target**: Match `src/frontend/scanner.zig`

### Changes Needed

| Current cot0 | Target Name |
|--------------|-------------|
| `scanner_init()` | `Scanner_init()` |
| `scanner_scan_token()` | `Scanner_next()` |
| `scanner_peek()` | `Scanner_peek()` |
| `scan_string()` | `Scanner_string()` |
| `scan_number()` | `Scanner_number()` |
| `scan_identifier()` | `Scanner_identifier()` |

---

## Section 2.3: frontend/ast.cot

**Target**: Match `src/frontend/ast.zig`

### Changes Needed

| Current cot0 | Target Name |
|--------------|-------------|
| `node_pool_init()` | `AST_init()` |
| `alloc_node()` | `AST_allocNode()` |

### Add Missing

- `AST_deinit()`
- `AST_getNode()`

---

## Section 2.4: frontend/parser.cot

**Target**: Match `src/frontend/parser.zig`

### Changes Needed (31 renames)

| Current cot0 | Target Name |
|--------------|-------------|
| `parser_init()` | `Parser_init()` |
| `parse_declaration()` | `Parser_declaration()` |
| `parse_fn_declaration()` | `Parser_fnDeclaration()` |
| `parse_struct_declaration()` | `Parser_structDeclaration()` |
| `parse_var_declaration()` | `Parser_varDeclaration()` |
| `parse_statement()` | `Parser_statement()` |
| `parse_if_statement()` | `Parser_ifStatement()` |
| `parse_while_statement()` | `Parser_whileStatement()` |
| `parse_for_statement()` | `Parser_forStatement()` |
| `parse_for_in_statement()` | `Parser_forInStatement()` |
| `parse_return_statement()` | `Parser_returnStatement()` |
| `parse_switch_statement()` | `Parser_switchStatement()` |
| `parse_block()` | `Parser_block()` |
| `parse_expression()` | `Parser_expression()` |
| `parse_assignment()` | `Parser_assignment()` |
| `parse_or()` | `Parser_orExpr()` |
| `parse_and()` | `Parser_andExpr()` |
| `parse_equality()` | `Parser_equality()` |
| `parse_comparison()` | `Parser_comparison()` |
| `parse_term()` | `Parser_term()` |
| `parse_factor()` | `Parser_factor()` |
| `parse_bitwise()` | `Parser_bitwise()` |
| `parse_shift()` | `Parser_shift()` |
| `parse_unary()` | `Parser_unary()` |
| `parse_postfix()` | `Parser_postfix()` |
| `parse_primary()` | `Parser_primary()` |
| `parse_call()` | `Parser_call()` |
| `parse_type()` | `Parser_parseType()` |
| `parse_function_type()` | `Parser_functionType()` |
| `advance_parser()` | `Parser_advance()` |
| `match_token()` | `Parser_match()` |

---

## Sections 3-7: Similar Pattern

Each section follows the same process:
1. Rename "Equivalent" functions to match Zig names
2. Add "Missing in cot0" functions by copying from Zig
3. Evaluate "Missing in Zig" functions (cot0-only)
4. Update COMPARISON.md status
5. Test after each change

---

## Section 7: Zig-Only Files (Create New)

These files don't exist in cot0 yet. Create them:

| New cot0 File | Copy From |
|---------------|-----------|
| `core/errors.cot` | `src/core/errors.zig` |
| `core/types.cot` | `src/core/types.zig` |
| `frontend/source.cot` | `src/frontend/source.zig` |
| `frontend/errors.cot` | `src/frontend/errors.zig` |
| `ssa/dom.cot` | `src/ssa/dom.zig` |
| `ssa/abi.cot` | `src/ssa/abi.zig` |
| `ssa/debug.cot` | `src/ssa/debug.zig` |
| `ssa/compile.cot` | `src/ssa/compile.zig` |
| `ssa/stackalloc.cot` | `src/ssa/stackalloc.zig` |
| `ssa/passes/lower.cot` | `src/ssa/passes/lower.zig` |
| `ssa/passes/schedule.cot` | `src/ssa/passes/schedule.zig` |
| `ssa/passes/expand_calls.cot` | `src/ssa/passes/expand_calls.zig` |
| `ssa/passes/decompose.cot` | `src/ssa/passes/decompose.zig` |
| `codegen/generic.cot` | `src/codegen/generic.zig` |

---

## Testing Protocol

After each function change:

```bash
# Rebuild cot0-stage1
./zig-out/bin/cot cot0/main.cot -o /tmp/cot0-stage1

# Test basic functionality
echo 'fn main() i64 { return 42 }' > /tmp/test.cot
/tmp/cot0-stage1 /tmp/test.cot -o /tmp/test.o
zig cc /tmp/test.o -o /tmp/test && /tmp/test; echo "Exit: $?"
# Expected: 42
```

---

## Completion Criteria

A section is COMPLETE when:
1. ALL functions show "Same" in COMPARISON.md
2. cot0-stage1 still compiles and runs
3. No regressions in test output

The project is COMPLETE when:
1. ALL 21 sections show COMPLETE
2. COMPARISON.md has NO "Equivalent" or "Missing" entries
3. cot0 can compile itself (self-hosting)

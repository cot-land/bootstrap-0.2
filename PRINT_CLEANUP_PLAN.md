# Print Function Consolidation Plan

## Goal
Exactly TWO print functions in the entire codebase:
- `print(x)` - prints string OR integer, no newline
- `println(x)` - prints string OR integer, with newline

NO OTHER IMPLEMENTATIONS. NO EXCEPTIONS.

## Current Mess (to be eliminated)

### Duplicate Implementations (DELETE ALL)
| Function | File | Action |
|----------|------|--------|
| `io_print(s: string)` | lib/io.cot | DELETE |
| `io_print_int(n: i64)` | lib/io.cot | DELETE |
| `io_print_hex(n: i64)` | lib/io.cot | DELETE |
| `print_str(s: string)` | codegen/e2e_codegen_test.cot | DELETE |
| `print_num(n: i64)` | codegen/e2e_codegen_test.cot | DELETE |
| `print_str(s: string)` | codegen/genssa_test.cot | DELETE |
| `print_num(n: i64)` | codegen/genssa_test.cot | DELETE |
| `print_str(s: string)` | obj/macho_writer_test.cot | DELETE |
| `print_num(n: i64)` | obj/macho_writer_test.cot | DELETE |
| `print_hex(n: i64)` | obj/macho_writer_test.cot | DELETE |
| `print_int(n: i64)` | main.cot | DELETE |
| `extern fn print(s: *u8)` | frontend/lower.cot | DELETE |
| `extern fn print_int(n: i64)` | frontend/lower.cot | DELETE |

### Canonical Implementation (KEEP & ENHANCE)
| Function | File | Status |
|----------|------|--------|
| `print(s: string)` | lib/stdlib.cot | ENHANCE to handle integers |
| `println(s: string)` | lib/stdlib.cot | ENHANCE to handle integers |

### Semantic Functions (KEEP - they USE print, not implement it)
These functions have meaningful names and call print internally:
- `print_usage()` - main.cot
- `print_trace_stats()` - lib/debug.cot
- `print_alloc_stats()` - lib/error.cot
- `print_error_context()` - lib/error.cot
- `print_io_stats()` - lib/safe_io.cot
- `debug_print_config()` - lib/debug_init.cot
- `debug_print_summary()` - lib/debug_init.cot
- `Lowerer_printName()` - frontend/lower.cot (debug helper)
- `Lowerer_printNodeKind()` - frontend/lower.cot (debug helper)

## Execution Plan

### Phase 1: Enhance Zig Compiler's print/println
**Status: DONE** (already modified lower.zig)

The Zig compiler now:
- Detects if argument is integer type -> calls `__print_int` runtime function
- Detects if argument is string type -> calls `write()` directly

### Phase 2: Add __print_int to Runtime
**Status: DONE** (already added to cot_runtime.zig)

### Phase 3: Delete lib/io.cot entirely
- [x] File contains ONLY duplicate implementations
- [ ] Remove all imports of io.cot from other files
- [ ] Delete the file

### Phase 4: Delete duplicate functions from test files
Files to clean:
- [ ] codegen/e2e_codegen_test.cot - remove print_str, print_num
- [ ] codegen/genssa_test.cot - remove print_str, print_num
- [ ] obj/macho_writer_test.cot - remove print_str, print_num, print_hex

### Phase 5: Delete print_int from main.cot
- [ ] Remove the function definition (lines 432-456)
- [ ] Update all callers to use print()

### Phase 6: Clean frontend/lower.cot
- [ ] Remove extern declarations for print/print_int
- [ ] Update all io_print/io_print_int calls to use print()

### Phase 7: Clean obj/macho.cot
- [ ] Replace all io_print() with print()
- [ ] Replace all io_print_int() with print()

### Phase 8: Verify no other implementations exist
```bash
# This command should return ONLY:
# - lib/stdlib.cot:15:fn print(s: string)
# - lib/stdlib.cot:20:fn println(s: string)
grep -rn "^fn print\|^fn println\|^extern fn print" stages/cot1/ --include="*.cot"
```

### Phase 9: Verify all usages compile
```bash
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1
```

## Success Criteria

1. `grep -rn "io_print" stages/cot1/` returns ZERO results
2. `grep -rn "print_str\|print_num\|print_hex\|print_int" stages/cot1/` returns ZERO results (except semantic functions like print_usage)
3. Only TWO print function definitions exist:
   - `fn print(s: string)` in lib/stdlib.cot
   - `fn println(s: string)` in lib/stdlib.cot
4. Compiler handles `print(42)` and `print("hello")` seamlessly
5. cot1 compiles successfully

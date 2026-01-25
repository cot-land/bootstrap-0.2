# Bug Tracking

## ⚠️ CRITICAL: ALL 166 TESTS MUST PASS ON COT0 FIRST ⚠️

**THIS IS THE ONLY FOCUS. NOTHING ELSE MATTERS UNTIL THIS IS DONE.**

```
/tmp/cot0-stage1 test/e2e/all_tests.cot -o /tmp/tests && /tmp/tests
```

**Current blockers:**
- ~~Self-compilation crash (BUG-057) - crashes in codegen~~ FIXED (malloc_IRLocal size 32->80)
- ~~String literals - garbled output (BUG-055)~~ FIXED (escape sequences + TYPE_STRING field access)

**Current status:** Self-compilation works! BUG-055 and BUG-057 fixed (2026-01-24)

---

## MANDATORY BUG FIXING WORKFLOW

**Every bug MUST follow these steps in order. No exceptions.**

### Step 1: Run COT_DEBUG=all
```bash
COT_DEBUG=all ./zig-out/bin/cot /tmp/bugtest.cot -o /tmp/bugtest 2>&1 | less
```
Trace the problematic value through the pipeline. Debug output should pinpoint the issue.

### Step 2: If Debug Is Too Thin - ADD MORE DEBUG FIRST
If `COT_DEBUG=all` doesn't make the bug obvious:
- **STOP** - Do not guess at the fix
- Add debug logging that WOULD have revealed the bug
- Re-run and verify the bug location is now obvious

### Step 3: Investigate Go - MANDATORY
```bash
grep -r "relevant_term" ~/learning/go/src/cmd/compile/internal/
```
- Find how Go handles the equivalent scenario
- Read and understand their implementation
- Copy their design pattern

### Step 4: Implement Fix
Only after steps 1-3. Adapt Go's pattern to Zig.

---

## Open Bugs

### BUG-063: Self-hosted cot1-stage2 crashes on startup (SIGBUS)

**Status:** OPEN
**Priority:** HIGH (blocks cot1 self-hosting chain)
**Discovered:** 2026-01-25

**Symptoms:**
- cot1-stage1 (built by Zig) successfully compiles cot1 source to produce cot1-stage2
- cot1-stage2 links successfully with zig cc
- cot1-stage2 crashes immediately on startup with SIGBUS

**Error Output:**
```
Cot0 Self-Hosting Compiler v0.2
 ================================

========================================================================
                           CRASH DETECTED
========================================================================

Signal:  SIGBUS (10)
Reason:  Bus error (misaligned access or bad address)
```

**Related Warnings During Compilation:**
During cot1-stage1's compilation of cot1 source, the lowerer reports warnings that may be related:
- `PTR_ARITH: left_type=172 elem_size=64` (multiple occurrences)
- Various pointer arithmetic type warnings

**Possible Causes:**
1. Pointer arithmetic codegen producing misaligned addresses
2. Incorrect struct field offset calculations
3. Stack frame layout issues in generated code
4. Global variable address calculations

**Investigation Steps:**
1. Run cot1-stage2 under lldb to get crash location
2. Disassemble the crashing instruction
3. Compare generated code with cot1-stage1's code for same function
4. Check pointer arithmetic lowering in `stages/cot1/frontend/lower.cot`

**Reproduction:**
```bash
# Build cot1-stage1
./zig-out/bin/cot stages/cot1/main.cot -o /tmp/cot1-stage1

# Build cot1-stage2
/tmp/cot1-stage1 stages/cot1/main.cot -o /tmp/cot1-stage2

# Link cot1-stage2
cp /tmp/cot1-stage2 /tmp/cot1-stage2.o
zig cc /tmp/cot1-stage2.o runtime/cot_runtime.o -o /tmp/cot1-stage2-linked

# Run (crashes)
/tmp/cot1-stage2-linked
```

---

### BUG-062: SSA builder reports "Invalid arg ir_rel=-1" for calls with many arguments

**Status:** FIXED (2026-01-25)
**Priority:** HIGH (was blocking cot1 self-hosting)
**Discovered:** 2026-01-25

**Symptoms:**
- When cot1-stage1 compiles cot1 source code, SSA builder reports errors for calls with 16+ arguments
- Error message: "Invalid arg ir_rel=-1 for call arg 16" (or higher arg numbers)
- Affects functions like `MachOWriter_init` with 22 arguments

**Root Cause:**
The cot1 parser (`stages/cot1/frontend/parser.cot`) only stored up to 16 call arguments in local variables (arg0-arg15). Arguments beyond 16 were parsed but NOT stored or added to the children array, causing the lowerer to read garbage or incorrect indices.

**Fix:**
Changed the parser's call argument handling to use a dynamic `I64List` instead of 16 fixed local variables. Now unlimited call arguments are properly stored and added to the children array.

**Key Code Changed:**
- `stages/cot1/frontend/parser.cot:862-899` - Replaced 16 fixed arg vars with I64List

**Verification:**
- cot1-stage1 now compiles cot1 source successfully (produces 459KB Mach-O object)
- All 166 bootstrap tests pass
- No more "Invalid arg ir_rel=-1" errors for 16+ arg calls

---

### BUG-061: DWARF debug_line relocation not 4-byte aligned

**Status:** OPEN
**Priority:** HIGH
**Discovered:** 2026-01-25

**Symptoms:**
- Stage1-compiled binaries show "exec format error" on macOS
- `BAD RELOC[src=2,idx=0]: offset=59 sym=0 type=0` in debug output
- Relocation offset 59 is not 4-byte aligned

**Root Cause:** The `__debug_line` section has a relocation at byte offset 59, but ARM64 Mach-O relocations typically require 4-byte alignment.

**Location:** `cot0/obj/macho.cot` DWARF section handling

---

### BUG-058: Global variable initialization returns 0

**Status:** OPEN
**Priority:** HIGH
**Discovered:** 2026-01-24

**Symptoms:**
- Global variables with initial values return 0 instead of the correct value
- Example: `var g: i64 = 42;` returns 0 when read

**Root Cause:** Unknown - likely in global data section initialization or relocation

**Location:** `cot0/codegen/genssa.cot` or `cot0/obj/macho.cot`

---

### BUG-059: For loop syntax not supported

**Status:** OPEN (by design)
**Priority:** LOW

**Symptoms:**
- `for i in 0..5 { }` syntax causes parser error
- cot0 parser doesn't support range-based for loops

**Workaround:** Use while loops instead

---

## Fixed Bugs

### BUG-060: Nested struct field lookup uses node index as type length

**Status:** FIXED
**Priority:** P0 (was blocking stage2)
**Discovered:** 2026-01-25
**Fixed:** 2026-01-25

**Symptoms:**
- `test_nested_struct` failing (165/166 tests)
- Stage2 GlobalReloc corruption (code_offset=817890 when max is 326248)
- Worked for simple cases but failed when many structs were defined

**Root Cause:**
In `Parser_parseStructField`, `field3` stores the type **node index**. But `lookup_struct_field_info` was interpreting `field3` as the type **string length**.

When Point struct was defined before Inner/Outer:
- "Inner" type appeared at node index 60+
- lookup_struct_field_info looked for 60+ characters instead of 5
- Field lookup failed, returned wrong offset
- Struct pointer arithmetic corrupted GlobalReloc writes

**Fix:**
Added `get_type_len_from_node()` helper in `cot0/frontend/lower.cot` that extracts the actual type length from the type node using `(type_node.end - type_node.start)`.

**Files Changed:**
- `cot0/frontend/lower.cot` - Added helper function (lines 231-241)
- `cot0/frontend/lower.cot` - Modified `lookup_struct_field_info` (line 2375)

---

### BUG-057: Self-compilation crashes in Phase 4/5 (SSA build)

**Status:** FIXED
**Priority:** P0 (was blocking self-hosting)
**Discovered:** 2026-01-24
**Fixed:** 2026-01-24

**Root Cause:**
`malloc_IRLocal` in `runtime/cot_runtime.zig` allocated only 32 bytes per struct, but IRLocal is 80 bytes (10 fields × 8 bytes). This caused memory corruption when writing to IRLocal fields past byte 32, which overwrote adjacent memory (g_ir_funcs).

**Fix:**
- Updated `malloc_IRLocal`: 32 → 80 bytes
- Updated `malloc_Local`: 32 → 72 bytes

---

### BUG-055: String literals produce garbled output in cot0-stage1

**Status:** FIXED
**Priority:** P0 (was blocking string tests)
**Discovered:** 2026-01-24
**Fixed:** 2026-01-24

**Symptoms:**
- String content appears garbled when printed or compared
- Tests using string literals fail with wrong content

**Root Cause:**
Two issues:
1. FieldAccess for `string` type (s.ptr, s.len) wasn't handled - only TYPE_SLICE was checked, not TYPE_STRING
2. Escape sequences weren't processed when copying string data to Mach-O data section
3. String length wasn't adjusted for escape sequences

**Fix:**
1. `lower.cot:2866-2871`: Check for TYPE_STRING and TypeKind.String in addition to TYPE_SLICE
2. `main.cot:1407-1430`: Process escape sequences (\n, \t, \r, etc.) when copying string data
3. `lower.cot:compute_escaped_length()`: Calculate actual string length after escape processing
4. `lower.cot:1055-1070`: Use actual length for ConstInt node (for s.len)

**Location:** cot0/main.cot, cot0/frontend/lower.cot

---

### BUG-054: Large struct returns (>16 bytes) crash in cot0-stage1

**Status:** FIXED
**Priority:** P0 (was blocking many tests)
**Discovered:** 2026-01-24
**Fixed:** 2026-01-24

**Symptoms:**
- Programs returning structs > 16 bytes crashed with SIGSEGV
- First failure at test_bug004_large_struct_return (line 1901 in all_tests.cot)
- Crash handler showed NULL pointer dereference

**Root Cause:**
ARM64 AAPCS64 ABI requires structs > 16 bytes to be returned via a hidden pointer:
1. Caller allocates space and passes address in x8
2. Callee copies result to [x8]
3. Caller retrieves result from that address

cot0 was NOT implementing this - callee returned first field value in x0 instead of using hidden pointer mechanism.

**Fix:**
1. `cot0/ssa/func.cot` - Added `return_type_size` field to Func struct
2. `cot0/main.cot` - Compute return type size using TypeRegistry_sizeof, pass type registry to GenState
3. `cot0/codegen/genssa.cot` - Added `has_hidden_return`, `hidden_ret_ptr_offset`, `type_registry` to GenState:
   - Prologue: if return type > 16B, save x8 to stack
   - Return: load x8, copy struct to [x8] using STP instructions
   - Call sites: detect >16B return type, allocate stack space, set x8 = SP before call
   - Note: Used `ADD x8, SP, #0` instead of `MOV x8, SP` because MOV encodes SP as XZR
4. `cot0/frontend/lower.cot` - Look up called function's return type for Call nodes
5. `cot0/ssa/builder.cot` - Use IRNode's type_idx instead of hardcoded TYPE_I64

**Test Results:**
- `/tmp/test_big_struct` - Exit: 0 ✓
- `/tmp/test_comprehensive.cot` - Exit: 0 ✓
- `/tmp/test_struct.cot` - Exit: 0 ✓

---

### BUG-048: cot0 parser crashes on large files

**Status:** OPEN

**Symptoms:**
- Parser segfaults (exit 139) when compiling full test suite (~1918 lines, ~9437 tokens)
- First ~1060 lines compile successfully
- Individual test patterns work in isolation

**Next Steps:**
- Add bounds checking and debug output to track node/children counts during parsing
- Compare with Zig compiler's dynamic array approach

**Location:** cot0/frontend/parser.cot

---

### BUG-047: @string builtin not recognized by cot0 parser

**Status:** FIXED

**Root Cause:** In `parse_unary()`, the code did `parser_want(p, TokenType.Ident)` for the builtin name, but `string` is tokenized as `TokenType.String` (a keyword), not `TokenType.Ident`.

**Fix:** Check for `TokenType.String` explicitly when parsing builtin names, similar to how the Zig compiler handles it:
```cot
let is_string_keyword: bool = p.current.kind == TokenType.String;
if is_string_keyword {
    parser_advance(p);  // Consume "string" keyword
} else {
    parser_want(p, TokenType.Ident);
}
// Then check is_string_keyword for @string builtin
if is_string_keyword {
    // parse ptr, len args
}
```

**Location:** cot0/frontend/parser.cot:530-560

---

### BUG-046: For-in over slices uses wrong length

**Status:** FIXED
**Priority:** P1 (was blocking slice iteration tests)
**Discovered:** 2026-01-21
**Fixed:** 2026-01-21

**Description:**
For-in loops over slices use the local's storage size (8 bytes for the pointer) instead of the slice's runtime length. This causes the loop to iterate only once regardless of slice size.

**Root Cause:**
In `cot0/frontend/lower.cot`, `lower_for` gets array length from `local.size / 8`. For slices, the local stores only the pointer (8 bytes), so `8 / 8 = 1` iteration.

**Fix Applied:**
1. Set slice locals to 16 bytes (ptr + len) in `lower_var_decl`
2. Added `lower_slice_expr_to_local` to store ptr at offset 0 and len at offset 8
3. Updated `lower_for` to detect slice locals and load length from offset 8
4. Updated `lower_for` body to index through slice ptr (loaded from offset 0)

**Zig Reference:**
`src/frontend/lower.zig:977-1036` - Uses `emitSliceLen()` for slices, compile-time length for arrays.

---

### BUG-045: Modulo operator only emitted SDIV (cot0)

**Status:** FIXED
**Priority:** P0 (was breaking modulo tests)
**Discovered:** 2026-01-21
**Fixed:** 2026-01-21

**Description:**
The `%` modulo operator returned the quotient instead of the remainder. `5 % 2` returned 2 instead of 1.

**Root Cause:**
In `cot0/codegen/genssa.cot`, `genssa_mod` only emitted SDIV, with a TODO comment. ARM64 has no modulo instruction.

**Zig Reference:**
`src/codegen/arm64.zig:1684-1702` - Computes `a % b = a - (a/b)*b`:
```zig
SDIV x16, a, b     // x16 = a / b
MUL  x16, x16, b   // x16 = (a / b) * b
SUB  dest, a, x16  // dest = a - (a / b) * b
```

**Fix:**
Updated `cot0/codegen/genssa.cot` `genssa_mod` to emit the full 3-instruction sequence.

---

### BUG-040: `null` keyword not supported in cot0 parser

**Status:** FIXED
**Priority:** P0 (was blocking Tier 14+ tests)
**Discovered:** 2026-01-21
**Fixed:** 2026-01-21

**Description:**
The cot0 parser didn't recognize the `null` keyword. Code like `let p: *i64 = null` failed to parse.

**Fix:**
Added `null` handling in parser.cot, following the same pattern as `true`/`false`:
```cot
if kind == TokenType.Null {
    parser_advance(p);
    return node_int_lit(p.pool, 0, start, end);  // null = 0
}
```

---

### BUG-041: Function type syntax not supported in cot0 parser

**Status:** FIXED
**Priority:** P1 (was blocking test_fn_type)
**Discovered:** 2026-01-21
**Fixed:** 2026-01-21

**Description:**
The cot0 parser didn't support function type syntax like `fn(i64, i64) -> i64`.

**Fix:**
1. Added `Arrow` token type for `->` in token.cot
2. Scanner recognizes `->` in scanner.cot
3. Parser handles `fn(params) -> ret` in parse_type()

---

### BUG-042: Branch fixups not reset between functions (cot0)

**Status:** FIXED
**Priority:** P0 (was causing segfaults in multi-function programs)
**Discovered:** 2026-01-21
**Fixed:** 2026-01-21

**Description:**
Programs with multiple functions using `!= 0` comparisons would segfault. The `cbz` instructions were branching to addresses in other functions.

**Root Cause:**
`gs.branches_count` was not reset between functions. When generating test_b after test_a, old branch entries from test_a were still in the array.

**Zig Reference:**
`src/codegen/arm64.zig:461-462`:
```zig
self.block_offsets.clearRetainingCapacity();
self.branch_fixups.clearRetainingCapacity();
```
Zig clears branch fixups at the start of each function.

**Fix:**
In `cot0/main.cot`, reset `gs.branches_count = 0` before calling `genssa()` for each function.

---

### BUG-043: Arrays with >3 elements segfault in cot0-stage1

**Status:** FIXED
**Priority:** P1 (was blocking many tests)
**Discovered:** 2026-01-21
**Fixed:** 2026-01-21

**Description:**
Arrays with more than 3 elements segfaulted at runtime when compiled by cot0-stage1.

**Root Cause:**
Same as BUG-044 - stack offset calculation assumed all locals were 8 bytes, causing array storage to overlap with subsequent locals.

**Fix:**
Same fix as BUG-044 - use actual local sizes for stack layout.

---

### BUG-044: Second local variable after array corrupts indexing in cot0-stage1

**Status:** FIXED
**Priority:** P1 (was blocking slice tests)
**Discovered:** 2026-01-21
**Fixed:** 2026-01-21

**Description:**
Declaring a second local variable after an array variable corrupted the array indexing result.

**Root Cause:**
In `cot0/main.cot`, stack offset calculation used `local_idx * 8`, assuming all locals are 8 bytes. Arrays need more space (e.g., `[5]i64` needs 40 bytes), so subsequent locals overlapped with array storage.

**Zig Reference:**
`src/ssa/stackalloc.zig:364-369` - Zig accumulates offsets based on actual `local_sizes`:
```zig
for (f.local_sizes, 0..) |size, idx| {
    current_offset = (current_offset + 7) & ~@as(i32, 7);
    f.local_offsets[idx] = current_offset;
    current_offset += @intCast(size);
}
```

**Fix:**
1. `cot0/frontend/ir.cot` - Added `func_builder_set_local_size()` function
2. `cot0/frontend/lower.cot` - In `lower_array_lit_to_local`, set local size to `elements_count * 8`
3. `cot0/main.cot` - Copy IR local sizes to SSA locals, compute stack offsets using cumulative sizes instead of `local_idx * 8`

---

## Recently Fixed Bugs

### BUG-053: Struct locals not allocated enough stack space (cot0)

**Status:** FIXED
**Priority:** P0 (was breaking pointer field access)
**Discovered:** 2026-01-21
**Fixed:** 2026-01-21

**Description:**
When declaring `var pt: Point` where Point is a struct with multiple fields, the local variable only got 8 bytes of stack space (default i64 size). For a 16-byte struct (two i64 fields), the second local variable would overlap with the second field.

**Symptoms:**
- `ptr.*.y` returned garbage values
- Disassembly showed `str x7, [sp, #0x8]` for both `pt.y = 222` and `var ptr = &pt`
- The pointer variable overlapped with the struct's second field

**Root Cause:**
In `cot0/frontend/lower.cot`, `lower_var_decl` added locals with default 8-byte size. For struct types, the size wasn't being computed and set using `func_builder_set_local_size`.

**Fix:**
Added code in `lower_var_decl` to compute struct size and allocate proper stack space:
```cot
if not is_pointer_to_struct {
    let struct_size: i64 = get_type_size_from_ast(l, struct_name_start, type_name_len);
    if struct_size > 8 {
        func_builder_set_local_size(fb, local_idx, struct_size);
    }
}
```

**Location:** cot0/frontend/lower.cot lines 527-532

---

### BUG-052: Direct struct types incorrectly detected as pointer-to-struct (cot0)

**Status:** FIXED
**Priority:** P0 (was breaking direct struct field access)
**Discovered:** 2026-01-21
**Fixed:** 2026-01-21

**Description:**
When declaring `var pt: Point` (direct struct), the PTYPE encoding check incorrectly identified it as a pointer-to-struct type for large source offsets. This caused wrong `struct_type_start` values to be stored, breaking field offset lookups.

**Root Cause:**
The PTYPE encoding has overlapping ranges:
- Direct struct: `type_handle = PTYPE_USER_BASE + offset = 100 + offset`
- Pointer to struct: `type_handle = PTYPE_PTR_BASE + PTYPE_USER_BASE + offset = 110 + offset`

For a struct at offset 60: type_handle = 160
For a pointer to struct at offset 50: type_handle = 160 (same!)

The original check `type_handle >= PTYPE_PTR_BASE` was too broad and matched direct structs.

**Fix:**
Added disambiguation by checking for `*` character before the potential struct name position:
```cot
var found_star: bool = false;
if ptr_offset > 0 {
    var scan_pos: i64 = ptr_offset - 1;
    while scan_pos >= 0 {
        let c: u8 = (l.source + scan_pos).*;
        if c == 32 or c == 9 or c == 10 or c == 13 {
            scan_pos = scan_pos - 1;
        } else if c == 42 {  // '*'
            found_star = true;
            break;
        } else {
            break;
        }
    }
}
```

**Location:** cot0/frontend/lower.cot lines 474-498

---

### BUG-050: ORN instruction encoding incorrect (cot0)

**Status:** FIXED
**Priority:** P0 (was breaking NOT operator)
**Discovered:** 2026-01-21
**Fixed:** 2026-01-21

**Description:**
The `not` operator returned wrong values. `not false` returned 132 instead of 1 (true). `not 0` similarly returned a wrong value.

**Root Cause:**
In `cot0/arm64/asm.cot`, the `encode_orn` function had incorrect bit positioning:
```cot
// WRONG:
(42 << 21) |          // 0b01010 = 10, but putting at wrong position
(1 << 21) |           // N = 1, also at position 21 - conflict!
```

The ARM64 ORN instruction encoding requires:
- bits 28-24: 01010 (logical register group)
- bit 21: N=1 (invert second operand)

But the code put `42` (0b101010) at position 21 instead of `10` (0b01010) at position 24.

**Fix:**
Changed `(42 << 21)` to `(10 << 24)`:
```cot
(10 << 24) |          // 01010 at bits 28-24
(1 << 21) |           // N = 1 (invert Rm)
```

**Test:**
- `not false` now returns 1 (true) ✓
- `not 0` now returns 1 ✓
- Full bool test now passes ✓

---

### BUG-049: Recursive function return values not captured correctly

**Status:** FIXED
**Priority:** P0 (was blocking recursive tests)
**Discovered:** 2026-01-21
**Fixed:** 2026-01-21

**Description:**
Recursive functions like `factorial(5)` returned wrong values (1 instead of 120). The issue was that values used across function calls were clobbered by the call.

**Root Cause:**
Two related issues:
1. **Binary expressions with call operands**: For `n * factorial(n-1)`, the left operand `n` was loaded into a register, then the call clobbered that register (X0-X7 are caller-saved).
2. **Parameters not stored to stack**: At function entry, parameters stayed in X0-X7 instead of being stored to stack slots. When a recursive call was made, the parameters were clobbered.

**Go Reference:**
`cmd/compile/internal/ssagen/ssa_builder.go` - Go stores all parameters to stack at function entry:
```go
// Phase 3: Store all args to their stack slots
for (param_values.items, param_indices.items) |param_val, local_idx| {
    const addr_val = try func.newValue(.local_addr, ...);
    const store_val = try func.newValue(.store, ...);
}
```

**Fix:**
Two fixes in cot0:

1. `cot0/frontend/lower.cot` - `lower_binary`: Spill left operand to temp local if right operand is a call:
```cot
if right_is_call {
    let left_idx: i64 = lower_expr(l, left_node);
    let temp_local: i64 = func_builder_add_local(fb, 0, 0, TYPE_I64, true);
    func_builder_emit_store_local(fb, temp_local, left_idx);
    right_idx = lower_expr(l, right_node);
    final_left_idx = func_builder_emit_load_local(fb, temp_local);
}
```

2. `cot0/main.cot` - Store parameters to stack at function entry:
```cot
while param_local_idx < ssa_func.locals_count {
    if param_local.is_param {
        let arg_val = func_new_value(&ssa_func, Op.Arg, ...);
        let addr_val = func_new_value(&ssa_func, Op.LocalAddr, ...);
        let store_val = func_new_value(&ssa_func, Op.Store, ...);
        value_add_arg2(store_val, addr_val, arg_val);
    }
}
```

And changed `LoadLocal` for parameters to load from stack instead of emitting Arg ops.

**Test:**
- `factorial(5)` now returns 120 ✓
- `double_times(1, 3)` now returns 8 ✓
- `fib_recursive(10)` now returns 55 ✓

---

### BUG-039: Bitwise operators not supported in cot0

**Status:** FIXED
**Priority:** P0
**Discovered:** 2026-01-21
**Fixed:** 2026-01-21

**Description:**
Bitwise operators `&`, `|`, `^`, `<<`, `>>` were not supported in cot0. Operations like `15 ^ 10` returned wrong values (25 instead of 5).

**Root Cause:**
Multiple layers needed updates:
1. `ast.cot` - BinaryOp enum missing BitAnd, BitOr, BitXor, Shl, Shr
2. `ast.cot` - `token_to_binop` and `binop_from_int` didn't map tokens 13-17
3. `ast.cot` - `token_precedence` missing for Pipe, Caret, LessLess, GreaterGreater, Amp
4. `parser.cot` - `make_binary_node` didn't handle op_int 13-17
5. `lower.cot` - `ast_op_to_ir_op` didn't map ast_op 13-17

**Fix:**
Added bitwise operator support through all cot0 compiler layers following Zig compiler pattern.

---

### BUG-038: Register clobbering in binary operations (cot0)

**Status:** FIXED
**Priority:** P0
**Discovered:** 2026-01-21
**Fixed:** 2026-01-21

**Description:**
Comparison chains like `test_chain(15)` returned 0 instead of 90. The `cset x0, eq` instruction was overwriting the parameter in x0.

**Root Cause:**
In `cot0/main.cot`, binary operations hardcoded `val.reg = X0` for results. This clobbered parameters that were still in x0.

**Go/Zig Reference:**
The Zig compiler uses `next_reg` to allocate the next available register for results, avoiding parameter clobbering.

**Fix:**
Changed `val.reg = X0;` to `val.reg = next_reg;` in `cot0/main.cot` line 681, following the Zig compiler pattern.

---

### BUG-037: ARM64 scaled offset encoding for LDR/STR (cot0)

**Status:** FIXED
**Priority:** P0
**Discovered:** 2026-01-21
**Fixed:** 2026-01-21

**Description:**
Array literal initialization produced wrong store offsets. `arr[1] = 20` stored at SP+64 instead of SP+8, causing incorrect array element values.

**Root Cause:**
ARM64 LDR/STR with unsigned immediate offset uses **scaled** immediates. The offset field encodes `byte_offset / access_size`, not the raw byte offset. For 8-byte accesses, offset 8 should be encoded as 1.

**Fix:**
In `cot0/arm64/asm.cot`, `encode_ldr_str_sized` now divides the byte offset by the access size:
```cot
let scale: i64 = 1 << size;
let scaled_offset: i64 = offset / scale;
```

**Verified:**
Array literal `[3]i64{10, 20, 30}` now correctly stores arr[0]=10, arr[1]=20, arr[2]=30.

---

### BUG-036: Method call syntax (obj.method()) not lowered

**Status:** FIXED
**Priority:** P0 (was blocking method support)
**Discovered:** 2026-01-21
**Fixed:** 2026-01-21

**Description:**
Method calls using the `obj.method()` syntax were not being lowered at all. The `lowerCall` function only handled callee expressions that were simple identifiers, returning `ir.null_node` for field_access callees (method calls).

**Root Cause:**
In `src/frontend/lower.zig`, `lowerCall` had:
```zig
const func_name = if (callee_expr == .ident)
    callee_expr.ident.name
else
    return ir.null_node;  // Method calls fell through here!
```

Method calls like `f.create()` have a `field_access` callee, not an `ident` callee, so they were silently ignored.

**Go Reference:**
Go's ssagen/ssa.go prepends the receiver to the call arguments:
```go
// Set receiver (for interface calls).
if rcvr != nil {
    callArgs = append(callArgs, rcvr)
}
```

**Fix:**
Added `lowerMethodCall` function in `src/frontend/lower.zig`:
1. Detect field_access callee in lowerCall
2. Look up method from checker's method_registry
3. Lower receiver (taking address if method expects pointer)
4. Prepend receiver to args list
5. Call method by its function name

**Verified:**
- 16-byte struct return (x0/x1): Exit 15 (correct)
- 24-byte struct return (x8 hidden pointer): Exit 30 (correct)

---

### BUG-035: Returning composite field (struct) via off_ptr uses void type, breaks hidden return detection

**Status:** FIXED
**Priority:** P0 (was blocking cot0-stage1 compilation)
**Discovered:** 2026-01-21
**Fixed:** 2026-01-21

**Description:**
When a function returns a struct field from another struct (e.g., `return p.peek_tok` where `peek_tok` is a `Token` struct), the return value is an `off_ptr` operation with `void(0B)` type instead of the actual struct type. This causes codegen to not detect that the function returns >16B and fails to use the hidden return path.

**Reproducer:**
```cot
struct Token {
    kind: i64,
    start: i64,
    end: i64,
}

struct Parser {
    current: Token,
    peek_tok: Token,
    has_peek: bool,
}

fn test_peek(p: *Parser) Token {
    if p.has_peek {
        return p.peek_tok  // Returns 24-byte Token
    }
    return p.current
}

fn main() i64 {
    var p: Parser
    p.has_peek = true
    p.peek_tok.kind = 42
    let t: Token = test_peek(&p)
    return t.kind  // Expected: 42, Actual: 8
}
```

**Debug Output (COT_DEBUG=all):**
```
  b2 (ret):
    v10: void(0B) = off_ptr v9 [24] : uses=1
    control: v10
```
The control value v10 has type `void(0B)` but should be `composite(24B)` for Token.

**Root Cause:**
In `src/frontend/ssa_builder.zig` at the `.field_value` handler (line ~1103), when creating an `off_ptr` for composite field access, it always uses `TypeRegistry.VOID`:
```zig
const off_val = try self.func.newValue(.off_ptr, TypeRegistry.VOID, cur, .{});
```

When this off_ptr is used as a return value, codegen checks `getTypeSize(ret_val.type_idx)` which returns 0 for VOID. Since 0 <= 16, hidden return is not triggered, and only the address is returned instead of copying the 24-byte struct.

**Go Reference:**
Go's SSA builder assigns proper types to offset operations. In `cmd/compile/internal/ssagen/ssa.go`, offset pointers carry the type information of the pointed-to element.

**Fix:**
Change line ~1103 in `src/frontend/ssa_builder.zig` to use `node.type_idx` instead of `TypeRegistry.VOID` when the field is a composite type:
```zig
const off_type = if (field_type == .struct_type or field_type == .array)
    node.type_idx
else
    TypeRegistry.VOID;
const off_val = try self.func.newValue(.off_ptr, off_type, cur, .{});
```

---

## Fixed Bugs

### BUG-034: Large struct field offsets overflow ADD immediate

**Status:** FIXED
**Priority:** P1
**Discovered:** 2026-01-20
**Fixed:** 2026-01-20

**Description:**
When accessing fields of large structs (total size > 4KB), the field offset exceeds the ARM64 ADD immediate encoding limit (12-bit unsigned, max 4095). This caused a panic during codegen.

**Root Cause:**
ARM64 `ADD Rd, Rn, #imm12` can only encode 12-bit immediates (0-4095). The `encodeADDImm` function takes `imm12: u12`. For large structs, field offsets exceed this.

**Fix:**
Added `emitAddImm()` function in `src/codegen/arm64.zig` that handles large immediates:
- imm <= 4095: Single `ADD Rd, Rn, #imm`
- imm <= 16MB: Split into two ADDs: `ADD Rd, Rn, #(imm & 0xFFF)` + `ADD Rd, Rd, #(imm >> 12), LSL #12`
- imm > 16MB: Load to scratch register with `emitLoadImmediate`, then `ADD Rd, Rn, Xscratch`

Based on Go's ARM64 backend pattern (`asm7.go` case 48 for C_ADDCON2).

**Test:**
`test/bugs/bug034_large_field_offset.cot` - Tests field offsets at 4096 and 8192 bytes.

### BUG-033: Global array element assignment silently fails

**Status:** FIXED
**Priority:** P2
**Discovered:** 2026-01-18
**Fixed:** 2026-01-18

**Symptom:** Assigning values to elements of global arrays (`g_arr[i] = x`) had no effect - values remained 0.

**Root cause:** In `lowerAssign` for `.index` case, after checking if the base identifier is a local variable, the code fell through to computed-base handling without checking if the base is a global variable.

**Debug output revealed:** No store instruction was being generated. The value was computed and truncated but marked as `(dead)` with `uses=0`.

**Fix:** Added global array check in `lowerAssign` `.index` case after local array handling:
```zig
// Check if base is a global array (BUG-033 fix)
// Following Go's pattern: addr(base) for ONAME with PEXTERN class
if (self.builder.lookupGlobal(base_expr.ident.name)) |g| {
    const global_addr = try fb.emitAddrGlobal(g.idx, ...);
    _ = try fb.emitStoreIndexValue(global_addr, index_node, value_node, elem_size, ...);
    return;
}
```

**Go reference:** `ssa.go:5266-5281` - Go's `addr()` function recursively computes addresses for `OINDEX`, using `linksymOffset` for globals (`PEXTERN` class).

---

### BUG-032: open() syscall ignores mode parameter

**Status:** FIXED
**Priority:** P2
**Discovered:** 2026-01-18
**Fixed:** 2026-01-18

**Description:**
When calling `open(path, O_CREAT | O_WRONLY | O_TRUNC, mode)`, the mode parameter was being passed in register x2 instead of on the stack. Files were created with garbage permissions.

**Root Cause:**
`open()` is a **variadic function** on macOS: `int open(const char *path, int flags, ...)`. On ARM64 macOS, the calling convention requires variadic arguments to be passed on the **stack**, not in registers.

Reference: Go's `runtime/sys_darwin_arm64.s`:
```asm
MOVW	R2, (RSP)	// arg 3 is variadic, pass on stack
```

**Fix:**
Added variadic function detection and handling to ARM64 codegen:
1. `getVariadicFixedArgCount()` - Detects known variadic libc functions (open, fcntl, ioctl, openat)
2. `setupCallArgsWithVariadic()` - Puts variadic args on stack, fixed args in registers

**Files Changed:**
- `src/codegen/arm64.zig`: Added `getVariadicFixedArgCount()`, modified `setupCallArgsWithVariadic()`, updated `static_call` handling

---

### BUG-031: Accessing array field inside struct through pointer causes crash

**Status:** FIXED
**Priority:** P0 (was blocking cot0 genssa.cot)
**Discovered:** 2026-01-18
**Fixed:** 2026-01-18

**Description:**
Accessing an array field inside a struct through a pointer (`ptr.array[idx]`) caused a runtime segfault. The array is part of the struct definition, not dynamically allocated.

**Root Cause:**
Two issues in the SSA builder:
1. `field_value` handler only returned address (no load) for struct types, not array types
2. `field_local` handler had the same issue

For `v.args[0]` where `v` is a `*Value` and `args` is `[4]i64`:
1. `field_value`/`field_local` computed the address of the `args` field
2. Then it LOADED from that address (treating it like a scalar/pointer field)
3. The loaded value (first array element) was then used as a base address for indexing
4. This caused a segfault when trying to load from a garbage address

**Fix:**
Modified `src/frontend/ssa_builder.zig` to also return address (no load) for array types:

1. Line 1036: `field_local` - added check for `.array` type alongside `.struct_type`
2. Line 1110: `field_value` - added check for `.array` type alongside `.struct_type`

Additionally, `src/frontend/lower.zig` line 854-866 was updated to handle array field access
in index assignments (e.g., `val.args[0] = 42`).

**Go Reference:**
Go's SSA treats array fields the same as struct fields - they're inline data at fixed offsets
from the base address, not pointers to separate allocations.

---

### BUG-029: Reading struct pointer field through function parameter causes crash

**Status:** FIXED
**Priority:** P1
**Discovered:** 2026-01-17
**Fixed:** 2026-01-18

**Root Cause:**
Multiple issues in how global struct and array field access was handled:
1. `lowerFieldAccess` didn't handle global struct identifiers - it fell through to load the struct value instead of using the address
2. `lowerIndex` didn't handle global array identifiers - same issue
3. `index_value` in SSA builder always loaded struct elements, but field_value expected an address
4. `lowerAssign` for field_access didn't handle when base was an index expression (e.g., `arr[0].field = value`)

**Fix:**
1. Added global struct handling in `lowerFieldAccess` using `emitAddrGlobal` (lower.zig:1524-1531)
2. Added global array handling in `lowerIndex` using `emitAddrGlobal` (lower.zig:1626-1633)
3. Added struct check in `index_value` to return address instead of loading (ssa_builder.zig:1318-1324)
4. Added index expression handling in field_access assignment (lower.zig:734-776)

**Description:**
When a function reads a pointer field from a struct passed as a parameter, and then passes that pointer to another function, the program crashes with SIGSEGV (exit 139). The same operations work when done directly in the caller.

**Reproducer:**
```cot
struct Inner {
    count: i64,
}

struct Outer {
    inner: *Inner,
}

fn inner_set(inner: *Inner, value: i64) {
    inner.count = value;  // Works fine
}

fn outer_set(outer: *Outer, value: i64) {
    // CRASH: Reading outer.inner and passing to inner_set
    inner_set(outer.inner, value);
}

fn main() i64 {
    var inner: Inner = undefined;
    var outer: Outer = undefined;
    outer.inner = &inner;

    // Direct call works:
    inner_set(outer.inner, 42);

    // Through function crashes:
    outer_set(&outer, 100);  // CRASH

    return 0;
}
```

**Workaround:**
Perform the nested pointer access directly in the calling function rather than through a helper function.

**Debug Output:**
Need to investigate with COT_DEBUG=all to trace the issue.

**Go Reference:**
Need to investigate how Go handles nested pointer field access through function parameters.

---

### BUG-030: Functions with >8 arguments don't work (ARM64 stack args missing)

**Status:** FIXED
**Priority:** P1
**Discovered:** 2026-01-18
**Fixed:** 2026-01-18

**Root Cause:**
ARM64 AAPCS64 requires first 8 arguments in x0-x7, with arguments 9+ passed on the stack.
Our `setupCallArgs` only handled the first 8 arguments and silently ignored the rest.
The callee side also didn't know how to read stack arguments.

**Fix:**
1. Updated `setupCallArgs` in `arm64.zig` to:
   - Allocate 16-byte aligned stack space for stack args (AAPCS64 requirement)
   - Store arguments 9+ to [SP], [SP+8], etc.
   - Return the stack cleanup size for the caller to restore SP after call

2. Updated `.arg` handler in `arm64.zig` to:
   - For arg indices >= 8, emit LDR from [FP + frame_size + N*8] where N = arg_idx - 8
   - Register args (0-7) already work via regalloc

3. Updated regalloc to:
   - For arg indices >= 8, allocate any available register (not fixed to x0-x7)
   - Codegen handles the stack load

**Reproducer:**
```cot
fn sum9(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64, i: i64) i64 {
    return a + b + c + d + e + f + g + h + i;
}

fn test_9args() i64 {
    let result: i64 = sum9(1, 2, 3, 4, 5, 6, 7, 8, 9);
    if result == 45 { return 42; }  // Expected: 45
    return 0;
}
```

**Go Reference:**
Go's calling convention is register-based for both args and returns, but the ARM64 backend
in `cmd/compile/internal/ssa/rewriteARM64.go` handles stack spills similarly.

---

### BUG-028: Taking address of local array element causes runtime crash

**Status:** FIXED
**Priority:** P1
**Discovered:** 2026-01-17
**Fixed:** 2026-01-18

**Root Cause:**
When a local array was initialized with `undefined`, the `lowerArrayInit` function in lower.zig fell through to the "array copy" case which tried to copy elements from the undefined value (const_nil). This resulted in SSA code that loaded from a null address.

**Fix:**
Added explicit handling for `.literal` with `kind == .undefined_lit` in `lowerArrayInit` to return early without generating any initialization code, leaving the memory uninitialized as intended.

**Description:**
Using `&arr[0]` where `arr` is a local array variable (e.g., `let source: [1]u8 = undefined;`) causes a runtime segfault (exit 139). The same code works with global arrays or with `null`.

---

### BUG-027: Direct global array field access causes compiler panic

**Status:** FIXED
**Priority:** P1
**Discovered:** 2026-01-17
**Fixed:** 2026-01-18

**Root Cause:**
Fixed as part of BUG-029 fix. The global array/struct handling added in lower.zig properly handles direct global array element field access by using `emitAddrGlobal` to get the global's address instead of falling through to code that tried to load the value.

**Description:**
Direct access to a global array element's field like `g_nodes[0].kind = X` causes a compiler panic in getTypeSize with "integer does not fit". The same operation works through a pointer.

---

### BUG-026: Integer literals > 2^31 not parsed correctly (FIXED)

**Status:** Fixed
**Priority:** P2
**Discovered:** 2026-01-17
**Fixed:** 2026-01-17

**Description:**
Integer literals larger than 2^31 (2147483648) were not parsed correctly. Hex literals like `0xD2824680` produced wrong values.

**Root Cause:**
`src/frontend/lower.zig:1316` used `std.fmt.parseInt(i64, ..., 10)` with hardcoded base 10. Hex/binary/octal literals need base 0 for auto-detection.

**Fix:**
Changed `parseInt(..., 10)` to `parseInt(..., 0)` in two places:
1. `src/frontend/lower.zig:1317` - Integer literal lowering
2. `src/frontend/lower.zig:2194` - Array length parsing

**Verified by:**
- Comparing with Go's `strconv.ParseInt(e.Value, 0, 64)` (base 0 for auto-detect)
- Test file: `cot0/arm64/asm_test.cot` now uses hex constants directly

---

### BUG-025: String pointer becomes null after many string accesses in is_keyword (FIXED)

**Status:** Fixed
**Priority:** P0 (was blocking cot0 scanner tests)
**Discovered:** 2026-01-17
**Fixed:** 2026-01-17

**Description:**
When calling `is_keyword` with a non-keyword (e.g., "foo"), the function crashed with a null pointer dereference at `text[0]`. Keywords like "fn" that matched early in the function worked fine.

**Root Cause:**
The register allocator's spill selection used block-level `live_out` to determine which values to spill. Values used only WITHIN a block (not live across block boundaries) had `dist = maxInt`, making them prime spill candidates even when they were needed very soon. This meant values like the string pointer in `is_keyword` could be spilled and their registers reused by the multiplication operation computing array offsets.

The actual issue: when `allocReg` needed to spill a value, it picked based on "farthest use" but computed distance from `live_out`, not per-instruction use lists. Go's `regalloc.go` uses per-instruction use distances via a linked list of `Use` structs.

**Go Reference:**
`~/learning/go/src/cmd/compile/internal/ssa/regalloc.go`:
```go
type use struct {
    dist int32
    pos  src.XPos
    next *use
}

// In assignReg - spill based on per-value use distance:
for i, rn := range s.regs {
    if v := s.values[vid]; v.uses != nil {
        d := v.uses.dist  // Per-instruction distance
        if d > maxuse { maxuse = d; ... }
    }
}
```

**Fix:**
`src/ssa/regalloc.zig` - Implemented Go's per-instruction use distance tracking:

1. Added `Use` struct with `dist`, `pos`, `next` fields
2. Changed `ValState.uses` from `i32` count to `?*Use` linked list
3. Added `addUse(id, dist, pos)` to build use lists by walking block backwards
4. Added `advanceUses(v)` to pop uses after each instruction is processed
5. Added `buildUseLists(block)` to initialize use lists for each block
6. Modified `allocReg` to use `vi.uses.dist` instead of block-level `live_out` for spill selection

This ensures values are spilled based on when they're actually next used, not just whether they're live-out of the block.

**Test:** `half_scanner_test.cot` scanning "foo" now passes with exit code 0

---

### BUG-024: String pointer becomes null in is_keyword after second scanner_next call (FIXED)

**Status:** Fixed
**Priority:** P0 (was blocking cot0 scanner tests)
**Discovered:** 2026-01-17
**Fixed:** 2026-01-17

**Description:**
When calling `scanner_next` twice, the second call crashes in `is_keyword` with a null pointer dereference. The string pointer (`text.ptr`) becomes 0 during execution.

**Root Cause:**
The `convertStringCompare` function in SSA builder creates `slice_len`/`slice_ptr` ops for string comparison (like `s == "if"`). However, the `decompose` pass only rewrites `string_len`/`string_ptr` ops - it didn't handle `slice_len`/`slice_ptr`.

After decompose converts `const_string` to `string_make`, the `slice_len(string_make)` wasn't being rewritten to `copy(len)`. This meant the register allocator treated `slice_len` as a separate op that could reuse the register holding the pointer component, clobbering it before `slice_ptr` could use it.

**The Fix:**
Added rules 7-9 to `decompose.zig` to also rewrite:
- `slice_len(string_make(ptr, len))` → `copy(len)`
- `slice_ptr(string_make(ptr, len))` → `copy(ptr)`
- `string_ptr(string_make(ptr, len))` → `copy(ptr)`

This matches Go's pattern where all component extractions from decomposed aggregates become direct copies.

**Go Reference:**
Go's `rewritedec.go` has rules `rewriteValuedec_OpStringLen` and `rewriteValuedec_OpStringPtr` that perform the same rewrites.

---

### BUG-022: Comparison operands use same register, causing always-true comparison (FIXED)

**Status:** Fixed
**Priority:** P0 (was blocking cot0 scanner.cot)
**Discovered:** 2026-01-17
**Fixed:** 2026-01-17

**Description:**
When there are many consecutive if statements in a function, comparisons like `if c == 200` generated incorrect assembly that always evaluated to true. The register allocator assigned the same register to both comparison operands.

**Generated Assembly (WRONG - before fix):**
```arm64
ldrb w1, [x0]         ; w1 = c (loaded from memory)
mov  x1, #0xc8        ; x1 = 200 (OVERWRITES c!)
cmp  x1, x1           ; compare 200 with 200 (ALWAYS TRUE!)
```

**Generated Assembly (CORRECT - after fix):**
```arm64
ldrb w1, [x0]         ; w1 = c
mov  x0, #0xc8        ; x0 = 200 (different register!)
cmp  x1, x0           ; compare c with 200
```

**Root Cause:**
The regalloc was clearing `self.used = 0` BEFORE allocating the output register. This meant `allocReg()` could evict operand registers when allocating the result register.

Go's pattern: `s.used` is never set to 0. Individual bits are cleared by `freeReg()` when a value's use count reaches 0. The `used` mask remains set during output allocation to prevent evicting operands.

**Go Reference:**
`~/learning/go/src/cmd/compile/internal/ssa/regalloc.go`:
- Line 373: `s.used &^= regMask(1) << r` (individual bit clear in freeReg)
- Line 430: `s.used |= regMask(1) << r` (set bit when register used)
- Line 448-449: `mask &^ s.used` (allocReg excludes used registers)

**Fix:**
`src/ssa/regalloc.zig` line 572 - Removed premature clearing of `self.used = 0` before output allocation:
```zig
// BEFORE (bug):
self.used = 0;  // Wrong! Clears before allocReg

// AFTER (fixed):
// NOTE: Do NOT clear 'used' here!
// Go's pattern: 'used' remains set during output allocation so allocReg
// won't evict operand registers. Individual bits are cleared by freeReg()
// when arg use counts reach 0.
```

**Test:** `parser_minimal_test.cot` now returns 12 (BinaryExpr) instead of 10 (IntLit)

---

### BUG-023: Stack slot reuse causes value corruption in functions with many branches (FIXED)

**Status:** Fixed (stack slot reuse part)
**Priority:** P0
**Discovered:** 2026-01-17
**Fixed:** 2026-01-17

**Description:**
When a function has many if statements (like `is_keyword` in scanner.cot), the stack allocator incorrectly reuses the same stack slot for multiple live values. This causes values to be overwritten.

**Symptoms (original):**
- `test_scanner_single.cot` passes (single scanner_next call)
- `test_scanner_two.cot` crashes with segfault (two scanner_next calls)
- Crash in `is_keyword` at null pointer dereference

**Generated Assembly (WRONG - before fix):**
```arm64
1000015cc: str x1, [sp, #0x28]
1000015d0: str x0, [sp, #0x28]  ; OVERWRITES x1!
1000015d8: str x0, [sp, #0x30]
1000015dc: str x2, [sp, #0x28]  ; OVERWRITES x0!
1000015e0: ldr x0, [sp, #0x28]  ; loads x2, not expected value!
1000015e4: add x1, x0, x2
1000015e8: ldrb w2, [x1]        ; CRASH - x1 is null
```

**Root Cause:**
The stackalloc was reusing the same stack slot for different store_reg values because no interference was computed between them. Values spilled in different blocks (b57, b60, b64, etc.) all got the same slot because they weren't detected as interfering.

**Fix:**
1. `src/ssa/stackalloc.zig` - **Disabled slot reuse for store_reg values**:
   - Store_reg values now always get unique slots
   - This is conservative but prevents the slot corruption bug
   - Proper interference computation (like Go's spillLive) can be added later for optimization

2. `src/ssa/liveness.zig` - **Fixed cross-block liveness propagation**:
   - After processing successor phis, update this block's live_out (matching Go's pattern)
   - Fixed propagation to predecessors - update pred's live_out, not current block
   - These changes improve liveness accuracy for future interference computation

3. `src/ssa/regalloc.zig` - **Added spillLive infrastructure**:
   - Added `spill_live` map to track spilled values live at block ends
   - Added `getSpillLive()` method for stackalloc to access
   - Currently not fully utilized due to the conservative fix, but infrastructure is in place

4. `src/driver.zig` - Updated stackalloc call signature

**Generated Assembly (after fix):**
```arm64
store_reg v1510 -> [sp+40] (new)
store_reg v1519 -> [sp+48] (new)  ; Different slot!
store_reg v1524 -> [sp+56] (new)  ; Different slot!
```

**Test:** All 166 e2e tests pass, `test_scanner_single.cot` passes

**Note:** `test_scanner_two.cot` still crashes, but with a different issue (null pointer in string indexing). This appears to be a separate bug, possibly in code generation for string pointer arithmetic.

---

## Fixed Bugs

### BUG-021: Chained AND operator incorrectly evaluates to true (FIXED)

**Status:** Fixed
**Priority:** P0 (was blocking cot0 parser tests)
**Discovered:** 2026-01-17
**Fixed:** 2026-01-17

**Root Cause:**
When regalloc evicts a rematerializeable value (const_int, const_bool) from a register to make room for another value, we were clearing its home assignment to prevent the original value from being emitted during codegen. However, this same eviction mechanism is also used when spilling caller-saved registers BEFORE a function call. In that case, clearing the home assignment is wrong because the values have already been used to set up call arguments.

**Fix:**
Modified `spillReg` in `src/ssa/regalloc.zig` to accept a `for_call: bool` parameter:
- When `for_call=true` (spilling for a call): don't clear home assignment
- When `for_call=false` (normal register pressure eviction): clear home assignment so the original value isn't emitted and only the rematerialized copy is

Also added `clearHome()` method to `src/ssa/func.zig` and skip check in codegen (`src/codegen/arm64.zig`) for evicted rematerializeable values.

**Files Changed:**
- `src/ssa/func.zig` - Added `clearHome()` method
- `src/ssa/regalloc.zig` - Added `for_call` parameter to `spillReg()`, clear home on non-call eviction
- `src/codegen/arm64.zig` - Skip emitting const values that have no home assignment

---

### BUG-020: Calling imported functions with many if statements causes segfault (FIXED)

**Status:** Fixed
**Priority:** P0 (was blocking cot0 self-hosting)
**Discovered:** 2026-01-17
**Fixed:** 2026-01-17

**Description:**
Calling a function from an imported file crashed when that function had many nested if statements. The actual root cause was unrelated to imports - it was a register allocator bug that only manifested with enough code complexity.

**Minimal Test:**
```cot
// token.cot - function with many if statements
fn is_keyword(text: string) i64 {
    let n: i64 = len(text);
    if n == 3 {
        if text[0] == 105 { return 1; }
        if text[0] == 108 { return 2; }
        // ... many more ifs
    }
    return 0;
}
```

**Root Cause:**
The register allocator's `allocReg` function could spill a register that was already holding an argument for the current instruction. When processing an instruction like `add_ptr v271, v277`:
1. v271 (base pointer) gets assigned x0
2. When allocating for v277 (offset), `allocReg` finds no free registers
3. `allocReg` spills v271's register (x0) and reuses it for v277
4. Both arguments now point to x0, generating `add x0, x0, x0`
5. The resulting pointer was garbage, causing segfault on dereference

**Go Reference:**
`~/learning/go/src/cmd/compile/internal/ssa/regalloc.go` uses `s.used` mask:
```go
// allocReg excludes s.used from both free reg search and spill candidates
// s.used tracks registers holding the current instruction's arguments
```

**Fix:**
`src/ssa/regalloc.zig` - Added `used` mask following Go's pattern:

1. Added `used: RegMask = 0` field to RegAllocState
2. Modified `allocReg` to exclude `used` from available registers:
```zig
fn allocReg(self: *Self, mask: RegMask, block: *Block) !RegNum {
    const available_mask = mask & ~self.used;  // Exclude 'used' registers
    if (self.findFreeReg(available_mask)) |reg| {
        return reg;
    }
    // Spill - also exclude 'used' from spill candidates
    var m = available_mask;
    // ...
}
```
3. Modified argument processing to mark each arg's register as used:
```zig
self.used = 0;  // Clear at start of instruction
for (v.args, 0..) |arg, i| {
    // ... load arg if needed ...
    if (self.values[v.args[i].id].firstReg()) |reg| {
        self.used |= @as(RegMask, 1) << @intCast(reg);
    }
}
self.used = 0;  // Clear after args processed
```

**Test:** All 166 e2e tests pass. Previously crashing functions now execute correctly.

---

### BUG-019: Large struct (>16B) by-value arguments not passed correctly (FIXED)

**Status:** Fixed
**Priority:** P0 (was blocking ir_test.cot)
**Discovered:** 2026-01-16
**Fixed:** 2026-01-16

**Description:**
When passing a struct larger than 16 bytes by value to a function, the callee receives corrupted data. ARM64 ABI requires structs > 16 bytes to be passed by reference (pointer in x0), but our compiler tries to pass them in registers which cannot hold 48+ bytes.

**Test File:** `test/bugs/bug019_large_struct_arg.cot`
```cot
struct BigNode {
    kind: i64,
    type_idx: i64,
    value: i64,
    left: i64,
    right: i64,
    op: i64,
}  // 48 bytes - 6 x i64 fields

fn get_value(node: BigNode) i64 {
    return node.value;
}

fn main() i64 {
    var node: BigNode = BigNode{
        .kind = 1,
        .type_idx = 2,
        .value = 42,
        .left = 3,
        .right = 4,
        .op = 5,
    };
    let v: i64 = get_value(node);  // Passes 48B struct by value
    if v != 42 { return 1; }
    return 0;
}
```
**Expected:** Exit 0
**Actual:** Exit 1 (corrupted value)

**Go Reference:**
`~/learning/go/src/cmd/compile/internal/ssa/expand_calls.go` lines 373-385:
```go
if !rc.hasRegs() && !CanSSA(at) {
    dst := x.offsetFrom(b, rc.storeDest, rc.storeOffset, types.NewPtr(at))
    if a.Op == OpLoad {
        m0 = b.NewValue3A(pos, OpMove, types.TypeMem, at, dst, a.Args[0], m0)
        m0.AuxInt = at.Size()
        return m0
    }
}
```

Go's pattern:
1. `CanSSA()` returns false for structs > 32B or with many fields
2. When `!hasRegs() && !CanSSA()`, use `OpMove` for memory-to-memory copy
3. Source must be an `OpLoad` - creates `OpMove(dst, src_addr, mem)` with `AuxInt = size`
4. The callee receives a pointer to the copy on the stack

**Root Cause:**
Our `expand_calls.zig` decomposes all struct arguments into individual fields regardless of size. For >16B structs, there aren't enough registers. Go's pattern copies the entire struct to stack and passes a pointer.

**Fix:**
Two coordinated changes following Go's expand_calls.go pattern:

1. **Caller side** (`src/ssa/passes/expand_calls.zig` in `expandCallArgs`):
   - For >16B struct args that are `load` ops, pass `load.args[0]` (source address) instead of the load value
   - Only applies to struct types (not arrays, strings, or other large types)

2. **Callee side** (`src/frontend/ssa_builder.zig` in SSA builder init):
   - For >16B struct parameters, treat the arg as a pointer (I64 type)
   - Use OpMove to copy from that pointer to the local's stack slot

Key insight: Only struct types needed this handling because:
- Arrays are already passed by reference via lower.zig
- Strings (16B) are decomposed into ptr/len components

---

### BUG-013: String concatenation in loops causes segfault (FIXED)

**Status:** Fixed
**Priority:** P0
**Discovered:** 2026-01-16
**Fixed:** 2026-01-16

**Description:**
String concatenation inside a while loop causes a segfault at runtime. The compiled binary crashes.

**Test File:** `/tmp/test_string_loop.cot`
```cot
fn test_string_loop() i64 {
    var s: string = "";
    var i: i64 = 0;
    while i < 3 {
        s = s + "x";  // phi for string in loop
        i = i + 1;
    }
    return len(s);  // Should return 3
}

fn main() i64 {
    return test_string_loop();
}
```

**Root Cause:**
In `expand_calls.zig`, when expanding call arguments (e.g., `string_concat v20, v21` -> `string_concat v17, v19, v34, v35`), we directly assigned `call_val.args = ...` without updating use counts. This meant v17's use count stayed at 1 (from v20) instead of incrementing to 2 (used by both v20 and v22).

The register allocator then freed v17's register after v20, even though v22 still needed it.

**Go Reference:**
Go's Value operations always maintain use counts via `AddArg()` which increments uses. Never directly assign to `.Args`.

**Fix:**
`src/ssa/passes/expand_calls.zig` line 358 - Use `resetArgs()` and `addArg()` instead of direct assignment:
```zig
// BEFORE (bug):
call_val.args = try f.allocator.dupe(*Value, new_args.items);

// AFTER (fixed):
call_val.resetArgs();
for (new_args.items) |arg| {
    call_val.addArg(arg);
}
```

---

### BUG-014: Switch statements not supported (only switch expressions) (FIXED)

**Status:** Fixed
**Priority:** P1
**Discovered:** 2026-01-16
**Fixed:** 2026-01-16

**Description:**
Switch can only be used as an expression that returns a value. Switch statements with side effects in branches are not supported. Using switch with block bodies that contain assignments causes a compiler panic.

**Test File:** `/tmp/test_switch_stmt.cot`
```cot
fn test() i64 {
    var result: i64 = 0;
    let x: i64 = 1;
    // This causes panic - switch branches are blocks with side effects
    switch x {
        1 => { result = 10; }
        2 => { result = 20; }
        else => { result = 30; }
    }
    return result;
}
```

**Root Cause:**
`lowerSwitchExpr` used `emitSelect` nodes for all cases, but `emitSelect` requires both then/else values to be valid expressions. When branch bodies return void (side effects only), this caused a panic.

**Go Reference:**
Go converts switch statements to if-else chains at the front-end level (`cmd/compile/internal/walk/switch.go`). The SSA gen just walks the compiled body.

**Fix:**
`src/frontend/lower.zig` - Split `lowerSwitchExpr` into two modes:
1. **Expression mode** (non-void result): Use nested selects (original behavior)
2. **Statement mode** (void result): Generate if-else control flow with blocks

Added `lowerSwitchStatement()` that creates proper control flow:
- Branch on case condition to case block or next block
- Lower case body in its own block
- Jump to merge block after each case
- Continue with next case or else branch

---

### BUG-015: Chained logical OR with 3+ conditions always evaluates to true (FIXED)

**Status:** Fixed
**Priority:** P0
**Discovered:** 2026-01-16
**Fixed:** 2026-01-16

**Description:**
Logical OR expressions with 3 or more conditions incorrectly evaluate to true even when all conditions are false. For example:
```cot
let x: i64 = 100;
if x == 1 or x == 2 or x == 3 {  // Should be false, but evaluates to true!
    return 2;
}
```

This bug caused the scanner's `skip_whitespace` function (which uses `c == 32 or c == 9 or c == 10 or c == 13`) to incorrectly skip over non-whitespace characters, breaking all parser tests.

**Root Cause:**
The IR processing loop evaluates all nodes in a flat list, including operands of logical OR/AND. For `(x == 1 or x == 2) or x == 3`:
1. The IR has nodes for `x == 1`, `x == 2`, `x == 3` followed by the OR nodes
2. The loop evaluates ALL comparison nodes in the current block before reaching the OR
3. When `convertLogicalOp` creates `eval_right_block` for the right operand, the values are already cached from the wrong block
4. The cached values (in wrong block) are used instead of creating new values in the correct control flow block

The result is that values for `x == 3` are evaluated in the merge block of the inner OR rather than in the outer OR's eval_right_block.

**Go Reference:**
Go (`ssagen/ssa.go:3398-3442`) uses a variable-based approach for logical ops:
```go
case ir.OANDAND, ir.OOROR:
    // Store left in variable, conditionally evaluate right
    el := s.expr(n.X)
    s.vars[n] = el
    // ... control flow ...
    er := s.expr(n.Y)
    s.vars[n] = er
    return s.variable(n, ...)  // Creates phi automatically
```
Go doesn't have the pre-evaluation problem because it evaluates expressions on-demand.

**Fix:**
`src/frontend/ssa_builder.zig` - Pre-scan IR to identify nodes that are operands of logical ops, then skip them in the main loop:
```zig
// Pre-scan: mark nodes that are operands of logical ops
var logical_operands = std.AutoHashMapUnmanaged(ir.NodeIndex, void){};
for (ir_blocks) |block| {
    for (block.nodes) |node_idx| {
        if (node.data == .binary and b.op.isLogical()) {
            try self.markLogicalOperands(b.left, &logical_operands);
            try self.markLogicalOperands(b.right, &logical_operands);
        }
    }
}

// Main loop: skip operands of logical ops
for (ir_block.nodes) |node_idx| {
    if (logical_operands.contains(node_idx)) continue;
    _ = try self.convertNode(node_idx);
}
```

This ensures operands of logical ops are only evaluated by `convertLogicalOp` in the correct SSA block.

---

### BUG-017: Using imported constant in binary expression causes panic (FIXED)

**Status:** Fixed (2026-01-16)
**Priority:** P1
**Discovered:** 2026-01-16

**Description:**
When using an imported constant directly in a binary expression, the compiler panics with an invalid node index. This affects any binary operation involving an imported const.

**Reproducer:**
```cot
// import_const.cot
const MY_CONST: i64 = 5;

// main.cot
import "import_const.cot"
fn main() i64 {
    if MY_CONST != 5 { return 1; }  // PANIC!
    return 0;
}
```

**Error:**
```
panic: index out of bounds: index 4294967295, len 7
/src/frontend/ir.zig:793 in getNode
```

**Root Cause:**
The `lowerIdent` function in `lower.zig` checked `self.const_values` for constants, but this map is per-Lowerer (per-file). Imported constants are defined in a different file's Lowerer, so they weren't found.

**Fix:**
In `lowerIdent`, after checking local `const_values`, also check the checker's scope (`self.chk.scope.lookup()`) for symbols with `kind == .constant`. The checker's scope already has imported constants with their `const_value` set.

```zig
// Check for imported constant with compile-time value
if (sym.kind == .constant) {
    if (sym.const_value) |value| {
        return try fb.emitConstInt(value, TypeRegistry.I64, ident.span);
    }
}
```

---

### BUG-016: Const identifier on right side of comparison fails to parse (FIXED)

**Status:** Fixed (2026-01-16)
**Priority:** P1
**Discovered:** 2026-01-16

**Description:**
When a const identifier appears on the RIGHT side of a comparison operator, the parser fails with "expected expression after operator". This affects all comparison operators (==, !=, <, >, etc.).

**Working:**
```cot
const A: i64 = 5;
if A == 5 { ... }     // const on left, literal on right - WORKS
if A == a { ... }     // const on left, local on right - WORKS
```

**Failing:**
```cot
const B: i64 = 5;
if a == B { ... }     // local on left, const on right - FAILS
if A == B { ... }     // const on left, const on right - FAILS
```

**Error:**
```
error: unexpected token
    return 0;
    ^
error[E201]: expected expression after operator
```

**Root Cause:**
In `parsePrimaryExpr`, when seeing an identifier followed by `{`, the parser checks if the identifier starts with uppercase and assumes it's a struct literal (`Type{ .field = ... }`). But const identifiers like `B` also start with uppercase.

For `if a == B { ... }`, after parsing `B`, the next token is `{` (start of if body). The parser sees uppercase `B` + `{` and tries to parse a struct literal, calling `expect(.period)` for field initializers. This fails because the actual content is `return 1;`, not `.field = ...`.

**Fix:**
Added proper 1-token lookahead with `peekToken()` in the Parser. Before attempting struct literal parsing, check if the token AFTER `{` is `.period`. If not, it's not a struct literal.

```zig
// Added peek_tok field to Parser for 1-token lookahead
fn peekNextIsPeriod(self: *Parser) bool {
    if (!self.check(.lbrace)) return false;
    const next = self.peekToken();
    return next.tok == .period;
}

// In parsePrimaryExpr, check for period before assuming struct literal
if (type_name.len > 0 and std.ascii.isUpper(type_name[0]) and self.peekNextIsPeriod()) {
    // Parse struct literal
}
```

---

## Fixed Bugs

### BUG-012: `ptr.*.field` loads entire struct instead of field (FIXED)

**Status:** Fixed
**Priority:** P0
**Discovered:** 2026-01-16
**Fixed:** 2026-01-16

**Description:**
When accessing a struct field through a pointer (`p.*.field`), the compiler was:
1. Loading the entire struct via LDP (16 bytes for 2-field struct)
2. Trying to treat the first 8 bytes as a pointer for field offset calculation

This caused segfaults because the loaded struct value (not a pointer) was being used for address calculation.

**Root Cause:**
In `lowerFieldAccess`, when `fa.base` is a `.deref` expression, calling `lowerExprNode(fa.base)` triggers the deref case which emits `ptr_load_value` - loading the entire struct. But for field access, we only need the pointer address.

**Go Reference:**
Go's ODOTPTR pattern (`src/cmd/compile/internal/ssagen/ssa.go`):
```go
case ir.ODOTPTR:
    p := s.exprPtr(n.X, n.Bounded(), n.Pos())
    p = s.newValue1I(ssa.OpOffPtr, types.NewPtr(n.Type()), n.Offset(), p)
    return s.load(n.Type(), p)
```
Go computes `ptr + offset` and loads just the field, NOT load-entire-struct-then-extract.

**Fix:**
`src/frontend/lower.zig` - In `lowerFieldAccess`, detect when `base_expr == .deref` and get the pointer value directly without loading the struct:
```zig
if (base_expr == .deref) {
    // Get the pointer value WITHOUT loading the struct
    const ptr_val = try self.lowerExprNode(base_expr.deref.operand);
    return try fb.emitFieldValue(ptr_val, field_idx, field_offset, field_type, fa.span);
}
```

**Test:** `p.*.value` now correctly returns 50 for `Node{ .kind = 5, .value = 50 }`

---

### BUG-009: Pointer arithmetic scaling (FIXED - WAS ALREADY WORKING)

**Status:** Fixed (was already implemented)
**Priority:** P0
**Discovered:** 2026-01-16
**Fixed:** Already working - scaling was implemented in ssa_builder.zig

**Description:**
Original report claimed `pool.nodes + idx` wasn't scaling by element size. Investigation showed the scaling WAS implemented:

**SSA actually shows (correct):**
```
v17: i64(8B) = const_int [16]      // sizeof(Node) = 16
v18: i64(8B) = mul v16, v17        // idx * 16
v19: composite(8B) = add_ptr v15, v18  // base + scaled_offset
```

**Implementation (ssa_builder.zig lines 737-762):**
Following Zig's pattern, pointer arithmetic automatically scales by element size:
```zig
if (result_type == .pointer and (b.op == .add or b.op == .sub)) {
    const elem_size = self.type_registry.sizeOf(elem_type);
    // Scale offset: offset_scaled = right * elem_size
    const scaled_offset = mul(right, const_int(elem_size));
    // Pointer arithmetic with scaled offset
    return add_ptr(left, scaled_offset);
}
```

**Decision:** Cot follows Zig's design (not Go's) for pointer arithmetic. Unlike Go which disallows `ptr + int`, Cot allows it and automatically scales by element size.

**Test:** `base + 1` where base is `*i64` correctly returns `values[1]` (20)

---

### BUG-008: Missing `addr_global` IR node (FIXED)

**Status:** Fixed
**Priority:** P0 (was blocking cot0 ast_test.cot)
**Discovered:** 2026-01-16
**Fixed:** 2026-01-16

**Description:**
`&g_pool` (address of global variable) returned `ir.null_node`, causing SSA builder panic with "index out of bounds: 4294967295".

**Root Cause:**
IR layer had `addr_local` for taking address of local variables, but no equivalent for globals.

**Fix:**
1. `src/frontend/ir.zig` - Added `addr_global: GlobalRef` to Node union
2. `src/frontend/ir.zig` - Added `emitAddrGlobal()` to FuncBuilder
3. `src/frontend/ssa_builder.zig` - Added `.addr_global` case producing `.global_addr` SSA op
4. `src/frontend/lower.zig` - Added global lookup in `&x` handling (lines 1122-1126)
5. `src/frontend/lower.zig` - Added global lookup in `&arr[idx]` handling (lines 1109-1115)

---

---

## Fixed Bugs

### BUG-002: Struct literal syntax not implemented (FIXED)

**Status:** Fixed
**Priority:** P0 (was blocking cot0 scanner.cot)
**Discovered:** 2026-01-15
**Fixed:** 2026-01-16

**Description:**
SYNTAX.md documents struct literals as `Point{ .x = 10, .y = 20 }` but this syntax was not implemented.

**Root Cause:**
1. Parser: The `parsePrimaryExpr` postfix loop had placeholder code for struct literals but never actually parsed them
2. Lowerer: No case for `.struct_init` expressions

**Fix:**
1. `src/frontend/parser.zig:808-864` - Added struct literal parsing after identifier + `{`:
   - Uses uppercase heuristic to distinguish type names from variables (matches Go/Cot convention)
   - Parses `.field = value, ...` syntax within braces
2. `src/frontend/lower.zig:368-384` - Added struct literal handling in `lowerLocalVarDecl`:
   - Detects `struct_init` expressions
   - Calls new `lowerStructInit` function
3. `src/frontend/lower.zig:476-537` - Added `lowerStructInit` function:
   - Looks up struct type by name
   - Iterates field initializers and emits `store_local_field` for each

**Go Reference:**
- `~/learning/go/src/cmd/compile/internal/walk/complit.go` - `fixedlit()` generates field-by-field assignments

**Test File:** `/tmp/test_struct_literal.cot` - Returns 30 (10 + 20)

### BUG-006: `not` keyword not recognized (FIXED)

**Status:** Fixed
**Priority:** P0 (was blocking cot0 scanner.cot)
**Discovered:** 2026-01-16
**Fixed:** 2026-01-16

**Description:**
The `not` keyword (synonym for `!`) was documented in SYNTAX.md but not working in the parser. Code like `while not scanner_at_end(s)` failed with "expected expression".

**Root Cause:**
The `kw_not` token existed in token.zig and the lowerer already mapped it to `.not` IR op, but the parser's `parseUnaryExpr()` didn't include `.kw_not` in its switch case.

**Fix:**
`src/frontend/parser.zig:694` - Added `.kw_not` to the unary expression switch case:
```zig
.sub, .lnot, .not, .kw_not => {  // Added .kw_not
```

**Test File:** `/tmp/test_not_keyword.cot` - Returns 42

---

### BUG-005: Logical NOT operator uses bitwise NOT (FIXED)

**Status:** Fixed
**Priority:** P0 (was blocking cot0 scanner.cot)
**Discovered:** 2026-01-16
**Fixed:** 2026-01-16

**Description:**
The `!` operator used MVN (bitwise NOT) for all types, including booleans. `!true` returned `0xFFFFFFFFFFFFFFFE` (non-zero = true) instead of `0` (false).

**Root Cause:**
1. `src/codegen/arm64.zig` used `encodeMVN()` for all `.not` operations
2. `src/frontend/types.zig` - `basicTypeSize()` returned 8 for `UNTYPED_BOOL` (fell through to `else` case)

**Go Reference:**
`~/learning/go/src/cmd/compile/internal/ssa/rewriteARM64.go`:
```go
func rewriteValueARM64_OpNot(v *Value) bool {
    // (Not x) -> (XOR (MOVDconst [1]) x)
}
```
Go rewrites `OpNot` to `XOR` with 1 for booleans, not bitwise complement.

**Fix:**
1. `src/frontend/types.zig` - Added `UNTYPED_BOOL` to the 1-byte case in `basicTypeSize()`
2. `src/codegen/arm64.zig` - Check type size: boolean (1B) uses `MOVZ x16, #1; EOR dest, x16, op`, integers use MVN

**Test File:** `/tmp/test_logical_not.cot` - Returns 42

---

### BUG-004: Struct returns > 16 bytes fail (FIXED)

**Status:** Fixed
**Priority:** P1 (was blocking cot0 token.cot)
**Discovered:** 2026-01-16
**Fixed:** 2026-01-16

**Description:**
Returning structs larger than 16 bytes from functions failed. The ARM64 ABI requires structs > 16 bytes to be returned via a hidden pointer parameter (x8 register).

**Example:**
```cot
struct BigStruct { a: i64, b: i64, c: i64, }  // 24 bytes

fn make_struct(x: i64, y: i64, z: i64) BigStruct {
    var s: BigStruct;
    s.a = x; s.b = y; s.c = z;
    return s;  // Was FAILING - struct is 24 bytes
}

fn main() i64 {
    let s: BigStruct = make_struct(10, 20, 30);
    return s.a + s.b + s.c;  // Now correctly returns 60
}
```

**Root Cause:**
Initial implementation dynamically adjusted SP at call time (`SUB sp, sp, #32`) to allocate hidden return space. This broke all subsequent SP-relative `local_addr` calculations.

**Go Reference:**
- `~/learning/go/src/cmd/compile/internal/ssa/expand_calls.go` - Pre-allocates result space using `OffsetOfResult`
- `~/learning/go/src/cmd/compile/internal/abi/abiutils.go` - `assignParam()` computes stack offsets at ABI analysis time
- Key insight: Go pre-allocates hidden return space in the frame, not dynamically at call time

**Fix:**
1. `src/ssa/passes/expand_calls.zig` - Mark calls with `hidden_ret_size > 0` for types > 16B
2. `src/codegen/arm64.zig` - Pre-scan function in `generateBinary()` to find all >16B return calls
3. `src/codegen/arm64.zig` - Add hidden return space to `frame_size` (pre-allocated, not dynamic)
4. `src/codegen/arm64.zig` - Store per-call offset in `hidden_ret_offsets` map
5. `src/codegen/arm64.zig` - At call time, use `ADD x8, sp, #frame_offset` (frame-relative, not SP adjustment)
6. `src/codegen/arm64.zig` - Callee: save x8 to x19 in prologue, copy data to [x19] on return

**Test Files:**
- `/tmp/test_big_struct2.cot` - Returns 60 (10 + 20 + 30)
- `cot0/frontend/token_test.cot` - All 5 tests pass

---

### BUG-003: Struct layout with enum field is wrong (FIXED)

**Status:** Fixed
**Priority:** P1 (was blocking cot0 token.cot)
**Discovered:** 2026-01-15
**Fixed:** 2026-01-15

**Description:**
When a struct contains an enum field followed by i64 fields, returning the struct from a function returned wrong values. For example, `s.x` returned 96 instead of 10.

**Root Causes (Multiple):**
1. **TypeRegistry index conflict**: SSA_MEM constant = 18 conflicted with user-defined enum types that also got index 18. Enum types were incorrectly treated as SSA_MEM.
2. **basicTypeSize didn't know enum sizes**: Static function returned 8 for unknown types, but enums are 4 bytes.
3. **16-byte struct loads used single 8-byte LDR**: For structs > 8 bytes, we need LDP (load pair).
4. **16-byte returns didn't move both halves**: `moveToX0` only moved the first half to x0.
5. **Caller clobbered x1 before saving struct result**: Regalloc reused x1 for local_addr before the 16-byte call result was consumed.

**Go Reference:**
- `cmd/compile/internal/types/size.go` - `CalcStructSize`, field alignment, `SetUnderlying` for named types
- Go's pattern: Named types (like enums) inherit size/alignment from underlying type

**Fix:**
1. `src/frontend/types.zig` - Reserved SSA type indices 18-21 in TypeRegistry.init()
2. `src/codegen/arm64.zig` - Added `type_reg` field and `getTypeSize()` method using TypeRegistry.sizeOf()
3. `src/codegen/arm64.zig` - Load handling: Use LDP for 16-byte types
4. `src/codegen/arm64.zig` - `moveToX0`: Handle 16-byte returns by moving both register halves
5. `src/codegen/arm64.zig` - static_call: Immediately save x1 to x8 for 16-byte returns
6. `src/driver.zig` - Pass TypeRegistry to codegen via setTypeRegistry()

**Test File:** `/tmp/test_struct_enum_return.cot` - Now returns 10

---

### BUG-001b: String literal arguments not decomposed (FIXED)

**Status:** Fixed
**Priority:** P0 (was blocking cot0)
**Discovered:** 2026-01-15
**Fixed:** 2026-01-15

**Description:**
When passing a string literal directly to a function (e.g., `get_len("fn")`), the length was wrong. Passing via a variable worked, but direct literals failed.

**Root Cause:**
`const_string` ops only contain the string address, not the length. When decomposing for call arguments, we need to look up the length from the string literal table.

**Go Reference:**
Go rewrites `ConstString` to `StringMake(Addr(StringData), Const64(len))` in `rewritegeneric.go:6477-6493`. The length is extracted at rewrite time.

**Fix:**
`src/ssa/passes/expand_calls.zig` - In `expandCallArgs()`, detect `const_string` args and create a `const_int` with the actual length from `f.string_literals[idx].len`.

**Test File:** `/tmp/len_direct.cot` - Now returns 2

---

### BUG-001: String parameter passing corrupts length (FIXED)

**Status:** Fixed
**Priority:** P0 (was blocking cot0)
**Discovered:** 2026-01-15
**Fixed:** 2026-01-15

**Description:**
When passing a string as a function parameter, the length field was corrupted. Direct `len(s)` worked, but `len(s)` inside a function receiving `s` as a parameter returned garbage (96 instead of 2).

**Root Cause:**
Strings are 16-byte slices (ptr + len). The implementation treated them as single values but they need to be decomposed into two registers at call sites and reassembled in the callee.

**Fix:**
1. `src/ssa/passes/expand_calls.zig` - Added `expandCallArgs()` to decompose string arguments into ptr/len before calls
2. `src/frontend/ssa_builder.zig` - String parameters now create two arg values (ptr, len) and combine with slice_make

**Test File:** `test/bugs/bug001_string_param.cot` - Now returns 2

---

## Bug Template

```markdown
### BUG-XXX: Short description

**Status:** Open | In Progress | Fixed
**Priority:** P0 | P1 | P2
**Discovered:** YYYY-MM-DD

**Description:**
What happens vs what should happen.

**Root Cause:**
(Once identified)

**Test File:** `/tmp/bugXXX_name.cot`
```cot
// Minimal reproduction
```

**Fix:**
(Once fixed - file:line and description)
```

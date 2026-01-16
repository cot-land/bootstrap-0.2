# Bug Tracking

Bugs discovered during cot0 self-hosting work.

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

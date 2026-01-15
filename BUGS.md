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

### BUG-006: `not` keyword not recognized

**Status:** Open
**Priority:** P0 (Blocking cot0 scanner.cot)
**Discovered:** 2026-01-16

**Description:**
The `not` keyword (synonym for `!`) is documented in SYNTAX.md but not implemented. Code like `while not scanner_at_end(s)` fails with "expected expression".

**Example:**
```cot
fn main() i64 {
    let x: bool = true;
    if not x {       // ERROR: expected expression
        return 1;
    }
    return 0;
}
```

**Fix:** Add `not` as a keyword in scanner, parse as unary `!` operator.

---

### BUG-005: Logical NOT operator uses bitwise NOT

**Status:** Open
**Priority:** P0 (Blocking cot0 scanner.cot)
**Discovered:** 2026-01-16

**Description:**
The `!` operator uses MVN (bitwise NOT) instead of logical NOT for booleans.

**Example:**
```cot
fn main() i64 {
    if !true {
        return 1;  // INCORRECTLY EXECUTES - !true returns 0xFFFFFFFE (non-zero)
    }
    return 0;
}
// Returns 1 instead of 0
```

**Root Cause:**
`src/codegen/arm64.zig:1491` uses `encodeMVN()` for all `not` operations.
- Bitwise NOT of 1 = 0xFFFFFFFFFFFFFFFE (non-zero = true)
- Should be: logical NOT of 1 = 0 (false)

**Fix:**
For boolean types (size 1), use `EOR Rd, Rm, #1` instead of MVN:
```zig
const type_size = self.getTypeSize(value.type_idx);
if (type_size == 1) {
    // Boolean: XOR with 1 flips 0↔1
    try self.emit(asm_mod.encodeEORImm(dest_reg, op_reg, 1));
} else {
    // Integer: bitwise NOT
    try self.emit(asm_mod.encodeMVN(dest_reg, op_reg));
}
```

---

### BUG-002: Struct literal syntax not implemented

**Status:** Open
**Priority:** P0 (Blocking cot0 scanner.cot)
**Discovered:** 2026-01-15

**Description:**
SYNTAX.md documents struct literals as `Point{ .x = 10, .y = 20 }` but this syntax is not implemented. Parser fails with "expected expression" at the comma.

**Workaround:**
Use field-by-field assignment:
```cot
var p: Point;
p.x = 10;
p.y = 20;
```

**Test File:** `/tmp/bug002_struct_literal.cot`
```cot
struct Point { x: i64, y: i64, }
fn main() i64 {
    let p: Point = Point{ .x = 10, .y = 20 };
    return p.x + p.y;
}
```

---

## Fixed Bugs

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

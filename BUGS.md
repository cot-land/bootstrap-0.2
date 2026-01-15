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

### BUG-004: Struct returns > 16 bytes fail

**Status:** Open
**Priority:** P1 (Blocking cot0 token.cot)
**Discovered:** 2026-01-16

**Description:**
Returning structs larger than 16 bytes from functions fails. The ARM64 ABI requires structs > 16 bytes to be returned via a hidden pointer parameter, but this is not implemented.

**Example:**
```cot
struct Token {
    kind: TokenType,  // 4 bytes + 4 padding
    start: i64,       // 8 bytes
    end: i64,         // 8 bytes
}  // Total: 24 bytes

fn token_new(k: TokenType, s: i64, e: i64) Token {
    var t: Token;
    t.kind = k;
    t.start = s;
    t.end = e;
    return t;  // FAILS - struct is 24 bytes
}
```

**Workaround:**
Keep structs to 16 bytes or less, OR use out-parameter pattern:
```cot
fn token_new(out: *Token, k: TokenType, s: i64, e: i64) {
    out.*.kind = k;
    out.*.start = s;
    out.*.end = e;
}
```

**Investigation Required:**
1. Go's `~/learning/go/src/cmd/compile/internal/ssa/expand_calls.go` - how Go handles large struct returns
2. ARM64 ABI docs for hidden pointer parameter convention (x8 register)

**ARM64 ABI Summary:**
- Structs <= 8 bytes: returned in x0
- Structs 9-16 bytes: returned in x0+x1
- Structs > 16 bytes: caller passes pointer in x8, callee writes to [x8]

---

### BUG-002: Struct literal syntax not implemented

**Status:** Open
**Priority:** P2 (Documentation mismatch)
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

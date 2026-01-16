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

### BUG-009: Pointer arithmetic not scaling by element size (DESIGN ISSUE)

**Status:** Open - NEEDS DESIGN REVIEW
**Priority:** P0 (blocking cot0 ast_test.cot)
**Discovered:** 2026-01-16

**Description:**
Expression `pool.nodes + idx` (where `pool.nodes` is `*Node` and `idx` is `i64`) produces incorrect address. The `add_ptr` SSA operation receives raw index instead of `idx * sizeof(Node)`.

**Test Case:** `cot0/frontend/ast_test.cot`
```cot
let n: *Node = pool.nodes + idx;  // Crashes - wrong address calculation
```

**SSA Output Shows:**
```
v32: composite(8B) = load v31 : uses=1       // loads pool.nodes (pointer)
v34: i64(8B) = load v33 : uses=1             // loads idx (raw integer)
v35: composite(8B) = add_ptr v32, v34        // ptr + idx (NOT scaled!)
```

**CRITICAL DESIGN QUESTION:**

Go does NOT support C-style pointer arithmetic:
```go
// NOT ALLOWED in Go:
ptr := &arr[0]
ptr = ptr + 1  // COMPILE ERROR - can't add to pointer

// REQUIRED in Go:
elem := arr[i]      // Index into array
elem := slice[i]    // Index into slice
ptr := &arr[i]      // Address of element
```

**Options:**

**Option A: Follow Go strictly (RECOMMENDED)**
- Make `ptr + int` a compile error
- Require `&arr[idx]` for address of element
- Require `ptr[idx]` or `ptr.*` for dereferencing
- Pros: Safer, simpler, matches Go, avoids this entire class of bugs
- Cons: Less flexible for unsafe low-level code

**Option B: Support C-style pointer arithmetic**
- `ptr + int` scales by element size
- Requires tracking pointee type in binary operations
- Need to modify: checker.zig, lower.zig, ssa_builder.zig
- Pros: More flexible
- Cons: Complex, error-prone, NOT Go-like, high bug surface

**Recommendation:** Follow Go. The code in ast_test.cot should be rewritten:
```cot
// BEFORE (C-style):
let n: *Node = pool.nodes + idx;

// AFTER (Go-style):
// But wait - pool.nodes is *Node, not []Node!
// In Go, you can't index a raw pointer.
// Design needs to use slices or array pointers properly.
```

**Go Source Evidence:**

From `~/learning/go/src/cmd/compile/internal/typecheck/universe.go:100-130`:
```go
// okforarith is ONLY set for:
// - Integer types (IsInt)
// - Float types (IsFloat)
// - Complex types (IsComplex)
// POINTERS ARE NOT INCLUDED
```

From `~/learning/go/src/cmd/compile/internal/typecheck/universe.go:183`:
```go
okfor[ir.OSUB] = okforarith[:]  // SUB only works on arithmetic types
okfor[ir.OADD] = okforadd[:]    // ADD only works on addable types (no pointers!)
```

**Conclusion:** Go explicitly does NOT allow `ptr + int` - it's a type error.

**Decision (Follow Go):**
1. Add compile error in `checker.zig` for `ptr + int` operations
2. Update SYNTAX.md to document that pointer arithmetic is not supported
3. Rewrite ast_test.cot to use proper Go-style patterns

**ast_test.cot Fix:**
```cot
// BEFORE (C-style - should be compile error):
let n: *Node = pool.nodes + idx;

// AFTER (Go-style option 1 - use array/slice with address-of):
// Change pool.nodes from *Node to []Node slice
// let n: *Node = &pool.nodes[idx];

// AFTER (Go-style option 2 - use proper function):
fn node_get(pool: *NodePool, idx: i64) *Node {
    // Internal implementation can use addr_index which scales properly
}
```

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

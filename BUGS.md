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

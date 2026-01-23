# cot0 Maturation Tasks

## Phase 1: Make cot0 Robust (CURRENT)

### 1.1 Add Debugging to cot0

- [ ] **Scanner debugging**
  - [ ] Log each token as it's scanned: `[SCAN] Token(Fn, "fn", 0:2)`
  - [ ] Wire debug.cot into scanner.cot
  - [ ] Test: `COT_DEBUG=scanner /tmp/cot0-stage1 test.cot`

- [ ] **Parser debugging**
  - [ ] Log entry/exit of each parse function: `[PARSE] -> parse_expr`, `[PARSE] <- parse_expr node#42`
  - [ ] Log current token at each decision point
  - [ ] Add depth tracking for indented output
  - [ ] Wire debug.cot into parser.cot
  - [ ] Test: `COT_DEBUG=parser /tmp/cot0-stage1 test.cot`

- [ ] **Lowering debugging**
  - [ ] Log each AST node being lowered: `[LOWER] BinaryExpr node#5 -> ir#12`
  - [ ] Log IR nodes as they're created
  - [ ] Wire debug.cot into lower.cot
  - [ ] Test: `COT_DEBUG=lower /tmp/cot0-stage1 test.cot`

- [ ] **SSA debugging**
  - [ ] Log block creation: `[SSA] block 3:`
  - [ ] Log value creation: `[SSA] v14 = add v12, v13 : i64`
  - [ ] Wire debug.cot into builder.cot
  - [ ] Test: `COT_DEBUG=ssa /tmp/cot0-stage1 test.cot`

- [ ] **Codegen debugging**
  - [ ] Log each instruction: `[CODEGEN] 0x100: MOV x0, #42`
  - [ ] Log register allocation decisions
  - [ ] Wire debug.cot into genssa.cot
  - [ ] Test: `COT_DEBUG=codegen /tmp/cot0-stage1 test.cot`

### 1.2 Fix Parser Hang

- [ ] **Identify where parser hangs**
  - [ ] Add parser debug output
  - [ ] Run on test suite with debug
  - [ ] Find which parse function loops forever

- [ ] **Compare with Zig parser (src/frontend/parser.zig)**
  - [ ] Find equivalent function in Zig
  - [ ] Identify difference in logic
  - [ ] Copy Zig's pattern

- [ ] **Fix the hang**
  - [ ] Implement fix in cot0/frontend/parser.cot
  - [ ] Rebuild cot0-stage1
  - [ ] Verify test suite no longer hangs

### 1.3 Copy Missing Logic from Zig Compiler

- [ ] **Compare scanner.cot vs src/frontend/scanner.zig**
  - [ ] Check token types match
  - [ ] Check edge cases (escapes, comments, etc.)
  - [ ] Copy any missing logic

- [ ] **Compare parser.cot vs src/frontend/parser.zig**
  - [ ] Check all parse functions exist
  - [ ] Check precedence handling matches
  - [ ] Check error recovery
  - [ ] Copy any missing logic

- [ ] **Compare lower.cot vs src/frontend/lower.zig**
  - [ ] Check all AST node types handled
  - [ ] Check IR generation matches
  - [ ] Copy any missing logic

- [ ] **Compare genssa.cot vs src/codegen/arm64.zig**
  - [ ] Check all SSA ops handled
  - [ ] Check instruction encoding
  - [ ] Copy any missing logic

---

## Phase 2: Test Suite Passes with cot0-stage1

### 2.1 Get Test Suite Compiling

- [ ] **Fix parser to handle full test suite**
  - [ ] Parser completes without hanging
  - [ ] All 166 tests parse successfully

- [ ] **Fix lowering for all test patterns**
  - [ ] All AST patterns lower to IR
  - [ ] No crashes during lowering

- [ ] **Fix codegen for all test patterns**
  - [ ] All IR patterns generate code
  - [ ] No crashes during codegen

- [ ] **Fix Mach-O output**
  - [ ] Object files are valid
  - [ ] Linking succeeds

### 2.2 Run Tests Individually

- [ ] **Tier 1: Arithmetic (tests 1-20)**
  - [ ] Compile each test with cot0-stage1
  - [ ] Link with zig cc
  - [ ] Run and verify exit code

- [ ] **Tier 2: Functions (tests 21-40)**
  - [ ] Same process

- [ ] **Tier 3: Control flow (tests 41-60)**
  - [ ] Same process

- [ ] **Tier 4: Variables (tests 61-80)**
  - [ ] Same process

- [ ] **Tier 5: Structs (tests 81-100)**
  - [ ] Same process

- [ ] **Tier 6: Strings/Arrays (tests 101-120)**
  - [ ] Same process

- [ ] **Tier 7: Pointers (tests 121-140)**
  - [ ] Same process

- [ ] **Tier 8: Advanced (tests 141-166)**
  - [ ] Same process

### 2.3 Fix Failures

For each failing test:
- [ ] Add debug output to identify issue
- [ ] Find equivalent handling in Zig compiler
- [ ] Copy the fix
- [ ] Verify test passes

---

## Phase 3: Build Confidence

### 3.1 Compile Complex Programs

- [ ] **Compile cot0/frontend/token.cot**
  - [ ] With cot0-stage1
  - [ ] Compare output with Zig compiler output
  - [ ] Fix any discrepancies

- [ ] **Compile cot0/frontend/scanner.cot**
  - [ ] Same process

- [ ] **Compile cot0/frontend/ast.cot**
  - [ ] Same process

- [ ] **Compile cot0/frontend/parser.cot**
  - [ ] Same process (this is ~1000 lines)

- [ ] **Compile cot0/main.cot**
  - [ ] Same process

### 3.2 Output Comparison

- [ ] **Create comparison script**
  - [ ] Compile same file with Zig and cot0-stage1
  - [ ] Compare object file sizes
  - [ ] Compare disassembly
  - [ ] Report differences

- [ ] **Fix any output discrepancies**
  - [ ] Investigate each difference
  - [ ] Determine if it's a bug or acceptable variation
  - [ ] Fix bugs

---

## Phase 4: Self-Hosting (FUTURE)

### 4.1 Prerequisites

- [ ] All 166 tests pass with cot0-stage1
- [ ] cot0-stage1 can compile cot0/*.cot files individually
- [ ] Output matches Zig compiler (or differences understood)

### 4.2 Self-Hosting Attempt

- [ ] `./tmp/cot0-stage1 cot0/main.cot -o /tmp/cot0-stage2`
- [ ] Link stage2
- [ ] Test stage2 on simple programs
- [ ] Compare stage1 and stage2 behavior

### 4.3 Verification

- [ ] stage2 compiles same programs as stage1
- [ ] stage2 output matches stage1 output
- [ ] stage2 can compile cot0/main.cot (produces stage3)
- [ ] stage2 and stage3 are identical (fixpoint reached)

---

## Current Priority

**Phase 1.1 and 1.2 are the immediate focus:**

1. Wire debug.cot into parser.cot
2. Add parser debug output
3. Rebuild cot0-stage1
4. Run on test suite with `COT_DEBUG=parser`
5. Find where it hangs
6. Fix the hang

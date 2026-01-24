# Fixed-Size Arrays in cot0 - Removal Tracking

Every fixed-size array that should be dynamically allocated is listed below.
Tick off each one as it is converted to dynamic allocation.

**Legend:**
- `[ ]` = Needs to be converted to dynamic allocation
- `[x]` = Converted to dynamic allocation
- `[SKIP]` = Genuinely fixed-size, keep as-is

---

## CATEGORY 1: Global Storage Arrays (MUST CONVERT)

These are the main offenders - global arrays used as storage pools.

### pipeline_test.cot
- [ ] 1. `var g_nodes: [1000]Node` (line 59)
- [ ] 2. `var g_children: [5000]i64` (line 60)
- [ ] 3. `var g_types: [100]Type` (line 64)
- [ ] 4. `var g_type_params: [100]i64` (line 65)
- [ ] 5. `var g_type_fields: [100]FieldInfo` (line 66)
- [ ] 6. `var g_ir_nodes: [1000]IRNode` (line 70)
- [ ] 7. `var g_ir_locals: [100]IRLocal` (line 71)
- [ ] 8. `var g_ssa_blocks: [100]Block` (line 74)
- [ ] 9. `var g_ssa_values: [1000]Value` (line 75)
- [ ] 10. `var g_ssa_locals: [50]Local` (line 76)
- [ ] 11. `var g_all_defs: [50]BlockDefs` (line 77)
- [ ] 12. `var g_block_map: [50]BlockMapping` (line 78)
- [ ] 13. `var g_node_values: [500]VarDef` (line 79)
- [ ] 14. `var g_var_storage: [2000]VarDef` (line 80)

### driver_test.cot
- [ ] 15. `var g_nodes: [1000]Node` (line 43)
- [ ] 16. `var g_children: [5000]i64` (line 44)
- [ ] 17. `var g_types: [100]Type` (line 48)
- [ ] 18. `var g_type_params: [100]i64` (line 49)
- [ ] 19. `var g_type_fields: [100]FieldInfo` (line 50)

### ssa/builder_test.cot
- [ ] 20. `var g_blocks: [100]Block` (line 7)
- [ ] 21. `var g_values: [1000]Value` (line 8)
- [ ] 22. `var g_locals: [50]Local` (line 9)
- [ ] 23. `var g_all_defs: [50]BlockDefs` (line 10)
- [ ] 24. `var g_block_map: [50]BlockMapping` (line 11)
- [ ] 25. `var g_node_values: [500]VarDef` (line 12)
- [ ] 26. `var g_var_storage: [2000]VarDef` (line 13)
- [ ] 27. `var g_defs_storage: [10]VarDef` (line 14)

### ssa/builder_setvar_test.cot
- [ ] 28. `var g_blocks: [100]Block` (line 4)
- [ ] 29. `var g_values: [1000]Value` (line 5)
- [ ] 30. `var g_locals: [50]Local` (line 6)
- [ ] 31. `var g_all_defs: [50]BlockDefs` (line 7)
- [ ] 32. `var g_block_map: [50]BlockMapping` (line 8)
- [ ] 33. `var g_node_values: [500]VarDef` (line 9)
- [ ] 34. `var g_var_storage: [2000]VarDef` (line 10)

### ssa/liveness_test.cot
- [ ] 35. `var g_lm_entries: [256]LiveInfo` (line 5)
- [ ] 36. `var g_live_out: [128]LiveInfo` (line 93)
- [ ] 37. `var g_next_call: [1000]i64` (line 94)

### ssa/regalloc_test.cot
- [ ] 38. `var g_val_states: [1000]ValState` (line 5)
- [ ] 39. `var g_reg_states: [32]RegState` (line 6)
- [ ] 40. `var g_block_liveness: [50]BlockLiveness` (line 9)
- [ ] 41. `var g_live_storage: [5000]LiveInfo` (line 10)
- [ ] 42. `var g_next_call_storage: [50000]i64` (line 11)
- [ ] 43. `var g_blocks: [100]Block` (line 14)
- [ ] 44. `var g_values: [1000]Value` (line 15)
- [ ] 45. `var g_locals: [50]Local` (line 16)

### codegen/genssa_test.cot
- [ ] 46. `var g_ssa_blocks: [100]Block` (line 43)
- [ ] 47. `var g_ssa_values: [1000]Value` (line 44)
- [ ] 48. `var g_ssa_locals: [50]Local` (line 45)
- [ ] 49. `var g_code: [65536]u8` (line 46)
- [ ] 50. `var g_bstart: [100]i64` (line 47)
- [ ] 51. `var g_branches: [100]Branch` (line 48)

### codegen/e2e_codegen_test.cot
- [ ] 52. `var g_ssa_blocks: [10]Block` (line 63)
- [ ] 53. `var g_ssa_values: [100]Value` (line 64)
- [ ] 54. `var g_ssa_locals: [10]Local` (line 65)
- [ ] 55. `var g_code: [4096]u8` (line 68)
- [ ] 56. `var g_bstart: [10]i64` (line 69)
- [ ] 57. `var g_branches: [10]Branch` (line 70)
- [ ] 58. `var g_data: [1024]u8` (line 73)
- [ ] 59. `var g_symbols: [10]Symbol` (line 74)
- [ ] 60. `var g_strings: [1024]u8` (line 75)
- [ ] 61. `var g_relocs: [10]Reloc` (line 76)
- [ ] 62. `var g_output: [65536]u8` (line 77)

### obj/macho_writer_test.cot
- [ ] 63. `var g_code: [4096]u8` (line 71)
- [ ] 64. `var g_data: [4096]u8` (line 72)
- [ ] 65. `var g_symbols: [100]Symbol` (line 73)
- [ ] 66. `var g_strings: [4096]u8` (line 74)
- [ ] 67. `var g_relocs: [100]Reloc` (line 75)
- [ ] 68. `var g_output: [65536]u8` (line 76)

### frontend/checker_test.cot
- [ ] 69. `var scopes: [100]Scope` (lines 67, 103)
- [ ] 70. `var symbols: [1000]Symbol` (lines 68, 104)

### frontend/parser_test.cot
- [ ] 71. `var g_nodes: [200]Node` (line 9)
- [ ] 72. `var g_children: [1000]i64` (line 10)
- [ ] 73. `var g_types: [100]Type` (line 14)
- [ ] 74. `var g_type_params: [100]i64` (line 15)
- [ ] 75. `var g_type_fields: [100]FieldInfo` (line 16)

### frontend/parser_test_minimal.cot
- [ ] 76. `var g_nodes: [100]Node` (line 7)
- [ ] 77. `var g_children: [500]i64` (line 8)
- [ ] 78. `var g_types: [50]Type` (line 12)
- [ ] 79. `var g_type_params: [50]i64` (line 13)
- [ ] 80. `var g_type_fields: [50]FieldInfo` (line 14)

### frontend/parser_debug.cot
- [ ] 81. `var g_nodes: [200]Node` (line 8)
- [ ] 82. `var g_children: [1000]i64` (line 9)
- [ ] 83. `var g_types: [50]Type` (line 12)
- [ ] 84. `var g_type_params: [50]i64` (line 13)
- [ ] 85. `var g_type_fields: [50]FieldInfo` (line 14)

### frontend/parser_min.cot
- [ ] 86. `var g_nodes: [200]Node` (line 8)
- [ ] 87. `var g_children: [1000]i64` (line 9)
- [ ] 88. `var g_types: [50]Type` (line 12)
- [ ] 89. `var g_type_params: [50]i64` (line 13)
- [ ] 90. `var g_type_fields: [50]FieldInfo` (line 14)

### frontend/scanner_trace.cot
- [ ] 91. `var g_nodes: [200]Node` (line 8)
- [ ] 92. `var g_children: [1000]i64` (line 9)
- [ ] 93. `var g_types: [50]Type` (line 12)
- [ ] 94. `var g_type_params: [50]i64` (line 13)
- [ ] 95. `var g_type_fields: [50]FieldInfo` (line 14)

### frontend/lower_test.cot
- [ ] 96. `var g_nodes: [100]Node` (line 10)
- [ ] 97. `var g_ir_nodes: [100]IRNode` (line 11)
- [ ] 98. `var g_ir_locals: [50]IRLocal` (line 12)
- [ ] 99. `var g_ir_funcs: [10]IRFunc` (line 13)
- [ ] 100. `var g_children: [200]i64` (line 14)
- [ ] 101. `var g_constants: [50]ConstEntry` (line 15)
- [ ] 102. `var g_source: [100]u8` (line 17)
- [ ] 103. `var g_types: [256]Type` (line 20)
- [ ] 104. `var g_params: [1024]i64` (line 21)
- [ ] 105. `var g_fields: [1024]FieldInfo` (line 22)

### frontend/ir_test.cot
- [ ] 106. `var g_nodes: [100]IRNode` (line 9)
- [ ] 107. `var g_locals: [50]IRLocal` (line 10)

### frontend/ir_debug.cot
- [ ] 108. `var g_simple: [5]Simple` (line 9)

### frontend/ast_test.cot
- [ ] 109. `var g_nodes: [100]Node` (line 7)
- [ ] 110. `var g_children: [500]i64` (line 8)

### lib/error.cot
- [ ] 111. `var g_error_context: [32]*u8` (line 576)

---

## CATEGORY 2: Local Function Arrays (MUST CONVERT)

These are local arrays inside functions that can grow unboundedly.

### ssa/regalloc.cot
- [x] 112. `var phi_ids: [32]i64` (line 371) - CONVERTED to I64List
- [x] 113. `var phi_regs: [32]i64` (line 391) - CONVERTED to I64List

### ssa/builder.cot
- [x] 114. `var temp_ids: [64]i64` (line 550) - CONVERTED to I64List
- [x] 115. `var fwd_refs: [256]i64` (line 588) - CONVERTED to I64List
- [x] 116. `var args: [16]i64` (line 616) - CONVERTED to I64List
- [x] 117. `var arg_values: [64]*Value` (line 945) - CONVERTED to I64List (stores value IDs)
- [x] 118. `var arg_local_indices: [64]i64` (line 946) - CONVERTED to I64List

### codegen/genssa.cot
- [x] 119. `var param_types: [32]i64` (line 1537) - CONVERTED to I64List
- [x] 120. `var move_src: [8]i64` (line 1579) - CONVERTED to I64List
- [x] 121. `var move_dest: [8]i64` (line 1580) - CONVERTED to I64List
- [x] 122. `var move_done: [8]bool` (line 1581) - CONVERTED to I64List (0/1 for bool)
- [x] 123. `var param_types: [32]i64` (line 1746) - CONVERTED to I64List
- [x] 124. `var src_regs: [16]i64` (line 1974) - CONVERTED to I64List
- [x] 125. `var dest_regs: [16]i64` (line 1975) - CONVERTED to I64List
- [x] 126. `var needs_temp: [16]bool` (line 1976) - CONVERTED to I64List (0/1 for bool)
- [x] 127. `var temp_regs: [16]i64` (line 1977) - CONVERTED to I64List

### frontend/lower.cot
- [x] 128. `var arg_ir: [16]i64` (line 2334) - CONVERTED to I64List
- [x] 129. `var arg_local: [16]i64` (line 2335) - CONVERTED to I64List
- [x] 130. `var arg_is_call: [16]bool` (line 2336) - CONVERTED to I64List (0/1 for bool)

### frontend/parser.cot
- [x] 131. `var param_types: [8]i64` (line 314) - CONVERTED to I64List

---

## CATEGORY 3: Struct Fields with Fixed Arrays (MUST CONVERT)

These are in struct definitions - they limit the struct's capability.

### ssa/block.cot
- [SKIP] 132. `succs: [2]i64` (line 63) - Block struct - genuinely fixed, max 2 successors
- [x] 133. `preds: [16]i64` (line 67) - CONVERTED to I64List

### ssa/value.cot
- [x] 134. `args: [16]i64` (line 32) - CONVERTED to I64List

---

## CATEGORY 4: Small Fixed Buffers (EVALUATE - likely OK)

These are small buffers for known-size data. Many can stay as-is.

### lib/error.cot
- [SKIP] 135. `var buf: [1]u8` (line 44) - single char output
- [SKIP] 136. `var buf: [32]u8` (line 50) - small print buffer
- [SKIP] 137. `var buf: [18]u8` (line 79) - hex output buffer

### main.cot
- [SKIP] 138. `var buf: [32]u8` (line 39) - small print buffer
- [SKIP] 139. `var buf: [18]u8` (line 62) - hex output buffer
- [SKIP] 140. `var buf: [20]u8` (line 414) - number buffer
- [x] 141. `var this_file_dir: [256]u8` (line 771) - CONVERTED to U8List
- [x] 142. `var sym_name: [128]u8` (line 1147) - CONVERTED to U8List
- [SKIP] 143. `var dash_o: [3]u8` (line 1734) - "-o" flag, fixed size

### debug.cot
- [SKIP] 144. `var env_name: [10]u8` (line 97) - "COT_DEBUG", fixed
- [SKIP] 145. `var all_str: [4]u8` (line 110) - "all", fixed
- [SKIP] 146. `var scanner_str: [8]u8` (line 133) - "scanner", fixed
- [SKIP] 147. `var parser_str: [7]u8` (line 146) - "parser", fixed
- [SKIP] 148. `var types_str: [6]u8` (line 158) - "types", fixed
- [SKIP] 149. `var lower_str: [6]u8` (line 169) - "lower", fixed
- [SKIP] 150. `var ir_str: [3]u8` (line 180) - "ir", fixed
- [SKIP] 151. `var ssa_str: [4]u8` (line 188) - "ssa", fixed
- [SKIP] 152. `var codegen_str: [8]u8` (line 197) - "codegen", fixed
- [SKIP] 153. `var buf: [20]u8` (line 268) - number buffer
- [SKIP] 154. `var buf: [18]u8` (line 300) - hex buffer
- [SKIP] 155. `var nl: [1]u8` (line 329) - newline char

### pipeline_test.cot
- [SKIP] 156. `var digits: [20]u8` (line 37) - number digits

### codegen/genssa_test.cot
- [SKIP] 157. `var digits: [20]u8` (line 26) - number digits

### codegen/e2e_codegen_test.cot
- [SKIP] 158. `var digits: [20]u8` (line 46) - number digits
- [SKIP] 159. `var main_name: [5]u8` (line 145) - "_main" symbol
- [SKIP] 160. `var path: [18]u8` (line 163) - fixed test path

### obj/macho_writer_test.cot
- [SKIP] 161. `var digits: [20]u8` (line 26) - number digits
- [SKIP] 162. `var digits: [16]u8` (line 44) - hex digits
- [SKIP] 163. `var nop: [4]u8` (line 315) - single instruction
- [SKIP] 164. `var name: [5]u8` (lines 165, 216) - "_main" symbol
- [SKIP] 165. `var mov_inst: [4]u8` (line 198) - single instruction
- [SKIP] 166. `var ret_inst: [4]u8` (line 207) - single instruction

### driver_test.cot
- [SKIP] 167. `var buf: [20]u8` (line 17) - number buffer

### obj/macho.cot
- [SKIP] 168. `var text_name: [16]u8` (line 1031) - section name, max 16
- [SKIP] 169. `var text_seg: [16]u8` (line 1039) - segment name, max 16
- [SKIP] 170. `var data_name: [16]u8` (line 1053) - section name, max 16
- [SKIP] 171. `var data_seg: [16]u8` (line 1061) - segment name, max 16
- [SKIP] 172. `var text_name: [16]u8` (line 1210) - section name, max 16
- [SKIP] 173. `var text_seg: [16]u8` (line 1213) - segment name, max 16
- [SKIP] 174. `var data_name: [16]u8` (line 1222) - section name, max 16
- [SKIP] 175. `var data_seg: [16]u8` (line 1225) - segment name, max 16
- [SKIP] 176. `var dbg_line_name: [16]u8` (line 1234) - section name, max 16
- [SKIP] 177. `var dwarf_seg: [16]u8` (line 1242) - segment name, max 16
- [SKIP] 178. `var dbg_abbrev_name: [16]u8` (line 1254) - section name, max 16
- [SKIP] 179. `var dbg_info_name: [16]u8` (line 1269) - section name, max 16

---

## CATEGORY 5: Test Files with Fixed Arrays (OK in test code)

Test files are allowed to have fixed-size arrays for test data.
These are part of the TEST SUITE, not the compiler itself.

### test/all_tests.cot
- [SKIP] All array literals like `var arr: [3]i64 = [10, 20, 30]` are test data

---

## SUMMARY

| Category | Count | To Convert | Skip |
|----------|-------|------------|------|
| Global Storage Arrays | 110 | 110 | 0 |
| Local Function Arrays | 20 | 20 | 0 |
| Struct Field Arrays | 2 | 1 | 1 |
| Small Fixed Buffers | 47 | 2 | 45 |
| **TOTAL** | **179** | **133** | **46** |

**Arrays requiring conversion: 133**
**Arrays that can stay fixed: 46**

---

## PROGRESS

Converted: 0 / 133

---

## NOTES

1. Struct field `succs: [2]i64` is genuinely fixed - a block can only have 0, 1, or 2 successors (fallthrough, jump, or conditional branch).

2. All section/segment names in Mach-O are genuinely limited to 16 characters by the file format.

3. Test files can keep fixed arrays since they're testing specific scenarios.

4. Priority order:
   - Struct fields first (affects all instances)
   - Global storage in main compiler files
   - Local function arrays
   - Test file globals (lowest priority)

//! SSA Operation definitions.
//!
//! Go reference: [cmd/compile/internal/ssa/op.go]
//!
//! Each Op defines what computation a Value performs. Operations have
//! associated metadata ([OpInfo]) that describes:
//! - Register constraints
//! - Side effects
//! - Memory access patterns
//! - Commutativity
//! - Other properties
//!
//! ## Organization
//!
//! Operations are organized into categories:
//! 1. **Invalid/Placeholder** - Sentinel values
//! 2. **Memory State** - Memory threading for SSA
//! 3. **Constants** - All rematerializable constant operations
//! 4. **Integer Arithmetic** - Generic and sized variants
//! 5. **Bitwise Operations** - AND, OR, XOR, shifts
//! 6. **Comparisons** - Equality and ordering
//! 7. **Type Conversions** - Extensions, truncations, casts
//! 8. **Floating Point** - FP arithmetic and conversions
//! 9. **Memory Operations** - Loads, stores, addressing
//! 10. **Control Flow** - Phi, copy, arguments
//! 11. **Function Calls** - All call variants
//! 12. **Safety Checks** - Nil checks, bounds checks
//! 13. **Atomics** - Atomic memory operations
//! 14. **Register Allocation** - Spill/restore operations
//! 15. **ARM64 Operations** - Architecture-specific lowered ops
//! 16. **x86_64 Operations** - Architecture-specific lowered ops
//!
//! Related modules:
//! - [value.zig] - Value representation using Op
//! - [compile.zig] - Pass infrastructure that transforms ops
//! - [debug.zig] - Debug output showing ops

const std = @import("std");
const types = @import("../core/types.zig");

const RegMask = types.RegMask;

/// SSA operation type.
///
/// Go reference: [cmd/compile/internal/ssa/op.go]
///
/// Use [Op.info] to get metadata about an operation including
/// register constraints, side effects, and commutativity.
pub const Op = enum(u16) {

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 1: Invalid / Placeholder
    // ═══════════════════════════════════════════════════════════════════════════

    /// Invalid operation - used as sentinel/uninitialized value.
    invalid,

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 2: Memory State
    // Go reference: [cmd/compile/internal/ssa/_gen/genericOps.go]
    //
    // The memory type represents the state of memory at a point in the program.
    // Memory operations take a memory argument and may return a new memory state.
    // This enables SSA to track memory dependencies.
    // ═══════════════════════════════════════════════════════════════════════════

    /// Initial memory state at function entry.
    /// Every function starts with this as the memory state.
    init_mem,

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 3: Constants
    // All constant operations are rematerializable - they can be recomputed
    // rather than spilled/reloaded, saving memory bandwidth.
    // ═══════════════════════════════════════════════════════════════════════════

    /// Boolean constant. aux_int: 0 (false) or 1 (true)
    const_bool,
    /// Integer constant. aux_int: the value (sign-extended)
    const_int,
    /// Float constant. aux_int: IEEE 754 bits via @bitCast
    const_float,
    /// Nil pointer constant.
    const_nil,
    /// String constant. aux: string slice
    const_string,
    /// Constant pointer (8-byte address). aux_int: symbol index for relocation
    const_ptr,

    // --- Sized Integer Constants (for type safety) ---
    /// 8-bit integer constant
    const_8,
    /// 16-bit integer constant
    const_16,
    /// 32-bit integer constant
    const_32,
    /// 64-bit integer constant
    const_64,

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 4: Integer Arithmetic
    // Generic operations - result type determined by operand types.
    // Sized variants for explicit bit widths.
    // ═══════════════════════════════════════════════════════════════════════════

    // --- Generic Arithmetic ---
    /// Addition: arg0 + arg1 (commutative)
    add,
    /// Subtraction: arg0 - arg1
    sub,
    /// Multiplication: arg0 * arg1 (commutative)
    mul,
    /// Signed division: arg0 / arg1
    div,
    /// Unsigned division: arg0 / arg1
    udiv,
    /// Signed modulo: arg0 % arg1
    mod,
    /// Unsigned modulo: arg0 % arg1
    umod,
    /// Negation: -arg0
    neg,

    // --- Sized Arithmetic (8-bit) ---
    add8,
    sub8,
    mul8,

    // --- Sized Arithmetic (16-bit) ---
    add16,
    sub16,
    mul16,

    // --- Sized Arithmetic (32-bit) ---
    add32,
    sub32,
    mul32,

    // --- Sized Arithmetic (64-bit) ---
    add64,
    sub64,
    mul64,

    // --- High Multiplication (upper half of result) ---
    /// High 32 bits of 32x32→64 multiply (signed)
    hmul32,
    /// High 32 bits of 32x32→64 multiply (unsigned)
    hmul32u,
    /// High 64 bits of 64x64→128 multiply (signed)
    hmul64,
    /// High 64 bits of 64x64→128 multiply (unsigned)
    hmul64u,

    // --- Division with Remainder (returns tuple) ---
    /// Signed 32-bit divmod: arg0 /% arg1 → (quotient, remainder)
    divmod32,
    /// Signed 64-bit divmod
    divmod64,
    /// Unsigned 32-bit divmod
    divmodu32,
    /// Unsigned 64-bit divmod
    divmodu64,

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 5: Bitwise Operations
    // ═══════════════════════════════════════════════════════════════════════════

    // --- Generic Bitwise (binary) ---
    /// Bitwise AND: arg0 & arg1 (commutative)
    and_,
    /// Bitwise OR: arg0 | arg1 (commutative)
    or_,
    /// Bitwise XOR: arg0 ^ arg1 (commutative)
    xor,
    /// Left shift: arg0 << arg1
    shl,
    /// Logical right shift: arg0 >> arg1 (zero-fill)
    shr,
    /// Arithmetic right shift: arg0 >> arg1 (sign-extend)
    sar,

    // --- Sized Bitwise AND ---
    and8,
    and16,
    and32,
    and64,

    // --- Sized Bitwise OR ---
    or8,
    or16,
    or32,
    or64,

    // --- Sized Bitwise XOR ---
    xor8,
    xor16,
    xor32,
    xor64,

    // --- Sized Left Shift ---
    shl8,
    shl16,
    shl32,
    shl64,

    // --- Sized Logical Right Shift ---
    shr8,
    shr16,
    shr32,
    shr64,

    // --- Sized Arithmetic Right Shift ---
    sar8,
    sar16,
    sar32,
    sar64,

    // --- Bitwise Unary ---
    /// Bitwise NOT: ~arg0
    not,
    /// 8-bit complement: ^arg0
    com8,
    /// 16-bit complement
    com16,
    /// 32-bit complement
    com32,
    /// 64-bit complement
    com64,

    // --- Bit Counting ---
    /// Count trailing zeros (32-bit)
    ctz32,
    /// Count trailing zeros (64-bit)
    ctz64,
    /// Count leading zeros (32-bit)
    clz32,
    /// Count leading zeros (64-bit)
    clz64,
    /// Population count / hamming weight (32-bit)
    popcnt32,
    /// Population count / hamming weight (64-bit)
    popcnt64,

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 6: Comparisons
    // All comparisons produce boolean results.
    // ═══════════════════════════════════════════════════════════════════════════

    // --- Generic Comparisons ---
    /// Equal: arg0 == arg1 (commutative)
    eq,
    /// Not equal: arg0 != arg1 (commutative)
    ne,
    /// Less than (signed): arg0 < arg1
    lt,
    /// Less or equal (signed): arg0 <= arg1
    le,
    /// Greater than (signed): arg0 > arg1
    gt,
    /// Greater or equal (signed): arg0 >= arg1
    ge,
    /// Less than (unsigned): arg0 < arg1
    ult,
    /// Less or equal (unsigned): arg0 <= arg1
    ule,
    /// Greater than (unsigned): arg0 > arg1
    ugt,
    /// Greater or equal (unsigned): arg0 >= arg1
    uge,

    // --- Sized Equality ---
    eq8,
    eq16,
    eq32,
    eq64,
    ne8,
    ne16,
    ne32,
    ne64,

    // --- Sized Ordering (signed) ---
    lt32,
    lt64,
    le32,
    le64,
    gt32,
    gt64,
    ge32,
    ge64,

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 7: Type Conversions
    // ═══════════════════════════════════════════════════════════════════════════

    // --- Sign Extension ---
    sign_ext8to16,
    sign_ext8to32,
    sign_ext8to64,
    sign_ext16to32,
    sign_ext16to64,
    sign_ext32to64,

    // --- Zero Extension ---
    zero_ext8to16,
    zero_ext8to32,
    zero_ext8to64,
    zero_ext16to32,
    zero_ext16to64,
    zero_ext32to64,

    // --- Truncation ---
    trunc16to8,
    trunc32to8,
    trunc32to16,
    trunc64to8,
    trunc64to16,
    trunc64to32,

    // --- Generic Conversion ---
    /// Generic type conversion. aux: target type
    convert,

    // --- Integer to Float ---
    /// int32 → float32
    cvt32to32f,
    /// int32 → float64
    cvt32to64f,
    /// int64 → float32
    cvt64to32f,
    /// int64 → float64
    cvt64to64f,

    // --- Float to Integer ---
    /// float32 → int32
    cvt32fto32,
    /// float32 → int64
    cvt32fto64,
    /// float64 → int32
    cvt64fto32,
    /// float64 → int64
    cvt64fto64,

    // --- Float to Float ---
    /// float32 → float64 (widen)
    cvt32fto64f,
    /// float64 → float32 (narrow)
    cvt64fto32f,

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 8: Floating Point Operations
    // ═══════════════════════════════════════════════════════════════════════════

    // --- 32-bit Float Arithmetic ---
    add32f,
    sub32f,
    mul32f,
    div32f,
    neg32f,
    sqrt32f,

    // --- 64-bit Float Arithmetic ---
    add64f,
    sub64f,
    mul64f,
    div64f,
    neg64f,
    sqrt64f,

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 9: Memory Operations
    // Go pattern: Load(ptr, mem) → value
    //            Store(ptr, value, mem) → mem
    // The memory argument threads memory state through SSA.
    // ═══════════════════════════════════════════════════════════════════════════

    // --- Generic Load/Store ---
    /// Load from memory: load(ptr, mem) → value
    load,
    /// Store to memory: store(ptr, value, mem) → mem
    store,

    // --- Sized Loads (zero-extending) ---
    load8,
    load16,
    load32,
    load64,

    // --- Sized Stores ---
    store8,
    store16,
    store32,
    store64,

    // --- Sign-Extending Loads ---
    /// Load 8-bit, sign extend to register width
    load8s,
    /// Load 16-bit, sign extend to register width
    load16s,
    /// Load 32-bit, sign extend to 64-bit
    load32s,

    // --- Address Computation ---
    /// Address of symbol. aux: symbol
    addr,
    /// Address of local variable. aux_int: stack offset
    local_addr,
    /// Address of global variable. aux: global symbol name
    global_addr,
    /// Pointer offset: ptr + aux_int
    off_ptr,
    /// Pointer + integer: arg0 + arg1
    add_ptr,
    /// Pointer - integer: arg0 - arg1
    sub_ptr,

    // --- Memory Operations with Write Barrier (for GC) ---
    /// Store with write barrier (notifies GC)
    store_wb,
    /// Bulk memory copy for non-SSA aggregates.
    /// Go reference: OpMove in opGen.go
    ///
    /// Args: [dest_addr, src_addr, mem]
    /// aux_int: size in bytes to copy
    /// Returns: new memory state
    ///
    /// Used by expand_calls for types that fail CanSSA (>32 bytes).
    /// These types cannot be loaded into registers, so we copy
    /// them directly in memory using LDP/STP loops.
    move,
    /// Zero memory: zero(ptr, mem) → mem. aux_int: size
    zero,

    // --- Variable Markers (for debugging) ---
    /// Variable definition. aux: variable name
    var_def,
    /// Variable is live at this point. aux: variable name
    var_live,
    /// Variable is dead after this point. aux: variable name
    var_kill,

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 10: Control Flow
    // ═══════════════════════════════════════════════════════════════════════════

    /// Phi node: select value based on control flow predecessor.
    /// Arguments correspond to block predecessors in order.
    phi,
    /// Copy value (inserted by register allocation)
    copy,
    /// Forward reference placeholder (used during IR→SSA conversion).
    /// Represents a use of a variable before its definition is known.
    /// aux_int: local variable index (frontend ir.LocalIdx)
    /// Resolved to phi or copy after all blocks are walked.
    fwd_ref,
    /// Function argument. aux_int: argument index
    arg,

    // --- Tuple Operations (for multi-return values) ---
    /// Extract first element of tuple
    select0,
    /// Extract second element of tuple
    select1,
    /// Create tuple from values
    make_tuple,

    /// Select Nth element from multi-register return (Go: OpSelectN).
    /// aux_int: index of element to select (0, 1, 2, ...)
    /// Used by expand_calls pass to decompose aggregate returns.
    select_n,

    /// Conditional select: if cond then arg1 else arg2
    /// Takes 3 args: condition (bool), then_value, else_value
    /// Lowered to ARM64 CSEL or x86-64 CMOV
    cond_select,

    // --- String/Slice Decomposition (Go: OpStringLen, OpStringPtr, OpSliceLen, etc.) ---
    /// Extract length from string. Takes string value, returns i64.
    string_len,
    /// Extract pointer from string. Takes string value, returns *u8.
    string_ptr,
    /// Create string from pointer and length. Takes (*u8, i64), returns string.
    string_make,

    /// Extract length from slice. Takes slice value, returns i64.
    slice_len,
    /// Extract pointer from slice. Takes slice value, returns *T.
    slice_ptr,
    /// Create slice from pointer and length. Takes (*T, i64), returns []T.
    slice_make,

    /// String concatenation: takes 2 string args, returns new string.
    /// Lowered to runtime call to __cot_str_concat.
    string_concat,

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 11: Function Calls
    // All call operations have side effects and may clobber registers.
    // ═══════════════════════════════════════════════════════════════════════════

    /// Generic function call. aux: [AuxCall]
    call,
    /// Tail call (no return). aux: [AuxCall]
    tail_call,
    /// Static function call. aux: symbol
    static_call,
    /// Closure call (function pointer + environment)
    closure_call,
    /// Interface method call (vtable dispatch)
    inter_call,

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 12: Safety Checks
    // ═══════════════════════════════════════════════════════════════════════════

    // --- Nil Checking ---
    /// Check if pointer is nil, panic if so. Has side effects.
    nil_check,
    /// Returns true if pointer is non-nil
    is_non_nil,
    /// Returns true if pointer is nil
    is_nil,

    // --- Bounds Checking ---
    /// Check array bounds: panic if index >= len
    bounds_check,
    /// Check slice bounds: panic if indices invalid
    slice_bounds,

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 13: Atomic Operations
    // All atomics have side effects and memory ordering guarantees.
    // ═══════════════════════════════════════════════════════════════════════════

    // --- Atomic Loads ---
    atomic_load32,
    atomic_load64,

    // --- Atomic Stores ---
    atomic_store32,
    atomic_store64,

    // --- Atomic Read-Modify-Write ---
    /// Atomic add, returns old value
    atomic_add32,
    atomic_add64,
    /// Compare and swap: if *ptr == old then *ptr = new
    atomic_cas32,
    atomic_cas64,
    /// Atomic exchange: swap *ptr with value
    atomic_exchange32,
    atomic_exchange64,

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 14: Register Allocation Operations
    // Inserted by regalloc pass, not present in initial SSA.
    // ═══════════════════════════════════════════════════════════════════════════

    /// Spill: store register to stack slot
    store_reg,
    /// Restore: load register from stack slot
    load_reg,

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 15: ARM64-Specific Operations (Lowered Form)
    // These replace generic ops after the "lower" pass.
    // Go reference: [cmd/compile/internal/ssa/_gen/ARM64Ops.go]
    // ═══════════════════════════════════════════════════════════════════════════

    arm64_add, // ADD Rd, Rn, Rm
    arm64_adds, // ADDS Rd, Rn, Rm (set flags)
    arm64_sub, // SUB Rd, Rn, Rm
    arm64_subs, // SUBS Rd, Rn, Rm (set flags)
    arm64_mul, // MUL Rd, Rn, Rm
    arm64_sdiv, // SDIV Rd, Rn, Rm
    arm64_udiv, // UDIV Rd, Rn, Rm
    arm64_madd, // MADD Rd, Rn, Rm, Ra (Rd = Ra + Rn*Rm)
    arm64_msub, // MSUB Rd, Rn, Rm, Ra (Rd = Ra - Rn*Rm)
    arm64_smulh, // SMULH (signed multiply high)
    arm64_umulh, // UMULH (unsigned multiply high)

    arm64_and, // AND Rd, Rn, Rm
    arm64_orr, // ORR Rd, Rn, Rm
    arm64_eor, // EOR Rd, Rn, Rm
    arm64_bic, // BIC Rd, Rn, Rm (bit clear)
    arm64_orn, // ORN Rd, Rn, Rm
    arm64_eon, // EON Rd, Rn, Rm
    arm64_mvn, // MVN Rd, Rm (bitwise not)

    arm64_lsl, // LSL Rd, Rn, Rm
    arm64_lsr, // LSR Rd, Rn, Rm
    arm64_asr, // ASR Rd, Rn, Rm
    arm64_ror, // ROR Rd, Rn, Rm
    arm64_lslimm, // LSL Rd, Rn, #imm
    arm64_lsrimm, // LSR Rd, Rn, #imm
    arm64_asrimm, // ASR Rd, Rn, #imm

    arm64_cmp, // CMP Rn, Rm (SUBS with Rd=XZR)
    arm64_cmn, // CMN Rn, Rm (ADDS with Rd=XZR)
    arm64_tst, // TST Rn, Rm (ANDS with Rd=XZR)

    arm64_movd, // MOV Rd, Rm (64-bit)
    arm64_movw, // MOV Wd, Wm (32-bit)
    arm64_movz, // MOVZ Rd, #imm, LSL #shift
    arm64_movn, // MOVN Rd, #imm, LSL #shift
    arm64_movk, // MOVK Rd, #imm, LSL #shift

    arm64_ldr, // LDR Rd, [Rn, #offset] (64-bit)
    arm64_ldrw, // LDR Wd, [Rn, #offset] (32-bit)
    arm64_ldrh, // LDRH Wd, [Rn, #offset] (16-bit)
    arm64_ldrb, // LDRB Wd, [Rn, #offset] (8-bit)
    arm64_ldrsw, // LDRSW Xd, [Rn, #offset] (signed 32-bit extend)
    arm64_ldrsh, // LDRSH Xd, [Rn, #offset] (signed 16-bit extend)
    arm64_ldrsb, // LDRSB Xd, [Rn, #offset] (signed 8-bit extend)
    arm64_ldp, // LDP (load pair)

    arm64_str, // STR Rd, [Rn, #offset] (64-bit)
    arm64_strw, // STR Wd, [Rn, #offset] (32-bit)
    arm64_strh, // STRH Wd, [Rn, #offset] (16-bit)
    arm64_strb, // STRB Wd, [Rn, #offset] (8-bit)
    arm64_stp, // STP (store pair)

    arm64_adrp, // ADRP Rd, symbol (page address)
    arm64_add_imm, // ADD Rd, Rn, #imm
    arm64_sub_imm, // SUB Rd, Rn, #imm

    arm64_bl, // BL target (branch and link)
    arm64_blr, // BLR Rn (branch and link register)
    arm64_br, // BR Rn (branch register)
    arm64_ret, // RET (return via LR)
    arm64_b, // B target (unconditional branch)
    arm64_bcond, // B.cond target (conditional branch)

    arm64_csel, // CSEL Rd, Rn, Rm, cond
    arm64_csinc, // CSINC Rd, Rn, Rm, cond
    arm64_csinv, // CSINV Rd, Rn, Rm, cond
    arm64_csneg, // CSNEG Rd, Rn, Rm, cond
    arm64_cset, // CSET Rd, cond (set to 1 if cond true)

    arm64_clz, // CLZ count leading zeros
    arm64_rbit, // RBIT reverse bits
    arm64_rev, // REV reverse bytes

    arm64_sxtb, // Sign extend byte
    arm64_sxth, // Sign extend halfword
    arm64_sxtw, // Sign extend word
    arm64_uxtb, // Zero extend byte
    arm64_uxth, // Zero extend halfword

    arm64_fadd, // Floating add
    arm64_fsub, // Floating subtract
    arm64_fmul, // Floating multiply
    arm64_fdiv, // Floating divide
    arm64_fneg, // Floating negate
    arm64_fsqrt, // Floating sqrt
    arm64_fcmp, // Floating compare
    arm64_fcvt, // Floating convert (between sizes)
    arm64_scvtf, // Signed int to float
    arm64_ucvtf, // Unsigned int to float
    arm64_fcvtzs, // Float to signed int (toward zero)
    arm64_fcvtzu, // Float to unsigned int (toward zero)

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 16: x86_64-Specific Operations (Lowered Form)
    // These replace generic ops after the "lower" pass.
    // Go reference: [cmd/compile/internal/ssa/_gen/AMD64Ops.go]
    // ═══════════════════════════════════════════════════════════════════════════

    // --- Arithmetic ---
    x86_64_add, // ADD
    x86_64_sub, // SUB
    x86_64_imul, // IMUL
    x86_64_idiv, // IDIV (signed divide)
    x86_64_div, // DIV (unsigned divide)

    x86_64_and, // AND
    x86_64_or, // OR
    x86_64_xor, // XOR
    x86_64_shl, // SHL
    x86_64_shr, // SHR
    x86_64_sar, // SAR

    x86_64_cmp, // CMP
    x86_64_test, // TEST

    x86_64_mov, // MOV
    x86_64_movzx, // MOVZX (zero extend)
    x86_64_movsx, // MOVSX (sign extend)
    x86_64_lea, // LEA (load effective address)

    x86_64_push, // PUSH
    x86_64_pop, // POP

    x86_64_call, // CALL
    x86_64_ret, // RET
    x86_64_jmp, // JMP

    x86_64_setcc, // SETcc (set byte on condition)
    x86_64_cmovcc, // CMOVcc (conditional move)

    /// Get operation info
    pub fn info(self: Op) OpInfo {
        return op_info_table[@intFromEnum(self)];
    }

    /// Returns true if this operation is a function call.
    /// Used by regalloc to query AuxCall for register constraints.
    /// Reference: Go's ssa/op.go opcodeTable[op].call
    pub fn isCall(self: Op) bool {
        return op_info_table[@intFromEnum(self)].call;
    }
};

/// Operation metadata.
/// Go reference: cmd/compile/internal/ssa/op.go lines 35-75
pub const OpInfo = struct {
    /// Display name
    name: []const u8 = "",

    /// Register constraints
    reg: RegInfo = .{},

    /// What aux/aux_int mean
    aux_type: AuxType = .none,

    /// Number of arguments (-1 = variable)
    arg_len: i8 = 0,

    /// Is this a generic (machine-independent) operation?
    generic: bool = true,

    /// Can this value be recomputed instead of loaded from spill?
    rematerializable: bool = false,

    /// Is arg order interchangeable? (e.g., add, mul)
    commutative: bool = false,

    /// Must output be in same register as arg[0]?
    result_in_arg0: bool = false,

    /// Does this operation clobber the flags register?
    clobber_flags: bool = false,

    /// Is this a function call?
    call: bool = false,

    /// Does this have side effects (can't eliminate even if unused)?
    has_side_effects: bool = false,

    /// Does this operation read from memory?
    /// Go reference: Memory operations take mem argument
    reads_memory: bool = false,

    /// Does this operation write to memory?
    /// Operations that write memory return a new memory state.
    writes_memory: bool = false,

    /// Is this a nil check operation?
    nil_check: bool = false,

    /// Is this a bounds check operation?
    fault_on_nil_arg0: bool = false,

    /// Does this use flags from a previous operation?
    uses_flags: bool = false,
};

/// Register constraints for an operation.
pub const RegInfo = struct {
    /// Input register constraints
    inputs: []const InputInfo = &.{},

    /// Output register constraints
    outputs: []const OutputInfo = &.{},

    /// Registers clobbered by this operation
    clobbers: RegMask = 0,
};

pub const InputInfo = struct {
    idx: usize, // Argument index
    regs: RegMask, // Allowed registers
};

pub const OutputInfo = struct {
    idx: usize, // Output index (usually 0)
    regs: RegMask, // Allowed registers
};

/// What auxiliary data means for an operation.
pub const AuxType = enum {
    none,
    bool_,
    int8,
    int16,
    int32,
    int64,
    float32,
    float64,
    string,
    symbol, // Symbol reference
    symbol_off, // Symbol + offset
    symbol_val_off, // Symbol + value + offset
    call, // AuxCall for function calls
    type_ref, // Type reference
    cond, // Condition code
    arch, // Architecture-specific data
};

// =========================================
// Operation info table
// =========================================

/// All general-purpose registers (ARM64 x0-x30)
const GP_REGS: RegMask = 0x7FFFFFFF;

/// Caller-saved registers (ARM64 x0-x18)
const CALLER_SAVED: RegMask = 0x0007FFFF;

const op_info_table = blk: {
    var table: [@typeInfo(Op).@"enum".fields.len]OpInfo = undefined;

    // Initialize all to default
    for (&table) |*info_entry| {
        info_entry.* = .{};
    }

    // Invalid
    table[@intFromEnum(Op.invalid)] = .{ .name = "Invalid" };

    // Memory state
    table[@intFromEnum(Op.init_mem)] = .{
        .name = "InitMem",
        .rematerializable = true,
    };

    // Constants (rematerializable)
    table[@intFromEnum(Op.const_bool)] = .{
        .name = "ConstBool",
        .aux_type = .int64,
        .rematerializable = true,
    };
    table[@intFromEnum(Op.const_int)] = .{
        .name = "ConstInt",
        .aux_type = .int64,
        .rematerializable = true,
    };
    table[@intFromEnum(Op.const_float)] = .{
        .name = "ConstFloat",
        .aux_type = .float64,
        .rematerializable = true,
    };
    table[@intFromEnum(Op.const_nil)] = .{
        .name = "ConstNil",
        .rematerializable = true,
    };
    table[@intFromEnum(Op.const_string)] = .{
        .name = "ConstString",
        .aux_type = .string,
        .rematerializable = true,
    };
    table[@intFromEnum(Op.const_ptr)] = .{
        .name = "ConstPtr",
        .aux_type = .symbol, // Symbol index for string literal relocation
        .rematerializable = true,
    };

    table[@intFromEnum(Op.const_8)] = .{ .name = "Const8", .aux_type = .int8, .rematerializable = true };
    table[@intFromEnum(Op.const_16)] = .{ .name = "Const16", .aux_type = .int16, .rematerializable = true };
    table[@intFromEnum(Op.const_32)] = .{ .name = "Const32", .aux_type = .int32, .rematerializable = true };
    table[@intFromEnum(Op.const_64)] = .{ .name = "Const64", .aux_type = .int64, .rematerializable = true };

    // Generic Arithmetic
    table[@intFromEnum(Op.add)] = .{ .name = "Add", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.sub)] = .{ .name = "Sub", .arg_len = 2 };
    table[@intFromEnum(Op.mul)] = .{ .name = "Mul", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.div)] = .{ .name = "Div", .arg_len = 2 };
    table[@intFromEnum(Op.udiv)] = .{ .name = "UDiv", .arg_len = 2 };
    table[@intFromEnum(Op.mod)] = .{ .name = "Mod", .arg_len = 2 };
    table[@intFromEnum(Op.umod)] = .{ .name = "UMod", .arg_len = 2 };
    table[@intFromEnum(Op.neg)] = .{ .name = "Neg", .arg_len = 1 };

    // Sized arithmetic
    table[@intFromEnum(Op.add8)] = .{ .name = "Add8", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.add16)] = .{ .name = "Add16", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.add32)] = .{ .name = "Add32", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.add64)] = .{ .name = "Add64", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.sub8)] = .{ .name = "Sub8", .arg_len = 2 };
    table[@intFromEnum(Op.sub16)] = .{ .name = "Sub16", .arg_len = 2 };
    table[@intFromEnum(Op.sub32)] = .{ .name = "Sub32", .arg_len = 2 };
    table[@intFromEnum(Op.sub64)] = .{ .name = "Sub64", .arg_len = 2 };
    table[@intFromEnum(Op.mul8)] = .{ .name = "Mul8", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.mul16)] = .{ .name = "Mul16", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.mul32)] = .{ .name = "Mul32", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.mul64)] = .{ .name = "Mul64", .arg_len = 2, .commutative = true };

    // High multiply
    table[@intFromEnum(Op.hmul32)] = .{ .name = "Hmul32", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.hmul32u)] = .{ .name = "Hmul32u", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.hmul64)] = .{ .name = "Hmul64", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.hmul64u)] = .{ .name = "Hmul64u", .arg_len = 2, .commutative = true };

    // Divmod
    table[@intFromEnum(Op.divmod32)] = .{ .name = "DivMod32", .arg_len = 2 };
    table[@intFromEnum(Op.divmod64)] = .{ .name = "DivMod64", .arg_len = 2 };
    table[@intFromEnum(Op.divmodu32)] = .{ .name = "DivModU32", .arg_len = 2 };
    table[@intFromEnum(Op.divmodu64)] = .{ .name = "DivModU64", .arg_len = 2 };

    // Bitwise
    table[@intFromEnum(Op.and_)] = .{ .name = "And", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.or_)] = .{ .name = "Or", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.xor)] = .{ .name = "Xor", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.shl)] = .{ .name = "Shl", .arg_len = 2 };
    table[@intFromEnum(Op.shr)] = .{ .name = "Shr", .arg_len = 2 };
    table[@intFromEnum(Op.sar)] = .{ .name = "Sar", .arg_len = 2 };
    table[@intFromEnum(Op.not)] = .{ .name = "Not", .arg_len = 1 };

    // Sized bitwise
    table[@intFromEnum(Op.and8)] = .{ .name = "And8", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.and16)] = .{ .name = "And16", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.and32)] = .{ .name = "And32", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.and64)] = .{ .name = "And64", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.or8)] = .{ .name = "Or8", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.or16)] = .{ .name = "Or16", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.or32)] = .{ .name = "Or32", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.or64)] = .{ .name = "Or64", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.xor8)] = .{ .name = "Xor8", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.xor16)] = .{ .name = "Xor16", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.xor32)] = .{ .name = "Xor32", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.xor64)] = .{ .name = "Xor64", .arg_len = 2, .commutative = true };

    // Sized shifts
    table[@intFromEnum(Op.shl8)] = .{ .name = "Shl8", .arg_len = 2 };
    table[@intFromEnum(Op.shl16)] = .{ .name = "Shl16", .arg_len = 2 };
    table[@intFromEnum(Op.shl32)] = .{ .name = "Shl32", .arg_len = 2 };
    table[@intFromEnum(Op.shl64)] = .{ .name = "Shl64", .arg_len = 2 };
    table[@intFromEnum(Op.shr8)] = .{ .name = "Shr8", .arg_len = 2 };
    table[@intFromEnum(Op.shr16)] = .{ .name = "Shr16", .arg_len = 2 };
    table[@intFromEnum(Op.shr32)] = .{ .name = "Shr32", .arg_len = 2 };
    table[@intFromEnum(Op.shr64)] = .{ .name = "Shr64", .arg_len = 2 };
    table[@intFromEnum(Op.sar8)] = .{ .name = "Sar8", .arg_len = 2 };
    table[@intFromEnum(Op.sar16)] = .{ .name = "Sar16", .arg_len = 2 };
    table[@intFromEnum(Op.sar32)] = .{ .name = "Sar32", .arg_len = 2 };
    table[@intFromEnum(Op.sar64)] = .{ .name = "Sar64", .arg_len = 2 };

    // Complement
    table[@intFromEnum(Op.com8)] = .{ .name = "Com8", .arg_len = 1 };
    table[@intFromEnum(Op.com16)] = .{ .name = "Com16", .arg_len = 1 };
    table[@intFromEnum(Op.com32)] = .{ .name = "Com32", .arg_len = 1 };
    table[@intFromEnum(Op.com64)] = .{ .name = "Com64", .arg_len = 1 };

    // Bit counting
    table[@intFromEnum(Op.ctz32)] = .{ .name = "Ctz32", .arg_len = 1 };
    table[@intFromEnum(Op.ctz64)] = .{ .name = "Ctz64", .arg_len = 1 };
    table[@intFromEnum(Op.clz32)] = .{ .name = "Clz32", .arg_len = 1 };
    table[@intFromEnum(Op.clz64)] = .{ .name = "Clz64", .arg_len = 1 };
    table[@intFromEnum(Op.popcnt32)] = .{ .name = "PopCnt32", .arg_len = 1 };
    table[@intFromEnum(Op.popcnt64)] = .{ .name = "PopCnt64", .arg_len = 1 };

    // Comparison
    table[@intFromEnum(Op.eq)] = .{ .name = "Eq", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.ne)] = .{ .name = "Ne", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.lt)] = .{ .name = "Lt", .arg_len = 2 };
    table[@intFromEnum(Op.le)] = .{ .name = "Le", .arg_len = 2 };
    table[@intFromEnum(Op.gt)] = .{ .name = "Gt", .arg_len = 2 };
    table[@intFromEnum(Op.ge)] = .{ .name = "Ge", .arg_len = 2 };
    table[@intFromEnum(Op.ult)] = .{ .name = "ULt", .arg_len = 2 };
    table[@intFromEnum(Op.ule)] = .{ .name = "ULe", .arg_len = 2 };
    table[@intFromEnum(Op.ugt)] = .{ .name = "UGt", .arg_len = 2 };
    table[@intFromEnum(Op.uge)] = .{ .name = "UGe", .arg_len = 2 };

    // Sized comparisons
    table[@intFromEnum(Op.eq8)] = .{ .name = "Eq8", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.eq16)] = .{ .name = "Eq16", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.eq32)] = .{ .name = "Eq32", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.eq64)] = .{ .name = "Eq64", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.ne8)] = .{ .name = "Ne8", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.ne16)] = .{ .name = "Ne16", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.ne32)] = .{ .name = "Ne32", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.ne64)] = .{ .name = "Ne64", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.lt32)] = .{ .name = "Lt32", .arg_len = 2 };
    table[@intFromEnum(Op.lt64)] = .{ .name = "Lt64", .arg_len = 2 };
    table[@intFromEnum(Op.le32)] = .{ .name = "Le32", .arg_len = 2 };
    table[@intFromEnum(Op.le64)] = .{ .name = "Le64", .arg_len = 2 };
    table[@intFromEnum(Op.gt32)] = .{ .name = "Gt32", .arg_len = 2 };
    table[@intFromEnum(Op.gt64)] = .{ .name = "Gt64", .arg_len = 2 };
    table[@intFromEnum(Op.ge32)] = .{ .name = "Ge32", .arg_len = 2 };
    table[@intFromEnum(Op.ge64)] = .{ .name = "Ge64", .arg_len = 2 };

    // Sign/zero extension
    table[@intFromEnum(Op.sign_ext8to16)] = .{ .name = "SignExt8to16", .arg_len = 1 };
    table[@intFromEnum(Op.sign_ext8to32)] = .{ .name = "SignExt8to32", .arg_len = 1 };
    table[@intFromEnum(Op.sign_ext8to64)] = .{ .name = "SignExt8to64", .arg_len = 1 };
    table[@intFromEnum(Op.sign_ext16to32)] = .{ .name = "SignExt16to32", .arg_len = 1 };
    table[@intFromEnum(Op.sign_ext16to64)] = .{ .name = "SignExt16to64", .arg_len = 1 };
    table[@intFromEnum(Op.sign_ext32to64)] = .{ .name = "SignExt32to64", .arg_len = 1 };
    table[@intFromEnum(Op.zero_ext8to16)] = .{ .name = "ZeroExt8to16", .arg_len = 1 };
    table[@intFromEnum(Op.zero_ext8to32)] = .{ .name = "ZeroExt8to32", .arg_len = 1 };
    table[@intFromEnum(Op.zero_ext8to64)] = .{ .name = "ZeroExt8to64", .arg_len = 1 };
    table[@intFromEnum(Op.zero_ext16to32)] = .{ .name = "ZeroExt16to32", .arg_len = 1 };
    table[@intFromEnum(Op.zero_ext16to64)] = .{ .name = "ZeroExt16to64", .arg_len = 1 };
    table[@intFromEnum(Op.zero_ext32to64)] = .{ .name = "ZeroExt32to64", .arg_len = 1 };

    // Truncation
    table[@intFromEnum(Op.trunc16to8)] = .{ .name = "Trunc16to8", .arg_len = 1 };
    table[@intFromEnum(Op.trunc32to8)] = .{ .name = "Trunc32to8", .arg_len = 1 };
    table[@intFromEnum(Op.trunc32to16)] = .{ .name = "Trunc32to16", .arg_len = 1 };
    table[@intFromEnum(Op.trunc64to8)] = .{ .name = "Trunc64to8", .arg_len = 1 };
    table[@intFromEnum(Op.trunc64to16)] = .{ .name = "Trunc64to16", .arg_len = 1 };
    table[@intFromEnum(Op.trunc64to32)] = .{ .name = "Trunc64to32", .arg_len = 1 };

    // Type conversion
    table[@intFromEnum(Op.convert)] = .{ .name = "Convert", .arg_len = 1, .aux_type = .type_ref };
    table[@intFromEnum(Op.cvt32to32f)] = .{ .name = "Cvt32to32F", .arg_len = 1 };
    table[@intFromEnum(Op.cvt32to64f)] = .{ .name = "Cvt32to64F", .arg_len = 1 };
    table[@intFromEnum(Op.cvt64to32f)] = .{ .name = "Cvt64to32F", .arg_len = 1 };
    table[@intFromEnum(Op.cvt64to64f)] = .{ .name = "Cvt64to64F", .arg_len = 1 };
    table[@intFromEnum(Op.cvt32fto32)] = .{ .name = "Cvt32Fto32", .arg_len = 1 };
    table[@intFromEnum(Op.cvt32fto64)] = .{ .name = "Cvt32Fto64", .arg_len = 1 };
    table[@intFromEnum(Op.cvt64fto32)] = .{ .name = "Cvt64Fto32", .arg_len = 1 };
    table[@intFromEnum(Op.cvt64fto64)] = .{ .name = "Cvt64Fto64", .arg_len = 1 };
    table[@intFromEnum(Op.cvt32fto64f)] = .{ .name = "Cvt32Fto64F", .arg_len = 1 };
    table[@intFromEnum(Op.cvt64fto32f)] = .{ .name = "Cvt64Fto32F", .arg_len = 1 };

    // Floating point
    table[@intFromEnum(Op.add32f)] = .{ .name = "Add32F", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.add64f)] = .{ .name = "Add64F", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.sub32f)] = .{ .name = "Sub32F", .arg_len = 2 };
    table[@intFromEnum(Op.sub64f)] = .{ .name = "Sub64F", .arg_len = 2 };
    table[@intFromEnum(Op.mul32f)] = .{ .name = "Mul32F", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.mul64f)] = .{ .name = "Mul64F", .arg_len = 2, .commutative = true };
    table[@intFromEnum(Op.div32f)] = .{ .name = "Div32F", .arg_len = 2 };
    table[@intFromEnum(Op.div64f)] = .{ .name = "Div64F", .arg_len = 2 };
    table[@intFromEnum(Op.neg32f)] = .{ .name = "Neg32F", .arg_len = 1 };
    table[@intFromEnum(Op.neg64f)] = .{ .name = "Neg64F", .arg_len = 1 };
    table[@intFromEnum(Op.sqrt32f)] = .{ .name = "Sqrt32F", .arg_len = 1 };
    table[@intFromEnum(Op.sqrt64f)] = .{ .name = "Sqrt64F", .arg_len = 1 };

    // Memory operations - these take memory argument and may return new memory
    table[@intFromEnum(Op.load)] = .{
        .name = "Load",
        .arg_len = 2, // (ptr, mem)
        .aux_type = .int64,
        .reads_memory = true,
    };
    table[@intFromEnum(Op.store)] = .{
        .name = "Store",
        .arg_len = 3, // (ptr, value, mem)
        .aux_type = .int64,
        .writes_memory = true,
        .has_side_effects = true,
    };
    table[@intFromEnum(Op.load8)] = .{ .name = "Load8", .arg_len = 2, .reads_memory = true };
    table[@intFromEnum(Op.load16)] = .{ .name = "Load16", .arg_len = 2, .reads_memory = true };
    table[@intFromEnum(Op.load32)] = .{ .name = "Load32", .arg_len = 2, .reads_memory = true };
    table[@intFromEnum(Op.load64)] = .{ .name = "Load64", .arg_len = 2, .reads_memory = true };
    table[@intFromEnum(Op.store8)] = .{ .name = "Store8", .arg_len = 3, .writes_memory = true, .has_side_effects = true };
    table[@intFromEnum(Op.store16)] = .{ .name = "Store16", .arg_len = 3, .writes_memory = true, .has_side_effects = true };
    table[@intFromEnum(Op.store32)] = .{ .name = "Store32", .arg_len = 3, .writes_memory = true, .has_side_effects = true };
    table[@intFromEnum(Op.store64)] = .{ .name = "Store64", .arg_len = 3, .writes_memory = true, .has_side_effects = true };

    table[@intFromEnum(Op.load8s)] = .{ .name = "Load8S", .arg_len = 2, .reads_memory = true };
    table[@intFromEnum(Op.load16s)] = .{ .name = "Load16S", .arg_len = 2, .reads_memory = true };
    table[@intFromEnum(Op.load32s)] = .{ .name = "Load32S", .arg_len = 2, .reads_memory = true };

    // Address operations
    table[@intFromEnum(Op.addr)] = .{ .name = "Addr", .aux_type = .symbol, .rematerializable = true };
    table[@intFromEnum(Op.local_addr)] = .{ .name = "LocalAddr", .aux_type = .int64, .rematerializable = true };
    table[@intFromEnum(Op.global_addr)] = .{ .name = "GlobalAddr", .aux_type = .symbol, .rematerializable = true };
    table[@intFromEnum(Op.off_ptr)] = .{ .name = "OffPtr", .arg_len = 1, .aux_type = .int64 };
    table[@intFromEnum(Op.add_ptr)] = .{ .name = "AddPtr", .arg_len = 2 };
    table[@intFromEnum(Op.sub_ptr)] = .{ .name = "SubPtr", .arg_len = 2 };

    // Memory with write barrier
    table[@intFromEnum(Op.store_wb)] = .{
        .name = "StoreWB",
        .arg_len = 3,
        .writes_memory = true,
        .has_side_effects = true,
    };
    table[@intFromEnum(Op.move)] = .{
        .name = "Move",
        .arg_len = 3, // (dst, src, mem)
        .aux_type = .int64,
        .reads_memory = true,
        .writes_memory = true,
        .has_side_effects = true,
    };
    table[@intFromEnum(Op.zero)] = .{
        .name = "Zero",
        .arg_len = 2, // (ptr, mem)
        .aux_type = .int64,
        .writes_memory = true,
        .has_side_effects = true,
    };

    // Variable markers
    table[@intFromEnum(Op.var_def)] = .{ .name = "VarDef", .aux_type = .symbol, .has_side_effects = true };
    table[@intFromEnum(Op.var_live)] = .{ .name = "VarLive", .aux_type = .symbol, .has_side_effects = true };
    table[@intFromEnum(Op.var_kill)] = .{ .name = "VarKill", .aux_type = .symbol, .has_side_effects = true };

    // Control flow
    table[@intFromEnum(Op.phi)] = .{ .name = "Phi", .arg_len = -1 };
    table[@intFromEnum(Op.copy)] = .{ .name = "Copy", .arg_len = 1 };
    table[@intFromEnum(Op.fwd_ref)] = .{ .name = "FwdRef", .aux_type = .int64 }; // aux_int = local idx
    table[@intFromEnum(Op.arg)] = .{ .name = "Arg", .aux_type = .int64 };

    // Tuple operations
    table[@intFromEnum(Op.select0)] = .{ .name = "Select0", .arg_len = 1 };
    table[@intFromEnum(Op.select1)] = .{ .name = "Select1", .arg_len = 1 };
    table[@intFromEnum(Op.make_tuple)] = .{ .name = "MakeTuple", .arg_len = 2 };
    table[@intFromEnum(Op.select_n)] = .{
        .name = "SelectN",
        .arg_len = 1,
        .aux_type = .int64, // index of element to select
    };
    table[@intFromEnum(Op.cond_select)] = .{ .name = "CondSelect", .arg_len = 3 };

    // String decomposition (Go: OpStringLen, OpStringPtr, OpStringMake)
    table[@intFromEnum(Op.string_len)] = .{ .name = "StringLen", .arg_len = 1 };
    table[@intFromEnum(Op.string_ptr)] = .{ .name = "StringPtr", .arg_len = 1 };
    table[@intFromEnum(Op.string_make)] = .{ .name = "StringMake", .arg_len = 2 };

    table[@intFromEnum(Op.slice_len)] = .{ .name = "SliceLen", .arg_len = 1 };
    table[@intFromEnum(Op.slice_ptr)] = .{ .name = "SlicePtr", .arg_len = 1 };
    table[@intFromEnum(Op.slice_make)] = .{ .name = "SliceMake", .arg_len = 2 };
    table[@intFromEnum(Op.string_concat)] = .{
        .name = "StringConcat",
        .arg_len = 2,
        .call = true, // Calls __cot_str_concat runtime
        .has_side_effects = true,
        .reads_memory = true,
        .writes_memory = true,
    };

    // Calls
    table[@intFromEnum(Op.call)] = .{
        .name = "Call",
        .arg_len = -1,
        .aux_type = .call,
        .call = true,
        .reads_memory = true,
        .writes_memory = true,
        .has_side_effects = true,
        .reg = .{ .clobbers = CALLER_SAVED },
    };
    table[@intFromEnum(Op.tail_call)] = .{
        .name = "TailCall",
        .arg_len = -1,
        .aux_type = .call,
        .call = true,
        .reads_memory = true,
        .writes_memory = true,
        .has_side_effects = true,
    };
    table[@intFromEnum(Op.static_call)] = .{
        .name = "StaticCall",
        .arg_len = -1,
        .aux_type = .symbol,
        .call = true,
        .reads_memory = true,
        .writes_memory = true,
        .has_side_effects = true,
        .reg = .{ .clobbers = CALLER_SAVED },
    };
    table[@intFromEnum(Op.closure_call)] = .{
        .name = "ClosureCall",
        .arg_len = -1,
        .call = true,
        .reads_memory = true,
        .writes_memory = true,
        .has_side_effects = true,
        .reg = .{ .clobbers = CALLER_SAVED },
    };
    table[@intFromEnum(Op.inter_call)] = .{
        .name = "InterCall",
        .arg_len = -1,
        .call = true,
        .reads_memory = true,
        .writes_memory = true,
        .has_side_effects = true,
        .reg = .{ .clobbers = CALLER_SAVED },
    };

    // Nil checking
    table[@intFromEnum(Op.nil_check)] = .{
        .name = "NilCheck",
        .arg_len = 2, // (ptr, mem)
        .nil_check = true,
        .fault_on_nil_arg0 = true,
        .has_side_effects = true,
    };
    table[@intFromEnum(Op.is_non_nil)] = .{ .name = "IsNonNil", .arg_len = 1 };
    table[@intFromEnum(Op.is_nil)] = .{ .name = "IsNil", .arg_len = 1 };

    // Bounds checking
    table[@intFromEnum(Op.bounds_check)] = .{
        .name = "BoundsCheck",
        .arg_len = 2,
        .has_side_effects = true,
    };
    table[@intFromEnum(Op.slice_bounds)] = .{
        .name = "SliceBounds",
        .arg_len = 3,
        .has_side_effects = true,
    };

    // Atomics
    table[@intFromEnum(Op.atomic_load32)] = .{ .name = "AtomicLoad32", .arg_len = 2, .reads_memory = true };
    table[@intFromEnum(Op.atomic_load64)] = .{ .name = "AtomicLoad64", .arg_len = 2, .reads_memory = true };
    table[@intFromEnum(Op.atomic_store32)] = .{ .name = "AtomicStore32", .arg_len = 3, .writes_memory = true, .has_side_effects = true };
    table[@intFromEnum(Op.atomic_store64)] = .{ .name = "AtomicStore64", .arg_len = 3, .writes_memory = true, .has_side_effects = true };
    table[@intFromEnum(Op.atomic_add32)] = .{ .name = "AtomicAdd32", .arg_len = 3, .reads_memory = true, .writes_memory = true, .has_side_effects = true };
    table[@intFromEnum(Op.atomic_add64)] = .{ .name = "AtomicAdd64", .arg_len = 3, .reads_memory = true, .writes_memory = true, .has_side_effects = true };
    table[@intFromEnum(Op.atomic_cas32)] = .{ .name = "AtomicCAS32", .arg_len = 4, .reads_memory = true, .writes_memory = true, .has_side_effects = true };
    table[@intFromEnum(Op.atomic_cas64)] = .{ .name = "AtomicCAS64", .arg_len = 4, .reads_memory = true, .writes_memory = true, .has_side_effects = true };
    table[@intFromEnum(Op.atomic_exchange32)] = .{ .name = "AtomicExchange32", .arg_len = 3, .reads_memory = true, .writes_memory = true, .has_side_effects = true };
    table[@intFromEnum(Op.atomic_exchange64)] = .{ .name = "AtomicExchange64", .arg_len = 3, .reads_memory = true, .writes_memory = true, .has_side_effects = true };

    // Spill/restore
    table[@intFromEnum(Op.store_reg)] = .{ .name = "StoreReg", .arg_len = 1, .has_side_effects = true };
    table[@intFromEnum(Op.load_reg)] = .{ .name = "LoadReg", .arg_len = 1 };

    // ARM64-specific
    table[@intFromEnum(Op.arm64_add)] = .{
        .name = "ARM64ADD",
        .arg_len = 2,
        .generic = false,
        .commutative = true,
        .reg = .{
            .inputs = &.{
                .{ .idx = 0, .regs = GP_REGS },
                .{ .idx = 1, .regs = GP_REGS },
            },
            .outputs = &.{
                .{ .idx = 0, .regs = GP_REGS },
            },
        },
    };
    table[@intFromEnum(Op.arm64_adds)] = .{ .name = "ARM64ADDS", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.arm64_sub)] = .{
        .name = "ARM64SUB",
        .arg_len = 2,
        .generic = false,
        .reg = .{
            .inputs = &.{
                .{ .idx = 0, .regs = GP_REGS },
                .{ .idx = 1, .regs = GP_REGS },
            },
            .outputs = &.{
                .{ .idx = 0, .regs = GP_REGS },
            },
        },
    };
    table[@intFromEnum(Op.arm64_subs)] = .{ .name = "ARM64SUBS", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.arm64_mul)] = .{ .name = "ARM64MUL", .arg_len = 2, .generic = false, .commutative = true };
    table[@intFromEnum(Op.arm64_sdiv)] = .{ .name = "ARM64SDIV", .arg_len = 2, .generic = false };
    table[@intFromEnum(Op.arm64_udiv)] = .{ .name = "ARM64UDIV", .arg_len = 2, .generic = false };
    table[@intFromEnum(Op.arm64_madd)] = .{ .name = "ARM64MADD", .arg_len = 3, .generic = false };
    table[@intFromEnum(Op.arm64_msub)] = .{ .name = "ARM64MSUB", .arg_len = 3, .generic = false };
    table[@intFromEnum(Op.arm64_smulh)] = .{ .name = "ARM64SMULH", .arg_len = 2, .generic = false };
    table[@intFromEnum(Op.arm64_umulh)] = .{ .name = "ARM64UMULH", .arg_len = 2, .generic = false };

    table[@intFromEnum(Op.arm64_and)] = .{ .name = "ARM64AND", .arg_len = 2, .generic = false, .commutative = true };
    table[@intFromEnum(Op.arm64_orr)] = .{ .name = "ARM64ORR", .arg_len = 2, .generic = false, .commutative = true };
    table[@intFromEnum(Op.arm64_eor)] = .{ .name = "ARM64EOR", .arg_len = 2, .generic = false, .commutative = true };
    table[@intFromEnum(Op.arm64_bic)] = .{ .name = "ARM64BIC", .arg_len = 2, .generic = false };
    table[@intFromEnum(Op.arm64_orn)] = .{ .name = "ARM64ORN", .arg_len = 2, .generic = false };
    table[@intFromEnum(Op.arm64_eon)] = .{ .name = "ARM64EON", .arg_len = 2, .generic = false };
    table[@intFromEnum(Op.arm64_mvn)] = .{ .name = "ARM64MVN", .arg_len = 1, .generic = false };

    table[@intFromEnum(Op.arm64_lsl)] = .{ .name = "ARM64LSL", .arg_len = 2, .generic = false };
    table[@intFromEnum(Op.arm64_lsr)] = .{ .name = "ARM64LSR", .arg_len = 2, .generic = false };
    table[@intFromEnum(Op.arm64_asr)] = .{ .name = "ARM64ASR", .arg_len = 2, .generic = false };
    table[@intFromEnum(Op.arm64_ror)] = .{ .name = "ARM64ROR", .arg_len = 2, .generic = false };
    table[@intFromEnum(Op.arm64_lslimm)] = .{ .name = "ARM64LSLimm", .arg_len = 1, .aux_type = .int64, .generic = false };
    table[@intFromEnum(Op.arm64_lsrimm)] = .{ .name = "ARM64LSRimm", .arg_len = 1, .aux_type = .int64, .generic = false };
    table[@intFromEnum(Op.arm64_asrimm)] = .{ .name = "ARM64ASRimm", .arg_len = 1, .aux_type = .int64, .generic = false };

    table[@intFromEnum(Op.arm64_cmp)] = .{ .name = "ARM64CMP", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.arm64_cmn)] = .{ .name = "ARM64CMN", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.arm64_tst)] = .{ .name = "ARM64TST", .arg_len = 2, .generic = false, .clobber_flags = true };

    table[@intFromEnum(Op.arm64_movd)] = .{ .name = "ARM64MOVDreg", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.arm64_movw)] = .{ .name = "ARM64MOVWreg", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.arm64_movz)] = .{ .name = "ARM64MOVZ", .aux_type = .int64, .generic = false, .rematerializable = true };
    table[@intFromEnum(Op.arm64_movn)] = .{ .name = "ARM64MOVN", .aux_type = .int64, .generic = false, .rematerializable = true };
    table[@intFromEnum(Op.arm64_movk)] = .{ .name = "ARM64MOVK", .arg_len = 1, .aux_type = .int64, .generic = false };

    table[@intFromEnum(Op.arm64_ldr)] = .{
        .name = "ARM64LDR",
        .arg_len = 2, // (ptr, mem)
        .generic = false,
        .aux_type = .int64,
        .reads_memory = true,
        .reg = .{
            .inputs = &.{ .{ .idx = 0, .regs = GP_REGS } },
            .outputs = &.{ .{ .idx = 0, .regs = GP_REGS } },
        },
    };
    table[@intFromEnum(Op.arm64_ldrw)] = .{ .name = "ARM64LDRW", .arg_len = 2, .generic = false, .reads_memory = true };
    table[@intFromEnum(Op.arm64_ldrh)] = .{ .name = "ARM64LDRH", .arg_len = 2, .generic = false, .reads_memory = true };
    table[@intFromEnum(Op.arm64_ldrb)] = .{ .name = "ARM64LDRB", .arg_len = 2, .generic = false, .reads_memory = true };
    table[@intFromEnum(Op.arm64_ldrsw)] = .{ .name = "ARM64LDRSW", .arg_len = 2, .generic = false, .reads_memory = true };
    table[@intFromEnum(Op.arm64_ldrsh)] = .{ .name = "ARM64LDRSH", .arg_len = 2, .generic = false, .reads_memory = true };
    table[@intFromEnum(Op.arm64_ldrsb)] = .{ .name = "ARM64LDRSB", .arg_len = 2, .generic = false, .reads_memory = true };
    table[@intFromEnum(Op.arm64_ldp)] = .{ .name = "ARM64LDP", .arg_len = 2, .generic = false, .reads_memory = true };

    table[@intFromEnum(Op.arm64_str)] = .{
        .name = "ARM64STR",
        .arg_len = 3, // (ptr, value, mem)
        .generic = false,
        .aux_type = .int64,
        .writes_memory = true,
        .has_side_effects = true,
        .reg = .{
            .inputs = &.{
                .{ .idx = 0, .regs = GP_REGS },
                .{ .idx = 1, .regs = GP_REGS },
            },
        },
    };
    table[@intFromEnum(Op.arm64_strw)] = .{ .name = "ARM64STRW", .arg_len = 3, .generic = false, .writes_memory = true, .has_side_effects = true };
    table[@intFromEnum(Op.arm64_strh)] = .{ .name = "ARM64STRH", .arg_len = 3, .generic = false, .writes_memory = true, .has_side_effects = true };
    table[@intFromEnum(Op.arm64_strb)] = .{ .name = "ARM64STRB", .arg_len = 3, .generic = false, .writes_memory = true, .has_side_effects = true };
    table[@intFromEnum(Op.arm64_stp)] = .{ .name = "ARM64STP", .arg_len = 4, .generic = false, .writes_memory = true, .has_side_effects = true };

    table[@intFromEnum(Op.arm64_adrp)] = .{ .name = "ARM64ADRP", .aux_type = .symbol, .generic = false, .rematerializable = true };
    table[@intFromEnum(Op.arm64_add_imm)] = .{ .name = "ARM64ADDconst", .arg_len = 1, .aux_type = .int64, .generic = false };
    table[@intFromEnum(Op.arm64_sub_imm)] = .{ .name = "ARM64SUBconst", .arg_len = 1, .aux_type = .int64, .generic = false };

    table[@intFromEnum(Op.arm64_bl)] = .{
        .name = "ARM64BL",
        .arg_len = -1,
        .generic = false,
        .call = true,
        .reads_memory = true,
        .writes_memory = true,
        .has_side_effects = true,
        .reg = .{ .clobbers = CALLER_SAVED },
    };
    table[@intFromEnum(Op.arm64_blr)] = .{ .name = "ARM64BLR", .arg_len = -1, .generic = false, .call = true, .has_side_effects = true };
    table[@intFromEnum(Op.arm64_br)] = .{ .name = "ARM64BR", .arg_len = 1, .generic = false, .has_side_effects = true };
    table[@intFromEnum(Op.arm64_ret)] = .{ .name = "ARM64RET", .generic = false, .has_side_effects = true };
    table[@intFromEnum(Op.arm64_b)] = .{ .name = "ARM64B", .generic = false, .has_side_effects = true };
    table[@intFromEnum(Op.arm64_bcond)] = .{ .name = "ARM64Bcond", .aux_type = .cond, .generic = false, .uses_flags = true, .has_side_effects = true };

    table[@intFromEnum(Op.arm64_csel)] = .{ .name = "ARM64CSEL", .arg_len = 2, .aux_type = .cond, .generic = false, .uses_flags = true };
    table[@intFromEnum(Op.arm64_csinc)] = .{ .name = "ARM64CSINC", .arg_len = 2, .aux_type = .cond, .generic = false, .uses_flags = true };
    table[@intFromEnum(Op.arm64_csinv)] = .{ .name = "ARM64CSINV", .arg_len = 2, .aux_type = .cond, .generic = false, .uses_flags = true };
    table[@intFromEnum(Op.arm64_csneg)] = .{ .name = "ARM64CSNEG", .arg_len = 2, .aux_type = .cond, .generic = false, .uses_flags = true };
    table[@intFromEnum(Op.arm64_cset)] = .{ .name = "ARM64CSET", .aux_type = .cond, .generic = false, .uses_flags = true };

    table[@intFromEnum(Op.arm64_clz)] = .{ .name = "ARM64CLZ", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.arm64_rbit)] = .{ .name = "ARM64RBIT", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.arm64_rev)] = .{ .name = "ARM64REV", .arg_len = 1, .generic = false };

    table[@intFromEnum(Op.arm64_sxtb)] = .{ .name = "ARM64SXTB", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.arm64_sxth)] = .{ .name = "ARM64SXTH", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.arm64_sxtw)] = .{ .name = "ARM64SXTW", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.arm64_uxtb)] = .{ .name = "ARM64UXTB", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.arm64_uxth)] = .{ .name = "ARM64UXTH", .arg_len = 1, .generic = false };

    // ARM64 floating point
    table[@intFromEnum(Op.arm64_fadd)] = .{ .name = "ARM64FADD", .arg_len = 2, .generic = false, .commutative = true };
    table[@intFromEnum(Op.arm64_fsub)] = .{ .name = "ARM64FSUB", .arg_len = 2, .generic = false };
    table[@intFromEnum(Op.arm64_fmul)] = .{ .name = "ARM64FMUL", .arg_len = 2, .generic = false, .commutative = true };
    table[@intFromEnum(Op.arm64_fdiv)] = .{ .name = "ARM64FDIV", .arg_len = 2, .generic = false };
    table[@intFromEnum(Op.arm64_fneg)] = .{ .name = "ARM64FNEG", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.arm64_fsqrt)] = .{ .name = "ARM64FSQRT", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.arm64_fcmp)] = .{ .name = "ARM64FCMP", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.arm64_fcvt)] = .{ .name = "ARM64FCVT", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.arm64_scvtf)] = .{ .name = "ARM64SCVTF", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.arm64_ucvtf)] = .{ .name = "ARM64UCVTF", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.arm64_fcvtzs)] = .{ .name = "ARM64FCVTZS", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.arm64_fcvtzu)] = .{ .name = "ARM64FCVTZU", .arg_len = 1, .generic = false };

    // x86_64 operations (basic entries)
    table[@intFromEnum(Op.x86_64_add)] = .{ .name = "x86_64ADD", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.x86_64_sub)] = .{ .name = "x86_64SUB", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.x86_64_imul)] = .{ .name = "x86_64IMUL", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.x86_64_idiv)] = .{ .name = "x86_64IDIV", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.x86_64_div)] = .{ .name = "x86_64DIV", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.x86_64_and)] = .{ .name = "x86_64AND", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.x86_64_or)] = .{ .name = "x86_64OR", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.x86_64_xor)] = .{ .name = "x86_64XOR", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.x86_64_shl)] = .{ .name = "x86_64SHL", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.x86_64_shr)] = .{ .name = "x86_64SHR", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.x86_64_sar)] = .{ .name = "x86_64SAR", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.x86_64_cmp)] = .{ .name = "x86_64CMP", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.x86_64_test)] = .{ .name = "x86_64TEST", .arg_len = 2, .generic = false, .clobber_flags = true };
    table[@intFromEnum(Op.x86_64_mov)] = .{ .name = "x86_64MOV", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.x86_64_movzx)] = .{ .name = "x86_64MOVZX", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.x86_64_movsx)] = .{ .name = "x86_64MOVSX", .arg_len = 1, .generic = false };
    table[@intFromEnum(Op.x86_64_lea)] = .{ .name = "x86_64LEA", .arg_len = 1, .aux_type = .symbol_off, .generic = false };
    table[@intFromEnum(Op.x86_64_push)] = .{ .name = "x86_64PUSH", .arg_len = 1, .generic = false, .has_side_effects = true };
    table[@intFromEnum(Op.x86_64_pop)] = .{ .name = "x86_64POP", .generic = false, .has_side_effects = true };
    table[@intFromEnum(Op.x86_64_call)] = .{ .name = "x86_64CALL", .arg_len = -1, .generic = false, .call = true, .has_side_effects = true };
    table[@intFromEnum(Op.x86_64_ret)] = .{ .name = "x86_64RET", .generic = false, .has_side_effects = true };
    table[@intFromEnum(Op.x86_64_jmp)] = .{ .name = "x86_64JMP", .generic = false, .has_side_effects = true };
    table[@intFromEnum(Op.x86_64_setcc)] = .{ .name = "x86_64SETcc", .aux_type = .cond, .generic = false, .uses_flags = true };
    table[@intFromEnum(Op.x86_64_cmovcc)] = .{ .name = "x86_64CMOVcc", .arg_len = 2, .aux_type = .cond, .generic = false, .uses_flags = true };

    break :blk table;
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests - Table-Driven (Go pattern)
// ═══════════════════════════════════════════════════════════════════════════

/// Test case for operation properties.
const OpTestCase = struct {
    op: Op,
    name: []const u8,
    arg_len: i8,
    commutative: bool = false,
    rematerializable: bool = false,
    has_side_effects: bool = false,
    reads_memory: bool = false,
    writes_memory: bool = false,
    generic: bool = true,
    call: bool = false,
};

/// Comprehensive table of operations with expected properties.
const op_test_cases = [_]OpTestCase{
    // Constants - all rematerializable
    .{ .op = .const_bool, .name = "ConstBool", .arg_len = 0, .rematerializable = true },
    .{ .op = .const_int, .name = "ConstInt", .arg_len = 0, .rematerializable = true },
    .{ .op = .const_float, .name = "ConstFloat", .arg_len = 0, .rematerializable = true },
    .{ .op = .const_nil, .name = "ConstNil", .arg_len = 0, .rematerializable = true },
    .{ .op = .const_string, .name = "ConstString", .arg_len = 0, .rematerializable = true },
    .{ .op = .const_ptr, .name = "ConstPtr", .arg_len = 0, .rematerializable = true },

    // Arithmetic - binary commutative
    .{ .op = .add, .name = "Add", .arg_len = 2, .commutative = true },
    .{ .op = .mul, .name = "Mul", .arg_len = 2, .commutative = true },

    // Arithmetic - binary non-commutative
    .{ .op = .sub, .name = "Sub", .arg_len = 2 },
    .{ .op = .div, .name = "Div", .arg_len = 2 },

    // Arithmetic - unary
    .{ .op = .neg, .name = "Neg", .arg_len = 1 },

    // Bitwise - commutative
    .{ .op = .and_, .name = "And", .arg_len = 2, .commutative = true },
    .{ .op = .or_, .name = "Or", .arg_len = 2, .commutative = true },
    .{ .op = .xor, .name = "Xor", .arg_len = 2, .commutative = true },

    // Comparisons - equality is commutative
    .{ .op = .eq, .name = "Eq", .arg_len = 2, .commutative = true },
    .{ .op = .ne, .name = "Ne", .arg_len = 2, .commutative = true },
    .{ .op = .lt, .name = "Lt", .arg_len = 2 },

    // Memory operations
    .{ .op = .load, .name = "Load", .arg_len = 2, .reads_memory = true },
    .{ .op = .store, .name = "Store", .arg_len = 3, .writes_memory = true, .has_side_effects = true },

    // Calls - have many flags
    .{ .op = .call, .name = "Call", .arg_len = -1, .call = true, .has_side_effects = true, .reads_memory = true, .writes_memory = true },
    .{ .op = .static_call, .name = "StaticCall", .arg_len = -1, .call = true, .has_side_effects = true, .reads_memory = true, .writes_memory = true },

    // Safety checks
    .{ .op = .nil_check, .name = "NilCheck", .arg_len = 2, .has_side_effects = true },
    .{ .op = .bounds_check, .name = "BoundsCheck", .arg_len = 2, .has_side_effects = true },

    // ARM64-specific
    .{ .op = .arm64_add, .name = "ARM64ADD", .arg_len = 2, .commutative = true, .generic = false },
    .{ .op = .arm64_ldr, .name = "ARM64LDR", .arg_len = 2, .reads_memory = true, .generic = false },
    .{ .op = .arm64_str, .name = "ARM64STR", .arg_len = 3, .writes_memory = true, .has_side_effects = true, .generic = false },
};

test "Op properties (table-driven)" {
    for (op_test_cases) |tc| {
        const info = tc.op.info();

        // Check name
        try std.testing.expectEqualStrings(tc.name, info.name);

        // Check argument length
        try std.testing.expectEqual(tc.arg_len, info.arg_len);

        // Check flags
        try std.testing.expectEqual(tc.commutative, info.commutative);
        try std.testing.expectEqual(tc.rematerializable, info.rematerializable);
        try std.testing.expectEqual(tc.has_side_effects, info.has_side_effects);
        try std.testing.expectEqual(tc.reads_memory, info.reads_memory);
        try std.testing.expectEqual(tc.writes_memory, info.writes_memory);
        try std.testing.expectEqual(tc.generic, info.generic);
        try std.testing.expectEqual(tc.call, info.call);
    }
}

/// Test cases for commutativity property.
const commutative_ops = [_]Op{
    .add,     .mul,     .and_,    .or_,     .xor,
    .eq,      .ne,      .add32,   .add64,   .mul32,
    .mul64,   .and32,   .and64,   .or32,    .or64,
    .add32f,  .add64f,  .mul32f,  .mul64f,
    // ARM64
    .arm64_add, .arm64_mul, .arm64_and, .arm64_orr, .arm64_eor,
    .arm64_fadd, .arm64_fmul,
};

test "Commutative operations (table-driven)" {
    for (commutative_ops) |op| {
        try std.testing.expect(op.info().commutative);
    }
}

/// Test cases for operations that should NOT be commutative.
const non_commutative_ops = [_]Op{
    .sub, .div, .mod, .shl, .shr, .sar, .lt, .le, .gt, .ge,
};

test "Non-commutative operations (table-driven)" {
    for (non_commutative_ops) |op| {
        try std.testing.expect(!op.info().commutative);
    }
}

/// Test cases for rematerializable (constant) operations.
const rematerializable_ops = [_]Op{
    .const_bool, .const_int, .const_float, .const_nil, .const_string, .const_ptr,
    .const_8,    .const_16,  .const_32,    .const_64,
    .init_mem,   .addr,      .local_addr,
    // ARM64 immediates
    .arm64_movz, .arm64_movn, .arm64_adrp,
};

test "Rematerializable operations (table-driven)" {
    for (rematerializable_ops) |op| {
        try std.testing.expect(op.info().rematerializable);
    }
}

/// Test cases for memory-reading operations.
const memory_read_ops = [_]Op{
    .load,    .load8,    .load16,    .load32,    .load64,
    .load8s,  .load16s,  .load32s,
    .atomic_load32, .atomic_load64,
    // ARM64
    .arm64_ldr, .arm64_ldrw, .arm64_ldrh, .arm64_ldrb, .arm64_ldp,
};

test "Memory read operations (table-driven)" {
    for (memory_read_ops) |op| {
        const info = op.info();
        try std.testing.expect(info.reads_memory);
        try std.testing.expect(!info.writes_memory);
    }
}

/// Test cases for memory-writing operations.
const memory_write_ops = [_]Op{
    .store,   .store8,   .store16,   .store32,   .store64,
    .store_wb, .zero,
    .atomic_store32, .atomic_store64,
    // ARM64
    .arm64_str, .arm64_strw, .arm64_strh, .arm64_strb, .arm64_stp,
};

test "Memory write operations (table-driven)" {
    for (memory_write_ops) |op| {
        const info = op.info();
        try std.testing.expect(info.writes_memory);
        try std.testing.expect(info.has_side_effects);
    }
}

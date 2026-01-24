//! Cot Runtime Library
//!
//! This file provides runtime functions required by Cot programs.
//! It must be compiled and linked with any Cot program that uses
//! the features below.
//!
//! Build:
//!   zig build-obj -OReleaseFast runtime/cot_runtime.zig -femit-bin=runtime/cot_runtime.o
//!
//! Link with Cot program:
//!   zig cc program.o runtime/cot_runtime.o -o program -lSystem
//!
//! Functions provided:
//!   __cot_str_concat      - String concatenation (s1 + s2)
//!   install_crash_handler - Install SIGSEGV/SIGBUS/etc signal handlers
//!   register_symbol       - Register function address/name for stack traces
//!   finalize_symbols      - Sort symbol table after registration

const std = @import("std");
const posix = std.posix;
const c = std.c;

// ============================================================================
// Crash Handler - Signal-based crash diagnostics
// ============================================================================

const MAX_SYMBOLS = 10000;

const Symbol = struct {
    addr: u64,
    name: [*:0]const u8,
};

var symbol_table: [MAX_SYMBOLS]Symbol = undefined;
var symbol_count: usize = 0;
var symbols_sorted: bool = false;

// Alternate stack for handling stack overflow
var alt_stack_mem: [c.SIGSTKSZ]u8 align(16) = undefined;

/// Write string to stderr (signal-safe, uses raw write syscall)
fn crashWrite(s: []const u8) void {
    _ = std.posix.write(std.posix.STDERR_FILENO, s) catch {};
}

fn crashPuts(s: [*:0]const u8) void {
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    crashWrite(s[0..len]);
}

fn crashPutChar(ch: u8) void {
    const buf = [_]u8{ch};
    crashWrite(&buf);
}

fn crashNewline() void {
    crashPutChar('\n');
}

fn crashPutHexDigit(d: u4) void {
    const ch: u8 = if (d < 10) '0' + @as(u8, d) else 'a' + @as(u8, d) - 10;
    crashPutChar(ch);
}

fn crashPutHex(val: u64, width: u8) void {
    var i: u8 = width;
    while (i > 0) {
        i -= 1;
        const shift: u6 = @intCast(i * 4);
        const digit: u4 = @truncate(val >> shift);
        crashPutHexDigit(digit);
    }
}

fn crashPutHexPtr(val: u64) void {
    crashWrite("0x");
    crashPutHex(val, 16);
}

fn crashPutDec(val: i64) void {
    var buf: [21]u8 = undefined;
    var pos: usize = 20;
    var v = val;
    const neg = v < 0;
    if (neg) v = -v;

    if (v == 0) {
        buf[pos] = '0';
        pos -= 1;
    } else {
        while (v > 0) {
            buf[pos] = @intCast('0' + @as(u8, @intCast(@mod(v, 10))));
            v = @divTrunc(v, 10);
            pos -= 1;
        }
    }

    if (neg) {
        buf[pos] = '-';
        pos -= 1;
    }

    crashWrite(buf[pos + 1 .. 21]);
}

fn signalName(sig: i32) []const u8 {
    return switch (sig) {
        std.posix.SIG.SEGV => "SIGSEGV",
        std.posix.SIG.BUS => "SIGBUS",
        std.posix.SIG.FPE => "SIGFPE",
        std.posix.SIG.ILL => "SIGILL",
        std.posix.SIG.ABRT => "SIGABRT",
        std.posix.SIG.TRAP => "SIGTRAP",
        else => "UNKNOWN",
    };
}

fn signalDescription(sig: i32) []const u8 {
    return switch (sig) {
        std.posix.SIG.SEGV => "Segmentation fault (invalid memory access)",
        std.posix.SIG.BUS => "Bus error (misaligned access or bad address)",
        std.posix.SIG.FPE => "Floating point exception (div by zero, overflow)",
        std.posix.SIG.ILL => "Illegal instruction (corrupted code or bad jump)",
        std.posix.SIG.ABRT => "Aborted (assertion failure or abort() called)",
        std.posix.SIG.TRAP => "Trap (breakpoint or debug trap)",
        else => "Unknown signal",
    };
}

// ============================================================================
// DWARF Source Location Lookup
// ============================================================================

// Mach-O constants
const MH_MAGIC_64: u32 = 0xfeedfacf;
const LC_SEGMENT_64: u32 = 0x19;

// Mach-O structures
const MachHeader64 = extern struct {
    magic: u32,
    cputype: i32,
    cpusubtype: i32,
    filetype: u32,
    ncmds: u32,
    sizeofcmds: u32,
    flags: u32,
    reserved: u32,
};

const SegmentCommand64 = extern struct {
    cmd: u32,
    cmdsize: u32,
    segname: [16]u8,
    vmaddr: u64,
    vmsize: u64,
    fileoff: u64,
    filesize: u64,
    maxprot: i32,
    initprot: i32,
    nsects: u32,
    flags: u32,
};

const Section64 = extern struct {
    sectname: [16]u8,
    segname: [16]u8,
    addr: u64,
    size: u64,
    offset: u32,
    @"align": u32,
    reloff: u32,
    nreloc: u32,
    flags: u32,
    reserved1: u32,
    reserved2: u32,
    reserved3: u32,
};

// DWARF line table parsing state
const LineInfo = struct {
    file: ?[*:0]const u8,
    line: u32,
    found: bool,
};

const DwarfSections = struct {
    debug_line: ?[*]const u8,
    debug_line_size: u64,
    debug_info: ?[*]const u8,
    debug_info_size: u64,
};

// Find __debug_line and __debug_info sections from Mach-O header
fn findDwarfSections(header: *const MachHeader64) DwarfSections {
    var result = DwarfSections{
        .debug_line = null,
        .debug_line_size = 0,
        .debug_info = null,
        .debug_info_size = 0,
    };

    if (header.magic != MH_MAGIC_64) return result;

    // First, find the __TEXT segment vmaddr to compute slide
    var text_vmaddr: u64 = 0;
    var ptr: [*]const u8 = @ptrCast(header);
    ptr += @sizeOf(MachHeader64);

    var i: u32 = 0;
    while (i < header.ncmds) : (i += 1) {
        const cmd: *const SegmentCommand64 = @ptrCast(@alignCast(ptr));

        if (cmd.cmd == LC_SEGMENT_64) {
            if (std.mem.eql(u8, cmd.segname[0..6], "__TEXT")) {
                text_vmaddr = cmd.vmaddr;
                break;
            }
        }

        ptr += cmd.cmdsize;
    }

    // Compute slide: actual header address - expected load address
    const actual_addr = @intFromPtr(header);
    const slide: i64 = @as(i64, @intCast(actual_addr)) - @as(i64, @intCast(text_vmaddr));

    // Now scan for DWARF sections
    ptr = @ptrCast(header);
    ptr += @sizeOf(MachHeader64);

    i = 0;
    while (i < header.ncmds) : (i += 1) {
        const cmd: *const SegmentCommand64 = @ptrCast(@alignCast(ptr));

        if (cmd.cmd == LC_SEGMENT_64) {
            // Check if this is __DWARF segment
            if (std.mem.eql(u8, cmd.segname[0..7], "__DWARF")) {
                // Scan sections
                var sect_ptr = ptr + @sizeOf(SegmentCommand64);
                var j: u32 = 0;
                while (j < cmd.nsects) : (j += 1) {
                    const sect: *const Section64 = @ptrCast(@alignCast(sect_ptr));

                    // Apply slide to section address
                    const adjusted_addr: u64 = @intCast(@as(i64, @intCast(sect.addr)) + slide);

                    if (std.mem.eql(u8, sect.sectname[0..12], "__debug_line")) {
                        result.debug_line = @ptrFromInt(adjusted_addr);
                        result.debug_line_size = sect.size;
                    } else if (std.mem.eql(u8, sect.sectname[0..12], "__debug_info")) {
                        result.debug_info = @ptrFromInt(adjusted_addr);
                        result.debug_info_size = sect.size;
                    }

                    sect_ptr += @sizeOf(Section64);
                }
            }
        }

        ptr += cmd.cmdsize;
    }

    return result;
}

// Read ULEB128 from buffer with bounds checking
fn readULEB128(ptr: *[*]const u8, end: [*]const u8) u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    var count: usize = 0;
    while (count < 10) { // Max 10 bytes for 64-bit ULEB128
        if (@intFromPtr(ptr.*) >= @intFromPtr(end)) return result;
        const b = ptr.*[0];
        ptr.* += 1;
        result |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) break;
        shift +%= 7;
        count += 1;
    }
    return result;
}

// Read SLEB128 from buffer with bounds checking
fn readSLEB128(ptr: *[*]const u8, end: [*]const u8) i64 {
    var result: i64 = 0;
    var shift: u6 = 0;
    var b: u8 = 0;
    var count: usize = 0;
    while (count < 10) { // Max 10 bytes for 64-bit SLEB128
        if (@intFromPtr(ptr.*) >= @intFromPtr(end)) return result;
        b = ptr.*[0];
        ptr.* += 1;
        result |= @as(i64, @intCast(b & 0x7f)) << shift;
        shift +%= 7;
        count += 1;
        if (b & 0x80 == 0) break;
    }
    // Sign extend
    if (shift < 64 and (b & 0x40) != 0) {
        result |= @as(i64, -1) << shift;
    }
    return result;
}

// Parse DWARF line table and find address -> line mapping
// slide: ASLR slide to add to DWARF addresses
fn lookupLineFromDwarf(debug_line: [*]const u8, size: u64, target_addr: u64) LineInfo {
    var info = LineInfo{ .file = null, .line = 0, .found = false };
    if (size < 15) return info;

    var ptr = debug_line;
    const end = debug_line + size;

    // Read header
    const unit_length = std.mem.readInt(u32, ptr[0..4], .little);
    _ = unit_length;
    ptr += 4;

    const version = std.mem.readInt(u16, ptr[0..2], .little);
    if (version != 4) return info; // Only support DWARF v4
    ptr += 2;

    const header_length = std.mem.readInt(u32, ptr[0..4], .little);
    ptr += 4;

    const min_inst_length = ptr[0];
    ptr += 1;
    ptr += 1; // max_ops_per_inst
    const default_is_stmt = ptr[0];
    ptr += 1;
    const line_base: i8 = @bitCast(ptr[0]);
    ptr += 1;
    const line_range = ptr[0];
    ptr += 1;
    const opcode_base = ptr[0];
    ptr += 1;

    // Skip standard opcode lengths
    ptr += opcode_base - 1;

    // Skip include directories (null-terminated strings, then empty string)
    while (@intFromPtr(ptr) < @intFromPtr(end) and ptr[0] != 0) {
        while (@intFromPtr(ptr) < @intFromPtr(end) and ptr[0] != 0) ptr += 1;
        if (@intFromPtr(ptr) >= @intFromPtr(end)) return info;
        ptr += 1;
    }
    if (@intFromPtr(ptr) >= @intFromPtr(end)) return info;
    ptr += 1;

    // Read file names - save first file
    if (@intFromPtr(ptr) < @intFromPtr(end) and ptr[0] != 0) {
        info.file = @ptrCast(ptr);
        while (@intFromPtr(ptr) < @intFromPtr(end) and ptr[0] != 0) ptr += 1;
        if (@intFromPtr(ptr) >= @intFromPtr(end)) return info;
        ptr += 1;
        _ = readULEB128(&ptr, end); // dir index
        _ = readULEB128(&ptr, end); // mtime
        _ = readULEB128(&ptr, end); // length
    }

    // Skip remaining files
    while (@intFromPtr(ptr) < @intFromPtr(end) and ptr[0] != 0) {
        while (@intFromPtr(ptr) < @intFromPtr(end) and ptr[0] != 0) ptr += 1;
        if (@intFromPtr(ptr) >= @intFromPtr(end)) return info;
        ptr += 1;
        _ = readULEB128(&ptr, end);
        _ = readULEB128(&ptr, end);
        _ = readULEB128(&ptr, end);
    }
    if (@intFromPtr(ptr) >= @intFromPtr(end)) return info;
    ptr += 1;

    // Now at start of line number program
    // Skip to correct position using header_length
    const program_start = debug_line + 4 + 2 + 4 + header_length;
    ptr = program_start;

    // Line number state machine
    var address: u64 = 0;
    var line: u32 = 1;
    const is_stmt = default_is_stmt != 0;
    _ = is_stmt;

    var prev_address: u64 = 0;
    var prev_line: u32 = 1;

    while (@intFromPtr(ptr) < @intFromPtr(end)) {
        const op = ptr[0];
        ptr += 1;

        if (op == 0) {
            // Extended opcode
            const len = readULEB128(&ptr, end);
            if (len == 0) break;
            if (@intFromPtr(ptr) >= @intFromPtr(end)) break;
            const ext_op = ptr[0];
            ptr += 1;

            if (ext_op == 1) {
                // DW_LNE_end_sequence
                if (target_addr >= prev_address and target_addr < address) {
                    info.line = prev_line;
                    info.found = true;
                    return info;
                }
                address = 0;
                line = 1;
            } else if (ext_op == 2) {
                // DW_LNE_set_address - addresses are already rebased by Mach-O loader
                if (@intFromPtr(ptr) + 8 > @intFromPtr(end)) break;
                const dwarf_addr = std.mem.readInt(u64, ptr[0..8], .little);
                // Don't add slide - Mach-O rebase fixups already applied at load time
                address = dwarf_addr;
                prev_address = address;
                ptr += 8;
            } else {
                ptr += len - 1;
            }
        } else if (op < opcode_base) {
            // Standard opcode
            switch (op) {
                1 => { // DW_LNS_copy
                    if (target_addr >= prev_address and target_addr < address) {
                        info.line = prev_line;
                        info.found = true;
                        return info;
                    }
                    prev_address = address;
                    prev_line = line;
                },
                2 => { // DW_LNS_advance_pc
                    const adv = readULEB128(&ptr, end);
                    address += adv * min_inst_length;
                },
                3 => { // DW_LNS_advance_line
                    const adv = readSLEB128(&ptr, end);
                    line = @intCast(@as(i64, @intCast(line)) + adv);
                },
                4 => _ = readULEB128(&ptr, end), // DW_LNS_set_file
                5 => _ = readULEB128(&ptr, end), // DW_LNS_set_column
                6, 7 => {}, // negate_stmt, set_basic_block
                8 => { // DW_LNS_const_add_pc
                    const adj_opcode: u8 = 255 - opcode_base;
                    address += (adj_opcode / line_range) * min_inst_length;
                },
                9 => { // DW_LNS_fixed_advance_pc
                    const adv = std.mem.readInt(u16, ptr[0..2], .little);
                    ptr += 2;
                    address += adv;
                },
                else => {},
            }
        } else {
            // Special opcode: first advance, then emit row
            const adj_opcode = op - opcode_base;
            const line_inc = @as(i8, line_base) + @as(i8, @intCast(adj_opcode % line_range));
            const addr_inc = (adj_opcode / line_range) * min_inst_length;

            // Compute new row's address and line (DWARF advances before emitting)
            const new_address = address + addr_inc;
            const new_line: u32 = @intCast(@as(i64, @intCast(line)) + line_inc);

            // Check if target falls in previous row's range
            if (target_addr >= prev_address and target_addr < new_address) {
                info.line = prev_line;
                info.found = true;
                return info;
            }

            // Update to this emitted row for next iteration
            prev_address = new_address;
            prev_line = new_line;
            address = new_address;
            line = new_line;
        }
    }

    // Check final range
    if (target_addr >= prev_address and target_addr <= address) {
        info.line = prev_line;
        info.found = true;
    }

    return info;
}

// Get Mach-O header of main executable
extern "c" fn _dyld_get_image_header(image_index: u32) ?*const MachHeader64;

// Print source location for crash address
fn printSourceLocation(pc: u64) void {
    const header = _dyld_get_image_header(0) orelse return;
    const sections = findDwarfSections(header);

    if (sections.debug_line) |debug_line| {
        const info = lookupLineFromDwarf(debug_line, sections.debug_line_size, pc);
        if (info.found) {
            crashWrite("\nSource Location:\n");
            crashWrite("  ");
            if (info.file) |file| {
                crashPuts(file);
            } else {
                crashWrite("<unknown>");
            }
            crashWrite(":");
            crashPutDec(info.line);
            crashNewline();
        }
    }
}

fn analyzeFaultAddress(addr: u64) void {
    crashWrite("  Analysis: ");
    if (addr == 0) {
        crashWrite("NULL pointer dereference");
    } else if (addr < 0x1000) {
        crashWrite("Near-NULL pointer (offset ");
        crashPutDec(@intCast(addr));
        crashWrite(" from NULL, likely accessing field of NULL struct)");
    } else if (addr >= 0x7F0000000000) {
        crashWrite("Stack region access (possible stack overflow or buffer overrun)");
    } else if ((addr & 0x7) != 0 and addr < 0x10000) {
        crashWrite("Misaligned small address");
    } else {
        crashWrite("Invalid memory address (wild pointer or use-after-free?)");
    }
    crashNewline();
}

fn lookupSymbol(addr: u64) ?struct { name: [*:0]const u8, offset: u64 } {
    if (symbol_count == 0) return null;

    // Binary search for largest address <= target
    var lo: usize = 0;
    var hi: usize = symbol_count;
    var best: ?usize = null;

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (symbol_table[mid].addr <= addr) {
            best = mid;
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    if (best) |idx| {
        return .{
            .name = symbol_table[idx].name,
            .offset = addr - symbol_table[idx].addr,
        };
    }
    return null;
}

fn isValidPtr(addr: u64) bool {
    if (addr == 0) return false;
    if (addr < 0x1000) return false;
    if (addr > 0x7FFFFFFFFFFF) return false;
    return true;
}

fn isValidFramePtr(fp: u64) bool {
    if (!isValidPtr(fp)) return false;
    if ((fp & 0xF) != 0) return false; // Must be 16-byte aligned
    return true;
}

fn printFrame(depth: usize, addr: u64, is_crash: bool) void {
    crashWrite("  #");
    if (depth < 10) crashPutChar(' ');
    crashPutDec(@intCast(depth));
    crashWrite("  ");
    crashPutHexPtr(addr);

    if (lookupSymbol(addr)) |sym| {
        crashPutChar(' ');
        crashPuts(sym.name);
        crashWrite("+0x");
        crashPutHex(sym.offset, 4);
    }

    if (is_crash) {
        crashWrite("  <-- CRASH HERE");
    }
    crashNewline();
}

fn walkStack(fp: u64, pc: u64, lr: u64) void {
    crashWrite("\nStack Trace:\n");
    crashWrite("------------------------------------------------------------------------\n");

    // Frame 0: Current PC (crash location)
    printFrame(0, pc, true);

    // Frame 1: Link register (immediate caller)
    if (isValidPtr(lr) and lr != pc) {
        printFrame(1, lr, false);
    }

    // Walk frame pointer chain
    var frame: [*]const u64 = @ptrFromInt(fp);
    var depth: usize = 2;
    const max_depth: usize = 50;

    while (depth < max_depth) {
        const frame_addr = @intFromPtr(frame);
        if (!isValidFramePtr(frame_addr)) break;

        // On ARM64: frame[0] = previous FP, frame[1] = return address (LR)
        const prev_fp = frame[0];
        const ret_addr = frame[1];

        if (!isValidPtr(ret_addr)) break;

        // Skip if same as LR (already printed)
        if (ret_addr != lr) {
            printFrame(depth, ret_addr, false);
            depth += 1;
        }

        // Check for end of stack
        if (prev_fp == 0 or prev_fp == frame_addr) break;
        if (prev_fp < frame_addr) break; // FP should grow (stack grows down)

        frame = @ptrFromInt(prev_fp);
    }

    if (depth >= max_depth) {
        crashWrite("  ... (truncated, max depth reached)\n");
    }

    crashWrite("------------------------------------------------------------------------\n");
}

// Darwin/macOS ARM64 context offsets (verified against C headers)
// ucontext_t: uc_mcontext is at offset 48 (pointer to mcontext)
// mcontext: __es at 0 (16 bytes), __ss at 16
// __ss: __x[29] at 0, __fp at 232, __lr at 240, __sp at 248, __pc at 256

const UC_MCONTEXT_OFFSET: usize = 48;
const MC_ES_FAR_OFFSET: usize = 0;  // __far in exception state
const MC_SS_OFFSET: usize = 16;     // thread state offset in mcontext
const SS_X_OFFSET: usize = 0;       // __x[0] offset in thread state
const SS_FP_OFFSET: usize = 232;    // __fp offset in thread state
const SS_LR_OFFSET: usize = 240;    // __lr offset in thread state
const SS_SP_OFFSET: usize = 248;    // __sp offset in thread state
const SS_PC_OFFSET: usize = 256;    // __pc offset in thread state

fn getRegFromContext(ctx: *anyopaque, ss_offset: usize) u64 {
    // Get pointer to mcontext from ucontext
    const uc_bytes: [*]const u8 = @ptrCast(ctx);
    const mc_ptr_ptr: *const usize = @ptrCast(@alignCast(uc_bytes + UC_MCONTEXT_OFFSET));
    const mc_bytes: [*]const u8 = @ptrFromInt(mc_ptr_ptr.*);

    // Get value from thread state (__ss) section
    const val_ptr: *const u64 = @ptrCast(@alignCast(mc_bytes + MC_SS_OFFSET + ss_offset));
    return val_ptr.*;
}

fn getFarFromContext(ctx: *anyopaque) u64 {
    // Get fault address from exception state (__es.__far)
    const uc_bytes: [*]const u8 = @ptrCast(ctx);
    const mc_ptr_ptr: *const usize = @ptrCast(@alignCast(uc_bytes + UC_MCONTEXT_OFFSET));
    const mc_bytes: [*]const u8 = @ptrFromInt(mc_ptr_ptr.*);

    const far_ptr: *const u64 = @ptrCast(@alignCast(mc_bytes + MC_ES_FAR_OFFSET));
    return far_ptr.*;
}

fn getXRegFromContext(ctx: *anyopaque, reg: usize) u64 {
    return getRegFromContext(ctx, SS_X_OFFSET + reg * 8);
}

fn dumpRegistersArm64(ctx: *anyopaque) void {
    crashWrite("\nRegisters:\n");
    crashWrite("------------------------------------------------------------------------\n");

    const pc = getRegFromContext(ctx, SS_PC_OFFSET);
    const lr = getRegFromContext(ctx, SS_LR_OFFSET);
    const sp = getRegFromContext(ctx, SS_SP_OFFSET);
    const fp = getRegFromContext(ctx, SS_FP_OFFSET);

    crashWrite("  PC   ");
    crashPutHexPtr(pc);
    crashWrite("  (program counter - crash location)\n");

    crashWrite("  LR   ");
    crashPutHexPtr(lr);
    crashWrite("  (link register - return address)\n");

    crashWrite("  SP   ");
    crashPutHexPtr(sp);
    crashWrite("  (stack pointer)\n");

    crashWrite("  FP   ");
    crashPutHexPtr(fp);
    crashWrite("  (frame pointer)\n");

    crashNewline();

    // General purpose registers x0-x28 in rows of 4
    var i: usize = 0;
    while (i < 29) : (i += 1) {
        if (i % 4 == 0) crashWrite("  ");

        crashPutChar('x');
        if (i < 10) crashPutChar('0');
        crashPutDec(@intCast(i));
        crashPutChar('=');
        crashPutHexPtr(getXRegFromContext(ctx, i));

        if (i % 4 == 3 or i == 28) {
            crashNewline();
        } else {
            crashPutChar(' ');
        }
    }

    crashWrite("------------------------------------------------------------------------\n");
}

fn crashHandler(sig: i32, info: *const std.posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    _ = info;

    crashNewline();
    crashWrite("========================================================================\n");
    crashWrite("                           CRASH DETECTED                               \n");
    crashWrite("========================================================================\n");
    crashNewline();

    // Signal info
    crashWrite("Signal:  ");
    crashWrite(signalName(sig));
    crashWrite(" (");
    crashPutDec(sig);
    crashWrite(")\n");

    crashWrite("Reason:  ");
    crashWrite(signalDescription(sig));
    crashNewline();

    // Get context for register/stack info
    if (ctx) |context| {
        const pc = getRegFromContext(context, SS_PC_OFFSET);
        const fp = getRegFromContext(context, SS_FP_OFFSET);
        const lr = getRegFromContext(context, SS_LR_OFFSET);
        const far = getFarFromContext(context);

        // Fault address for memory errors
        if (sig == std.posix.SIG.SEGV or sig == std.posix.SIG.BUS) {
            crashWrite("Address: ");
            crashPutHexPtr(far);
            crashNewline();
            analyzeFaultAddress(far);
        }

        // Registers
        dumpRegistersArm64(context);

        // Stack trace
        walkStack(fp, pc, lr);

        // Source location from DWARF
        printSourceLocation(pc);

        // Debugging hints
        crashWrite("\nTo investigate further:\n");
        crashWrite("  lldb <executable>\n");
        crashWrite("  (lldb) image lookup -a ");
        crashPutHexPtr(pc);
        crashNewline();
        crashWrite("  (lldb) disassemble -a ");
        crashPutHexPtr(pc);
        crashNewline();
    }
    crashNewline();

    // Exit with signal-appropriate code
    std.posix.exit(128 + @as(u8, @intCast(sig)));
}

/// Install crash handler for SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT.
/// Call this at the very start of main() before any other code runs.
export fn install_crash_handler() void {
    // Sort symbols if any were registered
    if (symbol_count > 0 and !symbols_sorted) {
        sortSymbols();
    }

    // Set up alternate signal stack (for handling stack overflow)
    var alt_stack = std.posix.stack_t{
        .sp = &alt_stack_mem,
        .flags = 0,
        .size = c.SIGSTKSZ,
    };
    std.posix.sigaltstack(&alt_stack, null) catch {};

    // Install signal handler
    const sa = std.posix.Sigaction{
        .handler = .{ .sigaction = crashHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO | std.posix.SA.ONSTACK,
    };

    std.posix.sigaction(std.posix.SIG.SEGV, &sa, null);
    std.posix.sigaction(std.posix.SIG.BUS, &sa, null);
    std.posix.sigaction(std.posix.SIG.FPE, &sa, null);
    std.posix.sigaction(std.posix.SIG.ILL, &sa, null);
    std.posix.sigaction(std.posix.SIG.ABRT, &sa, null);
}

/// Register a symbol for stack trace display.
export fn register_symbol(addr: u64, name: [*:0]const u8) void {
    if (symbol_count < MAX_SYMBOLS) {
        symbol_table[symbol_count] = .{ .addr = addr, .name = name };
        symbol_count += 1;
        symbols_sorted = false;
    }
}

/// Sort symbols by address (call after all symbols registered, or let install_crash_handler do it)
fn sortSymbols() void {
    // Simple insertion sort
    var i: usize = 1;
    while (i < symbol_count) : (i += 1) {
        const tmp = symbol_table[i];
        var j: usize = i;
        while (j > 0 and symbol_table[j - 1].addr > tmp.addr) {
            symbol_table[j] = symbol_table[j - 1];
            j -= 1;
        }
        symbol_table[j] = tmp;
    }
    symbols_sorted = true;
}

export fn finalize_symbols() void {
    if (symbol_count > 0 and !symbols_sorted) {
        sortSymbols();
    }
}

/// Cot string representation:
///   - ptr: pointer to character data (NOT null-terminated)
///   - len: length in bytes
///
/// On ARM64, this struct is returned in (x0, x1) registers.
const CotString = extern struct {
    ptr: [*]u8,
    len: i64,
};

/// String concatenation: allocates new string, copies both inputs.
///
/// Called by compiler-generated code as:
///   __cot_str_concat(ptr1, len1, ptr2, len2)
///
/// Returns:
///   CotString with (ptr, len) in (x0, x1) per ARM64 ABI
///
/// Note: Memory is allocated with malloc. In the future, this will
/// integrate with a garbage collector.
export fn __cot_str_concat(ptr1: [*]const u8, len1: i64, ptr2: [*]const u8, len2: i64) CotString {
    const total: usize = @intCast(len1 + len2);

    // Use libc allocator for malloc compatibility
    const allocator = std.heap.c_allocator;
    const result = allocator.alloc(u8, total) catch {
        return CotString{ .ptr = undefined, .len = 0 };
    };

    // Copy first string
    const ulen1: usize = @intCast(len1);
    const ulen2: usize = @intCast(len2);
    @memcpy(result[0..ulen1], ptr1[0..ulen1]);
    @memcpy(result[ulen1..total], ptr2[0..ulen2]);

    return CotString{ .ptr = result.ptr, .len = len1 + len2 };
}

/// Memory allocation wrappers for Cot
/// These provide typed versions of malloc/realloc/free for use in Cot code

export fn malloc_u8(size: i64) ?[*]u8 {
    const allocator = std.heap.c_allocator;
    const usize_size: usize = @intCast(size);
    const result = allocator.alloc(u8, usize_size) catch {
        return null;
    };
    return result.ptr;
}

export fn realloc_u8(ptr: ?[*]u8, new_size: i64) ?[*]u8 {
    const allocator = std.heap.c_allocator;
    const usize_size: usize = @intCast(new_size);
    if (ptr) |p| {
        // Get the old allocation - we need to know its size
        // Since we don't track sizes, just allocate new and copy
        const new_mem = allocator.alloc(u8, usize_size) catch {
            return null;
        };
        // Copy old data (up to new_size, assuming old was at least that large)
        @memcpy(new_mem[0..usize_size], p[0..usize_size]);
        // Free old memory - this is tricky without knowing old size
        // For now, just return new memory (leak old)
        return new_mem.ptr;
    } else {
        return malloc_u8(new_size);
    }
}

export fn free_u8(ptr: ?[*]u8) void {
    // With std.heap.c_allocator we can't properly free without knowing size
    // This is a limitation - for now just no-op
    _ = ptr;
}

/// i64 array allocation
export fn malloc_i64(count: i64) ?[*]i64 {
    const allocator = std.heap.c_allocator;
    const usize_count: usize = @intCast(count);
    const result = allocator.alloc(i64, usize_count) catch {
        return null;
    };
    return result.ptr;
}

export fn realloc_i64(ptr: ?[*]i64, old_count: i64, new_count: i64) ?[*]i64 {
    const allocator = std.heap.c_allocator;
    const usize_new: usize = @intCast(new_count);
    if (ptr) |p| {
        const new_mem = allocator.alloc(i64, usize_new) catch {
            return null;
        };
        // Copy old data
        const usize_old: usize = @intCast(old_count);
        const copy_count = @min(usize_old, usize_new);
        @memcpy(new_mem[0..copy_count], p[0..copy_count]);
        return new_mem.ptr;
    } else {
        return malloc_i64(new_count);
    }
}

export fn free_i64(ptr: ?[*]i64) void {
    _ = ptr;
}

// Struct allocation functions - allocate count * struct_size bytes
fn malloc_struct(count: i64, struct_size: i64) ?*anyopaque {
    const allocator = std.heap.c_allocator;
    const total: usize = @intCast(count * struct_size);
    const result = allocator.alloc(u8, total) catch return null;
    return @ptrCast(result.ptr);
}

export fn malloc_Node(count: i64) ?*anyopaque { return malloc_struct(count, 72); }
export fn malloc_Type(count: i64) ?*anyopaque { return malloc_struct(count, 80); }  // Type: kind(4) + pad(4) + 9*i64 = 80
export fn malloc_FieldInfo(count: i64) ?*anyopaque { return malloc_struct(count, 40); }
export fn malloc_IRNode(count: i64) ?*anyopaque { return malloc_struct(count, 96); }  // IRNode: 12 fields * 8 = 96
export fn malloc_IRLocal(count: i64) ?*anyopaque { return malloc_struct(count, 80); }  // IRLocal: 10 fields * 8 = 80
export fn malloc_IRFunc(count: i64) ?*anyopaque { return malloc_struct(count, 64); }
export fn malloc_ConstEntry(count: i64) ?*anyopaque { return malloc_struct(count, 24); }
export fn malloc_IRGlobal(count: i64) ?*anyopaque { return malloc_struct(count, 80); }  // IRGlobal: 10 fields * 8 = 80
export fn malloc_Block(count: i64) ?*anyopaque { return malloc_struct(count, 80); }
export fn malloc_Value(count: i64) ?*anyopaque { return malloc_struct(count, 128); }
export fn malloc_Local(count: i64) ?*anyopaque { return malloc_struct(count, 72); }  // Local: 9 fields * 8 = 72
export fn malloc_Branch(count: i64) ?*anyopaque { return malloc_struct(count, 24); }
export fn malloc_CallSite(count: i64) ?*anyopaque { return malloc_struct(count, 16); }
export fn malloc_GlobalReloc(count: i64) ?*anyopaque { return malloc_struct(count, 16); }
export fn malloc_FuncAddrReloc(count: i64) ?*anyopaque { return malloc_struct(count, 24); }  // FuncAddrReloc: 3 fields * 8 = 24
export fn malloc_StringReloc(count: i64) ?*anyopaque { return malloc_struct(count, 24); }  // StringReloc: 3 fields * 8 = 24
export fn malloc_Symbol(count: i64) ?*anyopaque { return malloc_struct(count, 40); }
export fn malloc_Reloc(count: i64) ?*anyopaque { return malloc_struct(count, 24); }
export fn malloc_BlockDefs(count: i64) ?*anyopaque { return malloc_struct(count, 24); }
export fn malloc_BlockMapping(count: i64) ?*anyopaque { return malloc_struct(count, 16); }
export fn malloc_VarDef(count: i64) ?*anyopaque { return malloc_struct(count, 24); }

// Liveness and RegAlloc types
export fn malloc_ValState(count: i64) ?*anyopaque { return malloc_struct(count, 24); }  // ValState: regs(8) + spill(8) + 3 bools(8 padded) = 24
export fn malloc_RegState(count: i64) ?*anyopaque { return malloc_struct(count, 16); }  // RegState: value_id(8) + dirty(8 padded) = 16
export fn malloc_LiveInfo(count: i64) ?*anyopaque { return malloc_struct(count, 24); }  // LiveInfo: id(8) + dist(8) + pos(8) = 24
export fn malloc_BlockLiveness(count: i64) ?*anyopaque { return malloc_struct(count, 48); }  // BlockLiveness: 6 * 8 = 48

// Struct reallocation functions - reallocate with copy
fn realloc_struct(ptr: ?*anyopaque, old_count: i64, new_count: i64, struct_size: i64) ?*anyopaque {
    const allocator = std.heap.c_allocator;
    const new_total: usize = @intCast(new_count * struct_size);
    if (ptr) |p| {
        const old_total: usize = @intCast(old_count * struct_size);
        const new_mem = allocator.alloc(u8, new_total) catch return null;
        const copy_size = @min(old_total, new_total);
        const src: [*]u8 = @ptrCast(p);
        @memcpy(new_mem[0..copy_size], src[0..copy_size]);
        return @ptrCast(new_mem.ptr);
    } else {
        return malloc_struct(new_count, struct_size);
    }
}

export fn realloc_Node(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 72); }
export fn realloc_Type(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 80); }
export fn realloc_FieldInfo(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 40); }
export fn realloc_IRNode(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 96); }
export fn realloc_IRLocal(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 80); }
export fn realloc_IRFunc(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 64); }
export fn realloc_ConstEntry(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 24); }
export fn realloc_IRGlobal(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 80); }
export fn realloc_Block(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 80); }
export fn realloc_Value(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 128); }
export fn realloc_Local(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 72); }
export fn realloc_Branch(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 24); }
export fn realloc_CallSite(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 16); }
export fn realloc_GlobalReloc(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 16); }
export fn realloc_FuncAddrReloc(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 24); }
export fn realloc_StringReloc(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 24); }
export fn realloc_Symbol(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 40); }
export fn realloc_Reloc(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 24); }
export fn realloc_BlockDefs(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 24); }
export fn realloc_BlockMapping(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 16); }
export fn realloc_VarDef(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 24); }
export fn realloc_ValState(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 24); }
export fn realloc_RegState(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 16); }
export fn realloc_LiveInfo(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 24); }
export fn realloc_BlockLiveness(ptr: ?*anyopaque, old_count: i64, new_count: i64) ?*anyopaque { return realloc_struct(ptr, old_count, new_count, 48); }

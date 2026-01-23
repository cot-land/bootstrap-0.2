// DWARF debug information generation
// Based on Go's cmd/internal/dwarf and cmd/internal/obj/dwarf.go
//
// This module generates DWARF debugging information following Go's architecture:
// - DWARF constants from the DWARF spec (via Go's dwarf_defs.go)
// - Line number program generation (from Go's obj/dwarf.go)
// - Compilation unit info (from Go's linker)

const std = @import("std");

// ===========================================================================
// DWARF Constants (from Go's cmd/internal/dwarf/dwarf_defs.go)
// ===========================================================================

// Table 18 - Tags
pub const DW_TAG_compile_unit: u8 = 0x11;
pub const DW_TAG_subprogram: u8 = 0x2e;
pub const DW_TAG_variable: u8 = 0x34;
pub const DW_TAG_formal_parameter: u8 = 0x05;
pub const DW_TAG_base_type: u8 = 0x24;

// Table 19 - Children
pub const DW_CHILDREN_no: u8 = 0x00;
pub const DW_CHILDREN_yes: u8 = 0x01;

// Table 20 - Attributes
pub const DW_AT_name: u8 = 0x03;
pub const DW_AT_stmt_list: u8 = 0x10;
pub const DW_AT_low_pc: u8 = 0x11;
pub const DW_AT_high_pc: u8 = 0x12;
pub const DW_AT_comp_dir: u8 = 0x1b;

// Table 21 - Forms
pub const DW_FORM_addr: u8 = 0x01;
pub const DW_FORM_data4: u8 = 0x06;
pub const DW_FORM_data8: u8 = 0x07;
pub const DW_FORM_string: u8 = 0x08;
pub const DW_FORM_sec_offset: u8 = 0x17;

// Table 37 - Line Number Standard Opcodes (DW_LNS)
pub const DW_LNS_copy: u8 = 0x01;
pub const DW_LNS_advance_pc: u8 = 0x02;
pub const DW_LNS_advance_line: u8 = 0x03;
pub const DW_LNS_set_file: u8 = 0x04;
pub const DW_LNS_set_column: u8 = 0x05;
pub const DW_LNS_negate_stmt: u8 = 0x06;
pub const DW_LNS_set_basic_block: u8 = 0x07;
pub const DW_LNS_const_add_pc: u8 = 0x08;
pub const DW_LNS_fixed_advance_pc: u8 = 0x09;
pub const DW_LNS_set_prologue_end: u8 = 0x0a;

// Table 38 - Line Number Extended Opcodes (DW_LNE)
pub const DW_LNE_end_sequence: u8 = 0x01;
pub const DW_LNE_set_address: u8 = 0x02;
pub const DW_LNE_define_file: u8 = 0x03;

// ===========================================================================
// Line Number Program Constants (from Go's cmd/internal/obj/dwarf.go)
// ===========================================================================

// Generate a sequence of opcodes that is as short as possible.
// See DWARF spec section 6.2.5
pub const LINE_BASE: i8 = -4;
pub const LINE_RANGE: u8 = 10;
pub const OPCODE_BASE: u8 = 11;
pub const PC_RANGE: u8 = (255 - OPCODE_BASE) / LINE_RANGE; // = 24

// ===========================================================================
// LEB128 Encoding (from Go's cmd/internal/dwarf/dwarf.go)
// ===========================================================================

/// Append unsigned LEB128 encoding of v to buffer
pub fn appendUleb128(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, v: u64) !void {
    var value = v;
    while (true) {
        var c: u8 = @truncate(value & 0x7f);
        value >>= 7;
        if (value != 0) {
            c |= 0x80;
        }
        try buf.append(allocator, c);
        if (c & 0x80 == 0) {
            break;
        }
    }
}

/// Append signed LEB128 encoding of v to buffer
pub fn appendSleb128(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, v: i64) !void {
    var value = v;
    while (true) {
        const c: u8 = @truncate(@as(u64, @bitCast(value)) & 0x7f);
        const s: u8 = @truncate(@as(u64, @bitCast(value)) & 0x40);
        value >>= 7;
        if ((value != -1 or s == 0) and (value != 0 or s != 0)) {
            try buf.append(allocator, c | 0x80);
        } else {
            try buf.append(allocator, c);
            break;
        }
    }
}

// ===========================================================================
// Line Entry - tracks code offset to source location mapping
// ===========================================================================

pub const LineEntry = struct {
    code_offset: u32, // Offset in code section
    source_offset: u32, // Byte offset in source file
};

// ===========================================================================
// DWARF Debug Info Builder (follows Go's architecture)
// ===========================================================================

pub const DwarfBuilder = struct {
    allocator: std.mem.Allocator,

    // Output buffers
    debug_line: std.ArrayListUnmanaged(u8) = .{},
    debug_abbrev: std.ArrayListUnmanaged(u8) = .{},
    debug_info: std.ArrayListUnmanaged(u8) = .{},

    // Relocations for addresses that need to be fixed by the linker
    debug_line_relocs: std.ArrayListUnmanaged(DebugReloc) = .{},
    debug_info_relocs: std.ArrayListUnmanaged(DebugReloc) = .{},

    // Source file info
    source_file: []const u8 = "",
    source_text: []const u8 = "",
    comp_dir: []const u8 = "",

    // Code size
    text_size: u64 = 0,

    pub const DebugReloc = struct {
        offset: u32, // Offset within the debug section
        symbol_idx: u32, // Symbol index for relocation
    };

    pub fn init(allocator: std.mem.Allocator) DwarfBuilder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DwarfBuilder) void {
        self.debug_line.deinit(self.allocator);
        self.debug_abbrev.deinit(self.allocator);
        self.debug_info.deinit(self.allocator);
        self.debug_line_relocs.deinit(self.allocator);
        self.debug_info_relocs.deinit(self.allocator);
    }

    pub fn setSourceInfo(self: *DwarfBuilder, file: []const u8, text: []const u8) void {
        self.source_file = file;
        self.source_text = text;
        // Extract directory from file path
        if (std.mem.lastIndexOf(u8, file, "/")) |idx| {
            self.comp_dir = file[0..idx];
        } else {
            self.comp_dir = ".";
        }
    }

    pub fn setTextSize(self: *DwarfBuilder, size: u64) void {
        self.text_size = size;
    }

    /// Convert source byte offset to line number
    fn sourceOffsetToLine(self: *DwarfBuilder, offset: u32) u32 {
        if (offset >= self.source_text.len) return 1;

        var line: u32 = 1;
        for (self.source_text[0..offset]) |c| {
            if (c == '\n') line += 1;
        }
        return line;
    }

    // =========================================================================
    // Generate Debug Sections (following Go's linker structure)
    // =========================================================================

    /// Generate all DWARF debug sections
    pub fn generate(self: *DwarfBuilder, line_entries: []const LineEntry, text_symbol_idx: u32) !void {
        try self.generateDebugAbbrev();
        try self.generateDebugInfo(text_symbol_idx);
        try self.generateDebugLine(line_entries, text_symbol_idx);
    }

    /// Generate .debug_abbrev section
    /// Following Go's structure in cmd/internal/dwarf/dwarf.go
    fn generateDebugAbbrev(self: *DwarfBuilder) !void {
        const buf = &self.debug_abbrev;
        const alloc = self.allocator;

        // Abbreviation 1: DW_TAG_compile_unit
        try appendUleb128(buf, alloc, 1); // Abbreviation code
        try appendUleb128(buf, alloc, DW_TAG_compile_unit);
        try buf.append(alloc, DW_CHILDREN_no);

        // Attributes for compile_unit
        try appendUleb128(buf, alloc, DW_AT_name);
        try appendUleb128(buf, alloc, DW_FORM_string);
        try appendUleb128(buf, alloc, DW_AT_comp_dir);
        try appendUleb128(buf, alloc, DW_FORM_string);
        try appendUleb128(buf, alloc, DW_AT_stmt_list);
        try appendUleb128(buf, alloc, DW_FORM_sec_offset);
        try appendUleb128(buf, alloc, DW_AT_low_pc);
        try appendUleb128(buf, alloc, DW_FORM_addr);
        try appendUleb128(buf, alloc, DW_AT_high_pc);
        try appendUleb128(buf, alloc, DW_FORM_data8);

        // End of attributes
        try appendUleb128(buf, alloc, 0);
        try appendUleb128(buf, alloc, 0);

        // End of abbreviations
        try appendUleb128(buf, alloc, 0);
    }

    /// Generate .debug_info section
    /// Following Go's linker structure
    fn generateDebugInfo(self: *DwarfBuilder, text_symbol_idx: u32) !void {
        const buf = &self.debug_info;
        const alloc = self.allocator;

        // Reserve space for unit length (will be filled in at end)
        const unit_length_offset = buf.items.len;
        try buf.appendNTimes(alloc, 0, 4); // 4-byte unit length

        const unit_start = buf.items.len;

        // DWARF version (2 bytes)
        try buf.append(alloc, 4); // Version 4
        try buf.append(alloc, 0);

        // Abbrev offset (4 bytes)
        try buf.appendNTimes(alloc, 0, 4); // Offset 0 into .debug_abbrev

        // Address size (1 byte)
        try buf.append(alloc, 8); // 64-bit addresses

        // DIE: DW_TAG_compile_unit (abbreviation 1)
        try appendUleb128(buf, alloc, 1);

        // DW_AT_name (string)
        try buf.appendSlice(alloc, self.source_file);
        try buf.append(alloc, 0); // null terminator

        // DW_AT_comp_dir (string)
        try buf.appendSlice(alloc, self.comp_dir);
        try buf.append(alloc, 0); // null terminator

        // DW_AT_stmt_list (4-byte offset into .debug_line)
        try buf.appendNTimes(alloc, 0, 4); // Offset 0

        // DW_AT_low_pc (8-byte address) - needs relocation
        const low_pc_offset: u32 = @intCast(buf.items.len);
        try self.debug_info_relocs.append(alloc, .{
            .offset = low_pc_offset,
            .symbol_idx = text_symbol_idx,
        });
        try buf.appendNTimes(alloc, 0, 8); // Placeholder for relocated address

        // DW_AT_high_pc (8-byte size, relative to low_pc in DWARF4)
        const high_pc_bytes = std.mem.toBytes(self.text_size);
        try buf.appendSlice(alloc, &high_pc_bytes);

        // Fill in unit length
        const unit_length: u32 = @intCast(buf.items.len - unit_start);
        @memcpy(buf.items[unit_length_offset..][0..4], &std.mem.toBytes(unit_length));
    }

    /// Generate .debug_line section
    /// Following Go's generateDebugLinesSymbol from cmd/internal/obj/dwarf.go
    /// and writelines from cmd/link/internal/ld/dwarf.go
    fn generateDebugLine(self: *DwarfBuilder, line_entries: []const LineEntry, text_symbol_idx: u32) !void {
        const buf = &self.debug_line;
        const alloc = self.allocator;

        // =====================================================================
        // Line Number Program Header (from Go's linker writelines)
        // See DWARF spec section 6.2.4
        // =====================================================================

        // Reserve space for total_length (filled in at end)
        const total_length_offset = buf.items.len;
        try buf.appendNTimes(alloc, 0, 4);

        const header_start = buf.items.len;

        // Version (2 bytes) - DWARF 4
        try buf.append(alloc, 4);
        try buf.append(alloc, 0);

        // Reserve space for header_length (filled in at end)
        const header_length_offset = buf.items.len;
        try buf.appendNTimes(alloc, 0, 4);

        const prologue_start = buf.items.len;

        // minimum_instruction_length - Go uses 1 for byte-level addressing
        try buf.append(alloc, 1);

        // maximum_operations_per_instruction (DWARF 4)
        try buf.append(alloc, 1);

        // default_is_stmt
        try buf.append(alloc, 1);

        // line_base (signed)
        try buf.append(alloc, @bitCast(LINE_BASE));

        // line_range
        try buf.append(alloc, LINE_RANGE);

        // opcode_base
        try buf.append(alloc, OPCODE_BASE);

        // standard_opcode_lengths (OPCODE_BASE - 1 entries)
        // From Go's writelines in cmd/link/internal/ld/dwarf.go
        try buf.append(alloc, 0); // DW_LNS_copy
        try buf.append(alloc, 1); // DW_LNS_advance_pc
        try buf.append(alloc, 1); // DW_LNS_advance_line
        try buf.append(alloc, 1); // DW_LNS_set_file
        try buf.append(alloc, 1); // DW_LNS_set_column
        try buf.append(alloc, 0); // DW_LNS_negate_stmt
        try buf.append(alloc, 0); // DW_LNS_set_basic_block
        try buf.append(alloc, 0); // DW_LNS_const_add_pc
        try buf.append(alloc, 1); // DW_LNS_fixed_advance_pc
        try buf.append(alloc, 0); // DW_LNS_set_prologue_end

        // Directory table (terminated by null byte)
        // We use a single entry: the compilation directory
        try buf.appendSlice(alloc, self.comp_dir);
        try buf.append(alloc, 0);
        try buf.append(alloc, 0); // End of directory table

        // File name table
        // Entry format: filename, dir_index (ULEB128), mod_time (ULEB128), file_length (ULEB128)
        // Extract just the filename from the path
        const filename = if (std.mem.lastIndexOf(u8, self.source_file, "/")) |idx|
            self.source_file[idx + 1 ..]
        else
            self.source_file;

        try buf.appendSlice(alloc, filename);
        try buf.append(alloc, 0); // null terminator
        try appendUleb128(buf, alloc, 1); // dir_index (1 = first directory)
        try appendUleb128(buf, alloc, 0); // mod_time
        try appendUleb128(buf, alloc, 0); // file_length
        try buf.append(alloc, 0); // End of file name table

        // Fill in header_length
        const header_length: u32 = @intCast(buf.items.len - prologue_start);
        @memcpy(buf.items[header_length_offset..][0..4], &std.mem.toBytes(header_length));

        // =====================================================================
        // Line Number Program (from Go's generateDebugLinesSymbol)
        // =====================================================================

        // Emit DW_LNE_set_address extended opcode to set starting address
        // This needs a relocation
        try buf.append(alloc, 0); // Extended opcode marker
        try appendUleb128(buf, alloc, 1 + 8); // Length: 1 (opcode) + 8 (address)
        try buf.append(alloc, DW_LNE_set_address);

        // Record relocation for the address
        const set_address_offset: u32 = @intCast(buf.items.len);
        try self.debug_line_relocs.append(alloc, .{
            .offset = set_address_offset,
            .symbol_idx = text_symbol_idx,
        });
        try buf.appendNTimes(alloc, 0, 8); // Placeholder for relocated address

        // Initialize state machine (following Go's approach)
        var pc: u64 = 0;
        var line: i64 = 1;

        // Walk through line entries and emit opcodes
        for (line_entries) |entry| {
            const new_line = self.sourceOffsetToLine(entry.source_offset);
            const delta_pc = entry.code_offset - pc;
            const delta_line: i64 = @as(i64, new_line) - line;

            // Use Go's putpclcdelta logic
            try self.putPcLcDelta(delta_pc, delta_line);

            pc = entry.code_offset;
            line = new_line;
        }

        // Advance PC to end of text section
        const final_delta = self.text_size - pc;
        if (final_delta > 0) {
            try buf.append(alloc, DW_LNS_advance_pc);
            try appendUleb128(buf, alloc, final_delta);
        }

        // Emit DW_LNE_end_sequence
        try buf.append(alloc, 0); // Extended opcode marker
        try appendUleb128(buf, alloc, 1); // Length
        try buf.append(alloc, DW_LNE_end_sequence);

        // Fill in total_length
        const total_length: u32 = @intCast(buf.items.len - header_start);
        @memcpy(buf.items[total_length_offset..][0..4], &std.mem.toBytes(total_length));
    }

    /// Emit opcodes for PC and line change
    /// Following Go's putpclcdelta from cmd/internal/obj/dwarf.go
    fn putPcLcDelta(self: *DwarfBuilder, delta_pc: u64, delta_lc: i64) !void {
        const buf = &self.debug_line;
        const alloc = self.allocator;

        // Choose a special opcode that minimizes bytes needed
        var opcode: i64 = undefined;

        if (delta_lc < LINE_BASE) {
            if (delta_pc >= PC_RANGE) {
                opcode = OPCODE_BASE + (LINE_RANGE * PC_RANGE);
            } else {
                opcode = OPCODE_BASE + (LINE_RANGE * @as(i64, @intCast(delta_pc)));
            }
        } else if (delta_lc < LINE_BASE + LINE_RANGE) {
            if (delta_pc >= PC_RANGE) {
                opcode = OPCODE_BASE + (delta_lc - LINE_BASE) + (LINE_RANGE * PC_RANGE);
                if (opcode > 255) {
                    opcode -= LINE_RANGE;
                }
            } else {
                opcode = OPCODE_BASE + (delta_lc - LINE_BASE) + (LINE_RANGE * @as(i64, @intCast(delta_pc)));
            }
        } else {
            if (delta_pc <= PC_RANGE) {
                opcode = OPCODE_BASE + (LINE_RANGE - 1) + (LINE_RANGE * @as(i64, @intCast(delta_pc)));
                if (opcode > 255) {
                    opcode = 255;
                }
            } else {
                opcode = 255;
            }
        }

        // Subtract from deltaPC and deltaLC the amounts the opcode will add
        const remaining_pc = delta_pc - @as(u64, @intCast(@divFloor(opcode - OPCODE_BASE, LINE_RANGE)));
        const remaining_lc = delta_lc - (@mod(opcode - OPCODE_BASE, LINE_RANGE) + LINE_BASE);

        // Encode remaining PC delta
        if (remaining_pc != 0) {
            if (remaining_pc <= PC_RANGE) {
                // Adjust opcode to use DW_LNS_const_add_pc
                opcode -= LINE_RANGE * @as(i64, @intCast(PC_RANGE - remaining_pc));
                try buf.append(alloc, DW_LNS_const_add_pc);
            } else if (remaining_pc >= (1 << 14) and remaining_pc < (1 << 16)) {
                try buf.append(alloc, DW_LNS_fixed_advance_pc);
                const pc16: u16 = @intCast(remaining_pc);
                try buf.appendSlice(alloc, &std.mem.toBytes(pc16));
            } else {
                try buf.append(alloc, DW_LNS_advance_pc);
                try appendUleb128(buf, alloc, remaining_pc);
            }
        }

        // Encode remaining line delta
        if (remaining_lc != 0) {
            try buf.append(alloc, DW_LNS_advance_line);
            try appendSleb128(buf, alloc, remaining_lc);
        }

        // Output the special opcode
        try buf.append(alloc, @intCast(@as(u8, @truncate(@as(u64, @bitCast(opcode))))));
    }
};

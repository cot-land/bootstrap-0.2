//! Mach-O Object File Writer
//!
//! Generates Mach-O object files for macOS ARM64.
//! Reference: Apple's Mach-O file format documentation
//!
//! ## Mach-O Structure
//!
//! ```
//! +------------------+
//! | Mach-O Header    |  64 bytes
//! +------------------+
//! | Load Commands    |  Variable size
//! +------------------+
//! | __TEXT Segment   |
//! |   __text section |  Code
//! +------------------+
//! | __DATA Segment   |
//! |   __data section |  Initialized data
//! +------------------+
//! | Symbol Table     |
//! +------------------+
//! | String Table     |
//! +------------------+
//! ```

const std = @import("std");

// =========================================
// Mach-O Constants
// =========================================

/// Mach-O magic numbers
pub const MH_MAGIC_64: u32 = 0xFEEDFACF;
pub const MH_CIGAM_64: u32 = 0xCFFAEDFE;

/// CPU types
pub const CPU_TYPE_ARM64: u32 = 0x0100000C;
pub const CPU_SUBTYPE_ARM64_ALL: u32 = 0x00000000;

/// File types
pub const MH_OBJECT: u32 = 0x1;
pub const MH_EXECUTE: u32 = 0x2;
pub const MH_DYLIB: u32 = 0x6;

/// Flags
pub const MH_SUBSECTIONS_VIA_SYMBOLS: u32 = 0x2000;

/// Load command types
pub const LC_SEGMENT_64: u32 = 0x19;
pub const LC_SYMTAB: u32 = 0x02;
pub const LC_DYSYMTAB: u32 = 0x0B;
pub const LC_BUILD_VERSION: u32 = 0x32;

/// Section types
pub const S_REGULAR: u32 = 0x0;
pub const S_ZEROFILL: u32 = 0x1;
pub const S_CSTRING_LITERALS: u32 = 0x2;

/// Section attributes
pub const S_ATTR_PURE_INSTRUCTIONS: u32 = 0x80000000;
pub const S_ATTR_SOME_INSTRUCTIONS: u32 = 0x00000400;

/// Symbol types
pub const N_UNDF: u8 = 0x0;
pub const N_EXT: u8 = 0x1;
pub const N_SECT: u8 = 0xE;

// =========================================
// Header Structures
// =========================================

/// Mach-O 64-bit header
pub const MachHeader64 = extern struct {
    magic: u32 = MH_MAGIC_64,
    cputype: u32 = CPU_TYPE_ARM64,
    cpusubtype: u32 = CPU_SUBTYPE_ARM64_ALL,
    filetype: u32 = MH_OBJECT,
    ncmds: u32 = 0,
    sizeofcmds: u32 = 0,
    flags: u32 = MH_SUBSECTIONS_VIA_SYMBOLS,
    reserved: u32 = 0,
};

/// Segment load command (64-bit)
pub const SegmentCommand64 = extern struct {
    cmd: u32 = LC_SEGMENT_64,
    cmdsize: u32 = 0,
    segname: [16]u8 = std.mem.zeroes([16]u8),
    vmaddr: u64 = 0,
    vmsize: u64 = 0,
    fileoff: u64 = 0,
    filesize: u64 = 0,
    maxprot: u32 = 0x7, // rwx
    initprot: u32 = 0x7,
    nsects: u32 = 0,
    flags: u32 = 0,
};

/// Section (64-bit)
pub const Section64 = extern struct {
    sectname: [16]u8 = std.mem.zeroes([16]u8),
    segname: [16]u8 = std.mem.zeroes([16]u8),
    addr: u64 = 0,
    size: u64 = 0,
    offset: u32 = 0,
    @"align": u32 = 0,
    reloff: u32 = 0,
    nreloc: u32 = 0,
    flags: u32 = 0,
    reserved1: u32 = 0,
    reserved2: u32 = 0,
    reserved3: u32 = 0,
};

/// Symbol table load command
pub const SymtabCommand = extern struct {
    cmd: u32 = LC_SYMTAB,
    cmdsize: u32 = @sizeOf(SymtabCommand),
    symoff: u32 = 0,
    nsyms: u32 = 0,
    stroff: u32 = 0,
    strsize: u32 = 0,
};

/// Symbol table entry (64-bit)
pub const Nlist64 = extern struct {
    n_strx: u32 = 0, // Index into string table
    n_type: u8 = 0, // Type flag
    n_sect: u8 = 0, // Section number (1-indexed)
    n_desc: u16 = 0, // Description
    n_value: u64 = 0, // Value (address)
};

/// Relocation entry
pub const RelocationInfo = extern struct {
    r_address: u32, // Offset in section
    r_info: u32, // Symbol index, pcrel, length, extern, type

    /// Create a relocation info word
    /// Format: symbolnum (24 bits) | pcrel (1) | length (2) | extern (1) | type (4)
    pub fn makeInfo(symbolnum: u24, pcrel: bool, length: u2, ext: bool, reloc_type: u4) u32 {
        return @as(u32, symbolnum) |
            (@as(u32, @intFromBool(pcrel)) << 24) |
            (@as(u32, length) << 25) |
            (@as(u32, @intFromBool(ext)) << 27) |
            (@as(u32, reloc_type) << 28);
    }
};

/// ARM64 relocation types
pub const ARM64_RELOC_UNSIGNED: u4 = 0; // Absolute address
pub const ARM64_RELOC_SUBTRACTOR: u4 = 1; // Subtractor for differences
pub const ARM64_RELOC_BRANCH26: u4 = 2; // BL instruction
pub const ARM64_RELOC_PAGE21: u4 = 3; // ADRP instruction (page address)
pub const ARM64_RELOC_PAGEOFF12: u4 = 4; // ADD/LDR instruction (page offset)

// =========================================
// Writer
// =========================================

/// Symbol definition
pub const Symbol = struct {
    name: []const u8,
    value: u64,
    section: u8, // 1 = text, 2 = data, 0 = undefined
    external: bool,
};

/// Relocation definition for the writer
pub const Relocation = struct {
    offset: u32, // Offset in text section
    target: []const u8, // Target symbol name
};

/// Extended relocation with type information
pub const ExtRelocation = struct {
    offset: u32, // Offset in text section
    target: []const u8, // Symbol name
    reloc_type: u4, // ARM64_RELOC_*
    length: u2 = 2, // log2(size): 2 = 4 bytes
    pc_rel: bool = false, // PC-relative?
};

/// String literal data with symbol name
pub const StringLiteral = struct {
    data: []const u8, // The actual string bytes
    symbol: []const u8, // Symbol name for this string
};

/// Mach-O object file writer
pub const MachOWriter = struct {
    allocator: std.mem.Allocator,

    /// Code section content
    text_data: std.ArrayListUnmanaged(u8),

    /// Data section content
    data: std.ArrayListUnmanaged(u8),

    /// Constant string literals (for __cstring section)
    cstring_data: std.ArrayListUnmanaged(u8),

    /// String literal symbols (offset in cstring_data -> symbol name)
    string_literals: std.ArrayListUnmanaged(StringLiteral),

    /// Symbols
    symbols: std.ArrayListUnmanaged(Symbol),

    /// Relocations for function calls (branch)
    relocations: std.ArrayListUnmanaged(Relocation),

    /// Extended relocations for data references (PAGE21, PAGEOFF12)
    data_relocations: std.ArrayListUnmanaged(ExtRelocation),

    /// String table (for symbol names)
    strings: std.ArrayListUnmanaged(u8),

    /// Counter for generating unique string symbol names
    string_counter: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) MachOWriter {
        var writer = MachOWriter{
            .allocator = allocator,
            .text_data = .{},
            .data = .{},
            .cstring_data = .{},
            .string_literals = .{},
            .symbols = .{},
            .relocations = .{},
            .data_relocations = .{},
            .strings = .{},
            .string_counter = 0,
        };

        // String table starts with null byte
        writer.strings.append(allocator, 0) catch {};

        return writer;
    }

    pub fn deinit(self: *MachOWriter) void {
        self.text_data.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.cstring_data.deinit(self.allocator);
        self.string_literals.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.relocations.deinit(self.allocator);
        self.data_relocations.deinit(self.allocator);
        self.strings.deinit(self.allocator);
    }

    /// Add code to text section.
    pub fn addCode(self: *MachOWriter, code: []const u8) !void {
        try self.text_data.appendSlice(self.allocator, code);
    }

    /// Add data to data section.
    pub fn addData(self: *MachOWriter, bytes: []const u8) !void {
        try self.data.appendSlice(self.allocator, bytes);
    }

    /// Add a symbol.
    pub fn addSymbol(self: *MachOWriter, name: []const u8, value: u64, section: u8, external: bool) !void {
        try self.symbols.append(self.allocator, .{
            .name = name,
            .value = value,
            .section = section,
            .external = external,
        });
    }

    /// Add a relocation for a function call.
    pub fn addRelocation(self: *MachOWriter, offset: u32, target: []const u8) !void {
        try self.relocations.append(self.allocator, .{
            .offset = offset,
            .target = target,
        });
    }

    /// Add a string literal to the data section.
    /// Returns the symbol name for this string.
    /// Deduplicates: if same content exists, returns existing symbol.
    pub fn addStringLiteral(self: *MachOWriter, str: []const u8) ![]const u8 {
        // Check for existing string with same content (deduplication)
        for (self.string_literals.items) |existing| {
            if (std.mem.eql(u8, existing.data, str)) {
                return existing.symbol; // Reuse existing symbol
            }
        }

        // Generate unique symbol name for new string
        const sym_name = try std.fmt.allocPrint(self.allocator, "L_.str.{d}", .{self.string_counter});
        self.string_counter += 1;

        // Record offset in data section
        const offset: u32 = @intCast(self.data.items.len);

        // Add string data (without null terminator - we store length separately)
        try self.data.appendSlice(self.allocator, str);

        // Align to 8 bytes for next item
        while (self.data.items.len % 8 != 0) {
            try self.data.append(self.allocator, 0);
        }

        // Add to string literals list (for tracking and deduplication)
        try self.string_literals.append(self.allocator, .{
            .data = str,
            .symbol = sym_name,
        });

        // Add symbol for this string (section 2 = __data)
        // Mark as external for PAGE21/PAGEOFF12 relocations to work
        try self.symbols.append(self.allocator, .{
            .name = sym_name,
            .value = offset,
            .section = 2, // __data section
            .external = true, // Required for PAGE21/PAGEOFF12 relocations
        });

        return sym_name;
    }

    /// Add a data relocation (PAGE21 or PAGEOFF12).
    pub fn addDataRelocation(self: *MachOWriter, offset: u32, target: []const u8, reloc_type: u4) !void {
        try self.data_relocations.append(self.allocator, .{
            .offset = offset,
            .target = target,
            .reloc_type = reloc_type,
            .length = 2, // 4 bytes
            .pc_rel = reloc_type == ARM64_RELOC_PAGE21, // PAGE21 is PC-relative
        });
    }

    /// Add string to string table, return its offset.
    fn addString(self: *MachOWriter, s: []const u8) !u32 {
        const offset: u32 = @intCast(self.strings.items.len);
        try self.strings.appendSlice(self.allocator, s);
        try self.strings.append(self.allocator, 0); // null terminator
        return offset;
    }

    /// Align to boundary.
    fn alignTo(offset: u64, alignment: u64) u64 {
        return (offset + alignment - 1) & ~(alignment - 1);
    }

    /// Write the complete object file.
    pub fn write(self: *MachOWriter, writer: anytype) !void {
        // Step 1: Build symbol name -> index map for existing symbols
        var sym_name_to_idx = std.StringHashMap(u32).init(self.allocator);
        defer sym_name_to_idx.deinit();

        for (self.symbols.items, 0..) |sym, i| {
            try sym_name_to_idx.put(sym.name, @intCast(i));
        }

        // Step 1b: Collect unique external relocation targets and add as undefined symbols
        const base_sym_count: u32 = @intCast(self.symbols.items.len);
        var extern_sym_count: u32 = 0;

        for (self.relocations.items) |reloc| {
            if (!sym_name_to_idx.contains(reloc.target)) {
                const sym_idx = base_sym_count + extern_sym_count;
                try sym_name_to_idx.put(reloc.target, sym_idx);
                // Add undefined external symbol
                try self.symbols.append(self.allocator, .{
                    .name = reloc.target,
                    .value = 0,
                    .section = 0, // N_UNDF
                    .external = true,
                });
                extern_sym_count += 1;
            }
        }

        // Also check data relocations for external symbols
        for (self.data_relocations.items) |reloc| {
            if (!sym_name_to_idx.contains(reloc.target)) {
                const sym_idx: u32 = @intCast(self.symbols.items.len);
                try sym_name_to_idx.put(reloc.target, sym_idx);
                try self.symbols.append(self.allocator, .{
                    .name = reloc.target,
                    .value = 0,
                    .section = 0, // N_UNDF
                    .external = true,
                });
            }
        }

        // Step 2: Pre-add all symbol names to string table
        var symbol_strx = std.ArrayListUnmanaged(u32){};
        defer symbol_strx.deinit(self.allocator);
        for (self.symbols.items) |sym| {
            const strx = try self.addString(sym.name);
            try symbol_strx.append(self.allocator, strx);
        }

        // Step 3: Calculate sizes and offsets
        const header_size: u64 = @sizeOf(MachHeader64);
        const segment_cmd_size: u64 = @sizeOf(SegmentCommand64);
        const section_size: u64 = @sizeOf(Section64);
        const symtab_cmd_size: u64 = @sizeOf(SymtabCommand);

        const num_sections: u32 = 2; // __text and __data
        const load_cmds_size = segment_cmd_size + (section_size * num_sections) + symtab_cmd_size;

        const text_offset = header_size + load_cmds_size;
        const text_size: u64 = self.text_data.items.len;

        const data_offset = alignTo(text_offset + text_size, 8);
        const data_size: u64 = self.data.items.len;

        // Relocations come after data section
        const reloc_offset = alignTo(data_offset + data_size, 4);
        const num_branch_relocs: u32 = @intCast(self.relocations.items.len);
        const num_data_relocs: u32 = @intCast(self.data_relocations.items.len);
        const num_relocs: u32 = num_branch_relocs + num_data_relocs;
        const reloc_size: u64 = @as(u64, num_relocs) * @sizeOf(RelocationInfo);

        const symtab_offset = alignTo(reloc_offset + reloc_size, 8);
        const num_syms: u32 = @intCast(self.symbols.items.len);

        const strtab_offset = symtab_offset + @as(u64, num_syms) * @sizeOf(Nlist64);
        const strtab_size: u32 = @intCast(self.strings.items.len);

        // Step 4: Write header
        var header = MachHeader64{
            .ncmds = 2, // segment + symtab
            .sizeofcmds = @intCast(load_cmds_size),
        };
        try writer.writeAll(std.mem.asBytes(&header));

        // Step 5: Write segment command
        // Note: vmsize must be >= filesize for valid Mach-O
        const segment_filesize = data_offset + data_size - text_offset;
        var segment = SegmentCommand64{
            .cmdsize = @intCast(segment_cmd_size + section_size * num_sections),
            .vmsize = segment_filesize, // Must match or exceed filesize
            .fileoff = text_offset,
            .filesize = segment_filesize,
            .nsects = num_sections,
        };
        try writer.writeAll(std.mem.asBytes(&segment));

        // Step 6: Write __text section with relocation info
        var text_sect = Section64{
            .size = text_size,
            .offset = @intCast(text_offset),
            .@"align" = 2, // 4-byte aligned
            .reloff = if (num_relocs > 0) @intCast(reloc_offset) else 0,
            .nreloc = num_relocs,
            .flags = S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS,
        };
        @memcpy(text_sect.sectname[0..6], "__text");
        @memcpy(text_sect.segname[0..6], "__TEXT");
        try writer.writeAll(std.mem.asBytes(&text_sect));

        // Step 7: Write __data section
        var data_sect = Section64{
            .size = data_size,
            .offset = @intCast(data_offset),
            .@"align" = 3, // 8-byte aligned
        };
        @memcpy(data_sect.sectname[0..6], "__data");
        @memcpy(data_sect.segname[0..6], "__DATA");
        try writer.writeAll(std.mem.asBytes(&data_sect));

        // Step 8: Write symtab command
        var symtab = SymtabCommand{
            .symoff = @intCast(symtab_offset),
            .nsyms = num_syms,
            .stroff = @intCast(strtab_offset),
            .strsize = strtab_size,
        };
        try writer.writeAll(std.mem.asBytes(&symtab));

        // Step 9: Write text section content
        try writer.writeAll(self.text_data.items);

        // Pad to data section offset
        const text_end = text_offset + text_size;
        const pad_size = data_offset - text_end;
        if (pad_size > 0) {
            var padding: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
            try writer.writeAll(padding[0..@intCast(pad_size)]);
        }

        // Step 10: Write data section content
        try writer.writeAll(self.data.items);

        // Pad to relocation table offset
        const data_end = data_offset + data_size;
        const reloc_pad = reloc_offset - data_end;
        if (reloc_pad > 0) {
            var padding: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
            try writer.writeAll(padding[0..@intCast(reloc_pad)]);
        }

        // Step 11: Write relocation entries
        // First, branch relocations (BL instructions)
        for (self.relocations.items) |reloc| {
            const sym_idx = sym_name_to_idx.get(reloc.target) orelse 0;
            const reloc_entry = RelocationInfo{
                .r_address = reloc.offset,
                .r_info = RelocationInfo.makeInfo(
                    @intCast(sym_idx), // symbol index
                    true, // PC-relative
                    2, // length = 4 bytes (log2)
                    true, // external
                    ARM64_RELOC_BRANCH26, // BL instruction relocation
                ),
            };
            try writer.writeAll(std.mem.asBytes(&reloc_entry));
        }

        // Then, data relocations (ADRP/ADD for addresses)
        for (self.data_relocations.items) |reloc| {
            const sym_idx = sym_name_to_idx.get(reloc.target) orelse 0;
            // Use the external field from symbol for PAGE21/PAGEOFF12 to work
            const is_external = if (sym_idx < self.symbols.items.len)
                self.symbols.items[sym_idx].external
            else
                true;
            const reloc_entry = RelocationInfo{
                .r_address = reloc.offset,
                .r_info = RelocationInfo.makeInfo(
                    @intCast(sym_idx),
                    reloc.pc_rel,
                    reloc.length,
                    is_external,
                    reloc.reloc_type,
                ),
            };
            try writer.writeAll(std.mem.asBytes(&reloc_entry));
        }

        // Pad to symtab offset
        const reloc_end = reloc_offset + reloc_size;
        const sym_pad = symtab_offset - reloc_end;
        if (sym_pad > 0) {
            var padding: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
            try writer.writeAll(padding[0..@intCast(sym_pad)]);
        }

        // Step 12: Write symbol table
        for (self.symbols.items, 0..) |sym, i| {
            var nlist = Nlist64{
                .n_strx = symbol_strx.items[i],
                .n_type = if (sym.section == 0) N_EXT else (N_SECT | (if (sym.external) N_EXT else 0)),
                .n_sect = sym.section,
                .n_value = sym.value,
            };
            try writer.writeAll(std.mem.asBytes(&nlist));
        }

        // Write string table
        try writer.writeAll(self.strings.items);
    }

    /// Write to file.
    pub fn writeToFile(self: *MachOWriter, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try self.write(file.writer());
    }
};

// =========================================
// Tests
// =========================================

test "MachHeader64 size" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(MachHeader64));
}

test "SegmentCommand64 size" {
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(SegmentCommand64));
}

test "Section64 size" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(Section64));
}

test "Nlist64 size" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Nlist64));
}

test "MachOWriter basic usage" {
    const allocator = std.testing.allocator;

    var writer = MachOWriter.init(allocator);
    defer writer.deinit();

    // Add some code (NOP instruction)
    try writer.addCode(&[_]u8{ 0x1F, 0x20, 0x03, 0xD5 });

    // Add a symbol
    try writer.addSymbol("_main", 0, 1, true);

    // Write to memory buffer
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);
    try writer.write(output.writer(allocator));

    // Verify header magic
    try std.testing.expect(output.items.len >= 4);
    const magic = std.mem.readInt(u32, output.items[0..4], .little);
    try std.testing.expectEqual(MH_MAGIC_64, magic);
}

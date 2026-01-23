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
const dwarf = @import("../dwarf.zig");

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

    // === DWARF Debug Info ===

    /// Line entries for DWARF __debug_line section
    line_entries: std.ArrayListUnmanaged(LineEntry) = .{},

    /// Source file name for DWARF
    source_file: ?[]const u8 = null,

    /// Source text for converting byte offsets to line/column
    source_text: ?[]const u8 = null,

    /// Generated __debug_line section content
    debug_line_data: std.ArrayListUnmanaged(u8) = .{},

    /// Generated __debug_abbrev section content
    debug_abbrev_data: std.ArrayListUnmanaged(u8) = .{},

    /// Generated __debug_info section content
    debug_info_data: std.ArrayListUnmanaged(u8) = .{},

    /// Relocations for debug_line section (e.g., DW_LNE_set_address)
    debug_line_relocs: std.ArrayListUnmanaged(DebugReloc) = .{},

    /// Relocations for debug_info section (e.g., DW_AT_low_pc)
    debug_info_relocs: std.ArrayListUnmanaged(DebugReloc) = .{},

    pub const DebugReloc = struct {
        offset: u32, // Offset within the debug section where relocation is needed
        symbol_idx: u32, // Symbol index to relocate to (e.g., _main)
    };

    pub const LineEntry = struct {
        code_offset: u32,
        source_offset: u32, // Byte offset in source file
    };

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
        self.line_entries.deinit(self.allocator);
        self.debug_line_data.deinit(self.allocator);
        self.debug_abbrev_data.deinit(self.allocator);
        self.debug_info_data.deinit(self.allocator);
        self.debug_line_relocs.deinit(self.allocator);
        self.debug_info_relocs.deinit(self.allocator);
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

    /// Add a global variable to the data section.
    /// Allocates space (zero-initialized) and creates a symbol for it.
    /// name: Global variable name (without underscore prefix)
    /// size: Size in bytes
    pub fn addGlobalVariable(self: *MachOWriter, name: []const u8, size: u32) !void {
        // Align to 8 bytes before adding global
        while (self.data.items.len % 8 != 0) {
            try self.data.append(self.allocator, 0);
        }

        // Record offset in data section
        const offset: u32 = @intCast(self.data.items.len);

        // Add zero-initialized space for the global variable
        for (0..size) |_| {
            try self.data.append(self.allocator, 0);
        }

        // Create mangled symbol name with underscore prefix (Darwin ABI)
        const sym_name = try std.fmt.allocPrint(self.allocator, "_{s}", .{name});

        // Add symbol for this global (section 2 = __data)
        // Mark as external for PAGE21/PAGEOFF12 relocations to work
        try self.symbols.append(self.allocator, .{
            .name = sym_name,
            .value = offset,
            .section = 2, // __data section
            .external = true, // Required for PAGE21/PAGEOFF12 relocations
        });
    }

    /// Set debug info for DWARF generation.
    /// source_file: Source file path
    /// source_text: Source text content (for byte offset → line/col conversion)
    pub fn setDebugInfo(self: *MachOWriter, source_file: []const u8, source_text: []const u8) void {
        self.source_file = source_file;
        self.source_text = source_text;
    }

    /// Add line entries for DWARF debug info.
    /// entries: Slice of LineEntry from codegen
    pub fn addLineEntries(self: *MachOWriter, entries: []const LineEntry) !void {
        try self.line_entries.appendSlice(self.allocator, entries);
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

        // Check for debug sections
        const has_debug = self.debug_line_data.items.len > 0;
        const num_sections: u32 = if (has_debug) 5 else 2; // +3 debug sections
        const load_cmds_size = segment_cmd_size + (section_size * num_sections) + symtab_cmd_size;

        const text_offset = header_size + load_cmds_size;
        const text_size: u64 = self.text_data.items.len;

        const data_offset = alignTo(text_offset + text_size, 8);
        const data_size: u64 = self.data.items.len;

        // Debug section offsets (after data, before relocs)
        const debug_line_offset = if (has_debug) alignTo(data_offset + data_size, 4) else 0;
        const debug_line_size: u64 = self.debug_line_data.items.len;

        const debug_abbrev_offset = if (has_debug) alignTo(debug_line_offset + debug_line_size, 4) else 0;
        const debug_abbrev_size: u64 = self.debug_abbrev_data.items.len;

        const debug_info_offset = if (has_debug) alignTo(debug_abbrev_offset + debug_abbrev_size, 4) else 0;
        const debug_info_size: u64 = self.debug_info_data.items.len;

        // Relocations come after debug sections (or data if no debug)
        // Text relocations first
        const reloc_offset = if (has_debug)
            alignTo(debug_info_offset + debug_info_size, 4)
        else
            alignTo(data_offset + data_size, 4);
        const num_branch_relocs: u32 = @intCast(self.relocations.items.len);
        const num_data_relocs: u32 = @intCast(self.data_relocations.items.len);
        const num_text_relocs: u32 = num_branch_relocs + num_data_relocs;
        const text_reloc_size: u64 = @as(u64, num_text_relocs) * @sizeOf(RelocationInfo);

        // Debug line relocations
        const num_debug_line_relocs: u32 = @intCast(self.debug_line_relocs.items.len);
        const debug_line_reloc_offset = reloc_offset + text_reloc_size;
        const debug_line_reloc_size: u64 = @as(u64, num_debug_line_relocs) * @sizeOf(RelocationInfo);

        // Debug info relocations
        const num_debug_info_relocs: u32 = @intCast(self.debug_info_relocs.items.len);
        const debug_info_reloc_offset = debug_line_reloc_offset + debug_line_reloc_size;
        const debug_info_reloc_size: u64 = @as(u64, num_debug_info_relocs) * @sizeOf(RelocationInfo);

        const total_reloc_size = text_reloc_size + debug_line_reloc_size + debug_info_reloc_size;

        const symtab_offset = alignTo(reloc_offset + total_reloc_size, 8);
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
        const segment_filesize = if (has_debug)
            debug_info_offset + debug_info_size - text_offset
        else
            data_offset + data_size - text_offset;
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
            .reloff = if (num_text_relocs > 0) @intCast(reloc_offset) else 0,
            .nreloc = num_text_relocs,
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

        // Step 7b: Write DWARF debug sections (if present)
        if (has_debug) {
            // __debug_line section
            var debug_line_sect = Section64{
                .size = debug_line_size,
                .offset = @intCast(debug_line_offset),
                .@"align" = 0,
                .reloff = if (num_debug_line_relocs > 0) @intCast(debug_line_reloc_offset) else 0,
                .nreloc = num_debug_line_relocs,
            };
            @memcpy(debug_line_sect.sectname[0..12], "__debug_line");
            @memcpy(debug_line_sect.segname[0..7], "__DWARF");
            try writer.writeAll(std.mem.asBytes(&debug_line_sect));

            // __debug_abbrev section
            var debug_abbrev_sect = Section64{
                .size = debug_abbrev_size,
                .offset = @intCast(debug_abbrev_offset),
                .@"align" = 0,
            };
            @memcpy(debug_abbrev_sect.sectname[0..14], "__debug_abbrev");
            @memcpy(debug_abbrev_sect.segname[0..7], "__DWARF");
            try writer.writeAll(std.mem.asBytes(&debug_abbrev_sect));

            // __debug_info section
            var debug_info_sect = Section64{
                .size = debug_info_size,
                .offset = @intCast(debug_info_offset),
                .@"align" = 0,
                .reloff = if (num_debug_info_relocs > 0) @intCast(debug_info_reloc_offset) else 0,
                .nreloc = num_debug_info_relocs,
            };
            @memcpy(debug_info_sect.sectname[0..12], "__debug_info");
            @memcpy(debug_info_sect.segname[0..7], "__DWARF");
            try writer.writeAll(std.mem.asBytes(&debug_info_sect));
        }

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

        // Step 10b: Write debug sections content (if present)
        if (has_debug) {
            // Pad to debug_line
            const data_end_pos = data_offset + data_size;
            if (debug_line_offset > data_end_pos) {
                const pad = debug_line_offset - data_end_pos;
                var padding: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
                try writer.writeAll(padding[0..@intCast(pad)]);
            }
            try writer.writeAll(self.debug_line_data.items);

            // Pad to debug_abbrev
            if (debug_abbrev_offset > debug_line_offset + debug_line_size) {
                const pad = debug_abbrev_offset - (debug_line_offset + debug_line_size);
                var padding: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
                try writer.writeAll(padding[0..@intCast(pad)]);
            }
            try writer.writeAll(self.debug_abbrev_data.items);

            // Pad to debug_info
            if (debug_info_offset > debug_abbrev_offset + debug_abbrev_size) {
                const pad = debug_info_offset - (debug_abbrev_offset + debug_abbrev_size);
                var padding: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
                try writer.writeAll(padding[0..@intCast(pad)]);
            }
            try writer.writeAll(self.debug_info_data.items);
        }

        // Pad to relocation table offset
        const last_section_end = if (has_debug)
            debug_info_offset + debug_info_size
        else
            data_offset + data_size;
        const reloc_pad = reloc_offset - last_section_end;
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

        // Write debug_line relocations
        for (self.debug_line_relocs.items) |reloc| {
            const reloc_entry = RelocationInfo{
                .r_address = reloc.offset,
                .r_info = RelocationInfo.makeInfo(
                    @intCast(reloc.symbol_idx),
                    false, // not PC-relative
                    3, // length = 8 bytes (log2)
                    true, // external
                    ARM64_RELOC_UNSIGNED, // absolute address
                ),
            };
            try writer.writeAll(std.mem.asBytes(&reloc_entry));
        }

        // Write debug_info relocations
        for (self.debug_info_relocs.items) |reloc| {
            const reloc_entry = RelocationInfo{
                .r_address = reloc.offset,
                .r_info = RelocationInfo.makeInfo(
                    @intCast(reloc.symbol_idx),
                    false, // not PC-relative
                    3, // length = 8 bytes (log2)
                    true, // external
                    ARM64_RELOC_UNSIGNED, // absolute address
                ),
            };
            try writer.writeAll(std.mem.asBytes(&reloc_entry));
        }

        // Pad to symtab offset
        const reloc_end = reloc_offset + total_reloc_size;
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

    // =========================================
    // DWARF Debug Info Generation
    // (Adapted from Go's cmd/internal/obj/dwarf.go)
    // =========================================

    // DWARF line number program constants (from Go)
    const DWARF_VERSION: u16 = 4;
    const LINE_BASE: i8 = -4; // Go uses -4
    const LINE_RANGE: u8 = 10; // Go uses 10
    const OPCODE_BASE: u8 = 11; // Go uses 11
    const MIN_INST_LENGTH: u8 = 4; // ARM64 instructions are 4 bytes

    // DWARF opcodes
    const DW_LNS_copy: u8 = 1;
    const DW_LNS_advance_pc: u8 = 2;
    const DW_LNS_advance_line: u8 = 3;
    const DW_LNS_set_file: u8 = 4;
    const DW_LNS_set_column: u8 = 5;
    const DW_LNE_end_sequence: u8 = 1;
    const DW_LNE_set_address: u8 = 2;

    // DWARF tags and attributes
    const DW_TAG_compile_unit: u8 = 0x11;
    const DW_AT_name: u8 = 0x03;
    const DW_AT_stmt_list: u8 = 0x10;
    const DW_AT_low_pc: u8 = 0x11;
    const DW_AT_high_pc: u8 = 0x12;
    const DW_AT_comp_dir: u8 = 0x1b;
    const DW_FORM_string: u8 = 0x08;
    const DW_FORM_addr: u8 = 0x01;
    const DW_FORM_data8: u8 = 0x07;
    const DW_FORM_sec_offset: u8 = 0x17;
    const DW_CHILDREN_no: u8 = 0;

    /// Convert byte offset in source to line number.
    fn sourceOffsetToLine(self: *MachOWriter, offset: u32) u32 {
        const text = self.source_text orelse return 1;
        if (offset >= text.len) return 1;

        var line: u32 = 1;
        for (text[0..offset]) |c| {
            if (c == '\n') line += 1;
        }
        return line;
    }

    /// Write unsigned LEB128.
    fn writeULEB128(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u64) !void {
        var val = value;
        while (true) {
            const byte: u8 = @truncate(val & 0x7f);
            val >>= 7;
            if (val == 0) {
                try buf.append(allocator, byte);
                break;
            } else {
                try buf.append(allocator, byte | 0x80);
            }
        }
    }

    /// Write signed LEB128.
    fn writeSLEB128(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: i64) !void {
        var val = value;
        while (true) {
            const byte: u8 = @truncate(@as(u64, @bitCast(val)) & 0x7f);
            val >>= 7;
            const sign_bit = (byte & 0x40) != 0;
            if ((val == 0 and !sign_bit) or (val == -1 and sign_bit)) {
                try buf.append(allocator, byte);
                break;
            } else {
                try buf.append(allocator, byte | 0x80);
            }
        }
    }

    /// Generate __debug_abbrev section.
    fn generateDebugAbbrev(self: *MachOWriter) !void {
        const buf = &self.debug_abbrev_data;
        const alloc = self.allocator;

        // Abbreviation 1: compile_unit
        try buf.append(alloc, 1); // abbrev code
        try buf.append(alloc, DW_TAG_compile_unit);
        try buf.append(alloc, DW_CHILDREN_no);

        // Attributes: name, comp_dir, stmt_list, low_pc, high_pc
        try buf.append(alloc, DW_AT_name);
        try buf.append(alloc, DW_FORM_string);
        try buf.append(alloc, DW_AT_comp_dir);
        try buf.append(alloc, DW_FORM_string);
        try buf.append(alloc, DW_AT_stmt_list);
        try buf.append(alloc, DW_FORM_sec_offset);
        try buf.append(alloc, DW_AT_low_pc);
        try buf.append(alloc, DW_FORM_addr);
        try buf.append(alloc, DW_AT_high_pc);
        try buf.append(alloc, DW_FORM_data8);

        // End attributes
        try buf.append(alloc, 0);
        try buf.append(alloc, 0);

        // End abbreviation table
        try buf.append(alloc, 0);
    }

    /// Generate __debug_info section.
    fn generateDebugInfo(self: *MachOWriter) !void {
        const buf = &self.debug_info_data;
        const alloc = self.allocator;

        const filename = self.source_file orelse "unknown.cot";
        const code_size = self.text_data.items.len;

        // Placeholder for unit_length (will patch)
        const length_pos = buf.items.len;
        try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 });

        // Version
        try buf.appendSlice(alloc, &std.mem.toBytes(@as(u16, DWARF_VERSION)));

        // Abbrev offset (always 0)
        try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 });

        // Address size
        try buf.append(alloc, 8);

        // DIE: compile_unit (abbrev 1)
        try buf.append(alloc, 1);

        // DW_AT_name
        try buf.appendSlice(alloc, filename);
        try buf.append(alloc, 0);

        // DW_AT_comp_dir
        try buf.appendSlice(alloc, "/tmp");
        try buf.append(alloc, 0);

        // DW_AT_stmt_list (offset to debug_line, always 0)
        try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 });

        // DW_AT_low_pc - record relocation for linker to fix up
        const low_pc_offset: u32 = @intCast(buf.items.len);
        try self.debug_info_relocs.append(alloc, .{
            .offset = low_pc_offset,
            .symbol_idx = 0, // First symbol (typically _main)
        });
        try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });

        // DW_AT_high_pc (code size)
        try buf.appendSlice(alloc, &std.mem.toBytes(@as(u64, code_size)));

        // Patch unit_length
        const unit_length: u32 = @intCast(buf.items.len - length_pos - 4);
        @memcpy(buf.items[length_pos..][0..4], &std.mem.toBytes(unit_length));
    }

    /// Generate __debug_line section (following Go's approach).
    fn generateDebugLine(self: *MachOWriter) !void {
        const buf = &self.debug_line_data;
        const alloc = self.allocator;

        const filename = self.source_file orelse "unknown.cot";
        const code_size = self.text_data.items.len;

        // Placeholder for unit_length
        const length_pos = buf.items.len;
        try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 });

        // Version
        try buf.appendSlice(alloc, &std.mem.toBytes(@as(u16, DWARF_VERSION)));

        // Header length placeholder
        const header_length_pos = buf.items.len;
        try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 });

        const header_start = buf.items.len;

        // minimum_instruction_length
        try buf.append(alloc, MIN_INST_LENGTH);

        // maximum_operations_per_instruction (DWARF v4)
        try buf.append(alloc, 1);

        // default_is_stmt
        try buf.append(alloc, 1);

        // line_base (signed)
        try buf.append(alloc, @bitCast(LINE_BASE));

        // line_range
        try buf.append(alloc, LINE_RANGE);

        // opcode_base
        try buf.append(alloc, OPCODE_BASE);

        // standard_opcode_lengths (opcodes 1 through opcode_base-1)
        try buf.appendSlice(alloc, &[_]u8{ 0, 1, 1, 1, 1, 0, 0, 0, 1, 0 });

        // Include directories (empty list)
        try buf.append(alloc, 0);

        // File names
        try buf.appendSlice(alloc, filename);
        try buf.append(alloc, 0); // null terminator
        try buf.append(alloc, 0); // directory index
        try buf.append(alloc, 0); // mtime
        try buf.append(alloc, 0); // length
        try buf.append(alloc, 0); // end of file list

        // Patch header_length
        const header_length: u32 = @intCast(buf.items.len - header_start);
        @memcpy(buf.items[header_length_pos..][0..4], &std.mem.toBytes(header_length));

        // Line number program
        if (self.line_entries.items.len > 0) {
            // DW_LNE_set_address
            try buf.append(alloc, 0); // extended opcode marker
            try writeULEB128(buf, alloc, 9); // length: 1 + 8
            try buf.append(alloc, DW_LNE_set_address);

            // Record relocation for the address (will be fixed up to point to _main)
            // The address offset is current position in debug_line section
            const addr_offset: u32 = @intCast(buf.items.len);
            try self.debug_line_relocs.append(alloc, .{
                .offset = addr_offset,
                .symbol_idx = 0, // First symbol (typically _main)
            });

            // Address 0 (will be relocated by linker)
            try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });

            var prev_line: u32 = 1;
            var prev_addr: u32 = 0;

            for (self.line_entries.items) |entry| {
                const cur_line = self.sourceOffsetToLine(entry.source_offset);
                const cur_addr = entry.code_offset;

                const line_delta: i64 = @as(i64, cur_line) - @as(i64, prev_line);
                const addr_delta: u32 = cur_addr - prev_addr;

                // Try special opcode (like Go's putpclcdelta)
                if (line_delta >= LINE_BASE and line_delta < LINE_BASE + LINE_RANGE) {
                    const addr_advance = addr_delta / MIN_INST_LENGTH;
                    const opcode: i64 = (line_delta - LINE_BASE) + (@as(i64, LINE_RANGE) * addr_advance) + OPCODE_BASE;
                    if (opcode >= OPCODE_BASE and opcode < 256) {
                        try buf.append(alloc, @intCast(opcode));
                        prev_line = cur_line;
                        prev_addr = cur_addr;
                        continue;
                    }
                }

                // Fall back to standard opcodes
                if (addr_delta > 0) {
                    try buf.append(alloc, DW_LNS_advance_pc);
                    try writeULEB128(buf, alloc, addr_delta / MIN_INST_LENGTH);
                }
                if (line_delta != 0) {
                    try buf.append(alloc, DW_LNS_advance_line);
                    try writeSLEB128(buf, alloc, line_delta);
                }
                try buf.append(alloc, DW_LNS_copy);

                prev_line = cur_line;
                prev_addr = cur_addr;
            }

            // Advance to end of code
            if (code_size > prev_addr) {
                const final_delta: u32 = @intCast(code_size - prev_addr);
                try buf.append(alloc, DW_LNS_advance_pc);
                try writeULEB128(buf, alloc, final_delta / MIN_INST_LENGTH);
            }
        }

        // DW_LNE_end_sequence
        try buf.append(alloc, 0);
        try writeULEB128(buf, alloc, 1);
        try buf.append(alloc, DW_LNE_end_sequence);

        // Patch unit_length
        const unit_length: u32 = @intCast(buf.items.len - length_pos - 4);
        @memcpy(buf.items[length_pos..][0..4], &std.mem.toBytes(unit_length));
    }

    /// Generate all debug sections using Go-style DwarfBuilder. Call before write().
    pub fn generateDebugSections(self: *MachOWriter) !void {
        if (self.line_entries.items.len == 0) return;

        // Create DWARF builder with Go-style implementation
        var builder = dwarf.DwarfBuilder.init(self.allocator);
        defer builder.deinit();

        // Set source file info
        const source_file = self.source_file orelse "unknown.cot";
        const source_text = self.source_text orelse "";
        builder.setSourceInfo(source_file, source_text);
        builder.setTextSize(self.text_data.items.len);

        // Find the symbol at the lowest address in __text section (typically first function)
        // This is the base address for the DWARF line table
        var text_symbol_idx: u32 = 0;
        var lowest_addr: u64 = std.math.maxInt(u64);
        for (self.symbols.items, 0..) |sym, i| {
            if (sym.section == 1 and sym.value < lowest_addr) { // section 1 = __text
                lowest_addr = sym.value;
                text_symbol_idx = @intCast(i);
            }
        }

        // Convert our line entries to DwarfBuilder's format
        var dwarf_entries = std.ArrayListUnmanaged(dwarf.LineEntry){};
        defer dwarf_entries.deinit(self.allocator);

        for (self.line_entries.items) |entry| {
            try dwarf_entries.append(self.allocator, .{
                .code_offset = entry.code_offset,
                .source_offset = entry.source_offset,
            });
        }

        // Generate DWARF sections
        try builder.generate(dwarf_entries.items, text_symbol_idx);

        // Copy results to our buffers
        try self.debug_abbrev_data.appendSlice(self.allocator, builder.debug_abbrev.items);
        try self.debug_info_data.appendSlice(self.allocator, builder.debug_info.items);
        try self.debug_line_data.appendSlice(self.allocator, builder.debug_line.items);

        // Copy relocations
        for (builder.debug_line_relocs.items) |reloc| {
            try self.debug_line_relocs.append(self.allocator, .{
                .offset = reloc.offset,
                .symbol_idx = reloc.symbol_idx,
            });
        }
        for (builder.debug_info_relocs.items) |reloc| {
            try self.debug_info_relocs.append(self.allocator, .{
                .offset = reloc.offset,
                .symbol_idx = reloc.symbol_idx,
            });
        }
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

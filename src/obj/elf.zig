//! ELF64 Object File Writer
//!
//! Generates ELF64 relocatable object files for Linux AMD64.
//! Reference: System V ABI AMD64 Architecture Processor Supplement
//!            ELF-64 Object File Format
//!
//! ## ELF64 Structure (Relocatable Object)
//!
//! ```
//! +------------------+
//! | ELF Header       |  64 bytes
//! +------------------+
//! | .text section    |  Code
//! +------------------+
//! | .data section    |  Initialized data
//! +------------------+
//! | .symtab section  |  Symbol table
//! +------------------+
//! | .strtab section  |  String table (symbol names)
//! +------------------+
//! | .shstrtab        |  Section header string table
//! +------------------+
//! | .rela.text       |  Relocations for .text
//! +------------------+
//! | Section Headers  |  Array of section headers
//! +------------------+
//! ```
//!
//! Note: For relocatable objects (ET_REL), there are no program headers.
//! Section headers describe each section.

const std = @import("std");

// =========================================
// ELF Constants
// =========================================

/// ELF magic number
pub const ELF_MAGIC = [4]u8{ 0x7F, 'E', 'L', 'F' };

/// ELF class (32-bit or 64-bit)
pub const ELFCLASS64: u8 = 2;

/// Data encoding (little-endian or big-endian)
pub const ELFDATA2LSB: u8 = 1; // Little-endian

/// ELF version
pub const EV_CURRENT: u8 = 1;

/// OS/ABI identification
pub const ELFOSABI_SYSV: u8 = 0; // System V ABI

/// Object file types
pub const ET_REL: u16 = 1; // Relocatable file
pub const ET_EXEC: u16 = 2; // Executable file
pub const ET_DYN: u16 = 3; // Shared object file

/// Machine types
pub const EM_X86_64: u16 = 62; // AMD64

/// Section types
pub const SHT_NULL: u32 = 0; // Inactive
pub const SHT_PROGBITS: u32 = 1; // Program data
pub const SHT_SYMTAB: u32 = 2; // Symbol table
pub const SHT_STRTAB: u32 = 3; // String table
pub const SHT_RELA: u32 = 4; // Relocation with addend
pub const SHT_NOBITS: u32 = 8; // BSS

/// Section flags
pub const SHF_WRITE: u64 = 1; // Writable
pub const SHF_ALLOC: u64 = 2; // Occupies memory during execution
pub const SHF_EXECINSTR: u64 = 4; // Executable
pub const SHF_INFO_LINK: u64 = 0x40; // sh_info contains SHT index

/// Symbol binding
pub const STB_LOCAL: u8 = 0;
pub const STB_GLOBAL: u8 = 1;
pub const STB_WEAK: u8 = 2;

/// Symbol types
pub const STT_NOTYPE: u8 = 0;
pub const STT_OBJECT: u8 = 1;
pub const STT_FUNC: u8 = 2;
pub const STT_SECTION: u8 = 3;
pub const STT_FILE: u8 = 4;

/// Special section indices
pub const SHN_UNDEF: u16 = 0;
pub const SHN_ABS: u16 = 0xFFF1;
pub const SHN_COMMON: u16 = 0xFFF2;

/// AMD64 relocation types
pub const R_X86_64_NONE: u32 = 0;
pub const R_X86_64_64: u32 = 1; // Direct 64-bit
pub const R_X86_64_PC32: u32 = 2; // PC-relative 32-bit
pub const R_X86_64_GOT32: u32 = 3; // 32-bit GOT entry
pub const R_X86_64_PLT32: u32 = 4; // 32-bit PLT address
pub const R_X86_64_32: u32 = 10; // Direct 32-bit zero-extended
pub const R_X86_64_32S: u32 = 11; // Direct 32-bit sign-extended

// =========================================
// ELF Structures
// =========================================

/// ELF64 header (64 bytes)
pub const Elf64_Ehdr = extern struct {
    e_ident: [16]u8 = .{
        0x7F, 'E', 'L', 'F', // Magic
        ELFCLASS64, // 64-bit
        ELFDATA2LSB, // Little-endian
        EV_CURRENT, // Version
        ELFOSABI_SYSV, // OS/ABI
        0, 0, 0, 0, 0, 0, 0, 0, // Padding
    },
    e_type: u16 = ET_REL,
    e_machine: u16 = EM_X86_64,
    e_version: u32 = EV_CURRENT,
    e_entry: u64 = 0, // Entry point (0 for relocatable)
    e_phoff: u64 = 0, // Program header offset (0 for relocatable)
    e_shoff: u64 = 0, // Section header offset (filled in later)
    e_flags: u32 = 0,
    e_ehsize: u16 = @sizeOf(Elf64_Ehdr),
    e_phentsize: u16 = 0, // Program header entry size (0 for relocatable)
    e_phnum: u16 = 0, // Number of program headers
    e_shentsize: u16 = @sizeOf(Elf64_Shdr),
    e_shnum: u16 = 0, // Number of section headers (filled in later)
    e_shstrndx: u16 = 0, // Section name string table index (filled in later)
};

/// ELF64 section header (64 bytes)
pub const Elf64_Shdr = extern struct {
    sh_name: u32 = 0, // Name (index into shstrtab)
    sh_type: u32 = SHT_NULL,
    sh_flags: u64 = 0,
    sh_addr: u64 = 0, // Virtual address (0 for relocatable)
    sh_offset: u64 = 0, // File offset
    sh_size: u64 = 0, // Section size
    sh_link: u32 = 0, // Link to another section
    sh_info: u32 = 0, // Additional info
    sh_addralign: u64 = 0, // Alignment
    sh_entsize: u64 = 0, // Entry size (for tables)
};

/// ELF64 symbol table entry (24 bytes)
pub const Elf64_Sym = extern struct {
    st_name: u32 = 0, // Name (index into strtab)
    st_info: u8 = 0, // Type and binding
    st_other: u8 = 0, // Visibility
    st_shndx: u16 = SHN_UNDEF, // Section index
    st_value: u64 = 0, // Value
    st_size: u64 = 0, // Size

    /// Create st_info from binding and type
    pub fn makeInfo(binding: u8, sym_type: u8) u8 {
        return (binding << 4) | (sym_type & 0xF);
    }

    /// Get binding from st_info
    pub fn getBinding(info: u8) u8 {
        return info >> 4;
    }

    /// Get type from st_info
    pub fn getType(info: u8) u8 {
        return info & 0xF;
    }
};

/// ELF64 relocation entry with addend (24 bytes)
pub const Elf64_Rela = extern struct {
    r_offset: u64 = 0, // Location to apply relocation
    r_info: u64 = 0, // Symbol index and relocation type
    r_addend: i64 = 0, // Addend

    /// Create r_info from symbol index and type
    pub fn makeInfo(sym: u32, rel_type: u32) u64 {
        return (@as(u64, sym) << 32) | @as(u64, rel_type);
    }

    /// Get symbol index from r_info
    pub fn getSym(info: u64) u32 {
        return @intCast(info >> 32);
    }

    /// Get relocation type from r_info
    pub fn getType(info: u64) u32 {
        return @truncate(info);
    }
};

// =========================================
// Writer Types
// =========================================

/// Symbol definition
pub const Symbol = struct {
    name: []const u8,
    value: u64,
    size: u64 = 0,
    section: u16, // Section index (1 = .text, 2 = .data, 0 = undefined)
    binding: u8 = STB_GLOBAL,
    sym_type: u8 = STT_FUNC,
};

/// Relocation definition
pub const Relocation = struct {
    offset: u32, // Offset in section
    target: []const u8, // Target symbol name
    rel_type: u32 = R_X86_64_PLT32, // Default: PLT32 for calls
    addend: i64 = -4, // Default: -4 for CALL (compensates for instruction size)
};

/// String literal with symbol
pub const StringLiteral = struct {
    data: []const u8,
    symbol: []const u8,
};

// =========================================
// ELF Writer
// =========================================

/// ELF64 object file writer
pub const ElfWriter = struct {
    allocator: std.mem.Allocator,

    /// Code section (.text)
    text_data: std.ArrayListUnmanaged(u8),

    /// Data section (.data)
    data: std.ArrayListUnmanaged(u8),

    /// Symbols
    symbols: std.ArrayListUnmanaged(Symbol),

    /// Relocations for .text section
    relocations: std.ArrayListUnmanaged(Relocation),

    /// String table (.strtab) for symbol names
    strtab: std.ArrayListUnmanaged(u8),

    /// Section header string table (.shstrtab)
    shstrtab: std.ArrayListUnmanaged(u8),

    /// String literals (for deduplication)
    string_literals: std.ArrayListUnmanaged(StringLiteral),
    string_counter: u32 = 0,

    // Section name offsets (in shstrtab)
    shstrtab_text: u32 = 0,
    shstrtab_data: u32 = 0,
    shstrtab_symtab: u32 = 0,
    shstrtab_strtab: u32 = 0,
    shstrtab_shstrtab: u32 = 0,
    shstrtab_rela_text: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) ElfWriter {
        var writer = ElfWriter{
            .allocator = allocator,
            .text_data = .{},
            .data = .{},
            .symbols = .{},
            .relocations = .{},
            .strtab = .{},
            .shstrtab = .{},
            .string_literals = .{},
        };

        // Initialize string tables with null byte
        writer.strtab.append(allocator, 0) catch {};
        writer.shstrtab.append(allocator, 0) catch {};

        // Add section names to shstrtab
        writer.shstrtab_text = writer.addShstrtab(".text") catch 0;
        writer.shstrtab_data = writer.addShstrtab(".data") catch 0;
        writer.shstrtab_symtab = writer.addShstrtab(".symtab") catch 0;
        writer.shstrtab_strtab = writer.addShstrtab(".strtab") catch 0;
        writer.shstrtab_shstrtab = writer.addShstrtab(".shstrtab") catch 0;
        writer.shstrtab_rela_text = writer.addShstrtab(".rela.text") catch 0;

        return writer;
    }

    pub fn deinit(self: *ElfWriter) void {
        self.text_data.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.relocations.deinit(self.allocator);
        self.strtab.deinit(self.allocator);
        self.shstrtab.deinit(self.allocator);
        self.string_literals.deinit(self.allocator);
    }

    /// Add string to strtab, return offset
    fn addStrtab(self: *ElfWriter, s: []const u8) !u32 {
        const offset: u32 = @intCast(self.strtab.items.len);
        try self.strtab.appendSlice(self.allocator, s);
        try self.strtab.append(self.allocator, 0);
        return offset;
    }

    /// Add string to shstrtab, return offset
    fn addShstrtab(self: *ElfWriter, s: []const u8) !u32 {
        const offset: u32 = @intCast(self.shstrtab.items.len);
        try self.shstrtab.appendSlice(self.allocator, s);
        try self.shstrtab.append(self.allocator, 0);
        return offset;
    }

    /// Add code to .text section
    pub fn addCode(self: *ElfWriter, code: []const u8) !void {
        try self.text_data.appendSlice(self.allocator, code);
    }

    /// Add data to .data section
    pub fn addData(self: *ElfWriter, bytes: []const u8) !void {
        try self.data.appendSlice(self.allocator, bytes);
    }

    /// Add a symbol
    pub fn addSymbol(self: *ElfWriter, name: []const u8, value: u64, section: u16, external: bool) !void {
        try self.symbols.append(self.allocator, .{
            .name = name,
            .value = value,
            .section = section,
            .binding = if (external) STB_GLOBAL else STB_LOCAL,
            .sym_type = if (section == 1) STT_FUNC else STT_OBJECT,
        });
    }

    /// Add a relocation for .text section
    pub fn addRelocation(self: *ElfWriter, offset: u32, target: []const u8) !void {
        try self.relocations.append(self.allocator, .{
            .offset = offset,
            .target = target,
            .rel_type = R_X86_64_PLT32,
            .addend = -4, // CALL instruction: target - (rip + 4)
        });
    }

    /// Add a string literal to .data section
    pub fn addStringLiteral(self: *ElfWriter, str: []const u8) ![]const u8 {
        // Check for existing (deduplication)
        for (self.string_literals.items) |existing| {
            if (std.mem.eql(u8, existing.data, str)) {
                return existing.symbol;
            }
        }

        // Generate unique symbol name
        const sym_name = try std.fmt.allocPrint(self.allocator, ".L.str.{d}", .{self.string_counter});
        self.string_counter += 1;

        // Record offset in data section
        const offset: u32 = @intCast(self.data.items.len);

        // Add string data
        try self.data.appendSlice(self.allocator, str);

        // Align to 8 bytes
        while (self.data.items.len % 8 != 0) {
            try self.data.append(self.allocator, 0);
        }

        // Add to tracking list
        try self.string_literals.append(self.allocator, .{
            .data = str,
            .symbol = sym_name,
        });

        // Add local symbol for this string
        try self.symbols.append(self.allocator, .{
            .name = sym_name,
            .value = offset,
            .section = 2, // .data
            .binding = STB_LOCAL,
            .sym_type = STT_OBJECT,
        });

        return sym_name;
    }

    /// Add a global variable to .data section
    pub fn addGlobalVariable(self: *ElfWriter, name: []const u8, size: u32) !void {
        // Align to 8 bytes
        while (self.data.items.len % 8 != 0) {
            try self.data.append(self.allocator, 0);
        }

        const offset: u32 = @intCast(self.data.items.len);

        // Add zero-initialized space
        for (0..size) |_| {
            try self.data.append(self.allocator, 0);
        }

        // Add symbol
        try self.symbols.append(self.allocator, .{
            .name = name,
            .value = offset,
            .size = size,
            .section = 2, // .data
            .binding = STB_GLOBAL,
            .sym_type = STT_OBJECT,
        });
    }

    /// Align to boundary
    fn alignTo(offset: u64, alignment: u64) u64 {
        if (alignment == 0) return offset;
        return (offset + alignment - 1) & ~(alignment - 1);
    }

    /// Write the complete object file
    pub fn write(self: *ElfWriter, writer: anytype) !void {
        // Build symbol name -> index map
        var sym_name_to_idx = std.StringHashMap(u32).init(self.allocator);
        defer sym_name_to_idx.deinit();

        // Add all defined symbols first
        for (self.symbols.items, 0..) |sym, i| {
            try sym_name_to_idx.put(sym.name, @intCast(i + 1)); // +1 for null symbol
        }

        // Add undefined symbols from relocations
        var extern_symbols = std.ArrayListUnmanaged(Symbol){};
        defer extern_symbols.deinit(self.allocator);

        for (self.relocations.items) |reloc| {
            if (!sym_name_to_idx.contains(reloc.target)) {
                const idx: u32 = @intCast(self.symbols.items.len + extern_symbols.items.len + 1);
                try sym_name_to_idx.put(reloc.target, idx);
                try extern_symbols.append(self.allocator, .{
                    .name = reloc.target,
                    .value = 0,
                    .section = SHN_UNDEF,
                    .binding = STB_GLOBAL,
                    .sym_type = STT_NOTYPE,
                });
            }
        }

        // Pre-add symbol names to strtab
        var symbol_strx = std.ArrayListUnmanaged(u32){};
        defer symbol_strx.deinit(self.allocator);

        for (self.symbols.items) |sym| {
            const strx = try self.addStrtab(sym.name);
            try symbol_strx.append(self.allocator, strx);
        }
        for (extern_symbols.items) |sym| {
            const strx = try self.addStrtab(sym.name);
            try symbol_strx.append(self.allocator, strx);
        }

        // Calculate section layout
        // Section order:
        // 0: NULL
        // 1: .text
        // 2: .data
        // 3: .symtab
        // 4: .strtab
        // 5: .shstrtab
        // 6: .rela.text (if relocations exist)

        const has_relocs = self.relocations.items.len > 0;
        const has_data = self.data.items.len > 0;
        const num_sections: u16 = if (has_relocs) 7 else 6;

        const ehdr_size: u64 = @sizeOf(Elf64_Ehdr);

        // Calculate offsets
        var offset: u64 = ehdr_size;

        // .text section
        const text_offset = offset;
        const text_size: u64 = self.text_data.items.len;
        offset += text_size;
        offset = alignTo(offset, 8);

        // .data section
        const data_offset = offset;
        const data_size: u64 = if (has_data) self.data.items.len else 0;
        if (has_data) {
            offset += data_size;
            offset = alignTo(offset, 8);
        }

        // .symtab section
        const symtab_offset = offset;
        const total_syms = 1 + self.symbols.items.len + extern_symbols.items.len; // +1 for null
        const symtab_size = total_syms * @sizeOf(Elf64_Sym);
        offset += symtab_size;
        offset = alignTo(offset, 8);

        // .strtab section
        const strtab_offset = offset;
        const strtab_size: u64 = self.strtab.items.len;
        offset += strtab_size;
        offset = alignTo(offset, 8);

        // .shstrtab section
        const shstrtab_offset = offset;
        const shstrtab_size: u64 = self.shstrtab.items.len;
        offset += shstrtab_size;
        offset = alignTo(offset, 8);

        // .rela.text section
        var rela_text_offset: u64 = 0;
        var rela_text_size: u64 = 0;
        if (has_relocs) {
            rela_text_offset = offset;
            rela_text_size = self.relocations.items.len * @sizeOf(Elf64_Rela);
            offset += rela_text_size;
            offset = alignTo(offset, 8);
        }

        // Section headers
        const shdr_offset = offset;

        // Write ELF header
        var ehdr = Elf64_Ehdr{};
        ehdr.e_shoff = shdr_offset;
        ehdr.e_shnum = num_sections;
        ehdr.e_shstrndx = 5; // .shstrtab is section 5
        try writer.writeAll(std.mem.asBytes(&ehdr));

        // Write .text section
        try writer.writeAll(self.text_data.items);
        try writePadding(writer, alignTo(ehdr_size + text_size, 8) - (ehdr_size + text_size));

        // Write .data section
        if (has_data) {
            try writer.writeAll(self.data.items);
            try writePadding(writer, alignTo(data_offset + data_size, 8) - (data_offset + data_size));
        }

        // Write .symtab section
        // First: null symbol
        var null_sym = Elf64_Sym{};
        try writer.writeAll(std.mem.asBytes(&null_sym));

        // Local symbols (including section symbols)
        // Count local symbols for sh_info
        var num_local: u32 = 1; // null symbol

        // Write defined symbols
        for (self.symbols.items, 0..) |sym, i| {
            var elf_sym = Elf64_Sym{
                .st_name = symbol_strx.items[i],
                .st_info = Elf64_Sym.makeInfo(sym.binding, sym.sym_type),
                .st_shndx = sym.section,
                .st_value = sym.value,
                .st_size = sym.size,
            };
            try writer.writeAll(std.mem.asBytes(&elf_sym));
            if (sym.binding == STB_LOCAL) num_local += 1;
        }

        // Write external (undefined) symbols
        for (extern_symbols.items, 0..) |sym, i| {
            const strx_idx = self.symbols.items.len + i;
            var elf_sym = Elf64_Sym{
                .st_name = symbol_strx.items[strx_idx],
                .st_info = Elf64_Sym.makeInfo(sym.binding, sym.sym_type),
                .st_shndx = SHN_UNDEF,
                .st_value = 0,
                .st_size = 0,
            };
            try writer.writeAll(std.mem.asBytes(&elf_sym));
        }
        try writePadding(writer, alignTo(symtab_offset + symtab_size, 8) - (symtab_offset + symtab_size));

        // Write .strtab section
        try writer.writeAll(self.strtab.items);
        try writePadding(writer, alignTo(strtab_offset + strtab_size, 8) - (strtab_offset + strtab_size));

        // Write .shstrtab section
        try writer.writeAll(self.shstrtab.items);
        try writePadding(writer, alignTo(shstrtab_offset + shstrtab_size, 8) - (shstrtab_offset + shstrtab_size));

        // Write .rela.text section
        if (has_relocs) {
            for (self.relocations.items) |reloc| {
                const sym_idx = sym_name_to_idx.get(reloc.target) orelse 0;
                var rela = Elf64_Rela{
                    .r_offset = reloc.offset,
                    .r_info = Elf64_Rela.makeInfo(sym_idx, reloc.rel_type),
                    .r_addend = reloc.addend,
                };
                try writer.writeAll(std.mem.asBytes(&rela));
            }
            try writePadding(writer, alignTo(rela_text_offset + rela_text_size, 8) - (rela_text_offset + rela_text_size));
        }

        // Write section headers
        // Section 0: NULL
        var shdr_null = Elf64_Shdr{};
        try writer.writeAll(std.mem.asBytes(&shdr_null));

        // Section 1: .text
        var shdr_text = Elf64_Shdr{
            .sh_name = self.shstrtab_text,
            .sh_type = SHT_PROGBITS,
            .sh_flags = SHF_ALLOC | SHF_EXECINSTR,
            .sh_offset = text_offset,
            .sh_size = text_size,
            .sh_addralign = 16,
        };
        try writer.writeAll(std.mem.asBytes(&shdr_text));

        // Section 2: .data
        var shdr_data = Elf64_Shdr{
            .sh_name = self.shstrtab_data,
            .sh_type = SHT_PROGBITS,
            .sh_flags = SHF_ALLOC | SHF_WRITE,
            .sh_offset = data_offset,
            .sh_size = data_size,
            .sh_addralign = 8,
        };
        try writer.writeAll(std.mem.asBytes(&shdr_data));

        // Section 3: .symtab
        var shdr_symtab = Elf64_Shdr{
            .sh_name = self.shstrtab_symtab,
            .sh_type = SHT_SYMTAB,
            .sh_offset = symtab_offset,
            .sh_size = symtab_size,
            .sh_link = 4, // Link to .strtab
            .sh_info = num_local, // First non-local symbol index
            .sh_addralign = 8,
            .sh_entsize = @sizeOf(Elf64_Sym),
        };
        try writer.writeAll(std.mem.asBytes(&shdr_symtab));

        // Section 4: .strtab
        var shdr_strtab = Elf64_Shdr{
            .sh_name = self.shstrtab_strtab,
            .sh_type = SHT_STRTAB,
            .sh_offset = strtab_offset,
            .sh_size = strtab_size,
            .sh_addralign = 1,
        };
        try writer.writeAll(std.mem.asBytes(&shdr_strtab));

        // Section 5: .shstrtab
        var shdr_shstrtab = Elf64_Shdr{
            .sh_name = self.shstrtab_shstrtab,
            .sh_type = SHT_STRTAB,
            .sh_offset = shstrtab_offset,
            .sh_size = shstrtab_size,
            .sh_addralign = 1,
        };
        try writer.writeAll(std.mem.asBytes(&shdr_shstrtab));

        // Section 6: .rela.text (if relocations exist)
        if (has_relocs) {
            var shdr_rela_text = Elf64_Shdr{
                .sh_name = self.shstrtab_rela_text,
                .sh_type = SHT_RELA,
                .sh_flags = SHF_INFO_LINK,
                .sh_offset = rela_text_offset,
                .sh_size = rela_text_size,
                .sh_link = 3, // Link to .symtab
                .sh_info = 1, // Applies to .text (section 1)
                .sh_addralign = 8,
                .sh_entsize = @sizeOf(Elf64_Rela),
            };
            try writer.writeAll(std.mem.asBytes(&shdr_rela_text));
        }
    }

    fn writePadding(writer: anytype, count: u64) !void {
        const zeros = [_]u8{0} ** 8;
        var remaining = count;
        while (remaining > 0) {
            const to_write = @min(remaining, 8);
            try writer.writeAll(zeros[0..to_write]);
            remaining -= to_write;
        }
    }
};

// =========================================
// Tests
// =========================================

test "ELF header size" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Elf64_Ehdr));
}

test "ELF section header size" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Elf64_Shdr));
}

test "ELF symbol size" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Elf64_Sym));
}

test "ELF relocation size" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Elf64_Rela));
}

test "symbol info encoding" {
    const info = Elf64_Sym.makeInfo(STB_GLOBAL, STT_FUNC);
    try std.testing.expectEqual(STB_GLOBAL, Elf64_Sym.getBinding(info));
    try std.testing.expectEqual(STT_FUNC, Elf64_Sym.getType(info));
}

test "relocation info encoding" {
    const info = Elf64_Rela.makeInfo(42, R_X86_64_PLT32);
    try std.testing.expectEqual(@as(u32, 42), Elf64_Rela.getSym(info));
    try std.testing.expectEqual(R_X86_64_PLT32, Elf64_Rela.getType(info));
}

test "ElfWriter basic" {
    const allocator = std.testing.allocator;
    var writer = ElfWriter.init(allocator);
    defer writer.deinit();

    // Add minimal code: mov rax, 42; ret
    try writer.addCode(&.{ 0x48, 0xC7, 0xC0, 0x2A, 0x00, 0x00, 0x00 }); // mov rax, 42
    try writer.addCode(&.{0xC3}); // ret

    // Add symbol
    try writer.addSymbol("main", 0, 1, true);

    // Write to buffer
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    try writer.write(output.writer(allocator));

    // Verify ELF magic
    try std.testing.expectEqual(@as(u8, 0x7F), output.items[0]);
    try std.testing.expectEqual(@as(u8, 'E'), output.items[1]);
    try std.testing.expectEqual(@as(u8, 'L'), output.items[2]);
    try std.testing.expectEqual(@as(u8, 'F'), output.items[3]);
}

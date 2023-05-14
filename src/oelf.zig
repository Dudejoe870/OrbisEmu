// PS4 OELF Parser
//
// OrbisEmu is an experimental PS4 GPU Emulator and Orbis compatibility layer for the Windows and Linux operating systems under the x86_64 CPU architecture.
// Copyright (C) 2023  John Clemis
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const root = @import("root");
const align_util = root.align_util;

const elf = std.elf;

pub const Header = extern struct {
    ident: [elf.EI_NIDENT]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};

pub const ModuleReference = struct {
    name: []const u8,
    value: packed union {
        int: u64,
        bits: packed struct {
            name_offset: u32,
            version_minor: u8,
            version_major: u8,
            id: u16,
        },
    },
};

pub const LibraryReference = struct {
    name: []const u8,
    value: packed union {
        int: u64,
        bits: packed struct {
            name_offset: u32,
            version: u16,
            id: u16,
        },
    },
};

pub const Data = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,

    header: *const Header = undefined,
    program_headers: []const elf.Elf64_Phdr = undefined,

    dynamic_entries: []const elf.Elf64_Dyn = undefined,

    symbol_table: []const elf.Elf64_Sym = undefined,
    string_table: []const u8 = undefined,

    rela_entries: []const elf.Elf64_Rela = undefined,
    plt_rela_entries: []const elf.Elf64_Rela = undefined,

    needed_files: ?[]const []const u8 = null,

    export_modules: ?[]const ModuleReference = null,
    import_modules: ?[]const ModuleReference = null,

    export_libraries: ?[]const LibraryReference = null,
    import_libraries: ?[]const LibraryReference = null,

    mapped_size: usize = 0,

    pub fn deinit(self: *Data) void {
        if (self.needed_files) |files| self.allocator.free(files);

        if (self.export_modules) |modules| self.allocator.free(modules);
        if (self.import_modules) |modules| self.allocator.free(modules);

        if (self.export_libraries) |libraries| self.allocator.free(libraries);
        if (self.import_libraries) |libraries| self.allocator.free(libraries);

        self.allocator.free(self.bytes);
    }

    pub fn getStringFromTable(self: *const Data, offset: u64) []const u8 {
        std.debug.assert(offset != self.string_table.len - 1);
        return std.mem.span(@ptrCast([*:0]const u8, self.string_table[offset..].ptr));
    }
};

pub const ParseError = error{
    MoreThanOneDynamicSection,
    CouldntFindDynamicSection,

    MoreThanOneRelaSzTag,
    CouldntFindRelaSzTag,

    MoreThanOneDynlibData,
    CouldntFindDynlibData,

    MoreThanOneSymTabTag,
    CouldntFindSymTabTag,

    MoreThanOneSymTabSzTag,
    CouldntFindSymTabSzTag,

    MoreThanOneStrTabTag,
    CouldntFindStrTabTag,

    MoreThanOneStrSzTag,
    CouldntFindStrSzTag,

    MoreThanOneRelaTag,
    CouldntFindRelaTag,

    MoreThanOneJmpRelTag,
    CouldntFindJmpRelTag,

    MoreThanOnePltRelaSzTag,
    CouldntFindPltRelaSzTag,
};

pub const ELF_MAGIC = [4]u8{ 0x7F, 'E', 'L', 'F' };

inline fn isSegmentLoadable(segment: elf.Elf64_Phdr) bool {
    return segment.p_type == elf.PT_LOAD or segment.p_type == PT_SCE_RELRO;
}

inline fn sliceCast(comptime T: type, buffer: []const u8, offset: usize, count: usize) []T {
    std.debug.assert(offset + count * @sizeOf(T) <= buffer.len);

    const ptr = @ptrToInt(buffer.ptr) + offset;
    return @intToPtr([*]T, ptr)[0..count];
}

/// Parses a data buffer into a Data struct that contains all of the information from the OELF file.
///
/// The data buffer transfers ownership to the Data struct and thus is deinitialized there, NOT by the caller.
///
/// Allocator must be the same allocator used to allocate the slice.
pub fn parse(oelf: []const u8, allocator: std.mem.Allocator) !Data {
    var data = Data{
        .allocator = allocator,
        .bytes = oelf,
    };
    errdefer allocator.free(data.bytes);

    data.header = std.mem.bytesAsValue(Header, @alignCast(@alignOf(Header), oelf[0..@sizeOf(Header)]));
    _ = try elf.Header.parse(std.mem.asBytes(data.header));

    data.program_headers = sliceCast(elf.Elf64_Phdr, oelf, data.header.phoff, data.header.phnum);

    // Get all Dynamic Tables, compute the in-memory mapped and loaded size,
    // and count the number of various other tags to know how much to allocate.
    {
        data.mapped_size = 0;
        var load_addr_begin: usize = 0;
        var load_addr_end: usize = 0;

        var dynlib_data_offset: ?u64 = null;

        var symbol_table_offset: ?u64 = null;
        var symbol_table_size: ?u64 = null;

        var string_table_offset: ?u64 = null;
        var string_table_size: ?u64 = null;

        var rela_table_offset: ?u64 = null;
        var rela_table_size: ?u64 = null;
        var plt_rela_table_offset: ?u64 = null;
        var plt_rela_table_size: ?u64 = null;

        var num_needed_files: u64 = 0;

        var num_export_modules: u64 = 0;
        var num_import_modules: u64 = 0;

        var num_export_libraries: u64 = 0;
        var num_import_libraries: u64 = 0;

        var found_dynamic: bool = false;
        for (data.program_headers) |segment| {
            if (isSegmentLoadable(segment)) {
                if (segment.p_vaddr < load_addr_begin) {
                    load_addr_begin = segment.p_vaddr;
                }

                const aligned_addr = align_util.alignDown(segment.p_vaddr + segment.p_memsz, segment.p_align);
                if (aligned_addr > load_addr_end) {
                    load_addr_end = aligned_addr;
                }
            }

            switch (segment.p_type) {
                elf.PT_DYNAMIC => {
                    // In the first pass we prepare all the table offset and sizes.
                    if (found_dynamic) return ParseError.MoreThanOneDynamicSection;
                    found_dynamic = true;

                    data.dynamic_entries = sliceCast(elf.Elf64_Dyn, oelf, segment.p_offset, segment.p_filesz / @sizeOf(elf.Elf64_Dyn));

                    for (data.dynamic_entries) |entry| {
                        switch (entry.d_tag) {
                            // Symbol Table
                            DT_SCE_SYMTAB => {
                                if (symbol_table_offset != null) return ParseError.MoreThanOneSymTabTag;
                                symbol_table_offset = entry.d_val;
                            },
                            DT_SCE_SYMTABSZ => {
                                if (symbol_table_size != null) return ParseError.MoreThanOneSymTabSzTag;
                                symbol_table_size = entry.d_val;
                            },

                            // String Table
                            DT_SCE_STRTAB => {
                                if (string_table_offset != null) return ParseError.MoreThanOneStrTabTag;
                                string_table_offset = entry.d_val;
                            },
                            DT_SCE_STRSZ => {
                                if (string_table_size != null) return ParseError.MoreThanOneStrSzTag;
                                string_table_size = entry.d_val;
                            },

                            // Relocation Table
                            DT_SCE_RELA => {
                                if (rela_table_offset != null) return ParseError.MoreThanOneRelaTag;
                                rela_table_offset = entry.d_val;
                            },
                            DT_SCE_RELASZ => {
                                if (rela_table_size != null) return ParseError.MoreThanOneRelaSzTag;
                                rela_table_size = entry.d_val;
                            },

                            // PLT Relocation Table
                            DT_SCE_JMPREL => {
                                if (plt_rela_table_offset != null) return ParseError.MoreThanOneJmpRelTag;
                                plt_rela_table_offset = entry.d_val;
                            },
                            DT_SCE_PLTRELSZ => {
                                if (plt_rela_table_size != null) return ParseError.MoreThanOnePltRelaSzTag;
                                plt_rela_table_size = entry.d_val;
                            },

                            // Other Tags
                            DT_NEEDED => {
                                num_needed_files += 1;
                            },
                            DT_SCE_MODULE_INFO => {
                                num_export_modules += 1;
                            },
                            DT_SCE_NEEDED_MODULE => {
                                num_import_modules += 1;
                            },
                            DT_SCE_EXPORT_LIB => {
                                num_export_libraries += 1;
                            },
                            DT_SCE_IMPORT_LIB => {
                                num_import_libraries += 1;
                            },
                            else => continue,
                        }
                    }
                },
                PT_SCE_DYNLIBDATA => {
                    if (dynlib_data_offset != null) return ParseError.MoreThanOneDynlibData;
                    dynlib_data_offset = segment.p_offset;
                },
                else => continue,
            }
        }
        if (!found_dynamic) return ParseError.CouldntFindDynamicSection;

        if (dynlib_data_offset == null) return ParseError.CouldntFindDynlibData;

        if (symbol_table_offset == null) return ParseError.CouldntFindSymTabTag;
        if (symbol_table_size == null) return ParseError.CouldntFindSymTabSzTag;

        if (string_table_offset == null) return ParseError.CouldntFindStrTabTag;
        if (string_table_size == null) return ParseError.CouldntFindStrSzTag;

        if (rela_table_offset == null) return ParseError.CouldntFindRelaTag;
        if (plt_rela_table_offset == null) return ParseError.CouldntFindJmpRelTag;
        if (rela_table_size == null) return ParseError.CouldntFindRelaSzTag;
        if (plt_rela_table_size == null) return ParseError.CouldntFindPltRelaSzTag;

        data.mapped_size = load_addr_end - load_addr_begin;

        data.symbol_table = sliceCast(elf.Elf64_Sym, oelf, dynlib_data_offset.? + symbol_table_offset.?, symbol_table_size.? / @sizeOf(elf.Elf64_Sym));
        data.string_table = oelf[dynlib_data_offset.? + string_table_offset.? ..][0..string_table_size.?];

        data.rela_entries = sliceCast(elf.Elf64_Rela, oelf, dynlib_data_offset.? + rela_table_offset.?, rela_table_size.? / @sizeOf(elf.Elf64_Rela));
        data.plt_rela_entries = sliceCast(elf.Elf64_Rela, oelf, dynlib_data_offset.? + plt_rela_table_offset.?, plt_rela_table_size.? / @sizeOf(elf.Elf64_Rela));

        if (num_needed_files > 0) data.needed_files = try allocator.alloc([]const u8, num_needed_files);

        if (num_export_modules > 0) data.export_modules = try allocator.alloc(ModuleReference, num_export_modules);
        if (num_import_modules > 0) data.import_modules = try allocator.alloc(ModuleReference, num_import_modules);

        if (num_export_libraries > 0) data.export_libraries = try allocator.alloc(LibraryReference, num_export_libraries);
        if (num_import_libraries > 0) data.import_libraries = try allocator.alloc(LibraryReference, num_import_libraries);
    }

    // Parse the rest of the Dynamic Entries.
    {
        var needed_index: usize = 0;
        var export_module_index: usize = 0;
        var import_module_index: usize = 0;
        var export_libraries_index: usize = 0;
        var import_libraries_index: usize = 0;
        for (data.dynamic_entries) |entry| {
            switch (entry.d_tag) {
                DT_NEEDED => {
                    @constCast(data.needed_files.?)[needed_index] = data.getStringFromTable(entry.d_val);
                    needed_index += 1;
                },
                DT_SCE_MODULE_INFO => {
                    const reference = &@constCast(data.export_modules.?)[export_module_index];
                    reference.value = .{ .int = entry.d_val };
                    reference.name = data.getStringFromTable(reference.value.bits.name_offset);
                    export_module_index += 1;
                },
                DT_SCE_NEEDED_MODULE => {
                    const reference = &@constCast(data.import_modules.?)[import_module_index];
                    reference.value = .{ .int = entry.d_val };
                    reference.name = data.getStringFromTable(reference.value.bits.name_offset);
                    import_module_index += 1;
                },
                DT_SCE_EXPORT_LIB => {
                    const reference = &@constCast(data.export_libraries.?)[export_libraries_index];
                    reference.value = .{ .int = entry.d_val };
                    reference.name = data.getStringFromTable(reference.value.bits.name_offset);
                    export_libraries_index += 1;
                },
                DT_SCE_IMPORT_LIB => {
                    const reference = &@constCast(data.import_libraries.?)[import_libraries_index];
                    reference.value = .{ .int = entry.d_val };
                    reference.name = data.getStringFromTable(reference.value.bits.name_offset);
                    import_libraries_index += 1;
                },
                else => continue,
            }
        }
    }

    return data;
}

pub const ET_SCE_DYNAMIC = 0xFE18;

pub const PT_SCE_DYNLIBDATA = 0x61000000;
pub const PT_SCE_RELRO = 0x61000010;

pub const DT_SCE_SYMTAB = 0x61000039;
pub const DT_SCE_SYMTABSZ = 0x6100003F;

pub const DT_SCE_STRTAB = 0x61000035;
pub const DT_SCE_STRSZ = 0x61000037;

pub const DT_SCE_RELA = 0x6100002F;
pub const DT_SCE_RELASZ = 0x61000031;

pub const DT_SCE_JMPREL = 0x61000029;
pub const DT_SCE_PLTREL = 0x6100002B;
pub const DT_SCE_PLTRELSZ = 0x6100002D;

pub const DT_NEEDED = 1;
pub const DT_SCE_MODULE_INFO = 0x6100000D;
pub const DT_SCE_NEEDED_MODULE = 0x6100000F;
pub const DT_SCE_EXPORT_LIB	= 0x61000013;
pub const DT_SCE_IMPORT_LIB	= 0x61000015;

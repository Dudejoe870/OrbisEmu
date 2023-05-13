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

pub const Data = struct {
    allocator: std.mem.Allocator,
    elf_data: []const u8,

    header: Header,
    program_headers: []const elf.Elf64_Phdr,

    dynamic_entries: []const elf.Elf64_Dyn,

    rela_entries: ?[]const elf.Elf64_Rela,
    plt_rela_entries: ?[]const elf.Elf64_Rela,

    mapped_size: usize,

    pub fn deinit(self: *Data) void {
        self.allocator.free(self.elf_data);
    }
};

pub const ParseError = error{
    MoreThanOneDynamicSection,
    CouldntFindDynamicSection,
    MoreThanOneRelaSzTag,
    CouldntFindRelaSzTag,
    NothingToLoad,
    MoreThanOneDynlibData,
    CouldntFindDynlibData,
    MoreThanOneRelaTag,
    MoreThanOneJmpRelTag,
    MoreThanOnePltRelaSzTag,
    NoRelocationTable,
};

inline fn isSegmentLoadable(segment: elf.Elf64_Phdr) bool {
    return segment.p_type == elf.PT_LOAD or segment.p_type == PT_SCE_RELRO;
}

inline fn sliceCast(comptime T: type, buffer: []const u8, offset: usize, count: usize) []T {
    std.debug.assert(offset + count * @sizeOf(T) <= buffer.len);

    const ptr = @ptrToInt(buffer.ptr) + offset;
    return @intToPtr([*]T, ptr)[0 .. count];
}

/// Parses a data buffer into a Data struct that contains all of the information from the OELF file.
///
/// The data buffer transfers ownership to the Data struct and thus is deinitialized there, NOT by the caller.
///
/// Allocator must be the same allocator used to allocate the slice.
pub fn parse(oelf: []const u8, allocator: std.mem.Allocator) !Data {
    var data: Data = undefined;
    data.allocator = allocator;
    data.elf_data = oelf;
    errdefer allocator.free(data.elf_data);

    var stream = std.io.fixedBufferStream(oelf);

    data.header = try stream.reader().readStruct(Header);
    _ = try elf.Header.parse(std.mem.asBytes(&data.header));

    data.program_headers = sliceCast(elf.Elf64_Phdr, oelf, data.header.phoff, data.header.phnum);

    data.mapped_size = 0;
    var load_addr_begin: usize = 0;
    var load_addr_end: usize = 0;

    var dynlib_data_offset: ?u64 = null;

    var rela_table_offset: ?u64 = null;
    var rela_table_size: ?u64 = null;
    var plt_rela_table_offset: ?u64 = null;
    var plt_rela_table_size: ?u64 = null;

    var found_dynamic: bool = false;
    for (data.program_headers) |segment| {
        if (isSegmentLoadable(segment)) {
            if (segment.p_vaddr < load_addr_begin) {
                load_addr_begin = segment.p_vaddr;
            }

            const aligned_addr = std.mem.alignBackward(segment.p_vaddr + segment.p_memsz, segment.p_align);
            if (aligned_addr > load_addr_end) {
                load_addr_end = aligned_addr;
            }
        }

        switch (segment.p_type) {
            elf.PT_DYNAMIC => {
                if (found_dynamic) return ParseError.MoreThanOneDynamicSection;
                found_dynamic = true;

                data.dynamic_entries = sliceCast(elf.Elf64_Dyn, oelf, segment.p_offset, segment.p_filesz / @sizeOf(elf.Elf64_Dyn));

                for (data.dynamic_entries) |entry| {
                    switch (entry.d_tag) {
                        DT_SCE_RELA => {
                            if (rela_table_offset != null) return ParseError.MoreThanOneRelaTag;
                            rela_table_offset = entry.d_val;
                        },
                        DT_SCE_RELASZ => {
                            if (rela_table_size != null) return ParseError.MoreThanOneRelaSzTag;
                            rela_table_size = entry.d_val;
                        },
                        DT_SCE_JMPREL => {
                            if (plt_rela_table_offset != null) return ParseError.MoreThanOneJmpRelTag;
                            plt_rela_table_offset = entry.d_val;
                        },
                        DT_SCE_PLTRELSZ => {
                            if (plt_rela_table_size != null) return ParseError.MoreThanOnePltRelaSzTag;
                            plt_rela_table_size = entry.d_val;
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

    data.mapped_size = load_addr_end - load_addr_begin;
    if (data.mapped_size == 0) return ParseError.NothingToLoad;

    if (rela_table_offset == null and plt_rela_table_offset == null) {
        return ParseError.NoRelocationTable;
    }

    data.rela_entries = null;
    if (rela_table_size) |size| {
        data.rela_entries = sliceCast(elf.Elf64_Rela, oelf, dynlib_data_offset.? + rela_table_offset.?, size / @sizeOf(elf.Elf64_Rela));
    }

    data.plt_rela_entries = null;
    if (plt_rela_table_size) |size| {
        data.plt_rela_entries = sliceCast(elf.Elf64_Rela, oelf, dynlib_data_offset.? + plt_rela_table_offset.?, size / @sizeOf(elf.Elf64_Rela));
    }

    return data;
}

pub const PTYPE_FAKE = 0x1;

pub const PT_SCE_DYNLIBDATA = 0x61000000;
pub const PT_SCE_RELRO = 0x61000010;

pub const DT_SCE_RELA = 0x6100002F;
pub const DT_SCE_RELASZ = 0x61000031;

pub const DT_SCE_JMPREL = 0x61000029;
pub const DT_SCE_PLTREL = 0x6100002B;
pub const DT_SCE_PLTRELSZ = 0x6100002D;

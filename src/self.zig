// PS4 SELF Parser (reconstructs the OELF from the SELF file)
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
const stream_util = root.stream_util;

const elf = std.elf;
const oelf = @import("oelf.zig");

pub const CommonHeader = extern struct {
    magic: [4]u8,
    version: u8,
    mode: u8,
    endian: u8,
    attribs: u8,
};

pub const ExtendedHeader = extern struct {
    key_type: u32,
    header_size: u16,
    meta_size: u16,
    file_size: u64,
    num_entries: u16,
    flags: u16,
    _padding: [4]u8,
};

pub const Entry = extern struct {
    props: u64,
    offset: u64,
    filesz: u64,
    memsz: u64,
};

pub const ParseError = error{
    InvalidFakeSelf,
};

pub const SELF_MAGIC = [4]u8{ 79, 21, 61, 29 };

/// Parses the SELF and returns the reconstructed OELF.
pub fn toOElf(stream: anytype, allocator: std.mem.Allocator) ![]align(@alignOf(oelf.Header)) u8 {
    const StreamType = @TypeOf(stream);

    comptime {
        std.debug.assert(@hasDecl(StreamType, "seekableStream"));
        std.debug.assert(@hasDecl(StreamType, "reader"));
    }

    const self_size = try stream.seekableStream().getEndPos();
    try stream.seekableStream().seekTo(0);

    const common_header = try stream.reader().readStruct(CommonHeader);
    if (!std.mem.eql(u8, &common_header.magic, &SELF_MAGIC)) {
        return ParseError.InvalidFakeSelf;
    }
    const extended_header = try stream.reader().readStruct(ExtendedHeader);
    const entries_offset = try stream.seekableStream().getPos();
    try stream.seekableStream().seekBy(extended_header.num_entries * @sizeOf(Entry));

    const elf_offset = try stream.seekableStream().getPos();
    const elf_stream = stream_util.OffsetStream(StreamType){ .stream = stream, .offset = elf_offset };

    const elf_header = try elf.Header.read(elf_stream);

    var program_header_iter = elf_header.program_header_iterator(elf_stream);

    var min_offset: u64 = std.math.maxInt(u64);
    var elf_size: u64 = 0;

    while (try program_header_iter.next()) |segment| {
        if (segment.p_offset != 0) {
            min_offset = @min(min_offset, segment.p_offset);
        }
        elf_size = @max(segment.p_offset + segment.p_filesz, elf_size);
    }

    if (min_offset == std.math.maxInt(u64)) {
        min_offset = 0;
    }
    min_offset = @min(min_offset, @max(self_size, elf_offset) - elf_offset);

    var elf_data: []align(@alignOf(oelf.Header)) u8 = try allocator.alignedAlloc(u8, @alignOf(oelf.Header), elf_size);
    errdefer allocator.free(elf_data);

    try stream.seekableStream().seekTo(elf_offset);
    try stream.reader().readNoEof(elf_data[0..min_offset]);

    var entry_index: usize = 0;
    while (entry_index < extended_header.num_entries) {
        try stream.seekableStream().seekTo(entries_offset + (entry_index * @sizeOf(Entry)));
        const entry = try stream.reader().readStruct(Entry);

        if (entry.props & SF_BFLG > 0) {
            const program_header_index = @truncate(u12, entry.props >> 20);
            const program_header = std.mem.bytesToValue(elf.Elf64_Phdr, elf_data[elf_header.phoff + (program_header_index * @sizeOf(elf.Elf64_Phdr)) ..][0..@sizeOf(elf.Elf64_Phdr)]);

            try stream.seekableStream().seekTo(entry.offset);
            try stream.reader().readNoEof(elf_data[program_header.p_offset..][0..entry.filesz]);
        }
        entry_index += 1;
    }
    return elf_data;
}

pub const SF_BFLG = 0x800;

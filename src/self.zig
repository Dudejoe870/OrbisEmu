// PS4 SELF Parser
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

pub const ElfHeader = extern struct {
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

pub const ExtendedInfo = extern struct {
    paid: u64,
    ptype: u64,
    app_version: u64,
    fw_version: u64,
    digest: [32]u8,
};

pub const NpdrmControlBlock = extern struct {
    type: u16,
    _pad0: [14]u8,
    content_id: [19]u8,
    random_pad: [13]u8,
};

pub const MetaBlock = extern struct {
    unk: [80]u8,
};

pub const MetaFooter = extern struct {
    unk0: [48]u8,
    unk1: u32,
    unk2: [28]u8,
};

pub const Signature = [16]u8;

pub const Data = struct {
    allocator: std.mem.Allocator,

    common_header: CommonHeader,
    extended_header: ExtendedHeader,

    elf_offset: u64,

    entries: []Entry,

    elf_header: ElfHeader,
    program_headers: []elf.Elf64_Phdr,

    extended_info: ExtendedInfo,
    npdrm_control_block: NpdrmControlBlock,

    meta_blocks: []MetaBlock,
    meta_footer: MetaFooter,

    signature: Signature,

    dynamic_entries: []elf.Elf64_Dyn,
    rela_entries: []elf.Elf64_Rela,

    pub fn deinit(self: *Data) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.program_headers);
        self.allocator.free(self.meta_blocks);
        self.allocator.free(self.dynamic_entries);
        self.allocator.free(self.rela_entries);
    }
};

pub const ParseError = error {
    NotFakeSelf,
};

/// Parse a data stream with a SeekableStream and a Reader into a Data struct that contains all of the information from the SELF file.
pub fn parse(stream: anytype, allocator: std.mem.Allocator) !Data {
    const StreamType = @TypeOf(stream);

    comptime {
        std.debug.assert(@hasDecl(StreamType, "seekableStream"));
        std.debug.assert(@hasDecl(StreamType, "reader"));
    }

    var data: Data = undefined;
    data.allocator = allocator;

    data.common_header = try stream.reader().readStruct(CommonHeader);
    data.extended_header = try stream.reader().readStruct(ExtendedHeader);

    data.entries = try allocator.alloc(Entry, data.extended_header.num_entries);
    errdefer allocator.free(data.entries);

    for (data.entries) |*entry| {
        entry.* = try stream.reader().readStruct(Entry);
    }

    data.elf_offset = try stream.seekableStream().getPos();
    var elf_stream = stream_util.OffsetStream(@TypeOf(stream)) { 
        .stream = stream, 
        .offset = data.elf_offset,
    };

    data.elf_header = try stream.reader().readStruct(ElfHeader);
    const header_parser = try elf.Header.parse(std.mem.asBytes(&data.elf_header));

    var program_header_iter = header_parser.program_header_iterator(elf_stream);

    data.program_headers = try allocator.alloc(elf.Elf64_Phdr, data.elf_header.phnum);
    errdefer allocator.free(data.program_headers);

    data.rela_entries = try allocator.alloc(elf.Elf64_Rela, data.elf_header.phnum);
    data.rela_entries.len = 0;
    errdefer allocator.free(data.rela_entries);

    var found_dynamic: bool = false;
    for (data.program_headers) |*header| {
        header.* = (try program_header_iter.next()).?;

        if (header.p_type == elf.PT_DYNAMIC) {
            std.debug.assert(!found_dynamic);
            found_dynamic = true;

            try elf_stream.seekableStream().seekTo(header.p_offset);
            data.dynamic_entries = try allocator.alloc(elf.Elf64_Dyn, header.p_filesz / @sizeOf(elf.Elf64_Dyn));
            errdefer allocator.free(data.dynamic_entries);
            for (data.dynamic_entries) |*entry| {
                entry.* = try elf_stream.reader().readStruct(elf.Elf64_Dyn);
            }
        }
    }

    const elf_end_pos = std.mem.alignForward(@max(data.elf_header.ehsize, data.elf_header.phoff + (data.elf_header.phentsize * data.elf_header.phnum)), 16);
    try elf_stream.seekableStream().seekTo(elf_end_pos);

    data.extended_info = try stream.reader().readStruct(ExtendedInfo);

    // We can only parse fake SELFs because we cannot decrypt actual PS4 SELFs. 
    // Perhaps some day it will possible to dump the keys required from the PS4, 
    // then we could potentially use dumped libraries from the Kernel for the ones that are LLEable,
    // instead of HLEing them by reimplementation. Kind of like what RPCS3 does!
    if (data.extended_info.ptype != PTYPE_FAKE) {
        return ParseError.NotFakeSelf;
    }

    data.npdrm_control_block = try stream.reader().readStruct(NpdrmControlBlock);

    data.meta_blocks = try allocator.alloc(MetaBlock, data.extended_header.num_entries);
    errdefer allocator.free(data.meta_blocks);

    for (data.meta_blocks) |*block| {
        block.* = try stream.reader().readStruct(MetaBlock);
    }

    data.meta_footer = try stream.reader().readStruct(MetaFooter);
    data.signature = try stream.reader().readBytesNoEof(@typeInfo(Signature).Array.len);

    return data;
}

pub const PTYPE_FAKE = 0x1;



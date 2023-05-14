// Handles loading Kernel ELF Modules.
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
const stream_util = root.stream_util;

const oelf = @import("oelf.zig");
const self = @import("self.zig");

pub const Module = struct {};

pub const LoadError = error{
    InvalidSelfOrOElf,
    NothingToLoad,
    NoModuleName,
};

/// Load either a SELF or OELF byte stream as a Kernel Module.
pub fn load(stream: anytype, allocator: std.mem.Allocator) !Module {
    const StreamType = @TypeOf(stream);

    comptime {
        std.debug.assert(@hasDecl(StreamType, "seekableStream"));
        std.debug.assert(@hasDecl(StreamType, "reader"));
    }

    var mod: Module = undefined;
    var elf_data: oelf.Data = undefined;

    // Check the first 4 bytes (The file magic) to see if the stream contains a SELF file or an OELF file.
    //
    // On real hardware SELFs are encrypted and compressed.
    // Here they are "fake" SELF files that have been pre-decrypted and pre-decompressed on real hardware.
    // We still have to parse them however, as they move around the blocks of ELF data as a
    // left over from when they were encoded.
    // We simply parse those and copy the blocks of data around to where they should be to retrieve the OELF file.
    //
    // OELF files are basically just normal ELF files with special Sony tags and values which contain all of
    // the essential data a regular ELF does.
    {
        var magic: [4]u8 = undefined;
        try stream.reader().readNoEof(&magic);
        try stream.seekableStream().seekTo(0);

        var oelf_data: []u8 = undefined;
        if (std.mem.eql(u8, &magic, &self.SELF_MAGIC)) {
            oelf_data = try self.toOElf(stream, allocator);
        } else if (std.mem.eql(u8, &magic, &oelf.ELF_MAGIC)) {
            try stream.seekableStream().seekTo(try stream.seekableStream().getEndPos());
            const file_size = try stream.seekableStream().getPos();
            try stream.seekableStream().seekTo(0);

            oelf_data = try allocator.alloc(u8, file_size);
            try stream.reader().readNoEof(oelf_data);
        } else {
            return LoadError.InvalidSelfOrOElf;
        }

        elf_data = try oelf.parse(oelf_data, allocator);
    }
    defer elf_data.deinit();
    if (elf_data.mapped_size == 0) return LoadError.NothingToLoad;
    if (elf_data.export_modules == null) return LoadError.NoModuleName;

    std.log.debug("{any}", .{elf_data.header});

    std.log.debug("program_headers:", .{});
    for (elf_data.program_headers) |header| {
        std.log.debug(" {any}", .{header});
    }

    if (elf_data.needed_files) |needed_files| {
        std.log.debug("needed_files:", .{});
        for (needed_files) |file| {
            std.log.debug(" {s}", .{file});
        }
    }

    if (elf_data.export_modules) |export_modules| {
        std.log.debug("export_modules:", .{});
        for (export_modules) |module| {
            std.log.debug(" {s}", .{module.name});
        }
    }

    if (elf_data.import_modules) |import_modules| {
        std.log.debug("import_modules:", .{});
        for (import_modules) |module| {
            std.log.debug(" {s}", .{module.name});
        }
    }

    if (elf_data.export_libraries) |export_libraries| {
        std.log.debug("export_libraries:", .{});
        for (export_libraries) |library| {
            std.log.debug(" {s}", .{library.name});
        }
    }

    if (elf_data.import_libraries) |import_libraries| {
        std.log.debug("import_libraries:", .{});
        for (import_libraries) |library| {
            std.log.debug(" {s}", .{library.name});
        }
    }

    std.log.info("Loaded module \"{s}\"", .{elf_data.export_modules.?[0].name});
    return mod;
}

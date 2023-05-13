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
const stream_util = root.stream_util;

const oelf = @import("oelf.zig");
const self = @import("self.zig");

pub const Module = struct {};

pub fn load(stream: anytype, allocator: std.mem.Allocator) !Module {
    const StreamType = @TypeOf(stream);

    comptime {
        std.debug.assert(@hasDecl(StreamType, "seekableStream"));
        std.debug.assert(@hasDecl(StreamType, "reader"));
    }

    var mod: Module = undefined;

    var elf_data = try oelf.parse(try self.toOElf(stream, allocator), allocator);
    defer elf_data.deinit();

    std.log.info("{any}", .{elf_data.header});

    for (elf_data.program_headers) |header| {
        std.log.info("{any}", .{header});
    }

    return mod;
}

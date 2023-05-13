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

const self = @import("self.zig");

pub const Module = struct {

};

pub fn load(stream: anytype, allocator: std.mem.Allocator) !Module {
    var mod: Module = undefined;

    var self_data = try self.parse(stream, allocator);
    defer self_data.deinit();

    var elf_stream = stream_util.OffsetStream(@TypeOf(stream)) {
        .stream = stream,
        .offset = self_data.elf_offset,
    };
    _ = elf_stream;

    std.log.info("{any}", .{self_data.common_header});
    std.log.info("{any}", .{self_data.extended_header});

    for (self_data.entries) |header| {
        std.log.info("{any}", .{header});
    }

    std.log.info("{any}", .{self_data.elf_header});

    for (self_data.program_headers) |header| {
        std.log.info("{any}", .{header});
    }

    std.log.info("{any}", .{self_data.extended_info});
    std.log.info("{any}", .{self_data.npdrm_control_block});

    return mod;
}

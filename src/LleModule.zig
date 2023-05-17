// LLE Module Structure
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

const Self = @This();

pub const RawSymbolInfo = struct {
    name: []const u8,
    is_encoded: bool,
    type: u4,
    binding: u4,
    address: ?*anyopaque,
};

id: u16 = 0,
name: []const u8 = undefined,

export_name: []const u8 = undefined,
library_names: ?[][]const u8 = null,

data: []align(std.mem.page_size) u8 = undefined,

code_section: []u8 = undefined,
data_section: []u8 = undefined,
relro_section: []u8 = undefined,

init_proc: ?*const fn (argc: usize, argv: ?[*]?[*:0]u8, ?*const fn (argc: usize, argv: ?[*]?[*:0]u8) callconv(.SysV) c_int) callconv(.SysV) c_int = null,
entry_point: ?*const fn (arg: ?*anyopaque, exit_function: ?*const fn () callconv(.SysV) void) callconv(.SysV) ?*anyopaque = null,
proc_param: ?*anyopaque = null,

raw_symbols: []const RawSymbolInfo = undefined,
local_symbol_table: std.StringHashMap(?*anyopaque) = undefined,

is_lib: bool = false,

dependencies: ?[][]const u8 = null,

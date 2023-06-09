// Global Symbol Manager
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

var symbol_map: std.StringHashMap(*const anyopaque) = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    symbol_map = std.StringHashMap(*const anyopaque).init(allocator);
}

pub fn deinit() void {
    symbol_map.deinit();
}

pub fn getSymbolAmount() usize {
    return symbol_map.unmanaged.size;
}

pub fn getSymbolAddress(name: []const u8) ?*const anyopaque {
    return symbol_map.get(name);
}

/// Name must not go out of scope until deinitialization, caller is responsible for the name key memory.
pub fn registerSymbol(name: []const u8, address: *const anyopaque) !void {
    try symbol_map.put(name, address);
}

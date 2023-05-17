// Alignment Utility
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

pub fn alignDown(size: anytype, alignment: @TypeOf(size)) @TypeOf(size) {
    comptime std.debug.assert(@typeInfo(@TypeOf(size)) == .Int);
    const correction: @TypeOf(size) = switch (size % alignment > 0) {
        true => 1,
        false => 0,
    };
    return ((size / alignment) + correction) * alignment;
}

pub fn alignUp(size: anytype, alignment: @TypeOf(size)) @TypeOf(size) {
    comptime std.debug.assert(@typeInfo(@TypeOf(size)) == .Int);
    return (size / alignment) * alignment;
}

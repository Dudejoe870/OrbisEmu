// General Byte Stream Utility
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

/// A generic Stream type that allows you to define an offset for all seeking operations.
pub fn OffsetStream(comptime StreamType: type) type {
    return struct {
        const Self = @This();

        pub const SeekableStream = std.io.SeekableStream(Self, 
            StreamType.SeekableStream.SeekError, StreamType.SeekableStream.GetSeekPosError, 
            seekTo, 
            seekBy, 
            getPos, 
            getEndPos);
        
        pub const Reader = StreamType.Reader;

        stream: StreamType,
        offset: u64,

        pub fn seekTo(self: Self, pos: u64) StreamType.SeekableStream.SeekError!void {
            return self.stream.seekTo(pos + self.offset);
        }

        pub fn seekBy(self: Self, pos: i64) StreamType.SeekableStream.SeekError!void {
            return self.stream.seekBy(pos);
        }

        pub fn getPos(self: Self) StreamType.SeekableStream.GetSeekPosError!u64 {
            return try self.stream.getPos() - self.offset;
        }

        pub fn getEndPos(self: Self) StreamType.SeekableStream.GetSeekPosError!u64 {
            return try self.stream.getEndPos() - self.offset;
        }

        pub fn seekableStream(self: Self) SeekableStream {
            return .{ .context = self };
        }

        pub fn reader(self: Self) Reader {
            return self.stream.reader();
        }
    };
}

// Cross-Platform Page Allocation Utility
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
const builtin = @import("builtin");
const win = std.os.windows;

pub const ProtectSettings = struct {
    read: bool,
    write: bool,
    execute: bool,

    pub fn toWindows(self: ProtectSettings) win.DWORD {
        if (self.read and self.write and self.execute) return win.PAGE_EXECUTE_READWRITE;

        if (self.read and self.write) return win.PAGE_READWRITE;
        if (self.write and self.execute) return win.PAGE_EXECUTE_READWRITE;
        if (self.read and self.execute) return win.PAGE_EXECUTE_READ;

        if (self.execute) return win.PAGE_EXECUTE;
        if (self.read) return win.PAGE_READONLY;
        if (self.write) return win.PAGE_READWRITE;
        unreachable;
    }

    pub fn toPosix(self: ProtectSettings) u32 {
        var result: u32 = 0;
        if (self.read) {
            result |= std.os.PROT.READ;
        }
        if (self.write) {
            result |= std.os.PROT.WRITE;
        }
        if (self.execute) {
            result |= std.os.PROT.EXEC;
        }
        return result;
    }
};

pub fn alloc(len: usize, protect: ProtectSettings) ![]align(std.mem.page_size) u8 {
    const aligned_len = std.mem.alignForward(len, std.mem.page_size);

    if (builtin.os.tag == .windows) {
        const ptr = try win.VirtualAlloc(null, aligned_len, win.MEM_COMMIT | win.MEM_RESERVE, protect.toWindows());
        return @ptrCast([*]align(std.mem.page_size) u8, @alignCast(std.mem.page_size, ptr))[0..len];
    } else {
        return try std.os.mmap(null, aligned_len, protect.toPosix(), std.os.MAP.PRIVATE | std.os.MAP.ANONYMOUS, -1, 0)[0..len];
    }
}

pub fn free(slice: []align(std.mem.page_size) u8) void {
    if (builtin.os.tag == .windows) {
        std.os.windows.VirtualFree(slice.ptr, 0, std.os.windows.MEM_RELEASE);
    } else {
        const buf_aligned_len = std.mem.alignForward(slice.len, std.mem.page_size);
        std.os.munmap(slice.ptr[0..buf_aligned_len]);
    }
}

// HLE Module Loader
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

pub const module_list = .{@import("hle_modules/libkernel.zig")};

pub fn shouldLoadLleSymbol(symbol_name: []const u8, module_name: []const u8, library_name: []const u8) bool {
    inline for (module_list) |module| {
        if (std.mem.eql(u8, module_name, module.info.name)) {
            inline for (module.info.library_list) |library| {
                if (std.mem.eql(u8, library_name, library.info.name)) {
                    if (library.info.default_mode == .hle) {
                        inline for (library.info.lle_symbols) |sym| {
                            if (std.mem.eql(u8, symbol_name, sym)) {
                                return true;
                            }
                        }
                    } else {
                        return true;
                    }
                }
            }
            return module.info.default_mode == .lle;
        }
    }
    return true;
}

/// Register the "low-priority" HLE symbols into the global Symbol table. Low-priority Symbols can get overwritten by the LLE Symbol if loaded
pub fn registerLowPriorityHleSymbols() !void {}

// In the middle of registering these, the LLE Modules get loaded (They can overwrite the low-priority HLE symbols but not the high-priority ones)

/// Register the "high-priority" HLE symbols into the global Symbol table. High-priority Symbols overwrite any LLE Symbol if loaded
pub fn registerHighPriorityHleSymbols() !void {}

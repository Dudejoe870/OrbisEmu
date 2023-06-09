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
const root = @import("root");

const symbol_manager = root.symbol_manager;

pub const module_list = .{@import("hle_modules/libkernel.zig")};

// TODO: Make most of the logic of this runtime data structures with hashmaps,
// a big web of if statements (even if it is generated by code at compile-time) smells of bad code to me.
// (even if the performance doesn't really matter since this is at initialization time and it should be fast enough-ish anyway)
pub fn shouldLoadLleSymbol(symbol_name: []const u8, module_name: []const u8, library_name: []const u8) bool {
    inline for (module_list) |module| {
        if (std.mem.eql(u8, module_name, module.info.name)) {
            inline for (module.info.library_list) |library| {
                if (std.mem.eql(u8, library_name, library.info.name)) { // The library definition exists in the module
                    if (library.info.default_mode == .hle) {
                        if (@hasField(@TypeOf(library.info), "lle_symbols")) {
                            inline for (library.info.lle_symbols) |sym| {
                                if (std.mem.eql(u8, symbol_name, sym)) {
                                    return true; // Only load the symbol if it is specifically listed in the "lle_symbols" list...
                                }
                            }
                        }
                        return false; // ...Otherwise return false.
                    } else {
                        return true; // If the default mode for the library is LLE, then load the symbol
                    }
                }
            }
            return module.info.default_mode == .lle; // If the library definition doesn't exist, use the default mode for the module
        }
    }
    return true; // If the entire module hasn't been defined yet, then load the symbol (could be a special user dynamic library, though idk if those are really a thing. You could definitely make one though)
}

/// Registers HLE low or high priority symbols from the module libraries.
///
/// This function operates almost entirely at compile-time.
/// The only runtime code is a list of registerSymbol and debug log function calls.
fn registerHleSymbols(comptime priority: anytype) !void {
    const main_list_name = switch (priority == .high) {
        true => "high_priority",
        false => "low_priority",
    };
    const other_list_name = switch (priority == .high) {
        true => "low_priority",
        false => "high_priority",
    };

    inline for (module_list) |module| {
        inline for (module.info.library_list) |library| {
            if (@hasField(@TypeOf(library.info), main_list_name)) {
                inline for (@field(library.info, main_list_name)) |func_name| {
                    const field = @field(library, func_name);

                    const symbol_name = std.fmt.comptimePrint("{s}#{s}#{s}", .{ func_name, module.info.name, library.info.name });
                    std.log.debug("Registering HLE Symbol {s} (0x{x})", .{ symbol_name, @ptrToInt(&field) });
                    try symbol_manager.registerSymbol(symbol_name, @ptrCast(*anyopaque, &field));
                }
            } else if (@hasField(@TypeOf(library.info), other_list_name)) {
                inline for (@typeInfo(library).Struct.decls) |decl| {
                    comptime if (!decl.is_pub) continue;
                    check_field: {
                        comptime var field = @field(library, decl.name);
                        if (@typeInfo(@TypeOf(field)) == .Fn) {
                            inline for (@field(library.info, other_list_name)) |func_name| {
                                comptime if (std.mem.eql(u8, decl.name, func_name)) {
                                    break :check_field;
                                };
                            }

                            const symbol_name = std.fmt.comptimePrint("{s}#{s}#{s}", .{ decl.name, module.info.name, library.info.name });
                            std.log.debug("Registering HLE Symbol {s} (0x{x})", .{ symbol_name, @ptrToInt(&field) });
                            try symbol_manager.registerSymbol(symbol_name, @ptrCast(*const anyopaque, &field));
                        }
                    }
                }
            } else {
                @compileError(std.fmt.comptimePrint("You must define either .low_priority or .high_priority in the {s}#{s} library info definition to set the default priority.", .{ module.info.name, library.info.name }));
            }
        }
    }
}

/// Register the "low-priority" HLE symbols into the global Symbol table. Low-priority Symbols can get overwritten by the LLE Symbol if loaded
pub fn registerLowPriorityHleSymbols() !void {
    try registerHleSymbols(.low);
}

// In the middle of registering these, the LLE Modules get loaded (They can overwrite the low-priority HLE symbols but not the high-priority ones)

/// Register the "high-priority" HLE symbols into the global Symbol table. High-priority Symbols overwrite any LLE Symbol if loaded
pub fn registerHighPriorityHleSymbols() !void {
    try registerHleSymbols(.high);
}

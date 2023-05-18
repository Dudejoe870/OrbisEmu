// Main Entrypoint And Argument Parsing
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

const yazap = @import("yazap");

pub var gpa = std.heap.GeneralPurposeAllocator(.{}){};

/// Default Allocator. Uses a fast Allocator in ReleaseFast mode, and a Debug allocator in any other mode.
pub const default_allocator = switch (builtin.mode) {
    .ReleaseFast => std.heap.c_allocator, // TODO: Replace with even faster third-party allocator?
    else => gpa.allocator(),
};

pub const LleModule = @import("LleModule.zig");

/// General Byte Stream Utility
pub const stream_util = @import("util/stream_util.zig");

/// Cross-Platform Page Allocation Utility
pub const page_util = @import("util/page_util.zig");

/// Alignment Utility
pub const align_util = @import("util/align_util.zig");

/// Encoded NID Symbol Name Utility
pub const nid_util = @import("util/nid_util.zig");

/// LLE Kernel ELF Module Loader
pub const lle_module_loader = @import("lle_module_loader.zig");

/// HLE Module Loader
pub const hle_module_loader = @import("hle_module_loader.zig");

/// NID Lookup Table (generated from ps4libdoc)
pub const nid_table = @import("nid_table.zig");

/// Global Symbol Manager
pub const symbol_manager = @import("symbol_manager.zig");

/// Main eboot.bin LLE Module
pub var eboot_module: *const LleModule = undefined;

/// Game Directory Path
pub var eboot_directory_path: []const u8 = undefined;

/// eboot_dir/sce_module
pub var sce_module_eboot_directory_path: []const u8 = undefined;

/// Emulator EXE Path
pub var exe_path: []const u8 = undefined;

/// exe_dir/system/common/lib
pub var system_common_exe_directory_path: []const u8 = undefined;

/// exe_dir/system/priv/lib
pub var system_priv_exe_directory_path: []const u8 = undefined;

pub fn main() !u8 {
    defer _ = gpa.deinit();

    var app = yazap.App.init(default_allocator, "OrbisEmu", "An experimental Orbis compatibility layer.");
    defer app.deinit();

    var root_cmd = app.rootCommand();

    var run_cmd = app.createCommand("run", "Run an extracted PS4 fake SELF/OELF in an extracted fake PKG directory.");
    try run_cmd.addArg(yazap.flag.argOne("path", 'i', "Path to the eboot.bin/oelf/elf"));

    try root_cmd.addSubcommand(run_cmd);

    const args = try app.parseProcess();

    if (!args.hasArgs()) {
        try app.displayHelp();
        return 1;
    }

    if (args.subcommandContext("run")) |run_cmd_args| {
        if (run_cmd_args.valueOf("path")) |path| {
            symbol_manager.init(default_allocator);
            defer symbol_manager.deinit();

            eboot_directory_path = try default_allocator.dupe(u8, std.fs.path.dirname(path).?);
            defer default_allocator.free(eboot_directory_path);
            
            sce_module_eboot_directory_path = try std.fs.path.join(default_allocator, &[_][]const u8 { eboot_directory_path, "sce_module" });
            defer default_allocator.free(sce_module_eboot_directory_path);

            exe_path = try std.fs.selfExeDirPathAlloc(default_allocator);
            defer default_allocator.free(exe_path);

            system_common_exe_directory_path = try std.fs.path.join(default_allocator, &[_][]const u8 { exe_path, "system/common/lib" });
            defer default_allocator.free(system_common_exe_directory_path);

            system_priv_exe_directory_path = try std.fs.path.join(default_allocator, &[_][]const u8 { exe_path, "system/priv/lib" });
            defer default_allocator.free(system_priv_exe_directory_path);

            try nid_table.init(default_allocator);
            defer nid_table.deinit();

            lle_module_loader.init(default_allocator);
            defer lle_module_loader.deinit();

            eboot_module = try lle_module_loader.loadFile(path);
            try lle_module_loader.loadAllDependencies();

            std.log.info("Loading Global Symbols...", .{});
            try hle_module_loader.registerLowPriorityHleSymbols();
            try lle_module_loader.registerGlobalLleSymbols();
            try hle_module_loader.registerHighPriorityHleSymbols();
            std.log.info("Loaded {d} Symbols.", .{symbol_manager.getSymbolAmount()});

            try lle_module_loader.linkModules();

            // TODO: Run loaded eboot.

            return 0;
        }
        return 1;
    }

    try app.displayHelp();
    return 1;
}

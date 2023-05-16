// Main Entrypoint and argument parsing
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

/// General Byte Stream Utility
pub const stream_util = @import("stream_util.zig");

/// Cross-Platform Page Allocation Utility
pub const page_util = @import("page_util.zig");

/// Alignment Utility
pub const align_util = @import("align_util.zig");

/// Kernel ELF Module Loader
pub const module_loader = @import("module_loader.zig");

/// HLE Module Definitions
pub const hle_modules = @import("hle_modules.zig");

/// NID lookup table (generated from ps4libdoc)
pub const nid_table = @import("nid_table.zig");

pub var eboot_module: *const module_loader.Module = undefined;

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
            module_loader.init(default_allocator);
            defer module_loader.deinit();

            eboot_module = try module_loader.loadFile(path, default_allocator);

            // TODO: Run loaded eboot.

            return 0;
        }
        return 1;
    }

    try app.displayHelp();
    return 1;
}

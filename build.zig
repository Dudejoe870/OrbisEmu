// OrbisEmu is an experimental PS4 GPU Emulator and Orbis compatibility layer for Windows and Linux operating systems under the x86_64 CPU architecture.
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

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    var arch: std.Target.Cpu.Arch = undefined;
    if (target.cpu_arch) |target_arch| {
        arch = target_arch;
    } else {
        arch = builtin.cpu.arch;
    }

    if (arch != .x86_64) {
        std.log.err("Target must be x86_64, this is a compatibility layer, not an emulator (at least not a CPU emulator). It cannot be built for any other target other than x86_64 (at this time at least, no CPU emulator is present)", .{});
        return;
    }

    const exe = b.addExecutable(.{ .name = "OrbisEmu", .root_source_file = .{ .path = "src/main.zig" }, .target = target, .optimize = optimize });

    const yazap_module = b.dependency("yazap", .{}).module("yazap");
    exe.addModule("yazap", yazap_module);

    exe.linkLibC();
    b.installArtifact(exe);
}

// Kernel ELF Module Loader
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
const elf = std.elf;
const stream_util = root.stream_util;
const page_util = root.page_util;
const align_util = root.align_util;

const oelf = @import("oelf.zig");
const ps4_self = @import("self.zig");

pub const Module = struct {
    pub const ExtraInfo = struct {
        allocator: std.mem.Allocator = undefined,
        export_name: []const u8 = undefined,
        library_name: ?[]const u8 = null,

        pub fn deinit(self: *ExtraInfo) void {
            self.allocator.free(self.export_name);
            if (self.library_name) |name| self.allocator.free(name);
        }
    };

    data: []align(std.mem.page_size) u8 = undefined,
    extra_info: ExtraInfo = .{},

    code_section: []u8 = undefined,
    data_section: []u8 = undefined,
    relro_section: []u8 = undefined,

    init_proc: ?*const fn(argc: usize, argv: ?*?*anyopaque, ?*const fn(argc: usize, argv: ?*?*anyopaque) callconv(.SysV) c_int) callconv(.SysV) c_int = null,
    entry_point: ?*const fn(arg: ?*anyopaque, exit_function: ?*const fn() callconv(.SysV) void) callconv(.SysV) ?*anyopaque = null,

    is_lib: bool = false,

    pub fn deinit(self: *Module) void {
        self.extra_info.deinit();
        page_util.free(self.data);
    }
};

pub const LoadError = error{
    InvalidSelfOrOElf,
    NothingToLoad,
    NoModuleName,

    NotAllSectionsArePresent,

    MoreThanOneCodeSection,
    MoreThanOneDataSection,
    MoreThanOneRelroSection,
};

var loaded_modules: std.ArrayList(Module) = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    loaded_modules = std.ArrayList(Module).init(allocator);
}

pub fn deinit() void {
    for (loaded_modules.items) |*module| {
        std.log.info("Unloading module \"{s}\" (is_lib: {any})", .{ module.extra_info.export_name, module.is_lib });
        module.deinit();
    }
    loaded_modules.deinit();
}

pub fn getLoadedModules() []const Module {
    return loaded_modules.items;
}

/// Load either a SELF or OELF byte stream as a Kernel Module.
pub fn load(stream: anytype, allocator: std.mem.Allocator) !*const Module {
    const StreamType = @TypeOf(stream);

    comptime {
        std.debug.assert(@hasDecl(StreamType, "seekableStream"));
        std.debug.assert(@hasDecl(StreamType, "reader"));
    }

    try loaded_modules.append(.{});
    var mod = &loaded_modules.items[loaded_modules.items.len-1];
    var elf_data: oelf.Data = undefined;

    // Check the first 4 bytes (The file magic) to see if the stream contains a SELF file or an OELF file.
    //
    // On real hardware SELFs are encrypted and compressed, here they are "fake" SELF files that have 
    // been pre-decrypted and pre-decompressed on real hardware.
    // We still have to parse them however, as they move around the blocks of ELF data as a
    // left over from when they were encoded.
    // We simply parse those and copy the blocks of data around to where they should be to retrieve the OELF file.
    //
    // OELF files are basically just normal ELF files with special Sony tags and values which contain all of
    // the same essential data a regular ELF does.
    {
        var magic: [4]u8 = undefined;
        try stream.reader().readNoEof(&magic);
        try stream.seekableStream().seekTo(0);

        var oelf_data: []u8 = undefined;
        if (std.mem.eql(u8, &magic, &ps4_self.SELF_MAGIC)) {
            oelf_data = try ps4_self.toOElf(stream, allocator);
        } else if (std.mem.eql(u8, &magic, &oelf.ELF_MAGIC)) {
            try stream.seekableStream().seekTo(try stream.seekableStream().getEndPos());
            const file_size = try stream.seekableStream().getPos();
            try stream.seekableStream().seekTo(0);

            oelf_data = try allocator.alloc(u8, file_size);
            try stream.reader().readNoEof(oelf_data);
        } else {
            return LoadError.InvalidSelfOrOElf;
        }

        elf_data = try oelf.parse(oelf_data, allocator);
    }
    defer elf_data.deinit();
    if (elf_data.mapped_size == 0) return LoadError.NothingToLoad;
    if (elf_data.export_modules == null) return LoadError.NoModuleName;
    logDebugElfInfo(&elf_data);

    mod.is_lib = elf_data.header.type == oelf.ET_SCE_DYNAMIC;

    mod.data = try page_util.alloc(elf_data.mapped_size, .{ .read = true, .write = true, .execute = true });
    errdefer page_util.free(mod.data);

    // Map all Sections into memory using the data from the Program Headers.
    {
        var mapped_code: bool = false;
        var mapped_data: bool = false;
        var mapped_relro: bool = false;
        for (elf_data.program_headers) |segment| {
            if (segment.p_flags & elf.PF_X > 0) {
                if (mapped_code) return LoadError.MoreThanOneCodeSection;

                mod.code_section = mod.data[align_util.alignDown(segment.p_vaddr, segment.p_align)..][0..segment.p_memsz];
                @memcpy(mod.code_section[0..segment.p_filesz], elf_data.bytes[segment.p_offset..][0..segment.p_filesz]);

                if (elf_data.header.entry != 0) {
                    mod.entry_point = @ptrCast(@TypeOf(mod.entry_point), &mod.data[elf_data.header.entry]);
                }

                mapped_code = true;
            } else if (segment.p_type == oelf.PT_SCE_RELRO) {
                if (mapped_relro) return LoadError.MoreThanOneRelroSection;

                mod.relro_section = mod.data[align_util.alignDown(segment.p_vaddr, segment.p_align)..][0..segment.p_memsz];
                @memcpy(mod.code_section[0..segment.p_filesz], elf_data.bytes[segment.p_offset..][0..segment.p_filesz]);
                mapped_relro = true;
            } else if (segment.p_flags & elf.PF_R > 0) {
                if (mapped_data) return LoadError.MoreThanOneDataSection;

                mod.data_section = mod.data[align_util.alignDown(segment.p_vaddr, segment.p_align)..][0..segment.p_memsz];
                @memcpy(mod.code_section[0..segment.p_filesz], elf_data.bytes[segment.p_offset..][0..segment.p_filesz]);
                mapped_data = true;
            }

            if (mapped_code and mapped_data and mapped_relro) break;
        }

        if (!mapped_code or !mapped_data or !mapped_relro) {
            return LoadError.NotAllSectionsArePresent;
        }
    }

    // Fill in extra info.
    {
        mod.extra_info.allocator = allocator;

        {
            const mod_export_name = elf_data.export_modules.?[0].name;
            mod.extra_info.export_name = try allocator.alloc(u8, mod_export_name.len);
            @memcpy(@constCast(mod.extra_info.export_name), mod_export_name);
        }

        if (elf_data.export_libraries) |libraries| {
            const mod_library_name = libraries[0].name;
            mod.extra_info.library_name = try allocator.alloc(u8, mod_library_name.len);
            @memcpy(@constCast(mod.extra_info.library_name.?), mod_library_name);
        }
    }

    std.log.info("Loaded module \"{s}\" ({d} bytes, is_lib: {any})", .{ mod.extra_info.export_name, mod.data.len, mod.is_lib });
    return mod;
}

fn logDebugElfInfo(elf_data: *oelf.Data) void {
    std.log.debug("{any}", .{elf_data.header});

    std.log.debug("program_headers:", .{});
    for (elf_data.program_headers) |header| {
        std.log.debug(" {any}", .{header});
    }

    if (elf_data.needed_files) |needed_files| {
        std.log.debug("needed_files:", .{});
        for (needed_files) |file| {
            std.log.debug(" {s}", .{file});
        }
    }

    if (elf_data.export_modules) |export_modules| {
        std.log.debug("export_modules:", .{});
        for (export_modules) |module| {
            std.log.debug(" {s}", .{module.name});
        }
    }

    if (elf_data.import_modules) |import_modules| {
        std.log.debug("import_modules:", .{});
        for (import_modules) |module| {
            std.log.debug(" {s}", .{module.name});
        }
    }

    if (elf_data.export_libraries) |export_libraries| {
        std.log.debug("export_libraries:", .{});
        for (export_libraries) |library| {
            std.log.debug(" {s}", .{library.name});
        }
    }

    if (elf_data.import_libraries) |import_libraries| {
        std.log.debug("import_libraries:", .{});
        for (import_libraries) |library| {
            std.log.debug(" {s}", .{library.name});
        }
    }
}

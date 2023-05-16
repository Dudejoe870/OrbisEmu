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
    allocator: std.mem.Allocator = undefined,

    id: u16 = 0,
    name: []const u8 = undefined,

    export_name: []const u8 = undefined,
    library_names: ?[][]const u8 = null,

    data: []align(std.mem.page_size) u8 = undefined,

    code_section: []u8 = undefined,
    data_section: []u8 = undefined,
    relro_section: []u8 = undefined,

    init_proc: ?*const fn (argc: usize, argv: ?[*]?[*:0]u8, ?*const fn (argc: usize, argv: ?[*]?[*:0]u8) callconv(.SysV) c_int) callconv(.SysV) c_int = null,
    entry_point: ?*const fn (arg: ?*anyopaque, exit_function: ?*const fn () callconv(.SysV) void) callconv(.SysV) ?*anyopaque = null,
    proc_param: ?*anyopaque = null,

    is_lib: bool = false,

    pub fn deinit(self: *Module) void {
        self.allocator.free(self.name);
        self.allocator.free(self.export_name);
        if (self.library_names) |names| {
            for (names) |name| {
                self.allocator.free(name);
            }
            self.allocator.free(names);
        }

        page_util.free(self.data);
    }
};

pub const LoadError = error{
    InvalidSelfOrOElf,
    NothingToLoad,
    NoModuleInfo,

    NotAllSectionsArePresent,

    MoreThanOneCodeSection,
    MoreThanOneDataSection,
    MoreThanOneRelroSection,
};

var loaded_modules: std.ArrayList(Module) = undefined;
var module_name_to_index: std.StringHashMap(usize) = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    loaded_modules = std.ArrayList(Module).init(allocator);
    module_name_to_index = std.StringHashMap(usize).init(allocator);
}

pub fn deinit() void {
    module_name_to_index.deinit();

    for (loaded_modules.items) |*module| {
        std.log.info("Unloading module \"{s}\" (id: 0x{x}, is_lib: {any})", .{ module.name, module.id, module.is_lib });
        module.deinit();
    }
    loaded_modules.deinit();
}

pub fn getLoadedModules() []const Module {
    return loaded_modules.items;
}

pub fn isModuleLoadedFromName(name: []const u8) bool {
    return module_name_to_index.contains(name);
}

pub fn getModuleFromName(name: []const u8) ?*const Module {
    if (module_name_to_index.get(name)) |index| {
        return &loaded_modules.items[index];
    }
    return null;
}

/// Load either a SELF or OELF file as a Kernel Module.
pub fn loadFile(path: []const u8, allocator: std.mem.Allocator) !*const Module {
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();
    return load(file, std.fs.path.stem(path), allocator);
}

/// Load either a SELF or OELF byte stream as a Kernel Module.
pub fn load(stream: anytype, name: []const u8, allocator: std.mem.Allocator) !*const Module {
    const StreamType = @TypeOf(stream);

    comptime {
        std.debug.assert(@hasDecl(StreamType, "seekableStream"));
        std.debug.assert(@hasDecl(StreamType, "reader"));
    }

    if (getModuleFromName(name)) |mod| {
        std.log.warn("Trying to load Module \"{s}\" but it is already loaded", .{name});
        return mod;
    }

    const module_index = loaded_modules.items.len;
    try loaded_modules.append(.{});
    try module_name_to_index.put(name, module_index);
    var mod = &loaded_modules.items[module_index];

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
    if (elf_data.export_modules == null) return LoadError.NoModuleInfo;
    logDebugElfInfo(&elf_data);

    mod.is_lib = elf_data.header.type == oelf.ET_SCE_DYNAMIC;

    mod.data = try page_util.alloc(elf_data.mapped_size, .{ .read = true, .write = true, .execute = true });
    errdefer page_util.free(mod.data);

    mod.id = elf_data.export_modules.?[0].value.bits.id;

    if (elf_data.init_proc_offset) |offset| {
        mod.init_proc = @ptrCast(@TypeOf(mod.init_proc), &mod.data[offset]);
    }
    if (elf_data.proc_param_offset) |offset| {
        mod.proc_param = @ptrCast(*anyopaque, &mod.data[offset]);
    }
    if (elf_data.header.entry != 0) {
        mod.entry_point = @ptrCast(@TypeOf(mod.entry_point), &mod.data[elf_data.header.entry]);
    }

    // TODO: TLS (Thread Local Storage)

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

                mapped_code = true;
            } else if (segment.p_type == oelf.PT_SCE_RELRO) {
                if (mapped_relro) return LoadError.MoreThanOneRelroSection;

                mod.relro_section = mod.data[align_util.alignDown(segment.p_vaddr, segment.p_align)..][0..segment.p_memsz];
                @memcpy(mod.relro_section[0..segment.p_filesz], elf_data.bytes[segment.p_offset..][0..segment.p_filesz]);

                mapped_relro = true;
            } else if (segment.p_flags & elf.PF_R > 0) {
                if (mapped_data) return LoadError.MoreThanOneDataSection;

                mod.data_section = mod.data[align_util.alignDown(segment.p_vaddr, segment.p_align)..][0..segment.p_memsz];
                @memcpy(mod.data_section[0..segment.p_filesz], elf_data.bytes[segment.p_offset..][0..segment.p_filesz]);

                mapped_data = true;
            }

            if (mapped_code and mapped_data and mapped_relro) break;
        }

        if (!mapped_code or !mapped_data or !mapped_relro) {
            return LoadError.NotAllSectionsArePresent;
        }
    }

    // Fill in variable-length strings.
    mod.allocator = allocator;

    {
        const mod_export_name = elf_data.export_modules.?[0].name;
        mod.export_name = try allocator.alloc(u8, mod_export_name.len);
        @memcpy(@constCast(mod.export_name), mod_export_name);
    }
    errdefer allocator.free(mod.export_name);

    {
        mod.name = try allocator.alloc(u8, name.len);
        @memcpy(@constCast(mod.name), name);
    }
    errdefer allocator.free(mod.name);

    if (elf_data.export_libraries) |libraries| {
        mod.library_names = try allocator.alloc([]const u8, libraries.len);
        errdefer allocator.free(mod.library_names.?);
        for (libraries, 0..) |mod_library_name, i| {
            mod.library_names.?[i] = try allocator.alloc(u8, mod_library_name.name.len);
            @memcpy(@constCast(mod.library_names.?[i]), mod_library_name.name);
        }
    }
    errdefer {
        if (mod.library_names) |lib_names| {
            for (lib_names) |mod_library_name| {
                allocator.free(mod_library_name);
            }
            allocator.free(lib_names);
        }
    }

    std.log.info("Loaded module \"{s}\" (export_name: \"{s}\", id: 0x{x}, {d} bytes, is_lib: {any})", .{ mod.name, mod.export_name, mod.id, mod.data.len, mod.is_lib });
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

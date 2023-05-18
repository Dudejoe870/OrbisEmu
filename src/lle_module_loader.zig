// LLE Kernel ELF Module Loader
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

const LleModule = root.LleModule;

const page_util = root.page_util;
const align_util = root.align_util;
const symbol_manager = root.symbol_manager;
const hle_module_loader = root.hle_module_loader;
const nid_util = root.nid_util;

const oelf = @import("oelf.zig");
const ps4_self = @import("self.zig");

pub const LoadError = error{
    InvalidSelfOrOElf,
    NothingToLoad,
    NoModuleInfo,

    NotAllSectionsArePresent,

    MoreThanOneCodeSection,
    MoreThanOneDataSection,
    MoreThanOneRelroSection,

    ImportModuleIdNotDefined,
};

var memory_pool: std.heap.ArenaAllocator = undefined;
inline fn getTempAllocator() std.mem.Allocator {
    return memory_pool.child_allocator;
}

var loaded_modules: std.ArrayList(LleModule) = undefined;
var module_name_to_index: std.StringHashMap(usize) = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    memory_pool = std.heap.ArenaAllocator.init(allocator);

    loaded_modules = std.ArrayList(LleModule).init(memory_pool.allocator());
    module_name_to_index = std.StringHashMap(usize).init(memory_pool.allocator());
}

pub fn loadAllDependencies() !void {
    if (loaded_modules.items[0].dependencies) |first_module_dependencies| {
        var node_allocator = std.heap.ArenaAllocator.init(getTempAllocator());
        defer node_allocator.deinit();

        var stack = std.SinglyLinkedList([]const u8){};

        var already_loaded = std.StringHashMap(void).init(getTempAllocator());
        defer already_loaded.deinit();

        for (first_module_dependencies) |name| {
            var new_node = try node_allocator.allocator().create(@TypeOf(stack).Node);
            new_node.data = name;
            stack.prepend(new_node);
        }

        var current_node = stack.popFirst();
        while (current_node) |node| {
            defer current_node = stack.popFirst();

            var full_dependency_path = try searchForModuleFile(node.data, getTempAllocator());
            defer getTempAllocator().free(full_dependency_path);

            if (already_loaded.contains(node.data)) {
                continue;
            }

            const module = try loadFile(full_dependency_path);

            if (module.dependencies) |dependencies| {
                for (dependencies) |name| {
                    var new_node = try node_allocator.allocator().create(@TypeOf(stack).Node);
                    new_node.data = name;
                    stack.prepend(new_node);
                }
            }

            try already_loaded.put(node.data, {});
        }
    }
}

/// Registers LLE Symbols into the global Symbol table
pub fn registerGlobalLleSymbols() !void {
    // Allow Global symbols to override Weak symbols.
    try registerLleSymbolsForBinding(elf.STB_WEAK);
    try registerLleSymbolsForBinding(elf.STB_GLOBAL);
}

fn hleStub() callconv(.SysV) void {
    // TODO: Generate stubs for each non-loaded function and make it log the symbol name.
    std.debug.panic("HLE Function not implemented!", .{});
}

fn registerLleSymbolsForBinding(comptime binding: comptime_int) !void {
    for (loaded_modules.items) |module| {
        for (module.raw_symbols) |sym| {
            if (sym.binding == binding and sym.address != null) {
                var sym_name: []const u8 = sym.name;
                if (sym.is_encoded) {
                    var symbol_name: []const u8 = undefined;
                    var module_name: []const u8 = undefined;
                    var library_name: []const u8 = undefined;
                    sym_name = try nid_util.reconstructFullNid(&module, sym.name, &symbol_name, &module_name, &library_name, memory_pool.allocator());
                    if (!hle_module_loader.shouldLoadLleSymbol(symbol_name, module_name, library_name)) {
                        try symbol_manager.registerSymbol(sym_name, @ptrCast(*const anyopaque, &hleStub));
                        continue;
                    }
                }
                try symbol_manager.registerSymbol(sym_name, sym.address.?);
            }
        }
    }
}

// TODO: Linking
/// Links all loaded Modules together via the global Symbol table
pub fn linkModules() !void {}

pub fn deinit() void {
    for (loaded_modules.items) |*module| {
        std.log.info("Unloading module \"{s}\" (export_name: \"{s}\", is_lib: {any})", .{ module.name, module.export_name, module.is_lib });
        page_util.free(module.data);
    }
    memory_pool.deinit();
}

pub fn getLoadedModules() []const LleModule {
    return loaded_modules.items;
}

pub fn isModuleLoadedFromName(name: []const u8) bool {
    return module_name_to_index.contains(name);
}

pub fn getModuleFromName(name: []const u8) ?*const LleModule {
    if (module_name_to_index.get(name)) |index| {
        return &loaded_modules.items[index];
    }
    return null;
}

/// Caller is responsible for allocated memory.
pub fn searchForModuleFile(name: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (try searchDirectoryForModule(name, root.sce_module_eboot_directory_path, allocator)) |path| {
        return path;
    }
    if (try searchDirectoryForModule(name, root.system_common_exe_directory_path, allocator)) |path| {
        return path;
    }
    if (try searchDirectoryForModule(name, root.system_priv_exe_directory_path, allocator)) |path| {
        return path;
    }
    return try allocator.dupe(u8, name);
}

fn searchDirectoryForModule(name: []const u8, path: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    var dir = std.fs.cwd().openIterableDir(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer dir.close();

    var dir_iter = dir.iterate();
    while (try dir_iter.next()) |entry| {
        if (entry.kind == .File) {
            const name_no_ext = std.fs.path.stem(name);
            if (std.mem.eql(u8, name_no_ext, std.fs.path.stem(entry.name))) {
                return try std.fs.path.join(allocator, &[_][]const u8{ path, entry.name });
            }
        }
    }
    return null;
}

/// Load either a SELF or OELF file as a Kernel Module.
pub fn loadFile(path: []const u8) !*const LleModule {
    var file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => {
            std.log.err("Couldn't load Module \"{s}\", please make sure you have the PS4 firmware system directory inside the directory with the executable.", .{path});
            return e;
        },
        else => return e,
    };
    defer file.close();
    return load(file, std.fs.path.stem(path));
}

/// Load either a SELF or OELF byte stream as a Kernel Module.
pub fn load(stream: anytype, name: []const u8) !*const LleModule {
    const StreamType = @TypeOf(stream);

    comptime {
        std.debug.assert(@hasDecl(StreamType, "seekableStream"));
        std.debug.assert(@hasDecl(StreamType, "reader"));
    }

    if (getModuleFromName(name)) |mod| {
        std.log.debug("Trying to load Module \"{s}\" but it is already loaded, retrieving instead.", .{name});
        return mod;
    }

    const module_index = loaded_modules.items.len;
    try loaded_modules.append(.{});
    var mod = &loaded_modules.items[module_index];

    var elf_data: oelf.Data = undefined;

    try stream.seekableStream().seekTo(0);

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

        var oelf_data: []align(@alignOf(oelf.Header)) u8 = undefined;
        if (std.mem.eql(u8, &magic, &ps4_self.SELF_MAGIC)) {
            oelf_data = try ps4_self.toOElf(stream, getTempAllocator());
        } else if (std.mem.eql(u8, &magic, &oelf.ELF_MAGIC)) {
            const file_size = try stream.seekableStream().getEndPos();
            oelf_data = try getTempAllocator().alignedAlloc(u8, @alignOf(oelf.Header), file_size);
            try stream.reader().readNoEof(oelf_data);
        } else {
            return LoadError.InvalidSelfOrOElf;
        }

        elf_data = try oelf.parse(oelf_data, getTempAllocator());
    }
    defer elf_data.deinit();
    if (elf_data.mapped_size == 0) return LoadError.NothingToLoad;
    if (elf_data.export_modules == null) return LoadError.NoModuleInfo;

    mod.is_lib = elf_data.header.type == oelf.ET_SCE_DYNAMIC;

    // Map executable pages into memory
    mod.data = try page_util.alloc(elf_data.mapped_size, .{ .read = true, .write = true, .execute = true });

    // Find addresses of the init function, the process parameter data, and the entry point function
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

    // Copy name data
    mod.export_name = try memory_pool.allocator().dupe(u8, elf_data.export_modules.?[0].name);
    mod.name = try memory_pool.allocator().dupe(u8, name);
    try module_name_to_index.put(mod.name, module_index);

    // Copy symbol data
    mod.local_symbol_table = std.StringHashMap(?*anyopaque).init(memory_pool.allocator());

    mod.raw_symbols = try memory_pool.allocator().alloc(LleModule.RawSymbolInfo, elf_data.symbol_table.len);
    for (@constCast(mod.raw_symbols), 0..) |*sym, i| {
        const elf_sym = &elf_data.symbol_table[i];
        sym.name = try memory_pool.allocator().dupe(u8, elf_data.getStringFromTable(elf_sym.st_name));

        sym.is_encoded = nid_util.isEncodedSymbol(sym.name);
        sym.type = elf_sym.st_type();
        sym.binding = elf_sym.st_bind();

        if (elf_sym.st_value != 0) {
            sym.address = @ptrCast(*anyopaque, &mod.data[elf_sym.st_value]);
        } else sym.address = null;

        if (sym.binding == elf.STB_LOCAL) try mod.local_symbol_table.put(sym.name, sym.address);
    }

    if (elf_data.needed_files) |needed| {
        mod.dependencies = try memory_pool.allocator().alloc([]const u8, needed.len);
        for (needed, 0..) |needed_file_name, i| {
            mod.dependencies.?[i] = try memory_pool.allocator().dupe(u8, needed_file_name);
        }
    }

    mod.module_id_to_name = std.AutoHashMap(u16, []const u8).init(memory_pool.allocator());
    mod.library_id_to_name = std.AutoHashMap(u16, []const u8).init(memory_pool.allocator());

    if (elf_data.import_modules) |import| {
        for (import) |ref| {
            if (ref.value.bits.id == 0) {
                return LoadError.ImportModuleIdNotDefined;
            }
            try mod.module_id_to_name.put(ref.value.bits.id, try memory_pool.allocator().dupe(u8, ref.name));
        }
    }

    if (elf_data.import_libraries) |import| {
        for (import) |ref| {
            try mod.library_id_to_name.put(ref.value.bits.id, try memory_pool.allocator().dupe(u8, ref.name));
        }
    }

    std.log.info("Loaded module \"{s}\" (export_name: \"{s}\", {d} bytes, is_lib: {any}, local symbols: {d})", .{
        mod.name,
        mod.export_name,
        mod.data.len,
        mod.is_lib,
        mod.local_symbol_table.unmanaged.size,
    });
    return mod;
}

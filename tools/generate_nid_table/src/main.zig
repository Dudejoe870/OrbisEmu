// NID lookup table source generator
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
const yazap = @import("yazap");
const json = std.json;

pub var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const allocator = gpa.allocator();

const header =
    \\// NID lookup table
    \\//
    \\// ******************************************************************
    \\// * DO NOT EDIT... GENERATED BY "generate_nid_table"               *
    \\// * YOU CAN UPDATE THIS FILE BY USING "zig build generate-sources" *
    \\// * IF PS4LIBDOC HAS UPDATED                                       *
    \\// ******************************************************************
    \\//
    \\// OrbisEmu is an experimental PS4 GPU Emulator and Orbis compatibility layer for the Windows and Linux operating systems under the x86_64 CPU architecture.
    \\// Copyright (C) 2023  John Clemis
    \\//
    \\// This program is free software: you can redistribute it and/or modify
    \\// it under the terms of the GNU General Public License as published by
    \\// the Free Software Foundation, either version 3 of the License, or
    \\// (at your option) any later version.
    \\//
    \\// This program is distributed in the hope that it will be useful,
    \\// but WITHOUT ANY WARRANTY; without even the implied warranty of
    \\// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    \\// GNU General Public License for more details.
    \\//
    \\// You should have received a copy of the GNU General Public License
    \\// along with this program.  If not, see <https://www.gnu.org/licenses/>.
    \\
    \\const std = @import("std");
    \\
    \\pub fn nidToSymbolName(nid: []const u8) []const u8 {
    \\    if (nid_table.get(nid)) |symbol_name| {
    \\        return symbol_name;
    \\    }
    \\    return nid;
    \\}
    \\
    \\const nid_table = std.ComptimeStringMap([]const u8, .{
    \\
;

const footer =
    \\}){};
    \\
;

pub fn main() !u8 {
    defer _ = gpa.deinit();

    var app = yazap.App.init(allocator, "generate_nid_table", "Generates a Zig source file for NID to Symbol name mapping.");
    defer app.deinit();

    var root_cmd = app.rootCommand();
    try root_cmd.addArg(yazap.flag.argOne("input-dir", 'i', "Path to ps4libdoc folder (https://github.com/idc/ps4libdoc)."));
    try root_cmd.addArg(yazap.flag.argOne("output", 'o', "Path to output Zig source file."));

    const args = try app.parseProcess();

    if (!args.hasArgs()) {
        try app.displayHelp();
        return 1;
    }

    if (args.valueOf("input-dir")) |input_path| {
        if (args.valueOf("output")) |output_path| {
            var output_file = try std.fs.cwd().createFile(output_path, .{});
            defer output_file.close();

            var input_dir = try std.fs.cwd().openDir(input_path, .{});
            defer input_dir.close();

            var system_common = try input_dir.openIterableDir("system/common/lib", .{});
            var system_priv = try input_dir.openIterableDir("system/priv/lib", .{});
            defer system_common.close();
            defer system_priv.close();

            var system_common_iter = system_common.iterate();
            var system_priv_iter = system_priv.iterate();

            _ = try output_file.write(header);
            try parseJsonsInDirectory(&output_file, &system_common_iter);
            try parseJsonsInDirectory(&output_file, &system_priv_iter);
            _ = try output_file.write(footer);
        } else {
            try app.displayHelp();
            return 1;
        }
    } else {
        try app.displayHelp();
        return 1;
    }

    return 0;
}

fn parseJsonsInDirectory(output: *std.fs.File, directory_iter: *std.fs.IterableDir.Iterator) !void {
    while (try directory_iter.next()) |dir_entry| {
        if (dir_entry.kind == .File) {
            var json_file = try directory_iter.dir.openFile(dir_entry.name, .{});
            defer json_file.close();

            var subtract_from_size: usize = 3;
            var utf_bom: [3]u8 = undefined;
            try json_file.reader().readNoEof(&utf_bom);
            if (!std.mem.eql(u8, &utf_bom, &[3]u8{ 0xEF, 0xBB, 0xBF })) {
                try json_file.seekTo(0);
                subtract_from_size = 0;
            }

            const json_file_size = try json_file.getEndPos() - subtract_from_size;
            var json_string = try allocator.alloc(u8, json_file_size);
            defer allocator.free(json_string);
            try json_file.reader().readNoEof(json_string);

            try parseJson(output, json_string);
        }
    }
}

fn parseJson(output: *std.fs.File, json_string: []const u8) !void {
    var buf: [1024]u8 = undefined;

    var json_parser = json.Parser.init(allocator, false);
    defer json_parser.deinit();
    var json_data = try json_parser.parse(json_string);
    defer json_data.deinit();

    var json_object = &json_data.root.Object;
    var modules_array = &json_object.get("modules").?.Array;
    for (modules_array.items) |module| {
        const module_object = &module.Object;
        var library_array = &module_object.get("libraries").?.Array;
        for (library_array.items) |library| {
            const library_object = &library.Object;
            if (library_object.get("is_export").?.Bool) {
                const symbol_array = &library_object.get("symbols").?.Array;
                for (symbol_array.items) |symbol| {
                    const symbol_object = &symbol.Object;
                    const name = symbol_object.get("name").?;
                    if (name == .String) {
                        const source_line = try std.fmt.bufPrint(buf[0..], "    .{{ \"{s}\", \"{s}\" }},\n", .{ symbol_object.get("encoded_id").?.String, name.String });
                        _ = try output.write(source_line);
                    }
                }
            }
        }
    }
}
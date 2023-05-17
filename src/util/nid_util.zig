// Encoded NID Symbol Name Utility
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

const nid_table = root.nid_table;
const lle_module_loader = root.lle_module_loader;

pub fn isEncodedSymbol(symbol: []const u8) bool {
    return symbol.len == 15 and symbol[11] == '#' and symbol[13] == '#';
}

pub const ReconstructNidError = error{
    InvalidNid,
};

/// Caller is responsible for allocated memory.
pub fn reconstructFullNid(encoded_nid: []const u8, out_symbol_name: ?*[]const u8, out_module_name: ?*[]const u8, out_library_name: ?*[]const u8, allocator: std.mem.Allocator) ![]const u8 {
    var nid_components: [3][]const u8 = undefined;

    var encoded_nid_iter = std.mem.split(u8, encoded_nid, "#");
    var i: usize = 0;
    while (encoded_nid_iter.next()) |component| {
        if (i >= 3) return ReconstructNidError.InvalidNid;
        nid_components[i] = component;
        i += 1;
    }

    const decoded_symbol_name = nid_table.nidToSymbolName(nid_components[0]);

    const decoded_module_id = @truncate(u16, try decodeValue(nid_components[1]));
    var module_name = nid_components[1];
    if (lle_module_loader.getModuleNameFromId(decoded_module_id)) |name| {
        module_name = name;
    }

    const decoded_library_id = @truncate(u16, try decodeValue(nid_components[2]));
    var library_name = nid_components[2];
    if (lle_module_loader.getLibraryNameFromId(decoded_library_id)) |name| {
        library_name = name;
    }

    var result = try std.fmt.allocPrint(allocator, "{s}#{s}#{s}", .{ decoded_symbol_name, module_name, library_name });
    if (out_symbol_name) |out| {
        out.* = result[0..decoded_symbol_name.len];
    }
    if (out_module_name) |out| {
        out.* = result[decoded_symbol_name.len..][0..module_name.len];
    }
    if (out_library_name) |out| {
        out.* = result[decoded_symbol_name.len + module_name.len ..][0..library_name.len];
    }
    return result;
}

pub const DecodeValueError = error{
    InvalidEncodedValue,
};

fn decodeValue(encoded_str: []const u8) !u64 {
    const max_encoded_length = 11;
    if (encoded_str.len > max_encoded_length) {
        return DecodeValueError.InvalidEncodedValue;
    }

    const codes = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-";

    var value: u64 = 0;
    for (encoded_str) |c| {
        var index: usize = 0;
        var found_index: bool = false;
        for (codes) |code_c| {
            if (c == code_c) {
                found_index = true;
                break;
            }
            index += 1;
        }
        if (!found_index) return DecodeValueError.InvalidEncodedValue;

        if (index < max_encoded_length - 1) {
            value <<= 6;
            value |= index;
        } else {
            value <<= 4;
            value |= (index >> 2);
        }
    }
    return value;
}

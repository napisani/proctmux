const std = @import("std");

const KeySequence = struct {
    bytes: []const u8,
    key: []const u8,
};

const escape_sequences = [_]KeySequence{
    .{ .bytes = "\x1b[1;5A", .key = "ctrl+up" },
    .{ .bytes = "\x1b[1;5B", .key = "ctrl+down" },
    .{ .bytes = "\x1b[1;5C", .key = "ctrl+right" },
    .{ .bytes = "\x1b[1;5D", .key = "ctrl+left" },
    .{ .bytes = "\x1b[5A", .key = "ctrl+up" },
    .{ .bytes = "\x1b[5B", .key = "ctrl+down" },
    .{ .bytes = "\x1b[15~", .key = "f5" },
    .{ .bytes = "\x1b[17~", .key = "f6" },
    .{ .bytes = "\x1b[18~", .key = "f7" },
    .{ .bytes = "\x1b[19~", .key = "f8" },
    .{ .bytes = "\x1b[20~", .key = "f9" },
    .{ .bytes = "\x1b[21~", .key = "f10" },
    .{ .bytes = "\x1b[23~", .key = "f11" },
    .{ .bytes = "\x1b[24~", .key = "f12" },
    .{ .bytes = "\x1b[1~", .key = "home" },
    .{ .bytes = "\x1b[2~", .key = "insert" },
    .{ .bytes = "\x1b[3~", .key = "delete" },
    .{ .bytes = "\x1b[4~", .key = "end" },
    .{ .bytes = "\x1b[5~", .key = "pageup" },
    .{ .bytes = "\x1b[6~", .key = "pagedown" },
    .{ .bytes = "\x1b[A", .key = "up" },
    .{ .bytes = "\x1b[B", .key = "down" },
    .{ .bytes = "\x1b[C", .key = "right" },
    .{ .bytes = "\x1b[D", .key = "left" },
    .{ .bytes = "\x1b[F", .key = "end" },
    .{ .bytes = "\x1b[H", .key = "home" },
    .{ .bytes = "\x1bOP", .key = "f1" },
    .{ .bytes = "\x1bOQ", .key = "f2" },
    .{ .bytes = "\x1bOR", .key = "f3" },
    .{ .bytes = "\x1bOS", .key = "f4" },
};

const control_key_names = buildControlKeyNames();

fn buildControlKeyNames() [27][]const u8 {
    comptime {
        var names: [27][]const u8 = undefined;
        names[0] = "";
        for (names[1..], 0..) |*name, index| {
            const letter: u8 = 'a' + @as(u8, @intCast(index));
            name.* = std.fmt.comptimePrint("ctrl+{c}", .{letter});
        }
        return names;
    }
}

pub fn keyForInput(bytes: []const u8, index: *usize, scratch: *[1]u8) ?[]const u8 {
    const current = index.*;
    const remaining = bytes[current..];

    for (escape_sequences) |sequence| {
        if (std.mem.startsWith(u8, remaining, sequence.bytes)) {
            index.* += sequence.bytes.len;
            return sequence.key;
        }
    }

    if (keyForModifiedCharacterSequence(remaining)) |parsed| {
        index.* += parsed.len;
        return parsed.key;
    }

    index.* += 1;
    return keyForByte(bytes[current], scratch);
}

const ParsedKey = struct {
    key: []const u8,
    len: usize,
};

fn keyForModifiedCharacterSequence(bytes: []const u8) ?ParsedKey {
    return keyForCsiUModifiedCharacter(bytes) orelse keyForXtermModifiedCharacter(bytes);
}

fn keyForCsiUModifiedCharacter(bytes: []const u8) ?ParsedKey {
    if (!std.mem.startsWith(u8, bytes, "\x1b[")) return null;
    const end = std.mem.indexOfScalar(u8, bytes, 'u') orelse return null;
    const body = bytes[2..end];

    var parts = std.mem.splitScalar(u8, body, ';');
    const codepoint_text = parts.next() orelse return null;
    const modifier_text = parts.next() orelse return null;
    if (parts.next() != null) return null;

    return keyForModifiedCharacterParts(codepoint_text, modifier_text, end + 1);
}

fn keyForXtermModifiedCharacter(bytes: []const u8) ?ParsedKey {
    if (!std.mem.startsWith(u8, bytes, "\x1b[27;")) return null;
    const end = std.mem.indexOfScalar(u8, bytes, '~') orelse return null;
    const body = bytes[2..end];

    var parts = std.mem.splitScalar(u8, body, ';');
    const marker_text = parts.next() orelse return null;
    if (!std.mem.eql(u8, marker_text, "27")) return null;
    const modifier_text = parts.next() orelse return null;
    const codepoint_text = parts.next() orelse return null;
    if (parts.next() != null) return null;

    return keyForModifiedCharacterParts(codepoint_text, modifier_text, end + 1);
}

fn keyForModifiedCharacterParts(
    codepoint_text: []const u8,
    modifier_text: []const u8,
    len: usize,
) ?ParsedKey {
    const modifier = std.fmt.parseInt(u8, modifier_text, 10) catch return null;
    if (modifier == 0 or ((modifier - 1) & 4) == 0) return null;

    const codepoint = std.fmt.parseInt(u21, codepoint_text, 10) catch return null;
    const key = controlKeyNameForCodepoint(codepoint) orelse return null;
    return .{ .key = key, .len = len };
}

fn controlKeyNameForCodepoint(codepoint: u21) ?[]const u8 {
    if (codepoint > 0 and codepoint < control_key_names.len) return control_key_names[@intCast(codepoint)];
    if (codepoint >= 'a' and codepoint <= 'z') return control_key_names[@intCast(codepoint - 'a' + 1)];
    if (codepoint >= 'A' and codepoint <= 'Z') return control_key_names[@intCast(codepoint - 'A' + 1)];
    return null;
}

fn keyForByte(byte: u8, scratch: *[1]u8) ?[]const u8 {
    switch (byte) {
        '\r' => return "enter",
        '\t' => return "tab",
        0x1b => return "esc",
        0x08 => return "backspace",
        0x7f => return "delete",
        else => {},
    }

    if (byte > 0 and byte < control_key_names.len) return control_key_names[byte];

    if (byte >= 0x20 and byte <= 0x7e) {
        scratch[0] = byte;
        return scratch[0..];
    }
    return null;
}

test "key input maps arrow and ctrl-arrow sequences" {
    var index: usize = 0;
    var scratch: [1]u8 = undefined;

    try std.testing.expectEqualStrings("right", keyForInput("\x1b[C", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 3), index);

    index = 0;
    try std.testing.expectEqualStrings("left", keyForInput("\x1b[D", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 3), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+up", keyForInput("\x1b[1;5A", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 6), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+down", keyForInput("\x1b[1;5B", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 6), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+up", keyForInput("\x1b[5A", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 4), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+down", keyForInput("\x1b[5B", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 4), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+right", keyForInput("\x1b[1;5C", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 6), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+left", keyForInput("\x1b[1;5D", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 6), index);
}

test "key input maps modified character escape sequences" {
    var index: usize = 0;
    var scratch: [1]u8 = undefined;

    try std.testing.expectEqualStrings("ctrl+j", keyForInput("\x1b[106;5u", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 8), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+k", keyForInput("\x1b[107;5u", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 8), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+j", keyForInput("\x1b[74;6u", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 7), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+j", keyForInput("\x1b[27;5;106~", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 11), index);
}

test "key input maps terminal control bytes" {
    var index: usize = 0;
    var scratch: [1]u8 = undefined;

    try std.testing.expectEqualStrings("enter", keyForInput("\r", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 1), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+j", keyForInput("\n", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 1), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+c", keyForInput("\x03", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 1), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+k", keyForInput("\x0b", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 1), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+s", keyForInput("\x13", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 1), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+x", keyForInput("\x18", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 1), index);

    index = 0;
    const ctrl_d = keyForInput("\x04", &index, &scratch);
    try std.testing.expect(ctrl_d != null);
    try std.testing.expectEqualStrings("ctrl+d", ctrl_d.?);
    try std.testing.expectEqual(@as(usize, 1), index);

    index = 0;
    const ctrl_l = keyForInput("\x0c", &index, &scratch);
    try std.testing.expect(ctrl_l != null);
    try std.testing.expectEqualStrings("ctrl+l", ctrl_l.?);
    try std.testing.expectEqual(@as(usize, 1), index);

    index = 0;
    const ctrl_z = keyForInput("\x1a", &index, &scratch);
    try std.testing.expect(ctrl_z != null);
    try std.testing.expectEqualStrings("ctrl+z", ctrl_z.?);
    try std.testing.expectEqual(@as(usize, 1), index);
}

test "key input maps terminal navigation and function sequences" {
    var index: usize = 0;
    var scratch: [1]u8 = undefined;

    try std.testing.expectEqualStrings("home", keyForInput("\x1b[H", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 3), index);

    index = 0;
    try std.testing.expectEqualStrings("end", keyForInput("\x1b[F", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 3), index);

    index = 0;
    try std.testing.expectEqualStrings("insert", keyForInput("\x1b[2~", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 4), index);

    index = 0;
    try std.testing.expectEqualStrings("pageup", keyForInput("\x1b[5~", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 4), index);

    index = 0;
    try std.testing.expectEqualStrings("pagedown", keyForInput("\x1b[6~", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 4), index);

    index = 0;
    try std.testing.expectEqualStrings("f1", keyForInput("\x1bOP", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 3), index);

    index = 0;
    try std.testing.expectEqualStrings("f4", keyForInput("\x1bOS", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 3), index);

    index = 0;
    try std.testing.expectEqualStrings("f5", keyForInput("\x1b[15~", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 5), index);

    index = 0;
    try std.testing.expectEqualStrings("f12", keyForInput("\x1b[24~", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 5), index);
}

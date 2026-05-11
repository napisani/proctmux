const std = @import("std");

const KeySequence = struct {
    bytes: []const u8,
    key: []const u8,
};

const escape_sequences = [_]KeySequence{
    .{ .bytes = "\x1b[1;5C", .key = "ctrl+right" },
    .{ .bytes = "\x1b[1;5D", .key = "ctrl+left" },
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

pub fn keyForInput(bytes: []const u8, index: *usize, scratch: *[1]u8) ?[]const u8 {
    const current = index.*;
    const remaining = bytes[current..];

    for (escape_sequences) |sequence| {
        if (std.mem.startsWith(u8, remaining, sequence.bytes)) {
            index.* += sequence.bytes.len;
            return sequence.key;
        }
    }

    index.* += 1;
    return keyForByte(bytes[current], scratch);
}

fn keyForByte(byte: u8, scratch: *[1]u8) ?[]const u8 {
    switch (byte) {
        '\n', '\r' => return "enter",
        '\t' => return "tab",
        0x1b => return "esc",
        0x03 => return "ctrl+c",
        0x04 => return "ctrl+d",
        0x0c => return "ctrl+l",
        0x17 => return "ctrl+w",
        0x1a => return "ctrl+z",
        0x08 => return "backspace",
        0x7f => return "delete",
        else => {},
    }

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
    try std.testing.expectEqualStrings("ctrl+right", keyForInput("\x1b[1;5C", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 6), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+left", keyForInput("\x1b[1;5D", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 6), index);
}

test "key input maps terminal control bytes" {
    var index: usize = 0;
    var scratch: [1]u8 = undefined;

    try std.testing.expectEqualStrings("ctrl+c", keyForInput("\x03", &index, &scratch).?);
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

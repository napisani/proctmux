//! ANSI-aware test assertions.
//! Rendering tests use these helpers to compare visible text without depending on every escape sequence byte.

const std = @import("std");

pub fn expectEqualPlain(allocator: std.mem.Allocator, expected: []const u8, rendered: []const u8) !void {
    const plain = try strip(allocator, rendered);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings(expected, plain);
}

pub fn expectContainsPlain(allocator: std.mem.Allocator, rendered: []const u8, needle: []const u8) !void {
    const plain = try strip(allocator, rendered);
    defer allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, needle) != null);
}

pub fn strip(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '[') {
            index += 2;
            while (index < text.len and !isAnsiFinalByte(text[index])) : (index += 1) {}
            if (index < text.len) index += 1;
            continue;
        }

        try out.append(text[index]);
        index += 1;
    }

    return out.toOwnedSlice();
}

fn isAnsiFinalByte(byte: u8) bool {
    return byte >= 0x40 and byte <= 0x7e;
}

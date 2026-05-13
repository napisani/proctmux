const std = @import("std");
const vt = @import("ghostty-vt");

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    inner: *Inner,

    const Inner = struct {
        terminal: vt.Terminal,
        stream: vt.TerminalStream,
    };

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !Terminal {
        const inner = try allocator.create(Inner);
        errdefer allocator.destroy(inner);

        inner.terminal = try vt.Terminal.init(allocator, .{
            .cols = @intCast(@max(cols, 1)),
            .rows = @intCast(@max(rows, 1)),
            .max_scrollback = 10_000,
        });
        errdefer inner.terminal.deinit(allocator);

        inner.stream = inner.terminal.vtStream();
        return .{
            .allocator = allocator,
            .inner = inner,
        };
    }

    pub fn deinit(self: *Terminal) void {
        self.inner.stream.deinit();
        self.inner.terminal.deinit(self.allocator);
        self.allocator.destroy(self.inner);
        self.* = undefined;
    }

    pub fn resize(self: *Terminal, cols: u16, rows: u16) !void {
        try self.inner.terminal.resize(
            self.allocator,
            @intCast(@max(cols, 1)),
            @intCast(@max(rows, 1)),
        );
    }

    pub fn write(self: *Terminal, bytes: []const u8) !void {
        self.inner.stream.nextSlice(bytes);
    }

    pub fn renderText(self: *Terminal, allocator: std.mem.Allocator) ![]const u8 {
        const raw = try self.inner.terminal.plainString(allocator);
        defer allocator.free(raw);
        return normalizeRenderedText(allocator, raw);
    }
};

fn normalizeRenderedText(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        try out.appendSlice(trimmed);
        if (lines.index != null) try out.append('\n');
    }

    while (out.items.len > 0) {
        const last = out.items[out.items.len - 1];
        if (last != '\n' and last != ' ' and last != '\t' and last != '\r') break;
        out.shrinkRetainingCapacity(out.items.len - 1);
    }

    return out.toOwnedSlice();
}

test "ghostty vt renders plain text" {
    var term = try Terminal.init(std.testing.allocator, 20, 5);
    defer term.deinit();

    try term.write("hello\r\nworld");
    const rendered = try term.renderText(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("hello\nworld", rendered);
}

test "ghostty vt carriage return replaces current line" {
    var term = try Terminal.init(std.testing.allocator, 20, 3);
    defer term.deinit();

    try term.write("progress 10%\rprogress 90%");
    const rendered = try term.renderText(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("progress 90%", rendered);
}

test "ghostty vt cursor movement updates existing cells" {
    var term = try Terminal.init(std.testing.allocator, 20, 3);
    defer term.deinit();

    try term.write("abc\x1b[2DXY");
    const rendered = try term.renderText(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("aXY", rendered);
}

test "ghostty vt erase line and clear screen remove stale text" {
    var term = try Terminal.init(std.testing.allocator, 20, 4);
    defer term.deinit();

    try term.write("stale text\r\x1b[Kfresh");
    const erased = try term.renderText(std.testing.allocator);
    defer std.testing.allocator.free(erased);
    try std.testing.expectEqualStrings("fresh", erased);

    try term.write("\x1b[2J\x1b[Hclear");
    const cleared = try term.renderText(std.testing.allocator);
    defer std.testing.allocator.free(cleared);
    try std.testing.expectEqualStrings("clear", cleared);
}

test "ghostty vt alternate screen restores main screen" {
    var term = try Terminal.init(std.testing.allocator, 20, 4);
    defer term.deinit();

    try term.write("main\x1b[?1049halt\x1b[Halt\x1b[?1049l");
    const rendered = try term.renderText(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("main", rendered);
}

test "ghostty vt keeps parser state across split escape writes" {
    var term = try Terminal.init(std.testing.allocator, 20, 3);
    defer term.deinit();

    try term.write("before\r\x1b[");
    try term.write("2Kafter");
    const rendered = try term.renderText(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("after", rendered);
}

test "ghostty vt resize updates visible viewport" {
    var term = try Terminal.init(std.testing.allocator, 10, 4);
    defer term.deinit();

    try term.write("one\r\ntwo\r\nthree\r\nfour");
    try term.resize(10, 2);
    const rendered = try term.renderText(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("three\nfour", rendered);
}

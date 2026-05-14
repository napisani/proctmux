const std = @import("std");
const vt = @import("ghostty-vt");

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    inner: *Inner,

    const Inner = struct {
        terminal: vt.Terminal,
        stream: vt.TerminalStream,
        render_state: vt.RenderState = .empty,
    };

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !Terminal {
        const inner = try allocator.create(Inner);
        errdefer allocator.destroy(inner);

        inner.render_state = .empty;
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
        self.inner.render_state.deinit(self.allocator);
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
        try self.inner.render_state.update(self.allocator, &self.inner.terminal);
        return renderStateText(allocator, &self.inner.render_state);
    }
};

fn renderStateText(allocator: std.mem.Allocator, state: *const vt.RenderState) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    const row_data = state.row_data.slice();
    const row_cells = row_data.items(.cells);
    const visible_rows = visibleRowCount(row_cells);

    for (row_cells[0..visible_rows], 0..) |cells, row_index| {
        if (row_index != 0) try out.append('\n');
        try appendRenderedRow(&out, cells);
    }

    return out.toOwnedSlice();
}

fn visibleRowCount(rows: []const std.MultiArrayList(vt.RenderState.Cell)) usize {
    var count = rows.len;
    while (count > 0) {
        if (visibleCellCount(rows[count - 1]) != 0) break;
        count -= 1;
    }
    return count;
}

fn visibleCellCount(cells: std.MultiArrayList(vt.RenderState.Cell)) usize {
    const slice = cells.slice();
    const raw_cells = slice.items(.raw);
    var count = raw_cells.len;
    while (count > 0) {
        const raw = raw_cells[count - 1];
        if (raw.wide != .spacer_tail and hasVisibleText(raw)) break;
        count -= 1;
    }
    return count;
}

fn hasVisibleText(raw: anytype) bool {
    const cp = raw.codepoint();
    return cp != 0 and cp != ' ' and cp != '\t' and cp != '\r';
}

fn appendRenderedRow(out: *std.array_list.Managed(u8), cells: std.MultiArrayList(vt.RenderState.Cell)) !void {
    const slice = cells.slice();
    const raw_cells = slice.items(.raw);
    const graphemes = slice.items(.grapheme);
    const styles = slice.items(.style);
    const visible_cells = visibleCellCount(cells);

    var current_style: vt.Style = .{};
    var style_active = false;

    for (0..visible_cells) |index| {
        const raw = raw_cells[index];
        if (raw.wide == .spacer_tail) continue;

        const target_style = styleForCell(raw, styles, index);
        if (!target_style.eql(current_style)) {
            try appendStyleTransition(out, target_style);
            current_style = target_style;
            style_active = !current_style.default();
        }

        const cp = raw.codepoint();
        if (cp == 0) {
            try out.append(' ');
            continue;
        }

        try out.writer().print("{u}", .{cp});
        if (raw.hasGrapheme()) {
            for (graphemes[index]) |grapheme_cp| {
                try out.writer().print("{u}", .{grapheme_cp});
            }
        }
    }

    if (style_active) try out.appendSlice("\x1b[0m");
}

fn styleForCell(raw: anytype, styles: []const vt.Style, index: usize) vt.Style {
    return switch (raw.content_tag) {
        .bg_color_palette => .{ .bg_color = .{ .palette = raw.content.color_palette } },
        .bg_color_rgb => .{ .bg_color = .{ .rgb = .{
            .r = raw.content.color_rgb.r,
            .g = raw.content.color_rgb.g,
            .b = raw.content.color_rgb.b,
        } } },
        else => if (raw.hasStyling()) styles[index] else .{},
    };
}

fn appendStyleTransition(out: *std.array_list.Managed(u8), style: vt.Style) !void {
    try out.appendSlice("\x1b[0m");
    try appendStyle(out, style);
}

fn appendStyle(out: *std.array_list.Managed(u8), style: vt.Style) !void {
    if (style.default()) return;

    if (style.flags.bold) try appendSgr(out, 1);
    if (style.flags.faint) try appendSgr(out, 2);
    if (style.flags.italic) try appendSgr(out, 3);
    if (style.flags.blink) try appendSgr(out, 5);
    if (style.flags.inverse) try appendSgr(out, 7);
    if (style.flags.invisible) try appendSgr(out, 8);
    if (style.flags.strikethrough) try appendSgr(out, 9);
    if (style.flags.overline) try appendSgr(out, 53);
    switch (style.flags.underline) {
        .none => {},
        .single => try appendSgr(out, 4),
        .double => try out.appendSlice("\x1b[4:2m"),
        .curly => try out.appendSlice("\x1b[4:3m"),
        .dotted => try out.appendSlice("\x1b[4:4m"),
        .dashed => try out.appendSlice("\x1b[4:5m"),
    }

    try appendColor(out, style.fg_color, .foreground);
    try appendColor(out, style.bg_color, .background);
    try appendColor(out, style.underline_color, .underline);
}

const ColorTarget = enum {
    foreground,
    background,
    underline,
};

fn appendColor(out: *std.array_list.Managed(u8), color: vt.Style.Color, target: ColorTarget) !void {
    switch (color) {
        .none => {},
        .palette => |idx| try appendPaletteColor(out, idx, target),
        .rgb => |rgb| try appendRgbColor(out, rgb, target),
    }
}

fn appendPaletteColor(out: *std.array_list.Managed(u8), idx: u8, target: ColorTarget) !void {
    switch (target) {
        .foreground => try appendPaletteSgr(out, idx, 30, 90, 38),
        .background => try appendPaletteSgr(out, idx, 40, 100, 48),
        .underline => try out.writer().print("\x1b[58;5;{}m", .{idx}),
    }
}

fn appendPaletteSgr(
    out: *std.array_list.Managed(u8),
    idx: u8,
    normal_base: u8,
    bright_base: u8,
    extended_prefix: u8,
) !void {
    if (idx < 8) {
        try appendSgr(out, normal_base + idx);
    } else if (idx < 16) {
        try appendSgr(out, bright_base + idx - 8);
    } else {
        try out.writer().print("\x1b[{};5;{}m", .{ extended_prefix, idx });
    }
}

fn appendRgbColor(out: *std.array_list.Managed(u8), rgb: anytype, target: ColorTarget) !void {
    const prefix: u8 = switch (target) {
        .foreground => 38,
        .background => 48,
        .underline => 58,
    };
    try out.writer().print("\x1b[{};2;{};{};{}m", .{ prefix, rgb.r, rgb.g, rgb.b });
}

fn appendSgr(out: *std.array_list.Managed(u8), code: u8) !void {
    try out.writer().print("\x1b[{}m", .{code});
}

test "ghostty vt renders plain text" {
    var term = try Terminal.init(std.testing.allocator, 20, 5);
    defer term.deinit();

    try term.write("hello\r\nworld");
    const rendered = try term.renderText(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("hello\nworld", rendered);
}

test "ghostty vt preserves ANSI foreground colors in rendered text" {
    var term = try Terminal.init(std.testing.allocator, 40, 3);
    defer term.deinit();

    try term.write("\x1b[31mRed\x1b[0m \x1b[32mGreen");
    const rendered = try term.renderText(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[31mRed") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[32mGreen") != null);
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

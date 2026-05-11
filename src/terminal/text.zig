const std = @import("std");

pub fn render(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var screen = try TerminalText.init(allocator);
    defer screen.deinit();

    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte == 0x1b) {
            try consumeEscape(&screen, bytes, &index);
            continue;
        }
        if (byte == '\r') {
            if (index + 1 < bytes.len and bytes[index + 1] == '\n') {
                try screen.newline();
                index += 2;
                continue;
            }
            screen.carriageReturn();
            index += 1;
            continue;
        }
        if (byte == '\n') {
            try screen.newline();
            index += 1;
            continue;
        }
        if (byte == '\t' or byte >= 0x20) {
            try screen.writeByte(byte);
        }
        index += 1;
    }

    return screen.toOwnedSlice();
}

const TerminalText = struct {
    allocator: std.mem.Allocator,
    lines: std.array_list.Managed(std.array_list.Managed(Cell)),
    styles: std.array_list.Managed([]const u8),
    saved_main: ?TerminalSnapshot,
    row: usize,
    col: usize,
    current_style: usize,

    fn init(allocator: std.mem.Allocator) !TerminalText {
        var self = TerminalText{
            .allocator = allocator,
            .lines = std.array_list.Managed(std.array_list.Managed(Cell)).init(allocator),
            .styles = std.array_list.Managed([]const u8).init(allocator),
            .saved_main = null,
            .row = 0,
            .col = 0,
            .current_style = 0,
        };
        errdefer self.deinit();
        try self.styles.append("");
        try self.lines.append(std.array_list.Managed(Cell).init(allocator));
        return self;
    }

    fn deinit(self: *TerminalText) void {
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.deinit();
        for (self.styles.items[1..]) |style| {
            self.allocator.free(style);
        }
        self.styles.deinit();
        if (self.saved_main) |*saved| {
            saved.deinit();
        }
    }

    fn ensureRow(self: *TerminalText, row: usize) !void {
        while (self.lines.items.len <= row) {
            try self.lines.append(std.array_list.Managed(Cell).init(self.allocator));
        }
    }

    fn writeByte(self: *TerminalText, byte: u8) !void {
        try self.ensureRow(self.row);
        var line = &self.lines.items[self.row];
        while (line.items.len < self.col) {
            try line.append(.{ .byte = ' ', .style = 0 });
        }
        if (self.col < line.items.len) {
            line.items[self.col] = .{ .byte = byte, .style = self.current_style };
        } else {
            try line.append(.{ .byte = byte, .style = self.current_style });
        }
        self.col += 1;
    }

    fn carriageReturn(self: *TerminalText) void {
        self.col = 0;
    }

    fn newline(self: *TerminalText) !void {
        self.row += 1;
        self.col = 0;
        try self.ensureRow(self.row);
    }

    fn clear(self: *TerminalText) !void {
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.clearRetainingCapacity();
        self.row = 0;
        self.col = 0;
        try self.lines.append(std.array_list.Managed(Cell).init(self.allocator));
    }

    fn enterAlternateScreen(self: *TerminalText) !void {
        if (self.saved_main) |*saved| {
            saved.deinit();
            self.saved_main = null;
        }
        self.saved_main = try TerminalSnapshot.clone(self.allocator, self.lines, self.row, self.col, self.current_style);
        try self.clear();
    }

    fn exitAlternateScreen(self: *TerminalText) void {
        if (self.saved_main) |*saved| {
            for (self.lines.items) |*line| {
                line.deinit();
            }
            self.lines.deinit();

            self.lines = saved.lines;
            self.row = saved.row;
            self.col = saved.col;
            self.current_style = saved.current_style;
            self.saved_main = null;
        }
    }

    fn moveLeft(self: *TerminalText, count: usize) void {
        if (count > self.col) {
            self.col = 0;
        } else {
            self.col -= count;
        }
    }

    fn moveRight(self: *TerminalText, count: usize) void {
        self.col += count;
    }

    fn moveUp(self: *TerminalText, count: usize) void {
        if (count > self.row) {
            self.row = 0;
        } else {
            self.row -= count;
        }
    }

    fn moveDown(self: *TerminalText, count: usize) !void {
        self.row += count;
        try self.ensureRow(self.row);
    }

    fn moveTo(self: *TerminalText, row: usize, col: usize) !void {
        self.row = if (row == 0) 0 else row - 1;
        self.col = if (col == 0) 0 else col - 1;
        try self.ensureRow(self.row);
    }

    fn eraseLine(self: *TerminalText, mode: usize) !void {
        try self.ensureRow(self.row);
        var line = &self.lines.items[self.row];
        switch (mode) {
            0 => {
                if (self.col < line.items.len) {
                    line.shrinkRetainingCapacity(self.col);
                }
            },
            1 => {
                const end = @min(self.col + 1, line.items.len);
                for (line.items[0..end]) |*cell| {
                    cell.* = .{ .byte = ' ', .style = 0 };
                }
                trimManagedLineRight(line);
            },
            2 => line.clearRetainingCapacity(),
            else => {},
        }
    }

    fn setGraphicRendition(self: *TerminalText, params: []const u8) !void {
        if (isSgrReset(params)) {
            self.current_style = 0;
            return;
        }

        for (self.styles.items, 0..) |style, index| {
            if (std.mem.eql(u8, style, params)) {
                self.current_style = index;
                return;
            }
        }

        const owned = try self.allocator.dupe(u8, params);
        errdefer self.allocator.free(owned);
        try self.styles.append(owned);
        self.current_style = self.styles.items.len - 1;
    }

    fn toOwnedSlice(self: *TerminalText) ![]u8 {
        var out = std.array_list.Managed(u8).init(self.allocator);
        errdefer out.deinit();

        var active_style: usize = 0;
        for (self.lines.items, 0..) |line, line_index| {
            const end = trimmedLineEnd(line.items);
            for (line.items[0..end]) |cell| {
                if (cell.style != active_style) {
                    try self.appendStyle(&out, cell.style);
                    active_style = cell.style;
                }
                try out.append(cell.byte);
            }
            if (active_style != 0) {
                try self.appendStyle(&out, 0);
                active_style = 0;
            }
            if (line_index + 1 < self.lines.items.len) {
                try out.append('\n');
            }
        }

        return out.toOwnedSlice();
    }

    fn appendStyle(self: *TerminalText, out: *std.array_list.Managed(u8), style: usize) !void {
        if (style == 0) {
            try out.appendSlice("\x1b[0m");
            return;
        }
        try out.writer().print("\x1b[{s}m", .{self.styles.items[style]});
    }
};

const Cell = struct {
    byte: u8,
    style: usize,
};

const TerminalSnapshot = struct {
    lines: std.array_list.Managed(std.array_list.Managed(Cell)),
    row: usize,
    col: usize,
    current_style: usize,

    fn clone(
        allocator: std.mem.Allocator,
        source: std.array_list.Managed(std.array_list.Managed(Cell)),
        row: usize,
        col: usize,
        current_style: usize,
    ) !TerminalSnapshot {
        var lines = std.array_list.Managed(std.array_list.Managed(Cell)).init(allocator);
        errdefer {
            for (lines.items) |*line| {
                line.deinit();
            }
            lines.deinit();
        }

        for (source.items) |source_line| {
            var line = std.array_list.Managed(Cell).init(allocator);
            errdefer line.deinit();
            try line.appendSlice(source_line.items);
            try lines.append(line);
        }

        return .{
            .lines = lines,
            .row = row,
            .col = col,
            .current_style = current_style,
        };
    }

    fn deinit(self: *TerminalSnapshot) void {
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.deinit();
    }
};

fn trimManagedLineRight(line: *std.array_list.Managed(Cell)) void {
    var end = line.items.len;
    while (end > 0 and line.items[end - 1].byte == ' ') {
        end -= 1;
    }
    line.shrinkRetainingCapacity(end);
}

fn trimmedLineEnd(line: []const Cell) usize {
    var end = line.len;
    while (end > 0 and line[end - 1].byte == ' ') {
        end -= 1;
    }
    return end;
}

fn consumeEscape(screen: *TerminalText, bytes: []const u8, index: *usize) !void {
    const start = index.*;
    if (start + 1 >= bytes.len) {
        index.* += 1;
        return;
    }

    const introducer = bytes[start + 1];
    if (introducer == '[') {
        var end = start + 2;
        while (end < bytes.len) : (end += 1) {
            const byte = bytes[end];
            if (byte >= 0x40 and byte <= 0x7e) {
                const params = bytes[start + 2 .. end];
                try applyCsi(screen, byte, params);
                index.* = end + 1;
                return;
            }
        }
        index.* = bytes.len;
        return;
    }

    if (introducer == ']') {
        var end = start + 2;
        while (end < bytes.len) : (end += 1) {
            if (bytes[end] == 0x07) {
                index.* = end + 1;
                return;
            }
            if (bytes[end] == 0x1b and end + 1 < bytes.len and bytes[end + 1] == '\\') {
                index.* = end + 2;
                return;
            }
        }
        index.* = bytes.len;
        return;
    }

    index.* += 2;
}

fn applyCsi(screen: *TerminalText, final: u8, params: []const u8) !void {
    switch (final) {
        'A' => screen.moveUp(csiParam(params, 0, 1)),
        'B' => try screen.moveDown(csiParam(params, 0, 1)),
        'C' => screen.moveRight(csiParam(params, 0, 1)),
        'D' => screen.moveLeft(csiParam(params, 0, 1)),
        'H', 'f' => try screen.moveTo(csiParam(params, 0, 1), csiParam(params, 1, 1)),
        'h' => {
            if (isAlternateScreenMode(params)) {
                try screen.enterAlternateScreen();
            }
        },
        'l' => {
            if (isAlternateScreenMode(params)) {
                screen.exitAlternateScreen();
            }
        },
        'J' => {
            const mode = csiParam(params, 0, 0);
            if (mode == 0 or mode == 2 or mode == 3) {
                try screen.clear();
            }
        },
        'K' => try screen.eraseLine(csiParam(params, 0, 0)),
        'm' => try screen.setGraphicRendition(params),
        else => {},
    }
}

fn csiParam(params: []const u8, param_index: usize, default: usize) usize {
    var current_index: usize = 0;
    var value: usize = 0;
    var has_digit = false;

    for (params) |byte| {
        if (byte >= '0' and byte <= '9') {
            value = value * 10 + byte - '0';
            has_digit = true;
            continue;
        }
        if (byte == ';') {
            if (current_index == param_index) {
                return if (has_digit and value != 0) value else default;
            }
            current_index += 1;
            value = 0;
            has_digit = false;
            continue;
        }
        if (byte == '?') {
            continue;
        }
    }

    if (current_index == param_index) {
        return if (has_digit and value != 0) value else default;
    }
    return default;
}

fn isAlternateScreenMode(params: []const u8) bool {
    if (params.len == 0 or params[0] != '?') return false;

    var modes = std.mem.splitScalar(u8, params[1..], ';');
    while (modes.next()) |mode| {
        if (std.mem.eql(u8, mode, "47") or
            std.mem.eql(u8, mode, "1047") or
            std.mem.eql(u8, mode, "1049"))
        {
            return true;
        }
    }
    return false;
}

fn isSgrReset(params: []const u8) bool {
    if (params.len == 0) return true;

    var current_resets = true;
    var saw_param = false;
    var parts = std.mem.splitScalar(u8, params, ';');
    while (parts.next()) |part| {
        saw_param = true;
        if (part.len == 0 or std.mem.eql(u8, part, "0")) {
            current_resets = true;
        } else {
            current_resets = false;
        }
    }
    return saw_param and current_resets;
}

test "terminal text renderer contains ANSI clear screen sequences" {
    const rendered = try render(std.testing.allocator, "before\x1b[2Jafter\n");
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("after\n", rendered);
}

test "terminal text renderer treats carriage return as line replacement" {
    const rendered = try render(std.testing.allocator, "first\rsecond\r\n");
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("second\n", rendered);
}

test "terminal text renderer handles cursor movement and erase line" {
    const rendered = try render(std.testing.allocator, "abcdef\x1b[3D\x1b[KXYZ\n");
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("abcXYZ\n", rendered);
}

test "terminal text renderer handles absolute cursor positioning" {
    const rendered = try render(std.testing.allocator, "one\nsecond\x1b[1;1Htop\n");
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("top\nsecond", rendered);
}

test "terminal text renderer restores main buffer after alternate screen" {
    const rendered = try render(std.testing.allocator, "main\n\x1b[?1049halt-screen\n\x1b[?1049lback\n");
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("main\nback\n", rendered);
}

test "terminal text renderer preserves SGR styles" {
    const rendered = try render(std.testing.allocator, "\x1b[38;2;12;34;56mstyled\x1b[0m\n");
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\x1b[38;2;12;34;56mstyled\x1b[0m\n", rendered);
}

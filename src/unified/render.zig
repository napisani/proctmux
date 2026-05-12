const std = @import("std");
const domain = @import("../domain/root.zig");
const io = @import("../modes/io.zig");
const primary = @import("../primary/root.zig");
const terminal = @import("../terminal/root.zig");
const tui = @import("../tui/root.zig");
const client_mode = @import("../modes/client.zig");
const child_primary = @import("child_primary.zig");

pub fn child(
    session: *tui.client_session.ClientSession,
    split: *const tui.split_model.Model,
    child_primary_server: *child_primary.ChildPrimary,
    output: io.Output,
) !void {
    try output.writeAll(terminal.repaint.begin_frame);
    try childContent(session, split, child_primary_server, output);
    try writeStatusBar(session, split, output);
    try output.writeAll(terminal.repaint.end_frame);
}

pub fn inProcess(
    session: *tui.client_session.ClientSession,
    split: *const tui.split_model.Model,
    primary_server: *primary.Server,
    output: io.Output,
) !void {
    try output.writeAll(terminal.repaint.begin_frame);
    try inProcessContent(session, split, primary_server, output);
    try writeStatusBar(session, split, output);
    try output.writeAll(terminal.repaint.end_frame);
}

fn writeStatusBar(
    session: *tui.client_session.ClientSession,
    split: *const tui.split_model.Model,
    output: io.Output,
) !void {
    const status = try split.statusBar(session.allocator);
    defer session.allocator.free(status);
    if (status.len > 0) {
        try io.writeTextClearingLineTails(output, status, terminal.repaint.clear_line_tail);
        try output.writeAll("\n");
    }
}

fn childContent(
    session: *tui.client_session.ClientSession,
    split: *const tui.split_model.Model,
    child_primary_server: *child_primary.ChildPrimary,
    output: io.Output,
) !void {
    const placeholder = std.mem.trim(u8, split.app_config.layout.placeholder_banner, " \t\r\n");
    const server_text = try childServerText(session.allocator, child_primary_server, placeholder);
    defer session.allocator.free(server_text);

    try writeSplitContent(session, split, server_text, output);
}

fn childServerText(
    allocator: std.mem.Allocator,
    child_primary_server: *child_primary.ChildPrimary,
    placeholder: []const u8,
) ![]const u8 {
    const output = try child_primary_server.snapshot(allocator);
    defer allocator.free(output);
    if (output.len > 0) return terminal.text.render(allocator, output);
    return allocator.dupe(u8, placeholder);
}

fn inProcessContent(
    session: *tui.client_session.ClientSession,
    split: *const tui.split_model.Model,
    primary_server: *primary.Server,
    output: io.Output,
) !void {
    const placeholder = std.mem.trim(u8, split.app_config.layout.placeholder_banner, " \t\r\n");
    const server_text = try inProcessServerText(session.allocator, primary_server, session.model.active_proc_id, placeholder);
    defer session.allocator.free(server_text);

    try writeSplitContent(session, split, server_text, output);
}

fn inProcessServerText(
    allocator: std.mem.Allocator,
    primary_server: *primary.Server,
    active_proc_id: domain.process.ProcessId,
    placeholder: []const u8,
) ![]const u8 {
    if (!active_proc_id.isNone()) {
        const scrollback = primary_server.controller.getScrollback(allocator, active_proc_id) catch |err| switch (err) {
            error.ProcessNotFound => null,
            else => return err,
        };
        if (scrollback) |text| {
            defer allocator.free(text);
            if (text.len > 0) return try terminal.text.render(allocator, text);
        }
    }

    return allocator.dupe(u8, placeholder);
}

fn writeSplitContent(
    session: *tui.client_session.ClientSession,
    split: *const tui.split_model.Model,
    server_text: []const u8,
    output: io.Output,
) !void {
    if (!split.clientVisible()) {
        try writeTextBlock(output, server_text);
        return;
    }

    const client_text = try client_mode.renderText(session);
    defer session.allocator.free(client_text);

    switch (split.orientation) {
        .left => try writeSideBySide(
            output,
            client_text,
            server_text,
            positiveWidth(split.clientSize().width),
            positiveWidth(split.serverSize().width),
        ),
        .right => try writeSideBySide(
            output,
            server_text,
            client_text,
            positiveWidth(split.serverSize().width),
            positiveWidth(split.clientSize().width),
        ),
        .top => {
            try writeTextBlock(output, client_text);
            try writeTextBlock(output, server_text);
        },
        .bottom => {
            try writeTextBlock(output, server_text);
            try writeTextBlock(output, client_text);
        },
    }
}

fn writeTextBlock(output: io.Output, text: []const u8) !void {
    if (text.len == 0) return;
    try io.writeTextClearingLineTails(output, text, terminal.repaint.clear_line_tail);
    if (text[text.len - 1] != '\n') try output.writeAll("\n");
}

fn writeSideBySide(
    output: io.Output,
    left: []const u8,
    right: []const u8,
    left_width: usize,
    right_width: usize,
) !void {
    var left_lines = std.mem.splitScalar(u8, left, '\n');
    var right_lines = std.mem.splitScalar(u8, right, '\n');

    while (true) {
        const left_line_opt = left_lines.next();
        const right_line_opt = right_lines.next();
        if (left_line_opt == null and right_line_opt == null) break;

        const left_line = trimLineRight(left_line_opt orelse "");
        const right_line = trimLineRight(right_line_opt orelse "");
        if (left_line.len == 0 and right_line.len == 0) continue;

        const left_display_width = try writeFittedLine(output, left_line, left_width);
        if (right_line.len > 0) {
            if (left_display_width < left_width) try writeSpaces(output, left_width - left_display_width);
            _ = try writeFittedLine(output, right_line, right_width);
        }
        try output.writeAll(terminal.repaint.clear_line_tail);
        try output.writeAll("\n");
    }
}

fn trimLineRight(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, " \t\r");
}

fn positiveWidth(width: i32) usize {
    return if (width > 0) @intCast(width) else 1;
}

fn displayWidth(value: []const u8) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < value.len) {
        if (ansiSequenceEnd(value, index)) |end| {
            index = end;
            continue;
        }
        const len = utf8SequenceLength(value, index);
        index += len;
        width += 1;
    }
    return width;
}

fn writeFittedLine(output: io.Output, line: []const u8, width: usize) !usize {
    var display_width: usize = 0;
    var index: usize = 0;
    var wrote_ansi = false;
    while (index < line.len) {
        if (ansiSequenceEnd(line, index)) |end| {
            try output.writeAll(line[index..end]);
            wrote_ansi = true;
            index = end;
            continue;
        }
        if (display_width >= width) break;

        const len = utf8SequenceLength(line, index);
        try output.writeAll(line[index..][0..len]);
        index += len;
        display_width += 1;
    }
    if (wrote_ansi) try output.writeAll("\x1b[0m");
    return display_width;
}

fn ansiSequenceEnd(value: []const u8, index: usize) ?usize {
    if (index >= value.len or value[index] != 0x1b) return null;
    if (index + 1 >= value.len) return value.len;

    switch (value[index + 1]) {
        '[' => {
            var end = index + 2;
            while (end < value.len) : (end += 1) {
                const byte = value[end];
                if (byte >= 0x40 and byte <= 0x7e) return end + 1;
            }
            return value.len;
        },
        ']' => {
            var end = index + 2;
            while (end < value.len) : (end += 1) {
                if (value[end] == 0x07) return end + 1;
                if (value[end] == 0x1b and end + 1 < value.len and value[end + 1] == '\\') return end + 2;
            }
            return value.len;
        },
        else => return @min(index + 2, value.len),
    }
}

fn utf8SequenceLength(value: []const u8, index: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(value[index]) catch 1;
    return @min(len, value.len - index);
}

fn writeSpaces(output: io.Output, count: usize) !void {
    var index: usize = 0;
    while (index < count) : (index += 1) try output.writeAll(" ");
}

test "unified split display width ignores ANSI escapes" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\x1b[32m●\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 7), displayWidth("\x1b[31m■\x1b[0m label"));
}

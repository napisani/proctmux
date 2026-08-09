//! Unified-mode frame renderer.
//! This module composes the Client Session pane, server-output pane, focus/status bar, and terminal repaint sequences.

const std = @import("std");
const domain = @import("../domain/root.zig");
const io = @import("../modes/io.zig");
const terminal = @import("../terminal/root.zig");
const tui = @import("../tui/root.zig");
const client_mode = @import("../modes/client.zig");

const side_by_side_separator = " │ ";
const side_by_side_separator_width = 3;
const min_unified_width = 80;
const min_unified_height = 24;

pub fn frame(
    session: *tui.client_session.ClientSession,
    split: *const tui.split_model.Model,
    server_text: []const u8,
    output: io.Output,
) !void {
    var frame_buffer = std.array_list.Managed(u8).init(session.allocator);
    defer frame_buffer.deinit();

    const buffered_output = io.BufferOutput.writer(&frame_buffer, output.fd);
    try writeFrame(session, split, server_text, buffered_output);
    try output.writeAll(frame_buffer.items);
}

fn writeFrame(
    session: *tui.client_session.ClientSession,
    split: *const tui.split_model.Model,
    server_text: []const u8,
    output: io.Output,
) !void {
    try output.writeAll(terminal.repaint.hide_cursor);
    try output.writeAll(terminal.repaint.begin_synchronized_update);
    errdefer output.writeAll(terminal.repaint.end_synchronized_update) catch {};

    try output.writeAll(terminal.repaint.begin_frame);
    if (terminalTooSmall(split)) {
        try writeSmallTerminalMessage(split, output);
    } else {
        try writeSplitContent(session, split, server_text, output);
    }
    try output.writeAll(terminal.repaint.end_frame);
    try writeStatusBar(session, split, output);
    try output.writeAll(terminal.repaint.end_frame);
    try output.writeAll(terminal.repaint.hide_cursor);
    try output.writeAll(terminal.repaint.end_synchronized_update);
}

fn terminalTooSmall(split: *const tui.split_model.Model) bool {
    const total_height = split.content_height + split.status_height;
    return split.content_width < min_unified_width or total_height < min_unified_height;
}

fn writeSmallTerminalMessage(
    split: *const tui.split_model.Model,
    output: io.Output,
) !void {
    var buffer: [128]u8 = undefined;
    const total_height = split.content_height + split.status_height;
    const message = try std.fmt.bufPrint(
        &buffer,
        "Terminal too small\nNeed at least {}x{}; current {}x{}\n",
        .{ min_unified_width, min_unified_height, split.content_width, total_height },
    );
    try writeTextBlock(output, message);
}

fn writeStatusBar(
    session: *tui.client_session.ClientSession,
    split: *const tui.split_model.Model,
    output: io.Output,
) !void {
    const status = try split.statusBar(session.allocator);
    defer session.allocator.free(status);
    if (status.len > 0) {
        try writeCursorPosition(output, statusRow(split), 1);
        _ = try writeFittedLine(output, status, positiveWidth(split.content_width));
        try output.writeAll(terminal.repaint.clear_line_tail);
    }
}

fn statusRow(split: *const tui.split_model.Model) usize {
    if (split.content_height <= 0) return 1;
    return @as(usize, @intCast(split.content_height)) + 1;
}

fn writeCursorPosition(output: io.Output, row: usize, column: usize) !void {
    var buffer: [32]u8 = undefined;
    const sequence = try std.fmt.bufPrint(&buffer, "\x1b[{};{}H", .{ row, column });
    try output.writeAll(sequence);
}

fn writeSplitContent(
    session: *tui.client_session.ClientSession,
    split: *const tui.split_model.Model,
    server_text: []const u8,
    output: io.Output,
) !void {
    if (session.model.show_help) {
        const overlay = try tui.render.renderHelpOverlay(
            session.allocator,
            &session.model,
            positiveWidth(split.content_width),
            positiveHeight(split.content_height),
        );
        defer session.allocator.free(overlay);
        try writeTextBlock(output, overlay);
        return;
    }

    const server_panel_text = try renderServerPanelText(
        session.allocator,
        &session.model,
        server_text,
        positiveHeight(split.serverSize().height),
    );
    defer session.allocator.free(server_panel_text);

    if (!split.clientVisible()) {
        try writeTextBlock(output, server_panel_text);
        return;
    }

    session.model.show_panel_headers = true;
    session.model.term_width = positiveWidth(split.clientSize().width);
    session.model.term_height = positiveHeight(split.clientSize().height);

    const client_text = try client_mode.renderText(session);
    defer session.allocator.free(client_text);

    switch (split.orientation) {
        .left => try writeSideBySide(
            output,
            client_text,
            server_panel_text,
            positiveWidth(split.clientSize().width),
            widthWithoutSeparator(positiveWidth(split.serverSize().width)),
            positiveHeight(split.serverSize().height),
            .head,
            .head,
        ),
        .right => try writeSideBySide(
            output,
            server_panel_text,
            client_text,
            widthWithoutSeparator(positiveWidth(split.serverSize().width)),
            positiveWidth(split.clientSize().width),
            positiveHeight(split.serverSize().height),
            .head,
            .head,
        ),
        .top => {
            try writeTextBlock(output, client_text);
            try writeTextBlock(output, server_panel_text);
        },
        .bottom => {
            try writeTextBlock(output, server_panel_text);
            try writeTextBlock(output, client_text);
        },
    }
}

fn renderServerPanelText(
    allocator: std.mem.Allocator,
    model: *const tui.client_model.ClientModel,
    server_text: []const u8,
    height: usize,
) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try appendServerHeader(&out, model);
    const available_lines = if (height > 1) height - 1 else 0;
    try appendTailLines(&out, server_text, available_lines);
    return out.toOwnedSlice();
}

fn appendServerHeader(
    out: *std.array_list.Managed(u8),
    model: *const tui.client_model.ClientModel,
) !void {
    const label = activeProcessLabel(model);
    if (label.len == 0) {
        try out.appendSlice("Output\n");
        return;
    }

    if (activeProcessStatus(model)) |status| {
        try out.writer().print("Output: {s}  {s}\n", .{ label, statusText(status) });
        return;
    }

    try out.writer().print("Output: {s}\n", .{label});
}

fn activeProcessLabel(model: *const tui.client_model.ClientModel) []const u8 {
    const summary = model.activeProcessSummary() orelse return "";
    return summary.label;
}

fn activeProcessStatus(model: *const tui.client_model.ClientModel) ?domain.process.ProcessStatus {
    const summary = model.activeProcessSummary() orelse return null;
    return summary.status;
}

fn statusText(status: domain.process.ProcessStatus) []const u8 {
    return switch (status) {
        .running => "running",
        .halting => "halting",
        .halted => "halted",
        .exited => "exited",
        .unknown => "unknown",
    };
}

fn appendTailLines(out: *std.array_list.Managed(u8), text: []const u8, max_lines: usize) !void {
    if (text.len == 0 or max_lines == 0) return;

    const count = visibleLineCount(text);
    const skip = if (count > max_lines) count - max_lines else 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_index: usize = 0;
    while (lines.next()) |line| : (line_index += 1) {
        if (line_index >= count) break;

        if (line_index < skip) continue;
        try out.appendSlice(line);
        try out.append('\n');
    }
}

const LineWindow = enum {
    head,
    tail,
};

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
    height: usize,
    left_window: LineWindow,
    right_window: LineWindow,
) !void {
    var left_lines = std.mem.splitScalar(u8, left, '\n');
    var right_lines = std.mem.splitScalar(u8, right, '\n');
    skipWindowedLines(&left_lines, left, height, left_window);
    skipWindowedLines(&right_lines, right, height, right_window);

    var row: usize = 0;
    while (row < height) : (row += 1) {
        const left_line_opt = left_lines.next();
        const right_line_opt = right_lines.next();

        const left_line = trimLineRight(left_line_opt orelse "");
        const right_line = trimLineRight(right_line_opt orelse "");

        const left_display_width = try writeFittedLine(output, left_line, left_width);
        if (left_display_width < left_width) try writeSpaces(output, left_width - left_display_width);
        try output.writeAll(side_by_side_separator);
        if (right_line.len > 0) {
            _ = try writeFittedLine(output, right_line, right_width);
        }
        try output.writeAll(terminal.repaint.clear_line_tail);
        try output.writeAll("\n");
    }
}

fn skipWindowedLines(lines: anytype, text: []const u8, height: usize, window: LineWindow) void {
    if (window == .head or height == 0) return;
    const count = visibleLineCount(text);
    if (count <= height) return;
    const skip_count = count - height;
    var skipped: usize = 0;
    while (skipped < skip_count) : (skipped += 1) _ = lines.next();
}

fn visibleLineCount(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    if (text[text.len - 1] == '\n') count -= 1;
    return count;
}

fn trimLineRight(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, " \t\r");
}

fn positiveWidth(width: i32) usize {
    return if (width > 0) @intCast(width) else 1;
}

fn widthWithoutSeparator(width: usize) usize {
    if (width <= side_by_side_separator_width) return 1;
    return width - side_by_side_separator_width;
}

fn positiveHeight(height: i32) usize {
    return if (height > 0) @intCast(height) else 1;
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

test "side-by-side renderer clips long left pane before right pane" {
    const test_io = @import("../test_support/io.zig");
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try writeSideBySide(
        test_io.TestOutput.writer(&out),
        "client-label-that-is-too-long",
        "RIGHT",
        10,
        10,
        3,
        .head,
        .tail,
    );

    const line_end = std.mem.indexOfScalar(u8, out.items, '\n') orelse out.items.len;
    const line = out.items[0..line_end];
    try std.testing.expect(std.mem.indexOf(u8, line, "RIGHT") != null);
    const right_index = std.mem.indexOf(u8, line, "RIGHT").?;
    try std.testing.expectEqual(@as(usize, 13), displayWidth(line[0..right_index]));
}

test "side-by-side renderer marks the pane boundary before server output" {
    const test_io = @import("../test_support/io.zig");
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try writeSideBySide(
        test_io.TestOutput.writer(&out),
        "client",
        "RIGHT",
        10,
        10,
        3,
        .head,
        .tail,
    );

    const line_end = std.mem.indexOfScalar(u8, out.items, '\n') orelse out.items.len;
    const line = out.items[0..line_end];
    try std.testing.expect(std.mem.indexOf(u8, line, " │ RIGHT") != null);
}

test "side-by-side renderer draws separator through empty rows" {
    const test_io = @import("../test_support/io.zig");
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try writeSideBySide(
        test_io.TestOutput.writer(&out),
        "client",
        "server",
        10,
        10,
        4,
        .head,
        .head,
    );

    var separators: usize = 0;
    var lines = std.mem.splitScalar(u8, out.items, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, side_by_side_separator) != null) separators += 1;
    }

    try std.testing.expectEqual(@as(usize, 4), separators);
}

test "side-by-side renderer tails server output without scrolling client away" {
    const test_io = @import("../test_support/io.zig");
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try writeSideBySide(
        test_io.TestOutput.writer(&out),
        "client",
        "one\ntwo\nthree\nfour\nfive\n",
        10,
        10,
        3,
        .head,
        .tail,
    );

    try std.testing.expect(std.mem.indexOf(u8, out.items, "client") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "one") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "two") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "five") != null);
}

test "status bar moves to bottom row before rendering" {
    const test_config = @import("../test_support/config.zig");
    const test_io = @import("../test_support/io.zig");

    var cfg = try test_config.basicConfig(std.testing.allocator);
    defer cfg.deinit();

    var split = tui.split_model.Model.init(.left, &cfg);
    try split.resize(90, 12);

    var session: tui.client_session.ClientSession = undefined;
    session.allocator = std.testing.allocator;

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try writeStatusBar(&session, &split, test_io.TestOutput.writer(&out));

    try std.testing.expect(std.mem.startsWith(
        u8,
        out.items,
        "\x1b[12;1HClient  [Tab] server",
    ));
}

test "status bar clips to terminal width before clearing line tail" {
    const test_config = @import("../test_support/config.zig");
    const test_io = @import("../test_support/io.zig");

    var cfg = try test_config.basicConfig(std.testing.allocator);
    defer cfg.deinit();

    var split = tui.split_model.Model.init(.left, &cfg);
    try split.resize(40, 12);

    var session: tui.client_session.ClientSession = undefined;
    session.allocator = std.testing.allocator;

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try writeStatusBar(&session, &split, test_io.TestOutput.writer(&out));

    const cursor = "\x1b[12;1H";
    try std.testing.expect(std.mem.startsWith(u8, out.items, cursor));

    const after_cursor = out.items[cursor.len..];
    const clear_index = std.mem.indexOf(u8, after_cursor, terminal.repaint.clear_line_tail) orelse
        return error.MissingClearLineTail;
    try std.testing.expectEqual(@as(usize, 40), clear_index);
    try std.testing.expect(std.mem.indexOfScalar(u8, after_cursor[0..clear_index], '\n') == null);
}

test "frame clears stale content before pinned status bar" {
    const test_config = @import("../test_support/config.zig");
    const test_io = @import("../test_support/io.zig");

    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.layout.hide_process_list_when_unfocused = true;

    var split = tui.split_model.Model.init(.left, &cfg);
    try split.resize(90, 24);
    try split.handleKey("ctrl+right");

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    const model = try tui.client_model.ClientModel.init(std.testing.allocator, snapshot.view());

    var session: tui.client_session.ClientSession = undefined;
    session.allocator = std.testing.allocator;
    session.model = model;
    defer session.model.deinit();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try frame(&session, &split, "NO PROCESS", test_io.TestOutput.writer(&out));

    try std.testing.expect(std.mem.indexOf(
        u8,
        out.items,
        "NO PROCESS\x1b[K\n\x1b[J\x1b[24;1H",
    ) != null);
}

test "frame renders small terminal resize message" {
    const test_config = @import("../test_support/config.zig");
    const test_io = @import("../test_support/io.zig");

    var cfg = try test_config.basicConfig(std.testing.allocator);
    defer cfg.deinit();

    var split = tui.split_model.Model.init(.left, &cfg);
    try split.resize(70, 18);

    var session: tui.client_session.ClientSession = undefined;
    session.allocator = std.testing.allocator;

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try frame(&session, &split, "READY", test_io.TestOutput.writer(&out));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "Terminal too small") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "80x24") != null);
}

test "frame renders help as full width overlay" {
    const test_config = @import("../test_support/config.zig");
    const test_io = @import("../test_support/io.zig");

    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try tui.client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    model.show_help = true;

    var session: tui.client_session.ClientSession = undefined;
    session.allocator = std.testing.allocator;
    session.model = model;
    defer session.model.deinit();

    var split = tui.split_model.Model.init(.left, &cfg);
    try split.resize(100, 24);

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try frame(&session, &split, "SERVER", test_io.TestOutput.writer(&out));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "Help") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Focus") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, " │ ") == null);
}

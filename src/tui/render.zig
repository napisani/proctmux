const std = @import("std");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");
const test_ansi = @import("../test_support/ansi.zig");
const test_config = @import("../test_support/config.zig");
const client_model = @import("client_model.zig");

pub fn renderProcessList(allocator: std.mem.Allocator, model: *const client_model.ClientModel) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try appendProcessHeader(&out, model);
    try appendHelpPanel(&out, model);
    try appendSelectedDescription(&out, model);
    try appendMessagesPanel(&out, model);
    try appendFilterPanel(&out, model);

    const processes = model.visibleProcesses();
    if (processes.len == 0) {
        try out.appendSlice("No matching processes\n");
        return out.toOwnedSlice();
    }

    const process_start = selectedProcessWindowStart(
        model,
        renderedLineCount(out.items),
        processes.len,
    );
    const process_end = selectedProcessWindowEnd(model, renderedLineCount(out.items), process_start);

    for (processes[process_start..process_end], process_start..) |summary, index| {
        const selected = if (model.active_proc_id.isNone())
            index == 0
        else
            domain.process.ProcessId.fromInt(summary.id) == model.active_proc_id;
        if (selected) {
            try out.appendSlice(model.snapshot.ui.style.pointer_char);
            try out.append(' ');
        } else {
            try out.appendSlice("  ");
        }

        try appendStatusMarker(&out, &model.snapshot.ui.style, summary.status, !model.no_color);
        try out.append(' ');
        if (model.snapshot.ui.layout.enable_debug_process_info) {
            try out.appendSlice(summary.label);
            try out.appendSlice(" [");
            try out.appendSlice(domain.process.statusName(summary.status));
            try out.writer().print("] PID:{}", .{summary.pid});
            if (summary.categories.len > 0) {
                try out.appendSlice(" [");
                for (summary.categories, 0..) |category, category_index| {
                    if (category_index != 0) try out.append(',');
                    try out.appendSlice(category);
                }
                try out.append(']');
            }
        } else {
            try out.appendSlice(summary.label);
        }
        try out.append('\n');
    }

    return out.toOwnedSlice();
}

fn appendProcessHeader(out: *std.array_list.Managed(u8), model: *const client_model.ClientModel) !void {
    if (!model.show_panel_headers) return;

    try out.writer().print("Processes {}/{}", .{ model.visibleCount(), model.processCount() });
    if (model.show_only_running) try out.appendSlice("  running only");
    if (model.filterText().len > 0) try out.writer().print("  filter: {s}", .{model.filterText()});
    try out.append('\n');
}

fn selectedProcessWindowStart(
    model: *const client_model.ClientModel,
    reserved_lines: usize,
    process_count: usize,
) usize {
    if (model.term_height == 0 or process_count == 0) return 0;
    if (reserved_lines >= model.term_height) return 0;

    const available_rows = model.term_height - reserved_lines;
    if (available_rows >= process_count) return 0;

    const selected_index = selectedProcessIndex(model);
    if (selected_index < available_rows) return 0;
    return selected_index + 1 - available_rows;
}

fn selectedProcessWindowEnd(
    model: *const client_model.ClientModel,
    reserved_lines: usize,
    start: usize,
) usize {
    if (model.term_height == 0) return model.visibleCount();
    if (reserved_lines >= model.term_height) return start;

    const available_rows = model.term_height - reserved_lines;
    return @min(start + available_rows, model.visibleCount());
}

fn selectedProcessIndex(model: *const client_model.ClientModel) usize {
    if (model.active_proc_id.isNone()) return 0;
    for (model.visibleProcesses(), 0..) |summary, index| {
        if (domain.process.ProcessId.fromInt(summary.id) == model.active_proc_id) return index;
    }
    return 0;
}

fn renderedLineCount(text: []const u8) usize {
    if (text.len == 0) return 0;

    var count: usize = 0;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    if (text[text.len - 1] != '\n') count += 1;
    return count;
}

fn appendMessagesPanel(out: *std.array_list.Managed(u8), model: *const client_model.ClientModel) !void {
    if (model.messageCount() == 0) return;

    const now_ms = std.time.milliTimestamp();
    const visible_count = countVisibleMessages(model, now_ms);
    if (visible_count == 0) return;

    try out.appendSlice("Messages:\n");
    const start = if (visible_count > 5) visible_count - 5 else 0;
    var visible_index: usize = 0;
    for (model.messages.items) |message_entry| {
        if (now_ms >= message_entry.expires_at_ms) continue;
        const current_index = visible_index;
        visible_index += 1;
        if (current_index < start) continue;

        try appendWrappedBulletLine(out, message_entry.text, model.term_width);
        try out.append('\n');
    }
}

fn countVisibleMessages(model: *const client_model.ClientModel, now_ms: i64) usize {
    var count: usize = 0;
    for (model.messages.items) |message_entry| {
        if (now_ms < message_entry.expires_at_ms) count += 1;
    }
    return count;
}

fn appendHelpPanel(out: *std.array_list.Managed(u8), model: *const client_model.ClientModel) !void {
    if (!model.show_help) return;

    const keys = model.snapshot.ui.keybinding;
    try appendHelpEntry(out, keys.up, "move up", 4, 17);
    try appendHelpEntry(out, keys.start, "start process", 4, 23);
    try appendHelpEntry(out, keys.filter, "filter processes", 2, 25);
    try appendHelpEntry(out, keys.docs, "show docs", 11, 0);
    try out.append('\n');

    try appendHelpEntry(out, keys.down, "move down", 4, 17);
    try appendHelpEntry(out, keys.stop, "stop process", 4, 23);
    try appendHelpEntry(out, keys.submit_filter, "apply filter", 2, 25);
    try appendHelpEntry(out, keys.toggle_help, "toggle help", 11, 0);
    try out.append('\n');

    try appendSpaces(out, 17);
    try appendHelpEntry(out, keys.restart, "restart process", 4, 23);
    try appendHelpEntry(out, keys.toggle_running, "toggle running only", 2, 25);
    try appendHelpEntry(out, keys.toggle_focus, "toggle focus", 11, 0);
    try out.append('\n');

    try appendSpaces(out, 65);
    try appendHelpEntry(out, keys.focus_client, "focus client", 11, 0);
    try out.append('\n');

    try appendSpaces(out, 65);
    try appendHelpEntry(out, keys.focus_server, "focus server", 11, 0);
    try out.append('\n');

    try appendSpaces(out, 65);
    try appendHelpEntry(out, keys.quit, "quit", 11, 0);
    try out.append('\n');

    try out.appendSlice("[Client Mode - Connected to Primary]\n");
}

fn appendHelpEntry(
    out: *std.array_list.Managed(u8),
    keys: domain.client_snapshot.StringList,
    label: []const u8,
    key_column_width: usize,
    group_width: usize,
) !void {
    const key_width = bindingDisplayWidth(keys);
    try appendBindingText(out, keys);

    const key_gap = if (key_width < key_column_width) key_column_width - key_width else 1;
    try appendSpaces(out, key_gap);
    try out.appendSlice(label);

    const entry_width = key_width + key_gap + displayWidth(label);
    if (group_width > entry_width) try appendSpaces(out, group_width - entry_width);
}

fn appendBindingText(out: *std.array_list.Managed(u8), keys: domain.client_snapshot.StringList) !void {
    for (keys, 0..) |key, index| {
        if (index >= 2) break;
        if (index != 0) try out.append('/');
        try out.appendSlice(formatKey(key));
    }
}

fn bindingDisplayWidth(keys: domain.client_snapshot.StringList) usize {
    var width: usize = 0;
    for (keys, 0..) |key, index| {
        if (index >= 2) break;
        if (index != 0) width += 1;
        width += displayWidth(formatKey(key));
    }
    return width;
}

fn appendSpaces(out: *std.array_list.Managed(u8), count: usize) !void {
    var index: usize = 0;
    while (index < count) : (index += 1) try out.append(' ');
}

fn appendFilterPanel(out: *std.array_list.Managed(u8), model: *const client_model.ClientModel) !void {
    const filter_text = model.filterText();
    if (model.entering_filter_text) {
        try out.appendSlice("Filter: ");
        try out.appendSlice(filter_text);
        try out.append('\n');
        return;
    }

    if (filter_text.len == 0) return;
    try out.appendSlice("Filter: ");
    try out.appendSlice(filter_text);
    try out.appendSlice(" (/ to edit, esc to clear)\n");
}

fn appendBinding(out: *std.array_list.Managed(u8), keys: domain.client_snapshot.StringList, label: []const u8) !void {
    for (keys, 0..) |key, index| {
        if (index >= 2) break;
        if (index != 0) try out.append('/');
        try out.appendSlice(formatKey(key));
    }
    try out.append(' ');
    try out.appendSlice(label);
}

fn displayWidth(value: []const u8) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < value.len) {
        const len = std.unicode.utf8ByteSequenceLength(value[index]) catch 1;
        index += @min(len, value.len - index);
        width += 1;
    }
    return width;
}

fn formatKey(key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "up")) return "↑";
    if (std.mem.eql(u8, key, "down")) return "↓";
    if (std.mem.eql(u8, key, "left")) return "←";
    if (std.mem.eql(u8, key, "right")) return "→";
    if (std.mem.eql(u8, key, "enter")) return "⏎";
    if (std.mem.eql(u8, key, "ctrl+c")) return "^C";
    return key;
}

fn appendSelectedDescription(out: *std.array_list.Managed(u8), model: *const client_model.ClientModel) !void {
    if (model.snapshot.ui.layout.hide_process_description_panel) return;

    const summary = model.activeProcessSummary() orelse return;
    const description = std.mem.trim(u8, summary.description, " \t\r\n");
    if (description.len == 0) return;

    try appendWrapped(out, description, model.term_width);
    try out.append('\n');
}

fn appendWrapped(out: *std.array_list.Managed(u8), text: []const u8, width: usize) !void {
    if (width == 0 or text.len <= width) {
        try out.appendSlice(text);
        return;
    }

    var remaining = text;
    var first_line = true;
    while (remaining.len > width) {
        var break_at = width;
        while (break_at > 0 and remaining[break_at] != ' ') : (break_at -= 1) {}
        if (break_at == 0) break_at = width;

        if (!first_line) try out.append('\n');
        try out.appendSlice(std.mem.trim(u8, remaining[0..break_at], " "));
        first_line = false;

        remaining = std.mem.trimLeft(u8, remaining[break_at..], " ");
    }

    if (remaining.len > 0) {
        if (!first_line) try out.append('\n');
        try out.appendSlice(remaining);
    }
}

fn appendWrappedBulletLine(out: *std.array_list.Managed(u8), text: []const u8, width: usize) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or width <= 2) {
        try out.appendSlice("- ");
        try out.appendSlice(trimmed);
        return;
    }

    var wrapped = std.array_list.Managed(u8).init(out.allocator);
    defer wrapped.deinit();
    try appendWrapped(&wrapped, trimmed, width - 2);

    var lines = std.mem.splitScalar(u8, wrapped.items, '\n');
    if (lines.next()) |first| {
        try out.appendSlice("- ");
        try out.appendSlice(first);
    } else {
        try out.appendSlice("- ");
        return;
    }

    while (lines.next()) |line| {
        try out.appendSlice("\n  ");
        try out.appendSlice(line);
    }
}

fn statusMarker(status: domain.process.ProcessStatus) []const u8 {
    return switch (status) {
        .running => "●",
        .halting => "◐",
        .halted, .exited, .unknown => "■",
    };
}

fn appendStatusMarker(
    out: *std.array_list.Managed(u8),
    style: *const domain.client_snapshot.UiStyleConfig,
    status: domain.process.ProcessStatus,
    colors_enabled: bool,
) !void {
    const color = statusMarkerColor(style, status);
    if (colors_enabled) {
        if (ansiForegroundCode(color)) |code| {
            try out.writer().print("\x1b[{}m{s}\x1b[0m", .{ code, statusMarker(status) });
            return;
        }
    }

    try out.appendSlice(statusMarker(status));
}

pub fn renderHelpOverlay(
    allocator: std.mem.Allocator,
    model: *const client_model.ClientModel,
    width: usize,
    height: usize,
) ![]const u8 {
    _ = width;

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var lines: usize = 0;
    const keys = model.snapshot.ui.keybinding;

    try appendHelpOverlayLine(&out, &lines, height, "Help");
    try appendHelpOverlayLine(&out, &lines, height, "");
    try appendHelpOverlayLine(&out, &lines, height, "Navigation");
    try appendHelpOverlayBindingLine(&out, &lines, height, keys.up, "move up");
    try appendHelpOverlayBindingLine(&out, &lines, height, keys.down, "move down");
    try appendHelpOverlayLine(&out, &lines, height, "");
    try appendHelpOverlayLine(&out, &lines, height, "Process");
    try appendHelpOverlayBindingLine(&out, &lines, height, keys.start, "start process");
    try appendHelpOverlayBindingLine(&out, &lines, height, keys.stop, "stop process");
    try appendHelpOverlayBindingLine(&out, &lines, height, keys.restart, "restart process");
    try appendHelpOverlayLine(&out, &lines, height, "");
    try appendHelpOverlayLine(&out, &lines, height, "Filter");
    try appendHelpOverlayBindingLine(&out, &lines, height, keys.filter, "filter processes");
    try appendHelpOverlayBindingLine(&out, &lines, height, keys.submit_filter, "apply filter");
    try appendHelpOverlayBindingLine(&out, &lines, height, keys.toggle_running, "toggle running only");
    try appendHelpOverlayLine(&out, &lines, height, "");
    try appendHelpOverlayLine(&out, &lines, height, "Focus");
    try appendHelpOverlayLiteralLine(&out, &lines, height, "Tab", "focus next pane");
    try appendHelpOverlayLiteralLine(&out, &lines, height, "Shift+Tab", "focus previous pane");
    try appendHelpOverlayBindingLine(&out, &lines, height, keys.toggle_focus, "toggle focus");
    try appendHelpOverlayBindingLine(&out, &lines, height, keys.focus_client, "focus client");
    try appendHelpOverlayBindingLine(&out, &lines, height, keys.focus_server, "focus server");
    try appendHelpOverlayLine(&out, &lines, height, "");
    try appendHelpOverlayLine(&out, &lines, height, "Other");
    try appendHelpOverlayBindingLine(&out, &lines, height, keys.toggle_help, "close help");
    try appendHelpOverlayBindingLine(&out, &lines, height, keys.docs, "show docs");
    try appendHelpOverlayBindingLine(&out, &lines, height, keys.quit, "quit");

    return out.toOwnedSlice();
}

fn appendHelpOverlayLine(
    out: *std.array_list.Managed(u8),
    lines: *usize,
    height: usize,
    text: []const u8,
) !void {
    if (height != 0 and lines.* >= height) return;
    try out.appendSlice(text);
    try out.append('\n');
    lines.* += 1;
}

fn appendHelpOverlayBindingLine(
    out: *std.array_list.Managed(u8),
    lines: *usize,
    height: usize,
    keys: domain.client_snapshot.StringList,
    label: []const u8,
) !void {
    if (height != 0 and lines.* >= height) return;
    try appendBindingText(out, keys);
    try out.append(' ');
    try out.appendSlice(label);
    try out.append('\n');
    lines.* += 1;
}

fn appendHelpOverlayLiteralLine(
    out: *std.array_list.Managed(u8),
    lines: *usize,
    height: usize,
    key: []const u8,
    label: []const u8,
) !void {
    if (height != 0 and lines.* >= height) return;
    try out.appendSlice(key);
    try out.append(' ');
    try out.appendSlice(label);
    try out.append('\n');
    lines.* += 1;
}

fn statusMarkerColor(style: *const domain.client_snapshot.UiStyleConfig, status: domain.process.ProcessStatus) []const u8 {
    return switch (status) {
        .running => style.status_running_color,
        .halting => style.status_halting_color,
        .halted, .exited, .unknown => style.status_stopped_color,
    };
}

fn ansiForegroundCode(color: []const u8) ?u8 {
    const trimmed = std.mem.trim(u8, color, " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "none")) return null;

    const named_colors = [_]struct {
        name: []const u8,
        code: u8,
    }{
        .{ .name = "black", .code = 30 },
        .{ .name = "red", .code = 31 },
        .{ .name = "green", .code = 32 },
        .{ .name = "yellow", .code = 33 },
        .{ .name = "blue", .code = 34 },
        .{ .name = "magenta", .code = 35 },
        .{ .name = "cyan", .code = 36 },
        .{ .name = "white", .code = 37 },
        .{ .name = "brightblack", .code = 90 },
        .{ .name = "gray", .code = 90 },
        .{ .name = "grey", .code = 90 },
        .{ .name = "brightred", .code = 91 },
        .{ .name = "lightred", .code = 91 },
        .{ .name = "brightgreen", .code = 92 },
        .{ .name = "lightgreen", .code = 92 },
        .{ .name = "brightyellow", .code = 93 },
        .{ .name = "brightblue", .code = 94 },
        .{ .name = "brightmagenta", .code = 95 },
        .{ .name = "brightcyan", .code = 96 },
        .{ .name = "brightwhite", .code = 97 },
        .{ .name = "ansiblack", .code = 30 },
        .{ .name = "ansired", .code = 31 },
        .{ .name = "ansigreen", .code = 32 },
        .{ .name = "ansiyellow", .code = 33 },
        .{ .name = "ansiblue", .code = 34 },
        .{ .name = "ansimagenta", .code = 35 },
        .{ .name = "ansicyan", .code = 36 },
        .{ .name = "ansiwhite", .code = 37 },
        .{ .name = "ansibrightblack", .code = 90 },
        .{ .name = "ansigray", .code = 90 },
        .{ .name = "ansigrey", .code = 90 },
        .{ .name = "ansibrightred", .code = 91 },
        .{ .name = "ansibrightgreen", .code = 92 },
        .{ .name = "ansibrightyellow", .code = 93 },
        .{ .name = "ansibrightblue", .code = 94 },
        .{ .name = "ansibrightmagenta", .code = 95 },
        .{ .name = "ansibrightcyan", .code = 96 },
        .{ .name = "ansibrightwhite", .code = 97 },
    };

    for (named_colors) |entry| {
        if (std.ascii.eqlIgnoreCase(trimmed, entry.name)) return entry.code;
    }

    const color_index = std.fmt.parseUnsigned(u8, trimmed, 10) catch return null;
    if (color_index <= 7) return 30 + color_index;
    if (color_index <= 15) return 90 + color_index - 8;
    return null;
}

test "process list renderer writes pointer status marker and labels" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try test_ansi.expectEqualPlain(
        std.testing.allocator,
        "  ■ alpha-api\n> ● beta-worker\n  ■ gamma-db\n",
        rendered,
    );
}

test "process list renderer colors status markers from config" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[31m■\x1b[0m alpha-api") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "> \x1b[32m●\x1b[0m beta-worker") != null);
}

test "process list renderer omits status colors when disabled" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();
    model.no_color = true;

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "> ● beta-worker") != null);
}

test "process list renderer adds compact header when enabled" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();
    model.show_panel_headers = true;

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try test_ansi.expectContainsPlain(std.testing.allocator, rendered, "Processes 3/3\n");
}

test "process list renderer reports active filter in header" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();
    model.show_panel_headers = true;

    _ = try model.handleKey("/");
    for ("alpha") |ch| {
        const key = [_]u8{ch};
        _ = try model.handleKey(key[0..]);
    }
    _ = try model.handleKey("enter");

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try test_ansi.expectContainsPlain(std.testing.allocator, rendered, "Processes 1/3  filter: alpha\n");
}

test "process list renderer keeps selected process visible inside terminal height" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(3);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();
    model.show_panel_headers = true;
    model.term_height = 2;

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try test_ansi.expectEqualPlain(std.testing.allocator, "Processes 3/3\n> ■ gamma-db\n", rendered);
}

test "process list renderer selects first row when active id is zero like legacy behavior" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = .none;

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try test_ansi.expectEqualPlain(
        std.testing.allocator,
        "> ■ alpha-api\n  ● beta-worker\n  ■ gamma-db\n",
        rendered,
    );
}

test "process list renderer includes status pid and categories in debug mode" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";
    cfg.layout.enable_debug_process_info = true;
    try config.schema.appendOwned(std.testing.allocator, &cfg.procs.getPtr("beta-worker").?.categories, "worker");
    try config.schema.appendOwned(std.testing.allocator, &cfg.procs.getPtr("beta-worker").?.categories, "queue");

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try test_ansi.expectContainsPlain(
        std.testing.allocator,
        rendered,
        "> ● beta-worker [Running] PID:1234 [worker,queue]\n",
    );
}

test "process list renderer shows friendly empty message" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();

    _ = try model.handleKey("/");
    for ("zzzzz") |ch| {
        const key = [_]u8{ch};
        _ = try model.handleKey(key[0..]);
    }

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("Filter: zzzzz\nNo matching processes\n", rendered);
}

test "process list renderer shows selected process description above list" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";
    cfg.procs.getPtr("beta-worker").?.description = try std.testing.allocator.dupe(u8, "Runs background jobs");

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try test_ansi.expectEqualPlain(
        std.testing.allocator,
        "Runs background jobs\n  ■ alpha-api\n> ● beta-worker\n  ■ gamma-db\n",
        rendered,
    );
}

test "process list renderer wraps selected process description to terminal width" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";
    cfg.procs.getPtr("beta-worker").?.description = try std.testing.allocator.dupe(u8, "alpha beta gamma delta");

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();
    model.term_width = 12;

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try test_ansi.expectEqualPlain(
        std.testing.allocator,
        "alpha beta\ngamma delta\n  ■ alpha-api\n> ● beta-worker\n  ■ gamma-db\n",
        rendered,
    );
}

test "process list renderer hides selected process description when configured" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";
    cfg.layout.hide_process_description_panel = true;
    cfg.procs.getPtr("beta-worker").?.description = try std.testing.allocator.dupe(u8, "Runs background jobs");

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try test_ansi.expectEqualPlain(
        std.testing.allocator,
        "  ■ alpha-api\n> ● beta-worker\n  ■ gamma-db\n",
        rendered,
    );
}

test "process list renderer shows help panel when toggled" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();

    _ = try model.handleKey("?");

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try test_ansi.expectEqualPlain(
        std.testing.allocator,
        "k/↑ move up      s/⏎ start process      / filter processes       d          show docs\n" ++
            "j/↓ move down    x   stop process       ⏎ apply filter           ?          toggle help\n" ++
            "                 r   restart process    R toggle running only    ctrl+w     toggle focus\n" ++
            "                                                                 ctrl+left  focus client\n" ++
            "                                                                 ctrl+right focus server\n" ++
            "                                                                 q/^C       quit\n" ++
            "[Client Mode - Connected to Primary]\n" ++
            "  ■ alpha-api\n> ● beta-worker\n  ■ gamma-db\n",
        rendered,
    );
}

test "help overlay renders full-width help content" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();

    const rendered = try renderHelpOverlay(std.testing.allocator, &model, 100, 30);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Help") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Focus") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ctrl+left focus client") != null);
}

test "process list renderer shows only the five most recent messages" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();

    try model.addMessage("oldest message");
    try model.addMessage("message two");
    try model.addMessage("message three");
    try model.addMessage("message four");
    try model.addMessage("message five");
    try model.addMessage("newest message");

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "oldest message") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "- message two\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "- newest message\n") != null);
}

test "process list renderer wraps long messages with bullet indentation" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();
    model.term_width = 10;

    try model.addMessage("alpha beta gamma");

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Messages:\n- alpha\n  beta\n  gamma\n") != null);
}

test "process list renderer hides expired messages before pruning" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();

    try model.addMessageAt("expired message", std.time.milliTimestamp() - client_model.message_timeout_ms - 1);

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "expired message") == null);
}

test "process list renderer shows focused filter prompt" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();

    _ = try model.handleKey("/");
    for ("alpha") |ch| {
        const key = [_]u8{ch};
        _ = try model.handleKey(key[0..]);
    }

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try test_ansi.expectEqualPlain(std.testing.allocator, "Filter: alpha\n> ■ alpha-api\n", rendered);
}

test "process list renderer shows submitted filter indicator" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();

    _ = try model.handleKey("/");
    for ("alpha") |ch| {
        const key = [_]u8{ch};
        _ = try model.handleKey(key[0..]);
    }
    _ = try model.handleKey("enter");

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try test_ansi.expectEqualPlain(std.testing.allocator, "Filter: alpha (/ to edit, esc to clear)\n> ■ alpha-api\n", rendered);
}

test "process list renderer keeps filter prompt when no processes match" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var snapshot = try test_config.snapshotFromViews(std.testing.allocator, &cfg, app_state.current_proc_id, views[0..]);
    defer snapshot.deinit(std.testing.allocator);

    var model = try client_model.ClientModel.init(std.testing.allocator, snapshot.view());
    defer model.deinit();

    _ = try model.handleKey("/");
    for ("zzzzz") |ch| {
        const key = [_]u8{ch};
        _ = try model.handleKey(key[0..]);
    }

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("Filter: zzzzz\nNo matching processes\n", rendered);
}

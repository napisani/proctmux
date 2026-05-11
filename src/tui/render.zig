const std = @import("std");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");
const test_config = @import("../test_support/config.zig");
const client_model = @import("client_model.zig");

pub fn renderProcessList(allocator: std.mem.Allocator, model: *const client_model.ClientModel) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try appendHelpPanel(&out, model);
    try appendSelectedDescription(&out, model);
    try appendMessagesPanel(&out, model);
    try appendFilterPanel(&out, model);

    if (model.filtered_views.len == 0) {
        try out.appendSlice("No matching processes\n");
        return out.toOwnedSlice();
    }

    for (model.filtered_views, 0..) |view, index| {
        const selected = if (model.active_proc_id.isNone())
            index == 0
        else
            view.id == model.active_proc_id;
        if (selected) {
            try out.appendSlice(model.app_state.config.style.pointer_char);
            try out.append(' ');
        } else {
            try out.appendSlice("  ");
        }

        try out.appendSlice(statusMarker(view.status));
        try out.append(' ');
        if (model.app_state.config.layout.enable_debug_process_info) {
            try out.appendSlice(view.label);
            try out.appendSlice(" [");
            try out.appendSlice(domain.process.statusName(view.status));
            try out.writer().print("] PID:{}", .{view.pid});
            if (view.config.categories.items.len > 0) {
                try out.appendSlice(" [");
                for (view.config.categories.items, 0..) |category, category_index| {
                    if (category_index != 0) try out.append(',');
                    try out.appendSlice(category);
                }
                try out.append(']');
            }
        } else {
            try out.appendSlice(view.label);
        }
        try out.append('\n');
    }

    return out.toOwnedSlice();
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

    const keys = model.app_state.config.keybinding;
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
    keys: config.schema.StringList,
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

fn appendBindingText(out: *std.array_list.Managed(u8), keys: config.schema.StringList) !void {
    for (keys.items, 0..) |key, index| {
        if (index >= 2) break;
        if (index != 0) try out.append('/');
        try out.appendSlice(formatKey(key));
    }
}

fn bindingDisplayWidth(keys: config.schema.StringList) usize {
    var width: usize = 0;
    for (keys.items, 0..) |key, index| {
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

fn appendBinding(out: *std.array_list.Managed(u8), keys: config.schema.StringList, label: []const u8) !void {
    for (keys.items, 0..) |key, index| {
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
    if (model.app_state.config.layout.hide_process_description_panel) return;

    const process = model.app_state.getProcessByID(model.active_proc_id) orelse return;
    const description = std.mem.trim(u8, process.config.description, " \t\r\n");
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

test "process list renderer writes pointer status marker and labels" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var model = try client_model.ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "  ■ alpha-api\n> ● beta-worker\n  ■ gamma-db\n",
        rendered,
    );
}

test "process list renderer selects first row when active id is zero like Go" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = .none;

    var views = test_config.standardRenderViews(&cfg);
    var model = try client_model.ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
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
    var model = try client_model.ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "> ● beta-worker [Running] PID:1234 [worker,queue]\n",
    ) != null);
}

test "process list renderer shows friendly empty message" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();

    var views = test_config.standardRenderViews(&cfg);
    var model = try client_model.ClientModel.init(std.testing.allocator, &app_state, views[0..]);
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
    var model = try client_model.ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
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
    var model = try client_model.ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();
    model.term_width = 12;

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
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
    var model = try client_model.ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
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
    var model = try client_model.ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    _ = try model.handleKey("?");

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
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

test "process list renderer shows only the five most recent messages" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var model = try client_model.ClientModel.init(std.testing.allocator, &app_state, views[0..]);
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
    var model = try client_model.ClientModel.init(std.testing.allocator, &app_state, views[0..]);
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
    var model = try client_model.ClientModel.init(std.testing.allocator, &app_state, views[0..]);
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
    var model = try client_model.ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    _ = try model.handleKey("/");
    for ("alpha") |ch| {
        const key = [_]u8{ch};
        _ = try model.handleKey(key[0..]);
    }

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("Filter: alpha\n> ■ alpha-api\n", rendered);
}

test "process list renderer shows submitted filter indicator" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.style.pointer_char = ">";

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var model = try client_model.ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    _ = try model.handleKey("/");
    for ("alpha") |ch| {
        const key = [_]u8{ch};
        _ = try model.handleKey(key[0..]);
    }
    _ = try model.handleKey("enter");

    const rendered = try renderProcessList(std.testing.allocator, &model);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("Filter: alpha (/ to edit, esc to clear)\n> ■ alpha-api\n", rendered);
}

test "process list renderer keeps filter prompt when no processes match" {
    var cfg = try test_config.standardRenderConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardRenderViews(&cfg);
    var model = try client_model.ClientModel.init(std.testing.allocator, &app_state, views[0..]);
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

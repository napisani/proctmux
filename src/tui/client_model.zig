const std = @import("std");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");
const ipc = @import("../ipc/root.zig");
const test_config = @import("../test_support/config.zig");

pub const CommandIntent = struct {
    action: ipc.protocol.Command,
    label: []const u8,
};

pub const message_timeout_ms: i64 = 5000;

pub const TimedMessage = struct {
    text: []const u8,
    expires_at_ms: i64,
};

pub const ClientModel = struct {
    allocator: std.mem.Allocator,
    app_state: *domain.state.AppState,
    process_views: []const domain.process.ProcessView,
    filtered_views: []domain.process.ProcessView,
    filter_text: std.array_list.Managed(u8),
    messages: std.array_list.Managed(TimedMessage),
    entering_filter_text: bool = false,
    show_only_running: bool = false,
    show_help: bool = false,
    mode: domain.state.Mode = .normal,
    active_proc_id: domain.process.ProcessId = .none,
    term_width: usize = 80,
    term_height: usize = 0,
    no_color: bool = false,
    show_panel_headers: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        app_state: *domain.state.AppState,
        process_views: []const domain.process.ProcessView,
    ) !ClientModel {
        var model = ClientModel{
            .allocator = allocator,
            .app_state = app_state,
            .process_views = process_views,
            .filtered_views = try allocator.alloc(domain.process.ProcessView, 0),
            .filter_text = std.array_list.Managed(u8).init(allocator),
            .messages = std.array_list.Managed(TimedMessage).init(allocator),
            .active_proc_id = app_state.current_proc_id,
        };
        errdefer model.deinit();
        try model.rebuildProcessList();
        return model;
    }

    pub fn deinit(self: *ClientModel) void {
        self.allocator.free(self.filtered_views);
        self.filter_text.deinit();
        for (self.messages.items) |message_entry| self.allocator.free(message_entry.text);
        self.messages.deinit();
    }

    pub fn filterText(self: *const ClientModel) []const u8 {
        return self.filter_text.items;
    }

    pub fn addMessage(self: *ClientModel, text: []const u8) !void {
        try self.addMessageAt(text, std.time.milliTimestamp());
    }

    pub fn addMessageAt(self: *ClientModel, text: []const u8, now_ms: i64) !void {
        if (text.len == 0) return;
        self.pruneExpiredMessages(now_ms);
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.messages.append(.{
            .text = owned,
            .expires_at_ms = now_ms + message_timeout_ms,
        });
    }

    pub fn pruneExpiredMessages(self: *ClientModel, now_ms: i64) void {
        if (self.messages.items.len == 0) return;

        var write_index: usize = 0;
        for (self.messages.items) |message_entry| {
            if (now_ms < message_entry.expires_at_ms) {
                self.messages.items[write_index] = message_entry;
                write_index += 1;
            } else {
                self.allocator.free(message_entry.text);
            }
        }
        self.messages.items.len = write_index;
    }

    pub fn messageCount(self: *const ClientModel) usize {
        return self.messages.items.len;
    }

    pub fn message(self: *const ClientModel, index: usize) []const u8 {
        return self.messages.items[index].text;
    }

    pub fn visibleCount(self: *const ClientModel) usize {
        return self.filtered_views.len;
    }

    pub fn visibleLabel(self: *const ClientModel, index: usize) []const u8 {
        return self.filtered_views[index].label;
    }

    pub fn activeProcessLabel(self: *ClientModel) []const u8 {
        return self.activeProcLabel();
    }

    pub fn replaceStatePreservingUI(
        self: *ClientModel,
        app_state: *domain.state.AppState,
        process_views: []const domain.process.ProcessView,
    ) !void {
        const new_filtered_views = try domain.filter.filterProcesses(
            self.allocator,
            app_state.config,
            process_views,
            self.filter_text.items,
            self.show_only_running,
        );

        self.allocator.free(self.filtered_views);
        self.app_state = app_state;
        self.process_views = process_views;
        self.filtered_views = new_filtered_views;
    }

    pub fn handleKey(self: *ClientModel, key: []const u8) !?CommandIntent {
        if (self.entering_filter_text) {
            if (self.processListIntentForControlModifiedKey(key)) |intent| return intent;

            if (matches(self.app_state.config.keybinding.submit_filter, key)) {
                self.entering_filter_text = false;
                self.mode = .normal;
                return self.applyFilterNow();
            }
            if (matches(self.app_state.config.keybinding.filter, key)) {
                self.entering_filter_text = false;
                self.mode = .normal;
                try self.rebuildProcessList();
                return null;
            }
            if (std.mem.eql(u8, key, "esc")) {
                self.entering_filter_text = false;
                self.mode = .normal;
                self.filter_text.clearRetainingCapacity();
                return self.applyFilterNow();
            }
            if (std.mem.eql(u8, key, "delete") or std.mem.eql(u8, key, "backspace")) {
                if (self.filter_text.items.len > 0) self.filter_text.items.len -= 1;
                return self.applyFilterNow();
            }
            if (self.navigationIntentForSpecialKey(key)) |intent| return intent;

            if (isTextInputKey(key)) {
                try self.filter_text.appendSlice(key);
                return self.applyFilterNow();
            }
            return null;
        }

        if (matches(self.app_state.config.keybinding.filter, key)) {
            self.entering_filter_text = true;
            self.mode = .filter;
            self.filter_text.clearRetainingCapacity();
            self.active_proc_id = .none;
            try self.rebuildProcessList();
            return null;
        }
        if (matches(self.app_state.config.keybinding.down, key)) {
            self.moveSelection(1);
            return self.switchIntent();
        }
        if (matches(self.app_state.config.keybinding.up, key)) {
            self.moveSelection(-1);
            return self.switchIntent();
        }
        if (matches(self.app_state.config.keybinding.toggle_running, key)) {
            self.show_only_running = !self.show_only_running;
            return self.applyFilterNow();
        }
        if (matches(self.app_state.config.keybinding.start, key)) {
            return self.commandIntent(.start);
        }
        if (matches(self.app_state.config.keybinding.stop, key)) {
            return self.commandIntent(.stop);
        }
        if (matches(self.app_state.config.keybinding.restart, key)) {
            return self.commandIntent(.restart);
        }
        if (matches(self.app_state.config.keybinding.toggle_help, key)) {
            self.show_help = !self.show_help;
            return null;
        }
        if (matches(self.app_state.config.keybinding.quit, key)) {
            return .{
                .action = .stop_running,
                .label = "",
            };
        }
        return null;
    }

    fn applyFilterNow(self: *ClientModel) !?CommandIntent {
        try self.rebuildProcessList();
        if (self.filtered_views.len == 0) {
            self.active_proc_id = .none;
            return null;
        }

        self.active_proc_id = self.filtered_views[0].id;
        return .{
            .action = .switch_process,
            .label = self.activeProcLabel(),
        };
    }

    fn switchIntent(self: *ClientModel) CommandIntent {
        return self.commandIntent(.switch_process);
    }

    fn processListIntentForControlModifiedKey(self: *ClientModel, key: []const u8) ?CommandIntent {
        const process_list_key = controlModifiedKey(key) orelse return null;
        const bindings = &self.app_state.config.keybinding;

        if (self.navigationIntentForKey(process_list_key)) |intent| return intent;
        if (matches(bindings.start, process_list_key)) return self.commandIntent(.start);
        if (matches(bindings.stop, process_list_key)) return self.commandIntent(.stop);
        if (matches(bindings.restart, process_list_key)) return self.commandIntent(.restart);
        return null;
    }

    fn navigationIntentForSpecialKey(self: *ClientModel, key: []const u8) ?CommandIntent {
        if (isTextInputKey(key)) return null;
        return self.navigationIntentForKey(key);
    }

    fn navigationIntentForKey(self: *ClientModel, key: []const u8) ?CommandIntent {
        const bindings = &self.app_state.config.keybinding;
        if (matches(bindings.down, key)) {
            self.moveSelection(1);
            if (self.active_proc_id.isNone()) return null;
            return self.switchIntent();
        }
        if (matches(bindings.up, key)) {
            self.moveSelection(-1);
            if (self.active_proc_id.isNone()) return null;
            return self.switchIntent();
        }
        return null;
    }

    fn commandIntent(self: *ClientModel, action: ipc.protocol.Command) CommandIntent {
        return .{
            .action = action,
            .label = self.activeProcLabel(),
        };
    }

    fn moveSelection(self: *ClientModel, delta: i32) void {
        if (self.filtered_views.len == 0) {
            self.active_proc_id = .none;
            return;
        }
        if (self.filtered_views.len == 1) {
            self.active_proc_id = self.filtered_views[0].id;
            return;
        }

        var current_index: ?usize = null;
        for (self.filtered_views, 0..) |view, index| {
            if (view.id == self.active_proc_id) {
                current_index = index;
                break;
            }
        }

        const index = current_index orelse {
            self.active_proc_id = self.filtered_views[0].id;
            return;
        };
        const next_index = if (delta < 0 and index == 0)
            self.filtered_views.len - 1
        else if (delta < 0)
            index - 1
        else
            (index + 1) % self.filtered_views.len;
        self.active_proc_id = self.filtered_views[next_index].id;
    }

    fn activeProcLabel(self: *ClientModel) []const u8 {
        if (self.app_state.getProcessByID(self.active_proc_id)) |proc| return proc.label;
        return "";
    }

    fn rebuildProcessList(self: *ClientModel) !void {
        self.allocator.free(self.filtered_views);
        self.filtered_views = try domain.filter.filterProcesses(
            self.allocator,
            self.app_state.config,
            self.process_views,
            self.filter_text.items,
            self.show_only_running,
        );
    }
};

fn matches(bindings: config.schema.StringList, key: []const u8) bool {
    for (bindings.items) |binding| {
        if (std.mem.eql(u8, binding, key)) return true;
    }
    return false;
}

fn controlModifiedKey(key: []const u8) ?[]const u8 {
    const prefix = "ctrl+";
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    const unmodified = key[prefix.len..];
    if (unmodified.len == 0) return null;
    return unmodified;
}

fn isTextInputKey(key: []const u8) bool {
    return key.len == 1 and key[0] >= 0x20 and key[0] <= 0x7e;
}

fn replaceTestBinding(list: *config.schema.StringList, values: []const []const u8) !void {
    config.schema.deinitStringList(list);
    list.* = config.schema.StringList.init(std.testing.allocator);
    for (values) |value| try config.schema.appendOwned(std.testing.allocator, list, value);
}

test "client model enters filter mode with configured filter key" {
    var cfg = try test_config.standardClientModelConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(1);

    var views = test_config.standardClientModelViews(&cfg);

    var model = try ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    _ = try model.handleKey("/");

    try std.testing.expect(model.entering_filter_text);
    try std.testing.expectEqual(domain.state.Mode.filter, model.mode);
    try std.testing.expectEqualStrings("", model.filterText());
    try std.testing.expectEqual(domain.process.ProcessId.none, model.active_proc_id);
}

test "client model typing filter narrows list and selects first match" {
    var cfg = try test_config.standardClientModelConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(1);

    var views = test_config.standardClientModelViews(&cfg);
    var model = try ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    _ = try model.handleKey("/");
    var intent: ?CommandIntent = null;
    for ("gamma") |ch| {
        const key = [_]u8{ch};
        intent = try model.handleKey(key[0..]);
    }

    try std.testing.expectEqualStrings("gamma", model.filterText());
    try std.testing.expectEqual(@as(usize, 1), model.visibleCount());
    try std.testing.expectEqualStrings("gamma-db", model.visibleLabel(0));
    try std.testing.expectEqual(domain.process.ProcessId.fromInt(3), model.active_proc_id);
    try std.testing.expectEqual(ipc.protocol.Command.switch_process, intent.?.action);
    try std.testing.expectEqualStrings("gamma-db", intent.?.label);
}

test "client model backspace edits filter text" {
    var cfg = try test_config.standardClientModelConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(1);

    var views = test_config.standardClientModelViews(&cfg);
    var model = try ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    _ = try model.handleKey("/");
    for ("alp") |ch| {
        const key = [_]u8{ch};
        _ = try model.handleKey(key[0..]);
    }

    _ = try model.handleKey("delete");
    _ = try model.handleKey("h");

    try std.testing.expectEqualStrings("alh", model.filterText());
}

test "client model control-modified process list keys work while typing filter" {
    var cfg = try test_config.standardClientModelConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(1);

    var views = test_config.standardClientModelViews(&cfg);
    var model = try ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    _ = try model.handleKey("/");
    _ = try model.handleKey("a");

    try std.testing.expect(model.entering_filter_text);
    try std.testing.expectEqualStrings("a", model.filterText());
    try std.testing.expect(model.visibleCount() > 1);

    const first_id = model.active_proc_id;
    const second_label = model.visibleLabel(1);
    const down = try model.handleKey("ctrl+j");

    try std.testing.expect(model.entering_filter_text);
    try std.testing.expectEqual(domain.state.Mode.filter, model.mode);
    try std.testing.expectEqualStrings("a", model.filterText());
    try std.testing.expect(down != null);
    try std.testing.expectEqual(ipc.protocol.Command.switch_process, down.?.action);
    try std.testing.expectEqualStrings(second_label, down.?.label);
    try std.testing.expect(model.active_proc_id != first_id);

    const up = try model.handleKey("ctrl+k");

    try std.testing.expect(model.entering_filter_text);
    try std.testing.expectEqualStrings("a", model.filterText());
    try std.testing.expect(up != null);
    try std.testing.expectEqual(ipc.protocol.Command.switch_process, up.?.action);
    try std.testing.expectEqual(first_id, model.active_proc_id);

    const start = try model.handleKey("ctrl+s");
    try std.testing.expect(model.entering_filter_text);
    try std.testing.expectEqualStrings("a", model.filterText());
    try std.testing.expect(start != null);
    try std.testing.expectEqual(ipc.protocol.Command.start, start.?.action);
    try std.testing.expectEqualStrings(model.activeProcessLabel(), start.?.label);

    const stop = try model.handleKey("ctrl+x");
    try std.testing.expect(model.entering_filter_text);
    try std.testing.expectEqualStrings("a", model.filterText());
    try std.testing.expect(stop != null);
    try std.testing.expectEqual(ipc.protocol.Command.stop, stop.?.action);
    try std.testing.expectEqualStrings(model.activeProcessLabel(), stop.?.label);
}

test "client model navigates on special up and down keys while typing filter" {
    var cfg = try test_config.standardClientModelConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(1);

    var views = test_config.standardClientModelViews(&cfg);
    var model = try ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    _ = try model.handleKey("/");
    _ = try model.handleKey("a");

    const first_id = model.active_proc_id;
    const down = try model.handleKey("down");
    try std.testing.expect(down != null);
    try std.testing.expectEqual(ipc.protocol.Command.switch_process, down.?.action);
    try std.testing.expect(model.active_proc_id != first_id);

    const up = try model.handleKey("up");
    try std.testing.expect(up != null);
    try std.testing.expectEqual(ipc.protocol.Command.switch_process, up.?.action);
    try std.testing.expectEqual(first_id, model.active_proc_id);
    try std.testing.expect(model.entering_filter_text);
    try std.testing.expectEqualStrings("a", model.filterText());

    _ = try model.handleKey("j");
    try std.testing.expectEqualStrings("aj", model.filterText());
}

test "client model control modifier honors configured process list bindings" {
    var cfg = try test_config.standardClientModelConfig(std.testing.allocator);
    defer cfg.deinit();
    try replaceTestBinding(&cfg.keybinding.down, &.{"n"});
    try replaceTestBinding(&cfg.keybinding.up, &.{"p"});

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(1);

    var views = test_config.standardClientModelViews(&cfg);
    var model = try ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    _ = try model.handleKey("/");
    _ = try model.handleKey("a");

    const first_id = model.active_proc_id;
    const down = try model.handleKey("ctrl+n");
    try std.testing.expect(down != null);
    try std.testing.expectEqual(ipc.protocol.Command.switch_process, down.?.action);
    try std.testing.expect(model.active_proc_id != first_id);

    const up = try model.handleKey("ctrl+p");
    try std.testing.expect(up != null);
    try std.testing.expectEqual(ipc.protocol.Command.switch_process, up.?.action);
    try std.testing.expectEqual(first_id, model.active_proc_id);
    try std.testing.expect(model.entering_filter_text);
    try std.testing.expectEqualStrings("a", model.filterText());
}

test "client model ctrl arrows move selection while typing filter when arrow keys are configured" {
    var cfg = try test_config.standardClientModelConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(1);

    var views = test_config.standardClientModelViews(&cfg);
    var model = try ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    _ = try model.handleKey("/");
    _ = try model.handleKey("a");

    const first_id = model.active_proc_id;
    const down = try model.handleKey("ctrl+down");
    try std.testing.expect(down != null);
    try std.testing.expectEqual(ipc.protocol.Command.switch_process, down.?.action);
    try std.testing.expect(model.active_proc_id != first_id);

    const up = try model.handleKey("ctrl+up");
    try std.testing.expect(up != null);
    try std.testing.expectEqual(ipc.protocol.Command.switch_process, up.?.action);
    try std.testing.expectEqual(first_id, model.active_proc_id);
    try std.testing.expect(model.entering_filter_text);
    try std.testing.expectEqualStrings("a", model.filterText());
}

test "client model down key moves selection and wraps within visible list" {
    var cfg = try test_config.standardClientModelConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(1);

    var views = test_config.standardClientModelViews(&cfg);
    var model = try ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    const beta = try model.handleKey("j");
    try std.testing.expectEqual(domain.process.ProcessId.fromInt(2), model.active_proc_id);
    try std.testing.expectEqual(ipc.protocol.Command.switch_process, beta.?.action);
    try std.testing.expectEqualStrings("beta-worker", beta.?.label);

    _ = try model.handleKey("j");
    const wrapped = try model.handleKey("j");
    try std.testing.expectEqual(domain.process.ProcessId.fromInt(1), model.active_proc_id);
    try std.testing.expectEqual(ipc.protocol.Command.switch_process, wrapped.?.action);
    try std.testing.expectEqualStrings("alpha-api", wrapped.?.label);
}

test "client model running-only toggle filters visible list and selects first running process" {
    var cfg = try test_config.standardClientModelConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardClientModelViews(&cfg);
    var model = try ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    const intent = try model.handleKey("R");

    try std.testing.expect(model.show_only_running);
    try std.testing.expectEqual(@as(usize, 2), model.visibleCount());
    try std.testing.expectEqualStrings("alpha-api", model.visibleLabel(0));
    try std.testing.expectEqualStrings("gamma-db", model.visibleLabel(1));
    try std.testing.expectEqual(domain.process.ProcessId.fromInt(1), model.active_proc_id);
    try std.testing.expectEqual(ipc.protocol.Command.switch_process, intent.?.action);
    try std.testing.expectEqualStrings("alpha-api", intent.?.label);
}

test "client model process control keys target active process" {
    var cfg = try test_config.standardClientModelConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var views = test_config.standardClientModelViews(&cfg);
    var model = try ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    const start = try model.handleKey("s");
    try std.testing.expect(start != null);
    try std.testing.expectEqual(ipc.protocol.Command.start, start.?.action);
    try std.testing.expectEqualStrings("beta-worker", start.?.label);

    const stop = try model.handleKey("x");
    try std.testing.expect(stop != null);
    try std.testing.expectEqual(ipc.protocol.Command.stop, stop.?.action);
    try std.testing.expectEqualStrings("beta-worker", stop.?.label);

    const restart = try model.handleKey("r");
    try std.testing.expect(restart != null);
    try std.testing.expectEqual(ipc.protocol.Command.restart, restart.?.action);
    try std.testing.expectEqualStrings("beta-worker", restart.?.label);
}

test "client model help key toggles help visibility" {
    var cfg = try test_config.standardClientModelConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();

    var views = test_config.standardClientModelViews(&cfg);
    var model = try ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    _ = try model.handleKey("?");
    try std.testing.expect(model.show_help);

    _ = try model.handleKey("?");
    try std.testing.expect(!model.show_help);
}

test "client model quit key emits stop-running intent" {
    var cfg = try test_config.standardClientModelConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();

    var views = test_config.standardClientModelViews(&cfg);
    var model = try ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    const intent = try model.handleKey("q");
    try std.testing.expect(intent != null);
    try std.testing.expectEqual(ipc.protocol.Command.stop_running, intent.?.action);
    try std.testing.expectEqualStrings("", intent.?.label);
}

test "client model prunes messages after five second timeout" {
    var cfg = try test_config.standardClientModelConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();

    var views = test_config.standardClientModelViews(&cfg);
    var model = try ClientModel.init(std.testing.allocator, &app_state, views[0..]);
    defer model.deinit();

    try model.addMessageAt("expired", 0);
    try model.addMessageAt("fresh", 1);

    model.pruneExpiredMessages(message_timeout_ms);

    try std.testing.expectEqual(@as(usize, 1), model.messageCount());
    try std.testing.expectEqualStrings("fresh", model.message(0));
}

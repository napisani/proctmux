const std = @import("std");
const config = @import("../config/root.zig");

const unified_status_lines = 1;
const unified_client_ratio = 55;
const min_client_width = 24;
const min_terminal_width = 32;
const client_width_padding = 6;
const min_client_height = 8;
const min_terminal_height = 10;

pub const Orientation = enum {
    left,
    right,
    top,
    bottom,
};

pub const Pane = enum {
    client,
    server,
};

pub const Size = struct {
    width: i32,
    height: i32,
};

pub const InputSink = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,

    fn writeAll(self: InputSink, bytes: []const u8) !void {
        try self.write(self.context, bytes);
    }
};

pub const Model = struct {
    orientation: Orientation,
    app_config: *const config.schema.Config,
    focus: Pane = .client,
    server_input: ?InputSink = null,
    status_height: i32 = 0,
    content_width: i32 = 0,
    content_height: i32 = 0,
    client_width: i32 = 0,
    client_height: i32 = 0,
    server_width: i32 = 0,
    server_height: i32 = 0,
    longest_process_label_width: i32 = 0,

    pub fn init(orientation: Orientation, app_config: *const config.schema.Config) Model {
        return .{
            .orientation = orientation,
            .app_config = app_config,
        };
    }

    pub fn focusedPane(self: *const Model) Pane {
        return self.focus;
    }

    pub fn clientVisible(self: *const Model) bool {
        if (!self.app_config.layout.hide_process_list_when_unfocused) return true;
        return self.focus == .client;
    }

    pub fn setServerInput(self: *Model, sink: InputSink) void {
        self.server_input = sink;
    }

    pub fn setProcessLabels(self: *Model, labels: []const []const u8) void {
        self.longest_process_label_width = 0;
        for (labels) |label| {
            const width: i32 = @intCast(label.len);
            if (width > self.longest_process_label_width) self.longest_process_label_width = width;
        }
    }

    pub fn handleKey(self: *Model, key: []const u8) !void {
        if (matches(self.app_config.keybinding.focus_client, key) or std.mem.eql(u8, key, "ctrl+left")) {
            self.focus = .client;
            self.relayoutAfterFocusChange();
            return;
        }
        if (matches(self.app_config.keybinding.focus_server, key) or std.mem.eql(u8, key, "ctrl+right")) {
            self.focus = .server;
            self.relayoutAfterFocusChange();
            return;
        }
        if (matches(self.app_config.keybinding.toggle_focus, key)) {
            self.focus = if (self.focus == .client) .server else .client;
            self.relayoutAfterFocusChange();
            return;
        }

        if (self.focus == .server) {
            if (self.server_input) |sink| {
                if (terminalInputForKey(key)) |input| try sink.writeAll(input);
            }
            return;
        }
    }

    pub fn resize(self: *Model, width: i32, height: i32) !void {
        if (width <= 0 or height <= 0) return;

        self.status_height = if (height <= unified_status_lines + 1) 0 else unified_status_lines;
        self.content_width = width;
        self.content_height = @max(height - self.status_height, 0);
        self.recalculateLayout();
    }

    pub fn clientSize(self: *const Model) Size {
        return .{ .width = self.client_width, .height = self.client_height };
    }

    pub fn serverSize(self: *const Model) Size {
        return .{ .width = self.server_width, .height = self.server_height };
    }

    pub fn statusBar(self: *const Model, allocator: std.mem.Allocator) ![]const u8 {
        if (self.status_height == 0) return allocator.dupe(u8, "");

        const client_label = if (self.focus == .client) "Client" else "client";
        const server_label = if (self.focus == .server) "Server" else "server";
        const hidden_label = if (!self.clientVisible()) "    process list hidden" else "";
        const toggle_label = firstBinding(self.app_config.keybinding.toggle_focus);
        return std.fmt.allocPrint(
            allocator,
            "{s} | {s}    {s} focus client; {s} focus server; {s} toggle focus{s}",
            .{
                client_label,
                server_label,
                firstBinding(self.app_config.keybinding.focus_client),
                firstBinding(self.app_config.keybinding.focus_server),
                toggle_label,
                hidden_label,
            },
        );
    }

    fn relayoutAfterFocusChange(self: *Model) void {
        if (self.app_config.layout.hide_process_list_when_unfocused and self.content_width > 0) {
            self.recalculateLayout();
        }
    }

    fn recalculateLayout(self: *Model) void {
        const hidden = !self.clientVisible();
        switch (self.orientation) {
            .left, .right => {
                if (hidden) {
                    self.client_width = 0;
                    self.client_height = 0;
                    self.server_width = self.content_width;
                    self.server_height = self.content_height;
                    return;
                }

                var client_width = self.desiredClientWidth();
                if (client_width < min_client_width and self.content_width >= min_client_width) {
                    client_width = min_client_width;
                }
                if (client_width >= self.content_width) {
                    client_width = @divTrunc(self.content_width, 2);
                }

                var server_width = self.content_width - client_width;
                if (server_width < min_terminal_width and self.content_width >= min_client_width + min_terminal_width) {
                    server_width = min_terminal_width;
                    client_width = self.content_width - server_width;
                }
                if (server_width < 0) {
                    server_width = 0;
                    client_width = self.content_width;
                }

                self.client_width = client_width;
                self.client_height = self.content_height;
                self.server_width = server_width;
                self.server_height = self.content_height;
            },
            .top, .bottom => {
                if (hidden) {
                    self.client_width = 0;
                    self.client_height = 0;
                    self.server_width = self.content_width;
                    self.server_height = self.content_height;
                    return;
                }

                var client_height = @divTrunc(self.content_height * unified_client_ratio, 100);
                if (client_height < min_client_height and self.content_height >= min_client_height) {
                    client_height = min_client_height;
                }
                if (client_height >= self.content_height) {
                    client_height = @divTrunc(self.content_height, 2);
                }

                var server_height = self.content_height - client_height;
                if (server_height < min_terminal_height and self.content_height >= min_client_height + min_terminal_height) {
                    server_height = min_terminal_height;
                    client_height = self.content_height - server_height;
                }
                if (server_height < 0) server_height = 0;

                self.client_width = self.content_width;
                self.client_height = client_height;
                self.server_width = self.content_width;
                self.server_height = server_height;
            },
        }
    }

    fn desiredClientWidth(self: *const Model) i32 {
        var desired: i32 = @max(self.longest_process_label_width + client_width_padding, min_client_width);

        if (self.content_width <= min_client_width + min_terminal_width) {
            if (self.content_width <= 0) return desired;
            const fallback = @max(@divTrunc(self.content_width, 2), min_client_width);
            return @min(fallback, self.content_width);
        }

        var max_allowed = self.content_width - min_terminal_width;
        if (max_allowed < min_client_width) max_allowed = @divTrunc(self.content_width, 2);
        if (desired > max_allowed) desired = max_allowed;
        if (desired < min_client_width) desired = min_client_width;
        if (desired > self.content_width) desired = self.content_width;
        return desired;
    }
};

pub fn terminalInputForKey(key: []const u8) ?[]const u8 {
    if (key.len == 1) return key;
    if (std.mem.eql(u8, key, "enter")) return "\n";
    if (std.mem.eql(u8, key, "tab")) return "\t";
    if (std.mem.eql(u8, key, "backspace")) return "\x08";
    if (std.mem.eql(u8, key, "delete")) return "\x7f";
    if (std.mem.eql(u8, key, "esc")) return "\x1b";
    if (std.mem.eql(u8, key, "up")) return "\x1b[A";
    if (std.mem.eql(u8, key, "down")) return "\x1b[B";
    if (std.mem.eql(u8, key, "right")) return "\x1b[C";
    if (std.mem.eql(u8, key, "left")) return "\x1b[D";
    if (std.mem.eql(u8, key, "home")) return "\x1b[H";
    if (std.mem.eql(u8, key, "end")) return "\x1b[F";
    if (std.mem.eql(u8, key, "pageup")) return "\x1b[5~";
    if (std.mem.eql(u8, key, "pagedown")) return "\x1b[6~";
    if (std.mem.eql(u8, key, "insert")) return "\x1b[2~";
    if (std.mem.eql(u8, key, "f1")) return "\x1bOP";
    if (std.mem.eql(u8, key, "f2")) return "\x1bOQ";
    if (std.mem.eql(u8, key, "f3")) return "\x1bOR";
    if (std.mem.eql(u8, key, "f4")) return "\x1bOS";
    if (std.mem.eql(u8, key, "f5")) return "\x1b[15~";
    if (std.mem.eql(u8, key, "f6")) return "\x1b[17~";
    if (std.mem.eql(u8, key, "f7")) return "\x1b[18~";
    if (std.mem.eql(u8, key, "f8")) return "\x1b[19~";
    if (std.mem.eql(u8, key, "f9")) return "\x1b[20~";
    if (std.mem.eql(u8, key, "f10")) return "\x1b[21~";
    if (std.mem.eql(u8, key, "f11")) return "\x1b[23~";
    if (std.mem.eql(u8, key, "f12")) return "\x1b[24~";
    if (std.mem.eql(u8, key, "ctrl+c")) return "\x03";
    if (std.mem.eql(u8, key, "ctrl+d")) return "\x04";
    if (std.mem.eql(u8, key, "ctrl+z")) return "\x1a";
    if (std.mem.eql(u8, key, "ctrl+l")) return "\x0c";
    return null;
}

fn matches(bindings: config.schema.StringList, key: []const u8) bool {
    for (bindings.items) |binding| {
        if (std.mem.eql(u8, binding, key)) return true;
    }
    return false;
}

fn firstBinding(bindings: config.schema.StringList) []const u8 {
    if (bindings.items.len == 0) return "";
    return bindings.items[0];
}

test "split model keeps client visible when hide on unfocus is disabled" {
    var cfg = try testConfig(false);
    defer cfg.deinit();

    var model = Model.init(.left, &cfg);

    try std.testing.expectEqual(Pane.client, model.focusedPane());
    try std.testing.expect(model.clientVisible());

    try model.handleKey("ctrl+right");
    try std.testing.expectEqual(Pane.server, model.focusedPane());
    try std.testing.expect(model.clientVisible());
}

test "split model hides client only after server focus when configured" {
    var cfg = try testConfig(true);
    defer cfg.deinit();

    var model = Model.init(.left, &cfg);

    try std.testing.expectEqual(Pane.client, model.focusedPane());
    try std.testing.expect(model.clientVisible());

    try model.handleKey("ctrl+right");
    try std.testing.expectEqual(Pane.server, model.focusedPane());
    try std.testing.expect(!model.clientVisible());
}

test "split model expands server pane when hidden client focus changes" {
    var cfg = try testConfig(true);
    defer cfg.deinit();

    var model = Model.init(.left, &cfg);
    try model.resize(120, 40);
    const visible_server = model.serverSize();

    try std.testing.expect(model.clientSize().width > 0);
    try std.testing.expect(model.serverSize().width > 0);

    try model.handleKey("ctrl+right");

    try std.testing.expectEqual(Size{ .width = 0, .height = 0 }, model.clientSize());
    try std.testing.expectEqual(Size{ .width = 120, .height = 39 }, model.serverSize());
    try std.testing.expect(model.serverSize().width > visible_server.width);
}

test "split model sizes side client pane from process labels" {
    var cfg = try testConfig(false);
    defer cfg.deinit();

    var model = Model.init(.left, &cfg);
    model.setProcessLabels(&.{ "api", "background-worker" });
    try model.resize(120, 40);

    try std.testing.expectEqual(@as(i32, 24), model.clientSize().width);
    try std.testing.expectEqual(@as(i32, 96), model.serverSize().width);
}

test "split model clamps side client pane to preserve terminal width" {
    var cfg = try testConfig(false);
    defer cfg.deinit();

    var model = Model.init(.left, &cfg);
    model.setProcessLabels(&.{"very-long-process-name-that-wants-too-much-space"});
    try model.resize(70, 30);

    try std.testing.expectEqual(@as(i32, 38), model.clientSize().width);
    try std.testing.expectEqual(@as(i32, 32), model.serverSize().width);
}

test "split model status bar reports hidden process list" {
    var cfg = try testConfig(true);
    defer cfg.deinit();

    var model = Model.init(.left, &cfg);
    try model.resize(120, 40);
    try model.handleKey("ctrl+right");

    const status = try model.statusBar(std.testing.allocator);
    defer std.testing.allocator.free(status);

    try std.testing.expect(std.mem.indexOf(u8, status, "process list hidden") != null);
}

test "split model status bar reports configured toggle focus binding" {
    var cfg = try testConfig(false);
    defer cfg.deinit();

    var model = Model.init(.left, &cfg);
    try model.resize(120, 40);

    const status = try model.statusBar(std.testing.allocator);
    defer std.testing.allocator.free(status);

    try std.testing.expect(std.mem.indexOf(u8, status, "ctrl+w toggle focus") != null);
}

test "split model forwards server-focused keys as terminal input" {
    var cfg = try testConfig(false);
    defer cfg.deinit();

    var capture = InputCapture{};
    var model = Model.init(.left, &cfg);
    model.setServerInput(InputCapture.sink(&capture));

    try model.handleKey("ctrl+right");
    try model.handleKey("up");

    try std.testing.expectEqualStrings("\x1b[A", capture.bytes());
}

test "split model forwards server-focused control keys as terminal input" {
    var cfg = try testConfig(false);
    defer cfg.deinit();

    var capture = InputCapture{};
    var model = Model.init(.left, &cfg);
    model.setServerInput(InputCapture.sink(&capture));

    try model.handleKey("ctrl+right");
    try model.handleKey("ctrl+d");
    try model.handleKey("ctrl+l");
    try model.handleKey("ctrl+z");

    try std.testing.expectEqualStrings("\x04\x0c\x1a", capture.bytes());
}

fn testConfig(hide_process_list_when_unfocused: bool) !config.schema.Config {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    errdefer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    cfg.layout.hide_process_list_when_unfocused = hide_process_list_when_unfocused;
    return cfg;
}

const InputCapture = struct {
    buffer: [64]u8 = undefined,
    len: usize = 0,

    fn sink(self: *InputCapture) InputSink {
        return .{ .context = self, .write = write };
    }

    fn write(context: *anyopaque, data: []const u8) anyerror!void {
        const self: *InputCapture = @ptrCast(@alignCast(context));
        @memcpy(self.buffer[self.len..][0..data.len], data);
        self.len += data.len;
    }

    fn bytes(self: *const InputCapture) []const u8 {
        return self.buffer[0..self.len];
    }
};

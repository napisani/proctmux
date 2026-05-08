const std = @import("std");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");
const ipc = @import("../ipc/root.zig");
const client_model = @import("client_model.zig");

pub const Transport = struct {
    context: *anyopaque,
    read_state: *const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror!ipc.protocol.StateUpdate,
    send_command: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        action: ipc.protocol.Command,
        label: []const u8,
    ) anyerror!CommandResult,

    fn readState(self: Transport, allocator: std.mem.Allocator) !ipc.protocol.StateUpdate {
        return self.read_state(self.context, allocator);
    }

    fn sendCommand(
        self: Transport,
        allocator: std.mem.Allocator,
        action: ipc.protocol.Command,
        label: []const u8,
    ) !CommandResult {
        return self.send_command(self.context, allocator, action, label);
    }
};

pub const CommandResult = struct {
    success: bool,
    error_message: []const u8,

    pub fn deinit(self: *const CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.error_message);
    }
};

pub const ClientSession = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    state_update: *ipc.protocol.StateUpdate,
    model: client_model.ClientModel,

    pub fn init(allocator: std.mem.Allocator, transport: Transport) !ClientSession {
        const state_update = try allocator.create(ipc.protocol.StateUpdate);
        errdefer allocator.destroy(state_update);

        state_update.* = try transport.readState(allocator);
        errdefer state_update.deinit();

        var model = try client_model.ClientModel.init(
            allocator,
            &state_update.state,
            state_update.process_views,
        );
        errdefer model.deinit();

        return .{
            .allocator = allocator,
            .transport = transport,
            .state_update = state_update,
            .model = model,
        };
    }

    pub fn deinit(self: *ClientSession) void {
        self.model.deinit();
        self.state_update.deinit();
        self.allocator.destroy(self.state_update);
    }

    pub fn handleKey(self: *ClientSession, key: []const u8) !void {
        _ = try self.handleKeyAction(key);
    }

    pub fn handleKeyAction(self: *ClientSession, key: []const u8) !?ipc.protocol.Command {
        if (try self.model.handleKey(key)) |intent| {
            if (requiresSelectedProcess(intent.action) and intent.label.len == 0) {
                try self.model.addMessage("no process selected");
                return null;
            }

            const result = self.transport.sendCommand(
                self.allocator,
                intent.action,
                intent.label,
            ) catch |err| {
                try self.model.addMessage(@errorName(err));
                return null;
            };
            defer result.deinit(self.allocator);

            if (!result.success) {
                const message = if (result.error_message.len == 0)
                    "command failed"
                else
                    result.error_message;
                try self.model.addMessage(message);
                return null;
            }
            return intent.action;
        }
        return null;
    }

    pub fn switchToActiveProcess(self: *ClientSession) !void {
        const label = self.model.activeProcessLabel();
        if (label.len == 0) return;

        const result = self.transport.sendCommand(
            self.allocator,
            .switch_process,
            label,
        ) catch |err| {
            try self.model.addMessage(@errorName(err));
            return;
        };
        defer result.deinit(self.allocator);

        if (!result.success) {
            const message = if (result.error_message.len == 0)
                "command failed"
            else
                result.error_message;
            try self.model.addMessage(message);
        }
    }

    pub fn readStateUpdate(self: *ClientSession) !void {
        const new_state_update = try self.allocator.create(ipc.protocol.StateUpdate);
        errdefer self.allocator.destroy(new_state_update);

        new_state_update.* = try self.transport.readState(self.allocator);
        errdefer new_state_update.deinit();

        try self.model.replaceStatePreservingUI(
            &new_state_update.state,
            new_state_update.process_views,
        );

        self.state_update.deinit();
        self.allocator.destroy(self.state_update);
        self.state_update = new_state_update;
    }
};

fn requiresSelectedProcess(action: ipc.protocol.Command) bool {
    return switch (action) {
        .start, .stop, .restart => true,
        else => false,
    };
}

pub const IpcTransport = struct {
    pub fn transport(client: *ipc.client.Client) Transport {
        return .{
            .context = client,
            .read_state = readState,
            .send_command = sendCommand,
        };
    }

    fn readState(context: *anyopaque, _: std.mem.Allocator) anyerror!ipc.protocol.StateUpdate {
        const client: *ipc.client.Client = @ptrCast(@alignCast(context));
        return client.readState();
    }

    fn sendCommand(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        action: ipc.protocol.Command,
        label: []const u8,
    ) anyerror!CommandResult {
        const client: *ipc.client.Client = @ptrCast(@alignCast(context));
        _ = try client.sendCommand(action, label);
        var response = try client.readResponse();
        defer response.deinit(client.allocator);
        return .{
            .success = response.success,
            .error_message = try allocator.dupe(u8, response.error_message),
        };
    }
};

test "client session initializes from transport state and dispatches key intents" {
    var cfg = try testConfig();
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = 2;

    var fake_controller = FakeProcessController{};
    const line = try ipc.protocol.stateLine(
        std.testing.allocator,
        &app_state,
        FakeProcessController.controller(&fake_controller),
    );
    defer std.testing.allocator.free(line);

    var fake = FakeTransport{ .state_line = line };
    var session = try ClientSession.init(std.testing.allocator, FakeTransport.transport(&fake));
    defer session.deinit();

    try std.testing.expectEqual(@as(u32, 2), session.model.active_proc_id);
    try std.testing.expectEqual(@as(usize, 3), session.model.visibleCount());

    try session.handleKey("s");

    try std.testing.expectEqual(ipc.protocol.Command.start, fake.last_action.?);
    try std.testing.expectEqualStrings("beta-worker", fake.lastLabel());
}

test "client session dispatches key intents through persistent IPC transport" {
    const path = "/tmp/proctmux-zig-tui-session-ipc-transport-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    var cfg = try testConfig();
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = 2;

    var fake_controller = FakeProcessController{};
    const line = try ipc.protocol.stateLine(
        std.testing.allocator,
        &app_state,
        FakeProcessController.controller(&fake_controller),
    );
    defer std.testing.allocator.free(line);

    var handler = FakeCommandHandler{};
    var state_provider = FakeStateProvider{ .line = line };
    var stopped = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, ipc.server.serveCommandsAtPathWithState, .{
        std.testing.allocator,
        path,
        FakeCommandHandler.handler(&handler),
        FakeStateProvider.provider(&state_provider),
        &stopped,
    });
    waitForSocketFile(path);

    var persistent = try ipc.client.Client.connect(std.testing.allocator, path);
    defer persistent.deinit();

    var session = try ClientSession.init(std.testing.allocator, IpcTransport.transport(&persistent));
    defer session.deinit();

    try session.handleKey("s");

    try std.testing.expectEqual(ipc.protocol.Command.start, handler.action);
    try std.testing.expectEqualStrings("beta-worker", handler.label());

    stopped.store(true, .seq_cst);
    persistent.close();
    unblockServer(path);
    thread.join();
}

test "client session records command failures as messages without exiting" {
    var cfg = try testConfig();
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = 2;

    var fake_controller = FakeProcessController{};
    const line = try ipc.protocol.stateLine(
        std.testing.allocator,
        &app_state,
        FakeProcessController.controller(&fake_controller),
    );
    defer std.testing.allocator.free(line);

    var fake = FakeTransport{
        .state_line = line,
        .command_success = false,
        .command_error_message = "already running",
    };
    var session = try ClientSession.init(std.testing.allocator, FakeTransport.transport(&fake));
    defer session.deinit();

    const action = try session.handleKeyAction("s");

    try std.testing.expectEqual(@as(?ipc.protocol.Command, null), action);
    try std.testing.expectEqual(ipc.protocol.Command.start, fake.last_action.?);
    try std.testing.expectEqual(@as(usize, 1), session.model.messageCount());
    try std.testing.expectEqualStrings("already running", session.model.message(0));
}

test "client session records no process selected locally without IPC command" {
    var cfg = try testConfig();
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = 0;

    var fake_controller = FakeProcessController{};
    const line = try ipc.protocol.stateLine(
        std.testing.allocator,
        &app_state,
        FakeProcessController.controller(&fake_controller),
    );
    defer std.testing.allocator.free(line);

    var fake = FakeTransport{ .state_line = line };
    var session = try ClientSession.init(std.testing.allocator, FakeTransport.transport(&fake));
    defer session.deinit();

    const action = try session.handleKeyAction("s");

    try std.testing.expectEqual(@as(?ipc.protocol.Command, null), action);
    try std.testing.expectEqual(@as(?ipc.protocol.Command, null), fake.last_action);
    try std.testing.expectEqual(@as(usize, 1), session.model.messageCount());
    try std.testing.expectEqualStrings("no process selected", session.model.message(0));
}

test "client session applies subsequent state updates to model" {
    var cfg = try testConfig();
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();

    var fake_controller = FakeProcessController{};
    app_state.current_proc_id = 1;
    const first_line = try ipc.protocol.stateLine(
        std.testing.allocator,
        &app_state,
        FakeProcessController.controller(&fake_controller),
    );
    defer std.testing.allocator.free(first_line);

    app_state.current_proc_id = 3;
    const second_line = try ipc.protocol.stateLine(
        std.testing.allocator,
        &app_state,
        FakeProcessController.controller(&fake_controller),
    );
    defer std.testing.allocator.free(second_line);

    var fake = FakeTransport{
        .state_line = first_line,
        .next_state_line = second_line,
    };
    var session = try ClientSession.init(std.testing.allocator, FakeTransport.transport(&fake));
    defer session.deinit();
    try std.testing.expectEqual(@as(u32, 1), session.model.active_proc_id);

    try session.readStateUpdate();

    try std.testing.expectEqual(@as(u32, 3), session.model.app_state.current_proc_id);
    try std.testing.expectEqual(@as(u32, 1), session.model.active_proc_id);
    try std.testing.expectEqual(@as(usize, 3), session.model.visibleCount());
}

test "client session preserves local ui state across state updates" {
    var cfg = try testConfig();
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();

    var fake_controller = FakeProcessController{};
    app_state.current_proc_id = 1;
    const first_line = try ipc.protocol.stateLine(
        std.testing.allocator,
        &app_state,
        FakeProcessController.controller(&fake_controller),
    );
    defer std.testing.allocator.free(first_line);

    app_state.current_proc_id = 2;
    const second_line = try ipc.protocol.stateLine(
        std.testing.allocator,
        &app_state,
        FakeProcessController.controller(&fake_controller),
    );
    defer std.testing.allocator.free(second_line);

    var fake = FakeTransport{
        .state_line = first_line,
        .next_state_line = second_line,
    };
    var session = try ClientSession.init(std.testing.allocator, FakeTransport.transport(&fake));
    defer session.deinit();

    _ = try session.model.handleKey("/");
    for ("gamma") |ch| {
        const key = [_]u8{ch};
        _ = try session.model.handleKey(key[0..]);
    }
    _ = try session.model.handleKey("enter");
    _ = try session.model.handleKey("?");

    try session.readStateUpdate();

    try std.testing.expectEqualStrings("gamma", session.model.filterText());
    try std.testing.expect(!session.model.entering_filter_text);
    try std.testing.expect(session.model.show_help);
    try std.testing.expectEqual(@as(usize, 1), session.model.visibleCount());
    try std.testing.expectEqualStrings("gamma-db", session.model.visibleLabel(0));
    try std.testing.expectEqual(@as(u32, 3), session.model.active_proc_id);
}

fn testConfig() !config.schema.Config {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    errdefer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    try putProcess(&cfg, "alpha-api", "sleep 1");
    try putProcess(&cfg, "beta-worker", "sleep 1");
    try putProcess(&cfg, "gamma-db", "sleep 1");
    return cfg;
}

fn putProcess(cfg: *config.schema.Config, label: []const u8, shell: []const u8) !void {
    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    errdefer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.owns_scalar_strings = true;
    proc_cfg.shell = try std.testing.allocator.dupe(u8, shell);

    const owned_label = try std.testing.allocator.dupe(u8, label);
    errdefer std.testing.allocator.free(owned_label);
    try cfg.procs.put(owned_label, proc_cfg);
}

const FakeProcessController = struct {
    fn controller(self: *FakeProcessController) domain.process.ProcessController {
        return .{
            .context = self,
            .get_process_status = getProcessStatus,
            .get_pid = getPID,
        };
    }

    fn getProcessStatus(_: *anyopaque, id: u32) domain.process.ProcessStatus {
        return if (id == 2) .running else .halted;
    }

    fn getPID(_: *anyopaque, id: u32) i32 {
        return @intCast(1000 + id);
    }
};

const FakeTransport = struct {
    state_line: []const u8,
    next_state_line: ?[]const u8 = null,
    state_read_count: usize = 0,
    command_success: bool = true,
    command_error_message: []const u8 = "",
    last_action: ?ipc.protocol.Command = null,
    last_label_buf: [64]u8 = undefined,
    last_label_len: usize = 0,

    fn transport(self: *FakeTransport) Transport {
        return .{
            .context = self,
            .read_state = readState,
            .send_command = sendCommand,
        };
    }

    fn lastLabel(self: *const FakeTransport) []const u8 {
        return self.last_label_buf[0..self.last_label_len];
    }

    fn readState(context: *anyopaque, allocator: std.mem.Allocator) anyerror!ipc.protocol.StateUpdate {
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        const line = if (self.state_read_count == 0)
            self.state_line
        else
            self.next_state_line orelse self.state_line;
        self.state_read_count += 1;
        return ipc.protocol.parseStateLine(allocator, line);
    }

    fn sendCommand(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        action: ipc.protocol.Command,
        label: []const u8,
    ) anyerror!CommandResult {
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        self.last_action = action;
        @memcpy(self.last_label_buf[0..label.len], label);
        self.last_label_len = label.len;
        return .{
            .success = self.command_success,
            .error_message = try allocator.dupe(u8, self.command_error_message),
        };
    }
};

const FakeCommandHandler = struct {
    action: ipc.protocol.Command = .list,
    label_buf: [64]u8 = undefined,
    label_len: usize = 0,

    fn handler(self: *FakeCommandHandler) ipc.server.CommandHandler {
        return .{
            .context = self,
            .handle = handle,
        };
    }

    fn label(self: *const FakeCommandHandler) []const u8 {
        return self.label_buf[0..self.label_len];
    }

    fn handle(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request: ipc.protocol.CommandRequest,
    ) anyerror!ipc.protocol.Response {
        const self: *FakeCommandHandler = @ptrCast(@alignCast(context));
        self.action = request.action;
        @memcpy(self.label_buf[0..request.label.len], request.label);
        self.label_len = request.label.len;

        return .{
            .request_id = try allocator.dupe(u8, request.request_id),
            .success = true,
            .error_message = try allocator.dupe(u8, ""),
            .process_list = try allocator.alloc(ipc.protocol.ProcessListItem, 0),
        };
    }
};

const FakeStateProvider = struct {
    line: []const u8,

    fn provider(self: *FakeStateProvider) ipc.server.StateProvider {
        return .{
            .context = self,
            .state_line = stateLine,
        };
    }

    fn stateLine(context: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *FakeStateProvider = @ptrCast(@alignCast(context));
        return allocator.dupe(u8, self.line);
    }
};

fn unblockServer(path: []const u8) void {
    var stream = std.net.connectUnixSocket(path) catch return;
    stream.close();
}

fn waitForSocketFile(path: []const u8) void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        std.fs.accessAbsolute(path, .{}) catch {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            continue;
        };
        return;
    }
}

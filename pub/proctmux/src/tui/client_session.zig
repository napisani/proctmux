//! Client Session orchestration over a Snapshot transport.
//! This module turns key intents into Process Commands, handles command errors, and applies server Snapshots while preserving local UI state.

const std = @import("std");
const domain = @import("../domain/root.zig");
const ipc = @import("../ipc/root.zig");
const test_config = @import("../test_support/config.zig");
const test_ipc = @import("../test_support/ipc.zig");
const client_model = @import("client_model.zig");

/// Transport seam used by Client Session. Production uses `ipc.client.Client`;
/// tests provide fake snapshots and command results without a socket.
pub const Transport = struct {
    context: *anyopaque,
    read_snapshot: *const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror!ipc.protocol.SnapshotUpdate,
    read_latest_snapshot: *const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror!ipc.protocol.SnapshotUpdate,
    send_command: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        action: ipc.protocol.Command,
        label: []const u8,
    ) anyerror!CommandResult,

    fn readSnapshot(self: Transport, allocator: std.mem.Allocator) !ipc.protocol.SnapshotUpdate {
        return self.read_snapshot(self.context, allocator);
    }

    fn readLatestSnapshot(self: Transport, allocator: std.mem.Allocator) !ipc.protocol.SnapshotUpdate {
        return self.read_latest_snapshot(self.context, allocator);
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

pub const KeyInteractionOptions = struct {
    sync_selection_after_command: bool = false,
};

/// Result of handling one key at the session layer. Runtime loops use this to
/// decide whether to stop, repaint immediately, or keep polling.
pub const KeyInteraction = struct {
    handled_command: bool = false,
    stop: bool = false,
    render_now: bool = false,
};

/// TUI-facing session that combines local ClientModel state with IPC Snapshot
/// updates and Process Command transport.
pub const ClientSession = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    snapshot_update: *ipc.protocol.SnapshotUpdate,
    model: client_model.ClientModel,

    pub fn init(allocator: std.mem.Allocator, transport: Transport) !ClientSession {
        const snapshot_update = try allocator.create(ipc.protocol.SnapshotUpdate);
        errdefer allocator.destroy(snapshot_update);

        snapshot_update.* = try transport.readSnapshot(allocator);
        errdefer snapshot_update.deinit();

        var model = try client_model.ClientModel.init(
            allocator,
            snapshot_update.snapshot(),
        );
        errdefer model.deinit();
        model.no_color = std.process.hasEnvVarConstant("NO_COLOR");

        return .{
            .allocator = allocator,
            .transport = transport,
            .snapshot_update = snapshot_update,
            .model = model,
        };
    }

    pub fn deinit(self: *ClientSession) void {
        self.model.deinit();
        self.snapshot_update.deinit();
        self.allocator.destroy(self.snapshot_update);
    }

    pub fn handleKey(self: *ClientSession, key: []const u8) !void {
        _ = try self.handleKeyAction(key);
    }

    /// Handles a key and performs the command/snapshot synchronization policy
    /// required for interactive clients and unified mode.
    pub fn handleKeyInteraction(
        self: *ClientSession,
        key: []const u8,
        options: KeyInteractionOptions,
    ) !KeyInteraction {
        const action = (try self.handleKeyAction(key)) orelse return .{};
        if (ipc.protocol.commandNeedsImmediateSnapshotSync(action)) {
            try self.readSnapshotUpdate();
            if (options.sync_selection_after_command) try self.syncSelectionAfterAction(action);
        }
        return .{
            .handled_command = true,
            .stop = action == .stop_running,
            .render_now = ipc.protocol.commandShouldRenderImmediately(action),
        };
    }

    pub fn handleKeyAction(self: *ClientSession, key: []const u8) !?ipc.protocol.Command {
        if (try self.model.handleKey(key)) |intent| {
            if (ipc.protocol.commandRequiresSelectedProcess(intent.action) and intent.label.len == 0) {
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

    fn syncSelectionAfterAction(self: *ClientSession, action: ipc.protocol.Command) !void {
        switch (action) {
            .start, .restart => try self.switchToActiveProcess(),
            else => {},
        }
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

    pub fn readSnapshotUpdate(self: *ClientSession) !void {
        try self.applySnapshotUpdate(try self.transport.readLatestSnapshot(self.allocator));
    }

    /// Takes ownership of a freshly parsed SnapshotUpdate and makes it the
    /// model's backing server state after local UI preservation succeeds.
    pub fn applySnapshotUpdate(self: *ClientSession, update: ipc.protocol.SnapshotUpdate) !void {
        var pending_update: ?ipc.protocol.SnapshotUpdate = update;
        errdefer if (pending_update) |*pending| pending.deinit();

        const new_snapshot_update = try self.allocator.create(ipc.protocol.SnapshotUpdate);
        errdefer self.allocator.destroy(new_snapshot_update);

        new_snapshot_update.* = pending_update.?;
        pending_update = null;
        errdefer new_snapshot_update.deinit();

        try self.model.replaceSnapshotPreservingUI(new_snapshot_update.snapshot());

        // Only release the old parsed arena after the model has moved to the new
        // snapshot; the model borrows strings from whichever update is current.
        self.snapshot_update.deinit();
        self.allocator.destroy(self.snapshot_update);
        self.snapshot_update = new_snapshot_update;
    }
};

pub const IpcTransport = struct {
    pub fn transport(client: *ipc.client.Client) Transport {
        return .{
            .context = client,
            .read_snapshot = readSnapshot,
            .read_latest_snapshot = readLatestSnapshot,
            .send_command = sendCommand,
        };
    }

    fn readSnapshot(context: *anyopaque, _: std.mem.Allocator) anyerror!ipc.protocol.SnapshotUpdate {
        const client: *ipc.client.Client = @ptrCast(@alignCast(context));
        return client.readSnapshot();
    }

    fn readLatestSnapshot(context: *anyopaque, _: std.mem.Allocator) anyerror!ipc.protocol.SnapshotUpdate {
        const client: *ipc.client.Client = @ptrCast(@alignCast(context));
        return client.readLatestSnapshot();
    }

    fn sendCommand(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        action: ipc.protocol.Command,
        label: []const u8,
    ) anyerror!CommandResult {
        const client: *ipc.client.Client = @ptrCast(@alignCast(context));
        const request_id = try client.sendCommand(action, label);
        if (action == .switch_process) {
            // The server publishes the selection snapshot before responding to
            // switch commands; treating the send as success avoids a deadlock
            // where the client waits for a response after intentionally
            // skipping its own selection broadcast.
            return .{
                .success = true,
                .error_message = try allocator.dupe(u8, ""),
            };
        }

        var response = try client.readResponseFor(request_id);
        defer response.deinit(client.allocator);
        return .{
            .success = response.success,
            .error_message = try allocator.dupe(u8, response.error_message),
        };
    }
};

test "client session initializes from transport snapshot and dispatches key intents" {
    var cfg = try test_config.standardSessionConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var fake_controller = test_ipc.FakeProcessController{ .running_id = domain.process.ProcessId.fromInt(2) };
    const line = try test_ipc.snapshotLineFromAppState(
        std.testing.allocator,
        &app_state,
        fake_controller.controller(),
    );
    defer std.testing.allocator.free(line);

    var fake = FakeTransport{ .snapshot_line = line };
    var session = try ClientSession.init(std.testing.allocator, FakeTransport.transport(&fake));
    defer session.deinit();

    try std.testing.expectEqual(domain.process.ProcessId.fromInt(2), session.model.active_proc_id);
    try std.testing.expectEqual(@as(usize, 3), session.model.visibleCount());

    try session.handleKey("s");

    try std.testing.expectEqual(ipc.protocol.Command.start, fake.last_action.?);
    try std.testing.expectEqualStrings("beta-worker", fake.lastLabel());
}

test "client session dispatches key intents through persistent IPC transport" {
    const path = "/tmp/proctmux-zig-tui-session-ipc-transport-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    var cfg = try test_config.standardSessionConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var fake_controller = test_ipc.FakeProcessController{ .running_id = domain.process.ProcessId.fromInt(2) };
    const line = try test_ipc.snapshotLineFromAppState(
        std.testing.allocator,
        &app_state,
        fake_controller.controller(),
    );
    defer std.testing.allocator.free(line);

    var handler = test_ipc.FakeCommandHandler{};
    var snapshot_provider = test_ipc.FakeSnapshotProvider{ .line = line };
    var stopped = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, ipc.server.serveCommandsAtPathWithSnapshots, .{
        std.testing.allocator,
        path,
        handler.handler(),
        snapshot_provider.provider(),
        &stopped,
    });
    test_ipc.waitForSocketFile(path);

    var persistent = try ipc.client.Client.connect(std.testing.allocator, path);
    defer persistent.deinit();

    var session = try ClientSession.init(std.testing.allocator, IpcTransport.transport(&persistent));
    defer session.deinit();

    try session.handleKey("s");

    try std.testing.expectEqual(ipc.protocol.Command.start, handler.action);
    try std.testing.expectEqualStrings("beta-worker", handler.label());

    stopped.store(true, .seq_cst);
    persistent.close();
    test_ipc.unblockServer(path);
    thread.join();
}

test "client session records command failures as messages without exiting" {
    var cfg = try test_config.standardSessionConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);

    var fake_controller = test_ipc.FakeProcessController{ .running_id = domain.process.ProcessId.fromInt(2) };
    const line = try test_ipc.snapshotLineFromAppState(
        std.testing.allocator,
        &app_state,
        fake_controller.controller(),
    );
    defer std.testing.allocator.free(line);

    var fake = FakeTransport{
        .snapshot_line = line,
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
    var cfg = try test_config.standardSessionConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = .none;

    var fake_controller = test_ipc.FakeProcessController{ .running_id = domain.process.ProcessId.fromInt(2) };
    const line = try test_ipc.snapshotLineFromAppState(
        std.testing.allocator,
        &app_state,
        fake_controller.controller(),
    );
    defer std.testing.allocator.free(line);

    var fake = FakeTransport{ .snapshot_line = line };
    var session = try ClientSession.init(std.testing.allocator, FakeTransport.transport(&fake));
    defer session.deinit();

    const action = try session.handleKeyAction("s");

    try std.testing.expectEqual(@as(?ipc.protocol.Command, null), action);
    try std.testing.expectEqual(@as(?ipc.protocol.Command, null), fake.last_action);
    try std.testing.expectEqual(@as(usize, 1), session.model.messageCount());
    try std.testing.expectEqualStrings("no process selected", session.model.message(0));
}

test "client session applies subsequent snapshot updates to model" {
    var cfg = try test_config.standardSessionConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();

    var fake_controller = test_ipc.FakeProcessController{ .running_id = domain.process.ProcessId.fromInt(2) };
    app_state.current_proc_id = domain.process.ProcessId.fromInt(1);
    const first_line = try test_ipc.snapshotLineFromAppState(
        std.testing.allocator,
        &app_state,
        fake_controller.controller(),
    );
    defer std.testing.allocator.free(first_line);

    app_state.current_proc_id = domain.process.ProcessId.fromInt(3);
    const second_line = try test_ipc.snapshotLineFromAppState(
        std.testing.allocator,
        &app_state,
        fake_controller.controller(),
    );
    defer std.testing.allocator.free(second_line);

    var fake = FakeTransport{
        .snapshot_line = first_line,
        .next_snapshot_line = second_line,
    };
    var session = try ClientSession.init(std.testing.allocator, FakeTransport.transport(&fake));
    defer session.deinit();
    try std.testing.expectEqual(domain.process.ProcessId.fromInt(1), session.model.active_proc_id);

    try session.readSnapshotUpdate();

    try std.testing.expectEqual(domain.process.ProcessId.fromInt(3), session.model.snapshot.currentProcessId());
    try std.testing.expectEqual(domain.process.ProcessId.fromInt(1), session.model.active_proc_id);
    try std.testing.expectEqual(@as(usize, 3), session.model.visibleCount());
}

test "client session preserves local ui state across snapshot updates" {
    var cfg = try test_config.standardSessionConfig(std.testing.allocator);
    defer cfg.deinit();

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();

    var fake_controller = test_ipc.FakeProcessController{ .running_id = domain.process.ProcessId.fromInt(2) };
    app_state.current_proc_id = domain.process.ProcessId.fromInt(1);
    const first_line = try test_ipc.snapshotLineFromAppState(
        std.testing.allocator,
        &app_state,
        fake_controller.controller(),
    );
    defer std.testing.allocator.free(first_line);

    app_state.current_proc_id = domain.process.ProcessId.fromInt(2);
    const second_line = try test_ipc.snapshotLineFromAppState(
        std.testing.allocator,
        &app_state,
        fake_controller.controller(),
    );
    defer std.testing.allocator.free(second_line);

    var fake = FakeTransport{
        .snapshot_line = first_line,
        .next_snapshot_line = second_line,
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

    try session.readSnapshotUpdate();

    try std.testing.expectEqualStrings("gamma", session.model.filterText());
    try std.testing.expect(!session.model.entering_filter_text);
    try std.testing.expect(session.model.show_help);
    try std.testing.expectEqual(@as(usize, 1), session.model.visibleCount());
    try std.testing.expectEqualStrings("gamma-db", session.model.visibleLabel(0));
    try std.testing.expectEqual(domain.process.ProcessId.fromInt(3), session.model.active_proc_id);
}

const FakeTransport = struct {
    snapshot_line: []const u8,
    next_snapshot_line: ?[]const u8 = null,
    snapshot_read_count: usize = 0,
    command_success: bool = true,
    command_error_message: []const u8 = "",
    last_action: ?ipc.protocol.Command = null,
    last_label_buf: [64]u8 = undefined,
    last_label_len: usize = 0,

    fn transport(self: *FakeTransport) Transport {
        return .{
            .context = self,
            .read_snapshot = readSnapshot,
            .read_latest_snapshot = readSnapshot,
            .send_command = sendCommand,
        };
    }

    fn lastLabel(self: *const FakeTransport) []const u8 {
        return self.last_label_buf[0..self.last_label_len];
    }

    fn readSnapshot(context: *anyopaque, allocator: std.mem.Allocator) anyerror!ipc.protocol.SnapshotUpdate {
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        const line = if (self.snapshot_read_count == 0)
            self.snapshot_line
        else
            self.next_snapshot_line orelse self.snapshot_line;
        self.snapshot_read_count += 1;
        return ipc.protocol.parseSnapshotLine(allocator, line);
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

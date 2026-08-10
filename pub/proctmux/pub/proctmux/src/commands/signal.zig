//! Signal-command CLI behavior over IPC.
//! Mutation commands send Process Commands and exit; `signal-list` is intentionally read-only and formats the initial Client Snapshot instead of requiring a list command in the protocol.

const std = @import("std");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");
const ipc = @import("../ipc/root.zig");
const test_ipc = @import("../test_support/ipc.zig");

pub const ProcessCommand = struct {
    action: ipc.protocol.Command,
    label: []const u8 = "",
};

/// Parsed signal-command intent. Listing is separate from Process Commands so
/// the IPC protocol does not need a request/response shape for process lists.
pub const Plan = union(enum) {
    command: ProcessCommand,
    list,
};

pub const Sender = struct {
    context: *anyopaque,
    send: *const fn (
        context: *anyopaque,
        action: ipc.protocol.Command,
        label: []const u8,
    ) anyerror!ipc.protocol.Response,

    fn sendCommand(self: Sender, action: ipc.protocol.Command, label: []const u8) !ipc.protocol.Response {
        return self.send(self.context, action, label);
    }
};

pub const Output = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,

    fn writeAll(self: Output, bytes: []const u8) !void {
        try self.write(self.context, bytes);
    }
};

pub fn parse(subcommand: []const u8, args: []const []const u8) !Plan {
    if (std.mem.eql(u8, subcommand, "signal-start")) {
        return commandPlan(.start, try requiredName(args));
    }
    if (std.mem.eql(u8, subcommand, "signal-stop")) {
        return commandPlan(.stop, try requiredName(args));
    }
    if (std.mem.eql(u8, subcommand, "signal-restart")) {
        return commandPlan(.restart, try requiredName(args));
    }
    if (std.mem.eql(u8, subcommand, "signal-switch")) {
        return commandPlan(.switch_process, try requiredName(args));
    }
    if (std.mem.eql(u8, subcommand, "signal-restart-running")) {
        return commandPlan(.restart_running, "");
    }
    if (std.mem.eql(u8, subcommand, "signal-stop-running")) {
        return commandPlan(.stop_running, "");
    }
    if (std.mem.eql(u8, subcommand, "signal-list")) {
        return .list;
    }
    return error.UnknownSignalCommand;
}

fn commandPlan(action: ipc.protocol.Command, label: []const u8) Plan {
    return .{ .command = .{ .action = action, .label = label } };
}

pub fn runWithSender(
    allocator: std.mem.Allocator,
    plan: Plan,
    sender: Sender,
    output: Output,
) !void {
    _ = output;
    switch (plan) {
        .list => return error.ListRequiresSnapshot,
        .command => |command| {
            var response = try sender.sendCommand(command.action, command.label);
            defer response.deinit(allocator);
            if (!response.success) return error.CommandFailed;
        },
    }
}

/// Executes a signal command against an already-running Primary Server socket.
/// List mode reads the initial Snapshot and never mutates server state.
pub fn runWithSocketPath(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    subcommand: []const u8,
    args: []const []const u8,
    output: Output,
) !void {
    const plan = try parse(subcommand, args);
    switch (plan) {
        .list => {
            var snapshot_update = try ipc.client.readInitialSnapshotFromPath(allocator, socket_path);
            defer snapshot_update.deinit();
            const table = try formatProcessList(allocator, snapshot_update.snapshot());
            defer allocator.free(table);
            try output.writeAll(table);
        },
        .command => |command| {
            var response = try ipc.client.sendCommandToPath(allocator, socket_path, 1, command.action, command.label);
            defer response.deinit(allocator);
            if (!response.success) return error.CommandFailed;
        },
    }
}

pub fn runWithConfig(
    allocator: std.mem.Allocator,
    cfg: *const config.schema.Config,
    subcommand: []const u8,
    args: []const []const u8,
    output: Output,
) !void {
    const socket_path = try ipc.socket.getPathForConfig(allocator, cfg);
    defer allocator.free(socket_path);

    try runWithSocketPath(allocator, socket_path, subcommand, args, output);
}

/// Formats the snapshot's process summaries for scripting-friendly output.
pub fn formatProcessList(
    allocator: std.mem.Allocator,
    snapshot: *const domain.client_snapshot.ClientSnapshot,
) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("NAME\tSTATUS\n");
    for (snapshot.processes) |item| {
        try out.appendSlice(item.label);
        try out.append('\t');
        try out.appendSlice(if (item.status == .running) "running" else "stopped");
        try out.append('\n');
    }

    return out.toOwnedSlice();
}

fn requiredName(args: []const []const u8) ![]const u8 {
    if (args.len < 2) return error.MissingName;
    return args[1];
}

test "signal command parser maps named process commands" {
    const start = try parse("signal-start", &.{ "signal-start", "api" });
    try expectCommandPlan(start, .start, "api");

    const stop = try parse("signal-stop", &.{ "signal-stop", "worker" });
    try expectCommandPlan(stop, .stop, "worker");

    const restart = try parse("signal-restart", &.{ "signal-restart", "web" });
    try expectCommandPlan(restart, .restart, "web");

    const switch_cmd = try parse("signal-switch", &.{ "signal-switch", "web" });
    try expectCommandPlan(switch_cmd, .switch_process, "web");
}

test "signal command parser maps running and list commands" {
    const restart_running = try parse("signal-restart-running", &.{"signal-restart-running"});
    try expectCommandPlan(restart_running, .restart_running, "");

    const stop_running = try parse("signal-stop-running", &.{"signal-stop-running"});
    try expectCommandPlan(stop_running, .stop_running, "");

    const list = try parse("signal-list", &.{"signal-list"});
    try std.testing.expectEqual(Plan.list, list);
}

fn expectCommandPlan(plan: Plan, action: ipc.protocol.Command, label: []const u8) !void {
    switch (plan) {
        .command => |command| {
            try std.testing.expectEqual(action, command.action);
            try std.testing.expectEqualStrings(label, command.label);
        },
        .list => return error.ExpectedCommandPlan,
    }
}

test "signal command parser reports legacy-compatible argument errors" {
    try std.testing.expectError(error.MissingName, parse("signal-start", &.{"signal-start"}));
    try std.testing.expectError(error.MissingName, parse("signal-stop", &.{"signal-stop"}));
    try std.testing.expectError(error.MissingName, parse("signal-restart", &.{"signal-restart"}));
    try std.testing.expectError(error.MissingName, parse("signal-switch", &.{"signal-switch"}));
    try std.testing.expectError(error.UnknownSignalCommand, parse("signal-nope", &.{"signal-nope"}));
}

test "signal list formatter matches tab-delimited output from snapshot" {
    const snapshot = domain.client_snapshot.ClientSnapshot{
        .processes = &.{
            .{ .id = 1, .label = "api", .status = .running },
            .{ .id = 2, .label = "worker", .status = .halted },
        },
    };

    const out = try formatProcessList(std.testing.allocator, &snapshot);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings(
        "NAME\tSTATUS\napi\trunning\nworker\tstopped\n",
        out,
    );
}

test "signal runner sends action and label without output for mutation commands" {
    var fake = FakeSender{};
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    const plan = try parse("signal-restart", &.{ "signal-restart", "api" });
    try runWithSender(std.testing.allocator, plan, FakeSender.sender(&fake), TestOutput.writer(&out));

    try std.testing.expectEqual(ipc.protocol.Command.restart, fake.last_action);
    try std.testing.expectEqualStrings("api", fake.last_label);
    try std.testing.expectEqualStrings("", out.items);
}

test "signal runner returns command failure for unsuccessful responses" {
    var fake = FakeSender{ .success = false };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    const plan = try parse("signal-stop", &.{ "signal-stop", "api" });
    try std.testing.expectError(
        error.CommandFailed,
        runWithSender(std.testing.allocator, plan, FakeSender.sender(&fake), TestOutput.writer(&out)),
    );
}

test "signal socket runner sends mutation command" {
    const path = "/tmp/proctmux-zig-signal-command-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    const address = try std.net.Address.initUnix(path);
    var server = try address.listen(.{});
    defer server.deinit();

    var capture = test_ipc.CommandCapture{};
    const thread = try std.Thread.spawn(.{}, test_ipc.runResponseCaptureServer, .{ &server, &capture });

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runWithSocketPath(std.testing.allocator, path, "signal-stop", &.{ "signal-stop", "api" }, TestOutput.writer(&out));
    thread.join();
    if (capture.err) |err| return err;

    try std.testing.expectEqualStrings(
        "{\"type\":\"command\",\"protocol_version\":1,\"request_id\":1,\"action\":\"stop\",\"target\":\"api\"}\n",
        capture.requestLine(),
    );
}

test "signal socket runner formats list from initial snapshot" {
    const path = "/tmp/proctmux-zig-signal-list-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    const address = try std.net.Address.initUnix(path);
    var server = try address.listen(.{});
    defer server.deinit();

    var server_result = test_ipc.ServerErrorCapture{};
    const thread = try std.Thread.spawn(.{}, test_ipc.runSnapshotLineServer, .{
        &server,
        &server_result,
        test_ipc.apiWorkerSnapshotLine,
        1,
    });

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runWithSocketPath(std.testing.allocator, path, "signal-list", &.{"signal-list"}, TestOutput.writer(&out));
    thread.join();
    if (server_result.err) |err| return err;

    try std.testing.expectEqualStrings("NAME\tSTATUS\napi\trunning\nworker\tstopped\n", out.items);
}

const FakeSender = struct {
    success: bool = true,
    last_action: ipc.protocol.Command = .start,
    last_label: []const u8 = "",

    fn sender(self: *FakeSender) Sender {
        return .{
            .context = self,
            .send = send,
        };
    }

    fn send(context: *anyopaque, action: ipc.protocol.Command, label: []const u8) anyerror!ipc.protocol.Response {
        const self: *FakeSender = @ptrCast(@alignCast(context));
        self.last_action = action;
        self.last_label = label;
        return .{
            .request_id = 1,
            .success = self.success,
            .error_message = try std.testing.allocator.dupe(u8, "failed"),
        };
    }
};

const TestOutput = struct {
    fn writer(out: *std.array_list.Managed(u8)) Output {
        return .{
            .context = out,
            .write = write,
        };
    }

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const out: *std.array_list.Managed(u8) = @ptrCast(@alignCast(context));
        try out.appendSlice(bytes);
    }
};

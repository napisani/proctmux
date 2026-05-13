const std = @import("std");
const config = @import("../config/root.zig");
const ipc = @import("../ipc/root.zig");

pub const Plan = struct {
    action: ipc.protocol.Command,
    label: []const u8 = "",
    renders_list: bool = false,
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
        return .{ .action = .start, .label = try requiredName(args) };
    }
    if (std.mem.eql(u8, subcommand, "signal-stop")) {
        return .{ .action = .stop, .label = try requiredName(args) };
    }
    if (std.mem.eql(u8, subcommand, "signal-restart")) {
        return .{ .action = .restart, .label = try requiredName(args) };
    }
    if (std.mem.eql(u8, subcommand, "signal-switch")) {
        return .{ .action = .switch_process, .label = try requiredName(args) };
    }
    if (std.mem.eql(u8, subcommand, "signal-restart-running")) {
        return .{ .action = .restart_running };
    }
    if (std.mem.eql(u8, subcommand, "signal-stop-running")) {
        return .{ .action = .stop_running };
    }
    if (std.mem.eql(u8, subcommand, "signal-list")) {
        return .{ .action = .list, .renders_list = true };
    }
    return error.UnknownSignalCommand;
}

pub fn runWithSender(
    allocator: std.mem.Allocator,
    plan: Plan,
    sender: Sender,
    output: Output,
) !void {
    const response = try sender.sendCommand(plan.action, plan.label);
    if (!response.success) return error.CommandFailed;

    if (plan.renders_list) {
        const table = try formatProcessList(allocator, response);
        defer allocator.free(table);
        try output.writeAll(table);
    }
}

pub fn runWithSocketPath(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    subcommand: []const u8,
    args: []const []const u8,
    output: Output,
) !void {
    const plan = try parse(subcommand, args);
    var response = try ipc.client.sendCommandToPath(allocator, socket_path, "1", plan.action, plan.label);
    defer response.deinit(allocator);

    if (!response.success) return error.CommandFailed;
    if (plan.renders_list) {
        const table = try formatProcessList(allocator, response);
        defer allocator.free(table);
        try output.writeAll(table);
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

pub fn formatProcessList(
    allocator: std.mem.Allocator,
    response: ipc.protocol.Response,
) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("NAME\tSTATUS\n");
    for (response.process_list) |item| {
        try out.appendSlice(item.name);
        try out.append('\t');
        try out.appendSlice(if (item.running) "running" else "stopped");
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
    try std.testing.expectEqual(ipc.protocol.Command.start, start.action);
    try std.testing.expectEqualStrings("api", start.label);
    try std.testing.expect(!start.renders_list);

    const stop = try parse("signal-stop", &.{ "signal-stop", "worker" });
    try std.testing.expectEqual(ipc.protocol.Command.stop, stop.action);
    try std.testing.expectEqualStrings("worker", stop.label);

    const restart = try parse("signal-restart", &.{ "signal-restart", "web" });
    try std.testing.expectEqual(ipc.protocol.Command.restart, restart.action);
    try std.testing.expectEqualStrings("web", restart.label);

    const switch_cmd = try parse("signal-switch", &.{ "signal-switch", "web" });
    try std.testing.expectEqual(ipc.protocol.Command.switch_process, switch_cmd.action);
    try std.testing.expectEqualStrings("web", switch_cmd.label);
}

test "signal command parser maps running and list commands" {
    const restart_running = try parse("signal-restart-running", &.{"signal-restart-running"});
    try std.testing.expectEqual(ipc.protocol.Command.restart_running, restart_running.action);
    try std.testing.expectEqualStrings("", restart_running.label);
    try std.testing.expect(!restart_running.renders_list);

    const stop_running = try parse("signal-stop-running", &.{"signal-stop-running"});
    try std.testing.expectEqual(ipc.protocol.Command.stop_running, stop_running.action);
    try std.testing.expectEqualStrings("", stop_running.label);

    const list = try parse("signal-list", &.{"signal-list"});
    try std.testing.expectEqual(ipc.protocol.Command.list, list.action);
    try std.testing.expectEqualStrings("", list.label);
    try std.testing.expect(list.renders_list);
}

test "signal command parser reports legacy-compatible argument errors" {
    try std.testing.expectError(error.MissingName, parse("signal-start", &.{"signal-start"}));
    try std.testing.expectError(error.MissingName, parse("signal-stop", &.{"signal-stop"}));
    try std.testing.expectError(error.MissingName, parse("signal-restart", &.{"signal-restart"}));
    try std.testing.expectError(error.MissingName, parse("signal-switch", &.{"signal-switch"}));
    try std.testing.expectError(error.UnknownSignalCommand, parse("signal-nope", &.{"signal-nope"}));
}

test "signal list formatter matches tab-delimited output" {
    var items = [_]ipc.protocol.ProcessListItem{
        .{ .name = "api", .running = true, .index = 1 },
        .{ .name = "worker", .running = false, .index = 2 },
    };
    const response = ipc.protocol.Response{
        .request_id = "1",
        .success = true,
        .error_message = "",
        .process_list = items[0..],
    };

    const out = try formatProcessList(std.testing.allocator, response);
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

test "signal runner renders list responses" {
    var fake = FakeSender{ .list_response = true };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    const plan = try parse("signal-list", &.{"signal-list"});
    try runWithSender(std.testing.allocator, plan, FakeSender.sender(&fake), TestOutput.writer(&out));

    try std.testing.expectEqual(ipc.protocol.Command.list, fake.last_action);
    try std.testing.expectEqualStrings("NAME\tSTATUS\napi\trunning\nworker\tstopped\n", out.items);
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

test "signal socket runner sends command and formats list response" {
    const path = "/tmp/proctmux-zig-signal-list-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    const address = try std.net.Address.initUnix(path);
    var server = try address.listen(.{});
    defer server.deinit();

    var capture = OneShotCapture{};
    const thread = try std.Thread.spawn(.{}, runSignalListResponseServer, .{ &server, &capture });

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runWithSocketPath(std.testing.allocator, path, "signal-list", &.{"signal-list"}, TestOutput.writer(&out));
    thread.join();
    if (capture.err) |err| return err;

    try std.testing.expectEqualStrings(
        "{\"type\":\"command\",\"request_id\":\"1\",\"action\":\"list\"}\n",
        capture.requestLine(),
    );
    try std.testing.expectEqualStrings("NAME\tSTATUS\napi\trunning\nworker\tstopped\n", out.items);
}

test "signal socket runner returns command failure from response" {
    const path = "/tmp/proctmux-zig-signal-failure-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    const address = try std.net.Address.initUnix(path);
    var server = try address.listen(.{});
    defer server.deinit();

    var capture = OneShotCapture{ .response = "{\"type\":\"response\",\"request_id\":\"1\",\"success\":false,\"error\":\"no such process\"}\n" };
    const thread = try std.Thread.spawn(.{}, runSignalListResponseServer, .{ &server, &capture });

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(
        error.CommandFailed,
        runWithSocketPath(std.testing.allocator, path, "signal-stop", &.{ "signal-stop", "api" }, TestOutput.writer(&out)),
    );
    thread.join();
    if (capture.err) |err| return err;
}

test "signal config runner locates socket from config hash" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    cfg.file_path = "/tmp/proctmux-zig-signal-config-test.yaml";

    const path = try ipc.socket.createPathForConfig(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(path);
    defer std.fs.deleteFileAbsolute(path) catch {};

    const address = try std.net.Address.initUnix(path);
    var server = try address.listen(.{});
    defer server.deinit();

    var capture = OneShotCapture{};
    var responded = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, runProbeTolerantSignalListResponseServer, .{ &server, &capture, &responded });

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    const result = runWithConfig(std.testing.allocator, &cfg, "signal-list", &.{"signal-list"}, TestOutput.writer(&out));
    unblockServer(path);
    thread.join();
    if (capture.err) |err| return err;
    try result;

    try std.testing.expectEqualStrings(
        "{\"type\":\"command\",\"request_id\":\"1\",\"action\":\"list\"}\n",
        capture.requestLine(),
    );
    try std.testing.expectEqualStrings("NAME\tSTATUS\napi\trunning\nworker\tstopped\n", out.items);
}

const FakeSender = struct {
    success: bool = true,
    list_response: bool = false,
    last_action: ipc.protocol.Command = .list,
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

        if (self.list_response) {
            return .{
                .request_id = "",
                .success = self.success,
                .error_message = "failed",
                .process_list = &fake_processes,
            };
        }

        return .{
            .request_id = "",
            .success = self.success,
            .error_message = "failed",
            .process_list = &.{},
        };
    }
};

var fake_processes = [_]ipc.protocol.ProcessListItem{
    .{ .name = "api", .running = true, .index = 1 },
    .{ .name = "worker", .running = false, .index = 2 },
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

const OneShotCapture = struct {
    request: [512]u8 = undefined,
    request_len: usize = 0,
    response: []const u8 =
        "{\"type\":\"response\",\"request_id\":\"1\",\"success\":true,\"process_list\":[{\"index\":1,\"name\":\"api\",\"running\":true},{\"index\":2,\"name\":\"worker\",\"running\":false}]}\n",
    err: ?anyerror = null,

    fn requestLine(self: *const OneShotCapture) []const u8 {
        return self.request[0..self.request_len];
    }
};

fn runSignalListResponseServer(server: *std.net.Server, capture: *OneShotCapture) void {
    const conn = server.accept() catch |err| {
        capture.err = err;
        return;
    };
    defer conn.stream.close();

    capture.request_len = conn.stream.read(&capture.request) catch |err| {
        capture.err = err;
        return;
    };

    conn.stream.writeAll(capture.response) catch |err| {
        capture.err = err;
        return;
    };
}

fn runProbeTolerantSignalListResponseServer(
    server: *std.net.Server,
    capture: *OneShotCapture,
    responded: *std.atomic.Value(bool),
) void {
    const first = server.accept() catch |err| {
        capture.err = err;
        return;
    };
    const first_thread = std.Thread.spawn(.{}, handleMaybeSignalCommand, .{ first, capture, responded }) catch |err| {
        capture.err = err;
        first.stream.close();
        return;
    };

    const second = server.accept() catch |err| {
        capture.err = err;
        first_thread.join();
        return;
    };
    handleMaybeSignalCommand(second, capture, responded);
    first_thread.join();
}

fn handleMaybeSignalCommand(
    conn: std.net.Server.Connection,
    capture: *OneShotCapture,
    responded: *std.atomic.Value(bool),
) void {
    defer conn.stream.close();

    var request: [512]u8 = undefined;
    const len = conn.stream.read(&request) catch |err| {
        capture.err = err;
        return;
    };
    if (len == 0) return;
    if (responded.swap(true, .seq_cst)) return;

    @memcpy(capture.request[0..len], request[0..len]);
    capture.request_len = len;
    conn.stream.writeAll(capture.response) catch |err| {
        capture.err = err;
        return;
    };
}

fn unblockServer(path: []const u8) void {
    var stream = std.net.connectUnixSocket(path) catch return;
    stream.close();
}

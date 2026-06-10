const std = @import("std");
const interfaces = @import("interfaces.zig");
const line_io = @import("line.zig");
const protocol = @import("protocol.zig");

const max_request_line = 1024 * 1024;
const default_client_write_timeout_ms: u64 = 2000;

const log = std.log.scoped(.ipc_snapshot_broadcaster);

pub const Broadcaster = struct {
    allocator: std.mem.Allocator,
    handler: interfaces.CommandHandler,
    snapshot_provider: interfaces.SnapshotProvider,
    stopped: *std.atomic.Value(bool),
    clients: std.array_list.Managed(*SnapshotClient),
    workers: std.array_list.Managed(ClientWorker),
    snapshot_monitor_thread: ?std.Thread = null,
    clients_mutex: std.Thread.Mutex = .{},
    snapshot_broadcast_mutex: std.Thread.Mutex = .{},
    last_broadcast_snapshot_line: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        handler: interfaces.CommandHandler,
        snapshot_provider: interfaces.SnapshotProvider,
        stopped: *std.atomic.Value(bool),
    ) Broadcaster {
        return .{
            .allocator = allocator,
            .handler = handler,
            .snapshot_provider = snapshot_provider,
            .stopped = stopped,
            .clients = std.array_list.Managed(*SnapshotClient).init(allocator),
            .workers = std.array_list.Managed(ClientWorker).init(allocator),
        };
    }

    pub fn start(self: *Broadcaster) !void {
        self.snapshot_monitor_thread = try std.Thread.spawn(.{}, runSnapshotMonitor, .{self});
    }

    pub fn deinit(self: *Broadcaster) void {
        self.closeAllClients();
        if (self.snapshot_monitor_thread) |thread| thread.join();
        for (self.workers.items) |worker| {
            worker.thread.join();
            self.removeClient(worker.client);
            worker.client.close();
            self.allocator.destroy(worker.client);
        }
        self.workers.deinit();

        for (self.clients.items) |client| {
            client.close();
            self.allocator.destroy(client);
        }
        self.clients.deinit();
        if (self.last_broadcast_snapshot_line) |line| self.allocator.free(line);
    }

    pub fn addClient(self: *Broadcaster, stream: std.net.Stream) !void {
        var stream_owned = true;
        errdefer if (stream_owned) stream.close();

        self.reapFinishedClients();
        try self.workers.ensureUnusedCapacity(1);
        self.clients_mutex.lock();
        self.clients.ensureUnusedCapacity(1) catch |err| {
            self.clients_mutex.unlock();
            return err;
        };
        self.clients_mutex.unlock();

        const client = try self.allocator.create(SnapshotClient);
        errdefer self.allocator.destroy(client);
        client.* = .{ .stream = stream };
        stream_owned = false;

        self.clients_mutex.lock();
        self.clients.appendAssumeCapacity(client);
        self.clients_mutex.unlock();

        const thread = std.Thread.spawn(.{}, handleSnapshotClient, .{ self, client }) catch |err| {
            self.removeClient(client);
            client.close();
            return err;
        };
        self.workers.appendAssumeCapacity(.{
            .client = client,
            .thread = thread,
        });
    }

    fn removeClient(self: *Broadcaster, client: *SnapshotClient) void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        for (self.clients.items, 0..) |item, index| {
            if (item == client) {
                _ = self.clients.swapRemove(index);
                return;
            }
        }
    }

    fn reapFinishedClients(self: *Broadcaster) void {
        var index: usize = 0;
        while (index < self.workers.items.len) {
            const worker = self.workers.items[index];
            if (!worker.client.finished.load(.seq_cst)) {
                index += 1;
                continue;
            }

            _ = self.workers.swapRemove(index);
            worker.thread.join();
            self.removeClient(worker.client);
            worker.client.close();
            self.allocator.destroy(worker.client);
        }
    }

    pub fn closeAllClients(self: *Broadcaster) void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        for (self.clients.items) |client| client.close();
    }

    fn serveClient(self: *Broadcaster, client: *SnapshotClient) !void {
        const initial_line = try self.snapshot_provider.snapshotLine(self.allocator);
        defer self.allocator.free(initial_line);
        try client.writeAll(initial_line);

        while (!self.stopped.load(.seq_cst)) {
            const request_line = try line_io.read(self.allocator, client.stream, max_request_line);
            defer self.allocator.free(request_line);

            const request = try protocol.parseCommandRequestLine(self.allocator, request_line);
            defer protocol.deinitCommandRequest(self.allocator, request);

            const is_switch = request.action == .switch_process;
            var snapshot_broadcast_locked = is_switch;
            if (snapshot_broadcast_locked) self.snapshot_broadcast_mutex.lock();
            defer if (snapshot_broadcast_locked) self.snapshot_broadcast_mutex.unlock();

            var response = try self.handler.handleCommand(self.allocator, request);
            defer response.deinit(self.allocator);

            const line = try protocol.responseLine(self.allocator, response);
            defer self.allocator.free(line);

            if (is_switch) {
                if (response.success) try self.publishCommandSnapshotExceptLocked(client);
                self.snapshot_broadcast_mutex.unlock();
                snapshot_broadcast_locked = false;
            }

            try client.writeAll(line);

            if (response.success and !is_switch) {
                try self.publishCommandSnapshot();
            }
        }
    }

    fn publishCommandSnapshot(self: *Broadcaster) !void {
        // Successful Process Commands publish the current Snapshot even when it is
        // byte-for-byte unchanged; the monitor uses the remembered line only to
        // avoid echoing that same Snapshot again on its next polling tick.
        self.snapshot_broadcast_mutex.lock();
        defer self.snapshot_broadcast_mutex.unlock();

        const line = try self.snapshot_provider.snapshotLine(self.allocator);
        defer self.allocator.free(line);
        try self.rememberPublishedSnapshotLineLocked(line);
        try self.writeSnapshotLineToClientsExcept(line, null);
    }

    fn publishCommandSnapshotExcept(self: *Broadcaster, excluded: *SnapshotClient) !void {
        self.snapshot_broadcast_mutex.lock();
        defer self.snapshot_broadcast_mutex.unlock();
        try self.publishCommandSnapshotExceptLocked(excluded);
    }

    fn publishCommandSnapshotExceptLocked(self: *Broadcaster, excluded: *SnapshotClient) !void {
        const line = try self.snapshot_provider.snapshotLine(self.allocator);
        defer self.allocator.free(line);
        try self.rememberPublishedSnapshotLineLocked(line);
        try self.writeSnapshotLineToClientsExcept(line, excluded);
    }

    fn rememberPublishedSnapshotLineLocked(self: *Broadcaster, line: []const u8) !void {
        if (self.last_broadcast_snapshot_line) |previous| {
            if (std.mem.eql(u8, previous, line)) return;
        }

        const copy = try self.allocator.dupe(u8, line);
        if (self.last_broadcast_snapshot_line) |previous| self.allocator.free(previous);
        self.last_broadcast_snapshot_line = copy;
    }

    fn writeSnapshotLineToClientsExcept(self: *Broadcaster, line: []const u8, excluded: ?*SnapshotClient) !void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        for (self.clients.items) |client| {
            if (excluded) |skip| {
                if (client == skip) continue;
            }
            if (client.closed.load(.seq_cst)) continue;
            client.writeAll(line) catch |err| {
                log.debug("dropping snapshot broadcast to disconnected client: {s}", .{@errorName(err)});
            };
        }
    }

    fn monitorSnapshotChanges(self: *Broadcaster) !void {
        while (!self.stopped.load(.seq_cst)) {
            std.Thread.sleep(50 * std.time.ns_per_ms);

            self.snapshot_broadcast_mutex.lock();
            defer self.snapshot_broadcast_mutex.unlock();

            const line = try self.snapshot_provider.snapshotLine(self.allocator);
            defer self.allocator.free(line);

            if (self.last_broadcast_snapshot_line) |previous| {
                if (std.mem.eql(u8, previous, line)) continue;
            }
            try self.rememberPublishedSnapshotLineLocked(line);
            try self.writeSnapshotLineToClientsExcept(line, null);
        }
    }
};

const ClientWorker = struct {
    client: *SnapshotClient,
    thread: std.Thread,
};

const SnapshotClient = struct {
    stream: std.net.Stream,
    write_mutex: std.Thread.Mutex = .{},
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    write_timeout_ms: u64 = default_client_write_timeout_ms,

    fn close(self: *SnapshotClient) void {
        if (!self.closed.swap(true, .seq_cst)) self.stream.close();
    }

    fn writeAll(self: *SnapshotClient, bytes: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        if (self.closed.load(.seq_cst)) return error.EndOfStream;
        writeAllWithTimeout(self.stream, bytes, self.write_timeout_ms) catch |err| {
            self.close();
            return err;
        };
    }
};

fn runSnapshotMonitor(server: *Broadcaster) void {
    server.monitorSnapshotChanges() catch |err| {
        log.debug("snapshot monitor stopped: {s}", .{@errorName(err)});
    };
}

fn handleSnapshotClient(server: *Broadcaster, client: *SnapshotClient) void {
    server.serveClient(client) catch |err| {
        log.debug("snapshot client handler stopped: {s}", .{@errorName(err)});
    };
    client.close();
    client.finished.store(true, .seq_cst);
}

fn writeAllWithTimeout(stream: std.net.Stream, bytes: []const u8, timeout_ms: u64) !void {
    try setStreamWriteTimeoutMs(stream, timeout_ms);

    var index: usize = 0;
    while (index < bytes.len) {
        const written = stream.write(bytes[index..]) catch |err| switch (err) {
            error.WouldBlock => return error.WriteTimeout,
            else => return err,
        };
        if (written == 0) return error.WriteFailed;
        index += written;
    }
}

fn setStreamWriteTimeoutMs(stream: std.net.Stream, timeout_ms: u64) !void {
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    const rc = std.c.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        &tv,
        @sizeOf(@TypeOf(tv)),
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => return,
        .DOM => return error.TimeoutTooBig,
        else => return error.WriteFailed,
    }
}

test "snapshot client write times out and closes slow reader" {
    var streams = try testSocketPair();
    var client = SnapshotClient{ .stream = streams[0] };
    defer client.close();
    defer streams[1].close();

    client.write_timeout_ms = 20;

    const payload = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');

    const started = std.time.milliTimestamp();
    try std.testing.expectError(error.WriteTimeout, client.writeAll(payload));
    const elapsed_ms = std.time.milliTimestamp() - started;

    try std.testing.expect(elapsed_ms < 1000);
    try std.testing.expect(client.closed.load(.seq_cst));
}

test "snapshot client closes peer that disconnects before initial snapshot write" {
    var streams = try testSocketPair();
    var client = SnapshotClient{ .stream = streams[0] };
    defer client.close();

    streams[1].close();

    try std.testing.expectError(error.WriteFailed, client.writeAll("initial\n"));
    try std.testing.expect(client.closed.load(.seq_cst));
}

test "snapshot monitor broadcasts its first sampled snapshot" {
    const snapshot_line = "{\"type\":\"snapshot\",\"protocol_version\":1,\"current_process_id\":0,\"exiting\":false,\"ui\":{},\"processes\":[]}\n";
    var provider = StaticSnapshotProvider{ .line = snapshot_line };
    var stopped = std.atomic.Value(bool).init(false);
    var broadcaster = Broadcaster.init(
        std.testing.allocator,
        unusedCommandHandler(),
        provider.provider(),
        &stopped,
    );
    defer {
        stopped.store(true, .seq_cst);
        broadcaster.closeAllClients();
        broadcaster.deinit();
    }

    var streams = try testSocketPair();
    defer streams[1].close();

    const client = try std.testing.allocator.create(SnapshotClient);
    errdefer std.testing.allocator.destroy(client);
    errdefer client.close();
    client.* = .{
        .stream = streams[0],
        .write_timeout_ms = 200,
    };
    try broadcaster.clients.append(client);

    try broadcaster.start();

    const line = try line_io.readTimeout(std.testing.allocator, streams[1], 1024, 500);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings(snapshot_line, line);
}

test "snapshot monitor does not echo snapshot already published except requester" {
    const snapshot_line = "{\"type\":\"snapshot\",\"protocol_version\":1,\"current_process_id\":1,\"exiting\":false,\"ui\":{},\"processes\":[]}\n";
    var provider = StaticSnapshotProvider{ .line = snapshot_line };
    var stopped = std.atomic.Value(bool).init(false);
    var broadcaster = Broadcaster.init(
        std.testing.allocator,
        unusedCommandHandler(),
        provider.provider(),
        &stopped,
    );
    defer {
        stopped.store(true, .seq_cst);
        broadcaster.closeAllClients();
        broadcaster.deinit();
    }

    var requester_streams = try testSocketPair();
    defer requester_streams[1].close();
    var observer_streams = try testSocketPair();
    defer observer_streams[1].close();

    const requester = try std.testing.allocator.create(SnapshotClient);
    errdefer std.testing.allocator.destroy(requester);
    errdefer requester.close();
    requester.* = .{
        .stream = requester_streams[0],
        .write_timeout_ms = 200,
    };
    try broadcaster.clients.append(requester);

    const observer = try std.testing.allocator.create(SnapshotClient);
    errdefer std.testing.allocator.destroy(observer);
    errdefer observer.close();
    observer.* = .{
        .stream = observer_streams[0],
        .write_timeout_ms = 200,
    };
    try broadcaster.clients.append(observer);

    try broadcaster.publishCommandSnapshotExcept(requester);

    const observer_line = try line_io.readTimeout(std.testing.allocator, observer_streams[1], 1024, 200);
    defer std.testing.allocator.free(observer_line);
    try std.testing.expectEqualStrings(snapshot_line, observer_line);

    try std.testing.expectError(
        error.CommandTimeout,
        line_io.readTimeout(std.testing.allocator, requester_streams[1], 1024, 50),
    );

    try broadcaster.start();
    try std.testing.expectError(
        error.CommandTimeout,
        line_io.readTimeout(std.testing.allocator, requester_streams[1], 1024, 150),
    );
}

test "successful process command publishes snapshot and finished client is reaped" {
    const snapshot_line = "{\"type\":\"snapshot\",\"protocol_version\":1,\"current_process_id\":1,\"exiting\":false,\"ui\":{},\"processes\":[]}\n";
    var handler = SuccessCommandHandler{};
    var provider = StaticSnapshotProvider{ .line = snapshot_line };
    var stopped = std.atomic.Value(bool).init(false);
    var broadcaster = Broadcaster.init(
        std.testing.allocator,
        handler.handler(),
        provider.provider(),
        &stopped,
    );
    defer {
        stopped.store(true, .seq_cst);
        broadcaster.closeAllClients();
        broadcaster.deinit();
    }

    var streams = try testSocketPair();
    var peer_open = true;
    defer if (peer_open) streams[1].close();

    try broadcaster.addClient(streams[0]);

    const initial_line = try line_io.readTimeout(std.testing.allocator, streams[1], 1024, 500);
    defer std.testing.allocator.free(initial_line);
    try std.testing.expectEqualStrings(snapshot_line, initial_line);

    const command_line = try protocol.commandRequestLine(std.testing.allocator, 9, .start, "api");
    defer std.testing.allocator.free(command_line);
    try streams[1].writeAll(command_line);

    const response_line = try line_io.readTimeout(std.testing.allocator, streams[1], 1024, 500);
    defer std.testing.allocator.free(response_line);
    var response = try protocol.parseResponseLine(std.testing.allocator, response_line);
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(response.success);
    try std.testing.expectEqual(@as(u64, 9), response.request_id);

    const published_line = try line_io.readTimeout(std.testing.allocator, streams[1], 1024, 500);
    defer std.testing.allocator.free(published_line);
    try std.testing.expectEqualStrings(snapshot_line, published_line);

    streams[1].close();
    peer_open = false;
    try waitForOnlyWorkerFinished(&broadcaster);
    broadcaster.reapFinishedClients();

    try std.testing.expectEqual(@as(usize, 0), broadcaster.workers.items.len);
    try std.testing.expectEqual(@as(usize, 0), broadcaster.clients.items.len);
    try std.testing.expectEqual(@as(usize, 1), handler.call_count);
}

fn waitForOnlyWorkerFinished(broadcaster: *Broadcaster) !void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (broadcaster.workers.items.len == 1 and
            broadcaster.workers.items[0].client.finished.load(.seq_cst)) return;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.WorkerDidNotFinish;
}

fn testSocketPair() ![2]std.net.Stream {
    var fds: [2]std.c.fd_t = undefined;
    const rc = std.c.socketpair(
        @intCast(std.posix.AF.UNIX),
        @intCast(std.posix.SOCK.STREAM),
        0,
        &fds,
    );
    if (rc != 0) return error.SocketPairFailed;

    return .{
        .{ .handle = fds[0] },
        .{ .handle = fds[1] },
    };
}

const SuccessCommandHandler = struct {
    call_count: usize = 0,

    fn handler(self: *SuccessCommandHandler) interfaces.CommandHandler {
        return .{
            .context = self,
            .handle = handle,
        };
    }

    fn handle(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request: protocol.CommandRequest,
    ) anyerror!protocol.Response {
        const self: *SuccessCommandHandler = @ptrCast(@alignCast(context));
        self.call_count += 1;
        return .{
            .request_id = request.request_id,
            .success = true,
            .error_message = try allocator.dupe(u8, ""),
        };
    }
};

const StaticSnapshotProvider = struct {
    line: []const u8,

    fn provider(self: *StaticSnapshotProvider) interfaces.SnapshotProvider {
        return .{
            .context = self,
            .snapshot_line = snapshotLine,
        };
    }

    fn snapshotLine(context: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *StaticSnapshotProvider = @ptrCast(@alignCast(context));
        return allocator.dupe(u8, self.line);
    }
};

fn unusedCommandHandler() interfaces.CommandHandler {
    return .{
        .context = undefined,
        .handle = unusedHandleCommand,
    };
}

fn unusedHandleCommand(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: protocol.CommandRequest,
) anyerror!protocol.Response {
    unreachable;
}

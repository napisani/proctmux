const std = @import("std");
const builtin = @import("builtin");
const line_io = @import("line.zig");
const protocol = @import("protocol.zig");

const max_request_line = 1024 * 1024;
const default_client_write_timeout_ms: u64 = 2000;
var peer_credential_warning_logged = std.atomic.Value(bool).init(false);

const log = std.log.scoped(.ipc_server);

pub const CommandHandler = struct {
    context: *anyopaque,
    handle: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request: protocol.CommandRequest,
    ) anyerror!protocol.Response,

    fn handleCommand(
        self: CommandHandler,
        allocator: std.mem.Allocator,
        request: protocol.CommandRequest,
    ) !protocol.Response {
        return self.handle(self.context, allocator, request);
    }
};

pub const StateProvider = struct {
    context: *anyopaque,
    state_line: *const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8,

    fn stateLine(self: StateProvider, allocator: std.mem.Allocator) ![]const u8 {
        return self.state_line(self.context, allocator);
    }
};

pub const PeerAuthorizer = struct {
    context: *anyopaque,
    authorize: *const fn (context: *anyopaque, fd: std.posix.fd_t) anyerror!void,

    fn authorizeStream(self: PeerAuthorizer, stream: std.net.Stream) !void {
        try self.authorize(self.context, stream.handle);
    }
};

const DefaultPeerAuthorizerContext = struct {};
var default_peer_authorizer_context = DefaultPeerAuthorizerContext{};

pub fn defaultPeerAuthorizer() PeerAuthorizer {
    return .{
        .context = &default_peer_authorizer_context,
        .authorize = authorizeDefaultPeer,
    };
}

pub fn serveOneCommandAtPath(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    handler: CommandHandler,
) !void {
    try serveAtPath(allocator, socket_path, handler, .one_command, null);
}

pub fn serveOneCommandAtPathWithAuthorizer(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    handler: CommandHandler,
    authorizer: PeerAuthorizer,
) !void {
    try serveAtPath(allocator, socket_path, handler, .one_command, authorizer);
}

pub fn serveCommandsAtPath(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    handler: CommandHandler,
    stopped: *std.atomic.Value(bool),
) !void {
    try serveAtPath(allocator, socket_path, handler, .{ .command_loop = stopped }, null);
}

pub fn serveCommandsAtPathWithAuthorizer(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    handler: CommandHandler,
    stopped: *std.atomic.Value(bool),
    authorizer: PeerAuthorizer,
) !void {
    try serveAtPath(allocator, socket_path, handler, .{ .command_loop = stopped }, authorizer);
}

pub fn serveCommandsAtPathWithState(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    handler: CommandHandler,
    state_provider: StateProvider,
    stopped: *std.atomic.Value(bool),
) !void {
    try serveAtPath(allocator, socket_path, handler, .{ .state_loop = .{
        .provider = state_provider,
        .stopped = stopped,
    } }, null);
}

pub fn serveCommandsAtPathWithStateAndAuthorizer(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    handler: CommandHandler,
    state_provider: StateProvider,
    stopped: *std.atomic.Value(bool),
    authorizer: PeerAuthorizer,
) !void {
    try serveAtPath(allocator, socket_path, handler, .{ .state_loop = .{
        .provider = state_provider,
        .stopped = stopped,
    } }, authorizer);
}

const ServeMode = union(enum) {
    one_command,
    command_loop: *std.atomic.Value(bool),
    state_loop: StateLoop,
};

const StateLoop = struct {
    provider: StateProvider,
    stopped: *std.atomic.Value(bool),
};

fn serveAtPath(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    handler: CommandHandler,
    mode: ServeMode,
    maybe_authorizer: ?PeerAuthorizer,
) !void {
    const authorizer = maybe_authorizer orelse defaultPeerAuthorizer();

    switch (mode) {
        .state_loop => |state_loop| {
            var state_server = StateCommandServer.init(
                allocator,
                handler,
                state_loop.provider,
                state_loop.stopped,
                authorizer,
            );
            defer state_server.deinit();
            try state_server.serve(socket_path);
        },
        .one_command => try serveCommandListener(allocator, socket_path, handler, authorizer, null),
        .command_loop => |stopped| try serveCommandListener(allocator, socket_path, handler, authorizer, stopped),
    }
}

fn serveCommandListener(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    handler: CommandHandler,
    authorizer: PeerAuthorizer,
    stopped: ?*std.atomic.Value(bool),
) !void {
    std.fs.deleteFileAbsolute(socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const address = try std.net.Address.initUnix(socket_path);
    var listener = try address.listen(.{});
    defer listener.deinit();
    try setSocketPermissions(socket_path);

    if (stopped == null) {
        const conn = try listener.accept();
        authorizer.authorizeStream(conn.stream) catch |err| {
            conn.stream.close();
            return err;
        };
        try serveCommandConnection(allocator, conn.stream, handler, null);
        return;
    }

    const stop_signal = stopped.?;
    while (!stop_signal.load(.seq_cst)) {
        const conn = listener.accept() catch |err| {
            if (stop_signal.load(.seq_cst)) break;
            return err;
        };
        authorizer.authorizeStream(conn.stream) catch {
            conn.stream.close();
            continue;
        };
        serveCommandConnection(allocator, conn.stream, handler, null) catch |err| switch (err) {
            error.EndOfStream, error.BrokenPipe, error.WriteFailed => {
                if (stop_signal.load(.seq_cst)) break;
            },
            else => return err,
        };
    }
}

fn serveCommandConnection(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    handler: CommandHandler,
    state_provider: ?StateProvider,
) !void {
    defer stream.close();

    if (state_provider) |provider| {
        const line = try provider.stateLine(allocator);
        defer allocator.free(line);
        try stream.writeAll(line);
    }

    while (true) {
        const request_line = try line_io.read(allocator, stream, max_request_line);
        defer allocator.free(request_line);

        var request = try protocol.parseCommandRequestLine(allocator, request_line);
        defer request.deinit(allocator);

        var response = try handler.handleCommand(allocator, request);
        defer response.deinit(allocator);

        if (state_provider) |provider| {
            if (response.success and shouldBroadcastState(request.action)) {
                const state_line = try provider.stateLine(allocator);
                defer allocator.free(state_line);
                try stream.writeAll(state_line);
            }
        }

        const line = try protocol.responseLine(allocator, response);
        defer allocator.free(line);
        try stream.writeAll(line);

        if (state_provider == null) return;
    }
}

fn shouldBroadcastState(action: protocol.Command) bool {
    return action != .list;
}

const StateClient = struct {
    stream: std.net.Stream,
    write_mutex: std.Thread.Mutex = .{},
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    write_timeout_ms: u64 = default_client_write_timeout_ms,

    fn close(self: *StateClient) void {
        if (!self.closed.swap(true, .seq_cst)) self.stream.close();
    }

    fn writeAll(self: *StateClient, bytes: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        if (self.closed.load(.seq_cst)) return error.EndOfStream;
        writeAllWithTimeout(self.stream, bytes, self.write_timeout_ms) catch |err| {
            self.close();
            return err;
        };
    }
};

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

test "state client write times out and closes slow reader" {
    var streams = try testSocketPair();
    var client = StateClient{ .stream = streams[0] };
    defer client.close();
    defer streams[1].close();

    client.write_timeout_ms = 20;

    const payload = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');

    const started = std.time.milliTimestamp();
    try std.testing.expectError(error.WriteTimeout, client.writeAll(payload));
    const elapsed = std.time.milliTimestamp() - started;

    try std.testing.expect(elapsed < 1000);
    try std.testing.expect(client.closed.load(.seq_cst));
}

test "state client closes peer that disconnects before initial state write" {
    var streams = try testSocketPair();
    var client = StateClient{ .stream = streams[0] };
    defer client.close();

    streams[1].close();

    try std.testing.expectError(error.WriteFailed, client.writeAll("initial\n"));
    try std.testing.expect(client.closed.load(.seq_cst));
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

const StateCommandServer = struct {
    allocator: std.mem.Allocator,
    handler: CommandHandler,
    state_provider: StateProvider,
    stopped: *std.atomic.Value(bool),
    authorizer: PeerAuthorizer,
    clients: std.array_list.Managed(*StateClient),
    threads: std.array_list.Managed(std.Thread),
    state_monitor_thread: ?std.Thread = null,
    clients_mutex: std.Thread.Mutex = .{},

    fn init(
        allocator: std.mem.Allocator,
        handler: CommandHandler,
        state_provider: StateProvider,
        stopped: *std.atomic.Value(bool),
        authorizer: PeerAuthorizer,
    ) StateCommandServer {
        return .{
            .allocator = allocator,
            .handler = handler,
            .state_provider = state_provider,
            .stopped = stopped,
            .authorizer = authorizer,
            .clients = std.array_list.Managed(*StateClient).init(allocator),
            .threads = std.array_list.Managed(std.Thread).init(allocator),
        };
    }

    fn deinit(self: *StateCommandServer) void {
        self.closeAllClients();
        if (self.state_monitor_thread) |thread| thread.join();
        for (self.threads.items) |thread| thread.join();
        self.threads.deinit();

        for (self.clients.items) |client| {
            client.close();
            self.allocator.destroy(client);
        }
        self.clients.deinit();
    }

    fn serve(self: *StateCommandServer, socket_path: []const u8) !void {
        std.fs.deleteFileAbsolute(socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const address = try std.net.Address.initUnix(socket_path);
        var listener = try address.listen(.{});
        defer listener.deinit();
        try setSocketPermissions(socket_path);

        self.state_monitor_thread = try std.Thread.spawn(.{}, runStateMonitor, .{self});

        while (!self.stopped.load(.seq_cst)) {
            const conn = listener.accept() catch |err| {
                if (self.stopped.load(.seq_cst)) break;
                return err;
            };
            if (self.stopped.load(.seq_cst)) {
                conn.stream.close();
                break;
            }

            self.authorizer.authorizeStream(conn.stream) catch {
                conn.stream.close();
                continue;
            };

            const client = try self.allocator.create(StateClient);
            errdefer self.allocator.destroy(client);
            client.* = .{ .stream = conn.stream };

            self.clients_mutex.lock();
            self.clients.append(client) catch |err| {
                self.clients_mutex.unlock();
                client.close();
                return err;
            };
            self.clients_mutex.unlock();

            const thread = try std.Thread.spawn(.{}, handleStateClient, .{ self, client });
            self.threads.append(thread) catch |err| {
                client.close();
                return err;
            };
        }
    }

    fn closeAllClients(self: *StateCommandServer) void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        for (self.clients.items) |client| client.close();
    }

    fn serveClient(self: *StateCommandServer, client: *StateClient) !void {
        const initial_line = try self.state_provider.stateLine(self.allocator);
        defer self.allocator.free(initial_line);
        try client.writeAll(initial_line);

        while (!self.stopped.load(.seq_cst)) {
            const request_line = try line_io.read(self.allocator, client.stream, max_request_line);
            defer self.allocator.free(request_line);

            var request = try protocol.parseCommandRequestLine(self.allocator, request_line);
            defer request.deinit(self.allocator);

            var response = try self.handler.handleCommand(self.allocator, request);
            defer response.deinit(self.allocator);

            if (response.success and shouldBroadcastState(request.action)) {
                try self.broadcastState();
            }

            const line = try protocol.responseLine(self.allocator, response);
            defer self.allocator.free(line);
            try client.writeAll(line);
        }
    }

    fn broadcastState(self: *StateCommandServer) !void {
        const line = try self.state_provider.stateLine(self.allocator);
        defer self.allocator.free(line);

        try self.broadcastStateLine(line);
    }

    fn broadcastStateLine(self: *StateCommandServer, line: []const u8) !void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        for (self.clients.items) |client| {
            if (client.closed.load(.seq_cst)) continue;
            client.writeAll(line) catch |err| {
                log.debug("dropping state broadcast to disconnected client: {s}", .{@errorName(err)});
            };
        }
    }

    fn monitorStateChanges(self: *StateCommandServer) !void {
        var last_line: ?[]const u8 = null;
        defer if (last_line) |line| self.allocator.free(line);

        while (!self.stopped.load(.seq_cst)) {
            std.Thread.sleep(50 * std.time.ns_per_ms);

            const line = try self.state_provider.stateLine(self.allocator);
            defer self.allocator.free(line);

            if (last_line) |previous| {
                if (std.mem.eql(u8, previous, line)) continue;
                self.allocator.free(previous);
                last_line = try self.allocator.dupe(u8, line);
                try self.broadcastStateLine(line);
            } else {
                last_line = try self.allocator.dupe(u8, line);
            }
        }
    }
};

fn runStateMonitor(server: *StateCommandServer) void {
    server.monitorStateChanges() catch |err| {
        log.debug("state monitor stopped: {s}", .{@errorName(err)});
    };
}

fn handleStateClient(server: *StateCommandServer, client: *StateClient) void {
    server.serveClient(client) catch |err| {
        log.debug("state client handler stopped: {s}", .{@errorName(err)});
    };
    client.close();
}

fn authorizeDefaultPeer(_: *anyopaque, fd: std.posix.fd_t) !void {
    const peer_uid = peerUID(fd) catch |err| switch (err) {
        error.PeerCredentialUnsupported => {
            if (!peer_credential_warning_logged.swap(true, .seq_cst)) {
                std.log.warn("Peer credential checks not supported on this platform; relying on socket permissions only", .{});
            }
            return;
        },
        else => return err,
    };

    const expected_uid: u32 = @intCast(std.posix.geteuid());
    if (peer_uid != expected_uid) return error.UnauthorizedPeer;
}

fn peerUID(fd: std.posix.fd_t) !u32 {
    return switch (builtin.os.tag) {
        .macos => peerUIDDarwin(fd),
        .linux => peerUIDLinux(fd),
        else => error.PeerCredentialUnsupported,
    };
}

const darwin_sol_local: i32 = 0;
const darwin_local_peercred: u32 = 0x001;
const darwin_ngroups: usize = 16;

const DarwinXuCred = extern struct {
    cr_version: c_uint,
    cr_uid: std.c.uid_t,
    cr_ngroups: c_short,
    cr_groups: [darwin_ngroups]std.c.gid_t,
};

fn peerUIDDarwin(fd: std.posix.fd_t) !u32 {
    var cred: DarwinXuCred = undefined;
    std.posix.getsockopt(fd, darwin_sol_local, darwin_local_peercred, std.mem.asBytes(&cred)) catch |err| switch (err) {
        error.InvalidProtocolOption => return error.PeerCredentialUnsupported,
        else => return err,
    };
    if (cred.cr_uid == std.math.maxInt(std.c.uid_t)) return error.InvalidPeerCredential;
    return @intCast(cred.cr_uid);
}

const LinuxUCred = extern struct {
    pid: std.os.linux.pid_t,
    uid: std.os.linux.uid_t,
    gid: std.os.linux.gid_t,
};

fn peerUIDLinux(fd: std.posix.fd_t) !u32 {
    var cred: LinuxUCred = undefined;
    std.posix.getsockopt(fd, std.os.linux.SOL.SOCKET, std.os.linux.SO.PEERCRED, std.mem.asBytes(&cred)) catch |err| switch (err) {
        error.InvalidProtocolOption => return error.PeerCredentialUnsupported,
        else => return err,
    };
    return @intCast(cred.uid);
}

fn setSocketPermissions(socket_path: []const u8) !void {
    try std.posix.fchmodat(std.posix.AT.FDCWD, socket_path, 0o600, 0);
}

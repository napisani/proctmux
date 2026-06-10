//! Unix-socket IPC server entrypoints.
//! This module owns socket lifecycle, permissions, and peer authorization; stateful Snapshot broadcasting is delegated to `snapshot_broadcaster`.

const std = @import("std");
const builtin = @import("builtin");
const interfaces = @import("interfaces.zig");
const line_io = @import("line.zig");
const protocol = @import("protocol.zig");
const snapshot_broadcaster = @import("snapshot_broadcaster.zig");

const max_request_line = 1024 * 1024;
var peer_credential_warning_logged = std.atomic.Value(bool).init(false);

pub const CommandHandler = interfaces.CommandHandler;
pub const SnapshotProvider = interfaces.SnapshotProvider;
pub const PeerAuthorizer = interfaces.PeerAuthorizer;

const DefaultPeerAuthorizerContext = struct {};
var default_peer_authorizer_context = DefaultPeerAuthorizerContext{};

/// Production authorizer: prefer same-UID peer credentials and fall back to
/// socket permissions only on platforms without credential support.
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

/// Serves the stateful Primary Server IPC path: clients receive an initial
/// Snapshot, then may send commands and receive broadcasts on the same stream.
pub fn serveCommandsAtPathWithSnapshots(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    handler: CommandHandler,
    snapshot_provider: SnapshotProvider,
    stopped: *std.atomic.Value(bool),
) !void {
    try serveAtPath(allocator, socket_path, handler, .{ .snapshot_loop = .{
        .provider = snapshot_provider,
        .stopped = stopped,
    } }, null);
}

pub fn serveCommandsAtPathWithSnapshotsAndAuthorizer(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    handler: CommandHandler,
    snapshot_provider: SnapshotProvider,
    stopped: *std.atomic.Value(bool),
    authorizer: PeerAuthorizer,
) !void {
    try serveAtPath(allocator, socket_path, handler, .{ .snapshot_loop = .{
        .provider = snapshot_provider,
        .stopped = stopped,
    } }, authorizer);
}

const ServeMode = union(enum) {
    one_command,
    snapshot_loop: SnapshotLoop,
};

const SnapshotLoop = struct {
    provider: SnapshotProvider,
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
        .snapshot_loop => |snapshot_loop| try serveSnapshotListener(
            allocator,
            socket_path,
            handler,
            snapshot_loop.provider,
            snapshot_loop.stopped,
            authorizer,
        ),
        .one_command => try serveOneCommandListener(allocator, socket_path, handler, authorizer),
    }
}

fn serveOneCommandListener(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    handler: CommandHandler,
    authorizer: PeerAuthorizer,
) !void {
    var listener = try listenAtSocketPath(socket_path);
    defer listener.deinit();

    const conn = try listener.accept();
    authorizer.authorizeStream(conn.stream) catch |err| {
        conn.stream.close();
        return err;
    };
    try serveCommandConnection(allocator, conn.stream, handler);
}

fn serveSnapshotListener(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    handler: CommandHandler,
    snapshot_provider: SnapshotProvider,
    stopped: *std.atomic.Value(bool),
    authorizer: PeerAuthorizer,
) !void {
    var listener = try listenAtSocketPath(socket_path);
    defer listener.deinit();

    var broadcaster = snapshot_broadcaster.Broadcaster.init(
        allocator,
        handler,
        snapshot_provider,
        stopped,
    );
    defer broadcaster.deinit();
    try broadcaster.start();

    while (!stopped.load(.seq_cst)) {
        const conn = listener.accept() catch |err| {
            if (stopped.load(.seq_cst)) break;
            return err;
        };
        if (stopped.load(.seq_cst)) {
            conn.stream.close();
            break;
        }

        authorizer.authorizeStream(conn.stream) catch {
            conn.stream.close();
            continue;
        };

        // After authorization the broadcaster owns the stream; this keeps
        // connection lifetime separate from socket accept/permission concerns.
        try broadcaster.addClient(conn.stream);
    }
}

fn listenAtSocketPath(socket_path: []const u8) !std.net.Server {
    std.fs.deleteFileAbsolute(socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const address = try std.net.Address.initUnix(socket_path);
    var listener = try address.listen(.{});
    errdefer listener.deinit();
    try setSocketPermissions(socket_path);
    return listener;
}

fn serveCommandConnection(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    handler: CommandHandler,
) !void {
    defer stream.close();

    const request_line = try line_io.read(allocator, stream, max_request_line);
    defer allocator.free(request_line);

    const request = try protocol.parseCommandRequestLine(allocator, request_line);
    defer protocol.deinitCommandRequest(allocator, request);

    var response = try handler.handleCommand(allocator, request);
    defer response.deinit(allocator);

    const line = try protocol.responseLine(allocator, response);
    defer allocator.free(line);
    try stream.writeAll(line);
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

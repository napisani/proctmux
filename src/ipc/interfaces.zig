//! Small callback interfaces at IPC seams.
//! These adapters let IPC transport own sockets and serialization while Primary Server owns Process Command execution and Snapshot production.

const std = @import("std");
const protocol = @import("protocol.zig");

/// Adapter from transport-owned command requests to the domain owner that can
/// actually mutate process state.
pub const CommandHandler = struct {
    context: *anyopaque,
    handle: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request: protocol.CommandRequest,
    ) anyerror!protocol.Response,

    pub fn handleCommand(
        self: CommandHandler,
        allocator: std.mem.Allocator,
        request: protocol.CommandRequest,
    ) !protocol.Response {
        return self.handle(self.context, allocator, request);
    }
};

/// Adapter that lets the broadcaster ask the Primary Server for a fresh encoded
/// Client Snapshot without knowing AppState or ProcessController internals.
pub const SnapshotProvider = struct {
    context: *anyopaque,
    snapshot_line: *const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8,

    pub fn snapshotLine(self: SnapshotProvider, allocator: std.mem.Allocator) ![]const u8 {
        return self.snapshot_line(self.context, allocator);
    }
};

/// Authorization seam for accepted Unix socket streams. Production verifies
/// same-user peers; tests can inject success or failure.
pub const PeerAuthorizer = struct {
    context: *anyopaque,
    authorize: *const fn (context: *anyopaque, fd: std.posix.fd_t) anyerror!void,

    pub fn authorizeStream(self: PeerAuthorizer, stream: std.net.Stream) !void {
        try self.authorize(self.context, stream.handle);
    }
};

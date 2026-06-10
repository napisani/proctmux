const std = @import("std");
const protocol = @import("protocol.zig");

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

pub const SnapshotProvider = struct {
    context: *anyopaque,
    snapshot_line: *const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8,

    pub fn snapshotLine(self: SnapshotProvider, allocator: std.mem.Allocator) ![]const u8 {
        return self.snapshot_line(self.context, allocator);
    }
};

pub const PeerAuthorizer = struct {
    context: *anyopaque,
    authorize: *const fn (context: *anyopaque, fd: std.posix.fd_t) anyerror!void,

    pub fn authorizeStream(self: PeerAuthorizer, stream: std.net.Stream) !void {
        try self.authorize(self.context, stream.handle);
    }
};

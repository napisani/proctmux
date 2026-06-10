const std = @import("std");
const line_io = @import("line.zig");
const protocol = @import("protocol.zig");

const max_response_line = 1024 * 1024;
const default_response_timeout_ms = 5000;

pub const Client = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    next_request_id: u64 = 1,
    closed: bool = false,
    pending_snapshot: ?protocol.SnapshotUpdate = null,
    response_timeout_ms: i32 = default_response_timeout_ms,
    read_buffer: std.array_list.Managed(u8),

    pub fn connect(allocator: std.mem.Allocator, socket_path: []const u8) !Client {
        return .{
            .allocator = allocator,
            .stream = try std.net.connectUnixSocket(socket_path),
            .read_buffer = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.pending_snapshot) |*snapshot| snapshot.deinit();
        self.read_buffer.deinit();
        self.close();
    }

    pub fn close(self: *Client) void {
        if (self.closed) return;
        self.closed = true;
        self.stream.close();
    }

    pub fn sendCommand(self: *Client, action: protocol.Command, label: []const u8) !u64 {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        const target: ?[]const u8 = if (label.len == 0) null else label;
        const request = try protocol.commandRequestLine(self.allocator, request_id, action, target);
        defer self.allocator.free(request);
        try self.stream.writeAll(request);

        return request_id;
    }

    pub fn readSnapshot(self: *Client) !protocol.SnapshotUpdate {
        if (self.pending_snapshot) |*snapshot| {
            const pending = snapshot.*;
            self.pending_snapshot = null;
            return pending;
        }

        while (true) {
            const line = try self.readLineBlocking();
            defer self.allocator.free(line);

            var message = try protocol.decodeLine(self.allocator, line);
            switch (message) {
                .snapshot => |snapshot| return snapshot,
                .response => |*response| {
                    response.deinit(self.allocator);
                    continue;
                },
                .command => |request| {
                    protocol.deinitCommandRequest(self.allocator, request);
                    return error.InvalidSnapshot;
                },
            }
        }
    }

    pub fn readLatestSnapshot(self: *Client) !protocol.SnapshotUpdate {
        var latest = try self.readSnapshot();
        errdefer latest.deinit();

        while (try self.readSnapshotIfAvailable()) |next| {
            latest.deinit();
            latest = next;
        }

        return latest;
    }

    pub fn readLatestSnapshotIfAvailable(self: *Client) !?protocol.SnapshotUpdate {
        var latest = (try self.readSnapshotIfAvailable()) orelse return null;
        errdefer latest.deinit();

        while (try self.readSnapshotIfAvailable()) |next| {
            latest.deinit();
            latest = next;
        }

        return latest;
    }

    pub fn readSnapshotIfAvailable(self: *Client) !?protocol.SnapshotUpdate {
        if (self.pending_snapshot) |*snapshot| {
            const pending = snapshot.*;
            self.pending_snapshot = null;
            return pending;
        }

        while (try self.readLineIfAvailable()) |line| {
            defer self.allocator.free(line);

            var message = try protocol.decodeLine(self.allocator, line);
            switch (message) {
                .snapshot => |snapshot| return snapshot,
                .response => |*response| {
                    response.deinit(self.allocator);
                    continue;
                },
                .command => |request| {
                    protocol.deinitCommandRequest(self.allocator, request);
                    return error.InvalidSnapshot;
                },
            }
        }

        return null;
    }

    fn readLineBlocking(self: *Client) ![]const u8 {
        while (true) {
            if (try self.takeBufferedLine()) |line| return line;
            try self.readOneByte();
        }
    }

    fn readLineWithTimeout(self: *Client, timeout_ms: i32) ![]const u8 {
        while (true) {
            if (try self.takeBufferedLine()) |line| return line;
            if (!try self.waitForReadableData(timeout_ms)) return error.CommandTimeout;
            try self.readOneByte();
        }
    }

    fn readLineIfAvailable(self: *Client) !?[]const u8 {
        if (try self.takeBufferedLine()) |line| return line;

        while (try self.streamHasReadableData()) {
            try self.readOneByte();
            if (try self.takeBufferedLine()) |line| return line;
        }

        return null;
    }

    fn takeBufferedLine(self: *Client) !?[]const u8 {
        const newline_index = std.mem.indexOfScalar(u8, self.read_buffer.items, '\n') orelse return null;
        const line_len = newline_index + 1;
        const line = try self.allocator.dupe(u8, self.read_buffer.items[0..line_len]);
        std.mem.copyForwards(u8, self.read_buffer.items, self.read_buffer.items[line_len..]);
        self.read_buffer.items.len -= line_len;
        return line;
    }

    fn readOneByte(self: *Client) !void {
        if (self.read_buffer.items.len >= max_response_line) return error.LineTooLong;

        var byte: [1]u8 = undefined;
        const n = try self.stream.read(&byte);
        if (n == 0) return error.EndOfStream;
        try self.read_buffer.append(byte[0]);
    }

    fn waitForReadableData(self: *Client, timeout_ms: i32) !bool {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = self.stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&poll_fds, timeout_ms);
        return ready != 0 and poll_fds[0].revents != 0;
    }

    fn streamHasReadableData(self: *Client) !bool {
        return self.waitForReadableData(0);
    }

    pub fn readResponseFor(self: *Client, expected_request_id: ?u64) !protocol.Response {
        while (true) {
            const line = try self.readLineWithTimeout(self.response_timeout_ms);
            defer self.allocator.free(line);

            const message = try protocol.decodeLine(self.allocator, line);
            switch (message) {
                .response => |response| {
                    if (expected_request_id) |request_id| {
                        if (response.request_id != request_id) {
                            var stale = response;
                            stale.deinit(self.allocator);
                            continue;
                        }
                    }
                    return response;
                },
                .snapshot => |snapshot| {
                    if (self.pending_snapshot) |*pending| pending.deinit();
                    self.pending_snapshot = snapshot;
                    continue;
                },
                .command => |request| {
                    protocol.deinitCommandRequest(self.allocator, request);
                    return error.InvalidResponse;
                },
            }
        }
    }
};

pub fn readInitialSnapshotFromPath(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
) !protocol.SnapshotUpdate {
    var client = try Client.connect(allocator, socket_path);
    defer client.deinit();
    return client.readSnapshot();
}

pub fn sendCommandToPath(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    request_id: u64,
    action: protocol.Command,
    label: []const u8,
) !protocol.Response {
    return sendCommandToPathWithTimeout(
        allocator,
        socket_path,
        request_id,
        action,
        label,
        default_response_timeout_ms,
    );
}

pub fn sendCommandToPathWithTimeout(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    request_id: u64,
    action: protocol.Command,
    label: []const u8,
    response_timeout_ms: i32,
) !protocol.Response {
    var stream = try std.net.connectUnixSocket(socket_path);
    defer stream.close();

    const target: ?[]const u8 = if (label.len == 0) null else label;
    const request_line = try protocol.commandRequestLine(allocator, request_id, action, target);
    defer allocator.free(request_line);
    try stream.writeAll(request_line);

    while (true) {
        const response_line = try line_io.readTimeout(allocator, stream, max_response_line, response_timeout_ms);
        defer allocator.free(response_line);

        var message = try protocol.decodeLine(allocator, response_line);
        switch (message) {
            .response => |response| return response,
            .snapshot => |*snapshot| {
                snapshot.deinit();
                continue;
            },
            .command => |command_request| {
                protocol.deinitCommandRequest(allocator, command_request);
                return error.InvalidResponse;
            },
        }
    }
}

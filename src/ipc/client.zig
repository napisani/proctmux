const std = @import("std");
const line_io = @import("line.zig");
const protocol = @import("protocol.zig");

const max_response_line = 1024 * 1024;
const default_response_timeout_ms = 5000;

pub const Client = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    next_request_id: u64 = 1,
    request_id_buf: [32]u8 = undefined,
    closed: bool = false,
    pending_state: ?protocol.StateUpdate = null,
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
        if (self.pending_state) |*state| state.deinit();
        self.read_buffer.deinit();
        self.close();
    }

    pub fn close(self: *Client) void {
        if (self.closed) return;
        self.closed = true;
        self.stream.close();
    }

    pub fn hasPendingState(self: *const Client) bool {
        return self.pending_state != null;
    }

    pub fn sendCommand(self: *Client, action: protocol.Command, label: []const u8) ![]const u8 {
        const request_id = try std.fmt.bufPrint(&self.request_id_buf, "{}", .{self.next_request_id});
        self.next_request_id += 1;

        const request = try protocol.commandRequestLine(self.allocator, request_id, action, label);
        defer self.allocator.free(request);
        try self.stream.writeAll(request);

        return request_id;
    }

    pub fn readState(self: *Client) !protocol.StateUpdate {
        if (self.pending_state) |*state| {
            const pending = state.*;
            self.pending_state = null;
            return pending;
        }

        while (true) {
            const line = try self.readLineBlocking();
            defer self.allocator.free(line);

            switch (try line_io.messageKind(self.allocator, line)) {
                .state => return protocol.parseStateLine(self.allocator, line),
                .response => continue,
                .command, .unknown => return error.InvalidState,
            }
        }
    }

    pub fn readLatestState(self: *Client) !protocol.StateUpdate {
        var latest = try self.readState();
        errdefer latest.deinit();

        while (try self.readStateIfAvailable()) |next| {
            latest.deinit();
            latest = next;
        }

        return latest;
    }

    pub fn readLatestStateIfAvailable(self: *Client) !?protocol.StateUpdate {
        var latest = (try self.readStateIfAvailable()) orelse return null;
        errdefer latest.deinit();

        while (try self.readStateIfAvailable()) |next| {
            latest.deinit();
            latest = next;
        }

        return latest;
    }

    pub fn readStateIfAvailable(self: *Client) !?protocol.StateUpdate {
        if (self.pending_state) |*state| {
            const pending = state.*;
            self.pending_state = null;
            return pending;
        }

        while (try self.readLineIfAvailable()) |line| {
            defer self.allocator.free(line);

            switch (try line_io.messageKind(self.allocator, line)) {
                .state => return try protocol.parseStateLine(self.allocator, line),
                .response => continue,
                .command, .unknown => return error.InvalidState,
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

    pub fn readResponse(self: *Client) !protocol.Response {
        return self.readResponseFor(null);
    }

    pub fn readResponseFor(self: *Client, expected_request_id: ?[]const u8) !protocol.Response {
        while (true) {
            const line = try self.readLineWithTimeout(self.response_timeout_ms);
            defer self.allocator.free(line);

            switch (try line_io.messageKind(self.allocator, line)) {
                .response => {
                    const response = try protocol.parseResponseLine(self.allocator, line);
                    if (expected_request_id) |request_id| {
                        if (!std.mem.eql(u8, response.request_id, request_id)) {
                            response.deinit(self.allocator);
                            continue;
                        }
                    }
                    return response;
                },
                .state => {
                    if (self.pending_state) |*state| state.deinit();
                    self.pending_state = try protocol.parseStateLine(self.allocator, line);
                    continue;
                },
                .command, .unknown => return error.InvalidResponse,
            }
        }
    }
};

pub fn sendCommandToPath(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    request_id: []const u8,
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
    request_id: []const u8,
    action: protocol.Command,
    label: []const u8,
    response_timeout_ms: i32,
) !protocol.Response {
    var stream = try std.net.connectUnixSocket(socket_path);
    defer stream.close();

    const request = try protocol.commandRequestLine(allocator, request_id, action, label);
    defer allocator.free(request);
    try stream.writeAll(request);

    while (true) {
        const response_line = try line_io.readTimeout(allocator, stream, max_response_line, response_timeout_ms);
        defer allocator.free(response_line);

        switch (try line_io.messageKind(allocator, response_line)) {
            .response => return protocol.parseResponseLine(allocator, response_line),
            .state => continue,
            .command, .unknown => return error.InvalidResponse,
        }
    }
}

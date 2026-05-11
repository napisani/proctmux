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

    pub fn connect(allocator: std.mem.Allocator, socket_path: []const u8) !Client {
        return .{
            .allocator = allocator,
            .stream = try std.net.connectUnixSocket(socket_path),
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.pending_state) |*state| state.deinit();
        self.close();
    }

    pub fn close(self: *Client) void {
        if (self.closed) return;
        self.closed = true;
        self.stream.close();
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
            const line = try line_io.read(self.allocator, self.stream, max_response_line);
            defer self.allocator.free(line);

            switch (try line_io.messageKind(self.allocator, line)) {
                .state => return protocol.parseStateLine(self.allocator, line),
                .response => continue,
                .command, .unknown => return error.InvalidState,
            }
        }
    }

    pub fn readResponse(self: *Client) !protocol.Response {
        while (true) {
            const line = try line_io.readTimeout(
                self.allocator,
                self.stream,
                max_response_line,
                self.response_timeout_ms,
            );
            defer self.allocator.free(line);

            switch (try line_io.messageKind(self.allocator, line)) {
                .response => return protocol.parseResponseLine(self.allocator, line),
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

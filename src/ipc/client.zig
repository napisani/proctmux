const std = @import("std");
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
            const line = try readLine(self.allocator, self.stream, max_response_line);
            defer self.allocator.free(line);

            switch (try messageKind(self.allocator, line)) {
                .state => return protocol.parseStateLine(self.allocator, line),
                .response => continue,
                .unknown => return error.InvalidState,
            }
        }
    }

    pub fn readResponse(self: *Client) !protocol.Response {
        while (true) {
            const line = try readLineTimeout(
                self.allocator,
                self.stream,
                max_response_line,
                self.response_timeout_ms,
            );
            defer self.allocator.free(line);

            switch (try messageKind(self.allocator, line)) {
                .response => return protocol.parseResponseLine(self.allocator, line),
                .state => {
                    if (self.pending_state) |*state| state.deinit();
                    self.pending_state = try protocol.parseStateLine(self.allocator, line);
                    continue;
                },
                .unknown => return error.InvalidResponse,
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
        const response_line = try readLineTimeout(allocator, stream, max_response_line, response_timeout_ms);
        defer allocator.free(response_line);

        switch (try messageKind(allocator, response_line)) {
            .response => return protocol.parseResponseLine(allocator, response_line),
            .state => continue,
            .unknown => return error.InvalidResponse,
        }
    }
}

const MessageKind = enum {
    response,
    state,
    unknown,
};

fn messageKind(allocator: std.mem.Allocator, line: []const u8) !MessageKind {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return .unknown;
    const type_value = parsed.value.object.get("type") orelse return .unknown;
    if (type_value != .string) return .unknown;

    if (std.mem.eql(u8, type_value.string, "response")) return .response;
    if (std.mem.eql(u8, type_value.string, "state")) return .state;
    return .unknown;
}

fn readLine(allocator: std.mem.Allocator, stream: std.net.Stream, max_len: usize) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    while (out.items.len < max_len) {
        var byte: [1]u8 = undefined;
        const n = try stream.read(&byte);
        if (n == 0) return error.EndOfStream;

        try out.append(byte[0]);
        if (byte[0] == '\n') return out.toOwnedSlice();
    }

    return error.LineTooLong;
}

fn readLineTimeout(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    max_len: usize,
    timeout_ms: i32,
) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    while (out.items.len < max_len) {
        var poll_fds = [_]std.posix.pollfd{
            .{
                .fd = stream.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };
        const ready = try std.posix.poll(&poll_fds, timeout_ms);
        if (ready == 0) return error.CommandTimeout;

        var byte: [1]u8 = undefined;
        const n = try stream.read(&byte);
        if (n == 0) return error.EndOfStream;

        try out.append(byte[0]);
        if (byte[0] == '\n') return out.toOwnedSlice();
    }

    return error.LineTooLong;
}

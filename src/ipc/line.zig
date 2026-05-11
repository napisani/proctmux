const std = @import("std");

pub const MessageKind = enum {
    command,
    response,
    state,
    unknown,
};

pub fn read(allocator: std.mem.Allocator, stream: std.net.Stream, max_len: usize) ![]const u8 {
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

pub fn readTimeout(
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

pub fn messageKind(allocator: std.mem.Allocator, line: []const u8) !MessageKind {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return .unknown;
    const type_value = parsed.value.object.get("type") orelse return .unknown;
    if (type_value != .string) return .unknown;

    if (std.mem.eql(u8, type_value.string, "command")) return .command;
    if (std.mem.eql(u8, type_value.string, "response")) return .response;
    if (std.mem.eql(u8, type_value.string, "state")) return .state;
    return .unknown;
}

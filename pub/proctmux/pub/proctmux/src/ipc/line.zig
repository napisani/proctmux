//! Raw JSON-line socket reading helpers.
//! This module intentionally knows nothing about protocol schemas; it only enforces newline framing, maximum line size, and optional read timeouts.

const std = @import("std");

/// Reads one newline-terminated frame. The returned slice includes the newline
/// because protocol golden tests compare complete wire lines.
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

/// Timeout variant used by command responses and tests so a silent peer does
/// not hang the caller indefinitely.
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

//! Terminal size probing.
//! A small fallback keeps rendering deterministic in tests or non-interactive environments where ioctl dimensions are unavailable.

const std = @import("std");

const default_terminal_width = 100;
const default_terminal_height = 30;

pub const Size = struct {
    width: i32,
    height: i32,
};

pub fn fromFds(output_fd: ?std.posix.fd_t, input_fd: ?std.posix.fd_t) Size {
    if (output_fd) |fd| {
        if (fromFd(fd)) |size| return size;
    }
    if (input_fd) |fd| {
        if (fromFd(fd)) |size| return size;
    }
    return .{
        .width = default_terminal_width,
        .height = default_terminal_height,
    };
}

fn fromFd(fd: std.posix.fd_t) ?Size {
    var size: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };

    const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&size));
    if (std.posix.errno(rc) != .SUCCESS) return null;
    if (size.row == 0 or size.col == 0) return null;
    return .{
        .width = @intCast(size.col),
        .height = @intCast(size.row),
    };
}

//! Raw terminal mode lifecycle.
//! This module owns saving/restoring terminal attributes so Runtime Modes can use raw input without leaking terminal state on exit.

const std = @import("std");

/// Saved terminal mode for restoration after raw input. Holding the original
/// termios value here makes cleanup explicit at Runtime Mode boundaries.
pub const Mode = struct {
    fd: std.posix.fd_t,
    original: ?std.posix.termios = null,

    pub fn enterIfNeeded(should_enter: bool, fd: std.posix.fd_t) Mode {
        if (!should_enter) return .{ .fd = fd };
        if (!std.posix.isatty(fd)) return .{ .fd = fd };

        const original = std.posix.tcgetattr(fd) catch return .{ .fd = fd };
        var raw = original;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 0;

        std.posix.tcsetattr(fd, .FLUSH, raw) catch return .{ .fd = fd };
        return .{ .fd = fd, .original = original };
    }

    pub fn restore(self: *Mode) void {
        const original = self.original orelse return;
        std.posix.tcsetattr(self.fd, .FLUSH, original) catch {};
        self.original = null;
    }
};

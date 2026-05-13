//! proctmux libghostty-vt PTY shim.

pub const Pty = struct {
    pub fn open(opts: anytype) !Pty {
        _ = opts;
        return error.Unsupported;
    }

    pub fn close(self: *Pty) void {
        _ = self;
    }
};

//! Test-support namespace.
//! Tests import this root when they need shared config, IPC, IO, or ANSI helpers.

pub const config = @import("config.zig");
pub const ipc = @import("ipc.zig");
pub const io = @import("io.zig");

test {
    _ = config;
    _ = ipc;
    _ = io;
}

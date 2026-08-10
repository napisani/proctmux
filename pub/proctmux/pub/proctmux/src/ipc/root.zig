//! IPC namespace.
//! Runtime modules import this root to access protocol, socket, client, server, and testable IPC interfaces through one stable seam.

pub const protocol = @import("protocol.zig");
pub const interfaces = @import("interfaces.zig");
pub const line = @import("line.zig");
pub const socket = @import("socket.zig");
pub const client = @import("client.zig");
pub const server = @import("server.zig");
pub const snapshot_broadcaster = @import("snapshot_broadcaster.zig");

test {
    _ = protocol;
    _ = interfaces;
    _ = line;
    _ = socket;
    _ = client;
    _ = server;
    _ = snapshot_broadcaster;
    _ = @import("tests.zig");
}

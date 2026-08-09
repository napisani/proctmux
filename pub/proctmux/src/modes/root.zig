//! Runtime modes namespace.
//! Importers use this root to avoid depending on individual mode file layout.

pub const client = @import("client.zig");
pub const io = @import("io.zig");
pub const primary = @import("primary.zig");
pub const signal = @import("signal.zig");

test {
    _ = client;
    _ = io;
    _ = primary;
    _ = signal;
}

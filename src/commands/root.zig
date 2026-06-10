//! Commands namespace for non-interactive subcommands.
//! Keeping command modules behind this small import surface lets app routing stay independent of individual command implementations.

pub const config_init = @import("config_init.zig");
pub const signal = @import("signal.zig");

test {
    _ = config_init;
    _ = signal;
}

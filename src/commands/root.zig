pub const config_init = @import("config_init.zig");
pub const signal = @import("signal.zig");

test {
    _ = config_init;
    _ = signal;
}

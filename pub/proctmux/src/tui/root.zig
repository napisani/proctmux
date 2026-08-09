//! TUI namespace.
//! Runtime modes import this root to access the client model, session, key input, renderer, and split layout model.

pub const client_model = @import("client_model.zig");
pub const client_session = @import("client_session.zig");
pub const key_input = @import("key_input.zig");
pub const render = @import("render.zig");
pub const split_model = @import("split_model.zig");

test {
    _ = client_model;
    _ = client_session;
    _ = key_input;
    _ = render;
    _ = split_model;
}

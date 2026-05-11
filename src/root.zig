const std = @import("std");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub const version = @import("version.zig");
pub const config = @import("config/root.zig");
pub const domain = @import("domain/root.zig");
pub const discover = @import("discover/root.zig");
pub const ipc = @import("ipc/root.zig");
pub const cli = @import("cli/root.zig");
pub const modes = @import("modes/root.zig");
pub const proc = @import("proc/root.zig");
pub const ring = @import("ring/root.zig");
pub const viewer = @import("viewer/root.zig");
pub const terminal = @import("terminal/root.zig");
pub const tui = @import("tui/root.zig");
pub const commands = @import("commands/root.zig");
pub const app = @import("app/root.zig");
pub const redact = @import("redact/root.zig");
pub const primary = @import("primary/root.zig");
pub const unified = @import("unified/root.zig");

test {
    _ = version;
    _ = config;
    _ = domain;
    _ = discover;
    _ = ipc;
    _ = cli;
    _ = modes;
    _ = proc;
    _ = ring;
    _ = viewer;
    _ = terminal;
    _ = tui;
    _ = commands;
    _ = app;
    _ = redact;
    _ = primary;
    _ = unified;
}

test "vendored yaml dependency is available" {
    const yaml = @import("yaml");
    _ = yaml.Yaml;
}

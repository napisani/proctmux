//! Signal Runtime Mode adapter.
//! This mode loads Project Config, locates the Primary Server socket, and delegates command behavior to the signal command module.

const std = @import("std");
const commands = @import("../commands/root.zig");
const config = @import("../config/root.zig");
const io = @import("io.zig");

pub fn run(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    config_file: []const u8,
    subcommand: []const u8,
    args: []const []const u8,
    output: io.Output,
) !void {
    var loaded = try config.runtime.loadInDir(allocator, dir, config_file);
    defer loaded.deinit();

    try commands.signal.runWithConfig(
        allocator,
        &loaded.config,
        subcommand,
        args,
        .{ .context = output.context, .write = output.write },
    );
}

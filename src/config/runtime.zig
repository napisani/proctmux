const std = @import("std");
const discover = @import("../discover/root.zig");
const load = @import("load.zig");

pub const LoadedRuntimeConfig = load.LoadedConfig;

pub fn loadInDir(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    config_file: []const u8,
) !LoadedRuntimeConfig {
    var loaded = if (config_file.len > 0)
        try load.loadFileInDir(allocator, dir, config_file)
    else
        try load.loadDefaultInDir(allocator, dir);
    errdefer loaded.deinit();

    const discovery_cwd = std.fs.path.dirname(loaded.config.file_path) orelse ".";
    try discover.apply_mod.apply(loaded.config.allocator, &loaded.config, discovery_cwd);
    return loaded;
}

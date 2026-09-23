//! Runtime config pipeline.
//! File-backed configs opt into individual sources; configless mode applies all built-ins.

const std = @import("std");
const platform = @import("../platform.zig");
const discover = @import("../discover/root.zig");
const load = @import("load.zig");

pub const LoadedRuntimeConfig = load.LoadedConfig;

/// Loads Project Config before any Runtime Mode starts. A file-backed config
/// applies only its enabled discovery sources; an implicit config applies all.
pub fn loadInDir(
    allocator: std.mem.Allocator,
    dir: platform.fs.Dir,
    config_file: []const u8,
) !LoadedRuntimeConfig {
    var implicit = false;
    var loaded = if (config_file.len > 0)
        try load.loadFileInDir(allocator, dir, config_file)
    else blk: {
        break :blk load.loadDefaultInDir(allocator, dir) catch |err| switch (err) {
            error.ConfigFileNotFound => blk2: {
                implicit = true;
                break :blk2 try load.loadImplicitInDir(allocator, dir);
            },
            else => return err,
        };
    };
    errdefer loaded.deinit();

    const discovery_cwd = platform.fs.path.dirname(loaded.config.file_path) orelse ".";
    if (implicit) {
        try discover.apply_mod.applyAll(
            loaded.config.allocator,
            &loaded.config,
            discovery_cwd,
            &discover.builtin_sources,
        );
    } else {
        try discover.apply_mod.applyEnabled(
            loaded.config.allocator,
            &loaded.config,
            discovery_cwd,
            &discover.builtin_sources,
        );
    }
    return loaded;
}

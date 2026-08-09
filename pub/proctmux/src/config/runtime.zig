//! Runtime config pipeline.
//! Loading from disk and applying Discovery are kept together so every Runtime Mode starts from the same Project Config semantics.

const std = @import("std");
const discover = @import("../discover/root.zig");
const load = @import("load.zig");

pub const LoadedRuntimeConfig = load.LoadedConfig;

/// Loads Project Config and applies Discovery before any Runtime Mode starts.
/// This keeps primary/client/unified modes aligned on effective config.
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

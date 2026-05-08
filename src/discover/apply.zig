const std = @import("std");
const config = @import("../config/root.zig");
const makefile = @import("makefile.zig");
const package_json = @import("package_json.zig");

pub fn apply(allocator: std.mem.Allocator, cfg: *config.schema.Config, cwd: []const u8) !void {
    if (cfg.general.procs_from_make_targets) {
        var discovered = makefile.discover(allocator, cwd) catch |err| switch (err) {
            error.SourceNotFound => null,
            else => return err,
        };
        if (discovered) |*map| {
            defer makefile.deinitProcessMap(allocator, map);
            try merge(allocator, cfg, map);
        }
    }

    if (cfg.general.procs_from_package_json) {
        var discovered = package_json.discover(allocator, cwd) catch |err| switch (err) {
            error.SourceNotFound => null,
            else => return err,
        };
        if (discovered) |*map| {
            defer makefile.deinitProcessMap(allocator, map);
            try merge(allocator, cfg, map);
        }
    }
}

fn merge(allocator: std.mem.Allocator, cfg: *config.schema.Config, discovered: *config.schema.ProcessMap) !void {
    var it = discovered.iterator();
    while (it.next()) |entry| {
        if (cfg.procs.contains(entry.key_ptr.*)) continue;
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        var value = try cloneProcessConfig(allocator, entry.value_ptr.*);
        errdefer value.deinit(allocator);
        try cfg.procs.put(key, value);
    }
}

fn cloneProcessConfig(allocator: std.mem.Allocator, source: config.schema.ProcessConfig) !config.schema.ProcessConfig {
    var out = config.schema.ProcessConfig.empty(allocator);
    errdefer out.deinit(allocator);
    out.owns_scalar_strings = true;

    if (source.shell.len > 0) out.shell = try allocator.dupe(u8, source.shell);
    if (source.cwd.len > 0) out.cwd = try allocator.dupe(u8, source.cwd);
    if (source.description.len > 0) out.description = try allocator.dupe(u8, source.description);
    if (source.docs.len > 0) out.docs = try allocator.dupe(u8, source.docs);
    out.stop = source.stop;
    out.stop_timeout_ms = source.stop_timeout_ms;
    out.autostart = source.autostart;
    out.autofocus = source.autofocus;
    out.terminal_rows = source.terminal_rows;
    out.terminal_cols = source.terminal_cols;

    for (source.cmd.items) |item| try config.schema.appendOwned(allocator, &out.cmd, item);
    for (source.meta_tags.items) |item| try config.schema.appendOwned(allocator, &out.meta_tags, item);
    for (source.categories.items) |item| try config.schema.appendOwned(allocator, &out.categories, item);
    for (source.add_path.items) |item| try config.schema.appendOwned(allocator, &out.add_path, item);
    for (source.on_kill.items) |item| try config.schema.appendOwned(allocator, &out.on_kill, item);

    var env_it = source.env.iterator();
    while (env_it.next()) |entry| {
        try config.schema.putOwnedString(allocator, &out.env, entry.key_ptr.*, entry.value_ptr.*);
    }

    return out;
}

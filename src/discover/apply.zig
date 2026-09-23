//! Extensible discovery coordinator for Project Config augmentation.
//! Sources return owned process maps; this module owns source ordering, merge
//! precedence, cleanup, and best-effort startup error handling.

const std = @import("std");
const config = @import("../config/root.zig");
const source = @import("source.zig");

pub fn applyAll(
    allocator: std.mem.Allocator,
    cfg: *config.schema.Config,
    cwd: []const u8,
    sources: []const source.Source,
) !void {
    return applySources(allocator, cfg, cwd, sources, false);
}

pub fn applyEnabled(
    allocator: std.mem.Allocator,
    cfg: *config.schema.Config,
    cwd: []const u8,
    sources: []const source.Source,
) !void {
    return applySources(allocator, cfg, cwd, sources, true);
}

fn applySources(
    allocator: std.mem.Allocator,
    cfg: *config.schema.Config,
    cwd: []const u8,
    sources: []const source.Source,
    enabled_only: bool,
) !void {
    for (sources) |item| {
        if (enabled_only and !item.enabled(&cfg.general)) continue;

        var discovered = item.discover(allocator, cwd) catch |err| switch (err) {
            error.SourceNotFound => continue,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.warn("discovery source '{s}' skipped: {s}", .{ item.name, @errorName(err) });
                continue;
            },
        };
        defer deinitProcessMap(allocator, &discovered);
        try merge(allocator, cfg, &discovered);
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

fn cloneProcessConfig(allocator: std.mem.Allocator, source_config: config.schema.ProcessConfig) !config.schema.ProcessConfig {
    var out = config.schema.ProcessConfig.empty(allocator);
    errdefer out.deinit(allocator);
    out.owns_scalar_strings = true;

    if (source_config.shell.len > 0) out.shell = try allocator.dupe(u8, source_config.shell);
    if (source_config.cwd.len > 0) out.cwd = try allocator.dupe(u8, source_config.cwd);
    if (source_config.description.len > 0) out.description = try allocator.dupe(u8, source_config.description);
    if (source_config.docs.len > 0) out.docs = try allocator.dupe(u8, source_config.docs);
    out.stop = source_config.stop;
    out.stop_timeout_ms = source_config.stop_timeout_ms;
    out.autostart = source_config.autostart;
    out.autofocus = source_config.autofocus;
    out.terminal_rows = source_config.terminal_rows;
    out.terminal_cols = source_config.terminal_cols;

    for (source_config.cmd.items) |item| try config.schema.appendOwned(allocator, &out.cmd, item);
    for (source_config.meta_tags.items) |item| try config.schema.appendOwned(allocator, &out.meta_tags, item);
    for (source_config.categories.items) |item| try config.schema.appendOwned(allocator, &out.categories, item);
    for (source_config.add_path.items) |item| try config.schema.appendOwned(allocator, &out.add_path, item);
    for (source_config.on_kill.items) |item| try config.schema.appendOwned(allocator, &out.on_kill, item);

    var env_it = source_config.env.iterator();
    while (env_it.next()) |entry| {
        try config.schema.putOwnedString(allocator, &out.env, entry.key_ptr.*, entry.value_ptr.*);
    }

    return out;
}

fn deinitProcessMap(allocator: std.mem.Allocator, procs: *config.schema.ProcessMap) void {
    var it = procs.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    procs.deinit();
}

const std = @import("std");
const config = @import("../config/root.zig");
const makefile = @import("makefile.zig");

const Manager = struct {
    prefix: []const u8,
    category: []const u8,
};

pub fn discover(allocator: std.mem.Allocator, cwd: []const u8) !config.schema.ProcessMap {
    const path = try std.fs.path.join(allocator, &.{ cwd, "package.json" });
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.SourceNotFound,
        else => return err,
    };
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    var procs = config.schema.ProcessMap.init(allocator);
    errdefer makefile.deinitProcessMap(allocator, &procs);

    const scripts = parsed.value.object.get("scripts") orelse return procs;
    if (scripts != .object) return procs;

    const manager = try detectManager(allocator, cwd);
    var it = scripts.object.iterator();
    while (it.next()) |entry| {
        const script = entry.key_ptr.*;
        if (!validScriptName(script)) continue;
        if (entry.value_ptr.* != .string) continue;
        const body = entry.value_ptr.string;

        const proc_name = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ manager.prefix, script });
        errdefer allocator.free(proc_name);
        if (procs.contains(proc_name)) {
            allocator.free(proc_name);
            continue;
        }

        var proc = config.schema.ProcessConfig.empty(allocator);
        proc.owns_scalar_strings = true;
        try buildCommand(allocator, &proc.cmd, manager.prefix, script);
        proc.cwd = try allocator.dupe(u8, cwd);
        proc.description = try description(allocator, manager.prefix, body);
        try config.schema.appendOwned(allocator, &proc.categories, manager.category);
        try procs.put(proc_name, proc);
    }

    return procs;
}

pub fn commandPreview(allocator: std.mem.Allocator, prefix: []const u8, script: []const u8) ![]const u8 {
    if (std.mem.eql(u8, prefix, "yarn")) return std.fmt.allocPrint(allocator, "yarn {s}", .{script});
    if (std.mem.eql(u8, prefix, "deno")) return std.fmt.allocPrint(allocator, "deno task {s}", .{script});
    return std.fmt.allocPrint(allocator, "{s} run {s}", .{ prefix, script });
}

fn buildCommand(allocator: std.mem.Allocator, out: *config.schema.StringList, prefix: []const u8, script: []const u8) !void {
    if (std.mem.eql(u8, prefix, "yarn")) {
        try config.schema.appendOwned(allocator, out, "yarn");
        try config.schema.appendOwned(allocator, out, script);
        return;
    }
    if (std.mem.eql(u8, prefix, "deno")) {
        try config.schema.appendOwned(allocator, out, "deno");
        try config.schema.appendOwned(allocator, out, "task");
        try config.schema.appendOwned(allocator, out, script);
        return;
    }
    try config.schema.appendOwned(allocator, out, prefix);
    try config.schema.appendOwned(allocator, out, "run");
    try config.schema.appendOwned(allocator, out, script);
}

fn detectManager(allocator: std.mem.Allocator, cwd: []const u8) !Manager {
    const checks = [_]struct { files: []const []const u8, prefix: []const u8 }{
        .{ .files = &.{ "pnpm-lock.yaml", ".pnpmfile.cjs", "pnpm-workspace.yaml" }, .prefix = "pnpm" },
        .{ .files = &.{ "bun.lockb", "bunfig.toml" }, .prefix = "bun" },
        .{ .files = &.{ "yarn.lock", ".yarnrc", ".yarnrc.yml", ".yarnrc.yaml" }, .prefix = "yarn" },
        .{ .files = &.{ "package-lock.json", "npm-shrinkwrap.json" }, .prefix = "npm" },
        .{ .files = &.{ "deno.json", "deno.jsonc" }, .prefix = "deno" },
    };

    for (checks) |check| {
        for (check.files) |file| {
            if (try exists(allocator, cwd, file)) {
                return .{ .prefix = check.prefix, .category = check.prefix };
            }
        }
    }
    return .{ .prefix = "npm", .category = "npm" };
}

fn exists(allocator: std.mem.Allocator, cwd: []const u8, name: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ cwd, name });
    defer allocator.free(path);
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn description(allocator: std.mem.Allocator, prefix: []const u8, body: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return std.fmt.allocPrint(allocator, "Auto-discovered {s} script", .{prefix});
    return std.fmt.allocPrint(allocator, "Auto-discovered {s} script: {s}", .{ prefix, body });
}

fn validScriptName(script: []const u8) bool {
    if (script.len == 0) return false;
    for (script) |c| {
        const valid = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == ':' or c == '_' or c == '-';
        if (!valid) return false;
    }
    return true;
}

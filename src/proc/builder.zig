const std = @import("std");
const config = @import("../config/root.zig");

const default_shell_cmd = [_][]const u8{ "sh", "-c" };

pub const CommandSpec = struct {
    argv: []const []const u8,

    pub fn deinit(self: CommandSpec, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
    }
};

pub fn buildCommand(
    allocator: std.mem.Allocator,
    proc_cfg: *const config.schema.ProcessConfig,
    global_config: ?*const config.schema.Config,
) !?CommandSpec {
    if (proc_cfg.shell.len > 0) {
        const shell_cmd = if (global_config) |cfg|
            if (cfg.shell_cmd.items.len > 0) cfg.shell_cmd.items else default_shell_cmd[0..]
        else
            default_shell_cmd[0..];

        var argv = std.array_list.Managed([]const u8).init(allocator);
        errdefer deinitArgv(allocator, &argv);
        for (shell_cmd) |part| try argv.append(try allocator.dupe(u8, part));
        try argv.append(try allocator.dupe(u8, proc_cfg.shell));
        return .{ .argv = try argv.toOwnedSlice() };
    }

    if (proc_cfg.cmd.items.len == 0) return null;

    var argv = std.array_list.Managed([]const u8).init(allocator);
    errdefer deinitArgv(allocator, &argv);
    for (proc_cfg.cmd.items) |part| try argv.append(try allocator.dupe(u8, part));
    return .{ .argv = try argv.toOwnedSlice() };
}

pub fn buildEnvironmentFromBase(
    allocator: std.mem.Allocator,
    base_env: []const []const u8,
    fallback_path: []const u8,
    proc_cfg: *const config.schema.ProcessConfig,
) ![]const []const u8 {
    var env = std.array_list.Managed([]const u8).init(allocator);
    errdefer deinitEnvironment(allocator, env.items);

    for (base_env) |entry| {
        if (proc_cfg.add_path.items.len > 0 and std.mem.startsWith(u8, entry, "PATH=")) continue;
        try env.append(try allocator.dupe(u8, entry));
    }

    if (proc_cfg.add_path.items.len > 0) {
        var path = std.array_list.Managed(u8).init(allocator);
        defer path.deinit();
        try path.appendSlice(findPath(base_env) orelse fallback_path);
        for (proc_cfg.add_path.items) |part| {
            try path.append(':');
            try path.appendSlice(part);
        }
        const path_entry = try std.fmt.allocPrint(allocator, "PATH={s}", .{path.items});
        try env.append(path_entry);
    }

    var it = proc_cfg.env.iterator();
    while (it.next()) |entry| {
        const env_entry = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        try env.append(env_entry);
    }

    return env.toOwnedSlice();
}

pub fn deinitEnvironment(allocator: std.mem.Allocator, env: []const []const u8) void {
    for (env) |entry| allocator.free(entry);
    allocator.free(env);
}

fn deinitArgv(allocator: std.mem.Allocator, argv: *std.array_list.Managed([]const u8)) void {
    for (argv.items) |arg| allocator.free(arg);
    argv.deinit();
}

fn findPath(base_env: []const []const u8) ?[]const u8 {
    for (base_env) |entry| {
        if (std.mem.startsWith(u8, entry, "PATH=")) return entry["PATH=".len..];
    }
    return null;
}

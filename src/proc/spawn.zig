const std = @import("std");
const config = @import("../config/root.zig");
const builder = @import("builder.zig");
const instance_mod = @import("instance.zig");
const pty = @import("pty.zig");

const default_terminal_rows = 24;
const default_terminal_cols = 80;

pub const Started = struct {
    handle: instance_mod.ProcessHandle,
    owned: bool = true,

    pub fn deinit(self: *Started) void {
        if (!self.owned) return;
        self.handle.killForStartupCleanup();
        self.handle.deinit();
        self.owned = false;
    }

    pub fn disarm(self: *Started) void {
        self.owned = false;
    }
};

pub fn start(
    allocator: std.mem.Allocator,
    proc_cfg: *const config.schema.ProcessConfig,
    command_spec: builder.CommandSpec,
    env_map: *std.process.EnvMap,
) !Started {
    return if (shouldUsePipeProcess())
        try startPipe(allocator, proc_cfg, command_spec, env_map)
    else
        try startPty(allocator, proc_cfg, command_spec, env_map);
}

pub fn waitForExit(instance: *instance_mod.Instance) void {
    const status = instance.handle.wait() catch {
        instance.markExited(1);
        return;
    };
    instance.markExited(status);
}

fn startPty(
    allocator: std.mem.Allocator,
    proc_cfg: *const config.schema.ProcessConfig,
    command_spec: builder.CommandSpec,
    env_map: *const std.process.EnvMap,
) !Started {
    const spawned = try pty.spawn(
        allocator,
        command_spec.argv,
        env_map,
        proc_cfg.cwd,
        resolveTerminalRows(proc_cfg),
        resolveTerminalCols(proc_cfg),
    );
    errdefer spawned.master.close();
    try pty.configureRawMode(spawned.master);

    return .{
        .handle = .{ .pty = .{
            .pid = spawned.pid,
            .master = spawned.master,
        } },
    };
}

fn startPipe(
    allocator: std.mem.Allocator,
    proc_cfg: *const config.schema.ProcessConfig,
    command_spec: builder.CommandSpec,
    env_map: *std.process.EnvMap,
) !Started {
    var child = std.process.Child.init(command_spec.argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.pgid = 0;
    if (proc_cfg.cwd.len > 0) child.cwd = proc_cfg.cwd;
    child.env_map = env_map;
    try child.spawn();
    errdefer _ = child.kill() catch null;

    const stdin = child.stdin.?;
    child.stdin = null;
    const stdout = child.stdout.?;
    child.stdout = null;

    return .{
        .handle = .{ .pipe = .{
            .pid = @intCast(child.id),
            .child = child,
            .stdin = stdin,
            .stdout = stdout,
        } },
    };
}

fn shouldUsePipeProcess() bool {
    return std.process.hasEnvVarConstant("PROCTMUX_EMBEDDED_PRIMARY");
}

fn resolveTerminalRows(proc_cfg: *const config.schema.ProcessConfig) u16 {
    if (proc_cfg.terminal_rows > 0) return @intCast(proc_cfg.terminal_rows);
    return default_terminal_rows;
}

fn resolveTerminalCols(proc_cfg: *const config.schema.ProcessConfig) u16 {
    if (proc_cfg.terminal_cols > 0) return @intCast(proc_cfg.terminal_cols);
    return default_terminal_cols;
}

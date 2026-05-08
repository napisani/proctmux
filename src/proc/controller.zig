const std = @import("std");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");
const ring = @import("../ring/root.zig");
const builder = @import("builder.zig");
const pty = @import("pty.zig");

const default_scrollback_capacity = 1024 * 1024;
const default_stop_timeout_ms = 3000;
const default_on_kill_timeout_ms = 30_000;
const default_terminal_rows = 24;
const default_terminal_cols = 80;

pub const Instance = struct {
    allocator: std.mem.Allocator,
    id: u32,
    pid: std.posix.pid_t,
    config: *const config.schema.ProcessConfig,
    command_spec: builder.CommandSpec,
    child: ?std.process.Child = null,
    pty_file: ?std.fs.File,
    output_file: ?std.fs.File,
    scrollback: ring.RingBuffer,
    output_thread: ?std.Thread = null,
    wait_thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},
    running: bool = true,
    term_status: ?u32 = null,

    fn deinit(self: *Instance) void {
        if (self.output_thread) |thread| thread.join();
        if (self.wait_thread) |thread| thread.join();
        if (self.output_file) |file| file.close();
        if (self.pty_file) |file| file.close();
        self.scrollback.deinit();
        self.command_spec.deinit(self.allocator);
    }

    pub fn isRunning(self: *Instance) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.running;
    }

    pub fn sendBytes(self: *Instance, bytes: []const u8) !void {
        const file = self.pty_file orelse return error.ProcessNotRunning;
        try file.writeAll(bytes);
    }

    fn markExited(self: *Instance, term_status: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.running = false;
        self.term_status = term_status;
    }
};

pub const Controller = struct {
    allocator: std.mem.Allocator,
    global_config: ?*const config.schema.Config,
    processes: std.AutoHashMap(u32, *Instance),
    mutex: std.Thread.Mutex = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        global_config: ?*const config.schema.Config,
    ) Controller {
        return .{
            .allocator = allocator,
            .global_config = global_config,
            .processes = std.AutoHashMap(u32, *Instance).init(allocator),
        };
    }

    pub fn deinit(self: *Controller) void {
        while (true) {
            self.mutex.lock();
            var it = self.processes.keyIterator();
            const maybe_id = if (it.next()) |key| key.* else null;
            self.mutex.unlock();

            const id = maybe_id orelse break;
            const instance = self.getInstance(id) orelse continue;
            if (instance.isRunning()) {
                self.stopProcess(id) catch {};
            } else {
                self.cleanupProcess(id) catch {};
            }
        }
        self.processes.deinit();
    }

    pub fn startProcess(
        self: *Controller,
        id: u32,
        proc_cfg: *const config.schema.ProcessConfig,
    ) !*Instance {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.processes.contains(id)) return error.ProcessAlreadyExists;

        const command_spec = (try builder.buildCommand(self.allocator, proc_cfg, self.global_config)) orelse {
            return error.InvalidProcessConfig;
        };
        errdefer command_spec.deinit(self.allocator);

        var env_map = try buildEnvironmentMap(self.allocator, proc_cfg);
        defer env_map.deinit();
        var instance = try self.allocator.create(Instance);
        errdefer self.allocator.destroy(instance);
        instance.* = if (shouldUsePipeProcess())
            try startPipeInstance(self.allocator, id, proc_cfg, command_spec, &env_map)
        else
            try startPtyInstance(self.allocator, id, proc_cfg, command_spec, &env_map);
        errdefer instance.deinit();

        instance.output_thread = try std.Thread.spawn(.{}, captureOutput, .{instance});
        instance.wait_thread = try std.Thread.spawn(.{}, waitForProcessExit, .{instance});

        try self.processes.put(id, instance);
        return instance;
    }

    pub fn stopProcess(self: *Controller, id: u32) !void {
        const instance = self.getInstance(id) orelse return error.ProcessNotFound;

        if (instance.isRunning()) {
            const stop_signal = resolveStopSignal(instance.config);
            std.posix.kill(instance.pid, stop_signal) catch {};
            if (!waitUntilStopped(instance, resolveStopTimeoutMs(instance.config))) {
                std.posix.kill(instance.pid, std.posix.SIG.KILL) catch {};
                _ = waitUntilStopped(instance, 2000);
            }
        }

        try self.releaseProcess(id, instance, true);
    }

    pub fn cleanupProcess(self: *Controller, id: u32) !void {
        const instance = self.getInstance(id) orelse return;
        if (instance.isRunning()) return error.ProcessStillRunning;

        try self.releaseProcess(id, instance, false);
    }

    fn releaseProcess(
        self: *Controller,
        id: u32,
        instance: *Instance,
        run_on_kill: bool,
    ) !void {
        if (instance.wait_thread) |thread| {
            thread.join();
            instance.wait_thread = null;
        }
        if (instance.output_thread) |thread| {
            thread.join();
            instance.output_thread = null;
        }

        self.mutex.lock();
        _ = self.processes.remove(id);
        self.mutex.unlock();

        const on_kill_result = if (run_on_kill)
            executeOnKillCommand(self.allocator, instance.config)
        else {};
        instance.deinit();
        self.allocator.destroy(instance);

        try on_kill_result;
    }

    pub fn isRunning(self: *Controller, id: u32) bool {
        const instance = self.getInstance(id) orelse return false;
        return instance.isRunning();
    }

    pub fn getProcessStatus(self: *Controller, id: u32) domain.process.ProcessStatus {
        return if (self.isRunning(id)) .running else .halted;
    }

    pub fn processController(self: *Controller) domain.process.ProcessController {
        return .{
            .context = self,
            .get_process_status = adapterGetProcessStatus,
            .get_pid = adapterGetPID,
        };
    }

    pub fn getPID(self: *Controller, id: u32) i32 {
        const instance = self.getInstance(id) orelse return -1;
        if (!instance.isRunning()) return -1;
        return @intCast(instance.pid);
    }

    pub fn getAllProcessIDs(self: *Controller, allocator: std.mem.Allocator) ![]u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var ids = try allocator.alloc(u32, self.processes.count());
        var it = self.processes.keyIterator();
        var index: usize = 0;
        while (it.next()) |key| : (index += 1) ids[index] = key.*;
        std.mem.sort(u32, ids, {}, lessThanU32);
        return ids;
    }

    pub fn getScrollback(self: *Controller, allocator: std.mem.Allocator, id: u32) ![]u8 {
        const instance = self.getInstance(id) orelse return error.ProcessNotFound;
        return instance.scrollback.bytes(allocator);
    }

    pub fn sendBytes(self: *Controller, id: u32, bytes: []const u8) !void {
        const instance = self.getInstance(id) orelse return error.ProcessNotFound;
        if (!instance.isRunning()) return error.ProcessNotRunning;
        try instance.sendBytes(bytes);
    }

    fn getInstance(self: *Controller, id: u32) ?*Instance {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.processes.get(id);
    }
};

fn lessThanU32(_: void, a: u32, b: u32) bool {
    return a < b;
}

fn adapterGetProcessStatus(context: *anyopaque, id: u32) domain.process.ProcessStatus {
    const self: *Controller = @ptrCast(@alignCast(context));
    return self.getProcessStatus(id);
}

fn adapterGetPID(context: *anyopaque, id: u32) i32 {
    const self: *Controller = @ptrCast(@alignCast(context));
    return self.getPID(id);
}

fn captureOutput(instance: *Instance) void {
    const has_output_file = instance.output_file != null;
    const file = instance.output_file orelse (instance.pty_file orelse return);
    defer if (has_output_file) {
        file.close();
        instance.output_file = null;
    };

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch return;
        if (n == 0) return;
        _ = instance.scrollback.write(buf[0..n]);
    }
}

fn waitForProcessExit(instance: *Instance) void {
    if (instance.child) |*child| {
        const term = child.wait() catch {
            instance.markExited(1);
            return;
        };
        instance.markExited(termStatus(term));
        return;
    }

    const result = std.posix.waitpid(instance.pid, 0);
    instance.markExited(result.status);
}

fn startPtyInstance(
    allocator: std.mem.Allocator,
    id: u32,
    proc_cfg: *const config.schema.ProcessConfig,
    command_spec: builder.CommandSpec,
    env_map: *const std.process.EnvMap,
) !Instance {
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
        .allocator = allocator,
        .id = id,
        .pid = spawned.pid,
        .config = proc_cfg,
        .command_spec = command_spec,
        .pty_file = spawned.master,
        .output_file = null,
        .scrollback = try ring.RingBuffer.init(allocator, default_scrollback_capacity),
    };
}

fn startPipeInstance(
    allocator: std.mem.Allocator,
    id: u32,
    proc_cfg: *const config.schema.ProcessConfig,
    command_spec: builder.CommandSpec,
    env_map: *std.process.EnvMap,
) !Instance {
    var child = std.process.Child.init(command_spec.argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    if (proc_cfg.cwd.len > 0) child.cwd = proc_cfg.cwd;
    child.env_map = env_map;
    try child.spawn();
    errdefer _ = child.kill() catch null;

    const stdin = child.stdin.?;
    child.stdin = null;
    const stdout = child.stdout.?;
    child.stdout = null;

    return .{
        .allocator = allocator,
        .id = id,
        .pid = @intCast(child.id),
        .config = proc_cfg,
        .command_spec = command_spec,
        .child = child,
        .pty_file = stdin,
        .output_file = stdout,
        .scrollback = try ring.RingBuffer.init(allocator, default_scrollback_capacity),
    };
}

fn shouldUsePipeProcess() bool {
    return std.process.hasEnvVarConstant("PROCTMUX_EMBEDDED_PRIMARY");
}

fn termStatus(term: std.process.Child.Term) u32 {
    return switch (term) {
        .Exited => |code| code,
        .Signal => |signal| 128 + signal,
        .Stopped => |signal| signal,
        .Unknown => |status| status,
    };
}

fn executeOnKillCommand(
    allocator: std.mem.Allocator,
    proc_cfg: *const config.schema.ProcessConfig,
) !void {
    return executeOnKillCommandWithTimeoutMs(allocator, proc_cfg, default_on_kill_timeout_ms);
}

fn executeOnKillCommandWithTimeoutMs(
    allocator: std.mem.Allocator,
    proc_cfg: *const config.schema.ProcessConfig,
    timeout_ms: u64,
) !void {
    if (proc_cfg.on_kill.items.len == 0) return;

    var env_map = try buildEnvironmentMap(allocator, proc_cfg);
    defer env_map.deinit();

    var child = std.process.Child.init(proc_cfg.on_kill.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    if (proc_cfg.cwd.len > 0) child.cwd = proc_cfg.cwd;
    child.env_map = &env_map;

    try child.spawn();
    const child_pid = child.id;

    var wait_state = OnKillWaitState{ .child = &child };
    const wait_thread = try std.Thread.spawn(.{}, waitOnKillChild, .{&wait_state});
    if (!waitForOnKillChild(&wait_state.done, timeout_ms)) {
        std.posix.kill(child_pid, std.posix.SIG.KILL) catch {};
        wait_thread.join();
        return error.OnKillFailed;
    }
    wait_thread.join();

    if (wait_state.err != null) return error.OnKillFailed;
    const term = wait_state.term orelse return error.OnKillFailed;
    switch (term) {
        .Exited => |code| if (code != 0) return error.OnKillFailed,
        else => return error.OnKillFailed,
    }
}

const OnKillWaitState = struct {
    child: *std.process.Child,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    term: ?std.process.Child.Term = null,
    err: ?anyerror = null,
};

fn waitOnKillChild(state: *OnKillWaitState) void {
    state.term = state.child.wait() catch |err| {
        state.err = err;
        state.done.store(true, .release);
        return;
    };
    state.done.store(true, .release);
}

fn waitForOnKillChild(done: *const std.atomic.Value(bool), timeout_ms: u64) bool {
    const sleep_ms: u64 = 5;
    var elapsed_ms: u64 = 0;

    while (elapsed_ms < timeout_ms) {
        if (done.load(.acquire)) return true;
        const remaining_ms = timeout_ms - elapsed_ms;
        const current_sleep_ms: u64 = @min(sleep_ms, remaining_ms);
        std.Thread.sleep(current_sleep_ms * @as(u64, std.time.ns_per_ms));
        elapsed_ms += current_sleep_ms;
    }

    return done.load(.acquire);
}

test "on kill hook times out and kills long running hook" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.cwd = cwd;
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.on_kill, "sh");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.on_kill, "-c");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.on_kill, "sleep 5; printf late > on_kill.txt");

    const started = std.time.milliTimestamp();
    try std.testing.expectError(error.OnKillFailed, executeOnKillCommandWithTimeoutMs(std.testing.allocator, &proc_cfg, 50));
    const elapsed = std.time.milliTimestamp() - started;

    try std.testing.expect(elapsed < 1000);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("on_kill.txt", .{}));
}

fn buildEnvironmentMap(
    allocator: std.mem.Allocator,
    proc_cfg: *const config.schema.ProcessConfig,
) !std.process.EnvMap {
    var env_map = try std.process.getEnvMap(allocator);
    errdefer env_map.deinit();

    if (proc_cfg.add_path.items.len > 0) {
        var path = std.array_list.Managed(u8).init(allocator);
        defer path.deinit();

        if (env_map.get("PATH")) |current| try path.appendSlice(current);
        for (proc_cfg.add_path.items) |part| {
            try path.append(':');
            try path.appendSlice(part);
        }
        try env_map.put("PATH", path.items);
    }

    var it = proc_cfg.env.iterator();
    while (it.next()) |entry| {
        try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    return env_map;
}

fn resolveStopSignal(proc_cfg: *const config.schema.ProcessConfig) u8 {
    if (proc_cfg.stop > 0) return @intCast(proc_cfg.stop);
    return std.posix.SIG.TERM;
}

fn resolveStopTimeoutMs(proc_cfg: *const config.schema.ProcessConfig) u64 {
    if (proc_cfg.stop_timeout_ms > 0) return @intCast(proc_cfg.stop_timeout_ms);
    return default_stop_timeout_ms;
}

fn resolveTerminalRows(proc_cfg: *const config.schema.ProcessConfig) u16 {
    if (proc_cfg.terminal_rows > 0) return @intCast(proc_cfg.terminal_rows);
    return default_terminal_rows;
}

fn resolveTerminalCols(proc_cfg: *const config.schema.ProcessConfig) u16 {
    if (proc_cfg.terminal_cols > 0) return @intCast(proc_cfg.terminal_cols);
    return default_terminal_cols;
}

fn waitUntilStopped(instance: *Instance, timeout_ms: u64) bool {
    const attempts = @max(@as(u64, 1), timeout_ms / 10);
    var index: u64 = 0;
    while (index < attempts) : (index += 1) {
        if (!instance.isRunning()) return true;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return !instance.isRunning();
}

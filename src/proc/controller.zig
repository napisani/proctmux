const std = @import("std");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");
const ring = @import("../ring/root.zig");
const builder = @import("builder.zig");
const env = @import("env.zig");
const instance_mod = @import("instance.zig");
const on_kill = @import("on_kill.zig");
const output = @import("output.zig");
const spawn = @import("spawn.zig");

const default_scrollback_capacity = 1024 * 1024;
const default_stop_timeout_ms = 3000;

pub const Instance = instance_mod.Instance;

pub const Controller = struct {
    allocator: std.mem.Allocator,
    global_config: ?*const config.schema.Config,
    processes: std.AutoHashMap(domain.process.ProcessId, *Instance),
    mutex: std.Thread.Mutex = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        global_config: ?*const config.schema.Config,
    ) Controller {
        return .{
            .allocator = allocator,
            .global_config = global_config,
            .processes = std.AutoHashMap(domain.process.ProcessId, *Instance).init(allocator),
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
        id: domain.process.ProcessId,
        proc_cfg: *const config.schema.ProcessConfig,
    ) !*Instance {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.processes.contains(id)) return error.ProcessAlreadyExists;

        const command_spec = (try builder.buildCommand(self.allocator, proc_cfg, self.global_config)) orelse {
            return error.InvalidProcessConfig;
        };
        var command_spec_owned = true;
        errdefer if (command_spec_owned) command_spec.deinit(self.allocator);

        var env_map = try env.buildMap(self.allocator, proc_cfg);
        defer env_map.deinit();

        var started = try spawn.start(self.allocator, proc_cfg, command_spec, &env_map);
        errdefer started.deinit();

        var instance = try self.allocator.create(Instance);
        errdefer self.allocator.destroy(instance);

        const scrollback = try ring.RingBuffer.init(self.allocator, default_scrollback_capacity);
        instance.* = .{
            .allocator = self.allocator,
            .id = id,
            .config = proc_cfg,
            .command_spec = command_spec,
            .handle = started.handle,
            .scrollback = scrollback,
        };
        command_spec_owned = false;
        started.disarm();
        errdefer instance.deinit();

        instance.output_thread = try std.Thread.spawn(.{}, output.capture, .{instance});
        instance.wait_thread = try std.Thread.spawn(.{}, spawn.waitForExit, .{instance});

        try self.processes.put(id, instance);
        return instance;
    }

    pub fn stopProcess(self: *Controller, id: domain.process.ProcessId) !void {
        const instance = self.getInstance(id) orelse return error.ProcessNotFound;

        if (instance.isRunning()) {
            const stop_signal = resolveStopSignal(instance.config);
            std.posix.kill(instance.pid(), stop_signal) catch {};
            if (!waitUntilStopped(instance, resolveStopTimeoutMs(instance.config))) {
                std.posix.kill(instance.pid(), std.posix.SIG.KILL) catch {};
                _ = waitUntilStopped(instance, 2000);
            }
        }

        try self.releaseProcess(id, instance, true);
    }

    pub fn cleanupProcess(self: *Controller, id: domain.process.ProcessId) !void {
        const instance = self.getInstance(id) orelse return;
        if (instance.isRunning()) return error.ProcessStillRunning;

        try self.releaseProcess(id, instance, false);
    }

    fn releaseProcess(
        self: *Controller,
        id: domain.process.ProcessId,
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
            on_kill.execute(self.allocator, instance.config)
        else {};
        instance.deinit();
        self.allocator.destroy(instance);

        try on_kill_result;
    }

    pub fn isRunning(self: *Controller, id: domain.process.ProcessId) bool {
        const instance = self.getInstance(id) orelse return false;
        return instance.isRunning();
    }

    pub fn getProcessStatus(self: *Controller, id: domain.process.ProcessId) domain.process.ProcessStatus {
        return if (self.isRunning(id)) .running else .halted;
    }

    pub fn processController(self: *Controller) domain.process.ProcessController {
        return .{
            .context = self,
            .get_process_status = adapterGetProcessStatus,
            .get_pid = adapterGetPID,
        };
    }

    pub fn getPID(self: *Controller, id: domain.process.ProcessId) i32 {
        const instance = self.getInstance(id) orelse return -1;
        if (!instance.isRunning()) return -1;
        return @intCast(instance.pid());
    }

    pub fn getAllProcessIDs(self: *Controller, allocator: std.mem.Allocator) ![]domain.process.ProcessId {
        self.mutex.lock();
        defer self.mutex.unlock();

        var ids = try allocator.alloc(domain.process.ProcessId, self.processes.count());
        var it = self.processes.keyIterator();
        var index: usize = 0;
        while (it.next()) |key| : (index += 1) ids[index] = key.*;
        std.mem.sort(domain.process.ProcessId, ids, {}, lessThanProcessId);
        return ids;
    }

    pub fn getScrollback(self: *Controller, allocator: std.mem.Allocator, id: domain.process.ProcessId) ![]u8 {
        const instance = self.getInstance(id) orelse return error.ProcessNotFound;
        return instance.scrollback.bytes(allocator);
    }

    pub fn sendBytes(self: *Controller, id: domain.process.ProcessId, bytes: []const u8) !void {
        const instance = self.getInstance(id) orelse return error.ProcessNotFound;
        if (!instance.isRunning()) return error.ProcessNotRunning;
        try instance.sendBytes(bytes);
    }

    fn getInstance(self: *Controller, id: domain.process.ProcessId) ?*Instance {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.processes.get(id);
    }
};

fn lessThanProcessId(_: void, a: domain.process.ProcessId, b: domain.process.ProcessId) bool {
    return a.toInt() < b.toInt();
}

fn adapterGetProcessStatus(context: *anyopaque, id: domain.process.ProcessId) domain.process.ProcessStatus {
    const self: *Controller = @ptrCast(@alignCast(context));
    return self.getProcessStatus(id);
}

fn adapterGetPID(context: *anyopaque, id: domain.process.ProcessId) i32 {
    const self: *Controller = @ptrCast(@alignCast(context));
    return self.getPID(id);
}

fn resolveStopSignal(proc_cfg: *const config.schema.ProcessConfig) u8 {
    if (proc_cfg.stop > 0) return @intCast(proc_cfg.stop);
    return std.posix.SIG.TERM;
}

fn resolveStopTimeoutMs(proc_cfg: *const config.schema.ProcessConfig) u64 {
    if (proc_cfg.stop_timeout_ms > 0) return @intCast(proc_cfg.stop_timeout_ms);
    return default_stop_timeout_ms;
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

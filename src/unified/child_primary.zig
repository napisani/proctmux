const std = @import("std");
const pty = @import("../proc/pty.zig");
const tui = @import("../tui/root.zig");

const log = std.log.scoped(.child_primary);

pub const ChildPrimary = struct {
    allocator: std.mem.Allocator,
    pid: std.posix.pid_t,
    pty_file: ?std.fs.File,
    output_file: ?std.fs.File,
    output: std.array_list.Managed(u8),
    mutex: std.Thread.Mutex = .{},
    output_thread: ?std.Thread = null,
    wait_thread: ?std.Thread = null,
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        env_map: *const std.process.EnvMap,
        cwd: []const u8,
    ) !*ChildPrimary {
        const spawned = try pty.spawn(allocator, argv, env_map, cwd, 30, 100);
        errdefer spawned.master.close();

        const output_fd = try std.posix.dup(spawned.master.handle);
        const output_file: std.fs.File = .{ .handle = output_fd };
        errdefer output_file.close();

        const child = try allocator.create(ChildPrimary);
        errdefer allocator.destroy(child);

        child.* = .{
            .allocator = allocator,
            .pid = spawned.pid,
            .pty_file = spawned.master,
            .output_file = output_file,
            .output = std.array_list.Managed(u8).init(allocator),
        };
        errdefer child.output.deinit();

        child.output_thread = try std.Thread.spawn(.{}, captureOutput, .{child});
        child.wait_thread = try std.Thread.spawn(.{}, waitChild, .{child});
        return child;
    }

    pub fn deinit(self: *ChildPrimary) void {
        if (!self.exited.load(.seq_cst)) {
            std.posix.kill(self.pid, std.posix.SIG.INT) catch {};
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        if (!self.exited.load(.seq_cst)) {
            std.posix.kill(self.pid, std.posix.SIG.TERM) catch {};
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        if (!self.exited.load(.seq_cst)) std.posix.kill(self.pid, std.posix.SIG.KILL) catch {};

        if (self.pty_file) |file| {
            file.close();
            self.pty_file = null;
        }
        if (self.wait_thread) |thread| {
            thread.join();
            self.wait_thread = null;
        }
        if (self.output_thread) |thread| {
            thread.join();
            self.output_thread = null;
        }
        if (self.output_file) |file| {
            file.close();
            self.output_file = null;
        }
        self.output.deinit();
        self.allocator.destroy(self);
    }

    pub fn sink(self: *ChildPrimary) tui.split_model.InputSink {
        return .{
            .context = self,
            .write = writeInput,
        };
    }

    pub fn snapshot(self: *ChildPrimary, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return allocator.dupe(u8, self.output.items);
    }

    fn appendOutput(self: *ChildPrimary, bytes: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.output.appendSlice(bytes);
        const max_output = 1024 * 1024;
        if (self.output.items.len > max_output) {
            const trim = self.output.items.len - max_output;
            std.mem.copyForwards(u8, self.output.items[0..max_output], self.output.items[trim..]);
            self.output.shrinkRetainingCapacity(max_output);
        }
    }

    fn writeInput(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *ChildPrimary = @ptrCast(@alignCast(context));
        const file = self.pty_file orelse return error.ProcessNotRunning;
        try file.writeAll(bytes);
    }
};

fn captureOutput(child: *ChildPrimary) void {
    const file = child.output_file orelse return;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&buffer) catch |err| {
            log.debug("child primary output capture stopped after read error: {s}", .{@errorName(err)});
            return;
        };
        if (n == 0) return;
        child.appendOutput(buffer[0..n]) catch |err| {
            log.debug("child primary output append failed: {s}", .{@errorName(err)});
            return;
        };
    }
}

fn waitChild(child: *ChildPrimary) void {
    _ = std.posix.waitpid(child.pid, 0);
    child.exited.store(true, .seq_cst);
}

//! Mutable runtime record for one started process.
//! An Instance ties together OS process handles, output capture state, and cleanup ownership for a single launch.
//! Scrollback storage is controller-owned so output survives after the process handle is released.

const std = @import("std");
const platform = @import("../platform.zig");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");
const ring = @import("../ring/root.zig");
const builder = @import("builder.zig");

pub const ProcessHandle = union(enum) {
    pty: PtyHandle,
    pipe: PipeHandle,

    pub fn pid(self: *const ProcessHandle) std.posix.pid_t {
        return switch (self.*) {
            .pty => |pty| pty.pid,
            .pipe => |pipe| pipe.pid,
        };
    }

    pub fn inputFile(self: *ProcessHandle) platform.fs.File {
        return switch (self.*) {
            .pty => |*pty| pty.master,
            .pipe => |*pipe| pipe.stdin,
        };
    }

    pub fn outputFile(self: *ProcessHandle) platform.fs.File {
        return switch (self.*) {
            .pty => |*pty| pty.master,
            .pipe => |*pipe| pipe.stdout,
        };
    }

    pub fn wait(self: *ProcessHandle) !u32 {
        return switch (self.*) {
            .pty => |pty| waitForPty(pty.pid),
            .pipe => |*pipe| termStatus(try pipe.child.wait(platform.io())),
        };
    }

    pub fn killForStartupCleanup(self: *ProcessHandle) void {
        switch (self.*) {
            .pty => |pty| std.posix.kill(pty.pid, std.posix.SIG.KILL) catch {},
            .pipe => |*pipe| pipe.child.kill(platform.io()),
        }
    }

    pub fn deinit(self: *ProcessHandle) void {
        switch (self.*) {
            .pty => |pty| platform.fs.close(pty.master),
            .pipe => |pipe| {
                platform.fs.close(pipe.stdin);
                platform.fs.close(pipe.stdout);
            },
        }
    }
};

pub const PtyHandle = struct {
    pid: std.posix.pid_t,
    master: platform.fs.File,
};

pub const PipeHandle = struct {
    pid: std.posix.pid_t,
    child: std.process.Child,
    stdin: platform.fs.File,
    stdout: platform.fs.File,
};

pub const Lifecycle = union(enum) {
    running,
    exited: u32,

    pub fn isRunning(self: Lifecycle) bool {
        return self == .running;
    }
};

pub const Instance = struct {
    allocator: std.mem.Allocator,
    id: domain.process.ProcessId,
    config: *const config.schema.ProcessConfig,
    command_spec: builder.CommandSpec,
    handle: ProcessHandle,
    scrollback: *ring.RingBuffer,
    output_thread: ?std.Thread = null,
    wait_thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    lifecycle: Lifecycle = .running,

    pub fn deinit(self: *Instance) void {
        if (self.output_thread) |thread| thread.join();
        if (self.wait_thread) |thread| thread.join();
        self.handle.deinit();
        self.command_spec.deinit(self.allocator);
    }

    pub fn pid(self: *const Instance) std.posix.pid_t {
        return self.handle.pid();
    }

    pub fn isRunning(self: *Instance) bool {
        self.mutex.lockUncancelable(platform.io());
        defer self.mutex.unlock(platform.io());
        return self.lifecycle.isRunning();
    }

    pub fn sendBytes(self: *Instance, bytes: []const u8) !void {
        if (!self.isRunning()) return error.ProcessNotRunning;
        const file = self.handle.inputFile();
        try platform.fs.writeAll(file, bytes);
    }

    pub fn markExited(self: *Instance, term_status: u32) void {
        self.mutex.lockUncancelable(platform.io());
        defer self.mutex.unlock(platform.io());
        self.lifecycle = .{ .exited = term_status };
    }
};

fn waitForPty(pid: std.posix.pid_t) !u32 {
    var status: c_int = 0;
    while (true) {
        switch (std.posix.errno(std.posix.system.waitpid(pid, &status, 0))) {
            .SUCCESS => return @bitCast(status),
            .INTR => continue,
            else => return error.WaitFailed,
        }
    }
}

fn termStatus(term: std.process.Child.Term) u32 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| 128 + @intFromEnum(signal),
        .stopped => |signal| @intFromEnum(signal),
        .unknown => |status| status,
    };
}

//! Mutable runtime record for one started process.
//! An Instance ties together OS process handles, output capture state, scrollback, and cleanup ownership for a single launch.

const std = @import("std");
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

    pub fn inputFile(self: *ProcessHandle) std.fs.File {
        return switch (self.*) {
            .pty => |*pty| pty.master,
            .pipe => |*pipe| pipe.stdin,
        };
    }

    pub fn outputFile(self: *ProcessHandle) std.fs.File {
        return switch (self.*) {
            .pty => |*pty| pty.master,
            .pipe => |*pipe| pipe.stdout,
        };
    }

    pub fn wait(self: *ProcessHandle) !u32 {
        return switch (self.*) {
            .pty => |pty| std.posix.waitpid(pty.pid, 0).status,
            .pipe => |*pipe| termStatus(try pipe.child.wait()),
        };
    }

    pub fn killForStartupCleanup(self: *ProcessHandle) void {
        switch (self.*) {
            .pty => |pty| std.posix.kill(pty.pid, std.posix.SIG.KILL) catch {},
            .pipe => |*pipe| _ = pipe.child.kill() catch null,
        }
    }

    pub fn deinit(self: *ProcessHandle) void {
        switch (self.*) {
            .pty => |pty| pty.master.close(),
            .pipe => |pipe| {
                pipe.stdin.close();
                pipe.stdout.close();
            },
        }
    }
};

pub const PtyHandle = struct {
    pid: std.posix.pid_t,
    master: std.fs.File,
};

pub const PipeHandle = struct {
    pid: std.posix.pid_t,
    child: std.process.Child,
    stdin: std.fs.File,
    stdout: std.fs.File,
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
    scrollback: ring.RingBuffer,
    output_thread: ?std.Thread = null,
    wait_thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},
    lifecycle: Lifecycle = .running,

    pub fn deinit(self: *Instance) void {
        if (self.output_thread) |thread| thread.join();
        if (self.wait_thread) |thread| thread.join();
        self.handle.deinit();
        self.scrollback.deinit();
        self.command_spec.deinit(self.allocator);
    }

    pub fn pid(self: *const Instance) std.posix.pid_t {
        return self.handle.pid();
    }

    pub fn isRunning(self: *Instance) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.lifecycle.isRunning();
    }

    pub fn sendBytes(self: *Instance, bytes: []const u8) !void {
        if (!self.isRunning()) return error.ProcessNotRunning;
        var file = self.handle.inputFile();
        try file.writeAll(bytes);
    }

    pub fn markExited(self: *Instance, term_status: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.lifecycle = .{ .exited = term_status };
    }
};

fn termStatus(term: std.process.Child.Term) u32 {
    return switch (term) {
        .Exited => |code| code,
        .Signal => |signal| 128 + signal,
        .Stopped => |signal| signal,
        .Unknown => |status| status,
    };
}

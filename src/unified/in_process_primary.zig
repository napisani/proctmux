//! In-process Primary adapter for unified tests.
//! Tests use this seam to exercise unified runtime behavior without spawning another proctmux binary.

const std = @import("std");
const primary = @import("../primary/root.zig");
const tui = @import("../tui/root.zig");

pub const PrimaryRun = struct {
    primary_server: *primary.Server,
    socket_path: []const u8,
    stopped: *std.atomic.Value(bool),
    result: ThreadResult = .running,
};

const ThreadResult = union(enum) {
    running,
    completed,
    failed: anyerror,
};

pub const ServerInput = struct {
    primary_server: *primary.Server,
    session: *tui.client_session.ClientSession,

    pub fn sink(self: *ServerInput) tui.split_model.InputSink {
        return .{
            .context = self,
            .write = write,
        };
    }

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *ServerInput = @ptrCast(@alignCast(context));
        self.primary_server.setCurrentProcess(self.session.model.active_proc_id);
        try self.primary_server.sendInputToCurrentProcess(bytes);
    }
};

pub fn runPrimaryServer(state: *PrimaryRun) void {
    state.primary_server.serveCommandsAtPath(state.socket_path, state.stopped) catch |err| {
        state.result = .{ .failed = err };
        return;
    };
    state.result = .completed;
}

pub fn finishPrimaryRun(stopped: *std.atomic.Value(bool), primary_run: *const PrimaryRun) !void {
    switch (primary_run.result) {
        .running, .completed => {},
        .failed => |err| {
            if (stopped.load(.seq_cst) and err == error.FileNotFound) return;
            return err;
        },
    }
}

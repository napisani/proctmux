//! Process-owning Primary Server.
//! The server owns AppState, ProcessController, Snapshot production, autostart, stdin forwarding, and the IPC command handler seam.

const std = @import("std");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");
const ipc = @import("../ipc/root.zig");
const proc_mod = @import("../proc/root.zig");
const command_runner = @import("command_runner.zig");
const test_config = @import("../test_support/config.zig");
const test_ipc = @import("../test_support/ipc.zig");

const log = std.log.scoped(.primary);

/// Process-owning server used by primary and unified modes. It is the only
/// module that can mutate AppState and ProcessController together.
pub const Server = struct {
    allocator: std.mem.Allocator,
    cfg: *config.schema.Config,
    state: domain.state.AppState,
    current_proc_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    controller: proc_mod.controller.Controller,

    pub fn init(allocator: std.mem.Allocator, cfg: *config.schema.Config) !Server {
        var state = try domain.state.AppState.init(allocator, cfg);
        errdefer state.deinit();

        return .{
            .allocator = allocator,
            .cfg = cfg,
            .state = state,
            .controller = proc_mod.controller.Controller.init(allocator, cfg),
        };
    }

    pub fn deinit(self: *Server) void {
        self.controller.deinit();
        self.state.deinit();
    }

    pub fn getState(self: *Server) *domain.state.AppState {
        return &self.state;
    }

    pub fn currentProcessID(self: *const Server) domain.process.ProcessId {
        return domain.process.ProcessId.fromInt(self.current_proc_id.load(.seq_cst));
    }

    pub fn setCurrentProcess(self: *Server, id: domain.process.ProcessId) void {
        self.state.current_proc_id = id;
        self.current_proc_id.store(id.toInt(), .seq_cst);
    }

    pub fn getProcessController(self: *Server) domain.process.ProcessController {
        return self.controller.processController();
    }

    pub fn commandHandler(self: *Server) ipc.server.CommandHandler {
        return .{
            .context = self,
            .handle = handleCommandAdapter,
        };
    }

    /// Produces client-visible snapshots on demand for IPC clients. The snapshot
    /// projection deliberately excludes process execution config and secrets.
    pub fn snapshotProvider(self: *Server) ipc.server.SnapshotProvider {
        return .{
            .context = self,
            .snapshot_line = snapshotLineAdapter,
        };
    }

    /// Starts autostart processes before clients attach so initial snapshots
    /// already reflect the configured startup state.
    pub fn startAutostartProcesses(self: *Server) void {
        for (self.state.processes.items) |*process| {
            if (process.config.autostart) self.startProcess(process) catch |err| {
                log.warn("autostart failed for process '{s}': {s}", .{ process.label, @errorName(err) });
            };
        }
    }

    /// Forwards raw terminal input to the selected process. Missing/stopped
    /// processes are ignored because process selection can race with exits.
    pub fn sendInputToCurrentProcess(self: *Server, bytes: []const u8) !void {
        const id = self.currentProcessID();
        if (id.isNone()) return;
        self.controller.sendBytes(id, bytes) catch |err| switch (err) {
            error.ProcessNotFound, error.ProcessNotRunning => return,
            else => return err,
        };
    }

    pub fn serveCommandsAtPath(
        self: *Server,
        socket_path: []const u8,
        stopped: *std.atomic.Value(bool),
    ) !void {
        self.startAutostartProcesses();
        try ipc.server.serveCommandsAtPathWithSnapshots(
            self.allocator,
            socket_path,
            self.commandHandler(),
            self.snapshotProvider(),
            stopped,
        );
    }

    pub fn handleRequest(
        self: *Server,
        allocator: std.mem.Allocator,
        request: ipc.protocol.CommandRequest,
    ) !ipc.protocol.Response {
        return self.commandRunner().handleRequest(allocator, request);
    }

    fn commandRunner(self: *Server) command_runner.Runner {
        return .{
            .state = &self.state,
            .controller = &self.controller,
            .current_process_id = &self.current_proc_id,
        };
    }

    fn startProcess(self: *Server, process: *domain.process.Process) !void {
        if (self.controller.isRunning(process.id)) return;
        try self.controller.cleanupProcess(process.id);
        if (self.currentProcessID().isNone()) self.setCurrentProcess(process.id);
        _ = try self.controller.startProcess(process.id, process.config);
    }
};

fn handleCommandAdapter(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    request: ipc.protocol.CommandRequest,
) !ipc.protocol.Response {
    const self: *Server = @ptrCast(@alignCast(context));
    return self.handleRequest(allocator, request);
}

fn snapshotLineAdapter(context: *anyopaque, allocator: std.mem.Allocator) ![]const u8 {
    const self: *Server = @ptrCast(@alignCast(context));
    var snapshot = try domain.client_snapshot.fromAppState(allocator, &self.state, self.getProcessController());
    defer snapshot.deinit(allocator);
    return ipc.protocol.snapshotLine(allocator, snapshot.view());
}

test "primary command handler starts switches and stops processes" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    try test_config.putShellProcessWithStopTimeout(&cfg, "api", "sleep 5", 500);

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();

    var started = try primary.handleRequest(std.testing.allocator, .{
        .request_id = 1,
        .action = .start,
        .target = "api",
    });
    defer started.deinit(std.testing.allocator);
    try std.testing.expect(started.success);
    try std.testing.expect(primary.controller.isRunning(domain.process.ProcessId.fromInt(1)));

    var switched = try primary.handleRequest(std.testing.allocator, .{
        .request_id = 2,
        .action = .switch_process,
        .target = "api",
    });
    defer switched.deinit(std.testing.allocator);
    try std.testing.expect(switched.success);
    try std.testing.expectEqual(domain.process.ProcessId.fromInt(1), primary.getState().current_proc_id);

    var stopped = try primary.handleRequest(std.testing.allocator, .{
        .request_id = 3,
        .action = .stop,
        .target = "api",
    });
    defer stopped.deinit(std.testing.allocator);
    try std.testing.expect(stopped.success);
    try std.testing.expect(!primary.controller.isRunning(domain.process.ProcessId.fromInt(1)));
}

test "primary command handler stops all running processes" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    try test_config.putShellProcessWithStopTimeout(&cfg, "api", "sleep 5", 500);
    try test_config.putShellProcessWithStopTimeout(&cfg, "worker", "sleep 5", 500);

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();

    for ([_][]const u8{ "api", "worker" }, 0..) |label, index| {
        var started = try primary.handleRequest(std.testing.allocator, .{
            .request_id = @intCast(index + 1),
            .action = .start,
            .target = label,
        });
        defer started.deinit(std.testing.allocator);
        try std.testing.expect(started.success);
    }

    var stopped = try primary.handleRequest(std.testing.allocator, .{
        .request_id = 10,
        .action = .stop_running,
        .target = null,
    });
    defer stopped.deinit(std.testing.allocator);
    try std.testing.expect(stopped.success);
    try std.testing.expect(!primary.controller.isRunning(domain.process.ProcessId.fromInt(1)));
    try std.testing.expect(!primary.controller.isRunning(domain.process.ProcessId.fromInt(2)));
}

test "primary command handler reports missing process names" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();

    var response = try primary.handleRequest(std.testing.allocator, .{
        .request_id = 1,
        .action = .start,
        .target = null,
    });
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(!response.success);
    try std.testing.expectEqualStrings("missing process name", response.error_message);
}

test "primary startup starts autostart processes only" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    try test_config.putShellProcessWithStopTimeout(&cfg, "api", "sleep 5", 500);
    try test_config.putShellProcessWithStopTimeout(&cfg, "worker", "sleep 5", 500);
    cfg.procs.getPtr("api").?.autostart = true;

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();

    primary.startAutostartProcesses();

    try std.testing.expect(primary.controller.isRunning(domain.process.ProcessId.fromInt(1)));
    try std.testing.expect(!primary.controller.isRunning(domain.process.ProcessId.fromInt(2)));
}

test "primary can start a process again after natural exit" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    try test_config.putShellProcessWithStopTimeout(&cfg, "api", "printf done", 500);

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();

    var first = try primary.handleRequest(std.testing.allocator, .{
        .request_id = 1,
        .action = .start,
        .target = "api",
    });
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.success);

    try waitForProcessStopped(&primary, domain.process.ProcessId.fromInt(1));

    var second = try primary.handleRequest(std.testing.allocator, .{
        .request_id = 2,
        .action = .start,
        .target = "api",
    });
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(second.success);
}

test "primary forwards stdin bytes to selected running process" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);

    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    errdefer proc_cfg.deinit(std.testing.allocator);
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "sh");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "-c");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "IFS= read line; printf 'got:%s' \"$line\"");
    proc_cfg.stop_timeout_ms = 500;
    const label = try std.testing.allocator.dupe(u8, "api");
    errdefer std.testing.allocator.free(label);
    try cfg.procs.put(label, proc_cfg);

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();

    var started = try primary.handleRequest(std.testing.allocator, .{
        .request_id = 1,
        .action = .start,
        .target = "api",
    });
    defer started.deinit(std.testing.allocator);
    try std.testing.expect(started.success);

    var switched = try primary.handleRequest(std.testing.allocator, .{
        .request_id = 2,
        .action = .switch_process,
        .target = "api",
    });
    defer switched.deinit(std.testing.allocator);
    try std.testing.expect(switched.success);

    try primary.sendInputToCurrentProcess("hello\n");
    try waitForPrimaryScrollbackContains(&primary, domain.process.ProcessId.fromInt(1), "got:hello");
}

test "primary snapshot provider serializes minimal snapshot" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    try test_config.putShellProcessWithStopTimeout(&cfg, "api", "sleep 5", 500);
    try config.schema.putOwnedString(std.testing.allocator, &cfg.procs.getPtr("api").?.env, "TOKEN", "secret");

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();
    primary.setCurrentProcess(domain.process.ProcessId.fromInt(1));

    const provider = primary.snapshotProvider();
    const line = try provider.snapshot_line(provider.context, std.testing.allocator);
    defer std.testing.allocator.free(line);

    var update = try ipc.protocol.parseSnapshotLine(std.testing.allocator, line);
    defer update.deinit();
    const snapshot = update.snapshot();
    try std.testing.expectEqual(@as(u32, 1), snapshot.current_process_id);
    try std.testing.expectEqualStrings("api", snapshot.processes[0].label);
    try std.testing.expect(std.mem.indexOf(u8, line, "TOKEN") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"env\"") == null);
}

test "primary command server handles repeated IPC clients" {
    const path = "/tmp/proctmux-zig-primary-server-loop-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    try test_config.putShellProcessWithStopTimeout(&cfg, "api", "sleep 5", 500);

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();

    var stopped = std.atomic.Value(bool).init(false);
    var run = PrimaryServerRun{
        .primary = &primary,
        .path = path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryServer, .{&run});
    test_ipc.waitForSocketFile(path);

    var start_response = try ipc.client.sendCommandToPath(std.testing.allocator, path, 1, .start, "api");
    defer start_response.deinit(std.testing.allocator);
    try std.testing.expect(start_response.success);

    var ipc_client = try ipc.client.Client.connect(std.testing.allocator, path);
    defer ipc_client.deinit();
    var snapshot_update = try ipc_client.readSnapshot();
    defer snapshot_update.deinit();
    try std.testing.expectEqualStrings("api", snapshot_update.snapshot().processes[0].label);
    try std.testing.expect(snapshot_update.snapshot().processes[0].status == .running);

    stopped.store(true, .seq_cst);
    test_ipc.unblockServer(path);
    thread.join();
    if (run.err) |err| return err;
}

const PrimaryServerRun = struct {
    primary: *Server,
    path: []const u8,
    stopped: *std.atomic.Value(bool),
    err: ?anyerror = null,
};

fn runPrimaryServer(run: *PrimaryServerRun) void {
    run.primary.serveCommandsAtPath(run.path, run.stopped) catch |err| {
        run.err = err;
    };
}

fn waitForPrimaryScrollbackContains(primary: *Server, id: domain.process.ProcessId, needle: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        const bytes = try primary.controller.getScrollback(std.testing.allocator, id);
        defer std.testing.allocator.free(bytes);
        if (std.mem.indexOf(u8, bytes, needle) != null) return;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.ExpectedScrollback;
}

fn waitForProcessStopped(primary: *Server, id: domain.process.ProcessId) !void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (!primary.controller.isRunning(id)) return;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.ExpectedStoppedProcess;
}

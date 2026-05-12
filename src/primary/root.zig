const std = @import("std");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");
const ipc = @import("../ipc/root.zig");
const proc_mod = @import("../proc/root.zig");
const test_config = @import("../test_support/config.zig");
const test_ipc = @import("../test_support/ipc.zig");

const log = std.log.scoped(.primary);

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

    pub fn stateProvider(self: *Server) ipc.server.StateProvider {
        return .{
            .context = self,
            .state_line = stateLineAdapter,
        };
    }

    pub fn startAutostartProcesses(self: *Server) void {
        for (self.state.processes.items) |*process| {
            if (process.config.autostart) self.startProcess(process) catch |err| {
                log.warn("autostart failed for process '{s}': {s}", .{ process.label, @errorName(err) });
            };
        }
    }

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
        try ipc.server.serveCommandsAtPathWithState(
            self.allocator,
            socket_path,
            self.commandHandler(),
            self.stateProvider(),
            stopped,
        );
    }

    pub fn handleRequest(
        self: *Server,
        allocator: std.mem.Allocator,
        request: ipc.protocol.CommandRequest,
    ) !ipc.protocol.Response {
        return switch (request.action) {
            .list => self.listResponse(allocator, request.request_id),
            .start, .stop, .restart, .switch_process => self.handleNamedRequest(allocator, request),
            .stop_running => self.stopRunningResponse(allocator, request.request_id),
            .restart_running => self.restartRunningResponse(allocator, request.request_id),
        };
    }

    fn handleNamedRequest(
        self: *Server,
        allocator: std.mem.Allocator,
        request: ipc.protocol.CommandRequest,
    ) !ipc.protocol.Response {
        if (request.label.len == 0) return errorResponse(allocator, request.request_id, "missing process name");

        const process = self.state.getProcessByLabel(request.label) orelse {
            const message = try std.fmt.allocPrint(allocator, "process not found: {s}", .{request.label});
            defer allocator.free(message);
            return errorResponse(allocator, request.request_id, message);
        };

        self.handleNamedProcess(request.action, process) catch |err| {
            return errorResponse(allocator, request.request_id, @errorName(err));
        };
        return successResponse(allocator, request.request_id);
    }

    fn handleNamedProcess(
        self: *Server,
        action: ipc.protocol.Command,
        process: *domain.process.Process,
    ) !void {
        switch (action) {
            .switch_process => self.setCurrentProcess(process.id),
            .start => try self.startProcess(process),
            .stop => try self.stopProcess(process),
            .restart => {
                try self.stopProcess(process);
                std.Thread.sleep(500 * std.time.ns_per_ms);
                try self.startProcess(process);
            },
            else => return error.UnsupportedCommand,
        }
    }

    fn startProcess(self: *Server, process: *domain.process.Process) !void {
        if (self.controller.isRunning(process.id)) return;
        try self.controller.cleanupProcess(process.id);
        if (self.currentProcessID().isNone()) self.setCurrentProcess(process.id);
        _ = try self.controller.startProcess(process.id, process.config);
    }

    fn stopProcess(self: *Server, process: *domain.process.Process) !void {
        if (!self.controller.isRunning(process.id)) return;
        try self.controller.stopProcess(process.id);
    }

    fn stopRunningResponse(self: *Server, allocator: std.mem.Allocator, request_id: []const u8) !ipc.protocol.Response {
        var stop_runs = std.array_list.Managed(StopProcessRun).init(allocator);
        defer stop_runs.deinit();

        for (self.state.processes.items) |*process| {
            if (self.controller.isRunning(process.id)) {
                try stop_runs.append(.{
                    .controller = &self.controller,
                    .id = process.id,
                    .label = process.label,
                });
            }
        }

        stopProcessesConcurrently(allocator, stop_runs.items);
        reportStopFailures(stop_runs.items);

        return successResponse(allocator, request_id);
    }

    fn restartRunningResponse(self: *Server, allocator: std.mem.Allocator, request_id: []const u8) !ipc.protocol.Response {
        for (self.state.processes.items) |*process| {
            if (self.controller.isRunning(process.id)) {
                try self.controller.stopProcess(process.id);
                std.Thread.sleep(500 * std.time.ns_per_ms);
                _ = try self.controller.startProcess(process.id, process.config);
            }
        }
        return successResponse(allocator, request_id);
    }

    fn listResponse(self: *Server, allocator: std.mem.Allocator, request_id: []const u8) !ipc.protocol.Response {
        var process_list = try allocator.alloc(ipc.protocol.ProcessListItem, self.state.processes.items.len);
        errdefer allocator.free(process_list);

        var initialized: usize = 0;
        errdefer deinitProcessList(allocator, process_list[0..initialized]);

        const process_controller = self.getProcessController();
        for (self.state.processes.items, 0..) |process, index| {
            const view = domain.process.toView(process, process_controller);
            process_list[index] = .{
                .name = try allocator.dupe(u8, view.label),
                .running = view.status == .running,
                .index = @intCast(view.id.toInt()),
            };
            initialized += 1;
        }

        return .{
            .request_id = try allocator.dupe(u8, request_id),
            .success = true,
            .error_message = try allocator.dupe(u8, ""),
            .process_list = process_list,
        };
    }
};

const StopProcessRun = struct {
    controller: *proc_mod.controller.Controller,
    id: domain.process.ProcessId,
    label: []const u8,
    result: ?anyerror = null,
};

fn stopProcessesConcurrently(
    allocator: std.mem.Allocator,
    stop_runs: []StopProcessRun,
) void {
    if (stop_runs.len == 0) return;

    const threads = allocator.alloc(std.Thread, stop_runs.len) catch |err| {
        log.warn("failed to allocate stop-running worker threads; stopping sequentially: {s}", .{@errorName(err)});
        stopProcessesSequentially(stop_runs);
        return;
    };
    defer allocator.free(threads);

    var started: usize = 0;
    while (started < stop_runs.len) : (started += 1) {
        threads[started] = std.Thread.spawn(.{}, stopProcessWorker, .{&stop_runs[started]}) catch |err| {
            log.warn("failed to spawn stop-running worker for {s}; stopping remaining processes sequentially: {s}", .{
                stop_runs[started].label,
                @errorName(err),
            });
            stopProcessWorker(&stop_runs[started]);
            if (stop_runs[started].result == null) stop_runs[started].result = err;
            break;
        };
    }

    for (threads[0..started]) |thread| thread.join();

    if (started < stop_runs.len) {
        stopProcessesSequentially(stop_runs[started + 1 ..]);
    }
}

fn stopProcessesSequentially(stop_runs: []StopProcessRun) void {
    for (stop_runs) |*stop_run| stopProcessWorker(stop_run);
}

fn stopProcessWorker(stop_run: *StopProcessRun) void {
    stop_run.controller.stopProcess(stop_run.id) catch |err| {
        stop_run.result = err;
    };
}

fn reportStopFailures(stop_runs: []const StopProcessRun) void {
    var failure_count: usize = 0;
    for (stop_runs) |stop_run| {
        if (stop_run.result) |err| {
            failure_count += 1;
            log.warn("stop-running failed for {s} (id={}): {s}", .{
                stop_run.label,
                stop_run.id.toInt(),
                @errorName(err),
            });
        }
    }

    if (failure_count > 0) {
        log.warn("stop-running completed with {} process stop failure(s); exiting anyway", .{failure_count});
    }
}

fn handleCommandAdapter(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    request: ipc.protocol.CommandRequest,
) !ipc.protocol.Response {
    const self: *Server = @ptrCast(@alignCast(context));
    return self.handleRequest(allocator, request);
}

fn stateLineAdapter(context: *anyopaque, allocator: std.mem.Allocator) ![]const u8 {
    const self: *Server = @ptrCast(@alignCast(context));
    return ipc.protocol.stateLine(allocator, &self.state, self.getProcessController());
}

fn successResponse(allocator: std.mem.Allocator, request_id: []const u8) !ipc.protocol.Response {
    return .{
        .request_id = try allocator.dupe(u8, request_id),
        .success = true,
        .error_message = try allocator.dupe(u8, ""),
        .process_list = try allocator.alloc(ipc.protocol.ProcessListItem, 0),
    };
}

fn errorResponse(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    message: []const u8,
) !ipc.protocol.Response {
    return .{
        .request_id = try allocator.dupe(u8, request_id),
        .success = false,
        .error_message = try allocator.dupe(u8, message),
        .process_list = try allocator.alloc(ipc.protocol.ProcessListItem, 0),
    };
}

fn deinitProcessList(allocator: std.mem.Allocator, items: []ipc.protocol.ProcessListItem) void {
    for (items) |item| item.deinit(allocator);
}

test "primary command handler lists starts switches and stops processes" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    try test_config.putShellProcessWithStopTimeout(&cfg, "api", "sleep 5", 500);
    try test_config.putShellProcessWithStopTimeout(&cfg, "worker", "sleep 5", 500);

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();

    var initial = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "1",
        .action = .list,
        .label = "",
    });
    defer initial.deinit(std.testing.allocator);
    try std.testing.expect(initial.success);
    try std.testing.expectEqual(@as(usize, 2), initial.process_list.len);
    try std.testing.expectEqualStrings("api", initial.process_list[0].name);
    try std.testing.expectEqual(@as(i64, 1), initial.process_list[0].index);
    try std.testing.expect(!initial.process_list[0].running);
    try std.testing.expectEqualStrings("worker", initial.process_list[1].name);
    try std.testing.expectEqual(@as(i64, 2), initial.process_list[1].index);
    try std.testing.expect(!initial.process_list[1].running);

    var started = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "2",
        .action = .start,
        .label = "api",
    });
    defer started.deinit(std.testing.allocator);
    try std.testing.expect(started.success);

    var switched = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "3",
        .action = .switch_process,
        .label = "api",
    });
    defer switched.deinit(std.testing.allocator);
    try std.testing.expect(switched.success);
    try std.testing.expectEqual(domain.process.ProcessId.fromInt(1), primary.getState().current_proc_id);

    var after_start = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "4",
        .action = .list,
        .label = "",
    });
    defer after_start.deinit(std.testing.allocator);
    try std.testing.expect(after_start.success);
    try std.testing.expect(after_start.process_list[0].running);
    try std.testing.expect(!after_start.process_list[1].running);

    var stopped = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "5",
        .action = .stop,
        .label = "api",
    });
    defer stopped.deinit(std.testing.allocator);
    try std.testing.expect(stopped.success);

    var after_stop = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "6",
        .action = .list,
        .label = "",
    });
    defer after_stop.deinit(std.testing.allocator);
    try std.testing.expect(after_stop.success);
    try std.testing.expect(!after_stop.process_list[0].running);
}

test "primary command handler stops all running processes" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    try test_config.putShellProcessWithStopTimeout(&cfg, "api", "sleep 5", 500);
    try test_config.putShellProcessWithStopTimeout(&cfg, "worker", "sleep 5", 500);

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();

    var start_api = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "1",
        .action = .start,
        .label = "api",
    });
    defer start_api.deinit(std.testing.allocator);
    var start_worker = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "2",
        .action = .start,
        .label = "worker",
    });
    defer start_worker.deinit(std.testing.allocator);

    var stopped = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "3",
        .action = .stop_running,
        .label = "",
    });
    defer stopped.deinit(std.testing.allocator);
    try std.testing.expect(stopped.success);

    var listed = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "4",
        .action = .list,
        .label = "",
    });
    defer listed.deinit(std.testing.allocator);
    try std.testing.expect(!listed.process_list[0].running);
    try std.testing.expect(!listed.process_list[1].running);
}

test "primary command handler stops running processes in parallel" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    try test_config.putShellProcessWithStopTimeout(&cfg, "api", "trap \"\" TERM; read line", 600);
    try test_config.putShellProcessWithStopTimeout(&cfg, "worker", "trap \"\" TERM; read line", 600);
    try test_config.putShellProcessWithStopTimeout(&cfg, "jobs", "trap \"\" TERM; read line", 600);

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();

    for ([_][]const u8{ "api", "worker", "jobs" }, 0..) |label, index| {
        var started = try primary.handleRequest(std.testing.allocator, .{
            .request_id = switch (index) {
                0 => "start-0",
                1 => "start-1",
                else => "start-2",
            },
            .action = .start,
            .label = label,
        });
        defer started.deinit(std.testing.allocator);
        try std.testing.expect(started.success);
    }

    const started_at = std.time.milliTimestamp();
    var stopped = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "stop-all",
        .action = .stop_running,
        .label = "",
    });
    defer stopped.deinit(std.testing.allocator);
    const elapsed_ms = std.time.milliTimestamp() - started_at;

    try std.testing.expect(stopped.success);
    try std.testing.expect(elapsed_ms < 1200);

    var listed = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "list",
        .action = .list,
        .label = "",
    });
    defer listed.deinit(std.testing.allocator);
    for (listed.process_list) |item| try std.testing.expect(!item.running);
}

test "primary command handler stop running exits after per-process stop errors" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    try test_config.putShellProcessWithStopTimeout(&cfg, "aaa-failer", "sleep 5", 500);
    try test_config.putShellProcessWithStopTimeout(&cfg, "zzz-survivor", "sleep 5", 500);
    try config.schema.appendOwned(std.testing.allocator, &cfg.procs.getPtr("aaa-failer").?.on_kill, "sh");
    try config.schema.appendOwned(std.testing.allocator, &cfg.procs.getPtr("aaa-failer").?.on_kill, "-c");
    try config.schema.appendOwned(std.testing.allocator, &cfg.procs.getPtr("aaa-failer").?.on_kill, "exit 3");

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();

    for ([_][]const u8{ "aaa-failer", "zzz-survivor" }, 0..) |label, index| {
        var started = try primary.handleRequest(std.testing.allocator, .{
            .request_id = if (index == 0) "start-0" else "start-1",
            .action = .start,
            .label = label,
        });
        defer started.deinit(std.testing.allocator);
        try std.testing.expect(started.success);
    }

    var stopped = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "stop-all",
        .action = .stop_running,
        .label = "",
    });
    defer stopped.deinit(std.testing.allocator);
    try std.testing.expect(stopped.success);

    var listed = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "list",
        .action = .list,
        .label = "",
    });
    defer listed.deinit(std.testing.allocator);
    try std.testing.expect(!listed.process_list[0].running);
    try std.testing.expect(!listed.process_list[1].running);
}

test "primary command handler reports missing process names" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();

    var response = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "1",
        .action = .start,
        .label = "",
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

    var listed = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "1",
        .action = .list,
        .label = "",
    });
    defer listed.deinit(std.testing.allocator);

    try std.testing.expect(listed.process_list[0].running);
    try std.testing.expect(!listed.process_list[1].running);
}

test "primary can start a process again after natural exit" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    try test_config.putShellProcessWithStopTimeout(&cfg, "api", "printf done", 500);

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();

    var first = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "1",
        .action = .start,
        .label = "api",
    });
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.success);

    try waitForProcessStopped(&primary, domain.process.ProcessId.fromInt(1));

    var second = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "2",
        .action = .start,
        .label = "api",
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
        .request_id = "1",
        .action = .start,
        .label = "api",
    });
    defer started.deinit(std.testing.allocator);
    try std.testing.expect(started.success);

    var switched = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "2",
        .action = .switch_process,
        .label = "api",
    });
    defer switched.deinit(std.testing.allocator);
    try std.testing.expect(switched.success);

    try primary.sendInputToCurrentProcess("hello\n");
    try waitForPrimaryScrollbackContains(&primary, domain.process.ProcessId.fromInt(1), "got:hello");
}

test "primary state provider serializes redacted current state" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    try test_config.putShellProcessWithStopTimeout(&cfg, "api", "sleep 5", 500);
    try config.schema.putOwnedString(std.testing.allocator, &cfg.procs.getPtr("api").?.env, "TOKEN", "secret");

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();
    primary.setCurrentProcess(domain.process.ProcessId.fromInt(1));

    const provider = primary.stateProvider();
    const line = try provider.state_line(provider.context, std.testing.allocator);
    defer std.testing.allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();

    const message = parsed.value.object;
    try std.testing.expectEqualStrings("state", message.get("type").?.string);
    const state = message.get("state").?.object;
    try std.testing.expectEqual(@as(i64, 1), state.get("CurrentProcID").?.integer);
    const api = state.get("Config").?.object.get("Procs").?.object.get("api").?.object;
    try std.testing.expect(api.get("Env").? == .null);
    const view = message.get("process_views").?.array.items[0].object;
    try std.testing.expectEqualStrings("api", view.get("Label").?.string);
    try std.testing.expect(view.get("Config").?.object.get("Env").? == .null);
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

    var start_response = try ipc.client.sendCommandToPath(std.testing.allocator, path, "1", .start, "api");
    defer start_response.deinit(std.testing.allocator);
    try std.testing.expect(start_response.success);

    var list_response = try ipc.client.sendCommandToPath(std.testing.allocator, path, "2", .list, "");
    defer list_response.deinit(std.testing.allocator);
    try std.testing.expect(list_response.success);
    try std.testing.expectEqual(@as(usize, 1), list_response.process_list.len);
    try std.testing.expectEqualStrings("api", list_response.process_list[0].name);
    try std.testing.expect(list_response.process_list[0].running);

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

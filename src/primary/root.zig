const std = @import("std");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");
const ipc = @import("../ipc/root.zig");
const proc_mod = @import("../proc/root.zig");

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

    pub fn currentProcessID(self: *const Server) u32 {
        return self.current_proc_id.load(.seq_cst);
    }

    pub fn setCurrentProcess(self: *Server, id: u32) void {
        self.state.current_proc_id = id;
        self.current_proc_id.store(id, .seq_cst);
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
            if (process.config.autostart) self.startProcess(process) catch {};
        }
    }

    pub fn sendInputToCurrentProcess(self: *Server, bytes: []const u8) !void {
        const id = self.currentProcessID();
        if (id == 0) return;
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
        if (self.currentProcessID() == 0) self.setCurrentProcess(process.id);
        _ = try self.controller.startProcess(process.id, process.config);
    }

    fn stopProcess(self: *Server, process: *domain.process.Process) !void {
        if (!self.controller.isRunning(process.id)) return;
        try self.controller.stopProcess(process.id);
    }

    fn stopRunningResponse(self: *Server, allocator: std.mem.Allocator, request_id: []const u8) !ipc.protocol.Response {
        for (self.state.processes.items) |*process| {
            if (self.controller.isRunning(process.id)) try self.controller.stopProcess(process.id);
        }
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
                .index = view.id,
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
    try putShellProcess(&cfg, "api", "sleep 5");
    try putShellProcess(&cfg, "worker", "sleep 5");

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
    try std.testing.expectEqual(@as(u32, 1), primary.getState().current_proc_id);

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
    try putShellProcess(&cfg, "api", "sleep 5");
    try putShellProcess(&cfg, "worker", "sleep 5");

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
    try putShellProcess(&cfg, "api", "sleep 5");
    try putShellProcess(&cfg, "worker", "sleep 5");
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
    try putShellProcess(&cfg, "api", "printf done");

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();

    var first = try primary.handleRequest(std.testing.allocator, .{
        .request_id = "1",
        .action = .start,
        .label = "api",
    });
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.success);

    try waitForProcessStopped(&primary, 1);

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
    try waitForPrimaryScrollbackContains(&primary, 1, "got:hello");
}

test "primary state provider serializes redacted current state" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    try putShellProcess(&cfg, "api", "sleep 5");
    try config.schema.putOwnedString(std.testing.allocator, &cfg.procs.getPtr("api").?.env, "TOKEN", "secret");

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();
    primary.setCurrentProcess(1);

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
    try putShellProcess(&cfg, "api", "sleep 5");

    var primary = try Server.init(std.testing.allocator, &cfg);
    defer primary.deinit();

    var stopped = std.atomic.Value(bool).init(false);
    var run = PrimaryServerRun{
        .primary = &primary,
        .path = path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryServer, .{&run});
    waitForSocketFile(path);

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
    unblockServer(path);
    thread.join();
    if (run.err) |err| return err;
}

fn putShellProcess(cfg: *config.schema.Config, label: []const u8, shell: []const u8) !void {
    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    errdefer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.owns_scalar_strings = true;
    proc_cfg.shell = try std.testing.allocator.dupe(u8, shell);
    proc_cfg.stop_timeout_ms = 500;

    const owned_label = try std.testing.allocator.dupe(u8, label);
    errdefer std.testing.allocator.free(owned_label);
    try cfg.procs.put(owned_label, proc_cfg);
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

fn unblockServer(path: []const u8) void {
    var stream = std.net.connectUnixSocket(path) catch return;
    stream.close();
}

fn waitForSocketFile(path: []const u8) void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        std.fs.accessAbsolute(path, .{}) catch {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            continue;
        };
        return;
    }
}

fn waitForPrimaryScrollbackContains(primary: *Server, id: u32, needle: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        const bytes = try primary.controller.getScrollback(std.testing.allocator, id);
        defer std.testing.allocator.free(bytes);
        if (std.mem.indexOf(u8, bytes, needle) != null) return;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.ExpectedScrollback;
}

fn waitForProcessStopped(primary: *Server, id: u32) !void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (!primary.controller.isRunning(id)) return;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.ExpectedStoppedProcess;
}

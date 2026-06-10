//! Primary Server Process Command execution.
//! This module converts IPC Process Commands into process lifecycle and selection changes while keeping response construction local to command semantics.

const std = @import("std");
const domain = @import("../domain/root.zig");
const ipc = @import("../ipc/root.zig");
const proc_mod = @import("../proc/root.zig");

const log = std.log.scoped(.primary_command_runner);

/// Executes Process Commands against Primary-owned state. The runner is kept
/// concrete instead of callback-heavy so command semantics stay local to the
/// Primary Server domain.
pub const Runner = struct {
    state: *domain.state.AppState,
    controller: *proc_mod.controller.Controller,
    current_process_id: *std.atomic.Value(u32),

    /// Handles one decoded IPC command and returns the response that should be
    /// written to the requesting client.
    pub fn handleRequest(
        self: Runner,
        allocator: std.mem.Allocator,
        request: ipc.protocol.CommandRequest,
    ) !ipc.protocol.Response {
        return switch (request.action) {
            .start, .stop, .restart, .switch_process => self.handleNamedRequest(allocator, request),
            .stop_running => self.stopRunningResponse(allocator, request.request_id),
            .restart_running => self.restartRunningResponse(allocator, request.request_id),
        };
    }

    fn handleNamedRequest(
        self: Runner,
        allocator: std.mem.Allocator,
        request: ipc.protocol.CommandRequest,
    ) !ipc.protocol.Response {
        const target = request.targetLabel();
        if (target.len == 0) return errorResponse(allocator, request.request_id, "missing process name");

        const target_process = self.state.getProcessByLabel(target) orelse {
            const message = try std.fmt.allocPrint(allocator, "process not found: {s}", .{target});
            defer allocator.free(message);
            return errorResponse(allocator, request.request_id, message);
        };

        self.handleNamedProcess(request.action, target_process) catch |err| {
            return errorResponse(allocator, request.request_id, @errorName(err));
        };
        return successResponse(allocator, request.request_id);
    }

    fn handleNamedProcess(
        self: Runner,
        action: ipc.protocol.Command,
        target_process: *domain.process.Process,
    ) !void {
        switch (action) {
            .switch_process => self.setCurrentProcess(target_process.id),
            .start => try self.startProcess(target_process),
            .stop => try self.stopProcess(target_process),
            .restart => {
                try self.stopProcess(target_process);
                std.Thread.sleep(500 * std.time.ns_per_ms);
                try self.startProcess(target_process);
            },
            else => return error.UnsupportedCommand,
        }
    }

    fn startProcess(self: Runner, target_process: *domain.process.Process) !void {
        if (self.controller.isRunning(target_process.id)) return;
        try self.controller.cleanupProcess(target_process.id);
        if (self.currentProcessID().isNone()) self.setCurrentProcess(target_process.id);
        _ = try self.controller.startProcess(target_process.id, target_process.config);
    }

    fn stopProcess(self: Runner, target_process: *domain.process.Process) !void {
        if (!self.controller.isRunning(target_process.id)) return;
        try self.controller.stopProcess(target_process.id);
    }

    fn stopRunningResponse(self: Runner, allocator: std.mem.Allocator, request_id: u64) !ipc.protocol.Response {
        var stop_runs = std.array_list.Managed(StopProcessRun).init(allocator);
        defer stop_runs.deinit();

        for (self.state.processes.items) |*target_process| {
            if (self.controller.isRunning(target_process.id)) {
                try stop_runs.append(.{
                    .controller = self.controller,
                    .id = target_process.id,
                    .label = target_process.label,
                });
            }
        }

        // Shutdown should make best effort across all processes; one stubborn
        // process must not prevent stop attempts for the rest.
        stopProcessesConcurrently(allocator, stop_runs.items);
        reportStopFailures(stop_runs.items);

        return successResponse(allocator, request_id);
    }

    fn restartRunningResponse(self: Runner, allocator: std.mem.Allocator, request_id: u64) !ipc.protocol.Response {
        for (self.state.processes.items) |*target_process| {
            if (self.controller.isRunning(target_process.id)) {
                try self.controller.stopProcess(target_process.id);
                std.Thread.sleep(500 * std.time.ns_per_ms);
                _ = try self.controller.startProcess(target_process.id, target_process.config);
            }
        }
        return successResponse(allocator, request_id);
    }

    fn currentProcessID(self: Runner) domain.process.ProcessId {
        return domain.process.ProcessId.fromInt(self.current_process_id.load(.seq_cst));
    }

    fn setCurrentProcess(self: Runner, id: domain.process.ProcessId) void {
        self.state.current_proc_id = id;
        self.current_process_id.store(id.toInt(), .seq_cst);
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

fn successResponse(allocator: std.mem.Allocator, request_id: u64) !ipc.protocol.Response {
    return .{
        .request_id = request_id,
        .success = true,
        .error_message = try allocator.dupe(u8, ""),
    };
}

fn errorResponse(
    allocator: std.mem.Allocator,
    request_id: u64,
    message: []const u8,
) !ipc.protocol.Response {
    return .{
        .request_id = request_id,
        .success = false,
        .error_message = try allocator.dupe(u8, message),
    };
}

const std = @import("std");
const domain = @import("../domain/root.zig");
const line_io = @import("../ipc/line.zig");
const protocol = @import("../ipc/protocol.zig");
const server = @import("../ipc/server.zig");

pub const emptySnapshotLine =
    "{\"type\":\"snapshot\",\"protocol_version\":1,\"current_process_id\":0,\"exiting\":false,\"ui\":{},\"processes\":[]}\n";

pub const apiWorkerSnapshotLine =
    "{\"type\":\"snapshot\",\"protocol_version\":1,\"current_process_id\":1,\"exiting\":false,\"ui\":{},\"processes\":[{\"id\":1,\"label\":\"api\",\"status\":\"running\",\"pid\":123,\"description\":\"\",\"docs\":\"\",\"categories\":[]},{\"id\":2,\"label\":\"worker\",\"status\":\"halted\",\"pid\":-1,\"description\":\"\",\"docs\":\"\",\"categories\":[]}]}\n";

pub const selectedApiSnapshotLine =
    "{\"type\":\"snapshot\",\"protocol_version\":1,\"current_process_id\":2,\"exiting\":false,\"ui\":{},\"processes\":[{\"id\":2,\"label\":\"api\",\"status\":\"running\",\"pid\":1002,\"description\":\"\",\"docs\":\"\",\"categories\":[]}]}\n";

pub fn snapshotLineFromAppState(
    allocator: std.mem.Allocator,
    app_state: *const domain.state.AppState,
    controller: domain.process.ProcessController,
) ![]const u8 {
    var snapshot = try domain.client_snapshot.fromAppState(allocator, app_state, controller);
    defer snapshot.deinit(allocator);
    return protocol.snapshotLine(allocator, snapshot.view());
}

pub const FakeProcessController = struct {
    status: domain.process.ProcessStatus = .halted,
    pid: i32 = -1,
    running_id: ?domain.process.ProcessId = null,

    pub fn controller(self: *FakeProcessController) domain.process.ProcessController {
        return .{
            .context = self,
            .get_process_status = getProcessStatus,
            .get_pid = getPID,
        };
    }

    fn getProcessStatus(context: *anyopaque, id: domain.process.ProcessId) domain.process.ProcessStatus {
        const self: *FakeProcessController = @ptrCast(@alignCast(context));
        if (self.running_id) |running_id| {
            return if (id == running_id) .running else .halted;
        }
        return self.status;
    }

    fn getPID(context: *anyopaque, id: domain.process.ProcessId) i32 {
        const self: *FakeProcessController = @ptrCast(@alignCast(context));
        if (self.running_id) |running_id| {
            if (id != running_id) return -1;
            return if (self.pid >= 0) self.pid else @intCast(1000 + id.toInt());
        }
        return self.pid;
    }
};

pub const FakeCommandHandler = struct {
    action: protocol.Command = .start,
    label_buf: [64]u8 = undefined,
    label_len: usize = 0,
    call_count: usize = 0,

    pub fn handler(self: *FakeCommandHandler) server.CommandHandler {
        return .{
            .context = self,
            .handle = handle,
        };
    }

    pub fn label(self: *const FakeCommandHandler) []const u8 {
        return self.label_buf[0..self.label_len];
    }

    fn handle(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request: protocol.CommandRequest,
    ) anyerror!protocol.Response {
        const self: *FakeCommandHandler = @ptrCast(@alignCast(context));
        self.action = request.action;
        self.call_count += 1;
        const target = request.targetLabel();
        @memcpy(self.label_buf[0..target.len], target);
        self.label_len = target.len;

        return .{
            .request_id = request.request_id,
            .success = true,
            .error_message = try allocator.dupe(u8, ""),
        };
    }
};

pub const FakeSnapshotProvider = struct {
    line: []const u8 = emptySnapshotLine,

    pub fn provider(self: *FakeSnapshotProvider) server.SnapshotProvider {
        return .{
            .context = self,
            .snapshot_line = snapshotLine,
        };
    }

    fn snapshotLine(context: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *FakeSnapshotProvider = @ptrCast(@alignCast(context));
        return allocator.dupe(u8, self.line);
    }
};

pub const FakePeerAuthorizer = struct {
    err: ?anyerror = null,
    called: bool = false,
    fd: std.posix.fd_t = -1,

    pub fn authorizer(self: *FakePeerAuthorizer) server.PeerAuthorizer {
        return .{
            .context = self,
            .authorize = authorize,
        };
    }

    fn authorize(context: *anyopaque, fd: std.posix.fd_t) anyerror!void {
        const self: *FakePeerAuthorizer = @ptrCast(@alignCast(context));
        self.called = true;
        self.fd = fd;
        if (self.err) |err| return err;
    }
};

pub const ServerErrorCapture = struct {
    err: ?anyerror = null,
};

pub const successResponseLine =
    "{\"type\":\"response\",\"protocol_version\":1,\"request_id\":1,\"success\":true,\"error\":\"\"}\n";

pub const CommandCapture = struct {
    request: [512]u8 = undefined,
    request_len: usize = 0,
    response: []const u8 = successResponseLine,
    err: ?anyerror = null,

    pub fn requestLine(self: *const CommandCapture) []const u8 {
        return self.request[0..self.request_len];
    }
};

pub fn runResponseCaptureServer(listener: *std.net.Server, capture: *CommandCapture) void {
    const conn = listener.accept() catch |err| {
        capture.err = err;
        return;
    };
    defer conn.stream.close();

    capture.request_len = conn.stream.read(&capture.request) catch |err| {
        capture.err = err;
        return;
    };

    conn.stream.writeAll(capture.response) catch |err| {
        capture.err = err;
        return;
    };
}

pub fn runSnapshotLineServer(
    listener: *std.net.Server,
    result: *ServerErrorCapture,
    line: []const u8,
    count: usize,
) void {
    var served: usize = 0;
    while (served < count) : (served += 1) {
        const conn = listener.accept() catch |err| {
            result.err = err;
            return;
        };
        conn.stream.writeAll(line) catch {};
        conn.stream.close();
    }
}

pub fn unblockServer(path: []const u8) void {
    var stream = std.net.connectUnixSocket(path) catch return;
    stream.close();
}

pub fn waitForSocketFile(path: []const u8) void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        std.fs.accessAbsolute(path, .{}) catch {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            continue;
        };
        return;
    }
}

pub fn readLine(allocator: std.mem.Allocator, stream: std.net.Stream) ![]const u8 {
    return line_io.read(allocator, stream, 1024 * 1024);
}

pub fn readLineTimeout(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    timeout_ms: i32,
) ![]const u8 {
    return line_io.readTimeout(allocator, stream, 1024 * 1024, timeout_ms);
}

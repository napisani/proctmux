const std = @import("std");
const domain = @import("../domain/root.zig");
const line_io = @import("../ipc/line.zig");
const protocol = @import("../ipc/protocol.zig");
const server = @import("../ipc/server.zig");

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
            return if (id == running_id) @intCast(1000 + id.toInt()) else -1;
        }
        return self.pid;
    }
};

pub const FakeCommandHandler = struct {
    action: protocol.Command = .list,
    label_buf: [64]u8 = undefined,
    label_len: usize = 0,
    call_count: usize = 0,
    include_process_list: bool = true,

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
        @memcpy(self.label_buf[0..request.label.len], request.label);
        self.label_len = request.label.len;

        const process_list = if (self.include_process_list)
            try oneItemProcessList(allocator, request.label)
        else
            try allocator.alloc(protocol.ProcessListItem, 0);
        errdefer deinitProcessList(allocator, process_list);

        return .{
            .request_id = try allocator.dupe(u8, request.request_id),
            .success = true,
            .error_message = try allocator.dupe(u8, ""),
            .process_list = process_list,
        };
    }
};

pub const FakeStateProvider = struct {
    line: []const u8 = "{\"type\":\"state\",\"state\":{\"CurrentProcID\":0},\"process_views\":[]}\n",

    pub fn provider(self: *FakeStateProvider) server.StateProvider {
        return .{
            .context = self,
            .state_line = stateLine,
        };
    }

    fn stateLine(context: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *FakeStateProvider = @ptrCast(@alignCast(context));
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

fn oneItemProcessList(
    allocator: std.mem.Allocator,
    label: []const u8,
) ![]protocol.ProcessListItem {
    const process_list = try allocator.alloc(protocol.ProcessListItem, 1);
    errdefer allocator.free(process_list);
    process_list[0] = .{
        .name = try allocator.dupe(u8, label),
        .running = true,
        .index = 1,
    };
    return process_list;
}

fn deinitProcessList(allocator: std.mem.Allocator, items: []protocol.ProcessListItem) void {
    for (items) |item| item.deinit(allocator);
    allocator.free(items);
}

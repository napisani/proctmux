const std = @import("std");
const domain = @import("../domain/root.zig");
const ring = @import("../ring/root.zig");

const clear_sequence = "\x1b[2J\x1b[H";
const default_placeholder = "Select a process to stream output.";

pub const ProcessRef = struct {
    id: domain.process.ProcessId,
    pid: i32,
    scrollback: *ring.RingBuffer,
};

pub const ProcessProvider = struct {
    context: *anyopaque,
    get: *const fn (context: *anyopaque, id: domain.process.ProcessId) ?ProcessRef,

    pub fn getProcess(self: ProcessProvider, id: domain.process.ProcessId) ?ProcessRef {
        return self.get(self.context, id);
    }
};

pub const Output = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,

    pub fn writeAll(self: Output, bytes: []const u8) !void {
        try self.write(self.context, bytes);
    }
};

pub const Viewer = struct {
    allocator: std.mem.Allocator,
    provider: ProcessProvider,
    output: Output,
    current_process_id: domain.process.ProcessId = .none,
    current_reader_id: ?usize = null,
    current_scrollback: ?*ring.RingBuffer = null,
    placeholder: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, provider: ProcessProvider, output: Output) Viewer {
        return .{
            .allocator = allocator,
            .provider = provider,
            .output = output,
        };
    }

    pub fn deinit(self: *Viewer) void {
        self.removeCurrentReader();
    }

    pub fn setPlaceholder(self: *Viewer, text: []const u8) void {
        self.placeholder = text;
    }

    pub fn currentProcessID(self: Viewer) domain.process.ProcessId {
        return self.current_process_id;
    }

    pub fn switchToProcess(self: *Viewer, process_id: domain.process.ProcessId) !void {
        try self.switchToProcessInternal(process_id, false);
    }

    pub fn refreshCurrentProcess(self: *Viewer) !void {
        if (self.current_process_id.isNone()) return;
        try self.switchToProcessInternal(self.current_process_id, true);
    }

    pub fn relayPending(self: *Viewer) !void {
        const reader_id = self.current_reader_id orelse return;
        const scrollback = self.current_scrollback orelse return;

        while (scrollback.readNext(reader_id)) |data| {
            defer self.allocator.free(data);
            try self.output.writeAll(data);
        }
    }

    fn switchToProcessInternal(self: *Viewer, process_id: domain.process.ProcessId, force: bool) !void {
        if (self.current_process_id == process_id and !force) return;

        self.removeCurrentReader();
        self.current_process_id = process_id;

        if (process_id.isNone()) {
            try self.output.writeAll(clear_sequence);
            try self.writePlaceholder();
            return;
        }

        const proc = self.provider.getProcess(process_id) orelse return;
        const sub = try proc.scrollback.snapshotAndSubscribe(self.allocator);
        defer self.allocator.free(sub.snapshot);

        self.current_reader_id = sub.reader_id;
        self.current_scrollback = proc.scrollback;

        try self.output.writeAll(clear_sequence);
        if (sub.snapshot.len > 0) try self.output.writeAll(sub.snapshot);
    }

    fn writePlaceholder(self: *Viewer) !void {
        const text = std.mem.trim(u8, self.placeholder, " \t\r\n");
        if (text.len == 0) {
            try self.output.writeAll(default_placeholder);
        } else {
            try self.output.writeAll(text);
        }
        try self.output.writeAll("\n");
    }

    fn removeCurrentReader(self: *Viewer) void {
        if (self.current_reader_id) |reader_id| {
            if (self.current_scrollback) |scrollback| {
                scrollback.removeReader(reader_id);
            }
        }
        self.current_reader_id = null;
        self.current_scrollback = null;
    }
};

test "viewer switch writes clear sequence and process scrollback" {
    var store = TestStore.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.add(1, 4242, "existing output\n");

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    var viewer = Viewer.init(std.testing.allocator, TestStore.provider(&store), TestOutput.writer(&out));
    defer viewer.deinit();

    try viewer.switchToProcess(domain.process.ProcessId.fromInt(1));

    try std.testing.expectEqual(domain.process.ProcessId.fromInt(1), viewer.currentProcessID());
    try std.testing.expectEqualStrings("\x1b[2J\x1b[Hexisting output\n", out.items);
}

test "viewer live relay follows only the current process reader" {
    var store = TestStore.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.add(1, 111, "first\n");
    _ = try store.add(2, 222, "second\n");
    const first = store.scrollback(1) orelse return error.ExpectedProcess;
    const second = store.scrollback(2) orelse return error.ExpectedProcess;

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    var viewer = Viewer.init(std.testing.allocator, TestStore.provider(&store), TestOutput.writer(&out));
    defer viewer.deinit();

    try viewer.switchToProcess(domain.process.ProcessId.fromInt(1));
    _ = first.write("first live\n");
    try viewer.relayPending();
    try std.testing.expect(std.mem.indexOf(u8, out.items, "first live\n") != null);

    out.clearRetainingCapacity();
    try viewer.switchToProcess(domain.process.ProcessId.fromInt(2));
    _ = first.write("old hidden\n");
    _ = second.write("second live\n");
    try viewer.relayPending();

    try std.testing.expect(std.mem.indexOf(u8, out.items, "second live\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "old hidden\n") == null);
}

test "viewer process zero renders placeholder" {
    var store = TestStore.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.add(1, 111, "active\n");

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    var viewer = Viewer.init(std.testing.allocator, TestStore.provider(&store), TestOutput.writer(&out));
    defer viewer.deinit();
    viewer.setPlaceholder("No process selected");

    try viewer.switchToProcess(domain.process.ProcessId.fromInt(1));
    out.clearRetainingCapacity();
    try viewer.switchToProcess(.none);

    try std.testing.expectEqualStrings("\x1b[2J\x1b[HNo process selected\n", out.items);
}

test "viewer refresh resends current process scrollback" {
    var store = TestStore.init(std.testing.allocator);
    defer store.deinit();
    const proc = try store.add(1, 111, "initial\n");

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    var viewer = Viewer.init(std.testing.allocator, TestStore.provider(&store), TestOutput.writer(&out));
    defer viewer.deinit();

    try viewer.switchToProcess(domain.process.ProcessId.fromInt(1));
    out.clearRetainingCapacity();
    _ = proc.write("after\n");
    try viewer.refreshCurrentProcess();

    try std.testing.expectEqualStrings("\x1b[2J\x1b[Hinitial\nafter\n", out.items);
}

const TestProcess = struct {
    id: domain.process.ProcessId,
    pid: i32,
    scrollback: ring.RingBuffer,

    fn deinit(self: *TestProcess) void {
        self.scrollback.deinit();
    }
};

const TestStore = struct {
    allocator: std.mem.Allocator,
    processes: std.array_list.Managed(TestProcess),

    fn init(allocator: std.mem.Allocator) TestStore {
        return .{
            .allocator = allocator,
            .processes = std.array_list.Managed(TestProcess).init(allocator),
        };
    }

    fn deinit(self: *TestStore) void {
        for (self.processes.items) |*proc| proc.deinit();
        self.processes.deinit();
    }

    fn add(self: *TestStore, id: u32, pid: i32, initial_output: []const u8) !*ring.RingBuffer {
        var rb = try ring.RingBuffer.init(self.allocator, 1024);
        errdefer rb.deinit();
        _ = rb.write(initial_output);

        try self.processes.append(.{
            .id = domain.process.ProcessId.fromInt(id),
            .pid = pid,
            .scrollback = rb,
        });
        return &self.processes.items[self.processes.items.len - 1].scrollback;
    }

    fn scrollback(self: *TestStore, id: u32) ?*ring.RingBuffer {
        const process_id = domain.process.ProcessId.fromInt(id);
        for (self.processes.items) |*proc| {
            if (proc.id == process_id) return &proc.scrollback;
        }
        return null;
    }

    fn provider(self: *TestStore) ProcessProvider {
        return .{
            .context = self,
            .get = getProcess,
        };
    }

    fn getProcess(context: *anyopaque, id: domain.process.ProcessId) ?ProcessRef {
        const self: *TestStore = @ptrCast(@alignCast(context));
        for (self.processes.items) |*proc| {
            if (proc.id == id) {
                return .{
                    .id = proc.id,
                    .pid = proc.pid,
                    .scrollback = &proc.scrollback,
                };
            }
        }
        return null;
    }
};

const TestOutput = struct {
    fn writer(out: *std.array_list.Managed(u8)) Output {
        return .{
            .context = out,
            .write = write,
        };
    }

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const out: *std.array_list.Managed(u8) = @ptrCast(@alignCast(context));
        try out.appendSlice(bytes);
    }
};

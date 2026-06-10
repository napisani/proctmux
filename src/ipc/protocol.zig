const std = @import("std");
const domain = @import("../domain/root.zig");

pub const current_protocol_version: u32 = 1;

pub const CommandNameError = error{UnknownCommand};
pub const DecodeError = error{
    InvalidMessageType,
    UnsupportedProtocolVersion,
} || CommandNameError || std.mem.Allocator.Error || std.json.ParseError(std.json.Scanner) || std.json.ParseFromValueError;

pub const EncodeError = std.mem.Allocator.Error || std.Io.Writer.Error;

pub const Command = enum {
    start,
    stop,
    restart,
    switch_process,
    restart_running,
    stop_running,
};

pub const CommandRequest = struct {
    request_id: u64,
    action: Command,
    target: ?[]const u8 = null,

    pub fn targetLabel(self: CommandRequest) []const u8 {
        return self.target orelse "";
    }

    pub fn requiresTarget(self: CommandRequest) bool {
        return commandRequiresTarget(self.action);
    }
};

pub const Response = struct {
    request_id: u64,
    success: bool,
    error_message: []const u8,

    pub fn deinit(self: *const Response, allocator: std.mem.Allocator) void {
        allocator.free(self.error_message);
    }
};

pub const SnapshotUpdate = struct {
    parsed: std.json.Parsed(SnapshotMessage),
    snapshot_value: domain.client_snapshot.ClientSnapshot,

    pub fn deinit(self: *SnapshotUpdate) void {
        self.parsed.deinit();
    }

    pub fn snapshot(self: *const SnapshotUpdate) *const domain.client_snapshot.ClientSnapshot {
        return &self.snapshot_value;
    }
};

pub const Message = union(enum) {
    snapshot: SnapshotUpdate,
    command: CommandRequest,
    response: Response,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .snapshot => |*snapshot| snapshot.deinit(),
            .command => |request| deinitCommandRequest(allocator, request),
            .response => |*response| response.deinit(allocator),
        }
    }
};

const MessageType = enum {
    snapshot,
    command,
    response,
};

const Header = struct {
    type: []const u8,
    protocol_version: u32 = 0,
};

const SnapshotMessage = struct {
    type: []const u8 = "snapshot",
    protocol_version: u32 = current_protocol_version,
    current_process_id: u32 = 0,
    exiting: bool = false,
    ui: domain.client_snapshot.UiConfig = .{},
    processes: []const domain.client_snapshot.ProcessSummary = &.{},

    fn toSnapshot(self: SnapshotMessage) domain.client_snapshot.ClientSnapshot {
        return .{
            .current_process_id = self.current_process_id,
            .exiting = self.exiting,
            .ui = self.ui,
            .processes = self.processes,
        };
    }
};

const CommandMessage = struct {
    type: []const u8 = "command",
    protocol_version: u32 = current_protocol_version,
    request_id: u64,
    action: []const u8,
    target: ?[]const u8 = null,
};

const ResponseMessage = struct {
    type: []const u8 = "response",
    protocol_version: u32 = current_protocol_version,
    request_id: u64,
    success: bool,
    @"error": []const u8 = "",
};

pub fn commandName(command: Command) []const u8 {
    return switch (command) {
        .start => "start",
        .stop => "stop",
        .restart => "restart",
        .switch_process => "switch",
        .restart_running => "restart_running",
        .stop_running => "stop_running",
    };
}

pub fn commandFromName(name: []const u8) CommandNameError!Command {
    if (std.mem.eql(u8, name, "start")) return .start;
    if (std.mem.eql(u8, name, "stop")) return .stop;
    if (std.mem.eql(u8, name, "restart")) return .restart;
    if (std.mem.eql(u8, name, "switch")) return .switch_process;
    if (std.mem.eql(u8, name, "restart_running")) return .restart_running;
    if (std.mem.eql(u8, name, "stop_running")) return .stop_running;
    return error.UnknownCommand;
}

pub fn commandRequiresTarget(command: Command) bool {
    return switch (command) {
        .start, .stop, .restart, .switch_process => true,
        .restart_running, .stop_running => false,
    };
}

pub fn commandRequiresSelectedProcess(command: Command) bool {
    return switch (command) {
        .start, .stop, .restart => true,
        .switch_process, .restart_running, .stop_running => false,
    };
}

pub fn commandNeedsImmediateSnapshotSync(command: Command) bool {
    return switch (command) {
        .start, .stop, .restart, .restart_running => true,
        .switch_process, .stop_running => false,
    };
}

pub fn commandShouldRenderImmediately(command: Command) bool {
    return command == .switch_process;
}

pub fn decodeLine(allocator: std.mem.Allocator, line: []const u8) DecodeError!Message {
    return switch (try messageType(allocator, line)) {
        .snapshot => .{ .snapshot = try parseSnapshotLine(allocator, line) },
        .command => .{ .command = try parseCommandRequestLine(allocator, line) },
        .response => .{ .response = try parseResponseLine(allocator, line) },
    };
}

pub fn snapshotLine(
    allocator: std.mem.Allocator,
    snapshot: *const domain.client_snapshot.ClientSnapshot,
) EncodeError![]const u8 {
    return jsonLine(allocator, SnapshotMessage{
        .current_process_id = snapshot.current_process_id,
        .exiting = snapshot.exiting,
        .ui = snapshot.ui,
        .processes = snapshot.processes,
    });
}

pub fn parseSnapshotLine(allocator: std.mem.Allocator, line: []const u8) DecodeError!SnapshotUpdate {
    try validateHeader(allocator, line, .snapshot);
    const parsed = try std.json.parseFromSlice(SnapshotMessage, allocator, line, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    });
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, "snapshot")) return error.InvalidMessageType;
    if (parsed.value.protocol_version != current_protocol_version) return error.UnsupportedProtocolVersion;
    const snapshot_value = parsed.value.toSnapshot();
    return .{ .parsed = parsed, .snapshot_value = snapshot_value };
}

pub fn commandRequestLine(
    allocator: std.mem.Allocator,
    request_id: u64,
    action: Command,
    target: ?[]const u8,
) EncodeError![]const u8 {
    return jsonLine(allocator, CommandMessage{
        .request_id = request_id,
        .action = commandName(action),
        .target = target,
    });
}

pub fn parseCommandRequestLine(allocator: std.mem.Allocator, line: []const u8) DecodeError!CommandRequest {
    try validateHeader(allocator, line, .command);
    var parsed = try std.json.parseFromSlice(CommandMessage, allocator, line, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, "command")) return error.InvalidMessageType;
    if (parsed.value.protocol_version != current_protocol_version) return error.UnsupportedProtocolVersion;

    const target = if (parsed.value.target) |value| try allocator.dupe(u8, value) else null;
    errdefer if (target) |value| allocator.free(value);

    return .{
        .request_id = parsed.value.request_id,
        .action = try commandFromName(parsed.value.action),
        .target = target,
    };
}

pub fn responseLine(allocator: std.mem.Allocator, response: Response) EncodeError![]const u8 {
    return jsonLine(allocator, ResponseMessage{
        .request_id = response.request_id,
        .success = response.success,
        .@"error" = response.error_message,
    });
}

pub fn parseResponseLine(allocator: std.mem.Allocator, line: []const u8) DecodeError!Response {
    try validateHeader(allocator, line, .response);
    var parsed = try std.json.parseFromSlice(ResponseMessage, allocator, line, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, "response")) return error.InvalidMessageType;
    if (parsed.value.protocol_version != current_protocol_version) return error.UnsupportedProtocolVersion;

    return .{
        .request_id = parsed.value.request_id,
        .success = parsed.value.success,
        .error_message = try allocator.dupe(u8, parsed.value.@"error"),
    };
}

pub fn deinitCommandRequest(allocator: std.mem.Allocator, request: CommandRequest) void {
    if (request.target) |target| allocator.free(target);
}

fn jsonLine(allocator: std.mem.Allocator, value: anytype) EncodeError![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.writer().print("{f}\n", .{std.json.fmt(value, .{ .emit_null_optional_fields = false })});
    return out.toOwnedSlice();
}

fn messageType(allocator: std.mem.Allocator, line: []const u8) DecodeError!MessageType {
    var parsed = try std.json.parseFromSlice(Header, allocator, line, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (parsed.value.protocol_version != current_protocol_version) return error.UnsupportedProtocolVersion;
    if (std.mem.eql(u8, parsed.value.type, "snapshot")) return .snapshot;
    if (std.mem.eql(u8, parsed.value.type, "command")) return .command;
    if (std.mem.eql(u8, parsed.value.type, "response")) return .response;
    return error.InvalidMessageType;
}

fn validateHeader(allocator: std.mem.Allocator, line: []const u8, expected_type: MessageType) DecodeError!void {
    if (try messageType(allocator, line) != expected_type) return error.InvalidMessageType;
}

test "protocol encodes and decodes snapshot messages" {
    const snapshot = domain.client_snapshot.ClientSnapshot{
        .current_process_id = 1,
        .ui = .{
            .keybinding = .{ .quit = &.{ "q", "ctrl+c" } },
            .layout = .{ .category_search_prefix = "cat:", .placeholder_banner = "READY" },
            .style = .{ .pointer_char = ">", .status_running_color = "green" },
        },
        .processes = &.{.{
            .id = 1,
            .label = "api",
            .status = .running,
            .pid = 12345,
            .description = "API server",
            .categories = &.{"backend"},
        }},
    };

    const line = try snapshotLine(std.testing.allocator, &snapshot);
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.startsWith(u8, line, "{\"type\":\"snapshot\",\"protocol_version\":1"));
    var parsed = try parseSnapshotLine(std.testing.allocator, line);
    defer parsed.deinit();

    const decoded = parsed.snapshot();
    try std.testing.expectEqual(@as(u32, 1), decoded.current_process_id);
    try std.testing.expectEqual(@as(usize, 1), decoded.processes.len);
    try std.testing.expectEqualStrings("api", decoded.processes[0].label);
    try std.testing.expectEqual(domain.process.ProcessStatus.running, decoded.processes[0].status);
    try std.testing.expectEqualStrings("backend", decoded.processes[0].categories[0]);
}

test "protocol snapshot excludes process execution and log fields" {
    const snapshot = domain.client_snapshot.ClientSnapshot{
        .processes = &.{.{ .id = 1, .label = "api" }},
    };
    const line = try snapshotLine(std.testing.allocator, &snapshot);
    defer std.testing.allocator.free(line);

    const forbidden = [_][]const u8{
        "\"env\"",
        "\"shell\"",
        "\"cmd\"",
        "\"cwd\"",
        "\"on_kill\"",
        "\"log_file\"",
        "\"stdout_debug_log_file\"",
    };
    for (forbidden) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, line, needle) == null);
    }
}

test "protocol owns process command semantics" {
    try std.testing.expect(commandRequiresTarget(.start));
    try std.testing.expect(commandRequiresTarget(.switch_process));
    try std.testing.expect(!commandRequiresTarget(.stop_running));

    try std.testing.expect(commandRequiresSelectedProcess(.start));
    try std.testing.expect(!commandRequiresSelectedProcess(.switch_process));
    try std.testing.expect(!commandRequiresSelectedProcess(.stop_running));

    try std.testing.expect(commandNeedsImmediateSnapshotSync(.restart));
    try std.testing.expect(!commandNeedsImmediateSnapshotSync(.switch_process));
    try std.testing.expect(commandShouldRenderImmediately(.switch_process));
    try std.testing.expect(!commandShouldRenderImmediately(.restart));
}

test "protocol encodes and decodes command requests" {
    const line = try commandRequestLine(std.testing.allocator, 42, .start, "api");
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings(
        "{\"type\":\"command\",\"protocol_version\":1,\"request_id\":42,\"action\":\"start\",\"target\":\"api\"}\n",
        line,
    );

    const parsed = try parseCommandRequestLine(std.testing.allocator, line);
    defer deinitCommandRequest(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(u64, 42), parsed.request_id);
    try std.testing.expectEqual(Command.start, parsed.action);
    try std.testing.expectEqualStrings("api", parsed.target.?);
}

test "protocol encodes targetless commands without null target" {
    const line = try commandRequestLine(std.testing.allocator, 7, .stop_running, null);
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings(
        "{\"type\":\"command\",\"protocol_version\":1,\"request_id\":7,\"action\":\"stop_running\"}\n",
        line,
    );
}

test "protocol encodes and decodes responses" {
    const line = try responseLine(std.testing.allocator, .{
        .request_id = 99,
        .success = false,
        .error_message = "process not found: api",
    });
    defer std.testing.allocator.free(line);

    var parsed = try parseResponseLine(std.testing.allocator, line);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 99), parsed.request_id);
    try std.testing.expect(!parsed.success);
    try std.testing.expectEqualStrings("process not found: api", parsed.error_message);
}

test "protocol decodes any message through one interface" {
    const line = try commandRequestLine(std.testing.allocator, 11, .restart, "api");
    defer std.testing.allocator.free(line);

    var message = try decodeLine(std.testing.allocator, line);
    defer message.deinit(std.testing.allocator);

    switch (message) {
        .command => |request| {
            try std.testing.expectEqual(@as(u64, 11), request.request_id);
            try std.testing.expectEqual(Command.restart, request.action);
            try std.testing.expectEqualStrings("api", request.target.?);
        },
        else => return error.ExpectedCommandMessage,
    }
}

test "protocol rejects unsupported protocol versions unknown actions and unknown message types" {
    try std.testing.expectError(
        error.UnsupportedProtocolVersion,
        parseCommandRequestLine(std.testing.allocator,
            \\{"type":"command","protocol_version":999,"request_id":1,"action":"start","target":"api"}
        ),
    );
    try std.testing.expectError(
        error.UnknownCommand,
        parseCommandRequestLine(std.testing.allocator,
            \\{"type":"command","protocol_version":1,"request_id":1,"action":"dance","target":"api"}
        ),
    );
    try std.testing.expectError(
        error.InvalidMessageType,
        decodeLine(std.testing.allocator,
            \\{"type":"event","protocol_version":1}
        ),
    );
    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        decodeLine(std.testing.allocator,
            \\{"type":"command","protocol_version":1,
        ),
    );
}

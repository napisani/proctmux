const std = @import("std");

pub const CommandNameError = error{UnknownCommand};
pub const CommandFormatError = std.mem.Allocator.Error;
pub const CommandParseError =
    error{InvalidCommandRequest} ||
    CommandNameError ||
    std.mem.Allocator.Error ||
    std.json.ParseError(std.json.Scanner);
pub const ResponseFormatError = std.mem.Allocator.Error;
pub const ResponseParseError =
    error{InvalidResponse} ||
    std.mem.Allocator.Error ||
    std.json.ParseError(std.json.Scanner);

pub const Command = enum {
    start,
    stop,
    restart,
    switch_process,
    restart_running,
    stop_running,
    list,
};

pub const Response = struct {
    request_id: []const u8,
    success: bool,
    error_message: []const u8,
    process_list: []ProcessListItem,

    pub fn deinit(self: *const Response, allocator: std.mem.Allocator) void {
        allocator.free(self.request_id);
        allocator.free(self.error_message);
        for (self.process_list) |item| item.deinit(allocator);
        allocator.free(self.process_list);
    }
};

pub const CommandRequest = struct {
    request_id: []const u8,
    action: Command,
    label: []const u8,

    pub fn deinit(self: *const CommandRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.request_id);
        allocator.free(self.label);
    }
};

pub const ProcessListItem = struct {
    name: []const u8,
    running: bool,
    index: i64,

    pub fn deinit(self: ProcessListItem, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub fn commandName(command: Command) []const u8 {
    return switch (command) {
        .start => "start",
        .stop => "stop",
        .restart => "restart",
        .switch_process => "switch",
        .restart_running => "restart-running",
        .stop_running => "stop-running",
        .list => "list",
    };
}

pub fn commandFromName(name: []const u8) CommandNameError!Command {
    if (std.mem.eql(u8, name, "start")) return .start;
    if (std.mem.eql(u8, name, "stop")) return .stop;
    if (std.mem.eql(u8, name, "restart")) return .restart;
    if (std.mem.eql(u8, name, "switch")) return .switch_process;
    if (std.mem.eql(u8, name, "restart-running")) return .restart_running;
    if (std.mem.eql(u8, name, "stop-running")) return .stop_running;
    if (std.mem.eql(u8, name, "list")) return .list;
    return error.UnknownCommand;
}

pub fn commandRequestLine(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    action: Command,
    label: []const u8,
) CommandFormatError![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("{\"type\":\"command\",\"request_id\":");
    try appendJsonString(&buf, request_id);
    if (label.len != 0) {
        try buf.appendSlice(",\"label\":");
        try appendJsonString(&buf, label);
    }
    try buf.appendSlice(",\"action\":");
    try appendJsonString(&buf, commandName(action));
    try buf.appendSlice("}\n");

    return buf.toOwnedSlice();
}

pub fn parseCommandRequestLine(allocator: std.mem.Allocator, line: []const u8) CommandParseError!CommandRequest {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidCommandRequest;
    const obj = parsed.value.object;

    const type_value = obj.get("type") orelse return error.InvalidCommandRequest;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "command")) {
        return error.InvalidCommandRequest;
    }

    const request_id_value = obj.get("request_id") orelse return error.InvalidCommandRequest;
    if (request_id_value != .string) return error.InvalidCommandRequest;

    const action_value = obj.get("action") orelse return error.InvalidCommandRequest;
    if (action_value != .string) return error.InvalidCommandRequest;

    const label = if (obj.get("label")) |label_value| blk: {
        if (label_value != .string) return error.InvalidCommandRequest;
        break :blk label_value.string;
    } else "";

    const request_id = try allocator.dupe(u8, request_id_value.string);
    errdefer allocator.free(request_id);
    const owned_label = try allocator.dupe(u8, label);
    errdefer allocator.free(owned_label);

    return .{
        .request_id = request_id,
        .action = try commandFromName(action_value.string),
        .label = owned_label,
    };
}

pub fn responseLine(allocator: std.mem.Allocator, response: Response) ResponseFormatError![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("{\"type\":\"response\",\"request_id\":");
    try appendJsonString(&buf, response.request_id);

    if (response.process_list.len != 0) {
        try buf.appendSlice(",\"process_list\":[");
        for (response.process_list, 0..) |item, index| {
            if (index != 0) try buf.append(',');
            try buf.writer().print("{{\"index\":{},\"name\":", .{item.index});
            try appendJsonString(&buf, item.name);
            try buf.writer().print(",\"running\":{s}}}", .{if (item.running) "true" else "false"});
        }
        try buf.append(']');
    }

    if (response.error_message.len != 0) {
        try buf.appendSlice(",\"error\":");
        try appendJsonString(&buf, response.error_message);
    }
    if (response.success) try buf.appendSlice(",\"success\":true");
    try buf.appendSlice("}\n");

    return buf.toOwnedSlice();
}

pub fn parseResponseLine(allocator: std.mem.Allocator, line: []const u8) ResponseParseError!Response {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;

    const obj = parsed.value.object;
    const request_id_value = obj.get("request_id") orelse return error.InvalidResponse;
    if (request_id_value != .string) return error.InvalidResponse;

    var success = false;
    if (obj.get("success")) |success_value| {
        if (success_value == .bool) success = success_value.bool;
    }

    const error_message = if (obj.get("error")) |error_value| blk: {
        if (error_value != .string) return error.InvalidResponse;
        break :blk error_value.string;
    } else "";

    var process_items = std.array_list.Managed(ProcessListItem).init(allocator);
    errdefer deinitProcessItems(allocator, &process_items);
    if (obj.get("process_list")) |process_list_value| {
        if (process_list_value != .array) return error.InvalidResponse;
        for (process_list_value.array.items) |item_value| {
            const item = try parseProcessListItem(allocator, item_value);
            process_items.append(item) catch |err| {
                item.deinit(allocator);
                return err;
            };
        }
    }

    const request_id = try allocator.dupe(u8, request_id_value.string);
    errdefer allocator.free(request_id);
    const owned_error_message = try allocator.dupe(u8, error_message);
    errdefer allocator.free(owned_error_message);
    const process_list = try process_items.toOwnedSlice();

    return .{
        .request_id = request_id,
        .success = success,
        .error_message = owned_error_message,
        .process_list = process_list,
    };
}

fn appendJsonString(buf: *std.array_list.Managed(u8), value: []const u8) CommandFormatError!void {
    try buf.writer().print("{f}", .{std.json.fmt(value, .{})});
}

fn parseProcessListItem(allocator: std.mem.Allocator, value: std.json.Value) ResponseParseError!ProcessListItem {
    if (value != .object) return error.InvalidResponse;
    const obj = value.object;

    const name_value = obj.get("name") orelse return error.InvalidResponse;
    if (name_value != .string) return error.InvalidResponse;

    const running_value = obj.get("running") orelse return error.InvalidResponse;
    if (running_value != .bool) return error.InvalidResponse;

    const index_value = obj.get("index") orelse return error.InvalidResponse;
    if (index_value != .integer) return error.InvalidResponse;

    return .{
        .name = try allocator.dupe(u8, name_value.string),
        .running = running_value.bool,
        .index = index_value.integer,
    };
}

fn deinitProcessItems(allocator: std.mem.Allocator, items: *std.array_list.Managed(ProcessListItem)) void {
    for (items.items) |item| item.deinit(allocator);
    items.deinit();
}

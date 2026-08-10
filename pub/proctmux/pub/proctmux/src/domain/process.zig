//! Core process domain types.
//! These types give the rest of the codebase stable IDs, status names, and a narrow ProcessController adapter without exposing concrete process-controller internals.

const std = @import("std");
const config = @import("../config/root.zig");

pub const ProcessStatus = enum(u8) {
    unknown = 0,
    running = 1,
    halting = 2,
    halted = 3,
    exited = 4,
};

/// Stable domain identifier assigned from sorted Project Config order. `none`
/// represents no selection and avoids sentinel integers in callers.
pub const ProcessId = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(value: u32) ProcessId {
        return @enumFromInt(value);
    }

    pub fn toInt(self: ProcessId) u32 {
        return @intFromEnum(self);
    }

    pub fn isNone(self: ProcessId) bool {
        return self == .none;
    }
};

pub fn processIdFromIndex(index: usize) ProcessId {
    return ProcessId.fromInt(@intCast(index + 1));
}

pub fn statusName(status: ProcessStatus) []const u8 {
    return switch (status) {
        .running => "Running",
        .halting => "Halting",
        .halted => "Halted",
        .exited => "Exited",
        .unknown => "Unknown",
    };
}

pub const Process = struct {
    id: ProcessId,
    label: []const u8,
    config: *config.schema.ProcessConfig,
};

pub const ProcessView = struct {
    id: ProcessId,
    label: []const u8,
    status: ProcessStatus = .halted,
    pid: i32 = -1,
    config: *config.schema.ProcessConfig,
};

/// Narrow status adapter used by domain code that needs live process facts
/// without depending on the concrete runtime controller.
pub const ProcessController = struct {
    context: *anyopaque,
    get_process_status: *const fn (context: *anyopaque, id: ProcessId) ProcessStatus,
    get_pid: *const fn (context: *anyopaque, id: ProcessId) i32,

    pub fn getProcessStatus(self: ProcessController, id: ProcessId) ProcessStatus {
        return self.get_process_status(self.context, id);
    }

    pub fn getPID(self: ProcessController, id: ProcessId) i32 {
        return self.get_pid(self.context, id);
    }
};

/// Combines static process config with optional live controller-derived status.
pub fn toView(proc: Process, controller: ?ProcessController) ProcessView {
    const status = if (controller) |ctl| ctl.getProcessStatus(proc.id) else ProcessStatus.halted;
    const pid = if (controller) |ctl| ctl.getPID(proc.id) else -1;
    return .{
        .id = proc.id,
        .label = proc.label,
        .status = status,
        .pid = pid,
        .config = proc.config,
    };
}

pub fn commandString(allocator: std.mem.Allocator, proc_cfg: *const config.schema.ProcessConfig) ![]const u8 {
    if (proc_cfg.shell.len > 0) return allocator.dupe(u8, proc_cfg.shell);
    if (proc_cfg.cmd.items.len == 0) return allocator.dupe(u8, "");

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    for (proc_cfg.cmd.items) |part| {
        try out.append('\'');
        try out.appendSlice(part);
        try out.appendSlice("' ");
    }
    return out.toOwnedSlice();
}

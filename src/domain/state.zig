const std = @import("std");
const config = @import("../config/root.zig");
const process = @import("process.zig");

pub const Mode = enum {
    normal,
    filter,
};

pub const AppState = struct {
    allocator: std.mem.Allocator,
    config: *config.schema.Config,
    processes: std.array_list.Managed(process.Process),
    current_proc_id: u32 = 0,
    exiting: bool = false,

    pub fn init(allocator: std.mem.Allocator, cfg: *config.schema.Config) !AppState {
        var app = AppState{
            .allocator = allocator,
            .config = cfg,
            .processes = std.array_list.Managed(process.Process).init(allocator),
        };
        errdefer app.deinit();

        var keys = try allocator.alloc([]const u8, cfg.procs.count());
        defer allocator.free(keys);
        var it = cfg.procs.iterator();
        var index: usize = 0;
        while (it.next()) |entry| : (index += 1) keys[index] = entry.key_ptr.*;
        std.mem.sort([]const u8, keys, {}, lessThanString);

        for (keys, 0..) |label, i| {
            try app.processes.append(.{
                .id = @intCast(i + 1),
                .label = label,
                .config = cfg.procs.getPtr(label).?,
            });
        }
        return app;
    }

    pub fn deinit(self: *AppState) void {
        self.processes.deinit();
    }

    pub fn getProcessByID(self: *AppState, id: u32) ?*process.Process {
        for (self.processes.items) |*proc| {
            if (proc.id == id) return proc;
        }
        return null;
    }

    pub fn getProcessByLabel(self: *AppState, label: []const u8) ?*process.Process {
        for (self.processes.items) |*proc| {
            if (std.mem.eql(u8, proc.label, label)) return proc;
        }
        return null;
    }
};

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

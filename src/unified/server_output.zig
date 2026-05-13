const std = @import("std");
const domain = @import("../domain/root.zig");
const primary = @import("../primary/root.zig");
const terminal = @import("../terminal/root.zig");
const tui = @import("../tui/root.zig");
const child_primary = @import("child_primary.zig");

pub const Target = union(enum) {
    child: *child_primary.ChildPrimary,
    in_process: *primary.Server,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    target: Target,
    child: ?ChildState = null,
    processes: ProcessMap,

    const ProcessMap = std.AutoHashMap(domain.process.ProcessId, ProcessState);

    const ChildState = struct {
        terminal: terminal.ghostty_vt.Terminal,
        cursor: child_primary.OutputCursor = .{},
        has_output: bool = false,

        fn deinit(self: *ChildState) void {
            self.terminal.deinit();
        }
    };

    const ProcessState = struct {
        terminal: terminal.ghostty_vt.Terminal,
        consumed_len: usize = 0,

        fn deinit(self: *ProcessState) void {
            self.terminal.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator, target: Target) !State {
        return .{
            .allocator = allocator,
            .target = target,
            .processes = ProcessMap.init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        if (self.child) |*child| child.deinit();

        var it = self.processes.valueIterator();
        while (it.next()) |process| process.deinit();
        self.processes.deinit();
    }

    pub fn renderText(
        self: *State,
        split: *const tui.split_model.Model,
        active_proc_id: domain.process.ProcessId,
        placeholder: []const u8,
    ) ![]const u8 {
        const size = split.serverSize();
        const cols = dimension(size.width);
        const rows = dimension(size.height);

        return switch (self.target) {
            .child => |child| self.renderChild(child, cols, rows, placeholder),
            .in_process => |server| self.renderProcess(server, active_proc_id, cols, rows, placeholder),
        };
    }

    fn renderChild(
        self: *State,
        child: *child_primary.ChildPrimary,
        cols: u16,
        rows: u16,
        placeholder: []const u8,
    ) ![]const u8 {
        if (self.child == null) {
            self.child = .{
                .terminal = try terminal.ghostty_vt.Terminal.init(self.allocator, cols, rows),
            };
        }

        var state = &self.child.?;
        try state.terminal.resize(cols, rows);

        const bytes = try child.readSince(self.allocator, &state.cursor);
        defer self.allocator.free(bytes);
        if (bytes.len > 0) {
            state.has_output = true;
            try state.terminal.write(bytes);
        }

        if (!state.has_output) return self.allocator.dupe(u8, placeholder);
        return state.terminal.renderText(self.allocator);
    }

    fn renderProcess(
        self: *State,
        server: *primary.Server,
        active_proc_id: domain.process.ProcessId,
        cols: u16,
        rows: u16,
        placeholder: []const u8,
    ) ![]const u8 {
        if (active_proc_id.isNone()) return self.allocator.dupe(u8, placeholder);

        const scrollback = server.controller.getScrollback(self.allocator, active_proc_id) catch |err| switch (err) {
            error.ProcessNotFound => return self.allocator.dupe(u8, placeholder),
            else => return err,
        };
        defer self.allocator.free(scrollback);
        if (scrollback.len == 0) return self.allocator.dupe(u8, placeholder);

        const entry = try self.processes.getOrPut(active_proc_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .terminal = try terminal.ghostty_vt.Terminal.init(self.allocator, cols, rows),
            };
        }

        var process = entry.value_ptr;
        try process.terminal.resize(cols, rows);

        if (scrollback.len < process.consumed_len) {
            process.terminal.deinit();
            process.* = .{
                .terminal = try terminal.ghostty_vt.Terminal.init(self.allocator, cols, rows),
            };
        }

        if (scrollback.len > process.consumed_len) {
            try process.terminal.write(scrollback[process.consumed_len..]);
            process.consumed_len = scrollback.len;
        }

        return process.terminal.renderText(self.allocator);
    }
};

fn dimension(value: i32) u16 {
    if (value <= 0) return 1;
    return @intCast(@min(value, std.math.maxInt(u16)));
}

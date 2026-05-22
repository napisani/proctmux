const std = @import("std");
const domain = @import("../domain/root.zig");
const primary = @import("../primary/root.zig");
const terminal = @import("../terminal/root.zig");
const tui = @import("../tui/root.zig");
const child_primary = @import("child_primary.zig");

const child_snapshot_reset = "\x1b[2J\x1b[H";

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
        selected_process_id: domain.process.ProcessId,
        pending_snapshot: std.array_list.Managed(u8),
        cursor: child_primary.OutputCursor = .{},
        has_output: bool = false,
        awaiting_snapshot: bool = false,

        fn deinit(self: *ChildState) void {
            self.pending_snapshot.deinit();
            self.terminal.deinit();
        }

        fn resetForProcess(
            self: *ChildState,
            allocator: std.mem.Allocator,
            selected_process_id: domain.process.ProcessId,
            cols: u16,
            rows: u16,
        ) !void {
            const new_terminal = try terminal.ghostty_vt.Terminal.init(allocator, cols, rows);
            self.terminal.deinit();
            self.terminal = new_terminal;
            self.selected_process_id = selected_process_id;
            self.pending_snapshot.clearRetainingCapacity();
            self.has_output = false;
            self.awaiting_snapshot = true;
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
            .child => |child| self.renderChild(child, active_proc_id, cols, rows, placeholder),
            .in_process => |server| self.renderProcess(server, active_proc_id, cols, rows, placeholder),
        };
    }

    pub fn hasPendingOutput(
        self: *State,
        active_proc_id: domain.process.ProcessId,
    ) !bool {
        return switch (self.target) {
            .child => |child| self.hasPendingChildOutput(child, active_proc_id),
            .in_process => |server| self.hasPendingProcessOutput(server, active_proc_id),
        };
    }

    fn hasPendingChildOutput(
        self: *State,
        child: *child_primary.ChildPrimary,
        active_proc_id: domain.process.ProcessId,
    ) bool {
        const state = if (self.child) |*value| value else return true;
        if (state.selected_process_id != active_proc_id) return true;
        return child.outputEndOffset() > state.cursor.offset;
    }

    fn hasPendingProcessOutput(
        self: *State,
        server: *primary.Server,
        active_proc_id: domain.process.ProcessId,
    ) !bool {
        if (active_proc_id.isNone()) return false;

        const scrollback = server.controller.getScrollback(self.allocator, active_proc_id) catch |err| switch (err) {
            error.ProcessNotFound => return false,
            else => return err,
        };
        defer self.allocator.free(scrollback);

        const process = self.processes.get(active_proc_id) orelse return scrollback.len > 0;
        return scrollback.len != process.consumed_len;
    }

    fn renderChild(
        self: *State,
        child: *child_primary.ChildPrimary,
        active_proc_id: domain.process.ProcessId,
        cols: u16,
        rows: u16,
        placeholder: []const u8,
    ) ![]const u8 {
        if (self.child == null) {
            self.child = .{
                .terminal = try terminal.ghostty_vt.Terminal.init(self.allocator, cols, rows),
                .selected_process_id = active_proc_id,
                .pending_snapshot = std.array_list.Managed(u8).init(self.allocator),
            };
        }

        var state = &self.child.?;
        if (state.selected_process_id != active_proc_id) {
            try state.resetForProcess(self.allocator, active_proc_id, cols, rows);
        }
        try state.terminal.resize(cols, rows);

        const bytes = try child.readSince(self.allocator, &state.cursor);
        defer self.allocator.free(bytes);
        const bytes_to_write = try bytesForSelectedProcess(state, bytes);
        if (bytes_to_write.len > 0) {
            state.has_output = true;
            try state.terminal.write(bytes_to_write);
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

fn bytesForSelectedProcess(state: *State.ChildState, bytes: []const u8) ![]const u8 {
    if (!state.awaiting_snapshot) return bytes;

    if (bytes.len > 0) try state.pending_snapshot.appendSlice(bytes);
    const pending = state.pending_snapshot.items;
    const reset_index = std.mem.indexOf(u8, pending, child_snapshot_reset) orelse return "";

    state.awaiting_snapshot = false;
    return pending[reset_index..];
}

fn dimension(value: i32) u16 {
    if (value <= 0) return 1;
    return @intCast(@min(value, std.math.maxInt(u16)));
}

test "child target shows placeholder immediately when active process changes before child emits output" {
    const test_config = @import("../test_support/config.zig");

    var cfg = try test_config.basicConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.layout.placeholder_banner = "NO PROCESS";

    var split = tui.split_model.Model.init(.left, &cfg);
    try split.resize(120, 40);

    var child = child_primary.ChildPrimary{
        .allocator = std.testing.allocator,
        .pid = 0,
        .pty_file = null,
        .output_file = null,
        .output = std.array_list.Managed(u8).init(std.testing.allocator),
    };
    defer child.output.deinit();

    try child.output.appendSlice("OLD_RUNNING_OUTPUT\n");

    var output = try State.init(std.testing.allocator, .{ .child = &child });
    defer output.deinit();

    const first = try output.renderText(&split, domain.process.ProcessId.fromInt(1), "NO PROCESS");
    defer std.testing.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "OLD_RUNNING_OUTPUT") != null);

    const second = try output.renderText(&split, domain.process.ProcessId.fromInt(2), "NO PROCESS");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("NO PROCESS", second);
}

test "child target ignores stale bytes queued before new process snapshot" {
    const test_config = @import("../test_support/config.zig");

    var cfg = try test_config.basicConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.layout.placeholder_banner = "NO PROCESS";

    var split = tui.split_model.Model.init(.left, &cfg);
    try split.resize(120, 40);

    var child = child_primary.ChildPrimary{
        .allocator = std.testing.allocator,
        .pid = 0,
        .pty_file = null,
        .output_file = null,
        .output = std.array_list.Managed(u8).init(std.testing.allocator),
    };
    defer child.output.deinit();

    try child.output.appendSlice("OLD_RUNNING_OUTPUT\n");

    var output = try State.init(std.testing.allocator, .{ .child = &child });
    defer output.deinit();

    const first = try output.renderText(&split, domain.process.ProcessId.fromInt(1), "NO PROCESS");
    defer std.testing.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "OLD_RUNNING_OUTPUT") != null);

    try child.output.appendSlice("LATE_OLD_OUTPUT\n");
    const second = try output.renderText(&split, domain.process.ProcessId.fromInt(2), "NO PROCESS");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("NO PROCESS", second);

    try child.output.appendSlice("\x1b[2J\x1b[HNEW_PROCESS_OUTPUT\n");
    const third = try output.renderText(&split, domain.process.ProcessId.fromInt(2), "NO PROCESS");
    defer std.testing.allocator.free(third);
    try std.testing.expectEqualStrings("NEW_PROCESS_OUTPUT", third);
}

test "child target reports pending output only when child output advances" {
    const test_config = @import("../test_support/config.zig");

    var cfg = try test_config.basicConfig(std.testing.allocator);
    defer cfg.deinit();
    cfg.layout.placeholder_banner = "NO PROCESS";

    var split = tui.split_model.Model.init(.left, &cfg);
    try split.resize(120, 40);

    var child = child_primary.ChildPrimary{
        .allocator = std.testing.allocator,
        .pid = 0,
        .pty_file = null,
        .output_file = null,
        .output = std.array_list.Managed(u8).init(std.testing.allocator),
    };
    defer child.output.deinit();

    var output = try State.init(std.testing.allocator, .{ .child = &child });
    defer output.deinit();

    try std.testing.expect(try output.hasPendingOutput(domain.process.ProcessId.fromInt(1)));

    try child.output.appendSlice("FIRST\n");
    const first = try output.renderText(&split, domain.process.ProcessId.fromInt(1), "NO PROCESS");
    defer std.testing.allocator.free(first);

    try std.testing.expect(!try output.hasPendingOutput(domain.process.ProcessId.fromInt(1)));

    try child.output.appendSlice("SECOND\n");
    try std.testing.expect(try output.hasPendingOutput(domain.process.ProcessId.fromInt(1)));
}

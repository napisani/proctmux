const std = @import("std");
const config = @import("../config/root.zig");

pub const process = @import("process.zig");
pub const state = @import("state.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const filter = @import("filter.zig");

test {
    _ = process;
    _ = state;
    _ = fuzzy;
    _ = filter;
}

test "status names match public status strings" {
    try std.testing.expectEqualStrings("Running", process.statusName(.running));
    try std.testing.expectEqualStrings("Halting", process.statusName(.halting));
    try std.testing.expectEqualStrings("Halted", process.statusName(.halted));
    try std.testing.expectEqualStrings("Exited", process.statusName(.exited));
    try std.testing.expectEqualStrings("Unknown", process.statusName(.unknown));
}

test "process command prefers shell and quotes cmd args like legacy behavior" {
    var cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);

    cfg.shell = "tail -f /var/log/syslog";
    const shell_cmd = try process.commandString(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(shell_cmd);
    try std.testing.expectEqualStrings("tail -f /var/log/syslog", shell_cmd);

    cfg.shell = "";
    try config.schema.appendOwned(std.testing.allocator, &cfg.cmd, "/bin/bash");
    try config.schema.appendOwned(std.testing.allocator, &cfg.cmd, "-c");
    try config.schema.appendOwned(std.testing.allocator, &cfg.cmd, "echo DONE");
    const argv_cmd = try process.commandString(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(argv_cmd);
    try std.testing.expectEqualStrings("'/bin/bash' '-c' 'echo DONE' ", argv_cmd);
}

test "process to view queries controller for live status and pid" {
    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.shell = "npm run dev";

    const proc = process.Process{
        .id = process.ProcessId.fromInt(5),
        .label = "backend",
        .config = &proc_cfg,
    };

    var fake = FakeController{ .status = .running, .pid = 12345 };
    const running_view = process.toView(proc, fake.controller());
    try std.testing.expectEqual(process.ProcessId.fromInt(5), running_view.id);
    try std.testing.expectEqualStrings("backend", running_view.label);
    try std.testing.expectEqual(process.ProcessStatus.running, running_view.status);
    try std.testing.expectEqual(@as(i32, 12345), running_view.pid);
    try std.testing.expect(running_view.config == &proc_cfg);

    const halted_view = process.toView(proc, null);
    try std.testing.expectEqual(process.ProcessStatus.halted, halted_view.status);
    try std.testing.expectEqual(@as(i32, -1), halted_view.pid);
}

test "app state sorts process labels before assigning ids" {
    var loaded = try config.load.loadFile(std.testing.allocator, "testdata/phase2/config/full-active.yaml");
    defer loaded.deinit();

    var app = try state.AppState.init(std.testing.allocator, &loaded.config);
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 2), app.processes.items.len);
    try std.testing.expectEqualStrings("backend", app.processes.items[0].label);
    try std.testing.expectEqual(process.ProcessId.fromInt(1), app.processes.items[0].id);
    try std.testing.expectEqualStrings("worker", app.processes.items[1].label);
    try std.testing.expectEqual(process.ProcessId.fromInt(2), app.processes.items[1].id);
    try std.testing.expect(app.getProcessByLabel("Backend") == null);
    try std.testing.expect(app.getProcessByLabel("backend") != null);
}

test "category filter uses AND matching and running-only toggle" {
    var api_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer api_cfg.deinit(std.testing.allocator);
    try config.schema.appendOwned(std.testing.allocator, &api_cfg.categories, "server");
    try config.schema.appendOwned(std.testing.allocator, &api_cfg.categories, "api");

    var gateway_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer gateway_cfg.deinit(std.testing.allocator);
    try config.schema.appendOwned(std.testing.allocator, &gateway_cfg.categories, "server");
    try config.schema.appendOwned(std.testing.allocator, &gateway_cfg.categories, "gateway");

    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);

    var views = [_]process.ProcessView{
        .{ .id = process.ProcessId.fromInt(1), .label = "backend", .status = .running, .pid = 101, .config = &api_cfg },
        .{ .id = process.ProcessId.fromInt(2), .label = "api-gateway", .status = .halted, .pid = -1, .config = &gateway_cfg },
    };

    const result = try filter.filterProcesses(std.testing.allocator, &cfg, views[0..], "cat:server,api", false);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("backend", result[0].label);

    const running = try filter.filterProcesses(std.testing.allocator, &cfg, views[0..], "cat:server", true);
    defer std.testing.allocator.free(running);
    try std.testing.expectEqual(@as(usize, 1), running.len);
    try std.testing.expectEqualStrings("backend", running[0].label);
}

test "sort running first then alpha" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    cfg.layout.sort_process_list_running_first = true;
    cfg.layout.sort_process_list_alpha = true;

    var empty_proc = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer empty_proc.deinit(std.testing.allocator);

    var views = [_]process.ProcessView{
        .{ .id = process.ProcessId.fromInt(1), .label = "halted-zebra", .status = .halted, .config = &empty_proc },
        .{ .id = process.ProcessId.fromInt(2), .label = "running-mango", .status = .running, .config = &empty_proc },
        .{ .id = process.ProcessId.fromInt(3), .label = "halted-apple", .status = .halted, .config = &empty_proc },
        .{ .id = process.ProcessId.fromInt(4), .label = "running-banana", .status = .running, .config = &empty_proc },
    };

    const result = try filter.filterProcesses(std.testing.allocator, &cfg, views[0..], "", false);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("running-banana", result[0].label);
    try std.testing.expectEqualStrings("running-mango", result[1].label);
    try std.testing.expectEqualStrings("halted-apple", result[2].label);
    try std.testing.expectEqualStrings("halted-zebra", result[3].label);
}

test "fuzzy label search ignores configured sorting" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    cfg.layout.sort_process_list_running_first = true;
    cfg.layout.sort_process_list_alpha = true;

    var empty_proc = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer empty_proc.deinit(std.testing.allocator);

    var views = [_]process.ProcessView{
        .{ .id = process.ProcessId.fromInt(1), .label = "zebra-api", .status = .halted, .config = &empty_proc },
        .{ .id = process.ProcessId.fromInt(2), .label = "api-service", .status = .running, .config = &empty_proc },
        .{ .id = process.ProcessId.fromInt(3), .label = "apple-api", .status = .halted, .config = &empty_proc },
    };

    const result = try filter.filterProcesses(std.testing.allocator, &cfg, views[0..], "api", false);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
}

const FakeController = struct {
    status: process.ProcessStatus,
    pid: i32,

    fn controller(self: *FakeController) process.ProcessController {
        return .{
            .context = self,
            .get_process_status = getProcessStatus,
            .get_pid = getPID,
        };
    }

    fn getProcessStatus(context: *anyopaque, _: process.ProcessId) process.ProcessStatus {
        const self: *FakeController = @ptrCast(@alignCast(context));
        return self.status;
    }

    fn getPID(context: *anyopaque, _: process.ProcessId) i32 {
        const self: *FakeController = @ptrCast(@alignCast(context));
        return self.pid;
    }
};

const std = @import("std");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");

pub fn basicConfig(allocator: std.mem.Allocator) !config.schema.Config {
    var cfg = config.schema.Config.empty(allocator);
    errdefer cfg.deinit();
    try config.defaults.apply(&cfg, allocator);
    return cfg;
}

pub fn configWithProcesses(
    allocator: std.mem.Allocator,
    labels: []const []const u8,
) !config.schema.Config {
    var cfg = try basicConfig(allocator);
    errdefer cfg.deinit();
    for (labels) |label| try putShellProcess(&cfg, label, "sleep 1");
    return cfg;
}

pub fn standardRenderConfig(allocator: std.mem.Allocator) !config.schema.Config {
    return configWithProcesses(allocator, &.{ "alpha-api", "beta-worker", "gamma-db" });
}

pub fn standardRenderViews(cfg: *config.schema.Config) [3]domain.process.ProcessView {
    return .{
        .{ .id = domain.process.ProcessId.fromInt(1), .label = "alpha-api", .status = .halted, .pid = -1, .config = cfg.procs.getPtr("alpha-api").? },
        .{ .id = domain.process.ProcessId.fromInt(2), .label = "beta-worker", .status = .running, .pid = 1234, .config = cfg.procs.getPtr("beta-worker").? },
        .{ .id = domain.process.ProcessId.fromInt(3), .label = "gamma-db", .status = .exited, .pid = -1, .config = cfg.procs.getPtr("gamma-db").? },
    };
}

pub fn standardClientModelConfig(allocator: std.mem.Allocator) !config.schema.Config {
    return configWithProcesses(allocator, &.{ "alpha-api", "beta-worker", "gamma-db" });
}

pub fn standardSessionConfig(allocator: std.mem.Allocator) !config.schema.Config {
    return configWithProcesses(allocator, &.{ "alpha-api", "beta-worker", "gamma-db" });
}

pub fn standardClientModelViews(cfg: *config.schema.Config) [3]domain.process.ProcessView {
    return .{
        .{ .id = domain.process.ProcessId.fromInt(1), .label = "alpha-api", .status = .running, .config = cfg.procs.getPtr("alpha-api").? },
        .{ .id = domain.process.ProcessId.fromInt(2), .label = "beta-worker", .status = .halted, .config = cfg.procs.getPtr("beta-worker").? },
        .{ .id = domain.process.ProcessId.fromInt(3), .label = "gamma-db", .status = .running, .config = cfg.procs.getPtr("gamma-db").? },
    };
}

pub fn snapshotFromViews(
    allocator: std.mem.Allocator,
    cfg: *const config.schema.Config,
    current_proc_id: domain.process.ProcessId,
    views: []const domain.process.ProcessView,
) !domain.client_snapshot.BuiltClientSnapshot {
    var summaries = try allocator.alloc(domain.client_snapshot.ProcessSummary, views.len);
    errdefer allocator.free(summaries);
    for (views, 0..) |view, index| {
        summaries[index] = domain.client_snapshot.summaryFromView(view);
    }
    return .{ .value = .{
        .current_process_id = current_proc_id.toInt(),
        .ui = domain.client_snapshot.fromConfig(cfg),
        .processes = summaries,
    } };
}

pub fn putShellProcess(cfg: *config.schema.Config, label: []const u8, shell: []const u8) !void {
    try putShellProcessWithStopTimeout(cfg, label, shell, 0);
}

pub fn putShellProcessWithStopTimeout(
    cfg: *config.schema.Config,
    label: []const u8,
    shell: []const u8,
    stop_timeout_ms: i32,
) !void {
    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    errdefer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.owns_scalar_strings = true;
    proc_cfg.shell = try std.testing.allocator.dupe(u8, shell);
    proc_cfg.stop_timeout_ms = stop_timeout_ms;

    const owned_label = try std.testing.allocator.dupe(u8, label);
    errdefer std.testing.allocator.free(owned_label);
    try cfg.procs.put(owned_label, proc_cfg);
}

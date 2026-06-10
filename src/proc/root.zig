//! Process subsystem namespace and tests.
//! This module exposes the controller plus focused internals used by Primary Server and process lifecycle tests.

const std = @import("std");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");

pub const builder = @import("builder.zig");
pub const controller = @import("controller.zig");
pub const env = @import("env.zig");
pub const instance = @import("instance.zig");
pub const on_kill = @import("on_kill.zig");
pub const output = @import("output.zig");
pub const spawn = @import("spawn.zig");

test {
    _ = builder;
    _ = controller;
    _ = env;
    _ = instance;
    _ = on_kill;
    _ = output;
    _ = spawn;
}

test "command builder uses shell command with default shell" {
    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.shell = "echo hello world";

    const spec = try builder.buildCommand(std.testing.allocator, &proc_cfg, null) orelse return error.ExpectedCommand;
    defer spec.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), spec.argv.len);
    try std.testing.expectEqualStrings("sh", spec.argv[0]);
    try std.testing.expectEqualStrings("-c", spec.argv[1]);
    try std.testing.expectEqualStrings("echo hello world", spec.argv[2]);
}

test "command builder uses custom shell command" {
    var global = config.schema.Config.empty(std.testing.allocator);
    defer global.deinit();
    try config.schema.appendOwned(std.testing.allocator, &global.shell_cmd, "/bin/bash");
    try config.schema.appendOwned(std.testing.allocator, &global.shell_cmd, "-lc");

    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.shell = "echo custom";

    const spec = try builder.buildCommand(std.testing.allocator, &proc_cfg, &global) orelse return error.ExpectedCommand;
    defer spec.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), spec.argv.len);
    try std.testing.expectEqualStrings("/bin/bash", spec.argv[0]);
    try std.testing.expectEqualStrings("-lc", spec.argv[1]);
    try std.testing.expectEqualStrings("echo custom", spec.argv[2]);
}

test "command builder prefers shell over cmd array" {
    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.shell = "shell command";
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "cmd");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "array");

    const spec = try builder.buildCommand(std.testing.allocator, &proc_cfg, null) orelse return error.ExpectedCommand;
    defer spec.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("sh", spec.argv[0]);
    try std.testing.expectEqualStrings("shell command", spec.argv[2]);
}

test "command builder uses argv command and returns null for empty command" {
    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer proc_cfg.deinit(std.testing.allocator);

    try std.testing.expect(try builder.buildCommand(std.testing.allocator, &proc_cfg, null) == null);

    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "/bin/ls");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "-la");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "/tmp");

    const spec = try builder.buildCommand(std.testing.allocator, &proc_cfg, null) orelse return error.ExpectedCommand;
    defer spec.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), spec.argv.len);
    try std.testing.expectEqualStrings("/bin/ls", spec.argv[0]);
    try std.testing.expectEqualStrings("-la", spec.argv[1]);
    try std.testing.expectEqualStrings("/tmp", spec.argv[2]);
}

test "environment builder appends add_path and custom env like legacy behavior" {
    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer proc_cfg.deinit(std.testing.allocator);
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.add_path, "/custom/bin");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.add_path, "/second/bin");
    try config.schema.putOwnedString(std.testing.allocator, &proc_cfg.env, "CUSTOM", "value");
    try config.schema.putOwnedString(std.testing.allocator, &proc_cfg.env, "HOME", "/custom/home");

    const built_env = try builder.buildEnvironmentFromBase(
        std.testing.allocator,
        &.{ "PATH=/usr/bin", "HOME=/home/nick", "KEEP=yes" },
        "/usr/bin",
        &proc_cfg,
    );
    defer builder.deinitEnvironment(std.testing.allocator, built_env);

    try std.testing.expect(contains(built_env, "HOME=/home/nick"));
    try std.testing.expect(contains(built_env, "KEEP=yes"));
    try std.testing.expect(contains(built_env, "PATH=/usr/bin:/custom/bin:/second/bin"));
    try std.testing.expect(contains(built_env, "CUSTOM=value"));
    try std.testing.expect(contains(built_env, "HOME=/custom/home"));
    try std.testing.expectEqual(@as(usize, 1), countPrefix(built_env, "PATH="));
}

test "controller starts process captures output and stops it" {
    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.shell = "printf ready; sleep 5";
    proc_cfg.stop_timeout_ms = 500;

    var ctl = controller.Controller.init(std.testing.allocator, null);
    defer ctl.deinit();

    const id = domain.process.ProcessId.fromInt(1);
    const proc_instance = try ctl.startProcess(id, &proc_cfg);
    try std.testing.expectEqual(id, proc_instance.id);
    try std.testing.expect(ctl.isRunning(id));
    try std.testing.expectEqual(domain.process.ProcessStatus.running, ctl.getProcessStatus(id));

    try waitForScrollbackContains(&ctl, id, "ready");
    try ctl.stopProcess(id);

    try std.testing.expect(!ctl.isRunning(id));
    try std.testing.expectEqual(domain.process.ProcessStatus.halted, ctl.getProcessStatus(id));
    try std.testing.expectError(error.ProcessNotFound, ctl.getScrollback(std.testing.allocator, id));
}

test "controller rejects duplicate starts and missing stops" {
    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.shell = "sleep 5";
    proc_cfg.stop_timeout_ms = 500;

    var ctl = controller.Controller.init(std.testing.allocator, null);
    defer ctl.deinit();

    const id = domain.process.ProcessId.fromInt(2);
    _ = try ctl.startProcess(id, &proc_cfg);
    try std.testing.expectError(error.ProcessAlreadyExists, ctl.startProcess(id, &proc_cfg));
    try ctl.stopProcess(id);
    try std.testing.expectError(error.ProcessNotFound, ctl.stopProcess(id));
}

test "controller runs on kill hook after user stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.cwd = cwd;
    proc_cfg.stop_timeout_ms = 500;
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "sh");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "-c");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "trap 'exit 0' TERM; while true; do sleep 0.05; done");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.on_kill, "sh");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.on_kill, "-c");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.on_kill, "printf hook > on_kill.txt");

    var ctl = controller.Controller.init(std.testing.allocator, null);
    defer ctl.deinit();

    const id = domain.process.ProcessId.fromInt(3);
    _ = try ctl.startProcess(id, &proc_cfg);
    try ctl.stopProcess(id);

    const contents = try tmp.dir.readFileAlloc(std.testing.allocator, "on_kill.txt", 1024);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("hook", contents);
}

test "controller cleanup skips on kill hook after natural exit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.cwd = cwd;
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "sh");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "-c");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "printf done");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.on_kill, "sh");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.on_kill, "-c");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.on_kill, "printf hook > on_kill.txt");

    var ctl = controller.Controller.init(std.testing.allocator, null);
    defer ctl.deinit();

    const id = domain.process.ProcessId.fromInt(4);
    _ = try ctl.startProcess(id, &proc_cfg);
    try waitForControllerStopped(&ctl, id);
    try ctl.cleanupProcess(id);
    try ctl.cleanupProcess(id);

    try std.testing.expectError(error.FileNotFound, tmp.dir.access("on_kill.txt", .{}));
    try std.testing.expectError(error.ProcessNotFound, ctl.getScrollback(std.testing.allocator, id));
}

test "controller deinit skips on kill hook after natural exit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.cwd = cwd;
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "sh");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "-c");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "printf done");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.on_kill, "sh");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.on_kill, "-c");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.on_kill, "printf hook > on_kill.txt");

    {
        var ctl = controller.Controller.init(std.testing.allocator, null);
        defer ctl.deinit();

        const id = domain.process.ProcessId.fromInt(8);
        _ = try ctl.startProcess(id, &proc_cfg);
        try waitForControllerStopped(&ctl, id);
    }

    try std.testing.expectError(error.FileNotFound, tmp.dir.access("on_kill.txt", .{}));
}

test "controller starts process in pty and forwards input" {
    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.terminal_rows = 33;
    proc_cfg.terminal_cols = 101;
    proc_cfg.stop_timeout_ms = 500;
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "sh");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "-c");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.cmd, "stty size; IFS= read line; printf 'got:%s' \"$line\"");

    var ctl = controller.Controller.init(std.testing.allocator, null);
    defer ctl.deinit();

    const id = domain.process.ProcessId.fromInt(5);
    const proc_instance = try ctl.startProcess(id, &proc_cfg);
    try waitForScrollbackContains(&ctl, id, "33 101");

    try proc_instance.sendBytes("hello\n");
    try waitForScrollbackContains(&ctl, id, "got:hello");

    try ctl.stopProcess(id);
}

test "controller exposes pid and managed process ids" {
    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.shell = "sleep 5";
    proc_cfg.stop_timeout_ms = 500;

    var ctl = controller.Controller.init(std.testing.allocator, null);
    defer ctl.deinit();

    const id = domain.process.ProcessId.fromInt(6);
    try std.testing.expectEqual(@as(i32, -1), ctl.getPID(id));
    const empty_ids = try ctl.getAllProcessIDs(std.testing.allocator);
    defer std.testing.allocator.free(empty_ids);
    try std.testing.expectEqual(@as(usize, 0), empty_ids.len);

    _ = try ctl.startProcess(id, &proc_cfg);
    try std.testing.expect(ctl.getPID(id) > 0);

    const ids = try ctl.getAllProcessIDs(std.testing.allocator);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(domain.process.ProcessId, &.{id}, ids);

    try ctl.stopProcess(id);
    try std.testing.expectEqual(@as(i32, -1), ctl.getPID(id));
}

test "controller adapts to domain process view controller" {
    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.shell = "sleep 5";
    proc_cfg.stop_timeout_ms = 500;

    var ctl = controller.Controller.init(std.testing.allocator, null);
    defer ctl.deinit();

    const proc = domain.process.Process{
        .id = domain.process.ProcessId.fromInt(7),
        .label = "api",
        .config = &proc_cfg,
    };

    _ = try ctl.startProcess(proc.id, &proc_cfg);
    const running_view = domain.process.toView(proc, ctl.processController());
    try std.testing.expectEqual(domain.process.ProcessStatus.running, running_view.status);
    try std.testing.expect(running_view.pid > 0);

    try ctl.stopProcess(proc.id);
    const halted_view = domain.process.toView(proc, ctl.processController());
    try std.testing.expectEqual(domain.process.ProcessStatus.halted, halted_view.status);
    try std.testing.expectEqual(@as(i32, -1), halted_view.pid);
}

fn contains(environment: []const []const u8, needle: []const u8) bool {
    for (environment) |entry| {
        if (std.mem.eql(u8, entry, needle)) return true;
    }
    return false;
}

fn countPrefix(environment: []const []const u8, prefix: []const u8) usize {
    var count: usize = 0;
    for (environment) |entry| {
        if (std.mem.startsWith(u8, entry, prefix)) count += 1;
    }
    return count;
}

fn waitForScrollbackContains(
    ctl: *controller.Controller,
    id: domain.process.ProcessId,
    needle: []const u8,
) !void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        const bytes = try ctl.getScrollback(std.testing.allocator, id);
        defer std.testing.allocator.free(bytes);
        if (std.mem.indexOf(u8, bytes, needle) != null) return;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.ExpectedScrollback;
}

fn waitForControllerStopped(ctl: *controller.Controller, id: domain.process.ProcessId) !void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (!ctl.isRunning(id)) return;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.ExpectedProcessStopped;
}

const std = @import("std");
const config = @import("../config/root.zig");
const env = @import("env.zig");

const default_timeout_ms = 30_000;

pub fn execute(
    allocator: std.mem.Allocator,
    proc_cfg: *const config.schema.ProcessConfig,
) !void {
    return executeWithTimeoutMs(allocator, proc_cfg, default_timeout_ms);
}

pub fn executeWithTimeoutMs(
    allocator: std.mem.Allocator,
    proc_cfg: *const config.schema.ProcessConfig,
    timeout_ms: u64,
) !void {
    if (proc_cfg.on_kill.items.len == 0) return;

    var env_map = try env.buildMap(allocator, proc_cfg);
    defer env_map.deinit();

    var child = std.process.Child.init(proc_cfg.on_kill.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    if (proc_cfg.cwd.len > 0) child.cwd = proc_cfg.cwd;
    child.env_map = &env_map;

    try child.spawn();
    const child_pid = child.id;

    var wait_state = WaitState{ .child = &child };
    const wait_thread = try std.Thread.spawn(.{}, waitChild, .{&wait_state});
    if (!waitForChild(&wait_state.done, timeout_ms)) {
        std.posix.kill(child_pid, std.posix.SIG.KILL) catch {};
        wait_thread.join();
        return error.OnKillFailed;
    }
    wait_thread.join();

    const term = switch (wait_state.result) {
        .running, .failed => return error.OnKillFailed,
        .exited => |term| term,
    };
    switch (term) {
        .Exited => |code| if (code != 0) return error.OnKillFailed,
        else => return error.OnKillFailed,
    }
}

const WaitResult = union(enum) {
    running,
    exited: std.process.Child.Term,
    failed: anyerror,
};

const WaitState = struct {
    child: *std.process.Child,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: WaitResult = .running,
};

fn waitChild(state: *WaitState) void {
    state.result = .{ .exited = state.child.wait() catch |err| {
        state.result = .{ .failed = err };
        state.done.store(true, .release);
        return;
    } };
    state.done.store(true, .release);
}

fn waitForChild(done: *const std.atomic.Value(bool), timeout_ms: u64) bool {
    const sleep_ms: u64 = 5;
    var elapsed_ms: u64 = 0;

    while (elapsed_ms < timeout_ms) {
        if (done.load(.acquire)) return true;
        const remaining_ms = timeout_ms - elapsed_ms;
        const current_sleep_ms: u64 = @min(sleep_ms, remaining_ms);
        std.Thread.sleep(current_sleep_ms * @as(u64, std.time.ns_per_ms));
        elapsed_ms += current_sleep_ms;
    }

    return done.load(.acquire);
}

test "on kill hook times out and kills long running hook" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.cwd = cwd;
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.on_kill, "sh");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.on_kill, "-c");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.on_kill, "sleep 5; printf late > on_kill.txt");

    const started = std.time.milliTimestamp();
    try std.testing.expectError(error.OnKillFailed, executeWithTimeoutMs(std.testing.allocator, &proc_cfg, 50));
    const elapsed = std.time.milliTimestamp() - started;

    try std.testing.expect(elapsed < 1000);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("on_kill.txt", .{}));
}

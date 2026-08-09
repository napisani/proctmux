//! IPC integration tests over real Unix sockets and protocol lines.
//! These tests protect the public IPC seam rather than old internal codec compatibility.

const std = @import("std");
const domain = @import("../domain/root.zig");
const config = @import("../config/root.zig");
const protocol = @import("protocol.zig");
const client = @import("client.zig");
const server = @import("server.zig");
const test_config = @import("../test_support/config.zig");
const test_ipc = @import("../test_support/ipc.zig");

test "protocol command names use clean zig-only action names" {
    try std.testing.expectEqualStrings("start", protocol.commandName(.start));
    try std.testing.expectEqualStrings("stop", protocol.commandName(.stop));
    try std.testing.expectEqualStrings("restart", protocol.commandName(.restart));
    try std.testing.expectEqualStrings("switch", protocol.commandName(.switch_process));
    try std.testing.expectEqualStrings("restart_running", protocol.commandName(.restart_running));
    try std.testing.expectEqualStrings("stop_running", protocol.commandName(.stop_running));
}

test "snapshotLine emits a minimal snapshot without process execution config" {
    var cfg = try test_config.basicConfig(std.testing.allocator);
    defer cfg.deinit();
    try test_config.putShellProcess(&cfg, "api", "sleep 5");
    const proc_cfg = cfg.procs.getPtr("api").?;
    proc_cfg.description = try std.testing.allocator.dupe(u8, "API server");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.categories, "backend");
    try config.schema.putOwnedString(std.testing.allocator, &proc_cfg.env, "SECRET", "value");

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(1);

    var fake_controller = test_ipc.FakeProcessController{
        .running_id = domain.process.ProcessId.fromInt(1),
    };
    var initial_snapshot = try domain.client_snapshot.fromAppState(
        std.testing.allocator,
        &app_state,
        fake_controller.controller(),
    );
    defer initial_snapshot.deinit(std.testing.allocator);

    const line = try protocol.snapshotLine(std.testing.allocator, initial_snapshot.view());
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.startsWith(u8, line, "{\"type\":\"snapshot\",\"protocol_version\":1"));
    try std.testing.expect(std.mem.indexOf(u8, line, "\"env\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"shell\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"cmd\"") == null);

    var update = try protocol.parseSnapshotLine(std.testing.allocator, line);
    defer update.deinit();
    const snapshot = update.snapshot();
    try std.testing.expectEqual(@as(u32, 1), snapshot.current_process_id);
    try std.testing.expectEqual(@as(usize, 1), snapshot.processes.len);
    try std.testing.expectEqualStrings("api", snapshot.processes[0].label);
    try std.testing.expectEqual(domain.process.ProcessStatus.running, snapshot.processes[0].status);
    try std.testing.expectEqualStrings("API server", snapshot.processes[0].description);
    try std.testing.expectEqualStrings("backend", snapshot.processes[0].categories[0]);
}

test "one-shot command server handles clean command request" {
    const path = "/tmp/proctmux-zig-clean-ipc-command-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    var handler = test_ipc.FakeCommandHandler{};
    var authorizer = test_ipc.FakePeerAuthorizer{};
    const thread = try std.Thread.spawn(.{}, server.serveOneCommandAtPathWithAuthorizer, .{
        std.testing.allocator,
        path,
        handler.handler(),
        authorizer.authorizer(),
    });
    defer thread.join();
    test_ipc.waitForSocketFile(path);

    var response = try client.sendCommandToPath(std.testing.allocator, path, 51, .restart, "web");
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.success);
    try std.testing.expectEqual(@as(u64, 51), response.request_id);
    try std.testing.expectEqual(protocol.Command.restart, handler.action);
    try std.testing.expectEqualStrings("web", handler.label());
    try std.testing.expect(authorizer.called);
}

test "snapshot client reads initial snapshot" {
    const path = "/tmp/proctmux-zig-clean-ipc-snapshot-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    var handler = test_ipc.FakeCommandHandler{};
    var provider = test_ipc.FakeSnapshotProvider{ .line = test_ipc.selectedApiSnapshotLine };
    var stopped = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, server.serveCommandsAtPathWithSnapshots, .{
        std.testing.allocator,
        path,
        handler.handler(),
        provider.provider(),
        &stopped,
    });
    defer {
        stopped.store(true, .seq_cst);
        test_ipc.unblockServer(path);
        thread.join();
    }
    test_ipc.waitForSocketFile(path);

    var ipc_client = try client.Client.connect(std.testing.allocator, path);
    defer ipc_client.deinit();

    var update = try ipc_client.readSnapshot();
    defer update.deinit();
    const snapshot = update.snapshot();
    try std.testing.expectEqual(@as(u32, 2), snapshot.current_process_id);
    try std.testing.expectEqualStrings("api", snapshot.processes[0].label);
}

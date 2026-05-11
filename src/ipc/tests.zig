const std = @import("std");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");
const test_config = @import("../test_support/config.zig");
const test_ipc = @import("../test_support/ipc.zig");

const protocol = @import("protocol.zig");
const line = @import("line.zig");
const command_codec = @import("command_codec.zig");
const state_codec = @import("state_codec.zig");
const socket = @import("socket.zig");
const client = @import("client.zig");
const server = @import("server.zig");

test {
    _ = protocol;
    _ = line;
    _ = command_codec;
    _ = state_codec;
    _ = socket;
    _ = client;
    _ = server;
}

test "command names match Go protocol constants" {
    try std.testing.expectEqualStrings("start", protocol.commandName(.start));
    try std.testing.expectEqualStrings("stop", protocol.commandName(.stop));
    try std.testing.expectEqualStrings("restart", protocol.commandName(.restart));
    try std.testing.expectEqualStrings("switch", protocol.commandName(.switch_process));
    try std.testing.expectEqualStrings("restart-running", protocol.commandName(.restart_running));
    try std.testing.expectEqualStrings("stop-running", protocol.commandName(.stop_running));
    try std.testing.expectEqualStrings("list", protocol.commandName(.list));
}

test "command request serializes as Go-compatible JSON line" {
    const encoded = try protocol.commandRequestLine(std.testing.allocator, "42", .start, "web");
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings(
        "{\"type\":\"command\",\"request_id\":\"42\",\"label\":\"web\",\"action\":\"start\"}\n",
        encoded,
    );
}

test "command request omits empty label like Go omitempty" {
    const encoded = try protocol.commandRequestLine(std.testing.allocator, "7", .list, "");
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings(
        "{\"type\":\"command\",\"request_id\":\"7\",\"action\":\"list\"}\n",
        encoded,
    );
}

test "command request escapes JSON string fields like Go" {
    const encoded = try protocol.commandRequestLine(std.testing.allocator, "44", .start, "web \"quoted\" \\ worker");
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings(
        "{\"type\":\"command\",\"request_id\":\"44\",\"label\":\"web \\\"quoted\\\" \\\\ worker\",\"action\":\"start\"}\n",
        encoded,
    );
}

test "command request parser reads Go-compatible JSON line" {
    var request = try protocol.parseCommandRequestLine(
        std.testing.allocator,
        "{\"type\":\"command\",\"request_id\":\"42\",\"label\":\"web\",\"action\":\"restart\"}\n",
    );
    defer request.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("42", request.request_id);
    try std.testing.expectEqual(protocol.Command.restart, request.action);
    try std.testing.expectEqualStrings("web", request.label);
}

test "response line serialization matches Go omitempty shape" {
    var items = [_]protocol.ProcessListItem{
        .{ .name = "api", .running = true, .index = 1 },
        .{ .name = "worker", .running = false, .index = 2 },
    };
    const response = protocol.Response{
        .request_id = "7",
        .success = true,
        .error_message = "",
        .process_list = items[0..],
    };

    const encoded = try protocol.responseLine(std.testing.allocator, response);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings(
        "{\"type\":\"response\",\"request_id\":\"7\",\"process_list\":[{\"index\":1,\"name\":\"api\",\"running\":true},{\"index\":2,\"name\":\"worker\",\"running\":false}],\"success\":true}\n",
        encoded,
    );
}

test "response line parsing preserves success and error" {
    const success = try protocol.parseResponseLine(
        std.testing.allocator,
        "{\"type\":\"response\",\"request_id\":\"42\",\"success\":true}\n",
    );
    defer success.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("42", success.request_id);
    try std.testing.expect(success.success);
    try std.testing.expectEqualStrings("", success.error_message);
    try std.testing.expectEqual(@as(usize, 0), success.process_list.len);

    const failure = try protocol.parseResponseLine(
        std.testing.allocator,
        "{\"type\":\"response\",\"request_id\":\"43\",\"error\":\"missing process name\"}\n",
    );
    defer failure.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("43", failure.request_id);
    try std.testing.expect(!failure.success);
    try std.testing.expectEqualStrings("missing process name", failure.error_message);
}

test "response line parsing preserves process list payload" {
    const response = try protocol.parseResponseLine(
        std.testing.allocator,
        "{\"type\":\"response\",\"request_id\":\"9\",\"process_list\":[{\"index\":0,\"name\":\"web\",\"running\":true},{\"index\":1,\"name\":\"worker\",\"running\":false}],\"success\":true}\n",
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.success);
    try std.testing.expectEqual(@as(usize, 2), response.process_list.len);
    try std.testing.expectEqual(@as(i64, 0), response.process_list[0].index);
    try std.testing.expectEqualStrings("web", response.process_list[0].name);
    try std.testing.expect(response.process_list[0].running);
    try std.testing.expectEqual(@as(i64, 1), response.process_list[1].index);
    try std.testing.expectEqualStrings("worker", response.process_list[1].name);
    try std.testing.expect(!response.process_list[1].running);
}

test "state message serializes redacted state and process views" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    cfg.file_path = "/tmp/proctmux-zig-state-test.yaml";

    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    errdefer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.shell = "npm run dev";
    proc_cfg.docs = "Run API docs";
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.meta_tags, "backend");
    try config.schema.putOwnedString(std.testing.allocator, &proc_cfg.env, "SECRET", "value");

    const label = try std.testing.allocator.dupe(u8, "api");
    errdefer std.testing.allocator.free(label);
    try cfg.procs.put(label, proc_cfg);

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(1);

    var fake_controller = test_ipc.FakeProcessController{ .status = .running, .pid = 12345 };
    const encoded = try protocol.stateLine(
        std.testing.allocator,
        &app_state,
        fake_controller.controller(),
    );
    defer std.testing.allocator.free(encoded);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();

    const message = parsed.value.object;
    try std.testing.expectEqualStrings("state", message.get("type").?.string);

    const state = message.get("state").?.object;
    try std.testing.expectEqual(@as(i64, 1), state.get("CurrentProcID").?.integer);

    const state_config = state.get("Config").?.object;
    const procs = state_config.get("Procs").?.object;
    const api = procs.get("api").?.object;
    try std.testing.expect(api.get("Env").? == .null);
    try std.testing.expectEqualStrings("Run API docs", api.get("Docs").?.string);
    try std.testing.expectEqualStrings("backend", api.get("MetaTags").?.array.items[0].string);

    const state_processes = state.get("Processes").?.array;
    const state_process = state_processes.items[0].object;
    try std.testing.expect(state_process.get("Config").?.object.get("Env").? == .null);

    const views = message.get("process_views").?.array;
    const view = views.items[0].object;
    try std.testing.expectEqual(@as(i64, 1), view.get("ID").?.integer);
    try std.testing.expectEqualStrings("api", view.get("Label").?.string);
    try std.testing.expectEqual(@as(i64, 1), view.get("Status").?.integer);
    try std.testing.expectEqual(@as(i64, 12345), view.get("PID").?.integer);
    try std.testing.expect(view.get("Config").?.object.get("Env").? == .null);
}

test "state message parser round-trips redacted state and process views" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    cfg.file_path = "/tmp/proctmux-zig-state-parse-test.yaml";
    cfg.layout.placeholder_banner = "READY";
    try config.schema.appendOwned(std.testing.allocator, &cfg.keybinding.quit, "q");

    var proc_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    errdefer proc_cfg.deinit(std.testing.allocator);
    proc_cfg.shell = "npm run dev";
    proc_cfg.description = "API server";
    proc_cfg.docs = "API docs";
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.meta_tags, "backend");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.categories, "server");
    try config.schema.putOwnedString(std.testing.allocator, &proc_cfg.env, "SECRET", "value");

    const label = try std.testing.allocator.dupe(u8, "api");
    errdefer std.testing.allocator.free(label);
    try cfg.procs.put(label, proc_cfg);

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(1);

    var fake_controller = test_ipc.FakeProcessController{ .status = .running, .pid = 12345 };
    const encoded = try protocol.stateLine(
        std.testing.allocator,
        &app_state,
        fake_controller.controller(),
    );
    defer std.testing.allocator.free(encoded);

    var update = try protocol.parseStateLine(std.testing.allocator, encoded);
    defer update.deinit();

    try std.testing.expectEqual(domain.process.ProcessId.fromInt(1), update.state.current_proc_id);
    try std.testing.expectEqualStrings("READY", update.config.layout.placeholder_banner);
    try std.testing.expectEqualStrings("q", update.config.keybinding.quit.items[0]);
    try std.testing.expectEqual(@as(usize, 1), update.state.processes.items.len);
    try std.testing.expectEqualStrings("api", update.state.processes.items[0].label);
    try std.testing.expectEqual(@as(usize, 0), update.state.processes.items[0].config.env.count());

    try std.testing.expectEqual(@as(usize, 1), update.process_views.len);
    try std.testing.expectEqual(domain.process.ProcessId.fromInt(1), update.process_views[0].id);
    try std.testing.expectEqualStrings("api", update.process_views[0].label);
    try std.testing.expectEqual(domain.process.ProcessStatus.running, update.process_views[0].status);
    try std.testing.expectEqual(@as(i32, 12345), update.process_views[0].pid);
    try std.testing.expectEqualStrings("API server", update.process_views[0].config.description);
    try std.testing.expectEqualStrings("API docs", update.process_views[0].config.docs);
    try std.testing.expectEqualStrings("backend", update.process_views[0].config.meta_tags.items[0]);
    try std.testing.expectEqual(@as(usize, 0), update.process_views[0].config.env.count());
}

test "state message parser accepts Go null slice fields" {
    var update = try protocol.parseStateLine(std.testing.allocator,
        \\{"type":"state","state":{"Config":{"FilePath":"/tmp/proctmux-go-state.yaml","Keybinding":{"Quit":["q"]},"Layout":{},"Style":{},"General":{},"ShellCmd":null,"Procs":{"api":{"Shell":"sleep 5","Cmd":null,"MetaTags":null,"Categories":null,"AddPath":null,"OnKill":null}}},"CurrentProcID":0,"Processes":[{"ID":1,"Label":"api"}],"Exiting":false},"process_views":[{"ID":1,"Label":"api","Status":3,"PID":-1}]}
        \\
    );
    defer update.deinit();

    try std.testing.expectEqual(@as(usize, 0), update.config.shell_cmd.items.len);
    try std.testing.expectEqualStrings("api", update.state.processes.items[0].label);
    try std.testing.expectEqualStrings("sleep 5", update.process_views[0].config.shell);
    try std.testing.expectEqual(@as(usize, 0), update.process_views[0].config.cmd.items.len);
    try std.testing.expectEqual(@as(usize, 0), update.process_views[0].config.categories.items.len);
    try std.testing.expectEqual(domain.process.ProcessStatus.halted, update.process_views[0].status);
}

test "socket path uses proctmux prefix and active config hash" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    cfg.file_path = "/tmp/example-proctmux.yaml";

    const hash = try config.hash.toHash(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(hash);

    const path = try socket.pathForConfig(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(path);

    const expected = try std.fmt.allocPrint(std.testing.allocator, "/tmp/proctmux-{s}.socket", .{hash});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "create socket path removes stale file like Go CreateSocket" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    cfg.file_path = "/tmp/proctmux-zig-ipc-create-test.yaml";

    const path = try socket.pathForConfig(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(path);
    defer std.fs.deleteFileAbsolute(path) catch {};

    var stale = try std.fs.createFileAbsolute(path, .{});
    stale.close();

    const created_path = try socket.createPathForConfig(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(created_path);

    try std.testing.expectEqualStrings(path, created_path);
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(path, .{}));
}

test "get socket path requires existing responsive unix socket" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    cfg.file_path = "/tmp/proctmux-zig-ipc-get-test.yaml";

    const path = try socket.createPathForConfig(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(path);
    defer std.fs.deleteFileAbsolute(path) catch {};

    try std.testing.expectError(error.FileNotFound, socket.getPathForConfig(std.testing.allocator, &cfg));

    const address = try std.net.Address.initUnix(path);
    var listener = try address.listen(.{});
    defer listener.deinit();

    const got = try socket.getPathForConfig(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(path, got);
}

test "wait socket path polls until listener responds" {
    const path = "/tmp/proctmux-zig-ipc-wait-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    var delayed = DelayedSocketServer{};
    const thread = try std.Thread.spawn(.{}, runDelayedSocketServer, .{ path, &delayed });

    try socket.waitPath(path, 1000, 5);
    thread.join();
    if (delayed.err) |err| return err;
}

test "wait socket path times out when socket never responds" {
    const path = "/tmp/proctmux-zig-ipc-wait-timeout-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    try std.testing.expectError(error.SocketWaitTimeout, socket.waitPath(path, 20, 5));
}

test "client sends one command and parses one response" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    cfg.file_path = "/tmp/proctmux-zig-ipc-client-test.yaml";

    const path = try socket.createPathForConfig(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(path);
    defer std.fs.deleteFileAbsolute(path) catch {};

    const address = try std.net.Address.initUnix(path);
    var listener = try address.listen(.{});
    defer listener.deinit();

    var capture = OneShotCapture{};
    const thread = try std.Thread.spawn(.{}, runOneShotResponseServer, .{ &listener, &capture });

    const response = try client.sendCommandToPath(std.testing.allocator, path, "51", .restart, "web");
    defer response.deinit(std.testing.allocator);
    thread.join();
    if (capture.err) |err| return err;

    try std.testing.expectEqualStrings(
        "{\"type\":\"command\",\"request_id\":\"51\",\"label\":\"web\",\"action\":\"restart\"}\n",
        capture.requestLine(),
    );
    try std.testing.expect(response.success);
    try std.testing.expectEqualStrings("51", response.request_id);
}

test "client skips state broadcasts while waiting for command response" {
    const path = "/tmp/proctmux-zig-ipc-client-skip-state-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    const address = try std.net.Address.initUnix(path);
    var listener = try address.listen(.{});
    defer listener.deinit();

    var capture = OneShotCapture{};
    const thread = try std.Thread.spawn(.{}, runStateThenResponseServer, .{ &listener, &capture });

    const response = try client.sendCommandToPath(std.testing.allocator, path, "52", .start, "api");
    defer response.deinit(std.testing.allocator);
    thread.join();
    if (capture.err) |err| return err;

    try std.testing.expect(response.success);
    try std.testing.expectEqualStrings("52", response.request_id);
}

test "persistent client times out waiting for command response like Go" {
    const path = "/tmp/proctmux-zig-ipc-client-response-timeout-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    const address = try std.net.Address.initUnix(path);
    var listener = try address.listen(.{});
    defer listener.deinit();

    var capture = OneShotCapture{};
    const thread = try std.Thread.spawn(.{}, runNoResponseServer, .{ &listener, &capture });

    var ipc_client = try client.Client.connect(std.testing.allocator, path);
    defer ipc_client.deinit();
    ipc_client.response_timeout_ms = 20;

    _ = try ipc_client.sendCommand(.start, "api");
    try std.testing.expectError(error.CommandTimeout, ipc_client.readResponse());

    thread.join();
    if (capture.err) |err| return err;
    try std.testing.expectEqualStrings(
        "{\"type\":\"command\",\"request_id\":\"1\",\"label\":\"api\",\"action\":\"start\"}\n",
        capture.requestLine(),
    );
}

test "one-shot command client times out waiting for command response like Go" {
    const path = "/tmp/proctmux-zig-ipc-one-shot-response-timeout-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    const address = try std.net.Address.initUnix(path);
    var listener = try address.listen(.{});
    defer listener.deinit();

    var capture = OneShotCapture{};
    const thread = try std.Thread.spawn(.{}, runNoResponseServer, .{ &listener, &capture });

    try std.testing.expectError(
        error.CommandTimeout,
        client.sendCommandToPathWithTimeout(std.testing.allocator, path, "91", .restart, "api", 20),
    );

    thread.join();
    if (capture.err) |err| return err;
    try std.testing.expectEqualStrings(
        "{\"type\":\"command\",\"request_id\":\"91\",\"label\":\"api\",\"action\":\"restart\"}\n",
        capture.requestLine(),
    );
}

test "persistent client consumes state updates and command responses" {
    const path = "/tmp/proctmux-zig-ipc-persistent-client-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    try test_config.putShellProcess(&cfg, "api", "npm run dev");

    var app_state = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app_state.deinit();
    app_state.current_proc_id = domain.process.ProcessId.fromInt(1);

    var fake_controller = test_ipc.FakeProcessController{ .status = .running, .pid = 12345 };
    const state_line = try protocol.stateLine(
        std.testing.allocator,
        &app_state,
        fake_controller.controller(),
    );
    defer std.testing.allocator.free(state_line);

    var fake = test_ipc.FakeCommandHandler{};
    var state_provider = test_ipc.FakeStateProvider{ .line = state_line };
    var stopped = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, server.serveCommandsAtPathWithState, .{
        std.testing.allocator,
        path,
        fake.handler(),
        state_provider.provider(),
        &stopped,
    });
    test_ipc.waitForSocketFile(path);

    var persistent = try client.Client.connect(std.testing.allocator, path);
    defer persistent.deinit();

    var initial = try persistent.readState();
    defer initial.deinit();
    try std.testing.expectEqual(domain.process.ProcessId.fromInt(1), initial.state.current_proc_id);
    try std.testing.expectEqualStrings("api", initial.process_views[0].label);

    const request_id = try persistent.sendCommand(.start, "api");
    try std.testing.expectEqualStrings("1", request_id);

    var broadcast = try persistent.readState();
    defer broadcast.deinit();
    try std.testing.expectEqualStrings("api", broadcast.process_views[0].label);

    var response = try persistent.readResponse();
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(response.success);
    try std.testing.expectEqualStrings("1", response.request_id);

    stopped.store(true, .seq_cst);
    persistent.close();
    test_ipc.unblockServer(path);
    thread.join();
}

test "zig client lists processes from Go server" {
    const allocator = std.testing.allocator;
    const go_bin = try getGoInteropBinary(allocator);
    defer allocator.free(go_bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\  worker:
        \\    shell: "sleep 5"
        \\
        ,
    });

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    const config_path = try std.fs.path.join(allocator, &.{ cwd, "proctmux.yaml" });
    defer allocator.free(config_path);

    var before = try snapshotProctmuxSockets(allocator);
    defer deinitSocketSnapshot(allocator, &before);

    var child = std.process.Child.init(&.{ go_bin, "-f", config_path }, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    defer stopInteropChild(&child);

    const socket_path = try waitForNewResponsiveProctmuxSocket(allocator, &before, 5000);
    defer allocator.free(socket_path);
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var ipc_client = try client.Client.connect(allocator, socket_path);
    defer ipc_client.deinit();

    const request_id = try ipc_client.sendCommand(.list, "");
    try std.testing.expectEqualStrings("1", request_id);

    var response = try ipc_client.readResponse();
    defer response.deinit(allocator);

    try std.testing.expect(response.success);
    try std.testing.expectEqualStrings("1", response.request_id);
    try std.testing.expectEqual(@as(usize, 2), response.process_list.len);
    try std.testing.expectEqualStrings("api", response.process_list[0].name);
    try std.testing.expect(!response.process_list[0].running);
    try std.testing.expectEqual(@as(i64, 1), response.process_list[0].index);
    try std.testing.expectEqualStrings("worker", response.process_list[1].name);
    try std.testing.expect(!response.process_list[1].running);
    try std.testing.expectEqual(@as(i64, 2), response.process_list[1].index);
}

test "one-shot command server dispatches client request to handler" {
    const path = "/tmp/proctmux-zig-ipc-server-command-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    var fake = test_ipc.FakeCommandHandler{};
    const thread = try std.Thread.spawn(.{}, server.serveOneCommandAtPath, .{
        std.testing.allocator,
        path,
        fake.handler(),
    });
    test_ipc.waitForSocketFile(path);

    var response = try client.sendCommandToPath(std.testing.allocator, path, "99", .restart, "api");
    defer response.deinit(std.testing.allocator);
    thread.join();

    try std.testing.expectEqual(protocol.Command.restart, fake.action);
    try std.testing.expectEqualStrings("api", fake.label());
    try std.testing.expectEqualStrings("99", response.request_id);
    try std.testing.expect(response.success);
    try std.testing.expectEqual(@as(usize, 1), response.process_list.len);
    try std.testing.expectEqualStrings("api", response.process_list[0].name);
    try std.testing.expect(response.process_list[0].running);
}

test "command server handles multiple clients until stopped" {
    const path = "/tmp/proctmux-zig-ipc-server-loop-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    var fake = test_ipc.FakeCommandHandler{};
    var stopped = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, server.serveCommandsAtPath, .{
        std.testing.allocator,
        path,
        fake.handler(),
        &stopped,
    });
    test_ipc.waitForSocketFile(path);

    var list_response = try client.sendCommandToPath(std.testing.allocator, path, "1", .list, "");
    defer list_response.deinit(std.testing.allocator);
    try std.testing.expect(list_response.success);
    try std.testing.expectEqual(@as(usize, 1), list_response.process_list.len);

    var start_response = try client.sendCommandToPath(std.testing.allocator, path, "2", .start, "api");
    defer start_response.deinit(std.testing.allocator);
    try std.testing.expect(start_response.success);

    stopped.store(true, .seq_cst);
    test_ipc.unblockServer(path);
    thread.join();

    try std.testing.expectEqual(@as(usize, 2), fake.call_count);
    try std.testing.expectEqual(protocol.Command.start, fake.action);
    try std.testing.expectEqualStrings("api", fake.label());
}

test "command server rejects unauthorized peer before handling request" {
    const path = "/tmp/proctmux-zig-ipc-peer-reject-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    var fake = test_ipc.FakeCommandHandler{};
    var authorizer = test_ipc.FakePeerAuthorizer{ .err = error.UnauthorizedPeer };
    var capture = test_ipc.ServerErrorCapture{};
    const thread = try std.Thread.spawn(.{}, runOneShotServerWithAuthorizer, .{
        path,
        &fake,
        authorizer.authorizer(),
        &capture,
    });
    test_ipc.waitForSocketFile(path);

    var stream = try std.net.connectUnixSocket(path);
    stream.close();
    thread.join();

    try std.testing.expect(authorizer.called);
    try std.testing.expect(capture.err != null);
    try std.testing.expectEqual(error.UnauthorizedPeer, capture.err.?);
    try std.testing.expectEqual(@as(usize, 0), fake.call_count);
}

test "command server authorizes peer before serving request" {
    const path = "/tmp/proctmux-zig-ipc-peer-allow-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    var fake = test_ipc.FakeCommandHandler{};
    var authorizer = test_ipc.FakePeerAuthorizer{};
    var capture = test_ipc.ServerErrorCapture{};
    const thread = try std.Thread.spawn(.{}, runOneShotServerWithAuthorizer, .{
        path,
        &fake,
        authorizer.authorizer(),
        &capture,
    });
    test_ipc.waitForSocketFile(path);

    var response = try client.sendCommandToPath(std.testing.allocator, path, "101", .start, "api");
    defer response.deinit(std.testing.allocator);
    thread.join();

    if (capture.err) |err| return err;
    try std.testing.expect(authorizer.called);
    try std.testing.expect(authorizer.fd >= 0);
    try std.testing.expectEqual(@as(usize, 1), fake.call_count);
    try std.testing.expectEqual(protocol.Command.start, fake.action);
    try std.testing.expectEqualStrings("api", fake.label());
    try std.testing.expect(response.success);
}

test "command server creates owner-only socket like Go" {
    const path = "/tmp/proctmux-zig-ipc-server-mode-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    var fake = test_ipc.FakeCommandHandler{};
    var stopped = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, server.serveCommandsAtPath, .{
        std.testing.allocator,
        path,
        fake.handler(),
        &stopped,
    });
    test_ipc.waitForSocketFile(path);

    const stat = try std.fs.cwd().statFile(path);
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.mode & 0o777)));

    stopped.store(true, .seq_cst);
    test_ipc.unblockServer(path);
    thread.join();
}

test "command server sends initial state before reading client commands" {
    const path = "/tmp/proctmux-zig-ipc-server-initial-state-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    var fake = test_ipc.FakeCommandHandler{};
    var state_provider = test_ipc.FakeStateProvider{};
    var stopped = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, server.serveCommandsAtPathWithState, .{
        std.testing.allocator,
        path,
        fake.handler(),
        state_provider.provider(),
        &stopped,
    });
    test_ipc.waitForSocketFile(path);

    var stream = try std.net.connectUnixSocket(path);

    const initial_line = try test_ipc.readLine(std.testing.allocator, stream);
    defer std.testing.allocator.free(initial_line);
    try std.testing.expectEqualStrings(
        "{\"type\":\"state\",\"state\":{\"CurrentProcID\":0},\"process_views\":[]}\n",
        initial_line,
    );

    const request_line = try protocol.commandRequestLine(std.testing.allocator, "71", .list, "");
    defer std.testing.allocator.free(request_line);
    try stream.writeAll(request_line);

    const response_line = try test_ipc.readLine(std.testing.allocator, stream);
    defer std.testing.allocator.free(response_line);
    const response = try protocol.parseResponseLine(std.testing.allocator, response_line);
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(response.success);
    try std.testing.expectEqualStrings("71", response.request_id);

    stopped.store(true, .seq_cst);
    stream.close();
    test_ipc.unblockServer(path);
    thread.join();
}

test "state command server keeps client open and broadcasts mutations" {
    const path = "/tmp/proctmux-zig-ipc-server-persistent-state-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    var fake = test_ipc.FakeCommandHandler{};
    var state_provider = test_ipc.FakeStateProvider{};
    var stopped = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, server.serveCommandsAtPathWithState, .{
        std.testing.allocator,
        path,
        fake.handler(),
        state_provider.provider(),
        &stopped,
    });
    test_ipc.waitForSocketFile(path);

    var stream = try std.net.connectUnixSocket(path);

    const initial_line = try test_ipc.readLine(std.testing.allocator, stream);
    defer std.testing.allocator.free(initial_line);
    try std.testing.expectEqualStrings(state_provider.line, initial_line);

    const start_request = try protocol.commandRequestLine(std.testing.allocator, "72", .start, "api");
    defer std.testing.allocator.free(start_request);
    try stream.writeAll(start_request);

    const broadcast_line = try test_ipc.readLine(std.testing.allocator, stream);
    defer std.testing.allocator.free(broadcast_line);
    try std.testing.expectEqualStrings(state_provider.line, broadcast_line);

    const start_response_line = try test_ipc.readLine(std.testing.allocator, stream);
    defer std.testing.allocator.free(start_response_line);
    var start_response = try protocol.parseResponseLine(std.testing.allocator, start_response_line);
    defer start_response.deinit(std.testing.allocator);
    try std.testing.expect(start_response.success);
    try std.testing.expectEqualStrings("72", start_response.request_id);

    const stop_request = try protocol.commandRequestLine(std.testing.allocator, "73", .stop, "api");
    defer std.testing.allocator.free(stop_request);
    try stream.writeAll(stop_request);

    const second_broadcast_line = try test_ipc.readLine(std.testing.allocator, stream);
    defer std.testing.allocator.free(second_broadcast_line);
    try std.testing.expectEqualStrings(state_provider.line, second_broadcast_line);

    const stop_response_line = try test_ipc.readLine(std.testing.allocator, stream);
    defer std.testing.allocator.free(stop_response_line);
    var stop_response = try protocol.parseResponseLine(std.testing.allocator, stop_response_line);
    defer stop_response.deinit(std.testing.allocator);
    try std.testing.expect(stop_response.success);
    try std.testing.expectEqualStrings("73", stop_response.request_id);

    stopped.store(true, .seq_cst);
    stream.close();
    test_ipc.unblockServer(path);
    thread.join();
}

test "state command server broadcasts mutations to other connected clients" {
    const path = "/tmp/proctmux-zig-ipc-server-fanout-test.socket";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    var fake = test_ipc.FakeCommandHandler{};
    var state_provider = test_ipc.FakeStateProvider{};
    var stopped = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, server.serveCommandsAtPathWithState, .{
        std.testing.allocator,
        path,
        fake.handler(),
        state_provider.provider(),
        &stopped,
    });
    test_ipc.waitForSocketFile(path);

    var first = try std.net.connectUnixSocket(path);
    var second = try std.net.connectUnixSocket(path);

    const first_initial = try test_ipc.readLineTimeout(std.testing.allocator, first, 200);
    defer std.testing.allocator.free(first_initial);
    try std.testing.expectEqualStrings(state_provider.line, first_initial);

    const second_initial = try test_ipc.readLineTimeout(std.testing.allocator, second, 200);
    defer std.testing.allocator.free(second_initial);
    try std.testing.expectEqualStrings(state_provider.line, second_initial);

    const start_request = try protocol.commandRequestLine(std.testing.allocator, "74", .start, "api");
    defer std.testing.allocator.free(start_request);
    try first.writeAll(start_request);

    const first_broadcast = try test_ipc.readLineTimeout(std.testing.allocator, first, 200);
    defer std.testing.allocator.free(first_broadcast);
    try std.testing.expectEqualStrings(state_provider.line, first_broadcast);

    const second_broadcast = try test_ipc.readLineTimeout(std.testing.allocator, second, 200);
    defer std.testing.allocator.free(second_broadcast);
    try std.testing.expectEqualStrings(state_provider.line, second_broadcast);

    const response_line = try test_ipc.readLineTimeout(std.testing.allocator, first, 200);
    defer std.testing.allocator.free(response_line);
    var response = try protocol.parseResponseLine(std.testing.allocator, response_line);
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(response.success);
    try std.testing.expectEqualStrings("74", response.request_id);

    stopped.store(true, .seq_cst);
    first.close();
    second.close();
    test_ipc.unblockServer(path);
    thread.join();
}

const OneShotCapture = struct {
    request: [512]u8 = undefined,
    request_len: usize = 0,
    err: ?anyerror = null,

    fn requestLine(self: *const OneShotCapture) []const u8 {
        return self.request[0..self.request_len];
    }
};

const DelayedSocketServer = struct {
    err: ?anyerror = null,
};

fn getGoInteropBinary(allocator: std.mem.Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, "PROCTMUX_GO_BIN") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            if (isEnvSet(allocator, "PROCTMUX_GO_INTEROP_REQUIRED")) return err;
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn isEnvSet(allocator: std.mem.Allocator, name: []const u8) bool {
    const value = std.process.getEnvVarOwned(allocator, name) catch return false;
    allocator.free(value);
    return true;
}

fn snapshotProctmuxSockets(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    var sockets = std.StringHashMap(void).init(allocator);
    errdefer deinitSocketSnapshot(allocator, &sockets);

    var tmp_dir = try std.fs.openDirAbsolute("/tmp", .{ .iterate = true });
    defer tmp_dir.close();

    var entries = tmp_dir.iterate();
    while (try entries.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "proctmux-") or
            !std.mem.endsWith(u8, entry.name, ".socket"))
        {
            continue;
        }

        const path = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{entry.name});
        errdefer allocator.free(path);
        try sockets.put(path, {});
    }

    return sockets;
}

fn deinitSocketSnapshot(allocator: std.mem.Allocator, sockets: *std.StringHashMap(void)) void {
    var keys = sockets.keyIterator();
    while (keys.next()) |key| allocator.free(key.*);
    sockets.deinit();
}

fn waitForNewResponsiveProctmuxSocket(
    allocator: std.mem.Allocator,
    before: *const std.StringHashMap(void),
    timeout_ms: u64,
) ![]const u8 {
    const sleep_ms: u64 = 25;
    var elapsed_ms: u64 = 0;
    while (elapsed_ms < timeout_ms) : (elapsed_ms += sleep_ms) {
        var tmp_dir = try std.fs.openDirAbsolute("/tmp", .{ .iterate = true });
        defer tmp_dir.close();

        var entries = tmp_dir.iterate();
        while (try entries.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "proctmux-") or
                !std.mem.endsWith(u8, entry.name, ".socket"))
            {
                continue;
            }

            const path = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{entry.name});
            errdefer allocator.free(path);
            if (before.contains(path)) {
                allocator.free(path);
                continue;
            }

            if (probeUnixSocket(path)) return path;
            allocator.free(path);
        }

        std.Thread.sleep(sleep_ms * std.time.ns_per_ms);
    }

    return error.SocketWaitTimeout;
}

fn probeUnixSocket(path: []const u8) bool {
    var stream = std.net.connectUnixSocket(path) catch return false;
    stream.close();
    return true;
}

fn stopInteropChild(child: *std.process.Child) void {
    _ = child.kill() catch {};
}

fn runDelayedSocketServer(path: []const u8, state: *DelayedSocketServer) void {
    std.Thread.sleep(25 * std.time.ns_per_ms);
    const address = std.net.Address.initUnix(path) catch |err| {
        state.err = err;
        return;
    };
    var listener = address.listen(.{}) catch |err| {
        state.err = err;
        return;
    };
    defer listener.deinit();

    const conn = listener.accept() catch |err| {
        state.err = err;
        return;
    };
    conn.stream.close();
}

fn runOneShotResponseServer(listener: *std.net.Server, capture: *OneShotCapture) void {
    const conn = listener.accept() catch |err| {
        capture.err = err;
        return;
    };
    defer conn.stream.close();

    while (capture.request_len < capture.request.len) {
        var byte: [1]u8 = undefined;
        const n = conn.stream.read(&byte) catch |err| {
            capture.err = err;
            return;
        };
        if (n == 0) {
            capture.err = error.EndOfStream;
            return;
        }
        capture.request[capture.request_len] = byte[0];
        capture.request_len += 1;
        if (byte[0] == '\n') break;
    }

    conn.stream.writeAll("{\"type\":\"response\",\"request_id\":\"51\",\"success\":true}\n") catch |err| {
        capture.err = err;
        return;
    };
}

fn runStateThenResponseServer(listener: *std.net.Server, capture: *OneShotCapture) void {
    const conn = listener.accept() catch |err| {
        capture.err = err;
        return;
    };
    defer conn.stream.close();

    while (capture.request_len < capture.request.len) {
        var byte: [1]u8 = undefined;
        const n = conn.stream.read(&byte) catch |err| {
            capture.err = err;
            return;
        };
        if (n == 0) {
            capture.err = error.EndOfStream;
            return;
        }
        capture.request[capture.request_len] = byte[0];
        capture.request_len += 1;
        if (byte[0] == '\n') break;
    }

    conn.stream.writeAll("{\"type\":\"state\",\"state\":{\"CurrentProcID\":0},\"process_views\":[]}\n") catch |err| {
        capture.err = err;
        return;
    };
    conn.stream.writeAll("{\"type\":\"response\",\"request_id\":\"52\",\"success\":true}\n") catch |err| {
        capture.err = err;
        return;
    };
}

fn runNoResponseServer(listener: *std.net.Server, capture: *OneShotCapture) void {
    const conn = listener.accept() catch |err| {
        capture.err = err;
        return;
    };
    defer conn.stream.close();

    while (capture.request_len < capture.request.len) {
        var byte: [1]u8 = undefined;
        const n = conn.stream.read(&byte) catch |err| {
            capture.err = err;
            return;
        };
        if (n == 0) {
            capture.err = error.EndOfStream;
            return;
        }
        capture.request[capture.request_len] = byte[0];
        capture.request_len += 1;
        if (byte[0] == '\n') break;
    }

    std.Thread.sleep(200 * std.time.ns_per_ms);
}

fn runOneShotServerWithAuthorizer(
    path: []const u8,
    fake: *test_ipc.FakeCommandHandler,
    authorizer: server.PeerAuthorizer,
    capture: *test_ipc.ServerErrorCapture,
) void {
    server.serveOneCommandAtPathWithAuthorizer(
        std.testing.allocator,
        path,
        fake.handler(),
        authorizer,
    ) catch |err| {
        capture.err = err;
    };
}

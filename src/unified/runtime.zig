const std = @import("std");
const builtin = @import("builtin");
const cli = @import("../cli/root.zig");
const config = @import("../config/root.zig");
const ipc = @import("../ipc/root.zig");
const io = @import("../modes/io.zig");
const primary = @import("../primary/root.zig");
const terminal = @import("../terminal/root.zig");
const tui = @import("../tui/root.zig");
const args_mod = @import("args.zig");
const child_primary = @import("child_primary.zig");
const in_process_primary = @import("in_process_primary.zig");
const render = @import("render.zig");
const server_output = @import("server_output.zig");

const log = std.log.scoped(.unified_runtime);

pub fn run(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    parent_args: []const []const u8,
    config_file: []const u8,
    orientation: cli.UnifiedSplit,
    input: io.Input,
    output: io.Output,
) !void {
    if (builtin.is_test) {
        try runInProcess(allocator, dir, config_file, orientation, input, output);
        return;
    }

    try runWithChildProcess(allocator, dir, parent_args, config_file, orientation, input, output);
}

fn runWithChildProcess(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    parent_args: []const []const u8,
    config_file: []const u8,
    orientation: cli.UnifiedSplit,
    input: io.Input,
    output: io.Output,
) !void {
    var loaded = try config.runtime.loadInDir(allocator, dir, config_file);
    defer loaded.deinit();

    const child_args = try args_mod.childArgs(allocator, parent_args);
    defer args_mod.deinitArgs(allocator, child_args);

    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    const child_argv = try allocator.alloc([]const u8, child_args.len + 1);
    defer allocator.free(child_argv);
    child_argv[0] = exe_path;
    for (child_args, 0..) |arg, index| child_argv[index + 1] = arg;

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("PROCTMUX_EMBEDDED_PRIMARY", "1");

    const child_cwd = std.fs.path.dirname(loaded.config.file_path) orelse ".";
    const child = try child_primary.ChildPrimary.init(allocator, child_argv, &env_map, child_cwd);
    defer child.deinit();

    const socket_path = try ipc.socket.waitPathForConfig(allocator, &loaded.config);
    defer allocator.free(socket_path);

    var ipc_client = try ipc.client.Client.connect(allocator, socket_path);
    defer ipc_client.deinit();

    var session = try tui.client_session.ClientSession.init(
        allocator,
        tui.client_session.IpcTransport.transport(&ipc_client),
    );
    defer session.deinit();

    var split = tui.split_model.Model.init(args_mod.orientationForCli(orientation), &loaded.config);
    split.setServerInput(child.sink());
    const labels = try processLabels(allocator, &session);
    defer allocator.free(labels);
    split.setProcessLabels(labels);

    var stopped = std.atomic.Value(bool).init(false);
    try runInteractiveRuntime(.{
        .session = &session,
        .split = &split,
        .target = .{ .child = child },
        .ipc_client = &ipc_client,
        .input = input,
        .output = output,
        .stopped = &stopped,
        .sync_selection_after_command = true,
    });
}

fn runInProcess(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    config_file: []const u8,
    orientation: cli.UnifiedSplit,
    input: io.Input,
    output: io.Output,
) !void {
    var loaded = try config.runtime.loadInDir(allocator, dir, config_file);
    defer loaded.deinit();

    const socket_path = try ipc.socket.createPathForConfig(allocator, &loaded.config);
    defer allocator.free(socket_path);
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var primary_server = try primary.Server.init(allocator, &loaded.config);
    defer primary_server.deinit();

    var stopped = std.atomic.Value(bool).init(false);
    var primary_run = in_process_primary.PrimaryRun{
        .primary_server = &primary_server,
        .socket_path = socket_path,
        .stopped = &stopped,
    };
    const primary_thread = try std.Thread.spawn(.{}, in_process_primary.runPrimaryServer, .{&primary_run});
    var primary_joined = false;
    errdefer {
        stopped.store(true, .seq_cst);
        unblockServer(socket_path);
        if (!primary_joined) primary_thread.join();
    }
    try waitForSocketFile(socket_path);

    var ipc_client = try ipc.client.Client.connect(allocator, socket_path);
    defer ipc_client.deinit();

    var session = try tui.client_session.ClientSession.init(
        allocator,
        tui.client_session.IpcTransport.transport(&ipc_client),
    );
    defer session.deinit();

    var server_input = in_process_primary.ServerInput{
        .primary_server = &primary_server,
        .session = &session,
    };
    var split = tui.split_model.Model.init(args_mod.orientationForCli(orientation), &loaded.config);
    split.setServerInput(server_input.sink());
    const labels = try processLabels(allocator, &session);
    defer allocator.free(labels);
    split.setProcessLabels(labels);

    try runInteractiveRuntime(.{
        .session = &session,
        .split = &split,
        .target = .{ .in_process = &primary_server },
        .ipc_client = &ipc_client,
        .input = input,
        .output = output,
        .stopped = &stopped,
    });

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    primary_thread.join();
    primary_joined = true;
    try in_process_primary.finishPrimaryRun(&stopped, &primary_run);
}

const RuntimeSession = struct {
    session: *tui.client_session.ClientSession,
    split: *tui.split_model.Model,
    target: server_output.Target,
    ipc_client: *ipc.client.Client,
    input: io.Input,
    output: io.Output,
    stopped: *std.atomic.Value(bool),
    sync_selection_after_command: bool = false,
};

fn runInteractiveRuntime(runtime: RuntimeSession) !void {
    try runtime.output.writeAll(terminal.repaint.hide_cursor);
    defer runtime.output.writeAll(terminal.repaint.show_cursor) catch {};

    try resizeLayout(runtime.session, runtime.split, runtime.input, runtime.output);

    var output_state = try server_output.State.init(runtime.session.allocator, runtime.target);
    defer output_state.deinit();

    var render_mutex = std.Thread.Mutex{};
    try renderFrame(runtime.session, runtime.split, &output_state, runtime.output);
    var render_run = RenderLoop{
        .session = runtime.session,
        .split = runtime.split,
        .output_state = &output_state,
        .ipc_client = runtime.ipc_client,
        .input = runtime.input,
        .output = runtime.output,
        .stopped = runtime.stopped,
        .mutex = &render_mutex,
    };
    const render_thread = try std.Thread.spawn(.{}, runRenderLoop, .{&render_run});
    var render_joined = false;
    errdefer {
        runtime.stopped.store(true, .seq_cst);
        if (!render_joined) render_thread.join();
    }

    try runInputLoop(.{
        .session = runtime.session,
        .split = runtime.split,
        .output_state = &output_state,
        .input = runtime.input,
        .output = runtime.output,
        .mutex = &render_mutex,
        .sync_selection_after_command = runtime.sync_selection_after_command,
    });

    runtime.stopped.store(true, .seq_cst);
    render_thread.join();
    render_joined = true;
    try render_run.result.finish();
}

const ThreadResult = union(enum) {
    running,
    completed,
    failed: anyerror,

    fn finish(self: ThreadResult) !void {
        switch (self) {
            .running, .completed => {},
            .failed => |err| return err,
        }
    }
};

const InputLoop = struct {
    session: *tui.client_session.ClientSession,
    split: *tui.split_model.Model,
    output_state: *server_output.State,
    input: io.Input,
    output: io.Output,
    mutex: *std.Thread.Mutex,
    sync_selection_after_command: bool,
};

fn runInputLoop(state: InputLoop) !void {
    var buffer: [64]u8 = undefined;
    while (true) {
        const n = try state.input.readBytes(&buffer);
        if (n == 0) return;

        var index: usize = 0;
        while (index < n) {
            var key_buf: [1]u8 = undefined;
            if (tui.key_input.keyForInput(buffer[0..n], &index, &key_buf)) |key| {
                if (try handleKey(state, key)) return;
            }
        }
    }
}

fn handleKey(state: InputLoop, key: []const u8) !bool {
    state.mutex.lock();
    defer state.mutex.unlock();

    if (state.split.focusedPane() == .client) {
        const action = try state.session.handleKeyAction(key);
        if (action) |value| {
            if (value != .stop_running) {
                try state.session.readStateUpdate();
                if (state.sync_selection_after_command) try syncSelectionAfterAction(state.session, value);
            }
        } else {
            try state.split.handleKey(key);
        }
        try resizeLayout(state.session, state.split, state.input, state.output);
        try renderFrame(state.session, state.split, state.output_state, state.output);
        if (action) |value| return value == .stop_running;
        return false;
    }

    try state.split.handleKey(key);
    try resizeLayout(state.session, state.split, state.input, state.output);
    try renderFrame(state.session, state.split, state.output_state, state.output);
    return false;
}

fn syncSelectionAfterAction(
    session: *tui.client_session.ClientSession,
    action: ipc.protocol.Command,
) !void {
    switch (action) {
        .start, .restart => try session.switchToActiveProcess(),
        else => {},
    }
}

fn renderFrame(
    session: *tui.client_session.ClientSession,
    split: *const tui.split_model.Model,
    output_state: *server_output.State,
    output: io.Output,
) !void {
    const placeholder = std.mem.trim(u8, split.app_config.layout.placeholder_banner, " \t\r\n");
    const server_text = try output_state.renderText(split, session.model.active_proc_id, placeholder);
    defer session.allocator.free(server_text);
    try render.frame(session, split, server_text, output);
}

fn resizeLayout(
    session: *tui.client_session.ClientSession,
    split: *tui.split_model.Model,
    input: io.Input,
    output: io.Output,
) !void {
    const size = terminal.dimensions.fromFds(output.fd, input.fd);
    try split.resize(size.width, size.height);
    syncClientTerminalWidth(session, split);
}

fn syncClientTerminalWidth(
    session: *tui.client_session.ClientSession,
    split: *const tui.split_model.Model,
) void {
    var width = split.clientSize().width;
    if (width <= 0) width = split.content_width;
    if (width <= 0) return;
    session.model.term_width = @intCast(width);
}

fn processLabels(
    allocator: std.mem.Allocator,
    session: *const tui.client_session.ClientSession,
) ![][]const u8 {
    const labels = try allocator.alloc([]const u8, session.model.process_views.len);
    for (session.model.process_views, 0..) |view, index| labels[index] = view.label;
    return labels;
}

const RenderLoop = struct {
    session: *tui.client_session.ClientSession,
    split: *tui.split_model.Model,
    output_state: *server_output.State,
    ipc_client: *ipc.client.Client,
    input: io.Input,
    output: io.Output,
    stopped: *std.atomic.Value(bool),
    mutex: *std.Thread.Mutex,
    result: ThreadResult = .running,
};

fn runRenderLoop(state: *RenderLoop) void {
    while (!state.stopped.load(.seq_cst)) {
        std.Thread.sleep(75 * std.time.ns_per_ms);
        state.mutex.lock();
        defer state.mutex.unlock();

        readPendingState(state.session, state.ipc_client) catch |err| {
            state.result = .{ .failed = err };
            return;
        };
        resizeLayout(state.session, state.split, state.input, state.output) catch |err| {
            state.result = .{ .failed = err };
            return;
        };
        renderFrame(state.session, state.split, state.output_state, state.output) catch |err| {
            state.result = .{ .failed = err };
            return;
        };
    }
    state.result = .completed;
}

fn readPendingState(
    session: *tui.client_session.ClientSession,
    ipc_client: *ipc.client.Client,
) !void {
    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = ipc_client.stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    const ready = try std.posix.poll(&poll_fds, 0);
    if (ready == 0) return;
    if ((poll_fds[0].revents & std.posix.POLL.IN) == 0) return;

    try session.readStateUpdate();
}

fn unblockServer(path: []const u8) void {
    var stream = std.net.connectUnixSocket(path) catch |err| {
        log.debug("failed to unblock in-process primary server: {s}", .{@errorName(err)});
        return;
    };
    stream.close();
}

fn waitForSocketFile(path: []const u8) !void {
    try ipc.socket.waitPath(path, 30 * 1000, 100);
}

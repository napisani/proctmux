const std = @import("std");
const config = @import("../config/root.zig");
const ipc = @import("../ipc/root.zig");
const terminal = @import("../terminal/root.zig");
const tui = @import("../tui/root.zig");
const io = @import("io.zig");

pub fn run(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    config_file: []const u8,
    input: io.Input,
    output: io.Output,
) !void {
    var loaded = try config.runtime.loadInDir(allocator, dir, config_file);
    defer loaded.deinit();

    const socket_path = ipc.socket.getPathForConfig(allocator, &loaded.config) catch
        try ipc.socket.waitPathForConfig(allocator, &loaded.config);
    defer allocator.free(socket_path);

    var ipc_client = try ipc.client.Client.connect(allocator, socket_path);
    defer ipc_client.deinit();

    var session = try tui.client_session.ClientSession.init(
        allocator,
        tui.client_session.IpcTransport.transport(&ipc_client),
    );
    defer session.deinit();

    try output.writeAll(terminal.repaint.hide_cursor);
    defer output.writeAll(terminal.repaint.show_cursor) catch {};

    try render(&session, output);

    if (input.fd) |input_fd| {
        try pollLoop(&session, &ipc_client, input, input_fd, output);
        return;
    }

    try inputLoop(&session, input, output);
}

fn inputLoop(
    session: *tui.client_session.ClientSession,
    input: io.Input,
    output: io.Output,
) !void {
    var buffer: [64]u8 = undefined;
    while (true) {
        if (try handleInput(session, input, output, &buffer)) return;
    }
}

fn pollLoop(
    session: *tui.client_session.ClientSession,
    ipc_client: *ipc.client.Client,
    input: io.Input,
    input_fd: std.posix.fd_t,
    output: io.Output,
) !void {
    var buffer: [64]u8 = undefined;
    while (true) {
        if (try readAvailableStateUpdate(session, ipc_client)) {
            try render(session, output);
            continue;
        }

        var poll_fds = [_]std.posix.pollfd{
            .{
                .fd = input_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = ipc_client.stream.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };

        const ready = try std.posix.poll(&poll_fds, -1);
        if (ready == 0) continue;

        if ((poll_fds[1].revents & std.posix.POLL.IN) != 0) {
            if (try readAvailableStateUpdate(session, ipc_client)) try render(session, output);
        }

        if ((poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            if (try handleInput(session, input, output, &buffer)) return;
        }
    }
}

fn readAvailableStateUpdate(
    session: *tui.client_session.ClientSession,
    ipc_client: *ipc.client.Client,
) !bool {
    const update = (try ipc_client.readLatestStateIfAvailable()) orelse return false;
    try session.applyStateUpdate(update);
    return true;
}

fn handleInput(
    session: *tui.client_session.ClientSession,
    input: io.Input,
    output: io.Output,
    buffer: *[64]u8,
) !bool {
    const n = try input.readBytes(buffer);
    if (n == 0) return true;

    var should_render = false;
    var index: usize = 0;
    while (index < n) {
        var key_buf: [1]u8 = undefined;
        if (tui.key_input.keyForInput(buffer[0..n], &index, &key_buf)) |key| {
            const action = try session.handleKeyAction(key);
            if (action) |value| {
                if (tui.client_session.commandNeedsImmediateStateSync(value)) try session.readStateUpdate();
                if (value == .stop_running) {
                    should_render = true;
                    try render(session, output);
                    return true;
                }
                if (tui.client_session.commandShouldRenderImmediately(value)) {
                    try render(session, output);
                    should_render = false;
                    continue;
                }
            }
            should_render = true;
        }
    }

    if (should_render) try render(session, output);
    return false;
}

fn render(session: *tui.client_session.ClientSession, output: io.Output) !void {
    var frame = std.array_list.Managed(u8).init(session.allocator);
    defer frame.deinit();

    try frame.appendSlice(terminal.repaint.begin_frame);
    const rendered = try renderText(session);
    defer session.allocator.free(rendered);
    try io.appendTextClearingLineTails(&frame, rendered, terminal.repaint.clear_line_tail);
    try frame.appendSlice(terminal.repaint.end_frame);

    try output.writeAll(frame.items);
}

pub fn renderText(session: *tui.client_session.ClientSession) ![]const u8 {
    return tui.render.renderProcessList(session.allocator, &session.model);
}

const std = @import("std");
const config = @import("../config/root.zig");
const ipc = @import("../ipc/root.zig");
const tui = @import("../tui/root.zig");
const io = @import("io.zig");

const clear_frame_sequence = "\x1b[2J\x1b[H";

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
            try session.readStateUpdate();
            try render(session, output);
        }

        if ((poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            if (try handleInput(session, input, output, &buffer)) return;
        }
    }
}

fn handleInput(
    session: *tui.client_session.ClientSession,
    input: io.Input,
    output: io.Output,
    buffer: *[64]u8,
) !bool {
    const n = try input.readBytes(buffer);
    if (n == 0) return true;

    var index: usize = 0;
    while (index < n) {
        var key_buf: [1]u8 = undefined;
        if (tui.key_input.keyForInput(buffer[0..n], &index, &key_buf)) |key| {
            const action = try session.handleKeyAction(key);
            if (action) |value| {
                if (value != .stop_running) try session.readStateUpdate();
            }
            try render(session, output);
            if (action) |value| {
                if (value == .stop_running) return true;
            }
        }
    }

    return false;
}

fn render(session: *tui.client_session.ClientSession, output: io.Output) !void {
    try output.writeAll(clear_frame_sequence);
    const rendered = try renderText(session);
    defer session.allocator.free(rendered);
    try output.writeAll(rendered);
}

pub fn renderText(session: *tui.client_session.ClientSession) ![]const u8 {
    return tui.render.renderProcessList(session.allocator, &session.model);
}

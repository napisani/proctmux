const std = @import("std");
const builtin = @import("builtin");
const cli = @import("../cli/root.zig");
const commands = @import("../commands/root.zig");
const config = @import("../config/root.zig");
const discover = @import("../discover/root.zig");
const ipc = @import("../ipc/root.zig");
const primary = @import("../primary/root.zig");
const pty = @import("../proc/pty.zig");
const tui = @import("../tui/root.zig");
const unified = @import("../unified/root.zig");
const version = @import("../version.zig");

pub const Input = struct {
    context: *anyopaque,
    read: *const fn (context: *anyopaque, buffer: []u8) anyerror!usize,
    fd: ?std.posix.fd_t = null,

    pub fn readBytes(self: Input, buffer: []u8) !usize {
        return self.read(self.context, buffer);
    }
};

pub const Output = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,
    fd: ?std.posix.fd_t = null,

    pub fn writeAll(self: Output, bytes: []const u8) !void {
        try self.write(self.context, bytes);
    }
};

pub fn exitCodeForError(err: anyerror) u8 {
    return switch (err) {
        error.HelpRequested => 0,
        error.DeprecatedFlag,
        error.UnknownFlag,
        error.MissingFlagValue,
        error.InvalidBool,
        error.ClientUnifiedConflict,
        error.MultipleUnifiedOrientations,
        => 2,
        else => 1,
    };
}

pub fn shouldPrintGenericError(err: anyerror) bool {
    return switch (err) {
        error.DeprecatedFlag,
        error.HelpRequested,
        error.ClientUnifiedConflict,
        error.MultipleUnifiedOrientations,
        error.UnknownFlag,
        error.MissingFlagValue,
        error.InvalidBool,
        error.MissingName,
        error.UnknownSignalCommand,
        error.CommandFailed,
        => false,
        else => true,
    };
}

pub fn run(args: []const []const u8, output: Output) !void {
    var stdin = std.fs.File.stdin();
    var terminal_mode = TerminalMode.enterIfInteractive(args, stdin.handle);
    defer terminal_mode.restore();
    try runWithInput(args, FileInput.reader(&stdin), output);
}

pub fn runWithInput(args: []const []const u8, input: Input, output: Output) !void {
    try runInDirWithInput(std.fs.cwd(), args, input, output);
}

pub fn runInDir(dir: std.fs.Dir, args: []const []const u8, output: Output) !void {
    try runInDirWithInput(dir, args, EmptyInput.reader(), output);
}

pub fn runInDirWithInput(dir: std.fs.Dir, args: []const []const u8, input: Input, output: Output) !void {
    var stopped = std.atomic.Value(bool).init(false);
    try runInDirUntilStoppedWithInput(dir, args, input, output, &stopped);
}

pub fn runInDirUntilStopped(
    dir: std.fs.Dir,
    args: []const []const u8,
    output: Output,
    stopped: *std.atomic.Value(bool),
) !void {
    try runInDirUntilStoppedWithInput(dir, args, EmptyInput.reader(), output, stopped);
}

pub fn runInDirUntilStoppedWithInput(
    dir: std.fs.Dir,
    args: []const []const u8,
    input: Input,
    output: Output,
    stopped: *std.atomic.Value(bool),
) !void {
    const parsed = cli.parse(args) catch |err| switch (err) {
        error.DeprecatedFlag => {
            if (cli.deprecatedFlagMessage(args)) |message| {
                try output.writeAll(message);
                try output.writeAll("\n");
            }
            return err;
        },
        error.HelpRequested => {
            try output.writeAll(cli.usage_text);
            return;
        },
        error.ClientUnifiedConflict => {
            try output.writeAll("--client cannot be combined with unified mode options\n");
            return err;
        },
        error.MultipleUnifiedOrientations => {
            try output.writeAll("multiple unified orientation flags specified\n");
            return err;
        },
        error.UnknownFlag => {
            if (cli.unknownFlagName(args)) |name| {
                try output.writeAll("flag provided but not defined: -");
                try output.writeAll(name);
                try output.writeAll("\n");
                try output.writeAll(cli.usage_text);
            }
            return err;
        },
        error.MissingFlagValue => {
            if (cli.missingValueFlagName(args)) |name| {
                try output.writeAll("flag needs an argument: -");
                try output.writeAll(name);
                try output.writeAll("\n");
                try output.writeAll(cli.usage_text);
            }
            return err;
        },
        error.InvalidBool => {
            if (cli.invalidBoolFlag(args)) |diagnostic| {
                try output.writeAll("invalid boolean value \"");
                try output.writeAll(diagnostic.value);
                try output.writeAll("\" for -");
                try output.writeAll(diagnostic.name);
                try output.writeAll(": parse error\n");
                try output.writeAll(cli.usage_text);
            }
            return err;
        },
        else => return err,
    };
    if (std.mem.eql(u8, parsed.subcommand, "config-init")) {
        const path = try commands.config_init.runInDir(dir, parsed.args);
        try output.writeAll("Created starter configuration at ");
        try output.writeAll(path);
        try output.writeAll("\n");
        return;
    }

    if (isSignalCommand(parsed.subcommand)) {
        const allocator = std.heap.page_allocator;
        var loaded = try loadRuntimeConfig(allocator, dir, parsed.config_file);
        defer loaded.deinit();

        try commands.signal.runWithConfig(
            allocator,
            &loaded.config,
            parsed.subcommand,
            parsed.args,
            .{ .context = output.context, .write = output.write },
        );
        return;
    }

    if (parsed.mode == .client and !parsed.unified) {
        try runClient(dir, parsed.config_file, input, output);
        return;
    }

    if (parsed.unified) {
        try runUnified(dir, args, parsed.config_file, parsed.unified_orientation, input, output);
        return;
    }

    if (parsed.mode == .primary and
        !parsed.unified and
        std.mem.eql(u8, parsed.subcommand, "start"))
    {
        try runPrimaryUntilStopped(dir, parsed.config_file, input, output, stopped);
        return;
    }

    try output.writeAll(version.banner());
    try output.writeAll("\n");
}

fn runClient(
    dir: std.fs.Dir,
    config_file: []const u8,
    input: Input,
    output: Output,
) !void {
    const allocator = std.heap.page_allocator;
    var loaded = try loadRuntimeConfig(allocator, dir, config_file);
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

    try renderClient(&session, output);

    if (input.fd) |input_fd| {
        try runClientPollLoop(&session, &ipc_client, input, input_fd, output);
        return;
    }

    try runClientInputLoop(&session, input, output);
}

fn runClientInputLoop(
    session: *tui.client_session.ClientSession,
    input: Input,
    output: Output,
) !void {
    var buffer: [64]u8 = undefined;
    while (true) {
        if (try handleClientInput(session, input, output, &buffer)) return;
    }
}

fn runClientPollLoop(
    session: *tui.client_session.ClientSession,
    ipc_client: *ipc.client.Client,
    input: Input,
    input_fd: std.posix.fd_t,
    output: Output,
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
            try renderClient(session, output);
        }

        if ((poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            if (try handleClientInput(session, input, output, &buffer)) return;
        }
    }
}

fn handleClientInput(
    session: *tui.client_session.ClientSession,
    input: Input,
    output: Output,
    buffer: *[64]u8,
) !bool {
    const n = try input.readBytes(buffer);
    if (n == 0) return true;

    var index: usize = 0;
    while (index < n) {
        var key_buf: [1]u8 = undefined;
        if (keyForInput(buffer[0..n], &index, &key_buf)) |key| {
            const action = try session.handleKeyAction(key);
            if (action) |value| {
                if (value != .stop_running) try session.readStateUpdate();
            }
            try renderClient(session, output);
            if (action) |value| {
                if (value == .stop_running) return true;
            }
        }
    }

    return false;
}

fn renderClient(session: *tui.client_session.ClientSession, output: Output) !void {
    try output.writeAll(clear_frame_sequence);
    try renderClientContent(session, output);
}

fn renderClientContent(session: *tui.client_session.ClientSession, output: Output) !void {
    const rendered = try renderClientText(session);
    defer session.allocator.free(rendered);
    try output.writeAll(rendered);
}

fn renderClientText(session: *tui.client_session.ClientSession) ![]const u8 {
    return tui.render.renderProcessList(session.allocator, &session.model);
}

fn runUnified(
    dir: std.fs.Dir,
    parent_args: []const []const u8,
    config_file: []const u8,
    orientation: cli.UnifiedSplit,
    input: Input,
    output: Output,
) !void {
    if (builtin.is_test) {
        try runUnifiedInProcess(dir, config_file, orientation, input, output);
        return;
    }

    const allocator = std.heap.page_allocator;
    var loaded = try loadRuntimeConfig(allocator, dir, config_file);
    defer loaded.deinit();

    const child_args = try unified.childArgs(allocator, parent_args);
    defer unified.deinitArgs(allocator, child_args);

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
    const child = try UnifiedChildPrimary.init(allocator, child_argv, &env_map, child_cwd);
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

    var split = tui.split_model.Model.init(unified.orientationForCli(orientation), &loaded.config);
    split.setServerInput(child.sink());
    const labels = try processLabels(allocator, &session);
    defer allocator.free(labels);
    split.setProcessLabels(labels);
    try resizeUnifiedLayout(&session, &split, input, output);

    var stopped = std.atomic.Value(bool).init(false);
    var render_mutex = std.Thread.Mutex{};
    try renderUnifiedChild(&session, &split, child, output);
    var render_run = UnifiedChildRenderRun{
        .session = &session,
        .split = &split,
        .child = child,
        .ipc_client = &ipc_client,
        .input = input,
        .output = output,
        .stopped = &stopped,
        .mutex = &render_mutex,
    };
    const render_thread = try std.Thread.spawn(.{}, runUnifiedChildRenderLoop, .{&render_run});
    var render_joined = false;
    errdefer {
        stopped.store(true, .seq_cst);
        if (!render_joined) render_thread.join();
    }

    var buffer: [64]u8 = undefined;
    while (true) {
        const n = try input.readBytes(&buffer);
        if (n == 0) break;

        var index: usize = 0;
        while (index < n) {
            var key_buf: [1]u8 = undefined;
            if (keyForInput(buffer[0..n], &index, &key_buf)) |key| {
                var should_stop = false;
                {
                    render_mutex.lock();
                    defer render_mutex.unlock();

                    if (split.focusedPane() == .client) {
                        const action = try session.handleKeyAction(key);
                        if (action) |value| {
                            if (value != .stop_running) {
                                try session.readStateUpdate();
                                try syncUnifiedSelectionAfterAction(&session, value);
                            }
                        } else {
                            try split.handleKey(key);
                        }
                        try resizeUnifiedLayout(&session, &split, input, output);
                        try renderUnifiedChild(&session, &split, child, output);
                        if (action) |value| {
                            if (value == .stop_running) should_stop = true;
                        }
                    } else {
                        try split.handleKey(key);
                        try resizeUnifiedLayout(&session, &split, input, output);
                        try renderUnifiedChild(&session, &split, child, output);
                    }
                }

                if (should_stop) {
                    stopped.store(true, .seq_cst);
                    render_thread.join();
                    render_joined = true;
                    try finishUnifiedChildRenderRun(&render_run);
                    return;
                }
            }
        }
    }

    stopped.store(true, .seq_cst);
    render_thread.join();
    render_joined = true;
    try finishUnifiedChildRenderRun(&render_run);
}

fn runUnifiedInProcess(
    dir: std.fs.Dir,
    config_file: []const u8,
    orientation: cli.UnifiedSplit,
    input: Input,
    output: Output,
) !void {
    const allocator = std.heap.page_allocator;
    var loaded = try loadRuntimeConfig(allocator, dir, config_file);
    defer loaded.deinit();

    const socket_path = try ipc.socket.createPathForConfig(allocator, &loaded.config);
    defer allocator.free(socket_path);
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var primary_server = try primary.Server.init(allocator, &loaded.config);
    defer primary_server.deinit();

    var stopped = std.atomic.Value(bool).init(false);
    var primary_run = UnifiedPrimaryRun{
        .primary_server = &primary_server,
        .socket_path = socket_path,
        .stopped = &stopped,
    };
    const primary_thread = try std.Thread.spawn(.{}, runUnifiedPrimaryServer, .{&primary_run});
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

    var server_input = UnifiedServerInput{
        .primary_server = &primary_server,
        .session = &session,
    };
    var split = tui.split_model.Model.init(unified.orientationForCli(orientation), &loaded.config);
    split.setServerInput(server_input.sink());
    const labels = try processLabels(allocator, &session);
    defer allocator.free(labels);
    split.setProcessLabels(labels);
    try resizeUnifiedLayout(&session, &split, input, output);

    var render_mutex = std.Thread.Mutex{};
    try renderUnified(&session, &split, &primary_server, output);
    var render_run = UnifiedRenderRun{
        .session = &session,
        .split = &split,
        .primary_server = &primary_server,
        .ipc_client = &ipc_client,
        .input = input,
        .output = output,
        .stopped = &stopped,
        .mutex = &render_mutex,
    };
    const render_thread = try std.Thread.spawn(.{}, runUnifiedRenderLoop, .{&render_run});
    var render_joined = false;
    errdefer {
        stopped.store(true, .seq_cst);
        if (!render_joined) render_thread.join();
    }

    var buffer: [64]u8 = undefined;
    while (true) {
        const n = try input.readBytes(&buffer);
        if (n == 0) break;

        var index: usize = 0;
        while (index < n) {
            var key_buf: [1]u8 = undefined;
            if (keyForInput(buffer[0..n], &index, &key_buf)) |key| {
                var should_stop = false;
                {
                    render_mutex.lock();
                    defer render_mutex.unlock();

                    if (split.focusedPane() == .client) {
                        const action = try session.handleKeyAction(key);
                        if (action) |value| {
                            if (value != .stop_running) try session.readStateUpdate();
                        } else {
                            try split.handleKey(key);
                        }
                        try resizeUnifiedLayout(&session, &split, input, output);
                        try renderUnified(&session, &split, &primary_server, output);
                        if (action) |value| {
                            if (value == .stop_running) {
                                should_stop = true;
                            }
                        }
                    } else {
                        try split.handleKey(key);
                        try resizeUnifiedLayout(&session, &split, input, output);
                        try renderUnified(&session, &split, &primary_server, output);
                    }
                }

                if (should_stop) {
                    stopped.store(true, .seq_cst);
                    unblockServer(socket_path);
                    primary_thread.join();
                    primary_joined = true;
                    render_thread.join();
                    render_joined = true;
                    try finishUnifiedRenderRun(&render_run);
                    try finishUnifiedPrimaryRun(&stopped, &primary_run);
                    return;
                }
            }
        }
    }

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    primary_thread.join();
    primary_joined = true;
    render_thread.join();
    render_joined = true;
    try finishUnifiedRenderRun(&render_run);
    try finishUnifiedPrimaryRun(&stopped, &primary_run);
}

fn finishUnifiedPrimaryRun(stopped: *std.atomic.Value(bool), primary_run: *const UnifiedPrimaryRun) !void {
    if (primary_run.err) |err| {
        if (stopped.load(.seq_cst) and err == error.FileNotFound) return;
        return err;
    }
}

fn syncUnifiedSelectionAfterAction(
    session: *tui.client_session.ClientSession,
    action: ipc.protocol.Command,
) !void {
    switch (action) {
        .start, .restart => try session.switchToActiveProcess(),
        else => {},
    }
}

fn renderUnifiedChild(
    session: *tui.client_session.ClientSession,
    split: *const tui.split_model.Model,
    child: *UnifiedChildPrimary,
    output: Output,
) !void {
    try output.writeAll(clear_frame_sequence);
    try renderUnifiedChildContent(session, split, child, output);

    const status = try split.statusBar(session.allocator);
    defer session.allocator.free(status);
    if (status.len > 0) {
        try output.writeAll(status);
        try output.writeAll("\n");
    }
}

fn renderUnifiedChildContent(
    session: *tui.client_session.ClientSession,
    split: *const tui.split_model.Model,
    child: *UnifiedChildPrimary,
    output: Output,
) !void {
    const placeholder = std.mem.trim(u8, split.app_config.layout.placeholder_banner, " \t\r\n");
    const server_text = try unifiedChildServerText(session.allocator, child, placeholder);
    defer session.allocator.free(server_text);

    if (!split.clientVisible()) {
        try writeTextBlock(output, server_text);
        return;
    }

    const client_text = try renderClientText(session);
    defer session.allocator.free(client_text);

    switch (split.orientation) {
        .left => try writeSideBySide(output, client_text, server_text, positiveWidth(split.clientSize().width)),
        .right => try writeSideBySide(output, server_text, client_text, positiveWidth(split.serverSize().width)),
        .top => {
            try writeTextBlock(output, client_text);
            try writeTextBlock(output, server_text);
        },
        .bottom => {
            try writeTextBlock(output, server_text);
            try writeTextBlock(output, client_text);
        },
    }
}

fn unifiedChildServerText(
    allocator: std.mem.Allocator,
    child: *UnifiedChildPrimary,
    placeholder: []const u8,
) ![]const u8 {
    const output = try child.snapshot(allocator);
    defer allocator.free(output);
    if (output.len > 0) return renderTerminalText(allocator, output);
    return allocator.dupe(u8, placeholder);
}

fn renderUnified(
    session: *tui.client_session.ClientSession,
    split: *const tui.split_model.Model,
    primary_server: *primary.Server,
    output: Output,
) !void {
    try output.writeAll(clear_frame_sequence);
    try renderUnifiedContent(session, split, primary_server, output);

    const status = try split.statusBar(session.allocator);
    defer session.allocator.free(status);
    if (status.len > 0) {
        try output.writeAll(status);
        try output.writeAll("\n");
    }
}

fn renderUnifiedContent(
    session: *tui.client_session.ClientSession,
    split: *const tui.split_model.Model,
    primary_server: *primary.Server,
    output: Output,
) !void {
    const placeholder = std.mem.trim(u8, split.app_config.layout.placeholder_banner, " \t\r\n");
    const server_text = try unifiedServerText(session.allocator, primary_server, session.model.active_proc_id, placeholder);
    defer session.allocator.free(server_text);

    if (!split.clientVisible()) {
        try writeTextBlock(output, server_text);
        return;
    }

    const client_text = try renderClientText(session);
    defer session.allocator.free(client_text);

    switch (split.orientation) {
        .left => try writeSideBySide(output, client_text, server_text, positiveWidth(split.clientSize().width)),
        .right => try writeSideBySide(output, server_text, client_text, positiveWidth(split.serverSize().width)),
        .top => {
            try writeTextBlock(output, client_text);
            try writeTextBlock(output, server_text);
        },
        .bottom => {
            try writeTextBlock(output, server_text);
            try writeTextBlock(output, client_text);
        },
    }
}

fn unifiedServerText(
    allocator: std.mem.Allocator,
    primary_server: *primary.Server,
    active_proc_id: u32,
    placeholder: []const u8,
) ![]const u8 {
    if (active_proc_id != 0) {
        const scrollback = primary_server.controller.getScrollback(allocator, active_proc_id) catch |err| switch (err) {
            error.ProcessNotFound => null,
            else => return err,
        };
        if (scrollback) |text| {
            defer allocator.free(text);
            if (text.len > 0) return try renderTerminalText(allocator, text);
        }
    }

    return allocator.dupe(u8, placeholder);
}

fn renderTerminalText(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var screen = try TerminalText.init(allocator);
    defer screen.deinit();

    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte == 0x1b) {
            try consumeEscape(&screen, bytes, &index);
            continue;
        }
        if (byte == '\r') {
            if (index + 1 < bytes.len and bytes[index + 1] == '\n') {
                try screen.newline();
                index += 2;
                continue;
            }
            screen.carriageReturn();
            index += 1;
            continue;
        }
        if (byte == '\n') {
            try screen.newline();
            index += 1;
            continue;
        }
        if (byte == '\t' or byte >= 0x20) {
            try screen.writeByte(byte);
        }
        index += 1;
    }

    return screen.toOwnedSlice();
}

const TerminalText = struct {
    allocator: std.mem.Allocator,
    lines: std.array_list.Managed(std.array_list.Managed(Cell)),
    styles: std.array_list.Managed([]const u8),
    saved_main: ?TerminalSnapshot,
    row: usize,
    col: usize,
    current_style: usize,

    fn init(allocator: std.mem.Allocator) !TerminalText {
        var self = TerminalText{
            .allocator = allocator,
            .lines = std.array_list.Managed(std.array_list.Managed(Cell)).init(allocator),
            .styles = std.array_list.Managed([]const u8).init(allocator),
            .saved_main = null,
            .row = 0,
            .col = 0,
            .current_style = 0,
        };
        errdefer self.deinit();
        try self.styles.append("");
        try self.lines.append(std.array_list.Managed(Cell).init(allocator));
        return self;
    }

    fn deinit(self: *TerminalText) void {
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.deinit();
        for (self.styles.items[1..]) |style| {
            self.allocator.free(style);
        }
        self.styles.deinit();
        if (self.saved_main) |*saved| {
            saved.deinit();
        }
    }

    fn ensureRow(self: *TerminalText, row: usize) !void {
        while (self.lines.items.len <= row) {
            try self.lines.append(std.array_list.Managed(Cell).init(self.allocator));
        }
    }

    fn writeByte(self: *TerminalText, byte: u8) !void {
        try self.ensureRow(self.row);
        var line = &self.lines.items[self.row];
        while (line.items.len < self.col) {
            try line.append(.{ .byte = ' ', .style = 0 });
        }
        if (self.col < line.items.len) {
            line.items[self.col] = .{ .byte = byte, .style = self.current_style };
        } else {
            try line.append(.{ .byte = byte, .style = self.current_style });
        }
        self.col += 1;
    }

    fn carriageReturn(self: *TerminalText) void {
        self.col = 0;
    }

    fn newline(self: *TerminalText) !void {
        self.row += 1;
        self.col = 0;
        try self.ensureRow(self.row);
    }

    fn clear(self: *TerminalText) !void {
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.clearRetainingCapacity();
        self.row = 0;
        self.col = 0;
        try self.lines.append(std.array_list.Managed(Cell).init(self.allocator));
    }

    fn enterAlternateScreen(self: *TerminalText) !void {
        if (self.saved_main) |*saved| {
            saved.deinit();
            self.saved_main = null;
        }
        self.saved_main = try TerminalSnapshot.clone(self.allocator, self.lines, self.row, self.col, self.current_style);
        try self.clear();
    }

    fn exitAlternateScreen(self: *TerminalText) void {
        if (self.saved_main) |*saved| {
            for (self.lines.items) |*line| {
                line.deinit();
            }
            self.lines.deinit();

            self.lines = saved.lines;
            self.row = saved.row;
            self.col = saved.col;
            self.current_style = saved.current_style;
            self.saved_main = null;
        }
    }

    fn moveLeft(self: *TerminalText, count: usize) void {
        if (count > self.col) {
            self.col = 0;
        } else {
            self.col -= count;
        }
    }

    fn moveRight(self: *TerminalText, count: usize) void {
        self.col += count;
    }

    fn moveUp(self: *TerminalText, count: usize) void {
        if (count > self.row) {
            self.row = 0;
        } else {
            self.row -= count;
        }
    }

    fn moveDown(self: *TerminalText, count: usize) !void {
        self.row += count;
        try self.ensureRow(self.row);
    }

    fn moveTo(self: *TerminalText, row: usize, col: usize) !void {
        self.row = if (row == 0) 0 else row - 1;
        self.col = if (col == 0) 0 else col - 1;
        try self.ensureRow(self.row);
    }

    fn eraseLine(self: *TerminalText, mode: usize) !void {
        try self.ensureRow(self.row);
        var line = &self.lines.items[self.row];
        switch (mode) {
            0 => {
                if (self.col < line.items.len) {
                    line.shrinkRetainingCapacity(self.col);
                }
            },
            1 => {
                const end = @min(self.col + 1, line.items.len);
                for (line.items[0..end]) |*cell| {
                    cell.* = .{ .byte = ' ', .style = 0 };
                }
                trimManagedLineRight(line);
            },
            2 => line.clearRetainingCapacity(),
            else => {},
        }
    }

    fn setGraphicRendition(self: *TerminalText, params: []const u8) !void {
        if (isSgrReset(params)) {
            self.current_style = 0;
            return;
        }

        for (self.styles.items, 0..) |style, index| {
            if (std.mem.eql(u8, style, params)) {
                self.current_style = index;
                return;
            }
        }

        const owned = try self.allocator.dupe(u8, params);
        errdefer self.allocator.free(owned);
        try self.styles.append(owned);
        self.current_style = self.styles.items.len - 1;
    }

    fn toOwnedSlice(self: *TerminalText) ![]u8 {
        var out = std.array_list.Managed(u8).init(self.allocator);
        errdefer out.deinit();

        var active_style: usize = 0;
        for (self.lines.items, 0..) |line, line_index| {
            const end = trimmedLineEnd(line.items);
            for (line.items[0..end]) |cell| {
                if (cell.style != active_style) {
                    try self.appendStyle(&out, cell.style);
                    active_style = cell.style;
                }
                try out.append(cell.byte);
            }
            if (active_style != 0) {
                try self.appendStyle(&out, 0);
                active_style = 0;
            }
            if (line_index + 1 < self.lines.items.len) {
                try out.append('\n');
            }
        }

        return out.toOwnedSlice();
    }

    fn appendStyle(self: *TerminalText, out: *std.array_list.Managed(u8), style: usize) !void {
        if (style == 0) {
            try out.appendSlice("\x1b[0m");
            return;
        }
        try out.writer().print("\x1b[{s}m", .{self.styles.items[style]});
    }
};

const Cell = struct {
    byte: u8,
    style: usize,
};

const TerminalSnapshot = struct {
    lines: std.array_list.Managed(std.array_list.Managed(Cell)),
    row: usize,
    col: usize,
    current_style: usize,

    fn clone(
        allocator: std.mem.Allocator,
        source: std.array_list.Managed(std.array_list.Managed(Cell)),
        row: usize,
        col: usize,
        current_style: usize,
    ) !TerminalSnapshot {
        var lines = std.array_list.Managed(std.array_list.Managed(Cell)).init(allocator);
        errdefer {
            for (lines.items) |*line| {
                line.deinit();
            }
            lines.deinit();
        }

        for (source.items) |source_line| {
            var line = std.array_list.Managed(Cell).init(allocator);
            errdefer line.deinit();
            try line.appendSlice(source_line.items);
            try lines.append(line);
        }

        return .{
            .lines = lines,
            .row = row,
            .col = col,
            .current_style = current_style,
        };
    }

    fn deinit(self: *TerminalSnapshot) void {
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.deinit();
    }
};

fn trimManagedLineRight(line: *std.array_list.Managed(Cell)) void {
    var end = line.items.len;
    while (end > 0 and line.items[end - 1].byte == ' ') {
        end -= 1;
    }
    line.shrinkRetainingCapacity(end);
}

fn trimmedLineEnd(line: []const Cell) usize {
    var end = line.len;
    while (end > 0 and line[end - 1].byte == ' ') {
        end -= 1;
    }
    return end;
}

fn consumeEscape(screen: *TerminalText, bytes: []const u8, index: *usize) !void {
    const start = index.*;
    if (start + 1 >= bytes.len) {
        index.* += 1;
        return;
    }

    const introducer = bytes[start + 1];
    if (introducer == '[') {
        var end = start + 2;
        while (end < bytes.len) : (end += 1) {
            const byte = bytes[end];
            if (byte >= 0x40 and byte <= 0x7e) {
                const params = bytes[start + 2 .. end];
                try applyCsi(screen, byte, params);
                index.* = end + 1;
                return;
            }
        }
        index.* = bytes.len;
        return;
    }

    if (introducer == ']') {
        var end = start + 2;
        while (end < bytes.len) : (end += 1) {
            if (bytes[end] == 0x07) {
                index.* = end + 1;
                return;
            }
            if (bytes[end] == 0x1b and end + 1 < bytes.len and bytes[end + 1] == '\\') {
                index.* = end + 2;
                return;
            }
        }
        index.* = bytes.len;
        return;
    }

    index.* += 2;
}

fn applyCsi(screen: *TerminalText, final: u8, params: []const u8) !void {
    switch (final) {
        'A' => screen.moveUp(csiParam(params, 0, 1)),
        'B' => try screen.moveDown(csiParam(params, 0, 1)),
        'C' => screen.moveRight(csiParam(params, 0, 1)),
        'D' => screen.moveLeft(csiParam(params, 0, 1)),
        'H', 'f' => try screen.moveTo(csiParam(params, 0, 1), csiParam(params, 1, 1)),
        'h' => {
            if (isAlternateScreenMode(params)) {
                try screen.enterAlternateScreen();
            }
        },
        'l' => {
            if (isAlternateScreenMode(params)) {
                screen.exitAlternateScreen();
            }
        },
        'J' => {
            const mode = csiParam(params, 0, 0);
            if (mode == 0 or mode == 2 or mode == 3) {
                try screen.clear();
            }
        },
        'K' => try screen.eraseLine(csiParam(params, 0, 0)),
        'm' => try screen.setGraphicRendition(params),
        else => {},
    }
}

fn csiParam(params: []const u8, param_index: usize, default: usize) usize {
    var current_index: usize = 0;
    var value: usize = 0;
    var has_digit = false;

    for (params) |byte| {
        if (byte >= '0' and byte <= '9') {
            value = value * 10 + byte - '0';
            has_digit = true;
            continue;
        }
        if (byte == ';') {
            if (current_index == param_index) {
                return if (has_digit and value != 0) value else default;
            }
            current_index += 1;
            value = 0;
            has_digit = false;
            continue;
        }
        if (byte == '?') {
            continue;
        }
    }

    if (current_index == param_index) {
        return if (has_digit and value != 0) value else default;
    }
    return default;
}

fn isAlternateScreenMode(params: []const u8) bool {
    if (params.len == 0 or params[0] != '?') return false;

    var modes = std.mem.splitScalar(u8, params[1..], ';');
    while (modes.next()) |mode| {
        if (std.mem.eql(u8, mode, "47") or
            std.mem.eql(u8, mode, "1047") or
            std.mem.eql(u8, mode, "1049"))
        {
            return true;
        }
    }
    return false;
}

fn isSgrReset(params: []const u8) bool {
    if (params.len == 0) return true;

    var current_resets = true;
    var saw_param = false;
    var parts = std.mem.splitScalar(u8, params, ';');
    while (parts.next()) |part| {
        saw_param = true;
        if (part.len == 0 or std.mem.eql(u8, part, "0")) {
            current_resets = true;
        } else {
            current_resets = false;
        }
    }
    return saw_param and current_resets;
}

test "terminal text renderer contains ANSI clear screen sequences" {
    const rendered = try renderTerminalText(std.testing.allocator, "before\x1b[2Jafter\n");
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("after\n", rendered);
}

test "terminal text renderer treats carriage return as line replacement" {
    const rendered = try renderTerminalText(std.testing.allocator, "first\rsecond\r\n");
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("second\n", rendered);
}

test "terminal text renderer handles cursor movement and erase line" {
    const rendered = try renderTerminalText(std.testing.allocator, "abcdef\x1b[3D\x1b[KXYZ\n");
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("abcXYZ\n", rendered);
}

test "terminal text renderer handles absolute cursor positioning" {
    const rendered = try renderTerminalText(std.testing.allocator, "one\nsecond\x1b[1;1Htop\n");
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("top\nsecond", rendered);
}

test "terminal text renderer restores main buffer after alternate screen" {
    const rendered = try renderTerminalText(std.testing.allocator, "main\n\x1b[?1049halt-screen\n\x1b[?1049lback\n");
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("main\nback\n", rendered);
}

test "terminal text renderer preserves SGR styles" {
    const rendered = try renderTerminalText(std.testing.allocator, "\x1b[38;2;12;34;56mstyled\x1b[0m\n");
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\x1b[38;2;12;34;56mstyled\x1b[0m\n", rendered);
}

fn writeTextBlock(output: Output, text: []const u8) !void {
    if (text.len == 0) return;
    try output.writeAll(text);
    if (text[text.len - 1] != '\n') try output.writeAll("\n");
}

fn writeSideBySide(output: Output, left: []const u8, right: []const u8, left_width: usize) !void {
    var left_lines = std.mem.splitScalar(u8, left, '\n');
    var right_lines = std.mem.splitScalar(u8, right, '\n');

    while (true) {
        const left_line_opt = left_lines.next();
        const right_line_opt = right_lines.next();
        if (left_line_opt == null and right_line_opt == null) break;

        const left_line = trimLineRight(left_line_opt orelse "");
        const right_line = trimLineRight(right_line_opt orelse "");
        if (left_line.len == 0 and right_line.len == 0) continue;

        try output.writeAll(left_line);
        if (right_line.len > 0) {
            const left_display_width = displayWidth(left_line);
            const gap = if (left_display_width < left_width) left_width - left_display_width else 3;
            try writeSpaces(output, gap);
            try output.writeAll(right_line);
        }
        try output.writeAll("\n");
    }
}

fn trimLineRight(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, " \t\r");
}

fn positiveWidth(width: i32) usize {
    return if (width > 0) @intCast(width) else 1;
}

fn displayWidth(value: []const u8) usize {
    return std.unicode.utf8CountCodepoints(value) catch value.len;
}

fn writeSpaces(output: Output, count: usize) !void {
    var index: usize = 0;
    while (index < count) : (index += 1) try output.writeAll(" ");
}

const clear_frame_sequence = "\x1b[2J\x1b[H";

const default_terminal_width = 100;
const default_terminal_height = 30;

const TerminalDimensions = struct {
    width: i32,
    height: i32,
};

fn resizeUnifiedLayout(
    session: *tui.client_session.ClientSession,
    split: *tui.split_model.Model,
    input: Input,
    output: Output,
) !void {
    const size = terminalDimensions(input, output);
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

fn terminalDimensions(input: Input, output: Output) TerminalDimensions {
    if (output.fd) |fd| {
        if (terminalDimensionsFromFd(fd)) |size| return size;
    }
    if (input.fd) |fd| {
        if (terminalDimensionsFromFd(fd)) |size| return size;
    }
    return .{
        .width = default_terminal_width,
        .height = default_terminal_height,
    };
}

fn terminalDimensionsFromFd(fd: std.posix.fd_t) ?TerminalDimensions {
    var size: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };

    const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&size));
    if (std.posix.errno(rc) != .SUCCESS) return null;
    if (size.row == 0 or size.col == 0) return null;
    return .{
        .width = @intCast(size.col),
        .height = @intCast(size.row),
    };
}

fn processLabels(
    allocator: std.mem.Allocator,
    session: *const tui.client_session.ClientSession,
) ![][]const u8 {
    const labels = try allocator.alloc([]const u8, session.model.process_views.len);
    for (session.model.process_views, 0..) |view, index| labels[index] = view.label;
    return labels;
}

const UnifiedChildPrimary = struct {
    allocator: std.mem.Allocator,
    pid: std.posix.pid_t,
    pty_file: ?std.fs.File,
    output_file: ?std.fs.File,
    output: std.array_list.Managed(u8),
    mutex: std.Thread.Mutex = .{},
    output_thread: ?std.Thread = null,
    wait_thread: ?std.Thread = null,
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn init(
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        env_map: *const std.process.EnvMap,
        cwd: []const u8,
    ) !*UnifiedChildPrimary {
        const spawned = try pty.spawn(allocator, argv, env_map, cwd, 30, 100);
        errdefer spawned.master.close();

        const output_fd = try std.posix.dup(spawned.master.handle);
        const output_file: std.fs.File = .{ .handle = output_fd };
        errdefer output_file.close();

        const child = try allocator.create(UnifiedChildPrimary);
        errdefer allocator.destroy(child);

        child.* = .{
            .allocator = allocator,
            .pid = spawned.pid,
            .pty_file = spawned.master,
            .output_file = output_file,
            .output = std.array_list.Managed(u8).init(allocator),
        };
        errdefer child.output.deinit();

        child.output_thread = try std.Thread.spawn(.{}, captureUnifiedChildOutput, .{child});
        child.wait_thread = try std.Thread.spawn(.{}, waitUnifiedChild, .{child});
        return child;
    }

    fn deinit(self: *UnifiedChildPrimary) void {
        if (!self.exited.load(.seq_cst)) {
            std.posix.kill(self.pid, std.posix.SIG.INT) catch {};
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        if (!self.exited.load(.seq_cst)) {
            std.posix.kill(self.pid, std.posix.SIG.TERM) catch {};
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        if (!self.exited.load(.seq_cst)) std.posix.kill(self.pid, std.posix.SIG.KILL) catch {};

        if (self.pty_file) |file| {
            file.close();
            self.pty_file = null;
        }
        if (self.wait_thread) |thread| {
            thread.join();
            self.wait_thread = null;
        }
        if (self.output_thread) |thread| {
            thread.join();
            self.output_thread = null;
        }
        if (self.output_file) |file| {
            file.close();
            self.output_file = null;
        }
        self.output.deinit();
        self.allocator.destroy(self);
    }

    fn sink(self: *UnifiedChildPrimary) tui.split_model.InputSink {
        return .{
            .context = self,
            .write = writeInput,
        };
    }

    fn snapshot(self: *UnifiedChildPrimary, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return allocator.dupe(u8, self.output.items);
    }

    fn appendOutput(self: *UnifiedChildPrimary, bytes: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.output.appendSlice(bytes);
        const max_output = 1024 * 1024;
        if (self.output.items.len > max_output) {
            const trim = self.output.items.len - max_output;
            std.mem.copyForwards(u8, self.output.items[0..max_output], self.output.items[trim..]);
            self.output.shrinkRetainingCapacity(max_output);
        }
    }

    fn writeInput(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *UnifiedChildPrimary = @ptrCast(@alignCast(context));
        const file = self.pty_file orelse return error.ProcessNotRunning;
        try file.writeAll(bytes);
    }
};

fn captureUnifiedChildOutput(child: *UnifiedChildPrimary) void {
    const file = child.output_file orelse return;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&buffer) catch return;
        if (n == 0) return;
        child.appendOutput(buffer[0..n]) catch return;
    }
}

fn waitUnifiedChild(child: *UnifiedChildPrimary) void {
    _ = std.posix.waitpid(child.pid, 0);
    child.exited.store(true, .seq_cst);
}

const UnifiedPrimaryRun = struct {
    primary_server: *primary.Server,
    socket_path: []const u8,
    stopped: *std.atomic.Value(bool),
    err: ?anyerror = null,
};

const UnifiedRenderRun = struct {
    session: *tui.client_session.ClientSession,
    split: *tui.split_model.Model,
    primary_server: *primary.Server,
    ipc_client: *ipc.client.Client,
    input: Input,
    output: Output,
    stopped: *std.atomic.Value(bool),
    mutex: *std.Thread.Mutex,
    err: ?anyerror = null,
};

const UnifiedChildRenderRun = struct {
    session: *tui.client_session.ClientSession,
    split: *tui.split_model.Model,
    child: *UnifiedChildPrimary,
    ipc_client: *ipc.client.Client,
    input: Input,
    output: Output,
    stopped: *std.atomic.Value(bool),
    mutex: *std.Thread.Mutex,
    err: ?anyerror = null,
};

const UnifiedServerInput = struct {
    primary_server: *primary.Server,
    session: *tui.client_session.ClientSession,

    fn sink(self: *UnifiedServerInput) tui.split_model.InputSink {
        return .{
            .context = self,
            .write = write,
        };
    }

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *UnifiedServerInput = @ptrCast(@alignCast(context));
        self.primary_server.setCurrentProcess(self.session.model.active_proc_id);
        try self.primary_server.sendInputToCurrentProcess(bytes);
    }
};

fn runUnifiedPrimaryServer(state: *UnifiedPrimaryRun) void {
    state.primary_server.serveCommandsAtPath(state.socket_path, state.stopped) catch |err| {
        state.err = err;
    };
}

fn runUnifiedRenderLoop(state: *UnifiedRenderRun) void {
    while (!state.stopped.load(.seq_cst)) {
        std.Thread.sleep(75 * std.time.ns_per_ms);
        state.mutex.lock();
        defer state.mutex.unlock();

        readPendingUnifiedState(state.session, state.ipc_client) catch |err| {
            state.err = err;
            return;
        };
        resizeUnifiedLayout(state.session, state.split, state.input, state.output) catch |err| {
            state.err = err;
            return;
        };
        renderUnified(state.session, state.split, state.primary_server, state.output) catch |err| {
            state.err = err;
            return;
        };
    }
}

fn runUnifiedChildRenderLoop(state: *UnifiedChildRenderRun) void {
    while (!state.stopped.load(.seq_cst)) {
        std.Thread.sleep(75 * std.time.ns_per_ms);
        state.mutex.lock();
        defer state.mutex.unlock();

        readPendingUnifiedState(state.session, state.ipc_client) catch |err| {
            state.err = err;
            return;
        };
        resizeUnifiedLayout(state.session, state.split, state.input, state.output) catch |err| {
            state.err = err;
            return;
        };
        renderUnifiedChild(state.session, state.split, state.child, state.output) catch |err| {
            state.err = err;
            return;
        };
    }
}

fn readPendingUnifiedState(
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

fn finishUnifiedRenderRun(render_run: *const UnifiedRenderRun) !void {
    if (render_run.err) |err| return err;
}

fn finishUnifiedChildRenderRun(render_run: *const UnifiedChildRenderRun) !void {
    if (render_run.err) |err| return err;
}

fn keyForInput(bytes: []const u8, index: *usize, scratch: *[1]u8) ?[]const u8 {
    const current = index.*;
    const byte = bytes[current];

    if (byte == 0x1b and current + 2 < bytes.len and bytes[current + 1] == 'O') {
        switch (bytes[current + 2]) {
            'P' => {
                index.* += 3;
                return "f1";
            },
            'Q' => {
                index.* += 3;
                return "f2";
            },
            'R' => {
                index.* += 3;
                return "f3";
            },
            'S' => {
                index.* += 3;
                return "f4";
            },
            else => {},
        }
    }

    if (byte == 0x1b and current + 5 < bytes.len and
        bytes[current + 1] == '[' and
        bytes[current + 2] == '1' and
        bytes[current + 3] == ';' and
        bytes[current + 4] == '5')
    {
        switch (bytes[current + 5]) {
            'C' => {
                index.* += 6;
                return "ctrl+right";
            },
            'D' => {
                index.* += 6;
                return "ctrl+left";
            },
            else => {},
        }
    }

    if (byte == 0x1b and current + 4 < bytes.len and
        bytes[current + 1] == '[' and
        bytes[current + 4] == '~')
    {
        const code = bytes[current + 2 .. current + 4];
        index.* += 5;
        if (std.mem.eql(u8, code, "15")) return "f5";
        if (std.mem.eql(u8, code, "17")) return "f6";
        if (std.mem.eql(u8, code, "18")) return "f7";
        if (std.mem.eql(u8, code, "19")) return "f8";
        if (std.mem.eql(u8, code, "20")) return "f9";
        if (std.mem.eql(u8, code, "21")) return "f10";
        if (std.mem.eql(u8, code, "23")) return "f11";
        if (std.mem.eql(u8, code, "24")) return "f12";
        index.* = current;
    }

    if (byte == 0x1b and current + 3 < bytes.len and
        bytes[current + 1] == '[' and
        bytes[current + 3] == '~')
    {
        switch (bytes[current + 2]) {
            '1' => {
                index.* += 4;
                return "home";
            },
            '2' => {
                index.* += 4;
                return "insert";
            },
            '3' => {
                index.* += 4;
                return "delete";
            },
            '4' => {
                index.* += 4;
                return "end";
            },
            '5' => {
                index.* += 4;
                return "pageup";
            },
            '6' => {
                index.* += 4;
                return "pagedown";
            },
            else => {},
        }
    }

    if (byte == 0x1b and current + 2 < bytes.len and bytes[current + 1] == '[') {
        switch (bytes[current + 2]) {
            'A' => {
                index.* += 3;
                return "up";
            },
            'B' => {
                index.* += 3;
                return "down";
            },
            'C' => {
                index.* += 3;
                return "right";
            },
            'D' => {
                index.* += 3;
                return "left";
            },
            'F' => {
                index.* += 3;
                return "end";
            },
            'H' => {
                index.* += 3;
                return "home";
            },
            else => {},
        }
    }

    index.* += 1;
    return keyForByte(byte, scratch);
}

fn keyForByte(byte: u8, scratch: *[1]u8) ?[]const u8 {
    switch (byte) {
        '\n', '\r' => return "enter",
        '\t' => return "tab",
        0x1b => return "esc",
        0x03 => return "ctrl+c",
        0x04 => return "ctrl+d",
        0x0c => return "ctrl+l",
        0x17 => return "ctrl+w",
        0x1a => return "ctrl+z",
        0x08 => return "backspace",
        0x7f => return "delete",
        else => {},
    }

    if (byte >= 0x20 and byte <= 0x7e) {
        scratch[0] = byte;
        return scratch[0..];
    }
    return null;
}

test "app input parser maps arrow and ctrl-arrow sequences" {
    var index: usize = 0;
    var scratch: [1]u8 = undefined;

    try std.testing.expectEqualStrings("right", keyForInput("\x1b[C", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 3), index);

    index = 0;
    try std.testing.expectEqualStrings("left", keyForInput("\x1b[D", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 3), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+right", keyForInput("\x1b[1;5C", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 6), index);

    index = 0;
    try std.testing.expectEqualStrings("ctrl+left", keyForInput("\x1b[1;5D", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 6), index);
}

test "app input parser maps terminal control bytes" {
    var index: usize = 0;
    var scratch: [1]u8 = undefined;

    try std.testing.expectEqualStrings("ctrl+c", keyForInput("\x03", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 1), index);

    index = 0;
    const ctrl_d = keyForInput("\x04", &index, &scratch);
    try std.testing.expect(ctrl_d != null);
    try std.testing.expectEqualStrings("ctrl+d", ctrl_d.?);
    try std.testing.expectEqual(@as(usize, 1), index);

    index = 0;
    const ctrl_l = keyForInput("\x0c", &index, &scratch);
    try std.testing.expect(ctrl_l != null);
    try std.testing.expectEqualStrings("ctrl+l", ctrl_l.?);
    try std.testing.expectEqual(@as(usize, 1), index);

    index = 0;
    const ctrl_z = keyForInput("\x1a", &index, &scratch);
    try std.testing.expect(ctrl_z != null);
    try std.testing.expectEqualStrings("ctrl+z", ctrl_z.?);
    try std.testing.expectEqual(@as(usize, 1), index);
}

test "app input parser maps terminal navigation and function sequences" {
    var index: usize = 0;
    var scratch: [1]u8 = undefined;

    try std.testing.expectEqualStrings("home", keyForInput("\x1b[H", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 3), index);

    index = 0;
    try std.testing.expectEqualStrings("end", keyForInput("\x1b[F", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 3), index);

    index = 0;
    try std.testing.expectEqualStrings("insert", keyForInput("\x1b[2~", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 4), index);

    index = 0;
    try std.testing.expectEqualStrings("pageup", keyForInput("\x1b[5~", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 4), index);

    index = 0;
    try std.testing.expectEqualStrings("pagedown", keyForInput("\x1b[6~", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 4), index);

    index = 0;
    try std.testing.expectEqualStrings("f1", keyForInput("\x1bOP", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 3), index);

    index = 0;
    try std.testing.expectEqualStrings("f4", keyForInput("\x1bOS", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 3), index);

    index = 0;
    try std.testing.expectEqualStrings("f5", keyForInput("\x1b[15~", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 5), index);

    index = 0;
    try std.testing.expectEqualStrings("f12", keyForInput("\x1b[24~", &index, &scratch).?);
    try std.testing.expectEqual(@as(usize, 5), index);
}

const FileInput = struct {
    fn reader(file: *std.fs.File) Input {
        return .{
            .context = file,
            .read = read,
            .fd = file.handle,
        };
    }

    fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
        const file: *std.fs.File = @ptrCast(@alignCast(context));
        return file.read(buffer);
    }
};

const EmptyInput = struct {
    fn reader() Input {
        return .{
            .context = undefined,
            .read = read,
        };
    }

    fn read(_: *anyopaque, _: []u8) anyerror!usize {
        return 0;
    }
};

const BytesInput = struct {
    data: []const u8,
    index: usize = 0,

    fn reader(input: *BytesInput) Input {
        return .{
            .context = input,
            .read = read,
        };
    }

    fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
        const input: *BytesInput = @ptrCast(@alignCast(context));
        if (input.index >= input.data.len) return 0;

        const n = @min(buffer.len, input.data.len - input.index);
        @memcpy(buffer[0..n], input.data[input.index..][0..n]);
        input.index += n;
        return n;
    }
};

const BlockingInput = struct {
    data: []const u8,
    released: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sent: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn reader(input: *BlockingInput) Input {
        return .{
            .context = input,
            .read = read,
        };
    }

    fn release(input: *BlockingInput) void {
        input.released.store(true, .seq_cst);
    }

    fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
        const input: *BlockingInput = @ptrCast(@alignCast(context));
        while (!input.released.load(.seq_cst)) {
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
        if (input.sent.swap(true, .seq_cst)) return 0;

        const n = @min(buffer.len, input.data.len);
        @memcpy(buffer[0..n], input.data[0..n]);
        return n;
    }
};

const FileGateInput = struct {
    dir: *std.fs.Dir,
    path: []const u8,
    needle: []const u8,
    first: []const u8,
    second: []const u8,
    phase: enum { first, wait_for_file, second, done } = .first,
    index: usize = 0,

    fn reader(input: *FileGateInput) Input {
        return .{
            .context = input,
            .read = read,
        };
    }

    fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
        const input: *FileGateInput = @ptrCast(@alignCast(context));
        switch (input.phase) {
            .first => return input.readFrom(input.first, .wait_for_file, buffer),
            .wait_for_file => {
                try waitForFileContains(input.dir.*, input.path, input.needle);
                input.phase = .second;
                input.index = 0;
                return input.readFrom(input.second, .done, buffer);
            },
            .second => return input.readFrom(input.second, .done, buffer),
            .done => return 0,
        }
    }

    fn readFrom(
        input: *FileGateInput,
        data: []const u8,
        next_phase: @TypeOf(input.phase),
        buffer: []u8,
    ) !usize {
        if (input.index >= data.len) {
            input.phase = next_phase;
            input.index = 0;
            return read(input, buffer);
        }

        const n = @min(buffer.len, data.len - input.index);
        @memcpy(buffer[0..n], data[input.index..][0..n]);
        input.index += n;
        return n;
    }
};

fn runPrimaryUntilStopped(
    dir: std.fs.Dir,
    config_file: []const u8,
    input: Input,
    output: Output,
    stopped: *std.atomic.Value(bool),
) !void {
    const allocator = std.heap.page_allocator;
    var loaded = try loadRuntimeConfig(allocator, dir, config_file);
    defer loaded.deinit();

    const socket_path = try ipc.socket.createPathForConfig(allocator, &loaded.config);
    defer allocator.free(socket_path);
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var primary_server = try primary.Server.init(allocator, &loaded.config);
    defer primary_server.deinit();

    var output_run = PrimaryOutputRun{
        .allocator = allocator,
        .primary_server = &primary_server,
        .output = output,
        .placeholder = loaded.config.layout.placeholder_banner,
        .stopped = stopped,
    };
    const output_thread = try std.Thread.spawn(.{}, runPrimaryOutputLoop, .{&output_run});
    defer {
        stopped.store(true, .seq_cst);
        output_thread.join();
    }

    var input_run = PrimaryInputRun{
        .input = input,
        .primary_server = &primary_server,
        .stopped = stopped,
        .socket_path = socket_path,
    };
    const input_thread = try std.Thread.spawn(.{}, forwardPrimaryInput, .{&input_run});
    defer input_thread.join();

    try primary_server.serveCommandsAtPath(socket_path, stopped);
    if (output_run.err) |err| return err;
}

const PrimaryOutputRun = struct {
    allocator: std.mem.Allocator,
    primary_server: *primary.Server,
    output: Output,
    placeholder: []const u8,
    stopped: *std.atomic.Value(bool),
    err: ?anyerror = null,
};

const primary_clear_sequence = "\x1b[2J\x1b[H";

fn runPrimaryOutputLoop(state: *PrimaryOutputRun) void {
    var last_process_id: u32 = std.math.maxInt(u32);
    var emitted_len: usize = 0;

    while (!state.stopped.load(.seq_cst)) {
        const process_id = state.primary_server.currentProcessID();
        if (process_id != last_process_id) {
            emitted_len = 0;
            if (process_id == 0) {
                state.output.writeAll(primary_clear_sequence) catch |err| {
                    state.err = err;
                    return;
                };
                writePrimaryPlaceholder(state.output, state.placeholder) catch |err| {
                    state.err = err;
                    return;
                };
            } else {
                writePrimaryScrollbackSnapshot(state, process_id, &emitted_len, true) catch |err| {
                    state.err = err;
                    return;
                };
            }
            last_process_id = process_id;
        } else if (process_id != 0) {
            writePrimaryScrollbackDelta(state, process_id, &emitted_len) catch |err| {
                state.err = err;
                return;
            };
        }

        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
}

fn writePrimaryPlaceholder(output: Output, placeholder: []const u8) !void {
    const text = std.mem.trim(u8, placeholder, " \t\r\n");
    if (text.len == 0) {
        try output.writeAll("Select a process to stream output.");
    } else {
        try output.writeAll(text);
    }
    try output.writeAll("\n");
}

fn writePrimaryScrollbackSnapshot(
    state: *PrimaryOutputRun,
    process_id: u32,
    emitted_len: *usize,
    clear: bool,
) !void {
    const bytes = state.primary_server.controller.getScrollback(state.allocator, process_id) catch |err| switch (err) {
        error.ProcessNotFound => {
            emitted_len.* = 0;
            return;
        },
        else => return err,
    };
    defer state.allocator.free(bytes);

    if (clear) try state.output.writeAll(primary_clear_sequence);
    if (bytes.len > 0) try state.output.writeAll(bytes);
    emitted_len.* = bytes.len;
}

fn writePrimaryScrollbackDelta(
    state: *PrimaryOutputRun,
    process_id: u32,
    emitted_len: *usize,
) !void {
    const bytes = state.primary_server.controller.getScrollback(state.allocator, process_id) catch |err| switch (err) {
        error.ProcessNotFound => {
            emitted_len.* = 0;
            return;
        },
        else => return err,
    };
    defer state.allocator.free(bytes);

    if (bytes.len < emitted_len.*) {
        try state.output.writeAll(primary_clear_sequence);
        if (bytes.len > 0) try state.output.writeAll(bytes);
    } else if (bytes.len > emitted_len.*) {
        try state.output.writeAll(bytes[emitted_len.*..]);
    }
    emitted_len.* = bytes.len;
}

const PrimaryInputRun = struct {
    input: Input,
    primary_server: *primary.Server,
    stopped: *std.atomic.Value(bool),
    socket_path: []const u8,
};

fn forwardPrimaryInput(state: *PrimaryInputRun) void {
    var buffer: [64]u8 = undefined;
    while (!state.stopped.load(.seq_cst)) {
        const n = state.input.readBytes(&buffer) catch return;
        if (n == 0) return;

        if (n == 1 and buffer[0] == 0x03) {
            state.stopped.store(true, .seq_cst);
            unblockServer(state.socket_path);
            return;
        }

        if (n >= 3 and buffer[0] == 0x1b and buffer[1] == '[' and
            (buffer[2] == 'I' or buffer[2] == 'O'))
        {
            continue;
        }

        state.primary_server.sendInputToCurrentProcess(buffer[0..n]) catch {};
    }
}

fn loadRuntimeConfig(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    config_file: []const u8,
) !config.load.LoadedConfig {
    var loaded = if (config_file.len > 0)
        try config.load.loadFileInDir(allocator, dir, config_file)
    else
        try config.load.loadDefaultInDir(allocator, dir);
    errdefer loaded.deinit();

    const discovery_cwd = std.fs.path.dirname(loaded.config.file_path) orelse ".";
    try discover.apply_mod.apply(loaded.config.allocator, &loaded.config, discovery_cwd);
    return loaded;
}

fn isSignalCommand(subcommand: []const u8) bool {
    return std.mem.startsWith(u8, subcommand, "signal-");
}

const TerminalMode = struct {
    fd: std.posix.fd_t,
    original: ?std.posix.termios = null,

    fn enterIfInteractive(args: []const []const u8, fd: std.posix.fd_t) TerminalMode {
        if (!argsNeedRawTerminal(args)) return .{ .fd = fd };
        if (!std.posix.isatty(fd)) return .{ .fd = fd };

        const original = std.posix.tcgetattr(fd) catch return .{ .fd = fd };
        var raw = original;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 0;

        std.posix.tcsetattr(fd, .FLUSH, raw) catch return .{ .fd = fd };
        return .{ .fd = fd, .original = original };
    }

    fn restore(self: *TerminalMode) void {
        const original = self.original orelse return;
        std.posix.tcsetattr(self.fd, .FLUSH, original) catch {};
        self.original = null;
    }
};

fn argsNeedRawTerminal(args: []const []const u8) bool {
    const parsed = cli.parse(args) catch return false;
    if (isSignalCommand(parsed.subcommand)) return false;
    if (std.mem.eql(u8, parsed.subcommand, "config-init")) return false;
    return parsed.unified or parsed.mode == .client or std.mem.eql(u8, parsed.subcommand, "start");
}

test "app routes config-init and prints created path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runInDir(tmp.dir, &.{"config-init"}, TestOutput.writer(&out));

    try tmp.dir.access("proctmux.yaml", .{});
    try std.testing.expectEqualStrings("Created starter configuration at proctmux.yaml\n", out.items);
}

test "app prints deprecated unified toggle migration guidance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(error.DeprecatedFlag, runInDir(tmp.dir, &.{"--unified-toggle"}, TestOutput.writer(&out)));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "--unified-toggle has been removed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "hide_process_list_when_unfocused: true") != null);
}

test "deprecated CLI flag exits like Go without generic error text" {
    try std.testing.expectEqual(@as(u8, 2), exitCodeForError(error.DeprecatedFlag));
    try std.testing.expect(!shouldPrintGenericError(error.DeprecatedFlag));
}

test "app prints Go-compatible client unified conflict message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(error.ClientUnifiedConflict, runInDir(tmp.dir, &.{ "--client", "--unified" }, TestOutput.writer(&out)));
    try std.testing.expectEqual(@as(u8, 2), exitCodeForError(error.ClientUnifiedConflict));
    try std.testing.expect(!shouldPrintGenericError(error.ClientUnifiedConflict));
    try std.testing.expectEqualStrings("--client cannot be combined with unified mode options\n", out.items);
}

test "app prints Go-compatible multiple unified orientation message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(error.MultipleUnifiedOrientations, runInDir(tmp.dir, &.{ "--unified-left", "--unified-right" }, TestOutput.writer(&out)));
    try std.testing.expectEqual(@as(u8, 2), exitCodeForError(error.MultipleUnifiedOrientations));
    try std.testing.expect(!shouldPrintGenericError(error.MultipleUnifiedOrientations));
    try std.testing.expectEqualStrings("multiple unified orientation flags specified\n", out.items);
}

test "app prints Go-compatible unknown flag diagnostic and usage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(error.UnknownFlag, runInDir(tmp.dir, &.{"--bad"}, TestOutput.writer(&out)));
    try std.testing.expectEqual(@as(u8, 2), exitCodeForError(error.UnknownFlag));
    try std.testing.expect(!shouldPrintGenericError(error.UnknownFlag));
    try std.testing.expect(std.mem.startsWith(u8, out.items, "flag provided but not defined: -bad\nUsage: proctmux [options] [command]"));
}

test "app prints Go-compatible missing flag value diagnostic and usage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(error.MissingFlagValue, runInDir(tmp.dir, &.{"-f"}, TestOutput.writer(&out)));
    try std.testing.expectEqual(@as(u8, 2), exitCodeForError(error.MissingFlagValue));
    try std.testing.expect(!shouldPrintGenericError(error.MissingFlagValue));
    try std.testing.expect(std.mem.startsWith(u8, out.items, "flag needs an argument: -f\nUsage: proctmux [options] [command]"));
}

test "app prints Go-compatible invalid bool diagnostic and usage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(error.InvalidBool, runInDir(tmp.dir, &.{"--client=nope"}, TestOutput.writer(&out)));
    try std.testing.expectEqual(@as(u8, 2), exitCodeForError(error.InvalidBool));
    try std.testing.expect(!shouldPrintGenericError(error.InvalidBool));
    try std.testing.expect(std.mem.startsWith(u8, out.items, "invalid boolean value \"nope\" for -client: parse error\nUsage: proctmux [options] [command]"));
}

test "app suppresses generic stderr for signal command failures like Go" {
    try std.testing.expectEqual(@as(u8, 1), exitCodeForError(error.MissingName));
    try std.testing.expectEqual(@as(u8, 1), exitCodeForError(error.UnknownSignalCommand));
    try std.testing.expectEqual(@as(u8, 1), exitCodeForError(error.CommandFailed));
    try std.testing.expect(!shouldPrintGenericError(error.MissingName));
    try std.testing.expect(!shouldPrintGenericError(error.UnknownSignalCommand));
    try std.testing.expect(!shouldPrintGenericError(error.CommandFailed));
}

test "app prints Go-compatible CLI help for help flag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runInDir(tmp.dir, &.{"--help"}, TestOutput.writer(&out));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "Usage: proctmux [options] [command]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Options:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "-client") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "-unified-right") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Modes:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "--unified-bottom") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "signal-stop-running") != null);
}

test "app routes signal-list through config-derived socket" {
    const tmp_path = "/tmp/proctmux-zig-app-signal-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{ .sub_path = "proctmux.yaml", .data = "{}\n" });

    const real_config_path = try dir.realpathAlloc(std.testing.allocator, "proctmux.yaml");
    defer std.testing.allocator.free(real_config_path);

    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    cfg.file_path = real_config_path;

    const socket_path = try ipc.socket.createPathForConfig(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(socket_path);
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    const address = try std.net.Address.initUnix(socket_path);
    var server = try address.listen(.{});
    defer server.deinit();

    var capture = OneShotCapture{};
    var responded = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, runProbeTolerantSignalListResponseServer, .{ &server, &capture, &responded });

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    const result = runInDir(dir, &.{"signal-list"}, TestOutput.writer(&out));
    unblockServer(socket_path);
    unblockServer(socket_path);
    thread.join();
    try result;

    try std.testing.expectEqualStrings("NAME\tSTATUS\napi\trunning\nworker\tstopped\n", out.items);
    if (capture.err) |err| return err;
    try std.testing.expectEqualStrings(
        "{\"type\":\"command\",\"request_id\":\"1\",\"action\":\"list\"}\n",
        capture.requestLine(),
    );
}

test "app primary mode serves signal-list from loaded config" {
    const tmp_path = "/tmp/proctmux-zig-app-primary-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    try waitForSocketFile(socket_path);

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDir(dir, &.{"signal-list"}, TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    if (run_state.err) |err| return err;

    try std.testing.expectEqualStrings("NAME\tSTATUS\napi\tstopped\n", out.items);
}

test "app client mode connects to primary and renders process list" {
    const tmp_path = "/tmp/proctmux-zig-app-client-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    var thread_joined = false;
    errdefer {
        if (!thread_joined) {
            stopped.store(true, .seq_cst);
            unblockServer(socket_path);
            thread.join();
        }
    }
    try waitForSocketFile(socket_path);

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDir(dir, &.{"--client"}, TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;

    try std.testing.expect(std.mem.indexOf(u8, out.items, "api") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, version.banner()) == null);
}

test "app client mode refreshes render after process command broadcast" {
    const tmp_path = "/tmp/proctmux-zig-app-client-refresh-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\    stop_timeout_ms: 500
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    var thread_joined = false;
    errdefer {
        if (!thread_joined) {
            stopped.store(true, .seq_cst);
            unblockServer(socket_path);
            thread.join();
        }
    }
    try waitForSocketFile(socket_path);

    var input = BytesInput{ .data = "js" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDirWithInput(dir, &.{"--client"}, BytesInput.reader(&input), TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;

    try std.testing.expect(std.mem.indexOf(u8, out.items, "■ api") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "● api") != null);
}

test "app client mode maps down arrow to process navigation" {
    const tmp_path = "/tmp/proctmux-zig-app-client-arrow-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    var thread_joined = false;
    errdefer {
        if (!thread_joined) {
            stopped.store(true, .seq_cst);
            unblockServer(socket_path);
            thread.join();
        }
    }
    try waitForSocketFile(socket_path);

    var input = BytesInput{ .data = "\x1b[B" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDirWithInput(dir, &.{"--client"}, BytesInput.reader(&input), TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;

    try std.testing.expect(std.mem.indexOf(u8, out.items, "▶ ■ api") != null);
}

test "app client mode maps up arrow to process navigation" {
    const tmp_path = "/tmp/proctmux-zig-app-client-up-arrow-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
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

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    var thread_joined = false;
    errdefer {
        if (!thread_joined) {
            stopped.store(true, .seq_cst);
            unblockServer(socket_path);
            thread.join();
        }
    }
    try waitForSocketFile(socket_path);

    var input = BytesInput{ .data = "j\x1b[A" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDirWithInput(dir, &.{"--client"}, BytesInput.reader(&input), TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;

    try std.testing.expect(std.mem.indexOf(u8, out.items, "▶ ■ worker") != null);
}

test "app client mode accepts printable filter input" {
    const tmp_path = "/tmp/proctmux-zig-app-client-filter-input-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
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

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    var thread_joined = false;
    errdefer {
        if (!thread_joined) {
            stopped.store(true, .seq_cst);
            unblockServer(socket_path);
            thread.join();
        }
    }
    try waitForSocketFile(socket_path);

    var input = BytesInput{ .data = "/api\nq" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDirWithInput(dir, &.{"--client"}, BytesInput.reader(&input), TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;

    try std.testing.expect(std.mem.indexOf(u8, out.items, "Filter: api") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "▶ ■ api") != null);
}

test "app client mode renders command failure message and keeps running" {
    const tmp_path = "/tmp/proctmux-zig-app-client-command-failure-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{ .sub_path = "proctmux.yaml", .data = "{}\n" });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    var thread_joined = false;
    errdefer {
        if (!thread_joined) {
            stopped.store(true, .seq_cst);
            unblockServer(socket_path);
            thread.join();
        }
    }
    try waitForSocketFile(socket_path);

    var input = BytesInput{ .data = "sq" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDirWithInput(dir, &.{"--client"}, BytesInput.reader(&input), TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;

    try std.testing.expect(std.mem.indexOf(u8, out.items, "No matching processes") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Messages:\n- no process selected") != null);
}

test "app client mode quit stops running primary processes" {
    const tmp_path = "/tmp/proctmux-zig-app-client-quit-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\    autostart: true
        \\    stop_timeout_ms: 500
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    var thread_joined = false;
    errdefer {
        if (!thread_joined) {
            stopped.store(true, .seq_cst);
            unblockServer(socket_path);
            thread.join();
        }
    }
    try waitForSocketFile(socket_path);

    var input = BytesInput{ .data = "q" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDirWithInput(dir, &.{"--client"}, BytesInput.reader(&input), TestOutput.writer(&out));

    out.clearRetainingCapacity();
    try runInDir(dir, &.{"signal-list"}, TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;

    try std.testing.expectEqualStrings("NAME\tSTATUS\napi\tstopped\n", out.items);
}

test "app primary mode serves signal start list and stop commands" {
    const tmp_path = "/tmp/proctmux-zig-app-primary-control-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\    stop_timeout_ms: 500
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    errdefer {
        stopped.store(true, .seq_cst);
        unblockServer(socket_path);
        thread.join();
    }
    try waitForSocketFile(socket_path);

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runInDir(dir, &.{ "signal-start", "api" }, TestOutput.writer(&out));
    try std.testing.expectEqualStrings("", out.items);

    try runInDir(dir, &.{"signal-list"}, TestOutput.writer(&out));
    try std.testing.expectEqualStrings("NAME\tSTATUS\napi\trunning\n", out.items);

    out.clearRetainingCapacity();
    try runInDir(dir, &.{ "signal-stop", "api" }, TestOutput.writer(&out));
    try std.testing.expectEqualStrings("", out.items);

    try runInDir(dir, &.{"signal-list"}, TestOutput.writer(&out));
    try std.testing.expectEqualStrings("NAME\tSTATUS\napi\tstopped\n", out.items);

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    if (run_state.err) |err| return err;
}

test "app primary mode forwards stdin to selected running process" {
    const tmp_path = "/tmp/proctmux-zig-app-primary-stdin-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    const got_path = tmp_path ++ "/got.txt";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteFileAbsolute(got_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    cwd: "/tmp/proctmux-zig-app-primary-stdin-test"
        \\    shell: |
        \\      IFS= read line; printf '%s' "$line" > got.txt
        \\    autostart: true
        \\    stop_timeout_ms: 500
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var input = BlockingInput{ .data = "hello\n" };
    var run_state = AppPrimaryInputRun{
        .dir_path = tmp_path,
        .input = &input,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryAppWithInput, .{&run_state});
    var thread_joined = false;
    errdefer {
        input.release();
        stopped.store(true, .seq_cst);
        unblockServer(socket_path);
        if (!thread_joined) thread.join();
    }
    try waitForSocketFile(socket_path);

    try runInDir(dir, &.{ "signal-switch", "api" }, NullOutput.writer());
    input.release();
    try waitForFileContains(dir, "got.txt", "hello");

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;
}

test "app unified mode renders process list and exits on quit" {
    const tmp_path = "/tmp/proctmux-zig-app-unified-render-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\    stop_timeout_ms: 500
        \\
        ,
    });

    var input = BytesInput{ .data = "q" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runInDirWithInput(dir, &.{"--unified"}, BytesInput.reader(&input), TestOutput.writer(&out));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "api") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Client | server") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, version.banner()) == null);
}

test "app unified mode hides process list when server focused and configured" {
    const tmp_path = "/tmp/proctmux-zig-app-unified-hide-list-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\layout:
        \\  hide_process_list_when_unfocused: true
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\    stop_timeout_ms: 500
        \\
        ,
    });

    var input = BytesInput{ .data = "\x17\x17q" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runInDirWithInput(dir, &.{"--unified"}, BytesInput.reader(&input), TestOutput.writer(&out));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "process list hidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Client | server") != null);
}

test "app unified mode forwards server-focused input to selected process" {
    const tmp_path = "/tmp/proctmux-zig-app-unified-stdin-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    const got_path = tmp_path ++ "/got.txt";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteFileAbsolute(got_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    cwd: "/tmp/proctmux-zig-app-unified-stdin-test"
        \\    shell: |
        \\      IFS= read line; printf '%s' "$line" > got.txt; sleep 5
        \\    autostart: true
        \\    stop_timeout_ms: 500
        \\
        ,
    });

    var input = FileGateInput{
        .dir = &dir,
        .path = "got.txt",
        .needle = "hello",
        .first = "j\x17hello\n",
        .second = "\x17q",
    };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runInDirWithInput(dir, &.{"--unified"}, FileGateInput.reader(&input), TestOutput.writer(&out));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "▶ ● api") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "client | Server") != null);
    try waitForFileContains(dir, "got.txt", "hello");
}

const TestOutput = struct {
    fn writer(out: *std.array_list.Managed(u8)) Output {
        return .{
            .context = out,
            .write = write,
        };
    }

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const out: *std.array_list.Managed(u8) = @ptrCast(@alignCast(context));
        try out.appendSlice(bytes);
    }
};

const NullOutput = struct {
    fn writer() Output {
        return .{
            .context = undefined,
            .write = write,
        };
    }

    fn write(_: *anyopaque, _: []const u8) anyerror!void {}
};

const AppPrimaryRun = struct {
    dir_path: []const u8,
    stopped: *std.atomic.Value(bool),
    err: ?anyerror = null,
};

const AppPrimaryInputRun = struct {
    dir_path: []const u8,
    input: *BlockingInput,
    stopped: *std.atomic.Value(bool),
    err: ?anyerror = null,
};

fn runPrimaryApp(state: *AppPrimaryRun) void {
    var dir = std.fs.openDirAbsolute(state.dir_path, .{}) catch |err| {
        state.err = err;
        return;
    };
    defer dir.close();

    runInDirUntilStoppedWithInput(dir, &.{}, EmptyInput.reader(), NullOutput.writer(), state.stopped) catch |err| {
        state.err = err;
    };
}

fn runPrimaryAppWithInput(state: *AppPrimaryInputRun) void {
    var dir = std.fs.openDirAbsolute(state.dir_path, .{}) catch |err| {
        state.err = err;
        return;
    };
    defer dir.close();

    runInDirUntilStoppedWithInput(dir, &.{}, BlockingInput.reader(state.input), NullOutput.writer(), state.stopped) catch |err| {
        state.err = err;
    };
}

const OneShotCapture = struct {
    request: [512]u8 = undefined,
    request_len: usize = 0,
    response: []const u8 =
        "{\"type\":\"response\",\"request_id\":\"1\",\"success\":true,\"process_list\":[{\"index\":1,\"name\":\"api\",\"running\":true},{\"index\":2,\"name\":\"worker\",\"running\":false}]}\n",
    err: ?anyerror = null,

    fn requestLine(self: *const OneShotCapture) []const u8 {
        return self.request[0..self.request_len];
    }
};

fn runProbeTolerantSignalListResponseServer(
    server: *std.net.Server,
    capture: *OneShotCapture,
    responded: *std.atomic.Value(bool),
) void {
    const first = server.accept() catch |err| {
        capture.err = err;
        return;
    };
    const first_thread = std.Thread.spawn(.{}, handleMaybeSignalCommand, .{ first, capture, responded }) catch |err| {
        capture.err = err;
        first.stream.close();
        return;
    };

    const second = server.accept() catch |err| {
        capture.err = err;
        first_thread.join();
        return;
    };
    handleMaybeSignalCommand(second, capture, responded);
    first_thread.join();

    if (!responded.load(.seq_cst)) capture.err = error.TestExpectedCommandConnection;
}

fn handleMaybeSignalCommand(
    conn: std.net.Server.Connection,
    capture: *OneShotCapture,
    responded: *std.atomic.Value(bool),
) void {
    defer conn.stream.close();

    var request: [512]u8 = undefined;
    const len = conn.stream.read(&request) catch |err| {
        capture.err = err;
        return;
    };
    if (len == 0) return;
    if (responded.swap(true, .seq_cst)) return;

    @memcpy(capture.request[0..len], request[0..len]);
    capture.request_len = len;
    conn.stream.writeAll(capture.response) catch |err| {
        capture.err = err;
        return;
    };
}

fn unblockServer(path: []const u8) void {
    var stream = std.net.connectUnixSocket(path) catch return;
    stream.close();
}

fn waitForSocketFile(path: []const u8) !void {
    try ipc.socket.waitPath(path, 30 * 1000, 100);
}

fn waitForFileContains(dir: std.fs.Dir, path: []const u8, needle: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        const contents = dir.readFileAlloc(std.testing.allocator, path, 1024) catch |err| switch (err) {
            error.FileNotFound => {
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        defer std.testing.allocator.free(contents);
        if (std.mem.indexOf(u8, contents, needle) != null) return;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.ExpectedFileContents;
}

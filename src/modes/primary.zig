const std = @import("std");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");
const ipc = @import("../ipc/root.zig");
const primary_mod = @import("../primary/root.zig");
const io = @import("io.zig");

const log = std.log.scoped(.primary_mode);

pub fn runUntilStopped(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    config_file: []const u8,
    input: io.Input,
    output: io.Output,
    stopped: *std.atomic.Value(bool),
) !void {
    var loaded = try config.runtime.loadInDir(allocator, dir, config_file);
    defer loaded.deinit();

    const socket_path = try ipc.socket.createPathForConfig(allocator, &loaded.config);
    defer allocator.free(socket_path);
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var primary_server = try primary_mod.Server.init(allocator, &loaded.config);
    defer primary_server.deinit();

    var output_run = PrimaryOutputRun{
        .allocator = allocator,
        .primary_server = &primary_server,
        .output = output,
        .placeholder = loaded.config.layout.placeholder_banner,
        .stopped = stopped,
    };
    const output_thread = try std.Thread.spawn(.{}, runOutputLoop, .{&output_run});
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
    const input_thread = try std.Thread.spawn(.{}, forwardInput, .{&input_run});
    defer input_thread.join();

    try primary_server.serveCommandsAtPath(socket_path, stopped);
    try output_run.result.finish();
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

const PrimaryOutputRun = struct {
    allocator: std.mem.Allocator,
    primary_server: *primary_mod.Server,
    output: io.Output,
    placeholder: []const u8,
    stopped: *std.atomic.Value(bool),
    result: ThreadResult = .running,
};

const clear_sequence = "\x1b[2J\x1b[H";

fn runOutputLoop(state: *PrimaryOutputRun) void {
    var last_process_id = domain.process.ProcessId.fromInt(std.math.maxInt(u32));
    var emitted_len: usize = 0;

    while (!state.stopped.load(.seq_cst)) {
        const process_id = state.primary_server.currentProcessID();
        if (process_id != last_process_id) {
            emitted_len = 0;
            if (process_id.isNone()) {
                state.output.writeAll(clear_sequence) catch |err| {
                    state.result = .{ .failed = err };
                    return;
                };
                writePlaceholder(state.output, state.placeholder) catch |err| {
                    state.result = .{ .failed = err };
                    return;
                };
            } else {
                writeScrollbackSnapshot(state, process_id, &emitted_len, true) catch |err| {
                    state.result = .{ .failed = err };
                    return;
                };
            }
            last_process_id = process_id;
        } else if (!process_id.isNone()) {
            writeScrollbackDelta(state, process_id, &emitted_len) catch |err| {
                state.result = .{ .failed = err };
                return;
            };
        }

        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    state.result = .completed;
}

fn writePlaceholder(output: io.Output, placeholder: []const u8) !void {
    const text = std.mem.trim(u8, placeholder, " \t\r\n");
    if (text.len == 0) {
        try output.writeAll("Select a process to stream output.");
    } else {
        try output.writeAll(text);
    }
    try output.writeAll("\n");
}

fn writeScrollbackSnapshot(
    state: *PrimaryOutputRun,
    process_id: domain.process.ProcessId,
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

    if (clear) try state.output.writeAll(clear_sequence);
    if (bytes.len > 0) try state.output.writeAll(bytes);
    emitted_len.* = bytes.len;
}

fn writeScrollbackDelta(
    state: *PrimaryOutputRun,
    process_id: domain.process.ProcessId,
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
        try state.output.writeAll(clear_sequence);
        if (bytes.len > 0) try state.output.writeAll(bytes);
    } else if (bytes.len > emitted_len.*) {
        try state.output.writeAll(bytes[emitted_len.*..]);
    }
    emitted_len.* = bytes.len;
}

const PrimaryInputRun = struct {
    input: io.Input,
    primary_server: *primary_mod.Server,
    stopped: *std.atomic.Value(bool),
    socket_path: []const u8,
};

fn forwardInput(state: *PrimaryInputRun) void {
    var buffer: [64]u8 = undefined;
    while (!state.stopped.load(.seq_cst)) {
        const n = state.input.readBytes(&buffer) catch |err| {
            log.debug("stdin forwarder stopped after read error: {s}", .{@errorName(err)});
            return;
        };
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

        state.primary_server.sendInputToCurrentProcess(buffer[0..n]) catch |err| {
            log.debug("failed to forward stdin to current process: {s}", .{@errorName(err)});
        };
    }
}

fn unblockServer(path: []const u8) void {
    var stream = std.net.connectUnixSocket(path) catch |err| {
        log.debug("failed to unblock primary command server: {s}", .{@errorName(err)});
        return;
    };
    stream.close();
}

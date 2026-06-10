//! Test input/output adapters for runtime loops.
//! These adapters make interactive modes deterministic by replacing blocking terminal IO with scripted readers and captured writers.

const std = @import("std");
const modes_io = @import("../modes/io.zig");

pub const BytesInput = struct {
    data: []const u8,
    index: usize = 0,

    pub fn reader(input: *BytesInput) modes_io.Input {
        return .{
            .context = input,
            .read = read,
        };
    }

    pub fn readBytes(self: *BytesInput, buffer: []u8) !usize {
        if (self.index >= self.data.len) return 0;

        const n = @min(buffer.len, self.data.len - self.index);
        @memcpy(buffer[0..n], self.data[self.index..][0..n]);
        self.index += n;
        return n;
    }

    fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
        const input: *BytesInput = @ptrCast(@alignCast(context));
        return input.readBytes(buffer);
    }
};

pub const BlockingInput = struct {
    data: []const u8,
    released: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sent: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn reader(input: *BlockingInput) modes_io.Input {
        return .{
            .context = input,
            .read = read,
        };
    }

    pub fn release(input: *BlockingInput) void {
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

pub const FileGateInput = struct {
    dir: *std.fs.Dir,
    path: []const u8,
    needle: []const u8,
    first: []const u8,
    second: []const u8,
    phase: enum { first, wait_for_file, second, done } = .first,
    index: usize = 0,

    pub fn reader(input: *FileGateInput) modes_io.Input {
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

pub const TestOutput = struct {
    buffer: std.array_list.Managed(u8),

    pub fn writer(out: *std.array_list.Managed(u8)) modes_io.Output {
        return .{
            .context = out,
            .write = write,
        };
    }

    pub fn init(allocator: std.mem.Allocator) TestOutput {
        return .{ .buffer = std.array_list.Managed(u8).init(allocator) };
    }

    pub fn deinit(self: *TestOutput) void {
        self.buffer.deinit();
    }

    pub fn bytes(self: *const TestOutput) []const u8 {
        return self.buffer.items;
    }

    pub fn writeAll(self: *TestOutput, data: []const u8) !void {
        try self.buffer.appendSlice(data);
    }

    fn write(context: *anyopaque, data: []const u8) anyerror!void {
        const out: *std.array_list.Managed(u8) = @ptrCast(@alignCast(context));
        try out.appendSlice(data);
    }
};

pub const NullOutput = struct {
    pub fn writer() modes_io.Output {
        return .{
            .context = undefined,
            .write = write,
        };
    }

    fn write(_: *anyopaque, _: []const u8) anyerror!void {}
};

pub fn waitForFileContains(dir: std.fs.Dir, path: []const u8, needle: []const u8) !void {
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

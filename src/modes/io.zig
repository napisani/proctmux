const std = @import("std");

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

pub const BufferOutput = struct {
    buffer: *std.array_list.Managed(u8),

    pub fn writer(buffer: *std.array_list.Managed(u8), fd: ?std.posix.fd_t) Output {
        return .{
            .context = buffer,
            .write = write,
            .fd = fd,
        };
    }

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const buffer: *std.array_list.Managed(u8) = @ptrCast(@alignCast(context));
        try buffer.appendSlice(bytes);
    }
};

pub fn appendTextClearingLineTails(out: *std.array_list.Managed(u8), text: []const u8, clear_line_tail: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte != '\n') continue;

        if (index > start) try out.appendSlice(text[start..index]);
        try out.appendSlice(clear_line_tail);
        try out.append('\n');
        start = index + 1;
    }

    if (start < text.len) {
        try out.appendSlice(text[start..]);
        try out.appendSlice(clear_line_tail);
    }
}

pub fn writeTextClearingLineTails(output: Output, text: []const u8, clear_line_tail: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte != '\n') continue;

        if (index > start) try output.writeAll(text[start..index]);
        try output.writeAll(clear_line_tail);
        try output.writeAll("\n");
        start = index + 1;
    }

    if (start < text.len) {
        try output.writeAll(text[start..]);
        try output.writeAll(clear_line_tail);
    }
}

pub const FileInput = struct {
    pub fn reader(file: *std.fs.File) Input {
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

pub const EmptyInput = struct {
    pub fn reader() Input {
        return .{
            .context = undefined,
            .read = read,
        };
    }

    fn read(_: *anyopaque, _: []u8) anyerror!usize {
        return 0;
    }
};

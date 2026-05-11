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

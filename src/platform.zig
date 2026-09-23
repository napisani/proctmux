//! Zig 0.16 platform I/O adapter.
//!
//! proctmux uses blocking file and Unix-socket operations. This module owns the
//! concrete `std.Io` choice and keeps that runtime detail out of domain code.

const builtin = @import("builtin");
const std = @import("std");

var runtime_io: ?std.Io = null;

pub fn setIo(value: std.Io) void {
    runtime_io = value;
}

pub fn io() std.Io {
    if (comptime builtin.is_test) return std.testing.io;
    return runtime_io orelse std.Io.Threaded.global_single_threaded.io();
}

pub fn sleepNanoseconds(nanoseconds: u64) void {
    std.Io.sleep(io(), .fromNanoseconds(@intCast(nanoseconds)), .awake) catch {};
}

pub fn milliTimestamp() i64 {
    return std.Io.Timestamp.now(io(), .real).toMilliseconds();
}

pub fn hasEnvVar(name: []const u8) bool {
    if (comptime builtin.os.tag == .windows) return false;
    var index: usize = 0;
    while (std.c.environ[index]) |entry| : (index += 1) {
        const value = std.mem.span(entry);
        if (value.len > name.len and value[name.len] == '=' and std.mem.eql(u8, value[0..name.len], name)) return true;
    }
    return false;
}

pub fn currentEnvironmentMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var result: std.process.Environ.Map = .init(allocator);
    errdefer result.deinit();

    var len: usize = 0;
    while (std.c.environ[len]) |_| : (len += 1) {}
    const view: std.process.Environ.PosixBlock.View = .{
        .slice = @ptrCast(std.c.environ[0..len]),
    };
    try result.putPosixBlock(view);
    return result;
}

pub fn appendPrint(
    list: *std.array_list.Managed(u8),
    comptime format: []const u8,
    args: anytype,
) !void {
    const rendered = try std.fmt.allocPrint(list.allocator, format, args);
    defer list.allocator.free(rendered);
    try list.appendSlice(rendered);
}

pub const fs = struct {
    pub const Dir = std.Io.Dir;
    pub const File = std.Io.File;
    pub const path = std.fs.path;

    pub fn cwd() Dir {
        return .cwd();
    }

    pub fn makeDirAbsolute(absolute_path: []const u8) !void {
        return Dir.createDirAbsolute(io(), absolute_path, .default_dir);
    }

    pub fn deleteFileAbsolute(absolute_path: []const u8) !void {
        return Dir.deleteFileAbsolute(io(), absolute_path);
    }

    pub fn deleteDirAbsolute(absolute_path: []const u8) !void {
        return Dir.deleteDirAbsolute(io(), absolute_path);
    }

    pub fn accessAbsolute(absolute_path: []const u8, options: Dir.AccessOptions) !void {
        return Dir.accessAbsolute(io(), absolute_path, options);
    }

    pub fn openDirAbsolute(absolute_path: []const u8, options: Dir.OpenOptions) !Dir {
        return Dir.openDirAbsolute(io(), absolute_path, options);
    }

    pub fn selfExePathAlloc(allocator: std.mem.Allocator) ![]u8 {
        var buffer: [Dir.max_path_bytes]u8 = undefined;
        const len = try std.process.executablePath(io(), &buffer);
        return allocator.dupe(u8, buffer[0..len]);
    }

    pub fn close(file: File) void {
        file.close(io());
    }

    pub fn duplicate(file: File) !File {
        const duplicated = std.c.dup(file.handle);
        return switch (std.posix.errno(duplicated)) {
            .SUCCESS => .{ .handle = @intCast(duplicated), .flags = file.flags },
            else => error.DuplicateFailed,
        };
    }

    pub fn read(file: File, buffer: []u8) !usize {
        while (true) {
            const rc = std.c.read(file.handle, buffer.ptr, buffer.len);
            switch (std.posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .BADF => return error.EndOfStream,
                else => return error.FileReadFailed,
            }
        }
    }

    pub fn writeAll(file: File, bytes: []const u8) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            const rc = std.c.write(file.handle, bytes[index..].ptr, bytes.len - index);
            switch (std.posix.errno(rc)) {
                .SUCCESS => index += @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .BADF, .PIPE => return error.EndOfStream,
                else => return error.FileWriteFailed,
            }
        }
    }
};

pub const net = struct {
    const current = std.Io.net;

    pub const Stream = struct {
        handle: std.posix.fd_t,

        fn inner(self: Stream) current.Stream {
            return .{ .socket = .{
                .handle = self.handle,
                .address = .{ .ip4 = .loopback(0) },
            } };
        }

        fn fromInner(stream: current.Stream) Stream {
            return .{ .handle = stream.socket.handle };
        }

        pub fn close(self: Stream) void {
            const stream = self.inner();
            stream.close(io());
        }

        pub fn read(self: Stream, buffer: []u8) anyerror!usize {
            while (true) {
                const rc = std.c.read(self.handle, buffer.ptr, buffer.len);
                switch (std.posix.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    .AGAIN => return error.WouldBlock,
                    .BADF => return error.EndOfStream,
                    else => return error.SocketReadFailed,
                }
            }
        }

        pub fn write(self: Stream, bytes: []const u8) anyerror!usize {
            while (true) {
                const rc = std.c.write(self.handle, bytes.ptr, bytes.len);
                switch (std.posix.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    .AGAIN => return error.WouldBlock,
                    .BADF, .PIPE => return error.EndOfStream,
                    else => return error.SocketWriteFailed,
                }
            }
        }

        pub fn writeAll(self: Stream, bytes: []const u8) !void {
            var index: usize = 0;
            while (index < bytes.len) index += try self.write(bytes[index..]);
        }
    };

    pub const Connection = struct {
        stream: Stream,
    };

    pub const Server = struct {
        inner: current.Server,

        pub fn accept(self: *Server) !Connection {
            return .{ .stream = Stream.fromInner(try self.inner.accept(io())) };
        }

        pub fn deinit(self: *Server) void {
            self.inner.deinit(io());
        }
    };

    pub const Address = struct {
        inner: current.UnixAddress,

        pub fn initUnix(path: []const u8) !Address {
            return .{ .inner = try .init(path) };
        }

        pub fn listen(self: *const Address, options: current.UnixAddress.ListenOptions) !Server {
            return .{ .inner = try self.inner.listen(io(), options) };
        }
    };

    pub fn connectUnixSocket(path: []const u8) !Stream {
        const address: current.UnixAddress = try .init(path);
        return .fromInner(try address.connect(io()));
    }
};

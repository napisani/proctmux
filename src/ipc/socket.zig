//! Project socket path lifecycle.
//! The socket hash is derived from Project Config so clients find the right Primary Server without a global registry or user-supplied port.

const std = @import("std");
const config = @import("../config/root.zig");

pub fn pathForConfig(allocator: std.mem.Allocator, cfg: *const config.schema.Config) ![]const u8 {
    const hash = try config.hash.toHash(allocator, cfg);
    defer allocator.free(hash);

    return std.fmt.allocPrint(allocator, "/tmp/proctmux-{s}.socket", .{hash});
}

/// Computes and clears the socket path a Primary Server is about to bind.
/// Removing a stale file here keeps startup deterministic after crashes.
pub fn createPathForConfig(allocator: std.mem.Allocator, cfg: *const config.schema.Config) ![]const u8 {
    const path = try pathForConfig(allocator, cfg);
    errdefer allocator.free(path);

    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    return path;
}

/// Computes and verifies the socket path for clients. A successful return means
/// the file exists and accepts a probe connection.
pub fn getPathForConfig(allocator: std.mem.Allocator, cfg: *const config.schema.Config) ![]const u8 {
    const path = try pathForConfig(allocator, cfg);
    errdefer allocator.free(path);

    try std.fs.accessAbsolute(path, .{});
    try probePath(path);

    return path;
}

/// Waits for a Primary Server to create its socket during startup, polling the
/// same probe used by `getPathForConfig`.
pub fn waitPathForConfig(allocator: std.mem.Allocator, cfg: *const config.schema.Config) ![]const u8 {
    const path = try pathForConfig(allocator, cfg);
    errdefer allocator.free(path);

    try waitPath(path, 30 * 1000, 100);
    return path;
}

pub fn waitPath(path: []const u8, total_ms: u64, poll_ms: u64) !void {
    const start = std.time.milliTimestamp();
    const deadline = start + @as(i64, @intCast(total_ms));

    while (std.time.milliTimestamp() < deadline) {
        std.fs.accessAbsolute(path, .{}) catch {
            sleepMs(poll_ms);
            continue;
        };

        probePath(path) catch {
            sleepMs(poll_ms);
            continue;
        };
        return;
    }

    return error.SocketWaitTimeout;
}

pub fn probePath(path: []const u8) !void {
    var stream = try std.net.connectUnixSocket(path);
    defer stream.close();
}

fn sleepMs(ms: u64) void {
    std.Thread.sleep(ms * std.time.ns_per_ms);
}

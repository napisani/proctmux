//! Binary entrypoint.
//! All substantial startup behavior is delegated to `app` so this file only owns allocator setup, logging setup, and process exit mapping.

const std = @import("std");
const app = @import("app/root.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    const args = try allocator.alloc([]const u8, if (raw_args.len > 0) raw_args.len - 1 else 0);
    defer allocator.free(args);
    for (args, 0..) |*arg, index| arg.* = raw_args[index + 1];

    var stdout = std.fs.File.stdout();
    const output = app.Output{
        .context = &stdout,
        .write = writeFile,
        .fd = stdout.handle,
    };

    app.run(allocator, args, output) catch |err| {
        var stderr = std.fs.File.stderr();
        if (app.shouldPrintGenericError(err)) {
            try stderr.writeAll("Error: ");
            try stderr.writeAll(@errorName(err));
            try stderr.writeAll("\n");
        }
        std.process.exit(app.exitCodeForError(err));
    };
}

fn writeFile(context: *anyopaque, bytes: []const u8) anyerror!void {
    const file: *std.fs.File = @ptrCast(@alignCast(context));
    try file.writeAll(bytes);
}

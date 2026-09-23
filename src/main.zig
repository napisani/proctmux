//! Binary entrypoint.
//! All substantial startup behavior is delegated to `app` so this file only owns allocator setup, logging setup, and process exit mapping.

const std = @import("std");
const platform = @import("platform.zig");
const app = @import("app/root.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    platform.setIo(init.io);

    var arg_iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_iterator.deinit();
    _ = arg_iterator.skip();

    var args = std.array_list.Managed([]const u8).init(allocator);
    defer args.deinit();
    while (arg_iterator.next()) |arg| try args.append(arg);

    var stdout = platform.fs.File.stdout();
    const output = app.Output{
        .context = &stdout,
        .write = writeFile,
        .fd = stdout.handle,
    };

    app.run(allocator, args.items, output) catch |err| {
        const stderr = platform.fs.File.stderr();
        if (app.shouldPrintGenericError(err)) {
            try platform.fs.writeAll(stderr, "Error: ");
            try platform.fs.writeAll(stderr, @errorName(err));
            try platform.fs.writeAll(stderr, "\n");
        }
        std.process.exit(app.exitCodeForError(err));
    };
}

fn writeFile(context: *anyopaque, bytes: []const u8) anyerror!void {
    const file: *platform.fs.File = @ptrCast(@alignCast(context));
    try platform.fs.writeAll(file.*, bytes);
}

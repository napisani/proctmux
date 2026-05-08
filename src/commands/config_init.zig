const std = @import("std");
const config = @import("../config/root.zig");

const default_output_path = "proctmux.yaml";

pub fn run(args: []const []const u8) ![]const u8 {
    return runInDir(std.fs.cwd(), args);
}

pub fn runInDir(dir: std.fs.Dir, args: []const []const u8) ![]const u8 {
    const output_path = try parseOutputPath(args);

    if (std.fs.path.dirname(output_path)) |parent| {
        if (!std.mem.eql(u8, parent, ".") and parent.len > 0) {
            try dir.makePath(parent);
        }
    }

    dir.access(output_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    if (exists(dir, output_path)) return error.FileAlreadyExists;

    try dir.writeFile(.{
        .sub_path = output_path,
        .data = config.template.content(),
        .flags = .{ .exclusive = true, .mode = 0o644 },
    });

    return output_path;
}

fn parseOutputPath(args: []const []const u8) ![]const u8 {
    if (args.len > 2) return error.TooManyArguments;
    if (args.len == 2) {
        if (args[1].len == 0) return error.EmptyOutputPath;
        return args[1];
    }
    return default_output_path;
}

fn exists(dir: std.fs.Dir, path: []const u8) bool {
    dir.access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return false,
    };
    return true;
}

test "config-init writes default proctmux yaml" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const created = try runInDir(tmp.dir, &.{"config-init"});
    try std.testing.expectEqualStrings("proctmux.yaml", created);

    const contents = try tmp.dir.readFileAlloc(std.testing.allocator, "proctmux.yaml", 1024 * 1024);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "# Proctmux Configuration File") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "shell_cmd:") != null);
}

test "config-init writes requested nested path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const created = try runInDir(tmp.dir, &.{ "config-init", "nested/proctmux.yaml" });
    try std.testing.expectEqualStrings("nested/proctmux.yaml", created);

    const contents = try tmp.dir.readFileAlloc(std.testing.allocator, "nested/proctmux.yaml", 1024 * 1024);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "procs:") != null);
}

test "config-init refuses overwrite empty path and extra args" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "exists.yaml", .data = "already here" });

    try std.testing.expectError(error.FileAlreadyExists, runInDir(tmp.dir, &.{ "config-init", "exists.yaml" }));
    try std.testing.expectError(error.EmptyOutputPath, runInDir(tmp.dir, &.{ "config-init", "" }));
    try std.testing.expectError(error.TooManyArguments, runInDir(tmp.dir, &.{ "config-init", "one.yaml", "two.yaml" }));
}

test "config-init generated yaml loads through active config parser" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try runInDir(tmp.dir, &.{"config-init"});
    const contents = try tmp.dir.readFileAlloc(std.testing.allocator, "proctmux.yaml", 1024 * 1024);
    defer std.testing.allocator.free(contents);

    var loaded = try config.load.loadFromSlice(std.testing.allocator, contents, "proctmux.yaml");
    defer loaded.deinit();
    try std.testing.expect(loaded.config.procs.contains("example-process"));
}

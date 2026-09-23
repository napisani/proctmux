//! Implementation of `proctmux config-init`.
//! This command writes the commented starter config and intentionally avoids runtime discovery or validation side effects.

const std = @import("std");
const platform = @import("../platform.zig");
const config = @import("../config/root.zig");

const default_output_path = "proctmux.yaml";

pub fn run(args: []const []const u8) ![]const u8 {
    return runInDir(platform.fs.cwd(), args);
}

pub fn runInDir(dir: platform.fs.Dir, args: []const []const u8) ![]const u8 {
    const output_path = try parseOutputPath(args);

    if (platform.fs.path.dirname(output_path)) |parent| {
        if (!std.mem.eql(u8, parent, ".") and parent.len > 0) {
            try dir.createDirPath(platform.io(), parent);
        }
    }

    dir.access(platform.io(), output_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    if (exists(dir, output_path)) return error.FileAlreadyExists;

    try dir.writeFile(platform.io(), .{
        .sub_path = output_path,
        .data = config.template.content(),
        .flags = .{ .exclusive = true, .permissions = .fromMode(0o644) },
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

fn exists(dir: platform.fs.Dir, path: []const u8) bool {
    dir.access(platform.io(), path, .{}) catch |err| switch (err) {
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

    const contents = try tmp.dir.readFileAlloc(platform.io(), "proctmux.yaml", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "# Proctmux Configuration File") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "shell_cmd:") != null);
}

test "config-init writes requested nested path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const created = try runInDir(tmp.dir, &.{ "config-init", "nested/proctmux.yaml" });
    try std.testing.expectEqualStrings("nested/proctmux.yaml", created);

    const contents = try tmp.dir.readFileAlloc(platform.io(), "nested/proctmux.yaml", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "procs:") != null);
}

test "config-init refuses overwrite empty path and extra args" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(platform.io(), .{ .sub_path = "exists.yaml", .data = "already here" });

    try std.testing.expectError(error.FileAlreadyExists, runInDir(tmp.dir, &.{ "config-init", "exists.yaml" }));
    try std.testing.expectError(error.EmptyOutputPath, runInDir(tmp.dir, &.{ "config-init", "" }));
    try std.testing.expectError(error.TooManyArguments, runInDir(tmp.dir, &.{ "config-init", "one.yaml", "two.yaml" }));
}

test "config-init generated yaml loads through active config parser" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try runInDir(tmp.dir, &.{"config-init"});
    const contents = try tmp.dir.readFileAlloc(platform.io(), "proctmux.yaml", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(contents);

    var loaded = try config.load.loadFromSlice(std.testing.allocator, contents, "proctmux.yaml");
    defer loaded.deinit();
    try std.testing.expect(loaded.config.procs.contains("example-process"));
}

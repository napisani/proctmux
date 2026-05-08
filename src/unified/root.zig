const std = @import("std");
const cli = @import("../cli/root.zig");
const tui = @import("../tui/root.zig");

pub fn orientationForCli(orientation: cli.UnifiedSplit) tui.split_model.Orientation {
    return switch (orientation) {
        .none, .left => .left,
        .right => .right,
        .top => .top,
        .bottom => .bottom,
    };
}

pub fn childArgs(allocator: std.mem.Allocator, parent_args: []const []const u8) ![][]const u8 {
    var out = std.array_list.Managed([]const u8).init(allocator);
    errdefer out.deinit();

    var skip_next = false;
    for (parent_args, 0..) |arg, index| {
        if (skip_next) {
            skip_next = false;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(arg, "--unified") or
            std.ascii.eqlIgnoreCase(arg, "-unified") or
            startsWithIgnoreCase(arg, "--unified="))
        {
            continue;
        }
        if (std.ascii.eqlIgnoreCase(arg, "--client") or
            std.ascii.eqlIgnoreCase(arg, "-client") or
            startsWithIgnoreCase(arg, "--client="))
        {
            continue;
        }
        if (std.ascii.eqlIgnoreCase(arg, "--mode") or
            std.ascii.eqlIgnoreCase(arg, "-mode"))
        {
            if (index + 1 < parent_args.len) skip_next = true;
            continue;
        }
        if (startsWithIgnoreCase(arg, "--mode=")) continue;
        if (std.ascii.eqlIgnoreCase(arg, "--unified-left") or
            std.ascii.eqlIgnoreCase(arg, "-unified-left") or
            std.ascii.eqlIgnoreCase(arg, "--unified-right") or
            std.ascii.eqlIgnoreCase(arg, "-unified-right") or
            std.ascii.eqlIgnoreCase(arg, "--unified-top") or
            std.ascii.eqlIgnoreCase(arg, "-unified-top") or
            std.ascii.eqlIgnoreCase(arg, "--unified-bottom") or
            std.ascii.eqlIgnoreCase(arg, "-unified-bottom"))
        {
            continue;
        }

        try out.append(arg);
    }

    try out.append("--mode");
    try out.append("primary");
    return out.toOwnedSlice();
}

pub fn deinitArgs(allocator: std.mem.Allocator, args: []const []const u8) void {
    allocator.free(args);
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

test "unified child args filter parent-only flags like Go" {
    const args = try childArgs(std.testing.allocator, &.{
        "--unified",
        "--unified-right",
        "-f",
        "config.yaml",
        "--mode",
        "client",
        "start",
        "--client=false",
    });
    defer deinitArgs(std.testing.allocator, args);

    try expectArgs(args, &.{ "-f", "config.yaml", "start", "--mode", "primary" });
}

test "unified child args filter equals-mode and single-dash unified flags like Go" {
    const args = try childArgs(std.testing.allocator, &.{
        "-unified",
        "-unified-left",
        "--mode=client",
        "--unified=true",
        "signal-list",
    });
    defer deinitArgs(std.testing.allocator, args);

    try expectArgs(args, &.{ "signal-list", "--mode", "primary" });
}

fn expectArgs(actual: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |item, index| {
        try std.testing.expectEqualStrings(item, actual[index]);
    }
}

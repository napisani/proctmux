//! Makefile process discovery.
//! The parser extracts likely user targets while avoiding targets that are internal, pattern-based, or unsuitable as long-running proctmux processes.

const std = @import("std");
const config = @import("../config/root.zig");

pub const ProcessMap = config.schema.ProcessMap;

pub fn discover(allocator: std.mem.Allocator, cwd: []const u8) !ProcessMap {
    const path = try std.fs.path.join(allocator, &.{ cwd, "Makefile" });
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.SourceNotFound,
        else => return err,
    };
    defer allocator.free(data);

    var procs = ProcessMap.init(allocator);
    errdefer deinitProcessMap(allocator, &procs);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const target = parseTarget(line) orelse continue;
        const name = try std.fmt.allocPrint(allocator, "make:{s}", .{target});
        errdefer allocator.free(name);
        if (procs.contains(name)) {
            allocator.free(name);
            continue;
        }

        var proc = config.schema.ProcessConfig.empty(allocator);
        proc.owns_scalar_strings = true;
        proc.shell = try std.fmt.allocPrint(allocator, "make {s}", .{target});
        proc.cwd = try allocator.dupe(u8, cwd);
        proc.description = try allocator.dupe(u8, "Auto-discovered Makefile target");
        try config.schema.appendOwned(allocator, &proc.categories, "makefile");
        try procs.put(name, proc);
    }

    return procs;
}

fn parseTarget(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and isTargetChar(line[i])) : (i += 1) {}
    if (i == 0 or i >= line.len or line[i] != ':') return null;
    return line[0..i];
}

fn isTargetChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '_' or c == '.' or c == '-';
}

pub fn deinitProcessMap(allocator: std.mem.Allocator, procs: *ProcessMap) void {
    var it = procs.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    procs.deinit();
}

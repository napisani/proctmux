const std = @import("std");
const version = @import("version.zig");

pub fn main() void {
    std.debug.print("{s}\n", .{version.banner()});
}

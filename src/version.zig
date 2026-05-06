const std = @import("std");

pub const app_name = "proctmux";
pub const version = "0.1.0-zig-dev";

pub fn banner() []const u8 {
    return app_name ++ " " ++ version;
}

test "banner includes app name and development version" {
    try std.testing.expectEqualStrings("proctmux 0.1.0-zig-dev", banner());
}

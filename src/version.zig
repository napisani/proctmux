const std = @import("std");
const options = @import("version_options");

pub const app_name = "proctmux";
pub const version = options.version;

pub fn banner() []const u8 {
    return app_name ++ " " ++ version;
}

test "banner includes app name and development version" {
    try std.testing.expectEqualStrings("proctmux 1.0.0-dev", banner());
}

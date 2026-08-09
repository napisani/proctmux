//! Build-time version metadata.
//! The generated version option is isolated here so CLI and packaging code can read one stable value.

const std = @import("std");
const options = @import("version_options");

pub const app_name = "proctmux";
pub const version = options.version;

pub fn banner() []const u8 {
    return app_name ++ " " ++ version;
}

test "banner includes app name and configured version" {
    try std.testing.expectEqualStrings(app_name ++ " " ++ version, banner());
}

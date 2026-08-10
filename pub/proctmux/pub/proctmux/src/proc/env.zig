//! Environment construction for child processes and hooks.
//! Parent environment inheritance, PATH augmentation, and per-process overrides are resolved here to keep spawn paths deterministic.

const std = @import("std");
const config = @import("../config/root.zig");

/// Builds the child environment from parent process state plus process config.
/// Configured env values override inherited values after PATH augmentation.
pub fn buildMap(
    allocator: std.mem.Allocator,
    proc_cfg: *const config.schema.ProcessConfig,
) !std.process.EnvMap {
    var env_map = try std.process.getEnvMap(allocator);
    errdefer env_map.deinit();

    if (proc_cfg.add_path.items.len > 0) {
        var path = std.array_list.Managed(u8).init(allocator);
        defer path.deinit();

        if (env_map.get("PATH")) |current| try path.appendSlice(current);
        for (proc_cfg.add_path.items) |part| {
            try path.append(':');
            try path.appendSlice(part);
        }
        try env_map.put("PATH", path.items);
    }

    var it = proc_cfg.env.iterator();
    while (it.next()) |entry| {
        try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    return env_map;
}

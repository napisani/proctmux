//! Process output capture thread.
//! Output is copied from PTY/pipe handles into ring buffers without blocking process lifecycle orchestration.

const std = @import("std");
const instance_mod = @import("instance.zig");

const log = std.log.scoped(.proc_output);

/// Copies child output into the process scrollback until the handle closes.
/// Errors end capture instead of surfacing through the controller thread.
pub fn capture(instance: *instance_mod.Instance) void {
    var file = instance.handle.outputFile();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch |err| {
            log.debug("process output capture stopped after read error: {s}", .{@errorName(err)});
            return;
        };
        if (n == 0) return;
        _ = instance.scrollback.write(buf[0..n]);
    }
}

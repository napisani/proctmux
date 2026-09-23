//! proctmux libghostty-vt C API shim.
//!
//! Terminal support code references Ghostty's C string carrier through config
//! modules, but proctmux does not embed Ghostty's application C entry point.

const global = @import("global.zig");

pub const String = extern struct {
    ptr: ?[*]const u8,
    len: usize,
    sentinel: bool,

    pub const empty: String = .{
        .ptr = null,
        .len = 0,
        .sentinel = false,
    };

    pub fn fromSlice(slice: anytype) String {
        return .{
            .ptr = slice.ptr,
            .len = slice.len,
            .sentinel = sentinel: {
                const info = @typeInfo(@TypeOf(slice));
                switch (info) {
                    .pointer => |pointer| {
                        if (pointer.size != .slice) @compileError("only slices supported");
                        if (pointer.child != u8) @compileError("only u8 slices supported");
                        const slice_sentinel = pointer.sentinel();
                        if (slice_sentinel) |value| {
                            if (value != 0) @compileError("only 0 is supported for sentinels");
                        }
                        break :sentinel slice_sentinel != null;
                    },
                    else => @compileError("only []const u8 and [:0]const u8"),
                }
            },
        };
    }

    pub fn deinit(self: *const String) void {
        const ptr = self.ptr orelse return;
        if (self.sentinel) {
            global.alloc().free(ptr[0..self.len :0]);
        } else {
            global.alloc().free(ptr[0..self.len]);
        }
    }
};

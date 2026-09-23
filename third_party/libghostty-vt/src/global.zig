//! proctmux libghostty-vt global shim.

const std = @import("std");

pub const xev = struct {};

pub fn alloc() std.mem.Allocator {
    return std.heap.c_allocator;
}

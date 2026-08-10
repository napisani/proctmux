//! proctmux libghostty-vt renderer shim.

pub const Backend = enum {
    opengl,
    metal,
    webgl,
};

pub const size = @import("renderer/size.zig");
pub const Size = size.Size;
pub const Coordinate = size.Coordinate;
pub const CellSize = size.CellSize;
pub const ScreenSize = size.ScreenSize;
pub const GridSize = size.GridSize;
pub const Padding = size.Padding;

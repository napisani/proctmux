//! Terminal subsystem namespace.
//! Importers use this root for dimensions, raw-mode lifecycle, repaint sequences, and VT rendering adapters.

pub const dimensions = @import("dimensions.zig");
pub const ghostty_vt = @import("ghostty_vt.zig");
pub const mode = @import("mode.zig");
pub const repaint = @import("repaint.zig");

test {
    _ = dimensions;
    _ = ghostty_vt;
    _ = mode;
    _ = repaint;
}

//! proctmux-specific Zig module root for the vendored libghostty-vt subset.
//!
//! Upstream `src/lib_vt.zig` exports additional input, C API, and wasm-facing
//! surfaces. proctmux only needs terminal byte interpretation and screen state,
//! so this root keeps the imported Ghostty surface intentionally narrow.

pub const Terminal = @import("terminal/Terminal.zig");
pub const TerminalStream = @import("terminal/stream_terminal.zig").Stream;
pub const RenderState = @import("terminal/render.zig").RenderState;

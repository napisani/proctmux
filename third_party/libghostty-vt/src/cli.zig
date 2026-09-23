//! proctmux libghostty-vt CLI shim.
//!
//! Terminal configuration parsing needs Ghostty's argument and diagnostic
//! types, but not application actions, commands, or crash-report handling.

const diagnostics = @import("cli/diagnostics.zig");

pub const args = @import("cli/args.zig");
pub const CompatibilityHandler = args.CompatibilityHandler;
pub const compatibilityRenamed = args.compatibilityRenamed;
pub const DiagnosticList = diagnostics.DiagnosticList;
pub const Diagnostic = diagnostics.Diagnostic;
pub const Location = diagnostics.Location;

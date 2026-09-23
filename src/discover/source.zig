//! Discovery source contract.
//! Each source returns an owned process map or `error.SourceNotFound`; the coordinator owns cleanup and runtime policy.

const config = @import("../config/root.zig");

pub const ProcessMap = config.schema.ProcessMap;
pub const DiscoverFn = *const fn (allocator: config.schema.Allocator, cwd: []const u8) anyerror!ProcessMap;
pub const EnabledFn = *const fn (general: *const config.schema.GeneralConfig) bool;

/// A discoverer for one project metadata format. Sources own parsing and their
/// config flag mapping; the coordinator handles ordering, merging, and errors.
pub const Source = struct {
    name: []const u8,
    enabled: EnabledFn,
    discover: DiscoverFn,
};

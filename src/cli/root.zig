//! Command-line parsing for proctmux modes and signal subcommands.
//! The parser intentionally produces small domain-shaped options so app startup can decide runtime behavior without re-reading raw argv.

const std = @import("std");

pub const Mode = enum {
    primary,
    client,
};

pub const UnifiedSplit = enum {
    none,
    left,
    right,
    top,
    bottom,
};

pub const Config = struct {
    config_file: []const u8 = "",
    mode: Mode = .primary,
    subcommand: []const u8 = "start",
    args: []const []const u8 = &.{},
    unified: bool = false,
    unified_orientation: UnifiedSplit = .none,
    version_requested: bool = false,
};

pub const deprecated_unified_toggle_message =
    \\--unified-toggle has been removed; use --unified or --unified-left/right/top/bottom with:
    \\layout:
    \\  hide_process_list_when_unfocused: true
;

pub const usage_text =
    \\Usage: proctmux [options] [command]
    \\
    \\Options:
    \\  -client
    \\        run in client mode (connects to primary)
    \\  -f string
    \\        path to config file (default: searches for proctmux.yaml in current directory)
    \\  -mode string
    \\        mode: primary (process server) or client (UI only) (default "primary")
    \\  -unified
    \\        run in unified mode (client + server split view; shorthand for --unified-left)
    \\  -unified-bottom
    \\        run in unified mode with process list below the output
    \\  -unified-left
    \\        run in unified mode with process list on the left (default)
    \\  -unified-right
    \\        run in unified mode with process list on the right
    \\  -unified-top
    \\        run in unified mode with process list above the output
    \\  -version
    \\        print version and exit
    \\  --version
    \\        print version and exit
    \\
    \\Modes:
    \\  (default)                Run primary server (manages processes)
    \\  --client                 Run UI client (connects to primary)
    \\  --unified                Run UI client and embedded server (process list on the left)
    \\  --unified-left           Alias for --unified
    \\  --unified-right          Unified mode with process list on the right
    \\  --unified-top            Unified mode with process list above the output
    \\  --unified-bottom         Unified mode with process list below the output
    \\
    \\Commands:
    \\  config-init [path]       Create a starter proctmux.yaml configuration file
    \\  start                    Start the TUI (default)
    \\  signal-list              List all processes and their statuses (tab-delimited)
    \\  signal-start <name>      Start a process
    \\  signal-stop <name>       Stop a process
    \\  signal-restart <name>    Restart a process
    \\  signal-restart-running   Restart all running processes
    \\  signal-stop-running      Stop all running processes
    \\
;

pub fn deprecatedFlagMessage(args: []const []const u8) ?[]const u8 {
    for (args) |arg| {
        if (std.ascii.eqlIgnoreCase(arg, "--unified-toggle") or
            std.ascii.eqlIgnoreCase(arg, "-unified-toggle"))
        {
            return deprecated_unified_toggle_message;
        }
    }
    return null;
}

pub const BoolFlagDiagnostic = struct {
    name: []const u8,
    value: []const u8,
};

pub fn unknownFlagName(args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) return null;
        if (arg.len <= 1 or arg[0] != '-') return null;

        const parsed = parseFlagToken(arg) catch |err| switch (err) {
            error.UnknownFlag => return flagName(arg),
            else => return null,
        };

        if (flagRequiresValue(parsed.kind) and parsed.value == null) i += 1;
        i += 1;
    }
    return null;
}

pub fn missingValueFlagName(args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) return null;
        if (arg.len <= 1 or arg[0] != '-') return null;

        const parsed = parseFlagToken(arg) catch return null;
        if (flagRequiresValue(parsed.kind) and parsed.value == null) {
            if (i + 1 >= args.len) return flagName(arg);
            i += 1;
        }
        i += 1;
    }
    return null;
}

pub fn invalidBoolFlag(args: []const []const u8) ?BoolFlagDiagnostic {
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) return null;
        if (arg.len <= 1 or arg[0] != '-') return null;

        const parsed = parseFlagToken(arg) catch return null;
        if (flagRequiresValue(parsed.kind) and parsed.value == null) i += 1;
        if (flagRequiresBool(parsed.kind)) {
            if (parsed.value) |value| {
                _ = parseBool(value) catch return .{
                    .name = flagName(arg),
                    .value = value,
                };
            }
        }
        i += 1;
    }
    return null;
}

pub fn parse(args: []const []const u8) !Config {
    if (deprecatedFlagMessage(args) != null) return error.DeprecatedFlag;

    var cfg = Config{};
    var client_mode = false;
    var orientation_count: usize = 0;
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (arg.len <= 1 or arg[0] != '-') break;

        const parsed = try parseFlagToken(arg);
        const value = parsed.value orelse switch (parsed.kind) {
            .config_file, .mode => blk: {
                i += 1;
                if (i >= args.len) return error.MissingFlagValue;
                break :blk args[i];
            },
            else => "true",
        };

        switch (parsed.kind) {
            .config_file => cfg.config_file = value,
            .mode => cfg.mode = parseMode(value),
            .client => client_mode = try parseBool(value),
            .unified => cfg.unified = try parseBool(value),
            .unified_left => try applyOrientation(&cfg, &orientation_count, .left, try parseBool(value)),
            .unified_right => try applyOrientation(&cfg, &orientation_count, .right, try parseBool(value)),
            .unified_top => try applyOrientation(&cfg, &orientation_count, .top, try parseBool(value)),
            .unified_bottom => try applyOrientation(&cfg, &orientation_count, .bottom, try parseBool(value)),
            .version => cfg.version_requested = true,
            .help => return error.HelpRequested,
        }
        i += 1;
    }

    if (cfg.unified and cfg.unified_orientation == .none) cfg.unified_orientation = .left;
    if (client_mode) cfg.mode = .client;
    if (cfg.unified and cfg.mode == .client) return error.ClientUnifiedConflict;

    cfg.args = args[i..];
    if (cfg.args.len > 0) cfg.subcommand = cfg.args[0];
    return cfg;
}

const FlagKind = enum {
    config_file,
    mode,
    client,
    unified,
    unified_left,
    unified_right,
    unified_top,
    unified_bottom,
    version,
    help,
};

const ParsedFlag = struct {
    kind: FlagKind,
    value: ?[]const u8,
};

fn parseFlagToken(arg: []const u8) !ParsedFlag {
    const without_prefix = if (std.mem.startsWith(u8, arg, "--"))
        arg[2..]
    else if (std.mem.startsWith(u8, arg, "-"))
        arg[1..]
    else
        return error.UnknownFlag;

    const eq_index = std.mem.indexOfScalar(u8, without_prefix, '=');
    const name = if (eq_index) |index| without_prefix[0..index] else without_prefix;
    const value = if (eq_index) |index| without_prefix[index + 1 ..] else null;

    if (std.mem.eql(u8, name, "f")) return .{ .kind = .config_file, .value = value };
    if (std.mem.eql(u8, name, "mode")) return .{ .kind = .mode, .value = value };
    if (std.mem.eql(u8, name, "client")) return .{ .kind = .client, .value = value };
    if (std.mem.eql(u8, name, "unified")) return .{ .kind = .unified, .value = value };
    if (std.mem.eql(u8, name, "unified-left")) return .{ .kind = .unified_left, .value = value };
    if (std.mem.eql(u8, name, "unified-right")) return .{ .kind = .unified_right, .value = value };
    if (std.mem.eql(u8, name, "unified-top")) return .{ .kind = .unified_top, .value = value };
    if (std.mem.eql(u8, name, "unified-bottom")) return .{ .kind = .unified_bottom, .value = value };
    if (std.mem.eql(u8, name, "version")) return .{ .kind = .version, .value = value };
    if (std.mem.eql(u8, name, "h") or std.mem.eql(u8, name, "help")) return .{ .kind = .help, .value = value };
    return error.UnknownFlag;
}

fn parseMode(value: []const u8) Mode {
    if (std.mem.eql(u8, value, "client")) return .client;
    return .primary;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "t") or
        std.ascii.eqlIgnoreCase(value, "true"))
    {
        return true;
    }
    if (std.mem.eql(u8, value, "0") or
        std.ascii.eqlIgnoreCase(value, "f") or
        std.ascii.eqlIgnoreCase(value, "false"))
    {
        return false;
    }
    return error.InvalidBool;
}

fn applyOrientation(cfg: *Config, count: *usize, orientation: UnifiedSplit, enabled: bool) !void {
    if (!enabled) return;
    if (count.* > 0) return error.MultipleUnifiedOrientations;
    cfg.unified = true;
    cfg.unified_orientation = orientation;
    count.* += 1;
}

fn flagName(arg: []const u8) []const u8 {
    const without_prefix = if (std.mem.startsWith(u8, arg, "--"))
        arg[2..]
    else if (std.mem.startsWith(u8, arg, "-"))
        arg[1..]
    else
        arg;
    const eq_index = std.mem.indexOfScalar(u8, without_prefix, '=');
    return if (eq_index) |index| without_prefix[0..index] else without_prefix;
}

fn flagRequiresValue(kind: FlagKind) bool {
    return switch (kind) {
        .config_file, .mode => true,
        else => false,
    };
}

fn flagRequiresBool(kind: FlagKind) bool {
    return switch (kind) {
        .client,
        .unified,
        .unified_left,
        .unified_right,
        .unified_top,
        .unified_bottom,
        => true,
        else => false,
    };
}

test "default CLI config matches legacy parser" {
    const cfg = try parse(&.{});

    try std.testing.expectEqualStrings("", cfg.config_file);
    try std.testing.expectEqual(Mode.primary, cfg.mode);
    try std.testing.expectEqualStrings("start", cfg.subcommand);
    try std.testing.expectEqual(@as(usize, 0), cfg.args.len);
    try std.testing.expect(!cfg.unified);
    try std.testing.expectEqual(UnifiedSplit.none, cfg.unified_orientation);
    try std.testing.expect(!cfg.version_requested);
}

test "version flag parses as a non-TUI request" {
    const cfg = try parse(&.{"--version"});

    try std.testing.expect(cfg.version_requested);
    try std.testing.expectEqual(Mode.primary, cfg.mode);
    try std.testing.expectEqualStrings("start", cfg.subcommand);
}

test "config file client mode and subcommand parse like legacy behavior" {
    const cfg = try parse(&.{ "-f", "proctmux.yaml", "--client", "signal-list" });

    try std.testing.expectEqualStrings("proctmux.yaml", cfg.config_file);
    try std.testing.expectEqual(Mode.client, cfg.mode);
    try std.testing.expectEqualStrings("signal-list", cfg.subcommand);
    try std.testing.expectEqual(@as(usize, 1), cfg.args.len);
    try std.testing.expectEqualStrings("signal-list", cfg.args[0]);
}

test "unified flags choose legacy-compatible orientation" {
    const unified = try parse(&.{"--unified"});
    try std.testing.expect(unified.unified);
    try std.testing.expectEqual(UnifiedSplit.left, unified.unified_orientation);

    const right = try parse(&.{ "--unified-right", "-f=config.yaml" });
    try std.testing.expect(right.unified);
    try std.testing.expectEqual(UnifiedSplit.right, right.unified_orientation);
    try std.testing.expectEqualStrings("config.yaml", right.config_file);

    const top = try parse(&.{"--unified-top"});
    try std.testing.expectEqual(UnifiedSplit.top, top.unified_orientation);

    const bottom = try parse(&.{"--unified-bottom"});
    try std.testing.expectEqual(UnifiedSplit.bottom, bottom.unified_orientation);
}

test "client conflicts with unified like legacy behavior" {
    try std.testing.expectError(error.ClientUnifiedConflict, parse(&.{ "--client", "--unified" }));
    try std.testing.expectError(error.ClientUnifiedConflict, parse(&.{ "--mode=client", "--unified-left" }));
}

test "boolean flag values accept legacy flag forms" {
    const client_one = try parse(&.{"--client=1"});
    try std.testing.expectEqual(Mode.client, client_one.mode);

    const client_t = try parse(&.{"--client=t"});
    try std.testing.expectEqual(Mode.client, client_t.mode);

    const unified_true = try parse(&.{"--unified=True"});
    try std.testing.expect(unified_true.unified);
    try std.testing.expectEqual(UnifiedSplit.left, unified_true.unified_orientation);

    const unified_false = try parse(&.{"--unified=False"});
    try std.testing.expect(!unified_false.unified);
    try std.testing.expectEqual(UnifiedSplit.none, unified_false.unified_orientation);
}

test "multiple unified orientation flags fail like legacy behavior" {
    try std.testing.expectError(error.MultipleUnifiedOrientations, parse(&.{ "--unified-left", "--unified-right" }));
}

test "flags after first positional argument remain command args like legacy flag parser" {
    const cfg = try parse(&.{ "start", "--client" });

    try std.testing.expectEqual(Mode.primary, cfg.mode);
    try std.testing.expectEqualStrings("start", cfg.subcommand);
    try std.testing.expectEqual(@as(usize, 2), cfg.args.len);
    try std.testing.expectEqualStrings("--client", cfg.args[1]);
}

test "lone dash remains a positional argument like legacy flag parser" {
    const cfg = try parse(&.{"-"});

    try std.testing.expectEqual(Mode.primary, cfg.mode);
    try std.testing.expectEqualStrings("-", cfg.subcommand);
    try std.testing.expectEqual(@as(usize, 1), cfg.args.len);
    try std.testing.expectEqualStrings("-", cfg.args[0]);
}

test "deprecated unified toggle message matches deprecated flag migration guidance" {
    const msg = deprecatedFlagMessage(&.{"-UNIFIED-TOGGLE"}) orelse return error.TestExpectedDeprecatedMessage;

    try std.testing.expect(std.mem.indexOf(u8, msg, "--unified") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "hide_process_list_when_unfocused: true") != null);
}

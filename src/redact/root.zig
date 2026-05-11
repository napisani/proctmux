const std = @import("std");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");

pub const RedactedAppState = struct {
    allocator: std.mem.Allocator,
    config: *config.schema.Config,
    state: domain.state.AppState,

    pub fn deinit(self: *RedactedAppState) void {
        self.state.deinit();
        self.config.deinit();
        self.allocator.destroy(self.config);
    }
};

pub fn appStateForIPC(
    allocator: std.mem.Allocator,
    source: *const domain.state.AppState,
) !RedactedAppState {
    const redacted_config = try allocator.create(config.schema.Config);
    errdefer allocator.destroy(redacted_config);
    redacted_config.* = try configForIPC(allocator, source.config);
    errdefer redacted_config.deinit();

    var redacted_state = domain.state.AppState{
        .allocator = allocator,
        .config = redacted_config,
        .processes = std.array_list.Managed(domain.process.Process).init(allocator),
        .current_proc_id = source.current_proc_id,
        .exiting = source.exiting,
    };
    errdefer redacted_state.deinit();

    for (source.processes.items) |proc| {
        const redacted_cfg = redacted_config.procs.getPtr(proc.label) orelse return error.MissingProcessConfig;
        const redacted_label = findProcessLabel(&redacted_config.procs, proc.label) orelse return error.MissingProcessConfig;
        try redacted_state.processes.append(.{
            .id = proc.id,
            .label = redacted_label,
            .config = redacted_cfg,
        });
    }

    return .{
        .allocator = allocator,
        .config = redacted_config,
        .state = redacted_state,
    };
}

pub fn configForIPC(
    allocator: std.mem.Allocator,
    source: *const config.schema.Config,
) !config.schema.Config {
    var out = config.schema.Config.empty(allocator);
    errdefer out.deinit();

    out.file_path = try dupeOptional(allocator, source.file_path);
    out.owns_file_path = out.file_path.len > 0;
    out.log_file = try dupeOptional(allocator, source.log_file);
    out.stdout_debug_log_file = try dupeOptional(allocator, source.stdout_debug_log_file);
    out.owns_log_paths = out.log_file.len > 0 or out.stdout_debug_log_file.len > 0;

    out.layout = source.layout;
    out.style = source.style;
    out.general = source.general;

    try cloneKeybindingConfig(allocator, &out.keybinding, &source.keybinding);
    try cloneStringList(allocator, &out.shell_cmd, source.shell_cmd.items);

    var it = source.procs.iterator();
    while (it.next()) |entry| {
        try putRedactedProcess(allocator, &out.procs, entry.key_ptr.*, entry.value_ptr);
    }

    return out;
}

pub fn processConfig(
    allocator: std.mem.Allocator,
    source: *const config.schema.ProcessConfig,
) !config.schema.ProcessConfig {
    var out = config.schema.ProcessConfig.empty(allocator);
    errdefer out.deinit(allocator);

    out.owns_scalar_strings = true;
    out.shell = try dupeOptional(allocator, source.shell);
    out.cwd = try dupeOptional(allocator, source.cwd);
    out.description = try dupeOptional(allocator, source.description);
    out.docs = try dupeOptional(allocator, source.docs);
    out.stop = source.stop;
    out.stop_timeout_ms = source.stop_timeout_ms;
    out.autostart = source.autostart;
    out.autofocus = source.autofocus;
    out.terminal_rows = source.terminal_rows;
    out.terminal_cols = source.terminal_cols;

    try cloneStringList(allocator, &out.cmd, source.cmd.items);
    try cloneStringList(allocator, &out.meta_tags, source.meta_tags.items);
    try cloneStringList(allocator, &out.categories, source.categories.items);
    try cloneStringList(allocator, &out.add_path, source.add_path.items);
    try cloneStringList(allocator, &out.on_kill, source.on_kill.items);
    return out;
}

fn cloneKeybindingConfig(
    allocator: std.mem.Allocator,
    out: *config.schema.KeybindingConfig,
    source: *const config.schema.KeybindingConfig,
) !void {
    try cloneStringList(allocator, &out.quit, source.quit.items);
    try cloneStringList(allocator, &out.up, source.up.items);
    try cloneStringList(allocator, &out.down, source.down.items);
    try cloneStringList(allocator, &out.start, source.start.items);
    try cloneStringList(allocator, &out.stop, source.stop.items);
    try cloneStringList(allocator, &out.restart, source.restart.items);
    try cloneStringList(allocator, &out.filter, source.filter.items);
    try cloneStringList(allocator, &out.submit_filter, source.submit_filter.items);
    try cloneStringList(allocator, &out.toggle_running, source.toggle_running.items);
    try cloneStringList(allocator, &out.toggle_help, source.toggle_help.items);
    try cloneStringList(allocator, &out.toggle_focus, source.toggle_focus.items);
    try cloneStringList(allocator, &out.focus_client, source.focus_client.items);
    try cloneStringList(allocator, &out.focus_server, source.focus_server.items);
    try cloneStringList(allocator, &out.docs, source.docs.items);
}

fn putRedactedProcess(
    allocator: std.mem.Allocator,
    procs: *config.schema.ProcessMap,
    label: []const u8,
    source: *const config.schema.ProcessConfig,
) !void {
    const owned_label = try allocator.dupe(u8, label);
    errdefer allocator.free(owned_label);

    var redacted_proc = try processConfig(allocator, source);
    errdefer redacted_proc.deinit(allocator);

    try procs.put(owned_label, redacted_proc);
}

fn findProcessLabel(procs: *const config.schema.ProcessMap, label: []const u8) ?[]const u8 {
    var it = procs.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, label)) return entry.key_ptr.*;
    }
    return null;
}

fn dupeOptional(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len == 0) return "";
    return allocator.dupe(u8, value);
}

fn cloneStringList(
    allocator: std.mem.Allocator,
    out: *config.schema.StringList,
    values: []const []const u8,
) !void {
    for (values) |value| try config.schema.appendOwned(allocator, out, value);
}

test "process config redaction strips env and deep-copies active slices" {
    var original = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer original.deinit(std.testing.allocator);
    original.shell = "run api";
    original.cwd = ".";
    original.description = "API";
    original.docs = "API docs";
    original.stop = 15;
    original.stop_timeout_ms = 3000;
    original.autostart = true;
    original.autofocus = true;
    original.terminal_rows = 40;
    original.terminal_cols = 120;
    try config.schema.appendOwned(std.testing.allocator, &original.cmd, "node");
    try config.schema.appendOwned(std.testing.allocator, &original.meta_tags, "service");
    try config.schema.appendOwned(std.testing.allocator, &original.categories, "server");
    try config.schema.appendOwned(std.testing.allocator, &original.add_path, "./node_modules/.bin");
    try config.schema.appendOwned(std.testing.allocator, &original.on_kill, "cleanup");
    try config.schema.putOwnedString(std.testing.allocator, &original.env, "TOKEN", "secret");

    var redacted = try processConfig(std.testing.allocator, &original);
    defer redacted.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), redacted.env.count());
    try std.testing.expectEqualStrings("run api", redacted.shell);
    try std.testing.expectEqualStrings(".", redacted.cwd);
    try std.testing.expectEqualStrings("API", redacted.description);
    try std.testing.expectEqualStrings("API docs", redacted.docs);
    try std.testing.expect(redacted.autostart);
    try std.testing.expect(redacted.autofocus);
    try std.testing.expectEqual(@as(i32, 40), redacted.terminal_rows);
    try std.testing.expectEqual(@as(i32, 120), redacted.terminal_cols);
    try std.testing.expectEqualStrings("node", redacted.cmd.items[0]);
    try std.testing.expectEqualStrings("service", redacted.meta_tags.items[0]);
    try std.testing.expectEqualStrings("server", redacted.categories.items[0]);
    try std.testing.expectEqualStrings("./node_modules/.bin", redacted.add_path.items[0]);
    try std.testing.expectEqualStrings("cleanup", redacted.on_kill.items[0]);

    try std.testing.expect(original.cmd.items[0].ptr != redacted.cmd.items[0].ptr);
    try std.testing.expectEqual(@as(usize, 1), original.env.count());
}

test "config redaction strips process env maps and deep-copies active lists" {
    var original = config.schema.Config.empty(std.testing.allocator);
    defer original.deinit();
    original.file_path = "proctmux.yaml";
    original.log_file = "/tmp/proctmux.log";
    original.stdout_debug_log_file = "/tmp/proctmux-stdout.log";
    try config.schema.appendOwned(std.testing.allocator, &original.shell_cmd, "/bin/sh");
    try config.schema.appendOwned(std.testing.allocator, &original.shell_cmd, "-c");
    try config.schema.appendOwned(std.testing.allocator, &original.keybinding.quit, "q");
    original.layout.placeholder_banner = "READY";
    original.style.pointer_char = ">";
    original.general.procs_from_make_targets = true;

    var proc = config.schema.ProcessConfig.empty(std.testing.allocator);
    errdefer proc.deinit(std.testing.allocator);
    proc.shell = "npm run dev";
    try config.schema.appendOwned(std.testing.allocator, &proc.categories, "server");
    try config.schema.putOwnedString(std.testing.allocator, &proc.env, "TOKEN", "secret");

    const label = try std.testing.allocator.dupe(u8, "api");
    errdefer std.testing.allocator.free(label);
    try original.procs.put(label, proc);

    var redacted = try configForIPC(std.testing.allocator, &original);
    defer redacted.deinit();

    try std.testing.expectEqualStrings("proctmux.yaml", redacted.file_path);
    try std.testing.expectEqualStrings("/tmp/proctmux.log", redacted.log_file);
    try std.testing.expectEqualStrings("/tmp/proctmux-stdout.log", redacted.stdout_debug_log_file);
    try std.testing.expectEqualStrings("/bin/sh", redacted.shell_cmd.items[0]);
    try std.testing.expectEqualStrings("q", redacted.keybinding.quit.items[0]);
    try std.testing.expectEqualStrings("READY", redacted.layout.placeholder_banner);
    try std.testing.expectEqualStrings(">", redacted.style.pointer_char);
    try std.testing.expect(redacted.general.procs_from_make_targets);

    const redacted_proc = redacted.procs.get("api") orelse return error.ExpectedProcess;
    try std.testing.expectEqualStrings("npm run dev", redacted_proc.shell);
    try std.testing.expectEqualStrings("server", redacted_proc.categories.items[0]);
    try std.testing.expectEqual(@as(usize, 0), redacted_proc.env.count());

    try std.testing.expect(original.shell_cmd.items[0].ptr != redacted.shell_cmd.items[0].ptr);
    try std.testing.expect(original.keybinding.quit.items[0].ptr != redacted.keybinding.quit.items[0].ptr);
    try std.testing.expectEqual(@as(usize, 1), original.procs.get("api").?.env.count());
}

test "app state redaction points processes at redacted configs" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();

    var proc = config.schema.ProcessConfig.empty(std.testing.allocator);
    errdefer proc.deinit(std.testing.allocator);
    proc.shell = "npm run dev";
    try config.schema.putOwnedString(std.testing.allocator, &proc.env, "ROLE", "api");

    const label = try std.testing.allocator.dupe(u8, "backend");
    errdefer std.testing.allocator.free(label);
    try cfg.procs.put(label, proc);

    var app = try domain.state.AppState.init(std.testing.allocator, &cfg);
    defer app.deinit();
    app.current_proc_id = domain.process.ProcessId.fromInt(1);
    app.exiting = true;

    var redacted = try appStateForIPC(std.testing.allocator, &app);
    defer redacted.deinit();

    try std.testing.expect(redacted.state.config != app.config);
    try std.testing.expectEqual(app.current_proc_id, redacted.state.current_proc_id);
    try std.testing.expect(redacted.state.exiting);
    try std.testing.expectEqual(app.processes.items.len, redacted.state.processes.items.len);

    const backend = redacted.state.getProcessByLabel("backend") orelse return error.ExpectedProcess;
    const redacted_backend_cfg = redacted.config.procs.getPtr("backend") orelse return error.ExpectedProcess;
    try std.testing.expect(backend.config == redacted_backend_cfg);
    try std.testing.expectEqual(@as(usize, 0), backend.config.env.count());
    try std.testing.expectEqual(@as(usize, 1), cfg.procs.get("backend").?.env.count());
}

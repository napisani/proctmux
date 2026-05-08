const std = @import("std");
const yaml_mod = @import("yaml");
const schema = @import("schema.zig");
const defaults = @import("defaults.zig");

const Yaml = yaml_mod.Yaml;
const Value = Yaml.Value;
const Map = Yaml.Map;

pub const LoadedConfig = struct {
    parent_allocator: schema.Allocator,
    arena: *std.heap.ArenaAllocator,
    config: schema.Config,
    warnings: std.array_list.Managed(schema.Warning),

    pub fn deinit(self: *LoadedConfig) void {
        deinitWarnings(self.parent_allocator, &self.warnings);
        self.config.deinit();
        self.arena.deinit();
        self.parent_allocator.destroy(self.arena);
    }

    pub fn hasWarning(self: LoadedConfig, path: []const u8) bool {
        for (self.warnings.items) |warning| {
            if (std.mem.eql(u8, warning.path, path)) return true;
        }
        return false;
    }
};

pub fn loadFile(allocator: schema.Allocator, path: []const u8) !LoadedConfig {
    return loadFileInDir(allocator, std.fs.cwd(), path);
}

pub fn loadFileInDir(allocator: schema.Allocator, dir: std.fs.Dir, path: []const u8) !LoadedConfig {
    const data = dir.readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer allocator.free(data);

    const absolute_path = try dir.realpathAlloc(allocator, path);
    defer allocator.free(absolute_path);

    return loadFromSlice(allocator, data, absolute_path);
}

pub fn loadDefault(allocator: schema.Allocator) !LoadedConfig {
    return loadDefaultInDir(allocator, std.fs.cwd());
}

pub fn loadDefaultInDir(allocator: schema.Allocator, dir: std.fs.Dir) !LoadedConfig {
    const paths = [_][]const u8{ "proctmux.yaml", "proctmux.yml", "procmux.yaml", "procmux.yml" };
    for (paths) |path| {
        return loadFileInDir(allocator, dir, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
    }
    return error.ConfigFileNotFound;
}

pub fn loadFromSlice(allocator: schema.Allocator, source: []const u8, source_path: []const u8) !LoadedConfig {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var cfg = schema.Config.empty(arena_allocator);
    errdefer cfg.deinit();

    var warnings = std.array_list.Managed(schema.Warning).init(allocator);
    errdefer deinitWarnings(allocator, &warnings);

    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "{}")) {
        try defaults.apply(&cfg, arena_allocator);
        cfg.file_path = try arena_allocator.dupe(u8, source_path);
        return .{
            .parent_allocator = allocator,
            .arena = arena,
            .config = cfg,
            .warnings = warnings,
        };
    }

    var yml: Yaml = .{ .source = source };
    defer yml.deinit(allocator);

    yml.load(allocator) catch |err| switch (err) {
        error.ParseFailure => return error.ParseFailure,
        else => return err,
    };

    try decodeDocument(arena_allocator, &cfg, &warnings, yml, allocator);
    try defaults.apply(&cfg, arena_allocator);
    cfg.file_path = try arena_allocator.dupe(u8, source_path);

    return .{
        .parent_allocator = allocator,
        .arena = arena,
        .config = cfg,
        .warnings = warnings,
    };
}

fn deinitWarnings(allocator: schema.Allocator, warnings: *std.array_list.Managed(schema.Warning)) void {
    for (warnings.items) |warning| {
        allocator.free(warning.path);
        allocator.free(warning.message);
    }
    warnings.deinit();
}

fn addWarning(
    allocator: schema.Allocator,
    warnings: *std.array_list.Managed(schema.Warning),
    kind: schema.WarningKind,
    path: []const u8,
    message: []const u8,
) !void {
    try warnings.append(.{
        .kind = kind,
        .path = try allocator.dupe(u8, path),
        .message = try allocator.dupe(u8, message),
    });
}

fn decodeDocument(
    allocator: schema.Allocator,
    cfg: *schema.Config,
    warnings: *std.array_list.Managed(schema.Warning),
    yml: Yaml,
    warning_allocator: schema.Allocator,
) !void {
    if (yml.docs.items.len == 0) return;
    if (yml.docs.items[0] == .empty) return;
    var root = yml.docs.items[0].asMap() orelse return error.TypeMismatch;

    var it = root.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "keybinding")) {
            try decodeKeybinding(allocator, &cfg.keybinding, value);
        } else if (std.mem.eql(u8, key, "layout")) {
            try decodeLayout(allocator, &cfg.layout, value);
        } else if (std.mem.eql(u8, key, "style")) {
            try decodeStyle(allocator, &cfg.style, value, warnings, warning_allocator);
        } else if (std.mem.eql(u8, key, "general")) {
            try decodeGeneral(allocator, &cfg.general, value, warnings, warning_allocator);
        } else if (std.mem.eql(u8, key, "shell_cmd")) {
            try decodeStringList(allocator, &cfg.shell_cmd, value);
        } else if (std.mem.eql(u8, key, "log_file")) {
            cfg.log_file = try dupeString(allocator, value);
        } else if (std.mem.eql(u8, key, "stdout_debug_log_file")) {
            cfg.stdout_debug_log_file = try dupeString(allocator, value);
        } else if (std.mem.eql(u8, key, "procs")) {
            try decodeProcs(allocator, &cfg.procs, value, warnings, warning_allocator);
        } else if (isDeadTopLevel(key)) {
            try addWarning(warning_allocator, warnings, .dead_field, key, "dead config field ignored");
        } else {
            try addWarning(warning_allocator, warnings, .unknown_field, key, "unknown config field ignored");
        }
    }
}

fn decodeKeybinding(allocator: schema.Allocator, cfg: *schema.KeybindingConfig, value: Value) !void {
    var map = value.asMap() orelse return error.TypeMismatch;
    var it = map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "quit")) try decodeStringList(allocator, &cfg.quit, v) else if (std.mem.eql(u8, key, "up")) try decodeStringList(allocator, &cfg.up, v) else if (std.mem.eql(u8, key, "down")) try decodeStringList(allocator, &cfg.down, v) else if (std.mem.eql(u8, key, "start")) try decodeStringList(allocator, &cfg.start, v) else if (std.mem.eql(u8, key, "stop")) try decodeStringList(allocator, &cfg.stop, v) else if (std.mem.eql(u8, key, "restart")) try decodeStringList(allocator, &cfg.restart, v) else if (std.mem.eql(u8, key, "filter")) try decodeStringList(allocator, &cfg.filter, v) else if (std.mem.eql(u8, key, "submit_filter")) try decodeStringList(allocator, &cfg.submit_filter, v) else if (std.mem.eql(u8, key, "toggle_running")) try decodeStringList(allocator, &cfg.toggle_running, v) else if (std.mem.eql(u8, key, "toggle_help")) try decodeStringList(allocator, &cfg.toggle_help, v) else if (std.mem.eql(u8, key, "toggle_focus")) try decodeStringList(allocator, &cfg.toggle_focus, v) else if (std.mem.eql(u8, key, "focus_client")) try decodeStringList(allocator, &cfg.focus_client, v) else if (std.mem.eql(u8, key, "focus_server")) try decodeStringList(allocator, &cfg.focus_server, v) else if (std.mem.eql(u8, key, "docs")) try decodeStringList(allocator, &cfg.docs, v);
    }
}

fn decodeLayout(allocator: schema.Allocator, cfg: *schema.LayoutConfig, value: Value) !void {
    var map = value.asMap() orelse return error.TypeMismatch;
    var it = map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "category_search_prefix")) {
            cfg.category_search_prefix = try dupeString(allocator, v);
        } else if (std.mem.eql(u8, key, "processes_list_width")) {
            cfg.processes_list_width = try decodeInt(v);
        } else if (std.mem.eql(u8, key, "hide_process_description_panel")) {
            cfg.hide_process_description_panel = try decodeBool(v);
        } else if (std.mem.eql(u8, key, "hide_process_list_when_unfocused")) {
            cfg.hide_process_list_when_unfocused = try decodeBool(v);
        } else if (std.mem.eql(u8, key, "sort_process_list_alpha")) {
            cfg.sort_process_list_alpha = try decodeBool(v);
        } else if (std.mem.eql(u8, key, "sort_process_list_running_first")) {
            cfg.sort_process_list_running_first = try decodeBool(v);
        } else if (std.mem.eql(u8, key, "placeholder_banner")) {
            cfg.placeholder_banner = try dupeString(allocator, v);
        } else if (std.mem.eql(u8, key, "enable_debug_process_info")) {
            cfg.enable_debug_process_info = try decodeBool(v);
        }
    }
}

fn decodeStyle(
    allocator: schema.Allocator,
    cfg: *schema.StyleConfig,
    value: Value,
    warnings: *std.array_list.Managed(schema.Warning),
    warning_allocator: schema.Allocator,
) !void {
    var map = value.asMap() orelse return error.TypeMismatch;
    var it = map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "selected_process_color")) {
            cfg.selected_process_color = try dupeString(allocator, v);
        } else if (std.mem.eql(u8, key, "selected_process_bg_color")) {
            cfg.selected_process_bg_color = try dupeString(allocator, v);
        } else if (std.mem.eql(u8, key, "unselected_process_color")) {
            cfg.unselected_process_color = try dupeString(allocator, v);
        } else if (std.mem.eql(u8, key, "status_running_color")) {
            cfg.status_running_color = try dupeString(allocator, v);
        } else if (std.mem.eql(u8, key, "status_halting_color")) {
            cfg.status_halting_color = try dupeString(allocator, v);
        } else if (std.mem.eql(u8, key, "status_stopped_color")) {
            cfg.status_stopped_color = try dupeString(allocator, v);
        } else if (std.mem.eql(u8, key, "pointer_char")) {
            cfg.pointer_char = try dupeString(allocator, v);
        } else {
            const path = try std.fmt.allocPrint(warning_allocator, "style.{s}", .{key});
            defer warning_allocator.free(path);
            try addWarning(warning_allocator, warnings, if (isDeadStyleField(key)) .dead_field else .unknown_field, path, "style field ignored");
        }
    }
}

fn decodeGeneral(
    allocator: schema.Allocator,
    cfg: *schema.GeneralConfig,
    value: Value,
    warnings: *std.array_list.Managed(schema.Warning),
    warning_allocator: schema.Allocator,
) !void {
    _ = allocator;
    var map = value.asMap() orelse return error.TypeMismatch;
    var it = map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "procs_from_make_targets")) {
            cfg.procs_from_make_targets = try decodeBool(v);
        } else if (std.mem.eql(u8, key, "procs_from_package_json")) {
            cfg.procs_from_package_json = try decodeBool(v);
        } else {
            const path = try std.fmt.allocPrint(warning_allocator, "general.{s}", .{key});
            defer warning_allocator.free(path);
            try addWarning(warning_allocator, warnings, if (isDeadGeneralField(key)) .dead_field else .unknown_field, path, "general field ignored");
        }
    }
}

fn decodeProcs(
    allocator: schema.Allocator,
    procs: *schema.ProcessMap,
    value: Value,
    warnings: *std.array_list.Managed(schema.Warning),
    warning_allocator: schema.Allocator,
) !void {
    var map = value.asMap() orelse return error.TypeMismatch;
    var it = map.iterator();
    while (it.next()) |entry| {
        var proc = schema.ProcessConfig.empty(allocator);
        errdefer proc.deinit(allocator);

        try decodeProcess(allocator, entry.key_ptr.*, &proc, entry.value_ptr.*, warnings, warning_allocator);

        const label = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(label);
        try procs.put(label, proc);
    }
}

fn decodeProcess(
    allocator: schema.Allocator,
    label: []const u8,
    proc: *schema.ProcessConfig,
    value: Value,
    warnings: *std.array_list.Managed(schema.Warning),
    warning_allocator: schema.Allocator,
) !void {
    var map = value.asMap() orelse return error.TypeMismatch;
    var it = map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "shell")) {
            proc.shell = try dupeString(allocator, v);
        } else if (std.mem.eql(u8, key, "cmd")) {
            try decodeStringList(allocator, &proc.cmd, v);
        } else if (std.mem.eql(u8, key, "cwd")) {
            proc.cwd = try dupeString(allocator, v);
        } else if (std.mem.eql(u8, key, "env")) {
            try decodeStringMap(allocator, &proc.env, v);
        } else if (std.mem.eql(u8, key, "stop")) {
            proc.stop = try decodeInt(v);
        } else if (std.mem.eql(u8, key, "stop_timeout_ms")) {
            proc.stop_timeout_ms = try decodeInt(v);
        } else if (std.mem.eql(u8, key, "autostart")) {
            proc.autostart = try decodeBool(v);
        } else if (std.mem.eql(u8, key, "autofocus")) {
            proc.autofocus = try decodeBool(v);
        } else if (std.mem.eql(u8, key, "description")) {
            proc.description = try dupeString(allocator, v);
        } else if (std.mem.eql(u8, key, "docs")) {
            proc.docs = try dupeString(allocator, v);
        } else if (std.mem.eql(u8, key, "meta_tags")) {
            try decodeStringList(allocator, &proc.meta_tags, v);
        } else if (std.mem.eql(u8, key, "categories")) {
            try decodeStringList(allocator, &proc.categories, v);
        } else if (std.mem.eql(u8, key, "add_path")) {
            try decodeStringList(allocator, &proc.add_path, v);
        } else if (std.mem.eql(u8, key, "terminal_rows")) {
            proc.terminal_rows = try decodeInt(v);
        } else if (std.mem.eql(u8, key, "terminal_cols")) {
            proc.terminal_cols = try decodeInt(v);
        } else if (std.mem.eql(u8, key, "on_kill")) {
            try decodeStringList(allocator, &proc.on_kill, v);
        } else {
            const path = try std.fmt.allocPrint(warning_allocator, "procs.{s}.{s}", .{ label, key });
            defer warning_allocator.free(path);
            try addWarning(warning_allocator, warnings, if (isDeadProcessField(key)) .dead_field else .unknown_field, path, "process field ignored");
        }
    }
}

fn decodeStringList(allocator: schema.Allocator, out: *schema.StringList, value: Value) !void {
    const list = value.asList() orelse return error.TypeMismatch;
    for (list) |item| try schema.appendOwned(allocator, out, scalar(item));
}

fn decodeStringMap(allocator: schema.Allocator, out: *schema.StringMap, value: Value) !void {
    var map = value.asMap() orelse return error.TypeMismatch;
    var it = map.iterator();
    while (it.next()) |entry| {
        try schema.putOwnedString(allocator, out, entry.key_ptr.*, scalar(entry.value_ptr.*));
    }
}

fn dupeString(allocator: schema.Allocator, value: Value) ![]const u8 {
    return allocator.dupe(u8, scalar(value));
}

fn scalar(value: Value) []const u8 {
    return value.asScalar() orelse "";
}

fn decodeInt(value: Value) !i32 {
    return std.fmt.parseInt(i32, scalar(value), 10);
}

fn decodeBool(value: Value) !bool {
    return switch (value) {
        .boolean => |b| b,
        .scalar => |s| blk: {
            if (std.ascii.eqlIgnoreCase(s, "true")) break :blk true;
            if (std.ascii.eqlIgnoreCase(s, "false")) break :blk false;
            return error.TypeMismatch;
        },
        else => error.TypeMismatch,
    };
}

fn isDeadTopLevel(key: []const u8) bool {
    return std.mem.eql(u8, key, "enable_mouse") or std.mem.eql(u8, key, "signal_server");
}

fn isDeadGeneralField(key: []const u8) bool {
    return std.mem.eql(u8, key, "detached_session_name") or std.mem.eql(u8, key, "kill_existing_session");
}

fn isDeadStyleField(key: []const u8) bool {
    return std.mem.eql(u8, key, "style_classes") or
        std.mem.eql(u8, key, "color_level") or
        std.mem.eql(u8, key, "placeholder_terminal_bg_color") or
        std.mem.eql(u8, key, "unified_terminal_fg_color") or
        std.mem.eql(u8, key, "unified_terminal_bg_color");
}

fn isDeadProcessField(key: []const u8) bool {
    _ = key;
    return false;
}

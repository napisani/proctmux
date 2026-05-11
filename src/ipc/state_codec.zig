const std = @import("std");
const config = @import("../config/root.zig");
const domain = @import("../domain/root.zig");
const redact = @import("../redact/root.zig");

pub const StateFormatError = error{MissingProcessConfig} || std.mem.Allocator.Error;
pub const StateParseError =
    error{InvalidState} ||
    std.mem.Allocator.Error ||
    std.json.ParseError(std.json.Scanner);

pub const StateUpdate = struct {
    allocator: std.mem.Allocator,
    config: *config.schema.Config,
    state: domain.state.AppState,
    process_views: []domain.process.ProcessView,
    owned_config_strings: []const []const u8,

    pub fn deinit(self: *StateUpdate) void {
        self.state.deinit();
        self.allocator.free(self.process_views);
        self.config.deinit();
        self.allocator.destroy(self.config);
        for (self.owned_config_strings) |value| self.allocator.free(value);
        self.allocator.free(self.owned_config_strings);
    }
};

pub fn stateLine(
    allocator: std.mem.Allocator,
    state: *const domain.state.AppState,
    controller: domain.process.ProcessController,
) StateFormatError![]const u8 {
    var redacted = try redact.appStateForIPC(allocator, state);
    defer redacted.deinit();

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("{\"type\":\"state\",\"state\":");
    try appendAppState(&buf, &redacted.state);
    try buf.appendSlice(",\"process_views\":[");
    for (redacted.state.processes.items, 0..) |proc, index| {
        if (index != 0) try buf.append(',');
        const view = domain.process.toView(proc, controller);
        try appendProcessView(&buf, view);
    }
    try buf.appendSlice("]}\n");

    return buf.toOwnedSlice();
}

pub fn parseStateLine(allocator: std.mem.Allocator, line: []const u8) StateParseError!StateUpdate {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidState;
    const obj = parsed.value.object;
    const type_value = obj.get("type") orelse return error.InvalidState;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "state")) return error.InvalidState;

    const state_value = obj.get("state") orelse return error.InvalidState;
    if (state_value != .object) return error.InvalidState;

    const state_obj = state_value.object;
    const config_value = state_obj.get("Config") orelse return error.InvalidState;
    if (config_value != .object) return error.InvalidState;

    const cfg = try allocator.create(config.schema.Config);
    errdefer allocator.destroy(cfg);
    var owned_config_strings = std.array_list.Managed([]const u8).init(allocator);
    errdefer deinitStringSliceList(allocator, &owned_config_strings);

    cfg.* = try parseConfigValue(allocator, config_value, &owned_config_strings);
    errdefer cfg.deinit();

    var app_state = domain.state.AppState{
        .allocator = allocator,
        .config = cfg,
        .processes = std.array_list.Managed(domain.process.Process).init(allocator),
        .current_proc_id = domain.process.ProcessId.fromInt(try getOptionalU32(state_obj, "CurrentProcID", 0)),
        .exiting = try getOptionalBool(state_obj, "Exiting", false),
    };
    errdefer app_state.deinit();

    if (state_obj.get("Processes")) |processes_value| {
        if (processes_value != .array) return error.InvalidState;
        for (processes_value.array.items) |process_value| {
            const proc = try parseStateProcess(cfg, process_value);
            try app_state.processes.append(proc);
        }
    }

    const views_value = obj.get("process_views") orelse return error.InvalidState;
    if (views_value != .array) return error.InvalidState;
    var views = std.array_list.Managed(domain.process.ProcessView).init(allocator);
    errdefer views.deinit();
    for (views_value.array.items) |view_value| {
        try views.append(try parseProcessView(cfg, view_value));
    }

    return .{
        .allocator = allocator,
        .config = cfg,
        .state = app_state,
        .process_views = try views.toOwnedSlice(),
        .owned_config_strings = try owned_config_strings.toOwnedSlice(),
    };
}

fn appendJsonString(buf: *std.array_list.Managed(u8), value: []const u8) !void {
    try buf.writer().print("{f}", .{std.json.fmt(value, .{})});
}

fn appendAppState(buf: *std.array_list.Managed(u8), state: *const domain.state.AppState) !void {
    try buf.appendSlice("{\"Config\":");
    try appendConfig(buf, state.config);
    try buf.writer().print(",\"CurrentProcID\":{},\"Processes\":[", .{state.current_proc_id.toInt()});
    for (state.processes.items, 0..) |proc, index| {
        if (index != 0) try buf.append(',');
        try appendProcess(buf, proc);
    }
    try buf.writer().print("],\"Exiting\":{s}}}", .{if (state.exiting) "true" else "false"});
}

fn appendConfig(buf: *std.array_list.Managed(u8), cfg: *const config.schema.Config) !void {
    try buf.appendSlice("{\"FilePath\":");
    try appendJsonString(buf, cfg.file_path);
    try buf.appendSlice(",\"Keybinding\":");
    try appendKeybinding(buf, &cfg.keybinding);
    try buf.appendSlice(",\"Layout\":");
    try appendLayout(buf, cfg.layout);
    try buf.appendSlice(",\"Style\":");
    try appendStyle(buf, cfg.style);
    try buf.appendSlice(",\"Procs\":");
    try appendProcessMap(buf, &cfg.procs);
    try buf.appendSlice(",\"General\":");
    try appendGeneral(buf, cfg.general);
    try buf.appendSlice(",\"ShellCmd\":");
    try appendStringList(buf, cfg.shell_cmd.items);
    try buf.appendSlice(",\"LogFile\":");
    try appendJsonString(buf, cfg.log_file);
    try buf.appendSlice(",\"StdOutDebugLogFile\":");
    try appendJsonString(buf, cfg.stdout_debug_log_file);
    try buf.append('}');
}

fn appendKeybinding(buf: *std.array_list.Managed(u8), keybinding: *const config.schema.KeybindingConfig) !void {
    try buf.appendSlice("{\"Quit\":");
    try appendStringList(buf, keybinding.quit.items);
    try buf.appendSlice(",\"Up\":");
    try appendStringList(buf, keybinding.up.items);
    try buf.appendSlice(",\"Down\":");
    try appendStringList(buf, keybinding.down.items);
    try buf.appendSlice(",\"Start\":");
    try appendStringList(buf, keybinding.start.items);
    try buf.appendSlice(",\"Stop\":");
    try appendStringList(buf, keybinding.stop.items);
    try buf.appendSlice(",\"Restart\":");
    try appendStringList(buf, keybinding.restart.items);
    try buf.appendSlice(",\"Filter\":");
    try appendStringList(buf, keybinding.filter.items);
    try buf.appendSlice(",\"FilterSubmit\":");
    try appendStringList(buf, keybinding.submit_filter.items);
    try buf.appendSlice(",\"ToggleRunning\":");
    try appendStringList(buf, keybinding.toggle_running.items);
    try buf.appendSlice(",\"ToggleHelp\":");
    try appendStringList(buf, keybinding.toggle_help.items);
    try buf.appendSlice(",\"ToggleFocus\":");
    try appendStringList(buf, keybinding.toggle_focus.items);
    try buf.appendSlice(",\"FocusClient\":");
    try appendStringList(buf, keybinding.focus_client.items);
    try buf.appendSlice(",\"FocusServer\":");
    try appendStringList(buf, keybinding.focus_server.items);
    try buf.appendSlice(",\"Docs\":");
    try appendStringList(buf, keybinding.docs.items);
    try buf.append('}');
}

fn appendLayout(buf: *std.array_list.Managed(u8), layout: config.schema.LayoutConfig) !void {
    try buf.appendSlice("{\"CategorySearchPrefix\":");
    try appendJsonString(buf, layout.category_search_prefix);
    try buf.writer().print(
        ",\"ProcessesListWidth\":{},\"HideProcessDescriptionPanel\":{s},\"HideProcessListWhenUnfocused\":{s},\"SortProcessListAlpha\":{s},\"SortProcessListRunningFirst\":{s},\"PlaceholderBanner\":",
        .{
            layout.processes_list_width,
            if (layout.hide_process_description_panel) "true" else "false",
            if (layout.hide_process_list_when_unfocused) "true" else "false",
            if (layout.sort_process_list_alpha) "true" else "false",
            if (layout.sort_process_list_running_first) "true" else "false",
        },
    );
    try appendJsonString(buf, layout.placeholder_banner);
    try buf.writer().print(",\"EnableDebugProcessInfo\":{s}}}", .{
        if (layout.enable_debug_process_info) "true" else "false",
    });
}

fn appendStyle(buf: *std.array_list.Managed(u8), style: config.schema.StyleConfig) !void {
    try buf.appendSlice("{\"SelectedProcessColor\":");
    try appendJsonString(buf, style.selected_process_color);
    try buf.appendSlice(",\"SelectedProcessBgColor\":");
    try appendJsonString(buf, style.selected_process_bg_color);
    try buf.appendSlice(",\"UnselectedProcessColor\":");
    try appendJsonString(buf, style.unselected_process_color);
    try buf.appendSlice(",\"StatusRunningColor\":");
    try appendJsonString(buf, style.status_running_color);
    try buf.appendSlice(",\"StatusHaltingColor\":");
    try appendJsonString(buf, style.status_halting_color);
    try buf.appendSlice(",\"StatusStoppedColor\":");
    try appendJsonString(buf, style.status_stopped_color);
    try buf.appendSlice(",\"PointerChar\":");
    try appendJsonString(buf, style.pointer_char);
    try buf.append('}');
}

fn appendGeneral(buf: *std.array_list.Managed(u8), general: config.schema.GeneralConfig) !void {
    try buf.writer().print(
        "{{\"ProcsFromMakeTargets\":{s},\"ProcsFromPackageJSON\":{s}}}",
        .{
            if (general.procs_from_make_targets) "true" else "false",
            if (general.procs_from_package_json) "true" else "false",
        },
    );
}

fn appendProcessMap(buf: *std.array_list.Managed(u8), procs: *const config.schema.ProcessMap) !void {
    var keys = try buf.allocator.alloc([]const u8, procs.count());
    defer buf.allocator.free(keys);

    var it = procs.iterator();
    var index: usize = 0;
    while (it.next()) |entry| : (index += 1) keys[index] = entry.key_ptr.*;
    std.mem.sort([]const u8, keys, {}, lessThanString);

    try buf.append('{');
    for (keys, 0..) |key, key_index| {
        if (key_index != 0) try buf.append(',');
        try appendJsonString(buf, key);
        try buf.append(':');
        try appendProcessConfig(buf, procs.get(key).?);
    }
    try buf.append('}');
}

fn appendProcess(buf: *std.array_list.Managed(u8), process: domain.process.Process) !void {
    try buf.writer().print("{{\"ID\":{},\"Label\":", .{process.id.toInt()});
    try appendJsonString(buf, process.label);
    try buf.appendSlice(",\"Config\":");
    try appendProcessConfig(buf, process.config.*);
    try buf.append('}');
}

fn appendProcessView(buf: *std.array_list.Managed(u8), view: domain.process.ProcessView) !void {
    try buf.writer().print("{{\"ID\":{},\"Label\":", .{view.id.toInt()});
    try appendJsonString(buf, view.label);
    try buf.writer().print(",\"Status\":{},\"PID\":{},\"Config\":", .{
        @intFromEnum(view.status),
        view.pid,
    });
    try appendProcessConfig(buf, view.config.*);
    try buf.append('}');
}

fn appendProcessConfig(buf: *std.array_list.Managed(u8), proc_cfg: config.schema.ProcessConfig) !void {
    try buf.appendSlice("{\"Shell\":");
    try appendJsonString(buf, proc_cfg.shell);
    try buf.appendSlice(",\"Cmd\":");
    try appendStringList(buf, proc_cfg.cmd.items);
    try buf.appendSlice(",\"Cwd\":");
    try appendJsonString(buf, proc_cfg.cwd);
    try buf.appendSlice(",\"Env\":null");
    try buf.writer().print(
        ",\"Stop\":{},\"StopTimeout\":{},\"Autostart\":{s},\"Autofocus\":{s},\"Description\":",
        .{
            proc_cfg.stop,
            proc_cfg.stop_timeout_ms,
            if (proc_cfg.autostart) "true" else "false",
            if (proc_cfg.autofocus) "true" else "false",
        },
    );
    try appendJsonString(buf, proc_cfg.description);
    try buf.appendSlice(",\"Docs\":");
    try appendJsonString(buf, proc_cfg.docs);
    try buf.appendSlice(",\"MetaTags\":");
    try appendStringList(buf, proc_cfg.meta_tags.items);
    try buf.appendSlice(",\"Categories\":");
    try appendStringList(buf, proc_cfg.categories.items);
    try buf.appendSlice(",\"AddPath\":");
    try appendStringList(buf, proc_cfg.add_path.items);
    try buf.writer().print(",\"TerminalRows\":{},\"TerminalCols\":{},\"OnKill\":", .{
        proc_cfg.terminal_rows,
        proc_cfg.terminal_cols,
    });
    try appendStringList(buf, proc_cfg.on_kill.items);
    try buf.append('}');
}

fn appendStringList(buf: *std.array_list.Managed(u8), items: []const []const u8) !void {
    try buf.append('[');
    for (items, 0..) |item, index| {
        if (index != 0) try buf.append(',');
        try appendJsonString(buf, item);
    }
    try buf.append(']');
}

fn parseConfigValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    owned_strings: *std.array_list.Managed([]const u8),
) !config.schema.Config {
    if (value != .object) return error.InvalidState;
    const obj = value.object;

    var cfg = config.schema.Config.empty(allocator);
    errdefer cfg.deinit();

    cfg.file_path = try dupeOptionalString(allocator, obj, "FilePath");
    cfg.owns_file_path = cfg.file_path.len > 0;
    cfg.log_file = try dupeOptionalString(allocator, obj, "LogFile");
    cfg.stdout_debug_log_file = try dupeOptionalString(allocator, obj, "StdOutDebugLogFile");
    cfg.owns_log_paths = cfg.log_file.len > 0 or cfg.stdout_debug_log_file.len > 0;

    if (obj.get("Keybinding")) |keybinding_value| {
        try parseKeybindingInto(allocator, &cfg.keybinding, keybinding_value);
    }
    if (obj.get("Layout")) |layout_value| cfg.layout = try parseLayout(allocator, layout_value, owned_strings);
    if (obj.get("Style")) |style_value| cfg.style = try parseStyle(allocator, style_value, owned_strings);
    if (obj.get("General")) |general_value| cfg.general = try parseGeneral(general_value);
    if (obj.get("ShellCmd")) |shell_cmd_value| try parseStringListInto(allocator, &cfg.shell_cmd, shell_cmd_value);
    if (obj.get("Procs")) |procs_value| try parseProcessMapInto(allocator, &cfg.procs, procs_value);

    return cfg;
}

fn parseKeybindingInto(
    allocator: std.mem.Allocator,
    out: *config.schema.KeybindingConfig,
    value: std.json.Value,
) !void {
    if (value != .object) return error.InvalidState;
    const obj = value.object;

    if (obj.get("Quit")) |v| try parseStringListInto(allocator, &out.quit, v);
    if (obj.get("Up")) |v| try parseStringListInto(allocator, &out.up, v);
    if (obj.get("Down")) |v| try parseStringListInto(allocator, &out.down, v);
    if (obj.get("Start")) |v| try parseStringListInto(allocator, &out.start, v);
    if (obj.get("Stop")) |v| try parseStringListInto(allocator, &out.stop, v);
    if (obj.get("Restart")) |v| try parseStringListInto(allocator, &out.restart, v);
    if (obj.get("Filter")) |v| try parseStringListInto(allocator, &out.filter, v);
    if (obj.get("FilterSubmit")) |v| try parseStringListInto(allocator, &out.submit_filter, v);
    if (obj.get("ToggleRunning")) |v| try parseStringListInto(allocator, &out.toggle_running, v);
    if (obj.get("ToggleHelp")) |v| try parseStringListInto(allocator, &out.toggle_help, v);
    if (obj.get("ToggleFocus")) |v| try parseStringListInto(allocator, &out.toggle_focus, v);
    if (obj.get("FocusClient")) |v| try parseStringListInto(allocator, &out.focus_client, v);
    if (obj.get("FocusServer")) |v| try parseStringListInto(allocator, &out.focus_server, v);
    if (obj.get("Docs")) |v| try parseStringListInto(allocator, &out.docs, v);
}

fn parseLayout(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    owned_strings: *std.array_list.Managed([]const u8),
) !config.schema.LayoutConfig {
    if (value != .object) return error.InvalidState;
    const obj = value.object;
    return .{
        .category_search_prefix = try dupeTrackedOptionalString(allocator, owned_strings, obj, "CategorySearchPrefix"),
        .processes_list_width = try getOptionalI32(obj, "ProcessesListWidth", 0),
        .hide_process_description_panel = try getOptionalBool(obj, "HideProcessDescriptionPanel", false),
        .hide_process_list_when_unfocused = try getOptionalBool(obj, "HideProcessListWhenUnfocused", false),
        .sort_process_list_alpha = try getOptionalBool(obj, "SortProcessListAlpha", false),
        .sort_process_list_running_first = try getOptionalBool(obj, "SortProcessListRunningFirst", false),
        .placeholder_banner = try dupeTrackedOptionalString(allocator, owned_strings, obj, "PlaceholderBanner"),
        .enable_debug_process_info = try getOptionalBool(obj, "EnableDebugProcessInfo", false),
    };
}

fn parseStyle(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    owned_strings: *std.array_list.Managed([]const u8),
) !config.schema.StyleConfig {
    if (value != .object) return error.InvalidState;
    const obj = value.object;
    return .{
        .selected_process_color = try dupeTrackedOptionalString(allocator, owned_strings, obj, "SelectedProcessColor"),
        .selected_process_bg_color = try dupeTrackedOptionalString(allocator, owned_strings, obj, "SelectedProcessBgColor"),
        .unselected_process_color = try dupeTrackedOptionalString(allocator, owned_strings, obj, "UnselectedProcessColor"),
        .status_running_color = try dupeTrackedOptionalString(allocator, owned_strings, obj, "StatusRunningColor"),
        .status_halting_color = try dupeTrackedOptionalString(allocator, owned_strings, obj, "StatusHaltingColor"),
        .status_stopped_color = try dupeTrackedOptionalString(allocator, owned_strings, obj, "StatusStoppedColor"),
        .pointer_char = try dupeTrackedOptionalString(allocator, owned_strings, obj, "PointerChar"),
    };
}

fn parseGeneral(value: std.json.Value) !config.schema.GeneralConfig {
    if (value != .object) return error.InvalidState;
    const obj = value.object;
    return .{
        .procs_from_make_targets = try getOptionalBool(obj, "ProcsFromMakeTargets", false),
        .procs_from_package_json = try getOptionalBool(obj, "ProcsFromPackageJSON", false),
    };
}

fn parseProcessMapInto(
    allocator: std.mem.Allocator,
    out: *config.schema.ProcessMap,
    value: std.json.Value,
) !void {
    if (value != .object) return error.InvalidState;

    var it = value.object.iterator();
    while (it.next()) |entry| {
        const owned_label = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(owned_label);

        var proc_cfg = try parseProcessConfig(allocator, entry.value_ptr.*);
        errdefer proc_cfg.deinit(allocator);

        try out.put(owned_label, proc_cfg);
    }
}

fn parseProcessConfig(allocator: std.mem.Allocator, value: std.json.Value) !config.schema.ProcessConfig {
    if (value != .object) return error.InvalidState;
    const obj = value.object;

    var proc_cfg = config.schema.ProcessConfig.empty(allocator);
    errdefer proc_cfg.deinit(allocator);

    proc_cfg.owns_scalar_strings = true;
    proc_cfg.shell = try dupeOptionalString(allocator, obj, "Shell");
    proc_cfg.cwd = try dupeOptionalString(allocator, obj, "Cwd");
    proc_cfg.description = try dupeOptionalString(allocator, obj, "Description");
    proc_cfg.docs = try dupeOptionalString(allocator, obj, "Docs");
    proc_cfg.stop = try getOptionalI32(obj, "Stop", 0);
    proc_cfg.stop_timeout_ms = try getOptionalI32(obj, "StopTimeout", 0);
    proc_cfg.autostart = try getOptionalBool(obj, "Autostart", false);
    proc_cfg.autofocus = try getOptionalBool(obj, "Autofocus", false);
    proc_cfg.terminal_rows = try getOptionalI32(obj, "TerminalRows", 0);
    proc_cfg.terminal_cols = try getOptionalI32(obj, "TerminalCols", 0);

    if (obj.get("Cmd")) |v| try parseStringListInto(allocator, &proc_cfg.cmd, v);
    if (obj.get("MetaTags")) |v| try parseStringListInto(allocator, &proc_cfg.meta_tags, v);
    if (obj.get("Categories")) |v| try parseStringListInto(allocator, &proc_cfg.categories, v);
    if (obj.get("AddPath")) |v| try parseStringListInto(allocator, &proc_cfg.add_path, v);
    if (obj.get("OnKill")) |v| try parseStringListInto(allocator, &proc_cfg.on_kill, v);

    return proc_cfg;
}

fn parseStateProcess(cfg: *config.schema.Config, value: std.json.Value) !domain.process.Process {
    if (value != .object) return error.InvalidState;
    const obj = value.object;
    const label = try getRequiredString(obj, "Label");
    const label_ptr = findProcessLabel(&cfg.procs, label) orelse return error.InvalidState;
    return .{
        .id = domain.process.ProcessId.fromInt(try getRequiredU32(obj, "ID")),
        .label = label_ptr,
        .config = cfg.procs.getPtr(label) orelse return error.InvalidState,
    };
}

fn parseProcessView(cfg: *config.schema.Config, value: std.json.Value) !domain.process.ProcessView {
    if (value != .object) return error.InvalidState;
    const obj = value.object;
    const label = try getRequiredString(obj, "Label");
    const label_ptr = findProcessLabel(&cfg.procs, label) orelse return error.InvalidState;
    const status_int = try getRequiredU8(obj, "Status");
    return .{
        .id = domain.process.ProcessId.fromInt(try getRequiredU32(obj, "ID")),
        .label = label_ptr,
        .status = std.meta.intToEnum(domain.process.ProcessStatus, status_int) catch return error.InvalidState,
        .pid = try getOptionalI32(obj, "PID", -1),
        .config = cfg.procs.getPtr(label) orelse return error.InvalidState,
    };
}

fn parseStringListInto(
    allocator: std.mem.Allocator,
    out: *config.schema.StringList,
    value: std.json.Value,
) !void {
    if (value == .null) return;
    if (value != .array) return error.InvalidState;
    for (value.array.items) |item| {
        if (item != .string) return error.InvalidState;
        try config.schema.appendOwned(allocator, out, item.string);
    }
}

fn deinitStringSliceList(allocator: std.mem.Allocator, items: *std.array_list.Managed([]const u8)) void {
    for (items.items) |item| allocator.free(item);
    items.deinit();
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn findProcessLabel(procs: *const config.schema.ProcessMap, label: []const u8) ?[]const u8 {
    var it = procs.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, label)) return entry.key_ptr.*;
    }
    return null;
}

fn dupeOptionalString(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) ![]const u8 {
    const value = obj.get(key) orelse return "";
    if (value != .string) return error.InvalidState;
    if (value.string.len == 0) return "";
    return allocator.dupe(u8, value.string);
}

fn getRequiredString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = obj.get(key) orelse return error.InvalidState;
    if (value != .string) return error.InvalidState;
    return value.string;
}

fn dupeTrackedOptionalString(
    allocator: std.mem.Allocator,
    owned_strings: *std.array_list.Managed([]const u8),
    obj: std.json.ObjectMap,
    key: []const u8,
) ![]const u8 {
    const value = obj.get(key) orelse return "";
    if (value != .string) return error.InvalidState;
    if (value.string.len == 0) return "";
    const owned = try allocator.dupe(u8, value.string);
    errdefer allocator.free(owned);
    try owned_strings.append(owned);
    return owned;
}

fn getRequiredU32(obj: std.json.ObjectMap, key: []const u8) !u32 {
    const value = obj.get(key) orelse return error.InvalidState;
    if (value != .integer) return error.InvalidState;
    return @intCast(value.integer);
}

fn getRequiredU8(obj: std.json.ObjectMap, key: []const u8) !u8 {
    const value = obj.get(key) orelse return error.InvalidState;
    if (value != .integer) return error.InvalidState;
    return @intCast(value.integer);
}

fn getOptionalU32(obj: std.json.ObjectMap, key: []const u8, default: u32) !u32 {
    const value = obj.get(key) orelse return default;
    if (value != .integer) return error.InvalidState;
    return @intCast(value.integer);
}

fn getOptionalI32(obj: std.json.ObjectMap, key: []const u8, default: i32) !i32 {
    const value = obj.get(key) orelse return default;
    if (value != .integer) return error.InvalidState;
    return @intCast(value.integer);
}

fn getOptionalBool(obj: std.json.ObjectMap, key: []const u8, default: bool) !bool {
    const value = obj.get(key) orelse return default;
    if (value != .bool) return error.InvalidState;
    return value.bool;
}

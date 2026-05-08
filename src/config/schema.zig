const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const WarningKind = enum {
    dead_field,
    unknown_field,
};

pub const Warning = struct {
    kind: WarningKind,
    path: []const u8,
    message: []const u8,
};

pub const StringList = std.array_list.Managed([]const u8);
pub const StringMap = std.StringArrayHashMap([]const u8);
pub const ProcessMap = std.StringArrayHashMap(ProcessConfig);

pub const KeybindingConfig = struct {
    quit: StringList,
    up: StringList,
    down: StringList,
    start: StringList,
    stop: StringList,
    restart: StringList,
    filter: StringList,
    submit_filter: StringList,
    toggle_running: StringList,
    toggle_help: StringList,
    toggle_focus: StringList,
    focus_client: StringList,
    focus_server: StringList,
    docs: StringList,

    pub fn empty(allocator: Allocator) KeybindingConfig {
        return .{
            .quit = StringList.init(allocator),
            .up = StringList.init(allocator),
            .down = StringList.init(allocator),
            .start = StringList.init(allocator),
            .stop = StringList.init(allocator),
            .restart = StringList.init(allocator),
            .filter = StringList.init(allocator),
            .submit_filter = StringList.init(allocator),
            .toggle_running = StringList.init(allocator),
            .toggle_help = StringList.init(allocator),
            .toggle_focus = StringList.init(allocator),
            .focus_client = StringList.init(allocator),
            .focus_server = StringList.init(allocator),
            .docs = StringList.init(allocator),
        };
    }

    pub fn deinit(self: *KeybindingConfig) void {
        deinitStringList(&self.quit);
        deinitStringList(&self.up);
        deinitStringList(&self.down);
        deinitStringList(&self.start);
        deinitStringList(&self.stop);
        deinitStringList(&self.restart);
        deinitStringList(&self.filter);
        deinitStringList(&self.submit_filter);
        deinitStringList(&self.toggle_running);
        deinitStringList(&self.toggle_help);
        deinitStringList(&self.toggle_focus);
        deinitStringList(&self.focus_client);
        deinitStringList(&self.focus_server);
        deinitStringList(&self.docs);
    }
};

pub const LayoutConfig = struct {
    category_search_prefix: []const u8 = "",
    processes_list_width: i32 = 0,
    hide_process_description_panel: bool = false,
    hide_process_list_when_unfocused: bool = false,
    sort_process_list_alpha: bool = false,
    sort_process_list_running_first: bool = false,
    placeholder_banner: []const u8 = "",
    enable_debug_process_info: bool = false,
};

pub const StyleConfig = struct {
    selected_process_color: []const u8 = "",
    selected_process_bg_color: []const u8 = "",
    unselected_process_color: []const u8 = "",
    status_running_color: []const u8 = "",
    status_halting_color: []const u8 = "",
    status_stopped_color: []const u8 = "",
    pointer_char: []const u8 = "",
};

pub const GeneralConfig = struct {
    procs_from_make_targets: bool = false,
    procs_from_package_json: bool = false,
};

pub const ProcessConfig = struct {
    shell: []const u8 = "",
    cmd: StringList,
    cwd: []const u8 = "",
    env: StringMap,
    stop: i32 = 0,
    stop_timeout_ms: i32 = 0,
    autostart: bool = false,
    autofocus: bool = false,
    description: []const u8 = "",
    docs: []const u8 = "",
    meta_tags: StringList,
    categories: StringList,
    add_path: StringList,
    terminal_rows: i32 = 0,
    terminal_cols: i32 = 0,
    on_kill: StringList,
    owns_scalar_strings: bool = false,

    pub fn empty(allocator: Allocator) ProcessConfig {
        return .{
            .cmd = StringList.init(allocator),
            .env = StringMap.init(allocator),
            .meta_tags = StringList.init(allocator),
            .categories = StringList.init(allocator),
            .add_path = StringList.init(allocator),
            .on_kill = StringList.init(allocator),
        };
    }

    pub fn deinit(self: *ProcessConfig, allocator: Allocator) void {
        deinitStringList(&self.cmd);
        deinitStringList(&self.meta_tags);
        deinitStringList(&self.categories);
        deinitStringList(&self.add_path);
        deinitStringList(&self.on_kill);

        var it = self.env.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.env.deinit();

        if (self.owns_scalar_strings) {
            if (self.shell.len > 0) allocator.free(self.shell);
            if (self.cwd.len > 0) allocator.free(self.cwd);
            if (self.description.len > 0) allocator.free(self.description);
            if (self.docs.len > 0) allocator.free(self.docs);
        }
    }
};

pub const Config = struct {
    allocator: Allocator,
    file_path: []const u8 = "",
    owns_file_path: bool = false,
    keybinding: KeybindingConfig,
    layout: LayoutConfig = .{},
    style: StyleConfig = .{},
    general: GeneralConfig = .{},
    shell_cmd: StringList,
    log_file: []const u8 = "",
    stdout_debug_log_file: []const u8 = "",
    owns_log_paths: bool = false,
    procs: ProcessMap,

    pub fn empty(allocator: Allocator) Config {
        return .{
            .allocator = allocator,
            .keybinding = KeybindingConfig.empty(allocator),
            .shell_cmd = StringList.init(allocator),
            .procs = ProcessMap.init(allocator),
        };
    }

    pub fn deinit(self: *Config) void {
        self.keybinding.deinit();
        deinitStringList(&self.shell_cmd);
        var it = self.procs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.procs.deinit();
        if (self.owns_file_path and self.file_path.len > 0) self.allocator.free(self.file_path);
        if (self.owns_log_paths) {
            if (self.log_file.len > 0) self.allocator.free(self.log_file);
            if (self.stdout_debug_log_file.len > 0) self.allocator.free(self.stdout_debug_log_file);
        }
    }
};

pub fn deinitStringList(list: *StringList) void {
    const allocator = list.allocator;
    for (list.items) |item| allocator.free(item);
    list.deinit();
}

pub fn appendOwned(allocator: Allocator, list: *StringList, value: []const u8) !void {
    try list.append(try allocator.dupe(u8, value));
}

pub fn putOwnedString(allocator: Allocator, map: *StringMap, key: []const u8, value: []const u8) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);

    const gop = try map.getOrPut(owned_key);
    if (gop.found_existing) {
        allocator.free(owned_key);
        allocator.free(gop.value_ptr.*);
    }
    gop.value_ptr.* = owned_value;
}

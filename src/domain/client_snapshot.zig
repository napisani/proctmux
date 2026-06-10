const std = @import("std");
const config = @import("../config/root.zig");
const process = @import("process.zig");
const state = @import("state.zig");
const fuzzy = @import("fuzzy.zig");

pub const StringList = []const []const u8;

pub const UiKeybindingConfig = struct {
    quit: StringList = &.{},
    up: StringList = &.{},
    down: StringList = &.{},
    start: StringList = &.{},
    stop: StringList = &.{},
    restart: StringList = &.{},
    filter: StringList = &.{},
    submit_filter: StringList = &.{},
    toggle_running: StringList = &.{},
    toggle_help: StringList = &.{},
    toggle_focus: StringList = &.{},
    focus_client: StringList = &.{},
    focus_server: StringList = &.{},
    docs: StringList = &.{},
};

pub const UiLayoutConfig = struct {
    category_search_prefix: []const u8 = "cat:",
    hide_process_description_panel: bool = false,
    hide_process_list_when_unfocused: bool = false,
    sort_process_list_alpha: bool = false,
    sort_process_list_running_first: bool = false,
    placeholder_banner: []const u8 = "",
    enable_debug_process_info: bool = false,
};

pub const UiStyleConfig = struct {
    pointer_char: []const u8 = ">",
    status_running_color: []const u8 = "green",
    status_halting_color: []const u8 = "yellow",
    status_stopped_color: []const u8 = "red",
};

pub const UiConfig = struct {
    keybinding: UiKeybindingConfig = .{},
    layout: UiLayoutConfig = .{},
    style: UiStyleConfig = .{},
};

pub const ProcessSummary = struct {
    id: u32,
    label: []const u8,
    status: process.ProcessStatus = .halted,
    pid: i32 = -1,
    description: []const u8 = "",
    docs: []const u8 = "",
    categories: StringList = &.{},
};

pub const ClientSnapshot = struct {
    current_process_id: u32 = 0,
    exiting: bool = false,
    ui: UiConfig = .{},
    processes: []const ProcessSummary = &.{},

    pub fn currentProcessId(self: ClientSnapshot) process.ProcessId {
        return process.ProcessId.fromInt(self.current_process_id);
    }
};

/// Snapshot built from server-side state. The process-summary slice is owned;
/// strings inside summaries and UI config are borrowed from Project Config.
pub const BuiltClientSnapshot = struct {
    value: ClientSnapshot,

    pub fn view(self: *const BuiltClientSnapshot) *const ClientSnapshot {
        return &self.value;
    }

    pub fn deinit(self: *BuiltClientSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.value.processes);
        self.value.processes = &.{};
    }
};

pub fn fromAppState(
    allocator: std.mem.Allocator,
    app_state: *const state.AppState,
    controller: process.ProcessController,
) !BuiltClientSnapshot {
    var processes = try allocator.alloc(ProcessSummary, app_state.processes.items.len);
    errdefer allocator.free(processes);

    for (app_state.processes.items, 0..) |proc, index| {
        const view = process.toView(proc, controller);
        processes[index] = summaryFromView(view);
    }

    return .{ .value = .{
        .current_process_id = app_state.current_proc_id.toInt(),
        .exiting = app_state.exiting,
        .ui = fromConfig(app_state.config),
        .processes = processes,
    } };
}

pub fn summaryFromView(view: process.ProcessView) ProcessSummary {
    return .{
        .id = view.id.toInt(),
        .label = view.label,
        .status = view.status,
        .pid = view.pid,
        .description = view.config.description,
        .docs = view.config.docs,
        .categories = view.config.categories.items,
    };
}

pub fn filteredProcesses(
    allocator: std.mem.Allocator,
    snapshot: *const ClientSnapshot,
    filter_text: []const u8,
    show_only_running: bool,
) ![]ProcessSummary {
    const trimmed = std.mem.trim(u8, filter_text, " \t\r\n");
    if (trimmed.len == 0) {
        const result = try selectRunningProcesses(allocator, snapshot.processes, show_only_running);
        sortProcesses(&snapshot.ui, result);
        return result;
    }

    if (std.mem.startsWith(u8, trimmed, snapshot.ui.layout.category_search_prefix)) {
        const raw = trimmed[snapshot.ui.layout.category_search_prefix.len..];
        var result = std.array_list.Managed(ProcessSummary).init(allocator);
        errdefer result.deinit();
        for (snapshot.processes) |summary| {
            if (show_only_running and summary.status != .running) continue;
            if (matchesAllCategories(raw, summary.categories)) try result.append(summary);
        }
        const owned = try result.toOwnedSlice();
        sortProcesses(&snapshot.ui, owned);
        return owned;
    }

    var matches = std.array_list.Managed(fuzzy.Match).init(allocator);
    defer matches.deinit();
    for (snapshot.processes, 0..) |summary, index| {
        if (show_only_running and summary.status != .running) continue;
        if (fuzzy.score(trimmed, summary.label)) |score| {
            try matches.append(.{ .index = index, .score = score });
        }
    }
    fuzzy.sortMatches(matches.items);

    var result = std.array_list.Managed(ProcessSummary).init(allocator);
    errdefer result.deinit();
    for (matches.items) |match| try result.append(snapshot.processes[match.index]);
    return result.toOwnedSlice();
}

fn selectRunningProcesses(
    allocator: std.mem.Allocator,
    processes: []const ProcessSummary,
    show_only_running: bool,
) ![]ProcessSummary {
    var result = std.array_list.Managed(ProcessSummary).init(allocator);
    errdefer result.deinit();
    for (processes) |summary| {
        if (show_only_running and summary.status != .running) continue;
        try result.append(summary);
    }
    return result.toOwnedSlice();
}

fn sortProcesses(ui: *const UiConfig, items: []ProcessSummary) void {
    if (!ui.layout.sort_process_list_running_first and !ui.layout.sort_process_list_alpha) return;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const value = items[i];
        var j = i;
        while (j > 0 and lessProcess(ui, value, items[j - 1])) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = value;
    }
}

fn lessProcess(ui: *const UiConfig, a: ProcessSummary, b: ProcessSummary) bool {
    if (ui.layout.sort_process_list_running_first) {
        const a_running = a.status == .running;
        const b_running = b.status == .running;
        if (a_running != b_running) return a_running;
    }
    if (ui.layout.sort_process_list_alpha) {
        return std.mem.order(u8, a.label, b.label) == .lt;
    }
    return false;
}

fn matchesAllCategories(raw: []const u8, categories: []const []const u8) bool {
    var parts = std.mem.splitScalar(u8, raw, ',');
    while (parts.next()) |part| {
        const wanted = std.mem.trim(u8, part, " \t\r\n");
        var found = false;
        for (categories) |category| {
            if (fuzzyCategoryMatch(category, wanted)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn fuzzyCategoryMatch(a: []const u8, b: []const u8) bool {
    return indexOfIgnoreCase(a, b) != null or indexOfIgnoreCase(b, a) != null;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                matched = false;
                break;
            }
        }
        if (matched) return i;
    }
    return null;
}

pub fn fromConfig(cfg: *const config.schema.Config) UiConfig {
    return .{
        .keybinding = .{
            .quit = cfg.keybinding.quit.items,
            .up = cfg.keybinding.up.items,
            .down = cfg.keybinding.down.items,
            .start = cfg.keybinding.start.items,
            .stop = cfg.keybinding.stop.items,
            .restart = cfg.keybinding.restart.items,
            .filter = cfg.keybinding.filter.items,
            .submit_filter = cfg.keybinding.submit_filter.items,
            .toggle_running = cfg.keybinding.toggle_running.items,
            .toggle_help = cfg.keybinding.toggle_help.items,
            .toggle_focus = cfg.keybinding.toggle_focus.items,
            .focus_client = cfg.keybinding.focus_client.items,
            .focus_server = cfg.keybinding.focus_server.items,
            .docs = cfg.keybinding.docs.items,
        },
        .layout = .{
            .category_search_prefix = cfg.layout.category_search_prefix,
            .hide_process_description_panel = cfg.layout.hide_process_description_panel,
            .hide_process_list_when_unfocused = cfg.layout.hide_process_list_when_unfocused,
            .sort_process_list_alpha = cfg.layout.sort_process_list_alpha,
            .sort_process_list_running_first = cfg.layout.sort_process_list_running_first,
            .placeholder_banner = cfg.layout.placeholder_banner,
            .enable_debug_process_info = cfg.layout.enable_debug_process_info,
        },
        .style = .{
            .pointer_char = cfg.style.pointer_char,
            .status_running_color = cfg.style.status_running_color,
            .status_halting_color = cfg.style.status_halting_color,
            .status_stopped_color = cfg.style.status_stopped_color,
        },
    };
}

test "client snapshot includes only client-visible process data" {
    const test_config = @import("../test_support/config.zig");
    const test_ipc = @import("../test_support/ipc.zig");

    var cfg = try test_config.basicConfig(std.testing.allocator);
    defer cfg.deinit();
    try test_config.putShellProcess(&cfg, "api", "sleep 5");
    const proc_cfg = cfg.procs.getPtr("api").?;
    proc_cfg.description = try std.testing.allocator.dupe(u8, "API server");
    try config.schema.appendOwned(std.testing.allocator, &proc_cfg.categories, "backend");

    var app = try state.AppState.init(std.testing.allocator, &cfg);
    defer app.deinit();
    app.current_proc_id = process.ProcessId.fromInt(1);

    var fake_controller = test_ipc.FakeProcessController{
        .running_id = process.ProcessId.fromInt(1),
        .pid = 1234,
    };
    var snapshot = try fromAppState(std.testing.allocator, &app, fake_controller.controller());
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), snapshot.view().current_process_id);
    try std.testing.expectEqual(@as(usize, 1), snapshot.view().processes.len);
    try std.testing.expectEqualStrings("api", snapshot.view().processes[0].label);
    try std.testing.expectEqual(process.ProcessStatus.running, snapshot.view().processes[0].status);
    try std.testing.expectEqual(@as(i32, 1234), snapshot.view().processes[0].pid);
    try std.testing.expectEqualStrings("API server", snapshot.view().processes[0].description);
    try std.testing.expectEqualStrings("backend", snapshot.view().processes[0].categories[0]);
}

const schema = @import("schema.zig");

pub const banner =
    \\
    \\███    ██  ██████      ██████  ██████   ██████   ██████ ███████ ███████ ███████
    \\████   ██ ██    ██     ██   ██ ██   ██ ██    ██ ██      ██      ██      ██
    \\██ ██  ██ ██    ██     ██████  ██████  ██    ██ ██      █████   ███████ ███████
    \\██  ██ ██ ██    ██     ██      ██   ██ ██    ██ ██      ██           ██      ██
    \\██   ████  ██████      ██      ██   ██  ██████   ██████ ███████ ███████ ███████
;

fn setListDefault(allocator: schema.Allocator, list: *schema.StringList, values: []const []const u8) !void {
    if (list.items.len != 0) return;
    for (values) |value| try schema.appendOwned(allocator, list, value);
}

pub fn apply(cfg: *schema.Config, allocator: schema.Allocator) !void {
    try setListDefault(allocator, &cfg.keybinding.quit, &.{ "q", "ctrl+c" });
    try setListDefault(allocator, &cfg.keybinding.up, &.{ "k", "up" });
    try setListDefault(allocator, &cfg.keybinding.down, &.{ "j", "down" });
    try setListDefault(allocator, &cfg.keybinding.start, &.{ "s", "enter" });
    try setListDefault(allocator, &cfg.keybinding.stop, &.{"x"});
    try setListDefault(allocator, &cfg.keybinding.restart, &.{"r"});
    try setListDefault(allocator, &cfg.keybinding.filter, &.{"/"});
    try setListDefault(allocator, &cfg.keybinding.submit_filter, &.{"enter"});
    try setListDefault(allocator, &cfg.keybinding.toggle_running, &.{"R"});
    try setListDefault(allocator, &cfg.keybinding.toggle_help, &.{"?"});
    try setListDefault(allocator, &cfg.keybinding.toggle_focus, &.{"ctrl+w"});
    try setListDefault(allocator, &cfg.keybinding.focus_client, &.{"ctrl+left"});
    try setListDefault(allocator, &cfg.keybinding.focus_server, &.{"ctrl+right"});
    try setListDefault(allocator, &cfg.keybinding.docs, &.{"d"});

    if (cfg.layout.category_search_prefix.len == 0) cfg.layout.category_search_prefix = "cat:";
    if (cfg.layout.placeholder_banner.len == 0) cfg.layout.placeholder_banner = banner;
    if (cfg.layout.processes_list_width <= 0 or cfg.layout.processes_list_width > 100) {
        cfg.layout.processes_list_width = 30;
    }

    if (cfg.style.pointer_char.len == 0) cfg.style.pointer_char = "▶";
    if (cfg.style.selected_process_color.len == 0) cfg.style.selected_process_color = "white";
    if (cfg.style.selected_process_bg_color.len == 0) cfg.style.selected_process_bg_color = "magenta";
    if (cfg.style.status_running_color.len == 0) cfg.style.status_running_color = "green";
    if (cfg.style.status_halting_color.len == 0) cfg.style.status_halting_color = "yellow";
    if (cfg.style.status_stopped_color.len == 0) cfg.style.status_stopped_color = "red";
}

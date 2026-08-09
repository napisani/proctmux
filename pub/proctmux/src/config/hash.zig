//! Stable Project Config hashing for socket identity.
//! Only fields that should distinguish running proctmux instances participate, so clients and primaries agree on a Unix socket path for the same effective project.

const std = @import("std");
const schema = @import("schema.zig");

pub fn toHash(allocator: schema.Allocator, cfg: *const schema.Config) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try writeConfig(allocator, &buf, cfg);

    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(buf.items, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

fn writeConfig(allocator: schema.Allocator, buf: *std.array_list.Managed(u8), cfg: *const schema.Config) !void {
    try writeLine(buf, "file_path", cfg.file_path);
    try writeStringList(buf, "keybinding.quit", cfg.keybinding.quit);
    try writeStringList(buf, "keybinding.up", cfg.keybinding.up);
    try writeStringList(buf, "keybinding.down", cfg.keybinding.down);
    try writeStringList(buf, "keybinding.start", cfg.keybinding.start);
    try writeStringList(buf, "keybinding.stop", cfg.keybinding.stop);
    try writeStringList(buf, "keybinding.restart", cfg.keybinding.restart);
    try writeStringList(buf, "keybinding.filter", cfg.keybinding.filter);
    try writeStringList(buf, "keybinding.submit_filter", cfg.keybinding.submit_filter);
    try writeStringList(buf, "keybinding.toggle_running", cfg.keybinding.toggle_running);
    try writeStringList(buf, "keybinding.toggle_help", cfg.keybinding.toggle_help);
    try writeStringList(buf, "keybinding.toggle_focus", cfg.keybinding.toggle_focus);
    try writeStringList(buf, "keybinding.focus_client", cfg.keybinding.focus_client);
    try writeStringList(buf, "keybinding.focus_server", cfg.keybinding.focus_server);
    try writeStringList(buf, "keybinding.docs", cfg.keybinding.docs);

    try writeLine(buf, "layout.category_search_prefix", cfg.layout.category_search_prefix);
    try writeInt(buf, "layout.processes_list_width", cfg.layout.processes_list_width);
    try writeBool(buf, "layout.hide_process_description_panel", cfg.layout.hide_process_description_panel);
    try writeBool(buf, "layout.hide_process_list_when_unfocused", cfg.layout.hide_process_list_when_unfocused);
    try writeBool(buf, "layout.sort_process_list_alpha", cfg.layout.sort_process_list_alpha);
    try writeBool(buf, "layout.sort_process_list_running_first", cfg.layout.sort_process_list_running_first);
    try writeLine(buf, "layout.placeholder_banner", cfg.layout.placeholder_banner);
    try writeBool(buf, "layout.enable_debug_process_info", cfg.layout.enable_debug_process_info);

    try writeLine(buf, "style.selected_process_color", cfg.style.selected_process_color);
    try writeLine(buf, "style.selected_process_bg_color", cfg.style.selected_process_bg_color);
    try writeLine(buf, "style.unselected_process_color", cfg.style.unselected_process_color);
    try writeLine(buf, "style.status_running_color", cfg.style.status_running_color);
    try writeLine(buf, "style.status_halting_color", cfg.style.status_halting_color);
    try writeLine(buf, "style.status_stopped_color", cfg.style.status_stopped_color);
    try writeLine(buf, "style.pointer_char", cfg.style.pointer_char);

    try writeBool(buf, "general.procs_from_make_targets", cfg.general.procs_from_make_targets);
    try writeBool(buf, "general.procs_from_package_json", cfg.general.procs_from_package_json);
    try writeStringList(buf, "shell_cmd", cfg.shell_cmd);
    try writeLine(buf, "log_file", cfg.log_file);
    try writeLine(buf, "stdout_debug_log_file", cfg.stdout_debug_log_file);

    var keys = try allocator.alloc([]const u8, cfg.procs.count());
    defer allocator.free(keys);
    var it = cfg.procs.iterator();
    var index: usize = 0;
    while (it.next()) |entry| : (index += 1) keys[index] = entry.key_ptr.*;
    std.mem.sort([]const u8, keys, {}, lessThanString);

    try writeInt(buf, "procs#len", @intCast(keys.len));
    for (keys) |label| {
        try writeProcess(allocator, buf, label, cfg.procs.get(label).?);
    }
}

fn writeProcess(allocator: schema.Allocator, buf: *std.array_list.Managed(u8), label: []const u8, proc: schema.ProcessConfig) !void {
    try writeLine(buf, "proc.label", label);
    try writeLine(buf, "proc.shell", proc.shell);
    try writeStringList(buf, "proc.cmd", proc.cmd);
    try writeLine(buf, "proc.cwd", proc.cwd);
    try writeStringMap(allocator, buf, "proc.env", proc.env);
    try writeInt(buf, "proc.stop", proc.stop);
    try writeInt(buf, "proc.stop_timeout_ms", proc.stop_timeout_ms);
    try writeBool(buf, "proc.autostart", proc.autostart);
    try writeBool(buf, "proc.autofocus", proc.autofocus);
    try writeLine(buf, "proc.description", proc.description);
    try writeLine(buf, "proc.docs", proc.docs);
    try writeStringList(buf, "proc.meta_tags", proc.meta_tags);
    try writeStringList(buf, "proc.categories", proc.categories);
    try writeStringList(buf, "proc.add_path", proc.add_path);
    try writeInt(buf, "proc.terminal_rows", proc.terminal_rows);
    try writeInt(buf, "proc.terminal_cols", proc.terminal_cols);
    try writeStringList(buf, "proc.on_kill", proc.on_kill);
}

fn writeLine(buf: *std.array_list.Managed(u8), key: []const u8, value: []const u8) !void {
    try buf.appendSlice(key);
    try buf.append('=');
    try buf.appendSlice(value);
    try buf.append('\n');
}

fn writeBool(buf: *std.array_list.Managed(u8), key: []const u8, value: bool) !void {
    try writeLine(buf, key, if (value) "true" else "false");
}

fn writeInt(buf: *std.array_list.Managed(u8), key: []const u8, value: i32) !void {
    try buf.writer().print("{s}={}\n", .{ key, value });
}

fn writeStringList(buf: *std.array_list.Managed(u8), key: []const u8, list: schema.StringList) !void {
    try buf.writer().print("{s}#len={}\n", .{ key, list.items.len });
    for (list.items, 0..) |item, i| {
        try buf.writer().print("{s}[{}]#len={}: {s}\n", .{ key, i, item.len, item });
    }
}

fn writeStringMap(allocator: schema.Allocator, buf: *std.array_list.Managed(u8), key: []const u8, map: schema.StringMap) !void {
    var keys = try allocator.alloc([]const u8, map.count());
    defer allocator.free(keys);
    var it = map.iterator();
    var index: usize = 0;
    while (it.next()) |entry| : (index += 1) keys[index] = entry.key_ptr.*;
    std.mem.sort([]const u8, keys, {}, lessThanString);

    try buf.writer().print("{s}#len={}\n", .{ key, keys.len });
    for (keys) |map_key| {
        try buf.writer().print("{s}.{s}={s}\n", .{ key, map_key, map.get(map_key).? });
    }
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

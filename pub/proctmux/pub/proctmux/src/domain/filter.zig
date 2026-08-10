//! Filtering and sorting for server-side ProcessView lists.
//! Client Snapshot filtering has its own module because summaries are the client-visible shape; this file remains for internal process views.

const std = @import("std");
const config = @import("../config/root.zig");
const process = @import("process.zig");
const fuzzy = @import("fuzzy.zig");

pub fn filterProcesses(
    allocator: std.mem.Allocator,
    cfg: *const config.schema.Config,
    processes: []const process.ProcessView,
    filter_text: []const u8,
    show_only_running: bool,
) ![]process.ProcessView {
    const trimmed = std.mem.trim(u8, filter_text, " \t\r\n");
    if (trimmed.len == 0) {
        const result = try selectRunning(allocator, processes, show_only_running);
        sortProcesses(cfg, result);
        return result;
    }

    if (std.mem.startsWith(u8, trimmed, cfg.layout.category_search_prefix)) {
        const raw = trimmed[cfg.layout.category_search_prefix.len..];
        var result = std.array_list.Managed(process.ProcessView).init(allocator);
        errdefer result.deinit();
        for (processes) |view| {
            if (show_only_running and view.status != .running) continue;
            if (matchesAllCategories(raw, view.config.categories.items)) try result.append(view);
        }
        const owned = try result.toOwnedSlice();
        sortProcesses(cfg, owned);
        return owned;
    }

    var matches = std.array_list.Managed(fuzzy.Match).init(allocator);
    defer matches.deinit();
    for (processes, 0..) |view, index| {
        if (show_only_running and view.status != .running) continue;
        if (fuzzy.score(trimmed, view.label)) |score| {
            try matches.append(.{ .index = index, .score = score });
        }
    }
    fuzzy.sortMatches(matches.items);

    var result = std.array_list.Managed(process.ProcessView).init(allocator);
    errdefer result.deinit();
    for (matches.items) |match| try result.append(processes[match.index]);
    return result.toOwnedSlice();
}

fn selectRunning(
    allocator: std.mem.Allocator,
    processes: []const process.ProcessView,
    show_only_running: bool,
) ![]process.ProcessView {
    var result = std.array_list.Managed(process.ProcessView).init(allocator);
    errdefer result.deinit();
    for (processes) |view| {
        if (show_only_running and view.status != .running) continue;
        try result.append(view);
    }
    return result.toOwnedSlice();
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

fn sortProcesses(cfg: *const config.schema.Config, items: []process.ProcessView) void {
    if (!cfg.layout.sort_process_list_running_first and !cfg.layout.sort_process_list_alpha) return;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const value = items[i];
        var j = i;
        while (j > 0 and lessProcess(cfg, value, items[j - 1])) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = value;
    }
}

fn lessProcess(cfg: *const config.schema.Config, a: process.ProcessView, b: process.ProcessView) bool {
    if (cfg.layout.sort_process_list_running_first) {
        const a_running = a.status == .running;
        const b_running = b.status == .running;
        if (a_running != b_running) return a_running;
    }
    if (cfg.layout.sort_process_list_alpha) {
        return std.mem.order(u8, a.label, b.label) == .lt;
    }
    return false;
}

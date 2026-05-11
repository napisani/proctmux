const std = @import("std");

pub const schema = @import("schema.zig");
pub const defaults = @import("defaults.zig");
pub const load = @import("load.zig");
pub const hash = @import("hash.zig");
pub const template = @import("template.zig");
pub const runtime = @import("runtime.zig");

test {
    _ = schema;
    _ = defaults;
    _ = load;
    _ = hash;
    _ = template;
    _ = runtime;
}

test "defaults match active Go defaults" {
    var cfg = schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();

    try defaults.apply(&cfg, std.testing.allocator);

    try std.testing.expectEqualStrings("q", cfg.keybinding.quit.items[0]);
    try std.testing.expectEqualStrings("ctrl+c", cfg.keybinding.quit.items[1]);
    try std.testing.expectEqualStrings("/", cfg.keybinding.filter.items[0]);
    try std.testing.expectEqualStrings("R", cfg.keybinding.toggle_running.items[0]);
    try std.testing.expectEqualStrings("?", cfg.keybinding.toggle_help.items[0]);
    try std.testing.expectEqualStrings("ctrl+w", cfg.keybinding.toggle_focus.items[0]);
    try std.testing.expectEqualStrings("d", cfg.keybinding.docs.items[0]);

    try std.testing.expectEqualStrings("cat:", cfg.layout.category_search_prefix);
    try std.testing.expectEqual(@as(i32, 30), cfg.layout.processes_list_width);
    try std.testing.expect(!cfg.layout.sort_process_list_running_first);
    try std.testing.expectEqualStrings("▶", cfg.style.pointer_char);
    try std.testing.expectEqualStrings("white", cfg.style.selected_process_color);
    try std.testing.expectEqualStrings("magenta", cfg.style.selected_process_bg_color);
    try std.testing.expectEqualStrings("green", cfg.style.status_running_color);
    try std.testing.expectEqualStrings("yellow", cfg.style.status_halting_color);
    try std.testing.expectEqualStrings("red", cfg.style.status_stopped_color);
}

test "load full active config fixture" {
    var loaded = try load.loadFile(std.testing.allocator, "testdata/phase2/config/full-active.yaml");
    defer loaded.deinit();

    try std.testing.expect(std.mem.endsWith(u8, loaded.config.file_path, "testdata/phase2/config/full-active.yaml"));
    try std.testing.expectEqualStrings("cat:", loaded.config.layout.category_search_prefix);
    try std.testing.expectEqual(@as(i32, 45), loaded.config.layout.processes_list_width);
    try std.testing.expect(loaded.config.layout.hide_process_description_panel);
    try std.testing.expect(loaded.config.layout.hide_process_list_when_unfocused);
    try std.testing.expect(loaded.config.layout.sort_process_list_alpha);
    try std.testing.expect(loaded.config.layout.sort_process_list_running_first);
    try std.testing.expect(loaded.config.layout.enable_debug_process_info);
    try std.testing.expectEqualStrings(">", loaded.config.style.pointer_char);
    try std.testing.expectEqualStrings("blue", loaded.config.style.unselected_process_color);
    try std.testing.expect(loaded.config.general.procs_from_make_targets);
    try std.testing.expect(loaded.config.general.procs_from_package_json);
    try std.testing.expectEqualStrings("/bin/bash", loaded.config.shell_cmd.items[0]);
    try std.testing.expectEqualStrings("/tmp/proctmux.log", loaded.config.log_file);

    const backend = loaded.config.procs.get("backend").?;
    try std.testing.expectEqualStrings("npm run dev", backend.shell);
    try std.testing.expectEqualStrings("api", backend.categories.items[1]);
    try std.testing.expectEqualStrings("api", backend.env.get("ROLE").?);
    try std.testing.expectEqual(@as(i32, 3000), backend.stop_timeout_ms);
    try std.testing.expectEqual(@as(i32, 40), backend.terminal_rows);

    const worker = loaded.config.procs.get("worker").?;
    try std.testing.expectEqualStrings("python", worker.cmd.items[0]);
}

test "load minimal config applies defaults" {
    var loaded = try load.loadFile(std.testing.allocator, "testdata/phase2/config/minimal.yaml");
    defer loaded.deinit();

    try std.testing.expectEqualStrings("q", loaded.config.keybinding.quit.items[0]);
    try std.testing.expectEqualStrings("cat:", loaded.config.layout.category_search_prefix);
    try std.testing.expectEqual(@as(i32, 30), loaded.config.layout.processes_list_width);
    try std.testing.expectEqualStrings("▶", loaded.config.style.pointer_char);
}

test "load process docs and meta tags like Go config" {
    var loaded = try load.loadFromSlice(
        std.testing.allocator,
        \\procs:
        \\  api:
        \\    shell: "sleep 1"
        \\    docs: "API developer notes"
        \\    meta_tags: ["service", "backend"]
        \\
    ,
        "inline-docs.yaml",
    );
    defer loaded.deinit();

    const proc = loaded.config.procs.get("api").?;
    try std.testing.expectEqualStrings("API developer notes", proc.docs);
    try std.testing.expectEqual(@as(usize, 2), proc.meta_tags.items.len);
    try std.testing.expectEqualStrings("service", proc.meta_tags.items[0]);
    try std.testing.expectEqualStrings("backend", proc.meta_tags.items[1]);
    try std.testing.expect(!loaded.hasWarning("procs.api.docs"));
    try std.testing.expect(!loaded.hasWarning("procs.api.meta_tags"));
}

test "load process docs literal block like Go config init" {
    var loaded = try load.loadFromSlice(
        std.testing.allocator,
        \\procs:
        \\  api:
        \\    shell: "sleep 1"
        \\    docs: |
        \\      API developer notes
        \\      Second line
        \\
    ,
        "inline-docs-block.yaml",
    );
    defer loaded.deinit();

    const proc = loaded.config.procs.get("api").?;
    try std.testing.expectEqualStrings("API developer notes\nSecond line\n", proc.docs);
}

test "load quoted process labels with spaces like Go config" {
    var loaded = try load.loadFromSlice(
        std.testing.allocator,
        \\procs:
        \\  "test ansi":
        \\    shell: "echo ok"
        \\
    ,
        "inline-quoted-label.yaml",
    );
    defer loaded.deinit();

    const proc = loaded.config.procs.get("test ansi").?;
    try std.testing.expectEqualStrings("echo ok", proc.shell);
}

test "load double quoted shell string with escaped backslash" {
    var loaded = try load.loadFromSlice(
        std.testing.allocator,
        \\procs:
        \\  ansi:
        \\    shell: "printf '\\033[31mred\\033[0m\n'"
        \\
    ,
        "inline-escaped-backslash.yaml",
    );
    defer loaded.deinit();

    const proc = loaded.config.procs.get("ansi").?;
    try std.testing.expectEqualStrings("printf '\\033[31mred\\033[0m\n'", proc.shell);
}

test "load double quoted shell string ending with escaped quote" {
    var loaded = try load.loadFromSlice(
        std.testing.allocator,
        \\procs:
        \\  interactive:
        \\    shell: "echo \"Nice to meet you, $name!\""
        \\
    ,
        "inline-escaped-ending-quote.yaml",
    );
    defer loaded.deinit();

    const proc = loaded.config.procs.get("interactive").?;
    try std.testing.expectEqualStrings("echo \"Nice to meet you, $name!\"", proc.shell);
}

test "load plain scalar values with trailing spaces like Go config" {
    var loaded = try load.loadFromSlice(
        std.testing.allocator,
        \\layout:
        \\  hide_process_description_panel: true 
        \\  sort_process_list_alpha: false 
        \\  sort_process_list_running_first: true
        \\
    ,
        "inline-trailing-spaces.yaml",
    );
    defer loaded.deinit();

    try std.testing.expect(loaded.config.layout.hide_process_description_panel);
    try std.testing.expect(!loaded.config.layout.sort_process_list_alpha);
    try std.testing.expect(loaded.config.layout.sort_process_list_running_first);
}

test "load file in dir uses supplied directory and records resolved path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "custom.yaml", .data = "{}\n" });

    var loaded = try load.loadFileInDir(std.testing.allocator, tmp.dir, "custom.yaml");
    defer loaded.deinit();

    try std.testing.expect(std.mem.endsWith(u8, loaded.config.file_path, "custom.yaml"));
    try std.testing.expectEqualStrings("q", loaded.config.keybinding.quit.items[0]);
}

test "load default in dir follows proctmux search order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "procmux.yml", .data = "{}\n" });

    var loaded = try load.loadDefaultInDir(std.testing.allocator, tmp.dir);
    defer loaded.deinit();

    try std.testing.expect(std.mem.endsWith(u8, loaded.config.file_path, "procmux.yml"));
    try std.testing.expectEqualStrings("cat:", loaded.config.layout.category_search_prefix);
}

test "runtime config loads explicit file and applies Makefile discovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "proctmux.yaml", .data = 
        \\general:
        \\  procs_from_make_targets: true
        \\procs:
        \\  explicit:
        \\    shell: "echo explicit"
        \\
    });
    try tmp.dir.writeFile(.{
        .sub_path = "Makefile",
        .data = "build:\n",
    });

    var loaded = try runtime.loadInDir(std.testing.allocator, tmp.dir, "proctmux.yaml");
    defer loaded.deinit();

    try std.testing.expect(loaded.config.procs.contains("explicit"));
    try std.testing.expect(loaded.config.procs.contains("make:build"));
}

test "runtime config loads default file and applies Makefile discovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "proctmux.yaml", .data = 
        \\general:
        \\  procs_from_make_targets: true
        \\
    });
    try tmp.dir.writeFile(.{
        .sub_path = "Makefile",
        .data = "test:\n",
    });

    var loaded = try runtime.loadInDir(std.testing.allocator, tmp.dir, "");
    defer loaded.deinit();

    try std.testing.expect(loaded.config.procs.contains("make:test"));
}

test "dead and unknown fields warn and do not populate active config" {
    var loaded = try load.loadFile(std.testing.allocator, "testdata/phase2/config/dead-fields.yaml");
    defer loaded.deinit();

    try std.testing.expect(loaded.hasWarning("enable_mouse"));
    try std.testing.expect(loaded.hasWarning("signal_server"));
    try std.testing.expect(loaded.hasWarning("general.detached_session_name"));
    try std.testing.expect(loaded.hasWarning("general.kill_existing_session"));
    try std.testing.expect(loaded.hasWarning("style.color_level"));
    try std.testing.expect(loaded.hasWarning("style.style_classes"));
    try std.testing.expect(loaded.hasWarning("style.placeholder_terminal_bg_color"));
    try std.testing.expect(loaded.hasWarning("style.unified_terminal_fg_color"));
    try std.testing.expect(loaded.hasWarning("style.unified_terminal_bg_color"));
    try std.testing.expect(loaded.hasWarning("procs.docs-demo.unknown_process_field"));
    try std.testing.expect(loaded.hasWarning("unknown_top_level"));

    const proc = loaded.config.procs.get("docs-demo").?;
    try std.testing.expectEqualStrings("sleep 1", proc.shell);
    try std.testing.expectEqualStrings("Not active in current Go input handling", proc.docs);
    try std.testing.expectEqualStrings("legacy", proc.meta_tags.items[0]);
    try std.testing.expectEqual(@as(usize, 0), proc.categories.items.len);
}

test "malformed yaml returns parse error" {
    try std.testing.expectError(error.ParseFailure, load.loadFile(std.testing.allocator, "testdata/phase2/config/malformed.yaml"));
}

test "active config hash is stable hex" {
    var loaded = try load.loadFile(std.testing.allocator, "testdata/phase2/config/full-active.yaml");
    defer loaded.deinit();

    const first = try hash.toHash(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(first);
    const second = try hash.toHash(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expectEqual(@as(usize, 32), first.len);
    for (first) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "changing process config changes active config hash" {
    var a = try load.loadFile(std.testing.allocator, "testdata/phase2/config/full-active.yaml");
    defer a.deinit();
    var b = try load.loadFile(std.testing.allocator, "testdata/phase2/config/full-active.yaml");
    defer b.deinit();

    b.config.procs.getPtr("backend").?.shell = "yarn dev";

    const hash_a = try hash.toHash(std.testing.allocator, &a.config);
    defer std.testing.allocator.free(hash_a);
    const hash_b = try hash.toHash(std.testing.allocator, &b.config);
    defer std.testing.allocator.free(hash_b);

    try std.testing.expect(!std.mem.eql(u8, hash_a, hash_b));
}

test "dead fields do not affect active config hash" {
    var dead = try load.loadFile(std.testing.allocator, "testdata/phase2/config/dead-fields.yaml");
    defer dead.deinit();
    var equivalent = try load.loadFile(std.testing.allocator, "testdata/phase2/config/dead-fields-active-equivalent.yaml");
    defer equivalent.deinit();

    dead.config.file_path = "";
    equivalent.config.file_path = "";

    const hash_dead = try hash.toHash(std.testing.allocator, &dead.config);
    defer std.testing.allocator.free(hash_dead);
    const hash_equivalent = try hash.toHash(std.testing.allocator, &equivalent.config);
    defer std.testing.allocator.free(hash_equivalent);

    try std.testing.expectEqualStrings(hash_equivalent, hash_dead);
    try std.testing.expect(dead.hasWarning("general.detached_session_name"));
    try std.testing.expect(!dead.hasWarning("procs.docs-demo.docs"));
    try std.testing.expect(!dead.hasWarning("procs.docs-demo.meta_tags"));
}

test "starter template parses docs and meta tags fields" {
    const content = template.content();
    try std.testing.expect(std.mem.indexOf(u8, content, "procs:") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "docs: |") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "meta_tags") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "detached_session_name") == null);

    var loaded = try load.loadFromSlice(std.testing.allocator, content, "generated");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.warnings.items.len);
}

test "process list width follows Go clamp behavior" {
    const Case = struct { input: i32, expected: i32 };
    const cases = [_]Case{
        .{ .input = 0, .expected = 30 },
        .{ .input = -10, .expected = 30 },
        .{ .input = 101, .expected = 30 },
        .{ .input = 50, .expected = 50 },
        .{ .input = 1, .expected = 1 },
        .{ .input = 99, .expected = 99 },
        .{ .input = 100, .expected = 100 },
    };

    for (cases) |case| {
        var cfg = schema.Config.empty(std.testing.allocator);
        defer cfg.deinit();
        cfg.layout.processes_list_width = case.input;
        try defaults.apply(&cfg, std.testing.allocator);
        try std.testing.expectEqual(case.expected, cfg.layout.processes_list_width);
    }
}

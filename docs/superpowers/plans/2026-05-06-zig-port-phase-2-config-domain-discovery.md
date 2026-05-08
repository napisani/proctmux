# Zig Port Phase 2 Config Domain Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the non-UI, non-IPC foundation of proctmux to Zig: config loading/defaults/warnings/hash, process domain state, filtering/sorting, and process discovery.

**Architecture:** Keep the Zig code split by behavior, not by the old Go package tree: `config` owns YAML/defaults/hash, `domain` owns process views and list behavior, and `discover` owns Makefile/package.json process creation. The Go implementation remains a reference only through fixture parity tests; shipped runtime behavior comes from Zig after the hard cutover.

**Tech Stack:** Zig 0.15.2, Zig stdlib, vendored `kubkon/zig-yaml` 0.2.0 as a local path dependency, existing Go tests as reference behavior, shared fixtures under `testdata/phase2`.

> Current repo note: the YAML dependency is vendored under
> `third_party/zig-yaml`, not `vendor/zig-yaml`. The active Makefile also uses
> direct `zig test` and `zig build-exe` invocations for local Zig verification,
> because the pinned macOS/Nix `zig build` runner path can fail before project
> code runs when SDK/libc context is not propagated. Use `make test-zig`,
> `make build-zig`, and the phase-specific Makefile parity targets for current
> verification.

---

## Sources

- Approved design: `docs/superpowers/specs/2026-05-06-zig-port-design.md`
- Phase 1 scaffold: `docs/superpowers/plans/2026-05-06-zig-port-phase-1-foundation.md`
- Active Go behavior:
  - `internal/config/*.go`
  - `internal/domain/*.go`
  - `internal/procdiscover/**/*.go`
  - `internal/process/builder.go`
  - `internal/process/controller.go`
  - `internal/tui/render.go`
  - `internal/tui/input.go`
- Zig package manager docs: `build.zig.zon` dependencies support local `path` dependencies and URL/hash dependencies.
- YAML dependency source: `https://github.com/kubkon/zig-yaml`
- YAML dependency release: `https://github.com/kubkon/zig-yaml/releases/tag/0.2.0`

## Phase Boundary

This phase does not implement CLI routing, IPC, PTY process execution, libghostty-vt, libvaxis, or runtime modes. It builds the pure modules those phases depend on.

Dead or stale config fields are warning-only inputs. They are parsed enough to report a warning, then ignored by runtime behavior and by the Zig config hash. This intentionally avoids preserving Go hash behavior where Go's opaque YAML marshal included stale struct fields; the hard-cutover Zig hash is MD5 over the active effective config only.

## Active Config Schema

Port these fields as active behavior:

- `keybinding`: `quit`, `up`, `down`, `start`, `stop`, `restart`, `filter`, `submit_filter`, `toggle_running`, `toggle_help`, `toggle_focus`, `focus_client`, `focus_server`, `docs`
- `layout`: `category_search_prefix`, `processes_list_width`, `hide_process_description_panel`, `hide_process_list_when_unfocused`, `sort_process_list_alpha`, `sort_process_list_running_first`, `placeholder_banner`, `enable_debug_process_info`
- `style`: `selected_process_color`, `selected_process_bg_color`, `unselected_process_color`, `status_running_color`, `status_halting_color`, `status_stopped_color`, `pointer_char`
- `general`: `procs_from_make_targets`, `procs_from_package_json`
- top level: `procs`, `shell_cmd`, `log_file`, `stdout_debug_log_file`
- process: `shell`, `cmd`, `cwd`, `env`, `stop`, `stop_timeout_ms`, `autostart`, `autofocus`, `description`, `categories`, `add_path`, `terminal_rows`, `terminal_cols`, `on_kill`

Warn and ignore these stale fields when present:

- top level: `enable_mouse`, `signal_server`
- `general`: `detached_session_name`, `kill_existing_session`
- `style`: `style_classes`, `color_level`, `placeholder_terminal_bg_color`, `unified_terminal_fg_color`, `unified_terminal_bg_color`
- process: `docs`, `meta_tags`
- any unknown field at top level, section level, or inside a process definition

## File Structure

- Modify `build.zig`: wire the vendored YAML dependency into the executable and test modules.
- Modify `build.zig.zon`: add `.dependencies.yaml.path = "third_party/zig-yaml"` and include `third_party/zig-yaml` in `.paths`.
- Modify `Makefile`: add phase-specific parity test target.
- Modify `src/root.zig`: export and test-import `config`, `domain`, and `discover`.
- Create `src/config/root.zig`: public entrypoint for config modules.
- Create `src/config/schema.zig`: active config structs, warning structs, cloning/deinit helpers.
- Create `src/config/defaults.zig`: default values and default application.
- Create `src/config/load.zig`: file search, YAML parse, active-field decode, dead/unknown warnings.
- Create `src/config/hash.zig`: deterministic active config hash.
- Create `src/config/template.zig`: starter config content without stale fields.
- Create `src/domain/root.zig`: public entrypoint for domain modules.
- Create `src/domain/process.zig`: status enum, process config view, command string helpers.
- Create `src/domain/state.zig`: app state construction and lookup.
- Create `src/domain/fuzzy.zig`: Zig port of the active Go fuzzy ranking behavior.
- Create `src/domain/filter.zig`: category filtering, fuzzy label filtering, running-only and sort behavior.
- Create `src/discover/root.zig`: public entrypoint for discovery modules.
- Create `src/discover/makefile.zig`: Makefile target discovery.
- Create `src/discover/package_json.zig`: package.json script discovery and package-manager detection.
- Create `src/discover/apply.zig`: deterministic discovery orchestration and manual-process precedence.
- Create `testdata/phase2/config/*.yaml`: shared config fixtures.
- Create `testdata/phase2/discovery/*`: shared discovery fixtures.
- Create `tools/parity/phase2/config_domain_discovery_test.go`: Go reference assertions against the same fixtures.

---

### Task 1: Vendor YAML And Wire Build

**Files:**
- Create: `third_party/zig-yaml/`
- Modify: `build.zig`
- Modify: `build.zig.zon`
- Modify: `src/root.zig`

- [ ] **Step 1: Create an isolated worktree**

Run from `/Users/nick/code/proctmux`:

```bash
git status --short
git worktree add .worktrees/zig-port-phase-2-config-domain-discovery -b zig-port-phase-2-config-domain-discovery
cd .worktrees/zig-port-phase-2-config-domain-discovery
```

Expected: `git status --short` is clean before creating the worktree.

- [ ] **Step 2: Vendor `kubkon/zig-yaml` 0.2.0**

Run:

```bash
mkdir -p third_party /tmp/proctmux-zig-deps
curl -L https://github.com/kubkon/zig-yaml/archive/refs/tags/0.2.0.tar.gz -o /tmp/proctmux-zig-deps/zig-yaml-0.2.0.tar.gz
tar -xzf /tmp/proctmux-zig-deps/zig-yaml-0.2.0.tar.gz -C third_party
mv third_party/zig-yaml-0.2.0 third_party/zig-yaml
```

Expected: `third_party/zig-yaml/build.zig.zon`, `third_party/zig-yaml/src`, and `third_party/zig-yaml/LICENSE` exist.

- [ ] **Step 3: Modify `build.zig.zon`**

Change `build.zig.zon` to:

```zig
.{
    .name = .proctmux,
    .version = "0.1.0",
    .fingerprint = 0x3d7124ec04f5452a,
    .minimum_zig_version = "0.15.2",
    .dependencies = .{
        .yaml = .{
            .path = "third_party/zig-yaml",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "third_party/zig-yaml",
    },
}
```

- [ ] **Step 4: Modify `build.zig`**

Replace the direct module creation with named modules so the YAML dependency is imported by both executable and tests:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const yaml_dep = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("yaml", yaml_dep.module("yaml"));

    const exe = b.addExecutable(.{
        .name = "proctmux",
        .root_module = exe_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run proctmux");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("yaml", yaml_dep.module("yaml"));

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
```

- [ ] **Step 5: Add a vendored dependency smoke test to `src/root.zig`**

Keep the existing version export and add:

```zig
pub const version = @import("version.zig");

test {
    _ = version;
}

test "vendored yaml dependency is available" {
    const yaml = @import("yaml");
    _ = yaml.Yaml;
}
```

- [ ] **Step 6: Run build tests**

Run:

```bash
nix develop --command make test-zig
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add build.zig build.zig.zon src/root.zig third_party/zig-yaml
git commit -m "build: vendor zig yaml dependency"
```

---

### Task 2: Add Shared Phase 2 Fixtures

**Files:**
- Create: `testdata/phase2/config/minimal.yaml`
- Create: `testdata/phase2/config/full-active.yaml`
- Create: `testdata/phase2/config/dead-fields.yaml`
- Create: `testdata/phase2/config/dead-fields-active-equivalent.yaml`
- Create: `testdata/phase2/config/malformed.yaml`
- Create: `testdata/phase2/discovery/Makefile`
- Create: `testdata/phase2/discovery/package.json`
- Create: `testdata/phase2/discovery/pnpm-lock.yaml`

- [ ] **Step 1: Create `testdata/phase2/config/minimal.yaml`**

```yaml
{}
```

- [ ] **Step 2: Create `testdata/phase2/config/full-active.yaml`**

```yaml
keybinding:
  quit: ["q"]
  up: ["k"]
  down: ["j"]
  start: ["s", "enter"]
  stop: ["x"]
  restart: ["r"]
  filter: ["/"]
  submit_filter: ["enter"]
  toggle_running: ["R"]
  toggle_help: ["?"]
  toggle_focus: ["ctrl+w"]
  focus_client: ["ctrl+left"]
  focus_server: ["ctrl+right"]
  docs: ["d"]

layout:
  category_search_prefix: "cat:"
  processes_list_width: 45
  hide_process_description_panel: true
  hide_process_list_when_unfocused: true
  sort_process_list_alpha: true
  sort_process_list_running_first: true
  placeholder_banner: "READY"
  enable_debug_process_info: true

style:
  selected_process_color: "white"
  selected_process_bg_color: "magenta"
  unselected_process_color: "blue"
  status_running_color: "green"
  status_halting_color: "yellow"
  status_stopped_color: "red"
  pointer_char: ">"

general:
  procs_from_make_targets: true
  procs_from_package_json: true

shell_cmd: ["/bin/bash", "-c"]
log_file: "/tmp/proctmux.log"
stdout_debug_log_file: "/tmp/proctmux-stdout.log"

procs:
  backend:
    shell: "npm run dev"
    cwd: "."
    env:
      ROLE: "api"
    stop: 15
    stop_timeout_ms: 3000
    autostart: true
    autofocus: true
    description: "Backend server"
    categories: ["server", "api"]
    add_path: ["./node_modules/.bin"]
    terminal_rows: 40
    terminal_cols: 120
    on_kill: ["echo", "cleanup"]
  worker:
    cmd: ["python", "-m", "worker"]
    categories: ["worker"]
```

- [ ] **Step 3: Create `testdata/phase2/config/dead-fields.yaml`**

```yaml
enable_mouse: true
signal_server:
  enable: true
  host: "localhost"
  port: 9792

general:
  detached_session_name: "_legacy"
  kill_existing_session: true
  procs_from_make_targets: false
  procs_from_package_json: false

style:
  style_classes:
    selected: "legacy"
  color_level: "truecolors"
  placeholder_terminal_bg_color: "black"
  unified_terminal_fg_color: "white"
  unified_terminal_bg_color: "black"
  pointer_char: ">"

procs:
  docs-demo:
    shell: "sleep 1"
    docs: "Not active in current Go input handling"
    meta_tags: ["legacy"]
    unknown_process_field: "ignored"

unknown_top_level: "ignored"
```

- [ ] **Step 4: Create `testdata/phase2/config/dead-fields-active-equivalent.yaml`**

```yaml
style:
  pointer_char: ">"

procs:
  docs-demo:
    shell: "sleep 1"
```

- [ ] **Step 5: Create `testdata/phase2/config/malformed.yaml`**

```yaml
general:
  procs_from_make_targets: "unterminated
procs:
  demo:
    shell: "sleep 1"
```

- [ ] **Step 6: Create discovery fixtures**

`testdata/phase2/discovery/Makefile`:

```makefile
build:
	@echo build

test:
	@echo test

.PHONY: build test
```

`testdata/phase2/discovery/package.json`:

```json
{
  "scripts": {
    "dev": "node server.js",
    "build": "pnpm run compile",
    "bad script": "rm -rf /"
  }
}
```

`testdata/phase2/discovery/pnpm-lock.yaml`:

```yaml
lockfileVersion: "9.0"
```

- [ ] **Step 7: Commit**

```bash
git add testdata/phase2
git commit -m "test: add zig phase 2 fixtures"
```

---

### Task 3: Config Schema And Defaults

**Files:**
- Create: `src/config/root.zig`
- Create: `src/config/schema.zig`
- Create: `src/config/defaults.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write schema/default tests in `src/config/root.zig`**

```zig
pub const schema = @import("schema.zig");
pub const defaults = @import("defaults.zig");

test {
    _ = schema;
    _ = defaults;
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
```

- [ ] **Step 2: Export config from `src/root.zig`**

```zig
pub const version = @import("version.zig");
pub const config = @import("config/root.zig");

test {
    _ = version;
    _ = config;
}

test "vendored yaml dependency is available" {
    const yaml = @import("yaml");
    _ = yaml.Yaml;
}
```

- [ ] **Step 3: Implement `src/config/schema.zig`**

Define owned active structs with `std.array_list.Managed([]const u8)` for repeated strings and `std.StringArrayHashMap` for deterministic map iteration after sorting keys at use sites. The public API must include these names:

```zig
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
    categories: StringList,
    add_path: StringList,
    terminal_rows: i32 = 0,
    terminal_cols: i32 = 0,
    on_kill: StringList,

    pub fn empty(allocator: Allocator) ProcessConfig {
        return .{
            .cmd = StringList.init(allocator),
            .env = StringMap.init(allocator),
            .categories = StringList.init(allocator),
            .add_path = StringList.init(allocator),
            .on_kill = StringList.init(allocator),
        };
    }
};

pub const Config = struct {
    allocator: Allocator,
    file_path: []const u8 = "",
    keybinding: KeybindingConfig,
    layout: LayoutConfig = .{},
    style: StyleConfig = .{},
    general: GeneralConfig = .{},
    shell_cmd: StringList,
    log_file: []const u8 = "",
    stdout_debug_log_file: []const u8 = "",
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
        deinitStringList(&self.keybinding.quit);
        deinitStringList(&self.keybinding.up);
        deinitStringList(&self.keybinding.down);
        deinitStringList(&self.keybinding.start);
        deinitStringList(&self.keybinding.stop);
        deinitStringList(&self.keybinding.restart);
        deinitStringList(&self.keybinding.filter);
        deinitStringList(&self.keybinding.submit_filter);
        deinitStringList(&self.keybinding.toggle_running);
        deinitStringList(&self.keybinding.toggle_help);
        deinitStringList(&self.keybinding.toggle_focus);
        deinitStringList(&self.keybinding.focus_client);
        deinitStringList(&self.keybinding.focus_server);
        deinitStringList(&self.keybinding.docs);
        deinitStringList(&self.shell_cmd);
        var it = self.procs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.procs.deinit();
        if (self.file_path.len > 0) self.allocator.free(self.file_path);
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
```

Add `ProcessConfig.deinit` below the struct:

```zig
pub fn deinitProcessConfig(self: *ProcessConfig, allocator: Allocator) void {
    deinitStringList(&self.cmd);
    deinitStringList(&self.categories);
    deinitStringList(&self.add_path);
    deinitStringList(&self.on_kill);
    var it = self.env.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    self.env.deinit();
}
```

Wire this as `pub fn deinit(self: *ProcessConfig, allocator: Allocator) void { deinitProcessConfig(self, allocator); }`.

- [ ] **Step 4: Implement `src/config/defaults.zig`**

Include the Go banner exactly, then apply defaults only to active fields:

```zig
const std = @import("std");
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
```

- [ ] **Step 5: Run tests**

Run:

```bash
nix develop --command make test-zig
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/root.zig src/config
git commit -m "feat: add zig config schema defaults"
```

---

### Task 4: YAML Config Loader With Dead-Field Warnings

**Files:**
- Modify: `src/config/root.zig`
- Create: `src/config/load.zig`

- [ ] **Step 1: Add loader tests to `src/config/root.zig`**

```zig
pub const load = @import("load.zig");

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
    try std.testing.expect(loaded.config.general.procs_from_make_targets);
    try std.testing.expect(loaded.config.general.procs_from_package_json);

    const backend = loaded.config.procs.get("backend").?;
    try std.testing.expectEqualStrings("npm run dev", backend.shell);
    try std.testing.expectEqualStrings("api", backend.categories.items[1]);
    try std.testing.expectEqual(@as(i32, 3000), backend.stop_timeout_ms);
}

test "load minimal config applies defaults" {
    var loaded = try load.loadFile(std.testing.allocator, "testdata/phase2/config/minimal.yaml");
    defer loaded.deinit();

    try std.testing.expectEqualStrings("q", loaded.config.keybinding.quit.items[0]);
    try std.testing.expectEqualStrings("cat:", loaded.config.layout.category_search_prefix);
    try std.testing.expectEqual(@as(i32, 30), loaded.config.layout.processes_list_width);
    try std.testing.expectEqualStrings("▶", loaded.config.style.pointer_char);
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
    try std.testing.expect(loaded.hasWarning("procs.docs-demo.docs"));
    try std.testing.expect(loaded.hasWarning("procs.docs-demo.meta_tags"));
    try std.testing.expect(loaded.hasWarning("procs.docs-demo.unknown_process_field"));
    try std.testing.expect(loaded.hasWarning("unknown_top_level"));

    const proc = loaded.config.procs.get("docs-demo").?;
    try std.testing.expectEqualStrings("sleep 1", proc.shell);
    try std.testing.expectEqual(@as(usize, 0), proc.categories.items.len);
}

test "malformed yaml returns parse error" {
    try std.testing.expectError(error.ParseFailure, load.loadFile(std.testing.allocator, "testdata/phase2/config/malformed.yaml"));
}
```

- [ ] **Step 2: Implement the public loader API in `src/config/load.zig`**

Use this public shape:

```zig
const std = @import("std");
const yaml_mod = @import("yaml");
const schema = @import("schema.zig");
const defaults = @import("defaults.zig");

pub const LoadedConfig = struct {
    parent_allocator: schema.Allocator,
    arena: std.heap.ArenaAllocator,
    config: schema.Config,
    warnings: std.array_list.Managed(schema.Warning),

    pub fn deinit(self: *LoadedConfig) void {
        self.warnings.deinit();
        self.config.deinit();
        self.arena.deinit();
    }

    pub fn hasWarning(self: LoadedConfig, path: []const u8) bool {
        for (self.warnings.items) |warning| {
            if (std.mem.eql(u8, warning.path, path)) return true;
        }
        return false;
    }
};

pub fn loadFile(allocator: schema.Allocator, path: []const u8) !LoadedConfig {
    const data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer allocator.free(data);

    const absolute_path = try std.fs.cwd().realpathAlloc(allocator, path);
    defer allocator.free(absolute_path);

    var loaded = try loadFromSlice(allocator, data, absolute_path);
    return loaded;
}

pub fn loadDefault(allocator: schema.Allocator) !LoadedConfig {
    const paths = [_][]const u8{ "proctmux.yaml", "proctmux.yml", "procmux.yaml", "procmux.yml" };
    for (paths) |path| {
        return loadFile(allocator, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
    }
    return error.ConfigFileNotFound;
}
```

Decode active fields from YAML into `schema.Config`. Parse the YAML with `yaml_mod.Yaml` using the vendored examples as the API reference:

```zig
pub fn loadFromSlice(allocator: schema.Allocator, source: []const u8, source_path: []const u8) !LoadedConfig {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var cfg = schema.Config.empty(arena_allocator);
    errdefer cfg.deinit();

    var warnings = std.array_list.Managed(schema.Warning).init(arena_allocator);
    errdefer deinitWarnings(arena_allocator, &warnings);

    var yml: yaml_mod.Yaml = .{ .source = source };
    defer yml.deinit(allocator);

    yml.load(allocator) catch |err| switch (err) {
        error.ParseFailure => return error.ParseFailure,
        else => return err,
    };

    try decodeDocument(arena_allocator, &cfg, &warnings, yml);
    try defaults.apply(&cfg, arena_allocator);
    cfg.file_path = try arena_allocator.dupe(u8, source_path);

    return .{
        .parent_allocator = allocator,
        .arena = arena,
        .config = cfg,
        .warnings = warnings,
    };
}
```

The implementation must provide these helper names so later tasks can use them:

```zig
fn deinitWarnings(allocator: schema.Allocator, warnings: *std.array_list.Managed(schema.Warning)) void
fn addWarning(allocator: schema.Allocator, warnings: *std.array_list.Managed(schema.Warning), kind: schema.WarningKind, path: []const u8, message: []const u8) !void
fn decodeDocument(allocator: schema.Allocator, cfg: *schema.Config, warnings: *std.array_list.Managed(schema.Warning), yml: yaml_mod.Yaml) !void
```

Decode booleans, ints, strings, string lists, string maps, process maps, and nested mappings. Duplicate YAML keys should use the last value, matching common YAML decoder behavior.

- [ ] **Step 3: Run loader tests**

Run:

```bash
nix develop --command make test-zig
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/config/root.zig src/config/load.zig
git commit -m "feat: load zig config yaml"
```

---

### Task 5: Config Hash And Starter Template

**Files:**
- Modify: `src/config/root.zig`
- Create: `src/config/hash.zig`
- Create: `src/config/template.zig`

- [ ] **Step 1: Add hash/template tests to `src/config/root.zig`**

```zig
pub const hash = @import("hash.zig");
pub const template = @import("template.zig");

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

    equivalent.config.file_path = "";
    dead.config.file_path = "";

    const hash_equivalent = try hash.toHash(std.testing.allocator, &equivalent.config);
    defer std.testing.allocator.free(hash_equivalent);
    const hash_dead = try hash.toHash(std.testing.allocator, &dead.config);
    defer std.testing.allocator.free(hash_dead);

    try std.testing.expectEqualStrings(hash_equivalent, hash_dead);
    try std.testing.expect(dead.hasWarning("general.detached_session_name"));
    try std.testing.expect(dead.hasWarning("procs.docs-demo.docs"));
}

test "starter template parses and contains no stale docs field" {
    const content = template.content();
    try std.testing.expect(std.mem.indexOf(u8, content, "procs:") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "meta_tags") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "detached_session_name") == null);

    var loaded = try load.loadFromSlice(std.testing.allocator, content, "generated");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.warnings.items.len);
}
```

- [ ] **Step 2: Implement `src/config/hash.zig`**

Use deterministic active serialization and MD5:

```zig
const std = @import("std");
const schema = @import("schema.zig");

pub fn toHash(allocator: schema.Allocator, cfg: *const schema.Config) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try writeConfig(&buf, cfg);

    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(buf.items, &digest, .{});
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
}

fn writeLine(buf: *std.array_list.Managed(u8), key: []const u8, value: []const u8) !void {
    try buf.appendSlice(key);
    try buf.append('=');
    try buf.appendSlice(value);
    try buf.append('\n');
}
```

Serialize every active config field in a fixed order. For `procs`, copy keys into an array, sort ascending with `std.mem.order(u8, a, b)`, then serialize each process. For `env`, copy keys and sort ascending before serializing. Lists are serialized with length-prefixed entries:

```zig
fn writeStringList(buf: *std.array_list.Managed(u8), key: []const u8, list: []const []const u8) !void {
    try buf.appendSlice(key);
    try buf.appendSlice("#len=");
    try buf.writer().print("{}\n", .{list.len});
    for (list, 0..) |item, i| {
        try buf.writer().print("{s}[{}]#len={}: {s}\n", .{ key, i, item.len, item });
    }
}
```

Include `file_path` in the hash so two config files with the same content can own distinct sockets, matching the active Go operational model.

- [ ] **Step 3: Implement `src/config/template.zig`**

Return a starter YAML string that contains active fields only:

```zig
pub fn content() []const u8 {
    return
        \\# Proctmux Configuration File
        \\# Generated by 'proctmux config-init'
        \\
        \\procs:
        \\  "example-process":
        \\    shell: "echo 'Hello from proctmux!' && sleep 30"
        \\    cwd: "."
        \\    env:
        \\      EXAMPLE_VAR: "example_value"
        \\    add_path: ["./node_modules/.bin"]
        \\    stop: 15
        \\    stop_timeout_ms: 3000
        \\    on_kill: ["echo", "Cleanup complete"]
        \\    autostart: false
        \\    autofocus: false
        \\    description: "Example process"
        \\    categories: ["example", "demo"]
        \\
        \\general:
        \\  procs_from_make_targets: false
        \\  procs_from_package_json: false
        \\
        \\layout:
        \\  processes_list_width: 30
        \\  hide_process_description_panel: false
        \\  hide_process_list_when_unfocused: false
        \\  sort_process_list_alpha: false
        \\  sort_process_list_running_first: false
        \\  category_search_prefix: "cat:"
        \\  enable_debug_process_info: false
        \\
        \\style:
        \\  pointer_char: "▶"
        \\  selected_process_color: "white"
        \\  selected_process_bg_color: "magenta"
        \\  unselected_process_color: "blue"
        \\  status_running_color: "green"
        \\  status_halting_color: "yellow"
        \\  status_stopped_color: "red"
        \\
        \\keybinding:
        \\  quit: ["q", "ctrl+c"]
        \\  up: ["k", "up"]
        \\  down: ["j", "down"]
        \\  start: ["s", "enter"]
        \\  stop: ["x"]
        \\  restart: ["r"]
        \\  filter: ["/"]
        \\  submit_filter: ["enter"]
        \\  toggle_running: ["R"]
        \\  toggle_help: ["?"]
        \\  toggle_focus: ["ctrl+w"]
        \\  focus_client: ["ctrl+left"]
        \\  focus_server: ["ctrl+right"]
        \\  docs: ["d"]
        \\
        \\shell_cmd: ["sh", "-c"]
        \\log_file: ""
        \\stdout_debug_log_file: ""
        \\
    ;
}
```

- [ ] **Step 4: Run tests**

```bash
nix develop --command make test-zig
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/config/root.zig src/config/hash.zig src/config/template.zig
git commit -m "feat: add zig config hash template"
```

---

### Task 6: Domain Process And App State

**Files:**
- Create: `src/domain/root.zig`
- Create: `src/domain/process.zig`
- Create: `src/domain/state.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Add domain tests in `src/domain/root.zig`**

```zig
pub const process = @import("process.zig");
pub const state = @import("state.zig");

test {
    _ = process;
    _ = state;
}

test "status names match Go" {
    try std.testing.expectEqualStrings("Running", process.statusName(.running));
    try std.testing.expectEqualStrings("Halting", process.statusName(.halting));
    try std.testing.expectEqualStrings("Halted", process.statusName(.halted));
    try std.testing.expectEqualStrings("Exited", process.statusName(.exited));
    try std.testing.expectEqualStrings("Unknown", process.statusName(.unknown));
}

test "process command prefers shell and quotes cmd args like Go" {
    var cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);

    cfg.shell = "tail -f /var/log/syslog";
    try std.testing.expectEqualStrings("tail -f /var/log/syslog", try process.commandString(std.testing.allocator, &cfg));

    cfg.shell = "";
    try config.schema.appendOwned(std.testing.allocator, &cfg.cmd, "/bin/bash");
    try config.schema.appendOwned(std.testing.allocator, &cfg.cmd, "-c");
    try config.schema.appendOwned(std.testing.allocator, &cfg.cmd, "echo DONE");
    const cmd = try process.commandString(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(cmd);
    try std.testing.expectEqualStrings("'/bin/bash' '-c' 'echo DONE' ", cmd);
}

test "app state sorts process labels before assigning ids" {
    var loaded = try config.load.loadFile(std.testing.allocator, "testdata/phase2/config/full-active.yaml");
    defer loaded.deinit();

    var app = try state.AppState.init(std.testing.allocator, &loaded.config);
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 2), app.processes.items.len);
    try std.testing.expectEqualStrings("backend", app.processes.items[0].label);
    try std.testing.expectEqual(@as(u32, 1), app.processes.items[0].id);
    try std.testing.expectEqualStrings("worker", app.processes.items[1].label);
    try std.testing.expectEqual(@as(u32, 2), app.processes.items[1].id);
    try std.testing.expect(app.getProcessByLabel("Backend") == null);
    try std.testing.expect(app.getProcessByLabel("backend") != null);
}
```

- [ ] **Step 2: Export domain from `src/root.zig`**

```zig
pub const version = @import("version.zig");
pub const config = @import("config/root.zig");
pub const domain = @import("domain/root.zig");

test {
    _ = version;
    _ = config;
    _ = domain;
}
```

- [ ] **Step 3: Implement `src/domain/process.zig`**

```zig
const std = @import("std");
const config = @import("../config/root.zig");

pub const ProcessStatus = enum(u8) {
    unknown = 0,
    running = 1,
    halting = 2,
    halted = 3,
    exited = 4,
};

pub fn statusName(status: ProcessStatus) []const u8 {
    return switch (status) {
        .running => "Running",
        .halting => "Halting",
        .halted => "Halted",
        .exited => "Exited",
        .unknown => "Unknown",
    };
}

pub const Process = struct {
    id: u32,
    label: []const u8,
    config: *config.schema.ProcessConfig,
};

pub const ProcessView = struct {
    id: u32,
    label: []const u8,
    status: ProcessStatus = .halted,
    pid: i32 = -1,
    config: *config.schema.ProcessConfig,
};

pub fn commandString(allocator: std.mem.Allocator, proc_cfg: *const config.schema.ProcessConfig) ![]const u8 {
    if (proc_cfg.shell.len > 0) return proc_cfg.shell;
    if (proc_cfg.cmd.items.len == 0) return "";

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    for (proc_cfg.cmd.items) |part| {
        try out.append('\'');
        try out.appendSlice(part);
        try out.appendSlice("' ");
    }
    return out.toOwnedSlice();
}
```

- [ ] **Step 4: Implement `src/domain/state.zig`**

```zig
const std = @import("std");
const config = @import("../config/root.zig");
const process = @import("process.zig");

pub const Mode = enum {
    normal,
    filter,
};

pub const AppState = struct {
    allocator: std.mem.Allocator,
    config: *config.schema.Config,
    processes: std.array_list.Managed(process.Process),
    current_proc_id: u32 = 0,
    exiting: bool = false,

    pub fn init(allocator: std.mem.Allocator, cfg: *config.schema.Config) !AppState {
        var app = AppState{
            .allocator = allocator,
            .config = cfg,
            .processes = std.array_list.Managed(process.Process).init(allocator),
        };
        errdefer app.deinit();

        var keys = try allocator.alloc([]const u8, cfg.procs.count());
        defer allocator.free(keys);
        var it = cfg.procs.iterator();
        var index: usize = 0;
        while (it.next()) |entry| : (index += 1) keys[index] = entry.key_ptr.*;
        std.mem.sort([]const u8, keys, {}, lessThanString);

        for (keys, 0..) |label, i| {
            try app.processes.append(.{
                .id = @intCast(i + 1),
                .label = label,
                .config = cfg.procs.getPtr(label).?,
            });
        }
        return app;
    }

    pub fn deinit(self: *AppState) void {
        self.processes.deinit();
    }

    pub fn getProcessByID(self: *AppState, id: u32) ?*process.Process {
        for (self.processes.items) |*proc| if (proc.id == id) return proc;
        return null;
    }

    pub fn getProcessByLabel(self: *AppState, label: []const u8) ?*process.Process {
        for (self.processes.items) |*proc| if (std.mem.eql(u8, proc.label, label)) return proc;
        return null;
    }
};

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
```

- [ ] **Step 5: Run tests**

```bash
nix develop --command make test-zig
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/root.zig src/domain
git commit -m "feat: add zig domain state"
```

---

### Task 7: Filter, Category Match, And Fuzzy Ranking

**Files:**
- Modify: `src/domain/root.zig`
- Create: `src/domain/fuzzy.zig`
- Create: `src/domain/filter.zig`

- [ ] **Step 1: Add filter tests in `src/domain/root.zig`**

```zig
pub const fuzzy = @import("fuzzy.zig");
pub const filter = @import("filter.zig");

test "category filter uses AND matching and running-only toggle" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);

    var api_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer api_cfg.deinit(std.testing.allocator);
    try config.schema.appendOwned(std.testing.allocator, &api_cfg.categories, "server");
    try config.schema.appendOwned(std.testing.allocator, &api_cfg.categories, "api");

    var gateway_cfg = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer gateway_cfg.deinit(std.testing.allocator);
    try config.schema.appendOwned(std.testing.allocator, &gateway_cfg.categories, "server");
    try config.schema.appendOwned(std.testing.allocator, &gateway_cfg.categories, "gateway");

    var views = [_]process.ProcessView{
        .{ .id = 1, .label = "backend", .status = .running, .pid = 101, .config = &api_cfg },
        .{ .id = 2, .label = "api-gateway", .status = .halted, .pid = -1, .config = &gateway_cfg },
    };

    const result = try filter.filterProcesses(std.testing.allocator, &cfg, views[0..], "cat:server,api", false);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("backend", result[0].label);

    const running = try filter.filterProcesses(std.testing.allocator, &cfg, views[0..], "cat:server", true);
    defer std.testing.allocator.free(running);
    try std.testing.expectEqual(@as(usize, 1), running.len);
    try std.testing.expectEqualStrings("backend", running[0].label);
}

test "sort running first then alpha" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    cfg.layout.sort_process_list_running_first = true;
    cfg.layout.sort_process_list_alpha = true;

    var empty_proc = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer empty_proc.deinit(std.testing.allocator);

    var views = [_]process.ProcessView{
        .{ .id = 1, .label = "halted-zebra", .status = .halted, .config = &empty_proc },
        .{ .id = 2, .label = "running-mango", .status = .running, .config = &empty_proc },
        .{ .id = 3, .label = "halted-apple", .status = .halted, .config = &empty_proc },
        .{ .id = 4, .label = "running-banana", .status = .running, .config = &empty_proc },
    };

    const result = try filter.filterProcesses(std.testing.allocator, &cfg, views[0..], "", false);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("running-banana", result[0].label);
    try std.testing.expectEqualStrings("running-mango", result[1].label);
    try std.testing.expectEqualStrings("halted-apple", result[2].label);
    try std.testing.expectEqualStrings("halted-zebra", result[3].label);
}

test "fuzzy label search ignores configured sorting" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    cfg.layout.sort_process_list_running_first = true;
    cfg.layout.sort_process_list_alpha = true;

    var empty_proc = config.schema.ProcessConfig.empty(std.testing.allocator);
    defer empty_proc.deinit(std.testing.allocator);

    var views = [_]process.ProcessView{
        .{ .id = 1, .label = "zebra-api", .status = .halted, .config = &empty_proc },
        .{ .id = 2, .label = "api-service", .status = .running, .config = &empty_proc },
        .{ .id = 3, .label = "apple-api", .status = .halted, .config = &empty_proc },
    };

    const result = try filter.filterProcesses(std.testing.allocator, &cfg, views[0..], "api", false);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
}
```

- [ ] **Step 2: Implement `src/domain/fuzzy.zig`**

Port the active Go constants and score rules:

```zig
const std = @import("std");

const first_char_match_bonus = 10;
const match_following_separator_bonus = 20;
const camel_case_match_bonus = 20;
const adjacent_match_bonus = 5;
const unmatched_leading_char_penalty = -5;
const max_unmatched_leading_char_penalty = -15;

pub const Match = struct {
    index: usize,
    score: i32,
};

pub fn find(allocator: std.mem.Allocator, pattern: []const u8, labels: []const []const u8) ![]Match {
    if (pattern.len == 0) return &[_]Match{};

    var matches = std.array_list.Managed(Match).init(allocator);
    errdefer matches.deinit();

    for (labels, 0..) |label, index| {
        if (score(pattern, label)) |value| {
            try matches.append(.{ .index = index, .score = value });
        }
    }

    std.mem.sort(Match, matches.items, {}, lessMatch);
    return matches.toOwnedSlice();
}

fn lessMatch(_: void, a: Match, b: Match) bool {
    if (a.score == b.score) return a.index < b.index;
    return a.score > b.score;
}
```

Implement `score(pattern, candidate) ?i32` using the same bonuses and penalties as `github.com/sahilm/fuzzy` v0.1.1. Use UTF-8 codepoint iteration for index accounting and ASCII-insensitive comparison for the common script/config namespace. Non-ASCII bytes compare equal only when identical, which preserves display while keeping the documented ASCII discovery/filter behavior deterministic.

- [ ] **Step 3: Implement `src/domain/filter.zig`**

Use the active Go behavior:

```zig
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
        var result = try selectRunning(allocator, processes, show_only_running);
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

    var labels = try allocator.alloc([]const u8, processes.len);
    defer allocator.free(labels);
    for (processes, 0..) |view, i| labels[i] = view.label;
    const matches = try fuzzy.find(allocator, trimmed, labels);
    defer allocator.free(matches);

    var result = std.array_list.Managed(process.ProcessView).init(allocator);
    errdefer result.deinit();
    for (matches) |match| {
        const view = processes[match.index];
        if (show_only_running and view.status != .running) continue;
        try result.append(view);
    }
    return result.toOwnedSlice();
}
```

Implement `matchesAllCategories` with comma split, whitespace trim, and the same contains-either-direction category helper used by Go:

```zig
fn fuzzyCategoryMatch(a: []const u8, b: []const u8) bool {
    return indexOfIgnoreCase(a, b) != null or indexOfIgnoreCase(b, a) != null;
}
```

- [ ] **Step 4: Run tests**

```bash
nix develop --command make test-zig
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/domain/root.zig src/domain/fuzzy.zig src/domain/filter.zig
git commit -m "feat: add zig process filtering"
```

---

### Task 8: Makefile Discovery

**Files:**
- Create: `src/discover/root.zig`
- Create: `src/discover/makefile.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Add Makefile discovery tests in `src/discover/root.zig`**

```zig
pub const makefile = @import("makefile.zig");

test {
    _ = makefile;
}

test "makefile discovery matches active Go behavior" {
    var procs = try makefile.discover(std.testing.allocator, "testdata/phase2/discovery");
    defer makefile.deinitProcessMap(std.testing.allocator, &procs);

    const build = procs.get("make:build").?;
    try std.testing.expectEqualStrings("make build", build.shell);
    try std.testing.expectEqualStrings("testdata/phase2/discovery", build.cwd);
    try std.testing.expectEqualStrings("makefile", build.categories.items[0]);

    const test_proc = procs.get("make:test").?;
    try std.testing.expectEqualStrings("make test", test_proc.shell);

    const phony = procs.get("make:.PHONY").?;
    try std.testing.expectEqualStrings("make .PHONY", phony.shell);
}

test "missing Makefile returns source not found" {
    try std.testing.expectError(error.SourceNotFound, makefile.discover(std.testing.allocator, "testdata/phase2/config"));
}
```

- [ ] **Step 2: Export discover from `src/root.zig`**

```zig
pub const discover = @import("discover/root.zig");

test {
    _ = version;
    _ = config;
    _ = domain;
    _ = discover;
}
```

- [ ] **Step 3: Implement `src/discover/makefile.zig`**

Scan lines using the Go target rule `^([A-Za-z0-9_.-]+):`:

```zig
const std = @import("std");
const config = @import("../config/root.zig");

pub const ProcessMap = config.schema.ProcessMap;

pub fn discover(allocator: std.mem.Allocator, cwd: []const u8) !ProcessMap {
    const path = try std.fs.path.join(allocator, &.{ cwd, "Makefile" });
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.SourceNotFound,
        else => return err,
    };
    defer allocator.free(data);

    var procs = ProcessMap.init(allocator);
    errdefer deinitProcessMap(allocator, &procs);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const target = parseTarget(line) orelse continue;
        const name = try std.fmt.allocPrint(allocator, "make:{s}", .{target});
        errdefer allocator.free(name);
        if (procs.contains(name)) {
            allocator.free(name);
            continue;
        }

        var proc = config.schema.ProcessConfig.empty(allocator);
        proc.shell = try std.fmt.allocPrint(allocator, "make {s}", .{target});
        proc.cwd = try allocator.dupe(u8, cwd);
        proc.description = "Auto-discovered Makefile target";
        try config.schema.appendOwned(allocator, &proc.categories, "makefile");
        try procs.put(name, proc);
    }

    return procs;
}

fn parseTarget(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and isTargetChar(line[i])) : (i += 1) {}
    if (i == 0 or i >= line.len or line[i] != ':') return null;
    return line[0..i];
}

fn isTargetChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '_' or c == '.' or c == '-';
}

pub fn deinitProcessMap(allocator: std.mem.Allocator, procs: *ProcessMap) void {
    var it = procs.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    procs.deinit();
}
```

- [ ] **Step 4: Run tests**

```bash
nix develop --command make test-zig
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/root.zig src/discover
git commit -m "feat: add zig makefile discovery"
```

---

### Task 9: package.json Discovery

**Files:**
- Modify: `src/discover/root.zig`
- Create: `src/discover/package_json.zig`

- [ ] **Step 1: Add package.json discovery tests in `src/discover/root.zig`**

```zig
pub const package_json = @import("package_json.zig");

test "package json discovery detects pnpm and skips invalid script names" {
    var procs = try package_json.discover(std.testing.allocator, "testdata/phase2/discovery");
    defer makefile.deinitProcessMap(std.testing.allocator, &procs);

    const dev = procs.get("pnpm:dev").?;
    try std.testing.expectEqualStrings("testdata/phase2/discovery", dev.cwd);
    try std.testing.expectEqualStrings("pnpm", dev.categories.items[0]);
    try std.testing.expectEqualStrings("pnpm", dev.cmd.items[0]);
    try std.testing.expectEqualStrings("run", dev.cmd.items[1]);
    try std.testing.expectEqualStrings("dev", dev.cmd.items[2]);
    try std.testing.expectEqualStrings("Auto-discovered pnpm script: node server.js", dev.description);

    const build = procs.get("pnpm:build").?;
    try std.testing.expectEqualStrings("build", build.cmd.items[2]);

    try std.testing.expect(procs.get("pnpm:bad script") == null);
}

test "manager command construction matches Go" {
    try std.testing.expectEqualStrings("pnpm run dev", try package_json.commandPreview(std.testing.allocator, "pnpm", "dev"));
    try std.testing.expectEqualStrings("yarn dev", try package_json.commandPreview(std.testing.allocator, "yarn", "dev"));
    try std.testing.expectEqualStrings("bun run dev", try package_json.commandPreview(std.testing.allocator, "bun", "dev"));
    try std.testing.expectEqualStrings("deno task dev", try package_json.commandPreview(std.testing.allocator, "deno", "dev"));
    try std.testing.expectEqualStrings("npm run dev", try package_json.commandPreview(std.testing.allocator, "npm", "dev"));
}
```

- [ ] **Step 2: Implement `src/discover/package_json.zig`**

Use `std.json` for parsing and preserve manager priority:

```zig
const std = @import("std");
const config = @import("../config/root.zig");
const makefile = @import("makefile.zig");

const Manager = struct {
    prefix: []const u8,
    category: []const u8,
};

pub fn discover(allocator: std.mem.Allocator, cwd: []const u8) !config.schema.ProcessMap {
    const path = try std.fs.path.join(allocator, &.{ cwd, "package.json" });
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.SourceNotFound,
        else => return err,
    };
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    var procs = config.schema.ProcessMap.init(allocator);
    errdefer makefile.deinitProcessMap(allocator, &procs);

    const scripts = parsed.value.object.get("scripts") orelse return procs;
    if (scripts != .object) return procs;

    const manager = try detectManager(allocator, cwd);
    var it = scripts.object.iterator();
    while (it.next()) |entry| {
        const script = entry.key_ptr.*;
        if (!validScriptName(script)) continue;
        if (entry.value_ptr.* != .string) continue;
        const body = entry.value_ptr.string;

        const proc_name = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ manager.prefix, script });
        errdefer allocator.free(proc_name);
        if (procs.contains(proc_name)) {
            allocator.free(proc_name);
            continue;
        }

        var proc = config.schema.ProcessConfig.empty(allocator);
        try buildCommand(allocator, &proc.cmd, manager.prefix, script);
        proc.cwd = try allocator.dupe(u8, cwd);
        proc.description = try description(allocator, manager.prefix, body);
        try config.schema.appendOwned(allocator, &proc.categories, manager.category);
        try procs.put(proc_name, proc);
    }

    return procs;
}
```

Manager detection order:

```zig
const checks = [_]struct { files: []const []const u8, prefix: []const u8 }{
    .{ .files = &.{ "pnpm-lock.yaml", ".pnpmfile.cjs", "pnpm-workspace.yaml" }, .prefix = "pnpm" },
    .{ .files = &.{ "bun.lockb", "bunfig.toml" }, .prefix = "bun" },
    .{ .files = &.{ "yarn.lock", ".yarnrc", ".yarnrc.yml", ".yarnrc.yaml" }, .prefix = "yarn" },
    .{ .files = &.{ "package-lock.json", "npm-shrinkwrap.json" }, .prefix = "npm" },
    .{ .files = &.{ "deno.json", "deno.jsonc" }, .prefix = "deno" },
};
```

Command construction:

```zig
fn buildCommand(allocator: std.mem.Allocator, out: *config.schema.StringList, prefix: []const u8, script: []const u8) !void {
    if (std.mem.eql(u8, prefix, "yarn")) {
        try config.schema.appendOwned(allocator, out, "yarn");
        try config.schema.appendOwned(allocator, out, script);
        return;
    }
    if (std.mem.eql(u8, prefix, "deno")) {
        try config.schema.appendOwned(allocator, out, "deno");
        try config.schema.appendOwned(allocator, out, "task");
        try config.schema.appendOwned(allocator, out, script);
        return;
    }
    try config.schema.appendOwned(allocator, out, prefix);
    try config.schema.appendOwned(allocator, out, "run");
    try config.schema.appendOwned(allocator, out, script);
}
```

Script names are valid only when every byte is `A-Z`, `a-z`, `0-9`, `:`, `_`, or `-`.

- [ ] **Step 3: Run tests**

```bash
nix develop --command make test-zig
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/discover/root.zig src/discover/package_json.zig
git commit -m "feat: add zig package json discovery"
```

---

### Task 10: Discovery Apply

**Files:**
- Modify: `src/discover/root.zig`
- Create: `src/discover/apply.zig`

- [ ] **Step 1: Add apply tests in `src/discover/root.zig`**

```zig
pub const apply_mod = @import("apply.zig");

test "discovery apply merges enabled sources and preserves manual process" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    cfg.general.procs_from_make_targets = true;
    cfg.general.procs_from_package_json = true;

    var manual = config.schema.ProcessConfig.empty(std.testing.allocator);
    manual.shell = "make build";
    manual.description = "custom";
    try cfg.procs.put(try std.testing.allocator.dupe(u8, "make:build"), manual);

    try apply_mod.apply(std.testing.allocator, &cfg, "testdata/phase2/discovery");

    try std.testing.expectEqualStrings("custom", cfg.procs.get("make:build").?.description);
    try std.testing.expect(cfg.procs.get("make:test") != null);
    try std.testing.expect(cfg.procs.get("pnpm:dev") != null);
    try std.testing.expect(cfg.procs.get("pnpm:build") != null);
}

test "discovery apply respects disabled sources" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();

    try apply_mod.apply(std.testing.allocator, &cfg, "testdata/phase2/discovery");
    try std.testing.expectEqual(@as(usize, 0), cfg.procs.count());
}
```

- [ ] **Step 2: Implement `src/discover/apply.zig`**

Run discoverers in deterministic order and ignore missing sources with no failure:

```zig
const std = @import("std");
const config = @import("../config/root.zig");
const makefile = @import("makefile.zig");
const package_json = @import("package_json.zig");

pub fn apply(allocator: std.mem.Allocator, cfg: *config.schema.Config, cwd: []const u8) !void {
    if (cfg.general.procs_from_make_targets) {
        var discovered = makefile.discover(allocator, cwd) catch |err| switch (err) {
            error.SourceNotFound => null,
            else => return err,
        };
        if (discovered) |*map| {
            defer makefile.deinitProcessMap(allocator, map);
            try merge(allocator, cfg, map);
        }
    }

    if (cfg.general.procs_from_package_json) {
        var discovered = package_json.discover(allocator, cwd) catch |err| switch (err) {
            error.SourceNotFound => null,
            else => return err,
        };
        if (discovered) |*map| {
            defer makefile.deinitProcessMap(allocator, map);
            try merge(allocator, cfg, map);
        }
    }
}

fn merge(allocator: std.mem.Allocator, cfg: *config.schema.Config, discovered: *config.schema.ProcessMap) !void {
    var it = discovered.iterator();
    while (it.next()) |entry| {
        if (cfg.procs.contains(entry.key_ptr.*)) continue;
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        var value = try cloneProcessConfig(allocator, entry.value_ptr.*);
        errdefer value.deinit(allocator);
        try cfg.procs.put(key, value);
    }
}
```

Implement `cloneProcessConfig` by copying every active process field and duplicating all owned strings/lists/maps.

- [ ] **Step 3: Run tests**

```bash
nix develop --command make test-zig
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/discover/root.zig src/discover/apply.zig
git commit -m "feat: apply zig process discovery"
```

---

### Task 11: Go Reference Fixture Parity

**Files:**
- Create: `tools/parity/phase2/config_domain_discovery_test.go`
- Modify: `Makefile`

- [ ] **Step 1: Add Go reference fixture tests**

Create `tools/parity/phase2/config_domain_discovery_test.go`:

```go
package phase2

import (
	"path/filepath"
	"testing"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
	"github.com/nick/proctmux/internal/procdiscover"

	_ "github.com/nick/proctmux/internal/procdiscover/makefile"
	_ "github.com/nick/proctmux/internal/procdiscover/packagejson"
)

func fixturePath(t *testing.T, parts ...string) string {
	t.Helper()
	all := append([]string{"..", "..", "..", "testdata", "phase2"}, parts...)
	path, err := filepath.Abs(filepath.Join(all...))
	if err != nil {
		t.Fatalf("abs fixture path: %v", err)
	}
	return path
}

func TestGoReferenceLoadsActiveFixture(t *testing.T) {
	cfg, err := config.LoadConfig(fixturePath(t, "config", "full-active.yaml"))
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.Layout.ProcessesListWidth != 45 {
		t.Fatalf("expected width 45, got %d", cfg.Layout.ProcessesListWidth)
	}
	if !cfg.Layout.HideProcessListWhenUnfocused {
		t.Fatalf("expected hide_process_list_when_unfocused true")
	}
	if !cfg.General.ProcsFromMakeTargets || !cfg.General.ProcsFromPackageJSON {
		t.Fatalf("expected discovery toggles true")
	}
	if got := cfg.Procs["backend"].Categories[1]; got != "api" {
		t.Fatalf("expected backend api category, got %q", got)
	}
}

func TestGoReferenceDiscoveryFixture(t *testing.T) {
	cfg := &config.ProcTmuxConfig{}
	cfg.General.ProcsFromMakeTargets = true
	cfg.General.ProcsFromPackageJSON = true
	cfg.Procs = map[string]config.ProcessConfig{
		"make:build": {Shell: "make build", Description: "custom"},
	}

	procdiscover.Apply(cfg, fixturePath(t, "discovery"))

	if cfg.Procs["make:build"].Description != "custom" {
		t.Fatalf("manual make:build should win")
	}
	if _, ok := cfg.Procs["make:test"]; !ok {
		t.Fatalf("expected make:test")
	}
	if _, ok := cfg.Procs["pnpm:dev"]; !ok {
		t.Fatalf("expected pnpm:dev")
	}
	if _, ok := cfg.Procs["pnpm:bad script"]; ok {
		t.Fatalf("invalid script name should be skipped")
	}
}

func TestGoReferenceFilterFixture(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		Layout: config.LayoutConfig{
			CategorySearchPrefix:        "cat:",
			SortProcessListAlpha:        true,
			SortProcessListRunningFirst: true,
		},
	}
	views := []domain.ProcessView{
		{ID: 1, Label: "halted-zebra", Status: domain.StatusHalted, Config: &config.ProcessConfig{Categories: []string{"server"}}},
		{ID: 2, Label: "running-mango", Status: domain.StatusRunning, Config: &config.ProcessConfig{Categories: []string{"server", "api"}}},
		{ID: 3, Label: "halted-apple", Status: domain.StatusHalted, Config: &config.ProcessConfig{Categories: []string{"client"}}},
		{ID: 4, Label: "running-banana", Status: domain.StatusRunning, Config: &config.ProcessConfig{Categories: []string{"server"}}},
	}

	filtered := domain.FilterProcesses(cfg, views, "", false)
	want := []string{"running-banana", "running-mango", "halted-apple", "halted-zebra"}
	for i, label := range want {
		if filtered[i].Label != label {
			t.Fatalf("position %d: expected %q, got %q", i, label, filtered[i].Label)
		}
	}

	cat := domain.FilterProcesses(cfg, views, "cat:server,api", false)
	if len(cat) != 1 || cat[0].Label != "running-mango" {
		t.Fatalf("expected running-mango category result, got %#v", cat)
	}
}
```

- [ ] **Step 2: Add `Makefile` target**

Add:

```makefile
.PHONY: test-phase2-parity
test-phase2-parity:
	go test ./tools/parity/phase2 -v
	$(MAKE) test-zig
```

- [ ] **Step 3: Run parity tests**

```bash
nix develop --command make test-phase2-parity
```

Expected: Go parity tests PASS and Zig tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Makefile tools/parity/phase2/config_domain_discovery_test.go
git commit -m "test: add phase 2 go parity fixtures"
```

---

### Task 12: Final Verification

**Files:**
- No new files.

- [ ] **Step 1: Format Zig**

```bash
nix develop --command make fmt-zig
```

Expected: PASS.

- [ ] **Step 2: Run Zig tests**

```bash
nix develop --command make test-zig
```

Expected: PASS.

- [ ] **Step 3: Run Phase 2 parity tests**

```bash
nix develop --command make test-phase2-parity
```

Expected: PASS.

- [ ] **Step 4: Run Go reference test suite**

```bash
nix develop --command make test
```

Expected: PASS.

- [ ] **Step 5: Build Zig binary**

```bash
nix develop --command make build-zig
```

Expected: `bin/proctmux` exists and runs.

- [ ] **Step 6: Smoke the existing scaffold CLI**

```bash
./bin/proctmux
```

Expected output:

```text
proctmux 0.1.0-zig-dev
```

- [ ] **Step 7: Commit verification-only fixes**

If formatting changed files, commit them:

```bash
git add .
git commit -m "chore: format phase 2 zig modules"
```

If formatting made no changes, do not create an empty commit.

---

## Self-Review Checklist

- Spec coverage:
  - Config search/loading/defaults: Tasks 3 and 4.
  - Dead-field warnings: Task 4.
  - Active-config hash: Task 5.
  - Config starter content: Task 5.
  - Process domain state: Task 6.
  - Filtering/sorting/category behavior: Task 7.
  - Makefile discovery: Task 8.
  - package.json discovery: Task 9.
  - Discovery merge/manual precedence: Task 10.
  - Go kept as reference only: Task 11.
- Placeholder scan:
  - No unspecified file paths.
  - No missing command expectations.
  - No undefined public module names in later tasks.
- Type consistency:
  - `config.schema.Config`, `ProcessConfig`, and `ProcessMap` are introduced before domain/discovery use them.
  - `domain.process.ProcessView` is introduced before filter tests use it.
  - `discover.makefile.deinitProcessMap` is introduced before package/apply tests reuse it.

# Configuration Reference

This document is the technical reference for `proctmux.yaml` configuration.
All fields and defaults are derived from the source code in
`internal/config/types.go`, `internal/config/defaults.go`, and
`cmd/proctmux/config_init.go`.

---

## Config File Location

proctmux searches the working directory for the first file matching (in order):

1. `proctmux.yaml`
2. `proctmux.yml`
3. `procmux.yaml`
4. `procmux.yml`

Override with the `-f` flag:

```
proctmux -f path/to/config.yaml
```

Generate a starter config with all options commented out:

```
proctmux config-init
```

The only required top-level key is `procs`.

---

## `general`

Top-level settings that control process discovery and session behavior.

| Field | Type | Default | Description |
|---|---|---|---|
| `procs_from_make_targets` | bool | `false` | Auto-discover Makefile targets and add them as processes. Each target becomes a runnable process entry. |
| `procs_from_package_json` | bool | `false` | Auto-discover `package.json` scripts and add them as processes. The package manager is detected automatically from lock/config files (pnpm, bun, yarn, npm, or deno). |

```yaml
general:
  procs_from_make_targets: false
  procs_from_package_json: false
```

---

## `layout`

Controls the arrangement and behavior of UI elements.

| Field | Type | Default | Description |
|---|---|---|---|
| `category_search_prefix` | string | `"cat:"` | Prefix for category-based filtering. Type this prefix followed by a category name in the filter bar to show only matching processes. |
| `processes_list_width` | int | `30` | Width of the process list pane as a percentage of the terminal width. Clamped to the range 1--99. Values outside this range reset to 30. |
| `sort_process_list_alpha` | bool | `false` | Sort the process list alphabetically by name. |
| `sort_process_list_running_first` | bool | `false` | Sort running processes to the top of the list. Note: the Go zero value applies since no explicit default is set in code; the config-init template suggests `true`. |
| `placeholder_banner` | string | *(built-in ASCII art)* | ASCII art banner displayed in the output pane before any process is selected. Set to a custom string or leave empty. |
| `enable_debug_process_info` | bool | `false` | Show extra debug information (categories, PID, status) next to each process in the list. |

```yaml
layout:
  processes_list_width: 30
  sort_process_list_alpha: false
  sort_process_list_running_first: true
  category_search_prefix: "cat:"
  enable_debug_process_info: false
```

---

## `style`

Controls colors and visual indicators. Color values accept:

- Named colors: `red`, `green`, `blue`, `white`, `black`, `yellow`, `magenta`, `cyan`
- Bright variants: `brightred`, `brightblue`, `brightgreen`, etc.
- ANSI-prefixed names: `ansired`, `ansigreen`, `ansibrightmagenta`, etc.
- Hex values: `#ff00ff`, `#333333`
- The string `"none"` disables the color (uses terminal default)

| Field | Type | Default | Description |
|---|---|---|---|
| `pointer_char` | string | `"▶"` | Character drawn next to the currently selected process. |
| `selected_process_color` | string | `"white"` | Foreground text color of the selected process entry. |
| `selected_process_bg_color` | string | `"magenta"` | Background color of the selected process entry. |
| `unselected_process_color` | string | *(none -- terminal default)* | Foreground text color of unselected process entries. No default is set in code; if empty, the terminal's default foreground is used. |
| `status_running_color` | string | `"green"` | Color of the status indicator for running processes. |
| `status_halting_color` | string | `"yellow"` | Color of the status indicator for processes that are stopping. |
| `status_stopped_color` | string | `"red"` | Color of the status indicator for stopped processes. |
| `placeholder_terminal_bg_color` | string | `"black"` | Background color of the terminal pane when no process output is shown. |
| `color_level` | string | `"256"` | Color support level hint. |

```yaml
style:
  pointer_char: "▶"
  selected_process_color: "white"
  selected_process_bg_color: "magenta"
  status_running_color: "green"
  status_halting_color: "yellow"
  status_stopped_color: "red"
```

---

## `keybinding`

Each value is a list of key strings. When multiple keys are specified, any of
them will trigger the action. Key notation uses lowercase names joined by `+`
for modifiers (e.g. `ctrl+c`, `ctrl+left`).

| Action | YAML key | Default | Description |
|---|---|---|---|
| Quit | `quit` | `["q", "ctrl+c"]` | Exit proctmux. |
| Move up | `up` | `["k", "up"]` | Move selection up in the process list. |
| Move down | `down` | `["j", "down"]` | Move selection down in the process list. |
| Start | `start` | `["s", "enter"]` | Start the selected process. |
| Stop | `stop` | `["x"]` | Stop the selected process. |
| Restart | `restart` | `["r"]` | Restart the selected process. |
| Filter | `filter` | `["/"]` | Activate the filter bar. |
| Submit filter | `submit_filter` | `["enter"]` | Confirm and apply the current filter. |
| Toggle running | `toggle_running` | `["R"]` | Toggle filter to show only running processes. |
| Toggle help | `toggle_help` | `["?"]` | Show or hide the help overlay. |
| Toggle focus | `toggle_focus` | `["ctrl+w"]` | Cycle focus between panes (unified modes). |
| Focus client | `focus_client` | `["ctrl+left"]` | Move focus to the process list pane (unified modes). |
| Focus server | `focus_server` | `["ctrl+right"]` | Move focus to the output pane (unified modes). |
| Docs | `docs` | `["d"]` | Reserved for future use. |

```yaml
keybinding:
  quit: ["q", "ctrl+c"]
  up: ["k", "up"]
  down: ["j", "down"]
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
```

---

## `shell_cmd`

| Field | Type | Default | Description |
|---|---|---|---|
| `shell_cmd` | string list | `["sh", "-c"]` | The shell used to execute process `shell` commands. The process's `shell` string is appended as the final argument. |

```yaml
shell_cmd:
  - "/bin/bash"
  - "-c"
```

---

## `log_file`

| Field | Type | Default | Description |
|---|---|---|---|
| `log_file` | string | `""` (disabled) | Path to write application logs. Leave empty to disable logging. |

```yaml
log_file: "/tmp/proctmux.log"
```

---

## `stdout_debug_log_file`

| Field | Type | Default | Description |
|---|---|---|---|
| `stdout_debug_log_file` | string | `""` (disabled) | Path to write stdout debug logs. Useful for debugging raw process output. |

```yaml
stdout_debug_log_file: "/tmp/proctmux_stdout.log"
```

---

## `procs`

A map of process name to process configuration. The map key is the display name
shown in the process list. At least one process must be defined.

### Process fields

| Field | Type | Default | Description |
|---|---|---|---|
| `shell` | string | -- | Shell command to execute. Passed to the shell defined by `shell_cmd` (default `sh -c`). Use either `shell` or `cmd`, not both. |
| `cmd` | string list | -- | Command and arguments as an explicit list. Executed directly without shell interpolation. Use either `cmd` or `shell`, not both. |
| `cwd` | string | *(proctmux working directory)* | Working directory for the process. Relative paths resolve from the proctmux working directory. |
| `env` | map[string]string | -- | Environment variables injected into the process. Merged with the inherited environment; these values take precedence. |
| `add_path` | string list | -- | Paths appended to the `$PATH` environment variable for this process. |
| `stop` | int | `15` (SIGTERM) | POSIX signal number sent to the process on stop. Common values: `2` (SIGINT), `9` (SIGKILL), `15` (SIGTERM). |
| `stop_timeout_ms` | int | `3000` | Milliseconds to wait after sending the stop signal before escalating to SIGKILL. |
| `on_kill` | string list | -- | Command executed after the user stops the process. Runs with the process's `cwd` and `env`, subject to a 30-second timeout. |
| `autostart` | bool | `false` | Start this process automatically when proctmux launches. |
| `autofocus` | bool | `false` | Focus the output pane on this process after it starts. |
| `description` | string | -- | Short description shown in the UI description panel. |
| `docs` | string | -- | Longer documentation shown in a popup via the `d` keybinding. Supports multi-line YAML strings. |
| `categories` | string list | -- | Tags for category-based filtering. Filter with the category search prefix (default `cat:`) followed by the category name. |
| `meta_tags` | string list | -- | Additional metadata tags. Not currently used by filtering. |
| `terminal_rows` | int | `24` | Row count for the PTY allocated to this process. |
| `terminal_cols` | int | `80` | Column count for the PTY allocated to this process. |

---

## Complete Example

```yaml
# proctmux.yaml

general:
  procs_from_make_targets: false
  procs_from_package_json: true

layout:
  processes_list_width: 35
  sort_process_list_alpha: true
  sort_process_list_running_first: true
  category_search_prefix: "cat:"
  enable_debug_process_info: false

style:
  pointer_char: ">"
  selected_process_color: "white"
  selected_process_bg_color: "#5f00af"
  unselected_process_color: "blue"
  status_running_color: "green"
  status_halting_color: "yellow"
  status_stopped_color: "red"
  color_level: "truecolors"

keybinding:
  quit: ["q", "ctrl+c"]
  up: ["k", "up"]
  down: ["j", "down"]
  start: ["s", "enter"]
  stop: ["x"]
  restart: ["r"]
  filter: ["/"]
  submit_filter: ["enter"]
  toggle_running: ["R"]
  toggle_help: ["?"]
  docs: ["d"]

log_file: "/tmp/proctmux.log"

procs:
  api-server:
    shell: "go run ./cmd/server"
    cwd: "./backend"
    env:
      PORT: "8080"
      LOG_LEVEL: "debug"
    add_path: ["./bin"]
    autostart: true
    autofocus: true
    description: "Backend API server"
    docs: |
      Runs the Go API server on port 8080.
      Requires a running database (see 'postgres' process).
    categories: ["backend", "core"]
    stop: 2
    stop_timeout_ms: 5000

  frontend:
    shell: "npm run dev"
    cwd: "./frontend"
    env:
      VITE_API_URL: "http://localhost:8080"
    autostart: true
    description: "Vite dev server"
    categories: ["frontend", "core"]

  postgres:
    cmd: ["docker", "compose", "up", "postgres"]
    autostart: true
    description: "PostgreSQL via Docker Compose"
    categories: ["infra"]
    on_kill: ["docker", "compose", "stop", "postgres"]

  worker:
    shell: "python worker.py"
    cwd: "./services/worker"
    env:
      QUEUE_URL: "amqp://localhost"
    description: "Background job worker"
    categories: ["backend"]
    terminal_rows: 40
    terminal_cols: 120
```

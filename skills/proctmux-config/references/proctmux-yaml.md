# proctmux.yaml Option Reference

This is a standalone reference for external proctmux users. It should be
enough to create, edit, explain, and troubleshoot `proctmux.yaml` files without
reading proctmux source code.

When advising users, phrase validation in terms of the installed CLI and the
observable behavior of the app, not implementation internals.

## Config File Lookup and CLI Use

When no `-f` path is supplied, proctmux searches the working directory in this
order:

1. `proctmux.yaml`
2. `proctmux.yml`
3. `procmux.yaml`
4. `procmux.yml`

Use `proctmux config-init` to generate a starter config.

Use `proctmux -f path/to/config.yaml` to run with an explicit config path.
Signal commands, such as `proctmux -f path/to/config.yaml signal-list`, must
point at the same config as the running proctmux instance.

## YAML Types

- `string`: YAML scalar string.
- `string list`: YAML sequence of strings, for example `["q", "ctrl+c"]`.
- `string map`: YAML mapping from string keys to string values.
- `bool`: YAML boolean. The loader also accepts scalar `true`/`false`.
- `int`: decimal integer.

Unknown fields are ignored with warnings. Dead legacy fields are also ignored.
For new configs, omit ignored fields rather than relying on them.

## Top-Level Keys

| Path | Type | Default | Meaning |
| --- | --- | --- | --- |
| `general` | map | `{}` | Discovery-related settings. |
| `layout` | map | defaults below | UI layout behavior. |
| `style` | map | defaults below | Accepted visual style settings. |
| `keybinding` | map | defaults below | Key lists for UI actions. |
| `shell_cmd` | string list | effective `["sh", "-c"]` | Command prefix used for process `shell` strings. |
| `log_file` | string | `""` | Application log path. Empty disables file logging. |
| `stdout_debug_log_file` | string | `""` | Raw stdout/debug log path. Empty disables it. |
| `procs` | map | `{}` | Process definitions keyed by display label. |

## `general`

| Path | Type | Default | Meaning |
| --- | --- | --- | --- |
| `general.procs_from_make_targets` | bool | `false` | Discover Makefile targets as processes. |
| `general.procs_from_package_json` | bool | `false` | Discover `package.json` scripts as processes. |

### Discovery Details

`general.procs_from_make_targets: true` scans `Makefile` in the config
directory. Targets matching `^([A-Za-z0-9_.-]+):` become processes:

- Label: `make:<target>`
- `shell`: `make <target>`
- `cwd`: config directory
- `description`: `Auto-discovered Makefile target`
- `categories`: `["makefile"]`

`general.procs_from_package_json: true` scans `package.json` scripts whose names
match `^[A-Za-z0-9:_-]+$`. Package manager detection checks, in order:

1. pnpm: `pnpm-lock.yaml`, `.pnpmfile.cjs`, `pnpm-workspace.yaml`
2. bun: `bun.lockb`, `bunfig.toml`
3. yarn: `yarn.lock`, `.yarnrc`, `.yarnrc.yml`, `.yarnrc.yaml`
4. npm: `package-lock.json`, `npm-shrinkwrap.json`
5. deno: `deno.json`, `deno.jsonc`

If none match, npm is used. Generated labels are `<manager>:<script>`, such as
`pnpm:dev`. Generated `cmd` values are:

- pnpm: `["pnpm", "run", "<script>"]`
- yarn: `["yarn", "<script>"]`
- bun: `["bun", "run", "<script>"]`
- deno: `["deno", "task", "<script>"]`
- npm: `["npm", "run", "<script>"]`

Explicit `procs` entries win on name collision.

## `layout`

| Path | Type | Default | Meaning |
| --- | --- | --- | --- |
| `layout.category_search_prefix` | string | `"cat:"` | Prefix for category filters in the filter bar. |
| `layout.processes_list_width` | int | `30` | Process list width setting. Values `<= 0` or `> 100` reset to `30`. |
| `layout.hide_process_description_panel` | bool | `false` | Hide the selected process description above the process list. |
| `layout.hide_process_list_when_unfocused` | bool | `false` | In unified mode, hide the process list when focus is on the server/output pane. |
| `layout.sort_process_list_alpha` | bool | `false` | Sort process labels alphabetically. |
| `layout.sort_process_list_running_first` | bool | `false` | Sort running processes before stopped/exited processes. |
| `layout.placeholder_banner` | string | built-in ASCII banner | Text shown when no process output is selected. |
| `layout.enable_debug_process_info` | bool | `false` | Show status, PID, and categories next to process labels. |

`layout.hide_process_list_when_unfocused` is used by unified mode with
`keybinding.toggle_focus`, `keybinding.focus_client`, and
`keybinding.focus_server`.

## `style`

| Path | Type | Default | Meaning |
| --- | --- | --- | --- |
| `style.pointer_char` | string | `"▶"` | Marker displayed next to the selected process. |
| `style.selected_process_color` | string | `"white"` | Accepted/stored selected process foreground color. |
| `style.selected_process_bg_color` | string | `"magenta"` | Accepted/stored selected process background color. |
| `style.unselected_process_color` | string | `""` | Accepted/stored unselected process foreground color. |
| `style.status_running_color` | string | `"green"` | Color for running status markers. |
| `style.status_halting_color` | string | `"yellow"` | Color for halting status markers. |
| `style.status_stopped_color` | string | `"red"` | Color for stopped, exited, and unknown status markers. |

The current proctmux process-list UI actively applies `pointer_char` and the
status marker colors. Selected/unselected process color fields are accepted,
but broad row styling may be limited depending on the installed version.

Supported color strings for status markers:

- `none` or empty string for terminal default
- Named colors: `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`,
  `white`
- Bright aliases: `brightblack`, `gray`, `grey`, `brightred`, `lightred`,
  `brightgreen`, `lightgreen`, `brightyellow`, `brightblue`,
  `brightmagenta`, `brightcyan`, `brightwhite`
- ANSI-prefixed equivalents: `ansired`, `ansigreen`, `ansibrightblue`, etc.
- Numeric strings `0` through `15`

Do not assume arbitrary hex colors are rendered by the active TUI.

## `keybinding`

Every keybinding value is a string list. Multiple entries are aliases for the
same action.

| Path | Default | Meaning |
| --- | --- | --- |
| `keybinding.quit` | `["q", "ctrl+c"]` | Quit proctmux. |
| `keybinding.up` | `["k", "up"]` | Move selection up. |
| `keybinding.down` | `["j", "down"]` | Move selection down. |
| `keybinding.start` | `["s", "enter"]` | Start selected process. |
| `keybinding.stop` | `["x"]` | Stop selected process. |
| `keybinding.restart` | `["r"]` | Restart selected process. |
| `keybinding.filter` | `["/"]` | Open the filter bar. |
| `keybinding.submit_filter` | `["enter"]` | Apply the current filter. |
| `keybinding.toggle_running` | `["R"]` | Toggle running-only filter. |
| `keybinding.toggle_help` | `["?"]` | Toggle help panel. |
| `keybinding.toggle_focus` | `["ctrl+w"]` | Toggle client/server focus in unified mode. |
| `keybinding.focus_client` | `["ctrl+left"]` | Focus the client/process-list pane in unified mode. |
| `keybinding.focus_server` | `["ctrl+right"]` | Focus the server/output pane in unified mode. |
| `keybinding.docs` | `["d"]` | Accepted docs keybinding shown in help. |

Use lowercase names for modifiers, such as `ctrl+c`, `ctrl+left`, and
`ctrl+right`.

## `shell_cmd`

`shell_cmd` is a string list used only for process entries that define `shell`.
The process `shell` string is appended as the final argument.

```yaml
shell_cmd: ["/bin/bash", "-lc"]
```

If omitted or empty, the effective command prefix is:

```yaml
shell_cmd: ["sh", "-c"]
```

Process entries using `cmd` do not use `shell_cmd`.

## `procs`

`procs` is a map from process label to process config. Quote labels that contain
spaces or punctuation.

```yaml
procs:
  "web server":
    shell: "npm run dev"
```

### Process Fields

| Path | Type | Default | Meaning |
| --- | --- | --- | --- |
| `procs.<name>.shell` | string | `""` | Shell command. Uses global `shell_cmd`. Good for pipes, redirects, variables, and compound shell syntax. |
| `procs.<name>.cmd` | string list | `[]` | Direct command argv. Good when no shell parsing is needed. |
| `procs.<name>.cwd` | string | `""` | Working directory. Empty means inherit the proctmux working directory. |
| `procs.<name>.env` | string map | `{}` | Environment variables to add or override for the process. |
| `procs.<name>.add_path` | string list | `[]` | Path entries appended to inherited `PATH`. |
| `procs.<name>.stop` | int | effective `15` | POSIX signal number used when stopping. `15` is SIGTERM, `2` is SIGINT, `9` is SIGKILL. |
| `procs.<name>.stop_timeout_ms` | int | effective `3000` | Milliseconds to wait after `stop` before SIGKILL escalation. |
| `procs.<name>.on_kill` | string list | `[]` | Cleanup command argv run after a user-initiated stop/restart. |
| `procs.<name>.autostart` | bool | `false` | Start automatically when proctmux starts. |
| `procs.<name>.autofocus` | bool | `false` | Focus this process after it starts. |
| `procs.<name>.description` | string | `""` | Short text shown in the selected process description panel. |
| `procs.<name>.docs` | string | `""` | Accepted/stored longer docs text. The UI shows the docs keybinding hint; docs-display behavior may vary by installed version. |
| `procs.<name>.meta_tags` | string list | `[]` | Additional metadata tags. Accepted/stored; not used for category filtering. |
| `procs.<name>.categories` | string list | `[]` | Categories used by category filtering. |
| `procs.<name>.terminal_rows` | int | effective `24` | PTY row count for the process. Non-positive values use `24`. |
| `procs.<name>.terminal_cols` | int | effective `80` | PTY column count for the process. Non-positive values use `80`. |

### `shell` vs `cmd`

Use one of these per process:

```yaml
procs:
  shell-example:
    shell: "printf 'ready\n' && npm run dev"

  cmd-example:
    cmd: ["python", "-m", "myapp.worker"]
```

If both are set, proctmux gives `shell` precedence for execution. Avoid setting
both so the config is unambiguous.

### Environment and PATH

`env` is merged into the inherited environment and overrides existing keys.
`add_path` appends entries to inherited `PATH` in order.

```yaml
procs:
  api:
    shell: "npm run dev"
    add_path: ["./node_modules/.bin"]
    env:
      NODE_ENV: "development"
      PORT: "3000"
```

### Stop and `on_kill`

On stop:

1. proctmux sends `stop` to the process group. If `stop <= 0`, SIGTERM (`15`)
   is used.
2. proctmux waits `stop_timeout_ms`. If `stop_timeout_ms <= 0`, `3000` ms is
   used.
3. If the process is still running, proctmux escalates to SIGKILL (`9`).
4. For user-initiated stops/restarts, proctmux runs `on_kill` after the process
   is released.

`on_kill` behavior:

- It is an argv list, not a shell string. Use `["sh", "-c", "..."]` if shell
  features are needed.
- It runs with the process `cwd`, `env`, and `add_path`.
- stdout/stderr/stdin are ignored.
- It has a 30 second timeout.
- A non-zero exit, signal termination, spawn failure, or timeout is treated as
  `OnKillFailed`.
- It does not run for natural process exit or crash cleanup.

## Logs

```yaml
log_file: "/tmp/proctmux.log"
stdout_debug_log_file: "/tmp/proctmux-stdout.log"
```

Leave either value empty to disable that log.

## External Validation Workflow

Use these checks when helping a user validate a config without source access:

1. Confirm the file is named one of the auto-discovered config names, or that
   the user will pass it explicitly with `-f`.
2. Confirm YAML parses with a normal YAML parser if one is available.
3. Run proctmux against the file:

   ```sh
   proctmux -f path/to/proctmux.yaml
   ```

4. If another terminal needs to control the running instance, use the same
   config path:

   ```sh
   proctmux -f path/to/proctmux.yaml signal-list
   proctmux -f path/to/proctmux.yaml signal-start web
   proctmux -f path/to/proctmux.yaml signal-stop web
   ```

5. For lifecycle configs, test start, stop, and restart for the affected process
   and verify any `on_kill` side effect is idempotent.

## Ignored Legacy Fields

The loader recognizes these as dead fields and ignores them with warnings:

Top level:

- `enable_mouse`
- `signal_server`

Under `general`:

- `detached_session_name`
- `kill_existing_session`

Under `style`:

- `style_classes`
- `color_level`
- `placeholder_terminal_bg_color`
- `unified_terminal_fg_color`
- `unified_terminal_bg_color`

Other unknown fields are also ignored with warnings. Do not include ignored
fields in newly generated configs unless the task is explicitly to remove or
explain legacy config.

## Complete Example

```yaml
general:
  procs_from_make_targets: false
  procs_from_package_json: true

layout:
  processes_list_width: 30
  hide_process_description_panel: false
  hide_process_list_when_unfocused: false
  sort_process_list_alpha: true
  sort_process_list_running_first: true
  category_search_prefix: "cat:"
  placeholder_banner: "READY"
  enable_debug_process_info: false

style:
  pointer_char: "▶"
  selected_process_color: "white"
  selected_process_bg_color: "magenta"
  unselected_process_color: "none"
  status_running_color: "green"
  status_halting_color: "yellow"
  status_stopped_color: "red"

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

shell_cmd: ["sh", "-c"]
log_file: ""
stdout_debug_log_file: ""

procs:
  web:
    shell: "npm run dev"
    cwd: "."
    add_path: ["./node_modules/.bin"]
    env:
      NODE_ENV: "development"
      PORT: "3000"
    stop: 15
    stop_timeout_ms: 3000
    autostart: true
    autofocus: true
    description: "Frontend dev server"
    categories: ["frontend", "dev"]
    terminal_rows: 24
    terminal_cols: 100

  worker:
    cmd: ["python", "-m", "myapp.worker"]
    env:
      QUEUE: "default"
    categories: ["worker"]

  stack:
    shell: "docker compose up"
    stop: 2
    stop_timeout_ms: 10000
    on_kill: ["docker", "compose", "down"]
    categories: ["infra"]
```

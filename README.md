# proctmux

A Go TUI for managing long‑running processes and scripts, built on top of tmux. It provides a searchable list of defined processes, starts them in real tmux panes/windows, and exposes an optional HTTP signal server and CLI for remote control.

Inspired by https://github.com/napisani/procmux, but using tmux as the terminal engine so you get native tmux features (split panes, zoom, remain‑on‑exit, etc.).


## Requirements

- tmux >= 3.x installed and available on PATH
- Run proctmux inside an existing tmux session (it needs the “current pane”/“current session”)
- Go 1.22+ to build from source (or use the provided Makefile)


## Installation

```bash
# Build a local binary
make build

# Run
./bin/proctmux
```

Tip: Start tmux first, then run proctmux from a pane:

```bash
tmux new -s work

# inside existing tmux session
proctmux     
```


## Quickstart

Create `proctmux.yaml` in your project directory:

```yaml
general:
  # Detached tmux session name used to host background panes
  detached_session_name: _proctmux
  # If a detached session with the same name exists, kill and recreate it
  kill_existing_session: true

layout:
  # Left list width as a percentage of the screen (1-99)
  processes_list_width: 31
  # Hide the help footer
  hide_help: false
  # Sort options
  sort_process_list_alpha: false
  sort_process_list_running_first: true
  # Optional: change the category filter prefix
  category_search_prefix: "cat:"

style:
  # Character indicating the current selection in the list
  pointer_char: "▶"

keybinding:
  quit: ["q", "ctrl+c"]
  up: ["k", "up"]
  down: ["j", "down"]
  start: ["s", "enter"]
  stop: ["x"]
  filter: ["/"]
  submit_filter: ["enter"]
  switch_focus: ["tab"]
  zoom: ["z"]
  docs: ["?"]

signal_server:
  enable: true
  host: localhost
  port: 9792

procs:
  "tail log":
    shell: "tail -f /tmp/proctmux.log"
    autostart: true
    description: "Tail the app log"
    categories: ["logs"]

  "env demo":
    shell: "echo $SOME_TEST && sleep 1 && echo done"
    env:
      SOME_TEST: "AAA"
    description: "Echo an injected env var"
    categories: ["demo"]

  "echo cmd list":
    cmd: ["/bin/bash", "-c", "echo DONE!"]
    cwd: "/tmp"
    stop: 2         # SIGINT
    description: "Run using cmd array"
    categories: ["demo"]
```

Run proctmux inside tmux and use the keybindings below to start/stop and filter.


## Keybindings (defaults)

- Start: `s` or `enter`
- Stop: `x`
- Up/Down: `k`/`up`, `j`/`down`
- Filter: `/` (type text; `enter` to apply)
- Quit: `q` or `ctrl+c`
- Switch Focus: `tab` (move focus to joined pane)
- Zoom: `z` (toggles tmux zoom of the main pane)
- Docs: `?` (opens a popup with the process docs text)

All bindings are configurable; see the config reference below.


## How It Works (tmux‑first)

- proctmux runs inside your current tmux session and creates a separate detached tmux session (name from `general.detached_session_name`).
- Autostart processes are started in the detached session so they run in the background immediately.
- When you start a process from the UI, its pane is created and can be joined into your main tmux window. Switching selection breaks/join panes to keep the view consistent.
- Panes use tmux’s global `remain-on-exit on` while proctmux runs (restored on exit).


## Configuration Reference

proctmux reads `proctmux.yaml` from the working directory. Only `procs` is required. Defaults are applied where not specified.

### Top‑level

- `general`:
  - `detached_session_name` (string): Name of the detached session used for background panes. Default `_proctmux`.
  - `kill_existing_session` (bool): If the detached session already exists, kill and recreate it. If false and it exists, startup fails.
- `layout`:
  - `processes_list_width` (int): Percent width of the left process list (1-99). The right pane uses the remainder.
  - `hide_help` (bool): Hide the help/footer text in the UI.
  - `hide_process_description_panel` (bool): Placeholder; not currently rendered by the UI.
  - `sort_process_list_alpha` (bool): Sort the list alphabetically.
  - `sort_process_list_running_first` (bool): When sorting, place running processes first.
  - `category_search_prefix` (string): Prefix to activate category filtering. Default `cat:`.
  - `placeholder_banner` (string): Optional ASCII banner for the right pane before any pane joins.
- `style`:
  - `pointer_char` (string): Selection indicator in the list (default `>`). Other style fields exist for future parity but are not yet applied by the current TUI renderer:
    - `selected_process_color`, `selected_process_bg_color`, `unselected_process_color`, `status_running_color`, `status_stopped_color`, `placeholder_terminal_bg_color`, `style_classes`, `color_level`.
- `keybinding` (each value is a list of keys):
  - `quit`, `up`, `down`, `start`, `stop`, `filter`, `submit_filter`, `switch_focus`, `zoom`, `docs`.
  - Keys are strings like `q`, `enter`, `up`, `down`, `ctrl+c`, etc.
- `signal_server`:
  - `enable` (bool): Start the HTTP server alongside the UI.
  - `host` (string): Bind host (e.g. `localhost`). Default `localhost` when enabled.
  - `port` (int): Bind port. Default `9792` when enabled.
- `shell_cmd` (string list): Reserved for parity with procmux; currently unused by proctmux (each process specifies its own command).
- `log_file` (string): Reserved; the current build logs to `/tmp/proctmux.log`.
- `enable_mouse` (bool): Reserved; mouse support is not currently wired.
- `procs` (map[string]Process): Your defined processes (see below).

### Process definition (`procs.<name>`) fields

- `shell` (string): A shell command line executed by tmux for this process. Example: `"tail -f /var/log/syslog"`.
- `cmd` (string list): Alternative to `shell`. proctmux will build a command line by quoting each element. Example: `["/bin/bash", "-c", "echo DONE"]`.
  - Use either `shell` or `cmd`.
- `cwd` (string): Working directory for the process.
- `env` (map[string]string): Extra environment variables for the child process.
- `add_path` (string list): Paths appended to `PATH` for the child process. Merged with any `env.PATH` or the current `PATH`.
- `stop` (int): POSIX signal number to send when stopping (default 15/SIGTERM). Example: `2` for SIGINT.
- `autostart` (bool): Start automatically when proctmux launches (runs in the detached session).
- `autofocus` (bool): After starting via keybinding, focus the process pane.
- `description` (string): Short description shown in the UI footer.
- `docs` (string): Free‑form text displayed in a tmux popup (`less -R`). Plain text and ANSI escapes work; HTML/markup tags are not interpreted.
- `categories` (string list): Tags for category filtering. Filter with `cat:<tag>` (comma‑separate for AND matching, e.g. `cat:build,backend`).
- `meta_tags` (string list): Present for parity; not currently used by filtering logic.


## Filtering

- Plain text filtering does a fuzzy match against process names.
- Category filtering: type `cat:<name>` to restrict to processes with that category. Multiple categories can be comma‑separated and must all match.


## Signal Server

When enabled, a lightweight HTTP server runs alongside the UI to control processes remotely.

- Configure in `proctmux.yaml`:

  ```yaml
  signal_server:
    enable: true
    host: localhost
    port: 9792
  ```

- Endpoints:
  - `GET /` → `{ "process_list": [{"name","running","index","scroll_mode"}] }`
  - `POST /start-by-name/{name}`
  - `POST /stop-by-name/{name}`
  - `POST /restart-by-name/{name}`
  - `POST /restart-running`
  - `POST /stop-running`

Examples:

```bash
curl http://localhost:9792/
curl -X POST http://localhost:9792/start-by-name/"env%20demo"
curl -X POST http://localhost:9792/restart-running
```

Security note: There is no authentication. Bind to `localhost` or restrict access via your firewall/reverse proxy.


## CLI Client (signal commands)

The `proctmux` binary includes client subcommands that talk to the running signal server using the current directory’s `proctmux.yaml` for host/port.

```bash
# Start the UI (and the server, if enabled)
proctmux start     # (default; `proctmux` also works)

# Signal subcommands
proctmux signal-start <process-name>
proctmux signal-stop <process-name>
proctmux signal-restart <process-name>
proctmux signal-restart-running
proctmux signal-stop-running
```

Notes:
- The server must be enabled and proctmux must be running for the client commands to work.
- Client subcommands read `proctmux.yaml` from the working directory to determine `signal_server.host` and `signal_server.port`.


## Tips & Troubleshooting

- Session already exists: if the detached session name is already in use and `kill_existing_session` is false, startup fails. Set it to true to replace the session.
- Run inside tmux: proctmux requires a current tmux pane and session (it calls `tmux display-message -p`).
- Remain‑on‑exit: proctmux enables tmux `remain-on-exit` globally while running; it restores the previous setting on exit.
- Stop behavior: `stop` uses a numeric signal (default SIGTERM=15). Use `2` for Ctrl‑C‑like behavior.
- Styling: only `pointer_char` is currently applied by the UI; other style fields are reserved for future parity.


## Differences vs procmux

- tmux‑native: processes run in real tmux panes/windows (join/break between your current session and a dedicated detached session).
- Config compatibility: overall structure and field names mirror procmux, but some fields are currently placeholders (`style` colors, `meta_tags`, `shell_cmd`, `enable_mouse`).
- Docs rendering: plain text; `less -R` supports ANSI escapes, not HTML‑like tags.


## License

MIT

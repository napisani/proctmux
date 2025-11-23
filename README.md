# proctmux

A terminal-based process manager with an interactive TUI for managing long‑running processes and scripts. While it can integrate with tmux for advanced features (split panes, session management), proctmux works in any modern terminal. It provides a searchable list of defined processes, manages their lifecycle, and exposes an optional HTTP signal server and CLI for remote control.

Inspired by https://github.com/napisani/procmux, with optional tmux integration for users who want native tmux features (split panes, remain‑on‑exit, detached sessions, etc.).


## Requirements

- **Unix-like operating system** (Linux, macOS, BSD) - Windows is not supported
- **Optional**: tmux >= 3.x for tmux integration features
  - If using tmux mode: Run proctmux inside an existing tmux session
- Go 1.22+ to build from source (if not using pre-built binaries)


## Installation

### macOS (Homebrew)

```bash
# Add the proctmux tap
brew tap napisani/proctmux

# Install proctmux
brew install proctmux

# Run (works in any terminal; tmux optional)
proctmux
```

### Linux / Build from Source

```bash
# Build a local binary
make build

# Run (works in any terminal; tmux optional)
./bin/proctmux        # same as: proctmux start
```

### Nix

```bash
# Run directly via nix
nix run github:napisani/proctmux
```


## Quickstart

Create `proctmux.yaml` in your project directory:

```yaml
general:
  detached_session_name: _proctmux   # Detached tmux session hosting background panes
  kill_existing_session: true        # Replace existing detached session if present

layout:
  processes_list_width: 31           # Left list width (percentage 1–99)
  hide_help: false                   # Hide the help footer
  sort_process_list_alpha: false     # Alpha sort
  sort_process_list_running_first: true
  category_search_prefix: "cat:"     # Prefix for category filtering
  enable_debug_process_info: false   # Show extra info (e.g. categories) in the list

style:
  pointer_char: "▶"                   # Selection indicator in the list
  status_running_color: ansigreen    # Colors for list icons (see color notes below)
  status_stopped_color: ansired

keybinding:
  quit: ["q", "ctrl+c"]
  up: ["k", "up"]
  down: ["j", "down"]
  start: ["s", "enter"]            # Enter will start if halted (and also attach)
  stop: ["x"]
  restart: ["r"]
  filter: ["/"]
  submit_filter: ["enter"]
  toggle_running: ["R"]            # Toggle showing only running processes
  toggle_help: ["?"]               # Toggle help/footer visibility
  docs: ["d"]                      # Show process documentation popup

signal_server:
  enable: true
  host: localhost
  port: 9792

# Write logs here. Leave empty to disable logging entirely.
log_file: "/tmp/proctmux.log"

# Optional: write stdout debug logs to a separate file
stdout_debug_log_file: "/tmp/proctmux_stdout.log"

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
- Restart: `r`
- Up/Down: `k`/`up`, `j`/`down`
- Filter: `/` (type text; `enter` to apply)
- Quit: `q` or `ctrl+c`
- Toggle Running: `R` (show only running processes)
- Toggle Help: `?` (show/hide help footer)
- Docs: `d` (opens a popup with the process docs text)
- Enter also attaches focus to the selected process pane after starting (if halted)


## What’s New (since last commit)

- Logging control: `log_file` now controls logging at runtime. If empty, logging is disabled; otherwise logs are written to the given path (e.g. `/tmp/proctmux.log`).
- Colored status indicators: the process list renders a colored icon/pointer using:
  - `style.status_running_color` for running processes (default `ansigreen`)
  - `style.status_stopped_color` for halted processes (default `ansired`)
  - Colors accept names like `red`, `brightblue`, `ansigreen`, or full hex `#rrggbb`.
- Enhanced color parsing: `ansired`/`ansi-red`/`ansi red` and short/long hex forms are recognized.
- Debug info in list: `layout.enable_debug_process_info: true` shows extra details (e.g., categories) in the process list.
- Enter behavior: pressing `enter` both triggers Start (if halted) and attaches focus to the pane.
- New keybinding: `restart` (default `r`) stops then starts the selected process.
- Default stop escalation: when `stop` is omitted, SIGTERM is sent first; if still running after ~3s, proctmux sends SIGKILL.


## How It Works (tmux‑first)

- proctmux runs inside your current tmux session and creates a separate detached tmux session (name from `general.detached_session_name`).
- Autostart processes are started in the detached session so they run in the background immediately.
- When you start a process from the UI, its pane is created and can be joined into your main tmux window. Switching selection breaks/joins panes to keep the view consistent.
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
  - `hide_process_description_panel` (bool): Placeholder in current UI.
  - `sort_process_list_alpha` (bool): Sort the list alphabetically.
  - `sort_process_list_running_first` (bool): When sorting, place running processes first.
  - `category_search_prefix` (string): Prefix to activate category filtering. Default `cat:`.
  - `placeholder_banner` (string): Optional ASCII banner for the right pane before any pane joins.
  - `enable_debug_process_info` (bool): Show extra details (e.g., categories) in the process list.
- `style`:
  - `pointer_char` (string): Selection indicator in the list (default `>`).
  - `status_running_color`, `status_stopped_color` (string): Colors for list icons/pointer. Accepts names like `red`, `brightmagenta`, `ansiblue`, or hex `#ff00ff`.
  - Other fields exist for future parity and may not currently affect the UI: `selected_process_color`, `selected_process_bg_color`, `unselected_process_color`, `placeholder_terminal_bg_color`, `style_classes`, `color_level`.
- `keybinding` (each value is a list of keys):
  - `quit`, `up`, `down`, `start`, `stop`, `restart`, `filter`, `submit_filter`, `toggle_running`, `toggle_help`, `docs`.
- `signal_server`:
  - `enable` (bool): Start the HTTP server alongside the UI.
  - `host` (string): Bind host (e.g. `localhost`). Default `localhost` when enabled.
  - `port` (int): Bind port. Default `9792` when enabled.
- `log_file` (string): Path to write logs. Leave empty to disable logging entirely.
- `stdout_debug_log_file` (string): Optional path to write stdout debug logs. Useful for debugging process output. Leave empty to disable.
- `shell_cmd` (string list): Present for config parity; currently unused by proctmux.
- `enable_mouse` (bool): Present for config parity; not wired in current TUI.
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
- `docs` (string): Free‑form text displayed in a tmux popup (`less -R`). Plain text and ANSI escapes work.
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
- Stop behavior: `stop` uses a numeric signal. If not specified, proctmux sends SIGTERM (15) and, if the process is still running after ~3s, escalates to SIGKILL (9). Set `stop: 2` for Ctrl‑C‑like behavior and no auto-escalation.
- Colors: `status_*_color` accepts common names (`red`, `brightblue`, `ansigreen`) and hex (`#rrggbb`).

## Feature wishlist
- [ ] support for templated processes 
- [ ] tighten up error handling and logging 
- [ ] mouse support 


## Development

### Running Tests

```bash
make test
```

### Setting Up Development Environment

Install git hooks to automate common tasks:

```bash
make install-hooks
```

This installs:
- **pre-commit hook**: Automatically runs `make update-vendor-hash` when you commit changes to `go.mod` or `go.sum`

See [.githooks/README.md](.githooks/README.md) for more details.

### Building from Source

```bash
# Build for current platform
make build

# Build for all supported Unix platforms (Linux amd64/arm64, macOS amd64/arm64)
make build-all

# Binary will be in ./bin/proctmux
```

### Updating Nix Flake Dependencies

If you update Go dependencies (via `go get` or `go mod tidy`), you must update the `vendorHash` in `flake.nix`:

```bash
# After updating go.mod/go.sum
make update-vendor-hash
```

This command:
- Automatically calculates the correct vendorHash for your dependencies
- Updates `flake.nix` with the new hash
- Verifies the Nix build works

**Important**: Run this before creating a release if dependencies have changed, otherwise Nix users will get build errors.

### Creating a Release

Releases are automated via GitHub Actions. When you push a git tag, the workflow will:

1. Run all tests (`make test`)
2. Build binaries for multiple platforms (Linux, macOS, Windows; amd64 and arm64)
3. Create a GitHub Release with all artifacts

To create a new release:

```bash
# 1. Update version in Makefile if needed
vim Makefile  # Update VERSION=x.y.z

# 2. If you've updated dependencies, update the Nix vendorHash
make update-vendor-hash

# 3. Commit any changes
git add .
git commit -m "Prepare release vX.Y.Z"

# 4. Create and push a tag
git tag v1.0.0
git push origin v1.0.0

# 5. Watch GitHub Actions build and publish the release
# Visit: https://github.com/YOUR_USERNAME/proctmux/actions
```

The release will include:
- `proctmux-linux-amd64.tar.gz` - Linux (Intel/AMD 64-bit)
- `proctmux-linux-arm64.tar.gz` - Linux (ARM 64-bit)
- `proctmux-darwin-amd64.tar.gz` - macOS (Intel)
- `proctmux-darwin-arm64.tar.gz` - macOS (Apple Silicon)

**Note:** Windows is not supported as proctmux requires Unix-specific terminal and tmux features.

Tags with hyphens (e.g., `v1.0.0-beta`, `v2.0.0-rc1`) are automatically marked as prereleases.


## License

MIT

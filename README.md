# proctmux

A terminal-based process manager with an interactive TUI for managing long-running processes and scripts. proctmux provides a searchable list of defined processes, manages their lifecycle, and exposes an optional HTTP signal server and CLI for remote control.

**Note**: proctmux is intentionally not a terminal emulator. It relies on your existing terminal emulator (iTerm2, Alacritty, Kitty, GNOME Terminal, etc.) to display process output and provide terminal features.

Inspired by https://github.com/napisani/procmux.

![proctmux demo](demo.gif)


## Requirements

- **Unix-like operating system** (Linux, macOS, BSD) - Windows is not supported
- **Terminal emulator** - Any modern terminal (iTerm2, Alacritty, Kitty, GNOME Terminal, etc.)
- Go 1.24+ to build from source (if not using pre-built binaries)


## Installation

### Homebrew (macOS / Linux)

```bash
# Add the proctmux tap
brew tap napisani/proctmux https://github.com/napisani/proctmux

# Install proctmux
brew install proctmux

# Run in your terminal (inside a tmux session)
proctmux
```

> **Migrating from the old tap?** If you previously installed via `brew tap napisani/proctmux`
> (without the URL), run:
> ```bash
> brew untap napisani/proctmux
> brew tap napisani/proctmux https://github.com/napisani/proctmux
> brew reinstall proctmux
> ```

### Build from Source

```bash
# Build a local binary
make build

# Run in your terminal
./bin/proctmux        # same as: proctmux start
```

### Nix

```bash
# Temporary shell session (recommended for trying it out)
nix shell github:napisani/proctmux --refresh

# After the above command, proctmux is available in your current shell
proctmux

# Run directly without shell session (one-off execution)
nix run github:napisani/proctmux --refresh

# Permanent installation
nix profile install github:napisani/proctmux

# Update installed version
nix profile upgrade '.*proctmux.*'

# Run a specific version
nix shell github:napisani/proctmux/v0.1.0
```


## Getting Started

### 1. Create a Configuration File

Generate a starter configuration with helpful comments:

```bash
proctmux config-init           # writes ./proctmux.yaml
proctmux config-init path/to/proctmux.yaml
```

See the [Configuration Reference](#configuration-reference) below for all available options.

### 2. Start proctmux

proctmux can run in two modes:

**Single Terminal Mode (Simple)**
```bash
# Just run proctmux - it will start with a TUI
proctmux
```

**Split Terminal Mode (Advanced)**

For a split-screen setup with separate client/server:

Terminal 1 (Primary/Server):
```bash
proctmux
```

Terminal 2 (Client - in the same directory):
```bash
proctmux --client
```

Both terminals will show the same TUI and stay synchronized. This is useful for monitoring processes from multiple locations.

**Unified Mode (Embedded server + client)**

Run everything in a single Bubble Tea program with a split view. By default the process list is on the left and the process output is on the right. Use `ctrl+left` / `ctrl+right` to switch focus or tap `ctrl+w` (configurable via `keybinding.toggle_focus`) to toggle between panes.

```bash
proctmux --unified            # same as --unified-left
proctmux --unified-right      # process list on the right
proctmux --unified-top        # process list above the output
proctmux --unified-bottom     # process list below the output
```

Unified mode automatically starts the primary server using the current working directory and configuration. The traditional split-terminal workflow remains available when you need to keep processes separated.

### 3. Use the TUI

Once running, use these keybindings to control your processes:
- **Start**: `s` or `enter`
- **Stop**: `x`
- **Restart**: `r`
- **Filter**: `/` (fuzzy search)
- **Quit**: `q` or `ctrl+c`

See [Keybindings](#keybindings-defaults) for the full list.


## Example Configuration

Full example with all configuration options:

```yaml
general:
  detached_session_name: _proctmux   # Session name for background processes
  kill_existing_session: true        # Replace existing session if present

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
  toggle_focus: ["ctrl+w"]         # Toggle between client/server panes in unified mode
  focus_client: ["ctrl+left"]      # Shortcut for focusing the client pane in unified mode
  focus_server: ["ctrl+right"]     # Shortcut for focusing the embedded server pane in unified mode
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
    stop: 2              # SIGINT on stop
    stop_timeout_ms: 5000 # Escalate to SIGKILL after 5s if still running
    on_kill: ["docker", "kill", "example-stack"]
    description: "Run using cmd array"
    categories: ["demo"]
```


## Keybindings (defaults)

- Start: `s` or `enter`
- Stop: `x`
- Restart: `r`
- Up/Down: `k`/`up`, `j`/`down`
- Filter: `/` (type text; `enter` to apply)
- Quit: `q` or `ctrl+c`
- Toggle Running: `R` (show only running processes)
- Toggle Help: `?` (show/hide help footer)
- Toggle Focus: `ctrl+w` (switch panes in unified mode; configurable via `keybinding.toggle_focus`)
- Focus Client Pane: `ctrl+left` (move keyboard input to the client pane; configurable via `keybinding.focus_client`)
- Focus Server Pane: `ctrl+right` (move keyboard input to the embedded server pane; configurable via `keybinding.focus_server`)
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
- Auto-discovery of processes: set `general.procs_from_make_targets` or `general.procs_from_package_json` to generate `make:<target>` and `<manager>:<script>` processes automatically (package.json scripts detect pnpm, bun, yarn, npm, or deno).


## How It Works

- proctmux manages processes in the background and displays their status in an interactive TUI
- Autostart processes are started immediately when proctmux launches
- Process output is displayed in your terminal emulator's native rendering
- When you start a process from the UI, its output becomes visible in the right pane
- Switching between processes updates the display to show the selected process's output
- proctmux uses your terminal's native features (scrolling, copy/paste, colors, etc.)


## Configuration Reference

proctmux reads `proctmux.yaml` from the working directory. Only `procs` is required. Defaults are applied where not specified.

### Top‑level

- `general`:
  - `detached_session_name` (string): Name for the background process session. Default `_proctmux`.
  - `kill_existing_session` (bool): If a session with this name already exists, kill and recreate it. If false and it exists, startup fails.
  - `procs_from_make_targets` (bool): When true, add a process for each Makefile target (`make:<target>`).
  - `procs_from_package_json` (bool): When true, add a process for each script in `package.json`. The package manager is inferred from lock/config files (pnpm, bun, yarn, npm, or deno) and the generated process names follow `<manager>:<script>`.
- `layout`:
  - `processes_list_width` (int): Percent width of the left process list (1-99). The right pane uses the remainder.
  - `hide_help` (bool): Hide the help/footer text in the UI.
  - `hide_process_description_panel` (bool): Placeholder in current UI.
  - `sort_process_list_alpha` (bool): Sort the list alphabetically.
  - `sort_process_list_running_first` (bool): When sorting, place running processes first.
  - `category_search_prefix` (string): Prefix to activate category filtering. Default `cat:`.
  - `placeholder_banner` (string): Optional ASCII banner for the right pane before selecting a process.
  - `enable_debug_process_info` (bool): Show extra details (e.g., categories) in the process list.
- `style`:
  - `pointer_char` (string): Selection indicator in the list (default `>`).
  - `status_running_color`, `status_stopped_color` (string): Colors for list icons/pointer. Accepts names like `red`, `brightmagenta`, `ansiblue`, or hex `#ff00ff`.
  - Other fields exist for future parity and may not currently affect the UI: `selected_process_color`, `selected_process_bg_color`, `unselected_process_color`, `placeholder_terminal_bg_color`, `style_classes`, `color_level`.
- `keybinding` (each value is a list of keys):
  - `quit`, `up`, `down`, `start`, `stop`, `restart`, `filter`, `submit_filter`, `toggle_running`, `toggle_help`, `toggle_focus`, `focus_client`, `focus_server`, `docs`.
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

- `shell` (string): A shell command line to execute for this process. Example: `"tail -f /var/log/syslog"`.
- `cmd` (string list): Alternative to `shell`. proctmux will build a command line by quoting each element. Example: `["/bin/bash", "-c", "echo DONE"]`.
  - Use either `shell` or `cmd`.
- `cwd` (string): Working directory for the process.
- `env` (map[string]string): Extra environment variables for the child process.
- `add_path` (string list): Paths appended to `PATH` for the child process. Merged with any `env.PATH` or the current `PATH`.
- `stop` (int): POSIX signal number to send when stopping (default 15/SIGTERM). Example: `2` for SIGINT.
- `stop_timeout_ms` (int): How long to wait after sending the stop signal before escalating to SIGKILL (default 3000ms).
- `on_kill` (string list): Command executed once after a user stops the process. Runs with the process's `cwd`/`env`. Example: `["docker", "kill", "web"]`.
- `autostart` (bool): Start automatically when proctmux launches.
- `autofocus` (bool): After starting via keybinding, focus the process output.
- `description` (string): Short description shown in the UI footer.
- `docs` (string): Free-form text displayed in a popup (`less -R`). Plain text and ANSI escapes work.
- `categories` (string list): Tags for category filtering. Filter with `cat:<tag>` (comma-separate for AND matching, e.g. `cat:build,backend`).
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

- **Process output**: Process output is displayed using your terminal emulator's native rendering. Use your terminal's built-in features for scrolling, copy/paste, and searching.
- **Stop behavior**: `stop` uses a numeric signal. If unspecified, proctmux sends SIGTERM (15) and waits `stop_timeout_ms` (default 3000ms) before escalating to SIGKILL (9). Override the signal/timeout per process and optionally run an `on_kill` command for post-stop cleanup.
- **Colors**: `status_*_color` accepts common names (`red`, `brightblue`, `ansigreen`) and hex (`#rrggbb`).
- **Client/Server mode**: Both terminals must be in the same directory with the same `proctmux.yaml` file for synchronized operation.

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

Releases are automated via GitHub Actions. When you push a git tag, the workflow builds
binaries for all platforms and creates a GitHub Release.

```bash
# 1. If you've updated dependencies, update the Nix vendorHash
make update-vendor-hash

# 2. Commit any changes
git add .
git commit -m "Prepare release vX.Y.Z"

# 3. Create the release (runs tests, creates + pushes the tag)
make release-create VERSION=v0.2.0

# 4. Wait for GitHub Actions to finish building
#    Check: https://github.com/napisani/proctmux/actions

# 5. Update the Homebrew formula with new checksums
make release-publish VERSION=v0.2.0

# 6. Push the formula update to main
git push origin main
```

Or use `make release VERSION=v0.2.0` to run steps 3-5 interactively (it pauses
and waits for you to confirm that the GitHub Actions workflow has completed).

The release will include:
- `proctmux-linux-amd64.tar.gz` - Linux (Intel/AMD 64-bit)
- `proctmux-linux-arm64.tar.gz` - Linux (ARM 64-bit)
- `proctmux-darwin-amd64.tar.gz` - macOS (Intel)
- `proctmux-darwin-arm64.tar.gz` - macOS (Apple Silicon)

**Note:** Windows is not supported as proctmux requires Unix-specific terminal and tmux features.

Tags with hyphens (e.g., `v1.0.0-beta`, `v2.0.0-rc1`) are automatically marked as prereleases.


## License

MIT

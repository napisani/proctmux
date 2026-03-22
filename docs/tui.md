# TUI Guide

Technical documentation for the proctmux terminal user interface.

## Overview

The proctmux TUI is built with [Bubble Tea](https://github.com/charmbracelet/bubbletea) (the Elm-architecture framework for Go terminal apps). The main model is `ClientModel` in `internal/tui/client_model.go`.

Key dependencies:

- **Bubble Tea** (`charmbracelet/bubbletea`) -- application framework and event loop
- **Bubbles** (`charmbracelet/bubbles`) -- the process list uses `bubbles/list` with a custom `procDelegate` for rendering; the filter input uses `bubbles/textinput`; help uses `bubbles/help`
- **Lip Gloss** (`charmbracelet/lipgloss`) -- all styling, layout composition, and color handling
- **sahilm/fuzzy** -- fuzzy matching for the filter feature

The TUI runs in alternate screen mode by default. Set `PROCTMUX_NO_ALTSCREEN=1` to disable this (the env var is checked in `cmd/proctmux/program_options.go`). Any truthy value enables the override; `""`, `"0"`, `"false"`, and `"no"` are treated as falsy.

## UI Panels

Panels are rendered top-to-bottom via `lipgloss.JoinVertical` in `ClientModel.View()` (`internal/tui/render.go:365`). Each panel is conditionally included -- if its content is empty, it is omitted entirely.

### 1. Help Panel

Toggled with `?`. When visible, renders the full keybinding help via Bubble Tea's `help.Model` with `ShowAll = true`. Keybindings are grouped into four columns: navigation, process control, filtering, and miscellaneous. A faint mode indicator (`[Client Mode - Connected to Primary]`) appears below the bindings.

### 2. Process Description Panel

Displays the `description` field from the currently selected process's config. Rendered in italic white/light gray text with word wrapping to terminal width. Hidden when `layout.hide_process_description_panel: true` is set, or when the selected process has no description.

### 3. Messages Panel

Shows temporary messages (errors, confirmations) that auto-expire after 5 seconds. Messages are stored as `timedMessage` structs with an `ExpiresAt` timestamp. At most 5 messages are displayed; if more exist, only the most recent 5 are shown. The panel also displays an optional info string (rendered in yellow). A `pruneMessagesMsg` tick fires after each message timeout to clean up expired entries.

### 4. Filter Input

Appears when filter mode is active (triggered by `/`). Uses `bubbles/textinput` with the prompt `"Filter: "`. When the filter is not focused, this panel renders as empty string and takes no vertical space. Note: `headerHeight()` always accounts for the filter line to prevent layout shifting.

### 5. Process List

The main panel. Uses `bubbles/list` with all built-in chrome disabled (no title, no status bar, no built-in help, no built-in filtering). The list height fills all remaining terminal space after the panels above are measured. Height is recalculated on every state update, window resize, and message change via `updateLayout()`.

## Process List Rendering

Each process row is rendered by `procDelegate.Render()` (`internal/tui/render.go:107`):

```
[pointer] [status marker] [label]
```

**Pointer:** Two spaces when unselected; the configured `style.pointer_char` (default `▶`) followed by a space when selected.

**Status marker:** A single character colored by process status:
- Running: `●` (colored with `style.status_running_color`, default green)
- Halting: `◐` (colored with `style.status_halting_color`, default yellow)
- Stopped/Exited/Unknown: `■` (colored with `style.status_stopped_color`, default red)

**Label:** The process name. Selected items use `style.selected_process_color` (default white) foreground and `style.selected_process_bg_color` (default magenta) background. Unselected items use `style.unselected_process_color` (no default -- inherits terminal default).

**Debug mode:** When `layout.enable_debug_process_info: true`, the label is replaced with:
```
<label> [<status>] PID:<pid> [<categories>]
```

## Keybindings

All keybindings are configurable via the `keybinding` section in the YAML config. Defaults are set in `internal/config/defaults.go`.

### Navigation

| Key | Default | Action |
|---|---|---|
| Move up | `k`, `up` | Move selection up (wraps around) |
| Move down | `j`, `down` | Move selection down (wraps around) |

### Process Control

| Key | Default | Action |
|---|---|---|
| Start | `s`, `enter` | Start the selected process |
| Stop | `x` | Stop the selected process |
| Restart | `r` | Restart: stop, wait 500ms, then start |

### Filtering

| Key | Default | Action |
|---|---|---|
| Filter | `/` | Enter filter mode |
| Submit filter | `enter` | Apply filter text and exit filter mode |
| Cancel filter | `esc` | Cancel filter, clear text, exit filter mode |

While in filter mode, pressing `/` again exits filter mode but keeps the current text. Typing any other key is forwarded to the text input and the filter is applied live as you type.

### Toggles

| Key | Default | Action |
|---|---|---|
| Toggle running only | `R` | Show only running processes / show all |
| Toggle help | `?` | Show/hide the help panel |
| Show docs | `d` | Show docs for the selected process |

### Focus (Split Pane Mode)

| Key | Default | Action |
|---|---|---|
| Toggle focus | `ctrl+w` | Toggle focus between client and server panes |
| Focus client | `ctrl+left` | Focus the client (process list) pane |
| Focus server | `ctrl+right` | Focus the server (terminal output) pane |

### Quit

| Key | Default | Action |
|---|---|---|
| Quit | `q`, `ctrl+c` | Send stop-running to primary, exit alt screen, then quit |

## Filtering

Two filter modes are supported, distinguished by prefix.

### Fuzzy Search (default)

Press `/` and type any text. The input is matched against process labels using the `sahilm/fuzzy` library (`internal/domain/filter.go`). Results are ranked by match quality (best match first). When fuzzy search is active, the normal sorting rules (running-first, alphabetical) are bypassed entirely -- fuzzy ranking takes priority.

### Category Search

Type `cat:<categories>` where `cat:` is the default prefix (configurable via `layout.category_search_prefix`). Categories are matched against each process's `categories` list.

- Multiple categories are comma-separated: `cat:build,backend`
- ALL specified categories must match (AND logic)
- Category matching is fuzzy: case-insensitive substring match in both directions (the `fuzzyMatch` helper checks `strings.Contains` both ways)

## Sorting

Sorting applies when no fuzzy filter is active (fuzzy results use match ranking instead).

Two config options control sorting:

- `layout.sort_process_list_running_first` (default: `false`) -- when true, running processes sort above stopped ones
- `layout.sort_process_list_alpha` (default: `false`) -- when true, alphabetical sort within each group

Both can be combined: running-first groups are sorted alphabetically within each group. When neither is enabled, processes appear in config-file order.

## Split Pane Mode

When running in unified split mode, the TUI is wrapped in a `SplitPaneModel` (`internal/tui/split_model.go`) that composes two panes and a status bar.

### Layout

- **Client pane:** The normal `ClientModel` process list TUI
- **Server pane:** A `charmbracelet/x/vt` emulator showing primary server output with full ANSI color/style rendering, polled every 75ms
- **Status bar:** One line at the bottom showing which pane is focused (bold = focused, faint = unfocused) and keybinding hints for switching focus

### Orientation

`SplitPaneModel` supports four orientations: `SplitLeft` (client on left, server on right -- the default), `SplitRight`, `SplitTop`, and `SplitBottom`.

### Sizing

For left/right splits, client pane width is auto-calculated based on the longest process name plus 6 characters of padding. Constraints:

- Minimum client width: 24 characters
- Minimum server (terminal) width: 32 characters
- If the terminal is too narrow to satisfy both minimums, the space is split evenly

For top/bottom splits, the client pane gets approximately 55% of content height, constrained by minimums of 8 (client) and 10 (server) lines.

Resize is handled automatically when `tea.WindowSizeMsg` is received -- both the client model and the emulator are resized accordingly.

### Focus Behavior

When the server pane is focused, all keypresses are converted to ANSI terminal input sequences and written to the emulator. Focus-switching keys (`ctrl+w`, `ctrl+left`, `ctrl+right`) are intercepted before forwarding. When the client pane is focused, keys are handled by the normal `ClientModel` input handler.

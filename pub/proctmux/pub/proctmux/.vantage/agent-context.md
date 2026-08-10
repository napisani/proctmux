# Agent Task Context

## Goal

Replace the narrow ctrl-up/down filter-mode behavior with a generic rule: while entering filter text, Control + a configured process-list keybinding should perform that process-list action without leaving filter mode or changing the filter text. Add e2e coverage proving it works in the real TUI.

## Current Focus

Implementation and focused verification complete.

## Relevant Files

- `src/tui/client_model.zig`
- `src/tui/key_input.zig`
- `src/tui/split_model.zig`
- `src/app/root.zig`
- `tests/e2e/test_filtering.py`
- `docs/tui.md`
- `.vantage/agent-context.md`

## Decisions

- Raw terminal LF (`Ctrl+J`) now maps to `ctrl+j`; raw Enter remains CR (`\r`) and maps to `enter`.
- Control-letter bytes map to `ctrl+<letter>` so configured bindings like `j`, `k`, `s`, and `x` can be control-modified.
- In filter mode, strip the `ctrl+` modifier and match only process-list controls: up/down/start/stop/restart.
- Control-modified actions preserve filter mode and filter text.
- Non-text special up/down keys also navigate while filtering because Nick's tmux/terminal maps Ctrl+J/Ctrl+K to plain arrow sequences (`ESC[B`/`ESC[A`).
- Non-text special keys are no longer appended to the filter prompt when filtering.
- Server-focused panes forward decoded control-letter keys so the broader decoder does not swallow process input.

## Constraints

- Prefix shell commands with `rtk`.
- Keep edits scoped to filtering/navigation/control behavior and regression tests.
- Use Zig best practices; run focused unit/e2e verification.

## Open Questions

- None.

## Recent Progress

- Implemented generic filter-mode control-modified process-list handling in `ClientModel`.
- Added key decoding for control letters, ctrl-up/down variants, and CSI-u/xterm modified-character sequences in `key_input`.
- Reviewed capture results: Ctrl+J produced `ESC[B` and Ctrl+K produced `ESC[A` under tmux/Alacritty, while Ctrl+S/X produced raw control bytes.
- Updated filter-mode handling so special up/down keys navigate while filtering, covering terminals that translate Ctrl+J/K to arrows.
- Added focused unit tests for default/custom configured process-list bindings and special up/down navigation while filtering.
- Added e2e test covering Ctrl+J/Ctrl+K navigation, ArrowDown/ArrowUp navigation, plus Ctrl+S start and Ctrl+X stop while filter text remains active.
- Updated TUI docs for control-modified process-list controls during filtering.
- Added `scripts/capture-key-sequences.py` for future key-sequence diagnostics.
- Removed the generated capture JSON after reviewing it.
- Ran `rtk make fmt`.
- Re-ran `rtk make test NATIVE_TARGET=native` successfully after the arrow-sequence fix.
- Re-ran `rtk make build NATIVE_TARGET=native` successfully.
- Re-ran `rtk env AGENT_TUI=agent-tui PROCTMUX_E2E_BIN=/Users/nick/code/proctmux/zig-out/bin/proctmux pytest -q -s tests/e2e/test_filtering.py` successfully (`4 passed`).
- Refactored `control_key_names` in `src/tui/key_input.zig` to generate `ctrl+a` through `ctrl+z` at comptime from `'a' + index`; `rtk make test NATIVE_TARGET=native` passed afterward.

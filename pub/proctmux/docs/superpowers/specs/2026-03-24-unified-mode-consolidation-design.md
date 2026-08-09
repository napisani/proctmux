# Unified Mode Consolidation Design

Date: 2026-03-24

## Overview

This design removes the `--unified-toggle` runtime mode and consolidates single-terminal unified behavior onto the existing split unified architecture used by `--unified`, `--unified-left`, `--unified-right`, `--unified-top`, and `--unified-bottom`.

Instead of maintaining a separate coordinator-based toggle implementation, unified mode gains an optional configuration that hides the process list when the user toggles away from it. When enabled, toggling off the process list collapses the client pane and allows the output pane to occupy the full unified content region. The existing status bar remains visible. Toggling back restores the process list in the configured unified direction.

## Motivation

The current codebase has two distinct unified implementations:

- Split unified mode in `cmd/proctmux/unified.go` and `internal/tui/split_model.go`
- Toggle unified mode in `cmd/proctmux/unified_toggle.go` with custom stdin routing, PTY management, replay buffering, and viewer coordination

This split adds architectural and testing overhead:

- CLI parsing and routing must preserve a specialty `--unified-toggle` path.
- `PrimaryServer` carries toggle-specific options (`SkipStdinForwarder`, `SkipViewer`) to support one runtime variant.
- E2E coverage is dominated by cross-pane relay behavior that exists only because toggle mode owns stdout and stdin directly.
- Documentation has to explain unified split and unified toggle as separate runtime concepts.

The repository already points toward consolidation:

- `TODOS.md` includes "unified mode with hidden process list".
- `docs/specs/2026-03-19-replace-bubbleterm-with-charm-vt.md` lists unified mode consolidation as future work.

## Goals

- Remove the `--unified-toggle` CLI option and its specialty runtime path.
- Preserve all `--unified-<direction>` options as the single unified entry point.
- Add a configuration option that hides the process list when toggled off.
- Reuse `SplitPaneModel` instead of introducing another wrapper model or coordinator.
- Keep default unified behavior unchanged for existing users unless they opt into the new config.
- Simplify docs, tests, and long-term maintenance by reducing unified-mode variants.

## Non-Goals

- Preserve the current raw-PTY child-client implementation of `--unified-toggle`.
- Merge primary mode and client mode into unified mode.
- Redesign the existing unified focus keybindings.
- Introduce mouse-driven pane resizing or animated transitions.
- Change the current embedded-primary startup model used by split unified mode.

## User-Facing Changes

### CLI

The supported unified CLI surface becomes:

- `--unified` (alias for left layout)
- `--unified-left`
- `--unified-right`
- `--unified-top`
- `--unified-bottom`

`--unified-toggle` is removed as a supported runtime mode and from usage text/documentation.

### Configuration

A new layout option is added:

```yaml
layout:
  hide_process_list_when_unfocused: false
```

Semantics:

- `false` (default): current split unified behavior remains unchanged. `toggle_focus` only changes which pane receives input.
- `true`: when focus moves from the client pane to the server pane via `toggle_focus`, the process list is hidden and the output pane expands to fill the unified content area. When focus returns to the client pane, the process list reappears in the configured direction.

Scope:

- `layout.hide_process_list_when_unfocused` only affects unified split mode.
- Primary mode and client mode ignore this setting.

This name is intentionally tied to focus rather than a removed CLI mode. It describes behavior inside unified split mode instead of introducing a new conceptual mode.

## Behavioral Design

### Unified Model State

`SplitPaneModel` gains an internal visibility concept for the client pane:

- `clientVisible = true`: current split layout behavior
- `clientVisible = false`: server pane occupies the full content region

Visibility is derived from:

- The config flag `layout.hide_process_list_when_unfocused`
- The active focus pane

Required rule:

- If hide-on-unfocus is disabled, `clientVisible` is always true.
- If hide-on-unfocus is enabled, `clientVisible` is true only while the client pane is focused.

Initial startup contract:

- Unified mode always starts with the client pane focused and the process list visible, even when `hide_process_list_when_unfocused` is enabled.
- The list is only hidden after an explicit user action that moves focus to the server pane.

This keeps the mental model simple: focusing the list shows it; focusing output hides it.

### Keybinding Semantics

- `toggle_focus`
  - Existing behavior when hide-on-unfocus is disabled: swap focus between client and server.
  - New behavior when hide-on-unfocus is enabled: toggles both focus and process-list visibility.
- `focus_client`
  - Always sets focus to client.
  - When hide-on-unfocus is enabled, it also restores the process list.
- `focus_server`
  - Always sets focus to server.
  - When hide-on-unfocus is enabled, it also hides the process list.

No new keybinding is required for this first iteration.

### Layout Rules

When the client pane is visible, the existing split sizing logic remains in force:

- Left/right layouts continue using content-aware width selection.
- Top/bottom layouts continue using the existing height ratio and minimums.

When the client pane is hidden:

- The client pane width or height becomes zero.
- The server pane width and height take the entire available content region.
- The child client model remains alive and continues receiving state updates, but it is not rendered.

This avoids reinitializing the client model or re-creating IPC connections on each toggle.

### Status Bar

The status bar should continue to reflect focus and available commands, but its language should no longer imply two simultaneously visible panes when hide-on-unfocus is active.

Required behavior:

- Keep `Client` / `Server` focus labels.
- Continue listing `focus_client`, `focus_server`, and `toggle_focus` hints.
- If hide-on-unfocus is enabled and server is focused, the status bar should explicitly include `process list hidden`.

### Terminal and IPC Behavior

The unified runtime remains the existing split implementation:

- spawn embedded primary child in PTY
- connect via IPC
- render output with the existing vt emulator
- forward terminal input to the focused pane

No coordinator, no replay ring buffer, and no toggle-specific `PROCTMUX_SOCKET` child-client path are needed.

## Architectural Changes

### Required in this change

- `UnifiedSplitToggle` enum value in `cmd/proctmux/cli.go`
- `--unified-toggle` flag parsing and usage text in `cmd/proctmux/cli.go`
- dedicated routing branch to `RunUnifiedToggle()` in `cmd/proctmux/main.go`
- `cmd/proctmux/unified_toggle.go`
- unified-toggle-only E2E helpers and tests based on the specialty coordinator path

### CLI Migration Behavior

To make the breaking change easier to understand, `--unified-toggle` must not degrade into a generic unknown-flag experience.

Required behavior:

- Keep a dedicated parse-time check for `--unified-toggle`.
- If `--unified-toggle` is present, print a targeted migration error to stderr and exit with status code `2`.
- The error message must tell the user to use `--unified` or `--unified-left|right|top|bottom` together with:

```yaml
layout:
  hide_process_list_when_unfocused: true
```

After this targeted check, normal CLI parsing should no longer treat `--unified-toggle` as a supported unified option. This preserves a clear migration path for humans and scripts while still removing the old mode.

### Optional follow-up cleanup

After removal of toggle mode, evaluate whether these toggle-specific hooks can be removed entirely:

- `PrimaryServerOptions.SkipStdinForwarder`
- `PrimaryServerOptions.SkipViewer`
- `PrimaryServer.GetRawProcessController()`
- `PrimaryServer.GetViewer()` if no longer needed elsewhere
- `PROCTMUX_SOCKET` comments/documentation that are only justified by unified-toggle

These cleanups are desirable, but they are not required to ship the user-facing consolidation if they create unnecessary risk or broaden the patch too much.

### Extend

`internal/config/types.go`

- Add `LayoutConfig.HideProcessListWhenUnfocused bool `yaml:"hide_process_list_when_unfocused"``

`internal/config/defaults.go`

- No explicit default assignment is required if `false` is the intended default, but comments/docs/config-init should show the default clearly.

`internal/tui/split_model.go`

- Add a config-driven field for hide-on-unfocus behavior.
- Centralize logic that derives `clientVisible` from focus + config.
- Update resize calculations to support a zero-sized client pane.
- Update `View()` to omit the client pane when hidden and render the server pane full-screen in the current orientation.

`cmd/proctmux/unified.go`

- Pass the new layout config through when constructing `SplitPaneModel`.

## Testing Strategy

### Unit / Model Tests

Add targeted tests around `SplitPaneModel` to verify:

- visibility toggles correctly when hide-on-unfocus is enabled
- `focus_client` restores the client pane
- `focus_server` hides the client pane
- left/right/top/bottom layouts preserve orientation when the client pane is restored
- resize logic produces full-screen server dimensions when the client pane is hidden

### E2E Tests

Replace unified-toggle E2E coverage with unified split E2E coverage for the new behavior:

- unified session starts with process list visible
- with hide-on-unfocus unset or false, unified behavior remains unchanged and the list stays visible while focus moves
- with hide-on-unfocus enabled, `ctrl+w` hides the list and output occupies the screen
- `ctrl+w` again restores the list
- `focus_server` / `focus_client` perform the same hide/show transitions
- process output does not corrupt the restored client pane after toggling back
- `--unified-toggle` exits with the expected targeted migration error

The new E2E tests should target `--unified` rather than a removed toggle-only launcher.

### Documentation Verification

Update and cross-check:

- `README.md`
- `docs/modes.md`
- `docs/architecture.md`
- `docs/configuration.md`
- `docs/troubleshooting.md`
- `docs/ipc.md`
- `cmd/proctmux/config_init.go`

## Migration Notes

This is a breaking CLI change for users invoking `--unified-toggle` directly.

Migration path:

- old: `proctmux --unified-toggle`
- new: `proctmux --unified-left` (or another direction) plus:

```yaml
layout:
  hide_process_list_when_unfocused: true
```

Because this is a behavior replacement rather than a strict compatibility alias, release notes should call out:

- the removed flag
- the new config option
- the fact that output now fills the unified content region while the status bar remains visible
- the fact that output is now rendered through the unified split runtime rather than the former raw-PTY child-client toggle path

## Risks and Trade-Offs

### PTY Fidelity Trade-Off

The removed toggle mode showed the client in a real PTY and routed process output directly via the viewer. The consolidated design uses the unified split runtime everywhere, so the hidden-list experience inherits emulator-based output rendering. This is an intentional simplification trade-off.

### Hidden-But-Alive Client Model

Keeping the client model alive while hidden avoids reconnection churn and state loss, but means hidden-state rendering bugs could persist unnoticed if not tested. Model tests should verify restoration after multiple toggles and resizes.

### Terminology Drift

Docs currently describe four runtime modes. After consolidation, the architecture docs must be updated carefully so the new model is described as one unified mode with configurable list visibility, not as a renamed toggle mode.

## Recommended Implementation Order

1. Add the new config field and config-init/docs plumbing.
2. Update `SplitPaneModel` to support hidden client pane behavior.
3. Remove `--unified-toggle` CLI parsing and main routing.
4. Delete `cmd/proctmux/unified_toggle.go` and associated dead paths.
5. Replace toggle-specific tests with unified split tests for hide/show behavior.
6. Update all architecture and user docs to describe the consolidated design.

## Open Decisions Resolved

The following product decision has been resolved for this design:

- When the process list is toggled off, unified mode should collapse to full-screen output inside the existing split unified app rather than preserving the raw-PTY full-screen toggle implementation.

This keeps the project on a single unified runtime path and maximizes code simplification.

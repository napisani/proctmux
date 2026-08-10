# Unified Mode Consolidation Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove `--unified-toggle`, add config-driven process-list hiding to unified split mode, and update tests/docs to reflect a single unified runtime path.

**Architecture:** Keep all single-terminal unified behavior on the existing `cmd/proctmux/unified.go` + `internal/tui/split_model.go` path. Add `layout.hide_process_list_when_unfocused` to drive whether focus changes merely switch input or also collapse/restore the client pane. Replace the toggle-specific CLI/runtime/tests/docs with targeted migration handling and consolidated unified-mode coverage.

**Tech Stack:** Go, Bubble Tea, Lip Gloss, charmbracelet/x/vt, creack/pty, Go test, integration/e2e harness

---

## File Map

- Modify: `internal/config/types.go` - add the new layout config field.
- Modify: `internal/config/defaults.go` - keep defaults behavior explicit in code comments if needed.
- Modify: `internal/config/config_test.go` - verify the new config field loads and defaults correctly.
- Create: `cmd/proctmux/cli_test.go` - cover targeted `--unified-toggle` migration handling and unified parsing behavior.
- Modify: `cmd/proctmux/cli.go` - remove supported `--unified-toggle` mode, add targeted migration detection, update help text.
- Modify: `cmd/proctmux/main.go` - remove `RunUnifiedToggle` routing.
- Delete: `cmd/proctmux/unified_toggle.go` - remove the specialty runtime implementation.
- Modify: `cmd/proctmux/unified.go` - pass the new hide-on-unfocus config into `SplitPaneModel` and remove stale `--unified-toggle` argument filtering.
- Create: `internal/tui/split_model_test.go` - cover visibility/focus/layout behavior in the unified split model.
- Modify: `internal/tui/split_model.go` - add config-driven client visibility behavior and update status text/layout calculations.
- Modify: `internal/testharness/e2e/start.go` - remove the unified-toggle session launcher if no longer needed.
- Modify: `tests/e2e/e2e_test.go` - replace unified-toggle-only coverage with unified split coverage for hide/show behavior.
- Modify: `README.md` - remove `--unified-toggle` references and document the new config.
- Modify: `docs/modes.md` - collapse runtime mode docs from four modes to unified split behavior with optional hidden list.
- Modify: `docs/architecture.md` - remove unified-toggle architecture and update mode/component descriptions.
- Modify: `docs/configuration.md` - document `layout.hide_process_list_when_unfocused`.
- Modify: `docs/troubleshooting.md` - update unified-mode guidance.
- Modify: `docs/ipc.md` - remove unified-toggle-specific `PROCTMUX_SOCKET` wording if no longer needed.
- Modify: `cmd/proctmux/config_init.go` - add the new commented config field to the starter template.

## Chunk 1: Config Surface and Starter Template

### Task 1: Add config coverage for `hide_process_list_when_unfocused`

**Files:**
- Modify: `internal/config/types.go`
- Modify: `internal/config/config_test.go`
- Modify: `cmd/proctmux/config_init.go`

- [ ] **Step 1: Write the failing config test for explicit true value**

Add a `LoadConfig` test in `internal/config/config_test.go` that writes:

```yaml
layout:
  hide_process_list_when_unfocused: true
procs:
  demo:
    shell: "sleep 1"
```

and asserts `cfg.Layout.HideProcessListWhenUnfocused` is `true`.

- [ ] **Step 2: Write the failing config test for default false value**

Add an assertion to an existing default-loading test (or a new one) that `cfg.Layout.HideProcessListWhenUnfocused` is `false` when omitted.

- [ ] **Step 3: Run the config tests to verify they fail**

Run: `go test ./internal/config -run 'TestLoadConfig_.*|Test.*HideProcessListWhenUnfocused.*' -v`

Expected: FAIL with an unknown field / missing struct member assertion until the field is added.

- [ ] **Step 4: Add the config field**

Update `internal/config/types.go`:

```go
type LayoutConfig struct {
	CategorySearchPrefix         string `yaml:"category_search_prefix"`
	ProcessesListWidth           int    `yaml:"processes_list_width"`
	HideProcessDescriptionPanel  bool   `yaml:"hide_process_description_panel"`
	HideProcessListWhenUnfocused bool   `yaml:"hide_process_list_when_unfocused"`
	SortProcessListAlpha         bool   `yaml:"sort_process_list_alpha"`
	// ...
}
```

Do not force a non-zero default in `internal/config/defaults.go`; the zero value (`false`) is the intended default.

- [ ] **Step 5: Add the starter config comment**

Update `cmd/proctmux/config_init.go` near the other layout settings:

```yaml
#   # Hide the process list when focus moves to the output pane in unified mode (default: false)
#   hide_process_list_when_unfocused: false
```

- [ ] **Step 6: Re-run the config tests**

Run: `go test ./internal/config -run 'TestLoadConfig_.*|Test.*HideProcessListWhenUnfocused.*' -v`

Expected: PASS

- [ ] **Step 7: Commit the config surface change**

```bash
git add internal/config/types.go internal/config/config_test.go cmd/proctmux/config_init.go
git commit -m "feat: add unified hide-list config"
```

## Chunk 2: Unified Split Model Behavior

### Task 2: Add failing model tests for focus and visibility rules

**Files:**
- Create: `internal/tui/split_model_test.go`
- Modify: `internal/tui/split_model.go`
- Modify: `cmd/proctmux/unified.go`

- [ ] **Step 1: Create model test scaffolding with lightweight fakes**

Add test-local fakes for:

- a minimal `terminal.Emulator`
- a minimal `tea.Model` child if needed

Prefer constructing a real `ClientModel` when practical so focus keybindings come from existing code paths.

- [ ] **Step 2: Write a failing startup visibility test**

Cover these required behaviors:

- hide-on-unfocus disabled -> `clientVisible` is effectively always true
- hide-on-unfocus enabled -> startup still shows the client pane and starts focused on client

- [ ] **Step 3: Write failing focus transition tests**

Cover these required behaviors:

- `focus_server` hides the client pane when hide-on-unfocus is enabled
- `focus_client` restores the client pane
- `toggle_focus` switches both focus and visibility when hide-on-unfocus is enabled

- [ ] **Step 4: Run the split model tests to verify they fail**

Run: `go test ./internal/tui -run 'TestSplitPaneModel' -v`

Expected: FAIL until model state logic is implemented.

- [ ] **Step 5: Implement the minimal focus/visibility behavior**

Modify `internal/tui/split_model.go` to:

- accept/store `hideProcessListWhenUnfocused`
- derive client visibility from focus + config
- keep startup focused on the client pane

Add a helper if it keeps logic small and obvious, for example:

```go
func (m SplitPaneModel) clientVisible() bool {
	if !m.hideProcessListWhenUnfocused {
		return true
	}
	return m.focus == paneClient
}
```

- [ ] **Step 6: Update constructor call sites**

Update `cmd/proctmux/unified.go` to pass the new config field into `tui.NewSplitPaneModel(...)`.

If needed, extend the constructor signature to include the bool:

```go
func NewSplitPaneModel(client ClientModel, emu terminal.Emulator, ptmx *os.File, cmd *exec.Cmd, orientation SplitOrientation, hideProcessListWhenUnfocused bool) SplitPaneModel
```

- [ ] **Step 7: Re-run the split model tests**

Run: `go test ./internal/tui -run 'TestSplitPaneModel' -v`

Expected: PASS

- [ ] **Step 8: Commit the focus/visibility change**

```bash
git add internal/tui/split_model.go internal/tui/split_model_test.go cmd/proctmux/unified.go
git commit -m "feat: add unified hide-list focus behavior"
```

### Task 3: Add failing model tests for layout sizing and status text

**Files:**
- Modify: `internal/tui/split_model_test.go`
- Modify: `internal/tui/split_model.go`

- [ ] **Step 1: Write failing layout sizing tests**

Cover these cases:

- left/right orientations: hidden client pane gives full content width to server pane
- top/bottom orientations: hidden client pane gives full content height to server pane
- restoring the client pane preserves the chosen orientation and uses existing sizing rules again

- [ ] **Step 2: Write a failing status bar text test**

Assert that when hide-on-unfocus is enabled and server is focused, `View()` includes `process list hidden`.

- [ ] **Step 3: Run the split model tests to verify they fail**

Run: `go test ./internal/tui -run 'TestSplitPaneModel' -v`

Expected: FAIL until layout/status logic is implemented.

- [ ] **Step 4: Implement the minimal layout and status behavior**

Modify `internal/tui/split_model.go` to:

- zero the client dimensions when hidden
- allow server dimensions to fill the unified content region
- append `process list hidden` to the status bar when required

- [ ] **Step 5: Re-run the split model tests**

Run: `go test ./internal/tui -run 'TestSplitPaneModel' -v`

Expected: PASS

- [ ] **Step 6: Run broader package tests for regressions**

Run: `go test ./internal/tui -v`

Expected: PASS

- [ ] **Step 7: Commit the layout/status change**

```bash
git add internal/tui/split_model.go internal/tui/split_model_test.go
git commit -m "feat: render unified output full-width when list hidden"
```

## Chunk 3: CLI Migration and Runtime Removal

### Task 4: Replace `--unified-toggle` with targeted migration handling

**Files:**
- Create: `cmd/proctmux/cli_test.go`
- Modify: `cmd/proctmux/cli.go`

- [ ] **Step 1: Write a failing parse test for removed flag guidance**

Create `cmd/proctmux/cli_test.go` with a subprocess-style CLI test (or equivalent testable parse helper) that verifies:

- passing `--unified-toggle` exits with status `2`
- stderr mentions `--unified`, `--unified-left|right|top|bottom`, and `hide_process_list_when_unfocused: true`

If direct `os.Exit` makes this hard to test, first extract the migration detection into a small helper that returns an error string / bool and test that helper directly.

- [ ] **Step 2: Write a failing parse test proving normal unified flags still work**

Add a test that `--unified-right` still produces `cfg.Unified == true` and `cfg.UnifiedOrientation == UnifiedSplitRight`.

- [ ] **Step 3: Run the CLI tests to verify they fail**

Run: `go test ./cmd/proctmux -run 'TestParseCLI|TestUnifiedToggleMigration' -v`

Expected: FAIL until parsing behavior is updated.

- [ ] **Step 4: Update CLI parsing and help text**

Modify `cmd/proctmux/cli.go` to:

- remove `UnifiedSplitToggle`
- remove `unifiedToggle` as a supported flag
- add a pre-parse `os.Args` scan for `--unified-toggle` / `-unified-toggle`
- print a targeted migration error and exit `2`
- remove `--unified-toggle` from usage output

Suggested migration message shape:

```text
--unified-toggle has been removed; use --unified or --unified-left/right/top/bottom with:
layout:
  hide_process_list_when_unfocused: true
```

- [ ] **Step 5: Re-run the CLI tests**

Run: `go test ./cmd/proctmux -run 'TestParseCLI|TestUnifiedToggleMigration' -v`

Expected: PASS

- [ ] **Step 6: Commit the CLI migration change**

```bash
git add cmd/proctmux/cli.go cmd/proctmux/cli_test.go
git commit -m "feat: replace unified-toggle with migration guidance"
```

### Task 5: Remove `RunUnifiedToggle` routing and dead launcher code

**Files:**
- Modify: `cmd/proctmux/main.go`
- Modify: `cmd/proctmux/unified.go`
- Delete: `cmd/proctmux/unified_toggle.go`
- Modify: `internal/testharness/e2e/start.go`

- [ ] **Step 1: Treat Task 4 CLI tests as the required regression check**

Do not add a second optional test here. The parse-time guarantee from Task 4 is the required regression coverage for the removed flag.

- [ ] **Step 2: Run the targeted package tests / build before deletion**

Run: `go test ./cmd/proctmux -v`

Expected: PASS before removal, giving a clean baseline.

- [ ] **Step 3: Remove the runtime branch and delete the file**

Update `cmd/proctmux/main.go` to route all unified behavior through `RunUnified(cfg, cliCfg)` only.

Update `cmd/proctmux/unified.go` to remove the stale `--unified-toggle` / `-unified-toggle` filtering branch from `unifiedChildArgs()`.

Delete `cmd/proctmux/unified_toggle.go`.

Update `internal/testharness/e2e/start.go` to remove `StartUnifiedToggleSession` and keep `StartUnifiedSession` as the supported unified launcher.

- [ ] **Step 4: Run a targeted compile to catch stale runtime references**

Run: `go test ./cmd/proctmux ./internal/testharness/e2e -run '^$'`

Expected: PASS compilation once the runtime and harness references are removed.

- [ ] **Step 5: Commit the specialty runtime removal**

```bash
git add cmd/proctmux/main.go internal/testharness/e2e/start.go
git add cmd/proctmux/unified.go
git rm cmd/proctmux/unified_toggle.go
git commit -m "refactor: remove unified-toggle runtime"
```

**Out of scope for this task:** do not remove `PrimaryServerOptions.SkipStdinForwarder`, `PrimaryServerOptions.SkipViewer`, `GetRawProcessController()`, `GetViewer()`, or related internals unless a compile error or stale reference requires a minimal cleanup to keep the required consolidation working.

## Chunk 4: End-to-End Coverage and Docs Cleanup

### Task 6: Replace unified-toggle e2e coverage with unified split coverage

**Files:**
- Modify: `tests/e2e/e2e_test.go`
- Modify: `internal/testharness/e2e/start.go`

- [ ] **Step 1: Write failing e2e tests for default/unset behavior**

Use `StartUnifiedSession` and verify both of these cases:

- when `hide_process_list_when_unfocused` is omitted, focus changes do not hide the process list
- when `hide_process_list_when_unfocused: false` is set explicitly, focus changes do not hide the process list

- [ ] **Step 2: Write a failing e2e test for `ctrl+w` hide/show behavior**

Use per-test config with `layout.hide_process_list_when_unfocused: true` and verify:

- initial process list visible
- `ctrl+w` hides the list and output occupies the unified content region
- `ctrl+w` restores the list

- [ ] **Step 3: Write a failing e2e test for explicit focus keys**

Verify `focus_server` / `focus_client` perform equivalent hide/show behavior when hide-on-unfocus is enabled.

- [ ] **Step 4: Write a failing e2e test for restore/no-corruption behavior**

Preserve the strongest existing unique label/output token assertions so that process output does not corrupt the restored client pane after toggling back.

- [ ] **Step 5: Run the integration tests to verify they fail**

Run: `go test ./tests/e2e -tags=integration -run 'TestUnified' -v`

Expected: FAIL until the tests match the new model behavior.

- [ ] **Step 6: Fix the harness/tests to the new model**

Update any helper assumptions in `internal/testharness/e2e/start.go` and `tests/e2e/e2e_test.go` so unified tests launch with `--unified` and per-test YAML config controls the hide-on-unfocus feature.

- [ ] **Step 7: Re-run the integration tests**

Run: `go test ./tests/e2e -tags=integration -run 'TestUnified' -v`

Expected: PASS

- [ ] **Step 8: Run the full test suite**

Run: `go test ./... -v`

Expected: PASS

- [ ] **Step 9: Commit the e2e migration**

```bash
git add tests/e2e/e2e_test.go internal/testharness/e2e/start.go
git commit -m "test: cover unified hide-list behavior"
```

### Task 7: Update user docs, architecture docs, and starter config references

**Files:**
- Modify: `README.md`
- Modify: `docs/modes.md`
- Modify: `docs/architecture.md`
- Modify: `docs/configuration.md`
- Modify: `docs/troubleshooting.md`
- Modify: `docs/ipc.md`

- [ ] **Step 1: Write the docs checklist before editing**

Use the approved spec at `docs/superpowers/specs/2026-03-24-unified-mode-consolidation-design.md` as the source of truth. Make a quick checklist in your scratchpad covering:

- removed flag references
- new config field docs
- status bar / hidden-list behavior wording
- mode-count changes in architecture docs
- migration guidance for existing users

- [ ] **Step 2: Update the configuration reference**

Document the new field in `docs/configuration.md`, including:

- default `false`
- unified-mode-only scope
- behavior when true

- [ ] **Step 3: Update README usage and examples**

Remove `--unified-toggle` references and add a concise migration/example snippet showing `--unified-left` plus `layout.hide_process_list_when_unfocused: true`.

- [ ] **Step 4: Update runtime and architecture docs**

In `docs/modes.md` and `docs/architecture.md`:

- remove unified-toggle as a separate runtime mode
- describe unified split mode as supporting optional hidden-list behavior
- remove coordinator/ring-buffer/child-client architecture descriptions

- [ ] **Step 5: Update troubleshooting and IPC docs**

Remove unified-toggle references that are no longer true. If `PROCTMUX_SOCKET` remains for other reasons, document its remaining purpose accurately; otherwise remove toggle-specific wording.

- [ ] **Step 6: Run a narrowed stale-reference search**

Run: `rg "unified-toggle|StartUnifiedToggleSession|UnifiedSplitToggle" README.md docs cmd/proctmux internal/testharness tests/e2e`

Expected: no stale shipped-surface references to removed runtime symbols

- [ ] **Step 7: Run focused tests after docs changes**

Run: `go test ./cmd/proctmux ./internal/config -v`

Expected: PASS

- [ ] **Step 8: Commit the docs updates**

```bash
git add README.md docs/modes.md docs/architecture.md docs/configuration.md docs/troubleshooting.md docs/ipc.md
git commit -m "docs: consolidate unified mode guidance"
```

- [ ] **Step 10: Run the full test suite**

Run: `go test ./... -v`

Expected: PASS

- [ ] **Step 11: Commit the CLI migration coverage if it changed after runtime removal**

```bash
git add cmd/proctmux/cli_test.go
git commit -m "test: keep unified-toggle migration coverage"
```

- [ ] **Step 12: Confirm the implementation stays within required scope**

Do not edit optional follow-up cleanup targets from the spec unless a concrete stale reference forces a minimal change.

- [ ] **Step 13: Commit any last e2e/doc touch-ups**

```bash
git add tests/e2e/e2e_test.go internal/testharness/e2e/start.go README.md docs
git commit -m "chore: finalize unified mode consolidation coverage"
```

- [ ] **Step 14: Run a final grep for the new config field where expected**

Run: `rg "hide_process_list_when_unfocused" README.md docs cmd/proctmux internal/config internal/tui tests/e2e`

Expected: references appear in config/docs/tests/model code and nowhere surprising

- [ ] **Step 15: Stop and review the diff before final verification**

Run: `git diff --stat HEAD~5..HEAD`

Expected: touches stay constrained to unified/config/test/doc surfaces described in this plan

- [ ] **Step 16: Proceed to final verification only after the above passes**

This is a checkpoint, not a code change.

## Final Verification

- [ ] **Step 1: Run formatting**

Run: `gofmt -w cmd/proctmux/*.go internal/config/*.go internal/tui/*.go internal/testharness/e2e/*.go tests/e2e/*.go`

Expected: files are formatted with no errors

- [ ] **Step 2: Run the full test suite again**

Run: `go test ./... -v`

Expected: PASS

- [ ] **Step 3: Run a local build**

Run: `make build`

Expected: `bin/proctmux` is produced successfully

- [ ] **Step 4: Sanity-check CLI migration behavior manually**

Run: `./bin/proctmux --unified-toggle`

Expected: exit status `2` and a targeted migration message on stderr

- [ ] **Step 5: Sanity-check the new unified behavior manually**

Use a temporary config with:

```yaml
layout:
  hide_process_list_when_unfocused: true
procs:
  demo:
    shell: "while true; do echo tick; sleep 1; done"
    autostart: true
```

Run: `./bin/proctmux --unified -f /path/to/temp/proctmux.yaml`

Verify manually:

- startup shows the process list
- `ctrl+w` hides the list and leaves the status bar visible
- `ctrl+w` restores the list
- `ctrl+right` hides the list
- `ctrl+left` restores the list

- [ ] **Step 6: Commit any final formatting/fixup changes**

```bash
git add cmd/proctmux internal/config internal/tui internal/testharness/e2e tests/e2e README.md docs
git commit -m "chore: finalize unified mode consolidation"
```

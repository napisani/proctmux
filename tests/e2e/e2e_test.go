//go:build integration

package e2e_test

import (
	"strings"
	"testing"
	"time"

	e2e "github.com/nick/proctmux/internal/testharness/e2e"
)

func TestUnifiedErrorMessageExpires(t *testing.T) {
	t.Skip("unified e2e pending deterministic TUI synchronization")
}

func TestPrimaryClientStartProcess(t *testing.T) {
	t.Skip("primary/client e2e pending tmux stub implementation")
}

func truncateLast(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return "..." + s[len(s)-n:]
}

// ---------------------------------------------------------------------------
// Default / unset hide_process_list_when_unfocused behavior
// ---------------------------------------------------------------------------

// TestUnified_DefaultConfig_ProcessListStaysVisible verifies that when
// hide_process_list_when_unfocused is omitted (default false), toggling focus
// does NOT hide the process list.
func TestUnified_DefaultConfig_ProcessListStaysVisible(t *testing.T) {
	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-default.log
procs:
  echo-default:
    shell: "echo DEFAULT_OUTPUT && sleep 60"
    autostart: true
`)

	sess := e2e.StartUnifiedSession(t, cfgDir, cfgPath)

	// Wait for the process list to appear.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "echo-default")
	}); err != nil {
		t.Fatalf("process list not shown: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Toggle focus to server pane.
	if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
		t.Fatalf("send ctrl+w: %v", err)
	}
	time.Sleep(500 * time.Millisecond)

	// The process label should still be visible because hide-on-unfocus is off.
	snap := sess.Snapshot()
	if !strings.Contains(snap, "echo-default") {
		t.Fatalf("process list disappeared after focus toggle with default config (should remain visible):\n%s", snap)
	}
}

// TestUnified_ExplicitFalse_ProcessListStaysVisible verifies that setting
// hide_process_list_when_unfocused: false explicitly keeps the process list
// visible when focus changes.
func TestUnified_ExplicitFalse_ProcessListStaysVisible(t *testing.T) {
	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-explicit-false.log
layout:
  hide_process_list_when_unfocused: false
procs:
  echo-explicit:
    shell: "echo EXPLICIT_OUTPUT && sleep 60"
    autostart: true
`)

	sess := e2e.StartUnifiedSession(t, cfgDir, cfgPath)

	// Wait for the process list to appear.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "echo-explicit")
	}); err != nil {
		t.Fatalf("process list not shown: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Toggle focus to server pane.
	if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
		t.Fatalf("send ctrl+w: %v", err)
	}
	time.Sleep(500 * time.Millisecond)

	// The process label should still be visible.
	snap := sess.Snapshot()
	if !strings.Contains(snap, "echo-explicit") {
		t.Fatalf("process list disappeared with explicit false config (should remain visible):\n%s", snap)
	}
}

// ---------------------------------------------------------------------------
// ctrl+w hide/show with hide_process_list_when_unfocused: true
// ---------------------------------------------------------------------------

// TestUnified_HideOnUnfocus_CtrlW verifies that when
// hide_process_list_when_unfocused: true, pressing ctrl+w hides the process
// list and pressing ctrl+w again restores it.
func TestUnified_HideOnUnfocus_CtrlW(t *testing.T) {
	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-hide-ctrlw.log
layout:
  hide_process_list_when_unfocused: true
procs:
  hide-test:
    shell: "echo HIDE_CTRLW_OUTPUT && sleep 60"
    autostart: true
`)

	sess := e2e.StartUnifiedSession(t, cfgDir, cfgPath)

	// Step 1: Process list should be visible initially.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "hide-test")
	}); err != nil {
		t.Fatalf("process list not shown initially: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Step 2: Press ctrl+w to hide the process list (focus server).
	if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
		t.Fatalf("send ctrl+w: %v", err)
	}

	// The process label should disappear and "process list hidden" should appear in status.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return !strings.Contains(snap, "hide-test") && strings.Contains(snap, "process list hidden")
	}); err != nil {
		t.Fatalf("process list did not hide after ctrl+w: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Step 3: Press ctrl+w again to restore the process list (focus client).
	if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
		t.Fatalf("send second ctrl+w: %v", err)
	}

	// The process label should reappear.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "hide-test")
	}); err != nil {
		t.Fatalf("process list not restored after second ctrl+w: %v\nSnapshot:\n%s\nCleanOutput (last 2000 bytes):\n%s",
			err, sess.Snapshot(), truncateLast(sess.CleanOutput(), 2000))
	}
}

// ---------------------------------------------------------------------------
// Explicit focus keys (ctrl+right / ctrl+left) hide/show
// ---------------------------------------------------------------------------

// TestUnified_HideOnUnfocus_FocusKeys verifies that focus_server (ctrl+right)
// hides the process list and focus_client (ctrl+left) restores it when
// hide_process_list_when_unfocused is enabled.
func TestUnified_HideOnUnfocus_FocusKeys(t *testing.T) {
	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-hide-focus-keys.log
layout:
  hide_process_list_when_unfocused: true
procs:
  focus-key-test:
    shell: "echo FOCUS_KEY_OUTPUT && sleep 60"
    autostart: true
`)

	sess := e2e.StartUnifiedSession(t, cfgDir, cfgPath)

	// Process list should be visible initially.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "focus-key-test")
	}); err != nil {
		t.Fatalf("process list not shown initially: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Press ctrl+right (focus_server) to hide the process list.
	if err := sess.SendKeys(e2e.KeyCtrlRight); err != nil {
		t.Fatalf("send ctrl+right: %v", err)
	}

	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return !strings.Contains(snap, "focus-key-test") && strings.Contains(snap, "process list hidden")
	}); err != nil {
		t.Fatalf("process list did not hide after ctrl+right: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Press ctrl+left (focus_client) to restore the process list.
	if err := sess.SendKeys(e2e.KeyCtrlLeft); err != nil {
		t.Fatalf("send ctrl+left: %v", err)
	}

	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "focus-key-test")
	}); err != nil {
		t.Fatalf("process list not restored after ctrl+left: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}
}

// ---------------------------------------------------------------------------
// Restore / no-corruption after toggling
// ---------------------------------------------------------------------------

// TestUnified_HideOnUnfocus_RestoreNoCrossPaneLeakage verifies that after
// toggling focus away and back with hide-on-unfocus enabled:
// - the client pane shows the process label
// - the client pane does NOT show process output text
// This catches corruption where process output bytes leak into the client view.
func TestUnified_HideOnUnfocus_RestoreNoCrossPaneLeakage(t *testing.T) {
	const procLabel = "sentinel-proc-UNIQUELABEL"
	const procOutput = "PROCESS_OUTPUT_UNIQUETOKEN"

	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-restore.log
layout:
  hide_process_list_when_unfocused: true
procs:
  `+procLabel+`:
    shell: "echo `+procOutput+` && sleep 60"
    autostart: true
`)

	sess := e2e.StartUnifiedSession(t, cfgDir, cfgPath)

	// Wait for the client pane to settle with the process label visible.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, procLabel)
	}); err != nil {
		t.Fatalf("client pane never showed process label: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Toggle to the server pane (hides process list).
	if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
		t.Fatalf("send ctrl+w: %v", err)
	}

	// Wait for the process list to be hidden.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "process list hidden")
	}); err != nil {
		t.Fatalf("process list did not hide: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Toggle back to the client pane (restores process list).
	if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
		t.Fatalf("send ctrl+w (back): %v", err)
	}

	// Wait for the process label to reappear.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, procLabel)
	}); err != nil {
		t.Fatalf("client pane did not reappear with process label: %v\nSnapshot:\n%s\nCleanOutput (last 2000 bytes):\n%s",
			err, sess.Snapshot(), truncateLast(sess.CleanOutput(), 2000))
	}

	// The process output token must NOT appear on the client pane screen.
	snap := sess.Snapshot()
	if strings.Contains(snap, procOutput) {
		t.Fatalf("process output %q leaked into client pane after restore:\n%s", procOutput, snap)
	}
}

// TestUnified_HideOnUnfocus_RapidToggleNoCrossLeakage stress-tests toggling
// rapidly and verifies that the final state is clean: no cross-pane leakage.
func TestUnified_HideOnUnfocus_RapidToggleNoCrossLeakage(t *testing.T) {
	const procLabel = "sentinel-rapid-UNIQUELABEL"
	const procOutput = "PROCESS_OUTPUT_RAPID_TOKEN"

	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-rapid.log
layout:
  hide_process_list_when_unfocused: true
procs:
  `+procLabel+`:
    shell: "echo `+procOutput+` && sleep 60"
    autostart: true
`)

	sess := e2e.StartUnifiedSession(t, cfgDir, cfgPath)

	// Wait for the client TUI to be ready.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, procLabel)
	}); err != nil {
		t.Fatalf("client pane never ready: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Rapid-fire 10 toggles (5 round-trips). Each pair should end up
	// back on the client pane.
	for i := range 10 {
		if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
			t.Fatalf("toggle %d: send ctrl+w: %v", i, err)
		}
		time.Sleep(50 * time.Millisecond)
	}

	// After an even number of toggles we should be back on the client pane.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, procLabel)
	}); err != nil {
		t.Fatalf("client pane did not settle after rapid toggling: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Process output token must not appear on the client pane screen.
	snap := sess.Snapshot()
	if strings.Contains(snap, procOutput) {
		t.Fatalf("process output %q leaked into client pane after rapid toggle:\n%s", procOutput, snap)
	}
}

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

func TestUnifiedToggle_ProcessListAndScrollback(t *testing.T) {
	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-toggle.log
procs:
  echo-test:
    shell: "echo HELLO_TOGGLE_E2E && sleep 30"
    autostart: true
`)

	sess := e2e.StartUnifiedToggleSession(t, cfgDir, cfgPath)

	// Should start showing the process list with the process name visible
	if err := sess.WaitForSnapshot(5*time.Second, func(snap string) bool {
		return strings.Contains(snap, "echo-test")
	}); err != nil {
		t.Fatalf("process list not shown: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Status bar should show "process list"
	snap := sess.Snapshot()
	if !strings.Contains(snap, "process list") {
		t.Fatalf("expected status bar to contain 'process list', snapshot:\n%s", snap)
	}

	// Press ctrl+w to toggle to scrollback view
	if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
		t.Fatalf("failed to send ctrl+w: %v", err)
	}

	// Should show the process output (HELLO_TOGGLE_E2E from echo)
	if err := sess.WaitForSnapshot(5*time.Second, func(snap string) bool {
		return strings.Contains(snap, "HELLO_TOGGLE_E2E")
	}); err != nil {
		t.Fatalf("scrollback not shown after toggle: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Status bar should now show "scrollback"
	snap = sess.Snapshot()
	if !strings.Contains(snap, "scrollback") {
		t.Fatalf("expected status bar to contain 'scrollback', snapshot:\n%s", snap)
	}

	// Press ctrl+w again to toggle back to process list
	if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
		t.Fatalf("failed to send ctrl+w: %v", err)
	}

	// Should be back to the process list
	if err := sess.WaitForSnapshot(5*time.Second, func(snap string) bool {
		return strings.Contains(snap, "echo-test") && strings.Contains(snap, "process list")
	}); err != nil {
		t.Fatalf("process list not shown after second toggle: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}
}

func TestUnifiedToggle_StartsWithProcessList(t *testing.T) {
	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-toggle-start.log
procs:
  proc-a:
    shell: "sleep 60"
  proc-b:
    shell: "sleep 60"
`)

	sess := e2e.StartUnifiedToggleSession(t, cfgDir, cfgPath)

	// Both processes should be listed
	if err := sess.WaitForSnapshot(5*time.Second, func(snap string) bool {
		return strings.Contains(snap, "proc-a") && strings.Contains(snap, "proc-b")
	}); err != nil {
		t.Fatalf("process list not shown: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}
}

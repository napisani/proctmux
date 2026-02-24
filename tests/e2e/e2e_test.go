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

// TestUnifiedToggle_ProcessListVisible verifies that in unified-toggle mode the
// client TUI starts up and shows the process list (process names are visible).
func TestUnifiedToggle_ProcessListVisible(t *testing.T) {
	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-toggle.log
procs:
  echo-test:
    shell: "echo HELLO_TOGGLE_E2E && sleep 30"
    autostart: true
`)

	sess := e2e.StartUnifiedToggleSession(t, cfgDir, cfgPath)

	// The client TUI should start, showing the process list with the process name.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "echo-test")
	}); err != nil {
		t.Fatalf("process list not shown: %v\nSnapshot:\n%s\nCleanOutput (last 2000 bytes):\n%s",
			err, sess.Snapshot(), truncateLast(sess.CleanOutput(), 2000))
	}
}

func truncateLast(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return "..." + s[len(s)-n:]
}

// TestUnifiedToggle_StartsWithProcessList verifies that all configured processes
// appear in the initial view.
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

	// Both processes should be listed in the client TUI.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "proc-a") && strings.Contains(snap, "proc-b")
	}); err != nil {
		t.Fatalf("process list not shown: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}
}

// TestUnifiedToggle_TogglesViewOnCtrlW verifies that pressing ctrl+w switches
// from the client TUI to the raw process output view, which shows the process
// scrollback (HELLO_TOGGLE_E2E).
func TestUnifiedToggle_TogglesViewOnCtrlW(t *testing.T) {
	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-toggle-ctrlw.log
procs:
  echo-test:
    shell: "echo HELLO_TOGGLE_E2E && sleep 30"
    autostart: true
`)

	sess := e2e.StartUnifiedToggleSession(t, cfgDir, cfgPath)

	// Wait for the client TUI to appear.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "echo-test")
	}); err != nil {
		t.Fatalf("process list not shown: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Press ctrl+w to toggle to the process pane.
	if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
		t.Fatalf("failed to send ctrl+w: %v", err)
	}

	// The raw output of the selected process should now be visible.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "HELLO_TOGGLE_E2E")
	}); err != nil {
		t.Fatalf("process output not shown after toggle: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Press ctrl+w again to toggle back to the client TUI.
	if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
		t.Fatalf("failed to send second ctrl+w: %v", err)
	}

	// The process list should be visible again.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "echo-test")
	}); err != nil {
		t.Fatalf("process list not shown after second toggle: %v\nSnapshot:\n%s\nCleanOutput (last 2000 bytes):\n%s",
			err, sess.Snapshot(), truncateLast(sess.CleanOutput(), 2000))
	}
}

// TestUnifiedToggle_NoLeakClientIntoProcess verifies that after toggling to the
// process pane the current screen contains no client-TUI-specific text. The
// process label is only rendered by the client TUI list; it must not appear in
// the process output pane.
func TestUnifiedToggle_NoLeakClientIntoProcess(t *testing.T) {
	// Use a long unique label so it can only come from the client TUI list,
	// never from the process's own stdout.
	const procLabel = "sentinel-proc-UNIQUELABEL"
	const procOutput = "PROCESS_OUTPUT_UNIQUETOKEN"

	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-noleak-client.log
procs:
  `+procLabel+`:
    shell: "echo `+procOutput+` && sleep 60"
    autostart: true
`)

	sess := e2e.StartUnifiedToggleSession(t, cfgDir, cfgPath)

	// Wait for the client TUI to settle with the process label visible.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, procLabel)
	}); err != nil {
		t.Fatalf("client pane never showed process label: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Toggle to the process pane.
	if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
		t.Fatalf("send ctrl+w: %v", err)
	}

	// Wait for the process output to appear — this is the settled state of the
	// process pane. We wait here rather than sleeping so the assertion below
	// runs on a stable frame.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, procOutput)
	}); err != nil {
		t.Fatalf("process pane never showed process output: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// The process label is a client-TUI-only string. It must not appear on the
	// settled process-pane screen — that would mean client TUI bytes leaked into
	// the process output view.
	snap := sess.Snapshot()
	if strings.Contains(snap, procLabel) {
		t.Fatalf("client TUI label %q leaked into process pane screen:\n%s", procLabel, snap)
	}
}

// TestUnifiedToggle_NoLeakProcessIntoClient verifies that after toggling back to
// the client pane the current screen contains no process-output-specific text.
// Process stdout must not appear in the client TUI pane.
func TestUnifiedToggle_NoLeakProcessIntoClient(t *testing.T) {
	const procLabel = "sentinel-proc2-UNIQUELABEL"
	const procOutput = "PROCESS_OUTPUT_UNIQUETOKEN2"

	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-noleak-process.log
procs:
  `+procLabel+`:
    shell: "echo `+procOutput+` && sleep 60"
    autostart: true
`)

	sess := e2e.StartUnifiedToggleSession(t, cfgDir, cfgPath)

	// Wait for the client TUI to show the process label.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, procLabel)
	}); err != nil {
		t.Fatalf("client pane never showed process label: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Toggle to the process pane and wait for it to settle.
	if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
		t.Fatalf("send ctrl+w: %v", err)
	}
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, procOutput)
	}); err != nil {
		t.Fatalf("process pane never showed process output: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Toggle back to the client pane and wait for the process label to reappear.
	if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
		t.Fatalf("send ctrl+w (back): %v", err)
	}
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, procLabel)
	}); err != nil {
		t.Fatalf("client pane did not reappear: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// The process output token must not appear on the settled client-pane screen.
	// If it does, process output leaked into the client TUI view.
	snap := sess.Snapshot()
	if strings.Contains(snap, procOutput) {
		t.Fatalf("process output %q leaked into client pane screen:\n%s", procOutput, snap)
	}
}

// TestUnifiedToggle_NoLeakOnRapidToggle stress-tests the pane boundary by
// toggling back and forth many times quickly, then verifying that the final
// settled state of each pane is clean. This catches races where in-flight
// goroutine writes land on the wrong pane.
func TestUnifiedToggle_NoLeakOnRapidToggle(t *testing.T) {
	const procLabel = "sentinel-proc3-UNIQUELABEL"
	const procOutput = "PROCESS_OUTPUT_UNIQUETOKEN3"

	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-noleak-rapid.log
procs:
  `+procLabel+`:
    shell: "echo `+procOutput+` && sleep 60"
    autostart: true
`)

	sess := e2e.StartUnifiedToggleSession(t, cfgDir, cfgPath)

	// Wait for the client TUI to be ready.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, procLabel)
	}); err != nil {
		t.Fatalf("client pane never ready: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Rapid-fire 10 toggles (5 round-trips). Each toggle pair should end up
	// back on the client pane.
	for i := range 10 {
		if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
			t.Fatalf("toggle %d: send ctrl+w: %v", i, err)
		}
		// Small pause between keystrokes so the coordinator can process each one.
		time.Sleep(50 * time.Millisecond)
	}

	// After an even number of toggles we should be back on the client pane.
	// Wait for it to settle.
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, procLabel)
	}); err != nil {
		t.Fatalf("client pane did not settle after rapid toggling: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Now verify the process output token is absent from the client pane screen.
	snap := sess.Snapshot()
	if strings.Contains(snap, procOutput) {
		t.Fatalf("process output %q leaked into client pane after rapid toggle:\n%s", procOutput, snap)
	}

	// Toggle once more to land on the process pane and let it settle.
	if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
		t.Fatalf("final toggle: send ctrl+w: %v", err)
	}
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, procOutput)
	}); err != nil {
		t.Fatalf("process pane did not settle after rapid toggling: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// The process label must not appear on the process pane screen.
	snap = sess.Snapshot()
	if strings.Contains(snap, procLabel) {
		t.Fatalf("client TUI label %q leaked into process pane after rapid toggle:\n%s", procLabel, snap)
	}
}

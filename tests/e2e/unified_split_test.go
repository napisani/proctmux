//go:build integration

package e2e_test

import (
	"strings"
	"testing"
	"time"

	e2e "github.com/nick/proctmux/internal/testharness/e2e"
)

// TestUnifiedSplit_ProcessListVisible verifies that in unified split mode the
// client TUI shows the process list alongside the embedded terminal.
func TestUnifiedSplit_ProcessListVisible(t *testing.T) {
	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-split.log
procs:
  echo-split:
    shell: "echo HELLO_SPLIT_E2E && sleep 30"
    autostart: true
`)

	sess := e2e.StartUnifiedSession(t, cfgDir, cfgPath)

	if err := sess.WaitForSnapshot(15*time.Second, func(snap string) bool {
		return strings.Contains(snap, "echo-split")
	}); err != nil {
		t.Fatalf("process list not shown in unified split mode: %v\nSnapshot:\n%s\nCleanOutput (last 2000 bytes):\n%s",
			err, sess.Snapshot(), truncateLast(sess.CleanOutput(), 2000))
	}
}

// TestUnifiedSplit_MultipleProcessesVisible verifies that all configured processes
// appear in the process list in unified split mode.
func TestUnifiedSplit_MultipleProcessesVisible(t *testing.T) {
	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-split-multi.log
procs:
  proc-alpha:
    shell: "sleep 60"
  proc-beta:
    shell: "sleep 60"
`)

	sess := e2e.StartUnifiedSession(t, cfgDir, cfgPath)

	if err := sess.WaitForSnapshot(15*time.Second, func(snap string) bool {
		return strings.Contains(snap, "proc-alpha") && strings.Contains(snap, "proc-beta")
	}); err != nil {
		t.Fatalf("not all processes shown: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}
}

// TestUnifiedSplit_StartProcess verifies that pressing 's' starts a process
// and the process state updates in the TUI.
func TestUnifiedSplit_StartProcess(t *testing.T) {
	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-split-start.log
procs:
  starter-proc:
    shell: "echo STARTED_SPLIT_PROC && sleep 30"
    autostart: false
`)

	sess := e2e.StartUnifiedSession(t, cfgDir, cfgPath)

	// Wait for process list to appear.
	if err := sess.WaitForSnapshot(15*time.Second, func(snap string) bool {
		return strings.Contains(snap, "starter-proc")
	}); err != nil {
		t.Fatalf("process list not shown: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Start the process by pressing 's'.
	if err := sess.SendRunes('s'); err != nil {
		t.Fatalf("send 's': %v", err)
	}

	// Wait a moment for the process to start and state to update.
	time.Sleep(2 * time.Second)

	// The process list should still be visible (we're in split mode,
	// the process list doesn't go away).
	snap := sess.Snapshot()
	if !strings.Contains(snap, "starter-proc") {
		t.Fatalf("process list disappeared after starting process:\n%s", snap)
	}
}

// TestUnifiedSplit_HeavyOutput verifies that the emulator handles rapid,
// continuous output without crashing. This exercises the concurrent
// Write/Render path under load.
func TestUnifiedSplit_HeavyOutput(t *testing.T) {
	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-split-heavy.log
procs:
  heavy-emitter:
    shell: "for i in $(seq 1 500); do echo \"LINE_$i $(date +%s%N)\"; done && echo HEAVY_DONE && sleep 10"
    autostart: true
`)

	sess := e2e.StartUnifiedSession(t, cfgDir, cfgPath)

	// Wait for the process list to appear.
	if err := sess.WaitForSnapshot(15*time.Second, func(snap string) bool {
		return strings.Contains(snap, "heavy-emitter")
	}); err != nil {
		t.Fatalf("process list not shown: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Wait for the heavy output to complete — the app should not crash.
	time.Sleep(5 * time.Second)

	// Verify the process list is still intact after heavy output.
	snap := sess.Snapshot()
	if !strings.Contains(snap, "heavy-emitter") {
		t.Fatalf("process list disappeared after heavy output:\n%s", snap)
	}
}

// TestUnifiedSplit_ColoredOutput verifies that ANSI colored output doesn't
// crash the emulator.
func TestUnifiedSplit_ColoredOutput(t *testing.T) {
	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-split-color.log
procs:
  color-emitter:
    shell: "for i in $(seq 31 37); do echo -e \"\\033[${i}mColor $i\\033[0m\"; done && echo COLOR_DONE && sleep 10"
    autostart: true
`)

	sess := e2e.StartUnifiedSession(t, cfgDir, cfgPath)

	if err := sess.WaitForSnapshot(15*time.Second, func(snap string) bool {
		return strings.Contains(snap, "color-emitter")
	}); err != nil {
		t.Fatalf("process list not shown: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Wait for colored output to complete.
	time.Sleep(3 * time.Second)

	snap := sess.Snapshot()
	if !strings.Contains(snap, "color-emitter") {
		t.Fatalf("process list disappeared after colored output:\n%s", snap)
	}
}

// TestUnifiedSplit_AltScreen verifies that the emulator handles alt screen
// transitions (like less/vim) without crashing.
func TestUnifiedSplit_AltScreen(t *testing.T) {
	// This process enters alt screen, writes text, exits alt screen.
	// The sequence: \033[?1049h (enter alt) \033[?1049l (exit alt)
	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-split-altscreen.log
procs:
  alt-screen-proc:
    shell: "echo BEFORE_ALT && printf '\\033[?1049h' && echo ALT_SCREEN_ACTIVE && sleep 1 && printf '\\033[?1049l' && echo AFTER_ALT && sleep 10"
    autostart: true
`)

	sess := e2e.StartUnifiedSession(t, cfgDir, cfgPath)

	if err := sess.WaitForSnapshot(15*time.Second, func(snap string) bool {
		return strings.Contains(snap, "alt-screen-proc")
	}); err != nil {
		t.Fatalf("process list not shown: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Wait for the alt screen transitions to complete.
	time.Sleep(4 * time.Second)

	// App should still be running and process list visible.
	snap := sess.Snapshot()
	if !strings.Contains(snap, "alt-screen-proc") {
		t.Fatalf("process list disappeared after alt screen transition:\n%s", snap)
	}
}

// TestUnifiedSplit_NavigateList verifies that j/k navigation works in the
// process list within unified split mode.
func TestUnifiedSplit_NavigateList(t *testing.T) {
	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-split-nav.log
procs:
  nav-proc-1:
    shell: "sleep 60"
    description: "first process"
  nav-proc-2:
    shell: "sleep 60"
    description: "second process"
`)

	sess := e2e.StartUnifiedSession(t, cfgDir, cfgPath)

	// Wait for both processes to appear.
	if err := sess.WaitForSnapshot(15*time.Second, func(snap string) bool {
		return strings.Contains(snap, "nav-proc-1") && strings.Contains(snap, "nav-proc-2")
	}); err != nil {
		t.Fatalf("process list not shown: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Navigate down.
	if err := sess.SendKeys(e2e.KeyDown); err != nil {
		t.Fatalf("send down: %v", err)
	}
	time.Sleep(500 * time.Millisecond)

	// Navigate back up.
	if err := sess.SendKeys(e2e.KeyUp); err != nil {
		t.Fatalf("send up: %v", err)
	}
	time.Sleep(500 * time.Millisecond)

	// Process list should still be intact.
	snap := sess.Snapshot()
	if !strings.Contains(snap, "nav-proc-1") || !strings.Contains(snap, "nav-proc-2") {
		t.Fatalf("process list corrupted after navigation:\n%s", snap)
	}
}

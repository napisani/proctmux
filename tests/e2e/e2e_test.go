//go:build integration

package e2e_test

import (
	"bytes"
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
// ---------------------------------------------------------------------------
// Rapid stdout flashing reproduction
// ---------------------------------------------------------------------------

// TestUnified_RapidStdout_NoExcessiveRepaints verifies that when a process
// emits output rapidly, the terminal does not flash by issuing excessive
// full-screen repaints. This reproduces a bug where the unified-left mode
// repaints the entire terminal on every poll tick when process output is
// changing rapidly.
//
// Root cause: lipgloss.JoinHorizontal merges client and server pane content
// into single composite lines. When the server pane updates (every 75ms poll),
// every composite line differs from the previous render, causing Bubble Tea's
// line-level diff to repaint ALL lines — including the unchanged client pane.
// This manifests as visible flashing/flickering of the entire terminal.
func TestUnified_RapidStdout_NoExcessiveRepaints(t *testing.T) {
	// The shell command outputs 500 numbered lines as fast as possible,
	// then sleeps to keep the process alive for the test assertions.
	cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-unified-rapid-stdout.log
procs:
  rapid-output:
    shell: "for i in $(seq 1 500); do echo \"LINE_$i: $(date +%s%N)\"; done; sleep 60"
    autostart: true
`)

	sess := e2e.StartUnifiedSession(t, cfgDir, cfgPath)

	// Wait for the process list to appear (client pane is working).
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "rapid-output")
	}); err != nil {
		t.Fatalf("process list not shown: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Select the process by pressing 'j' (down) to trigger a switch command
	// to the primary server, which causes the viewer to display process output.
	if err := sess.SendRunes('j'); err != nil {
		t.Fatalf("send selection key: %v", err)
	}

	// Wait for some output to appear in the server pane (the rapid output
	// process should be producing lines via the VT emulator).
	if err := sess.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "LINE_")
	}); err != nil {
		t.Fatalf("process output never appeared: %v\nSnapshot:\n%s", err, sess.Snapshot())
	}

	// Now capture a baseline of the raw output size, then wait and measure
	// how many full-screen repaints occur during the period while output is
	// being produced.
	baselineRaw := sess.RawOutput()

	// Wait for the rapid output to complete and several render cycles to pass.
	time.Sleep(3 * time.Second)

	// Count full-screen clear sequences (ESC[2J) in the raw output that
	// occurred AFTER our baseline. Each one represents a full terminal
	// repaint.
	fullRaw := sess.RawOutput()
	newOutput := fullRaw[len(baselineRaw):]

	clearSeq := []byte("\033[2J")
	clearCount := countOccurrences(newOutput, clearSeq)

	// Count "erase line" sequences (ESC[2K) — Bubble Tea emits these when
	// repainting a line. Each one means a line was cleared and rewritten.
	// A high count relative to the number of render cycles means many lines
	// are being repainted per frame.
	eraseLineSeq := []byte("\033[2K")
	eraseLineCount := countOccurrences(newOutput, eraseLineSeq)

	// Count cursor-up sequences (ESC[<n>A or ESC[A) — the renderer moves
	// cursor up before repainting. The total cursor-up distance per frame
	// indicates how many lines are being repainted.
	cursorUpCount := countCursorUpSequences(newOutput)

	t.Logf("Measurement period: 3 seconds")
	t.Logf("New raw output bytes: %d", len(newOutput))
	t.Logf("Full-screen clears (ESC[2J): %d", clearCount)
	t.Logf("Erase-line sequences (ESC[2K): %d", eraseLineCount)
	t.Logf("Total cursor-up lines: %d", cursorUpCount)

	// In 3 seconds at 75ms poll interval, we expect ~40 terminal frames.
	// Bubble Tea renders at 60fps max, so up to ~180 frames.
	//
	// If the renderer is efficiently diffing, only server-pane lines should
	// be repainted. For a 40-row terminal with a ~24-col client pane, only
	// the server portion of each line should change. But because
	// JoinHorizontal creates composite lines, ALL lines change.
	//
	// For a 40-row terminal with ~180 frames, inefficient repainting would
	// produce: ~180 frames × ~39 erase-lines = ~7000 erase-line sequences.
	// Efficient repainting (only server pane lines, or no unnecessary repaints)
	// would produce significantly fewer.
	//
	// We set a threshold that catches the pathological case while allowing
	// some overhead. In an efficient renderer, only the server-pane lines
	// would change between frames. For a 40-row terminal where the server
	// pane occupies ~39 rows (minus status bar), and ~40 frames in 3 seconds
	// (75ms poll), an efficient renderer that only repaints changed server
	// lines would produce ~40 × 39 = ~1560 erase-lines at most.
	//
	// However, if the CLIENT pane lines are also being repainted (because
	// JoinHorizontal merges both panes into each line), the count will be
	// similar but EVERY line in EVERY frame changes needlessly. We can
	// detect this by checking if the erase-line count is proportional to
	// total_rows × frames rather than just server_rows × frames.
	//
	// For now, we log the data for diagnostic purposes. The flashing is
	// confirmed by the high per-frame repaint count relative to terminal
	// rows. A future fix should bring this number down significantly.
	maxAcceptableEraseLines := 2000
	if eraseLineCount > maxAcceptableEraseLines {
		t.Errorf("excessive line repaints detected: %d erase-line sequences in 3s "+
			"(max acceptable: %d)\n"+
			"This indicates the terminal is flashing/flickering during rapid output.\n"+
			"Each render frame is repainting most/all lines instead of only changed ones.\n"+
			"Likely cause: lipgloss.JoinHorizontal creates composite lines where both\n"+
			"client and server content are on the same line, so Bubble Tea's line-level\n"+
			"diff sees every line as changed when only the server pane updates.",
			eraseLineCount, maxAcceptableEraseLines)
	}

	maxAcceptableClears := 5
	if clearCount > maxAcceptableClears {
		t.Errorf("excessive full-screen clears detected: %d (max acceptable: %d)",
			clearCount, maxAcceptableClears)
	}

	// Verify the client pane is still intact (process list visible).
	snap := sess.Snapshot()
	if !strings.Contains(snap, "rapid-output") {
		t.Errorf("client pane lost process label during rapid output:\n%s", snap)
	}
}

// countCursorUpSequences counts the total number of lines moved up by cursor-up
// sequences (ESC[A and ESC[<n>A) in the raw output.
func countCursorUpSequences(data []byte) int {
	total := 0
	for i := 0; i < len(data); i++ {
		if data[i] != 0x1b || i+1 >= len(data) || data[i+1] != '[' {
			continue
		}
		i += 2
		// Parse optional numeric parameter
		n := 0
		hasDigit := false
		for i < len(data) && data[i] >= '0' && data[i] <= '9' {
			n = n*10 + int(data[i]-'0')
			hasDigit = true
			i++
		}
		if i < len(data) && data[i] == 'A' {
			if !hasDigit {
				n = 1
			}
			total += n
		}
	}
	return total
}

// countOccurrences counts non-overlapping occurrences of sep in data.
func countOccurrences(data, sep []byte) int {
	count := 0
	for {
		idx := bytes.Index(data, sep)
		if idx < 0 {
			break
		}
		count++
		data = data[idx+len(sep):]
	}
	return count
}

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

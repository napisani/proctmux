# Replace bubbleterm with charmbracelet/x/vt

**Date:** 2026-03-19
**Status:** Proposed
**Goal:** Replace `taigrr/bubbleterm v0.0.1` with `charmbracelet/x/vt` as the terminal emulator in unified split mode, enabling full color/style rendering in the embedded terminal pane.

---

## Problem

The unified split modes (`--unified-left/right/top/bottom`) embed a terminal emulator to display the primary server's output alongside the client TUI. The current emulator (`taigrr/bubbleterm v0.0.1`) has significant limitations:

1. **No color/style support in rendering** — `GetScreen().Rows` returns plain text strings. ANSI colors, bold, underline, and other SGR attributes from the primary server are stripped or lost.
2. **Polling-based rendering** at 75ms intervals with no damage tracking — burns CPU even when nothing changes.
3. **Incomplete keyboard translation** — `keyMsgToTerminalInput()` in `input.go` manually maps keys and silently drops unknown multi-character sequences. No mouse event forwarding.
4. **Pre-release quality** — v0.0.1 with 19 GitHub stars and 22 commits. Uncertain longevity.
5. **No alt screen, scroll regions, or advanced VT features** — makes interactive programs (vim, htop) unusable in the split pane.

## Research Summary

Three alternative approaches were evaluated:

| Approach | Library | Language | Verdict |
|----------|---------|----------|---------|
| **A (selected)** | `charmbracelet/x/vt` | Pure Go | Best fit — same ecosystem, full color, no CGo |
| B | `libvterm` via CGo | C | Most battle-tested but adds CGo build complexity |
| C | `libghostty-vt` via CGo | Zig | Right layer but alpha API, no Go bindings, Zig toolchain required |

`charmbracelet/x/vt` was selected because:
- Pure Go — no CGo, no external toolchains, no cross-compilation issues
- Same Charmbracelet ecosystem as Bubble Tea and Lip Gloss (already used)
- Full true color, 256-color, indexed color support
- Alt screen buffer, scrollback, damage tracking, grapheme-aware
- `Render()` method returns ANSI-styled text ready for display
- Actively developed — powers Bubble Tea v2

**Risk:** Pre-release (`v0.0.0-...` pseudo-version), API stability not guaranteed. Mitigated by defining an internal interface for future swappability.

## Design

### Current Architecture (to be changed)

```
unified.go:
  emulator.New(80, 24)           -- creates bubbleterm emulator
  emu.StartCommand(cmd)          -- runs child process inside emulator's PTY

split_model.go:
  emu.GetScreen()                -- polls for plain text rows (75ms interval)
  strings.Join(rows, "\n")       -- renders as unstyled text
  emu.Write([]byte(input))       -- forwards keyboard input
  emu.Resize(w, h)               -- resizes on window change
  emu.IsProcessExited()          -- checks child exit
```

### New Architecture

Separation of concerns: PTY management (via `creack/pty`, already a dependency) is separated from terminal emulation (via `charmbracelet/x/vt`).

```
unified.go:
  pty.Start(cmd)                 -- start child in PTY (creack/pty)
  go io.Copy(emulator, ptmx)    -- pipe PTY output to emulator
  
  vt.NewEmulator(w, h)           -- create charmbracelet/x/vt emulator

split_model.go:
  emulator.Render()              -- get ANSI-styled output (replaces GetScreen)
  ptmx.Write([]byte(input))     -- forward keyboard input directly to PTY
  emulator.Resize(w, h)         -- resize virtual terminal
  cmd.ProcessState               -- check child exit via process handle
```

### Interface for Future Swappability

Define an internal interface so the emulator can be swapped to `libghostty-vt` or `libvterm` later without changing the split model:

```go
// internal/terminal/emulator.go

// Emulator abstracts a virtual terminal that processes PTY output and
// produces styled text for display. Implementations can be swapped
// without changing the split pane model.
type Emulator interface {
    // Write feeds raw PTY output into the emulator.
    io.Writer

    // Render returns the current screen content as an ANSI-styled string
    // suitable for display in a terminal or lipgloss pane.
    Render() string

    // Resize changes the virtual terminal dimensions.
    Resize(cols, rows int)

    // Close releases resources held by the emulator.
    Close()
}
```

A `charmvt` implementation wraps `charmbracelet/x/vt`:

```go
// internal/terminal/charmvt/emulator.go

type CharmEmulator struct {
    emu *vt.Emulator
}

func New(cols, rows int) *CharmEmulator { ... }
func (e *CharmEmulator) Write(p []byte) (int, error) { return e.emu.Write(p) }
func (e *CharmEmulator) Render() string { return e.emu.Render() }
func (e *CharmEmulator) Resize(cols, rows int) { e.emu.Resize(cols, rows) }
func (e *CharmEmulator) Close() { /* cleanup */ }
```

### Files Changed

| File | Change |
|------|--------|
| `go.mod` | Remove `taigrr/bubbleterm`, add `charmbracelet/x` |
| `cmd/proctmux/unified.go` | Replace `emulator.New` + `StartCommand` with `pty.Start` + `vt.NewEmulator` + `io.Copy` goroutine |
| `internal/tui/split_model.go` | Replace `*emulator.Emulator` field with `terminal.Emulator` interface. Replace `GetScreen()` with `Render()`. Replace `emu.Write()` with direct PTY write. Replace `IsProcessExited()` with process handle check. |
| `internal/terminal/emulator.go` | **New file.** `Emulator` interface definition. |
| `internal/terminal/charmvt/emulator.go` | **New file.** `charmbracelet/x/vt` wrapper implementing the interface. |

### Implementation Notes

- **`keyMsgToTerminalInput()` is retained.** Bubble Tea delivers key events as `tea.KeyMsg` values, not raw bytes. The function in `input.go` translates these to ANSI escape sequences, which is still needed when writing to the PTY fd directly.
- **`io.Copy` goroutine lifecycle.** The goroutine piping PTY output to the emulator terminates naturally when the PTY master fd returns `io.EOF` on child exit. On early user quit, the PTY fd must be closed (which triggers EOF), ensuring no goroutine leak. Use a deferred `ptmx.Close()` in the parent scope.
- **Constructor error handling.** Check whether `vt.NewEmulator` returns an error. If so, propagate it from `unified.go` startup. The `CharmEmulator.New()` wrapper should return `(*CharmEmulator, error)`.

### What This Does NOT Include

- Does NOT consolidate unified-split and unified-toggle into one mode (separate effort)
- Does NOT add mouse event forwarding (future work, depends on `charmbracelet/x/vt` capabilities)
- Does NOT change the polling interval (75ms, can optimize to damage-tracking later)
- Does NOT change the unified-toggle mode (it doesn't use an emulator)

### Testing

- Verify colored process output renders correctly in all 4 split orientations
- Verify keyboard input forwarding works (basic keys, arrow keys, ctrl sequences)
- Verify resize propagates to the emulator and re-renders correctly
- Verify child process exit is detected
- Manual test with interactive programs (vim, htop) to assess rendering quality
- Run existing test suite to ensure no regressions

### Future Work

- **libghostty-vt adapter:** When the C API stabilizes (~2026), implement `terminal.Emulator` using `libghostty-vt` via CGo. The interface makes this a drop-in swap.
- **Mode consolidation:** Merge unified-split and unified-toggle into a single `--unified` mode with a toggle keybinding between split and full-screen.
- **Push-based rendering:** Replace 75ms polling with damage-tracking from `charmbracelet/x/vt` (it supports touched-line tracking).
- **Mouse forwarding:** Pass mouse events from the Bubble Tea framework through to the PTY.

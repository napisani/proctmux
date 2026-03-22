// Package charmvt implements the terminal.Emulator interface using
// charmbracelet/x/vt. It provides a virtual terminal with full ANSI
// color/style support, alt screen buffer, scroll regions, and
// grapheme-aware rendering.
package charmvt

import (
	"github.com/charmbracelet/x/vt"

	"github.com/nick/proctmux/internal/terminal"
)

// Verify interface compliance at compile time.
var _ terminal.Emulator = (*Emulator)(nil)

// Emulator wraps charmbracelet/x/vt's SafeEmulator to satisfy the
// terminal.Emulator interface. SafeEmulator provides mutex-protected
// access for concurrent Write (from io.Copy goroutine) and Render
// (from Bubble Tea polling tick).
type Emulator struct {
	emu *vt.SafeEmulator
}

// New creates a new charmbracelet/x/vt emulator with the given dimensions.
func New(cols, rows int) *Emulator {
	return &Emulator{
		emu: vt.NewSafeEmulator(cols, rows),
	}
}

// Write feeds raw PTY output into the emulator for VT sequence processing.
func (e *Emulator) Write(p []byte) (int, error) {
	return e.emu.Write(p)
}

// Render returns the current screen content as an ANSI-styled string.
func (e *Emulator) Render() string {
	return e.emu.Render()
}

// Resize changes the virtual terminal dimensions.
func (e *Emulator) Resize(cols, rows int) {
	e.emu.Resize(cols, rows)
}

// Close releases resources held by the emulator.
func (e *Emulator) Close() {
	e.emu.Close()
}

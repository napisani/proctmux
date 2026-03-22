// Package terminal defines the interface for virtual terminal emulators used
// by the unified split-pane mode. The interface abstracts the emulator
// implementation so it can be swapped (e.g., charmbracelet/x/vt today,
// libghostty-vt or libvterm in the future) without changing the split model.
package terminal

import "io"

// Emulator abstracts a virtual terminal that processes PTY output and
// produces styled text for display. Implementations must be safe for
// concurrent use: the io.Copy goroutine calls Write while the Bubble Tea
// polling tick calls Render and Resize.
type Emulator interface {
	// Write feeds raw PTY output into the emulator for processing.
	io.Writer

	// Render returns the current screen content as an ANSI-styled string
	// suitable for display in a terminal or lipgloss pane.
	Render() string

	// Resize changes the virtual terminal dimensions (columns, rows).
	Resize(cols, rows int)

	// Close releases resources held by the emulator.
	Close()
}

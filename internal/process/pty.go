//go:build unix

package process

import (
	"os"

	"golang.org/x/sys/unix"
)

const (
	// Default terminal size for PTY
	RowsDefault = uint16(24)
	ColsDefault = uint16(80)
)

// setRawMode configures a PTY to raw mode using direct termios manipulation
// This is a lower-level alternative to term.MakeRaw() with explicit control over flags.
//
// Raw mode configuration:
//
// Input flags (Iflag) - disable input processing:
//   - IGNBRK:  don't ignore break condition
//   - BRKINT:  don't generate SIGINT on break
//   - PARMRK:  don't mark parity errors
//   - ISTRIP:  don't strip 8th bit
//   - INLCR:   don't translate NL to CR
//   - IGNCR:   don't ignore CR
//   - ICRNL:   don't translate CR to NL (important: Enter key sends CR not NL)
//   - IXON:    disable XON/XOFF flow control
//
// Output flags (Oflag) - disable output processing:
//   - OPOST:   disable output processing (no NL to CR+NL translation, etc.)
//
// Local flags (Lflag) - disable terminal processing:
//   - ECHO:    don't echo input characters
//   - ECHONL:  don't echo newline
//   - ICANON:  disable canonical mode (no line buffering, no erase/kill processing)
//   - ISIG:    disable signal generation (Ctrl+C doesn't generate SIGINT)
//   - IEXTEN:  disable extended input processing
//
// Control flags (Cflag) - character size:
//   - CS8:     8-bit characters
//   - PARENB:  no parity
//
// The result is a "transparent pipe" that passes bytes through without interpretation,
// suitable for programs that want to handle all terminal control themselves.
func setRawMode(f *os.File) error {
	fd := int(f.Fd())
	// ioctlReadTermios and ioctlWriteTermios are defined in platform-specific files
	// (pty_darwin.go, pty_linux.go) to handle platform differences

	// Read current terminal settings
	termios, err := unix.IoctlGetTermios(fd, ioctlReadTermios)
	if err != nil {
		return err
	}

	// Clear flags to disable all input/output/local processing (raw mode)
	// &^= is the "bit clear" operator: x &^= y means x = x & ^y (clear bits set in y)
	// NOTE: We keep ICRNL enabled so CR (\r) gets translated to NL (\n) for shell compatibility
	termios.Iflag &^= unix.IGNBRK | unix.BRKINT | unix.PARMRK | unix.ISTRIP | unix.INLCR | unix.IGNCR | unix.IXON
	// Keep ICRNL for CR->NL translation: termios.Iflag &^= unix.ICRNL

	// Keep OPOST enabled for output processing (NL -> CR+NL)
	// termios.Oflag &^= unix.OPOST

	// Keep ECHO enabled so the shell echoes input characters back
	// Disable other local processing but keep echo
	termios.Lflag &^= unix.ECHONL | unix.ICANON | unix.ISIG | unix.IEXTEN
	// Keep ECHO: termios.Lflag &^= unix.ECHO

	termios.Cflag &^= unix.CSIZE | unix.PARENB
	termios.Cflag |= unix.CS8

	// Configure read behavior:
	// VMIN = 1:  read() returns after at least 1 byte is available
	// VTIME = 0: read() has no timeout (blocks until VMIN bytes available)
	// This creates a "read one byte at a time" behavior for minimal latency
	termios.Cc[unix.VMIN] = 1
	termios.Cc[unix.VTIME] = 0

	// Write the modified terminal settings back
	return unix.IoctlSetTermios(fd, ioctlWriteTermios, termios)
}

// IsTerminal checks if a file descriptor is a terminal
func IsTerminal(fd int) bool {
	_, err := unix.IoctlGetTermios(fd, ioctlReadTermios)
	return err == nil
}

// MakeRawInput sets the terminal to raw mode for input only (keeps output processing)
// This is used for the primary server's stdin to allow interactive input while keeping
// proper output formatting. Returns the old state for restoration.
func MakeRawInput(fd int) (*unix.Termios, error) {
	// Get current terminal settings
	oldState, err := unix.IoctlGetTermios(fd, ioctlReadTermios)
	if err != nil {
		return nil, err
	}

	// Make a copy to modify
	newState := *oldState

	// Raw mode for INPUT: disable input processing and local processing
	newState.Iflag &^= unix.IGNBRK | unix.BRKINT | unix.PARMRK | unix.ISTRIP | unix.INLCR | unix.IGNCR | unix.ICRNL | unix.IXON
	newState.Lflag &^= unix.ECHO | unix.ECHONL | unix.ICANON | unix.ISIG | unix.IEXTEN

	// IMPORTANT: Keep OPOST enabled for output processing (NL -> CR+NL translation)
	// DO NOT clear: newState.Oflag &^= unix.OPOST

	newState.Cflag &^= unix.CSIZE | unix.PARENB
	newState.Cflag |= unix.CS8

	// Read one byte at a time
	newState.Cc[unix.VMIN] = 1
	newState.Cc[unix.VTIME] = 0

	// Apply new settings
	if err := unix.IoctlSetTermios(fd, ioctlWriteTermios, &newState); err != nil {
		return nil, err
	}

	return oldState, nil
}

// RestoreTerminal restores the terminal to its previous state
func RestoreTerminal(fd int, oldState *unix.Termios) error {
	return unix.IoctlSetTermios(fd, ioctlWriteTermios, oldState)
}

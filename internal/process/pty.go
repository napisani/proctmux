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
	const ioctlReadTermios = unix.TIOCGETA  // OSX/Darwin ioctl to get terminal attributes
	const ioctlWriteTermios = unix.TIOCSETA // OSX/Darwin ioctl to set terminal attributes

	// Read current terminal settings
	termios, err := unix.IoctlGetTermios(fd, ioctlReadTermios)
	if err != nil {
		return err
	}

	// Clear flags to disable all input/output/local processing (raw mode)
	// &^= is the "bit clear" operator: x &^= y means x = x & ^y (clear bits set in y)
	termios.Iflag &^= unix.IGNBRK | unix.BRKINT | unix.PARMRK | unix.ISTRIP | unix.INLCR | unix.IGNCR | unix.ICRNL | unix.IXON
	termios.Oflag &^= unix.OPOST
	termios.Lflag &^= unix.ECHO | unix.ECHONL | unix.ICANON | unix.ISIG | unix.IEXTEN
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

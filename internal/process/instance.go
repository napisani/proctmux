package process

import (
	"io"
	"log"
	"log/slog"
	"os"
	"os/exec"
	"sync"
	"time"

	"github.com/nick/proctmux/internal/buffer"
	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/viewer"
)

// Instance represents a running program with a pseudo-terminal (PTY) attached
// This is a higher-level abstraction than the server's pipe-based approach.
//
// PTY vs Pipe Architecture:
// Unlike the server which uses simple pipes (cmd/server/main.go), this uses a PTY (pseudo-terminal).
// Key differences:
//
// PTY (this file):
// - Allocates a master/slave PTY pair (/dev/ptmx, /dev/pts/N)
// - Child process gets a slave PTY as its stdin/stdout/stderr (looks like a real terminal)
// - Kernel interprets control characters (Ctrl+C -> SIGINT to child process group)
// - Terminal line discipline handles line editing, echo, signal generation
// - Child process can query terminal size with ioctl(TIOCGWINSZ)
// - Required for TUI apps that need terminal detection (vim, top, etc.)
//
// Pipe (server):
// - Creates anonymous pipes with pipe() syscall
// - Child sees regular pipes as stdin/stdout (isatty() returns false)
// - No kernel interpretation of control characters (raw bytes)
// - No terminal size information available to child
// - Simpler, lower overhead, suitable for non-interactive or PTY-aware programs
//
// File Descriptor Layout:
// Parent process (this code):
//   - Has master PTY fd (a.File) for read/write
//
// Child process:
//   - fd 0 (stdin):  slave PTY (read side)
//   - fd 1 (stdout): slave PTY (write side)
//   - fd 2 (stderr): slave PTY (write side)
//   - Has /dev/tty pointing to slave PTY
type Instance struct {
	// ID is the unique identifier for this process instance
	ID int

	// File is the master side of the PTY (ptmx)
	// Reading from this gets output from the child process
	// Writing to this sends input to the child process
	// This is the "controlling terminal" file descriptor
	File *os.File

	// cmd is the child process handle
	cmd *exec.Cmd

	// stdin is kept for potential future use (currently unused since PTY handles I/O)
	stdin io.WriteCloser

	// path is the executable path to run
	path string

	// rows and cols define the terminal size for the PTY
	// These are set via TIOCSWINSZ ioctl and queryable by child via TIOCGWINSZ
	rows uint16
	cols uint16

	// Writer receives output from the PTY master
	// This is where the program's stdout/stderr appears
	Writer io.Writer

	// args are command line arguments for the program
	args []string

	// config is the original process configuration that this instance was created with
	config *config.ProcessConfig

	// exitChan is used to signal when the process has exited
	exitChan chan error

	// scrollback is a ring buffer that stores the last N bytes of output
	// This allows users to see recent output when switching between processes
	// The ring buffer also supports live readers for streaming new data
	scrollback *buffer.RingBuffer

	// stopMu guards process shutdown and cleanup to prevent double execution
	stopMu sync.Mutex

	// cleaned indicates whether the instance has been fully cleaned up
	cleaned bool

	// onKillOnce ensures we only execute the on-kill hook a single time
	onKillOnce sync.Once
}

// GetPID returns the process ID of the running process, or -1 if not started
func (pi *Instance) GetPID() int {
	if pi.cmd.Process == nil {
		return -1
	}
	return pi.cmd.Process.Pid
}

// WaitForExit returns a channel that will receive an error when the process exits
func (pi *Instance) WaitForExit() <-chan error {
	return pi.exitChan
}

// Scrollback returns the scrollback buffer for this process
// This method is required to satisfy the viewer.ProcessInstance interface
func (pi *Instance) Scrollback() viewer.ScrollbackBuffer {
	return pi.scrollback
}

// PassThroughInput reads from a reader and forwards to the PTY
// This creates an input pipeline: source reader -> PTY master -> child stdin
//
// Used for piping input from various sources:
// - os.Stdin for interactive use
// - Network connection for remote control
// - File or buffer for automated testing
//
// Reads in 3-byte chunks to handle multi-byte UTF-8 sequences and escape codes
// (many terminal escape sequences are 3 bytes, e.g. arrow keys are ESC[A)
func (pi *Instance) PassThroughInput(reader io.Reader) {
	// 3-byte buffer handles most escape sequences and UTF-8 characters
	b := make([]byte, 3)

	for {
		n, err := reader.Read(b)
		if err != nil {
			slog.Error("failed to read from stdin", "error", err)
			return
		}
		if n == 0 {
			continue
		}

		// Forward input bytes to PTY master (becomes available on child's stdin)
		pi.SendBytes(b[:n])
	}
}

// SendKey sends a string as individual keystrokes with delays
// This simulates typing and is useful for automated testing of interactive programs
// The delay ensures the child process has time to process each character before
// the next arrives (important for programs with per-character input handling)
func (pi *Instance) SendKey(key string) {
	for _, k := range key {
		// Write each character byte to the PTY master
		// Child reads it from PTY slave stdin
		pi.File.Write([]byte{byte(k)})
		// 40ms delay simulates human typing speed and gives program time to react
		<-time.After(time.Millisecond * 40)
	}
}

// SendBytes writes raw bytes to the PTY master (child's stdin)
// This is used for sending input that may include control characters,
// multi-byte sequences (UTF-8), or binary data
func (pi *Instance) SendBytes(bytes []byte) {
	n, err := pi.File.Write(bytes)
	if err != nil {
		log.Printf("process %d: error writing to PTY: %v", pi.ID, err)
	} else if n != len(bytes) {
		log.Printf("process %d: partial write to PTY: wrote %d of %d bytes", pi.ID, n, len(bytes))
	}
}

// WithArgs sets command line arguments for the program (builder pattern)
func (pi *Instance) WithArgs(args []string) *Instance {
	pi.args = args
	return pi
}

// WithWriter sets or adds an output writer (builder pattern)
// Supports multiple writers via io.MultiWriter for output fan-out
// This allows the program's output to be sent to multiple destinations
// (e.g., stdout and a log file simultaneously)
func (pi *Instance) WithWriter(writer io.Writer) *Instance {
	if pi.Writer != nil {
		// If writer already exists, create a multi-writer to fan-out to both
		pi.Writer = io.MultiWriter(pi.Writer, writer)
	} else {
		pi.Writer = writer
	}
	return pi
}

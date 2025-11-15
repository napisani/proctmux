package proctmux

import (
	"fmt"
	"io"
	"log"
	"log/slog"
	"os"
	"os/exec"
	"sync"
	"time"

	"github.com/creack/pty"
	"github.com/nick/proctmux/internal/buffer"
	"github.com/nick/proctmux/internal/config"
	"golang.org/x/sys/unix"
)

type ProcessServer struct {
	processes map[int]*ProcessInstance
	mu        sync.RWMutex
}

const rowsDefault = uint16(24)
const colsDefault = uint16(80)

// Program represents a running program with a pseudo-terminal (PTY) attached
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
type ProcessInstance struct {
	// ID is the unique identifier for this process instance
	ID int
	// *os.File is the master side of the PTY (ptmx)
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

	// the original process configuration that this instance was created with
	config *config.ProcessConfig

	// exitChan is used to signal when the process has exited
	exitChan chan error

	// Scrollback is a ring buffer that stores the last N bytes of output
	// This allows users to see recent output when switching between processes
	// The ring buffer also supports live readers for streaming new data
	Scrollback *buffer.RingBuffer
}

func NewProcessServer() *ProcessServer {
	return &ProcessServer{
		processes: make(map[int]*ProcessInstance),
	}
}

func (ps *ProcessServer) StartProcess(id int, config *config.ProcessConfig) (*ProcessInstance, error) {
	ps.mu.Lock()
	defer ps.mu.Unlock()

	if _, exists := ps.processes[id]; exists {
		return nil, fmt.Errorf("process %d already exists", id)
	}

	cmd := buildCommand(config)
	if cmd == nil {
		return nil, fmt.Errorf("invalid process config: no shell or cmd specified")
	}

	if config.Cwd != "" {
		cmd.Dir = config.Cwd
	}

	cmd.Env = buildEnvironment(config)

	log.Printf("Starting process %d: %s", id, cmd.String())

	ptmx, err := pty.Start(cmd)
	if err != nil {
		return nil, fmt.Errorf("failed to start process with pty: %w", err)
	}

	rows := rowsDefault
	cols := colsDefault
	if config.TerminalRows > 0 {
		rows = uint16(config.TerminalRows)
	}
	if config.TerminalCols > 0 {
		cols = uint16(config.TerminalCols)
	}

	size := &pty.Winsize{
		Rows: rows,
		Cols: cols,
	}
	if err := pty.Setsize(ptmx, size); err != nil {
		log.Printf("Warning: failed to set PTY size: %v", err)
	}

	// Configure master PTY to raw mode
	// This ensures no processing happens on the master side
	// Child still has a proper PTY with all terminal features
	log.Printf("Setting PTY to raw mode for process %d", id)
	if err := setRawMode(ptmx); err != nil {
		ptmx.Close()
		log.Printf("Warning: failed to set PTY to raw mode: %v", err)
	}

	instance := &ProcessInstance{
		ID:         id,
		cmd:        cmd,
		rows:       rows,
		cols:       cols,
		File:       ptmx,
		config:     config,
		exitChan:   make(chan error, 1),
		Scrollback: buffer.NewRingBuffer(1024 * 1024), // 1MB scrollback buffer per process
	}

	go func() {
		err := cmd.Wait()
		log.Printf("Process %d exited with error: %v", id, err)
		instance.exitChan <- err
		close(instance.exitChan)
	}()

	ps.processes[id] = instance
	log.Printf("Started process %d (PID: %d)", id, cmd.Process.Pid)

	log.Printf("Attaching PTY output logger for process %d", id)
	i := instance.WithWriter(instance.Scrollback) // Capture output in scrollback buffer (also notifies readers)

	// Copy PTY output to configured writer (blocking operation)
	// This reads from master PTY and forwards to a.writer
	// Continues until PTY is closed (child exits or Close() called)
	go func() {
		_, err = io.Copy(i.Writer, ptmx)
	}()
	return i, err

}

func (ps *ProcessServer) GetProcess(id int) (*ProcessInstance, error) {
	ps.mu.RLock()
	defer ps.mu.RUnlock()

	instance, exists := ps.processes[id]
	if !exists {
		return nil, fmt.Errorf("process %d not found", id)
	}

	return instance, nil
}

func (ps *ProcessServer) StopProcess(id int) error {
	ps.mu.Lock()
	defer ps.mu.Unlock()

	instance, exists := ps.processes[id]
	if !exists {
		return fmt.Errorf("process %d not found", id)
	}

	if instance.cmd.Process != nil {
		if err := instance.cmd.Process.Kill(); err != nil {
			return fmt.Errorf("failed to kill process: %w", err)
		}
	}

	if instance.File != nil {
		instance.File.Close()
	}

	delete(ps.processes, id)
	log.Printf("Stopped process %d", id)

	return nil
}

func (ps *ProcessServer) RemoveProcess(id int) {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	delete(ps.processes, id)
}

func (ps *ProcessServer) GetScrollback(id int) ([]byte, error) {
	ps.mu.RLock()
	defer ps.mu.RUnlock()

	instance, exists := ps.processes[id]
	if !exists {
		return nil, fmt.Errorf("process %d not found", id)
	}

	if instance.Scrollback == nil {
		return []byte{}, nil
	}

	return instance.Scrollback.Bytes(), nil
}

func (ps *ProcessServer) GetReader(id int) (io.Reader, error) {
	ps.mu.RLock()
	defer ps.mu.RUnlock()

	instance, exists := ps.processes[id]
	if !exists {
		return nil, fmt.Errorf("process %d not found", id)
	}

	return instance.File, nil
}

func (ps *ProcessServer) GetWriter(id int) (io.Writer, error) {
	ps.mu.RLock()
	defer ps.mu.RUnlock()

	instance, exists := ps.processes[id]
	if !exists {
		return nil, fmt.Errorf("process %d not found", id)
	}

	return instance.File, nil
}

func (pi *ProcessInstance) GetPID() int {
	if pi.cmd.Process == nil {
		return -1
	}
	return pi.cmd.Process.Pid
}

func (pi *ProcessInstance) WaitForExit() <-chan error {
	return pi.exitChan
}

func buildCommand(config *config.ProcessConfig) *exec.Cmd {
	if config.Shell != "" {
		return exec.Command("sh", "-c", config.Shell)
	}

	if len(config.Cmd) > 0 {
		return exec.Command(config.Cmd[0], config.Cmd[1:]...)
	}

	return nil
}

func buildEnvironment(config *config.ProcessConfig) []string {
	env := os.Environ()

	if config.Env != nil {
		for k, v := range config.Env {
			env = append(env, fmt.Sprintf("%s=%s", k, v))
		}
	}

	if len(config.AddPath) > 0 {
		currentPath := os.Getenv("PATH")
		for _, p := range config.AddPath {
			currentPath = fmt.Sprintf("%s:%s", currentPath, p)
		}
		env = append(env, fmt.Sprintf("PATH=%s", currentPath))
	}

	return env
}

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
func (p *ProcessInstance) PassThroughInput(reader io.Reader) {
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
		p.SendBytes(b[:n])
	}
}

// SendKey sends a string as individual keystrokes with delays
// This simulates typing and is useful for automated testing of interactive programs
// The delay ensures the child process has time to process each character before
// the next arrives (important for programs with per-character input handling)
func (a *ProcessInstance) SendKey(key string) {
	for _, k := range key {
		// Write each character byte to the PTY master
		// Child reads it from PTY slave stdin
		a.File.Write([]byte{byte(k)})
		// 40ms delay simulates human typing speed and gives program time to react
		<-time.After(time.Millisecond * 40)
	}
}

// SendBytes writes raw bytes to the PTY master (child's stdin)
// This is used for sending input that may include control characters,
// multi-byte sequences (UTF-8), or binary data
func (a *ProcessInstance) SendBytes(bytes []byte) {
	a.File.Write(bytes)
}

// WithArgs sets command line arguments for the program (builder pattern)
func (a *ProcessInstance) WithArgs(args []string) *ProcessInstance {
	a.args = args
	return a
}

// WithWriter sets or adds an output writer (builder pattern)
// Supports multiple writers via io.MultiWriter for output fan-out
// This allows the program's output to be sent to multiple destinations
// (e.g., stdout and a log file simultaneously)
func (a *ProcessInstance) WithWriter(writer io.Writer) *ProcessInstance {
	if a.Writer != nil {
		// If writer already exists, create a multi-writer to fan-out to both
		a.Writer = io.MultiWriter(a.Writer, writer)
	} else {
		a.Writer = writer
	}
	return a
}

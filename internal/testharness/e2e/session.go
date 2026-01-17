package e2e

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
)

const (
	maxTranscriptBytes = 1 << 20 // 1 MiB
)

var (
	clearSequence = []byte{0x1b, '[', '2', 'J'}
	dsrRequest    = []byte{0x1b, '[', '6', 'n'}
)

type terminalState struct {
	rows, cols int
	cursorRow  int
	cursorCol  int
	cells      [][]rune
}

func newTerminalState(rows, cols int) *terminalState {
	t := &terminalState{
		rows:  rows,
		cols:  cols,
		cells: make([][]rune, rows),
	}
	for i := range t.cells {
		t.cells[i] = make([]rune, cols)
		for j := range t.cells[i] {
			t.cells[i][j] = ' '
		}
	}
	return t
}

func (t *terminalState) clear() {
	for i := range t.cells {
		row := t.cells[i]
		for j := range row {
			row[j] = ' '
		}
	}
	t.cursorRow = 0
	t.cursorCol = 0
}

func (t *terminalState) apply(data []byte) {
	for i := 0; i < len(data); i++ {
		b := data[i]
		switch b {
		case 0x1b:
			i++
			if i >= len(data) {
				return
			}
			next := data[i]
			switch next {
			case '[':
				i = t.handleCSI(data, i+1)
			case ']':
				for i < len(data) && data[i] != 0x07 {
					i++
				}
			default:
				// Skip unsupported sequences
			}
		case '\r':
			t.cursorCol = 0
		case '\n':
			if t.cursorRow < t.rows-1 {
				t.cursorRow++
			}
		case '\t':
			nextTab := ((t.cursorCol / 8) + 1) * 8
			if nextTab >= t.cols {
				nextTab = t.cols - 1
			}
			t.cursorCol = nextTab
		default:
			if b >= 0x20 {
				t.writeByte(b)
			}
		}
	}
}

func (t *terminalState) writeByte(b byte) {
	if t.cursorRow < 0 {
		t.cursorRow = 0
	}
	if t.cursorRow >= t.rows {
		t.cursorRow = t.rows - 1
	}
	if t.cursorCol < 0 {
		t.cursorCol = 0
	}
	if t.cursorCol >= t.cols {
		t.cursorCol = t.cols - 1
	}

	t.cells[t.cursorRow][t.cursorCol] = rune(b)
	t.cursorCol++
	if t.cursorCol >= t.cols {
		t.cursorCol = 0
		if t.cursorRow < t.rows-1 {
			t.cursorRow++
		}
	}
}

func (t *terminalState) handleCSI(data []byte, start int) int {
	params := []int{}
	param := 0
	hasDigits := false
	private := false

	i := start
	for ; i < len(data); i++ {
		ch := data[i]
		if ch >= '0' && ch <= '9' {
			param = param*10 + int(ch-'0')
			hasDigits = true
			continue
		}
		if ch == ';' {
			params = append(params, param)
			param = 0
			hasDigits = false
			continue
		}
		if ch == '?' {
			private = true
			continue
		}

		if hasDigits || len(params) == 0 {
			params = append(params, param)
		}

		t.executeCSI(ch, params, private)
		return i
	}

	return len(data) - 1
}

func (t *terminalState) executeCSI(final byte, params []int, private bool) {
	if private {
		return
	}

	switch final {
	case 'A':
		n := getParam(params, 0, 1)
		t.cursorRow -= n
		if t.cursorRow < 0 {
			t.cursorRow = 0
		}
	case 'B':
		n := getParam(params, 0, 1)
		t.cursorRow += n
		if t.cursorRow >= t.rows {
			t.cursorRow = t.rows - 1
		}
	case 'C':
		n := getParam(params, 0, 1)
		t.cursorCol += n
		if t.cursorCol >= t.cols {
			t.cursorCol = t.cols - 1
		}
	case 'D':
		n := getParam(params, 0, 1)
		t.cursorCol -= n
		if t.cursorCol < 0 {
			t.cursorCol = 0
		}
	case 'H', 'f':
		row := getParam(params, 0, 1)
		col := getParam(params, 1, 1)
		t.cursorRow = clamp(row-1, 0, t.rows-1)
		t.cursorCol = clamp(col-1, 0, t.cols-1)
	case 'J':
		mode := getParam(params, 0, 0)
		if mode == 2 || mode == 0 {
			t.clear()
		}
	case 'K':
		mode := getParam(params, 0, 0)
		switch mode {
		case 0:
			for c := t.cursorCol; c < t.cols; c++ {
				t.cells[t.cursorRow][c] = ' '
			}
		case 1:
			for c := 0; c <= t.cursorCol && c < t.cols; c++ {
				t.cells[t.cursorRow][c] = ' '
			}
		case 2:
			for c := 0; c < t.cols; c++ {
				t.cells[t.cursorRow][c] = ' '
			}
		}
	case 'm':
		// ignore style changes
	}
}

func (t *terminalState) render() string {
	var builder strings.Builder
	for i, row := range t.cells {
		line := strings.TrimRight(string(row), " ")
		builder.WriteString(line)
		if i < t.rows-1 {
			builder.WriteByte('\n')
		}
	}
	return strings.TrimRight(builder.String(), "\n")
}

func getParam(params []int, index int, def int) int {
	if index < len(params) {
		if params[index] == 0 {
			return def
		}
		return params[index]
	}
	return def
}

func clamp(value, min, max int) int {
	if value < min {
		return min
	}
	if value > max {
		return max
	}
	return value
}

// Session represents a running proctmux Bubble Tea program controlled via PTY.
type Session struct {
	Cmd    *exec.Cmd
	PTY    *os.File
	cancel context.CancelFunc

	mu          sync.Mutex
	raw         []byte
	clean       []byte
	lastFrame   string
	lastFrameRW []byte
	dsrResid    []byte
	readErr     error
	stopped     bool

	screen *terminalState

	done chan struct{}
}

func startSession(binary string, args []string, dir string, env []string) (*Session, error) {
	ctx, cancel := context.WithCancel(context.Background())

	cmd := exec.CommandContext(ctx, binary, args...)
	cmd.Dir = dir
	cmd.Env = mergeEnv(env)

	ptyFile, err := pty.Start(cmd)
	if err != nil {
		cancel()
		return nil, fmt.Errorf("start session: %w", err)
	}

	_ = pty.Setsize(ptyFile, &pty.Winsize{Rows: 40, Cols: 120})

	s := &Session{
		Cmd:    cmd,
		PTY:    ptyFile,
		cancel: cancel,
		screen: newTerminalState(40, 120),
		done:   make(chan struct{}),
	}

	go s.readLoop()

	return s, nil
}

func (s *Session) readLoop() {
	defer close(s.done)

	buf := make([]byte, 4096)
	for {
		n, err := s.PTY.Read(buf)
		if n > 0 {
			chunk := make([]byte, n)
			copy(chunk, buf[:n])
			s.processChunk(chunk)
		}
		if err != nil {
			if !errors.Is(err, os.ErrClosed) && !errors.Is(err, syscall.EIO) {
				s.mu.Lock()
				s.readErr = err
				s.mu.Unlock()
			}
			return
		}
	}
}

func (s *Session) processChunk(chunk []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.detectDSR(chunk)

	s.raw = appendAndTrim(s.raw, chunk, maxTranscriptBytes)
	s.lastFrameRW = append(s.lastFrameRW, chunk...)

	s.screen.apply(chunk)

	if idx := bytes.LastIndex(s.lastFrameRW, clearSequence); idx >= 0 {
		tail := append([]byte{}, s.lastFrameRW[idx+len(clearSequence):]...)
		s.lastFrameRW = tail
	}

	s.clean = []byte(sanitize(s.raw))
	s.lastFrame = s.screen.render()
}

func appendAndTrim(buf, chunk []byte, limit int) []byte {
	if len(chunk) == 0 {
		return buf
	}

	buf = append(buf, chunk...)
	if limit > 0 && len(buf) > limit {
		buf = append([]byte{}, buf[len(buf)-limit:]...)
	}
	return buf
}

func (s *Session) detectDSR(chunk []byte) {
	combined := append(append([]byte{}, s.dsrResid...), chunk...)
	for {
		idx := bytes.Index(combined, dsrRequest)
		if idx == -1 {
			break
		}
		go s.respondCursorPosition()
		combined = combined[idx+len(dsrRequest):]
	}

	if len(combined) >= len(dsrRequest)-1 {
		s.dsrResid = append([]byte{}, combined[len(combined)-(len(dsrRequest)-1):]...)
	} else {
		s.dsrResid = combined
	}
}

func (s *Session) respondCursorPosition() {
	if s.PTY != nil {
		_, _ = s.PTY.Write([]byte("\x1b[24;80R"))
	}
}

// SendString writes an arbitrary string (bytes) to the session PTY.
func (s *Session) SendString(input string) error {
	if s == nil {
		return fmt.Errorf("session is nil")
	}
	if _, err := s.PTY.Write([]byte(input)); err != nil {
		return fmt.Errorf("send string: %w", err)
	}
	return nil
}

// SendKeys writes a series of predefined key sequences to the PTY.
func (s *Session) SendKeys(keys ...KeySequence) error {
	for _, k := range keys {
		if err := s.SendString(string(k)); err != nil {
			return err
		}
	}
	return nil
}

// SendRunes writes rune keys (useful for letters/numbers).
func (s *Session) SendRunes(runes ...rune) error {
	for _, r := range runes {
		if err := s.SendString(string(r)); err != nil {
			return err
		}
	}
	return nil
}

// CleanOutput returns the sanitized transcript of the session.
func (s *Session) CleanOutput() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return string(append([]byte(nil), s.clean...))
}

// Snapshot returns the sanitized contents of the most recent screen frame.
func (s *Session) Snapshot() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastFrame
}

// RawOutput returns the raw PTY transcript (with ANSI codes intact).
func (s *Session) RawOutput() []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]byte(nil), s.raw...)
}

// WaitFor waits until the sanitized transcript contains substring or times out.
func (s *Session) WaitFor(substring string, timeout time.Duration) error {
	deadline := time.After(timeout)
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			if strings.Contains(s.CleanOutput(), substring) {
				return nil
			}
		case <-deadline:
			return fmt.Errorf("timeout waiting for %q", substring)
		}
	}
}

// WaitForRaw waits until the raw transcript contains substring or times out.
func (s *Session) WaitForRaw(substring string, timeout time.Duration) error {
	deadline := time.After(timeout)
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			if strings.Contains(string(s.RawOutput()), substring) {
				return nil
			}
		case <-deadline:
			return fmt.Errorf("timeout waiting for raw substring %q", substring)
		}
	}
}

// WaitForSnapshot waits until the sanitized current frame satisfies predicate.
func (s *Session) WaitForSnapshot(timeout time.Duration, predicate func(string) bool) error {
	deadline := time.After(timeout)
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			if predicate(s.Snapshot()) {
				return nil
			}
		case <-deadline:
			return fmt.Errorf("timeout waiting for snapshot condition")
		}
	}
}

// Stop terminates the session process and closes the PTY.
func (s *Session) Stop() error {
	if s == nil {
		return nil
	}

	s.mu.Lock()
	if s.stopped {
		s.mu.Unlock()
		return nil
	}
	s.stopped = true
	s.mu.Unlock()

	defer s.cancel()
	defer s.PTY.Close()

	if s.Cmd.Process != nil {
		_ = s.Cmd.Process.Signal(syscall.SIGINT)
	}

	select {
	case <-s.done:
	case <-time.After(5 * time.Second):
		if s.Cmd.Process != nil {
			_ = s.Cmd.Process.Kill()
		}
		<-s.done
	}

	err := s.Cmd.Wait()
	s.mu.Lock()
	readErr := s.readErr
	s.mu.Unlock()

	if err != nil {
		return err
	}
	return readErr
}

func sanitize(data []byte) string {
	var builder strings.Builder
	builder.Grow(len(data))

	for i := 0; i < len(data); i++ {
		b := data[i]
		if b == 0x1b { // ESC
			i++
			if i >= len(data) {
				break
			}
			switch data[i] {
			case '[':
				for {
					i++
					if i >= len(data) || isCSITerminator(data[i]) {
						break
					}
				}
			case ']':
				for i < len(data) && data[i] != 0x07 {
					i++
				}
			default:
				// Skip a single character for other escape sequences.
			}
			continue
		}

		if b < 0x20 {
			if b == '\n' || b == '\t' {
				builder.WriteByte(b)
			}
			continue
		}

		builder.WriteByte(b)
	}

	return builder.String()
}

func isCSITerminator(b byte) bool {
	return b >= 0x40 && b <= 0x7e
}

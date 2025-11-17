package process

import (
	"fmt"
	"io"
	"log"
	"sync"

	"github.com/creack/pty"
	"github.com/nick/proctmux/internal/buffer"
	"github.com/nick/proctmux/internal/config"
)

// Server manages a collection of process instances
type Server struct {
	processes map[int]*Instance
	mu        sync.RWMutex
}

// NewServer creates a new process server
func NewServer() *Server {
	return &Server{
		processes: make(map[int]*Instance),
	}
}

// StartProcess starts a new process with the given configuration
func (ps *Server) StartProcess(id int, cfg *config.ProcessConfig) (*Instance, error) {
	ps.mu.Lock()
	defer ps.mu.Unlock()

	if _, exists := ps.processes[id]; exists {
		return nil, fmt.Errorf("process %d already exists", id)
	}

	cmd := buildCommand(cfg)
	if cmd == nil {
		return nil, fmt.Errorf("invalid process config: no shell or cmd specified")
	}

	if cfg.Cwd != "" {
		cmd.Dir = cfg.Cwd
	}

	cmd.Env = buildEnvironment(cfg)

	log.Printf("Starting process %d: %s", id, cmd.String())

	ptmx, err := pty.Start(cmd)
	if err != nil {
		return nil, fmt.Errorf("failed to start process with pty: %w", err)
	}

	rows := RowsDefault
	cols := ColsDefault
	if cfg.TerminalRows > 0 {
		rows = uint16(cfg.TerminalRows)
	}
	if cfg.TerminalCols > 0 {
		cols = uint16(cfg.TerminalCols)
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

	instance := &Instance{
		ID:         id,
		cmd:        cmd,
		rows:       rows,
		cols:       cols,
		File:       ptmx,
		config:     cfg,
		exitChan:   make(chan error, 1),
		scrollback: buffer.NewRingBuffer(1024 * 1024), // 1MB scrollback buffer per process
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
	i := instance.WithWriter(instance.scrollback) // Capture output in scrollback buffer (also notifies readers)

	// Copy PTY output to configured writer (blocking operation)
	// This reads from master PTY and forwards to a.writer
	// Continues until PTY is closed (child exits or Close() called)
	go func() {
		_, err = io.Copy(i.Writer, ptmx)
	}()

	return i, err
}

// GetProcess returns the process instance with the given ID
func (ps *Server) GetProcess(id int) (*Instance, error) {
	ps.mu.RLock()
	defer ps.mu.RUnlock()

	instance, exists := ps.processes[id]
	if !exists {
		return nil, fmt.Errorf("process %d not found", id)
	}

	return instance, nil
}

// StopProcess stops the process with the given ID
func (ps *Server) StopProcess(id int) error {
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

// RemoveProcess removes a process from the server without stopping it
func (ps *Server) RemoveProcess(id int) {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	delete(ps.processes, id)
}

// GetScrollback returns the scrollback buffer contents for the given process
func (ps *Server) GetScrollback(id int) ([]byte, error) {
	ps.mu.RLock()
	defer ps.mu.RUnlock()

	instance, exists := ps.processes[id]
	if !exists {
		return nil, fmt.Errorf("process %d not found", id)
	}

	if instance.scrollback == nil {
		return []byte{}, nil
	}

	return instance.scrollback.Bytes(), nil
}

// GetReader returns a reader for the process's PTY output
func (ps *Server) GetReader(id int) (io.Reader, error) {
	ps.mu.RLock()
	defer ps.mu.RUnlock()

	instance, exists := ps.processes[id]
	if !exists {
		return nil, fmt.Errorf("process %d not found", id)
	}

	return instance.File, nil
}

// GetWriter returns a writer for the process's PTY input
func (ps *Server) GetWriter(id int) (io.Writer, error) {
	ps.mu.RLock()
	defer ps.mu.RUnlock()

	instance, exists := ps.processes[id]
	if !exists {
		return nil, fmt.Errorf("process %d not found", id)
	}

	return instance.File, nil
}

package process

import (
	"context"
	"fmt"
	"io"
	"log"
	"os/exec"
	"sync"
	"time"

	"github.com/creack/pty"
	"github.com/nick/proctmux/internal/buffer"
	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
)

// Controller manages a collection of process instances and controls their lifecycle
type Controller struct {
	processes map[int]*Instance
	mu        sync.RWMutex
}

// NewController creates a new process controller
func NewController() *Controller {
	return &Controller{
		processes: make(map[int]*Instance),
	}
}

// StartProcess starts a new process with the given configuration
func (pc *Controller) StartProcess(id int, cfg *config.ProcessConfig) (*Instance, error) {
	pc.mu.Lock()
	defer pc.mu.Unlock()

	if _, exists := pc.processes[id]; exists {
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

	pc.processes[id] = instance
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
func (pc *Controller) GetProcess(id int) (*Instance, error) {
	pc.mu.RLock()
	defer pc.mu.RUnlock()

	instance, exists := pc.processes[id]
	if !exists {
		return nil, fmt.Errorf("process %d not found", id)
	}

	return instance, nil
}

// StopProcess stops the process with the given ID
func (pc *Controller) StopProcess(id int) error {
	pc.mu.Lock()
	defer pc.mu.Unlock()

	instance, exists := pc.processes[id]
	if !exists {
		return fmt.Errorf("process %d not found", id)
	}

	if instance.cmd.Process != nil {
		if err := instance.cmd.Process.Kill(); err != nil {
			if err.Error() == "os: process already finished" {
				log.Printf("Process %d already finished", id)
			} else {
				return fmt.Errorf("failed to kill process: %w", err)
			}
		}

		// Wait for process to exit (with timeout), then run on-kill command
		go func() {
			select {
			case <-instance.exitChan:
				log.Printf("Process %d exited, triggering on-kill command", id)
				executeOnKillCommand(instance.config, id)
			case <-time.After(5 * time.Second):
				log.Printf("Process %d did not exit within timeout, running on-kill command anyway", id)
				executeOnKillCommand(instance.config, id)
			}
		}()
	}

	if instance.File != nil {
		instance.File.Close()
	}

	delete(pc.processes, id)
	log.Printf("Stopped process %d", id)

	return nil
}

// GetScrollback returns the scrollback buffer contents for the given process
func (pc *Controller) GetScrollback(id int) ([]byte, error) {
	pc.mu.RLock()
	defer pc.mu.RUnlock()

	instance, exists := pc.processes[id]
	if !exists {
		return nil, fmt.Errorf("process %d not found", id)
	}

	if instance.scrollback == nil {
		return []byte{}, nil
	}

	return instance.scrollback.Bytes(), nil
}

// GetReader returns a reader for the process's PTY output
func (pc *Controller) GetReader(id int) (io.Reader, error) {
	pc.mu.RLock()
	defer pc.mu.RUnlock()

	instance, exists := pc.processes[id]
	if !exists {
		return nil, fmt.Errorf("process %d not found", id)
	}

	return instance.File, nil
}

// GetWriter returns a writer for the process's PTY input
func (pc *Controller) GetWriter(id int) (io.Writer, error) {
	pc.mu.RLock()
	defer pc.mu.RUnlock()

	instance, exists := pc.processes[id]
	if !exists {
		return nil, fmt.Errorf("process %d not found", id)
	}

	return instance.File, nil
}

// GetPID returns the process ID for the given process, or -1 if not running
func (pc *Controller) GetPID(id int) int {
	pc.mu.RLock()
	defer pc.mu.RUnlock()

	instance, exists := pc.processes[id]
	if !exists {
		return -1
	}

	return instance.GetPID()
}

// IsRunning returns true if the process exists and is currently running
func (pc *Controller) IsRunning(id int) bool {
	pc.mu.RLock()
	defer pc.mu.RUnlock()

	instance, exists := pc.processes[id]
	if !exists {
		return false
	}

	// Process is running if it has a valid PID
	return instance.cmd.Process != nil
}

// GetAllProcessIDs returns a list of all process IDs currently managed by the controller
func (pc *Controller) GetAllProcessIDs() []int {
	pc.mu.RLock()
	defer pc.mu.RUnlock()

	ids := make([]int, 0, len(pc.processes))
	for id := range pc.processes {
		ids = append(ids, id)
	}

	return ids
}

// GetProcessStatus returns the current status of the process
// This derives the status from the actual process state rather than storing it
func (pc *Controller) GetProcessStatus(id int) domain.ProcessStatus {
	pc.mu.RLock()
	defer pc.mu.RUnlock()

	instance, exists := pc.processes[id]
	if !exists {
		return domain.StatusHalted
	}

	// Process is running if it has a valid process handle
	if instance.cmd.Process != nil {
		return domain.StatusRunning
	}

	return domain.StatusHalted
}

// executeOnKillCommand runs the on-kill command in the background with a timeout
func executeOnKillCommand(cfg *config.ProcessConfig, processID int) {
	if len(cfg.OnKill) == 0 {
		return
	}

	go func() {
		log.Printf("Executing on-kill command for process %d: %v", processID, cfg.OnKill)

		// Create command with 30 second timeout
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		cmd := exec.CommandContext(ctx, cfg.OnKill[0], cfg.OnKill[1:]...)

		// Use same working directory as original process
		if cfg.Cwd != "" {
			cmd.Dir = cfg.Cwd
		}

		// Use same environment as original process
		cmd.Env = buildEnvironment(cfg)

		// Run the command
		if err := cmd.Run(); err != nil {
			log.Printf("On-kill command for process %d failed: %v", processID, err)
		} else {
			log.Printf("On-kill command for process %d completed successfully", processID)
		}
	}()
}

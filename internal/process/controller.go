package process

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	"github.com/nick/proctmux/internal/buffer"
	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
)

const (
	defaultStopTimeout = 3 * time.Second
)

type stopOptions struct {
	sendSignal   bool
	runOnKill    bool
	allowMissing bool
}

// Controller manages a collection of process instances and controls their lifecycle
type Controller struct {
	processes    map[int]*Instance
	mu           sync.RWMutex
	globalConfig *config.ProcTmuxConfig
}

var configurePTYRawMode = setRawMode

// NewController creates a new process controller
func NewController(globalConfig *config.ProcTmuxConfig) *Controller {
	return &Controller{
		processes:    make(map[int]*Instance),
		globalConfig: globalConfig,
	}
}

// StartProcess starts a new process with the given configuration
func (pc *Controller) StartProcess(id int, cfg *config.ProcessConfig) (*Instance, error) {
	pc.mu.Lock()
	defer pc.mu.Unlock()

	if _, exists := pc.processes[id]; exists {
		return nil, fmt.Errorf("process %d already exists", id)
	}

	cmd := buildCommand(cfg, pc.globalConfig)
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
	if err := configurePTYRawMode(ptmx); err != nil {
		cleanupStartFailure(cmd, ptmx)
		return nil, fmt.Errorf("failed to configure PTY for process %d: %w", id, err)
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
	go func(writer io.Writer, src *os.File, procID int) {
		if _, copyErr := io.Copy(writer, src); copyErr != nil {
			log.Printf("PTY copy for process %d failed: %v", procID, copyErr)
		}
	}(i.Writer, ptmx, id)

	return i, err
}

func cleanupStartFailure(cmd *exec.Cmd, ptmx *os.File) {
	if ptmx != nil {
		if err := ptmx.Close(); err != nil {
			log.Printf("failed to close PTY during startup cleanup: %v", err)
		}
	}

	if cmd == nil || cmd.Process == nil {
		return
	}

	if err := cmd.Process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) && !errors.Is(err, syscall.ESRCH) {
		log.Printf("failed to kill process %d during startup cleanup: %v", cmd.Process.Pid, err)
	}

	if err := cmd.Wait(); err != nil && !errors.Is(err, os.ErrProcessDone) {
		log.Printf("process wait during startup cleanup returned error: %v", err)
	}
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

// StopProcess stops the process with the given ID, sending a graceful signal
// and executing any configured on-kill hook exactly once.
func (pc *Controller) StopProcess(id int) error {
	return pc.stopProcess(id, stopOptions{
		sendSignal:   true,
		runOnKill:    true,
		allowMissing: false,
	})
}

// CleanupProcess releases controller state for a process that has already
// exited externally. This does not trigger on-kill hooks.
func (pc *Controller) CleanupProcess(id int) error {
	return pc.stopProcess(id, stopOptions{
		sendSignal:   false,
		runOnKill:    false,
		allowMissing: true,
	})
}

func (pc *Controller) stopProcess(id int, opts stopOptions) error {
	pc.mu.RLock()
	instance, exists := pc.processes[id]
	pc.mu.RUnlock()

	if !exists {
		if opts.allowMissing {
			return nil
		}
		return fmt.Errorf("process %d not found", id)
	}

	instance.stopMu.Lock()
	if instance.cleaned {
		instance.stopMu.Unlock()
		return nil
	}

	cfg := instance.config
	process := instance.cmd.Process
	pid := -1
	if process != nil {
		pid = process.Pid
	}

	if process != nil && opts.sendSignal {
		sig := resolveStopSignal(cfg)
		log.Printf("Sending signal %d to process %d (PID: %d)", sig, id, pid)
		if err := process.Signal(sig); err != nil && !errors.Is(err, os.ErrProcessDone) && !errors.Is(err, syscall.ESRCH) {
			log.Printf("Failed to send signal %d to process %d: %v", sig, id, err)
		}

		timeout := resolveStopTimeout(cfg)
		if !waitForExit(instance.exitChan, timeout) {
			log.Printf("Process %d did not exit after %s; escalating to SIGKILL", id, timeout)
			if err := process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) && !errors.Is(err, syscall.ESRCH) {
				log.Printf("Failed to kill process %d: %v", id, err)
			} else {
				if !waitForExit(instance.exitChan, 2*time.Second) {
					log.Printf("Process %d still running after SIGKILL escalation", id)
				}
			}
		}
	} else if process != nil {
		waitForExit(instance.exitChan, 0)
	}

	if instance.File != nil {
		instance.File.Close()
		instance.File = nil
	}

	if instance.cmd.Process != nil {
		instance.cmd.Process.Release()
		instance.cmd.Process = nil
	}

	instance.cleaned = true

	pc.mu.Lock()
	delete(pc.processes, id)
	pc.mu.Unlock()

	instance.stopMu.Unlock()

	var hookErr error
	if opts.runOnKill {
		instance.onKillOnce.Do(func() {
			hookErr = executeOnKillCommand(cfg, id)
		})
		if hookErr != nil {
			log.Printf("On-kill command for process %d failed: %v", id, hookErr)
		}
	}

	log.Printf("Stopped process %d", id)
	return hookErr
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

// ScrollbackAndSubscribe atomically captures the current scrollback snapshot
// and registers a live reader in a single operation, eliminating the race
// window between GetScrollback and NewReader.
//
// Returns:
//   - snapshot: all bytes currently in the scrollback buffer
//   - readerID: ID to pass to UnsubscribeScrollback when done
//   - ch: live channel receiving new bytes as the process writes them
//   - err: non-nil if the process is not found or has no scrollback buffer
func (pc *Controller) ScrollbackAndSubscribe(id int) (snapshot []byte, readerID int, ch <-chan []byte, err error) {
	pc.mu.RLock()
	defer pc.mu.RUnlock()

	instance, exists := pc.processes[id]
	if !exists {
		return nil, 0, nil, fmt.Errorf("process %d not found", id)
	}

	if instance.scrollback == nil {
		return []byte{}, 0, nil, nil
	}

	snapshot, readerID, ch = instance.scrollback.SnapshotAndSubscribe()
	return snapshot, readerID, ch, nil
}

// UnsubscribeScrollback removes a live scrollback reader registered via ScrollbackAndSubscribe.
func (pc *Controller) UnsubscribeScrollback(procID, readerID int) {
	pc.mu.RLock()
	instance, exists := pc.processes[procID]
	pc.mu.RUnlock()
	if exists && instance.scrollback != nil {
		instance.scrollback.RemoveReader(readerID)
	}
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

func resolveStopSignal(cfg *config.ProcessConfig) syscall.Signal {
	if cfg != nil && cfg.Stop > 0 {
		return syscall.Signal(cfg.Stop)
	}
	return syscall.SIGTERM
}

func resolveStopTimeout(cfg *config.ProcessConfig) time.Duration {
	if cfg != nil && cfg.StopTimeout > 0 {
		return time.Duration(cfg.StopTimeout) * time.Millisecond
	}
	return defaultStopTimeout
}

func waitForExit(exitCh <-chan error, timeout time.Duration) bool {
	if exitCh == nil {
		return true
	}

	if timeout <= 0 {
		select {
		case <-exitCh:
			return true
		default:
			return false
		}
	}

	timer := time.NewTimer(timeout)
	defer timer.Stop()

	select {
	case <-exitCh:
		return true
	case <-timer.C:
		return false
	}
}

// executeOnKillCommand runs the on-kill command with a timeout and returns any error
func executeOnKillCommand(cfg *config.ProcessConfig, processID int) error {
	if cfg == nil || len(cfg.OnKill) == 0 {
		return nil
	}

	log.Printf("Executing on-kill command for process %d: %v", processID, cfg.OnKill)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, cfg.OnKill[0], cfg.OnKill[1:]...)

	if cfg.Cwd != "" {
		cmd.Dir = cfg.Cwd
	}

	cmd.Env = buildEnvironment(cfg)

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("on-kill command %v failed: %w", cfg.OnKill, err)
	}

	log.Printf("On-kill command for process %d completed successfully", processID)
	return nil
}

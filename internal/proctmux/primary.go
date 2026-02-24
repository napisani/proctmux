package proctmux

import (
	"fmt"
	"io"
	"log"
	"os"
	"sync"
	"time"

	"github.com/nick/proctmux/internal/buffer"
	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
	"github.com/nick/proctmux/internal/process"
	"github.com/nick/proctmux/internal/protocol"
	"github.com/nick/proctmux/internal/viewer"
	"golang.org/x/sys/unix"
)

// PrimaryServerOptions controls optional behavior of the PrimaryServer.
type PrimaryServerOptions struct {
	// SkipStdinForwarder disables raw stdin mode and the stdin-to-process forwarder.
	// Used in unified-toggle mode where the coordinator owns stdin.
	SkipStdinForwarder bool
}

// PrimaryServer is the main process server that manages all processes and state
type PrimaryServer struct {
	processController *process.Controller
	ipcServer         IPCServerInterface
	viewer            *viewer.Viewer
	state             *domain.AppState
	stateMu           sync.RWMutex
	cfg               *config.ProcTmuxConfig
	done              chan struct{}
	stdOutDebugWriter io.Writer
	opts              PrimaryServerOptions

	// stdin pass-through management - just track which process has stdin
	currentStdinProcID int
	stdinMu            sync.Mutex

	// terminal state management
	originalTermState *unix.Termios
}

// IPCServerInterface defines the interface for IPC server operations
type IPCServerInterface interface {
	Start(socketPath string) error
	SetPrimaryServer(primary interface {
		HandleCommand(action protocol.Command, label string) error
		GetState() *domain.AppState
		GetProcessController() domain.ProcessController
	})
	BroadcastState(state *domain.AppState, pc domain.ProcessController)
	Stop()
}

func setupLogger(
	cfg *config.ProcTmuxConfig,
) (io.Writer, error) {
	if cfg != nil && cfg.StdOutDebugLogFile != "" {
		logPath := cfg.StdOutDebugLogFile
		logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
		if err != nil {
			return nil, err
		}

		return buffer.FnToWriter(func(b []byte) (int, error) {
			if logFile != nil {
				return logFile.Write(b)
			}
			return len(b), nil
		}), err
	}
	return nil, nil
}

func NewPrimaryServer(cfg *config.ProcTmuxConfig, ipcServer IPCServerInterface) *PrimaryServer {
	return NewPrimaryServerWithOptions(cfg, ipcServer, PrimaryServerOptions{})
}

// NewPrimaryServerWithOptions creates a PrimaryServer with the given options.
func NewPrimaryServerWithOptions(cfg *config.ProcTmuxConfig, ipcServer IPCServerInterface, opts PrimaryServerOptions) *PrimaryServer {
	state := domain.NewAppState(cfg)
	processController := process.NewController(cfg)

	logWriter, err := setupLogger(cfg)
	if err != nil {
		log.Printf("Warning: failed to set up stdout debug logger: %v", err)
	}

	// Create an adapter that satisfies the viewer.ProcessServer interface
	serverAdapter := &processControllerAdapter{pc: processController}
	v := viewer.New(serverAdapter)
	v.SetPlaceholder(cfg.Layout.PlaceholderBanner)
	v.ShowPlaceholder()

	return &PrimaryServer{
		processController: processController,
		ipcServer:         ipcServer,
		viewer:            v,
		state:             &state,
		cfg:               cfg,
		done:              make(chan struct{}),
		stdOutDebugWriter: logWriter,
		opts:              opts,
	}
}

// processControllerAdapter adapts process.Controller to satisfy viewer.ProcessServer interface
type processControllerAdapter struct {
	pc *process.Controller
}

func (a *processControllerAdapter) GetProcess(id int) (viewer.ProcessInstance, error) {
	return a.pc.GetProcess(id)
}

func (m *PrimaryServer) Start(socketPath string) error {
	// Start IPC server
	if err := m.ipcServer.Start(socketPath); err != nil {
		return fmt.Errorf("failed to start IPC server: %w", err)
	}

	// Set up IPC server to handle commands
	m.ipcServer.SetPrimaryServer(m)

	if !m.opts.SkipStdinForwarder {
		// Set stdin to raw mode for interactive input
		if process.IsTerminal(int(os.Stdin.Fd())) {
			log.Println("stdin: setting terminal to raw input mode")
			oldState, err := process.MakeRawInput(int(os.Stdin.Fd()))
			if err != nil {
				log.Printf("stdin: warning: failed to set stdin to raw mode: %v", err)
			} else {
				m.originalTermState = oldState
				log.Println("stdin: terminal set to raw input mode successfully")
			}
		} else {
			log.Println("stdin: not a terminal, skipping raw mode setup")
		}

		// Start single stdin forwarder
		m.startStdinForwarder()
	} else {
		log.Println("stdin: forwarder skipped (managed externally)")
	}

	// Auto-start processes
	m.autoStartProcesses()

	log.Printf("Primary server started on %s", socketPath)
	return nil
}

func (m *PrimaryServer) autoStartProcesses() {
	m.stateMu.Lock()
	defer m.stateMu.Unlock()

	for idx := range m.state.Processes {
		proc := &m.state.Processes[idx]
		if proc.Config.Autostart {
			log.Printf("Auto-starting process %s", proc.Label)
			m.startProcessLocked(proc.ID)
		}
	}
	m.broadcastStateLocked()
}

func (m *PrimaryServer) broadcastStateLocked() {
	// Pass the controller to the IPC server so it can compute ProcessViews
	m.ipcServer.BroadcastState(m.state, m.processController)
}

// HandleCommand handles IPC commands from clients
func (m *PrimaryServer) HandleCommand(action protocol.Command, label string) error {
	m.stateMu.Lock()
	defer m.stateMu.Unlock()

	proc := m.state.GetProcessByLabel(label)
	if proc == nil {
		return fmt.Errorf("process not found: %s", label)
	}
	var err error

	switch action {
	case protocol.CommandSwitch:
		err = m.switchToProcessLocked(proc.ID)
	case protocol.CommandStart:
		err = m.startProcessLocked(proc.ID)
	case protocol.CommandStop:
		err = m.stopProcessLocked(proc.ID)
	case protocol.CommandRestart:
		err = m.stopProcessLocked(proc.ID)
		if err == nil {
			time.Sleep(500 * time.Millisecond)
			err = m.startProcessLocked(proc.ID)
		}
	default:
		return fmt.Errorf("unknown action: %s", action)

	}
	m.broadcastStateLocked()
	return err
}

func (m *PrimaryServer) GetState() *domain.AppState {
	m.stateMu.RLock()
	defer m.stateMu.RUnlock()
	return m.state
}

func (m *PrimaryServer) GetProcessController() domain.ProcessController {
	return m.processController
}

// GetRawProcessController returns the underlying process.Controller for direct access
// to process instances (scrollback, stdin). Used by unified-toggle mode.
func (m *PrimaryServer) GetRawProcessController() *process.Controller {
	return m.processController
}

func (m *PrimaryServer) GetViewer() *viewer.Viewer {
	return m.viewer
}

// startStdinForwarder starts a single goroutine that reads from stdin
// and forwards to whichever process is current
func (m *PrimaryServer) startStdinForwarder() {
	go func() {
		log.Println("stdin forwarder started")
		buf := make([]byte, 3) // 3 bytes to handle escape sequences

		for {
			n, err := os.Stdin.Read(buf)
			if err != nil {
				log.Printf("stdin read error: %v", err)
				return
			}
			if n == 0 {
				continue
			}

			// Detect Ctrl+C (0x03) and exit the server
			if n == 1 && buf[0] == 0x03 {
				log.Println("stdin: Ctrl+C detected, shutting down...")
				m.Stop()
				os.Exit(0)
			}

			// Filter out tmux focus events: ESC[I (focus in) and ESC[O (focus out)
			// These are 3-byte sequences: 0x1b 0x5b 0x49 and 0x1b 0x5b 0x4f
			if n >= 3 && buf[0] == 0x1b && buf[1] == '[' && (buf[2] == 'I' || buf[2] == 'O') {
				log.Printf("stdin: filtered tmux focus event: %c", buf[2])
				continue
			}

			// Get current process and send bytes
			m.stdinMu.Lock()
			procID := m.currentStdinProcID
			m.stdinMu.Unlock()

			if procID > 0 && m.processController.IsRunning(procID) {
				instance, err := m.processController.GetProcess(procID)
				if err == nil {
					instance.SendBytes(buf[:n])
				} else {
					log.Printf("stdin: failed to get process %d: %v", procID, err)
				}
			} else if procID > 0 {
				log.Printf("stdin: process %d not running, dropping input", procID)
			} else {
				log.Printf("stdin: no process attached, dropping input")
			}
		}
	}()
}

// attachStdinToProcess marks a process as the stdin target
func (m *PrimaryServer) attachStdinToProcess(procID int) {
	m.stdinMu.Lock()
	defer m.stdinMu.Unlock()

	if m.currentStdinProcID != procID {
		oldProcID := m.currentStdinProcID
		m.currentStdinProcID = procID
		if oldProcID > 0 {
			log.Printf("stdin: detached from process %d, attached to process %d", oldProcID, procID)
		} else {
			log.Printf("stdin: attached to process %d", procID)
		}
	}
}

func (m *PrimaryServer) switchToProcessLocked(procID int) error {
	proc := m.state.GetProcessByID(procID)
	if proc == nil {
		return fmt.Errorf("process not found: %d", procID)
	}

	// Update selection
	m.state.CurrentProcID = proc.ID
	log.Printf("Switched to process %s (ID: %d)", proc.Label, proc.ID)

	// Switch the viewer to display this process (if viewer is active)
	if m.viewer != nil {
		if err := m.viewer.SwitchToProcess(proc.ID); err != nil {
			log.Printf("Warning: failed to switch viewer to process %d: %v", proc.ID, err)
		}
	}

	// Attach stdin to the new process
	if !m.opts.SkipStdinForwarder {
		m.attachStdinToProcess(proc.ID)
	}

	return nil
}

func (m *PrimaryServer) startProcessLocked(procID int) error {
	proc := m.state.GetProcessByID(procID)
	if proc == nil {
		return fmt.Errorf("process not found: %d", procID)
	}

	// Check if already running by querying the controller
	if m.processController.IsRunning(procID) {
		log.Printf("Process %s is already running", proc.Label)
		return nil
	}

	log.Printf("Starting process %s (ID: %d)", proc.Label, procID)

	instance, err := m.processController.StartProcess(procID, proc.Config)
	if err != nil {
		log.Printf("Error starting process %d: %v", procID, err)
		return err
	}

	// Attach debug writer if configured, so that all stdout/stderr is also written there
	if m.stdOutDebugWriter != nil {
		instance = instance.WithWriter(m.stdOutDebugWriter)
	}

	pid := instance.GetPID()
	log.Printf("Started process %s with PID %d", proc.Label, pid)

	// No need to manually update Status/PID - they will be queried from controller when needed

	// If this process is currently being viewed, refresh the viewer to show output from the beginning
	if m.viewer != nil && m.viewer.GetCurrentProcessID() == procID {
		log.Printf("Refreshing viewer for newly started process %d", procID)
		go m.viewer.RefreshCurrentProcess()
		// Also attach stdin since this process is being viewed
		if !m.opts.SkipStdinForwarder {
			m.attachStdinToProcess(procID)
		}
	}

	// Watch for process exit
	go func() {
		<-instance.WaitForExit()
		log.Printf("Process %d (PID: %d) exited", procID, pid)
		// even though the processes has exited, its not clear if it was stopped via the proctmux app
		// or crashed/terminated externally, so ensure to stop it properly here.
		if err := m.processController.CleanupProcess(procID); err != nil {
			log.Printf("Cleanup of process %d after exit failed: %v", procID, err)
		}

		// Broadcast state change to notify clients that process has exited
		m.stateMu.Lock()
		m.broadcastStateLocked()
		m.stateMu.Unlock()

	}()

	return nil
}

func (m *PrimaryServer) stopProcessLocked(procID int) error {
	proc := m.state.GetProcessByID(procID)
	if proc == nil {
		return fmt.Errorf("process not found: %d", procID)
	}

	// Check if running by querying the controller
	if !m.processController.IsRunning(procID) {
		log.Printf("Process %s is not running", proc.Label)
		return nil
	}

	// Actually stop the process via the controller (this was the bug!)
	if err := m.processController.StopProcess(procID); err != nil {
		log.Printf("Error stopping process %s: %v", proc.Label, err)
		return err
	}

	log.Printf("Stopped process %s", proc.Label)
	// No need to manually update Status/PID - they will be queried from controller when needed

	return nil
}

func (m *PrimaryServer) Stop() {
	log.Println("Stopping primary server...")

	// Restore terminal state
	if m.originalTermState != nil {
		log.Println("stdin: restoring terminal to original state")
		if err := process.RestoreTerminal(int(os.Stdin.Fd()), m.originalTermState); err != nil {
			log.Printf("stdin: warning: failed to restore terminal: %v", err)
		} else {
			log.Println("stdin: terminal restored successfully")
		}
		m.originalTermState = nil
	}

	if m.stdOutDebugWriter != nil {
		if closer, ok := m.stdOutDebugWriter.(io.Closer); ok {
			closer.Close()
		}
	}
	close(m.done)

	// Stop all running processes by querying the controller
	m.stateMu.Lock()
	runningIDs := m.processController.GetAllProcessIDs()
	for _, id := range runningIDs {
		if m.processController.IsRunning(id) {
			proc := m.state.GetProcessByID(id)
			if proc != nil {
				log.Printf("Stopping process %s", proc.Label)
			}
			m.processController.StopProcess(id)
		}
	}
	m.stateMu.Unlock()

	// Stop IPC server
	m.ipcServer.Stop()

	log.Println("Primary server stopped")
}

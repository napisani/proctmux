package proctmux

import (
	"fmt"
	"io"
	"log"
	"os"
	"sync"
	"time"
)

// PrimaryServer is the main process server that manages all processes and state
type PrimaryServer struct {
	processServer     *ProcessServer
	ipcServer         IPCServerInterface
	viewer            *Viewer
	state             *AppState
	stateMu           sync.RWMutex
	cfg               *ProcTmuxConfig
	done              chan struct{}
	stdOutDebugWriter io.Writer
}

// IPCServerInterface defines the interface for IPC server operations
type IPCServerInterface interface {
	Start(socketPath string) error
	SetPrimaryServer(primary interface {
		HandleCommand(action, label string) error
		GetState() *AppState
	})
	BroadcastState(state *AppState)
	Stop()
}

func setupLogger(
	cfg *ProcTmuxConfig,
) (io.Writer, error) {
	if cfg != nil && cfg.StdOutDebugLogFile != "" {
		logPath := cfg.StdOutDebugLogFile
		logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
		if err != nil {
			return nil, err
		}

		return FnToWriter(func(b []byte) (int, error) {
			if logFile != nil {
				return logFile.Write(b)
			}
			return len(b), nil
		}), err
	}
	return nil, nil
}

func NewPrimaryServer(cfg *ProcTmuxConfig, ipcServer IPCServerInterface) *PrimaryServer {
	state := NewAppState(cfg)
	processServer := NewProcessServer()

	logWriter, err := setupLogger(cfg)
	if err != nil {
		log.Printf("Warning: failed to set up stdout debug logger: %v", err)
	}

	return &PrimaryServer{
		processServer:     processServer,
		ipcServer:         ipcServer,
		viewer:            NewViewer(processServer),
		state:             &state,
		cfg:               cfg,
		done:              make(chan struct{}),
		stdOutDebugWriter: logWriter,
	}
}

func (m *PrimaryServer) Start(socketPath string) error {
	// Start IPC server
	if err := m.ipcServer.Start(socketPath); err != nil {
		return fmt.Errorf("failed to start IPC server: %w", err)
	}

	// Set up IPC server to handle commands
	m.ipcServer.SetPrimaryServer(m)

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
	m.ipcServer.BroadcastState(m.state)
}

// HandleCommand handles IPC commands from clients
func (m *PrimaryServer) HandleCommand(action string, label string) error {
	m.stateMu.Lock()
	defer m.stateMu.Unlock()

	proc := m.state.GetProcessByLabel(label)
	if proc == nil {
		return fmt.Errorf("process not found: %s", label)
	}
	var err error

	switch action {
	case "switch":
		err = m.switchToProcessLocked(proc.ID)
	case "start":
		err = m.startProcessLocked(proc.ID)
	case "stop":
		err = m.stopProcessLocked(proc.ID)
	case "restart":
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

func (m *PrimaryServer) GetState() *AppState {
	m.stateMu.RLock()
	defer m.stateMu.RUnlock()
	return m.state
}

func (m *PrimaryServer) GetProcessServer() *ProcessServer {
	return m.processServer
}

func (m *PrimaryServer) GetViewer() *Viewer {
	return m.viewer
}

func (m *PrimaryServer) switchToProcessLocked(procID int) error {
	proc := m.state.GetProcessByID(procID)
	if proc == nil {
		return fmt.Errorf("process not found: %d", procID)
	}

	// Update selection
	m.state.CurrentProcID = proc.ID
	log.Printf("Switched to process %s (ID: %d)", proc.Label, proc.ID)

	// Switch the viewer to display this process
	if err := m.viewer.SwitchToProcess(proc.ID); err != nil {
		log.Printf("Warning: failed to switch viewer to process %d: %v", proc.ID, err)
	}

	return nil
}

func (m *PrimaryServer) startProcessLocked(procID int) error {
	proc := m.state.GetProcessByID(procID)
	if proc == nil {
		return fmt.Errorf("process not found: %d", procID)
	}

	if proc.Status == StatusRunning {
		log.Printf("Process %s is already running", proc.Label)
		return nil
	}

	log.Printf("Starting process %s (ID: %d)", proc.Label, procID)

	instance, err := m.processServer.StartProcess(procID, proc.Config)
	if err != nil {
		log.Printf("Error starting process %d: %v", procID, err)
		proc.Status = StatusHalted
		proc.PID = 0
		return err
	}

	// Attach debug writer if configured, so that all stdout/stderr is also written there
	if m.stdOutDebugWriter != nil {
		instance = instance.WithWriter(m.stdOutDebugWriter)
	}

	pid := instance.GetPID()
	log.Printf("Started process %s with PID %d", proc.Label, pid)

	proc.Status = StatusRunning
	proc.PID = pid

	// If this process is currently being viewed, refresh the viewer to show output from the beginning
	if m.viewer.GetCurrentProcessID() == procID {
		log.Printf("Refreshing viewer for newly started process %d", procID)
		go m.viewer.RefreshCurrentProcess()
	}

	// Watch for process exit
	go func() {
		<-instance.WaitForExit()
		log.Printf("Process %d (PID: %d) exited", procID, pid)
		m.processServer.RemoveProcess(procID)

		m.stateMu.Lock()
		proc := m.state.GetProcessByID(procID)
		if proc != nil {
			proc.Status = StatusHalted
			proc.PID = 0
		}
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

	if proc.Status != StatusRunning {
		log.Printf("Process %s is not running", proc.Label)
		return nil
	}

	log.Printf("Stopping process %s (ID: %d)", proc.Label, procID)

	if err := m.processServer.StopProcess(procID); err != nil {
		log.Printf("Error stopping process %d: %v", procID, err)
		return err
	}

	proc.Status = StatusHalted
	proc.PID = 0
	log.Printf("Stopped process %s", proc.Label)

	return nil
}

func (m *PrimaryServer) Stop() {
	log.Println("Stopping primary server...")
	if m.stdOutDebugWriter != nil {
		if closer, ok := m.stdOutDebugWriter.(io.Closer); ok {
			closer.Close()
		}
	}
	close(m.done)

	// Stop all running processes
	m.stateMu.Lock()
	for idx := range m.state.Processes {
		proc := &m.state.Processes[idx]
		if proc.Status == StatusRunning {
			log.Printf("Stopping process %s", proc.Label)
			m.processServer.StopProcess(proc.ID)
		}
	}
	m.stateMu.Unlock()

	// Stop IPC server
	m.ipcServer.Stop()

	log.Println("Primary server stopped")
}

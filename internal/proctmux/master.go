package proctmux

import (
	"fmt"
	"log"
	"os"
	"sync"
	"time"
)

// MasterServer is the main process server that manages all processes and state
type MasterServer struct {
	processServer *ProcessServer
	ipcServer     *IPCServer
	state         *AppState
	stateMu       sync.RWMutex
	cfg           *ProcTmuxConfig
	done          chan struct{}
}

func NewMasterServer(cfg *ProcTmuxConfig) *MasterServer {
	state := NewAppState(cfg)
	return &MasterServer{
		processServer: NewProcessServer(),
		ipcServer:     NewIPCServer(),
		state:         &state,
		cfg:           cfg,
		done:          make(chan struct{}),
	}
}

func (m *MasterServer) Start(socketPath string) error {
	// Start IPC server
	if err := m.ipcServer.Start(socketPath); err != nil {
		return fmt.Errorf("failed to start IPC server: %w", err)
	}

	// Set up IPC server to handle commands
	m.ipcServer.SetMasterServer(m)

	// Write socket path to well-known location
	if err := WriteSocketPathFile(socketPath); err != nil {
		log.Printf("Warning: Failed to write socket path file: %v", err)
	}

	// Auto-start processes
	m.autoStartProcesses()

	// Start state broadcast loop
	go m.broadcastLoop()

	log.Printf("Master server started on %s", socketPath)
	return nil
}

func (m *MasterServer) autoStartProcesses() {
	m.stateMu.Lock()
	defer m.stateMu.Unlock()

	for idx := range m.state.Processes {
		proc := &m.state.Processes[idx]
		if proc.Config.Autostart {
			log.Printf("Auto-starting process %s", proc.Label)
			m.startProcessLocked(proc.ID, proc.Config)
		}
	}
}

func (m *MasterServer) broadcastLoop() {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-m.done:
			return
		case <-ticker.C:
			m.broadcastState()
		}
	}
}

func (m *MasterServer) broadcastState() {
	m.stateMu.RLock()
	state := m.state
	m.stateMu.RUnlock()

	m.ipcServer.BroadcastState(state)
}

// HandleCommand handles IPC commands from clients
func (m *MasterServer) HandleCommand(action string, label string) error {
	m.stateMu.Lock()
	defer m.stateMu.Unlock()

	// Handle switch action separately (doesn't need to lock a specific process)
	if action == "switch" {
		proc := m.state.GetProcessByLabel(label)
		if proc == nil {
			return fmt.Errorf("process not found: %s", label)
		}
		// Update selection
		m.state.CurrentProcID = proc.ID
		log.Printf("Switched to process %s (ID: %d)", label, proc.ID)
		return nil
	}

	proc := m.state.GetProcessByLabel(label)
	if proc == nil {
		return fmt.Errorf("process not found: %s", label)
	}

	switch action {
	case "start":
		return m.startProcessLocked(proc.ID, proc.Config)
	case "stop":
		return m.stopProcessLocked(proc.ID)
	case "restart":
		if err := m.stopProcessLocked(proc.ID); err != nil {
			return err
		}
		time.Sleep(500 * time.Millisecond)
		return m.startProcessLocked(proc.ID, proc.Config)
	default:
		return fmt.Errorf("unknown action: %s", action)
	}
}

// HandleSelection handles selection changes from UI clients
func (m *MasterServer) HandleSelection(procID int) {
	m.stateMu.Lock()
	defer m.stateMu.Unlock()

	if m.state.CurrentProcID == procID {
		return
	}

	m.state.CurrentProcID = procID
	log.Printf("Selection changed to process ID %d", procID)
}

func (m *MasterServer) GetState() *AppState {
	m.stateMu.RLock()
	defer m.stateMu.RUnlock()
	return m.state
}

func (m *MasterServer) GetProcessServer() *ProcessServer {
	return m.processServer
}

func (m *MasterServer) startProcessLocked(procID int, config *ProcessConfig) error {
	proc := m.state.GetProcessByID(procID)
	if proc == nil {
		return fmt.Errorf("process not found: %d", procID)
	}

	if proc.Status == StatusRunning {
		log.Printf("Process %s is already running", proc.Label)
		return nil
	}

	log.Printf("Starting process %s (ID: %d)", proc.Label, procID)

	instance, err := m.processServer.StartProcess(procID, config)
	if err != nil {
		log.Printf("Error starting process %d: %v", procID, err)
		proc.Status = StatusHalted
		proc.PID = 0
		return err
	}

	pid := instance.GetPID()
	log.Printf("Started process %s with PID %d", proc.Label, pid)

	proc.Status = StatusRunning
	proc.PID = pid

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
		m.stateMu.Unlock()

		m.broadcastState()
	}()

	return nil
}

func (m *MasterServer) stopProcessLocked(procID int) error {
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

func (m *MasterServer) Stop() {
	log.Println("Stopping master server...")
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

	// Clean up socket path file
	_ = os.Remove("/tmp/proctmux.socket")

	log.Println("Master server stopped")
}

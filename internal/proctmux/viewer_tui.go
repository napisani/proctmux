package proctmux

import (
	"fmt"
	"log"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

type ViewerModel struct {
	ipcClient     *IPCClient
	processServer *ProcessServer
	ttyViewer     *TTYViewer
	state         *AppState
	termWidth     int
	termHeight    int
	errorMsg      string
	connected     bool
}

type userActionMsg struct {
	action string
	procID int
	label  string
	config *ProcessConfig
}

type connectionErrorMsg struct {
	err error
}

type tickMsg time.Time

func NewViewerModel(client *IPCClient, server *ProcessServer, cfg *ProcTmuxConfig) ViewerModel {
	viewer := NewTTYViewer(server)
	state := NewAppState(cfg)
	return ViewerModel{
		ipcClient:     client,
		processServer: server,
		ttyViewer:     viewer,
		state:         &state,
		connected:     client.IsConnected(),
	}
}

func (m ViewerModel) Init() tea.Cmd {
	m.broadcastState()
	return tea.Batch(
		m.pollSelection(),
		tickCmd(),
	)
}

func tickCmd() tea.Cmd {
	return tea.Tick(time.Millisecond*100, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

func (m ViewerModel) pollSelection() tea.Cmd {
	return func() tea.Msg {
		if !m.ipcClient.IsConnected() {
			return connectionErrorMsg{err: fmt.Errorf("not connected to IPC server")}
		}

		msg, err := m.ipcClient.ReadMessage()
		if err != nil {
			return connectionErrorMsg{err: err}
		}

		switch msg.Type {
		case "user_action":
			return userActionMsg{
				action: msg.Action,
				procID: msg.ProcessID,
				label:  msg.Label,
				config: msg.Config,
			}
		default:
			log.Printf("Unknown message type: %s", msg.Type)
			return nil
		}
	}
}

func (m ViewerModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.termWidth, m.termHeight = msg.Width, msg.Height
		return m, nil

	case tea.KeyMsg:
		key := msg.String()
		if key == "ctrl+c" || key == "q" {
			return m, tea.Quit
		}
		return m, nil

	case userActionMsg:
		m.errorMsg = ""
		m.connected = true

		log.Printf("Received user action: action=%s procID=%d", msg.action, msg.procID)

		switch msg.action {
		case "select":
			m.handleSelect(msg.procID, msg.label)
		case "start":
			m.handleStart(msg.procID, msg.config)
		case "stop":
			m.handleStop(msg.procID)
		case "restart":
			m.handleStop(msg.procID)
			time.Sleep(500 * time.Millisecond)
			m.handleStart(msg.procID, msg.config)
		default:
			log.Printf("Unknown user action: %s", msg.action)
		}

		m.broadcastState()
		return m, m.pollSelection()

	case connectionErrorMsg:
		m.connected = false
		m.errorMsg = fmt.Sprintf("Connection error: %v", msg.err)
		log.Printf("IPC connection error: %v", msg.err)
		return m, tea.Batch(
			tea.Tick(time.Second*2, func(t time.Time) tea.Msg {
				if err := m.ipcClient.Connect(); err != nil {
					return connectionErrorMsg{err: err}
				}
				return userActionMsg{}
			}),
		)

	case tickMsg:
		m.broadcastState()
		return m, tickCmd()

	case errMsg:
		m.errorMsg = msg.Error()
		return m, nil
	}

	return m, nil
}

func (m ViewerModel) View() string {
	if !m.connected {
		return fmt.Sprintf("❌ Disconnected from master process\n\n%s\n\nRetrying connection...\n\nPress 'q' or Ctrl+C to quit.", m.errorMsg)
	}

	currentProc := m.state.GetCurrentProcess()
	if currentProc == nil {
		return "⏸  No process selected\n\nWaiting for selection from master terminal...\n\nPress 'q' or Ctrl+C to quit."
	}

	if currentProc.ID == DummyProcessID {
		return "⏸  Dummy process selected\n\nSelect a real process in the master terminal.\n\nPress 'q' or Ctrl+C to quit."
	}

	output := m.ttyViewer.GetOutput()
	header := fmt.Sprintf("👁  Viewing: %s (Process ID: %d)\n", currentProc.Label, currentProc.ID)
	separator := "─────────────────────────────────────────────────────────────────────────────\n"

	if output == "" {
		return header + separator + "\n(No output yet)\n\nPress 'q' or Ctrl+C to quit."
	}

	return header + separator + "\n" + output
}

func (m *ViewerModel) broadcastState() {
	if err := m.ipcClient.SendState(m.state); err != nil {
		log.Printf("Failed to broadcast state: %v", err)
		m.errorMsg = fmt.Sprintf("State broadcast error: %v", err)
	}
}

func (m *ViewerModel) handleSelect(procID int, label string) {
	if m.state.CurrentProcID == procID {
		return
	}

	m.state.CurrentProcID = procID
	log.Printf("Viewer switched to process: %s (ID: %d)", label, procID)

	if procID != 0 && procID != DummyProcessID {
		if err := m.ttyViewer.SwitchToProcess(procID); err != nil {
			log.Printf("Failed to switch TTY viewer: %v", err)
			m.errorMsg = fmt.Sprintf("Error: %v", err)
		}
	}
}

func (m *ViewerModel) handleStart(procID int, config *ProcessConfig) {
	log.Printf("Starting process ID %d", procID)

	instance, err := m.processServer.StartProcess(procID, config)
	if err != nil {
		log.Printf("Error starting process %d: %v", procID, err)
		proc := m.state.GetProcessByID(procID)
		if proc != nil {
			proc.Status = StatusHalted
			proc.PID = 0
		}
		return
	}

	pid := instance.GetPID()
	log.Printf("Started process %d with PID %d", procID, pid)

	proc := m.state.GetProcessByID(procID)
	if proc != nil {
		proc.Status = StatusRunning
		proc.PID = pid
	}

	go func() {
		<-instance.WaitForExit()
		log.Printf("Process %d (PID: %d) exited", procID, pid)
		m.processServer.RemoveProcess(procID)

		proc := m.state.GetProcessByID(procID)
		if proc != nil {
			proc.Status = StatusHalted
			proc.PID = 0
		}
		m.broadcastState()
	}()
}

func (m *ViewerModel) handleStop(procID int) {
	log.Printf("Stopping process ID %d", procID)

	proc := m.state.GetProcessByID(procID)
	if proc == nil {
		log.Printf("Process %d not found in state", procID)
		return
	}

	oldPID := proc.PID

	if err := m.processServer.StopProcess(procID); err != nil {
		log.Printf("Error stopping process %d: %v", procID, err)
	}

	proc.Status = StatusHalted
	proc.PID = 0
	log.Printf("Stopped process %d (was PID %d)", procID, oldPID)
}

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
	currentProcID int
	currentLabel  string
	termWidth     int
	termHeight    int
	errorMsg      string
	connected     bool
	processes     map[int]*Process
}

type selectionMsg struct {
	procID int
	label  string
}

type commandMsg struct {
	action string
	procID int
	config *ProcessConfig
}

type connectionErrorMsg struct {
	err error
}

type tickMsg time.Time

func NewViewerModel(client *IPCClient, server *ProcessServer) ViewerModel {
	viewer := NewTTYViewer(server)
	return ViewerModel{
		ipcClient:     client,
		processServer: server,
		ttyViewer:     viewer,
		currentProcID: 0,
		currentLabel:  "",
		connected:     client.IsConnected(),
		processes:     make(map[int]*Process),
	}
}

func (m ViewerModel) Init() tea.Cmd {
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

		msg, err := m.ipcClient.ReadSelection()
		if err != nil {
			return connectionErrorMsg{err: err}
		}

		switch msg.Type {
		case "selection":
			return selectionMsg{
				procID: msg.ProcessID,
				label:  msg.Label,
			}
		case "command":
			return commandMsg{
				action: msg.Action,
				procID: msg.ProcessID,
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

	case selectionMsg:
		m.errorMsg = ""
		m.connected = true

		if msg.procID != m.currentProcID {
			m.currentProcID = msg.procID
			m.currentLabel = msg.label
			log.Printf("Viewer switched to process: %s (ID: %d)", msg.label, msg.procID)

			if msg.procID != 0 && msg.procID != DummyProcessID {
				if err := m.ttyViewer.SwitchToProcess(msg.procID); err != nil {
					log.Printf("Failed to switch TTY viewer: %v", err)
					m.errorMsg = fmt.Sprintf("Error: %v", err)
				}
			}
		}

		return m, m.pollSelection()

	case commandMsg:
		m.errorMsg = ""
		m.connected = true

		log.Printf("Received command: action=%s procID=%d", msg.action, msg.procID)

		switch msg.action {
		case "start":
			m.handleStart(msg.procID, msg.config)
		case "stop":
			m.handleStop(msg.procID)
		case "restart":
			m.handleStop(msg.procID)
			time.Sleep(500 * time.Millisecond)
			m.handleStart(msg.procID, msg.config)
		default:
			log.Printf("Unknown command action: %s", msg.action)
		}

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
				return selectionMsg{}
			}),
		)

	case tickMsg:
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

	if m.currentProcID == 0 {
		return "⏸  No process selected\n\nWaiting for selection from master terminal...\n\nPress 'q' or Ctrl+C to quit."
	}

	if m.currentProcID == DummyProcessID {
		return "⏸  Dummy process selected\n\nSelect a real process in the master terminal.\n\nPress 'q' or Ctrl+C to quit."
	}

	output := m.ttyViewer.GetOutput()
	header := fmt.Sprintf("👁  Viewing: %s (Process ID: %d)\n", m.currentLabel, m.currentProcID)
	separator := "─────────────────────────────────────────────────────────────────────────────\n"

	if output == "" {
		return header + separator + "\n(No output yet)\n\nPress 'q' or Ctrl+C to quit."
	}

	return header + separator + "\n" + output
}

func (m *ViewerModel) handleStart(procID int, config *ProcessConfig) {
	log.Printf("Starting process ID %d", procID)

	instance, err := m.processServer.StartProcess(procID, config)
	if err != nil {
		log.Printf("Error starting process %d: %v", procID, err)
		m.ipcClient.SendStatus(procID, "stopped", 0, 1)
		return
	}

	pid := instance.GetPID()
	log.Printf("Started process %d with PID %d", procID, pid)

	proc := &Process{
		ID:     procID,
		Status: StatusRunning,
		PID:    pid,
		Config: config,
	}
	m.processes[procID] = proc

	m.ipcClient.SendStatus(procID, "running", pid, 0)

	go func() {
		<-instance.WaitForExit()
		log.Printf("Process %d (PID: %d) exited", procID, pid)
		m.processServer.RemoveProcess(procID)
		delete(m.processes, procID)
		m.ipcClient.SendStatus(procID, "stopped", 0, 0)
	}()
}

func (m *ViewerModel) handleStop(procID int) {
	log.Printf("Stopping process ID %d", procID)

	proc, exists := m.processes[procID]
	if !exists {
		log.Printf("Process %d not found in viewer", procID)
		m.ipcClient.SendStatus(procID, "stopped", 0, 0)
		return
	}

	if err := m.processServer.StopProcess(procID); err != nil {
		log.Printf("Error stopping process %d: %v", procID, err)
	}

	delete(m.processes, procID)
	m.ipcClient.SendStatus(procID, "stopped", 0, 0)
	log.Printf("Stopped process %d (was PID %d)", procID, proc.PID)
}

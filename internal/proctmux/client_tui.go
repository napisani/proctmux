package proctmux

import (
	"fmt"
	"log"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

// ClientModel is a UI-only model that connects to a primary server
type ClientModel struct {
	client     *IPCClient
	domain     *AppState
	ui         UIState
	termWidth  int
	termHeight int
	filterSeq  int
	selectSeq  int
}

// clientStateUpdateMsg wraps state updates from primary
type clientStateUpdateMsg struct {
	state *AppState
}

func NewClientModel(client *IPCClient, state *AppState) ClientModel {
	return ClientModel{
		client: client,
		domain: state,
		ui:     UIState{Messages: []string{}, ActiveProcID: state.CurrentProcID},
	}
}

// subscribeToStateUpdates listens for state updates from the primary server
func (m ClientModel) subscribeToStateUpdates() tea.Cmd {
	return func() tea.Msg {
		// Block until we receive a state update
		state := <-m.client.ReceiveState()
		return clientStateUpdateMsg{state: state}
	}
}

func (m ClientModel) Init() tea.Cmd {
	return m.subscribeToStateUpdates()
}

func (m ClientModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case clientStateUpdateMsg:
		// Update our local state copy from primary
		m.domain = msg.state
		return m, m.subscribeToStateUpdates()

	case tea.WindowSizeMsg:
		m.termWidth, m.termHeight = msg.Width, msg.Height
		return m, nil

	case errMsg:
		m.ui.Messages = append(m.ui.Messages, msg.Error())
		return m, nil

	case tea.KeyMsg:
		key := msg.String()
		cfg := m.domain.Config
		kb := cfg.Keybinding

		if m.ui.EnteringFilterText {
			switch {
			case contains(kb.FilterSubmit, key):
				m.ui.EnteringFilterText = false
				m.ui.Mode = NormalMode
				m.filterSeq++
				return m, debounceFilter(m.filterSeq)
			case contains(kb.Filter, key):
				m.ui.EnteringFilterText = false
				m.ui.Mode = NormalMode
				return m, nil
			case key == "esc":
				m.ui.EnteringFilterText = false
				m.ui.Mode = NormalMode
				m.ui.FilterText = ""
				m.filterSeq++
				return m, debounceFilter(m.filterSeq)
			case key == "backspace" || key == "ctrl+h":
				if len(m.ui.FilterText) > 0 {
					m.ui.FilterText = m.ui.FilterText[:len(m.ui.FilterText)-1]
					m.filterSeq++
					return m, debounceFilter(m.filterSeq)
				}
			default:
				if len(key) == 1 {
					m.ui.FilterText += key
					m.filterSeq++
					return m, debounceFilter(m.filterSeq)
				}
			}
			return m, nil
		}

		switch {
		case contains(kb.Quit, key):
			return m, tea.Sequence(tea.ExitAltScreen, tea.Quit)
		case contains(kb.Filter, key):
			m.ui.EnteringFilterText = true
			m.ui.Mode = FilterMode
			m.ui.FilterText = ""
			m.ui.ActiveProcID = 0
			m.selectSeq++
			return m, debounceSelection(m.selectSeq, 0)
		case contains(kb.Down, key):
			m.moveSelection(+1)
			m.selectSeq++
			return m, m.sendSelectionToPrimary(m.ui.ActiveProcID)
		case contains(kb.Up, key):
			m.moveSelection(-1)
			m.selectSeq++
			return m, m.sendSelectionToPrimary(m.ui.ActiveProcID)
		case contains(kb.Start, key):
			return m, m.sendCommandToPrimary("start")
		case contains(kb.Stop, key):
			return m, m.sendCommandToPrimary("stop")
		case contains(kb.Restart, key):
			return m, m.sendCommandToPrimary("restart")
		}
		return m, nil

	case applyFilterMsg:
		if msg.seq != m.filterSeq {
			return m, nil
		}
		procs := FilterProcesses(m.domain.Config, m.domain.Processes, m.ui.FilterText)
		if len(procs) > 0 {
			m.ui.ActiveProcID = procs[0].ID
			m.selectSeq++
			return m, m.sendSelectionToPrimary(m.ui.ActiveProcID)
		}
		m.ui.ActiveProcID = 0
		m.selectSeq++
		return m, m.sendSelectionToPrimary(0)
	}
	return m, nil
}

func (m *ClientModel) moveSelection(delta int) {
	procs := FilterProcesses(m.domain.Config, m.domain.Processes, m.ui.FilterText)
	if len(procs) == 0 {
		m.ui.ActiveProcID = 0
		return
	}
	if len(procs) == 1 {
		m.ui.ActiveProcID = procs[0].ID
		return
	}
	ids := make([]int, len(procs))
	cur := -1
	for i, p := range procs {
		ids[i] = p.ID
		if p.ID == m.ui.ActiveProcID {
			cur = i
		}
	}
	if cur == -1 {
		m.ui.ActiveProcID = ids[0]
		return
	}
	ni := cur + delta
	if ni < 0 {
		ni = len(ids) - 1
	} else {
		ni = ni % len(ids)
	}
	m.ui.ActiveProcID = ids[ni]
}

// sendSelectionToPrimary sends selection change to the primary server
func (m ClientModel) sendSelectionToPrimary(procID int) tea.Cmd {
	return func() tea.Msg {
		if err := m.client.SendSelection(procID); err != nil {
			log.Printf("Failed to send selection to primary: %v", err)
			return errMsg{err}
		}
		return nil
	}
}

// sendCommandToPrimary sends a command (start/stop/restart) to the primary server
func (m ClientModel) sendCommandToPrimary(action string) tea.Cmd {
	return func() tea.Msg {
		proc := m.domain.GetProcessByID(m.ui.ActiveProcID)
		if proc == nil {
			return errMsg{fmt.Errorf("no process selected")}
		}

		var err error
		switch action {
		case "start":
			err = m.client.StartProcess(proc.Label)
		case "stop":
			err = m.client.StopProcess(proc.Label)
		case "restart":
			err = m.client.RestartProcess(proc.Label)
		default:
			err = fmt.Errorf("unknown action: %s", action)
		}

		if err != nil {
			return errMsg{err}
		}

		log.Printf("Client sent %s command for process %s", action, proc.Label)
		return nil
	}
}

func (m ClientModel) appendFilterInput(s string) string {
	if m.ui.EnteringFilterText {
		s += "\nFilter: " + m.ui.FilterText + "_\n"
	} else {
		s += "\n\n"
	}
	return s
}

func (m ClientModel) appendHelpPanel(s string) string {
	if m.domain.Config.Layout.HideHelp {
		return s
	}
	s += "\n[" + strings.Join(m.domain.Config.Keybinding.Start, "/") + "] Start  [" +
		strings.Join(m.domain.Config.Keybinding.Stop, "/") + "] Stop  [" +
		strings.Join(m.domain.Config.Keybinding.Up, "/") + "] Up  [" +
		strings.Join(m.domain.Config.Keybinding.Down, "/") + "] Down  [" +
		strings.Join(m.domain.Config.Keybinding.Filter, "/") + "] Filter  [" +
		strings.Join(m.domain.Config.Keybinding.Quit, "/") + "] Quit\n"
	s += "\n[Client Mode - Connected to Primary]\n"
	return s
}

func (m ClientModel) appendMessages(s string) string {
	if m.ui.Info != "" {
		s += "\n" + m.ui.Info + "\n"
	}
	if len(m.ui.Messages) > 0 {
		s += "\nMessages:\n"
		start := 0
		if len(m.ui.Messages) > 5 {
			start = len(m.ui.Messages) - 5
		}
		for _, msg := range m.ui.Messages[start:] {
			s += "- " + msg + "\n"
		}
	}
	return s
}

func (m ClientModel) appendProcessDescription(s string) string {
	if m.domain.Config.Layout.HideProcessDescriptionPanel {
		return s
	}
	proc := m.domain.GetProcessByID(m.ui.ActiveProcID)
	if proc == nil || proc.Config == nil || len(strings.TrimSpace(proc.Config.Description)) == 0 {
		return s
	}
	s += strings.TrimSpace(proc.Config.Description) + "\n"
	return s
}

func (m ClientModel) appendProcess(p *Process, s string) string {
	cursor := "  "
	statusColor := m.domain.Config.Style.StatusStoppedColor
	if p.Status == StatusRunning {
		statusColor = m.domain.Config.Style.StatusRunningColor
	}
	styleStart, styleEnd := colorToAnsi(statusColor)
	var processColorStart, processColorEnd string
	var bgColorStart, bgColorEnd string
	isSelected := p.ID == m.ui.ActiveProcID
	if isSelected {
		char := m.domain.Config.Style.PointerChar
		cursor = styleStart + char + " " + styleEnd
		processColorStart, processColorEnd = colorToAnsi(m.domain.Config.Style.SelectedProcessColor)
		bgColorStart, bgColorEnd = colorToBgAnsi(m.domain.Config.Style.SelectedProcessBgColor)
	} else {
		if p.Status == StatusRunning {
			cursor = styleStart + "● " + styleEnd
		} else {
			cursor = styleStart + "■ " + styleEnd
		}
		processColorStart, processColorEnd = colorToAnsi(m.domain.Config.Style.UnselectedProcessColor)
	}
	cat := ""
	if p.Config != nil && len(p.Config.Categories) > 0 && m.domain.Config.Layout.EnableDebugProcessInfo {
		cat = " [" + strings.Join(p.Config.Categories, ",") + "]"
	}
	processText := ""
	if m.domain.Config.Layout.EnableDebugProcessInfo {
		processText = fmt.Sprintf("%s [%s] PID:%d%s", p.Label, p.Status.String(), p.PID, cat)
	} else {
		processText = p.Label
	}
	styledText := bgColorStart + processColorStart + processText + processColorEnd + bgColorEnd
	s += fmt.Sprintf("%s%s\n", cursor, styledText)
	return s
}

func (m ClientModel) View() string {
	procs := FilterProcesses(m.domain.Config, m.domain.Processes, m.ui.FilterText)
	s := ""
	s = m.appendHelpPanel(s)
	s = m.appendProcessDescription(s)
	s = m.appendMessages(s)
	s = m.appendFilterInput(s)
	for _, p := range procs {
		s = m.appendProcess(p, s)
	}
	return s
}

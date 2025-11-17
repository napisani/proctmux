package proctmux

import (
	"fmt"
	"log"
	"slices"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/nick/proctmux/internal/domain"
)

// UIState holds the UI-specific state for the client TUI
type UIState struct {
	Messages           []string
	FilterText         string
	EnteringFilterText bool
	Info               string
	Mode               domain.Mode
	ActiveProcID       int
}

// errMsg wraps errors for Bubble Tea
type errMsg struct{ err error }

func (e errMsg) Error() string { return e.err.Error() }

// applyFilterMsg is sent after debounce to apply filter
type applyFilterMsg struct{ seq int }

// applySelectionMsg is sent after debounce to apply selection
type applySelectionMsg struct {
	seq    int
	procID int
}

// debounceFilter returns a command that debounces filter input
func debounceFilter(seq int) tea.Cmd {
	return tea.Tick(150*time.Millisecond, func(time.Time) tea.Msg { return applyFilterMsg{seq: seq} })
}

// debounceSelection returns a command that debounces selection changes
func debounceSelection(seq, procID int) tea.Cmd {
	return tea.Tick(120*time.Millisecond, func(time.Time) tea.Msg { return applySelectionMsg{seq: seq, procID: procID} })
}

// IPCClient interface abstracts IPC client operations
type IPCClient interface {
	ReceiveState() <-chan *domain.AppState
	ReceiveProcessViews() <-chan []domain.ProcessView
	SwitchProcess(label string) error
	StartProcess(label string) error
	StopProcess(label string) error
	RestartProcess(label string) error
}

// ClientModel is a UI-only model that connects to a primary server
type ClientModel struct {
	client       IPCClient
	domain       *domain.AppState
	processViews []domain.ProcessView
	ui           UIState
	termWidth    int
	termHeight   int
	filterSeq    int
	selectSeq    int
}

// clientStateUpdateMsg wraps state updates from primary
type clientStateUpdateMsg struct {
	state        *domain.AppState
	processViews []domain.ProcessView
}

func NewClientModel(client IPCClient, state *domain.AppState) ClientModel {
	return ClientModel{
		client:       client,
		domain:       state,
		processViews: []domain.ProcessView{},
		ui:           UIState{Messages: []string{}, ActiveProcID: state.CurrentProcID},
	}
}

// subscribeToStateUpdates listens for state updates from the primary server
func (m ClientModel) subscribeToStateUpdates() tea.Cmd {
	return func() tea.Msg {
		// Both state and processViews are sent together in the same IPC message
		// They arrive on separate buffered channels, so we can receive them in order
		state := <-m.client.ReceiveState()
		processViews := <-m.client.ReceiveProcessViews()
		return clientStateUpdateMsg{state: state, processViews: processViews}
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
		m.processViews = msg.processViews
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
			case slices.Contains(kb.FilterSubmit, key):
				m.ui.EnteringFilterText = false
				m.ui.Mode = domain.NormalMode
				m.filterSeq++
				return m, debounceFilter(m.filterSeq)
			case slices.Contains(kb.Filter, key):
				m.ui.EnteringFilterText = false
				m.ui.Mode = domain.NormalMode
				return m, nil
			case key == "esc":
				m.ui.EnteringFilterText = false
				m.ui.Mode = domain.NormalMode
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
		case slices.Contains(kb.Quit, key):
			return m, tea.Sequence(tea.ExitAltScreen, tea.Quit)
		case slices.Contains(kb.Filter, key):
			m.ui.EnteringFilterText = true
			m.ui.Mode = domain.FilterMode
			m.ui.FilterText = ""
			m.ui.ActiveProcID = 0
			m.selectSeq++
			return m, debounceSelection(m.selectSeq, 0)
		case slices.Contains(kb.Down, key):
			m.moveSelection(+1)
			m.selectSeq++
			return m, m.sendSelectionToPrimary(m.activeProcLabel())
		case slices.Contains(kb.Up, key):
			m.moveSelection(-1)
			m.selectSeq++
			return m, m.sendSelectionToPrimary(m.activeProcLabel())
		case slices.Contains(kb.Start, key):
			return m, m.sendCommandToPrimary("start")
		case slices.Contains(kb.Stop, key):
			return m, m.sendCommandToPrimary("stop")
		case slices.Contains(kb.Restart, key):
			return m, m.sendCommandToPrimary("restart")
		}
		return m, nil

	case applyFilterMsg:
		if msg.seq != m.filterSeq {
			return m, nil
		}
		procs := domain.FilterProcesses(m.domain.Config, m.processViews, m.ui.FilterText)
		if len(procs) > 0 {
			m.ui.ActiveProcID = procs[0].ID
			m.selectSeq++
			return m, m.sendSelectionToPrimary(m.activeProcLabel())
		}
		m.ui.ActiveProcID = 0
		m.selectSeq++
		return m, m.sendSelectionToPrimary("Dummy")
	}
	return m, nil
}

func (m *ClientModel) activeProcLabel() string {
	procID := m.ui.ActiveProcID
	proc := m.domain.GetProcessByID(procID)
	if proc != nil {
		return proc.Label
	}
	return ""
}

func (m *ClientModel) moveSelection(delta int) {
	procs := domain.FilterProcesses(m.domain.Config, m.processViews, m.ui.FilterText)
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
func (m ClientModel) sendSelectionToPrimary(label string) tea.Cmd {
	return func() tea.Msg {
		if err := m.client.SwitchProcess(label); err != nil {
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

func (m ClientModel) appendProcess(p *domain.ProcessView, s string) string {
	cursor := "  "
	statusColor := m.domain.Config.Style.StatusStoppedColor
	if p.Status == domain.StatusRunning {
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
		if p.Status == domain.StatusRunning {
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
	procs := domain.FilterProcesses(m.domain.Config, m.processViews, m.ui.FilterText)
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

// Helper functions for color formatting

func hexToDec(hex string) int { var dec int; fmt.Sscanf(hex, "%x", &dec); return dec }

func colorToAnsi(color string) (string, string) {
	c := strings.TrimSpace(strings.ToLower(color))
	if c == "" || c == "none" {
		return "", ""
	}
	c = strings.TrimPrefix(c, "ansi")
	c = strings.ReplaceAll(c, " ", "")
	c = strings.ReplaceAll(c, "-", "")
	c = strings.ReplaceAll(c, "_", "")
	const resetCode = "\u001b[0m"
	if strings.HasPrefix(c, "#") && len(c) == 7 {
		r := c[1:3]
		g := c[3:5]
		b := c[5:7]
		return fmt.Sprintf("\u001b[38;2;%d;%d;%dm", hexToDec(r), hexToDec(g), hexToDec(b)), resetCode
	}
	if c == "grey" || c == "gray" || c == "lightgrey" || c == "lightgray" {
		c = "brightblack"
	}
	colors := map[string]int{"black": 30, "red": 31, "green": 32, "yellow": 33, "blue": 34, "magenta": 35, "cyan": 36, "white": 37, "brightblack": 90, "brightred": 91, "brightgreen": 92, "brightyellow": 93, "brightblue": 94, "brightmagenta": 95, "brightcyan": 96, "brightwhite": 97}
	if code, ok := colors[c]; ok {
		return fmt.Sprintf("\u001b[%dm", code), resetCode
	}
	if len(c) == 6 {
		return fmt.Sprintf("\u001b[38;2;%d;%d;%dm", hexToDec(c[0:2]), hexToDec(c[2:4]), hexToDec(c[4:6])), resetCode
	}
	if len(c) == 3 {
		rr := string([]byte{c[0], c[0]})
		gg := string([]byte{c[1], c[1]})
		bb := string([]byte{c[2], c[2]})
		return fmt.Sprintf("\u001b[38;2;%d;%d;%dm", hexToDec(rr), hexToDec(gg), hexToDec(bb)), resetCode
	}
	return "", ""
}

func colorToBgAnsi(color string) (string, string) {
	c := strings.TrimSpace(strings.ToLower(color))
	if c == "" || c == "none" {
		return "", ""
	}
	c = strings.TrimPrefix(c, "ansi")
	c = strings.ReplaceAll(c, " ", "")
	c = strings.ReplaceAll(c, "-", "")
	c = strings.ReplaceAll(c, "_", "")
	const resetCode = "\u001b[0m"
	if strings.HasPrefix(c, "#") && len(c) == 7 {
		r := c[1:3]
		g := c[3:5]
		b := c[5:7]
		return fmt.Sprintf("\u001b[48;2;%d;%d;%dm", hexToDec(r), hexToDec(g), hexToDec(b)), resetCode
	}
	if c == "grey" || c == "gray" || c == "lightgrey" || c == "lightgray" {
		c = "brightblack"
	}
	colors := map[string]int{"black": 40, "red": 41, "green": 42, "yellow": 43, "blue": 44, "magenta": 45, "cyan": 46, "white": 47, "brightblack": 100, "brightred": 101, "brightgreen": 102, "brightyellow": 103, "brightblue": 104, "brightmagenta": 105, "brightcyan": 106, "brightwhite": 107}
	if code, ok := colors[c]; ok {
		return fmt.Sprintf("\u001b[%dm", code), resetCode
	}
	if len(c) == 6 {
		return fmt.Sprintf("\u001b[48;2;%d;%d;%dm", hexToDec(c[0:2]), hexToDec(c[2:4]), hexToDec(c[4:6])), resetCode
	}
	if len(c) == 3 {
		rr := string([]byte{c[0], c[0]})
		gg := string([]byte{c[1], c[1]})
		bb := string([]byte{c[2], c[2]})
		return fmt.Sprintf("\u001b[48;2;%d;%d;%dm", hexToDec(rr), hexToDec(gg), hexToDec(bb)), resetCode
	}
	return "", ""
}

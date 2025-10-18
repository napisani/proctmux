package proctmux

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

type Model struct {
	controller     *Controller
	domain         *AppState
	ui             UIState
	termWidth      int
	termHeight     int
	stateUpdateSub chan StateUpdateMsg

	filterSeq int
	selectSeq int
}

func NewModel(state *AppState, controller *Controller) Model {
	model := Model{
		domain:         state,
		controller:     controller,
		stateUpdateSub: make(chan StateUpdateMsg),
		ui:             UIState{Messages: []string{}, ActiveProcID: state.CurrentProcID},
	}
	controller.SubscribeToStateChanges(model.stateUpdateSub)
	return model
}

// subscribeToStateUpdates returns a command that listens for state updates
func (m Model) subscribeToStateUpdates() tea.Cmd {
	return func() tea.Msg { return <-m.stateUpdateSub }
}

func (m Model) Init() tea.Cmd { return tea.Batch(m.subscribeToStateUpdates()) }

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case StateUpdateMsg:
		m.domain = msg.State
		return m, m.subscribeToStateUpdates()
	case tea.WindowSizeMsg:
		m.termWidth, m.termHeight = msg.Width, msg.Height
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
			_ = m.controller.OnKeypressQuit()
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
			return m, debounceSelection(m.selectSeq, m.ui.ActiveProcID)
		case contains(kb.Up, key):
			m.moveSelection(-1)
			m.selectSeq++
			return m, debounceSelection(m.selectSeq, m.ui.ActiveProcID)
		case contains(kb.Start, key):
			_ = m.controller.OnKeypressStart()
		case contains(kb.Stop, key):
			_ = m.controller.OnKeypressStop()
		case contains(kb.Restart, key):
			_ = m.controller.OnKeypressRestart()
		case contains(kb.Docs, key):
			_ = m.controller.OnKeypressDocs()
		case key == "enter":
			_ = m.controller.OnKeypressSwitchFocus()
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
			return m, debounceSelection(m.selectSeq, m.ui.ActiveProcID)
		}
		m.ui.ActiveProcID = 0
		m.selectSeq++
		return m, debounceSelection(m.selectSeq, 0)

	case applySelectionMsg:
		if msg.seq != m.selectSeq {
			return m, nil
		}
		_ = m.controller.ApplySelection(msg.procID)
		return m, nil
	}
	return m, nil
}

func (m *Model) moveSelection(delta int) {
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

func (m Model) appendFilterInput(s string) string {
	if m.ui.EnteringFilterText {
		s += "\nFilter: " + m.ui.FilterText + "_\n"
	} else {
		s += "\n\n"
	}
	return s
}

func (m Model) appendHelpPanel(s string) string {
	if m.domain.Config.Layout.HideHelp {
		return s
	}
	s += "\n[" + strings.Join(m.domain.Config.Keybinding.Start, "/") + "] Start  [" +
		strings.Join(m.domain.Config.Keybinding.Stop, "/") + "] Stop  [" +
		strings.Join(m.domain.Config.Keybinding.Up, "/") + "] Up  [" +
		strings.Join(m.domain.Config.Keybinding.Down, "/") + "] Down  [" +
		strings.Join(m.domain.Config.Keybinding.Filter, "/") + "] Filter  [" +
		strings.Join(m.domain.Config.Keybinding.Quit, "/") + "] Quit\n"
	return s
}

func (m Model) appendMessages(s string) string {
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

func (m Model) appendProcessDescription(s string) string {
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

func hexToDec(hex string) int { var dec int; fmt.Sscanf(hex, "%x", &dec); return dec }

// color helpers and appendProcess remain largely unchanged

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

func (m Model) appendProcess(p *Process, s string) string {
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
		processText = fmt.Sprintf("%s [%s] PID:%d%s (Pane: %s)", p.Label, p.Status.String(), p.PID, cat, p.PaneID)
	} else {
		processText = p.Label
	}
	styledText := bgColorStart + processColorStart + processText + processColorEnd + bgColorEnd
	s += fmt.Sprintf("%s%s\n", cursor, styledText)
	return s
}

func (m Model) View() string {
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

package proctmux

import (
	"fmt"
	"slices"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

type Model struct {
	controller     *Controller
	state          *AppState
	termWidth      int
	termHeight     int
	stateUpdateSub chan StateUpdateMsg
}

func NewModel(state *AppState, controller *Controller) Model {
	model := Model{
		state:          state,
		controller:     controller,
		stateUpdateSub: make(chan StateUpdateMsg),
	}

	// Register the model's channel with the controller
	controller.SubscribeToStateChanges(model.stateUpdateSub)

	return model
}

// subscribeToStateUpdates returns a command that listens for state updates
func (m Model) subscribeToStateUpdates() tea.Cmd {
	return func() tea.Msg {
		return <-m.stateUpdateSub
	}
}

func (m Model) Init() tea.Cmd {
	return tea.Batch(
		m.subscribeToStateUpdates(),
	)
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case StateUpdateMsg:
		// Update the model's state with the new state
		m.state = msg.State
		// Re-subscribe to keep getting updates
		return m, m.subscribeToStateUpdates()

	case tea.WindowSizeMsg:
		m.termWidth = msg.Width
		m.termHeight = msg.Height
		return m, nil
	case tea.KeyMsg:
		key := msg.String()
		cfg := m.state.Config
		kb := cfg.Keybinding

		if m.state.GUIState.EnteringFilterText {
			if contains(kb.FilterSubmit, key) {
				m.controller.OnFilterDone()
				_ = m.controller.LockAndLoad(func(state *AppState) (*AppState, error) {
					gui := NewGUIStateMutation(&state.GUIState).
						SetMode(NormalMode).
						Commit()
					newState := NewStateMutation(state).SetGUIState(gui).Commit()
					return newState, nil
				})
			} else if contains(kb.Filter, key) {
				m.controller.OnFilterDone()
			} else if key == "backspace" || key == "ctrl+h" {
				if len(m.state.GUIState.FilterText) > 0 {
					m.controller.OnFilterSet(m.state.GUIState.FilterText[:len(m.state.GUIState.FilterText)-1])
				}
			} else if len(key) == 1 {
				m.controller.OnFilterSet(m.state.GUIState.FilterText + key)
			}
			return m, nil
		}

		if contains(kb.Quit, key) {
			m.controller.OnKeypressQuit()
			return m, tea.Sequence(tea.ExitAltScreen, tea.Quit)
		}
		if contains(kb.Down, key) {
			m.controller.OnKeypressDown()
		}
		if contains(kb.Up, key) {
			m.controller.OnKeypressUp()
		}
		if contains(kb.Start, key) {
			m.controller.OnKeypressStart()
		}
		if contains(kb.Stop, key) {
			m.controller.OnKeypressStop()
		}
		if contains(kb.Filter, key) {
			m.controller.OnFilterStart()
			_ = m.controller.LockAndLoad(func(state *AppState) (*AppState, error) {
				gui := NewGUIStateMutation(&state.GUIState).
					SetMode(FilterMode).
					Commit()
				newState := NewStateMutation(state).SetGUIState(gui).Commit()
				return newState, nil
			})
		}
		if contains(kb.Docs, key) {
			_ = m.controller.OnKeypressDocs()
		}
		if key == "enter" {
			m.controller.OnKeypressSwitchFocus()
		}
	}
	return m, nil
}

func (m Model) appendFilterInput(s string) string {
	if m.state.GUIState.EnteringFilterText {
		s += "\nFilter: " + m.state.GUIState.FilterText + "_\n"
	} else {
		s += "\n\n"
	}
	return s
}

func (m Model) appendHelpPanel(s string) string {
	if m.state.Config.Layout.HideHelp {
		return s
	}

	s += "\n[" + strings.Join(m.state.Config.Keybinding.Start, "/") + "] Start  [" +
		strings.Join(m.state.Config.Keybinding.Stop, "/") + "] Stop  [" +
		strings.Join(m.state.Config.Keybinding.Up, "/") + "] Up  [" +
		strings.Join(m.state.Config.Keybinding.Down, "/") + "] Down  [" +
		strings.Join(m.state.Config.Keybinding.Filter, "/") + "] Filter  [" +
		strings.Join(m.state.Config.Keybinding.Quit, "/") + "] Quit\n"
	return s
}

func (m Model) appendMessages(s string) string {
	if m.state.GUIState.Info != "" {
		s += "\n" + m.state.GUIState.Info + "\n"
	}
	if len(m.state.GUIState.Messages) > 0 {
		s += "\nMessages:\n"
		start := 0
		if len(m.state.GUIState.Messages) > 5 {
			start = len(m.state.GUIState.Messages) - 5
		}
		for _, msg := range m.state.GUIState.Messages[start:] {
			s += "- " + msg + "\n"
		}
	}
	return s
}

func (m Model) appendProcessDescription(s string) string {
	if m.state.Config.Layout.HideProcessDescriptionPanel {
		return s
	}
	proc := m.state.GetCurrentProcess()
	if proc == nil || proc.Config == nil || len(strings.TrimSpace(proc.Config.Description)) == 0 {
		return s
	}
	s += strings.TrimSpace(proc.Config.Description) + "\n"
	return s

}

func hexToDec(hex string) int {
	var dec int
	fmt.Sscanf(hex, "%x", &dec)
	return dec
}

// returns ANSI color codes and reset code for the given color
// colors can be provided in hex (e.g. #ff0000) or as standard color names (e.g. red)
func colorToAnsi(color string) (string, string) {
	c := strings.TrimSpace(strings.ToLower(color))
	if c == "" || c == "none" {
		return "", ""
	}

	// Normalize common config styles like "ansired", "ansi-red", "ansi red",
	// and collapse separators so we end up with e.g. "brightmagenta".
	c = strings.TrimPrefix(c, "ansi")
	c = strings.ReplaceAll(c, " ", "")
	c = strings.ReplaceAll(c, "-", "")
	c = strings.ReplaceAll(c, "_", "")

	// Standard reset code
	const resetCode = "\u001b[0m"

	// 24-bit hex colors: #rrggbb
	if strings.HasPrefix(c, "#") && len(c) == 7 {
		r := c[1:3]
		g := c[3:5]
		b := c[5:7]
		return fmt.Sprintf("\u001b[38;2;%d;%d;%dm", hexToDec(r), hexToDec(g), hexToDec(b)), resetCode
	}

	// Map common greys to brightblack
	if c == "grey" || c == "gray" || c == "lightgrey" || c == "lightgray" {
		c = "brightblack"
	}

	// Standard color names (foreground)
	colors := map[string]int{
		"black":         30,
		"red":           31,
		"green":         32,
		"yellow":        33,
		"blue":          34,
		"magenta":       35,
		"cyan":          36,
		"white":         37,
		"brightblack":   90,
		"brightred":     91,
		"brightgreen":   92,
		"brightyellow":  93,
		"brightblue":    94,
		"brightmagenta": 95,
		"brightcyan":    96,
		"brightwhite":   97,
	}
	if code, ok := colors[c]; ok {
		return fmt.Sprintf("\u001b[%dm", code), resetCode
	}

	// Fallback: 6-digit hex without '#'
	if len(c) == 6 {
		return fmt.Sprintf("\u001b[38;2;%d;%d;%dm", hexToDec(c[0:2]), hexToDec(c[2:4]), hexToDec(c[4:6])), resetCode
	}
	// Fallback: 3-digit hex without '#'
	if len(c) == 3 {
		rr := string([]byte{c[0], c[0]})
		gg := string([]byte{c[1], c[1]})
		bb := string([]byte{c[2], c[2]})
		return fmt.Sprintf("\u001b[38;2;%d;%d;%dm", hexToDec(rr), hexToDec(gg), hexToDec(bb)), resetCode
	}

	// Not recognized
	return "", ""
}

// returns ANSI background color codes and reset code for the given color
func colorToBgAnsi(color string) (string, string) {
	c := strings.TrimSpace(strings.ToLower(color))
	if c == "" || c == "none" {
		return "", ""
	}

	// Normalize common config styles like "ansired", "ansi-red", "ansi red",
	// and collapse separators so we end up with e.g. "brightmagenta".
	c = strings.TrimPrefix(c, "ansi")
	c = strings.ReplaceAll(c, " ", "")
	c = strings.ReplaceAll(c, "-", "")
	c = strings.ReplaceAll(c, "_", "")

	// Standard reset code
	const resetCode = "\u001b[0m"

	// 24-bit hex colors: #rrggbb
	if strings.HasPrefix(c, "#") && len(c) == 7 {
		r := c[1:3]
		g := c[3:5]
		b := c[5:7]
		return fmt.Sprintf("\u001b[48;2;%d;%d;%dm", hexToDec(r), hexToDec(g), hexToDec(b)), resetCode
	}

	// Map common greys to brightblack
	if c == "grey" || c == "gray" || c == "lightgrey" || c == "lightgray" {
		c = "brightblack"
	}

	// Standard color names (background)
	colors := map[string]int{
		"black":         40,
		"red":           41,
		"green":         42,
		"yellow":        43,
		"blue":          44,
		"magenta":       45,
		"cyan":          46,
		"white":         47,
		"brightblack":   100,
		"brightred":     101,
		"brightgreen":   102,
		"brightyellow":  103,
		"brightblue":    104,
		"brightmagenta": 105,
		"brightcyan":    106,
		"brightwhite":   107,
	}
	if code, ok := colors[c]; ok {
		return fmt.Sprintf("\u001b[%dm", code), resetCode
	}

	// Fallback: 6-digit hex without '#'
	if len(c) == 6 {
		return fmt.Sprintf("\u001b[48;2;%d;%d;%dm", hexToDec(c[0:2]), hexToDec(c[2:4]), hexToDec(c[4:6])), resetCode
	}
	// Fallback: 3-digit hex without '#'
	if len(c) == 3 {
		rr := string([]byte{c[0], c[0]})
		gg := string([]byte{c[1], c[1]})
		bb := string([]byte{c[2], c[2]})
		return fmt.Sprintf("\u001b[48;2;%d;%d;%dm", hexToDec(rr), hexToDec(gg), hexToDec(bb)), resetCode
	}

	// Not recognized
	return "", ""
}

func contains(slice []string, s string) bool {
	return slices.Contains(slice, s)
}

func (m Model) appendProcess(p *Process, s string) string {
	cursor := "  "

	statusColor := m.state.Config.Style.StatusStoppedColor
	if p.Status == StatusRunning {
		statusColor = m.state.Config.Style.StatusRunningColor
	}
	styleStart, styleEnd := colorToAnsi(statusColor)

	var processColorStart, processColorEnd string
	var bgColorStart, bgColorEnd string

	isSelected := p.ID == m.state.CurrentProcID

	if isSelected {
		char := m.state.Config.Style.PointerChar
		cursor = styleStart + char + " " + styleEnd
		processColorStart, processColorEnd = colorToAnsi(m.state.Config.Style.SelectedProcessColor)
		bgColorStart, bgColorEnd = colorToBgAnsi(m.state.Config.Style.SelectedProcessBgColor)
	} else {
		if p.Status == StatusRunning {
			cursor = styleStart + "● " + styleEnd
		} else {
			cursor = styleStart + "■ " + styleEnd
		}
		processColorStart, processColorEnd = colorToAnsi(m.state.Config.Style.UnselectedProcessColor)
	}

	cat := ""
	if p.Config != nil && len(p.Config.Categories) > 0 && m.state.Config.Layout.EnableDebugProcessInfo {
		cat = " [" + strings.Join(p.Config.Categories, ",") + "]"
	}

	processText := ""
	if m.state.Config.Layout.EnableDebugProcessInfo {
		processText = fmt.Sprintf("%s [%s] PID:%d%s (Pane: %s)", p.Label, p.Status.String(), p.PID, cat, p.PaneID)
	} else {
		processText = p.Label
	}

	// Apply combined styling
	styledText := bgColorStart + processColorStart + processText + processColorEnd + bgColorEnd
	s += fmt.Sprintf("%s%s\n", cursor, styledText)

	return s
}

func (m Model) View() string {
	procs := m.state.GetFilteredProcesses()
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

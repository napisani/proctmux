package tui

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/taigrr/bubbleterm/emulator"
)

const (
	unifiedStatusLines  = 1
	unifiedClientRatio  = 55 // percentage fallback for client pane
	unifiedPollInterval = 75 * time.Millisecond
	minClientWidth      = 24
	minTerminalWidth    = 32
	clientWidthPadding  = 6
)

type focusPane int

const (
	focusClient focusPane = iota
	focusServer
)

type terminalFrameMsg struct {
	rows   []string
	exited bool
}

// UnifiedModel composes the existing client TUI with a virtual terminal that
// hosts the embedded primary server.
type UnifiedModel struct {
	clientModel tea.Model
	emu         *emulator.Emulator

	focus        focusPane
	pollInterval time.Duration

	toggleFocus      key.Binding
	toggleFocusLabel string
	focusClient      key.Binding
	focusServer      key.Binding
	focusClientLabel string
	focusServerLabel string

	terminalRows   []string
	terminalExited bool

	statusHeight  int
	contentHeight int
	leftWidth     int
	rightWidth    int
}

// NewUnifiedModel constructs a unified TUI model from an existing client model
// and an initialized bubbleterm emulator.
func NewUnifiedModel(client ClientModel, emu *emulator.Emulator) UnifiedModel {
	toggleFocus := client.keys.ToggleFocus
	toggleLabel := joinKeys(toggleFocus.Keys())

	focusClientBinding := client.keys.FocusClient
	focusServerBinding := client.keys.FocusServer
	focusClientLabel := joinKeys(focusClientBinding.Keys())
	focusServerLabel := joinKeys(focusServerBinding.Keys())

	return UnifiedModel{
		clientModel:      client,
		emu:              emu,
		focus:            focusClient,
		pollInterval:     unifiedPollInterval,
		toggleFocus:      toggleFocus,
		toggleFocusLabel: toggleLabel,
		focusClient:      focusClientBinding,
		focusServer:      focusServerBinding,
		focusClientLabel: focusClientLabel,
		focusServerLabel: focusServerLabel,
		statusHeight:     unifiedStatusLines,
	}
}

func (m UnifiedModel) Init() tea.Cmd {
	var cmds []tea.Cmd
	if m.clientModel != nil {
		if cmd := m.clientModel.Init(); cmd != nil {
			cmds = append(cmds, cmd)
		}
	}
	if m.emu != nil {
		cmds = append(cmds, m.pollTerminal())
	}
	return tea.Batch(cmds...)
}

func (m UnifiedModel) pollTerminal() tea.Cmd {
	if m.emu == nil {
		return nil
	}
	return tea.Tick(m.pollInterval, func(time.Time) tea.Msg {
		frame := m.emu.GetScreen()
		rows := make([]string, len(frame.Rows))
		copy(rows, frame.Rows)
		return terminalFrameMsg{rows: rows, exited: m.emu.IsProcessExited()}
	})
}

func (m UnifiedModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		return m.handleResize(msg)
	case tea.KeyMsg:
		return m.handleKeyMsg(msg)
	case terminalFrameMsg:
		m.terminalRows = msg.rows
		m.terminalExited = msg.exited
		return m, m.pollTerminal()
	default:
		return m.forwardToClient(msg)
	}
}

func (m UnifiedModel) handleResize(msg tea.WindowSizeMsg) (tea.Model, tea.Cmd) {
	if msg.Width <= 0 || msg.Height <= 0 {
		return m, nil
	}

	statusLines := unifiedStatusLines
	if msg.Height <= unifiedStatusLines+1 {
		statusLines = 0
	}
	m.statusHeight = statusLines

	contentHeight := msg.Height - statusLines
	if contentHeight < 0 {
		contentHeight = 0
	}
	m.contentHeight = contentHeight

	leftWidth := m.desiredClientWidth(msg.Width)
	if leftWidth <= 0 {
		leftWidth = (msg.Width * unifiedClientRatio) / 100
	}
	if leftWidth >= msg.Width {
		leftWidth = msg.Width / 2
	}
	m.leftWidth = leftWidth
	m.rightWidth = msg.Width - leftWidth
	if m.rightWidth < 0 {
		m.rightWidth = 0
	}

	if m.clientModel != nil {
		childMsg := tea.WindowSizeMsg{Width: leftWidth, Height: contentHeight}
		var cmd tea.Cmd
		m.clientModel, cmd = m.clientModel.Update(childMsg)
		if cmd != nil {
			if m.emu != nil {
				_ = m.emu.Resize(max(1, m.rightWidth), max(1, m.contentHeight))
			}
			return m, cmd
		}
	}

	if m.emu != nil {
		_ = m.emu.Resize(max(1, m.rightWidth), max(1, m.contentHeight))
	}

	return m, nil
}

func (m UnifiedModel) handleKeyMsg(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if len(m.toggleFocus.Keys()) > 0 && key.Matches(msg, m.toggleFocus) {
		if m.focus == focusClient {
			m.focus = focusServer
		} else {
			m.focus = focusClient
		}
		return m, nil
	}

	if len(m.focusClient.Keys()) > 0 && key.Matches(msg, m.focusClient) {
		m.focus = focusClient
		return m, nil
	}
	if len(m.focusServer.Keys()) > 0 && key.Matches(msg, m.focusServer) {
		m.focus = focusServer
		return m, nil
	}

	switch msg.String() {
	case "ctrl+right":
		m.focus = focusServer
		return m, nil
	case "ctrl+left":
		m.focus = focusClient
		return m, nil
	}

	if m.focus == focusServer {
		if m.emu != nil {
			if input := keyMsgToTerminalInput(msg); input != "" {
				_, _ = m.emu.Write([]byte(input))
			}
		}
		return m, nil
	}

	return m.forwardToClient(msg)
}

func (m UnifiedModel) forwardToClient(msg tea.Msg) (tea.Model, tea.Cmd) {
	if m.clientModel == nil {
		return m, nil
	}

	var cmd tea.Cmd
	m.clientModel, cmd = m.clientModel.Update(msg)
	return m, cmd
}

func (m UnifiedModel) View() string {
	leftView := ""
	if m.clientModel != nil {
		leftView = m.clientModel.View()
	}

	rightView := ""
	if len(m.terminalRows) > 0 {
		rightView = strings.Join(m.terminalRows, "\n")
	} else if m.focus == focusServer {
		rightView = "Connecting to embedded server..."
	}

	leftStyle := lipgloss.NewStyle().Width(max(m.leftWidth, 0)).Height(max(m.contentHeight, 0))
	rightStyle := lipgloss.NewStyle().Width(max(m.rightWidth, 0)).Height(max(m.contentHeight, 0))

	split := lipgloss.JoinHorizontal(
		lipgloss.Top,
		leftStyle.Render(leftView),
		rightStyle.Render(rightView),
	)

	status := m.statusBar()
	if status == "" {
		return split
	}

	return lipgloss.JoinVertical(lipgloss.Left, split, status)
}

func (m UnifiedModel) statusBar() string {
	totalWidth := m.leftWidth + m.rightWidth
	if totalWidth <= 0 || m.statusHeight == 0 {
		return ""
	}

	focusStyle := lipgloss.NewStyle().Bold(true)
	blurStyle := lipgloss.NewStyle().Faint(true)

	clientLabel := blurStyle.Render("Client")
	serverLabel := blurStyle.Render("Server")
	if m.focus == focusClient {
		clientLabel = focusStyle.Render("Client")
	} else {
		serverLabel = focusStyle.Render("Server")
	}

	instructionParts := []string{"ctrl+left focus client", "ctrl+right focus server"}
	if m.toggleFocusLabel != "" {
		instructionParts = append(instructionParts, fmt.Sprintf("%s toggle focus", m.toggleFocusLabel))
	}

	var instructionText string
	if len(instructionParts) > 0 {
		instructionText = lipgloss.NewStyle().Faint(true).Render(strings.Join(instructionParts, " • "))
	}

	statusParts := []string{clientLabel, serverLabel}
	if m.terminalExited {
		statusParts = append(statusParts, lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Render("server exited"))
	}

	content := fmt.Sprintf("%s | %s", statusParts[0], statusParts[1])
	if instructionText != "" {
		content += "    " + instructionText
	}
	if len(statusParts) > 2 {
		content += "    " + statusParts[2]
	}

	return lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Left).Render(content)
}

func (m UnifiedModel) desiredClientWidth(totalWidth int) int {
	longest := m.longestProcessNameWidth()
	desired := longest + clientWidthPadding
	if desired < minClientWidth {
		desired = minClientWidth
	}

	if totalWidth <= minClientWidth+minTerminalWidth {
		if totalWidth <= 0 {
			return desired
		}
		fallback := totalWidth / 2
		if fallback < minClientWidth {
			fallback = minClientWidth
		}
		if fallback > totalWidth {
			fallback = totalWidth
		}
		return fallback
	}

	maxAllowed := totalWidth - minTerminalWidth
	if maxAllowed < minClientWidth {
		maxAllowed = totalWidth / 2
	}
	if desired > maxAllowed {
		desired = maxAllowed
	}
	if desired < minClientWidth {
		desired = minClientWidth
	}
	if desired > totalWidth {
		desired = totalWidth
	}
	return desired
}

func (m UnifiedModel) longestProcessNameWidth() int {
	switch cm := m.clientModel.(type) {
	case ClientModel:
		return longestProcessNameWidthFromClient(cm)
	case *ClientModel:
		return longestProcessNameWidthFromClient(*cm)
	default:
		return 0
	}
}

func longestProcessNameWidthFromClient(client ClientModel) int {
	maxWidth := 0
	for _, view := range client.processViews {
		if w := lipgloss.Width(view.Label); w > maxWidth {
			maxWidth = w
		}
	}

	if maxWidth == 0 && client.domain != nil {
		for _, proc := range client.domain.Processes {
			if w := lipgloss.Width(proc.Label); w > maxWidth {
				maxWidth = w
			}
		}
	}

	return maxWidth
}

func keyMsgToTerminalInput(msg tea.KeyMsg) string {
	switch msg.String() {
	case "enter":
		return "\r"
	case "tab":
		return "\t"
	case "backspace":
		return "\b"
	case "delete":
		return "\x7f"
	case "esc":
		return "\x1b"
	case " ":
		return " "
	case "up":
		return "\x1b[A"
	case "down":
		return "\x1b[B"
	case "right":
		return "\x1b[C"
	case "left":
		return "\x1b[D"
	case "home":
		return "\x1b[H"
	case "end":
		return "\x1b[F"
	case "pageup":
		return "\x1b[5~"
	case "pagedown":
		return "\x1b[6~"
	case "insert":
		return "\x1b[2~"
	case "f1":
		return "\x1bOP"
	case "f2":
		return "\x1bOQ"
	case "f3":
		return "\x1bOR"
	case "f4":
		return "\x1bOS"
	case "f5":
		return "\x1b[15~"
	case "f6":
		return "\x1b[17~"
	case "f7":
		return "\x1b[18~"
	case "f8":
		return "\x1b[19~"
	case "f9":
		return "\x1b[20~"
	case "f10":
		return "\x1b[21~"
	case "f11":
		return "\x1b[23~"
	case "f12":
		return "\x1b[24~"
	case "ctrl+c":
		return "\x03"
	case "ctrl+d":
		return "\x04"
	case "ctrl+z":
		return "\x1a"
	case "ctrl+l":
		return "\x0c"
	default:
		str := msg.String()
		if len(str) == 1 {
			return str
		}
		return ""
	}
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

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
	minClientHeight     = 8
	minTerminalHeight   = 10
)

type SplitOrientation int

const (
	SplitLeft SplitOrientation = iota
	SplitRight
	SplitTop
	SplitBottom
)

type focusPane int

const (
	paneClient focusPane = iota
	paneServer
)

type terminalFrameMsg struct {
	rows   []string
	exited bool
}

// SplitPaneModel composes the existing client TUI with a virtual terminal that
// hosts the embedded primary server.
type SplitPaneModel struct {
	clientModel tea.Model
	emu         *emulator.Emulator

	focus        focusPane
	pollInterval time.Duration

	keys             focusKeys
	toggleFocusLabel string
	focusClientLabel string
	focusServerLabel string

	orientation SplitOrientation

	terminalRows   []string
	terminalExited bool

	statusHeight  int
	contentWidth  int
	contentHeight int
	clientWidth   int
	serverWidth   int
	clientHeight  int
	serverHeight  int
}

// NewSplitPaneModel constructs a split-pane TUI model from an existing client
// model and an initialized bubbleterm emulator.
func NewSplitPaneModel(client ClientModel, emu *emulator.Emulator, orientation SplitOrientation) SplitPaneModel {
	fk := newFocusKeys(client.keys)

	return SplitPaneModel{
		clientModel:      client,
		emu:              emu,
		focus:            paneClient,
		pollInterval:     unifiedPollInterval,
		keys:             fk,
		toggleFocusLabel: joinKeys(fk.toggle.Keys()),
		focusClientLabel: joinKeys(fk.client.Keys()),
		focusServerLabel: joinKeys(fk.server.Keys()),
		orientation:      orientation,
		statusHeight:     unifiedStatusLines,
	}
}

func (m SplitPaneModel) Init() tea.Cmd {
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

func (m SplitPaneModel) pollTerminal() tea.Cmd {
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

func (m SplitPaneModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
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

func (m SplitPaneModel) handleResize(msg tea.WindowSizeMsg) (tea.Model, tea.Cmd) {
	if msg.Width <= 0 || msg.Height <= 0 {
		return m, nil
	}

	statusLines := unifiedStatusLines
	if msg.Height <= unifiedStatusLines+1 {
		statusLines = 0
	}
	m.statusHeight = statusLines

	m.contentWidth = msg.Width
	contentHeight := max(msg.Height-statusLines, 0)
	m.contentHeight = contentHeight

	var clientCmd tea.Cmd

	switch m.orientation {
	case SplitLeft, SplitRight:
		clientWidth := m.desiredClientWidth(msg.Width)
		if clientWidth <= 0 {
			clientWidth = (msg.Width * unifiedClientRatio) / 100
		}
		if clientWidth < minClientWidth && msg.Width >= minClientWidth {
			clientWidth = minClientWidth
		}
		if clientWidth >= msg.Width {
			clientWidth = msg.Width / 2
		}

		serverWidth := msg.Width - clientWidth
		if serverWidth < minTerminalWidth && msg.Width >= minClientWidth+minTerminalWidth {
			serverWidth = minTerminalWidth
			clientWidth = msg.Width - serverWidth
		}
		if serverWidth < 0 {
			serverWidth = 0
			clientWidth = msg.Width
		}

		m.clientWidth = clientWidth
		m.serverWidth = serverWidth
		m.clientHeight = contentHeight
		m.serverHeight = contentHeight

		if m.clientModel != nil {
			childMsg := tea.WindowSizeMsg{Width: clientWidth, Height: contentHeight}
			m.clientModel, clientCmd = m.clientModel.Update(childMsg)
		}
		if m.emu != nil {
			_ = m.emu.Resize(max(1, serverWidth), max(1, contentHeight))
		}

	case SplitTop, SplitBottom:
		clientHeight := m.desiredClientHeight(contentHeight)
		if clientHeight <= 0 {
			clientHeight = (contentHeight * unifiedClientRatio) / 100
		}
		if clientHeight < minClientHeight && contentHeight >= minClientHeight {
			clientHeight = minClientHeight
		}
		if clientHeight >= contentHeight {
			clientHeight = contentHeight / 2
		}

		serverHeight := contentHeight - clientHeight
		if serverHeight < minTerminalHeight && contentHeight >= minClientHeight+minTerminalHeight {
			serverHeight = minTerminalHeight
			clientHeight = contentHeight - serverHeight
		}
		if serverHeight < 0 {
			serverHeight = 0
		}

		m.clientWidth = msg.Width
		m.serverWidth = msg.Width
		m.clientHeight = clientHeight
		m.serverHeight = serverHeight

		if m.clientModel != nil {
			childMsg := tea.WindowSizeMsg{Width: msg.Width, Height: clientHeight}
			m.clientModel, clientCmd = m.clientModel.Update(childMsg)
		}
		if m.emu != nil {
			_ = m.emu.Resize(max(1, msg.Width), max(1, serverHeight))
		}
	default:
		// fallback to left layout if unset
		m.orientation = SplitLeft
		return m.handleResize(msg)
	}

	return m, clientCmd
}

func (m SplitPaneModel) handleKeyMsg(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if len(m.keys.toggle.Keys()) > 0 && key.Matches(msg, m.keys.toggle) {
		if m.focus == paneClient {
			m.focus = paneServer
		} else {
			m.focus = paneClient
		}
		return m, nil
	}

	if len(m.keys.client.Keys()) > 0 && key.Matches(msg, m.keys.client) {
		m.focus = paneClient
		return m, nil
	}
	if len(m.keys.server.Keys()) > 0 && key.Matches(msg, m.keys.server) {
		m.focus = paneServer
		return m, nil
	}

	switch msg.String() {
	case "ctrl+right":
		m.focus = paneServer
		return m, nil
	case "ctrl+left":
		m.focus = paneClient
		return m, nil
	}

	if m.focus == paneServer {
		if m.emu != nil {
			if input := keyMsgToTerminalInput(msg); input != "" {
				_, _ = m.emu.Write([]byte(input))
			}
		}
		return m, nil
	}

	return m.forwardToClient(msg)
}

func (m SplitPaneModel) forwardToClient(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	m.clientModel, cmd = forwardMsgToChild(m.clientModel, msg)
	return m, cmd
}

func (m SplitPaneModel) View() string {
	clientView := ""
	if m.clientModel != nil {
		clientView = m.clientModel.View()
	}

	serverView := ""
	if len(m.terminalRows) > 0 {
		serverView = strings.Join(m.terminalRows, "\n")
	} else if m.focus == paneServer {
		serverView = "Connecting to embedded server..."
	}

	clientStyle := lipgloss.NewStyle().Width(max(m.clientWidth, 0)).Height(max(m.clientHeight, 0))
	serverStyle := lipgloss.NewStyle().Width(max(m.serverWidth, 0)).Height(max(m.serverHeight, 0))

	var layout string
	switch m.orientation {
	case SplitRight:
		layout = lipgloss.JoinHorizontal(
			lipgloss.Top,
			serverStyle.Render(serverView),
			clientStyle.Render(clientView),
		)
	case SplitTop:
		layout = lipgloss.JoinVertical(
			lipgloss.Left,
			clientStyle.Render(clientView),
			serverStyle.Render(serverView),
		)
	case SplitBottom:
		layout = lipgloss.JoinVertical(
			lipgloss.Left,
			serverStyle.Render(serverView),
			clientStyle.Render(clientView),
		)
	default:
		layout = lipgloss.JoinHorizontal(
			lipgloss.Top,
			clientStyle.Render(clientView),
			serverStyle.Render(serverView),
		)
	}

	status := m.statusBar()
	if status == "" {
		return layout
	}

	return lipgloss.JoinVertical(lipgloss.Left, layout, status)
}

func (m SplitPaneModel) statusBar() string {
	totalWidth := m.contentWidth
	if totalWidth <= 0 {
		totalWidth = max(m.clientWidth, m.serverWidth)
	}
	if totalWidth <= 0 || m.statusHeight == 0 {
		return ""
	}

	focusStyle := lipgloss.NewStyle().Bold(true)
	blurStyle := lipgloss.NewStyle().Faint(true)

	clientLabel := blurStyle.Render("Client")
	serverLabel := blurStyle.Render("Server")
	if m.focus == paneClient {
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

func (m SplitPaneModel) desiredClientWidth(totalWidth int) int {
	longest := m.longestProcessNameWidth()
	desired := max(longest+clientWidthPadding, minClientWidth)

	if totalWidth <= minClientWidth+minTerminalWidth {
		if totalWidth <= 0 {
			return desired
		}
		fallback := min(max(totalWidth/2, minClientWidth), totalWidth)
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

func (m SplitPaneModel) desiredClientHeight(totalHeight int) int {
	desired := min(max((totalHeight*unifiedClientRatio)/100, minClientHeight), totalHeight-minTerminalHeight)
	if desired <= 0 {
		desired = totalHeight / 2
	}
	return desired
}

func (m SplitPaneModel) longestProcessNameWidth() int {
	client := asClientModel(m.clientModel)
	if client == nil {
		return 0
	}
	return longestProcessNameWidthFromClient(*client)
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

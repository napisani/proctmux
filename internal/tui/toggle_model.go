package tui

import (
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/process"
)

const (
	togglePollInterval = 50 * time.Millisecond
	toggleStatusLines  = 1

	// maxScrollbackLines is the maximum number of lines kept in scrollbackContent.
	// Capping this prevents the string from growing without bound over a long-lived
	// process session, which was causing increasingly expensive tailLines() calls and
	// full-screen re-renders on every 50ms poll tick (Bug 1).
	maxScrollbackLines = 5000
)

// scrollbackPollMsg triggers polling the ring buffer reader channel.
type scrollbackPollMsg struct{}

// ToggleViewModel is a Bubble Tea model that toggles between the process
// list (ClientModel) and a raw scrollback view of the selected process.
// It runs in-process with the PrimaryServer — no terminal emulator needed.
//
// Keybindings reuse the existing unified-mode bindings:
//   - ToggleFocus (default ctrl+w): toggle between process list and scrollback
//   - FocusClient (default ctrl+left): switch to process list
//   - FocusServer (default ctrl+right): switch to scrollback
type ToggleViewModel struct {
	clientModel       tea.Model
	processController *process.Controller
	cfg               *config.ProcTmuxConfig

	showingProcessList bool
	keys               focusKeys

	// scrollback state
	scrollbackContent   string
	readerID            int
	readerChan          <-chan []byte
	currentViewedProcID int

	termWidth  int
	termHeight int
}

// NewToggleViewModel constructs a toggle-view TUI model that alternates between
// the process list and a raw scrollback view of the selected process.
func NewToggleViewModel(client ClientModel, pc *process.Controller, cfg *config.ProcTmuxConfig) ToggleViewModel {
	return ToggleViewModel{
		clientModel:        client,
		processController:  pc,
		cfg:                cfg,
		showingProcessList: true,
		keys:               newFocusKeys(client.keys),
	}
}

func (m ToggleViewModel) Init() tea.Cmd {
	var cmds []tea.Cmd
	if m.clientModel != nil {
		if cmd := m.clientModel.Init(); cmd != nil {
			cmds = append(cmds, cmd)
		}
	}
	return tea.Batch(cmds...)
}

func (m ToggleViewModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		return m.handleResize(msg)
	case tea.KeyMsg:
		return m.handleKeyMsg(msg)
	case scrollbackPollMsg:
		return m.pollReader()
	default:
		return m.forwardToClient(msg)
	}
}

func (m ToggleViewModel) handleResize(msg tea.WindowSizeMsg) (tea.Model, tea.Cmd) {
	m.termWidth = msg.Width
	m.termHeight = msg.Height

	var cmd tea.Cmd
	if m.clientModel != nil {
		clientHeight := max(msg.Height-toggleStatusLines, 0)
		childMsg := tea.WindowSizeMsg{Width: msg.Width, Height: clientHeight}
		m.clientModel, cmd = m.clientModel.Update(childMsg)
	}

	return m, cmd
}

func (m ToggleViewModel) handleKeyMsg(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// ToggleFocus toggles between the two views
	if len(m.keys.toggle.Keys()) > 0 && key.Matches(msg, m.keys.toggle) {
		if m.showingProcessList {
			return m.switchToScrollback()
		}
		return m.switchToProcessList()
	}

	// FocusClient always switches to process list
	if len(m.keys.client.Keys()) > 0 && key.Matches(msg, m.keys.client) {
		if !m.showingProcessList {
			return m.switchToProcessList()
		}
		return m, nil
	}

	// FocusServer always switches to scrollback
	if len(m.keys.server.Keys()) > 0 && key.Matches(msg, m.keys.server) {
		if m.showingProcessList {
			return m.switchToScrollback()
		}
		return m, nil
	}

	if m.showingProcessList {
		return m.forwardToClient(msg)
	}

	// In scrollback mode: forward keystrokes to the process as stdin
	return m.forwardToProcess(msg)
}

func (m ToggleViewModel) switchToScrollback() (tea.Model, tea.Cmd) {
	m.showingProcessList = false

	// Determine which process to view from the ClientModel
	procID := m.getActiveProcessID()
	if procID == 0 {
		// No process selected, stay on process list
		m.showingProcessList = true
		return m, nil
	}

	// Unsubscribe from any previous reader (value-receiver version)
	m = m.cleanupReader()

	m.currentViewedProcID = procID

	if m.processController != nil {
		// Bug 2 fix: use ScrollbackAndSubscribe to atomically capture the
		// historical snapshot and register the live reader in one lock
		// acquisition, closing the race window where bytes written between
		// a separate GetScrollback() and NewReader() call would be lost.
		snapshot, readerID, ch, err := m.processController.ScrollbackAndSubscribe(procID)
		if err != nil {
			log.Printf("Failed to subscribe to scrollback for process %d: %v", procID, err)
			m.scrollbackContent = ""
		} else {
			// Bug 1 fix: cap initial snapshot to maxScrollbackLines so
			// tailLines() never iterates a multi-megabyte string.
			m.scrollbackContent = capLines(string(snapshot), maxScrollbackLines)
			if ch != nil {
				m.readerID = readerID
				m.readerChan = ch
				return m, m.pollReaderCmd()
			}
		}
	}

	return m, nil
}

func (m ToggleViewModel) switchToProcessList() (tea.Model, tea.Cmd) {
	m.showingProcessList = true
	m = m.cleanupReader()
	m.currentViewedProcID = 0

	// Re-send window size to client so it recalculates layout
	var cmd tea.Cmd
	if m.clientModel != nil && m.termWidth > 0 && m.termHeight > 0 {
		clientHeight := max(m.termHeight-toggleStatusLines, 0)
		childMsg := tea.WindowSizeMsg{Width: m.termWidth, Height: clientHeight}
		m.clientModel, cmd = m.clientModel.Update(childMsg)
	}

	return m, cmd
}

// cleanupReader unsubscribes the current live scrollback reader and clears the
// related fields. It is a value receiver so it fits naturally into the
// copy-on-update Bubble Tea pattern: callers do m = m.cleanupReader().
func (m ToggleViewModel) cleanupReader() ToggleViewModel {
	if m.readerChan != nil && m.currentViewedProcID > 0 && m.processController != nil {
		m.processController.UnsubscribeScrollback(m.currentViewedProcID, m.readerID)
	}
	m.readerChan = nil
	m.readerID = 0
	return m
}

func (m ToggleViewModel) pollReaderCmd() tea.Cmd {
	return tea.Tick(togglePollInterval, func(time.Time) tea.Msg {
		return scrollbackPollMsg{}
	})
}

func (m ToggleViewModel) pollReader() (tea.Model, tea.Cmd) {
	if m.showingProcessList || m.readerChan == nil {
		return m, nil
	}

	// Drain all available data from the reader channel
	for {
		select {
		case data, ok := <-m.readerChan:
			if !ok {
				// Channel closed: process stopped or reader was removed.
				m.readerChan = nil
				return m, nil
			}
			m.scrollbackContent += string(data)
			// Bug 1 fix: trim the accumulated string so tailLines() always
			// operates on a bounded number of lines, not the full session history.
			if strings.Count(m.scrollbackContent, "\n") > maxScrollbackLines {
				m.scrollbackContent = capLines(m.scrollbackContent, maxScrollbackLines)
			}
		default:
			return m, m.pollReaderCmd()
		}
	}
}

func (m ToggleViewModel) forwardToClient(msg tea.Msg) (tea.Model, tea.Cmd) {
	// Bug 3 fix: when a state-update arrives while we are in scrollback view,
	// check whether the currently-viewed process has exited. If so, clean up
	// the reader so we don't leak the ring-buffer subscription and so the user
	// sees a sensible "stopped" state rather than a frozen scrollback.
	if _, ok := msg.(clientStateUpdateMsg); ok && !m.showingProcessList && m.currentViewedProcID != 0 && m.processController != nil {
		if !m.processController.IsRunning(m.currentViewedProcID) && m.readerChan != nil {
			log.Printf("Process %d exited; closing scrollback reader", m.currentViewedProcID)
			m = m.cleanupReader()
		}
	}

	var cmd tea.Cmd
	m.clientModel, cmd = forwardMsgToChild(m.clientModel, msg)
	return m, cmd
}

func (m ToggleViewModel) forwardToProcess(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if m.currentViewedProcID == 0 {
		return m, nil
	}

	input := keyMsgToTerminalInput(msg)
	if input == "" {
		return m, nil
	}

	if m.processController == nil {
		return m, nil
	}

	instance, err := m.processController.GetProcess(m.currentViewedProcID)
	if err != nil {
		log.Printf("Failed to get process %d for stdin: %v", m.currentViewedProcID, err)
		return m, nil
	}

	instance.SendBytes([]byte(input))
	return m, nil
}

func (m ToggleViewModel) getActiveProcessID() int {
	client := asClientModel(m.clientModel)
	if client == nil {
		return 0
	}

	if client.ui.ActiveProcID != 0 {
		return client.ui.ActiveProcID
	}

	// If no process is explicitly active, pick the first one in the list
	if client.domain != nil && len(client.domain.Processes) > 0 {
		return client.domain.Processes[0].ID
	}
	return 0
}

func (m ToggleViewModel) View() string {
	if m.showingProcessList {
		return m.viewProcessList()
	}
	return m.viewScrollback()
}

func (m ToggleViewModel) viewProcessList() string {
	clientView := ""
	if m.clientModel != nil {
		clientView = m.clientModel.View()
	}

	status := m.statusBar("process list")
	if status == "" {
		return clientView
	}

	return lipgloss.JoinVertical(lipgloss.Left, clientView, status)
}

func (m ToggleViewModel) viewScrollback() string {
	contentHeight := max(m.termHeight-toggleStatusLines, 0)

	// Take the tail of scrollback that fits the screen
	content := tailLines(m.scrollbackContent, contentHeight)

	contentStyle := lipgloss.NewStyle().
		Width(max(m.termWidth, 0)).
		Height(max(contentHeight, 0))

	status := m.statusBar("scrollback")
	if status == "" {
		return contentStyle.Render(content)
	}

	return lipgloss.JoinVertical(lipgloss.Left, contentStyle.Render(content), status)
}

// tailLines returns the last n lines of s with carriage returns stripped.
func tailLines(s string, n int) string {
	if n <= 0 {
		return ""
	}
	// Strip carriage returns — raw PTY output uses \r\n line endings which
	// confuse lipgloss's width-padding (the \r resets the cursor to column 0,
	// then padding spaces overwrite the text).
	s = strings.ReplaceAll(s, "\r", "")
	lines := strings.Split(s, "\n")
	if len(lines) <= n {
		return s
	}
	return strings.Join(lines[len(lines)-n:], "\n")
}

// capLines keeps only the last n lines of s. Used to bound scrollbackContent.
func capLines(s string, n int) string {
	if n <= 0 {
		return ""
	}
	s = strings.ReplaceAll(s, "\r", "")
	lines := strings.Split(s, "\n")
	if len(lines) <= n {
		return s
	}
	return strings.Join(lines[len(lines)-n:], "\n")
}

func (m ToggleViewModel) statusBar(mode string) string {
	totalWidth := m.termWidth
	if totalWidth <= 0 {
		return ""
	}
	if m.termHeight <= toggleStatusLines+1 {
		return ""
	}

	toggleLabel := joinKeys(m.keys.toggle.Keys())
	hint := fmt.Sprintf("%s toggle view", toggleLabel)

	modeStyle := lipgloss.NewStyle().Bold(true)
	hintStyle := lipgloss.NewStyle().Faint(true)

	content := modeStyle.Render(mode) + "    " + hintStyle.Render(hint)

	return lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Left).Render(content)
}

package tui

import (
	"fmt"
	"log"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"

	"github.com/nick/proctmux/internal/domain"
	"github.com/nick/proctmux/internal/protocol"
)

// Error message type

type errMsg struct{ err error }

func (e errMsg) Error() string { return e.err.Error() }

// keyMsgToTerminalInput converts a Bubble Tea key message into the
// corresponding ANSI terminal input byte sequence. Used by both
// SplitPaneModel (to write to the emulator) and ToggleViewModel
// (to forward stdin to processes).
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

// Input handlers and actions

func (m *ClientModel) syncFilterComponent() {
	m.filterUI.SetFocused(m.ui.EnteringFilterText)
	m.filterUI.SetValue(m.ui.FilterText)
}

// applyFilterNow applies the current filter text immediately without debouncing
func (m *ClientModel) applyFilterNow() tea.Cmd {
	procs := domain.FilterProcesses(m.domain.Config, m.processViews, m.ui.FilterText, m.ui.ShowOnlyRunning)
	if len(procs) > 0 {
		m.ui.ActiveProcID = procs[0].ID
		m.rebuildProcessList()
		return m.sendSelectionToPrimary(m.activeProcLabel())
	}
	m.ui.ActiveProcID = 0
	m.rebuildProcessList()
	return nil
}

func (m *ClientModel) handleKey(msg tea.KeyMsg) tea.Cmd {
	// Handle filter mode separately
	if m.ui.EnteringFilterText {
		switch {
		case key.Matches(msg, m.keys.FilterSubmit):
			// Submit filter and exit filter mode
			m.ui.EnteringFilterText = false
			m.ui.Mode = domain.NormalMode
			m.ui.FilterText = m.filterUI.ti.Value()
			m.syncFilterComponent()
			// Apply filter immediately on submit
			return m.applyFilterNow()

		case key.Matches(msg, m.keys.Filter):
			// Toggle filter mode off
			m.ui.EnteringFilterText = false
			m.ui.Mode = domain.NormalMode
			m.ui.FilterText = m.filterUI.ti.Value()
			m.syncFilterComponent()
			return nil

		case key.Matches(msg, m.keys.FilterEscape):
			// Cancel filter and clear text
			m.ui.EnteringFilterText = false
			m.ui.Mode = domain.NormalMode
			m.ui.FilterText = ""
			m.syncFilterComponent()
			// Apply filter immediately to clear it
			return m.applyFilterNow()

		default:
			// Delegate all other key handling to the textinput component
			var cmd tea.Cmd
			m.filterUI.ti, cmd = m.filterUI.ti.Update(msg)
			m.ui.FilterText = m.filterUI.ti.Value()
			// Apply filter as user types
			return tea.Batch(cmd, m.applyFilterNow())
		}
	}

	// Normal mode keybindings
	switch {
	case key.Matches(msg, m.keys.Quit):
		log.Printf("Client quitting, sending stop-running to primary")
		return tea.Sequence(
			m.sendCommandToPrimary(protocol.CommandStopRunning),
			tea.ExitAltScreen,
			tea.Quit,
		)

	case key.Matches(msg, m.keys.Filter):
		m.ui.EnteringFilterText = true
		m.ui.Mode = domain.FilterMode
		m.ui.FilterText = ""
		m.ui.ActiveProcID = 0
		m.syncFilterComponent()
		m.rebuildProcessList()
		return nil

	case key.Matches(msg, m.keys.Down):
		m.moveSelection(+1)
		m.procList.SetActiveID(m.ui.ActiveProcID)
		return m.sendSelectionToPrimary(m.activeProcLabel())

	case key.Matches(msg, m.keys.Up):
		m.moveSelection(-1)
		m.procList.SetActiveID(m.ui.ActiveProcID)
		return m.sendSelectionToPrimary(m.activeProcLabel())

	case key.Matches(msg, m.keys.Start):
		return m.sendCommandToPrimary(protocol.CommandStart)

	case key.Matches(msg, m.keys.Stop):
		return m.sendCommandToPrimary(protocol.CommandStop)

	case key.Matches(msg, m.keys.Restart):
		return m.sendCommandToPrimary(protocol.CommandRestart)

	case key.Matches(msg, m.keys.ToggleRunning):
		m.ui.ShowOnlyRunning = !m.ui.ShowOnlyRunning
		m.rebuildProcessList()
		return m.applyFilterNow()

	case key.Matches(msg, m.keys.ToggleHelp):
		m.ui.ShowHelp = !m.ui.ShowHelp
		m.updateLayout()
		return nil
	}

	return nil
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
	procs := domain.FilterProcesses(m.domain.Config, m.processViews, m.ui.FilterText, m.ui.ShowOnlyRunning)
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

func (m ClientModel) sendSelectionToPrimary(label string) tea.Cmd {
	return func() tea.Msg {
		if err := m.client.SwitchProcess(label); err != nil {
			log.Printf("Failed to send selection to primary: %v", err)
			return errMsg{err}
		}
		return nil
	}
}

func (m ClientModel) sendCommandToPrimary(action protocol.Command) tea.Cmd {
	return func() tea.Msg {
		if action == protocol.CommandStopRunning {
			if err := m.client.StopRunning(); err != nil {
				return errMsg{err}
			}
			log.Printf("Client sent %s command for all running processes", action)
			return nil
		}
		proc := m.domain.GetProcessByID(m.ui.ActiveProcID)
		if proc == nil {
			return errMsg{fmt.Errorf("no process selected")}
		}
		var err error
		switch action {
		case protocol.CommandStart:
			err = m.client.StartProcess(proc.Label)
		case protocol.CommandStop:
			err = m.client.StopProcess(proc.Label)
		case protocol.CommandRestart:
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

package tui

import (
	"fmt"
	"log"
	"slices"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/nick/proctmux/internal/domain"
)

// Error and input/debounce messages

type errMsg struct{ err error }

func (e errMsg) Error() string { return e.err.Error() }

type applyFilterMsg struct{ seq int }

type applySelectionMsg struct {
	seq    int
	procID int
}

func debounceFilter(seq int) tea.Cmd {
	return tea.Tick(150*time.Millisecond, func(time.Time) tea.Msg { return applyFilterMsg{seq: seq} })
}

func debounceSelection(seq, procID int) tea.Cmd {
	return tea.Tick(120*time.Millisecond, func(time.Time) tea.Msg { return applySelectionMsg{seq: seq, procID: procID} })
}

// Input handlers and actions

func (m *ClientModel) syncFilterComponent() {
	m.filterUI.SetFocused(m.ui.EnteringFilterText)
	m.filterUI.SetValue(m.ui.FilterText)
}

func (m *ClientModel) handleKey(key string) tea.Cmd {
	cfg := m.domain.Config
	kb := cfg.Keybinding

	if m.ui.EnteringFilterText {
		switch {
		case slices.Contains(kb.FilterSubmit, key):
			m.ui.EnteringFilterText = false
			m.ui.Mode = domain.NormalMode
			m.syncFilterComponent()
			m.filterSeq++
			return debounceFilter(m.filterSeq)
		case slices.Contains(kb.Filter, key):
			m.ui.EnteringFilterText = false
			m.ui.Mode = domain.NormalMode
			m.syncFilterComponent()
			return nil
		case key == "esc":
			m.ui.EnteringFilterText = false
			m.ui.Mode = domain.NormalMode
			m.ui.FilterText = ""
			m.syncFilterComponent()
			m.filterSeq++
			return debounceFilter(m.filterSeq)
		case key == "backspace" || key == "ctrl+h":
			if len(m.ui.FilterText) > 0 {
				m.ui.FilterText = m.ui.FilterText[:len(m.ui.FilterText)-1]
				m.syncFilterComponent()
				m.filterSeq++
				return debounceFilter(m.filterSeq)
			}
		default:
			if len(key) == 1 {
				m.ui.FilterText += key
				m.syncFilterComponent()
				m.filterSeq++
				return debounceFilter(m.filterSeq)
			}
		}
		return nil
	}

	switch {
	case slices.Contains(kb.Quit, key):
		log.Printf("Client quitting, sending stop-running to primary")
		return tea.Sequence(
			m.sendCommandToPrimary("stop-running"),
			tea.ExitAltScreen,
			tea.Quit,
		)
	case slices.Contains(kb.Filter, key):
		m.ui.EnteringFilterText = true
		m.ui.Mode = domain.FilterMode
		m.ui.FilterText = ""
		m.ui.ActiveProcID = 0
		m.syncFilterComponent()
		m.rebuildProcessList()
		m.selectSeq++
		return debounceSelection(m.selectSeq, 0)
	case slices.Contains(kb.Down, key):
		m.moveSelection(+1)
		m.procList.SetActiveID(m.ui.ActiveProcID)
		m.selectSeq++
		return m.sendSelectionToPrimary(m.activeProcLabel())
	case slices.Contains(kb.Up, key):
		m.moveSelection(-1)
		m.procList.SetActiveID(m.ui.ActiveProcID)
		m.selectSeq++
		return m.sendSelectionToPrimary(m.activeProcLabel())
	case slices.Contains(kb.Start, key):
		return m.sendCommandToPrimary("start")
	case slices.Contains(kb.Stop, key):
		return m.sendCommandToPrimary("stop")
	case slices.Contains(kb.Restart, key):
		return m.sendCommandToPrimary("restart")
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

func (m ClientModel) sendSelectionToPrimary(label string) tea.Cmd {
	return func() tea.Msg {
		if err := m.client.SwitchProcess(label); err != nil {
			log.Printf("Failed to send selection to primary: %v", err)
			return errMsg{err}
		}
		return nil
	}
}

func (m ClientModel) sendCommandToPrimary(action string) tea.Cmd {
	return func() tea.Msg {
		if action == "stop-running" {
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

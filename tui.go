package main

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

type Mode int

const (
	NormalMode Mode = iota
	FilterMode
)

type Model struct {
	controller *Controller
	state      *AppState
	mode       Mode
}

func NewModel(state *AppState, controller *Controller) Model {
	return Model{state: state, controller: controller, mode: NormalMode}
}

func (m Model) Init() tea.Cmd { return nil }

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		key := msg.String()
		cfg := m.state.Config
		kb := cfg.Keybinding

		if m.state.EnteringFilterText {
			// Filter mode key handling
			if contains(kb.FilterSubmit, key) {
				m.controller.OnFilterDone()
				m.mode = NormalMode
				m.state.Info = "Filter applied: " + m.state.FilterText
			} else if contains(kb.Filter, key) {
				m.controller.OnFilterDone()
				m.mode = NormalMode
				m.state.Info = "Filter cancelled"
			} else if key == "backspace" || key == "ctrl+h" {
				if len(m.state.FilterText) > 0 {
					m.controller.OnFilterSet(m.state.FilterText[:len(m.state.FilterText)-1])
				}
			} else if len(key) == 1 {
				m.controller.OnFilterSet(m.state.FilterText + key)
			}
			return m, nil
		}

		// Normal mode key handling
		if contains(kb.Quit, key) || key == "ctrl+c" {
			m.controller.OnKeypressQuit()
			return m, tea.Quit
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
			m.mode = FilterMode
			m.state.Info = "Enter filter text:"
		}
		if contains(kb.SwitchFocus, key) {
			m.controller.OnKeypressSwitchFocus()
			m.state.Info = "Switched focus (not implemented)"
		}
		if key == "enter" {
			if len(m.state.Processes) > 0 {
				// Attach to pane logic (not implemented)
				m.state.Info = "Attach to pane: " + m.state.Processes[m.state.ActiveIdx].PaneID
			}
		}
	}
	return m, nil
}

func (m Model) View() string {
	procs := m.filteredProcesses()
	s := "Proctmux (Go + Bubbletea version)\n\n"
	for i, p := range procs {
		cursor := "  "
		if i == m.state.ActiveIdx {
			cursor = m.state.Config.Style.PointerChar + " "
		}
		cat := ""
		if len(p.Categories) > 0 {
			cat = " [" + strings.Join(p.Categories, ",") + "]"
		}
		s += fmt.Sprintf("%s%s [%s]%s (Pane: %s)\n", cursor, p.Name, p.Status, cat, p.PaneID)
	}
	if m.state.EnteringFilterText {
		s += "\nFilter: " + m.state.FilterText + "_\n"
	}
	s += "\n[" + strings.Join(m.state.Config.Keybinding.Start, "/") + "] Start  [" +
		strings.Join(m.state.Config.Keybinding.Stop, "/") + "] Stop  [" +
		strings.Join(m.state.Config.Keybinding.Up, "/") + "] Up  [" +
		strings.Join(m.state.Config.Keybinding.Down, "/") + "] Down  [" +
		strings.Join(m.state.Config.Keybinding.Filter, "/") + "] Filter  [" +
		strings.Join(m.state.Config.Keybinding.Quit, "/") + "] Quit\n"
	if m.state.Info != "" {
		s += "\n" + m.state.Info + "\n"
	}
	// Show last 5 messages
	if len(m.state.Messages) > 0 {
		s += "\nMessages:\n"
		start := 0
		if len(m.state.Messages) > 5 {
			start = len(m.state.Messages) - 5
		}
		for _, msg := range m.state.Messages[start:] {
			s += "- " + msg + "\n"
		}
	}
	return s
}

// filteredProcesses returns the filtered process list as in Rust
func (m Model) filteredProcesses() []*Process {
	if m.state.FilterText == "" {
		return m.state.Processes
	}
	prefix := m.state.Config.Layout.CategorySearchPrefix
	var out []*Process
	for _, p := range m.state.Processes {
		if strings.HasPrefix(m.state.FilterText, prefix) {
			cat := strings.TrimPrefix(m.state.FilterText, prefix)
			for _, c := range m.state.Config.Procs[p.Name].Categories {
				if strings.EqualFold(c, cat) {
					out = append(out, p)
					break
				}
			}
		} else {
			if strings.Contains(strings.ToLower(p.Name), strings.ToLower(m.state.FilterText)) {
				out = append(out, p)
			}
		}
	}
	return out
}

// contains checks if a slice contains a string
func contains(slice []string, s string) bool {
	for _, v := range slice {
		if v == s {
			return true
		}
	}
	return false
}

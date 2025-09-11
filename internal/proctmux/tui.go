package proctmux

import (
	"fmt"
	"strings"

	"slices"

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

		if m.state.GUIState.EnteringFilterText {
			if contains(kb.FilterSubmit, key) {
				m.controller.OnFilterDone()
				m.mode = NormalMode
				m.state.GUIState.Info = "Filter applied: " + m.state.GUIState.FilterText
			} else if contains(kb.Filter, key) {
				m.controller.OnFilterDone()
				m.mode = NormalMode
				m.state.GUIState.Info = "Filter cancelled"
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
			m.state.GUIState.Info = "Enter filter text:"
		}
		if contains(kb.SwitchFocus, key) {
			m.controller.OnKeypressSwitchFocus()
			m.state.GUIState.Info = "Switched focus (not implemented)"
		}
		if contains(kb.Zoom, key) {
			// m.controller.OnKeypressZoom() // TODO: implement or remove
			m.state.GUIState.Info = "Toggled zoom for active pane"
		}
		if contains(kb.Focus, key) {
			// m.controller.OnKeypressFocus() // TODO: implement or remove
			m.state.GUIState.Info = "Focused active pane"
		}
		if key == "enter" {
			if len(m.state.Processes) > 0 {
				m.state.GUIState.Info = "Attach to pane: " + func() string {
					for i := range m.state.Processes {
						if m.state.Processes[i].ID == m.state.CurrentProcID {
							return m.state.Processes[i].PaneID
						}
					}
					return ""
				}()
			}
		}
	}
	return m, nil
}

func (m Model) View() string {
	procs := m.state.FilteredProcesses()
	s := "Proctmux (Go + Bubbletea version)\n\n"
	for _, p := range procs {
		cursor := "  "
		if p.ID == m.state.CurrentProcID {
			cursor = m.state.Config.Style.PointerChar + " "
		}
		cat := ""
		if p.Config != nil && len(p.Config.Categories) > 0 {
			cat = " [" + strings.Join(p.Config.Categories, ",") + "]"
		}
		zoom := ""
		if m.controller.tmuxContext.IsZoomedIn() && p.PaneID == m.controller.tmuxContext.PaneID {
			zoom = " (zoomed)"
		}
		s += fmt.Sprintf("%s%s [%s] PID:%d%s%s (Pane: %s)\n", cursor, p.Label, p.Status.String(), p.PID, cat, zoom, p.PaneID)
	}
	if m.state.GUIState.EnteringFilterText {
		s += "\nFilter: " + m.state.GUIState.FilterText + "_\n"
	}
	s += "\n[" + strings.Join(m.state.Config.Keybinding.Start, "/") + "] Start  [" +
		strings.Join(m.state.Config.Keybinding.Stop, "/") + "] Stop  [" +
		strings.Join(m.state.Config.Keybinding.Up, "/") + "] Up  [" +
		strings.Join(m.state.Config.Keybinding.Down, "/") + "] Down  [" +
		strings.Join(m.state.Config.Keybinding.Filter, "/") + "] Filter  [" +
		strings.Join(m.state.Config.Keybinding.Quit, "/") + "] Quit\n"
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

func contains(slice []string, s string) bool {
	return slices.Contains(slice, s)
}

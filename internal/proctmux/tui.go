package proctmux

import (
	"fmt"
	"strings"

	"slices"

	tea "github.com/charmbracelet/bubbletea"
)

type Model struct {
	controller *Controller
	state      *AppState
	termWidth  int
	termHeight int
}

func NewModel(state *AppState, controller *Controller) Model {
	return Model{state: state, controller: controller}
}

func (m Model) Init() tea.Cmd { return tea.Batch(tea.EnterAltScreen, tea.ClearScreen) }

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
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
						SetInfo("Filter applied: " + state.GUIState.FilterText).
						Commit()
					newState := NewStateMutation(state).SetGUIState(gui).Commit()
					return newState, nil
				})
			} else if contains(kb.Filter, key) {
				m.controller.OnFilterDone()
				_ = m.controller.LockAndLoad(func(state *AppState) (*AppState, error) {
					gui := NewGUIStateMutation(&state.GUIState).
						SetMode(NormalMode).
						SetInfo("Filter cancelled").
						Commit()
					newState := NewStateMutation(state).SetGUIState(gui).Commit()
					return newState, nil
				})
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
					SetInfo("Enter filter text:").
					Commit()
				newState := NewStateMutation(state).SetGUIState(gui).Commit()
				return newState, nil
			})
		}
		if contains(kb.SwitchFocus, key) {
			m.controller.OnKeypressSwitchFocus()
			_ = m.controller.LockAndLoad(func(state *AppState) (*AppState, error) {
				gui := NewGUIStateMutation(&state.GUIState).SetInfo("Switched focus (not implemented)").Commit()
				newState := NewStateMutation(state).SetGUIState(gui).Commit()
				return newState, nil
			})
		}
		if contains(kb.Zoom, key) {
			// m.controller.OnKeypressZoom() // TODO: implement or remove
			_ = m.controller.LockAndLoad(func(state *AppState) (*AppState, error) {
				gui := NewGUIStateMutation(&state.GUIState).SetInfo("Toggled zoom for active pane").Commit()
				newState := NewStateMutation(state).SetGUIState(gui).Commit()
				return newState, nil
			})
		}
		if contains(kb.Focus, key) {
			// m.controller.OnKeypressFocus() // TODO: implement or remove
			_ = m.controller.LockAndLoad(func(state *AppState) (*AppState, error) {
				gui := NewGUIStateMutation(&state.GUIState).SetInfo("Focused active pane").Commit()
				newState := NewStateMutation(state).SetGUIState(gui).Commit()
				return newState, nil
			})
		}
		if key == "enter" {
			if len(m.state.Processes) > 0 {
				_ = m.controller.LockAndLoad(func(state *AppState) (*AppState, error) {
					var pane string
					for i := range state.Processes {
						if state.Processes[i].ID == state.CurrentProcID {
							pane = state.Processes[i].PaneID
							break
						}
					}
					gui := NewGUIStateMutation(&state.GUIState).SetInfo("Attach to pane: " + pane).Commit()
					newState := NewStateMutation(state).SetGUIState(gui).Commit()
					return newState, nil
				})
			}
		}
	}
	return m, nil
}

func (m Model) View() string {
	procs := m.state.GetFilteredProcesses()
	// an ANSI terminal control sequence that clears
	// the screen and repositions the cursor to the home position (top-left corner)
	clear := "\x1b[2J\x1b[H"
	s := clear + "\nProctmux\n"
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
	// Pad to full terminal height so the panel fills the screen
	if m.termHeight > 0 {
		lines := strings.Count(s, "\n")
		missing := m.termHeight - lines
		for i := 0; i < missing; i++ {
			s += "\n"
		}
	}
	return s
}

func contains(slice []string, s string) bool {
	return slices.Contains(slice, s)
}

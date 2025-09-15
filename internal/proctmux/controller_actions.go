package proctmux

import (
	"log"
	"strings"
)

func (c *Controller) OnKeypressStart() error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		if state.Exiting {
			return state, nil
		}
		currentProcess := state.GetProcessByID(state.CurrentProcID)

		if currentProcess == nil {
			log.Println("No current process selected")
			return state, nil
		}

		if currentProcess.Status != StatusHalted {
			log.Printf("Process %s is already running", currentProcess.Label)
			return state, nil
		}

		newState, err := killPane(state, currentProcess)
		if err != nil {
			log.Printf("Error killing existing pane for %s: %v", currentProcess.Label, err)
		}
		c.breakCurrentPane(newState, true)
		currentProcess = newState.GetProcessByID(state.CurrentProcID)
		newState, err = startProcess(newState, c.tmuxContext, currentProcess, false)
		if err == nil && currentProcess.Config.Autofocus {
			if err2 := focusActivePane(newState, c.tmuxContext); err2 != nil {
				log.Printf("Error auto-focusing %s: %v", currentProcess.Label, err2)
			}
		}
		return newState, err
	})
}

func (c *Controller) OnKeypressStop() error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		currentProcess := state.GetCurrentProcess()
		return haltProcess(state, currentProcess)
	})
}

func (c *Controller) OnKeypressQuit() error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		if state.Exiting {
			return state, nil
		}

		newState := NewStateMutation(state).SetExiting().Commit()
		var err error
		for _, p := range newState.Processes {
			if p.Status != StatusHalted {
				newState, err = haltProcess(newState, &p)
				if err != nil {
					log.Printf("Error halting process %s: %v", p.Label, err)
					return nil, err
				}
			}
		}

		return state, nil
	})
}

func (c *Controller) OnFilterStart() error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		guiState := NewGUIStateMutation(&state.GUIState).StartEnteringFilter().Commit()
		newState := NewStateMutation(state).SetGUIState(guiState).Commit()
		return newState, nil
	})
}

func (c *Controller) OnFilterSet(text string) error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		// Update filter text and reset selection
		state.UpdateFilterText(text)
		// Keep GUIState in sync for entering text flow
		guiState := NewGUIStateMutation(&state.GUIState).SetFilterText(text).Commit()
		newState := NewStateMutation(state).SetGUIState(guiState).Commit()
		return newState, nil
	})
}

func (c *Controller) OnFilterDone() error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		guiState := NewGUIStateMutation(&state.GUIState).
			StopEnteringFilter().
			Commit()
		newState := NewStateMutation(state).
			SetGUIState(guiState).
			Commit()
		return newState, nil
	})
}

func (c *Controller) OnKeypressSwitchFocus() error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		err := focusActivePane(state, c.tmuxContext)
		if err != nil {
			log.Printf("Error focusing active pane: %v", err)
		}
		return state, err
	})
}

func (c *Controller) OnKeypressDocs() error {
	var doc string
	if err := c.LockAndLoad(func(state *AppState) (*AppState, error) {
		current := state.GetCurrentProcess()
		if current == nil || current.Config == nil || len(strings.TrimSpace(current.Config.Docs)) == 0 {
			gui := NewGUIStateMutation(&state.GUIState).SetInfo("no documentation for process").Commit()
			newState := NewStateMutation(state).SetGUIState(gui).Commit()
			return newState, nil
		}
		doc = current.Config.Docs
		return state, nil
	}); err != nil {
		return err
	}
	if len(strings.TrimSpace(doc)) > 0 {
		return c.tmuxContext.ShowTextPopup(doc)
	}
	return nil
}

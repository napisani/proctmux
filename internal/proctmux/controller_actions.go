package proctmux

import "log"

func (c *Controller) OnKeypressStart() error {
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
		if state.Exiting {
			return state, nil
		}
		currentProcess := state.GetProcessByID(state.CurrentProcID)

		if currentProcess == nil {
			log.Println("No current process selected")
			return state, nil
		}

		newState, err := killPane(state, currentProcess)
		if err != nil {
			log.Printf("Error killing existing pane for %s: %v", currentProcess.Label, err)
			return nil, err
		}

		newState, err = startProcess(state, c.tmuxContext, currentProcess)
		if err == nil && currentProcess.Config.Autofocus {
			if err2 := focusActivePane(newState, c.tmuxContext); err2 != nil {
				log.Printf("Error auto-focusing %s: %v", currentProcess.Label, err2)
			}
		}
		return newState, err
	})
}

func (c *Controller) OnKeypressStop() error {
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
		currentProcess := state.GetCurrentProcess()
		return haltProcess(state, currentProcess)
	})
}

func (c *Controller) OnKeypressQuit() error {
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
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
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
		guiState := NewGUIStateMutation(&state.GUIState).StartEnteringFilter().Commit()
		newState := NewStateMutation(state).SetGUIState(guiState).Commit()
		return newState, nil
	})
}

func (c *Controller) OnFilterSet(text string) error {
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
		guiState := NewGUIStateMutation(&state.GUIState).SetFilterText(text).Commit()
		newState := NewStateMutation(state).SetGUIState(guiState).Commit()
		return newState, nil
	})
}

func (c *Controller) OnFilterDone() error {
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
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
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
		err := focusActivePane(state, c.tmuxContext)
		if err != nil {
			log.Printf("Error focusing active pane: %v", err)
		}
		return state, err
	})
}

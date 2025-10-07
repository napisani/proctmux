package proctmux

import (
	"fmt"
	"log"
	"strings"
	"time"
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
		newState := state
		c.breakCurrentPane(newState, true)
		guiState := NewGUIStateMutation(&state.GUIState).StartEnteringFilter().SetFilterText("").Commit()
		newState = NewStateMutation(state).SetGUIState(guiState).ClearProcessSelection().Commit()
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

func (c *Controller) OnKeypressRestart() error {
	log.Println("Restarting current process...")
	var currentProcessLabel string
	err := c.LockAndLoad(func(state *AppState) (*AppState, error) {
		currentProcess := state.GetCurrentProcess()
		if currentProcess == nil {
			log.Println("No current process selected")
			return state, nil
		}
		currentProcessLabel = currentProcess.Label
		return state, nil
	})

	if err != nil {
		log.Printf("Error current process identification: %v", err)
		return err
	}
	err = c.OnKeypressStop()

	log.Printf("Waiting for process %s to stop...", currentProcessLabel)
	err = c.WaitUntilStopped(currentProcessLabel)
	if err != nil {
		log.Printf("Error waiting for process %s to stop: %v", currentProcessLabel, err)
		return err
	}

	return c.OnKeypressStart()
}

func (c *Controller) WaitUntilStopped(label string) error {
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		var stopped bool
		err := c.LockAndLoad(func(state *AppState) (*AppState, error) {
			p := state.GetProcessByLabel(label)
			log.Printf("Waiting for process %s to stop, current status: %v PID: %v", label, p.Status, p.PID)
			if p == nil || p.Status == StatusHalted {
				stopped = true
			}
			return state, nil
		})
		if err != nil {
			return err
		}
		if stopped {
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("timeout waiting for process to stop")
}

func (c *Controller) OnKeypressStartWithLabel(label string) error {
	err := c.handleMoveToProcessByLabel(label)
	if err != nil {
		return err
	}
	return c.OnKeypressStart()
}

func (c *Controller) OnKeypressStopWithLabel(label string) error {
	err := c.handleMoveToProcessByLabel(label)
	if err != nil {
		return err
	}
	return c.OnKeypressStop()
}

func (c *Controller) OnKeypressRestartWithLabel(label string) error {
	err := c.handleMoveToProcessByLabel(label)
	if err != nil {
		return err
	}
	return c.OnKeypressRestart()
}

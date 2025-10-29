package proctmux

import (
	"errors"
	"log"
)

func (c *Controller) handleMove(directionNum int) error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		numProcesses := 0
		for _, p := range state.Processes {
			if p.ID != DummyProcessID {
				numProcesses++
			}
		}
		if numProcesses == 0 {
			log.Printf("No processes available to move selection")
			return state, nil
		}

		mut := NewStateMutation(state)
		if directionNum > 0 {
			mut = mut.NextProcess()
		} else {
			mut = mut.PreviousProcess()
		}
		newState := mut.Commit()

		if c.ipcServer != nil {
			proc := newState.GetProcessByID(newState.CurrentProcID)
			if proc != nil {
				c.ipcServer.BroadcastSelection(proc.ID, proc.Label)
			}
		}

		return newState, nil
	})
}

func (c *Controller) handleMoveToProcessByLabel(processLabel string) error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		foundAny := false
		for _, p := range state.Processes {
			if p.ID != DummyProcessID {
				foundAny = true
				break
			}
		}
		if !foundAny {
			log.Printf("No processes available to move selection")
			return state, nil
		}
		proc := state.GetProcessByLabel(processLabel)
		if proc == nil {
			log.Printf("No process found with label %s", processLabel)
			return state, errors.New("process not found")
		}
		processID := proc.ID
		log.Printf("Moving selection to process with label %s and ID %d", processLabel, processID)

		if state.CurrentProcID == processID {
			log.Printf("Process ID %d is already selected", processID)
			return state, nil
		}

		mut := NewStateMutation(state)
		var err error
		mut, err = mut.SelectProcessByID(processID)
		if err != nil {
			log.Printf("Error selecting process by ID %d: %v", processID, err)
			return state, err
		}
		newState := mut.Commit()

		if c.ipcServer != nil {
			proc := newState.GetProcessByID(newState.CurrentProcID)
			if proc != nil {
				c.ipcServer.BroadcastSelection(proc.ID, proc.Label)
			}
		}

		return newState, nil
	})
}

func (c *Controller) OnKeypressDown() error { return c.handleMove(1) }
func (c *Controller) OnKeypressUp() error   { return c.handleMove(-1) }

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

		err := c.SendCommand("start", currentProcess.ID, currentProcess.Config)
		if err != nil {
			log.Printf("Error sending start command for %s: %v", currentProcess.Label, err)
			return state, err
		}

		return state, nil
	})
}

func (c *Controller) OnKeypressStop() error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		currentProcess := state.GetCurrentProcess()
		if currentProcess == nil {
			log.Println("No current process selected")
			return state, nil
		}

		if currentProcess.Status != StatusRunning {
			log.Printf("Process %s is not running", currentProcess.Label)
			return state, nil
		}

		err := c.SendCommand("stop", currentProcess.ID, nil)
		if err != nil {
			log.Printf("Error sending stop command for %s: %v", currentProcess.Label, err)
			return state, err
		}

		return state, nil
	})
}

func (c *Controller) OnKeypressQuit() error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		if state.Exiting {
			return state, nil
		}

		newState := NewStateMutation(state).SetExiting().Commit()

		for _, p := range newState.Processes {
			if p.Status == StatusRunning {
				err := c.SendCommand("stop", p.ID, nil)
				if err != nil {
					log.Printf("Error sending stop command for %s: %v", p.Label, err)
				}
			}
		}

		return newState, nil
	})
}

func (c *Controller) OnFilterStart() error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		newState := NewStateMutation(state).ClearProcessSelection().Commit()
		return newState, nil
	})
}


func (c *Controller) OnKeypressSwitchFocus() error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		return state, nil
	})
}

func (c *Controller) OnKeypressDocs() error {
	var doc string
	if err := c.LockAndLoad(func(state *AppState) (*AppState, error) {
		current := state.GetCurrentProcess()
		if current == nil || current.Config == nil || len(strings.TrimSpace(current.Config.Docs)) == 0 {
			return state, nil
		}
		doc = current.Config.Docs
		return state, nil
	}); err != nil {
		return err
	}
	if len(strings.TrimSpace(doc)) > 0 {
		log.Printf("Documentation for current process:\n%s", doc)
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

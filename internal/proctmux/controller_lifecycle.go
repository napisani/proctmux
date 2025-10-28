package proctmux

import "log"

func (c *Controller) OnStartup() error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		newState := state
		var err error

		for idx := range newState.Processes {
			proc := newState.Processes[idx]
			if proc.Config.Autostart {
				log.Printf("Auto-starting process %s", proc.Label)
				newState, err = startProcess(newState, c.processServer, &proc, true)
				if err != nil {
					log.Printf("Error auto-starting process %s: %v", proc.Label, err)
				}
			}
		}

		return newState, nil
	})
}

func (c *Controller) Destroy() error {
	log.Println("Controller destroying, cleaning up...")
	close(c.pidCh)
	c.LockAndLoad(func(state *AppState) (*AppState, error) {
		accState := state
		var err error
		newState, err := haltAllProcesses(c.state)
		if err != nil {
			log.Printf("Error halting all processes on exit: %v", err)
		}

		if newState != nil {
			accState = newState
		}

		for _, process := range state.Processes {
			newState, err = killPane(newState, c.processServer, &process)
			if err != nil {
				log.Printf("Error killing pane on exit for label: %s: %v", process.Label, err)
			}
			if newState != nil {
				accState = newState
			}
		}
		return accState, nil
	})
	return nil
}

package proctmux

import "log"

func (c *Controller) OnStartup() error {
	if err := c.tmuxContext.Prepare(); err != nil {
		return err
	}
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
		newState := state
		var err error

		for idx := range newState.Processes {
			log.Printf("index %d %d", idx, len(newState.Processes))
			proc := newState.Processes[idx]
			if proc.Config.Autostart {
				// newState, err = startProcess(newState, c.tmuxContext, &proc)
				if err != nil {
					log.Printf("Error auto-starting process %s: %v", proc.Label, err)
				}
			}
		}

		// c.breakCurrentPane(newState)
		// c.joinSelectedPane(newState)

		return newState, nil
	})
}

func (c *Controller) Destroy() error {
	log.Println("Controller destroying, cleaning up...")
	close(c.pidCh)
	for _, d := range c.daemons {
		log.Printf("Destroying daemon for session %s", d.SessionID)
		d.Destroy()
	}
	c.lockAndLoad(func(state *AppState) (*AppState, error) {
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
			newState, err = killPane(newState, &process)
			if err != nil {
				log.Printf("Error killing pane on exit for label: %s: %v", process.Label, err)
			}
			if newState != nil {
				accState = newState
			}
		}
		if err := c.tmuxContext.Cleanup(); err != nil {
			log.Printf("Error cleaning up tmux context: %v", err)
		}
		return accState, nil
	})
	return nil
}

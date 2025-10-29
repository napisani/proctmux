package proctmux

import "log"

func (c *Controller) OnStartup() error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		for idx := range state.Processes {
			proc := state.Processes[idx]
			if proc.Config.Autostart {
				log.Printf("Auto-starting process %s", proc.Label)
				err := c.SendCommand("start", proc.ID, proc.Config)
				if err != nil {
					log.Printf("Error auto-starting process %s: %v", proc.Label, err)
				}
			}
		}

		return state, nil
	})
}

func (c *Controller) Destroy() error {
	log.Println("Controller destroying, cleaning up...")
	close(c.pidCh)
	c.LockAndLoad(func(state *AppState) (*AppState, error) {
		for _, process := range state.Processes {
			if process.Status == StatusRunning {
				err := c.SendCommand("stop", process.ID, nil)
				if err != nil {
					log.Printf("Error stopping process on exit for label: %s: %v", process.Label, err)
				}
			}
		}
		return state, nil
	})
	return nil
}

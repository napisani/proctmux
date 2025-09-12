package proctmux

import "log"

func (c *Controller) RegisterTmuxDaemons(attachedID, detachedID string) error {
	attached, err := NewTmuxDaemon(attachedID)
	if err != nil {
		return err
	}
	attached.state = c.state
	attached.stateMu = &c.stateMu
	detached, err := NewTmuxDaemon(detachedID)
	if err != nil {
		return err
	}
	detached.state = c.state
	detached.stateMu = &c.stateMu
	go func() { _ = attached.ListenForDeadPanes(c.pidCh) }()
	go func() { _ = detached.ListenForDeadPanes(c.pidCh) }()
	go func() {
		for pid := range c.pidCh {
			c.OnPidTerminated(pid)
		}
	}()
	c.daemons = []*TmuxDaemon{attached, detached}
	return nil
}

func (c *Controller) OnPidTerminated(pid int) {
	c.LockAndLoad(func(state *AppState) (*AppState, error) {
		process := state.GetProcessByPID(pid)
		newState, err := setProcessTerminated(state, process)
		if err != nil {
			log.Printf("Error setting process terminated for PID %d: %v", pid, err)
			return nil, err
		} else {
			err = SelectPane(c.tmuxContext.PaneID)
			if err != nil {
				log.Printf("Error selecting pane %s: %v", c.tmuxContext.PaneID, err)
			}
		}
		return newState, nil
	})
}

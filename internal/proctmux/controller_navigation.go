package proctmux

import "log"

func (c *Controller) handleMove(directionNum int) error {
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
		// Break current pane out to detached session (if any)
		c.breakCurrentPane(state)

		// Move selection
		mut := NewStateMutation(state)
		if directionNum > 0 {
			mut = mut.NextProcess()
		} else {
			mut = mut.PreviousProcess()
		}
		newState := mut.Commit()

		// Join newly selected pane into main pane (if any)
		c.joinSelectedPane(newState)
		return newState, nil
	})
}

// breakCurrentPane breaks the current pane out to a detached session if one exists
func (c *Controller) breakCurrentPane(state *AppState) {
	if curr := state.GetCurrentProcess(); curr != nil && curr.PaneID != "" {
		log.Printf("Breaking pane for %s out to detached session", curr.Label)
		err := c.tmuxContext.BreakPane(curr.PaneID, curr.ID, curr.Label)
		if err != nil {
			log.Printf("Error breaking pane for %s: %v", curr.Label, err)
		}
	} else {
		dummyProc := state.GetDummyProcess()
		if dummyProc != nil && dummyProc.PaneID != "" {
			log.Printf("Breaking dummy pane out to detached session PaneID %s", dummyProc.PaneID)
			err := c.tmuxContext.BreakPane(dummyProc.PaneID, dummyProc.ID, dummyProc.Label)
			if err != nil {
				log.Printf("Error breaking dummy pane: %v", err)
			}
		}
	}
}

// joinSelectedPane joins the currently selected pane into the main pane if one exists
func (c *Controller) joinSelectedPane(state *AppState) {
	log.Printf("Joining selected pane into main pane")
	if sel := state.GetCurrentProcess(); sel != nil && sel.PaneID != "" {
		log.Printf("Joining pane for %s into main pane", sel.Label)
		if err := c.tmuxContext.JoinPane(sel.PaneID); err != nil {
			log.Printf("Error joining pane for %s: %v", sel.Label, err)
		}
	} else {
		dummyProc := state.GetDummyProcess()
		log.Printf("No selected process, checking for dummy pane")
		if dummyProc != nil && dummyProc.PaneID != "" {
			log.Printf("Joining dummy pane into main pane PaneID %s", dummyProc.PaneID)
			if err := c.tmuxContext.JoinPane(dummyProc.PaneID); err != nil {
				log.Printf("Error joining dummy pane: %v", err)
			}
		}
	}
}

func (c *Controller) OnKeypressDown() error { return c.handleMove(1) }
func (c *Controller) OnKeypressUp() error   { return c.handleMove(-1) }

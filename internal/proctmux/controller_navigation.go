package proctmux

import "log"

func (c *Controller) handleMove(directionNum int) error {
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
		// Break current pane out to detached session (if any)
		if curr := state.GetCurrentProcess(); curr != nil && curr.PaneID != "" {
			_ = c.tmuxContext.BreakPane(curr.PaneID, curr.ID, curr.Label)
		}

		// Move selection
		mut := NewStateMutation(state)
		if directionNum > 0 {
			mut = mut.NextProcess()
		} else {
			mut = mut.PreviousProcess()
		}
		newState := mut.Commit()

		// Join newly selected pane into main pane (if any)
		if sel := newState.GetCurrentProcess(); sel != nil && sel.PaneID != "" {
			if err := c.tmuxContext.JoinPane(sel.PaneID); err != nil {
				log.Printf("Error joining pane for %s: %v", sel.Label, err)
			}
		}
		return newState, nil
	})
}

func (c *Controller) OnKeypressDown() error { return c.handleMove(1) }
func (c *Controller) OnKeypressUp() error   { return c.handleMove(-1) }

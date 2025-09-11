package proctmux

import (
	"log"
)

func (c *Controller) handleMove(directionNum int) error {
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
		// Break current pane out to detached session (if any)
		c.breakCurrentPane(state, true)

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
func (c *Controller) breakCurrentPane(state *AppState, includeDummy bool) {
	breakPaneFn := func(paneID string, label string, windowID int) bool {
		sessionType, err := c.tmuxContext.GetPaneSessionType(paneID)
		if err != nil {
			log.Printf("Error getting session type for pane %s: %v", paneID, err)
			return false
		}
		if sessionType != SessionTypeForeground {
			log.Printf("Pane %s is not in foreground session, skipping break", paneID)
			return false
		}
		log.Printf("Breaking pane for %s out to detached session", label)
		if err := c.tmuxContext.BreakPane(paneID, windowID, label); err != nil {
			log.Printf("Error breaking pane for %s: %v", label, err)
		}
		return true
	}

	sel := state.GetCurrentProcess()
	shouldBreak := sel != nil && sel.PaneID != ""
	if shouldBreak {
		_ = breakPaneFn(sel.PaneID, sel.Label, sel.ID)
	}
	if !includeDummy {
		return
	}
	dummyProc := state.GetDummyProcess()
	if dummyProc != nil && dummyProc.PaneID != "" {
		_ = breakPaneFn(dummyProc.PaneID, dummyProc.Label, dummyProc.ID)
	}
}

// joinSelectedPane joins the currently selected pane into the main pane if one exists
func (c *Controller) joinSelectedPane(state *AppState) {
	joinPaneFn := func(paneID string, label string) bool {
		sessionType, err := c.tmuxContext.GetPaneSessionType(paneID)
		if err != nil {
			log.Printf("Error getting session type for pane %s: %v", paneID, err)
			return false

		}
		if sessionType != SessionTypeDetached {
			log.Printf("Selected pane %s is not in detached session, skipping join", paneID)
			return false
		}
		log.Printf("Joining pane for %s into main pane", label)
		if err := c.tmuxContext.JoinPane(paneID); err != nil {
			log.Printf("Error joining pane for %s: %v", label, err)
		}
		return true
	}

	log.Printf("Joining selected pane into main pane")
	sel := state.GetCurrentProcess()
	shouldJoin := sel != nil && sel.PaneID != ""
	foundJoinablePane := false
	if shouldJoin {
		foundJoinablePane = joinPaneFn(sel.PaneID, sel.Label)

	}
	if !foundJoinablePane || !shouldJoin {
		dummyProc := state.GetDummyProcess()
		log.Printf("No selected process, checking for dummy pane")
		if dummyProc != nil && dummyProc.PaneID != "" {
			_ = joinPaneFn(dummyProc.PaneID, dummyProc.Label)
		}
	}
}

func (c *Controller) OnKeypressDown() error { return c.handleMove(1) }
func (c *Controller) OnKeypressUp() error   { return c.handleMove(-1) }

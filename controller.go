package main

import (
	"log"
	"os"
	"sync"
	"sync/atomic"
	"syscall"
)

type Controller struct {
	state       *AppState
	stateMu     sync.Mutex
	tmuxContext *TmuxContext
	running     *atomic.Bool
}

func NewController(state *AppState, tmuxContext *TmuxContext, running *atomic.Bool) *Controller {
	return &Controller{state: state, tmuxContext: tmuxContext, running: running}
}

func (c *Controller) lockAndLoad(f func(*AppState) (*AppState, error)) error {
	c.stateMu.Lock()
	defer c.stateMu.Unlock()
	newState, err := f(c.state)
	if err != nil {
		log.Printf("Error in controller operation: %v", err)
		return err
	}
	if newState != nil {
		c.state = newState
	}
	return nil
}

func (c *Controller) OnStartup() error {
	if err := c.tmuxContext.Prepare(); err != nil {
		return err
	}
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
		newState := state
		var err error
		for name, proc := range state.Processes {
			if proc.Config.Autostart {
				newState, err = startProcess(state, c.tmuxContext, &proc)
				if err != nil {
					log.Printf("Error auto-starting process %s: %v", name, err)
					return nil, err
				}
			}
		}
		return newState, nil
	})
}

func (c *Controller) OnExit() error {
	c.lockAndLoad(func(state *AppState) (*AppState, error) {
		newState := state
		var err error
		for _, process := range state.Processes {
			if process.Status == StatusHalted {
				newState, err = killPane(newState, &process)
				if err != nil {
					log.Printf("Error killing pane on exit for label: %s: %v", process.Label, err)
					return nil, err
				}
			}
		}
		if err := c.tmuxContext.Cleanup(); err != nil {
			log.Printf("Error cleaning up tmux context: %v", err)
			return nil, err
		}
		return state, nil
	})
	return nil
}

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

func (c *Controller) OnKeypressDown() error {
	return c.handleMove(1)
}

func (c *Controller) OnKeypressUp() error {
	return c.handleMove(-1)
}

func (c *Controller) OnKeypressStart() error {
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
		if state.Exiting {
			return state, nil
		}
		currentProcess := state.GetProcessByID(state.CurrentProcID)

		if currentProcess == nil {
			log.Println("No current process selected")
			return state, nil
		}

		newState, err := killPane(state, currentProcess)
		if err != nil {
			log.Printf("Error killing existing pane for %s: %v", currentProcess.Label, err)
			return nil, err
		}

		newState, err = startProcess(state, c.tmuxContext, currentProcess)
		if err == nil && currentProcess.Config.Autofocus {
			if err2 := focusActivePane(newState, c.tmuxContext); err2 != nil {
				log.Printf("Error auto-focusing %s: %v", currentProcess.Label, err2)
			}
		}
		return newState, err
	})
}

func (c *Controller) OnKeypressStop() error {
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
		currentProcess := state.GetCurrentProcess()
		return haltProcess(state, currentProcess)
	})
}

func (c *Controller) OnKeypressQuit() error {
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
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
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
		guiState := NewGUIStateMutation(&state.GUIState).StartEnteringFilter().Commit()
		newState := NewStateMutation(state).SetGUIState(guiState).Commit()
		return newState, nil
	})
}

func (c *Controller) OnFilterSet(text string) error {
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
		guiState := NewGUIStateMutation(&state.GUIState).SetFilterText(text).Commit()
		newState := NewStateMutation(state).SetGUIState(guiState).Commit()
		return newState, nil
	})
}

func (c *Controller) OnFilterDone() error {
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
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
	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
		err := focusActivePane(state, c.tmuxContext)
		if err != nil {
			log.Printf("Error focusing active pane: %v", err)
		}
		return state, err
	})
}

// func (c *Controller) OnKeypressZoom() error {
// 	return c.lockAndLoad(func(state *AppState) (*AppState, error) {
// 		if len(state.Processes) == 0 {
// 			return nil
// 		}
// 		p := state.Processes[state.ActiveIdx]
// 		return c.tmuxContext.ToggleZoom(p.PaneID)
// 	})
// }

func killPane(state *AppState, process *Process) (*AppState, error) {
	if process.PaneID == "" {
		return state, nil
	}
	err := KillPane(process.PaneID)
	if err != nil {
		log.Printf("Error killing pane %s for process %s: %v", process.PaneID, process.Label, err)
		return nil, err
	}
	newState := NewStateMutation(state).
		SetProcessPaneID("", process.ID).
		Commit()
	return newState, nil
}

func startProcess(state *AppState, tmuxContext *TmuxContext, process *Process) (*AppState, error) {
	isSameProc := process.ID == state.CurrentProcID
	if process.Status != StatusHalted {
		return state, nil
	}

	log.Printf("current process log before start: %+v", process)

	var newPane string
	var errPane error
	if isSameProc {
		log.Printf("Starting process %s in new attached pane, current process id %d", process.Label, process.ID)
		newPane, errPane = tmuxContext.CreatePane(process)
	} else {
		log.Printf("Starting process %s in new detached pane, current process id %d", process.Label, process.ID)
		newPane, errPane = tmuxContext.CreateDetachedPane(process)
	}

	if errPane != nil {
		log.Printf("Error creating pane for process %s: %v", process.Label, errPane)
		return nil, errPane
	}

	pid, pidErr := tmuxContext.GetPanePID(newPane)
	if pidErr != nil {
		log.Printf("Error getting PID for process %s: %v", process.Label, pidErr)
		return nil, pidErr
	}
	log.Printf("Started process %s with PID %d in pane %s", process.Label, pid, newPane)

	newState := NewStateMutation(state).
		SetProcessStatus(StatusRunning, process.ID).
		SetProcessPaneID(newPane, process.ID).
		SetProcessPID(pid, process.ID).
		Commit()
	return newState, nil

}

func focusActivePane(state *AppState, tmuxContext *TmuxContext) error {
	currentProcess := state.GetCurrentProcess()
	if currentProcess == nil {
		log.Println("No current process to focus")
		return nil
	}
	return tmuxContext.FocusPane(currentProcess.PaneID)

}

func haltProcess(state *AppState, process *Process) (*AppState, error) {
	if process.Status != StatusRunning {
		log.Printf("Process %s is not running, cannot halt", process.Label)
		return state, nil
	}

	if process.PID <= 0 {
		log.Printf("Process %s has no valid PID to halt", process.Label)
		return state, nil
	}

	signal := process.Config.Stop
	if signal == 0 {
		signal = 15 // Default to SIGTERM if not specified
	}

	osProcess, err := os.FindProcess(process.PID)
	if err != nil {
		log.Printf("Failed to find process: %v\n", err)
		return nil, err
	}

	err = osProcess.Signal(syscall.Signal(signal))
	if err != nil {
		log.Printf("Failed to send signal: %v\n", err)
		return nil, err
	}

	newState := NewStateMutation(state).
		SetProcessStatus(StatusHalting, process.ID).
		Commit()

	return newState, nil
}

func (c *Controller) OnPidTerminated(pid int) {
	c.lockAndLoad(func(state *AppState) (*AppState, error) {
		process := state.GetProcessByPID(pid)
		newState, err := setProcessTerminated(state, process)
		if err != nil {
			log.Printf("Error setting process terminated for PID %d: %v", pid, err)
			return nil, err
		} else {
			err = SelectPane(c.tmuxContext.PaneID)
			if err != nil {
				log.Printf("Error selecting pane %s: %v", c.tmuxContext.PaneID, err)
				return nil, err
			}
		}
		return newState, nil
	})
}

func setProcessTerminated(state *AppState, process *Process) (*AppState, error) {
	if process == nil {
		log.Println("No process found for PID termination")
		return state, nil
	}

	if process.Status == StatusHalted {
		return state, nil
	}

	log.Printf("Process %s with PID %d has exited", process.Label, process.PID)
	newState := NewStateMutation(state).
		SetProcessStatus(StatusHalted, process.ID).
		SetProcessPID(-1, process.ID).
		Commit()

	return newState, nil
}

package proctmux

import (
	"log"
	"sync"
	"sync/atomic"
)

// StateUpdateMsg is sent when the AppState changes and the UI needs to refresh
type StateUpdateMsg struct {
	State *AppState
}

type Controller struct {
	state         *AppState
	stateMu       sync.Mutex
	running       *atomic.Bool
	pidCh         chan int
	uiSubscribers []chan<- StateUpdateMsg
	processServer *ProcessServer
	ttyViewer     *TTYViewer
}

func NewController(state *AppState, running *atomic.Bool) *Controller {
	server := NewProcessServer()
	viewer := NewTTYViewer(server)
	return &Controller{
		state:         state,
		running:       running,
		pidCh:         make(chan int, 64),
		processServer: server,
		ttyViewer:     viewer,
	}
}

func (c *Controller) LockAndLoad(f func(*AppState) (*AppState, error)) error {
	c.stateMu.Lock()
	defer c.stateMu.Unlock()
	newState, err := f(c.state)
	if err != nil {
		log.Printf("Error in controller operation: %v", err)
		return err
	}
	if newState != nil {
		c.state = newState
		// Notify UI subscribers about the state change
		c.EmitStateChangeNotification()
	}
	return nil
}

// SubscribeToStateChanges adds a channel that will receive state updates
func (c *Controller) SubscribeToStateChanges(ch chan<- StateUpdateMsg) {
	c.stateMu.Lock()
	defer c.stateMu.Unlock()
	c.uiSubscribers = append(c.uiSubscribers, ch)
}

// EmitStateChangeNotification sends state updates to all subscribers
func (c *Controller) EmitStateChangeNotification() {
	for _, ch := range c.uiSubscribers {
		select {
		case ch <- StateUpdateMsg{State: c.state}:
			// Update sent successfully
		default:
			// Channel full or closed, skip without blocking
		}
	}
}

// ApplySelection reflects a UI-selected process into the domain and switches TTY viewer.
// procID==0 clears selection.
func (c *Controller) ApplySelection(procID int) error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		if procID == 0 {
			state.CurrentProcID = 0
			return state, nil
		}
		if state.CurrentProcID == procID {
			return state, nil
		}
		mut := NewStateMutation(state)
		mut, err := mut.SelectProcessByID(procID)
		if err != nil {
			return state, err
		}
		newState := mut.Commit()

		proc := newState.GetProcessByID(procID)
		if proc != nil && proc.Status == StatusRunning {
			if err := c.ttyViewer.SwitchToProcess(proc.ID); err != nil {
				log.Printf("Error switching TTY viewer to %s: %v", proc.Label, err)
			}
		}

		return newState, nil
	})
}

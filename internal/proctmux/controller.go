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
	tmuxContext   *TmuxContext
	running       *atomic.Bool
	pidCh         chan int
	daemons       []*TmuxDaemon
	uiSubscribers []chan<- StateUpdateMsg
}

func NewController(state *AppState, tmuxContext *TmuxContext, running *atomic.Bool) *Controller {
	return &Controller{state: state, tmuxContext: tmuxContext, running: running, pidCh: make(chan int, 64)}
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

// ApplySelection reflects a UI-selected process into the domain and tmux panes.
// procID==0 clears selection and breaks current/dummy to detached if needed.
func (c *Controller) ApplySelection(procID int) error {
	return c.LockAndLoad(func(state *AppState) (*AppState, error) {
		if procID == 0 {
			c.breakCurrentPane(state, true)
			state.CurrentProcID = 0
			return state, nil
		}
		if state.CurrentProcID == procID {
			c.joinSelectedPane(state)
			return state, nil
		}
		c.breakCurrentPane(state, true)
		mut := NewStateMutation(state)
		mut, err := mut.SelectProcessByID(procID)
		if err != nil {
			return state, err
		}
		newState := mut.Commit()
		c.joinSelectedPane(newState)
		return newState, nil
	})
}

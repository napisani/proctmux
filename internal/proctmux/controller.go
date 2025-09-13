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

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
	ipcServer     *IPCServer
}

func NewController(state *AppState, running *atomic.Bool) *Controller {
	return &Controller{
		state:   state,
		running: running,
		pidCh:   make(chan int, 64),
	}
}

func (c *Controller) SetIPCServer(server *IPCServer) {
	c.stateMu.Lock()
	defer c.stateMu.Unlock()
	c.ipcServer = server
	server.SetController(c)
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

// ApplySelection reflects a UI-selected process into the domain and broadcasts to viewers.
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

		return newState, nil
	})
}

// OnStateUpdate handles full state updates from viewers
func (c *Controller) OnStateUpdate(newState *AppState) {
	if newState == nil {
		log.Printf("Received nil state update")
		return
	}

	c.stateMu.Lock()
	defer c.stateMu.Unlock()

	c.state = newState
	c.EmitStateChangeNotification()

	log.Printf("Applied state update with %d processes", len(newState.Processes))
}

// SendCommand sends a command to viewers via IPC
func (c *Controller) SendCommand(action string, procID int, config *ProcessConfig) error {
	if c.ipcServer == nil {
		return nil
	}
	return c.ipcServer.SendCommand(action, procID, config)
}

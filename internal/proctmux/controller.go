package proctmux

import (
	"log"
	"sync"
	"sync/atomic"
)

type Controller struct {
	state       *AppState
	stateMu     sync.Mutex
	tmuxContext *TmuxContext
	running     *atomic.Bool
	pidCh       chan int
	daemons     []*TmuxDaemon
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
	}
	return nil
}

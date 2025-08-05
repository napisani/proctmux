package main

import (
	"fmt"
	"sync"
	"sync/atomic"
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

func (c *Controller) lockAndLoad(f func(*AppState) error) error {
	c.stateMu.Lock()
	defer c.stateMu.Unlock()
	return f(c.state)
}

func (c *Controller) OnStartup() error {
	if err := c.tmuxContext.Prepare(); err != nil {
		return err
	}
	return c.lockAndLoad(func(state *AppState) error {
		for name, procCfg := range state.Config.Procs {
			if procCfg.Autostart {
				c.StartProcess(name)
			}
		}
		return nil
	})
}

func (c *Controller) OnExit() error {
	c.lockAndLoad(func(state *AppState) error {
		for _, p := range state.Processes {
			if p.Status == StatusRunning {
				c.StopProcess(p.Name)
			}
		}
		return nil
	})
	return c.tmuxContext.Cleanup()
}

func (c *Controller) OnKeypressDown() error {
	return c.lockAndLoad(func(state *AppState) error {
		if state.ActiveIdx < len(state.Processes)-1 {
			state.ActiveIdx++
			state.ActiveID = state.Processes[state.ActiveIdx].ID
		}
		return nil
	})
}

func (c *Controller) OnKeypressUp() error {
	return c.lockAndLoad(func(state *AppState) error {
		if state.ActiveIdx > 0 {
			state.ActiveIdx--
			state.ActiveID = state.Processes[state.ActiveIdx].ID
		}
		return nil
	})
}

func (c *Controller) OnKeypressStart() error {
	return c.lockAndLoad(func(state *AppState) error {
		if len(state.Processes) == 0 {
			return nil
		}
		name := state.Processes[state.ActiveIdx].Name
		c.StartProcess(name)
		return nil
	})
}

func (c *Controller) OnKeypressStop() error {
	return c.lockAndLoad(func(state *AppState) error {
		if len(state.Processes) == 0 {
			return nil
		}
		name := state.Processes[state.ActiveIdx].Name
		c.StopProcess(name)
		return nil
	})
}

func (c *Controller) OnKeypressQuit() error {
	return c.OnExit()
}

func (c *Controller) OnFilterStart() error {
	return c.lockAndLoad(func(state *AppState) error {
		state.EnteringFilterText = true
		state.FilterText = ""
		return nil
	})
}

func (c *Controller) OnFilterSet(text string) error {
	return c.lockAndLoad(func(state *AppState) error {
		state.FilterText = text
		return nil
	})
}

func (c *Controller) OnFilterDone() error {
	return c.lockAndLoad(func(state *AppState) error {
		state.EnteringFilterText = false
		return nil
	})
}

func (c *Controller) OnKeypressSwitchFocus() error {
	return nil
}

func (c *Controller) OnKeypressFocus() error {
	return c.lockAndLoad(func(state *AppState) error {
		if len(state.Processes) == 0 {
			return nil
		}
		p := state.Processes[state.ActiveIdx]
		return c.tmuxContext.FocusPane(p.PaneID)
	})
}

func (c *Controller) OnKeypressZoom() error {
	return c.lockAndLoad(func(state *AppState) error {
		if len(state.Processes) == 0 {
			return nil
		}
		p := state.Processes[state.ActiveIdx]
		return c.tmuxContext.ToggleZoom(p.PaneID)
	})
}

func (c *Controller) StartProcess(name string) {
	procCfg, ok := c.state.Config.Procs[name]
	if !ok {
		c.state.AddError(fmt.Errorf("process config not found for %s", name))
		return
	}
	cmd := procCfg.Shell
	if cmd == "" && len(procCfg.Cmd) > 0 {
		cmd = procCfg.Cmd[0]
	}
	args := []string{}
	if len(procCfg.Cmd) > 1 {
		args = procCfg.Cmd[1:]
	}
	cwd := procCfg.Cwd
	if cwd == "" {
		cwd = "."
	}
	env := map[string]string{}
	for k, v := range procCfg.Env {
		if v != nil {
			env[k] = *v
		} else {
			env[k] = ""
		}
	}
	paneID, err := c.tmuxContext.CreatePane(cmd, cwd, env)
	if err != nil {
		c.state.AddError(err)
		return
	}
	pid, err := c.tmuxContext.GetPanePID(paneID)
	if err != nil {
		pid = 0
	}
	categories := procCfg.Categories
	p := &Process{
		ID:         len(c.state.Processes),
		Name:       name,
		Cmd:        cmd,
		Args:       args,
		PID:        pid,
		PaneID:     paneID,
		Status:     StatusRunning,
		Categories: categories,
		Config:     &procCfg,
	}
	c.state.AddProcess(p)
	c.state.SetProcessStatus(p.ID, StatusRunning)
	c.state.SetProcessPID(p.ID, pid)
	c.state.SetProcessPaneID(p.ID, paneID)
	c.state.AddMessage("Started process: " + name)
}

func (c *Controller) StopProcess(name string) {
	for _, p := range c.state.Processes {
		if p.Name == name && p.Status == StatusRunning {
			err := KillPane(p.PaneID)
			if err == nil {
				c.state.SetProcessStatus(p.ID, StatusHalted)
				c.state.SetProcessPID(p.ID, 0)
				c.state.AddMessage("Stopped process: " + name)
			} else {
				c.state.AddError(err)
			}
		}
	}
}

func (c *Controller) OnPidTerminated(pid int) {
	c.lockAndLoad(func(state *AppState) error {
		for _, p := range state.Processes {
			if p.PID == pid && p.Status == StatusRunning {
				state.SetProcessStatus(p.ID, StatusExited)
				state.SetProcessPID(p.ID, 0)
				state.AddMessage("Process exited: " + p.Name)
				// Focus main pane after process exit
				c.tmuxContext.FocusPane(state.Processes[0].PaneID)
			}
		}
		return nil
	})
}

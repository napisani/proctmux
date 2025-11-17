package domain

import (
	"fmt"

	"github.com/nick/proctmux/internal/config"
)

type ProcessStatus int

const (
	StatusUnknown ProcessStatus = iota
	StatusRunning
	StatusHalting
	StatusHalted
	StatusExited
)

func (s ProcessStatus) String() string {
	switch s {
	case StatusRunning:
		return "Running"
	case StatusHalting:
		return "Halting"
	case StatusHalted:
		return "Halted"
	case StatusExited:
		return "Exited"
	default:
		return "Unknown"
	}
}

type Process struct {
	ID    int
	Label string
	// Status and PID are kept for backward compatibility with IPC protocol
	// These fields are synced from the process controller before broadcasting
	// DO NOT update these fields directly - they are derived from controller state
	// TODO: Phase 4 - Remove these fields and use ProcessView everywhere
	Status ProcessStatus
	PID    int
	Config *config.ProcessConfig
}

func NewFromProcessConfig(id int, label string, cfg *config.ProcessConfig) Process {
	return Process{
		ID:     id,
		Label:  label,
		Status: StatusHalted,
		PID:    -1,
		Config: cfg,
	}

}

func (p *Process) Command() string {
	if p.Config.Shell != "" {
		return p.Config.Shell
	}

	if len(p.Config.Cmd) == 0 {
		return ""
	}

	var result string
	for _, s := range p.Config.Cmd {
		result += fmt.Sprintf("'%s' ", s)
	}
	return result
}

// ProcessView combines static process configuration with live runtime state
// This is the type that should be used for display and IPC communication
// It derives PID and Status from the process controller rather than storing them
type ProcessView struct {
	ID     int
	Label  string
	Status ProcessStatus
	PID    int
	Config *config.ProcessConfig
}

// Command returns the command string for display purposes
func (pv *ProcessView) Command() string {
	if pv.Config.Shell != "" {
		return pv.Config.Shell
	}

	if len(pv.Config.Cmd) == 0 {
		return ""
	}

	var result string
	for _, s := range pv.Config.Cmd {
		result += fmt.Sprintf("'%s' ", s)
	}
	return result
}

// ProcessController defines the interface for querying live process state
// This avoids importing the process package directly and prevents circular dependencies
type ProcessController interface {
	GetProcessStatus(id int) ProcessStatus
	GetPID(id int) int
}

// ToView converts a Process to a ProcessView by querying the controller for live state
func (p *Process) ToView(pc ProcessController) ProcessView {
	status := ProcessStatus(StatusHalted)
	pid := -1

	if pc != nil {
		status = pc.GetProcessStatus(p.ID)
		pid = pc.GetPID(p.ID)
	} else {
		// Fallback to stored values if no controller is available
		status = p.Status
		pid = p.PID
	}

	return ProcessView{
		ID:     p.ID,
		Label:  p.Label,
		Status: status,
		PID:    pid,
		Config: p.Config,
	}
}

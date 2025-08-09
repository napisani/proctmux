package main

import "fmt"

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
	ID     int
	Label  string
	Status ProcessStatus
	PaneID string
	PID    int
	Config *ProcessConfig
}

func NewFromProcessConfig(id int, label string, cfg *ProcessConfig) Process {
	return Process{
		ID:     id,
		Label:  label,
		Status: StatusHalted,
		PaneID: "",
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

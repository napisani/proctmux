package main

const (
	StatusRunning = "Running"
	StatusHalting = "Halting"
	StatusHalted  = "Halted"
	StatusExited  = "Exited"
)

type Process struct {
	ID         int
	Name       string
	Cmd        string
	Args       []string
	PID        int
	PaneID     string
	Status     string // "Running", "Halting", "Halted", "Exited", etc.
	Categories []string
	Config     *ProcessConfig // Optional: pointer to config for this process
}

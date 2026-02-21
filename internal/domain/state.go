package domain

import (
	"sort"
	"strings"

	"github.com/nick/proctmux/internal/config"
)

// UI modes are kept for TUI usage; domain does not depend on them.
type Mode int

const (
	NormalMode Mode = iota
	FilterMode
)

// AppState contains only domain state; GUI state lives in the Bubble Tea model.
type AppState struct {
	Config        *config.ProcTmuxConfig
	CurrentProcID int
	Processes     []Process
	Exiting       bool
}

const DummyProcessID = 1

func NewAppState(cfg *config.ProcTmuxConfig) AppState {
	s := AppState{
		Config:        cfg,
		CurrentProcID: 0,
		Processes:     []Process{},
		Exiting:       false,
	}

	proc := NewFromProcessConfig(DummyProcessID, "Dummy", &config.ProcessConfig{
		Cmd:       []string{},
		Autostart: true,
	})

	var echo strings.Builder
	echo.WriteString(" echo \"\"; ")

	banner := cfg.Layout.PlaceholderBanner
	for line := range strings.SplitSeq(banner, "\n") {
		if strings.TrimSpace(line) != "" {
			echo.WriteString("echo \"" + line + "\"; ")
		}
	}

	proc.Config.Cmd = []string{"bash", "-c", echo.String()}

	s.Processes = append(s.Processes, proc)

	i := 2
	for k, proc := range cfg.Procs {
		proc := NewFromProcessConfig(i, k, &proc)
		s.Processes = append(s.Processes, proc)
		i++
	}

	// Optional alphabetical sort of process list
	if cfg.Layout.SortProcessListAlpha {
		sort.Slice(s.Processes, func(i, j int) bool { return s.Processes[i].Label < s.Processes[j].Label })
	}

	return s
}

func (s *AppState) GetProcessByID(id int) *Process {
	for i, p := range s.Processes {
		if p.ID == id {
			return &s.Processes[i]
		}
	}
	return nil
}

func (s *AppState) GetProcessByLabel(label string) *Process {
	for i, p := range s.Processes {
		if p.Label == label {
			return &s.Processes[i]
		}
	}
	return nil
}

// StateUpdate carries a full state update and computed views over IPC
// Used by clients to consume updates as a single atomic unit.
type StateUpdate struct {
	State        *AppState
	ProcessViews []ProcessView
}

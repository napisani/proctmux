package domain

import (
	"sort"

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

func NewAppState(cfg *config.ProcTmuxConfig) AppState {
	s := AppState{
		Config:        cfg,
		CurrentProcID: 0,
		Processes:     []Process{},
		Exiting:       false,
	}

	keys := make([]string, 0, len(cfg.Procs))
	for label := range cfg.Procs {
		keys = append(keys, label)
	}
	sort.Strings(keys)

	i := 1
	for _, label := range keys {
		procCfg := cfg.Procs[label]
		proc := NewFromProcessConfig(i, label, &procCfg)
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

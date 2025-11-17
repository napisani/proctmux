package domain

import (
	"log"
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

	echo := " echo \"\"; "

	banner := cfg.Layout.PlaceholderBanner
	for _, line := range strings.Split(banner, "\n") {
		if strings.TrimSpace(line) != "" {
			echo += "echo \"" + line + "\"; "
		}
	}

	proc.Config.Cmd = []string{"bash", "-c", echo}

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


// SelectFirstProcess selects the first non-dummy process by current ordering.
func (s *AppState) SelectFirstProcess() *AppState {
	for i := range s.Processes {
		if s.Processes[i].ID != DummyProcessID {
			s.CurrentProcID = s.Processes[i].ID
			log.Printf("Selecting first process with ID %d", s.CurrentProcID)
			return s
		}
	}
	log.Printf("No processes available to select")
	return s
}

// GetProcessView returns a ProcessView for the given process ID
// The ProcessView combines static config with live state from the controller
func (s *AppState) GetProcessView(pc ProcessController, id int) *ProcessView {
	proc := s.GetProcessByID(id)
	if proc == nil {
		return nil
	}
	view := proc.ToView(pc)
	return &view
}

// GetAllProcessViews returns ProcessViews for all processes
func (s *AppState) GetAllProcessViews(pc ProcessController) []ProcessView {
	views := make([]ProcessView, len(s.Processes))
	for i, proc := range s.Processes {
		views[i] = proc.ToView(pc)
	}
	return views
}

package proctmux

import (
	"log"
	"sort"
	"strings"
)

// UI modes are kept for TUI usage; domain does not depend on them.
type Mode int

const (
	NormalMode Mode = iota
	FilterMode
)

// AppState contains only domain state; GUI state lives in the Bubble Tea model.
type AppState struct {
	Config        *ProcTmuxConfig
	CurrentProcID int
	Processes     []Process
	Exiting       bool
}

const DummyProcessID = 1

func NewAppState(cfg *ProcTmuxConfig) AppState {
	s := AppState{
		Config:        cfg,
		CurrentProcID: 0,
		Processes:     []Process{},
		Exiting:       false,
	}

	proc := NewFromProcessConfig(DummyProcessID, "Dummy", &ProcessConfig{
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

func (s *AppState) SetProcessStatus(id int, status ProcessStatus) {
	if p := s.GetProcessByID(id); p != nil {
		p.Status = status
	}
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


func fuzzyMatch(a, b string) bool {
	a = strings.ToLower(a)
	b = strings.ToLower(b)
	return strings.Contains(a, b) || strings.Contains(b, a)
}

// FilterProcesses is a pure helper to compute a filtered/sorted view from domain state and UI filter text.
func FilterProcesses(cfg *ProcTmuxConfig, processes []Process, filterText string) []*Process {
	var out []*Process
	prefix := cfg.Layout.CategorySearchPrefix
	ft := strings.TrimSpace(filterText)
	if ft == "" {
		for i := range processes {
			if processes[i].ID != DummyProcessID {
				out = append(out, &processes[i])
			}
		}
	} else if strings.HasPrefix(ft, prefix) {
		cats := strings.Split(strings.TrimPrefix(ft, prefix), ",")
		for i := range processes {
			if processes[i].ID == DummyProcessID {
				continue
			}
			match := true
			for _, cat := range cats {
				cat = strings.TrimSpace(cat)
				found := false
				for _, c := range processes[i].Config.Categories {
					if fuzzyMatch(c, cat) {
						found = true
						break
					}
				}
				if !found {
					match = false
					break
				}
			}
			if match {
				out = append(out, &processes[i])
			}
		}
	} else {
		for i := range processes {
			if processes[i].ID == DummyProcessID {
				continue
			}
			if fuzzyMatch(processes[i].Label, ft) {
				out = append(out, &processes[i])
			}
		}
	}
	if cfg.Layout.SortProcessListRunningFirst {
		sort.SliceStable(out, func(i, j int) bool {
			ai := out[i].Status == StatusRunning
			aj := out[j].Status == StatusRunning
			if ai != aj {
				return ai
			}
			if cfg.Layout.SortProcessListAlpha {
				return out[i].Label < out[j].Label
			}
			return false
		})
	} else if cfg.Layout.SortProcessListAlpha {
		sort.SliceStable(out, func(i, j int) bool { return out[i].Label < out[j].Label })
	}
	return out
}

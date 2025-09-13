package proctmux

import (
	"log"
	"sort"
	"strings"
)

type Mode int

const (
	NormalMode Mode = iota
	FilterMode
)

type GUIState struct {
	Messages           []string
	FilterText         string
	EnteringFilterText bool
	Info               string
	Mode               Mode
}

type AppState struct {
	Config        *ProcTmuxConfig
	CurrentProcID int
	Processes     []Process
	GUIState
	Exiting   bool
	ActiveIdx int
}

const DummyProcessID = 1

func NewAppState(cfg *ProcTmuxConfig) AppState {
	s := AppState{
		Config:        cfg,
		CurrentProcID: 0,
		Processes:     []Process{},
		GUIState: GUIState{
			Messages:           []string{},
			FilterText:         "",
			EnteringFilterText: false,
		},

		Exiting: false,
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

func (s *AppState) GetDummyProcess() *Process {
	return s.GetProcessByID(DummyProcessID)
}

func (s *AppState) GetProcessByID(id int) *Process {
	for i, p := range s.Processes {
		if p.ID == id {
			return &s.Processes[i]
		}
	}
	return nil
}

func (s *AppState) GetProcessByPID(pid int) *Process {
	for i, p := range s.Processes {
		if p.PID == pid {
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

func (s *AppState) GetCurrentProcess() *Process {
	if s.CurrentProcID == 0 {
		return nil
	}
	return s.GetProcessByID(s.CurrentProcID)
}

func (s *AppState) SetProcessStatus(id int, status ProcessStatus) {
	proc := s.GetProcessByID(id)
	proc.Status = status
}

func (s *AppState) SetProcessPaneID(id int, paneID string) {
	proc := s.GetProcessByID(id)
	proc.PaneID = paneID
}

func (s *AppState) AddMessage(msg string) {
	s.GUIState.Messages = append(s.GUIState.Messages, msg)
}

func (s *AppState) AddError(err error) {
	msg := "Error: " + err.Error()
	s.GUIState.Messages = append(s.GUIState.Messages, msg)
}

// Helper function to filter by category
func filterByCategory(filterText string, proc *Process) bool {
	if proc.Config.Categories == nil {
		return false
	}

	for _, category := range proc.Config.Categories {
		if strings.ToLower(category) == filterText {
			return true
		}
	}

	return false
}

// Helper function to filter by name or meta tags
func filterByNameOrMetaTags(filterText string, proc *Process) bool {
	// Check if process label contains filter text
	if strings.Contains(strings.ToLower(proc.Label), strings.ToLower(filterText)) {
		return true
	}

	// Check meta tags if they exist
	if proc.Config.MetaTags != nil {
		for _, tag := range proc.Config.MetaTags {
			if strings.ToLower(tag) == strings.ToLower(filterText) {
				return true
			}
		}
	}

	return false
}

func (s *AppState) SelectFirstProcess() *AppState {

	filteredProcs := s.GetFilteredProcesses()
	if len(filteredProcs) > 0 {
		s.CurrentProcID = filteredProcs[0].ID
		log.Printf("Selecting first process with ID %d", s.CurrentProcID)
	} else {
		log.Printf("No processes available to select")
	}
	return s

}

func (s *AppState) MoveProcessSelection(directionNum int) *AppState {
	log.Printf("move direction: %d", directionNum)
	filteredProcs := s.GetFilteredProcesses()
	if len(filteredProcs) == 0 {
		return s
	}
	if len(filteredProcs) == 1 {
		return s.SelectFirstProcess()
	}
	// Build ids and locate current index
	availableProcIDs := make([]int, len(filteredProcs))
	currentIdx := -1
	for i, p := range filteredProcs {
		availableProcIDs[i] = p.ID
		if p.ID == s.CurrentProcID {
			currentIdx = i
		}
	}
	if currentIdx == -1 {
		return s.SelectFirstProcess()
	}
	newIdx := currentIdx + directionNum
	if newIdx < 0 {
		newIdx = len(filteredProcs) - 1
	} else {
		newIdx = newIdx % len(filteredProcs)
	}
	s.CurrentProcID = availableProcIDs[newIdx]
	return s
}

func fuzzyMatch(a, b string) bool {
	a = strings.ToLower(a)
	b = strings.ToLower(b)
	return strings.Contains(a, b) || strings.Contains(b, a)
}

func (s *AppState) GetFilteredProcesses() []*Process {
	var out []*Process
	prefix := s.Config.Layout.CategorySearchPrefix
	if strings.TrimSpace(s.GUIState.FilterText) == "" {
		for i := range s.Processes {
			if s.Processes[i].ID != DummyProcessID {
				out = append(out, &s.Processes[i])
			}
		}
	} else if strings.HasPrefix(s.GUIState.FilterText, prefix) {

		cats := strings.Split(strings.TrimPrefix(s.GUIState.FilterText, prefix), ",")
		for i := range s.Processes {
			if s.Processes[i].ID == DummyProcessID {
				continue
			}
			match := true
			for _, cat := range cats {
				cat = strings.TrimSpace(cat)
				found := false
				for _, c := range s.Processes[i].Config.Categories {
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
				out = append(out, &s.Processes[i])
			}
		}
	} else {
		for i := range s.Processes {
			if s.Processes[i].ID == DummyProcessID {
				continue
			}
			if fuzzyMatch(s.Processes[i].Label, s.GUIState.FilterText) {
				out = append(out, &s.Processes[i])
			}
		}
	}
	// Apply sorting based on config
	if s.Config.Layout.SortProcessListRunningFirst {
		sort.SliceStable(out, func(i, j int) bool {
			ai := out[i].Status == StatusRunning
			aj := out[j].Status == StatusRunning
			if ai != aj {
				return ai
			}
			if s.Config.Layout.SortProcessListAlpha {
				return out[i].Label < out[j].Label
			}
			return false
		})
	} else if s.Config.Layout.SortProcessListAlpha {
		sort.SliceStable(out, func(i, j int) bool { return out[i].Label < out[j].Label })
	}
	return out
}

func (s *AppState) UpdateFilterText(newText string) {
	if s.GUIState.FilterText != newText {
		s.GUIState.FilterText = newText
		s.CurrentProcID = -1
	}
}

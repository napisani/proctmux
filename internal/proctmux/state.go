package proctmux

import (
	"log"
	"sort"
	"strings"
)

type GUIState struct {
	Messages           []string
	FilterText         string
	EnteringFilterText bool
	Info               string
}

type AppState struct {
	Config        *ProcTmuxConfig
	CurrentProcID int
	Processes     []Process
	GUIState      GUIState
	Exiting       bool
}

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

	i := 1
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

func (s *AppState) GetProcessByPID(pid int) *Process {
	for i, p := range s.Processes {
		if p.PID == pid {
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

func (s *AppState) GetFilteredProcesses() []Process {
	// If no filter text, return all processes
	if strings.TrimSpace(s.GUIState.FilterText) == "" {
		return s.Processes
	}

	filterText := s.GUIState.FilterText
	prefix := s.Config.Layout.CategorySearchPrefix

	var filtered []Process
	for _, proc := range s.Processes {
		if strings.HasPrefix(filterText, prefix) {
			categoryFilter := strings.ToLower(strings.TrimSpace(filterText[len(prefix):]))
			if filterByCategory(categoryFilter, &proc) {
				filtered = append(filtered, proc)
			}
		} else {
			if filterByNameOrMetaTags(filterText, &proc) {
				filtered = append(filtered, proc)
			}
		}
	}
	return filtered
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

package main

import (
	"log"
	"strings"
)

type GUIState struct {
	Messages           []string
	FilterText         string
	EnteringFilterText bool
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
	// If not filtering, return all processes
	if s.GUIState.FilterText == "" || !s.GUIState.EnteringFilterText {
		return s.Processes
	}

	filterText := s.GUIState.FilterText
	prefix := s.Config.Layout.CategorySearchPrefix

	var filtered []Process

	for _, proc := range s.Processes {
		// Check if filtering by category
		if strings.HasPrefix(filterText, prefix) {
			categoryFilter := strings.ToLower(filterText[len(prefix):])
			if filterByCategory(categoryFilter, &proc) {
				filtered = append(filtered, proc)
			}
		} else {
			// Filter by name or meta tags
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
	// Get filtered processes
	filteredProcs := s.GetFilteredProcesses()
	if len(filteredProcs) == 0 {
		log.Printf("No processes after filtering - no state changes")
		return s
	}
	if len(filteredProcs) == 1 {
		log.Printf("Only one process after filtering - selecting first process")
		return s.SelectFirstProcess()
	}

	availableProcIDs := make([]int, len(filteredProcs))
	currentIdx := -1
	for _, p := range filteredProcs {
		availableProcIDs = append(availableProcIDs, p.ID)
		if p.ID == s.CurrentProcID {
			currentIdx = p.ID
		}
	}
	log.Printf("availableProcIDs: %+v", availableProcIDs)
	log.Printf("currentIdx: %d", currentIdx)

	if currentIdx == -1 {
		log.Printf("Current process not in filtered list - selecting first process")
		return s.SelectFirstProcess()
	}

	newIdx := (currentIdx + directionNum) % len(filteredProcs)
	log.Printf("newIdx: %d", newIdx)
	if newIdx < 0 {
		newIdx = len(filteredProcs) - 1
	}
	newProc := filteredProcs[newIdx]
	s.CurrentProcID = newProc.ID
	return s

}

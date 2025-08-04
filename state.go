package main

// Updated AppState to match Rust logic and support TUI controller

type AppState struct {
	Processes          []*Process
	ActiveIdx          int // Index of currently selected process
	ActiveID           int // ID of currently selected process (for parity)
	Config             *ProcTmuxConfig
	Exiting            bool
	Messages           []string // Info and error messages for the UI
	EnteringFilterText bool
	FilterText         string
	Info               string // Current info message
}

func NewAppState(cfg *ProcTmuxConfig) *AppState {
	return &AppState{
		Processes: []*Process{},
		ActiveIdx: 0,
		ActiveID:  0,
		Config:    cfg,
		Messages:  []string{},
	}
}

func (s *AppState) AddProcess(p *Process) {
	p.ID = len(s.Processes)
	s.Processes = append(s.Processes, p)
	s.ActiveIdx = len(s.Processes) - 1
	s.ActiveID = p.ID
}

func (s *AppState) SetProcessStatus(id int, status string) {
	for _, p := range s.Processes {
		if p.ID == id {
			p.Status = status
			return
		}
	}
}

func (s *AppState) SetProcessPID(id int, pid int) {
	for _, p := range s.Processes {
		if p.ID == id {
			p.PID = pid
			return
		}
	}
}

func (s *AppState) SetProcessPaneID(id int, paneID string) {
	for _, p := range s.Processes {
		if p.ID == id {
			p.PaneID = paneID
			return
		}
	}
}

func (s *AppState) AddMessage(msg string) {
	s.Messages = append(s.Messages, msg)
	s.Info = msg
}

func (s *AppState) AddError(err error) {
	msg := "Error: " + err.Error()
	s.Messages = append(s.Messages, msg)
	s.Info = msg
}

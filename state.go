package main

type AppState struct {
	Processes          []*Process
	ActiveIdx          int
	ActiveID           int
	Config             *ProcTmuxConfig
	Exiting            bool
	Messages           []string
	EnteringFilterText bool
	FilterText         string
	Info               string
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

func (s *AppState) SetProcessStatus(id int, status ProcessStatus) {
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

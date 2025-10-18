package proctmux

import (
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

type UIState struct {
	Messages           []string
	FilterText         string
	EnteringFilterText bool
	Info               string
	Mode               Mode
	ActiveProcID       int
}

type applyFilterMsg struct{ seq int }

type applySelectionMsg struct {
	seq    int
	procID int
}

func debounceFilter(seq int) tea.Cmd {
	return tea.Tick(150*time.Millisecond, func(time.Time) tea.Msg { return applyFilterMsg{seq: seq} })
}

func debounceSelection(seq, procID int) tea.Cmd {
	return tea.Tick(120*time.Millisecond, func(time.Time) tea.Msg { return applySelectionMsg{seq: seq, procID: procID} })
}

func contains(slice []string, s string) bool {
	for _, v := range slice {
		if v == s {
			return true
		}
	}
	return false
}

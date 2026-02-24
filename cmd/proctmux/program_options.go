package main

import (
	"os"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

func bubbleTeaProgramOptions() []tea.ProgramOption {
	if disableAltScreen() {
		return nil
	}
	return []tea.ProgramOption{tea.WithAltScreen()}
}

func disableAltScreen() bool {
	value, ok := os.LookupEnv("PROCTMUX_NO_ALTSCREEN")
	if !ok {
		return false
	}

	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "0", "false", "no":
		return false
	default:
		return true
	}
}

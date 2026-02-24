package main

import (
	"os"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

func bubbleTeaProgramOptions() []tea.ProgramOption {
	// Explicitly pass stdin and stdout so Bubble Tea does not try to open
	// /dev/tty. This is required when the process is spawned inside a PTY
	// by the unified-toggle coordinator, where /dev/tty may not be available.
	opts := []tea.ProgramOption{
		tea.WithInput(os.Stdin),
		tea.WithOutput(os.Stdout),
	}
	if disableAltScreen() {
		return opts
	}
	return append(opts, tea.WithAltScreen())
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

package proctmux

import "os"

// tmuxBin returns the tmux binary path. Tests can override via PROCTMUX_TMUX_BIN.
func tmuxBin() string {
	if v := os.Getenv("PROCTMUX_TMUX_BIN"); v != "" {
		return v
	}
	return "tmux"
}

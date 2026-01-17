//go:build integration

package e2e_test

import "testing"

func TestUnifiedErrorMessageExpires(t *testing.T) {
	t.Skip("unified e2e pending deterministic TUI synchronization")
}

func TestPrimaryClientStartProcess(t *testing.T) {
	t.Skip("primary/client e2e pending tmux stub implementation")
}

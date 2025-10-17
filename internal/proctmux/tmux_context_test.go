package proctmux

import (
	"path/filepath"
	"testing"
)

func TestTmuxContextCreatePaneWithMock(t *testing.T) {
	// point to mock tmux
	mock := filepath.Join("testdata", "tmux-mock.sh")
	t.Setenv("PROCTMUX_TMUX_BIN", mock)
	// Construct via real constructor (uses mock outputs)
	ctx, err := NewTmuxContext("_proctmux", false, 30)
	if err != nil {
		t.Fatalf("NewTmuxContext error: %v", err)
	}
	p := NewFromProcessConfig(2, "echoA", &ProcessConfig{Cmd: []string{"echo", "A"}, Cwd: "."})
	pane, pid, err := ctx.CreatePane(&p)
	if err != nil {
		t.Fatalf("CreatePane error: %v", err)
	}
	if pane == "" || pid <= 0 {
		t.Fatalf("unexpected pane or pid: %q %d", pane, pid)
	}
}

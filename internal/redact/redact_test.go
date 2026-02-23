package redact

import (
	"testing"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
)

type stubProcessController struct{}

func (stubProcessController) GetProcessStatus(id int) domain.ProcessStatus {
	return domain.StatusRunning
}
func (stubProcessController) GetPID(id int) int { return 1234 }

func TestStateForIPC_RedactsSensitiveFields(t *testing.T) {
	original := &domain.AppState{
		Config: &config.ProcTmuxConfig{
			FilePath: "test.yml",
			ShellCmd: []string{"/bin/sh", "-c"},
			Procs: map[string]config.ProcessConfig{
				"api": {
					Shell:    "run api",
					Env:      map[string]string{"TOKEN": "secret"},
					MetaTags: []string{"svc"},
				},
			},
		},
		Processes: []domain.Process{
			{
				ID:    1,
				Label: "api",
				Config: &config.ProcessConfig{
					Env: map[string]string{"PASSWORD": "hunter2"},
				},
			},
		},
	}

	pc := stubProcessController{}
	redactedState, processViews := StateForIPC(original, pc)

	if redactedState == nil {
		t.Fatal("expected redacted state")
	}

	if redactedState == original {
		t.Fatal("expected state copy, got same pointer")
	}

	if redactedState.Config == nil {
		t.Fatalf("expected config copy")
	}

	if redactedState.Config.Procs["api"].Env != nil {
		t.Fatalf("global config env should be redacted")
	}

	if len(redactedState.Processes) != 1 {
		t.Fatalf("expected one process, got %d", len(redactedState.Processes))
	}

	if redactedState.Processes[0].Config == nil || redactedState.Processes[0].Config.Env != nil {
		t.Fatalf("process config env should be redacted")
	}

	if len(processViews) != 1 {
		t.Fatalf("expected one process view, got %d", len(processViews))
	}

	if processViews[0].Config == nil || processViews[0].Config.Env != nil {
		t.Fatalf("process view config env should be redacted")
	}

	if original.Config.Procs["api"].Env == nil || original.Processes[0].Config.Env == nil {
		t.Fatalf("original state should remain unchanged")
	}
}

func TestCloneStringSliceReturnsCopy(t *testing.T) {
	vals := []string{"a", "b"}
	clone := cloneStringSlice(vals)
	if &vals[0] == &clone[0] {
		t.Fatalf("expected copy of slice, not shared backing array")
	}
	clone[0] = "z"
	if vals[0] != "a" {
		t.Fatalf("modifying clone should not change original slice")
	}
}

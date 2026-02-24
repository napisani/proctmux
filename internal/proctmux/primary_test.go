package proctmux

import (
	"testing"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
	"github.com/nick/proctmux/internal/protocol"
)

// mockIPCServer satisfies IPCServerInterface for testing.
type mockIPCServer struct {
	started        bool
	primarySet     bool
	broadcastCount int
	stopped        bool
}

func (m *mockIPCServer) Start(_ string) error {
	m.started = true
	return nil
}

func (m *mockIPCServer) SetPrimaryServer(_ interface {
	HandleCommand(action protocol.Command, label string) error
	GetState() *domain.AppState
	GetProcessController() domain.ProcessController
}) {
	m.primarySet = true
}

func (m *mockIPCServer) BroadcastState(_ *domain.AppState, _ domain.ProcessController) {
	m.broadcastCount++
}

func (m *mockIPCServer) Stop() {
	m.stopped = true
}

func testPrimaryConfig() *config.ProcTmuxConfig {
	return &config.ProcTmuxConfig{
		FilePath: "test.yaml",
		Procs: map[string]config.ProcessConfig{
			"test": {Shell: "echo hello"},
		},
	}
}

func TestNewPrimaryServer_DefaultOptions(t *testing.T) {
	cfg := testPrimaryConfig()
	ipc := &mockIPCServer{}

	ps := NewPrimaryServer(cfg, ipc)

	if ps.viewer == nil {
		t.Error("expected viewer to be created with default options")
	}
	if ps.opts.SkipStdinForwarder {
		t.Error("expected SkipStdinForwarder to be false by default")
	}
}

func TestNewPrimaryServerWithOptions_SkipStdinForwarder(t *testing.T) {
	cfg := testPrimaryConfig()
	ipc := &mockIPCServer{}

	ps := NewPrimaryServerWithOptions(cfg, ipc, PrimaryServerOptions{
		SkipStdinForwarder: true,
	})

	// Start should not set terminal to raw mode or start stdin forwarder.
	// We verify by checking that originalTermState remains nil after Start.
	if err := ps.Start(""); err != nil {
		t.Fatalf("Start failed: %v", err)
	}
	defer ps.Stop()

	if ps.originalTermState != nil {
		t.Error("expected originalTermState to be nil when SkipStdinForwarder is true")
	}
}

func TestPrimaryServer_GetRawProcessController(t *testing.T) {
	cfg := testPrimaryConfig()
	ipc := &mockIPCServer{}

	ps := NewPrimaryServerWithOptions(cfg, ipc, PrimaryServerOptions{
		SkipStdinForwarder: true,
	})

	pc := ps.GetRawProcessController()
	if pc == nil {
		t.Error("expected GetRawProcessController to return non-nil controller")
	}
}

func TestPrimaryServer_GetViewer(t *testing.T) {
	cfg := testPrimaryConfig()
	ipc := &mockIPCServer{}

	ps := NewPrimaryServer(cfg, ipc)

	v := ps.GetViewer()
	if v == nil {
		t.Error("expected GetViewer to return non-nil viewer")
	}
}

func TestPrimaryServer_IPCServerInteraction(t *testing.T) {
	cfg := testPrimaryConfig()
	ipc := &mockIPCServer{}

	ps := NewPrimaryServerWithOptions(cfg, ipc, PrimaryServerOptions{
		SkipStdinForwarder: true,
	})

	if err := ps.Start(""); err != nil {
		t.Fatalf("Start failed: %v", err)
	}
	defer ps.Stop()

	if !ipc.started {
		t.Error("expected IPC server to be started")
	}
	if !ipc.primarySet {
		t.Error("expected SetPrimaryServer to be called")
	}
}

package ipc

import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"testing"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
)

func TestRegisterClientRejectsUnauthorizedPeer(t *testing.T) {
	s := NewServer()
	s.allowedUID = os.Geteuid()
	orig := authorizePeerConn
	authorizePeerConn = func(conn net.Conn, expectedUID int) error {
		return errors.New("unauthorized")
	}
	t.Cleanup(func() {
		authorizePeerConn = orig
	})

	client, server := net.Pipe()
	defer client.Close()
	server.Close()

	if _, err := s.registerClient(client); err == nil {
		t.Fatalf("expected registerClient to fail when authorization fails")
	}

	if s.clientCount() != 0 {
		t.Fatalf("expected zero registered clients, got %d", s.clientCount())
	}
}

func TestRegisterClientStoresAuthorizedPeer(t *testing.T) {
	s := NewServer()
	s.allowedUID = os.Geteuid()
	orig := authorizePeerConn
	authorizePeerConn = func(conn net.Conn, expectedUID int) error {
		if expectedUID != s.allowedUID {
			t.Fatalf("expected UID %d to be passed, got %d", s.allowedUID, expectedUID)
		}
		return nil
	}
	t.Cleanup(func() {
		authorizePeerConn = orig
	})

	client, server := net.Pipe()
	defer client.Close()
	server.Close()

	cc, err := s.registerClient(client)
	if err != nil {
		t.Fatalf("registerClient returned error: %v", err)
	}
	if cc == nil || cc.Conn == nil {
		t.Fatalf("expected clientConn to wrap the net.Conn")
	}
	if s.clientCount() != 1 {
		t.Fatalf("expected one registered client, got %d", s.clientCount())
	}
}

type fakeProcessController struct{}

func (f *fakeProcessController) GetProcessStatus(id int) domain.ProcessStatus {
	return domain.StatusRunning
}

func (f *fakeProcessController) GetPID(id int) int {
	return 123
}

func TestBuildStateMessageRedactsEnvironment(t *testing.T) {
	state := &domain.AppState{
		Config: &config.ProcTmuxConfig{
			FilePath: "test",
			Procs: map[string]config.ProcessConfig{
				"web": {
					Shell: "run",
					Env:   map[string]string{"SECRET": "value"},
				},
			},
		},
		Processes: []domain.Process{
			{
				ID:    1,
				Label: "Dummy",
				Config: &config.ProcessConfig{
					Env: map[string]string{"TOKEN": "abc"},
				},
			},
		},
	}

	pc := &fakeProcessController{}
	data, err := buildStateMessage(state, pc)
	if err != nil {
		t.Fatalf("buildStateMessage error: %v", err)
	}
	var msg Message
	if err := json.Unmarshal(data, &msg); err != nil {
		t.Fatalf("failed to unmarshal state message: %v", err)
	}

	if msg.State == nil {
		t.Fatalf("expected state payload")
	}

	if msg.State.Config == nil || msg.State.Config.Procs["web"].Env != nil {
		t.Fatalf("expected config env to be redacted")
	}

	if len(msg.State.Processes) == 0 || msg.State.Processes[0].Config == nil {
		t.Fatalf("expected process config to be present")
	}

	if msg.State.Processes[0].Config.Env != nil {
		t.Fatalf("expected process env to be redacted")
	}

	if len(msg.ProcessViews) == 0 || msg.ProcessViews[0].Config == nil {
		t.Fatalf("expected process view to include config")
	}

	if msg.ProcessViews[0].Config.Env != nil {
		t.Fatalf("expected process view env to be redacted")
	}

	if state.Processes[0].Config.Env == nil {
		t.Fatalf("original state should remain unchanged")
	}
}

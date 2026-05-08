package phase3

import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"testing"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/ipc"
	"github.com/nick/proctmux/internal/protocol"
)

func marshalLine(t *testing.T, msg ipc.Message) string {
	t.Helper()
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	data = append(data, '\n')
	return string(data)
}

func TestGoReferenceCommandConstants(t *testing.T) {
	tests := map[protocol.Command]string{
		protocol.CommandStart:          "start",
		protocol.CommandStop:           "stop",
		protocol.CommandRestart:        "restart",
		protocol.CommandSwitch:         "switch",
		protocol.CommandRestartRunning: "restart-running",
		protocol.CommandStopRunning:    "stop-running",
		protocol.CommandList:           "list",
	}

	for command, want := range tests {
		if got := command.String(); got != want {
			t.Fatalf("expected %q, got %q", want, got)
		}
	}
}

func TestGoReferenceCommandRequestMessageShape(t *testing.T) {
	line := marshalLine(t, ipc.Message{
		Type:      "command",
		RequestID: "42",
		Label:     "web",
		Action:    protocol.CommandStart.String(),
	})

	want := "{\"type\":\"command\",\"request_id\":\"42\",\"label\":\"web\",\"action\":\"start\"}\n"
	if line != want {
		t.Fatalf("command JSON mismatch:\nwant %q\n got %q", want, line)
	}
}

func TestGoReferenceCommandRequestOmitsEmptyLabel(t *testing.T) {
	line := marshalLine(t, ipc.Message{
		Type:      "command",
		RequestID: "7",
		Action:    protocol.CommandList.String(),
	})

	want := "{\"type\":\"command\",\"request_id\":\"7\",\"action\":\"list\"}\n"
	if line != want {
		t.Fatalf("command JSON mismatch:\nwant %q\n got %q", want, line)
	}
}

func TestGoReferenceCommandRequestEscapesStrings(t *testing.T) {
	line := marshalLine(t, ipc.Message{
		Type:      "command",
		RequestID: "44",
		Label:     `web "quoted" \ worker`,
		Action:    protocol.CommandStart.String(),
	})

	want := `{"type":"command","request_id":"44","label":"web \"quoted\" \\ worker","action":"start"}` + "\n"
	if line != want {
		t.Fatalf("command JSON mismatch:\nwant %q\n got %q", want, line)
	}
}

func TestGoReferenceResponseMessageShapes(t *testing.T) {
	success := marshalLine(t, ipc.Message{
		Type:      "response",
		RequestID: "42",
		Success:   true,
	})
	if want := "{\"type\":\"response\",\"request_id\":\"42\",\"success\":true}\n"; success != want {
		t.Fatalf("success response JSON mismatch:\nwant %q\n got %q", want, success)
	}

	failure := marshalLine(t, ipc.Message{
		Type:      "response",
		RequestID: "43",
		Error:     "missing process name",
	})
	if want := "{\"type\":\"response\",\"request_id\":\"43\",\"error\":\"missing process name\"}\n"; failure != want {
		t.Fatalf("failure response JSON mismatch:\nwant %q\n got %q", want, failure)
	}
}

func TestGoReferenceProcessListResponseShape(t *testing.T) {
	line := marshalLine(t, ipc.Message{
		Type:      "response",
		RequestID: "9",
		ProcessList: []map[string]any{
			{"name": "web", "running": true, "index": 0},
			{"name": "worker", "running": false, "index": 1},
		},
		Success: true,
	})

	want := `{"type":"response","request_id":"9","process_list":[{"index":0,"name":"web","running":true},{"index":1,"name":"worker","running":false}],"success":true}` + "\n"
	if line != want {
		t.Fatalf("process list response JSON mismatch:\nwant %q\n got %q", want, line)
	}
}

func TestGoReferenceCreateSocketRemovesStaleFile(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		FilePath: "/tmp/proctmux-go-ipc-create-test.yaml",
	}

	path, err := ipc.CreateSocket(cfg)
	if err != nil {
		t.Fatalf("CreateSocket path: %v", err)
	}
	defer os.Remove(path)

	file, err := os.Create(path)
	if err != nil {
		t.Fatalf("create stale socket placeholder: %v", err)
	}
	if err := file.Close(); err != nil {
		t.Fatalf("close stale socket placeholder: %v", err)
	}

	got, err := ipc.CreateSocket(cfg)
	if err != nil {
		t.Fatalf("CreateSocket cleanup: %v", err)
	}
	if got != path {
		t.Fatalf("expected stable socket path %q, got %q", path, got)
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expected stale socket placeholder removed, stat error: %v", err)
	}
}

func TestGoReferenceGetSocketRequiresResponsiveUnixSocket(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		FilePath: "/tmp/proctmux-go-ipc-get-test.yaml",
	}

	path, err := ipc.CreateSocket(cfg)
	if err != nil {
		t.Fatalf("CreateSocket path: %v", err)
	}
	defer os.Remove(path)

	if _, err := ipc.GetSocket(cfg); err == nil {
		t.Fatalf("expected missing socket to fail")
	}

	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listen unix socket: %v", err)
	}
	defer listener.Close()

	got, err := ipc.GetSocket(cfg)
	if err != nil {
		t.Fatalf("GetSocket: %v", err)
	}
	if got != path {
		t.Fatalf("expected %q, got %q", path, got)
	}
}

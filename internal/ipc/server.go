package ipc

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"sync"
	"time"

	"slices"

	"github.com/nick/proctmux/internal/domain"
	"github.com/nick/proctmux/internal/redact"
)

type clientConn struct {
	net.Conn
	mu sync.Mutex
}

type Server struct {
	socketPath    string
	listener      net.Listener
	clients       []*clientConn
	mu            sync.RWMutex
	done          chan struct{}
	allowedUID    int
	writeTimeout  time.Duration
	primaryServer interface {
		HandleCommand(action, label string) error
		GetState() *domain.AppState
		GetProcessController() domain.ProcessController
	}
	// currentProcID removed
}

var (
	authorizePeerConn      = defaultAuthorizePeerConn
	errPeerCredUnsupported = errors.New("peer credential inspection unsupported")
	peerCredWarningOnce    sync.Once
)

type Message struct {
	Type         string               `json:"type"`
	RequestID    string               `json:"request_id,omitempty"`
	Label        string               `json:"label,omitempty"`
	Action       string               `json:"action,omitempty"`
	State        *domain.AppState     `json:"state,omitempty"`
	ProcessList  []map[string]any     `json:"process_list,omitempty"`
	ProcessViews []domain.ProcessView `json:"process_views,omitempty"`
	Error        string               `json:"error,omitempty"`
	Success      bool                 `json:"success,omitempty"`
}

func NewServer() *Server {
	return &Server{
		clients:      []*clientConn{},
		done:         make(chan struct{}),
		writeTimeout: defaultClientWriteTimeout,
	}
}

const defaultClientWriteTimeout = 2 * time.Second

func (s *Server) Start(socketPath string) error {
	if err := os.RemoveAll(socketPath); err != nil {
		return fmt.Errorf("failed to remove existing socket: %w", err)
	}

	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return fmt.Errorf("failed to create unix socket: %w", err)
	}
	if err := os.Chmod(socketPath, 0o600); err != nil {
		listener.Close()
		return fmt.Errorf("failed to set unix socket permissions: %w", err)
	}

	s.socketPath = socketPath
	s.listener = listener
	s.allowedUID = os.Geteuid()

	go s.acceptClients()

	log.Printf("IPC server started on %s", socketPath)
	return nil
}

func (s *Server) acceptClients() {
	for {
		select {
		case <-s.done:
			return
		default:
			conn, err := s.listener.Accept()
			if err != nil {
				select {
				case <-s.done:
					return
				default:
					log.Printf("IPC accept error: %v", err)
					continue
				}
			}

			cc, err := s.registerClient(conn)
			if err != nil {
				log.Printf("Rejected IPC client: %v", err)
				conn.Close()
				continue
			}

			log.Printf("IPC client connected (total: %d)", s.clientCount())

			// Send initial state to the new client
			if s.primaryServer != nil {
				state := s.primaryServer.GetState()
				pc := s.primaryServer.GetProcessController()
				s.sendInitialState(cc, state, pc)
			}

			go s.handleClient(cc)
		}
	}
}

func (s *Server) registerClient(conn net.Conn) (*clientConn, error) {
	if err := authorizePeerConn(conn, s.allowedUID); err != nil {
		return nil, err
	}

	cc := &clientConn{Conn: conn}
	s.mu.Lock()
	s.clients = append(s.clients, cc)
	s.mu.Unlock()
	return cc, nil
}

func (s *Server) clientCount() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.clients)
}

func defaultAuthorizePeerConn(conn net.Conn, expectedUID int) error {
	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return fmt.Errorf("unexpected connection type %T", conn)
	}

	if expectedUID == 0 {
		expectedUID = os.Geteuid()
	}

	sysConn, err := unixConn.SyscallConn()
	if err != nil {
		return fmt.Errorf("failed to access unix connection: %w", err)
	}

	var (
		peerUIDVal uint32
		credErr    error
	)
	if ctrlErr := sysConn.Control(func(fd uintptr) {
		peerUIDVal, credErr = peerUID(fd)
	}); ctrlErr != nil {
		return fmt.Errorf("failed to inspect peer credentials: %w", ctrlErr)
	}
	if credErr != nil {
		if errors.Is(credErr, errPeerCredUnsupported) {
			peerCredWarningOnce.Do(func() {
				log.Printf("Peer credential checks not supported on this platform; relying on socket permissions only")
			})
			return nil
		}
		return fmt.Errorf("failed to read peer credentials: %w", credErr)
	}

	if int(peerUIDVal) != expectedUID {
		return fmt.Errorf("unauthorized peer uid %d (expected %d)", peerUIDVal, expectedUID)
	}

	return nil
}

func (s *Server) handleClient(conn *clientConn) {
	defer func() {
		conn.Close()
		s.removeClient(conn)
	}()

	reader := bufio.NewReader(conn.Conn)
	for {
		select {
		case <-s.done:
			return
		default:
		}

		line, err := reader.ReadBytes('\n')
		if err != nil {
			// If the client closed the connection, just return
			log.Printf("IPC client read error: %v", err)
			return
		}

		var msg Message
		if err := json.Unmarshal(line, &msg); err != nil {
			log.Printf("Failed to parse IPC message: %v", err)
			continue
		}

		s.handleMessage(conn, msg)
	}
}

func getRunningLabels(state *domain.AppState, pc domain.ProcessController) []string {
	var labels []string
	for i := range state.Processes {
		p := &state.Processes[i]
		if p.ID == domain.DummyProcessID {
			continue
		}
		view := p.ToView(pc)
		if view.Status == domain.StatusRunning {
			labels = append(labels, view.Label)
		}
	}
	return labels
}

func (s *Server) handleMessage(conn *clientConn, msg Message) {
	switch msg.Type {
	case "command":
		s.handleCommand(conn, msg)
	default:
		log.Printf("Unknown IPC message type: %s", msg.Type)
	}
}

func (s *Server) handleCommand(conn *clientConn, msg Message) {
	response := Message{
		Type:      "response",
		RequestID: msg.RequestID,
		Success:   false,
	}

	// If we have a primary server, use it to handle commands
	if s.primaryServer != nil {
		switch msg.Action {
		case "start", "stop", "restart", "switch":
			if msg.Label == "" {
				response.Error = "missing process name"
			} else if err := s.primaryServer.HandleCommand(msg.Action, msg.Label); err != nil {
				response.Error = err.Error()
			} else {
				response.Success = true
			}
		case "list":
			state := s.primaryServer.GetState()
			pc := s.primaryServer.GetProcessController()
			var processList []map[string]any
			for i := range state.Processes {
				p := &state.Processes[i]
				if p.ID == domain.DummyProcessID {
					continue
				}
				view := p.ToView(pc)
				processList = append(processList, map[string]any{
					"name":    view.Label,
					"running": view.Status == domain.StatusRunning,
					"index":   view.ID,
				})
			}
			response.ProcessList = processList
			response.Success = true
		case "restart-running":
			state := s.primaryServer.GetState()
			pc := s.primaryServer.GetProcessController()
			runningLabels := getRunningLabels(state, pc)
			for _, name := range runningLabels {
				_ = s.primaryServer.HandleCommand("restart", name)
			}
			response.Success = true
		case "stop-running":
			state := s.primaryServer.GetState()
			pc := s.primaryServer.GetProcessController()
			runningLabels := getRunningLabels(state, pc)
			for _, name := range runningLabels {
				log.Printf("IPC server sending stop command for process: %s", name)
				_ = s.primaryServer.HandleCommand("stop", name)
			}
			response.Success = true
		default:
			response.Error = fmt.Sprintf("unknown action: %s", msg.Action)
		}
		s.sendResponse(conn, response)
		return
	}

	// No primary server available
	response.Error = "primary server not available"
	s.sendResponse(conn, response)
}

func (s *Server) sendResponse(conn *clientConn, msg Message) {
	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("Failed to marshal response: %v", err)
		return
	}
	data = append(data, '\n')
	conn.mu.Lock()
	defer conn.mu.Unlock()
	if _, err := conn.Write(data); err != nil {
		log.Printf("Failed to send response: %v", err)
	}
}

func (s *Server) removeClient(conn *clientConn) {
	s.mu.Lock()
	defer s.mu.Unlock()

	for i, c := range s.clients {
		if c == conn {
			s.clients = slices.Delete(s.clients, i, i+1)
			log.Printf("IPC client disconnected (remaining: %d)", len(s.clients))
			break
		}
	}
}

func buildStateMessage(state *domain.AppState, pc domain.ProcessController) ([]byte, error) {
	redactedState, redactedViews := redact.StateForIPC(state, pc)
	msg := Message{
		Type:         "state",
		State:        redactedState,
		ProcessViews: redactedViews,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return nil, err
	}
	data = append(data, '\n')
	return data, nil
}

func (s *Server) BroadcastState(state *domain.AppState, pc domain.ProcessController) {
	clients := s.snapshotClients()
	if len(clients) == 0 {
		return
	}

	data, err := buildStateMessage(state, pc)
	if err != nil {
		log.Printf("Failed to marshal state message: %v", err)
		return
	}

	for _, cc := range clients {
		if err := writeWithDeadline(cc, data, s.writeTimeout); err != nil {
			log.Printf("Failed to broadcast state to IPC client: %v", err)
			// Remove misbehaving client from the active set
			s.removeClient(cc)
		}
	}
}

// sendInitialState sends the current state to a newly connected client
func (s *Server) sendInitialState(conn *clientConn, state *domain.AppState, pc domain.ProcessController) {
	data, err := buildStateMessage(state, pc)
	if err != nil {
		log.Printf("Failed to marshal initial state message: %v", err)
		return
	}
	if err := writeWithDeadline(conn, data, s.writeTimeout); err != nil {
		log.Printf("Failed to send initial state to IPC client: %v", err)
		s.removeClient(conn)
	}
}

func (s *Server) snapshotClients() []*clientConn {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if len(s.clients) == 0 {
		return nil
	}
	copyClients := make([]*clientConn, len(s.clients))
	copy(copyClients, s.clients)
	return copyClients
}

func writeWithDeadline(conn *clientConn, data []byte, timeout time.Duration) error {
	conn.mu.Lock()
	defer conn.mu.Unlock()

	if err := conn.SetWriteDeadline(time.Now().Add(timeout)); err != nil {
		return fmt.Errorf("set write deadline: %w", err)
	}
	_, err := conn.Write(data)
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		return fmt.Errorf("IPC client write timeout: %w", err)
	}
	return err
}

func (s *Server) SetPrimaryServer(primary interface {
	HandleCommand(action, label string) error
	GetState() *domain.AppState
	GetProcessController() domain.ProcessController
}) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.primaryServer = primary
}

func (s *Server) Stop() {
	close(s.done)

	s.mu.Lock()
	defer s.mu.Unlock()

	for _, conn := range s.clients {
		conn.Close()
	}
	s.clients = []*clientConn{}

	if s.listener != nil {
		s.listener.Close()
	}

	if s.socketPath != "" {
		os.RemoveAll(s.socketPath)
	}

	log.Printf("IPC server stopped")
}

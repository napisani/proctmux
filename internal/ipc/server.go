package ipc

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"sync"

	"slices"

	"github.com/nick/proctmux/internal/domain"
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
	primaryServer interface {
		HandleCommand(action, label string) error
		GetState() *domain.AppState
		GetProcessController() domain.ProcessController
	}
	// currentProcID removed
}

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
		clients: []*clientConn{},
		done:    make(chan struct{}),
	}
}

func (s *Server) Start(socketPath string) error {
	if err := os.RemoveAll(socketPath); err != nil {
		return fmt.Errorf("failed to remove existing socket: %w", err)
	}

	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return fmt.Errorf("failed to create unix socket: %w", err)
	}

	s.socketPath = socketPath
	s.listener = listener

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

			s.mu.Lock()
			cc := &clientConn{Conn: conn}
			s.clients = append(s.clients, cc)
			s.mu.Unlock()

			log.Printf("IPC client connected (total: %d)", len(s.clients))

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
	// Convert processes to ProcessViews
	processViews := make([]domain.ProcessView, len(state.Processes))
	for i := range state.Processes {
		processViews[i] = state.Processes[i].ToView(pc)
	}
	msg := Message{
		Type:         "state",
		State:        state,
		ProcessViews: processViews,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return nil, err
	}
	data = append(data, '\n')
	return data, nil
}

func (s *Server) BroadcastState(state *domain.AppState, pc domain.ProcessController) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if len(s.clients) == 0 {
		return
	}

	data, err := buildStateMessage(state, pc)
	if err != nil {
		log.Printf("Failed to marshal state message: %v", err)
		return
	}
	for _, cc := range s.clients {
		cc.mu.Lock()
		if _, err := cc.Write(data); err != nil {
			log.Printf("Failed to broadcast state to IPC client: %v", err)
		}
		cc.mu.Unlock()
	}
}

// sendInitialState sends the current state to a newly connected client
func (s *Server) sendInitialState(conn *clientConn, state *domain.AppState, pc domain.ProcessController) {
	data, err := buildStateMessage(state, pc)
	if err != nil {
		log.Printf("Failed to marshal initial state message: %v", err)
		return
	}
	conn.mu.Lock()
	defer conn.mu.Unlock()
	if _, err := conn.Write(data); err != nil {
		log.Printf("Failed to send initial state to IPC client: %v", err)
	}
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

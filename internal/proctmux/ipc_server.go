package proctmux

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"sync"
)

type IPCServer struct {
	socketPath    string
	listener      net.Listener
	clients       []net.Conn
	mu            sync.RWMutex
	done          chan struct{}
	controller    *Controller
	masterServer  *MasterServer
	currentProcID int
}

type IPCMessage struct {
	Type        string                   `json:"type"`
	RequestID   string                   `json:"request_id,omitempty"`
	ProcessID   int                      `json:"process_id,omitempty"`
	Label       string                   `json:"label,omitempty"`
	Action      string                   `json:"action,omitempty"`
	Config      *ProcessConfig           `json:"config,omitempty"`
	Status      string                   `json:"status,omitempty"`
	PID         int                      `json:"pid,omitempty"`
	ExitCode    int                      `json:"exit_code,omitempty"`
	State       *AppState                `json:"state,omitempty"`
	ProcessList []map[string]interface{} `json:"process_list,omitempty"`
	Error       string                   `json:"error,omitempty"`
	Success     bool                     `json:"success,omitempty"`
}

func NewIPCServer() *IPCServer {
	return &IPCServer{
		clients: []net.Conn{},
		done:    make(chan struct{}),
	}
}

func (s *IPCServer) Start(socketPath string) error {
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

func (s *IPCServer) acceptClients() {
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
			s.clients = append(s.clients, conn)
			s.mu.Unlock()

			log.Printf("IPC client connected (total: %d)", len(s.clients))

			go s.handleClient(conn)
		}
	}
}

func (s *IPCServer) handleClient(conn net.Conn) {
	defer func() {
		conn.Close()
		s.removeClient(conn)
	}()

	scanner := bufio.NewScanner(conn)
	for scanner.Scan() {
		select {
		case <-s.done:
			return
		default:
			line := scanner.Bytes()
			var msg IPCMessage
			if err := json.Unmarshal(line, &msg); err != nil {
				log.Printf("Failed to parse IPC message: %v", err)
				continue
			}

			s.handleMessage(conn, msg)
		}
	}

	if err := scanner.Err(); err != nil {
		log.Printf("IPC client read error: %v", err)
	}
}

func (s *IPCServer) handleMessage(conn net.Conn, msg IPCMessage) {
	switch msg.Type {
	case "state":
		if s.controller != nil {
			s.controller.OnStateUpdate(msg.State)
		}
	case "command":
		s.handleCommand(conn, msg)
	case "select":
		// Handle selection from UI clients
		if s.masterServer != nil {
			s.masterServer.HandleSelection(msg.ProcessID)
		}
	default:
		log.Printf("Unknown IPC message type: %s", msg.Type)
	}
}

func (s *IPCServer) handleCommand(conn net.Conn, msg IPCMessage) {
	response := IPCMessage{
		Type:      "response",
		RequestID: msg.RequestID,
		Success:   false,
	}

	// If we have a master server, use it to handle commands
	if s.masterServer != nil {
		switch msg.Action {
		case "start", "stop", "restart", "switch":
			if msg.Label == "" {
				response.Error = "missing process name"
			} else if err := s.masterServer.HandleCommand(msg.Action, msg.Label); err != nil {
				response.Error = err.Error()
			} else {
				response.Success = true
			}
		case "list":
			state := s.masterServer.GetState()
			var processList []map[string]interface{}
			for i := range state.Processes {
				p := state.Processes[i]
				if p.ID == DummyProcessID {
					continue
				}
				processList = append(processList, map[string]interface{}{
					"name":    p.Label,
					"running": p.Status == StatusRunning,
					"index":   p.ID,
				})
			}
			response.ProcessList = processList
			response.Success = true
		case "restart-running":
			state := s.masterServer.GetState()
			var runningLabels []string
			for i := range state.Processes {
				p := state.Processes[i]
				if p.Status == StatusRunning && p.ID != DummyProcessID {
					runningLabels = append(runningLabels, p.Label)
				}
			}
			for _, name := range runningLabels {
				_ = s.masterServer.HandleCommand("restart", name)
			}
			response.Success = true
		case "stop-running":
			state := s.masterServer.GetState()
			var runningLabels []string
			for i := range state.Processes {
				p := state.Processes[i]
				if p.Status == StatusRunning && p.ID != DummyProcessID {
					runningLabels = append(runningLabels, p.Label)
				}
			}
			for _, name := range runningLabels {
				_ = s.masterServer.HandleCommand("stop", name)
			}
			response.Success = true
		default:
			response.Error = fmt.Sprintf("unknown action: %s", msg.Action)
		}
		s.sendResponse(conn, response)
		return
	}

	// Fall back to controller if no master server
	if s.controller == nil {
		response.Error = "controller not available"
		s.sendResponse(conn, response)
		return
	}

	switch msg.Action {
	case "start":
		if msg.Label == "" {
			response.Error = "missing process name"
		} else if err := s.controller.OnKeypressStartWithLabel(msg.Label); err != nil {
			response.Error = err.Error()
		} else {
			response.Success = true
		}
	case "stop":
		if msg.Label == "" {
			response.Error = "missing process name"
		} else if err := s.controller.OnKeypressStopWithLabel(msg.Label); err != nil {
			response.Error = err.Error()
		} else {
			response.Success = true
		}
	case "restart":
		if msg.Label == "" {
			response.Error = "missing process name"
		} else if err := s.controller.OnKeypressRestartWithLabel(msg.Label); err != nil {
			response.Error = err.Error()
		} else {
			response.Success = true
		}
	case "list":
		var processList []map[string]interface{}
		_ = s.controller.LockAndLoad(func(state *AppState) (*AppState, error) {
			for i := range state.Processes {
				p := state.Processes[i]
				if p.ID == DummyProcessID {
					continue
				}
				processList = append(processList, map[string]interface{}{
					"name":    p.Label,
					"running": p.Status == StatusRunning,
					"index":   p.ID,
				})
			}
			return state, nil
		})
		response.ProcessList = processList
		response.Success = true
	case "restart-running":
		var runningLabels []string
		_ = s.controller.LockAndLoad(func(state *AppState) (*AppState, error) {
			for i := range state.Processes {
				p := state.Processes[i]
				if p.Status == StatusRunning && p.ID != DummyProcessID {
					runningLabels = append(runningLabels, p.Label)
				}
			}
			return state, nil
		})
		for _, name := range runningLabels {
			_ = s.controller.OnKeypressRestartWithLabel(name)
		}
		response.Success = true
	case "stop-running":
		var runningLabels []string
		_ = s.controller.LockAndLoad(func(state *AppState) (*AppState, error) {
			for i := range state.Processes {
				p := state.Processes[i]
				if p.Status == StatusRunning && p.ID != DummyProcessID {
					runningLabels = append(runningLabels, p.Label)
				}
			}
			return state, nil
		})
		for _, name := range runningLabels {
			_ = s.controller.OnKeypressStopWithLabel(name)
		}
		response.Success = true
	default:
		response.Error = fmt.Sprintf("unknown action: %s", msg.Action)
	}

	s.sendResponse(conn, response)
}

func (s *IPCServer) sendResponse(conn net.Conn, msg IPCMessage) {
	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("Failed to marshal response: %v", err)
		return
	}
	data = append(data, '\n')
	if _, err := conn.Write(data); err != nil {
		log.Printf("Failed to send response: %v", err)
	}
}

func (s *IPCServer) removeClient(conn net.Conn) {
	s.mu.Lock()
	defer s.mu.Unlock()

	for i, c := range s.clients {
		if c == conn {
			s.clients = append(s.clients[:i], s.clients[i+1:]...)
			log.Printf("IPC client disconnected (remaining: %d)", len(s.clients))
			break
		}
	}
}

func (s *IPCServer) BroadcastSelection(procID int, label string) {
	s.mu.Lock()
	s.currentProcID = procID
	s.mu.Unlock()

	s.mu.RLock()
	defer s.mu.RUnlock()

	if len(s.clients) == 0 {
		return
	}

	msg := IPCMessage{
		Type:      "user_action",
		Action:    "select",
		ProcessID: procID,
		Label:     label,
	}

	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("Failed to marshal IPC message: %v", err)
		return
	}

	data = append(data, '\n')

	for _, conn := range s.clients {
		if _, err := conn.Write(data); err != nil {
			log.Printf("Failed to write to IPC client: %v", err)
		}
	}

	log.Printf("Broadcasted selection to %d clients: %s (ID: %d)", len(s.clients), label, procID)
}

func (s *IPCServer) BroadcastState(state *AppState) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if len(s.clients) == 0 {
		return
	}

	msg := IPCMessage{
		Type:  "state",
		State: state,
	}

	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("Failed to marshal state message: %v", err)
		return
	}

	data = append(data, '\n')

	for _, conn := range s.clients {
		if _, err := conn.Write(data); err != nil {
			log.Printf("Failed to broadcast state to IPC client: %v", err)
		}
	}
}

func (s *IPCServer) SendCommand(action string, procID int, config *ProcessConfig) error {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if len(s.clients) == 0 {
		return fmt.Errorf("no connected viewers to send command")
	}

	msg := IPCMessage{
		Type:      "user_action",
		Action:    action,
		ProcessID: procID,
		Config:    config,
	}

	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal command: %w", err)
	}

	data = append(data, '\n')

	for _, conn := range s.clients {
		if _, err := conn.Write(data); err != nil {
			log.Printf("Failed to send command to IPC client: %v", err)
		}
	}

	log.Printf("Sent command '%s' for process %d to %d clients", action, procID, len(s.clients))
	return nil
}

func (s *IPCServer) SetController(controller *Controller) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.controller = controller
}

func (s *IPCServer) SetMasterServer(master *MasterServer) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.masterServer = master
}

func (s *IPCServer) Stop() {
	close(s.done)

	s.mu.Lock()
	defer s.mu.Unlock()

	for _, conn := range s.clients {
		conn.Close()
	}
	s.clients = []net.Conn{}

	if s.listener != nil {
		s.listener.Close()
	}

	if s.socketPath != "" {
		os.RemoveAll(s.socketPath)
	}

	log.Printf("IPC server stopped")
}

func (s *IPCServer) GetSocketPath() string {
	return s.socketPath
}

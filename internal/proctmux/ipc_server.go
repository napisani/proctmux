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
	currentProcID int
}

type IPCMessage struct {
	Type      string         `json:"type"`
	ProcessID int            `json:"process_id,omitempty"`
	Label     string         `json:"label,omitempty"`
	Action    string         `json:"action,omitempty"`
	Config    *ProcessConfig `json:"config,omitempty"`
	Status    string         `json:"status,omitempty"`
	PID       int            `json:"pid,omitempty"`
	ExitCode  int            `json:"exit_code,omitempty"`
	State     *AppState      `json:"state,omitempty"`
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

			s.handleMessage(msg)
		}
	}

	if err := scanner.Err(); err != nil {
		log.Printf("IPC client read error: %v", err)
	}
}

func (s *IPCServer) handleMessage(msg IPCMessage) {
	switch msg.Type {
	case "state":
		if s.controller != nil {
			s.controller.OnStateUpdate(msg.State)
		}
	default:
		log.Printf("Unknown IPC message type: %s", msg.Type)
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

package ipc

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nick/proctmux/internal/domain"
)

type Client struct {
	socketPath    string
	conn          net.Conn
	mu            sync.Mutex
	reader        *bufio.Reader
	requestID     atomic.Uint64
	pendingReqs   map[string]chan Message
	pendingReqsMu sync.Mutex
	updatesCh     chan domain.StateUpdate
}

func NewClient(socketPath string) (*Client, error) {
	client := &Client{
		socketPath:  socketPath,
		pendingReqs: make(map[string]chan Message),
		updatesCh:   make(chan domain.StateUpdate, 10), // Buffered channel for combined updates
	}

	if err := client.Connect(); err != nil {
		return nil, err
	}

	// Start response reader goroutine
	go client.readResponses()

	return client, nil
}

func (c *Client) Connect() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	maxRetries := 5
	for i := range maxRetries {
		conn, err := net.Dial("unix", c.socketPath)
		if err != nil {
			if i < maxRetries-1 {
				log.Printf("Failed to connect to IPC server (attempt %d/%d): %v", i+1, maxRetries, err)
				time.Sleep(time.Second * 2)
				continue
			}
			return fmt.Errorf("failed to connect to IPC server after %d attempts: %w", maxRetries, err)
		}

		c.conn = conn
		c.reader = bufio.NewReader(conn)
		log.Printf("Connected to IPC server at %s", c.socketPath)
		return nil
	}

	return fmt.Errorf("failed to connect to IPC server")
}

func (c *Client) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn != nil {
		c.conn.Close()
		c.conn = nil
		c.reader = nil
		log.Printf("Disconnected from IPC server")
	}
}

func (c *Client) readResponses() {
	for {
		c.mu.Lock()
		if c.conn == nil || c.reader == nil {
			c.mu.Unlock()
			return
		}
		reader := c.reader
		c.mu.Unlock()

		line, err := reader.ReadBytes('\n')
		if err != nil {
			log.Printf("Failed to read from IPC server: %v", err)
			return
		}

		var msg Message
		if err := json.Unmarshal(line, &msg); err != nil {
			log.Printf("Failed to unmarshal IPC message: %v", err)
			continue
		}

		// Handle state broadcast messages
		if msg.Type == "state" && msg.State != nil {
			upd := domain.StateUpdate{State: msg.State, ProcessViews: msg.ProcessViews}
			select {
			case c.updatesCh <- upd:
				// Update sent to channel
			default:
				// Channel full, skip this update
			}
			continue
		}

		// Handle response messages
		if msg.Type == "response" && msg.RequestID != "" {
			c.pendingReqsMu.Lock()
			if ch, ok := c.pendingReqs[msg.RequestID]; ok {
				ch <- msg
				delete(c.pendingReqs, msg.RequestID)
			}
			c.pendingReqsMu.Unlock()
		}
	}
}

func (c *Client) sendCommand(action string, label string) (*Message, error) {
	c.mu.Lock()
	if c.conn == nil {
		c.mu.Unlock()
		return nil, fmt.Errorf("not connected")
	}
	c.mu.Unlock()

	reqID := fmt.Sprintf("%d", c.requestID.Add(1))
	msg := Message{
		Type:      "command",
		RequestID: reqID,
		Action:    action,
		Label:     label,
	}

	data, err := json.Marshal(msg)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal command: %w", err)
	}
	data = append(data, '\n')

	// Create response channel
	respCh := make(chan Message, 1)
	c.pendingReqsMu.Lock()
	c.pendingReqs[reqID] = respCh
	c.pendingReqsMu.Unlock()

	// Send command
	c.mu.Lock()
	if _, err := c.conn.Write(data); err != nil {
		c.mu.Unlock()
		c.pendingReqsMu.Lock()
		delete(c.pendingReqs, reqID)
		c.pendingReqsMu.Unlock()
		return nil, fmt.Errorf("failed to send command: %w", err)
	}
	c.mu.Unlock()

	// Wait for response with timeout
	select {
	case resp := <-respCh:
		if !resp.Success {
			return nil, fmt.Errorf("%s", resp.Error)
		}
		return &resp, nil
	case <-time.After(5 * time.Second):
		c.pendingReqsMu.Lock()
		delete(c.pendingReqs, reqID)
		c.pendingReqsMu.Unlock()
		return nil, fmt.Errorf("command timeout")
	}
}

func (c *Client) StartProcess(name string) error {
	_, err := c.sendCommand("start", name)
	return err
}

func (c *Client) StopProcess(name string) error {
	_, err := c.sendCommand("stop", name)
	return err
}

func (c *Client) RestartProcess(name string) error {
	_, err := c.sendCommand("restart", name)
	return err
}

func (c *Client) RestartRunning() error {
	_, err := c.sendCommand("restart-running", "")
	return err
}

func (c *Client) StopRunning() error {
	_, err := c.sendCommand("stop-running", "")
	return err
}

func (c *Client) SwitchProcess(name string) error {
	_, err := c.sendCommand("switch", name)
	return err
}

func (c *Client) GetProcessList() ([]byte, error) {
	resp, err := c.sendCommand("list", "")
	if err != nil {
		return nil, err
	}
	// Return JSON in same format as signal server
	data, err := json.Marshal(map[string]any{
		"process_list": resp.ProcessList,
	})
	return data, err
}

// ReceiveUpdates returns a channel that receives combined state updates
func (c *Client) ReceiveUpdates() <-chan domain.StateUpdate {
	return c.updatesCh
}

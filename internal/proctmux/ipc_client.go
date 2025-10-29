package proctmux

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"sync"
	"time"
)

type IPCClient struct {
	socketPath string
	conn       net.Conn
	mu         sync.Mutex
	reader     *bufio.Reader
}

func NewIPCClient(socketPath string) (*IPCClient, error) {
	client := &IPCClient{
		socketPath: socketPath,
	}

	if err := client.Connect(); err != nil {
		return nil, err
	}

	return client, nil
}

func (c *IPCClient) Connect() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	maxRetries := 5
	for i := 0; i < maxRetries; i++ {
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

func (c *IPCClient) ReadSelection() (*IPCMessage, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn == nil {
		return nil, fmt.Errorf("not connected")
	}

	line, err := c.reader.ReadBytes('\n')
	if err != nil {
		return nil, fmt.Errorf("failed to read from IPC server: %w", err)
	}

	var msg IPCMessage
	if err := json.Unmarshal(line, &msg); err != nil {
		return nil, fmt.Errorf("failed to unmarshal IPC message: %w", err)
	}

	return &msg, nil
}

func (c *IPCClient) ReadMessage() (*IPCMessage, error) {
	return c.ReadSelection()
}

func (c *IPCClient) SendState(state *AppState) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn == nil {
		return fmt.Errorf("not connected")
	}

	msg := IPCMessage{
		Type:  "state",
		State: state,
	}

	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal state message: %w", err)
	}

	data = append(data, '\n')

	if _, err := c.conn.Write(data); err != nil {
		return fmt.Errorf("failed to send state message: %w", err)
	}

	log.Printf("Sent state update with %d processes", len(state.Processes))
	return nil
}

func (c *IPCClient) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn != nil {
		c.conn.Close()
		c.conn = nil
		c.reader = nil
		log.Printf("Disconnected from IPC server")
	}
}

func (c *IPCClient) IsConnected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.conn != nil
}

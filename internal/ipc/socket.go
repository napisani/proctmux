package ipc

import (
	"fmt"
	"os"
	"time"

	"github.com/nick/proctmux/internal/config"
)

func getTmpDir() string {
	return "/tmp"
}

// CreateSocket creates a new socket file path based on config hash and creates it.
// Returns the socket path.
func CreateSocket(config *config.ProcTmuxConfig) (string, error) {
	hash, err := config.ToHash()
	if err != nil {
		return "", fmt.Errorf("failed to generate config hash: %w", err)
	}

	socketPath := fmt.Sprintf("%s/proctmux-%s.socket", getTmpDir(), hash)

	// Remove any existing socket file
	_ = os.Remove(socketPath)

	return socketPath, nil
}

// GetSocket returns the socket path for the given config.
// It checks if the socket exists, and returns an error if it doesn't.
func GetSocket(config *config.ProcTmuxConfig) (string, error) {
	hash, err := config.ToHash()
	if err != nil {
		return "", fmt.Errorf("failed to generate config hash: %w", err)
	}

	socketPath := fmt.Sprintf("%s/proctmux-%s.socket", getTmpDir(), hash)

	// Verify the socket exists
	if _, err := os.Stat(socketPath); err != nil {
		return "", fmt.Errorf("socket file does not exist: %s", socketPath)
	}

	return socketPath, nil
}

// WaitForSocket waits for the socket to be created, up to a timeout.
// Returns the socket path when it becomes available.
func WaitForSocket(config *config.ProcTmuxConfig) (string, error) {
	hash, err := config.ToHash()
	if err != nil {
		return "", fmt.Errorf("failed to generate config hash: %w", err)
	}

	socketPath := fmt.Sprintf("%s/proctmux-%s.socket", getTmpDir(), hash)

	// Wait up to 5 seconds for the socket to be created
	timeout := time.After(5 * time.Second)
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-timeout:
			return "", fmt.Errorf("timeout waiting for socket: %s", socketPath)
		case <-ticker.C:
			if _, err := os.Stat(socketPath); err == nil {
				return socketPath, nil
			}
		}
	}
}

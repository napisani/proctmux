package proctmux

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// FindIPCSocket finds the most recent proctmux IPC socket.
// It looks for socket files matching /tmp/proctmux-*.sock and returns the most recent one.
func FindIPCSocket() (string, error) {
	pattern := "/tmp/proctmux-*.sock"
	matches, err := filepath.Glob(pattern)
	if err != nil {
		return "", fmt.Errorf("failed to search for sockets: %w", err)
	}

	if len(matches) == 0 {
		return "", fmt.Errorf("no proctmux instance found (no socket files in /tmp)")
	}

	// Sort by modification time (most recent first)
	sort.Slice(matches, func(i, j int) bool {
		infoI, errI := os.Stat(matches[i])
		infoJ, errJ := os.Stat(matches[j])
		if errI != nil || errJ != nil {
			return false
		}
		return infoI.ModTime().After(infoJ.ModTime())
	})

	// Return the most recent socket
	return matches[0], nil
}

// GetIPCSocketPath returns the socket path for the given PID, or discovers it if pid is 0.
func GetIPCSocketPath(pid int) (string, error) {
	if pid > 0 {
		return fmt.Sprintf("/tmp/proctmux-%d.sock", pid), nil
	}
	return FindIPCSocket()
}

// WriteSocketPathFile writes the socket path to a well-known location for discovery.
func WriteSocketPathFile(socketPath string) error {
	pidFile := "/tmp/proctmux.socket"
	content := socketPath + "\n"
	if err := os.WriteFile(pidFile, []byte(content), 0644); err != nil {
		return fmt.Errorf("failed to write socket path file: %w", err)
	}
	return nil
}

// ReadSocketPathFile reads the socket path from the well-known location.
func ReadSocketPathFile() (string, error) {
	pidFile := "/tmp/proctmux.socket"
	content, err := os.ReadFile(pidFile)
	if err != nil {
		return "", err
	}
	socketPath := strings.TrimSpace(string(content))

	// Verify the socket still exists
	if _, err := os.Stat(socketPath); err != nil {
		return "", fmt.Errorf("socket file no longer exists: %s", socketPath)
	}

	return socketPath, nil
}

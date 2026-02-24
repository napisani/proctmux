package main

import (
	"fmt"
	"log"
	"os"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
	"github.com/nick/proctmux/internal/ipc"
	"github.com/nick/proctmux/internal/tui"
)

// proctmuxSocketEnv is the environment variable name that the unified-toggle
// coordinator sets when spawning the --client child so the child can connect
// directly without probing the socket first. The probe creates a spurious
// connection that the IPC server tries to write to (broken pipe) right before
// the real client connection arrives, causing the real connection's initial
// state message to be delayed or lost.
const proctmuxSocketEnv = "PROCTMUX_SOCKET"

// RunClient starts the application in client mode, connecting to a running primary server
func RunClient(cfg *config.ProcTmuxConfig) error {
	log.SetPrefix("[CLIENT] ")

	// If the coordinator passed the socket path directly via env, use it without
	// probing (avoids a spurious probe connection that causes broken-pipe races).
	var socketPath string
	if envSocket := os.Getenv(proctmuxSocketEnv); envSocket != "" {
		log.Printf("Using socket from env: %s", envSocket)
		socketPath = envSocket
	}

	var err error
	if socketPath == "" {
		// Auto-discover socket path if not provided
		socketPath, err = ipc.GetSocket(cfg)
	}
	if socketPath == "" || err != nil {
		// Socket doesn't exist yet - wait for it with user feedback
		fmt.Println("Primary server not found. Waiting for server to start...")
		fmt.Println("(Will timeout in 30 seconds if server doesn't start)")
		fmt.Println()

		socketPath, err = ipc.WaitForSocketWithProgress(cfg, func(elapsed, total time.Duration) {
			remaining := total - elapsed
			fmt.Printf("\rWaiting for primary server... %d seconds remaining   ", int(remaining.Seconds()))
		})

		if err != nil {
			fmt.Printf("\n\nError: Failed to connect to primary server\n")
			fmt.Printf("Reason: %v\n\n", err)
			fmt.Println("To start the primary server, run:")
			fmt.Println("  proctmux")
			fmt.Println()
			return fmt.Errorf("wait for primary server socket: %w", err)
		}

		// Clear the waiting message
		fmt.Printf("\r%s\r", "                                                        ")
		fmt.Println("Connected to primary server!")
		fmt.Println()
	}

	log.Printf("Connecting to primary at %s", socketPath)
	client, err := ipc.NewClient(socketPath)
	if err != nil {
		fmt.Printf("\nError connecting to primary server: %v\n", err)
		return fmt.Errorf("connect to primary server: %w", err)
	}
	defer client.Close()

	// Create client UI model
	state := domain.NewAppState(cfg)
	clientModel := tui.NewClientModel(client, &state)
	p := tea.NewProgram(clientModel, bubbleTeaProgramOptions()...)
	if _, err := p.Run(); err != nil {
		fmt.Printf("Error running proctmux client: %v\n", err)
		return fmt.Errorf("run client UI: %w", err)
	}

	return nil
}

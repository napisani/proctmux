package main

import (
	"fmt"
	"log"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
	"github.com/nick/proctmux/internal/ipc"
	"github.com/nick/proctmux/internal/tui"
)

// RunClient starts the application in client mode, connecting to a running primary server
func RunClient(cfg *config.ProcTmuxConfig) error {
	log.SetPrefix("[CLIENT] ")

	// Auto-discover socket path if not provided
	socketPath, err := ipc.GetSocket(cfg)
	if err != nil {
		// Wait for socket to be created
		socketPath, err = ipc.WaitForSocket(cfg)
		if err != nil {
			fmt.Printf("Error finding primary server socket: %v\n", err)
			log.Fatal("Failed to find primary server socket. Start primary first with `proctmux`")
		}
	}

	log.Printf("Connecting to primary at %s", socketPath)
	client, err := ipc.NewClient(socketPath)
	if err != nil {
		fmt.Printf("Error connecting to primary server: %v", err)
		log.Fatal("Failed to connect to primary server:", err)
	}
	defer client.Close()

	// Create client UI model
	state := domain.NewAppState(cfg)
	clientModel := tui.NewClientModel(client, &state)
	p := tea.NewProgram(clientModel, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Printf("Error running proctmux client: %v\n", err)
		log.Fatal(err)
	}

	return nil
}

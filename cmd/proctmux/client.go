package main

import (
	"log"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/nick/proctmux/internal/proctmux"
)

// RunClient starts the application in client mode, connecting to a running primary server
func RunClient(cfg *proctmux.ProcTmuxConfig, socketPath string) error {
	log.SetPrefix("[CLIENT] ")

	// Auto-discover socket path if not provided
	if socketPath == "" {
		var err error
		socketPath, err = proctmux.ReadSocketPathFile()
		if err != nil {
			socketPath, err = proctmux.FindIPCSocket()
			if err != nil {
				log.Fatal("Failed to find primary server socket. Start primary first with `proctmux`")
			}
		}
	}

	log.Printf("Connecting to primary at %s", socketPath)
	client, err := proctmux.NewIPCClient(socketPath)
	if err != nil {
		log.Fatal("Failed to connect to primary server:", err)
	}
	defer client.Close()

	// Create client UI model
	state := proctmux.NewAppState(cfg)
	clientModel := proctmux.NewClientModel(client, &state)
	p := tea.NewProgram(clientModel, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		log.Fatal(err)
	}

	return nil
}

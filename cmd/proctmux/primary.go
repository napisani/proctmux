package main

import (
	"log"

	"github.com/nick/proctmux/internal/proctmux"
)

// RunPrimary starts the application in primary mode, running the process server
func RunPrimary(cfg *proctmux.ProcTmuxConfig) error {
	log.SetPrefix("[PRIMARY] ")
	log.Println("Starting proctmux primary server...")
	log.Printf("Loaded config: %+v", cfg)

	// Create and start primary server
	primaryServer := proctmux.NewPrimaryServer(cfg)
	ipcSocketPath, err := proctmux.CreateSocket(cfg)
	if err != nil {
		log.Fatal("Failed to create socket path:", err)
	}

	if err := primaryServer.Start(ipcSocketPath); err != nil {
		log.Fatal("Failed to start primary server:", err)
	}
	defer primaryServer.Stop()

	// Just pause until ctrl-c
	select {}
}

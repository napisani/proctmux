package main

import (
	"fmt"
	"log"
	"os"
	"time"

	"github.com/nick/proctmux/internal/proctmux"
)

// RunPrimary starts the application in primary mode, running the process server
func RunPrimary(cfg *proctmux.ProcTmuxConfig) error {
	log.SetPrefix("[PRIMARY] ")
	log.Println("Starting proctmux primary server...")
	log.Printf("Loaded config: %+v", cfg)

	// Log deprecation warning if signal server is enabled in config
	if cfg.SignalServer.Enable {
		log.Printf("Warning: signal_server configuration is deprecated. Signal commands now use IPC automatically.")
	}

	// Create and start primary server
	primaryServer := proctmux.NewPrimaryServer(cfg)
	ipcSocketPath := fmt.Sprintf("/tmp/proctmux-%d.sock", os.Getpid())

	if err := primaryServer.Start(ipcSocketPath); err != nil {
		log.Fatal("Failed to start primary server:", err)
	}
	defer primaryServer.Stop()

	// Create local IPC client to receive state updates from primary
	// Wait a moment for IPC server to be ready
	time.Sleep(100 * time.Millisecond)
	localClient, err := proctmux.NewIPCClient(ipcSocketPath)
	if err != nil {
		log.Fatal("Failed to create local IPC client:", err)
	}
	defer localClient.Close()

	// Just pause until ctrl-c
	select {}
}

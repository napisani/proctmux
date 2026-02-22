package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/ipc"
	"github.com/nick/proctmux/internal/proctmux"
)

// RunPrimary starts the application in primary mode, running the process server
func RunPrimary(cfg *config.ProcTmuxConfig) error {
	log.SetPrefix("[PRIMARY] ")
	log.Println("Starting proctmux primary server...")
	log.Printf("Loaded config from %s with %d processes", cfg.FilePath, len(cfg.Procs))

	ctx, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignals()

	// Create IPC server
	ipcServer := ipc.NewServer()

	// Create and start primary server
	primaryServer := proctmux.NewPrimaryServer(cfg, ipcServer)
	ipcSocketPath, err := ipc.CreateSocket(cfg)
	if err != nil {
		return fmt.Errorf("create IPC socket: %w", err)
	}

	if err := primaryServer.Start(ipcSocketPath); err != nil {
		return fmt.Errorf("start primary server: %w", err)
	}

	log.Println("Primary server running; waiting for shutdown signal (Ctrl+C)")
	return waitForShutdown(ctx, primaryServer.Stop)
}

func waitForShutdown(ctx context.Context, stop func()) error {
	<-ctx.Done()
	if err := ctx.Err(); err != nil {
		log.Printf("Shutdown signal received: %v", err)
	} else {
		log.Printf("Shutdown signal received")
	}
	stop()
	return ctx.Err()
}

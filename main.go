package main

import (
	"log"
	"os"
	"sync/atomic"

	tea "github.com/charmbracelet/bubbletea"
)

// setupLogger configures the logger to write to the specified file path.
// It returns an error if the log file cannot be opened.
func setupLogger(logPath string) (*os.File, error) {
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
	if err != nil {
		return nil, err
	}
	log.SetOutput(logFile)
	return logFile, nil
}

func main() {
	// Set up logging to file
	logFile, err := setupLogger("/tmp/proctmux.log")
	if err != nil {
		log.Fatal("Failed to set up logger:", err)
	}
	defer logFile.Close()

	log.Println("Starting proctmux...")

	// Now logs will go to the file
	cfg, err := LoadConfig("proctmux.yaml")
	if err != nil {
		log.Printf("Config load warning: %v", err)
	}

	// print the config for debugging
	log.Printf("Loaded config: %+v", cfg)

	state := NewAppState(cfg)
	tmuxContext, err := NewTmuxContext(cfg.General.DetachedSessionName, cfg.General.KillExistingSession)
	if err != nil {
		log.Fatal("Failed to create TmuxContext:", err)
	}
	running := new(atomic.Bool)
	running.Store(true)
	controller := NewController(&state, tmuxContext, running)

	// --- TmuxDaemon logic ---
	attachedDaemon, err := NewTmuxDaemon(tmuxContext.SessionID)
	if err != nil {
		log.Fatal("Failed to start attached TmuxDaemon:", err)
	}
	detachedDaemon, err := NewTmuxDaemon(tmuxContext.DetachedSessionID)
	if err != nil {
		log.Fatal("Failed to start detached TmuxDaemon:", err)
	}
	deadPidCh := make(chan int, 10)
	// Listen for dead panes in both daemons
	go func() { _ = attachedDaemon.ListenForDeadPanes(deadPidCh) }()
	go func() { _ = detachedDaemon.ListenForDeadPanes(deadPidCh) }()
	// Handle dead PIDs
	go func() {
		for pid := range deadPidCh {
			log.Printf("Received dead PID notification: %d", pid)
			controller.OnPidTerminated(pid)
		}
	}()
	// --- End TmuxDaemon logic ---

	if err := controller.OnStartup(); err != nil {
		log.Fatal("Controller startup failed:", err)
	}
	p := tea.NewProgram(NewModel(&state, controller))
	if err := p.Start(); err != nil {
		log.Fatal(err)
	}
	// On shutdown, kill daemons
	_ = attachedDaemon.Kill()
	_ = detachedDaemon.Kill()
}

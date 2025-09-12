package main

import (
	"log"
	"os"
	"strings"
	"sync/atomic"

	"github.com/nick/proctmux/internal/proctmux"

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

	cfg, err := proctmux.LoadConfig("proctmux.yaml")
	if err != nil {
		log.Printf("Config load warning: %v", err)
	}

	args := os.Args
	subcmd := "start"
	if len(args) > 1 {
		subcmd = args[1]
	}

	// Client mode
	if strings.HasPrefix(subcmd, "signal-") {
		client, cerr := proctmux.NewSignalClient(cfg)
		if cerr != nil {
			log.Fatal(cerr)
		}
		switch subcmd {
		case "signal-start":
			if len(args) < 3 {
				log.Fatal("missing name for signal-start")
			}
			if err := client.StartProcess(args[2]); err != nil {
				log.Fatal(err)
			}
		case "signal-stop":
			if len(args) < 3 {
				log.Fatal("missing name for signal-stop")
			}
			if err := client.StopProcess(args[2]); err != nil {
				log.Fatal(err)
			}
		case "signal-restart":
			if len(args) < 3 {
				log.Fatal("missing name for signal-restart")
			}
			if err := client.RestartProcess(args[2]); err != nil {
				log.Fatal(err)
			}
		case "signal-restart-running":
			if err := client.RestartRunning(); err != nil {
				log.Fatal(err)
			}
		case "signal-stop-running":
			if err := client.StopRunning(); err != nil {
				log.Fatal(err)
			}
		default:
			log.Fatal("unknown subcommand: ", subcmd)
		}
		return
	}

	log.Println("Starting proctmux...")
	log.Printf("Loaded config: %+v", cfg)

	state := proctmux.NewAppState(cfg)
	tmuxContext, err := proctmux.NewTmuxContext(cfg.General.DetachedSessionName, cfg.General.KillExistingSession)
	if err != nil {
		log.Fatal("Failed to create TmuxContext:", err)
	}
	running := new(atomic.Bool)
	running.Store(true)
	controller := proctmux.NewController(&state, tmuxContext, running)
	defer controller.Destroy()

	// --- TmuxDaemon logic moved into controller ---
	if err := controller.RegisterTmuxDaemons(tmuxContext.SessionID, tmuxContext.DetachedSessionID); err != nil {
		log.Fatal("Failed to register tmux daemons:", err)
	}
	// --- End TmuxDaemon logic ---

	if err := controller.OnStartup(); err != nil {
		log.Fatal("Controller startup failed:", err)
	}

	// Start signal server if enabled
	stopServer, serr := proctmux.StartSignalServer(cfg, controller)
	if serr != nil {
		log.Fatal(serr)
	}
	defer stopServer()

	p := tea.NewProgram(proctmux.NewModel(&state, controller))
	if err := p.Start(); err != nil {
		log.Fatal(err)
	}
}

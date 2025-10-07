package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
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
	if logPath == "" {
		// Silence all logging when logPath is empty
		log.SetOutput(io.Discard)
		return nil, nil
	}

	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
	if err != nil {
		return nil, err
	}
	log.SetOutput(logFile)
	return logFile, nil
}

func main() {
	// Parse command-line flags
	var configFile string
	flag.StringVar(&configFile, "f", "", "path to config file (default: searches for proctmux.yaml in current directory)")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: %s [options] [command]\n\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "Options:\n")
		flag.PrintDefaults()
		fmt.Fprintf(os.Stderr, "\nCommands:\n")
		fmt.Fprintf(os.Stderr, "  start                    Start the TUI (default)\n")
		fmt.Fprintf(os.Stderr, "  signal-list              List all processes and their statuses (tab-delimited)\n")
		fmt.Fprintf(os.Stderr, "  signal-start <name>      Start a process via signal server\n")
		fmt.Fprintf(os.Stderr, "  signal-stop <name>       Stop a process via signal server\n")
		fmt.Fprintf(os.Stderr, "  signal-restart <name>    Restart a process via signal server\n")
		fmt.Fprintf(os.Stderr, "  signal-restart-running   Restart all running processes\n")
		fmt.Fprintf(os.Stderr, "  signal-stop-running      Stop all running processes\n")
	}
	flag.Parse()

	cfg, cfgLoadErr := proctmux.LoadConfig(configFile)

	logPath := ""
	if cfg != nil && cfg.LogFile != "" {
		logPath = cfg.LogFile
	}

	logFile, err := setupLogger(logPath)
	if err != nil {
		fmt.Println("Failed to open log file:", cfgLoadErr)
		panic(cfgLoadErr)
	}
	defer func() {
		if logFile != nil {
			logFile.Close()
		}
	}()

	if cfgLoadErr != nil {
		log.Printf("Error loading config: %v", cfgLoadErr)
	}
	if cfg != nil {
		log.Printf("Config loaded: %+v", cfg)
	} else {
		panic(cfgLoadErr)
	}

	// Determine subcommand from remaining args after flag parsing
	args := flag.Args()
	log.Printf("Command-line args: %+v", args)
	subcmd := "start"
	if len(args) > 0 {
		subcmd = args[0]
	}

	// Client mode
	if strings.HasPrefix(subcmd, "signal-") {
		client, cerr := proctmux.NewSignalClient(cfg)
		if cerr != nil {
			log.Fatal(cerr)
		}
		switch subcmd {
		case "signal-start":
			if len(args) < 2 {
				log.Fatal("missing name for signal-start")
			}
			if err := client.StartProcess(args[1]); err != nil {
				log.Fatal(err)
			}
		case "signal-stop":
			if len(args) < 2 {
				log.Fatal("missing name for signal-stop")
			}
			if err := client.StopProcess(args[1]); err != nil {
				log.Fatal(err)
			}
		case "signal-restart":
			if len(args) < 2 {
				log.Fatal("missing name for signal-restart")
			}
			if err := client.RestartProcess(args[1]); err != nil {
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
		case "signal-list":
			data, err := client.GetProcessList()
			if err != nil {
				log.Fatal(err)
			}
			var resp struct {
				ProcessList []map[string]interface{} `json:"process_list"`
			}
			if err := json.Unmarshal(data, &resp); err != nil {
				log.Fatal("failed to parse process list:", err)
			}
			// Output tab-delimited header
			fmt.Println("NAME\tSTATUS")
			// Output each process
			for _, proc := range resp.ProcessList {
				name, _ := proc["name"].(string)
				running, _ := proc["running"].(bool)
				status := "stopped"
				if running {
					status = "running"
				}
				fmt.Printf("%s\t%s\n", name, status)
			}
		default:
			log.Fatal("unknown subcommand: ", subcmd)
		}
		return
	}

	log.Println("Starting proctmux...")
	log.Printf("Loaded config: %+v", cfg)

	state := proctmux.NewAppState(cfg)
	tmuxContext, cfgLoadErr := proctmux.NewTmuxContext(cfg.General.DetachedSessionName, cfg.General.KillExistingSession, cfg.Layout.ProcessesListWidth)
	if cfgLoadErr != nil {
		log.Fatal("Failed to create TmuxContext:", cfgLoadErr)
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

	p := tea.NewProgram(proctmux.NewModel(&state, controller), tea.WithAltScreen())
	if err := p.Start(); err != nil {
		log.Fatal(err)
	}
}

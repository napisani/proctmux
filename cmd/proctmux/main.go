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
	var mode string
	var socketPath string
	flag.StringVar(&configFile, "f", "", "path to config file (default: searches for proctmux.yaml in current directory)")
	flag.StringVar(&mode, "mode", "list", "mode: list (process list UI) or viewer (output viewer)")
	flag.StringVar(&socketPath, "socket", "", "unix socket path (required for viewer mode)")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: %s [options] [command]\n\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "Options:\n")
		flag.PrintDefaults()
		fmt.Fprintf(os.Stderr, "\nCommands:\n")
		fmt.Fprintf(os.Stderr, "  start                    Start the TUI (default)\n")
		fmt.Fprintf(os.Stderr, "  signal-list              List all processes and their statuses (tab-delimited)\n")
		fmt.Fprintf(os.Stderr, "  signal-start <name>      Start a process\n")
		fmt.Fprintf(os.Stderr, "  signal-stop <name>       Stop a process\n")
		fmt.Fprintf(os.Stderr, "  signal-restart <name>    Restart a process\n")
		fmt.Fprintf(os.Stderr, "  signal-restart-running   Restart all running processes\n")
		fmt.Fprintf(os.Stderr, "  signal-stop-running      Stop all running processes\n")
		fmt.Fprintf(os.Stderr, "\nViewer Mode:\n")
		fmt.Fprintf(os.Stderr, "  --mode viewer --socket <path>    View process output in separate terminal\n")
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

	// Viewer mode
	if mode == "viewer" {
		if socketPath == "" {
			log.Fatal("--socket required for viewer mode")
		}
		client, err := proctmux.NewIPCClient(socketPath)
		if err != nil {
			log.Fatal("Failed to connect to IPC server:", err)
		}
		processServer := proctmux.NewProcessServer()
		viewerModel := proctmux.NewViewerModel(client, processServer, cfg)
		p := tea.NewProgram(viewerModel, tea.WithAltScreen())
		if err := p.Start(); err != nil {
			log.Fatal(err)
		}
		return
	}

	// Client mode
	if strings.HasPrefix(subcmd, "signal-") {
		// Discover socket path
		socketPath, cerr := proctmux.ReadSocketPathFile()
		if cerr != nil {
			// Fallback to finding most recent socket
			socketPath, cerr = proctmux.FindIPCSocket()
			if cerr != nil {
				log.Fatal("Failed to find proctmux instance: ", cerr)
			}
		}

		client, cerr := proctmux.NewIPCClient(socketPath)
		if cerr != nil {
			log.Fatal(cerr)
		}
		defer client.Close()

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
	running := new(atomic.Bool)
	running.Store(true)
	controller := proctmux.NewController(&state, running)
	defer controller.Destroy()

	if err := controller.OnStartup(); err != nil {
		log.Fatal("Controller startup failed:", err)
	}

	// Log deprecation warning if signal server is enabled in config
	if cfg.SignalServer.Enable {
		log.Printf("Warning: signal_server configuration is deprecated. Signal commands now use IPC automatically.")
	}

	// Start IPC server for viewer mode and signal commands
	var ipcServer *proctmux.IPCServer
	ipcSocketPath := fmt.Sprintf("/tmp/proctmux-%d.sock", os.Getpid())
	ipcServer = proctmux.NewIPCServer()
	if err := ipcServer.Start(ipcSocketPath); err != nil {
		log.Printf("Warning: Failed to start IPC server: %v", err)
		ipcSocketPath = ""
	} else {
		controller.SetIPCServer(ipcServer)
		log.Printf("IPC server started on %s", ipcSocketPath)

		// Write socket path to well-known location for signal commands
		if err := proctmux.WriteSocketPathFile(ipcSocketPath); err != nil {
			log.Printf("Warning: Failed to write socket path file: %v", err)
		}

		defer func() {
			ipcServer.Stop()
			// Clean up socket path file
			_ = os.Remove("/tmp/proctmux.socket")
		}()
	}

	p := tea.NewProgram(proctmux.NewModel(&state, controller, ipcSocketPath), tea.WithAltScreen())
	if err := p.Start(); err != nil {
		log.Fatal(err)
	}
}

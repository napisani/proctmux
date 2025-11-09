package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"strings"
	"time"

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
	var clientMode bool
	flag.StringVar(&configFile, "f", "", "path to config file (default: searches for proctmux.yaml in current directory)")
	flag.StringVar(&mode, "mode", "master", "mode: master (process server) or client (UI only)")
	flag.BoolVar(&clientMode, "client", false, "run in client mode (connects to master)")
	flag.StringVar(&socketPath, "socket", "", "unix socket path (optional, auto-discovered if not provided)")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: %s [options] [command]\n\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "Options:\n")
		flag.PrintDefaults()
		fmt.Fprintf(os.Stderr, "\nModes:\n")
		fmt.Fprintf(os.Stderr, "  (default)                Run master server (manages processes)\n")
		fmt.Fprintf(os.Stderr, "  --client                 Run UI client (connects to master)\n")
		fmt.Fprintf(os.Stderr, "\nCommands:\n")
		fmt.Fprintf(os.Stderr, "  start                    Start the TUI (default)\n")
		fmt.Fprintf(os.Stderr, "  signal-list              List all processes and their statuses (tab-delimited)\n")
		fmt.Fprintf(os.Stderr, "  signal-start <name>      Start a process\n")
		fmt.Fprintf(os.Stderr, "  signal-stop <name>       Stop a process\n")
		fmt.Fprintf(os.Stderr, "  signal-restart <name>    Restart a process\n")
		fmt.Fprintf(os.Stderr, "  signal-restart-running   Restart all running processes\n")
		fmt.Fprintf(os.Stderr, "  signal-stop-running      Stop all running processes\n")
	}
	flag.Parse()

	// If --client is set, override mode
	if clientMode {
		mode = "client"
	}

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

	// Client mode - connect to master and show UI
	if mode == "client" {
		log.SetPrefix("[CLIENT] ")
		if socketPath == "" {
			// Auto-discover socket path
			var err error
			socketPath, err = proctmux.ReadSocketPathFile()
			if err != nil {
				socketPath, err = proctmux.FindIPCSocket()
				if err != nil {
					log.Fatal("Failed to find master server socket. Start master first with `proctmux`")
				}
			}
		}
		log.Printf("Connecting to master at %s", socketPath)
		client, err := proctmux.NewIPCClient(socketPath)
		if err != nil {
			log.Fatal("Failed to connect to master server:", err)
		}
		defer client.Close()

		// Create client UI model
		state := proctmux.NewAppState(cfg)
		clientModel := proctmux.NewClientModel(client, &state)
		p := tea.NewProgram(clientModel, tea.WithAltScreen())
		if _, err := p.Run(); err != nil {
			log.Fatal(err)
		}
		return
	}

	// Signal commands - connect via IPC
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
		case "signal-switch":
			if len(args) < 2 {
				log.Fatal("missing name for signal-switch")
			}
			if err := client.SwitchProcess(args[1]); err != nil {
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

	// Master mode (default) - Process server with output viewer UI
	log.Println("Starting proctmux master server...")
	log.Printf("Loaded config: %+v", cfg)

	// Log deprecation warning if signal server is enabled in config
	if cfg.SignalServer.Enable {
		log.Printf("Warning: signal_server configuration is deprecated. Signal commands now use IPC automatically.")
	}

	// Create and start master server
	masterServer := proctmux.NewMasterServer(cfg)
	ipcSocketPath := fmt.Sprintf("/tmp/proctmux-%d.sock", os.Getpid())
	
	if err := masterServer.Start(ipcSocketPath); err != nil {
		log.Fatal("Failed to start master server:", err)
	}
	defer masterServer.Stop()

	// Create local IPC client to receive state updates from master
	// Wait a moment for IPC server to be ready
	time.Sleep(100 * time.Millisecond)
	localClient, err := proctmux.NewIPCClient(ipcSocketPath)
	if err != nil {
		log.Fatal("Failed to create local IPC client:", err)
	}
	defer localClient.Close()

	// Create viewer UI with IPC client for state updates and direct process server access
	// model := proctmux.NewViewerModel(localClient, masterServer.GetProcessServer(), cfg)
	// p := tea.NewProgram(model, tea.WithAltScreen())
	// if _, err := p.Run(); err != nil {
	// 	log.Fatal(err)
	// }

	// just pause until ctrl-c
	select {}
}

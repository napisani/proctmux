package main

import (
	"encoding/json"
	"fmt"
	"log"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/ipc"
)

// RunSignalCommand executes a signal command by connecting to the primary server via IPC
func RunSignalCommand(cfg *config.ProcTmuxConfig, subcmd string, args []string) error {
	// Discover socket path
	socketPath, err := ipc.GetSocket(cfg)
	if err != nil {
		log.Fatal("Failed to find proctmux instance: ", err)
	}

	client, err := ipc.NewClient(socketPath)
	if err != nil {
		log.Fatal(err)
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
			ProcessList []map[string]any `json:"process_list"`
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

	return nil
}

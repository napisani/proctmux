package main

import (
	"flag"
	"fmt"
	"os"
)

// CLIConfig holds the parsed command-line configuration
type CLIConfig struct {
	ConfigFile string
	Mode       string
	Subcommand string
	Args       []string
}

// ParseCLI parses command-line arguments and returns the configuration
func ParseCLI() *CLIConfig {
	cfg := &CLIConfig{}

	var clientMode bool
	flag.StringVar(&cfg.ConfigFile, "f", "", "path to config file (default: searches for proctmux.yaml in current directory)")
	flag.StringVar(&cfg.Mode, "mode", "primary", "mode: primary (process server) or client (UI only)")
	flag.BoolVar(&clientMode, "client", false, "run in client mode (connects to primary)")
	flag.Usage = printUsage
	flag.Parse()

	// If --client is set, override mode
	if clientMode {
		cfg.Mode = "client"
	}

	// Determine subcommand from remaining args after flag parsing
	cfg.Args = flag.Args()
	cfg.Subcommand = "start"
	if len(cfg.Args) > 0 {
		cfg.Subcommand = cfg.Args[0]
	}

	return cfg
}

// printUsage prints the command usage information
func printUsage() {
	fmt.Fprintf(os.Stderr, "Usage: %s [options] [command]\n\n", os.Args[0])
	fmt.Fprintf(os.Stderr, "Options:\n")
	flag.PrintDefaults()
	fmt.Fprintf(os.Stderr, "\nModes:\n")
	fmt.Fprintf(os.Stderr, "  (default)                Run primary server (manages processes)\n")
	fmt.Fprintf(os.Stderr, "  --client                 Run UI client (connects to primary)\n")
	fmt.Fprintf(os.Stderr, "\nCommands:\n")
	fmt.Fprintf(os.Stderr, "  start                    Start the TUI (default)\n")
	fmt.Fprintf(os.Stderr, "  signal-list              List all processes and their statuses (tab-delimited)\n")
	fmt.Fprintf(os.Stderr, "  signal-start <name>      Start a process\n")
	fmt.Fprintf(os.Stderr, "  signal-stop <name>       Stop a process\n")
	fmt.Fprintf(os.Stderr, "  signal-restart <name>    Restart a process\n")
	fmt.Fprintf(os.Stderr, "  signal-restart-running   Restart all running processes\n")
	fmt.Fprintf(os.Stderr, "  signal-stop-running      Stop all running processes\n")
}

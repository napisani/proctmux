package main

import (
	"flag"
	"fmt"
	"os"
)

// UnifiedSplit indicates how the unified layout should split the panes.
type UnifiedSplit string

const (
	UnifiedSplitNone   UnifiedSplit = ""
	UnifiedSplitLeft   UnifiedSplit = "left"
	UnifiedSplitRight  UnifiedSplit = "right"
	UnifiedSplitTop    UnifiedSplit = "top"
	UnifiedSplitBottom UnifiedSplit = "bottom"
)

// CLIConfig holds the parsed command-line configuration
type CLIConfig struct {
	ConfigFile         string
	Mode               string
	Subcommand         string
	Args               []string
	Unified            bool
	UnifiedOrientation UnifiedSplit
}

// ParseCLI parses command-line arguments and returns the configuration
func ParseCLI() *CLIConfig {
	cfg := &CLIConfig{}

	var clientMode bool
	var unifiedLeft, unifiedRight, unifiedTop, unifiedBottom bool
	flag.StringVar(&cfg.ConfigFile, "f", "", "path to config file (default: searches for proctmux.yaml in current directory)")
	flag.StringVar(&cfg.Mode, "mode", "primary", "mode: primary (process server) or client (UI only)")
	flag.BoolVar(&clientMode, "client", false, "run in client mode (connects to primary)")
	flag.BoolVar(&cfg.Unified, "unified", false, "run in unified mode (client + server split view; shorthand for --unified-left)")
	flag.BoolVar(&unifiedLeft, "unified-left", false, "run in unified mode with process list on the left (default)")
	flag.BoolVar(&unifiedRight, "unified-right", false, "run in unified mode with process list on the right")
	flag.BoolVar(&unifiedTop, "unified-top", false, "run in unified mode with process list above the output")
	flag.BoolVar(&unifiedBottom, "unified-bottom", false, "run in unified mode with process list below the output")
	flag.Usage = printUsage
	flag.Parse()

	orientationFlags := []struct {
		set         bool
		orientation UnifiedSplit
	}{
		{unifiedLeft, UnifiedSplitLeft},
		{unifiedRight, UnifiedSplitRight},
		{unifiedTop, UnifiedSplitTop},
		{unifiedBottom, UnifiedSplitBottom},
	}

	for _, item := range orientationFlags {
		if !item.set {
			continue
		}
		if cfg.UnifiedOrientation != UnifiedSplitNone {
			fmt.Fprintln(os.Stderr, "multiple unified orientation flags specified")
			os.Exit(2)
		}
		cfg.Unified = true
		cfg.UnifiedOrientation = item.orientation
	}

	if cfg.Unified && cfg.UnifiedOrientation == UnifiedSplitNone {
		cfg.UnifiedOrientation = UnifiedSplitLeft
	}

	// If --client is set, override mode
	if clientMode {
		cfg.Mode = "client"
	}

	if cfg.Unified && cfg.Mode == "client" {
		fmt.Fprintf(os.Stderr, "--client cannot be combined with unified mode options\n")
		os.Exit(2)
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
	fmt.Fprintf(os.Stderr, "  --unified                Run UI client and embedded server (process list on the left)\n")
	fmt.Fprintf(os.Stderr, "  --unified-left           Alias for --unified\n")
	fmt.Fprintf(os.Stderr, "  --unified-right          Unified mode with process list on the right\n")
	fmt.Fprintf(os.Stderr, "  --unified-top            Unified mode with process list above the output\n")
	fmt.Fprintf(os.Stderr, "  --unified-bottom         Unified mode with process list below the output\n")
	fmt.Fprintf(os.Stderr, "\nCommands:\n")
	fmt.Fprintf(os.Stderr, "  start                    Start the TUI (default)\n")
	fmt.Fprintf(os.Stderr, "  signal-list              List all processes and their statuses (tab-delimited)\n")
	fmt.Fprintf(os.Stderr, "  signal-start <name>      Start a process\n")
	fmt.Fprintf(os.Stderr, "  signal-stop <name>       Stop a process\n")
	fmt.Fprintf(os.Stderr, "  signal-restart <name>    Restart a process\n")
	fmt.Fprintf(os.Stderr, "  signal-restart-running   Restart all running processes\n")
	fmt.Fprintf(os.Stderr, "  signal-stop-running      Stop all running processes\n")
}

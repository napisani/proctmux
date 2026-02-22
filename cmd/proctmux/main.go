package main

import (
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/procdiscover"

	_ "github.com/nick/proctmux/internal/procdiscover/makefile"
	_ "github.com/nick/proctmux/internal/procdiscover/packagejson"
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
	// Parse command-line arguments
	cliCfg := ParseCLI()

	// Handle config-init before attempting to load configuration
	if cliCfg.Subcommand == "config-init" {
		if err := RunConfigInit(cliCfg.Args); err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(1)
		}
		return
	}

	// Load configuration file
	cfg, cfgLoadErr := config.LoadConfig(cliCfg.ConfigFile)

	// Setup logging
	logPath := ""
	if cfg != nil && cfg.LogFile != "" {
		logPath = cfg.LogFile
	}

	logFile, err := setupLogger(logPath)
	if err != nil {
		fmt.Println("Failed to open log file:", err)
		panic(err)
	}
	defer func() {
		if logFile != nil {
			logFile.Close()
		}
	}()

	// Handle config loading errors
	if cfgLoadErr != nil {
		log.Printf("Error loading config: %v", cfgLoadErr)
	}
	if cfg != nil {
		discoveryCwd := filepath.Dir(cfg.FilePath)
		if discoveryCwd == "" || discoveryCwd == "." {
			if cwd, err := os.Getwd(); err == nil {
				discoveryCwd = cwd
			} else {
				log.Printf("Proc discovery: unable to determine working directory: %v", err)
			}
		}
		procdiscover.Apply(cfg, discoveryCwd)
		log.Printf("Config loaded from %s with %d processes", cfg.FilePath, len(cfg.Procs))
	} else {
		panic(cfgLoadErr)
	}

	log.Printf("Command-line args: %+v", cliCfg.Args)

	if cliCfg.Unified {
		if err := RunUnified(cfg, cliCfg); err != nil {
			log.Fatal(err)
		}
		return
	}

	// Route to appropriate mode/command
	if cliCfg.Mode == "client" {
		if err := RunClient(cfg); err != nil {
			log.Fatal(err)
		}
		return
	}

	if strings.HasPrefix(cliCfg.Subcommand, "signal-") {
		if err := RunSignalCommand(cfg, cliCfg.Subcommand, cliCfg.Args); err != nil {
			log.Fatal(err)
		}
		return
	}

	// Default: primary mode
	if err := RunPrimary(cfg); err != nil {
		log.Fatal(err)
	}
}

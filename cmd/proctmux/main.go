package main

import (
	"fmt"
	"io"
	"log"
	"os"
	"strings"

	"github.com/nick/proctmux/internal/proctmux"
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

	// Load configuration file
	cfg, cfgLoadErr := proctmux.LoadConfig(cliCfg.ConfigFile)

	// Setup logging
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

	// Handle config loading errors
	if cfgLoadErr != nil {
		log.Printf("Error loading config: %v", cfgLoadErr)
	}
	if cfg != nil {
		log.Printf("Config loaded: %+v", cfg)
	} else {
		panic(cfgLoadErr)
	}

	log.Printf("Command-line args: %+v", cliCfg.Args)

	// Route to appropriate mode/command
	if cliCfg.Mode == "client" {
		if err := RunClient(cfg, cliCfg.SocketPath); err != nil {
			log.Fatal(err)
		}
		return
	}

	if strings.HasPrefix(cliCfg.Subcommand, "signal-") {
		if err := RunSignalCommand(cliCfg.Subcommand, cliCfg.Args); err != nil {
			log.Fatal(err)
		}
		return
	}

	// Default: primary mode
	if err := RunPrimary(cfg); err != nil {
		log.Fatal(err)
	}
}

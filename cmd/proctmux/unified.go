package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/taigrr/bubbleterm/emulator"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
	"github.com/nick/proctmux/internal/ipc"
	"github.com/nick/proctmux/internal/tui"
)

// RunUnified launches proctmux in unified mode with a split-pane UI combining the
// client view and an embedded terminal running the primary server.
func RunUnified(cfg *config.ProcTmuxConfig, cliCfg *CLIConfig) error {
	if cliCfg.Mode == "client" {
		return fmt.Errorf("--unified cannot be combined with client mode")
	}

	log.SetPrefix("[UNIFIED] ")

	executable := os.Args[0]
	cwd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("failed to determine working directory: %w", err)
	}

	args := unifiedChildArgs()

	emu, err := emulator.New(80, 24)
	if err != nil {
		return fmt.Errorf("failed to create embedded terminal: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	defer emu.Close()

	cmd := exec.CommandContext(ctx, executable, args...)
	cmd.Dir = cwd
	cmd.Env = os.Environ()

	if err := emu.StartCommand(cmd); err != nil {
		return fmt.Errorf("failed to start embedded primary server: %w", err)
	}

	log.Println("Waiting for embedded primary server to become available...")
	socketPath, err := ipc.WaitForSocket(cfg)
	if err != nil {
		return fmt.Errorf("embedded primary server did not start: %w", err)
	}

	client, err := ipc.NewClient(socketPath)
	if err != nil {
		return fmt.Errorf("failed to connect to embedded primary server: %w", err)
	}
	defer client.Close()

	state := domain.NewAppState(cfg)
	clientModel := tui.NewClientModel(client, &state)

	orientation := tui.SplitLeft
	switch cliCfg.UnifiedOrientation {
	case UnifiedSplitRight:
		orientation = tui.SplitRight
	case UnifiedSplitTop:
		orientation = tui.SplitTop
	case UnifiedSplitBottom:
		orientation = tui.SplitBottom
	}

	unified := tui.NewUnifiedModel(clientModel, emu, orientation)

	program := tea.NewProgram(unified, bubbleTeaProgramOptions()...)
	if _, err := program.Run(); err != nil {
		return fmt.Errorf("unified program exited with error: %w", err)
	}

	return nil
}

func unifiedChildArgs() []string {
	args := os.Args[1:]
	filtered := make([]string, 0, len(args)+2)
	skipNext := false

	for i := 0; i < len(args); i++ {
		if skipNext {
			skipNext = false
			continue
		}

		arg := args[i]
		lower := strings.ToLower(arg)

		switch {
		case lower == "--unified", lower == "-unified", strings.HasPrefix(lower, "--unified="):
			continue
		case lower == "--client", lower == "-client", strings.HasPrefix(lower, "--client="):
			continue
		case lower == "--mode", lower == "-mode":
			if i+1 < len(args) {
				skipNext = true
			}
			continue
		case strings.HasPrefix(lower, "--mode="):
			continue
		case lower == "--unified-left", lower == "-unified-left":
			continue
		case lower == "--unified-right", lower == "-unified-right":
			continue
		case lower == "--unified-top", lower == "-unified-top":
			continue
		case lower == "--unified-bottom", lower == "-unified-bottom":
			continue
		}

		filtered = append(filtered, arg)
	}

	filtered = append(filtered, "--mode", "primary")
	return filtered
}

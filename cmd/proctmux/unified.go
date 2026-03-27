package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/creack/pty"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
	"github.com/nick/proctmux/internal/ipc"
	"github.com/nick/proctmux/internal/terminal/charmvt"
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

	// Create the virtual terminal emulator for rendering the primary server's output.
	emu := charmvt.New(80, 24)
	defer emu.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Start the primary server as a child process in a real PTY.
	// PTY management is separate from terminal emulation: creack/pty owns
	// the PTY, and charmbracelet/x/vt processes the output for rendering.
	cmd := exec.CommandContext(ctx, executable, args...)
	cmd.Dir = cwd
	cmd.Env = os.Environ()

	ptmx, err := pty.Start(cmd)
	if err != nil {
		return fmt.Errorf("failed to start embedded primary server: %w", err)
	}
	defer ptmx.Close()

	// Pipe PTY output into the emulator. The goroutine exits naturally when
	// the PTY master returns io.EOF (child exits) or when ptmx is closed
	// (deferred above on early return / user quit).
	go func() {
		if _, err := io.Copy(emu, ptmx); err != nil {
			log.Printf("PTY copy to emulator ended: %v", err)
		}
	}()

	// Relay the emulator's terminal responses back to the child process.
	// The VT emulator generates responses to terminal queries (e.g. OSC 11
	// background color queries, DSR cursor position reports) and writes them
	// to an internal pipe accessible via Read(). These responses must be
	// forwarded back to the child's stdin (via ptmx) so that libraries like
	// termenv/lipgloss in the child process receive the answers they're
	// waiting for — otherwise the child blocks for up to 5 seconds on each
	// unanswered query (the termenv.OSCTimeout).
	//
	// This also prevents a deadlock: if nobody reads from the pipe, Write()
	// blocks while holding the SafeEmulator mutex, which deadlocks Render().
	go func() {
		buf := make([]byte, 256)
		for {
			n, err := emu.Read(buf)
			if err != nil {
				return
			}
			if n > 0 {
				if _, werr := ptmx.Write(buf[:n]); werr != nil {
					return
				}
			}
		}
	}()

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

	unified := tui.NewSplitPaneModel(clientModel, emu, ptmx, cmd, orientation, cfg.Layout.HideProcessListWhenUnfocused)

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

	for i := range args {
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

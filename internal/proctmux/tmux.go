package proctmux

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// TODO make this part of the configuration
const splitSize = "70%"

const (
	SessionTypeForeground = "FOREGROUND_SESSION"
	SessionTypeDetached   = "DETACHED_SESSION"
	SessionTypeNone       = "NO_SESSION"
)

func ListSessions() ([]string, error) {
	out, err := exec.Command(tmuxBin(), "list-sessions", "-F", "#{session_name}").Output()
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	return lines, nil
}

// CurrentSession returns the current tmux session id
func CurrentSession() (string, error) {
	out, err := exec.Command(tmuxBin(), "display-message", "-p", "#{session_id}").Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// CurrentPane returns the current tmux pane id
func CurrentPane() (string, error) {
	out, err := exec.Command(tmuxBin(), "display-message", "-p", "#{pane_id}").Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// StartDetachedSession creates a new detached tmux session and returns its id
func StartDetachedSession(sessionName string) (string, error) {
	out, err := exec.Command(tmuxBin(), "new-session", "-d", "-s", sessionName, "-P", "-F", "#{session_id}").Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func SetGlobalRemainOnExit(enabled bool) error {
	value := "off"
	if enabled {
		value = "on"
	}

	cmd := exec.Command(tmuxBin(), "set-option", "-g", "remain-on-exit", value)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to set global remain-on-exit option to %s: %w", value, err)
	}

	return nil
}

// KillSession kills a tmux session by id
func KillSession(sessionID string) error {
	return exec.Command(tmuxBin(), "kill-session", "-t", sessionID).Run()
}

// KillPane kills a tmux pane by id
func KillPane(paneID string) error {
	// Validate pane ID
	if paneID == "" {
		return fmt.Errorf("cannot kill pane: pane ID is empty")
	}

	// Optional: Check if the pane exists before trying to kill it
	// This adds safety but requires additional command execution
	checkCmd := exec.Command(tmuxBin(), "has-session", "-t", paneID)
	if err := checkCmd.Run(); err != nil {
		return fmt.Errorf("pane %s does not exist or is invalid: %w", paneID, err)
	}

	// Execute the kill command with the validated pane ID
	killCmd := exec.Command(tmuxBin(), "kill-pane", "-t", paneID)
	if err := killCmd.Run(); err != nil {
		return fmt.Errorf("failed to kill pane %s: %w", paneID, err)
	}

	return nil
}

// BreakPane breaks a pane into a new window in a session
func BreakPane(paneID, destSession string, destWindow int, windowLabel string) error {
	target := fmt.Sprintf("%s:%d", destSession, destWindow)
	log.Printf("running command: tmux break-pane -d -s %s -t %s -n %s", paneID, target, windowLabel)
	return exec.Command(tmuxBin(), "break-pane", "-d", "-s", paneID, "-t", target, "-n", windowLabel).Run()
}

// JoinPane joins a source pane into a destination pane
func JoinPane(sourcePane, destPane string, splitSize string) error {
	return exec.Command(tmuxBin(), "join-pane", "-d", "-h",
		"-l", splitSize,
		"-f",
		"-s", sourcePane, "-t", destPane).Run()
}

// SelectPane selects a pane by id
func SelectPane(paneID string) error {
	return exec.Command(tmuxBin(), "select-pane", "-t", paneID).Run()
}

// ToggleZoom toggles zoom for a pane
func ToggleZoom(paneID string) error {
	return exec.Command(tmuxBin(), "resize-pane", "-Z", "-t", paneID).Run()
}

// CreatePane creates a new pane with env and working directory
func CreatePane(parentPaneID, command, workingDir string, env map[string]string, splitSize string) (string, int, error) {
	SetGlobalRemainOnExit(true)
	args := []string{"split-window", "-d", "-h", "-l", splitSize, "-t", parentPaneID, "-c", workingDir, "-P", "-F", "#{pane_id}:#{pane_pid}"}
	for k, v := range env {
		args = append(args, "-e", fmt.Sprintf("%s=%s", k, v))
	}
	args = append(args, command)
	out, err := exec.Command(tmuxBin(), args...).Output()
	if err != nil {
		return "", 0, err
	}

	parts := strings.Split(strings.TrimSpace(string(out)), ":")
	if len(parts) != 2 {
		return "", 0, fmt.Errorf("unexpected output format from tmux: %s", out)
	}

	paneID := parts[0]
	pid, err := strconv.Atoi(parts[1])
	if err != nil {
		return paneID, 0, fmt.Errorf("failed to parse PID: %w", err)
	}

	return paneID, pid, nil
}

// CreateDetachedPane creates a new detached window with env and working directory
func CreateDetachedPane(destSession string, destWindow int, windowLabel, command, workingDir string, env map[string]string) (string, int, error) {
	target := fmt.Sprintf("%s:%d", destSession, destWindow)
	args := []string{"new-window", "-d", "-t", target, "-n", windowLabel, "-c", workingDir, "-P", "-F", "#{pane_id}:#{pane_pid}"}
	for k, v := range env {
		args = append(args, "-e", fmt.Sprintf("%s=%s", k, v))
	}
	args = append(args, command)
	out, err := exec.Command(tmuxBin(), args...).Output()
	if err != nil {
		return "", 0, err
	}

	parts := strings.Split(strings.TrimSpace(string(out)), ":")
	if len(parts) != 2 {
		return "", 0, fmt.Errorf("unexpected output format from tmux: %s", out)
	}

	paneID := parts[0]
	pid, err := strconv.Atoi(parts[1])
	if err != nil {
		return paneID, 0, fmt.Errorf("failed to parse PID: %w", err)
	}

	return paneID, pid, nil
}

// PaneVariables returns formatted variables for a pane
func PaneVariables(paneID, format string) (string, error) {
	args := []string{"list-panes", "-t", paneID, "-f", fmt.Sprintf("#{m:%s,#{pane_id}}", paneID), "-F", format}
	out, err := exec.Command(tmuxBin(), args...).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// GetPaneSessionType returns FOREGROUND_SESSION, DETACHED_SESSION, or NO_SESSION
// for the given pane by comparing its session_id via tmux.
// It compares to the provided foreground and detached session IDs.
func GetPaneSessionType(paneID, foregroundSessionID, detachedSessionID string) (string, error) {
	out, err := exec.Command(tmuxBin(), "display-message", "-p", "-t", paneID, "#{session_id}").Output()
	if err != nil {
		// If the pane doesn't exist or tmux errors, treat as no session.
		return SessionTypeNone, nil
	}
	session := strings.TrimSpace(string(out))
	if session == strings.TrimSpace(foregroundSessionID) {
		return SessionTypeForeground, nil
	}
	if session == strings.TrimSpace(detachedSessionID) {
		return SessionTypeDetached, nil
	}
	return SessionTypeNone, nil
}

// ControlMode attaches to a session in control mode
func ControlMode(sessionID string) (*exec.Cmd, error) {
	cmd := exec.Command(tmuxBin(), "-C", "attach-session", "-t", sessionID)
	cmd.Stdin = nil
	cmd.Stdout = nil
	return cmd, nil
}

// ShowTextPopup opens a tmux popup and renders the given content.
// Uses `less -R` so the user can scroll; close with 'q'.
func (t *TmuxContext) ShowTextPopup(content string) error {
	tmp, err := os.CreateTemp("", "proctmux-doc-*.txt")
	if err != nil {
		return err
	}
	path := tmp.Name()
	_ = tmp.Close()
	defer os.Remove(path)
	if err := os.WriteFile(path, []byte(content), 0600); err != nil {
		return err
	}
	cmd := exec.Command(tmuxBin(), "display-popup", "-E", "sh", "-lc", fmt.Sprintf("less -R %q", path))
	return cmd.Run()
}

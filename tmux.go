package main

import (
	"fmt"
	"os/exec"
	"strings"
)

// TODO make this part of the configuration
const splitSize = "70%"

func TmuxNewPane(cmd string, args ...string) (string, error) {
	fullCmd := strings.Join(append([]string{cmd}, args...), " ")
	out, err := exec.Command("tmux", "split-window", "-P", "-F", "#{pane_id}", fullCmd).Output()
	if err != nil {
		return "", fmt.Errorf("tmux split-window: %w", err)
	}
	return strings.TrimSpace(string(out)), nil
}

func TmuxAttachPane(paneID string) error {
	return exec.Command("tmux", "select-pane", "-t", paneID).Run()
}

func TmuxListPanes() ([]string, error) {
	out, err := exec.Command("tmux", "list-panes", "-F", "#{pane_id}").Output()
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	return lines, nil
}

// ListSessions returns a list of tmux session names
func ListSessions() ([]string, error) {
	out, err := exec.Command("tmux", "list-sessions", "-F", "#{session_name}").Output()
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	return lines, nil
}

// CurrentSession returns the current tmux session id
func CurrentSession() (string, error) {
	out, err := exec.Command("tmux", "display-message", "-p", "#{session_id}").Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// CurrentPane returns the current tmux pane id
func CurrentPane() (string, error) {
	out, err := exec.Command("tmux", "display-message", "-p", "#{pane_id}").Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// StartDetachedSession creates a new detached tmux session and returns its id
func StartDetachedSession(sessionName string) (string, error) {
	out, err := exec.Command("tmux", "new-session", "-d", "-s", sessionName, "-P", "-F", "#{session_id}").Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// SetRemainOnExit sets the remain-on-exit option for a pane
func SetRemainOnExit(paneID string, on bool) error {
	val := "off"
	if on {
		val = "on"
	}
	return exec.Command("tmux", "set-option", "-t", paneID, "remain-on-exit", val).Run()
}

// KillSession kills a tmux session by id
func KillSession(sessionID string) error {
	return exec.Command("tmux", "kill-session", "-t", sessionID).Run()
}

// KillPane kills a tmux pane by id
func KillPane(paneID string) error {
	return exec.Command("tmux", "kill-pane", "-t", paneID).Run()
}

// BreakPane breaks a pane into a new window in a session
func BreakPane(paneID, destSession string, destWindow int, windowLabel string) error {
	target := fmt.Sprintf("%s:%d", destSession, destWindow)
	return exec.Command("tmux", "break-pane", "-d", "-s", paneID, "-t", target, "-n", windowLabel).Run()
}

// JoinPane joins a source pane into a destination pane
func JoinPane(sourcePane, destPane string) error {
	return exec.Command("tmux", "join-pane", "-d", "-h",
		"-l", splitSize,
		"-f",
		"-s", sourcePane, "-t", destPane).Run()
}

// GetPanePID returns the PID of the process running in a pane
func GetPanePID(paneID string) (string, error) {
	out, err := exec.Command("tmux", "display-message", "-p", "-t", paneID, "#{pane_pid}").Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// SelectPane selects a pane by id
func SelectPane(paneID string) error {
	return exec.Command("tmux", "select-pane", "-t", paneID).Run()
}

// ToggleZoom toggles zoom for a pane
func ToggleZoom(paneID string) error {
	return exec.Command("tmux", "resize-pane", "-Z", "-t", paneID).Run()
}

// CreatePane creates a new pane with env and working directory
func CreatePane(parentPaneID, command, workingDir string, env map[string]string) (string, error) {
	args := []string{"split-window", "-d", "-h", "-l", splitSize, "-t", parentPaneID, "-c", workingDir, "-P", "-F", "#{pane_id}"}
	for k, v := range env {
		args = append(args, "-e", fmt.Sprintf("%s=%s", k, v))
	}
	args = append(args, command)
	out, err := exec.Command("tmux", args...).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// CreateDetachedPane creates a new detached window with env and working directory
func CreateDetachedPane(destSession string, destWindow int, windowLabel, command, workingDir string, env map[string]string) (string, error) {
	target := fmt.Sprintf("%s:%d", destSession, destWindow)
	args := []string{"new-window", "-d", "-t", target, "-n", windowLabel, "-c", workingDir, "-P", "-F", "#{pane_id}"}
	for k, v := range env {
		args = append(args, "-e", fmt.Sprintf("%s=%s", k, v))
	}
	args = append(args, command)
	out, err := exec.Command("tmux", args...).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// PaneVariables returns formatted variables for a pane
func PaneVariables(paneID, format string) (string, error) {
	args := []string{"list-panes", "-t", paneID, "-f", fmt.Sprintf("#{m:%s,#{pane_id}}", paneID), "-F", format}
	out, err := exec.Command("tmux", args...).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// ControlMode attaches to a session in control mode
func ControlMode(sessionID string) (*exec.Cmd, error) {
	cmd := exec.Command("tmux", "-C", "attach-session", "-t", sessionID)
	cmd.Stdin = nil
	cmd.Stdout = nil
	return cmd, nil
}

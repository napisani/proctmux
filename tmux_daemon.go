package main

import (
	"bufio"
	"fmt"
	"io"
	"os/exec"
	"strconv"
	"strings"
	"sync/atomic"
)

type TmuxDaemon struct {
	SessionID        string
	Cmd              *exec.Cmd
	Stdin            io.WriteCloser
	Stdout           io.ReadCloser
	Running          *atomic.Bool
	SubscriptionName string
}

func NewTmuxDaemon(sessionID string) (*TmuxDaemon, error) {
	cmd := exec.Command("tmux", "-C", "attach-session", "-t", sessionID)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("failed to get stdin: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("failed to get stdout: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start tmux control mode: %w", err)
	}
	subscriptionName := fmt.Sprintf("pane_dead_notification_%s", cleanSessionID(sessionID))
	daemon := &TmuxDaemon{
		SessionID:        sessionID,
		Cmd:              cmd,
		Stdin:            stdin,
		Stdout:           stdout,
		Running:          new(atomic.Bool),
		SubscriptionName: subscriptionName,
	}
	daemon.Running.Store(true)
	return daemon, nil
}

func (d *TmuxDaemon) SubscribeToPaneDeadNotifications() error {
	cmd := fmt.Sprintf("refresh-client -B %s:%%*:\"#{pane_dead} #{pane_pid}\"\n", d.SubscriptionName)
	_, err := d.Stdin.Write([]byte(cmd))
	return err
}

func (d *TmuxDaemon) ListenForDeadPanes(pidCh chan<- int) error {
	reader := bufio.NewReader(d.Stdout)
	subscriptionName := d.SubscriptionName
	sessionID := d.SessionID
	go func() {
		for d.Running.Load() {
			line, err := reader.ReadString('\n')
			if err != nil {
				return
			}
			if pid, ok := parsePaneDeadNotification(line, subscriptionName, sessionID); ok {
				pidCh <- pid
			}
		}
	}()
	return d.SubscribeToPaneDeadNotifications()
}

func (d *TmuxDaemon) Kill() error {
	d.Running.Store(false)
	if err := d.Cmd.Process.Kill(); err != nil {
		return err
	}
	_, err := d.Cmd.Process.Wait()
	return err
}

func parsePaneDeadNotification(line, subscriptionName, sessionID string) (int, bool) {
	if strings.HasPrefix(line, "%subscription-changed "+subscriptionName) {
		ss := strings.Fields(line)
		if len(ss) >= 2 && ss[len(ss)-2] == "1" {
			pid, err := strconv.Atoi(strings.TrimSpace(ss[len(ss)-1]))
			if err == nil {
				return pid, true
			}
		}
	}
	return 0, false
}

func cleanSessionID(s string) string {
	return strings.ReplaceAll(s, "$", "")
}

package proctmux

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"log"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type TmuxDaemon struct {
	SessionID        string
	Cmd              *exec.Cmd
	Stdin            io.WriteCloser
	Stdout           io.ReadCloser
	Running          *atomic.Bool
	SubscriptionName string
	state            *AppState
	stateMu          *sync.Mutex
}

func NewTmuxDaemon(sessionID string) (*TmuxDaemon, error) {
	cmd := exec.Command(tmuxBin(), "-C", "attach-session", "-t", sessionID)
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
				log.Printf("Detected dead pane in session %s with PID %d", sessionID, pid)
				pidCh <- pid
			}
		}
	}()

	// Okay, for now there are two mechanisms by which we can detect dead panes.
	// the first, and preferred, is via tmux's built-in pane_dead notification. However, from some testing, this seems unreliable under certain conditions. (d.SubscribeToPaneDeadNotifications())
	// Therefore, we also implement a periodic reaper that checks the liveness of known PIDs.
	// This is a fallback mechanism to ensure we catch any missed terminations.
	// We start the reaper in a separate goroutine. (d.startPidReaper(pidCh))
	d.startPidReaper(pidCh)
	return d.SubscribeToPaneDeadNotifications()
}

func (d *TmuxDaemon) Destroy() error {
	d.Running.Store(false)
	if err := d.Cmd.Process.Kill(); err != nil {
		return err
	}
	_, err := d.Cmd.Process.Wait()
	return err
}

func pidExists(pid int) bool {
	if pid <= 0 {
		return false
	}
	if runtime.GOOS != "windows" {
		err := syscall.Kill(pid, 0)
		if err == nil {
			return true
		}
		if errors.Is(err, syscall.EPERM) {
			return true
		}
		return false
	}
	// For windows, best effort check
	return true
}

func (d *TmuxDaemon) startPidReaper(pidCh chan<- int) {
	ticker := time.NewTicker(10 * time.Second)
	go func() {
		defer ticker.Stop()
		for d.Running.Load() {
			<-ticker.C
			// snapshot PIDs under controller mutex
			var pids []int
			if d.stateMu != nil && d.state != nil {
				d.stateMu.Lock()
				for _, p := range d.state.Processes {
					if p.PID > 0 {
						pids = append(pids, p.PID)
					}
				}
				d.stateMu.Unlock()
			}
			for _, pid := range pids {
				if !pidExists(pid) {
					log.Printf("Reaper detected dead PID %d", pid)
					select {
					case pidCh <- pid:
					default:
						log.Printf("pidCh full, cannot send pid %d", pid)
					}
				} else {
					log.Printf("Reaper checked PID %d, still alive", pid)
				}
			}
		}
	}()
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

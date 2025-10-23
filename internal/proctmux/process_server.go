package proctmux

import (
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"sync"

	"github.com/creack/pty"
)

type ProcessServer struct {
	processes map[int]*ProcessInstance
	mu        sync.RWMutex
}

type ProcessInstance struct {
	ID       int
	cmd      *exec.Cmd
	pty      *os.File
	config   *ProcessConfig
	exitChan chan error
}

func NewProcessServer() *ProcessServer {
	return &ProcessServer{
		processes: make(map[int]*ProcessInstance),
	}
}

func (ps *ProcessServer) StartProcess(id int, config *ProcessConfig) (*ProcessInstance, error) {
	ps.mu.Lock()
	defer ps.mu.Unlock()

	if _, exists := ps.processes[id]; exists {
		return nil, fmt.Errorf("process %d already exists", id)
	}

	cmd := buildCommand(config)
	if cmd == nil {
		return nil, fmt.Errorf("invalid process config: no shell or cmd specified")
	}

	if config.Cwd != "" {
		cmd.Dir = config.Cwd
	}

	cmd.Env = buildEnvironment(config)

	ptmx, err := pty.Start(cmd)
	if err != nil {
		return nil, fmt.Errorf("failed to start process with pty: %w", err)
	}

	instance := &ProcessInstance{
		ID:       id,
		cmd:      cmd,
		pty:      ptmx,
		config:   config,
		exitChan: make(chan error, 1),
	}

	go func() {
		err := cmd.Wait()
		instance.exitChan <- err
		close(instance.exitChan)
	}()

	ps.processes[id] = instance
	log.Printf("Started process %d (PID: %d)", id, cmd.Process.Pid)

	return instance, nil
}

func (ps *ProcessServer) GetProcess(id int) (*ProcessInstance, error) {
	ps.mu.RLock()
	defer ps.mu.RUnlock()

	instance, exists := ps.processes[id]
	if !exists {
		return nil, fmt.Errorf("process %d not found", id)
	}

	return instance, nil
}

func (ps *ProcessServer) StopProcess(id int) error {
	ps.mu.Lock()
	defer ps.mu.Unlock()

	instance, exists := ps.processes[id]
	if !exists {
		return fmt.Errorf("process %d not found", id)
	}

	if instance.cmd.Process != nil {
		if err := instance.cmd.Process.Kill(); err != nil {
			return fmt.Errorf("failed to kill process: %w", err)
		}
	}

	if instance.pty != nil {
		instance.pty.Close()
	}

	delete(ps.processes, id)
	log.Printf("Stopped process %d", id)

	return nil
}

func (ps *ProcessServer) RemoveProcess(id int) {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	delete(ps.processes, id)
}

func (ps *ProcessServer) GetReader(id int) (io.Reader, error) {
	ps.mu.RLock()
	defer ps.mu.RUnlock()

	instance, exists := ps.processes[id]
	if !exists {
		return nil, fmt.Errorf("process %d not found", id)
	}

	return instance.pty, nil
}

func (ps *ProcessServer) GetWriter(id int) (io.Writer, error) {
	ps.mu.RLock()
	defer ps.mu.RUnlock()

	instance, exists := ps.processes[id]
	if !exists {
		return nil, fmt.Errorf("process %d not found", id)
	}

	return instance.pty, nil
}

func (pi *ProcessInstance) GetPID() int {
	if pi.cmd.Process == nil {
		return -1
	}
	return pi.cmd.Process.Pid
}

func (pi *ProcessInstance) WaitForExit() <-chan error {
	return pi.exitChan
}

func buildCommand(config *ProcessConfig) *exec.Cmd {
	if config.Shell != "" {
		return exec.Command("sh", "-c", config.Shell)
	}

	if len(config.Cmd) > 0 {
		return exec.Command(config.Cmd[0], config.Cmd[1:]...)
	}

	return nil
}

func buildEnvironment(config *ProcessConfig) []string {
	env := os.Environ()

	if config.Env != nil {
		for k, v := range config.Env {
			env = append(env, fmt.Sprintf("%s=%s", k, v))
		}
	}

	if len(config.AddPath) > 0 {
		currentPath := os.Getenv("PATH")
		for _, p := range config.AddPath {
			currentPath = fmt.Sprintf("%s:%s", currentPath, p)
		}
		env = append(env, fmt.Sprintf("PATH=%s", currentPath))
	}

	return env
}

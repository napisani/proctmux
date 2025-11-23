package process

import (
	"os"
	"strings"
	"testing"

	"github.com/nick/proctmux/internal/config"
)

func TestBuildCommand_Shell(t *testing.T) {
	cfg := &config.ProcessConfig{
		Shell: "echo hello world",
	}

	cmd := buildCommand(cfg, nil)

	if cmd == nil {
		t.Fatal("Expected command to be created")
	}

	// sh path can vary by system (/bin/sh, /nix/store/.../bin/sh, etc)
	if !strings.Contains(cmd.Path, "sh") {
		t.Errorf("Expected sh command, got %q", cmd.Path)
	}

	// Should use sh -c
	if len(cmd.Args) < 3 {
		t.Fatalf("Expected at least 3 args for sh -c, got %d", len(cmd.Args))
	}

	if cmd.Args[1] != "-c" {
		t.Errorf("Expected second arg to be '-c', got %q", cmd.Args[1])
	}

	if cmd.Args[2] != "echo hello world" {
		t.Errorf("Expected shell command as third arg, got %q", cmd.Args[2])
	}
}

func TestBuildCommand_CmdArray(t *testing.T) {
	cfg := &config.ProcessConfig{
		Cmd: []string{"/bin/ls", "-la", "/tmp"},
	}

	cmd := buildCommand(cfg, nil)

	if cmd == nil {
		t.Fatal("Expected command to be created")
	}

	if cmd.Path != "/bin/ls" {
		t.Errorf("Expected /bin/ls, got %q", cmd.Path)
	}

	// Args should include the command name plus additional args
	expectedArgs := []string{"/bin/ls", "-la", "/tmp"}
	if len(cmd.Args) != len(expectedArgs) {
		t.Fatalf("Expected %d args, got %d", len(expectedArgs), len(cmd.Args))
	}

	for i, expected := range expectedArgs {
		if cmd.Args[i] != expected {
			t.Errorf("Arg %d: expected %q, got %q", i, expected, cmd.Args[i])
		}
	}
}

func TestBuildCommand_ShellPriority(t *testing.T) {
	// When both Shell and Cmd are set, Shell should take priority
	cfg := &config.ProcessConfig{
		Shell: "shell command",
		Cmd:   []string{"cmd", "array"},
	}

	cmd := buildCommand(cfg, nil)

	if cmd == nil {
		t.Fatal("Expected command to be created")
	}

	// Should use shell
	if !strings.Contains(cmd.String(), "sh") {
		t.Error("Expected shell command to be used")
	}

	// The shell command should be in the args
	found := false
	for _, arg := range cmd.Args {
		if arg == "shell command" {
			found = true
			break
		}
	}
	if !found {
		t.Error("Expected shell command in args")
	}
}

func TestBuildCommand_NeitherShellNorCmd(t *testing.T) {
	cfg := &config.ProcessConfig{}

	cmd := buildCommand(cfg, nil)

	if cmd != nil {
		t.Error("Expected nil command when neither Shell nor Cmd is set")
	}
}

func TestBuildCommand_EmptyCmdArray(t *testing.T) {
	cfg := &config.ProcessConfig{
		Cmd: []string{},
	}

	cmd := buildCommand(cfg, nil)

	if cmd != nil {
		t.Error("Expected nil command when Cmd array is empty")
	}
}

func TestBuildCommand_SingleElementCmd(t *testing.T) {
	cfg := &config.ProcessConfig{
		Cmd: []string{"/usr/bin/whoami"},
	}

	cmd := buildCommand(cfg, nil)

	if cmd == nil {
		t.Fatal("Expected command to be created")
	}

	if cmd.Path != "/usr/bin/whoami" {
		t.Errorf("Expected /usr/bin/whoami, got %q", cmd.Path)
	}

	if len(cmd.Args) != 1 {
		t.Errorf("Expected 1 arg, got %d", len(cmd.Args))
	}
}

func TestBuildCommand_CustomShellCmd(t *testing.T) {
	cfg := &config.ProcessConfig{
		Shell: "echo -e '\\033[31mRed\\033[0m'",
	}

	globalConfig := &config.ProcTmuxConfig{
		ShellCmd: []string{"/bin/bash", "-c"},
	}

	cmd := buildCommand(cfg, globalConfig)

	if cmd == nil {
		t.Fatal("Expected command to be created")
	}

	// Should use bash instead of sh
	if !strings.Contains(cmd.Path, "bash") {
		t.Errorf("Expected bash command, got %q", cmd.Path)
	}

	// Should have bash -c "shell command"
	if len(cmd.Args) < 3 {
		t.Fatalf("Expected at least 3 args, got %d", len(cmd.Args))
	}

	if cmd.Args[1] != "-c" {
		t.Errorf("Expected second arg to be '-c', got %q", cmd.Args[1])
	}

	if cmd.Args[2] != cfg.Shell {
		t.Errorf("Expected shell command as third arg, got %q", cmd.Args[2])
	}
}

func TestBuildCommand_DefaultShellWhenNoGlobalConfig(t *testing.T) {
	cfg := &config.ProcessConfig{
		Shell: "echo test",
	}

	cmd := buildCommand(cfg, nil)

	if cmd == nil {
		t.Fatal("Expected command to be created")
	}

	// Should default to sh
	if !strings.Contains(cmd.Path, "sh") {
		t.Errorf("Expected sh command, got %q", cmd.Path)
	}
}

func TestBuildEnvironment_NoCustomEnv(t *testing.T) {
	cfg := &config.ProcessConfig{}

	env := buildEnvironment(cfg)

	// Should include current process environment
	if len(env) == 0 {
		t.Error("Expected environment to include current process env vars")
	}

	// Check that some common env var is present (PATH should always exist)
	found := false
	for _, e := range env {
		if strings.HasPrefix(e, "PATH=") {
			found = true
			break
		}
	}
	if !found {
		t.Error("Expected PATH in environment")
	}
}

func TestBuildEnvironment_CustomEnvVars(t *testing.T) {
	cfg := &config.ProcessConfig{
		Env: map[string]string{
			"CUSTOM_VAR": "custom_value",
			"API_KEY":    "secret123",
		},
	}

	env := buildEnvironment(cfg)

	// Check custom vars are present
	foundCustom := false
	foundAPI := false
	for _, e := range env {
		if e == "CUSTOM_VAR=custom_value" {
			foundCustom = true
		}
		if e == "API_KEY=secret123" {
			foundAPI = true
		}
	}

	if !foundCustom {
		t.Error("Expected CUSTOM_VAR in environment")
	}
	if !foundAPI {
		t.Error("Expected API_KEY in environment")
	}
}

func TestBuildEnvironment_AddPath_Single(t *testing.T) {
	cfg := &config.ProcessConfig{
		AddPath: []string{"/custom/bin"},
	}

	env := buildEnvironment(cfg)

	// Find PATH variable
	var pathValue string
	for _, e := range env {
		if strings.HasPrefix(e, "PATH=") {
			pathValue = strings.TrimPrefix(e, "PATH=")
			break
		}
	}

	if pathValue == "" {
		t.Fatal("PATH not found in environment")
	}

	// Should include the custom path (appended at the end)
	if !strings.Contains(pathValue, "/custom/bin") {
		t.Errorf("Expected /custom/bin in PATH, got: %s", pathValue)
	}

	// Should also include original PATH
	originalPath := os.Getenv("PATH")
	if !strings.Contains(pathValue, originalPath) {
		t.Error("Expected original PATH to be preserved")
	}

	// Verify it's appended (appears after original PATH)
	parts := strings.Split(pathValue, ":")
	found := false
	for _, part := range parts {
		if part == "/custom/bin" {
			found = true
			break
		}
	}
	if !found {
		t.Error("Custom path should be in PATH as a separate entry")
	}
}

func TestBuildEnvironment_AddPath_Multiple(t *testing.T) {
	cfg := &config.ProcessConfig{
		AddPath: []string{"/first/bin", "/second/bin", "/third/bin"},
	}

	env := buildEnvironment(cfg)

	var pathValue string
	for _, e := range env {
		if strings.HasPrefix(e, "PATH=") {
			pathValue = strings.TrimPrefix(e, "PATH=")
			break
		}
	}

	if pathValue == "" {
		t.Fatal("PATH not found in environment")
	}

	// All paths should be included
	for _, p := range cfg.AddPath {
		if !strings.Contains(pathValue, p) {
			t.Errorf("Expected %s in PATH", p)
		}
	}
}

func TestBuildEnvironment_AddPath_Format(t *testing.T) {
	cfg := &config.ProcessConfig{
		AddPath: []string{"/new/path"},
	}

	env := buildEnvironment(cfg)

	var pathValue string
	for _, e := range env {
		if strings.HasPrefix(e, "PATH=") {
			pathValue = strings.TrimPrefix(e, "PATH=")
			break
		}
	}

	// The format should be original:new:new:...
	// New paths are appended with colons
	parts := strings.Split(pathValue, ":")
	if len(parts) < 2 {
		t.Error("Expected PATH to have multiple parts separated by :")
	}
}

func TestBuildEnvironment_BothEnvAndAddPath(t *testing.T) {
	cfg := &config.ProcessConfig{
		Env: map[string]string{
			"CUSTOM": "value",
		},
		AddPath: []string{"/custom/bin"},
	}

	env := buildEnvironment(cfg)

	foundCustom := false
	foundPath := false
	var pathValue string

	for _, e := range env {
		if e == "CUSTOM=value" {
			foundCustom = true
		}
		if strings.HasPrefix(e, "PATH=") {
			foundPath = true
			pathValue = e
		}
	}

	if !foundCustom {
		t.Error("Expected CUSTOM env var")
	}
	if !foundPath {
		t.Error("Expected PATH to be set")
	}
	if !strings.Contains(pathValue, "/custom/bin") {
		t.Error("Expected custom path in PATH")
	}
}

func TestBuildEnvironment_OverrideExistingVar(t *testing.T) {
	// Setting an env var that already exists should add both
	// (the behavior appends, doesn't replace in the current implementation)
	cfg := &config.ProcessConfig{
		Env: map[string]string{
			"HOME": "/custom/home",
		},
	}

	env := buildEnvironment(cfg)

	customHomeFound := false
	for _, e := range env {
		if e == "HOME=/custom/home" {
			customHomeFound = true
			break
		}
	}

	if !customHomeFound {
		t.Error("Expected custom HOME to be added to environment")
	}
}

func TestBuildEnvironment_EmptyAddPath(t *testing.T) {
	cfg := &config.ProcessConfig{
		AddPath: []string{},
	}

	env := buildEnvironment(cfg)

	// Should still have environment, just no custom path additions
	if len(env) == 0 {
		t.Error("Expected environment to be set")
	}
}

func TestBuildEnvironment_NilEnv(t *testing.T) {
	cfg := &config.ProcessConfig{
		Env: nil,
	}

	env := buildEnvironment(cfg)

	// Should not panic, should return current environment
	if len(env) == 0 {
		t.Error("Expected environment to include current process env")
	}
}

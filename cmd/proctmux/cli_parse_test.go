package main

import (
	"flag"
	"io"
	"os"
	"testing"
)

func parseCLIForTest(t *testing.T, args ...string) *CLIConfig {
	t.Helper()

	oldArgs := os.Args
	oldCommandLine := flag.CommandLine
	oldUsage := flag.Usage
	t.Cleanup(func() {
		os.Args = oldArgs
		flag.CommandLine = oldCommandLine
		flag.Usage = oldUsage
	})

	os.Args = append([]string{"proctmux"}, args...)
	flag.CommandLine = flag.NewFlagSet("proctmux", flag.ContinueOnError)
	flag.CommandLine.SetOutput(io.Discard)

	return ParseCLI()
}

func TestParseCLIParityDefaults(t *testing.T) {
	cfg := parseCLIForTest(t)

	if cfg.ConfigFile != "" {
		t.Fatalf("expected empty config file, got %q", cfg.ConfigFile)
	}
	if cfg.Mode != "primary" {
		t.Fatalf("expected primary mode, got %q", cfg.Mode)
	}
	if cfg.Subcommand != "start" {
		t.Fatalf("expected start subcommand, got %q", cfg.Subcommand)
	}
	if len(cfg.Args) != 0 {
		t.Fatalf("expected no args, got %#v", cfg.Args)
	}
	if cfg.Unified {
		t.Fatalf("expected unified false")
	}
	if cfg.UnifiedOrientation != UnifiedSplitNone {
		t.Fatalf("expected no unified orientation, got %q", cfg.UnifiedOrientation)
	}
}

func TestParseCLIParityConfigClientAndSubcommand(t *testing.T) {
	cfg := parseCLIForTest(t, "-f", "proctmux.yaml", "--client", "signal-list")

	if cfg.ConfigFile != "proctmux.yaml" {
		t.Fatalf("expected config path proctmux.yaml, got %q", cfg.ConfigFile)
	}
	if cfg.Mode != "client" {
		t.Fatalf("expected client mode, got %q", cfg.Mode)
	}
	if cfg.Subcommand != "signal-list" {
		t.Fatalf("expected signal-list subcommand, got %q", cfg.Subcommand)
	}
	if len(cfg.Args) != 1 || cfg.Args[0] != "signal-list" {
		t.Fatalf("expected signal-list args, got %#v", cfg.Args)
	}
}

func TestParseCLIParityUnifiedOrientations(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want UnifiedSplit
	}{
		{"unified", []string{"--unified"}, UnifiedSplitLeft},
		{"left", []string{"--unified-left"}, UnifiedSplitLeft},
		{"right", []string{"--unified-right", "-f=config.yaml"}, UnifiedSplitRight},
		{"top", []string{"--unified-top"}, UnifiedSplitTop},
		{"bottom", []string{"--unified-bottom"}, UnifiedSplitBottom},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := parseCLIForTest(t, tt.args...)
			if !cfg.Unified {
				t.Fatalf("expected unified true")
			}
			if cfg.UnifiedOrientation != tt.want {
				t.Fatalf("expected orientation %q, got %q", tt.want, cfg.UnifiedOrientation)
			}
		})
	}
}

func TestParseCLIParityFlagsAfterCommandRemainArgs(t *testing.T) {
	cfg := parseCLIForTest(t, "start", "--client")

	if cfg.Mode != "primary" {
		t.Fatalf("expected primary mode because --client is positional after command, got %q", cfg.Mode)
	}
	if cfg.Subcommand != "start" {
		t.Fatalf("expected start subcommand, got %q", cfg.Subcommand)
	}
	if len(cfg.Args) != 2 || cfg.Args[1] != "--client" {
		t.Fatalf("expected positional --client to remain in args, got %#v", cfg.Args)
	}
}

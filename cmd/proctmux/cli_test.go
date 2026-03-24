package main

import (
	"strings"
	"testing"
)

func TestCheckDeprecatedFlags_UnifiedToggle(t *testing.T) {
	msg := checkDeprecatedFlags([]string{"--unified-toggle"})
	if msg == "" {
		t.Fatal("expected non-empty migration message for --unified-toggle")
	}
	if !strings.Contains(msg, "--unified") {
		t.Errorf("migration message should mention --unified, got: %s", msg)
	}
	if !strings.Contains(msg, "hide_process_list_when_unfocused: true") {
		t.Errorf("migration message should mention hide_process_list_when_unfocused, got: %s", msg)
	}
}

func TestCheckDeprecatedFlags_UnifiedToggleSingleDash(t *testing.T) {
	msg := checkDeprecatedFlags([]string{"-unified-toggle"})
	if msg == "" {
		t.Fatal("expected non-empty migration message for -unified-toggle")
	}
}

func TestCheckDeprecatedFlags_NormalArgs(t *testing.T) {
	tests := []struct {
		name string
		args []string
	}{
		{"no args", nil},
		{"unified-right", []string{"--unified-right"}},
		{"unified-left", []string{"--unified-left"}},
		{"unified", []string{"--unified"}},
		{"config flag", []string{"-f", "proctmux.yaml"}},
		{"mixed normal flags", []string{"--unified-right", "-f", "config.yaml"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			msg := checkDeprecatedFlags(tt.args)
			if msg != "" {
				t.Errorf("expected empty message for normal args %v, got: %s", tt.args, msg)
			}
		})
	}
}

package domain

import (
	"slices"
	"testing"

	"github.com/nick/proctmux/internal/config"
)

// Helper to create test config
func testConfig() *config.ProcTmuxConfig {
	return &config.ProcTmuxConfig{
		Layout: config.LayoutConfig{
			CategorySearchPrefix:        "cat:",
			SortProcessListAlpha:        false,
			SortProcessListRunningFirst: false,
		},
	}
}

// Helper to create ProcessView
func makeProcessView(id int, label string, status ProcessStatus, categories []string) ProcessView {
	return ProcessView{
		ID:     id,
		Label:  label,
		Status: status,
		PID:    0,
		Config: &config.ProcessConfig{
			Categories: categories,
		},
	}
}

func TestFilterProcesses_NoFilter_AllProcesses(t *testing.T) {
	cfg := testConfig()
	processes := []ProcessView{
		makeProcessView(1, "backend", StatusRunning, []string{"server"}),
		makeProcessView(2, "frontend", StatusHalted, []string{"client"}),
		makeProcessView(3, "database", StatusRunning, []string{"db"}),
	}

	result := FilterProcesses(cfg, processes, "", false)

	if len(result) != 3 {
		t.Errorf("Expected 3 processes, got %d", len(result))
	}
}

func TestFilterProcesses_NoFilter_ShowOnlyRunning(t *testing.T) {
	cfg := testConfig()
	processes := []ProcessView{
		makeProcessView(1, "backend", StatusRunning, []string{"server"}),
		makeProcessView(2, "frontend", StatusHalted, []string{"client"}),
		makeProcessView(3, "database", StatusRunning, []string{"db"}),
	}

	result := FilterProcesses(cfg, processes, "", true)

	if len(result) != 2 {
		t.Errorf("Expected 2 running processes, got %d", len(result))
	}

	for _, p := range result {
		if p.Status != StatusRunning {
			t.Errorf("Expected only running processes, got %v", p.Status)
		}
	}
}

func TestFilterProcesses_CategorySearch_Single(t *testing.T) {
	cfg := testConfig()
	processes := []ProcessView{
		makeProcessView(2, "backend", StatusHalted, []string{"server", "api"}),
		makeProcessView(3, "frontend", StatusHalted, []string{"client", "ui"}),
		makeProcessView(4, "api-gateway", StatusHalted, []string{"server", "gateway"}),
	}

	result := FilterProcesses(cfg, processes, "cat:server", false)

	if len(result) != 2 {
		t.Errorf("Expected 2 processes with 'server' category, got %d", len(result))
	}

	for _, p := range result {
		found := slices.Contains(p.Config.Categories, "server")
		if !found {
			t.Errorf("Process %q should have 'server' category", p.Label)
		}
	}
}

func TestFilterProcesses_CategorySearch_Multiple_AND(t *testing.T) {
	cfg := testConfig()
	processes := []ProcessView{
		makeProcessView(2, "backend", StatusHalted, []string{"server", "api"}),
		makeProcessView(3, "frontend", StatusHalted, []string{"client", "ui"}),
		makeProcessView(4, "api-gateway", StatusHalted, []string{"server", "gateway"}),
		makeProcessView(5, "api-server", StatusHalted, []string{"server", "api", "production"}),
	}

	// Should match only processes with BOTH server AND api
	result := FilterProcesses(cfg, processes, "cat:server,api", false)

	if len(result) != 2 {
		t.Errorf("Expected 2 processes with both 'server' and 'api', got %d", len(result))
	}

	for _, p := range result {
		hasServer := false
		hasAPI := false
		for _, cat := range p.Config.Categories {
			if cat == "server" {
				hasServer = true
			}
			if cat == "api" {
				hasAPI = true
			}
		}
		if !hasServer || !hasAPI {
			t.Errorf("Process %q should have both 'server' and 'api' categories", p.Label)
		}
	}
}

func TestFilterProcesses_CategorySearch_WithWhitespace(t *testing.T) {
	cfg := testConfig()
	processes := []ProcessView{
		makeProcessView(2, "backend", StatusHalted, []string{"server"}),
		makeProcessView(3, "frontend", StatusHalted, []string{"client"}),
	}

	// Should handle whitespace around category names
	result := FilterProcesses(cfg, processes, "cat: server , client ", false)

	// No process has both server and client, should be empty
	if len(result) != 0 {
		t.Errorf("Expected 0 processes, got %d", len(result))
	}
}

func TestFilterProcesses_CategorySearch_FuzzyMatch(t *testing.T) {
	cfg := testConfig()
	processes := []ProcessView{
		makeProcessView(2, "backend", StatusHalted, []string{"backend-service"}),
		makeProcessView(3, "frontend", StatusHalted, []string{"frontend-app"}),
	}

	// Should fuzzy match "backend" with "backend-service"
	result := FilterProcesses(cfg, processes, "cat:backend", false)

	if len(result) != 1 {
		t.Errorf("Expected 1 process with fuzzy match, got %d", len(result))
	}
	if len(result) > 0 && result[0].Label != "backend" {
		t.Errorf("Expected 'backend' process, got %q", result[0].Label)
	}
}

func TestFilterProcesses_CategorySearch_ShowOnlyRunning(t *testing.T) {
	cfg := testConfig()
	processes := []ProcessView{
		makeProcessView(2, "backend", StatusRunning, []string{"server"}),
		makeProcessView(3, "api", StatusHalted, []string{"server"}),
	}

	result := FilterProcesses(cfg, processes, "cat:server", true)

	// Should only include running processes with the category
	if len(result) != 1 {
		t.Errorf("Expected 1 running process with 'server' category, got %d", len(result))
	}
	if len(result) > 0 {
		if result[0].Label != "backend" {
			t.Errorf("Expected 'backend', got %q", result[0].Label)
		}
		if result[0].Status != StatusRunning {
			t.Error("Expected running process")
		}
	}
}

func TestFilterProcesses_FuzzySearch_BasicMatch(t *testing.T) {
	cfg := testConfig()
	processes := []ProcessView{
		makeProcessView(2, "backend-api", StatusHalted, nil),
		makeProcessView(3, "frontend-ui", StatusHalted, nil),
		makeProcessView(4, "database-postgres", StatusHalted, nil),
	}

	result := FilterProcesses(cfg, processes, "back", false)

	// Should match "backend-api"
	if len(result) != 1 {
		t.Errorf("Expected 1 match for 'back', got %d", len(result))
	}
	if len(result) > 0 && result[0].Label != "backend-api" {
		t.Errorf("Expected 'backend-api', got %q", result[0].Label)
	}
}

func TestFilterProcesses_FuzzySearch_MultipleMatches(t *testing.T) {
	cfg := testConfig()
	processes := []ProcessView{
		makeProcessView(2, "api-server", StatusHalted, nil),
		makeProcessView(3, "api-gateway", StatusHalted, nil),
		makeProcessView(4, "database", StatusHalted, nil),
	}

	result := FilterProcesses(cfg, processes, "api", false)

	// Should match both api-server and api-gateway
	if len(result) != 2 {
		t.Errorf("Expected 2 matches for 'api', got %d", len(result))
	}
}

func TestFilterProcesses_FuzzySearch_CaseInsensitive(t *testing.T) {
	cfg := testConfig()
	processes := []ProcessView{
		makeProcessView(2, "Backend-API", StatusHalted, nil),
		makeProcessView(3, "frontend", StatusHalted, nil),
	}

	result := FilterProcesses(cfg, processes, "BACKEND", false)

	// Should match despite case difference
	if len(result) != 1 {
		t.Errorf("Expected 1 match (case insensitive), got %d", len(result))
	}
}

func TestFilterProcesses_FuzzySearch_ShowOnlyRunning(t *testing.T) {
	cfg := testConfig()
	processes := []ProcessView{
		makeProcessView(2, "api-running", StatusRunning, nil),
		makeProcessView(3, "api-stopped", StatusHalted, nil),
	}

	result := FilterProcesses(cfg, processes, "api", true)

	// Should only match running processes
	if len(result) != 1 {
		t.Errorf("Expected 1 running match, got %d", len(result))
	}
	if len(result) > 0 && result[0].Label != "api-running" {
		t.Errorf("Expected 'api-running', got %q", result[0].Label)
	}
}

func TestFilterProcesses_SortAlphabetically(t *testing.T) {
	cfg := testConfig()
	cfg.Layout.SortProcessListAlpha = true

	processes := []ProcessView{
		makeProcessView(2, "zebra", StatusHalted, nil),
		makeProcessView(3, "apple", StatusHalted, nil),
		makeProcessView(4, "mango", StatusHalted, nil),
	}

	result := FilterProcesses(cfg, processes, "", false)

	expected := []string{"apple", "mango", "zebra"}
	for i, p := range result {
		if p.Label != expected[i] {
			t.Errorf("Expected %q at position %d, got %q", expected[i], i, p.Label)
		}
	}
}

func TestFilterProcesses_SortRunningFirst(t *testing.T) {
	cfg := testConfig()
	cfg.Layout.SortProcessListRunningFirst = true

	processes := []ProcessView{
		makeProcessView(2, "halted-1", StatusHalted, nil),
		makeProcessView(3, "running-1", StatusRunning, nil),
		makeProcessView(4, "halted-2", StatusHalted, nil),
		makeProcessView(5, "running-2", StatusRunning, nil),
	}

	result := FilterProcesses(cfg, processes, "", false)

	// First two should be running
	if len(result) < 2 {
		t.Fatal("Expected at least 2 results")
	}
	if result[0].Status != StatusRunning {
		t.Errorf("Expected first process to be running, got %v", result[0].Status)
	}
	if result[1].Status != StatusRunning {
		t.Errorf("Expected second process to be running, got %v", result[1].Status)
	}
}

func TestFilterProcesses_SortRunningFirstAndAlpha(t *testing.T) {
	cfg := testConfig()
	cfg.Layout.SortProcessListRunningFirst = true
	cfg.Layout.SortProcessListAlpha = true

	processes := []ProcessView{
		makeProcessView(2, "halted-zebra", StatusHalted, nil),
		makeProcessView(3, "running-mango", StatusRunning, nil),
		makeProcessView(4, "halted-apple", StatusHalted, nil),
		makeProcessView(5, "running-banana", StatusRunning, nil),
	}

	result := FilterProcesses(cfg, processes, "", false)

	// Running first, then alphabetically within each group
	expected := []string{"running-banana", "running-mango", "halted-apple", "halted-zebra"}
	for i, p := range result {
		if p.Label != expected[i] {
			t.Errorf("Position %d: expected %q, got %q", i, expected[i], p.Label)
		}
	}
}

func TestFilterProcesses_FuzzySearch_IgnoresSorting(t *testing.T) {
	cfg := testConfig()
	cfg.Layout.SortProcessListAlpha = true
	cfg.Layout.SortProcessListRunningFirst = true

	processes := []ProcessView{
		makeProcessView(2, "zebra-api", StatusHalted, nil),
		makeProcessView(3, "api-service", StatusRunning, nil),
		makeProcessView(4, "apple-api", StatusHalted, nil),
	}

	result := FilterProcesses(cfg, processes, "api", false)

	// Fuzzy search returns results in fuzzy ranking order, not sorted
	// Just verify all matches are returned
	if len(result) != 3 {
		t.Errorf("Expected 3 matches, got %d", len(result))
	}
}

func TestFilterProcesses_EmptyProcessList(t *testing.T) {
	cfg := testConfig()
	processes := []ProcessView{}

	result := FilterProcesses(cfg, processes, "", false)

	if len(result) != 0 {
		t.Errorf("Expected empty result, got %d processes", len(result))
	}
}

func TestFilterProcesses_AllFiltered(t *testing.T) {
	cfg := testConfig()
	processes := []ProcessView{
		makeProcessView(2, "backend", StatusHalted, []string{"server"}),
		makeProcessView(3, "frontend", StatusHalted, []string{"client"}),
	}

	// Category that doesn't exist
	result := FilterProcesses(cfg, processes, "cat:nonexistent", false)

	if len(result) != 0 {
		t.Errorf("Expected no matches, got %d", len(result))
	}
}

func TestFilterProcesses_ShowOnlyRunning_NoneRunning(t *testing.T) {
	cfg := testConfig()
	processes := []ProcessView{
		makeProcessView(2, "backend", StatusHalted, nil),
		makeProcessView(3, "frontend", StatusHalted, nil),
	}

	result := FilterProcesses(cfg, processes, "", true)

	if len(result) != 0 {
		t.Errorf("Expected no running processes, got %d", len(result))
	}
}

func TestFuzzyMatch_Helper(t *testing.T) {
	tests := []struct {
		a        string
		b        string
		expected bool
	}{
		{"backend", "back", true},
		{"back", "backend", true},
		{"frontend", "front", true},
		{"api", "gateway", false},
		{"Backend", "backend", true}, // case insensitive
		{"", "test", true},           // empty string is contained in any string
		{"test", "", true},           // any string contains empty string
	}

	for _, tt := range tests {
		t.Run(tt.a+"_"+tt.b, func(t *testing.T) {
			result := fuzzyMatch(tt.a, tt.b)
			if result != tt.expected {
				t.Errorf("fuzzyMatch(%q, %q) = %v, expected %v", tt.a, tt.b, result, tt.expected)
			}
		})
	}
}

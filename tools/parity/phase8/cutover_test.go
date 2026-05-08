package phase8

import (
	"os"
	"strings"
	"testing"
)

func repoFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}

func makeTargetBody(t *testing.T, makefile, target string) string {
	t.Helper()
	marker := ".PHONY: " + target
	start := strings.Index(makefile, marker)
	if start < 0 {
		t.Fatalf("missing .PHONY declaration for %s", target)
	}
	rest := makefile[start+len(marker):]
	next := strings.Index(rest, "\n.PHONY:")
	if next < 0 {
		return rest
	}
	return rest[:next]
}

func requireContains(t *testing.T, text, needle, context string) {
	t.Helper()
	if !strings.Contains(text, needle) {
		t.Fatalf("%s must contain %q\n--- content ---\n%s", context, needle, text)
	}
}

func requireNotContains(t *testing.T, text, needle, context string) {
	t.Helper()
	if strings.Contains(text, needle) {
		t.Fatalf("%s must not contain %q\n--- content ---\n%s", context, needle, text)
	}
}

func TestDefaultMakeTargetsAreZigBacked(t *testing.T) {
	makefile := repoFile(t, "../../../Makefile")

	build := makeTargetBody(t, makefile, "build")
	requireContains(t, build, "$(MAKE) build-zig", "build target")
	requireNotContains(t, build, "go build", "build target")

	run := makeTargetBody(t, makefile, "run")
	requireContains(t, run, "$(MAKE) run-zig", "run target")
	requireNotContains(t, run, "go run", "run target")
}

func TestReleaseMakeTargetsAreZigBacked(t *testing.T) {
	makefile := repoFile(t, "../../../Makefile")

	buildArtifact := makeTargetBody(t, makefile, "build-release-artifact")
	requireContains(t, buildArtifact, "$(ZIG)", "build-release-artifact target")
	requireContains(t, buildArtifact, "ZIG_TARGET", "build-release-artifact target")
	requireContains(t, buildArtifact, "ARTIFACT_NAME", "build-release-artifact target")
	requireNotContains(t, buildArtifact, "go build", "build-release-artifact target")

	buildAll := makeTargetBody(t, makefile, "build-all")
	for _, target := range []string{
		"x86_64-linux-gnu",
		"aarch64-linux-gnu",
		"x86_64-macos",
		"aarch64-macos",
	} {
		requireContains(t, buildAll, target, "build-all target")
	}
	requireContains(t, buildAll, "build-release-artifact", "build-all target")
	requireNotContains(t, buildAll, "go build", "build-all target")
	requireNotContains(t, buildAll, "GOOS=", "build-all target")

	releaseCreate := makeTargetBody(t, makefile, "release-create")
	requireContains(t, releaseCreate, "$(MAKE) test-release-parity", "release-create target")
	requireNotContains(t, releaseCreate, "go vet", "release-create target")
}

func TestReleaseWorkflowBuildsZigArtifacts(t *testing.T) {
	workflow := repoFile(t, "../../../.github/workflows/release.yml")

	requireContains(t, workflow, "zig_target", "release workflow build matrix")
	requireContains(t, workflow, "make build-release-artifact", "release workflow build step")
	requireContains(t, workflow, "make test-release-parity", "release workflow test step")
	requireNotContains(t, workflow, "go build -o", "release workflow")
	requireNotContains(t, workflow, "GOOS:", "release workflow")
	requireNotContains(t, workflow, "GOARCH:", "release workflow")
}

func TestZigUnifiedModeUsesChildPrimaryComposition(t *testing.T) {
	source := repoFile(t, "../../../src/app/root.zig")
	runUnified := functionBody(t, source, "fn runUnified(")

	requireContains(t, runUnified, "unified.childArgs", "runUnified")
	requireContains(t, runUnified, "UnifiedChildPrimary.init", "runUnified")
	requireContains(t, source, "pty.spawn", "unified child primary")
	requireNotContains(t, runUnified, "primary.Server.init", "runUnified")
	requireNotContains(t, runUnified, "runUnifiedPrimaryServer", "runUnified")
}

func functionBody(t *testing.T, source, signature string) string {
	t.Helper()

	start := strings.Index(source, signature)
	if start < 0 {
		t.Fatalf("missing function signature %q", signature)
	}
	open := strings.Index(source[start:], "{")
	if open < 0 {
		t.Fatalf("missing function body for %q", signature)
	}
	bodyStart := start + open
	depth := 0
	for index := bodyStart; index < len(source); index++ {
		switch source[index] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return source[bodyStart : index+1]
			}
		}
	}
	t.Fatalf("unterminated function body for %q", signature)
	return ""
}

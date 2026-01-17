package e2e

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
)

var (
	buildOnce  sync.Once
	buildPath  string
	buildErr   error
	moduleRoot string
)

func init() {
	_, file, _, ok := runtime.Caller(0)
	if ok {
		moduleRoot = filepath.Join(filepath.Dir(file), "..", "..", "..")
	}
}

// Binary returns the path to a proctmux binary built for end-to-end testing.
// The binary is built once per test process and reused across individual tests.
func Binary(t testing.TB) string {
	t.Helper()

	buildOnce.Do(func() {
		tmpDir, err := os.MkdirTemp("", "proctmux-e2e-bin-*")
		if err != nil {
			buildErr = err
			return
		}
		buildPath = filepath.Join(tmpDir, "proctmux")

		cmd := exec.Command("go", "build", "-o", buildPath, "./cmd/proctmux")
		cmd.Env = os.Environ()
		if moduleRoot != "" {
			cmd.Dir = moduleRoot
		}
		buildErr = cmd.Run()
	})

	if buildErr != nil {
		t.Fatalf("failed to build proctmux binary: %v", buildErr)
	}

	return buildPath
}

package phase6

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	e2e "github.com/nick/proctmux/internal/testharness/e2e"
)

type implementation struct {
	name string
	bin  string
}

const defaultClientConfig = `
log_file: proctmux-test.log
procs:
  alpha-service:
    shell: "sleep 60"
  beta-worker:
    shell: "sleep 60"
`

func TestClientInitialSnapshotMatchesGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goSnapshot := clientInitialSnapshot(t, implementation{name: "go", bin: goBin})
	zigSnapshot := clientInitialSnapshot(t, implementation{name: "zig", bin: zigBin})

	if zigSnapshot != goSnapshot {
		t.Fatalf("client initial snapshot mismatch:\nGo:\n%s\n\nZig:\n%s", goSnapshot, zigSnapshot)
	}
}

func TestClientDownNavigationSnapshotMatchesGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goSnapshot := clientSnapshotAfterKeys(t, implementation{name: "go", bin: goBin}, "jj")
	zigSnapshot := clientSnapshotAfterKeys(t, implementation{name: "zig", bin: zigBin}, "jj")

	if zigSnapshot != goSnapshot {
		t.Fatalf("client down-navigation snapshot mismatch:\nGo:\n%s\n\nZig:\n%s", goSnapshot, zigSnapshot)
	}
}

func TestClientSubmittedFilterSnapshotMatchesGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	waitForSubmittedFilter := func(snap string) bool {
		trimmed := trimSnapshot(snap)
		return strings.Contains(trimmed, "Filter: beta") &&
			strings.Contains(trimmed, "beta-worker") &&
			!strings.Contains(trimmed, "alpha-service")
	}

	goSnapshot := clientSnapshotAfterKeysMatching(t, implementation{name: "go", bin: goBin}, "/beta\r", waitForSubmittedFilter)
	zigSnapshot := clientSnapshotAfterKeysMatching(t, implementation{name: "zig", bin: zigBin}, "/beta\r", waitForSubmittedFilter)

	if zigSnapshot != goSnapshot {
		t.Fatalf("client submitted-filter snapshot mismatch:\nGo:\n%s\n\nZig:\n%s", goSnapshot, zigSnapshot)
	}
}

func TestClientCategoryFilterSnapshotMatchesGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	const configWithCategories = `
log_file: proctmux-test.log
procs:
  alpha-service:
    shell: "sleep 60"
    categories: ["api"]
  beta-worker:
    shell: "sleep 60"
    categories: ["worker"]
`
	waitForCategoryFilter := func(snap string) bool {
		trimmed := trimSnapshot(snap)
		return strings.Contains(trimmed, "Filter: cat:worker") &&
			strings.Contains(trimmed, "beta-worker") &&
			!strings.Contains(trimmed, "alpha-service")
	}

	goSnapshot := clientSnapshotAfterKeysMatchingWithConfig(t, implementation{name: "go", bin: goBin}, configWithCategories, "/cat:worker\r", waitForCategoryFilter)
	zigSnapshot := clientSnapshotAfterKeysMatchingWithConfig(t, implementation{name: "zig", bin: zigBin}, configWithCategories, "/cat:worker\r", waitForCategoryFilter)

	if zigSnapshot != goSnapshot {
		t.Fatalf("client category-filter snapshot mismatch:\nGo:\n%s\n\nZig:\n%s", goSnapshot, zigSnapshot)
	}
}

func TestClientRunningOnlyAfterStartSnapshotMatchesGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	waitForRunningOnly := func(snap string) bool {
		trimmed := trimSnapshot(snap)
		return strings.Contains(trimmed, "alpha-service") &&
			!strings.Contains(trimmed, "beta-worker") &&
			!strings.Contains(trimmed, "No matching processes")
	}

	exercise := func(t *testing.T, impl implementation, session *e2e.Session, primary *e2e.PrimaryProcess, initial string) {
		t.Helper()

		if err := session.SendRunes('j'); err != nil {
			t.Fatalf("%s client send select-first key: %v", impl.name, err)
		}
		time.Sleep(50 * time.Millisecond)
		if err := session.SendRunes('s'); err != nil {
			t.Fatalf("%s client send start key: %v", impl.name, err)
		}
		time.Sleep(100 * time.Millisecond)
		if err := session.SendRunes('R'); err != nil {
			t.Fatalf("%s client send running-only key: %v", impl.name, err)
		}
		if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
			return trimSnapshot(snap) != initial && waitForRunningOnly(snap)
		}); err != nil {
			t.Fatalf("%s client did not render running-only snapshot: %v\nsnapshot:\n%s\nprimary output:\n%s\nlog file:\n%s",
				impl.name,
				err,
				session.Snapshot(),
				primary.Logs(),
				readLogFile(t, primary.Cmd.Dir),
			)
		}
	}

	goSnapshot := clientSnapshotAfterExercise(t, implementation{name: "go", bin: goBin}, exercise)
	zigSnapshot := clientSnapshotAfterExercise(t, implementation{name: "zig", bin: zigBin}, exercise)

	if zigSnapshot != goSnapshot {
		t.Fatalf("client running-only snapshot mismatch:\nGo:\n%s\n\nZig:\n%s", goSnapshot, zigSnapshot)
	}
}

func TestClientHelpSnapshotMatchesGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	waitForHelp := func(snap string) bool {
		trimmed := trimSnapshot(snap)
		return strings.Contains(trimmed, "filter") &&
			strings.Contains(trimmed, "quit") &&
			strings.Contains(trimmed, "alpha-service")
	}

	goSnapshot := clientSnapshotAfterKeysMatching(t, implementation{name: "go", bin: goBin}, "?", waitForHelp)
	zigSnapshot := clientSnapshotAfterKeysMatching(t, implementation{name: "zig", bin: zigBin}, "?", waitForHelp)

	if zigSnapshot != goSnapshot {
		t.Fatalf("client help snapshot mismatch:\nGo:\n%s\n\nZig:\n%s", goSnapshot, zigSnapshot)
	}
}

func TestClientReceivesNaturalProcessExitStateLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	const configWithShortLivedProcess = `
layout:
  enable_debug_process_info: true
log_file: proctmux-test.log
procs:
  short-lived:
    shell: "sleep 1"
`

	exercise := func(t *testing.T, impl implementation, session *e2e.Session, primary *e2e.PrimaryProcess, initial string) {
		t.Helper()

		if err := session.SendRunes('j'); err != nil {
			t.Fatalf("%s client send select-first key: %v", impl.name, err)
		}
		time.Sleep(50 * time.Millisecond)
		if err := session.SendRunes('s'); err != nil {
			t.Fatalf("%s client send start key: %v", impl.name, err)
		}
		if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
			trimmed := trimSnapshot(snap)
			return trimmed != initial &&
				strings.Contains(trimmed, "short-lived [Running]")
		}); err != nil {
			t.Fatalf("%s client did not render running process after start: %v\nsnapshot:\n%s\nprimary output:\n%s\nlog file:\n%s",
				impl.name,
				err,
				session.Snapshot(),
				primary.Logs(),
				readLogFile(t, primary.Cmd.Dir),
			)
		}

		running := trimSnapshot(session.Snapshot())
		if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
			trimmed := trimSnapshot(snap)
			return trimmed != running &&
				strings.Contains(trimmed, "short-lived [Halted]")
		}); err != nil {
			t.Fatalf("%s client did not receive stopped state after natural process exit: %v\nsnapshot:\n%s\nprimary output:\n%s\nlog file:\n%s",
				impl.name,
				err,
				session.Snapshot(),
				primary.Logs(),
				readLogFile(t, primary.Cmd.Dir),
			)
		}
	}

	ready := func(snap string) bool {
		return strings.Contains(snap, "short-lived")
	}
	goSnapshot := clientSnapshotAfterExerciseWithConfigAndReady(t, implementation{name: "go", bin: goBin}, configWithShortLivedProcess, ready, exercise)
	zigSnapshot := clientSnapshotAfterExerciseWithConfigAndReady(t, implementation{name: "zig", bin: zigBin}, configWithShortLivedProcess, ready, exercise)

	if zigSnapshot != goSnapshot {
		t.Fatalf("client natural-exit snapshot mismatch:\nGo:\n%s\n\nZig:\n%s", goSnapshot, zigSnapshot)
	}
}

func clientInitialSnapshot(t *testing.T, impl implementation) string {
	t.Helper()

	return clientSnapshotAfterKeys(t, impl, "")
}

func clientSnapshotAfterKeys(t *testing.T, impl implementation, keys string) string {
	t.Helper()

	return clientSnapshotAfterKeysMatching(t, impl, keys, func(snap string) bool {
		return true
	})
}

func clientSnapshotAfterKeysMatching(t *testing.T, impl implementation, keys string, waitAfterKeys func(string) bool) string {
	t.Helper()
	return clientSnapshotAfterKeysMatchingWithConfig(t, impl, defaultClientConfig, keys, waitAfterKeys)
}

func clientSnapshotAfterKeysMatchingWithConfig(t *testing.T, impl implementation, configText string, keys string, waitAfterKeys func(string) bool) string {
	t.Helper()
	return clientSnapshotAfterExerciseWithConfig(t, impl, configText, func(t *testing.T, impl implementation, session *e2e.Session, primary *e2e.PrimaryProcess, initial string) {
		t.Helper()

		if keys == "" {
			return
		}
		for _, key := range keys {
			if err := session.SendRunes(key); err != nil {
				t.Fatalf("%s client send key %q: %v", impl.name, key, err)
			}
			time.Sleep(50 * time.Millisecond)
		}
		if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
			return trimSnapshot(snap) != initial && waitAfterKeys(snap)
		}); err != nil {
			t.Fatalf("%s client did not render post-key snapshot: %v\nsnapshot:\n%s\nprimary output:\n%s\nlog file:\n%s",
				impl.name,
				err,
				session.Snapshot(),
				primary.Logs(),
				readLogFile(t, primary.Cmd.Dir),
			)
		}
	})
}

func clientSnapshotAfterExercise(
	t *testing.T,
	impl implementation,
	exercise func(t *testing.T, impl implementation, session *e2e.Session, primary *e2e.PrimaryProcess, initial string),
) string {
	t.Helper()
	return clientSnapshotAfterExerciseWithConfig(t, impl, defaultClientConfig, exercise)
}

func clientSnapshotAfterExerciseWithConfig(
	t *testing.T,
	impl implementation,
	configText string,
	exercise func(t *testing.T, impl implementation, session *e2e.Session, primary *e2e.PrimaryProcess, initial string),
) string {
	t.Helper()
	return clientSnapshotAfterExerciseWithConfigAndReady(t, impl, configText, func(snap string) bool {
		return strings.Contains(snap, "alpha-service") && strings.Contains(snap, "beta-worker")
	}, exercise)
}

func clientSnapshotAfterExerciseWithConfigAndReady(
	t *testing.T,
	impl implementation,
	configText string,
	ready func(string) bool,
	exercise func(t *testing.T, impl implementation, session *e2e.Session, primary *e2e.PrimaryProcess, initial string),
) string {
	t.Helper()

	cfgDir, cfgPath := e2e.WriteConfig(t, configText)

	beforeSockets := snapshotProctmuxSockets(t)
	primary := e2e.StartPrimaryProcessWithBinary(t, impl.bin, cfgDir, cfgPath)
	waitForNewResponsiveSocket(t, beforeSockets, primary, 10*time.Second)
	session := e2e.StartClientSessionWithBinary(t, impl.bin, cfgDir, cfgPath)

	if err := session.WaitForSnapshot(10*time.Second, ready); err != nil {
		t.Fatalf("%s client did not render process list: %v\nsnapshot:\n%s\nprimary output:\n%s\nlog file:\n%s",
			impl.name,
			err,
			session.Snapshot(),
			primary.Logs(),
			readLogFile(t, cfgDir),
		)
	}

	initial := trimSnapshot(session.Snapshot())
	exercise(t, impl, session, primary, initial)

	return trimSnapshot(session.Snapshot())
}

func readLogFile(t *testing.T, cfgDir string) string {
	t.Helper()

	data, err := os.ReadFile(filepath.Join(cfgDir, "proctmux-test.log"))
	if err != nil {
		return "<unavailable: " + err.Error() + ">"
	}
	return string(data)
}

func snapshotProctmuxSockets(t *testing.T) map[string]struct{} {
	t.Helper()

	paths, err := filepath.Glob("/tmp/proctmux-*.socket")
	if err != nil {
		t.Fatalf("glob proctmux sockets: %v", err)
	}
	out := make(map[string]struct{}, len(paths))
	for _, path := range paths {
		out[path] = struct{}{}
	}
	return out
}

func waitForNewResponsiveSocket(
	t *testing.T,
	before map[string]struct{},
	primary *e2e.PrimaryProcess,
	timeout time.Duration,
) string {
	t.Helper()

	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		paths, err := filepath.Glob("/tmp/proctmux-*.socket")
		if err != nil {
			t.Fatalf("glob proctmux sockets: %v", err)
		}
		for _, path := range paths {
			if _, existed := before[path]; existed {
				continue
			}
			if err := probeUnixSocket(path); err == nil {
				return path
			} else {
				lastErr = err
			}
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s primary socket: %v\nprimary output:\n%s", primary.Cmd.Path, lastErr, primary.Logs())
	return ""
}

func probeUnixSocket(path string) error {
	conn, err := net.DialTimeout("unix", path, 100*time.Millisecond)
	if err != nil {
		return err
	}
	return conn.Close()
}

func trimSnapshot(snapshot string) string {
	var lines []string
	for _, line := range strings.Split(snapshot, "\n") {
		line = strings.TrimRight(line, " ")
		if line == "" {
			continue
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}

func requiredEnv(t *testing.T, name string) string {
	t.Helper()

	value := os.Getenv(name)
	if value == "" {
		t.Fatalf("%s must be set", name)
	}
	return value
}

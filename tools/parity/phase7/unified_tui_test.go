package phase7

import (
	"bytes"
	"os"
	"strings"
	"testing"
	"time"

	e2e "github.com/nick/proctmux/internal/testharness/e2e"
)

type implementation struct {
	name string
	bin  string
}

const unifiedConfigWithPlaceholder = `
layout:
  placeholder_banner: "READY"
log_file: proctmux-test.log
procs:
  alpha-service:
    shell: "sleep 60"
  beta-worker:
    shell: "sleep 60"
`

const unifiedConfigWithOutputProcess = `
layout:
  placeholder_banner: "READY"
log_file: proctmux-test.log
procs:
  alpha-service:
    shell: "printf 'process-ready\n'; sleep 60"
  beta-worker:
    shell: "sleep 60"
`

const unifiedConfigWithInteractiveProcess = `
layout:
  placeholder_banner: "READY"
log_file: proctmux-test.log
procs:
  alpha-service:
    shell: "printf 'ready-for-input\n'; IFS= read -r line; printf 'got:%s\n' $line; sleep 60"
  beta-worker:
    shell: "sleep 60"
`

const unifiedConfigWithAnsiClearOutput = `
layout:
  placeholder_banner: "READY"
log_file: proctmux-test.log
procs:
  alpha-service:
    shell: |
      printf 'before\033[2Jafter\n'; sleep 60
  beta-worker:
    shell: "sleep 60"
`

const unifiedConfigWithCarriageReturnOutput = `
layout:
  placeholder_banner: "READY"
log_file: proctmux-test.log
procs:
  alpha-service:
    shell: |
      printf 'first\rsecond\n'; sleep 60
  beta-worker:
    shell: "sleep 60"
`

const unifiedConfigWithCursorEraseOutput = `
layout:
  placeholder_banner: "READY"
log_file: proctmux-test.log
procs:
  alpha-service:
    shell: |
      printf 'abcdef\033[3D\033[KXYZ\n'; sleep 60
  beta-worker:
    shell: "sleep 60"
`

const unifiedConfigWithAlternateScreenOutput = `
layout:
  placeholder_banner: "READY"
log_file: proctmux-test.log
procs:
  alpha-service:
    shell: |
      printf 'main\n\033[?1049halt-screen\n\033[?1049lback\n'; sleep 60
  beta-worker:
    shell: "sleep 60"
`

const styledPayload = "STYLE-PAYLOAD-12-34-56"
const styledPayloadSGR = "38;2;12;34;56"

const unifiedConfigWithStyledOutput = `
layout:
  placeholder_banner: "READY"
log_file: proctmux-test.log
procs:
  alpha-service:
    shell: |
      printf '\033[38;2;12;34;56mSTYLE-PAYLOAD-12-34-56\033[0m\n'; sleep 60
  beta-worker:
    shell: "sleep 60"
`

const largeOutputFinalLine = "LOAD-LINE-0200"

const unifiedConfigWithLargeOutput = `
layout:
  placeholder_banner: "READY"
log_file: proctmux-test.log
procs:
  alpha-service:
    shell: |
      i=1
      while [ "$i" -le 200 ]; do
        printf 'LOAD-LINE-%04d\n' "$i"
        i=$((i + 1))
      done
      sleep 60
  beta-worker:
    shell: "sleep 60"
`

const unifiedConfigWithShortLivedDebugProcess = `
layout:
  placeholder_banner: "READY"
  enable_debug_process_info: true
log_file: proctmux-test.log
procs:
  p:
    shell: "sleep 1"
`

func TestUnifiedInitialFrameShowsServerPlaceholderLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goSnapshot := unifiedInitialSnapshot(t, implementation{name: "go", bin: goBin})
	zigSnapshot := unifiedInitialSnapshot(t, implementation{name: "zig", bin: zigBin})

	goHasPlaceholder := strings.Contains(goSnapshot, "READY")
	zigHasPlaceholder := strings.Contains(zigSnapshot, "READY")
	if zigHasPlaceholder != goHasPlaceholder {
		t.Fatalf("unified placeholder visibility mismatch: Go=%v Zig=%v\nGo:\n%s\n\nZig:\n%s",
			goHasPlaceholder,
			zigHasPlaceholder,
			goSnapshot,
			zigSnapshot,
		)
	}
}

func TestUnifiedLeftInitialFrameComposesClientAndServerColumnsLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goSnapshot := unifiedInitialSnapshot(t, implementation{name: "go", bin: goBin}, "--unified")
	zigSnapshot := unifiedInitialSnapshot(t, implementation{name: "zig", bin: zigBin}, "--unified")

	goComposed := lineContainsAll(goSnapshot, "alpha-service", "READY")
	zigComposed := lineContainsAll(zigSnapshot, "alpha-service", "READY")
	if zigComposed != goComposed {
		t.Fatalf("unified left composition mismatch: Go=%v Zig=%v\nGo:\n%s\n\nZig:\n%s",
			goComposed,
			zigComposed,
			goSnapshot,
			zigSnapshot,
		)
	}
}

func TestUnifiedRightInitialFrameComposesServerAndClientColumnsLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goSnapshot := unifiedInitialSnapshot(t, implementation{name: "go", bin: goBin}, "--unified-right")
	zigSnapshot := unifiedInitialSnapshot(t, implementation{name: "zig", bin: zigBin}, "--unified-right")

	goComposed := lineContainsAll(goSnapshot, "READY", "alpha-service")
	zigComposed := lineContainsAll(zigSnapshot, "READY", "alpha-service")
	if zigComposed != goComposed {
		t.Fatalf("unified right composition mismatch: Go=%v Zig=%v\nGo:\n%s\n\nZig:\n%s",
			goComposed,
			zigComposed,
			goSnapshot,
			zigSnapshot,
		)
	}
}

func TestUnifiedRightInitialFrameUsesTerminalWidthLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	size := e2e.TerminalSize{Rows: 20, Cols: 90}
	goSnapshot := unifiedInitialSnapshotWithConfigAndSize(t, implementation{name: "go", bin: goBin}, unifiedConfigWithPlaceholder, size, "--unified-right")
	zigSnapshot := unifiedInitialSnapshotWithConfigAndSize(t, implementation{name: "zig", bin: zigBin}, unifiedConfigWithPlaceholder, size, "--unified-right")

	goComposed := lineContainsAll(goSnapshot, "READY", "alpha-service")
	zigComposed := lineContainsAll(zigSnapshot, "READY", "alpha-service")
	if !goComposed {
		t.Fatalf("Go reference did not compose right split at narrow width\nGo:\n%s", goSnapshot)
	}
	if zigComposed != goComposed {
		t.Fatalf("unified right initial terminal-width mismatch: Go=%v Zig=%v\nGo:\n%s\n\nZig:\n%s",
			goComposed,
			zigComposed,
			goSnapshot,
			zigSnapshot,
		)
	}
}

func TestUnifiedRightLiveResizeReflowsLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goSnapshot := unifiedRightSnapshotAfterResize(t, implementation{name: "go", bin: goBin})
	zigSnapshot := unifiedRightSnapshotAfterResize(t, implementation{name: "zig", bin: zigBin})

	goComposed := lineContainsAll(goSnapshot, "READY", "alpha-service")
	zigComposed := lineContainsAll(zigSnapshot, "READY", "alpha-service")
	if !goComposed {
		t.Fatalf("Go reference did not compose right split after live resize\nGo:\n%s", goSnapshot)
	}
	if zigComposed != goComposed {
		t.Fatalf("unified right live resize mismatch: Go=%v Zig=%v\nGo:\n%s\n\nZig:\n%s",
			goComposed,
			zigComposed,
			goSnapshot,
			zigSnapshot,
		)
	}
}

func TestUnifiedVerticalOrientationsOrderClientAndServerLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	tests := []struct {
		name string
		flag string
	}{
		{name: "top", flag: "--unified-top"},
		{name: "bottom", flag: "--unified-bottom"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			goSnapshot := unifiedInitialSnapshot(t, implementation{name: "go", bin: goBin}, tt.flag)
			zigSnapshot := unifiedInitialSnapshot(t, implementation{name: "zig", bin: zigBin}, tt.flag)

			goClientBefore := appearsBefore(goSnapshot, "alpha-service", "READY")
			zigClientBefore := appearsBefore(zigSnapshot, "alpha-service", "READY")
			goServerBefore := appearsBefore(goSnapshot, "READY", "alpha-service")
			zigServerBefore := appearsBefore(zigSnapshot, "READY", "alpha-service")

			if zigClientBefore != goClientBefore || zigServerBefore != goServerBefore {
				t.Fatalf("unified %s ordering mismatch: Go(clientBefore=%v serverBefore=%v) Zig(clientBefore=%v serverBefore=%v)\nGo:\n%s\n\nZig:\n%s",
					tt.name,
					goClientBefore,
					goServerBefore,
					zigClientBefore,
					zigServerBefore,
					goSnapshot,
					zigSnapshot,
				)
			}
		})
	}
}

func TestUnifiedServerPaneShowsStartedProcessOutputLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goSnapshot := unifiedSnapshotAfterStartingFirstProcess(t, implementation{name: "go", bin: goBin})
	zigSnapshot := unifiedSnapshotAfterStartingFirstProcess(t, implementation{name: "zig", bin: zigBin})

	goShowsOutput := strings.Contains(goSnapshot, "process-ready")
	zigShowsOutput := strings.Contains(zigSnapshot, "process-ready")
	if zigShowsOutput != goShowsOutput {
		t.Fatalf("unified process output visibility mismatch: Go=%v Zig=%v\nGo:\n%s\n\nZig:\n%s",
			goShowsOutput,
			zigShowsOutput,
			goSnapshot,
			zigSnapshot,
		)
	}
}

func TestUnifiedServerPaneForwardsInputToStartedProcessLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goSnapshot := unifiedSnapshotAfterServerInput(t, implementation{name: "go", bin: goBin}, "hello")
	zigSnapshot := unifiedSnapshotAfterServerInput(t, implementation{name: "zig", bin: zigBin}, "hello")

	goShowsInput := strings.Contains(goSnapshot, "got:hello")
	zigShowsInput := strings.Contains(zigSnapshot, "got:hello")
	if zigShowsInput != goShowsInput {
		t.Fatalf("unified server input forwarding mismatch: Go=%v Zig=%v\nGo:\n%s\n\nZig:\n%s",
			goShowsInput,
			zigShowsInput,
			goSnapshot,
			zigSnapshot,
		)
	}
}

func TestUnifiedServerPaneContainsAnsiClearLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goSnapshot := unifiedSnapshotAfterStartingProcessWithConfig(t, implementation{name: "go", bin: goBin}, unifiedConfigWithAnsiClearOutput, "after")
	zigSnapshot := unifiedSnapshotAfterStartingProcessWithConfig(t, implementation{name: "zig", bin: zigBin}, unifiedConfigWithAnsiClearOutput, "after")

	goKeepsClientUI := strings.Contains(goSnapshot, "alpha-service") && strings.Contains(goSnapshot, "after")
	zigKeepsClientUI := strings.Contains(zigSnapshot, "alpha-service") && strings.Contains(zigSnapshot, "after")
	if zigKeepsClientUI != goKeepsClientUI {
		t.Fatalf("unified ANSI clear containment mismatch: Go=%v Zig=%v\nGo:\n%s\n\nZig:\n%s",
			goKeepsClientUI,
			zigKeepsClientUI,
			goSnapshot,
			zigSnapshot,
		)
	}
}

func TestUnifiedServerPaneHandlesCarriageReturnLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goSnapshot := unifiedSnapshotAfterStartingProcessWithConfig(t, implementation{name: "go", bin: goBin}, unifiedConfigWithCarriageReturnOutput, "second")
	zigSnapshot := unifiedSnapshotAfterStartingProcessWithConfig(t, implementation{name: "zig", bin: zigBin}, unifiedConfigWithCarriageReturnOutput, "second")

	goHasConcatenatedLine := strings.Contains(goSnapshot, "firstsecond")
	zigHasConcatenatedLine := strings.Contains(zigSnapshot, "firstsecond")
	if zigHasConcatenatedLine != goHasConcatenatedLine {
		t.Fatalf("unified carriage-return rendering mismatch: Go(concat=%v) Zig(concat=%v)\nGo:\n%s\n\nZig:\n%s",
			goHasConcatenatedLine,
			zigHasConcatenatedLine,
			goSnapshot,
			zigSnapshot,
		)
	}
}

func TestUnifiedServerPaneHandlesCursorEraseLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goSnapshot := unifiedSnapshotAfterStartingProcessWithConfig(t, implementation{name: "go", bin: goBin}, unifiedConfigWithCursorEraseOutput, "abcXYZ")
	zigSnapshot := unifiedSnapshotAfterStartingProcessWithConfig(t, implementation{name: "zig", bin: zigBin}, unifiedConfigWithCursorEraseOutput, "abcXYZ")

	goHasUnprocessedLine := strings.Contains(goSnapshot, "abcdefXYZ")
	zigHasUnprocessedLine := strings.Contains(zigSnapshot, "abcdefXYZ")
	if zigHasUnprocessedLine != goHasUnprocessedLine {
		t.Fatalf("unified cursor erase rendering mismatch: Go(unprocessed=%v) Zig(unprocessed=%v)\nGo:\n%s\n\nZig:\n%s",
			goHasUnprocessedLine,
			zigHasUnprocessedLine,
			goSnapshot,
			zigSnapshot,
		)
	}
}

func TestUnifiedServerPaneHandlesAlternateScreenLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goSnapshot := unifiedSnapshotAfterStartingProcessWithConfig(t, implementation{name: "go", bin: goBin}, unifiedConfigWithAlternateScreenOutput, "back")
	zigSnapshot := unifiedSnapshotAfterStartingProcessWithConfig(t, implementation{name: "zig", bin: zigBin}, unifiedConfigWithAlternateScreenOutput, "back")

	goLeaksAltScreen := strings.Contains(goSnapshot, "alt-screen")
	zigLeaksAltScreen := strings.Contains(zigSnapshot, "alt-screen")
	if zigLeaksAltScreen != goLeaksAltScreen {
		t.Fatalf("unified alternate-screen rendering mismatch: Go(leaks=%v) Zig(leaks=%v)\nGo:\n%s\n\nZig:\n%s",
			goLeaksAltScreen,
			zigLeaksAltScreen,
			goSnapshot,
			zigSnapshot,
		)
	}
}

func TestUnifiedServerPanePreservesAnsiStylesLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goRaw := unifiedRawAfterStartingProcessWithConfig(t, implementation{name: "go", bin: goBin}, unifiedConfigWithStyledOutput, styledPayload)
	zigRaw := unifiedRawAfterStartingProcessWithConfig(t, implementation{name: "zig", bin: zigBin}, unifiedConfigWithStyledOutput, styledPayload)

	goPreservesStyle := bytes.Contains(goRaw, []byte(styledPayloadSGR))
	zigPreservesStyle := bytes.Contains(zigRaw, []byte(styledPayloadSGR))
	if !goPreservesStyle {
		t.Fatalf("Go reference did not preserve styled payload SGR %q in raw output\nraw:\n%s", styledPayloadSGR, string(goRaw))
	}
	if zigPreservesStyle != goPreservesStyle {
		t.Fatalf("unified ANSI style preservation mismatch: Go=%v Zig=%v\nGo raw:\n%s\n\nZig raw:\n%s",
			goPreservesStyle,
			zigPreservesStyle,
			string(goRaw),
			string(zigRaw),
		)
	}
}

func TestUnifiedServerPaneHandlesLargeOutputLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goRaw := unifiedRawAfterStartingProcessWithRawNeedle(t, implementation{name: "go", bin: goBin}, unifiedConfigWithLargeOutput, largeOutputFinalLine)
	zigRaw := unifiedRawAfterStartingProcessWithRawNeedle(t, implementation{name: "zig", bin: zigBin}, unifiedConfigWithLargeOutput, largeOutputFinalLine)

	goShowsFinalLine := bytes.Contains(goRaw, []byte(largeOutputFinalLine))
	zigShowsFinalLine := bytes.Contains(zigRaw, []byte(largeOutputFinalLine))
	if !goShowsFinalLine {
		t.Fatalf("Go reference did not render large output final line %q in raw transcript\nGo raw:\n%s", largeOutputFinalLine, string(goRaw))
	}
	if zigShowsFinalLine != goShowsFinalLine {
		t.Fatalf("unified large output rendering mismatch: Go=%v Zig=%v\nGo raw:\n%s\n\nZig raw:\n%s",
			goShowsFinalLine,
			zigShowsFinalLine,
			string(goRaw),
			string(zigRaw),
		)
	}
}

func TestUnifiedProcessListReceivesNaturalExitStateLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	_ = unifiedSnapshotAfterNaturalProcessExit(t, implementation{name: "go", bin: goBin})
	_ = unifiedSnapshotAfterNaturalProcessExit(t, implementation{name: "zig", bin: zigBin})
}

func unifiedInitialSnapshot(t *testing.T, impl implementation, unifiedFlag ...string) string {
	t.Helper()

	return unifiedInitialSnapshotWithConfigAndSize(t, impl, unifiedConfigWithPlaceholder, e2e.TerminalSize{}, unifiedFlag...)
}

func unifiedInitialSnapshotWithConfigAndSize(
	t *testing.T,
	impl implementation,
	configText string,
	size e2e.TerminalSize,
	unifiedFlag ...string,
) string {
	t.Helper()

	cfgDir, cfgPath := e2e.WriteConfig(t, configText)
	args := unifiedFlag
	if len(args) == 0 {
		args = []string{"--unified"}
	}
	session := e2e.StartUnifiedSessionWithBinaryArgsAndSize(t, impl.bin, cfgDir, cfgPath, args, size)

	if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "beta-worker")
	}); err != nil {
		t.Fatalf("%s unified session did not render process list: %v\nsnapshot:\n%s",
			impl.name,
			err,
			session.Snapshot(),
		)
	}

	if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
		if impl.name != "go" {
			return true
		}
		return strings.Contains(snap, "READY")
	}); err != nil {
		t.Fatalf("%s unified session did not render server placeholder: %v\nsnapshot:\n%s",
			impl.name,
			err,
			session.Snapshot(),
		)
	}

	return trimSnapshot(session.Snapshot())
}

func unifiedSnapshotAfterNaturalProcessExit(t *testing.T, impl implementation) string {
	t.Helper()

	cfgDir, cfgPath := e2e.WriteConfig(t, unifiedConfigWithShortLivedDebugProcess)
	session := e2e.StartUnifiedSessionWithBinaryArgs(t, impl.bin, cfgDir, cfgPath, []string{"--unified-top"})

	if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "p [Halted]")
	}); err != nil {
		t.Fatalf("%s unified session did not render process list: %v\nsnapshot:\n%s",
			impl.name,
			err,
			session.Snapshot(),
		)
	}

	if err := session.SendRunes('j'); err != nil {
		t.Fatalf("%s unified send select-first key: %v", impl.name, err)
	}
	time.Sleep(50 * time.Millisecond)
	if err := session.SendRunes('s'); err != nil {
		t.Fatalf("%s unified send start key: %v", impl.name, err)
	}

	if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(trimSnapshot(snap), "p [Running]")
	}); err != nil {
		t.Fatalf("%s unified session did not render running process after start: %v\nsnapshot:\n%s",
			impl.name,
			err,
			session.Snapshot(),
		)
	}

	running := trimSnapshot(session.Snapshot())
	if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
		trimmed := trimSnapshot(snap)
		return trimmed != running &&
			strings.Contains(trimmed, "p [Halted]")
	}); err != nil {
		t.Fatalf("%s unified session did not receive stopped state after natural process exit: %v\nsnapshot:\n%s",
			impl.name,
			err,
			session.Snapshot(),
		)
	}

	return trimSnapshot(session.Snapshot())
}

func unifiedRightSnapshotAfterResize(t *testing.T, impl implementation) string {
	t.Helper()

	cfgDir, cfgPath := e2e.WriteConfig(t, unifiedConfigWithPlaceholder)
	session := e2e.StartUnifiedSessionWithBinaryArgsAndSize(
		t,
		impl.bin,
		cfgDir,
		cfgPath,
		[]string{"--unified-right"},
		e2e.TerminalSize{Rows: 24, Cols: 120},
	)

	if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "alpha-service") &&
			strings.Contains(snap, "READY")
	}); err != nil {
		t.Fatalf("%s unified session did not render initial right split: %v\nsnapshot:\n%s",
			impl.name,
			err,
			session.Snapshot(),
		)
	}

	if err := session.Resize(e2e.TerminalSize{Rows: 20, Cols: 90}); err != nil {
		t.Fatalf("%s unified session resize: %v", impl.name, err)
	}

	if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return lineContainsAll(trimSnapshot(snap), "READY", "alpha-service")
	}); err != nil {
		t.Fatalf("%s unified session did not reflow after resize: %v\nsnapshot:\n%s",
			impl.name,
			err,
			session.Snapshot(),
		)
	}

	return trimSnapshot(session.Snapshot())
}

func unifiedSnapshotAfterStartingFirstProcess(t *testing.T, impl implementation) string {
	t.Helper()

	return unifiedSnapshotAfterStartingProcessWithConfig(t, impl, unifiedConfigWithOutputProcess, "process-ready")
}

func unifiedSnapshotAfterStartingProcessWithConfig(t *testing.T, impl implementation, configText string, outputNeedle string) string {
	t.Helper()

	cfgDir, cfgPath := e2e.WriteConfig(t, configText)
	session := e2e.StartUnifiedSessionWithBinaryArgs(t, impl.bin, cfgDir, cfgPath, []string{"--unified"})

	if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "alpha-service") &&
			strings.Contains(snap, "beta-worker")
	}); err != nil {
		t.Fatalf("%s unified session did not render process list: %v\nsnapshot:\n%s",
			impl.name,
			err,
			session.Snapshot(),
		)
	}

	if err := session.SendRunes('j'); err != nil {
		t.Fatalf("%s unified send select-first key: %v", impl.name, err)
	}
	time.Sleep(50 * time.Millisecond)
	if err := session.SendRunes('s'); err != nil {
		t.Fatalf("%s unified send start key: %v", impl.name, err)
	}
	time.Sleep(200 * time.Millisecond)
	if err := session.SendKeys(e2e.KeyCtrlRight); err != nil {
		t.Fatalf("%s unified send focus-server key: %v", impl.name, err)
	}

	if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, outputNeedle)
	}); err != nil {
		t.Fatalf("%s unified session did not render process output: %v\nsnapshot:\n%s",
			impl.name,
			err,
			session.Snapshot(),
		)
	}

	return trimSnapshot(session.Snapshot())
}

func unifiedRawAfterStartingProcessWithConfig(t *testing.T, impl implementation, configText string, outputNeedle string) []byte {
	t.Helper()

	cfgDir, cfgPath := e2e.WriteConfig(t, configText)
	session := e2e.StartUnifiedSessionWithBinaryArgs(t, impl.bin, cfgDir, cfgPath, []string{"--unified"})

	if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "alpha-service") &&
			strings.Contains(snap, "beta-worker")
	}); err != nil {
		t.Fatalf("%s unified session did not render process list: %v\nsnapshot:\n%s",
			impl.name,
			err,
			session.Snapshot(),
		)
	}

	if err := session.SendRunes('j'); err != nil {
		t.Fatalf("%s unified send select-first key: %v", impl.name, err)
	}
	time.Sleep(50 * time.Millisecond)
	if err := session.SendRunes('s'); err != nil {
		t.Fatalf("%s unified send start key: %v", impl.name, err)
	}
	time.Sleep(200 * time.Millisecond)
	if err := session.SendKeys(e2e.KeyCtrlRight); err != nil {
		t.Fatalf("%s unified send focus-server key: %v", impl.name, err)
	}

	if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, outputNeedle)
	}); err != nil {
		t.Fatalf("%s unified session did not render process output: %v\nsnapshot:\n%s",
			impl.name,
			err,
			session.Snapshot(),
		)
	}

	return session.RawOutput()
}

func unifiedRawAfterStartingProcessWithRawNeedle(t *testing.T, impl implementation, configText string, rawNeedle string) []byte {
	t.Helper()

	cfgDir, cfgPath := e2e.WriteConfig(t, configText)
	session := e2e.StartUnifiedSessionWithBinaryArgs(t, impl.bin, cfgDir, cfgPath, []string{"--unified"})

	if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "alpha-service") &&
			strings.Contains(snap, "beta-worker")
	}); err != nil {
		t.Fatalf("%s unified session did not render process list: %v\nsnapshot:\n%s",
			impl.name,
			err,
			session.Snapshot(),
		)
	}

	if err := session.SendRunes('j'); err != nil {
		t.Fatalf("%s unified send select-first key: %v", impl.name, err)
	}
	time.Sleep(50 * time.Millisecond)
	if err := session.SendRunes('s'); err != nil {
		t.Fatalf("%s unified send start key: %v", impl.name, err)
	}
	time.Sleep(200 * time.Millisecond)
	if err := session.SendKeys(e2e.KeyCtrlRight); err != nil {
		t.Fatalf("%s unified send focus-server key: %v", impl.name, err)
	}

	if err := session.WaitForRaw(rawNeedle, 10*time.Second); err != nil {
		t.Fatalf("%s unified session raw transcript did not contain process output: %v\nraw:\n%s",
			impl.name,
			err,
			string(session.RawOutput()),
		)
	}

	return session.RawOutput()
}

func unifiedSnapshotAfterServerInput(t *testing.T, impl implementation, inputLine string) string {
	t.Helper()

	cfgDir, cfgPath := e2e.WriteConfig(t, unifiedConfigWithInteractiveProcess)
	session := e2e.StartUnifiedSessionWithBinaryArgs(t, impl.bin, cfgDir, cfgPath, []string{"--unified"})

	if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "alpha-service") &&
			strings.Contains(snap, "beta-worker")
	}); err != nil {
		t.Fatalf("%s unified session did not render process list: %v\nsnapshot:\n%s",
			impl.name,
			err,
			session.Snapshot(),
		)
	}

	if err := session.SendRunes('j'); err != nil {
		t.Fatalf("%s unified send select-first key: %v", impl.name, err)
	}
	time.Sleep(50 * time.Millisecond)
	if err := session.SendRunes('s'); err != nil {
		t.Fatalf("%s unified send start key: %v", impl.name, err)
	}
	if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "ready-for-input")
	}); err != nil {
		t.Fatalf("%s unified session did not render input prompt: %v\nsnapshot:\n%s",
			impl.name,
			err,
			session.Snapshot(),
		)
	}
	if err := session.SendKeys(e2e.KeyCtrlRight); err != nil {
		t.Fatalf("%s unified send focus-server key: %v", impl.name, err)
	}
	time.Sleep(100 * time.Millisecond)
	for _, r := range inputLine {
		if err := session.SendRunes(r); err != nil {
			t.Fatalf("%s unified send server input: %v", impl.name, err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err := session.SendKeys(e2e.KeyEnter); err != nil {
		t.Fatalf("%s unified send server enter: %v", impl.name, err)
	}

	if err := session.WaitForSnapshot(10*time.Second, func(snap string) bool {
		return strings.Contains(snap, "got:"+inputLine)
	}); err != nil {
		t.Fatalf("%s unified session did not render echoed server input: %v\nsnapshot:\n%s",
			impl.name,
			err,
			session.Snapshot(),
		)
	}

	return trimSnapshot(session.Snapshot())
}

func appearsBefore(snapshot string, first string, second string) bool {
	firstIndex := strings.Index(snapshot, first)
	secondIndex := strings.Index(snapshot, second)
	return firstIndex >= 0 && secondIndex >= 0 && firstIndex < secondIndex
}

func lineContainsAll(snapshot string, needles ...string) bool {
	for _, line := range strings.Split(snapshot, "\n") {
		matched := true
		for _, needle := range needles {
			if !strings.Contains(line, needle) {
				matched = false
				break
			}
		}
		if matched {
			return true
		}
	}
	return false
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

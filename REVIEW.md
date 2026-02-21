# Multi-Valued Code Review Report

## Review Summary
- **Resolved Scope:** project
- **Scope Input:** scope=project
- **Scope Fallback:** none
- **Files Considered:** 34
- **Overall Risk:** High
- **Blocking Issues:** 9
- **Non-Blocking Issues:** 11

## Blocking Issues

### [F-001] Process configs alias the same pointer
- **Blocking:** Yes
- **Severity:** Critical
- **Category:** correctness-invariants
- **Location:** internal/domain/state.go:56
- **Comment:** `NewAppState` takes `&proc` from a map range variable, causing all `Process.Config` pointers to reference the same reused variable.
- **Why It Matters:** Different processes can run with incorrect command/env/cwd, violating core process identity invariants.
- **Suggested Fix:** Copy per iteration before taking address (e.g., `procCfg := proc`) or store config by value in `Process`.
- **Confidence:** High
- **Evidence:** `for k, proc := range cfg.Procs { proc := NewFromProcessConfig(i, k, &proc) ... }`

### [F-002] Start returns success after closing PTY on raw-mode error
- **Blocking:** Yes
- **Severity:** High
- **Category:** correctness-invariants
- **Location:** internal/process/controller.go:94
- **Comment:** On `setRawMode(ptmx)` failure, code closes PTY and continues returning a started instance.
- **Why It Matters:** Caller sees successful startup, but I/O contracts are broken because PTY is invalidated.
- **Suggested Fix:** Treat raw-mode failure as startup failure with cleanup, or continue explicitly in non-raw mode without closing PTY.
- **Confidence:** High
- **Evidence:** `ptmx.Close()` in error path, followed by normal return.

### [F-003] IPC command channel lacks local client authorization controls
- **Blocking:** Yes
- **Severity:** High
- **Category:** security-trust-boundaries
- **Location:** internal/ipc/server.go:55
- **Comment:** Server accepts Unix socket clients and executes privileged commands without peer identity authorization checks.
- **Why It Matters:** Any local process able to connect can control process lifecycle actions across a trust boundary.
- **Suggested Fix:** Enforce restrictive socket permissions/ownership and validate peer credentials (same-UID).
- **Confidence:** High
- **Evidence:** `net.Listen("unix", socketPath)` + command handling with no auth/peer-cred validation.

### [F-004] Shell injection via placeholder banner construction
- **Blocking:** Yes
- **Severity:** High
- **Category:** security-trust-boundaries
- **Location:** internal/domain/state.go:47
- **Comment:** Banner content is interpolated into a `bash -c` command string without robust escaping.
- **Why It Matters:** Config text can become command execution input, violating data-vs-executable trust boundaries.
- **Suggested Fix:** Avoid shell for banner rendering; render in UI or pass argv-safe arguments only.
- **Confidence:** High
- **Evidence:** `echo.WriteString("echo \"" + line + "\"; ")` and `[]string{"bash","-c",...}`

### [F-005] Full config/state exposure risks secret leakage
- **Blocking:** Yes
- **Severity:** High
- **Category:** security-trust-boundaries
- **Location:** internal/ipc/server.go:263
- **Comment:** Full app state/config (including process env) is serialized over IPC and full configs are logged with `%+v`.
- **Why It Matters:** Secrets/tokens may leak to local clients or log files.
- **Suggested Fix:** Use redacted IPC/log DTOs; omit sensitive fields like env and credential-like values.
- **Confidence:** High
- **Evidence:** `Message{Type:"state", State: state...}` and config `%+v` logging in startup paths.

### [F-006] Primary mode lacks graceful signal-driven shutdown path
- **Blocking:** Yes
- **Severity:** High
- **Category:** reliability-operability
- **Location:** cmd/proctmux/primary.go:34
- **Comment:** Primary mode blocks with `select {}` and does not actively coordinate SIGINT/SIGTERM shutdown.
- **Why It Matters:** Can leave child processes/socket state inconsistent on termination.
- **Suggested Fix:** Use `signal.NotifyContext` and call stop/cleanup on cancellation.
- **Confidence:** High
- **Evidence:** Infinite `select {}` after startup with no signal wait loop.

### [F-007] Broadcast writes can block server under lock
- **Blocking:** Yes
- **Severity:** High
- **Category:** reliability-operability
- **Location:** internal/ipc/server.go:276
- **Comment:** Broadcast performs synchronous client writes while holding shared lock and without write deadlines.
- **Why It Matters:** One slow/stuck client can stall state fanout and degrade control-plane responsiveness.
- **Suggested Fix:** Snapshot clients before write, set deadlines, and evict timed-out clients.
- **Confidence:** High
- **Evidence:** `s.mu.RLock()` held across per-client `cc.Write(data)`.

### [F-008] Internal command paths terminate process instead of returning errors
- **Blocking:** Yes
- **Severity:** High
- **Category:** evolvability-maintainability
- **Location:** cmd/proctmux/primary.go:24
- **Comment:** Functions that return `error` call `log.Fatal`/`os.Exit`, collapsing error boundaries.
- **Why It Matters:** Hurts reuse/testing and forces abrupt exits from deep layers.
- **Suggested Fix:** Return wrapped errors and keep process-exit decisions only in `main()`.
- **Confidence:** High
- **Evidence:** Fatal/exit behavior in `RunPrimary`, `RunClient`, `RunSignalCommand`.

### [F-009] Command protocol is duplicated and stringly typed across layers
- **Blocking:** Yes
- **Severity:** High
- **Category:** evolvability-maintainability
- **Location:** internal/ipc/server.go:174
- **Comment:** Action names (`start/stop/restart/...`) are hard-coded in multiple packages with independent switches.
- **Why It Matters:** Changes require synchronized edits with no compile-time guarantees; drift risk is high.
- **Suggested Fix:** Introduce shared typed command constants/registry and common DTOs used by CLI, client, server.
- **Confidence:** High
- **Evidence:** Parallel string-switch dispatch paths in CLI, IPC client/server, and primary handlers.

## Non-Blocking Issues

### [F-010] Logger setup failure reports wrong error variable
- **Blocking:** No
- **Severity:** Medium
- **Category:** correctness-invariants
- **Location:** cmd/proctmux/main.go:58
- **Comment:** Logger-open failure path prints/panics `cfgLoadErr` instead of logger `err`.
- **Why It Matters:** Diagnostics can be incorrect or nil, masking root cause.
- **Suggested Fix:** Use `err` consistently in that failure branch.
- **Confidence:** High
- **Evidence:** `fmt.Println(..., cfgLoadErr); panic(cfgLoadErr)` after `setupLogger`.

### [F-011] Auto-discovered package script names are shell-interpolated
- **Blocking:** No
- **Severity:** Medium
- **Category:** security-trust-boundaries
- **Location:** internal/procdiscover/packagejson/discoverer.go:79
- **Comment:** Script names from `package.json` are included in shell command strings without strict validation.
- **Why It Matters:** Untrusted repo/script metadata can alter execution behavior.
- **Suggested Fix:** Validate script names with strict pattern and prefer argv-based exec over shell strings.
- **Confidence:** Medium
- **Evidence:** Manager builds shell command string from discovered script names.

### [F-012] Log file creation permissions are broad by default
- **Blocking:** No
- **Severity:** Low
- **Category:** security-trust-boundaries
- **Location:** cmd/proctmux/main.go:27
- **Comment:** Logs are created with `0666` (subject to umask).
- **Why It Matters:** May overexpose operational output on permissive environments.
- **Suggested Fix:** Create logs with `0600` and enforce mode where appropriate.
- **Confidence:** High
- **Evidence:** `os.OpenFile(..., 0666)` in startup logging setup.

### [F-013] Socket readiness uses file-exists heuristic only
- **Blocking:** No
- **Severity:** Medium
- **Category:** reliability-operability
- **Location:** internal/ipc/socket.go:79
- **Comment:** Readiness check returns success on socket file existence without dial/handshake probe.
- **Why It Matters:** Stale socket files can cause false-ready conditions and startup flakiness.
- **Suggested Fix:** Validate readiness by actual connect/handshake.
- **Confidence:** High
- **Evidence:** Loop exits on `os.Stat(socketPath) == nil`.

### [F-014] Goroutine writes to outer error variable in startup flow
- **Blocking:** No
- **Severity:** Medium
- **Category:** reliability-operability
- **Location:** internal/process/controller.go:127
- **Comment:** Goroutine assigns to function-scoped `err`, creating race-prone behavior.
- **Why It Matters:** Nondeterministic behavior under concurrency and poorer incident diagnosability.
- **Suggested Fix:** Use goroutine-local error variables and explicit reporting channels.
- **Confidence:** High
- **Evidence:** `_, err = io.Copy(...)` inside goroutine capturing outer `err`.

### [F-015] Dummy process injects UI concern into domain state
- **Blocking:** No
- **Severity:** Medium
- **Category:** complexity-simplification
- **Location:** internal/domain/state.go:26
- **Comment:** Placeholder banner is represented as synthetic process and then filtered via special cases.
- **Why It Matters:** Adds hidden invariants and scattered conditional branches.
- **Suggested Fix:** Move placeholder/banner into UI-specific state instead of domain process list.
- **Confidence:** High
- **Evidence:** `DummyProcessID` handling and repeated exclusion checks.

### [F-016] Filter/selection recomputation is duplicated across handlers
- **Blocking:** No
- **Severity:** Medium
- **Category:** complexity-simplification
- **Location:** internal/tui/input.go:27
- **Comment:** Multiple handlers independently recompute filtered lists and active selection.
- **Why It Matters:** Policy changes become error-prone and behavior drift likely.
- **Suggested Fix:** Centralize recomputation into one helper returning normalized filtered/selection state.
- **Confidence:** High
- **Evidence:** Parallel logic across `rebuildProcessList`, `applyFilterNow`, `moveSelection`.

### [F-017] Resize logic duplicates similar split math paths
- **Blocking:** No
- **Severity:** Low
- **Category:** complexity-simplification
- **Location:** internal/tui/unified.go:163
- **Comment:** Horizontal/vertical split branches repeat clamp/fallback calculations.
- **Why It Matters:** Makes layout adjustments harder and increases regression surface.
- **Suggested Fix:** Extract shared split-size calculation helpers.
- **Confidence:** Medium
- **Evidence:** Mirrored calculations for `SplitLeft/Right` vs `SplitTop/Bottom`.

### [F-018] Unified TUI model is highly coupled and multi-responsibility
- **Blocking:** No
- **Severity:** Medium
- **Category:** evolvability-maintainability
- **Location:** internal/tui/unified.go:49
- **Comment:** One large model handles layout, key routing, terminal mapping, status UI, and reaches into client internals.
- **Why It Matters:** Changes are harder to isolate/test; internal coupling increases breakage risk.
- **Suggested Fix:** Split into smaller components with narrow interfaces between client and unified rendering.
- **Confidence:** Medium
- **Evidence:** Large `UnifiedModel` and direct internal field access patterns.

### [F-019] Discoverer registration depends on init side effects
- **Blocking:** No
- **Severity:** Medium
- **Category:** evolvability-maintainability
- **Location:** cmd/proctmux/main.go:14
- **Comment:** Blank imports trigger global discoverer registration via `init()`.
- **Why It Matters:** Dependency wiring is implicit and harder to reason about/test.
- **Suggested Fix:** Use explicit registration in startup composition.
- **Confidence:** Medium
- **Evidence:** Side-effect imports plus global registry in procdiscover.

### [F-020] Process IDs are assigned via nondeterministic map iteration
- **Blocking:** No
- **Severity:** Low
- **Category:** evolvability-maintainability
- **Location:** internal/domain/state.go:56
- **Comment:** IDs increment while iterating `cfg.Procs` map directly.
- **Why It Matters:** Run-to-run ordering differences can create brittle tests/behavior tied to IDs.
- **Suggested Fix:** Sort process keys before ID assignment.
- **Confidence:** High
- **Evidence:** `for k, proc := range cfg.Procs { ... i++ }` over map.

## Category Totals
- **correctness-invariants:** C:1 H:1 M:1 L:0
- **security-trust-boundaries:** C:0 H:3 M:1 L:1
- **reliability-operability:** C:0 H:2 M:2 L:0
- **complexity-simplification:** C:0 H:0 M:2 L:1
- **evolvability-maintainability:** C:0 H:2 M:2 L:1

# Zig Cutover Review Findings

Date: 2026-06-09  
Branch reviewed: `zig-spike`  
Reference implementation: Go branch/worktree `go-archive`  
Status: read-only review; no code changes made during review.

## Purpose

This document captures the review findings from comparing the current Zig implementation against the Go implementation before replacing Go with Zig as the single implementation.

Use this as a working checklist. We will work through the findings one by one, decide whether each is a bug, intentional change, documentation cleanup, or simplification opportunity, then record the resolution.

## Current Recommendation

Do **not** cut over to Zig yet. The Zig implementation is viable, but it is not a thin port. It is a larger rewrite that hand-rolls TUI rendering, IPC JSON codecs, terminal repainting, PTY/process management, and unified-mode terminal rendering.

Before cutover, address the must-fix items below and update docs to match actual behavior.

## Review Notes

- Zig branch had a clean status at review time.
- `zig build test -Dversion=1.0.0-dev` passed.
- `make test` failed because of Makefile/macOS SDK/sysroot resolution, not because of Zig test failures.
- Approximate code size:
  - Zig `src/`: ~16.7k lines total, ~14.1k nonblank.
  - Go production code: ~7.0k lines total, ~6.0k nonblank.
  - Zig e2e Python tests: ~2.3k lines total.
  - Go tests: ~5.1k lines total.

## Working Queue

| ID | Priority | Finding | Proposed classification | Status |
|---|---:|---|---|---|
| F1 | P0 | Output replay/drop risk after ring-buffer wrap or restart | Bug / cutover blocker | Open |
| F2 | P0 | `log_file` / `stdout_debug_log_file` parsed but not honored | Bug or docs/config cleanup | Open |
| F3 | P0 | Docs/config overpromise current Zig behavior | Cutover blocker for docs | Open |
| F4 | P1 | Discovery failure semantics changed from Go | Intentional? Needs decision | Open |
| F5 | P1 | Go/Zig IPC/socket compatibility break | Intentional? Needs decision | Open |
| F6 | P1 | Manual JSON codecs add substantial complexity | Simplification opportunity | Open |
| F7 | P1 | Unified mode / `libghostty-vt` is largest complexity area | Architecture decision | Open |
| F8 | P2 | Dead config fields still leak into docs/hash/IPC | Cleanup | Open |
| F9 | P2 | Test coverage shifted: more Zig production, fewer tests than Go | Risk | Open |
| F10 | P2 | TUI style/color parity changed | Intentional? Needs decision | Open |

---

## F1: Output Replay/Drop Risk After Ring-Buffer Wrap or Restart

**Priority:** P0  
**Status:** Open  
**Area:** process output, primary mode, unified mode

### Finding

Production output paths track process output by scrollback byte length:

- `src/modes/primary.zig`
- `src/unified/server_output.zig`

Once the 1MB ring buffer wraps, `bytes.len` can stop increasing even though new output is being written. That means live output can stop appearing. Restarted processes can also skip initial output if the new scrollback length is greater than the previously consumed length.

`src/viewer/root.zig` has a better `snapshotAndSubscribe()` model, but production primary mode does not appear to use that viewer path.

### Why it matters

This can drop or freeze visible process output, which is core proctmux behavior.

### Suggested resolution

Use a generation/cursor/subscription model everywhere instead of comparing scrollback lengths. Prefer consolidating around `RingBuffer.snapshotAndSubscribe()` or an equivalent monotonic output cursor.

### Acceptance checks

- Long-running process with >1MB output continues to display new lines.
- Restarted selected process shows its new initial output immediately.
- Switching between processes does not lose bytes written during the switch.
- Add unit or e2e coverage for wraparound and restart output.

### Resolution notes

_To be filled in._

---

## F2: Logging Config Parsed But Not Honored

**Priority:** P0  
**Status:** Open  
**Area:** logging, runtime config, TUI stability

### Finding

Go configured runtime logging from `log_file` and disabled logging when empty. Zig parses `log_file` and `stdout_debug_log_file`, includes them in config hash and IPC state, and documents them, but there does not appear to be a runtime log sink setup in `src/main.zig`.

Observed Zig log calls use `std.log`. Without a configured log sink, warnings/errors can go to stderr and corrupt the TUI.

### Why it matters

Docs say logging is controlled by config. If that is false, users lose troubleshooting support and TUI output can be polluted.

### Suggested resolution

Choose one:

1. Implement config-driven logging before starting interactive modes.
2. Or mark these fields dead/unsupported, remove them from docs/template/hash/IPC active state, and avoid logging to stderr during TUI runtime.

### Acceptance checks

- With `log_file: ""`, no app logs are emitted into the TUI.
- With `log_file: "/tmp/proctmux.log"`, app logs go to that file.
- `stdout_debug_log_file` either works or is explicitly removed/marked unsupported.

### Resolution notes

_To be filled in._

---

## F3: Docs/Config Overpromise Current Zig Behavior

**Priority:** P0  
**Status:** Open  
**Area:** README and docs

### Finding

Current docs still mention behavior that appears missing, stale, or materially different in Zig:

- `signal_server` HTTP server and CLI signal commands talking to it.
- `PROCTMUX_NO_ALTSCREEN`.
- `stdout_debug_log_file`.
- `autofocus` behavior.
- `docs` popup key.
- selected/unselected process foreground/background colors.
- hex color support.
- IPC/client state carrying output/scrollback snapshots.

### Why it matters

Cutover should not ship docs for behavior that is not present. This creates false regressions and makes support harder.

### Suggested resolution

Audit and update:

- `README.md`
- `docs/configuration.md`
- `docs/modes.md`
- `docs/architecture.md`
- `docs/ipc.md`
- `docs/troubleshooting.md`
- `docs/tui.md`
- `src/config/template.zig`

### Acceptance checks

- Every documented config field is classified as active, ignored-with-warning, or unsupported.
- Every documented keybinding is implemented or explicitly marked reserved.
- HTTP signal server docs are removed unless implemented.

### Resolution notes

_To be filled in._

---

## F4: Discovery Failure Semantics Changed From Go

**Priority:** P1  
**Status:** Open  
**Area:** auto-discovery

### Finding

Go discovery logged non-missing errors and continued. Zig discovery ignores missing sources but propagates other errors.

Examples:

- invalid `package.json`
- unreadable Makefile/package.json
- JSON parse failures

### Why it matters

A project with explicit `procs` and broken optional discovery metadata could start in Go but fail in Zig.

### Suggested resolution

Decide desired behavior:

- Strict: discovery failures abort startup.
- Lenient: discovery failures warn and continue, preserving Go behavior.

For developer ergonomics, lenient behavior may be safer unless strictness is explicitly desired.

### Acceptance checks

- Add a test for invalid `package.json` with explicit procs.
- Document whether discovery failures are fatal.

### Resolution notes

_To be filled in._

---

## F5: Go/Zig IPC and Socket Compatibility Break

**Priority:** P1  
**Status:** Open  
**Area:** IPC, socket hashing, migration

### Finding

Go computed the socket hash by YAML-marshalling config. Zig uses a custom deterministic writer. Protocol encoding is also hand-written in Zig rather than Go `encoding/json`.

### Why it matters

A Go primary and Zig client, or Zig primary and Go client, should not be expected to interoperate. This is fine for a hard cutover, but should be explicit.

### Suggested resolution

Document that cross-version Go/Zig IPC compatibility is unsupported during cutover. If compatibility is required, add a compatibility layer or matching socket hash/protocol tests.

### Acceptance checks

- Cutover notes explicitly state whether mixed Go/Zig clients are supported.
- Socket hash behavior is covered by tests.

### Resolution notes

_To be filled in._

---

## F6: Manual JSON Codecs Add Substantial Complexity

**Priority:** P1  
**Status:** Open  
**Area:** IPC architecture

### Finding

Zig manually encodes and decodes protocol/state JSON in files such as:

- `src/ipc/command_codec.zig`
- `src/ipc/state_codec.zig`
- `src/ipc/protocol.zig`

This is a major source of code size and future maintenance risk.

### Why it matters

Manual JSON codecs are easy to break when fields change. They also obscure the actual protocol schema.

### Suggested resolution

Prefer typed DTO structs plus shared encode/decode helpers using `std.json`, with golden tests. If manual codecs remain, add strong golden protocol tests and keep them isolated.

### Acceptance checks

- Protocol schema is obvious from types/tests.
- Adding a field does not require scattered manual string construction.
- Golden tests cover command request, command response, list response, and state update.

### Resolution notes

_To be filled in._

---

## F7: Unified Mode / `libghostty-vt` Is the Largest Complexity Area

**Priority:** P1  
**Status:** Open  
**Area:** TUI architecture, unified mode

### Finding

Unified mode adds a large amount of complexity:

- embedded primary/server orchestration
- split-pane focus/input routing
- terminal output rendering through vendored `libghostty-vt`
- separate child-primary and in-process output paths

### Why it matters

If embedded terminal panes are core to proctmux, this complexity may be justified. If unified mode is optional, it dominates the cutover risk and maintenance burden.

### Suggested resolution

Make an explicit product/architecture decision:

- Unified mode is core: keep it, but simplify output paths and invest in e2e coverage.
- Unified mode is optional: consider cutting over primary/client first, then stabilizing unified separately.

### Acceptance checks

- A documented decision exists.
- Unified mode has focused e2e tests for switching, restart, long output, interactive input, and terminal escape handling.

### Resolution notes

_To be filled in._

---

## F8: Dead Config Fields Still Leak Into Active Surfaces

**Priority:** P2  
**Status:** Open  
**Area:** config, docs, IPC

### Finding

Some fields are treated as dead or ignored in Zig but still appear in docs, templates, hash, or IPC state. Examples include stale tmux/session-era fields and style fields that do not affect rendering.

### Why it matters

Config should have a clear contract. Dead fields should not affect socket identity or be advertised as active behavior.

### Suggested resolution

Classify every config field:

- active
- parsed for migration but ignored with warning
- removed/unsupported

Then align parser, defaults, template, docs, hash, and IPC state with that classification.

### Acceptance checks

- Dead fields do not affect config hash.
- Dead fields are absent from starter template unless explicitly documented as ignored migration fields.
- Unknown/dead warnings are visible enough to help users.

### Resolution notes

_To be filled in._

---

## F9: Test Coverage Shifted Toward Less Coverage Per Production LOC

**Priority:** P2  
**Status:** Open  
**Area:** tests, release readiness

### Finding

Zig production code is much larger than Go production code, while Go had a larger dedicated test suite. Zig has many unit tests embedded in source files and Python e2e tests, but the surface area grew significantly.

### Why it matters

The rewrite increases custom infrastructure: TUI rendering, IPC, terminal emulation, PTY/process handling, and JSON codecs. These need strong regression coverage before Go is removed.

### Suggested resolution

Prioritize tests around high-risk behavior rather than matching Go test count:

- output wraparound/restart
- process lifecycle and stop escalation
- IPC protocol golden tests
- config load/hash/dead fields
- discovery failure behavior
- unified mode terminal rendering/input

### Acceptance checks

- `make test-all` or equivalent passes locally.
- Release gate documents which tests must pass before cutover.

### Resolution notes

_To be filled in._

---

## F10: TUI Style/Color Parity Changed

**Priority:** P2  
**Status:** Open  
**Area:** TUI rendering, configuration

### Finding

Go used configured selected/unselected process colors and background colors through lipgloss. Zig appears to color status markers but does not fully apply selected/unselected text/background styling. Go/lipgloss also accepted richer color values, while Zig currently supports a narrower set of ANSI-style names/codes.

### Why it matters

This is user-visible if people customized styles. It may be acceptable, but it should be intentional and documented.

### Suggested resolution

Decide whether style parity matters:

- If yes, implement selected/unselected foreground/background and hex support.
- If no, remove or mark unsupported style fields.

### Acceptance checks

- Style docs match actual rendering.
- Tests cover at least status marker colors and any supported selected/unselected styling.

### Resolution notes

_To be filled in._

---

## Proposed Work Order

1. F1: fix output cursor/subscription model.
2. F2: decide and fix logging behavior.
3. F3/F8/F10: clean config/docs/style contract together.
4. F4: decide discovery strictness and test it.
5. F5/F6: decide IPC compatibility and simplify or harden codecs.
6. F7: make explicit unified-mode decision.
7. F9: close remaining test gaps and define release gate.

## Running Resolution Log

Use this section to record decisions as we work through the list.

| Date | Finding | Decision | Follow-up |
|---|---|---|---|
| 2026-06-09 | Initial review | Created findings queue | Start with F1 |

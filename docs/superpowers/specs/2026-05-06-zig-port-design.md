# Zig Port Design

Date: 2026-05-06

## Overview

This design ports proctmux from Go to Zig as a hard cutover. The shipped
`proctmux` binary becomes Zig-only. The existing Go implementation remains in
the repository during the migration only as a parity oracle for tests,
fixtures, and reference behavior. Go is not a deployment target after the
cutover.

The Zig implementation should preserve user-facing behavior at the command,
configuration, IPC, process-management, and TUI workflow boundaries while
allowing the internal architecture to use Zig-native patterns and libraries.
The unified terminal pane will use vendored `libghostty-vt` for terminal
emulation. The process-list TUI will use a comparable popular Zig TUI library,
with `libvaxis` as the selected candidate unless implementation work uncovers a
blocking limitation.

## Goals

- Replace the deployed Go binary with a Zig implementation.
- Preserve the existing CLI surface:
  - `proctmux`
  - `proctmux start`
  - `proctmux --client`
  - `proctmux --unified`
  - `proctmux --unified-left`
  - `proctmux --unified-right`
  - `proctmux --unified-top`
  - `proctmux --unified-bottom`
  - `proctmux config-init [path]`
  - all `signal-*` commands
- Preserve active YAML configuration structure, defaults, and behavior.
- Ignore stale/dead config fields with warnings instead of implementing them.
- Preserve Unix socket JSON-lines IPC behavior and socket discovery.
- Preserve all three runtime modes: primary, client, and unified.
- Use vendored/pinned dependencies; do not assume system-installed libraries.
- Target macOS and Linux on amd64 and arm64.
- Achieve behavioral parity for the TUI, with a visually familiar but not
  pixel-identical process list.

## Non-Goals

- Keep Go as a shipped binary, compatibility layer, or distribution path.
- Preserve Go package structure or internal implementation paradigms.
- Preserve stale README/config-init fields that are not active in the current
  Go implementation.
- Replace the IPC protocol during the initial port.
- Add Windows support.
- Require screenshot-perfect TUI parity.

## Compatibility Boundaries

The port treats active Go behavior as the source of truth. Documentation and
templates are useful references, but current implementation behavior wins when
they disagree.

### CLI

The Zig binary must remain a command-line drop-in replacement for the active
CLI surface. User-visible flag conflicts, subcommand names, and signal-command
behavior should be preserved where practical.

### Configuration

The Zig config loader must preserve:

- Config search order: `proctmux.yaml`, `proctmux.yml`, `procmux.yaml`,
  `procmux.yml`
- `-f <path>` override behavior
- Active top-level and process config fields
- Defaults for keybindings, layout, style, shell command, process stop timeout,
  PTY size, and placeholder behavior
- Config hashing behavior used for socket discovery
- `config-init` as a generated starter config

Dead or stale config fields should be parsed as unknown/dead fields and should
emit warnings. They should not affect behavior.

### IPC

The initial Zig implementation preserves the current protocol:

- Unix domain socket
- Socket path derived from a hash of the effective config
- JSON object per line
- State broadcasts
- Command request/response messages
- Redacted config environment values in IPC state
- Peer UID verification on Linux and macOS
- Slow-client timeout/backpressure semantics

Zig internals should model IPC messages with typed tagged unions and explicit
serialization/deserialization, but the wire format should remain compatible.
An additive protocol version field may be introduced only if it does not break
existing Go/Zig interoperability tests.

### TUI

TUI acceptance is behavioral parity:

- Same default and configurable keybindings
- Same process control workflows
- Same filter lifecycle
- Same fuzzy and category filtering behavior
- Same running-only toggle behavior
- Same help toggle behavior
- Same docs action if the behavior is active in Go
- Same focus switching in unified mode
- Same split orientations
- Same `layout.hide_process_list_when_unfocused` behavior

The process list may differ slightly in rendering if `libvaxis` naturally
produces different layout or style details. It should remain visually familiar:
selected row, status marker, pointer, process label, debug information, panels,
and messages should correspond to the Go UI.

## Library Choices

### Terminal Emulation

Unified mode should use vendored `libghostty-vt`.

Rationale:

- It is the Ghostty terminal-emulation library.
- It provides modern VT parsing and formatting capabilities.
- It supports the direction of the project better than the current Go terminal
  emulator dependency.

Integration requirements:

- Vendor and pin Ghostty source or a reproducible vendored artifact.
- Build `libghostty-vt` through the Zig build system.
- Wrap it behind a narrow internal `terminal` interface.
- Keep C ABI and Ghostty-specific details out of TUI and mode orchestration
  code.
- Treat API churn as expected and isolated to the wrapper module.

### Process-List TUI

Use `libvaxis` as the default Zig TUI framework candidate.

Rationale:

- It is a credible Zig-native terminal UI library.
- It supports event/input handling and higher-level UI framework concepts.
- It is popular enough relative to the Zig TUI ecosystem to justify using it
  over smaller or less mature options.

Design constraint:

- Keep proctmux UI state, filtering, keybinding matching, and IPC actions
  testable outside of `libvaxis` rendering. The framework should render and
  route events, not own application semantics.

## Target Architecture

The Zig architecture should preserve the current conceptual boundaries without
copying the Go package layout mechanically.

Proposed modules:

| Module | Responsibility |
| --- | --- |
| `cli` | Parse flags/subcommands and preserve the command surface. |
| `config` | Load YAML, apply defaults, validate active fields, warn on dead fields, generate starter config. |
| `discover` | Discover processes from Makefile targets and `package.json` scripts. |
| `domain` | Process model, state, process views, statuses, filtering, sorting. |
| `ipc` | Socket path hashing, Unix socket server/client, JSON-lines protocol, request correlation, state broadcasts, peer UID checks. |
| `proc` | PTY-backed process execution, command building, environment merging, stop/restart lifecycle, `on_kill`. |
| `ring` | Bounded scrollback buffer with live subscribers. |
| `viewer` | Primary-mode stdout relay with snapshot plus live subscription semantics. |
| `tui` | `libvaxis` client UI, key handling, process list, filter input, messages, help, focus behavior. |
| `terminal` | `libghostty-vt` wrapper for unified terminal emulation. |
| `modes` | Primary, client, unified, and signal command orchestration. |
| `parity` | Test utilities for invoking the Go reference implementation during migration. |

## Runtime Composition

### Primary Mode

Primary mode owns:

- Config loading and process discovery
- App state
- Process controller
- IPC server
- Stdin forwarding to the selected process PTY
- Stdout viewer for selected process output
- Signal handling and shutdown

It remains the authoritative owner of process lifecycle and state.

### Client Mode

Client mode owns:

- Socket discovery and connection
- IPC client subscription
- Process-list TUI
- Command dispatch to the primary server

It does not manage processes directly.

### Unified Mode

Unified mode should continue to compose the primary server as a child process in
a PTY. It then connects to that child primary server over the same IPC protocol
used by standalone client mode.

This preserves one control path:

- Process lifecycle still belongs to primary mode.
- Client actions still travel through IPC.
- Signal commands still use the same IPC protocol.
- Unified mode gets terminal output by feeding the child primary PTY into
  `libghostty-vt`.

Avoiding an in-process unified server prevents two separate control paths from
drifting apart.

### Signal Commands

Signal commands remain short-lived IPC clients. They discover the socket from
the current config, send one command, wait for a response, print or report the
result, and exit.

## Parity Strategy

The Go implementation remains in-tree during migration as a reference oracle.
The Zig implementation should pass parity gates before replacing Go as the
default binary.

### Config Parity

Verify:

- Search order and `-f` override
- YAML parsing for active fields
- Defaults
- Dead-field warnings
- Config hash/socket path behavior
- Starter config generation intent

### Discovery Parity

Verify:

- Makefile target extraction regex
- Package manager detection order
- `package.json` script name validation
- Generated process names and fields
- Explicit process precedence over discovered processes

### Domain Parity

Verify:

- Process ordering and sequential IDs
- Status meanings
- Fuzzy filter ranking
- Category filter matching
- Running-only filtering
- Alpha and running-first sorting

### IPC Parity

Verify:

- Socket creation, lookup, probe, and wait behavior
- Message shapes
- Request/response correlation
- State broadcasts
- Command errors
- Redaction of process env values
- Peer UID checks on Linux and macOS
- Slow-client write timeout and dropped-update behavior

During migration, include interoperability tests:

- Go client to Zig server
- Zig client to Go server

These tests can be removed or quarantined after the final cutover, but they are
valuable while the protocol is being reimplemented.

### Process Parity

Verify:

- `shell` and `cmd` resolution
- Working directory handling
- Environment inheritance and overrides
- `add_path`
- PTY size
- Autostart
- Autofocus
- Stop signal and timeout
- SIGKILL escalation
- 500ms restart delay
- `on_kill` runs once for user-initiated stops
- Natural process exits do not run `on_kill`
- Quit stops all running processes

### TUI Parity

Verify behavior with a harness that drives key sequences and observes resulting
state, not by strict screenshots.

Coverage should include:

- Navigation and wraparound
- Start, stop, restart
- Live filter input
- Filter submit/cancel/toggle behavior
- Category search
- Running-only toggle
- Help toggle
- Docs action if active
- Message expiry
- Focus switching
- Split orientations
- Hide-list-when-unfocused behavior

### Terminal Validation

Unified terminal rendering is expected to improve because it uses
`libghostty-vt`. Validate manually and with focused automated tests where
possible:

- ANSI colors and styles
- Alternate screen apps
- Resize propagation
- Keyboard routing to the focused pane
- PTY EOF and child exit handling
- Large output without excessive CPU or memory use

## Migration Phases

### Phase 1: Repo And Build Foundation

Add the Zig project structure, vendored dependency strategy, target matrix,
build scripts, and a parity-test path that can build and invoke the Go
reference binary.

Outputs:

- Zig build skeleton
- Vendored dependency plan
- Target definitions for macOS/Linux amd64/arm64
- Go reference binary build path for tests only

### Phase 2: Config, Domain, And Discovery

Port config loading/defaults/hash, active schema validation, dead-field
warnings, process model, filtering/sorting, and process discovery.

Outputs:

- Config fixtures
- Golden tests
- Go-vs-Zig parity tests for deterministic pure logic

### Phase 3: IPC

Port Unix socket discovery, JSON-lines messages, client/server behavior,
request correlation, redaction, peer UID verification, timeouts, and
backpressure.

Outputs:

- IPC unit tests
- Go/Zig interoperability tests
- Signal-command protocol fixtures

### Phase 4: Process Controller And Ring Buffer

Port PTY process execution, command building, env/cwd handling, output
buffering, lifecycle operations, autostart/autofocus, `on_kill`, and viewer
semantics.

Outputs:

- Process lifecycle integration tests
- Ring buffer tests
- Viewer behavior tests

### Phase 5: Primary Mode And Signal Commands

Wire the Zig primary server and all `signal-*` commands through the new
modules.

Outputs:

- Headless primary mode
- Working signal commands
- Scripted end-to-end tests for process control

### Phase 6: Client TUI

Implement the process-list client using `libvaxis`.

Outputs:

- Client mode TUI
- TUI behavior harness tests
- Manual validation against a running primary

### Phase 7: Unified Mode With libghostty-vt

Vendor/pin Ghostty, build `libghostty-vt`, implement the terminal wrapper, and
compose unified mode.

Outputs:

- Unified left/right/top/bottom modes
- Focus and input routing
- Resize behavior
- Hide-list-when-unfocused behavior
- Manual terminal validation

### Phase 8: Cutover Hardening

Complete parity testing, release builds, documentation updates, and removal or
quarantine of Go deployment paths.

Outputs:

- Passing full parity suite
- Passing end-to-end scenarios
- macOS/Linux amd64/arm64 release artifacts
- Updated docs that describe Zig as the implementation
- Go retained only if still needed for historical reference tests

## Key Risks

### libghostty-vt API Churn

`libghostty-vt` is expected to evolve. Keep it vendored and pinned. Isolate all
Ghostty API usage inside `terminal`.

### Zig TUI Ecosystem Maturity

`libvaxis` should be validated early with a small process-list prototype. If it
cannot support required behavior, choose the next best Zig TUI option before
the main TUI implementation spreads framework assumptions.

### PTY And Signal Semantics

PTYs, process groups, signal delivery, and terminal resizing differ subtly by
platform. Add integration tests early on both macOS and Linux.

### Config Drift

Use active Go behavior and tests as the source of truth. Treat stale docs as
inputs to cleanup, not requirements.

### IPC Scope Creep

Do not replace JSON-lines IPC during the initial port. The protocol is simple,
debuggable, and an effective parity boundary.

### Hard Cutover

Because Go will not ship after cutover, release readiness depends on parity
evidence. The implementation plan should make every phase produce runnable,
testable behavior.

## Acceptance Criteria

- The Zig binary preserves the active CLI surface.
- Existing active config files continue to work.
- Dead/stale config fields produce warnings and no behavior.
- Primary, client, unified, and signal-command modes work on macOS/Linux
  amd64/arm64.
- IPC protocol compatibility is validated during migration.
- Process lifecycle behavior matches active Go behavior.
- TUI workflows match active Go behavior.
- Unified mode uses `libghostty-vt` for terminal emulation.
- Dependencies needed for release builds are vendored/pinned.
- Go build/distribution paths are removed or quarantined before final release.

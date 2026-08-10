# libghostty-vt Unified Rendering Design

Date: 2026-05-13

## Overview

Unified mode currently interprets terminal output bytes with an in-tree
renderer in `src/terminal/text.zig`. That makes proctmux responsible for a
domain it should not own: parsing and applying terminal escape/control
sequences for the embedded process output pane.

This design replaces that renderer with a hard dependency on a vendored,
minimal `libghostty-vt` subset. proctmux keeps ownership of its application
layout and process-management behavior, but delegates terminal byte
interpretation and terminal screen state to Ghostty code.

## Decisions

- Vendor only the minimal `libghostty-vt` subset under
  `third_party/libghostty-vt/`.
- Import the vendored Ghostty Zig modules directly from proctmux Zig code.
- Do not use the C API.
- Do not keep a fallback renderer.
- Delete `src/terminal/text.zig` after the Ghostty-backed path is working.
- Keep the existing proctmux unified split layout rather than adopting
  Ghostty application-level split behavior.

## Goals

- Remove proctmux-owned VT/ANSI/CSI/OSC interpretation for process output.
- Preserve unified-mode user behavior:
  - process list/output split panes
  - focus switching
  - hide-process-list-when-unfocused
  - output switching between processes
  - start/restart selected process output activation
  - cursor hiding during redraws
  - low-flicker frame repainting
- Keep the integration narrow enough that Ghostty API churn is contained to
  one proctmux wrapper module.
- Keep builds reproducible without requiring a system-installed Ghostty.

## Non-Goals

- Build or vendor the full Ghostty application.
- Reimplement Ghostty's app-level tabs, panes, or split tree.
- Add a compatibility fallback to the current in-tree renderer.
- Support a system-only libghostty installation path.
- Rework the process-list TUI renderer.

## Architecture

### Ownership Boundaries

proctmux continues to own:

- unified mode orchestration
- child primary process management
- process list rendering
- split sizing and orientation
- focus routing
- outer TUI repaint sequences

`libghostty-vt` owns:

- terminal control sequence parsing
- terminal cursor state
- terminal screen/alternate-screen state
- terminal resize/reflow behavior
- style/color state for process output

### New Wrapper Module

Add a narrow wrapper module:

```text
src/terminal/ghostty_vt.zig
```

The rest of proctmux must not import Ghostty modules directly. The wrapper API
should be shaped around proctmux's needs:

```zig
pub const Terminal = struct {
    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !Terminal;
    pub fn deinit(self: *Terminal) void;
    pub fn resize(self: *Terminal, cols: u16, rows: u16) !void;
    pub fn write(self: *Terminal, bytes: []const u8) !void;
    pub fn renderText(self: *Terminal, allocator: std.mem.Allocator) ![]const u8;
};
```

The exact internal Ghostty types are intentionally hidden. If Ghostty's Zig API
changes, proctmux should update this wrapper rather than spread direct imports
through unified mode.

### Data Flow

Production unified mode:

```text
child primary PTY
  -> ChildPrimary output capture
  -> Ghostty Terminal.write(new bytes)
  -> Ghostty terminal state
  -> Terminal.renderText()
  -> proctmux split composition
  -> outer terminal
```

In-process test unified mode:

```text
selected process scrollback bytes
  -> Ghostty Terminal.write(new bytes or full reset+replay)
  -> Ghostty terminal state
  -> Terminal.renderText()
  -> proctmux split composition
```

The production path must use incremental writes so each render frame feeds only
new child PTY bytes into Ghostty. The in-process test path may start with a
reset-and-replay implementation if that keeps the first integration simpler,
but production must not repeatedly replay the full scrollback indefinitely.

### Rendering Contract

`renderText()` returns the visible terminal pane content in a representation
that `src/unified/render.zig` can compose beside the process list.

Required behavior:

- Use Ghostty-provided screen/formatter APIs to extract display text and style.
- Preserve styled terminal output where Ghostty exposes style information.
- Keep any conversion from Ghostty display state to outer-terminal text inside
  `src/terminal/ghostty_vt.zig`.

The wrapper may emit ANSI SGR sequences to display Ghostty's styled cells in
the outer terminal, but it must not parse process-output escape sequences
itself. Parsing and terminal state transitions belong to Ghostty.

### Unified Renderer Changes

`src/unified/render.zig` should stop calling `terminal.text.render(...)`.

Instead, unified runtime state should own one Ghostty terminal instance for the
server/output pane and pass rendered output text into the existing split
composition functions.

The existing split code may continue to:

- fit left/right pane text to column widths
- clear line tails
- emit frame begin/end repaint sequences
- hide/show the outer terminal cursor

This outer TUI repainting is separate from interpreting process terminal
output and remains proctmux responsibility.

## Vendoring Plan

Add:

```text
third_party/libghostty-vt/
```

The vendored directory should include:

- the minimal Ghostty Zig modules needed for terminal state and formatting
- any small support modules required by those modules
- upstream license files
- a manifest recording:
  - upstream repository URL
  - upstream commit SHA
  - vendoring date
  - included paths
  - excluded paths

Avoid manually editing vendored source except for clearly documented build
patches. If patches are required, keep them isolated and listed in the vendor
manifest.

## Build Integration

Update:

- `build.zig.zon`
- `build.zig`
- `Makefile` only if direct `zig build-exe` module wiring needs another
  module path
- `flake.nix` if the vendored subset needs additional build tools

The build should fail if the Ghostty wrapper cannot compile. There should be
no "disable Ghostty" or "use old renderer" option.

## Deletions

Delete after Ghostty-backed rendering passes tests:

- `src/terminal/text.zig`
- terminal-text renderer exports from `src/terminal/root.zig`
- unit tests that assert proctmux-owned CSI/OSC/SGR interpretation

Replace those tests with wrapper-level behavior tests that exercise Ghostty
through the proctmux wrapper.

## Testing

### Unit Tests

Add tests around `src/terminal/ghostty_vt.zig` for:

- plain text output
- carriage return line replacement
- cursor movement
- clear screen
- erase line
- alternate-screen enter/exit
- styled output preservation, if exposed by the vendored Ghostty APIs
- resize behavior

These tests should feed bytes into `Terminal.write()` and assert rendered
visible output through `Terminal.renderText()`.

### Unified Tests

Keep the existing agent-tui e2e coverage:

- pane separation
- low repaint/flicker behavior
- hidden cursor during navigation/output
- running-to-running output switching
- running-to-stopped output switching
- never-run process placeholder
- exited process last output
- start/restart selected process activates output
- filtering and navigation

Add at least one e2e case with output that previously depended on the in-tree
terminal parser, such as carriage-return progress output or alternate-screen
output.

## Risks

- The Ghostty Zig API is unstable. This is accepted by design; the vendored
  subset and wrapper boundary contain the churn.
- Minimal vendoring may miss transitive Ghostty modules. The first
  implementation should expect an extraction pass to discover the true minimal
  subset.
- Ghostty's rendering data model may not map directly to proctmux's current
  text-based split composition. If so, the wrapper should still own the
  projection from Ghostty state into the text representation used by unified
  layout.
- If Ghostty requires broader runtime services than expected, the design may
  need to expand the vendored subset, but not to reintroduce a fallback parser.

## Acceptance Criteria

- `src/terminal/text.zig` is deleted.
- No production code parses process-output CSI/OSC/SGR/VT sequences in
  proctmux-owned modules.
- Unified mode output pane is backed by vendored `libghostty-vt`.
- The build has no non-Ghostty fallback path for terminal output rendering.
- `make test-zig` passes in the Nix dev shell.
- `make test-zig-e2e` passes in the Nix dev shell.
- Active docs describe `libghostty-vt` as the unified terminal rendering
  backend.

## References

- Ghostty repository: https://github.com/ghostty-org/ghostty
- libghostty generated docs: https://libghostty.tip.ghostty.org/
- Ghostling embedding example: https://github.com/ghostty-org/ghostling

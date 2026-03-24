# libghostty-vt Terminal Emulator Backend

**Date:** 2026-03-22
**Status:** Proposed
**Goal:** Add a second `terminal.Emulator` implementation backed by libghostty-vt via CGo, giving proctmux Ghostty-grade terminal emulation quality as a compile-time option.

---

## Problem

The current `charmbracelet/x/vt` emulator (`internal/terminal/charmvt/`) is pure Go and convenient, but is pre-release software with unknown VT compliance depth. For users running interactive programs (vim, htop, tmux) in the unified split pane, edge cases in escape sequence handling, scroll regions, or mouse protocols may cause misrendering.

libghostty-vt is the terminal emulation core extracted from Ghostty — a production terminal emulator used daily by thousands of developers. It handles every VT/xterm/ECMA-48 feature correctly, is SIMD-optimized, fuzz-tested, and battle-hardened. The Ghostling project (ghostty-org/ghostling) proves it can be consumed from C as a ~750 line integration, renderer-agnostic.

## Research Summary

### Ghostling architecture (proof of concept)

Ghostling is a single-file C program that:
1. Spawns a shell in a PTY via `forkpty()`
2. Feeds PTY output into `ghostty_terminal_vt_write()`
3. Snapshots terminal state via `ghostty_render_state_update()`
4. Iterates rows/cells with style data and draws with Raylib
5. Encodes keyboard/mouse input via `ghostty_key_encoder_encode()` / `ghostty_mouse_encoder_encode()` and writes to the PTY

It uses ~40 distinct `ghostty_*` API functions. The API follows a clean pattern: `_new/_free` lifecycle, `_get/_set` for properties, `_encode` for input. All types are opaque pointer-sized handles. No callbacks — poll-based, which fits Bubble Tea's model.

### Go -> CGo -> libghostty-vt feasibility

- **Static linking works.** `zig build -Demit-lib-vt -Dsimd=false` produces `libghostty-vt.a` with only libc as a dependency. Preserves Go's single-binary distribution.
- **CGo overhead is negligible.** ~50-100ns per call. `ghostty_terminal_vt_write` takes full buffers (4KB-64KB), so 1-2 CGo calls per PTY read.
- **Memory management is clean.** Pass `NULL` allocator (libc malloc/free). No Go pointers cross the boundary. `runtime.Pinner` not needed.
- **Thread safety.** Lock the terminal during `ghostty_render_state_update()` only. Reading from render state is safe while the terminal processes new data.
- **Precedent.** `kristoff-it/zig-cuckoofilter` has a working Go-CGo-Zig example. `yuuki/rpingmesh` is a production Go+Zig project.

## Design

### How it fits

The existing `terminal.Emulator` interface (`internal/terminal/emulator.go`) remains unchanged. A new `ghosttyvt` package implements it alongside the existing `charmvt` package:

```
terminal.Emulator interface
    |
    +--- internal/terminal/charmvt/    (pure Go, charmbracelet/x/vt)
    |
    +--- internal/terminal/ghosttyvt/  (CGo, libghostty-vt.a)
```

### How swapping works

In `cmd/proctmux/unified.go`, one import and one constructor call change:

```go
// Default: charmbracelet/x/vt (pure Go)
import "github.com/nick/proctmux/internal/terminal/charmvt"
emu := charmvt.New(80, 24)

// Alternative: libghostty-vt (CGo, Ghostty-grade)
// import "github.com/nick/proctmux/internal/terminal/ghosttyvt"
// emu, err := ghosttyvt.New(80, 24)
```

No build tags. No runtime config. Compile-time choice via import swap.

### New files

| File | Purpose |
|------|---------|
| `internal/terminal/ghosttyvt/emulator.go` | CGo wrapper implementing `terminal.Emulator` |
| `internal/terminal/ghosttyvt/lib/include/ghostty/` | C headers copied from `zig build -Demit-lib-vt` output |
| `internal/terminal/ghosttyvt/lib/darwin-arm64/libghostty-vt.a` | Pre-built static library for macOS arm64 |
| `internal/terminal/ghosttyvt/lib/darwin-amd64/libghostty-vt.a` | Pre-built static library for macOS amd64 |
| `internal/terminal/ghosttyvt/lib/linux-amd64/libghostty-vt.a` | Pre-built static library for Linux amd64 |
| `internal/terminal/ghosttyvt/lib/linux-arm64/libghostty-vt.a` | Pre-built static library for Linux arm64 |
| `scripts/build-libghostty.sh` | Script to rebuild `.a` files from Ghostty source |

### CGo bridge

```go
package ghosttyvt

/*
#cgo CFLAGS: -I${SRCDIR}/lib/include
#cgo darwin,arm64 LDFLAGS: ${SRCDIR}/lib/darwin-arm64/libghostty-vt.a -lc
#cgo darwin,amd64 LDFLAGS: ${SRCDIR}/lib/darwin-amd64/libghostty-vt.a -lc
#cgo linux,amd64 LDFLAGS: ${SRCDIR}/lib/linux-amd64/libghostty-vt.a -lm -lc
#cgo linux,arm64 LDFLAGS: ${SRCDIR}/lib/linux-arm64/libghostty-vt.a -lm -lc
#include <ghostty/vt.h>
#include <stdlib.h>
*/
import "C"

import (
    "fmt"
    "sync"
    "unsafe"

    "github.com/nick/proctmux/internal/terminal"
)

var _ terminal.Emulator = (*Emulator)(nil)

type Emulator struct {
    term   C.GhosttyTerminal
    closed bool
    mu     sync.Mutex
}
```

### API mapping

The formatter API is confirmed in Ghostty's C headers (`include/ghostty/vt/formatter.h`) and official examples (`example/c-vt-formatter/src/main.c`). Key functions:

- `ghostty_formatter_terminal_new(allocator, &formatter, terminal, opts)` — create formatter from terminal
- `ghostty_formatter_format_alloc(formatter, allocator, &buf, &len)` — format to allocated buffer
- `ghostty_formatter_free(formatter)` — cleanup

Setting `opts.emit = GHOSTTY_FORMATTER_FORMAT_VT` produces ANSI-styled output with colors, styles, and URLs encoded as escape codes.

| `terminal.Emulator` method | libghostty-vt calls |
|---|---|
| `New(cols, rows) (*Emulator, error)` | `ghostty_terminal_new` + `ghostty_render_state_new`. Returns error if any call returns non-`GHOSTTY_SUCCESS`. Note: the `terminal.Emulator` interface has no error in constructors; the error is handled at the call site in `unified.go`. |
| `Write(p []byte) (int, error)` | `ghostty_terminal_vt_write(term, buf, len)` — single CGo call per buffer |
| `Render() string` | Creates a formatter per call with `ghostty_formatter_terminal_new(NULL, &fmt, term, opts)` where `opts.emit = GHOSTTY_FORMATTER_FORMAT_VT`, then `ghostty_formatter_format_alloc(fmt, NULL, &buf, &len)`, converts to Go string, frees buf and formatter. |
| `Resize(cols, rows)` | `ghostty_terminal_resize(term, cols, rows)` |
| `Close()` | `ghostty_render_state_free` + `ghostty_terminal_free`. Idempotent: guards against double-free by nil-checking handles before freeing and zeroing them after. |

### Thread safety model

```
io.Copy goroutine:    Write(p) → mu.Lock → ghostty_terminal_vt_write → mu.Unlock
Bubble Tea poll tick:  Render() → mu.Lock → ghostty_formatter_terminal_new + format_alloc → mu.Unlock
```

The mutex serializes all access to the `GhosttyTerminal` handle. Both `Write()` and `Render()` hold the lock for the duration of their C calls. The formatter is created, used, and freed within a single `Render()` call (no state persists between frames). This is simple and correct — the 75ms polling interval means lock contention is minimal.

### Build script (`scripts/build-libghostty.sh`)

```bash
#!/usr/bin/env bash
# Builds libghostty-vt.a for all target platforms.
# Requires: zig 0.15.x, git
# Usage: ./scripts/build-libghostty.sh [ghostty-commit-hash]

set -euo pipefail

GHOSTTY_COMMIT="${1:-main}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../internal/terminal/ghosttyvt/lib"

# Clone/update ghostty
GHOSTTY_SRC="/tmp/ghostty-src"
if [ ! -d "$GHOSTTY_SRC" ]; then
    git clone --depth 1 https://github.com/ghostty-org/ghostty.git "$GHOSTTY_SRC"
fi
cd "$GHOSTTY_SRC"
git fetch origin "$GHOSTTY_COMMIT"
git checkout "$GHOSTTY_COMMIT"

# Build for each target
for target in aarch64-macos x86_64-macos aarch64-linux x86_64-linux; do
    echo "Building libghostty-vt for $target..."
    zig build -Demit-lib-vt -Dsimd=false -Dtarget="$target" --release=fast
    
    # Map zig target to our directory names
    case "$target" in
        aarch64-macos) dir="darwin-arm64" ;;
        x86_64-macos)  dir="darwin-amd64" ;;
        aarch64-linux) dir="linux-arm64" ;;
        x86_64-linux)  dir="linux-amd64" ;;
    esac
    
    mkdir -p "$OUT_DIR/$dir"
    cp zig-out/lib/libghostty-vt.a "$OUT_DIR/$dir/"
done

# Copy headers (same for all platforms)
mkdir -p "$OUT_DIR/include"
cp -r zig-out/include/ghostty "$OUT_DIR/include/"

echo "Done. Libraries and headers in $OUT_DIR"
```

### What this does NOT include

- **No key/mouse encoder wrappers.** Not needed — proctmux handles input via `keyMsgToTerminalInput()` writing ANSI sequences to the PTY. libghostty's encoders would be more correct (full Kitty protocol, all mouse formats), but that's a separate enhancement.
- **No build tag system.** Import swap is simpler and sufficient for now.
- **No runtime selection.** Compile-time choice only.
- **No Windows support.** macOS + Linux only.
- **No SIMD mode.** Built with `-Dsimd=false` to avoid C++ dependencies. Can be enabled later for performance.

### Testing

- Build with `make build` (CGo enabled by default) — verify the static library links correctly.
- Run existing test suite — verify no regressions.
- Manual testing in unified split mode:
  - Colored output (build logs, test runners)
  - Interactive programs (vim, htop, less)
  - Resize behavior
  - Alt screen (vim enter/exit)
  - Scroll regions
- Compare output side-by-side with `charmvt` to verify parity or improvement.

### Risks

| Risk | Mitigation |
|------|-----------|
| libghostty-vt API breaks | Pin to a specific Ghostty commit in the build script. Keep the wrapper thin. |
| Pre-built `.a` files are large | Static libs for a single-purpose VT library should be <5MB per platform. Use `.gitignore` and download script if too large for git. |
| CGo complicates cross-compilation | Pre-built libs for all 4 targets avoids needing Zig at compile time. Go cross-compilation with CGo works when the target `.a` is available. |
| Formatter API changes between Ghostty versions | Pin to a specific commit. The formatter API is confirmed in headers and official examples, so it's stable enough for now. Cell iteration is available as a fallback if the formatter is ever removed. |

### Future work

- **Key/mouse encoder integration.** Replace `keyMsgToTerminalInput()` with libghostty's encoders for full Kitty keyboard protocol and all mouse formats.
- **SIMD mode.** Rebuild with `-Dsimd=true` for faster VT parsing (adds C++ dependency).
- **Build tag selection.** If demand exists, add `//go:build ghostty` so `go build -tags ghostty` selects the backend automatically.
- **CI pipeline.** Automate `.a` rebuilds when Ghostty releases a new version.

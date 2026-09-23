# libghostty-vt Vendor Manifest

Vendored for proctmux unified-mode terminal output rendering.

## Upstream

- Repository: https://github.com/ghostty-org/ghostty
- Commit: `50d3ac8ed6ad1cbca498f7a4388ab14054a5c3e1`
- Ghostty app version: `1.3.2-dev`
- libghostty-vt version: `0.1.0-dev`
- Vendored date: 2026-08-19

## Included Source

- `LICENSE`
- `src/proctmux_vt.zig`
- Upstream Ghostty source files required to compile `src/proctmux_vt.zig`,
  `src/terminal/Terminal.zig`, `src/terminal/stream_terminal.zig`, terminal
  support modules, Unicode handling, and the Unicode table generators.

The vendored tree is intentionally rooted at `third_party/libghostty-vt/` even
where upstream support files keep their original relative paths. proctmux does
not import Ghostty directly from application code; the only production import
of the Zig package is through `src/terminal/ghostty_vt.zig`.

## Primary Upstream Areas

- `src/terminal/`
- `src/unicode/`
- `src/config/`
- `src/lib/`
- `src/datastruct/`
- `src/os/`
- `src/simd/`
- `src/build/`
- `src/fastmem.zig`
- `src/quirks.zig`
- `src/tripwire.zig`

Some additional upstream files may be present to preserve Ghostty's relative
import graph, but they are not a proctmux API surface.

## Excluded Responsibility

proctmux does not use Ghostty's application runtime, UI backends, renderer
backends, PTY runtime, shell integration, or C API as product features. Where a
file with one of those names exists in this vendored tree, it is present only
because the terminal library's upstream relative imports or tests require that
path to exist, or because it has been replaced by a local shim below.

## Transitive Dependency

`libghostty-vt` requires `uucode` for Unicode tables and grapheme handling.
proctmux vendors the exact dependency used by the pinned Ghostty revision:

- Path: `third_party/uucode/`
- Source: `https://deps.files.ghostty.org/uucode-2826a37a4562284fdacd8fa029d49509cc9bffcd.tar.gz`
- Zig package hash: `uucode-0.2.0-ZZjBPlK5VADj7fdoq7G8LIHzD5o6FSkcBXXrRWr4jnrA`

## Local Patches

- Added `src/proctmux_vt.zig` as a proctmux-specific module root. This file
  imports only the Ghostty terminal state APIs used by proctmux and avoids
  pulling in upstream `src/lib_vt.zig` public surfaces for input encoding, C
  exports, and wasm logging that are outside this integration.
- Replaced `src/build_config.zig`, `src/apprt.zig`, `src/renderer.zig`,
  `src/font/main.zig`, `src/global.zig`, `src/termio.zig`, and `src/pty.zig`
  with narrow lib-mode shims. These keep Ghostty terminal code compiling
  without linking Ghostty application, renderer, font backend, event loop, and
  PTY runtime implementations into proctmux.
- Replaced `src/cli.zig` with the argument/diagnostic subset needed by terminal
  configuration parsing, excluding application commands and crash reporting.
- Replaced `src/main_c.zig` with the `String` carrier needed transitively by
  config modules, excluding Ghostty's application C entry point.

Keep upstream vendored source unchanged unless a required build patch is
recorded in this section.

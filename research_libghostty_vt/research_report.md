# libghostty-vt Deep Technical Research Report

**Date**: March 19, 2026  
**Status**: Active development, C API available but unstable ("alpha")

---

## 1. Source Code & C API

### Repository Location
- **Repo**: https://github.com/ghostty-org/ghostty (MIT License, 47.7k stars)
- **Build file**: `src/build/GhosttyLibVt.zig` — the build definition for the library
- **C API headers**: `include/ghostty/vt/` directory
- **Examples**: `example/c-vt-formatter/`, `example/c-vt-encode-key/`, `example/c-vt-encode-mouse/`, `example/c-vt-paste/`, `example/c-vt-sgr/`, etc.

### Header Files (Complete List)
The main umbrella header is `include/ghostty/vt.h`, which includes:

| Header | Purpose |
|--------|---------|
| `vt/types.h` | Result codes (`GhosttyResult`), `GHOSTTY_INIT_SIZED` macro |
| `vt/allocator.h` | Custom allocator interface (Zig-style vtable) |
| `vt/terminal.h` | Terminal emulator state (create, write, resize, scroll, modes) |
| `vt/formatter.h` | Format terminal content as plain text, VT sequences, or HTML |
| `vt/osc.h` | OSC (Operating System Command) sequence parser |
| `vt/sgr.h` | SGR (Select Graphic Rendition) attribute parser |
| `vt/key.h` + `vt/key/encoder.h` + `vt/key/event.h` | Key event encoding (Kitty keyboard protocol) |
| `vt/mouse.h` + `vt/mouse/encoder.h` + `vt/mouse/event.h` | Mouse event encoding (X10, UTF-8, SGR, URxvt, SGR-Pixels) |
| `vt/focus.h` | Focus in/out event encoding |
| `vt/paste.h` | Paste safety validation |
| `vt/modes.h` | Terminal mode pack/unpack (ANSI + DEC private modes) |
| `vt/size_report.h` | Terminal size report encoding |
| `vt/color.h` | Color types (RGB, palette) |
| `vt/wasm.h` | WebAssembly convenience functions |

### Exported C API Function Signatures

**Terminal (terminal.h):**
```c
GhosttyResult ghostty_terminal_new(const GhosttyAllocator* allocator, GhosttyTerminal* terminal, GhosttyTerminalOptions options);
void ghostty_terminal_free(GhosttyTerminal terminal);
void ghostty_terminal_reset(GhosttyTerminal terminal);
GhosttyResult ghostty_terminal_resize(GhosttyTerminal terminal, uint16_t cols, uint16_t rows);
void ghostty_terminal_vt_write(GhosttyTerminal terminal, const uint8_t* data, size_t len);
void ghostty_terminal_scroll_viewport(GhosttyTerminal terminal, GhosttyTerminalScrollViewport behavior);
GhosttyResult ghostty_terminal_mode_get(GhosttyTerminal terminal, GhosttyMode mode, bool* out_value);
GhosttyResult ghostty_terminal_mode_set(GhosttyTerminal terminal, GhosttyMode mode, bool value);
```

**Formatter (formatter.h):**
```c
GhosttyResult ghostty_formatter_terminal_new(const GhosttyAllocator* allocator, GhosttyFormatter* formatter, GhosttyTerminal terminal, GhosttyFormatterTerminalOptions options);
GhosttyResult ghostty_formatter_format_buf(GhosttyFormatter formatter, uint8_t* buf, size_t buf_len, size_t* out_written);
GhosttyResult ghostty_formatter_format_alloc(GhosttyFormatter formatter, const GhosttyAllocator* allocator, uint8_t** out_ptr, size_t* out_len);
void ghostty_formatter_free(GhosttyFormatter formatter);
```

**OSC Parser (osc.h):**
```c
GhosttyResult ghostty_osc_new(const GhosttyAllocator *allocator, GhosttyOscParser *parser);
void ghostty_osc_free(GhosttyOscParser parser);
void ghostty_osc_reset(GhosttyOscParser parser);
void ghostty_osc_next(GhosttyOscParser parser, uint8_t byte);
GhosttyOscCommand ghostty_osc_end(GhosttyOscParser parser, uint8_t terminator);
GhosttyOscCommandType ghostty_osc_command_type(GhosttyOscCommand command);
bool ghostty_osc_command_data(GhosttyOscCommand command, GhosttyOscCommandData data, void *out);
```

**SGR Parser (sgr.h):**
```c
GhosttyResult ghostty_sgr_new(const GhosttyAllocator* allocator, GhosttySgrParser* parser);
void ghostty_sgr_free(GhosttySgrParser parser);
void ghostty_sgr_reset(GhosttySgrParser parser);
GhosttyResult ghostty_sgr_set_params(GhosttySgrParser parser, const uint16_t* params, const char* separators, size_t len);
bool ghostty_sgr_next(GhosttySgrParser parser, GhosttySgrAttribute* attr);
```

**Key Encoder (key/encoder.h):**
```c
GhosttyResult ghostty_key_encoder_new(const GhosttyAllocator *allocator, GhosttyKeyEncoder *encoder);
void ghostty_key_encoder_free(GhosttyKeyEncoder encoder);
void ghostty_key_encoder_setopt(GhosttyKeyEncoder encoder, GhosttyKeyEncoderOption option, const void *value);
void ghostty_key_encoder_setopt_from_terminal(GhosttyKeyEncoder encoder, GhosttyTerminal terminal);
GhosttyResult ghostty_key_encoder_encode(GhosttyKeyEncoder encoder, GhosttyKeyEvent event, char *out_buf, size_t out_buf_size, size_t *out_len);
```

**Mouse Encoder (mouse/encoder.h):**
```c
GhosttyResult ghostty_mouse_encoder_new(const GhosttyAllocator *allocator, GhosttyMouseEncoder *encoder);
void ghostty_mouse_encoder_free(GhosttyMouseEncoder encoder);
void ghostty_mouse_encoder_setopt(GhosttyMouseEncoder encoder, GhosttyMouseEncoderOption option, const void *value);
void ghostty_mouse_encoder_setopt_from_terminal(GhosttyMouseEncoder encoder, GhosttyTerminal terminal);
void ghostty_mouse_encoder_reset(GhosttyMouseEncoder encoder);
GhosttyResult ghostty_mouse_encoder_encode(GhosttyMouseEncoder encoder, GhosttyMouseEvent event, char *out_buf, size_t out_buf_size, size_t *out_len);
```

**Focus (focus.h):**
```c
GhosttyResult ghostty_focus_encode(GhosttyFocusEvent event, char* buf, size_t buf_len, size_t* out_written);
```

**Paste (paste.h):**
```c
bool ghostty_paste_is_safe(const char* data, size_t len);
```

**Modes (modes.h):**
```c
static inline GhosttyMode ghostty_mode_new(uint16_t value, bool ansi);
static inline uint16_t ghostty_mode_value(GhosttyMode mode);
static inline bool ghostty_mode_ansi(GhosttyMode mode);
GhosttyResult ghostty_mode_report_encode(GhosttyMode mode, GhosttyModeReportState state, char* buf, size_t buf_len, size_t* out_written);
```

**Size Report (size_report.h):**
```c
GhosttyResult ghostty_size_report_encode(GhosttySizeReportStyle style, GhosttySizeReportSize size, char* buf, size_t buf_len, size_t* out_written);
```

---

## 2. Blog Post & Official Documentation

### Primary Blog Post
**"Libghostty Is Coming"** — Mitchell Hashimoto, September 22, 2025
- URL: https://mitchellh.com/writing/libghostty-is-coming

### Key Points from the Blog:
1. **Vision**: An embeddable library for any app to embed a fully functional, modern, fast terminal emulator
2. **Zero dependencies** — does not even require libc
3. **C API** for maximum language interoperability
4. **API is NOT stable** — explicitly marked as alpha/WIP
5. **Timeline**: Mitchell hoped to ship a tagged version within ~6 months of Sept 2025 (so roughly Q1-Q2 2026). As of March 2026, the C API headers exist and have working examples, but the header still says "WARNING: This is an incomplete, work-in-progress API."
6. **Versioning**: libghostty will be versioned separately from Ghostty the application. Current version in build: `0.1.0`

### API Stability Status
From `vt.h`:
> "WARNING: This is an incomplete, work-in-progress API. It is not yet stable and is definitely going to change."

From `terminal.h`:
> `// TODO: Consider ABI compatibility implications of this struct.`

**The API uses a `GHOSTTY_INIT_SIZED` pattern** — sized structs with a `size` field as the first member for forward ABI compatibility. This is a good sign they're thinking about stability.

### Platform Targets
From the blog:
- **Initial**: macOS and Linux, both x86_64 and aarch64
- **Planned**: Windows, embedded devices, WebAssembly
- **Already working**: WASM target exists in `GhosttyLibVt.zig` with `initWasm()`

From the build system, the library already handles:
- **Darwin** (macOS) — with LLVM backend, dsymutil, headerpad
- **Android** (16kb page size support for Android 15+)
- **WASM** (executable with exported symbols, no entrypoint)
- **Linux** (implicit from shared library path)

### Longer-Term Roadmap (from blog)
Future `libghostty-<x>` libraries planned for:
- Input handling (keyboard encoding)
- GPU rendering (OpenGL/Metal surface)
- GTK widgets
- Swift frameworks for terminal views

---

## 3. Third-Party Usage & Bindings

### Confirmed Users

#### 1. Arbor (Rust) — `penso/arbor`
- **URL**: https://github.com/penso/arbor (366 stars, actively developed)
- **Description**: "Fully native app for agentic coding" with embedded terminals
- **Integration**: Uses libghostty-vt as an **experimental** terminal engine behind a feature flag `ghostty-vt-experimental`
- **How they do it**: 
  - They vendor Ghostty as a git submodule at `vendor/ghostty`
  - Build a Zig bridge library (`libarbor_ghostty_vt_bridge`) that wraps the Zig API
  - Call it from Rust via C FFI (`#[link(name = "arbor_ghostty_vt_bridge")]`)
  - Their FFI layer: `crates/arbor-terminal-emulator/src/ghostty_vt_experimental.rs`
  - Their Zig bridge: `scripts/ghostty-vt/arbor_build.zig`
- **They have benchmarks** comparing ghostty-vt vs alacritty emulator engine: `crates/arbor-benchmarks/benches/embedded_terminal.rs`

#### 2. OrbStack (Commercial)
- Mentioned in the blog post: "the Ghostty macOS app already consumes an internal-only C API... used by real commercial products already (OrbStack)"
- OrbStack uses the older internal `ghostty.h` API, not the new `libghostty-vt` API

#### 3. txtx/axel-app and yuuichieguchi/Calyx
- Both bundle `GhosttyKit.xcframework` with the vt.h headers, suggesting they use libghostty via Apple frameworks

### No Go Bindings Found
- **No Go wrapper exists on GitHub** as of this research
- No results for `ghostty_terminal_new` in Go code
- No results for `libghostty` in Go code
- **This is greenfield territory** for a Go binding

### No Python Bindings Found
### No standalone Rust crate wrapping libghostty-vt exists (Arbor vendors directly)

---

## 4. Technical Capabilities

### VT Features Supported

**Alt Screen Buffer**: YES  
Modes defined in `modes.h`:
- `GHOSTTY_MODE_ALT_SCREEN_LEGACY` (mode 47)
- `GHOSTTY_MODE_ALT_SCREEN` (mode 1047)
- `GHOSTTY_MODE_ALT_SCREEN_SAVE` (mode 1049 — alt screen + save cursor + clear)

**Mouse Events**: YES — Full support  
Mouse tracking modes:
- X10 (`GHOSTTY_MOUSE_TRACKING_X10`)
- Normal (button press/release)
- Button-event tracking
- Any-event tracking

Mouse output formats:
- X10, UTF-8, SGR, URxvt, SGR-Pixels

Mode definitions for all mouse modes: `GHOSTTY_MODE_X10_MOUSE` through `GHOSTTY_MODE_SGR_PIXELS_MOUSE`

**Scroll Regions**: YES  
- `GHOSTTY_MODE_LEFT_RIGHT_MARGIN` (mode 69) for DECSLRM
- Formatter has `scrolling_region` extra for emitting DECSTBM/DECSLRM
- Terminal supports viewport scrolling (top, bottom, delta)

**Kitty Graphics Protocol**: YES (conditional)  
- Full implementation in `src/terminal/kitty/graphics.zig`
- Includes: command parser, execution, rendering, image storage, unicode placeholders
- Build-time toggle: `kitty_graphics` option in `build_options.zig`
- Requires oniguruma dependency when enabled
- Note: some features still TODO (shared memory transmit, animation)

**Sixel**: NOT FOUND in search results — likely not supported yet or behind a flag

**Kitty Keyboard Protocol**: YES — Full support
- All flags: disambiguate, report events, report alternates, report all, report associated
- Encoder integrates with terminal mode state

**OSC Commands Supported** (from `osc.h` enum):
- Window title, window icon changes
- Semantic prompt
- Clipboard contents
- Report PWD
- Mouse shape
- Color operations
- Kitty color protocol
- Desktop notifications
- Hyperlinks (start/end)
- ConEmu extensions (sleep, message box, tab title, progress, etc.)
- Kitty text sizing

**SGR (Styling) Support**:
- Bold, italic, faint, blink, inverse, invisible, strikethrough
- Underline (single, double, curly, dotted, dashed)
- Underline color (RGB + 256-color)
- Overline
- Foreground/background: 8-color, 16-color (bright), 256-color, RGB direct color

**Additional Modes Defined** (from `modes.h`):
- Bracketed paste mode (2004)
- Synchronized output (2026)
- Grapheme cluster mode (2027)
- Color scheme reporting (2031)
- In-band size reports (2048)
- Focus events (1004)
- Origin mode, wraparound, reverse wrap
- Cursor visible/blinking

**SIMD Optimization**: YES  
- `simd` is a build option in `build_options.zig`
- Used in: stream parsing (`src/terminal/stream.zig`), base64 decoding for Kitty graphics, iTerm2 OSC parsing
- The blog confirms: "SIMD-optimized parsing"

**Tmux Control Mode**: Referenced in `build_options.zig` as requiring oniguruma

### Formatter Output Formats
- **Plain text** — no escape sequences
- **VT sequences** — preserving colors, styles, URLs, etc.
- **HTML** — with inline styles

The formatter can emit extra state:
- Cursor position, SGR style, hyperlinks, character protection
- Kitty keyboard protocol state, character set designations
- Palette (OSC 4), modes (CSI h/l), scrolling region, tabstops, PWD

---

## 5. Build System

### How to Build
From `build.zig`:
```bash
zig build lib-vt    # Build libghostty-vt specifically
```

This produces a **shared library** (`.so` on Linux, `.dylib` on macOS).

The build creates:
- `libghostty-vt.so` / `libghostty-vt.dylib` — shared library
- `libghostty-vt.dSYM` — debug symbols on macOS
- `libghostty-vt.pc` — pkg-config file
- Headers installed to `include/ghostty/`

### Build Variants
From `GhosttyLibVt.zig`:
1. **Shared library** (`initShared`) — `.dynamic` linkage, version 0.1.0
2. **WASM** (`initWasm`) — executable with `rdynamic`, no entrypoint

**No static library** (`initStatic`) variant found — only shared/dynamic and wasm.

### Dependencies
From the blog: **"zero-dependency library... It doesn't even require libc!"**

From `build_options.zig`:
- **SIMD**: Optional. "Pulls in more build-time dependencies and adds libc as a runtime dependency, but results in significant performance improvements."
- **Oniguruma**: Optional. Required for Kitty graphics and Tmux control mode.
- **Base**: Zero dependencies, no libc needed

So the dependency picture is:
- **Minimal build**: Zero deps, no libc
- **With SIMD**: Requires libc
- **With Kitty graphics/Tmux**: Requires oniguruma

### Cross-Compilation
Zig's build system inherently supports cross-compilation. The build file handles:
- macOS (Darwin) — with Apple SDK integration, LLVM backend
- Android — 16kb page size for Android 15+
- WASM — as an executable with exported symbols
- Linux — implicit

The Arbor project demonstrates cross-target building with `ARBOR_GHOSTTY_TARGET` / `ARBOR_GHOSTTY_CPU` environment variables.

### pkg-config Output
```
Name: libghostty-vt
URL: https://github.com/ghostty-org/ghostty
Description: Ghostty VT library
Version: 0.1.0
Cflags: -I${includedir}
Libs: -L${libdir} -lghostty-vt
```

---

## 6. Comparison to libvterm

### Direct Benchmarks
**No direct benchmarks found** comparing libghostty-vt to libvterm.

However, Arbor has benchmarks comparing ghostty-vt to Alacritty's terminal emulator (`alacritty_terminal` crate). Both `process_*` and `snapshot_*` benchmarks exist in `crates/arbor-benchmarks/benches/embedded_terminal.rs`.

### Feature Comparison: libghostty-vt vs libvterm

| Feature | libghostty-vt | libvterm |
|---------|--------------|----------|
| **Language** | Zig (with C API) | C |
| **SIMD Parsing** | YES (optional) | No |
| **Kitty Graphics** | YES (optional) | No |
| **Kitty Keyboard Protocol** | YES | No |
| **SGR-Pixels Mouse** | YES | No |
| **Grapheme Clusters (Unicode)** | YES (mode 2027) | Limited |
| **HTML Output** | YES (formatter) | No |
| **VT Output Formatter** | YES (plain, VT, HTML) | No built-in |
| **Synchronized Output (mode 2026)** | YES | No |
| **Bracketed Paste** | YES | YES |
| **Custom Allocator** | YES (Zig-style vtable) | No |
| **Zero libc dependency** | YES (without SIMD) | Requires libc |
| **WASM Support** | YES | No |
| **Android Support** | YES | Not designed for |
| **Sixel** | Not confirmed | YES |
| **OSC Support** | Extensive (23+ types) | Basic |
| **ConEmu Extensions** | YES | No |
| **pkg-config** | YES | YES |
| **API Stability** | Alpha/unstable | Stable |
| **Documentation** | Doxygen-style C headers | Man pages |

### Key Architectural Differences
1. **libghostty-vt** uses opaque handles (`GhosttyTerminal`, `GhosttyOscParser`, etc.) — all types are pointers to opaque structs
2. **libghostty-vt** separates concerns into dedicated sub-APIs (terminal, formatter, key encoder, mouse encoder, etc.)
3. **libvterm** is a more monolithic design with callbacks
4. **libghostty-vt** uses sized structs (`GHOSTTY_INIT_SIZED`) for forward ABI compatibility
5. **libghostty-vt** has the formatter concept — you can extract terminal state as plain text, VT codes, or HTML without implementing your own renderer

---

## 7. Investment Assessment

### Strengths (Invest)
- Battle-tested core from Ghostty (3+ years of real-world use, fuzzed, Valgrind-tested)
- Very clean, well-documented C API with Doxygen comments
- Modern feature set (Kitty graphics, Kitty keyboard, grapheme clusters, SIMD)
- Zero dependency option makes it ideal for embedding
- WASM support opens web use cases
- Mitchell Hashimoto's track record (HashiCorp founder) — serious engineering
- MIT license
- Active development (headers are recent additions)
- At least one real project (Arbor) already integrating it
- Working examples in C

### Risks (Wait)
- **API is explicitly unstable** — "WARNING: This is an incomplete, work-in-progress API. It is not yet stable and is definitely going to change."
- **No tagged release yet** — blog said "within 6 months" of Sept 2025, now at month 6
- **No Go bindings exist** — you'd be writing the first
- **No static library target** currently — only shared/dynamic and wasm
- **Terminal struct has a TODO** about ABI compatibility: "Consider ABI compatibility implications of this struct"
- **No callback API yet** for output sequences — `ghostty_terminal_vt_write` is read-only: "sequences that require output (queries) are ignored. In the future, a callback-based API will be added"
- **Sixel not confirmed** — if you need sixel, this may not have it yet
- **Zig build system required** — consumers need Zig toolchain to build from source

### Verdict
**Worth starting experimental work now, not worth production dependency yet.**

The C API is real, working, and well-designed. The core is proven. But the API will break, there's no callback mechanism for terminal queries yet, and there are no prebuilt binaries or tagged releases. For a Go wrapper in proctmux, you could start prototyping against the current API, but plan for API churn. The "first mover" advantage of being the first Go bindings is real — no one has done it yet.

**Recommendation**: Start with a proof-of-concept Go binding targeting the formatter API (create terminal -> write VT data -> format as plain text). This is the most immediately useful subset for a process multiplexer and exercises the core API surface. Wait for a tagged release before committing to production use.

# Technical Assessment: Calling libghostty-vt (Zig) from Go via CGo

## Executive Summary

Calling a Zig-built C-ABI shared/static library from Go via CGo is **well-supported and practical**. The key finding is that **libghostty-vt produces both static (.a) and shared (.so/.dylib) libraries** via `zig build -Demit-lib-vt`, which means static linking into the Go binary is the recommended path for distribution simplicity.

---

## 1. CGo Basics for Shared/Static Libraries

### How CGo Links to External Libraries

CGo uses special comment directives immediately before `import "C"` to configure the C compiler and linker. The Go toolchain invokes the system C compiler (gcc/clang) to compile C code and link against external libraries.

### Minimal Example: Go Source File for libghostty-vt

```go
package vt

/*
#cgo CFLAGS: -I${SRCDIR}/ghostty/zig-out/include
#cgo LDFLAGS: -L${SRCDIR}/ghostty/zig-out/lib -lghostty-vt

#cgo noescape ghostty_terminal_vt_write
#cgo nocallback ghostty_terminal_vt_write
#cgo noescape ghostty_terminal_new
#cgo nocallback ghostty_terminal_new
#cgo noescape ghostty_terminal_free
#cgo nocallback ghostty_terminal_free
#cgo noescape ghostty_formatter_terminal_new
#cgo nocallback ghostty_formatter_terminal_new
#cgo noescape ghostty_formatter_format_alloc
#cgo nocallback ghostty_formatter_format_alloc
#cgo noescape ghostty_formatter_free
#cgo nocallback ghostty_formatter_free

#include <ghostty/vt.h>
#include <stdlib.h>
*/
import "C"

import (
    "fmt"
    "unsafe"
)

// Terminal wraps a ghostty terminal instance.
type Terminal struct {
    handle C.GhosttyTerminal
}

// NewTerminal creates a new terminal with the given dimensions.
func NewTerminal(cols, rows uint16, maxScrollback int) (*Terminal, error) {
    opts := C.GhosttyTerminalOptions{
        cols:           C.uint16_t(cols),
        rows:           C.uint16_t(rows),
        max_scrollback: C.size_t(maxScrollback),
    }

    var handle C.GhosttyTerminal
    result := C.ghostty_terminal_new(nil, &handle, opts)
    if result != C.GHOSTTY_SUCCESS {
        return nil, fmt.Errorf("ghostty_terminal_new failed: %d", result)
    }

    return &Terminal{handle: handle}, nil
}

// Write feeds VT-encoded data into the terminal.
func (t *Terminal) Write(data []byte) {
    if len(data) == 0 {
        return
    }
    C.ghostty_terminal_vt_write(
        t.handle,
        (*C.uint8_t)(unsafe.Pointer(&data[0])),
        C.size_t(len(data)),
    )
}

// Close frees the terminal instance.
func (t *Terminal) Close() {
    if t.handle != nil {
        C.ghostty_terminal_free(t.handle)
        t.handle = nil
    }
}

// RenderPlainText formats the terminal contents as plain text.
func (t *Terminal) RenderPlainText() (string, error) {
    // Use GHOSTTY_INIT_SIZED equivalent - zero-initialize and set size
    var fmtOpts C.GhosttyFormatterTerminalOptions
    fmtOpts.size = C.sizeof_GhosttyFormatterTerminalOptions
    fmtOpts.emit = C.GHOSTTY_FORMATTER_FORMAT_PLAIN
    fmtOpts.trim = C.bool(true)

    var formatter C.GhosttyFormatter
    result := C.ghostty_formatter_terminal_new(nil, &formatter, t.handle, fmtOpts)
    if result != C.GHOSTTY_SUCCESS {
        return "", fmt.Errorf("ghostty_formatter_terminal_new failed: %d", result)
    }
    defer C.ghostty_formatter_free(formatter)

    var buf *C.uint8_t
    var length C.size_t
    result = C.ghostty_formatter_format_alloc(formatter, nil, &buf, &length)
    if result != C.GHOSTTY_SUCCESS {
        return "", fmt.Errorf("ghostty_formatter_format_alloc failed: %d", result)
    }
    defer C.free(unsafe.Pointer(buf))

    return C.GoStringN((*C.char)(unsafe.Pointer(buf)), C.int(length)), nil
}
```

### Key CGo Directives

| Directive | Purpose |
|-----------|---------|
| `#cgo CFLAGS: -I<path>` | Header include path |
| `#cgo LDFLAGS: -L<path> -l<lib>` | Library search path and link target |
| `${SRCDIR}` | Expands to absolute path of the Go source file's directory |
| `#cgo noescape <func>` | Tells compiler Go pointers don't escape through this C function (Go 1.22+) |
| `#cgo nocallback <func>` | Tells compiler this C function never calls back into Go (Go 1.22+) |
| `#cgo darwin LDFLAGS:` | Platform-conditional flags |
| `#cgo linux LDFLAGS:` | Platform-conditional flags |

### Platform-Specific Flag Example

```go
/*
#cgo CFLAGS: -I${SRCDIR}/ghostty/zig-out/include
#cgo darwin LDFLAGS: -L${SRCDIR}/ghostty/zig-out/lib -lghostty-vt
#cgo linux LDFLAGS: -L${SRCDIR}/ghostty/zig-out/lib -lghostty-vt -lm
*/
import "C"
```

---

## 2. Real-World Go + Zig Projects

### kristoff-it/zig-cuckoofilter (Direct Example)

**Source:** https://github.com/kristoff-it/zig-cuckoofilter/blob/master/c-abi-examples/go_example.go

This is the canonical example of Go calling a Zig library via CGo. Key patterns:

```go
/*
#cgo CFLAGS: -I ../
#cgo LDFLAGS: -L ../ -l cuckoofilter_c.0.0.0
#include <stdint.h>
#include "cuckoofilter_c.h"
*/
import "C"

func main() {
    cf8 := C.struct_Filter8{}
    memory := make([]C.uint8_t, 1024)
    err := C.cf_init8(&memory[0], 1024, &cf8)
    // ...
}
```

**Important note from this project:** On macOS, Zig-produced dylibs sometimes don't work directly with `ld`. The workaround was:
```bash
zig build-obj --release-fast src/cuckoofilter_c.zig
gcc -dynamiclib -o libcuckoofilter_c.0.0.0.dylib cuckoofilter_c.o
```

However, this issue is from an older Zig version. Modern `zig build` with proper build.zig (as ghostty uses) produces correct dylibs.

### Zig as Cross-Compilation CC for CGo

A very common pattern (found in 10+ production projects) is using `zig cc` as the CC for Go cross-compilation:

```makefile
# From nkanaev/yarr, keygen-sh/keygen-relay, timelinize, etc.
CGO_ENABLED=1 GOOS=linux GOARCH=amd64 \
    CC="zig cc -target x86_64-linux-musl" \
    go build -o myapp ./cmd

CGO_ENABLED=1 GOOS=linux GOARCH=arm64 \
    CC="zig cc -target aarch64-linux-musl" \
    go build -o myapp ./cmd

CGO_ENABLED=1 GOOS=windows GOARCH=amd64 \
    CC="zig cc -target x86_64-windows-gnu" \
    go build -o myapp ./cmd
```

This is relevant because it means Zig's toolchain is already proven to work with Go's CGo pipeline.

### fluent/fluent-bit (WAMR Go bindings - Pre-built Library Pattern)

**Source:** https://github.com/fluent/fluent-bit (wasm-micro-runtime Go bindings)

Shows the pattern of distributing pre-built libraries per platform:

```go
// #cgo CFLAGS: -I${SRCDIR}/packaged/include
// #cgo LDFLAGS: -lvmlib -lm
//
// #cgo linux,amd64 LDFLAGS: -Wl,-rpath,${SRCDIR}/packaged/lib/linux-amd64 -L${SRCDIR}/packaged/lib/linux-amd64
// #cgo linux,arm64 LDFLAGS: -Wl,-rpath,${SRCDIR}/packaged/lib/linux-aarch64 -L${SRCDIR}/packaged/lib/linux-aarch64
// #cgo darwin,amd64 LDFLAGS: -Wl,-rpath,${SRCDIR}/packaged/lib/darwin-amd64 -L${SRCDIR}/packaged/lib/darwin-amd64
// #cgo darwin,arm64 LDFLAGS: -Wl,-rpath,${SRCDIR}/packaged/lib/darwin-aarch64 -L${SRCDIR}/packaged/lib/darwin-aarch64
//
// #include <wasm_export.h>
import "C"
```

---

## 3. Build System Integration

### Option A: Pre-Build with `go generate` (Recommended)

```go
//go:generate sh -c "cd ghostty && zig build lib-vt -Doptimize=ReleaseFast"
package vt
```

Or with a Makefile target:

```makefile
.PHONY: ghostty-vt
ghostty-vt:
	cd ghostty && zig build lib-vt -Doptimize=ReleaseFast

build: ghostty-vt
	go build -o bin/proctmux ./cmd/proctmux
```

### Option B: Pre-Built Binary Artifacts (Best for Distribution)

Build the library for each platform in CI, commit or release the artifacts:

```
internal/vt/lib/
├── darwin-arm64/
│   ├── libghostty-vt.a
│   └── libghostty-vt.dylib
├── darwin-amd64/
│   ├── libghostty-vt.a
│   └── libghostty-vt.dylib
├── linux-amd64/
│   ├── libghostty-vt.a
│   └── libghostty-vt.so
├── linux-arm64/
│   ├── libghostty-vt.a
│   └── libghostty-vt.so
└── include/
    └── ghostty/
        └── vt/
            ├── vt.h
            ├── terminal.h
            ├── formatter.h
            └── ...
```

### Option C: Git Submodule + Build on Demand

```makefile
ghostty:
	git submodule update --init --recursive

ghostty-vt: ghostty
	cd ghostty && zig build lib-vt -Doptimize=ReleaseFast
```

### Cross-Compilation

Zig's cross-compilation is excellent. libghostty-vt can be built for any target:

```bash
# Build libghostty-vt for Linux ARM64 from macOS
cd ghostty && zig build lib-vt -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast
```

For the Go side, using `zig cc` as the C compiler enables cross-compilation:

```bash
CGO_ENABLED=1 GOOS=linux GOARCH=arm64 \
    CC="zig cc -target aarch64-linux-musl" \
    CGO_CFLAGS="-Ighostty/zig-out/include" \
    CGO_LDFLAGS="-Lghostty/zig-out/lib -lghostty-vt" \
    go build ./cmd/proctmux
```

---

## 4. Memory Management Across the Boundary

### The Rules

1. **Go GC does NOT manage C-allocated memory.** Any memory allocated by C/Zig (malloc, Zig allocators) must be freed by C/Zig.
2. **C code must NOT hold Go pointers past the function call** unless they are pinned with `runtime.Pinner`.
3. **Passing Go slices to C is safe** for the duration of a CGo call -- the Go runtime pins function arguments automatically.

### libghostty-vt Memory Model

libghostty-vt has a clean ownership model:

| Function | Memory Owner | How to Free |
|----------|-------------|-------------|
| `ghostty_terminal_new` | Library (Zig allocator) | `ghostty_terminal_free` |
| `ghostty_terminal_vt_write` | Caller passes buffer, library copies what it needs | No cleanup needed |
| `ghostty_formatter_terminal_new` | Library (Zig allocator) | `ghostty_formatter_free` |
| `ghostty_formatter_format_alloc` | Library allocates output buffer | `free()` (default allocator uses libc) |
| `ghostty_formatter_format_buf` | Caller provides buffer | No cleanup needed |

### Passing Go Data to C

```go
// SAFE: Go slice data is pinned for duration of CGo call
func (t *Terminal) Write(data []byte) {
    if len(data) == 0 {
        return
    }
    // &data[0] is a Go pointer, but it's pinned as a function argument
    C.ghostty_terminal_vt_write(
        t.handle,
        (*C.uint8_t)(unsafe.Pointer(&data[0])),
        C.size_t(len(data)),
    )
}
```

### Receiving C-Allocated Memory

```go
// ghostty_formatter_format_alloc allocates via the library's allocator
// With NULL allocator, it uses libc malloc, so free with C.free
var buf *C.uint8_t
var length C.size_t
result := C.ghostty_formatter_format_alloc(formatter, nil, &buf, &length)
// ... use buf ...
C.free(unsafe.Pointer(buf))  // MUST free with C.free
```

### runtime.Pinner (Go 1.21+)

Only needed if C code needs to hold a Go pointer beyond a single call. **For libghostty-vt, this is NOT needed** because:
- `ghostty_terminal_vt_write` copies/processes data during the call
- The terminal handle is a C pointer (Zig-allocated), not a Go pointer
- No callbacks from C back to Go are needed (yet)

If callbacks were needed in the future:

```go
var pinner runtime.Pinner
goObj := &myState{}
pinner.Pin(goObj)
defer pinner.Unpin()
// Now safe to store goObj's pointer in C memory
C.some_func_that_stores_pointer(unsafe.Pointer(goObj))
```

### Custom Allocator Consideration

libghostty-vt supports custom allocators via `GhosttyAllocator`. For the Go integration, **pass NULL** (default allocator) which uses libc malloc/free. This is simplest and means:
- Memory returned by `ghostty_formatter_format_alloc` can be freed with `C.free()`
- No need to implement the Zig allocator interface in Go

---

## 5. Concurrency Concerns

### CGo Call Overhead

**Each CGo call costs approximately 50-100 nanoseconds** (compared to ~2ns for a Go function call). This is due to:

1. The Go runtime must save goroutine state
2. Switch from a goroutine stack to a system thread stack  
3. The C function runs on the OS thread stack
4. On return, switch back to the goroutine stack

### Goroutine Blocking

**A CGo call blocks the OS thread**, not just the goroutine. The Go scheduler will spin up additional OS threads to keep other goroutines running (up to `GOMAXPROCS`), but excessive blocking CGo calls can exhaust the thread pool.

For libghostty-vt:
- `ghostty_terminal_vt_write`: Fast, processes VT sequences in-memory. Should take microseconds for typical writes.
- `ghostty_formatter_format_alloc`: Traverses terminal grid, allocates output. Could take longer for large terminals.
- `ghostty_terminal_new`: One-time setup, not a concern.

### Optimization Directives (Go 1.22+)

```go
// #cgo noescape ghostty_terminal_vt_write
// #cgo nocallback ghostty_terminal_vt_write
```

- `noescape`: Tells the compiler that Go pointers passed to this C function don't escape. Avoids unnecessary heap allocations.
- `nocallback`: Tells the compiler this C function never calls back into Go. Avoids setting up the callback infrastructure.

**Both should be used for ALL ghostty functions** since the library never calls back into Go and never retains Go pointers.

### Batching Strategy

**YES, batch calls.** Instead of writing byte-by-byte:

```go
// BAD: 50-100ns overhead per byte
for _, b := range data {
    C.ghostty_terminal_vt_write(t.handle, (*C.uint8_t)(&b), 1)
}

// GOOD: One CGo call for the entire buffer
C.ghostty_terminal_vt_write(
    t.handle,
    (*C.uint8_t)(unsafe.Pointer(&data[0])),
    C.size_t(len(data)),
)
```

For the formatter, prefer `ghostty_formatter_format_buf` (caller provides buffer) over `ghostty_formatter_format_alloc` (library allocates) to avoid cross-boundary allocation:

```go
// Reuse a Go-allocated buffer across calls
buf := make([]byte, 64*1024) // 64KB buffer
var written C.size_t
result := C.ghostty_formatter_format_buf(
    formatter,
    (*C.uint8_t)(unsafe.Pointer(&buf[0])),
    C.size_t(len(buf)),
    &written,
)
if result == C.GHOSTTY_OUT_OF_SPACE {
    // Retry with larger buffer using 'written' as required size
    buf = make([]byte, written)
    // ...
}
```

---

## 6. Distribution

### Static Linking (Recommended)

**libghostty-vt produces a static library** (`libghostty-vt.a`). Use it:

```go
/*
#cgo CFLAGS: -I${SRCDIR}/lib/include
#cgo darwin,arm64 LDFLAGS: ${SRCDIR}/lib/darwin-arm64/libghostty-vt.a
#cgo darwin,amd64 LDFLAGS: ${SRCDIR}/lib/darwin-amd64/libghostty-vt.a
#cgo linux,amd64 LDFLAGS: ${SRCDIR}/lib/linux-amd64/libghostty-vt.a -lm
#cgo linux,arm64 LDFLAGS: ${SRCDIR}/lib/linux-arm64/libghostty-vt.a -lm
*/
import "C"
```

With static linking:
- **Single binary distribution** (Go's key advantage preserved)
- No need to ship .so/.dylib alongside the binary
- No `LD_LIBRARY_PATH` or `@rpath` issues
- No version mismatch problems

### Static Library Dependencies

From the ghostty CMakeLists.txt:

> When linking the static library, consumers must also link its transitive dependencies. By default (with SIMD enabled), these are:
> - libc
> - libc++ (or libstdc++ on Linux)  
> - highway
> - simdutf
>
> Building with `-Dsimd=false` removes the C++ / highway / simdutf dependencies, leaving only libc.

**Recommendation:** Build with `-Dsimd=false` for simpler static linking from Go:

```bash
zig build lib-vt -Doptimize=ReleaseFast -Dsimd=false
```

This eliminates C++ runtime dependencies, leaving only libc (which Go already links).

### Dynamic Linking (If Needed)

If you must use dynamic linking:

```go
// Set rpath so the binary finds the library relative to itself
#cgo linux LDFLAGS: -Wl,-rpath,'$ORIGIN/lib' -L${SRCDIR}/lib/linux-amd64 -lghostty-vt
#cgo darwin LDFLAGS: -Wl,-rpath,@executable_path/lib -L${SRCDIR}/lib/darwin-arm64 -lghostty-vt
```

Then distribute:
```
proctmux
lib/
  libghostty-vt.so.0.1.0  (Linux)
  libghostty-vt.dylib      (macOS)
```

### Platform Matrix

| Platform | Shared Lib | Static Lib | Notes |
|----------|-----------|-----------|-------|
| macOS arm64 | `.dylib` | `.a` | Need to handle @rpath for shared |
| macOS amd64 | `.dylib` | `.a` | Same |
| Linux amd64 | `.so` | `.a` | May need `-lm` for math |
| Linux arm64 | `.so` | `.a` | Same |
| Windows amd64 | `.dll` | `.lib` | Need import library for dll |

---

## 7. Specific libghostty-vt Integration Design

### Recommended Package Layout

```
proctmux/
├── internal/
│   └── ghostty/
│       ├── ghostty.go          // CGo bridge, Terminal type
│       ├── formatter.go        // Formatter wrapper
│       ├── ghostty_test.go     // Tests
│       ├── lib/
│       │   ├── include/
│       │   │   └── ghostty/
│       │   │       └── vt/     // Headers from zig-out/include
│       │   ├── darwin-arm64/
│       │   │   └── libghostty-vt.a
│       │   ├── linux-amd64/
│       │   │   └── libghostty-vt.a
│       │   └── ...
│       └── generate.go         // go:generate for building library
```

### Complete Bridge Implementation

```go
// internal/ghostty/ghostty.go
package ghostty

/*
#cgo CFLAGS: -I${SRCDIR}/lib/include

// Static linking per platform
#cgo darwin,arm64 LDFLAGS: ${SRCDIR}/lib/darwin-arm64/libghostty-vt.a -lc
#cgo darwin,amd64 LDFLAGS: ${SRCDIR}/lib/darwin-amd64/libghostty-vt.a -lc
#cgo linux,amd64 LDFLAGS: ${SRCDIR}/lib/linux-amd64/libghostty-vt.a -lm -lc
#cgo linux,arm64 LDFLAGS: ${SRCDIR}/lib/linux-arm64/libghostty-vt.a -lm -lc

// Performance hints - these functions never call back to Go and never retain Go pointers
#cgo noescape ghostty_terminal_new
#cgo nocallback ghostty_terminal_new
#cgo noescape ghostty_terminal_free
#cgo nocallback ghostty_terminal_free
#cgo noescape ghostty_terminal_vt_write
#cgo nocallback ghostty_terminal_vt_write
#cgo noescape ghostty_terminal_resize
#cgo nocallback ghostty_terminal_resize
#cgo noescape ghostty_terminal_get
#cgo nocallback ghostty_terminal_get
#cgo noescape ghostty_formatter_terminal_new
#cgo nocallback ghostty_formatter_terminal_new
#cgo noescape ghostty_formatter_format_buf
#cgo nocallback ghostty_formatter_format_buf
#cgo noescape ghostty_formatter_format_alloc
#cgo nocallback ghostty_formatter_format_alloc
#cgo noescape ghostty_formatter_free
#cgo nocallback ghostty_formatter_free

#include <ghostty/vt.h>
#include <stdlib.h>
*/
import "C"

import (
    "errors"
    "fmt"
    "runtime"
    "unsafe"
)

var (
    ErrTerminalCreate   = errors.New("failed to create terminal")
    ErrFormatterCreate  = errors.New("failed to create formatter")
    ErrFormat           = errors.New("failed to format terminal")
    ErrResize           = errors.New("failed to resize terminal")
    ErrOutOfSpace       = errors.New("buffer too small")
)

func ghosttyError(result C.GhosttyResult, base error) error {
    if result == C.GHOSTTY_SUCCESS {
        return nil
    }
    return fmt.Errorf("%w: error code %d", base, result)
}

// Terminal wraps a ghostty terminal emulator instance.
type Terminal struct {
    handle C.GhosttyTerminal
}

// NewTerminal creates a new virtual terminal with the given dimensions.
func NewTerminal(cols, rows uint16, maxScrollback int) (*Terminal, error) {
    opts := C.GhosttyTerminalOptions{
        cols:           C.uint16_t(cols),
        rows:           C.uint16_t(rows),
        max_scrollback: C.size_t(maxScrollback),
    }

    var handle C.GhosttyTerminal
    result := C.ghostty_terminal_new(nil, &handle, opts)
    if err := ghosttyError(result, ErrTerminalCreate); err != nil {
        return nil, err
    }

    t := &Terminal{handle: handle}
    runtime.SetFinalizer(t, (*Terminal).Close)
    return t, nil
}

// Write feeds VT-encoded data into the terminal for processing.
// This is safe to call with any data; malformed sequences are handled gracefully.
func (t *Terminal) Write(data []byte) (int, error) {
    if len(data) == 0 {
        return 0, nil
    }
    C.ghostty_terminal_vt_write(
        t.handle,
        (*C.uint8_t)(unsafe.Pointer(&data[0])),
        C.size_t(len(data)),
    )
    return len(data), nil
}

// Resize changes the terminal dimensions.
func (t *Terminal) Resize(cols, rows uint16) error {
    result := C.ghostty_terminal_resize(t.handle, C.uint16_t(cols), C.uint16_t(rows))
    return ghosttyError(result, ErrResize)
}

// Close frees the terminal and all associated resources.
func (t *Terminal) Close() {
    if t.handle != nil {
        C.ghostty_terminal_free(t.handle)
        t.handle = nil
        runtime.SetFinalizer(t, nil)
    }
}

// Format specifies the output format for rendering.
type Format int

const (
    FormatPlain Format = iota
    FormatVT
    FormatHTML
)

// RenderOptions controls how terminal content is rendered.
type RenderOptions struct {
    Format Format
    Trim   bool
    Unwrap bool
}

// Render formats the current terminal screen contents.
func (t *Terminal) Render(opts RenderOptions) ([]byte, error) {
    var fmtOpts C.GhosttyFormatterTerminalOptions
    fmtOpts.size = C.sizeof_GhosttyFormatterTerminalOptions
    fmtOpts.trim = C._Bool(opts.Trim)
    fmtOpts.unwrap = C._Bool(opts.Unwrap)

    switch opts.Format {
    case FormatPlain:
        fmtOpts.emit = C.GHOSTTY_FORMATTER_FORMAT_PLAIN
    case FormatVT:
        fmtOpts.emit = C.GHOSTTY_FORMATTER_FORMAT_VT
    case FormatHTML:
        fmtOpts.emit = C.GHOSTTY_FORMATTER_FORMAT_HTML
    }

    var formatter C.GhosttyFormatter
    result := C.ghostty_formatter_terminal_new(nil, &formatter, t.handle, fmtOpts)
    if err := ghosttyError(result, ErrFormatterCreate); err != nil {
        return nil, err
    }
    defer C.ghostty_formatter_free(formatter)

    // Use format_alloc for simplicity (library allocates the buffer)
    var buf *C.uint8_t
    var length C.size_t
    result = C.ghostty_formatter_format_alloc(formatter, nil, &buf, &length)
    if err := ghosttyError(result, ErrFormat); err != nil {
        return nil, err
    }
    defer C.free(unsafe.Pointer(buf))

    // Copy to Go-managed memory
    return C.GoBytes(unsafe.Pointer(buf), C.int(length)), nil
}

// CursorPosition returns the current cursor column and row (0-indexed).
func (t *Terminal) CursorPosition() (col, row uint16) {
    var x, y C.uint16_t
    C.ghostty_terminal_get(t.handle, C.GHOSTTY_TERMINAL_DATA_CURSOR_X, unsafe.Pointer(&x))
    C.ghostty_terminal_get(t.handle, C.GHOSTTY_TERMINAL_DATA_CURSOR_Y, unsafe.Pointer(&y))
    return uint16(x), uint16(y)
}
```

### Build Script

```makefile
# Makefile additions for proctmux

GHOSTTY_DIR ?= ghostty
GHOSTTY_ZIG_OUT = $(GHOSTTY_DIR)/zig-out
GHOSTTY_FLAGS = -Doptimize=ReleaseFast -Dsimd=false

.PHONY: ghostty-vt
ghostty-vt:
	cd $(GHOSTTY_DIR) && zig build lib-vt $(GHOSTTY_FLAGS)

.PHONY: ghostty-vt-install
ghostty-vt-install: ghostty-vt
	@mkdir -p internal/ghostty/lib/include
	@cp -r $(GHOSTTY_ZIG_OUT)/include/ghostty internal/ghostty/lib/include/
	@# Detect current platform and copy the right library
	@PLATFORM=$$(go env GOOS)-$$(go env GOARCH); \
	mkdir -p internal/ghostty/lib/$$PLATFORM; \
	cp $(GHOSTTY_ZIG_OUT)/lib/libghostty-vt.a internal/ghostty/lib/$$PLATFORM/

build: ghostty-vt-install
	go build -o bin/proctmux ./cmd/proctmux
```

---

## 8. Risk Assessment and Recommendations

### Low Risk
- **CGo bridging works**: Zig's C-ABI compatibility is excellent. The cuckoo filter example proves the pattern works end-to-end.
- **Memory model is clean**: ghostty-vt uses explicit allocators, returns error codes, and has clear ownership semantics.
- **Static linking is supported**: The library produces `.a` files, enabling single-binary distribution.

### Medium Risk
- **Build complexity**: Users need Zig installed to build from source. Mitigated by pre-building and distributing `.a` files.
- **CGo overhead per call**: ~50-100ns per call. Mitigated by batching writes and using buffer-based formatters.
- **Cross-compilation**: Requires building libghostty-vt for each target separately. Zig makes this easy.

### Low Risk but Worth Noting
- **API stability**: libghostty-vt warns "This is an incomplete, work-in-progress API. It is not yet stable." Plan for API changes.
- **SIMD dependencies**: Building with SIMD enabled adds libc++/highway/simdutf as transitive deps. Build with `-Dsimd=false` for simpler linking.
- **The `GHOSTTY_INIT_SIZED` macro**: C examples use this macro to initialize options structs. In Go, manually set the `size` field.

### Recommendation

1. **Use static linking** with pre-built `.a` files per platform
2. **Build with `-Dsimd=false`** to minimize dependencies
3. **Use `#cgo noescape` and `#cgo nocallback`** on all ghostty functions
4. **Batch VT writes** -- collect output and write in chunks, not bytes
5. **Use `runtime.SetFinalizer`** as a safety net, but provide explicit `Close()` methods
6. **Keep the CGo bridge thin** -- a single Go package (`internal/ghostty`) that wraps the C API with idiomatic Go types

---

## Sources

- Official CGo documentation: https://pkg.go.dev/cmd/cgo
- Go Wiki CGo page: https://go.dev/wiki/cgo
- Dave Cheney "cgo is not Go": https://dave.cheney.net/2016/01/18/cgo-is-not-go
- kristoff-it/zig-cuckoofilter Go example: https://github.com/kristoff-it/zig-cuckoofilter/blob/master/c-abi-examples/go_example.go
- fluent/fluent-bit WAMR Go bindings: https://github.com/fluent/fluent-bit (pre-built library pattern)
- ghostty-org/ghostty CMakeLists.txt: https://github.com/ghostty-org/ghostty/blob/main/CMakeLists.txt
- ghostty-org/ghostty C examples: https://github.com/ghostty-org/ghostty/tree/main/example/
- nkanaev/yarr, keygen-sh/keygen-relay, timelinize: Zig CC cross-compilation patterns

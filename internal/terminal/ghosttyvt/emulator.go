// Package ghosttyvt implements the terminal.Emulator interface using
// libghostty-vt via CGo. This provides Ghostty-grade terminal emulation
// quality — the same VT parser and terminal state engine that powers
// the Ghostty terminal emulator.
//
// All libghostty-vt C calls are serialized onto a single dedicated OS
// thread via runtime.LockOSThread(). This ensures the Zig allocator's
// thread-local state is never accessed from multiple OS threads, which
// can cause crashes even when Go-level mutexes are held (because CGo
// calls can be scheduled onto different OS threads between lock/unlock).
//
// This package requires pre-built libghostty-vt.a static libraries
// for the target platform. See scripts/build-libghostty.sh.
package ghosttyvt

/*
#cgo CFLAGS: -I${SRCDIR}/lib/include
#cgo darwin,arm64  LDFLAGS: ${SRCDIR}/lib/darwin-arm64/libghostty-vt.a -lc
#cgo darwin,amd64  LDFLAGS: ${SRCDIR}/lib/darwin-amd64/libghostty-vt.a -lc
#cgo linux,amd64   LDFLAGS: ${SRCDIR}/lib/linux-amd64/libghostty-vt.a -lm -lc
#cgo linux,arm64   LDFLAGS: ${SRCDIR}/lib/linux-arm64/libghostty-vt.a -lm -lc

#include <ghostty/vt.h>
#include <stdlib.h>
#include <string.h>

// CGo cannot call C macros that use compound literals. This helper
// wraps the GHOSTTY_INIT_SIZED pattern for formatter options.
static inline GhosttyFormatterTerminalOptions ghostty_init_formatter_opts(void) {
	GhosttyFormatterTerminalOptions opts;
	memset(&opts, 0, sizeof(opts));
	opts.size = sizeof(GhosttyFormatterTerminalOptions);
	return opts;
}

// Helper: create formatter, format as VT into a caller-provided buffer.
// Uses the two-pass approach: first call with NULL to query size, then
// allocate from C heap and call again. This avoids any Zig allocator issues.
static inline GhosttyResult ghostty_format_terminal_vt(
	GhosttyTerminal terminal,
	uint8_t **out_buf,
	size_t *out_len
) {
	if (terminal == NULL) {
		return GHOSTTY_INVALID_VALUE;
	}

	GhosttyFormatterTerminalOptions opts = ghostty_init_formatter_opts();
	opts.emit = GHOSTTY_FORMATTER_FORMAT_VT;
	opts.trim = true;

	GhosttyFormatter formatter = NULL;
	GhosttyResult result = ghostty_formatter_terminal_new(NULL, &formatter, terminal, opts);
	if (result != GHOSTTY_SUCCESS || formatter == NULL) {
		return result != GHOSTTY_SUCCESS ? result : GHOSTTY_INVALID_VALUE;
	}

	// First pass: query required size.
	size_t needed = 0;
	result = ghostty_formatter_format_buf(formatter, NULL, 0, &needed);
	// GHOSTTY_OUT_OF_SPACE is expected — it tells us the required size.
	if (result != GHOSTTY_OUT_OF_SPACE || needed == 0) {
		ghostty_formatter_free(formatter);
		if (result == GHOSTTY_SUCCESS) {
			// Empty output.
			*out_buf = NULL;
			*out_len = 0;
			return GHOSTTY_SUCCESS;
		}
		return result;
	}

	// Allocate from C heap.
	uint8_t *buf = (uint8_t *)malloc(needed);
	if (buf == NULL) {
		ghostty_formatter_free(formatter);
		return GHOSTTY_OUT_OF_MEMORY;
	}

	// Second pass: format into the buffer.
	size_t written = 0;
	result = ghostty_formatter_format_buf(formatter, buf, needed, &written);
	ghostty_formatter_free(formatter);

	if (result != GHOSTTY_SUCCESS) {
		free(buf);
		return result;
	}

	*out_buf = buf;
	*out_len = written;
	return GHOSTTY_SUCCESS;
}
*/
import "C"

import (
	"fmt"
	"runtime"
	"unsafe"

	"github.com/nick/proctmux/internal/terminal"
)

// Verify interface compliance at compile time.
var _ terminal.Emulator = (*Emulator)(nil)

// op represents a serialized operation to execute on the dedicated C thread.
type op struct {
	fn   func()
	done chan struct{}
}

// Emulator wraps libghostty-vt's terminal and formatter APIs to satisfy
// the terminal.Emulator interface. All C calls are dispatched to a single
// OS thread via a channel to avoid Zig allocator thread-safety issues.
type Emulator struct {
	term   C.GhosttyTerminal
	ops    chan op
	closed chan struct{}
}

// New creates a new libghostty-vt terminal emulator with the given
// dimensions. Returns an error if the terminal cannot be allocated.
//
// This spawns a dedicated goroutine pinned to a single OS thread
// (via runtime.LockOSThread) that executes all C calls.
func New(cols, rows int) (*Emulator, error) {
	e := &Emulator{
		ops:    make(chan op, 16),
		closed: make(chan struct{}),
	}

	// Channel to receive initialization result.
	initErr := make(chan error, 1)

	go func() {
		// Pin this goroutine to a single OS thread for the lifetime
		// of the emulator. All libghostty C calls happen here.
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()

		opts := C.GhosttyTerminalOptions{
			cols:           C.uint16_t(cols),
			rows:           C.uint16_t(rows),
			max_scrollback: C.size_t(10000),
		}

		var term C.GhosttyTerminal
		result := C.ghostty_terminal_new(nil, &term, opts)
		if result != C.GHOSTTY_SUCCESS {
			initErr <- fmt.Errorf("ghostty_terminal_new failed: %d", result)
			return
		}
		e.term = term
		initErr <- nil

		// Event loop: process operations until closed.
		for {
			select {
			case <-e.closed:
				C.ghostty_terminal_free(e.term)
				return
			case o := <-e.ops:
				o.fn()
				close(o.done)
			}
		}
	}()

	if err := <-initErr; err != nil {
		return nil, err
	}

	return e, nil
}

// exec dispatches a function to the dedicated C thread and waits for completion.
func (e *Emulator) exec(fn func()) {
	done := make(chan struct{})
	select {
	case e.ops <- op{fn: fn, done: done}:
		<-done
	case <-e.closed:
	}
}

// Write feeds raw PTY output into the libghostty-vt terminal for
// VT sequence processing.
func (e *Emulator) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}

	// Copy the slice data so it's safe to use after Write returns
	// (the caller may reuse the buffer).
	buf := make([]byte, len(p))
	copy(buf, p)

	var writeErr error
	e.exec(func() {
		C.ghostty_terminal_vt_write(
			e.term,
			(*C.uint8_t)(unsafe.Pointer(&buf[0])),
			C.size_t(len(buf)),
		)
	})

	return len(p), writeErr
}

// Render returns the current terminal screen content as an ANSI-styled
// string using libghostty-vt's formatter API.
func (e *Emulator) Render() string {
	var result string

	e.exec(func() {
		var buf *C.uint8_t
		var bufLen C.size_t

		ret := C.ghostty_format_terminal_vt(e.term, &buf, &bufLen)
		if ret != C.GHOSTTY_SUCCESS {
			return
		}

		result = C.GoStringN((*C.char)(unsafe.Pointer(buf)), C.int(bufLen))
		C.free(unsafe.Pointer(buf))
	})

	return result
}

// Resize changes the virtual terminal dimensions.
func (e *Emulator) Resize(cols, rows int) {
	if cols <= 0 || rows <= 0 {
		return
	}

	e.exec(func() {
		C.ghostty_terminal_resize(e.term, C.uint16_t(cols), C.uint16_t(rows))
	})
}

// Close releases all resources held by the emulator. It is idempotent —
// calling Close multiple times is safe.
func (e *Emulator) Close() {
	select {
	case <-e.closed:
		// Already closed.
	default:
		close(e.closed)
	}
}

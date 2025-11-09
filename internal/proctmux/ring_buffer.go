package proctmux

import (
	"sync"
)

// RingBuffer is a circular buffer that implements io.Writer
// It stores the last N bytes written to it, providing a scrollback
// buffer for process output with O(1) write operations and bounded memory.
//
// The buffer maintains a write position and wraps around when full,
// overwriting the oldest data. This makes it ideal for terminal scrollback
// where you want to keep recent output without unbounded memory growth.
//
// Thread-safe: All operations are protected by a RWMutex.
type RingBuffer struct {
	buf  []byte       // The underlying circular buffer
	size int          // Total capacity in bytes
	w    int          // Write position (0 to size-1)
	full bool         // Whether we've wrapped around at least once
	mu   sync.RWMutex // Protects concurrent access
}

// NewRingBuffer creates a new ring buffer with the specified capacity.
// The size parameter determines how many bytes of scrollback to maintain.
//
// Example:
//   rb := NewRingBuffer(1024 * 1024) // 1MB scrollback buffer
func NewRingBuffer(size int) *RingBuffer {
	return &RingBuffer{
		buf:  make([]byte, size),
		size: size,
	}
}

// Write implements io.Writer interface.
// Writes the provided bytes to the ring buffer, wrapping around when
// the buffer is full and overwriting the oldest data.
//
// Always returns len(p), nil to satisfy io.Writer contract.
// This ensures writes never fail, making it suitable for use in
// io.MultiWriter chains where one writer shouldn't block others.
func (rb *RingBuffer) Write(p []byte) (n int, err error) {
	rb.mu.Lock()
	defer rb.mu.Unlock()

	n = len(p)

	// Write each byte, wrapping around when we hit the end
	for _, b := range p {
		rb.buf[rb.w] = b
		rb.w++
		if rb.w >= rb.size {
			rb.w = 0
			rb.full = true
		}
	}

	return n, nil
}

// Bytes returns a copy of the buffered content in the correct order.
// The returned slice contains the most recent data, up to the buffer's
// capacity. If the buffer hasn't wrapped yet, it returns only the
// written portion.
//
// Returns a copy to prevent external modification of the internal buffer.
// This is safe for concurrent access with Write operations.
//
// Example:
//   buf := rb.Bytes()
//   // buf contains the last N bytes written, in chronological order
func (rb *RingBuffer) Bytes() []byte {
	rb.mu.RLock()
	defer rb.mu.RUnlock()

	if !rb.full {
		// Haven't wrapped yet, just return what we have so far
		return append([]byte{}, rb.buf[:rb.w]...)
	}

	// Wrapped around, need to reconstruct in chronological order
	// Data from write position to end is the oldest data
	// Data from start to write position is the newest data
	result := make([]byte, rb.size)
	copy(result, rb.buf[rb.w:])           // Copy older data (from w to end)
	copy(result[rb.size-rb.w:], rb.buf[:rb.w]) // Copy newer data (from start to w)
	return result
}

// Len returns the number of bytes currently stored in the buffer.
// This is the size of the slice that Bytes() would return.
func (rb *RingBuffer) Len() int {
	rb.mu.RLock()
	defer rb.mu.RUnlock()

	if !rb.full {
		return rb.w
	}
	return rb.size
}

// Cap returns the total capacity of the ring buffer.
func (rb *RingBuffer) Cap() int {
	return rb.size
}

// Clear resets the buffer to its initial empty state.
// This is useful when restarting a process or clearing scrollback.
func (rb *RingBuffer) Clear() {
	rb.mu.Lock()
	defer rb.mu.Unlock()
	rb.w = 0
	rb.full = false
}

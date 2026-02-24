package buffer

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
// Readers can follow new writes by calling NewReader() to get a channel
// that receives new data as it's written to the buffer.
//
// Thread-safe: All operations are protected by a RWMutex.
type RingBuffer struct {
	buf       []byte              // The underlying circular buffer
	size      int                 // Total capacity in bytes
	w         int                 // Write position (0 to size-1)
	full      bool                // Whether we've wrapped around at least once
	mu        sync.RWMutex        // Protects concurrent access
	readers   map[int]chan []byte // Active readers following new writes
	nextID    int                 // Next reader ID
	readersMu sync.RWMutex        // Protects readers map
}

// NewRingBuffer creates a new ring buffer with the specified capacity.
// The size parameter determines how many bytes of scrollback to maintain.
//
// Example:
//
//	rb := NewRingBuffer(1024 * 1024) // 1MB scrollback buffer
func NewRingBuffer(size int) *RingBuffer {
	return &RingBuffer{
		buf:     make([]byte, size),
		size:    size,
		readers: make(map[int]chan []byte),
	}
}

// Write implements io.Writer interface.
// Writes the provided bytes to the ring buffer, wrapping around when
// the buffer is full and overwriting the oldest data.
//
// Notifies all active readers of the new data.
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

	// Notify all readers of new data (make a copy for each reader)
	rb.readersMu.RLock()
	defer rb.readersMu.RUnlock()

	if len(rb.readers) > 0 {
		data := make([]byte, len(p))
		copy(data, p)

		for _, ch := range rb.readers {
			select {
			case ch <- data:
				// Successfully sent
			default:
				// Channel full, reader is slow - skip to avoid blocking writes
				// The reader will still get historical data from Bytes() when switching
			}
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
//
//	buf := rb.Bytes()
//	// buf contains the last N bytes written, in chronological order
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
	copy(result, rb.buf[rb.w:])                // Copy older data (from w to end)
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

// NewReader creates a new reader that receives copies of data as it's written.
// The returned channel will receive all new data written to the buffer after
// this call. The caller should call RemoveReader when done to avoid resource leaks.
//
// Returns:
//   - id: unique identifier for this reader (used for removal)
//   - ch: channel that receives new data as it's written
//
// Example:
//
//	id, ch := rb.NewReader()
//	defer rb.RemoveReader(id)
//	for data := range ch {
//	    os.Stdout.Write(data)
//	}
func (rb *RingBuffer) NewReader() (int, <-chan []byte) {
	rb.readersMu.Lock()
	defer rb.readersMu.Unlock()

	id := rb.nextID
	rb.nextID++

	// Buffered channel to avoid blocking on slow readers
	ch := make(chan []byte, 100)
	rb.readers[id] = ch

	return id, ch
}

// SnapshotAndSubscribe atomically captures the current buffer contents and
// registers a live reader in a single lock acquisition. This eliminates the
// race window that would exist if Bytes() and NewReader() were called
// separately — bytes written between those two calls would be lost.
//
// Returns:
//   - snapshot: copy of all bytes currently in the buffer (chronological order)
//   - id: unique identifier for the live reader (used for RemoveReader)
//   - ch: channel that receives new data written after this call
func (rb *RingBuffer) SnapshotAndSubscribe() (snapshot []byte, id int, ch <-chan []byte) {
	// Acquire the write lock so no writes can interleave between snapshot and subscribe.
	rb.mu.Lock()
	defer rb.mu.Unlock()

	// Take snapshot while holding write lock (same logic as Bytes()).
	if !rb.full {
		snapshot = append([]byte{}, rb.buf[:rb.w]...)
	} else {
		snapshot = make([]byte, rb.size)
		copy(snapshot, rb.buf[rb.w:])
		copy(snapshot[rb.size-rb.w:], rb.buf[:rb.w])
	}

	// Register reader while still holding write lock so no write can slip through.
	rb.readersMu.Lock()
	readerID := rb.nextID
	rb.nextID++
	liveCh := make(chan []byte, 100)
	rb.readers[readerID] = liveCh
	rb.readersMu.Unlock()

	return snapshot, readerID, liveCh
}

// RemoveReader removes a reader and closes its channel.
// This should be called when the reader is done to avoid resource leaks.
func (rb *RingBuffer) RemoveReader(id int) {
	rb.readersMu.Lock()
	defer rb.readersMu.Unlock()

	if ch, exists := rb.readers[id]; exists {
		close(ch)
		delete(rb.readers, id)
	}
}

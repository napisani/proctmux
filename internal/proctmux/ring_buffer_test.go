package proctmux

import (
	"bytes"
	"io"
	"testing"
)

func TestRingBuffer_NewRingBuffer(t *testing.T) {
	rb := NewRingBuffer(100)
	if rb == nil {
		t.Fatal("NewRingBuffer returned nil")
	}
	if rb.Cap() != 100 {
		t.Errorf("Expected capacity 100, got %d", rb.Cap())
	}
	if rb.Len() != 0 {
		t.Errorf("Expected length 0, got %d", rb.Len())
	}
}

func TestRingBuffer_Write_SmallData(t *testing.T) {
	rb := NewRingBuffer(100)

	data := []byte("hello world")
	n, err := rb.Write(data)

	if err != nil {
		t.Errorf("Write failed: %v", err)
	}
	if n != len(data) {
		t.Errorf("Expected to write %d bytes, wrote %d", len(data), n)
	}
	if rb.Len() != len(data) {
		t.Errorf("Expected length %d, got %d", len(data), rb.Len())
	}

	result := rb.Bytes()
	if !bytes.Equal(result, data) {
		t.Errorf("Expected %q, got %q", data, result)
	}
}

func TestRingBuffer_Write_ExactCapacity(t *testing.T) {
	rb := NewRingBuffer(10)

	data := []byte("0123456789") // Exactly 10 bytes
	n, err := rb.Write(data)

	if err != nil {
		t.Errorf("Write failed: %v", err)
	}
	if n != len(data) {
		t.Errorf("Expected to write %d bytes, wrote %d", len(data), n)
	}
	if rb.Len() != 10 {
		t.Errorf("Expected length 10, got %d", rb.Len())
	}

	result := rb.Bytes()
	if !bytes.Equal(result, data) {
		t.Errorf("Expected %q, got %q", data, result)
	}
}

func TestRingBuffer_Write_Overflow(t *testing.T) {
	rb := NewRingBuffer(10)

	// Write 15 bytes to a 10-byte buffer
	// Should keep only the last 10 bytes: "56789abcde"
	data := []byte("0123456789abcde")
	n, err := rb.Write(data)

	if err != nil {
		t.Errorf("Write failed: %v", err)
	}
	if n != len(data) {
		t.Errorf("Expected to write %d bytes, wrote %d", len(data), n)
	}
	if rb.Len() != 10 {
		t.Errorf("Expected length 10 (buffer full), got %d", rb.Len())
	}

	result := rb.Bytes()
	expected := []byte("56789abcde")
	if !bytes.Equal(result, expected) {
		t.Errorf("Expected %q, got %q", expected, result)
	}
}

func TestRingBuffer_Write_MultipleWrites(t *testing.T) {
	rb := NewRingBuffer(20)

	// Write in chunks
	rb.Write([]byte("hello "))
	rb.Write([]byte("world"))
	rb.Write([]byte(" test"))

	expected := []byte("hello world test")
	result := rb.Bytes()

	if !bytes.Equal(result, expected) {
		t.Errorf("Expected %q, got %q", expected, result)
	}
}

func TestRingBuffer_Write_MultipleWritesWithOverflow(t *testing.T) {
	rb := NewRingBuffer(10)

	// Each write is small, but combined they overflow
	rb.Write([]byte("abc"))   // Buffer: "abc"
	rb.Write([]byte("defg"))  // Buffer: "abcdefg"
	rb.Write([]byte("hijk"))  // Buffer: "bcdefghijk" (wraps, drops "a")
	rb.Write([]byte("lmn"))   // Buffer: "defghijklmn" -> last 10: "efghijklmn"

	expected := []byte("efghijklmn")
	result := rb.Bytes()

	if !bytes.Equal(result, expected) {
		t.Errorf("Expected %q, got %q", expected, result)
	}
}

func TestRingBuffer_Clear(t *testing.T) {
	rb := NewRingBuffer(100)

	rb.Write([]byte("some data"))
	if rb.Len() == 0 {
		t.Error("Buffer should have data before clear")
	}

	rb.Clear()

	if rb.Len() != 0 {
		t.Errorf("Expected length 0 after clear, got %d", rb.Len())
	}

	result := rb.Bytes()
	if len(result) != 0 {
		t.Errorf("Expected empty bytes after clear, got %q", result)
	}
}

func TestRingBuffer_Clear_AndReuse(t *testing.T) {
	rb := NewRingBuffer(10)

	// Write, clear, write again
	rb.Write([]byte("first"))
	rb.Clear()
	rb.Write([]byte("second"))

	expected := []byte("second")
	result := rb.Bytes()

	if !bytes.Equal(result, expected) {
		t.Errorf("Expected %q after reuse, got %q", expected, result)
	}
}

func TestRingBuffer_IoWriter_Interface(t *testing.T) {
	rb := NewRingBuffer(100)

	// Verify it can be used as io.Writer
	var w io.Writer = rb

	data := []byte("test data")
	n, err := w.Write(data)

	if err != nil {
		t.Errorf("Write via io.Writer interface failed: %v", err)
	}
	if n != len(data) {
		t.Errorf("Expected to write %d bytes, wrote %d", len(data), n)
	}

	result := rb.Bytes()
	if !bytes.Equal(result, data) {
		t.Errorf("Expected %q, got %q", data, result)
	}
}

func TestRingBuffer_ConcurrentWrites(t *testing.T) {
	rb := NewRingBuffer(1000)

	// Write concurrently from multiple goroutines
	done := make(chan bool)
	for i := 0; i < 10; i++ {
		go func(id int) {
			for j := 0; j < 10; j++ {
				rb.Write([]byte{byte(id)})
			}
			done <- true
		}(i)
	}

	// Wait for all goroutines
	for i := 0; i < 10; i++ {
		<-done
	}

	// Should have written 100 bytes total
	if rb.Len() != 100 {
		t.Errorf("Expected length 100, got %d", rb.Len())
	}
}

func TestRingBuffer_Bytes_ReturnsCopy(t *testing.T) {
	rb := NewRingBuffer(100)
	rb.Write([]byte("original"))

	result1 := rb.Bytes()
	result2 := rb.Bytes()

	// Modify first result
	if len(result1) > 0 {
		result1[0] = 'X'
	}

	// Second result should be unchanged
	expected := []byte("original")
	if !bytes.Equal(result2, expected) {
		t.Errorf("Bytes() should return a copy. Expected %q, got %q", expected, result2)
	}

	// Original buffer should be unchanged
	result3 := rb.Bytes()
	if !bytes.Equal(result3, expected) {
		t.Errorf("Original buffer was modified. Expected %q, got %q", expected, result3)
	}
}

func TestRingBuffer_WrapAround_Alignment(t *testing.T) {
	rb := NewRingBuffer(10)

	// Fill buffer completely, then wrap around
	rb.Write([]byte("0123456789")) // Full
	rb.Write([]byte("ABC"))         // Wraps, oldest data is "3456789", newest is "ABC"

	// Result should be in chronological order (oldest first)
	expected := []byte("3456789ABC")
	result := rb.Bytes()

	if !bytes.Equal(result, expected) {
		t.Errorf("Expected %q, got %q", expected, result)
	}
}

func TestRingBuffer_EmptyBuffer(t *testing.T) {
	rb := NewRingBuffer(100)

	result := rb.Bytes()
	if len(result) != 0 {
		t.Errorf("Expected empty result, got %q", result)
	}
	if rb.Len() != 0 {
		t.Errorf("Expected length 0, got %d", rb.Len())
	}
}

func TestRingBuffer_SingleByte(t *testing.T) {
	rb := NewRingBuffer(10)

	rb.Write([]byte("A"))

	expected := []byte("A")
	result := rb.Bytes()

	if !bytes.Equal(result, expected) {
		t.Errorf("Expected %q, got %q", expected, result)
	}
	if rb.Len() != 1 {
		t.Errorf("Expected length 1, got %d", rb.Len())
	}
}

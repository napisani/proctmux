package ghosttyvt

import (
	"strings"
	"testing"
)

func TestNew(t *testing.T) {
	emu, err := New(80, 24)
	if err != nil {
		t.Fatalf("New failed: %v", err)
	}
	defer emu.Close()
}

func TestWriteAndRender(t *testing.T) {
	emu, err := New(80, 24)
	if err != nil {
		t.Fatalf("New failed: %v", err)
	}
	defer emu.Close()

	// Write plain text.
	n, err := emu.Write([]byte("Hello, libghostty!"))
	if err != nil {
		t.Fatalf("Write failed: %v", err)
	}
	if n != 18 {
		t.Fatalf("expected 18 bytes written, got %d", n)
	}

	output := emu.Render()
	if !strings.Contains(output, "Hello, libghostty!") {
		t.Fatalf("Render() did not contain expected text, got: %q", output)
	}
}

func TestWriteColoredAndRender(t *testing.T) {
	emu, err := New(80, 24)
	if err != nil {
		t.Fatalf("New failed: %v", err)
	}
	defer emu.Close()

	// Write red text using SGR.
	emu.Write([]byte("\033[31mRed Text\033[0m Normal"))

	output := emu.Render()
	if !strings.Contains(output, "Red Text") {
		t.Fatalf("Render() missing 'Red Text', got: %q", output)
	}
	// VT format should preserve the SGR escape sequence.
	if !strings.Contains(output, "\033[") {
		t.Fatalf("Render() should contain ANSI escape sequences in VT mode, got: %q", output)
	}
}

func TestResize(t *testing.T) {
	emu, err := New(80, 24)
	if err != nil {
		t.Fatalf("New failed: %v", err)
	}
	defer emu.Close()

	// Resize should not panic or error.
	emu.Resize(120, 40)
	emu.Resize(40, 10)

	// Write and render at new size.
	emu.Write([]byte("After resize"))
	output := emu.Render()
	if !strings.Contains(output, "After resize") {
		t.Fatalf("Render() after resize missing text, got: %q", output)
	}
}

func TestCloseIdempotent(t *testing.T) {
	emu, err := New(80, 24)
	if err != nil {
		t.Fatalf("New failed: %v", err)
	}

	// Close twice should not panic.
	emu.Close()
	emu.Close()
}

func TestWriteEmpty(t *testing.T) {
	emu, err := New(80, 24)
	if err != nil {
		t.Fatalf("New failed: %v", err)
	}
	defer emu.Close()

	n, err := emu.Write([]byte{})
	if err != nil {
		t.Fatalf("Write empty should not error: %v", err)
	}
	if n != 0 {
		t.Fatalf("expected 0 bytes written, got %d", n)
	}
}

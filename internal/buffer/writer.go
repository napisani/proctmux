package buffer

import "io"

// FnWriter adapts a function to the io.Writer interface
// This allows passing simple functions wherever io.Writer is required
type FnWriter struct {
	w func(b []byte) (int, error)
}

func (f *FnWriter) Write(b []byte) (int, error) {
	return f.w(b)
}

// FnToWriter converts a write function into an io.Writer
// Useful for creating custom writers with inline behavior
func FnToWriter(w func(b []byte) (int, error)) io.Writer {
	return &FnWriter{w: w}
}

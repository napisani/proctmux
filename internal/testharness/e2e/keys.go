package e2e

// KeySequence represents a raw byte sequence for a key press.
type KeySequence string

const (
	KeyEnter     KeySequence = "\r"
	KeyUp        KeySequence = "\x1b[A"
	KeyDown      KeySequence = "\x1b[B"
	KeyRight     KeySequence = "\x1b[C"
	KeyLeft      KeySequence = "\x1b[D"
	KeyCtrlC     KeySequence = "\x03"
	KeyCtrlW     KeySequence = "\x17"
	KeyCtrlH     KeySequence = "\x08"
	KeyCtrlL     KeySequence = "\x0c"
	KeyCtrlLeft  KeySequence = "\x1b[1;5D"
	KeyCtrlRight KeySequence = "\x1b[1;5C"
	KeyCtrlA     KeySequence = "\x01"
	KeyCtrlS     KeySequence = "\x13"
	KeyEscape    KeySequence = "\x1b"
)

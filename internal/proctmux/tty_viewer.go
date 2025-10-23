package proctmux

import (
	"io"
	"log"
	"sync"
	"time"
)

type TTYViewer struct {
	currentProcessID int
	server           *ProcessServer
	mu               sync.RWMutex
	outputBuffer     *OutputBuffer
	inputBuffer      *InputBuffer
	readerCancel     chan struct{}
}

type OutputBuffer struct {
	lines    []string
	mu       sync.RWMutex
	maxLines int
}

type InputBuffer struct {
	data []byte
	mu   sync.Mutex
}

func NewTTYViewer(server *ProcessServer) *TTYViewer {
	return &TTYViewer{
		currentProcessID: 0,
		server:           server,
		outputBuffer:     NewOutputBuffer(10000),
		inputBuffer:      &InputBuffer{data: []byte{}},
	}
}

func NewOutputBuffer(maxLines int) *OutputBuffer {
	return &OutputBuffer{
		lines:    []string{},
		maxLines: maxLines,
	}
}

func (v *TTYViewer) SwitchToProcess(id int) error {
	v.mu.Lock()
	defer v.mu.Unlock()

	if v.currentProcessID == id {
		return nil
	}

	if v.readerCancel != nil {
		close(v.readerCancel)
		v.readerCancel = nil
	}

	v.currentProcessID = id

	if id == 0 || id == DummyProcessID {
		v.outputBuffer.Clear()
		return nil
	}

	instance, err := v.server.GetProcess(id)
	if err != nil {
		log.Printf("Failed to get process %d: %v", id, err)
		return err
	}

	v.outputBuffer.Clear()

	v.readerCancel = make(chan struct{})
	go v.readProcessOutput(instance, v.readerCancel)

	log.Printf("Switched TTYViewer to process %d (PID: %d)", id, instance.GetPID())
	return nil
}

func (v *TTYViewer) readProcessOutput(instance *ProcessInstance, cancel chan struct{}) {
	reader := instance.pty
	buf := make([]byte, 4096)

	for {
		select {
		case <-cancel:
			log.Printf("Stopping output reader for process %d", instance.ID)
			return
		default:
			reader.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
			n, err := reader.Read(buf)
			if err != nil {
				if err != io.EOF {
					select {
					case <-cancel:
						return
					default:
					}
				}
				if n == 0 {
					continue
				}
			}

			if n > 0 {
				v.outputBuffer.Append(string(buf[:n]))
			}
		}
	}
}

func (v *TTYViewer) WriteInput(data []byte) error {
	v.mu.RLock()
	defer v.mu.RUnlock()

	if v.currentProcessID == 0 || v.currentProcessID == DummyProcessID {
		return nil
	}

	writer, err := v.server.GetWriter(v.currentProcessID)
	if err != nil {
		return err
	}

	_, err = writer.Write(data)
	return err
}

func (v *TTYViewer) GetOutput() string {
	return v.outputBuffer.GetAll()
}

func (v *TTYViewer) GetCurrentProcessID() int {
	v.mu.RLock()
	defer v.mu.RUnlock()
	return v.currentProcessID
}

func (ob *OutputBuffer) Append(text string) {
	ob.mu.Lock()
	defer ob.mu.Unlock()

	ob.lines = append(ob.lines, text)

	if len(ob.lines) > ob.maxLines {
		ob.lines = ob.lines[len(ob.lines)-ob.maxLines:]
	}
}

func (ob *OutputBuffer) GetAll() string {
	ob.mu.RLock()
	defer ob.mu.RUnlock()

	result := ""
	for _, line := range ob.lines {
		result += line
	}
	return result
}

func (ob *OutputBuffer) Clear() {
	ob.mu.Lock()
	defer ob.mu.Unlock()
	ob.lines = []string{}
}

package proctmux

import (
	"io"
	"log"
	"os"
)

type Viewer struct {
	processServer        *ProcessServer
	interruptOutputRelay chan struct{}
}

func NewViewer(server *ProcessServer) *Viewer {
	return &Viewer{
		processServer: server,
	}
}

func (v *Viewer) StartRelayingOutput(processID int) error {
	v.interruptOutputRelay = make(chan struct{})

	go func() {
		instance, err := v.processServer.GetProcess(processID)
		if err != nil {
			log.Printf("Failed to get process %d: %v", processID, err)
			return
		}
		if instance == nil {
			log.Printf("Failed to get process %d: %v", processID, err)
			return
		}

		currentScrollback := instance.Scrollback.Bytes()
		os.Stdout.Write(currentScrollback)
		io.Copy(os.Stdout, instance.Writer)
	}()

	return nil

}

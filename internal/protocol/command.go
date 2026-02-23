package protocol

type Command string

const (
	CommandStart          Command = "start"
	CommandStop           Command = "stop"
	CommandRestart        Command = "restart"
	CommandSwitch         Command = "switch"
	CommandRestartRunning Command = "restart-running"
	CommandStopRunning    Command = "stop-running"
	CommandList           Command = "list"
)

func (c Command) String() string {
	return string(c)
}

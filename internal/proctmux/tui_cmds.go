package proctmux

import tea "github.com/charmbracelet/bubbletea"

type errMsg struct{ err error }

func (e errMsg) Error() string { return e.err.Error() }

func startCmd(c *Controller) tea.Cmd {
	return func() tea.Msg {
		if err := c.OnKeypressStart(); err != nil {
			return errMsg{err}
		}
		return nil
	}
}

func stopCmd(c *Controller) tea.Cmd {
	return func() tea.Msg {
		if err := c.OnKeypressStop(); err != nil {
			return errMsg{err}
		}
		return nil
	}
}

func restartCmd(c *Controller) tea.Cmd {
	return func() tea.Msg {
		if err := c.OnKeypressRestart(); err != nil {
			return errMsg{err}
		}
		return nil
	}
}

func docsCmd(c *Controller) tea.Cmd {
	return func() tea.Msg {
		if err := c.OnKeypressDocs(); err != nil {
			return errMsg{err}
		}
		return nil
	}
}

func focusCmd(c *Controller) tea.Cmd {
	return func() tea.Msg {
		if err := c.OnKeypressSwitchFocus(); err != nil {
			return errMsg{err}
		}
		return nil
	}
}

func applySelectionCmd(c *Controller, procID int) tea.Cmd {
	return func() tea.Msg {
		if err := c.ApplySelection(procID); err != nil {
			return errMsg{err}
		}
		return nil
	}
}

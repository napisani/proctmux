package proctmux

import "strconv"

// NewTmuxContextWithIDs is a helper for tests to construct a context
// without querying the live tmux environment.
func NewTmuxContextWithIDs(paneID, sessionID, detachedSessionID string, processListWidthPercent int) *TmuxContext {
	splitSize := 100 - processListWidthPercent
	return &TmuxContext{
		PaneID:            paneID,
		SessionID:         sessionID,
		DetachedSessionID: detachedSessionID,
		SplitSize:         strconv.Itoa(splitSize) + "%",
	}
}

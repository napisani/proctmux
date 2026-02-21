//go:build darwin

package ipc

import (
	"errors"
	"fmt"

	"golang.org/x/sys/unix"
)

func peerUID(fd uintptr) (uint32, error) {
	xucred, err := unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
	if err != nil {
		if errors.Is(err, unix.ENOTSUP) {
			return 0, errPeerCredUnsupported
		}
		return 0, fmt.Errorf("getsockopt(LOCAL_PEERCRED): %w", err)
	}
	if xucred == nil {
		return 0, fmt.Errorf("xucred not available")
	}
	if xucred.Uid == ^uint32(0) {
		return 0, fmt.Errorf("peer reported invalid uid")
	}
	return xucred.Uid, nil
}

//go:build linux

package ipc

import (
	"errors"
	"fmt"

	"golang.org/x/sys/unix"
)

func peerUID(fd uintptr) (uint32, error) {
	ucred, err := unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	if err != nil {
		if errors.Is(err, unix.ENOTSUP) {
			return 0, errPeerCredUnsupported
		}
		return 0, fmt.Errorf("getsockopt(SO_PEERCRED): %w", err)
	}

	return ucred.Uid, nil
}

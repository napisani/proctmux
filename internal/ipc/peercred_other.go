//go:build !linux && !darwin

package ipc

func peerUID(fd uintptr) (uint32, error) {
	return 0, errPeerCredUnsupported
}

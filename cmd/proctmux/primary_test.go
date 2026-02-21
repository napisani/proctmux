package main

import (
	"context"
	"testing"
	"time"
)

func TestWaitForShutdownInvokesStopOnContextCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		waitForShutdown(ctx, func() { close(done) })
	}()

	cancel()

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("waitForShutdown did not invoke stop before timeout")
	}
}

func TestWaitForShutdownHandlesAlreadyCanceledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	done := make(chan struct{})
	go func() {
		waitForShutdown(ctx, func() { close(done) })
	}()

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("waitForShutdown blocked with canceled context")
	}
}

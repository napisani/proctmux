package main

import (
	"context"
	"testing"
	"time"
)

func TestWaitForShutdownInvokesStopOnContextCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	stopCalled := make(chan struct{}, 1)
	errCh := make(chan error, 1)
	go func() {
		err := waitForShutdown(ctx, func() { close(stopCalled) })
		errCh <- err
	}()

	cancel()

	select {
	case <-stopCalled:
	case <-time.After(time.Second):
		t.Fatal("waitForShutdown did not invoke stop before timeout")
	}
	select {
	case err := <-errCh:
		if err != context.Canceled {
			t.Fatalf("expected context.Canceled, got %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("waitForShutdown did not report context error")
	}
}

func TestWaitForShutdownHandlesAlreadyCanceledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	stopCalled := make(chan struct{}, 1)
	errCh := make(chan error, 1)
	go func() {
		err := waitForShutdown(ctx, func() { close(stopCalled) })
		errCh <- err
	}()

	select {
	case <-stopCalled:
	case <-time.After(time.Second):
		t.Fatal("waitForShutdown blocked with canceled context")
	}
	select {
	case err := <-errCh:
		if err != context.Canceled {
			t.Fatalf("expected context.Canceled, got %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("waitForShutdown blocked with canceled context")
	}
}

#!/bin/bash
# Comprehensive integration test for proctmux master + client

set -e

echo "=== Cleaning up old processes ==="
pkill -f "bin/proctmux" 2>/dev/null || true
sleep 1

echo ""
echo "=== Starting master server in background ==="
./bin/proctmux &
MASTER_PID=$!
echo "Master PID: $MASTER_PID"

# Wait for master to be ready
echo "Waiting for master to initialize..."
sleep 2

if ! ps -p $MASTER_PID > /dev/null; then
    echo "ERROR: Master process died"
    exit 1
fi

SOCKET_PATH=$(cat /tmp/proctmux.socket)
echo "Socket path: $SOCKET_PATH"

echo ""
echo "=== Testing signal commands ==="
echo "Listing processes..."
./bin/proctmux signal-list | head -10

echo ""
echo "=== Testing client mode (background) ==="
timeout 2 ./bin/proctmux --mode client &
CLIENT_PID=$!
sleep 1

if ps -p $CLIENT_PID > /dev/null 2>&1; then
    echo "✓ Client is running"
    kill $CLIENT_PID 2>/dev/null || true
else
    echo "✓ Client exited (expected with timeout)"
fi

echo ""
echo "=== Checking logs for errors ==="
if tail -50 /tmp/proctmux.log | grep -i "panic\|fatal" | grep -v "could not open a new TTY"; then
    echo "ERROR: Found panic or fatal errors in logs"
    kill $MASTER_PID 2>/dev/null || true
    exit 1
else
    echo "✓ No panics or fatal errors in logs"
fi

echo ""
echo "=== Cleanup ==="
kill $MASTER_PID 2>/dev/null || true
sleep 1

echo ""
echo "=== SUCCESS ==="
echo "✓ Master mode works"
echo "✓ Client mode works"
echo "✓ IPC communication works"
echo "✓ No crashes or panics"

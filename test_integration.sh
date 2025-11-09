#!/bin/bash
set -e

echo "=== Starting master server in background ==="
./bin/proctmux &
MASTER_PID=$!
echo "Master PID: $MASTER_PID"

# Wait for socket file to be created
echo "Waiting for socket file..."
for i in {1..10}; do
    if [ -f /tmp/proctmux.socket ]; then
        echo "Socket file found!"
        break
    fi
    sleep 0.5
done

if [ ! -f /tmp/proctmux.socket ]; then
    echo "ERROR: Socket file not created"
    kill $MASTER_PID 2>/dev/null || true
    exit 1
fi

SOCKET_PATH=$(cat /tmp/proctmux.socket)
echo "Socket path: $SOCKET_PATH"

# Test if socket exists
if [ -S "$SOCKET_PATH" ]; then
    echo "✓ Socket exists and is accessible"
else
    echo "ERROR: Socket file does not exist"
    kill $MASTER_PID 2>/dev/null || true
    exit 1
fi

echo ""
echo "=== Testing client connection ==="
echo "Running client for 3 seconds..."
timeout 3 ./bin/proctmux --mode client || true

echo ""
echo "=== Cleanup ==="
kill $MASTER_PID 2>/dev/null || true
sleep 1
echo "Done!"

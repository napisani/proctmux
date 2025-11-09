#!/bin/bash

# Test script for signal-switch command

echo "=== Testing signal-switch command ==="
echo ""

# Start proctmux master in background (requires tmux)
echo "Note: proctmux master must be running in a tmux session for this test to work."
echo "If not already running, start it with: make run"
echo ""

# Wait a moment for master to be ready
sleep 2

# Test 1: List processes
echo "Test 1: Listing processes..."
./bin/proctmux signal-list
echo ""

# Test 2: Switch to a valid process
echo "Test 2: Switching to 'vim' process..."
./bin/proctmux signal-switch "vim"
if [ $? -eq 0 ]; then
    echo "✓ Switch to 'vim' succeeded"
else
    echo "✗ Switch to 'vim' failed"
fi
echo ""

# Test 3: Switch to another valid process
echo "Test 3: Switching to 'tail log' process..."
./bin/proctmux signal-switch "tail log"
if [ $? -eq 0 ]; then
    echo "✓ Switch to 'tail log' succeeded"
else
    echo "✗ Switch to 'tail log' failed"
fi
echo ""

# Test 4: Try to switch to non-existent process (should fail)
echo "Test 4: Switching to non-existent process (should fail)..."
./bin/proctmux signal-switch "nonexistent" 2>&1
if [ $? -ne 0 ]; then
    echo "✓ Switch to 'nonexistent' failed as expected"
else
    echo "✗ Switch to 'nonexistent' should have failed but didn't"
fi
echo ""

echo "=== Test complete ==="
echo "Check /tmp/proctmux.log for detailed logs"

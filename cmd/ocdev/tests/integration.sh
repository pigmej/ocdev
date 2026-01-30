#!/bin/bash
# Integration test comparing Nim and Bash implementations

set -e

NIM_BIN="./bin/ocdev"
BASH_BIN="./bin/ocdev-bash"
TEST_NAME="test-$(date +%s)"

echo "=== Testing with container: $TEST_NAME ==="

# Test create
echo "Testing create..."
$NIM_BIN create -n="$TEST_NAME"
$NIM_BIN list | grep -q "$TEST_NAME"

# Test stop/start
echo "Testing stop/start..."
$NIM_BIN stop -n="$TEST_NAME"
$NIM_BIN start -n="$TEST_NAME"

# Test ssh info
echo "Testing ssh info..."
$NIM_BIN ssh -n="$TEST_NAME" | grep -q "ssh -p"

# Test ports
echo "Testing ports..."
$NIM_BIN ports | grep -q "$TEST_NAME"

# Test shell (non-interactive check)
echo "Testing shell availability..."
$NIM_BIN shell -n="$TEST_NAME" <<< "exit 0"

# Test bind
echo "Testing bind..."
$NIM_BIN bind -n="$TEST_NAME" -p=5173
$NIM_BIN bind -n="$TEST_NAME" --list | grep -q "5173"

# Test bind with container:host format
echo "Testing bind with port mapping..."
$NIM_BIN bind -n="$TEST_NAME" -p=3000:8080
$NIM_BIN bind -n="$TEST_NAME" --list | grep -q "8080"

# Test bind rejects already-bound port
echo "Testing bind rejects duplicate..."
! $NIM_BIN bind -n="$TEST_NAME" -p=5173

# Test unbind
echo "Testing unbind..."
$NIM_BIN unbind -n="$TEST_NAME" -p=5173
! $NIM_BIN bind -n="$TEST_NAME" --list | grep -q "5173"

# Test unbind rejects non-existent binding
echo "Testing unbind rejects non-existent..."
! $NIM_BIN unbind -n="$TEST_NAME" -p=5173

# Clean up remaining binding
$NIM_BIN unbind -n="$TEST_NAME" -p=8080

# Test rebind (fresh bind - port not bound anywhere)
echo "Testing rebind (fresh)..."
$NIM_BIN rebind -n="$TEST_NAME" -p=5173
$NIM_BIN bind -n="$TEST_NAME" --list | grep -q "5173"

# Test rebind (already bound to same container - should be no-op)
echo "Testing rebind (same container)..."
$NIM_BIN rebind -n="$TEST_NAME" -p=5173

# Test bindings (global view)
echo "Testing bindings..."
$NIM_BIN bindings | grep -q "$TEST_NAME"
$NIM_BIN bindings | grep -q "5173"

# Clean up
$NIM_BIN unbind -n="$TEST_NAME" -p=5173

# Test bindings shows nothing after cleanup
echo "Testing bindings empty..."
! $NIM_BIN bindings | grep -q "$TEST_NAME"

# Test delete
echo "Testing delete..."
$NIM_BIN delete -n="$TEST_NAME"
! $NIM_BIN list | grep -q "$TEST_NAME"

echo "=== All tests passed ==="

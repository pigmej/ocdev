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

# Test delete
echo "Testing delete..."
$NIM_BIN delete -n="$TEST_NAME"
! $NIM_BIN list | grep -q "$TEST_NAME"

echo "=== All tests passed ==="

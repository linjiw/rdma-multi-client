#!/bin/bash

# Quick test of demo concept with 2 clients

echo "Testing demo concept with 2 clients..."

# Clean up
pkill -f secure_server
pkill -f secure_client
sleep 1

# Start server
./build/secure_server > test_server.log 2>&1 &
SERVER_PID=$!
sleep 2

if ! ps -p $SERVER_PID > /dev/null; then
    echo "Server failed to start"
    cat test_server.log
    exit 1
fi

echo "Server started"

# Test client 1 with 'a' pattern
echo "Testing Client 1 with 'aaa' pattern..."
MESSAGE_A=$(printf "%0.sa" {1..100})
{
    echo "send Test_Pattern:$MESSAGE_A"
    sleep 0.5
    echo "quit"
} | ./build/secure_client 127.0.0.1 localhost > test_client1.log 2>&1 &

sleep 1

# Test client 2 with 'b' pattern  
echo "Testing Client 2 with 'bbb' pattern..."
MESSAGE_B=$(printf "%0.sb" {1..100})
{
    echo "send Test_Pattern:$MESSAGE_B"
    sleep 0.5
    echo "quit"
} | ./build/secure_client 127.0.0.1 localhost > test_client2.log 2>&1 &

sleep 3

# Check results
echo ""
echo "Checking server received messages..."
if grep -q "$MESSAGE_A" test_server.log; then
    echo "✓ Server received 100 'a' characters"
else
    echo "✗ Server did not receive 'a' pattern"
fi

if grep -q "$MESSAGE_B" test_server.log; then
    echo "✓ Server received 100 'b' characters"
else
    echo "✗ Server did not receive 'b' pattern"
fi

# Check PSNs
echo ""
echo "PSN values:"
grep "PSN" test_client1.log | head -1
grep "PSN" test_client2.log | head -1

# Cleanup
pkill -f secure_server
pkill -f secure_client

echo ""
echo "Test complete"
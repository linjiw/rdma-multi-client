#!/bin/bash

# Multi-Client RDMA Test Script
# Tests multiple concurrent client connections to the server

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SERVER_ADDR="127.0.0.1"
SERVER_NAME="localhost"
CLIENT_LOGS_DIR="client_logs"
NUM_CLIENTS=5
TEST_DURATION=10  # seconds

# Function to print colored output
print_status() {
    echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"
}

print_error() {
    echo -e "${RED}[$(date +%H:%M:%S)]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $1"
}

# Clean up function
cleanup() {
    print_status "Cleaning up..."
    
    # Kill all client processes
    pkill -f secure_client 2>/dev/null
    
    # Kill server
    pkill -f secure_server 2>/dev/null
    
    # Wait for processes to terminate
    sleep 2
    
    # Force kill if still running
    pkill -9 -f secure_client 2>/dev/null
    pkill -9 -f secure_server 2>/dev/null
    
    print_status "Cleanup complete"
}

# Trap exit signals
trap cleanup EXIT INT TERM

# Create logs directory
mkdir -p $CLIENT_LOGS_DIR
rm -f $CLIENT_LOGS_DIR/*.log

print_status "Starting Multi-Client RDMA Test"
print_status "Number of clients: $NUM_CLIENTS"
print_status "Test duration: $TEST_DURATION seconds"

# Check if binaries exist
if [ ! -f build/secure_server ] || [ ! -f build/secure_client ]; then
    print_error "Server or client binary not found. Please build first."
    exit 1
fi

# Kill any existing processes
cleanup

# Start server
print_status "Starting RDMA server..."
./build/secure_server > server.log 2>&1 &
SERVER_PID=$!

# Wait for server to start
sleep 3

# Check if server is running
if ! ps -p $SERVER_PID > /dev/null; then
    print_error "Server failed to start. Check server.log"
    cat server.log
    exit 1
fi

print_status "Server started with PID $SERVER_PID"

# Function to run a client
run_client() {
    local client_id=$1
    local log_file="$CLIENT_LOGS_DIR/client_$client_id.log"
    
    print_status "Starting client $client_id"
    
    # Create client commands
    cat << EOF | ./build/secure_client $SERVER_ADDR $SERVER_NAME > $log_file 2>&1 &
send Hello from client $client_id
write RDMA Write from client $client_id
send Test message $client_id-1
send Test message $client_id-2
write Final write from client $client_id
quit
EOF
    
    echo $! > $CLIENT_LOGS_DIR/client_$client_id.pid
}

# Test 1: Sequential client connections
print_status "=== Test 1: Sequential Client Connections ==="
for i in $(seq 1 3); do
    run_client $i
    sleep 1
done

# Wait for sequential clients to finish
sleep 5

# Check results
print_status "Checking sequential test results..."
for i in $(seq 1 3); do
    if grep -q "Secure RDMA connection established" $CLIENT_LOGS_DIR/client_$i.log; then
        psn=$(grep "Local PSN:" $CLIENT_LOGS_DIR/client_$i.log | awk '{print $3}')
        print_status "Client $i connected successfully with PSN: $psn"
    else
        print_error "Client $i failed to connect"
    fi
done

# Test 2: Concurrent client connections
print_status "=== Test 2: Concurrent Client Connections ==="
for i in $(seq 4 $((NUM_CLIENTS + 3))); do
    run_client $i &
done

# Wait for concurrent clients
sleep 5

# Check concurrent results
print_status "Checking concurrent test results..."
for i in $(seq 4 $((NUM_CLIENTS + 3))); do
    if [ -f $CLIENT_LOGS_DIR/client_$i.log ]; then
        if grep -q "Secure RDMA connection established" $CLIENT_LOGS_DIR/client_$i.log; then
            psn=$(grep "Local PSN:" $CLIENT_LOGS_DIR/client_$i.log | awk '{print $3}')
            print_status "Client $i connected successfully with PSN: $psn"
        else
            print_error "Client $i failed to connect"
        fi
    fi
done

# Test 3: Stress test - rapid connections
print_status "=== Test 3: Stress Test - Rapid Connections ==="
for i in $(seq $((NUM_CLIENTS + 4)) $((NUM_CLIENTS + 8))); do
    run_client $i &
    # No delay between connections
done

# Wait for stress test clients
sleep 5

# Collect PSN values to check uniqueness
print_status "=== PSN Uniqueness Check ==="
echo "Client PSN values:"
grep "Local PSN:" $CLIENT_LOGS_DIR/*.log | awk '{print $1, $5}' | sort -u

# Check for duplicate PSNs
psn_count=$(grep "Local PSN:" $CLIENT_LOGS_DIR/*.log | awk '{print $5}' | sort | uniq -c | awk '$1 > 1' | wc -l)
if [ $psn_count -eq 0 ]; then
    print_status "✓ All PSN values are unique"
else
    print_error "✗ Found duplicate PSN values!"
fi

# Check server status
print_status "=== Server Statistics ==="
if ps -p $SERVER_PID > /dev/null; then
    print_status "Server is still running"
    
    # Count active connections in server log
    active_clients=$(tail -20 server.log | grep "Active clients:" | tail -1 | awk '{print $3}')
    print_status "Active clients reported by server: ${active_clients:-0}"
    
    # Check for errors in server log
    error_count=$(grep -i "error\|failed" server.log | wc -l)
    if [ $error_count -gt 0 ]; then
        print_warning "Found $error_count error messages in server log"
    else
        print_status "No errors found in server log"
    fi
else
    print_error "Server has crashed!"
fi

# Summary
print_status "=== Test Summary ==="
total_clients=$((NUM_CLIENTS + 8))
successful_clients=$(grep -l "Secure RDMA connection established" $CLIENT_LOGS_DIR/*.log | wc -l)
failed_clients=$((total_clients - successful_clients))

print_status "Total clients attempted: $total_clients"
print_status "Successful connections: $successful_clients"
if [ $failed_clients -gt 0 ]; then
    print_error "Failed connections: $failed_clients"
else
    print_status "Failed connections: 0"
fi

# Check for memory leaks (basic check)
print_status "=== Resource Check ==="
server_mem=$(ps aux | grep secure_server | grep -v grep | awk '{print $6}')
print_status "Server memory usage: ${server_mem:-0} KB"

# Save detailed results
print_status "Saving detailed results to test_results.txt"
{
    echo "Multi-Client Test Results - $(date)"
    echo "================================"
    echo "Total clients: $total_clients"
    echo "Successful: $successful_clients"
    echo "Failed: $failed_clients"
    echo ""
    echo "PSN Values:"
    grep "Local PSN:" $CLIENT_LOGS_DIR/*.log | awk '{print $1, $5}'
    echo ""
    echo "Server Log Tail:"
    tail -50 server.log
} > test_results.txt

print_status "Test complete. Check test_results.txt for details"

# Keep server running for manual inspection if needed
print_status "Server still running. Press Ctrl+C to stop..."
wait $SERVER_PID
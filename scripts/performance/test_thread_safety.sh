#!/bin/bash

# Thread Safety Verification Test
# Tests concurrent client connections with various patterns

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SERVER_ADDR="127.0.0.1"
SERVER_NAME="localhost"
CLIENT_LOGS_DIR="thread_test_logs"

print_status() {
    echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"
}

print_error() {
    echo -e "${RED}[$(date +%H:%M:%S)]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $1"
}

cleanup() {
    print_status "Cleaning up..."
    pkill -f secure_client 2>/dev/null
    pkill -f secure_server 2>/dev/null
    sleep 2
    pkill -9 -f secure_client 2>/dev/null
    pkill -9 -f secure_server 2>/dev/null
    print_status "Cleanup complete"
}

trap cleanup EXIT INT TERM

# Create logs directory
mkdir -p $CLIENT_LOGS_DIR
rm -f $CLIENT_LOGS_DIR/*.log

print_status "=== Thread Safety Verification Test ==="

# Check binaries
if [ ! -f build/secure_server ] || [ ! -f build/secure_client ]; then
    print_error "Binaries not found. Please build first."
    exit 1
fi

# Kill any existing processes
cleanup

# Start server
print_status "Starting RDMA server..."
./build/secure_server > thread_server.log 2>&1 &
SERVER_PID=$!
sleep 3

if ! ps -p $SERVER_PID > /dev/null; then
    print_error "Server failed to start"
    cat thread_server.log
    exit 1
fi

print_status "Server started with PID $SERVER_PID"

# Function to run a client
run_client() {
    local client_id=$1
    local delay=$2
    local log_file="$CLIENT_LOGS_DIR/client_$client_id.log"
    
    if [ $delay -gt 0 ]; then
        sleep $delay
    fi
    
    cat << EOF | ./build/secure_client $SERVER_ADDR $SERVER_NAME > $log_file 2>&1 &
send Thread test from client $client_id
write RDMA write from client $client_id
send Message 2 from client $client_id
quit
EOF
    
    echo $! > $CLIENT_LOGS_DIR/client_$client_id.pid
}

# Test 1: Truly simultaneous connections (10 clients at once)
print_status "Test 1: 10 simultaneous connections"
for i in $(seq 1 10); do
    run_client "sim_$i" 0 &
done

sleep 5

# Count successful connections
success_count=$(grep -l "Secure RDMA connection established" $CLIENT_LOGS_DIR/client_sim_*.log 2>/dev/null | wc -l)
print_status "Simultaneous test: $success_count/10 successful"

# Test 2: Rapid fire connections (no delay)
print_status "Test 2: Rapid fire connections"
for i in $(seq 1 5); do
    run_client "rapid_$i" 0
done

sleep 3

# Test 3: Connect/disconnect cycling
print_status "Test 3: Connection cycling (5 rounds)"
for round in $(seq 1 5); do
    print_status "Round $round"
    run_client "cycle_${round}_1" 0
    run_client "cycle_${round}_2" 0
    sleep 1
done

sleep 3

# Analyze results
print_status "=== Analysis ==="

# Check for race conditions in PSN assignment
print_status "Checking PSN uniqueness across all tests..."
all_psns=$(grep "Local PSN:" $CLIENT_LOGS_DIR/*.log 2>/dev/null | awk '{print $3}' | sort)
unique_psns=$(echo "$all_psns" | uniq | wc -l)
total_psns=$(echo "$all_psns" | wc -l)

if [ "$unique_psns" -eq "$total_psns" ]; then
    print_status "✓ All PSN values are unique ($unique_psns PSNs)"
else
    print_error "✗ Found duplicate PSNs! ($unique_psns unique out of $total_psns)"
    echo "$all_psns" | uniq -d
fi

# Check for server errors
error_count=$(grep -i "error\|segfault\|assertion" thread_server.log | wc -l)
if [ $error_count -eq 0 ]; then
    print_status "✓ No server errors detected"
else
    print_warning "Found $error_count potential errors in server log"
fi

# Check client slot management
print_status "Checking client slot management..."
max_active=$(grep "Active clients:" thread_server.log | awk '{print $3}' | sort -rn | head -1)
print_status "Maximum concurrent clients: ${max_active:-0}/10"

# Memory check
server_mem=$(ps aux | grep secure_server | grep -v grep | awk '{print $6}')
print_status "Server memory usage: ${server_mem:-0} KB"

# Count total successful connections
total_success=$(grep -l "Secure RDMA connection established" $CLIENT_LOGS_DIR/*.log 2>/dev/null | wc -l)
total_attempts=$(ls $CLIENT_LOGS_DIR/*.log 2>/dev/null | wc -l)
print_status "Total: $total_success/$total_attempts connections successful"

# Check for thread safety issues
print_status "Checking for thread safety issues..."
mutex_errors=$(grep -i "mutex\|deadlock\|race" thread_server.log | wc -l)
if [ $mutex_errors -eq 0 ]; then
    print_status "✓ No obvious thread safety issues detected"
else
    print_warning "Found $mutex_errors potential thread safety issues"
fi

# Save detailed report
{
    echo "Thread Safety Test Report - $(date)"
    echo "=================================="
    echo "Total connection attempts: $total_attempts"
    echo "Successful connections: $total_success"
    echo "PSN uniqueness: $unique_psns unique out of $total_psns"
    echo "Maximum concurrent clients: ${max_active:-0}"
    echo "Server errors: $error_count"
    echo "Thread safety issues: $mutex_errors"
    echo ""
    echo "PSN Distribution:"
    grep "Local PSN:" $CLIENT_LOGS_DIR/*.log 2>/dev/null | awk '{print $1, $3}' | sort -k2
} > thread_safety_report.txt

print_status "Test complete. Report saved to thread_safety_report.txt"
print_status "Server still running for inspection. Press Ctrl+C to stop..."
wait $SERVER_PID
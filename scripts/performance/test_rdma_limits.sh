#!/bin/bash

# Test real RDMA connection limits with Soft-RoCE
# Progressively increases client count until failure

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
TEST_DIR="rdma_limit_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$TEST_DIR"
RESULTS_FILE="$TEST_DIR/results.txt"
LOG_FILE="$TEST_DIR/test.log"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  RDMA Connection Limit Test${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Function to test a specific number of clients
test_client_count() {
    local num_clients=$1
    local server_binary="build/secure_server_$num_clients"
    
    echo -e "${YELLOW}Testing $num_clients clients...${NC}"
    
    # Build server if needed
    if [ ! -f "$server_binary" ]; then
        echo "Building server for $num_clients clients..."
        ./build_configurable_server.sh $num_clients secure_server_$num_clients >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to build server for $num_clients clients${NC}"
            return 1
        fi
    fi
    
    # Kill any existing processes
    pkill -f secure_server 2>/dev/null || true
    pkill -f secure_client 2>/dev/null || true
    sleep 1
    
    # Start server
    echo "Starting server..."
    $server_binary > "$TEST_DIR/server_${num_clients}.log" 2>&1 &
    SERVER_PID=$!
    sleep 2
    
    # Check if server started
    if ! ps -p $SERVER_PID > /dev/null; then
        echo -e "${RED}Server failed to start${NC}"
        return 1
    fi
    
    # Launch clients
    echo "Launching $num_clients clients..."
    local successful=0
    local failed=0
    
    for i in $(seq 1 $num_clients); do
        # Start client in background
        timeout 5 ./build/secure_client 127.0.0.1 localhost > "$TEST_DIR/client_${num_clients}_${i}.log" 2>&1 &
        CLIENT_PID=$!
        
        # Small delay to prevent thundering herd
        if [ $((i % 10)) -eq 0 ]; then
            sleep 0.1
        fi
        
        # Check if we're hitting limits
        if [ $((i % 50)) -eq 0 ]; then
            echo "  Launched $i clients..."
            
            # Check RDMA resources
            local qp_count=$(rdma resource show | grep -o "qp [0-9]*" | awk '{print $2}')
            echo "  Current QPs: $qp_count"
        fi
    done
    
    # Wait for clients to connect
    echo "Waiting for connections to establish..."
    sleep 5
    
    # Count successful connections from server log
    successful=$(grep -c "Client .* connected" "$TEST_DIR/server_${num_clients}.log" 2>/dev/null || echo "0")
    
    # Check active clients
    active=$(grep -o "Active clients: [0-9]*" "$TEST_DIR/server_${num_clients}.log" 2>/dev/null | tail -1 | awk '{print $3}' || echo "0")
    
    # Kill server
    kill $SERVER_PID 2>/dev/null || true
    pkill -f secure_server 2>/dev/null || true
    pkill -f secure_client 2>/dev/null || true
    
    # Record results
    echo "$num_clients,$successful,$active" >> "$RESULTS_FILE"
    
    if [ "$successful" -lt "$num_clients" ]; then
        echo -e "${YELLOW}Only $successful/$num_clients clients connected successfully${NC}"
        if [ "$successful" -lt $((num_clients / 2)) ]; then
            echo -e "${RED}Less than 50% success rate - stopping test${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}✓ All $num_clients clients connected successfully${NC}"
    fi
    
    # Check RDMA resources after test
    echo "RDMA resources after test:"
    rdma resource show
    
    echo ""
    return 0
}

# Function to test single client repeatedly
stress_test_single() {
    local iterations=$1
    echo -e "${BLUE}Stress testing single client $iterations times...${NC}"
    
    # Start server
    ./build/secure_server > "$TEST_DIR/stress_server.log" 2>&1 &
    SERVER_PID=$!
    sleep 2
    
    local success=0
    for i in $(seq 1 $iterations); do
        timeout 3 ./build/secure_client 127.0.0.1 localhost > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            ((success++))
        fi
        
        if [ $((i % 100)) -eq 0 ]; then
            echo "  Completed $i iterations ($success successful)"
        fi
    done
    
    kill $SERVER_PID 2>/dev/null || true
    
    echo "Single client stress test: $success/$iterations successful"
    echo ""
}

# Main test sequence
main() {
    echo "Test started at $(date)" | tee -a "$LOG_FILE"
    echo "Instance: $(uname -n)" | tee -a "$LOG_FILE"
    echo "Kernel: $(uname -r)" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    
    # Check initial state
    echo -e "${BLUE}Initial RDMA state:${NC}"
    rdma resource show
    echo ""
    
    # Initialize results file
    echo "clients,successful,active" > "$RESULTS_FILE"
    
    # Progressive test
    echo -e "${GREEN}Starting progressive client test...${NC}"
    echo ""
    
    # Test increasing client counts
    for clients in 5 10 20 30 40 50 75 100 150 200 300 500 750 1000; do
        if ! test_client_count $clients; then
            echo -e "${RED}Test failed at $clients clients${NC}"
            break
        fi
        
        # Cleanup between tests
        sleep 2
    done
    
    # Analyze results
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Test Results Summary${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    # Find maximum successful count
    MAX_CLIENTS=$(tail -n +2 "$RESULTS_FILE" | awk -F',' '$2 == $1 {print $1}' | tail -1)
    
    if [ -n "$MAX_CLIENTS" ]; then
        echo -e "${GREEN}Maximum successful clients: $MAX_CLIENTS${NC}"
    fi
    
    # Show all results
    echo ""
    echo "Detailed results:"
    echo "Clients | Successful | Active"
    echo "--------|------------|-------"
    tail -n +2 "$RESULTS_FILE" | while IFS=',' read -r clients successful active; do
        printf "%-8s| %-11s| %s\n" "$clients" "$successful" "$active"
    done
    
    # Final RDMA state
    echo ""
    echo -e "${BLUE}Final RDMA state:${NC}"
    rdma resource show
    
    # Save summary
    echo "" | tee -a "$LOG_FILE"
    echo "Test completed at $(date)" | tee -a "$LOG_FILE"
    echo "Maximum clients achieved: $MAX_CLIENTS" | tee -a "$LOG_FILE"
    
    echo ""
    echo "Results saved in: $TEST_DIR"
}

# Run the test
main "$@"
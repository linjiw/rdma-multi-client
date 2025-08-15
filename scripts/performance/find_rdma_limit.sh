#!/bin/bash

# Find exact RDMA connection limit with Soft-RoCE
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Results directory
RESULTS_DIR="rdma_limit_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Finding RDMA Connection Limit${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Test started at $(date)"
echo "Instance: $(uname -n)"
echo ""

# Function to clean processes
cleanup() {
    sudo killall -9 secure_server secure_client 2>/dev/null || true
    sudo lsof -ti:4433,4791 | xargs -r sudo kill -9 2>/dev/null || true
    sleep 1
}

# Function to test specific client count
test_clients() {
    local count=$1
    echo -e "${YELLOW}Testing $count clients...${NC}"
    
    # Build server if needed
    if [ ! -f "build/secure_server_$count" ]; then
        echo "Building server for $count clients..."
        ./build_configurable_server.sh $count secure_server_$count >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to build server${NC}"
            return 1
        fi
    fi
    
    # Clean before test
    cleanup
    
    # Start server
    ./build/secure_server_$count > "$RESULTS_DIR/server_$count.log" 2>&1 &
    SERVER_PID=$!
    sleep 2
    
    # Check server started
    if ! ps -p $SERVER_PID > /dev/null; then
        echo -e "${RED}Server failed to start${NC}"
        cat "$RESULTS_DIR/server_$count.log" | head -5
        return 1
    fi
    
    # Start clients
    echo "Launching clients..."
    for i in $(seq 1 $count); do
        (
            echo -e "send Test message $i\nquit" | timeout 3 ./build/secure_client 127.0.0.1 localhost > "$RESULTS_DIR/client_${count}_$i.log" 2>&1
        ) &
        
        # Pace client launches
        if [ $((i % 5)) -eq 0 ]; then
            sleep 0.1
        fi
    done
    
    # Wait for connections
    echo "Waiting for connections..."
    sleep 5
    
    # Check results
    local connected=$(grep -c "RDMA connection established" "$RESULTS_DIR/server_$count.log" 2>/dev/null || echo "0")
    local active=$(grep "Active clients:" "$RESULTS_DIR/server_$count.log" 2>/dev/null | tail -1 | awk '{print $3}' || echo "0")
    
    # Check RDMA resources
    echo "RDMA resources during test:"
    rdma resource show | tee "$RESULTS_DIR/rdma_$count.txt"
    
    # Kill server
    kill -TERM $SERVER_PID 2>/dev/null || true
    sleep 2
    cleanup
    
    echo -e "${BLUE}Result: $connected/$count connected, $active active${NC}"
    echo "$count,$connected,$active" >> "$RESULTS_DIR/summary.csv"
    
    if [ "$connected" -eq "$count" ]; then
        echo -e "${GREEN}✓ All clients connected successfully${NC}"
        return 0
    elif [ "$connected" -gt 0 ]; then
        echo -e "${YELLOW}Partial success: $connected/$count${NC}"
        return 0
    else
        echo -e "${RED}No clients connected${NC}"
        return 1
    fi
}

# Main test
echo "clients,connected,active" > "$RESULTS_DIR/summary.csv"

# Test progressive client counts
MAX_SUCCESSFUL=0
for clients in 5 10 15 20 25 30 40 50 60 70 80 90 100 125 150 200 250 300 400 500; do
    if test_clients $clients; then
        MAX_SUCCESSFUL=$clients
        echo ""
    else
        echo -e "${RED}Failed at $clients clients${NC}"
        break
    fi
    
    # Check if we're hitting limits
    QP_COUNT=$(rdma resource show | grep -o "qp [0-9]*" | awk '{print $2}')
    if [ "$QP_COUNT" -gt 500 ]; then
        echo -e "${YELLOW}Approaching QP limit (current: $QP_COUNT)${NC}"
    fi
done

# Final cleanup
cleanup

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Test Results${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${GREEN}Maximum successful clients: $MAX_SUCCESSFUL${NC}"
echo ""
echo "Detailed results:"
cat "$RESULTS_DIR/summary.csv" | column -t -s','
echo ""
echo "Results saved in: $RESULTS_DIR"
echo "Test completed at $(date)"
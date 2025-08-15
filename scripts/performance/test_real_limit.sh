#!/bin/bash

# Find exact RDMA limit by testing progressive client counts
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RESULTS_DIR="rdma_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  RDMA Real Connection Limit Test${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Starting at $(date)"
echo ""

# Clean function
cleanup() {
    sudo killall -9 secure_server secure_client 2>/dev/null || true
    sudo lsof -ti:4433,4791 | xargs -r sudo kill -9 2>/dev/null || true
    sleep 1
}

# Test function
test_count() {
    local n=$1
    echo -e "${YELLOW}Testing $n clients...${NC}"
    
    # Build server
    if [ ! -f "build/secure_server_$n" ]; then
        echo "Building server for $n clients..."
        ./build_configurable_server.sh $n secure_server_$n >/dev/null 2>&1 || return 1
    fi
    
    cleanup
    
    # Start server
    ./build/secure_server_$n > "$RESULTS_DIR/server_$n.log" 2>&1 &
    SPID=$!
    sleep 2
    
    if ! ps -p $SPID > /dev/null; then
        echo -e "${RED}Server failed to start${NC}"
        return 1
    fi
    
    # Launch clients in parallel
    echo "Launching $n clients..."
    for i in $(seq 1 $n); do
        (
            echo -e "send Test$i\nquit" | timeout 5 ./build/secure_client 127.0.0.1 localhost > "$RESULTS_DIR/client_${n}_$i.log" 2>&1
        ) &
        
        # Pace launches
        if [ $((i % 10)) -eq 0 ]; then
            sleep 0.2
        fi
    done
    
    # Wait for connections
    echo "Waiting for all clients to connect..."
    sleep $((n/10 + 3))
    
    # Count successful connections
    local success=$(grep -c "Secure RDMA connection established" "$RESULTS_DIR"/client_${n}_*.log 2>/dev/null | wc -l)
    local server_connected=$(grep -c "RDMA connection established" "$RESULTS_DIR/server_$n.log" 2>/dev/null || echo "0")
    local active=$(grep "Active clients:" "$RESULTS_DIR/server_$n.log" 2>/dev/null | tail -1 | awk '{print $3}' || echo "0")
    
    # Get RDMA stats
    local qps=$(rdma resource show | grep -o "qp [0-9]*" | awk '{print $2}')
    local cqs=$(rdma resource show | grep -o "cq [0-9]*" | awk '{print $2}')
    
    echo "Results: Connected=$success/$n, Server reported=$server_connected, Active=$active, QPs=$qps, CQs=$cqs"
    echo "$n,$success,$server_connected,$active,$qps,$cqs" >> "$RESULTS_DIR/results.csv"
    
    # Cleanup
    kill -TERM $SPID 2>/dev/null || true
    sleep 1
    cleanup
    
    if [ "$success" -eq "$n" ]; then
        echo -e "${GREEN}✓ All $n clients connected successfully${NC}"
        return 0
    elif [ "$success" -gt 0 ]; then
        echo -e "${YELLOW}⚠ Partial success: $success/$n connected${NC}"
        if [ "$success" -lt $((n/2)) ]; then
            return 1
        fi
        return 0
    else
        echo -e "${RED}✗ No clients connected${NC}"
        return 1
    fi
}

# Main test sequence
echo "Requested,Connected,ServerReported,Active,QPs,CQs" > "$RESULTS_DIR/results.csv"

MAX_SUCCESS=0
LAST_FULL_SUCCESS=0

# Test increasing counts
for count in 5 10 15 20 25 30 35 40 45 50 60 70 80 90 100 150 200 250 300 400 500 750 1000; do
    if test_count $count; then
        MAX_SUCCESS=$count
        # Check if all connected
        connected=$(tail -1 "$RESULTS_DIR/results.csv" | cut -d',' -f2)
        if [ "$connected" -eq "$count" ]; then
            LAST_FULL_SUCCESS=$count
        fi
    else
        echo -e "${RED}Stopping at $count clients (failure threshold reached)${NC}"
        break
    fi
    echo ""
done

# Summary
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Final Results${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${GREEN}Maximum clients tested successfully: $MAX_SUCCESS${NC}"
echo -e "${GREEN}Last count with 100% success: $LAST_FULL_SUCCESS${NC}"
echo ""
echo "Full results:"
cat "$RESULTS_DIR/results.csv" | column -t -s','
echo ""
echo "Final RDMA state:"
rdma resource show
echo ""
echo "Results saved in: $RESULTS_DIR"
echo "Completed at $(date)"
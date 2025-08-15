#!/bin/bash

# Test exact RDMA limit between 500-750 clients
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RESULTS_DIR="rdma_exact_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Finding Exact RDMA Limit (500-750)${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Clean function
cleanup() {
    sudo killall -9 secure_server secure_client 2>/dev/null || true
    sudo lsof -ti:4433,4791 | xargs -r sudo kill -9 2>/dev/null || true
    sleep 1
}

# Test function with better error handling
test_clients() {
    local n=$1
    echo -e "${YELLOW}Testing $n clients...${NC}"
    
    # Build server if needed
    if [ ! -f "build/secure_server_$n" ]; then
        echo "Building server for $n clients..."
        ./build_configurable_server.sh $n secure_server_$n >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to build server${NC}"
            return 1
        fi
    fi
    
    cleanup
    
    # Start server
    ./build/secure_server_$n > "$RESULTS_DIR/server_$n.log" 2>&1 &
    SPID=$!
    sleep 2
    
    if ! ps -p $SPID > /dev/null; then
        echo -e "${RED}Server failed to start${NC}"
        cat "$RESULTS_DIR/server_$n.log" | tail -5
        return 1
    fi
    
    # Launch clients with better pacing
    echo "Launching $n clients..."
    SUCCESS_COUNT=0
    FAILED_COUNT=0
    
    for i in $(seq 1 $n); do
        (
            if echo -e "send Test$i\nquit" | timeout 10 ./build/secure_client 127.0.0.1 localhost > "$RESULTS_DIR/client_${n}_$i.log" 2>&1; then
                echo "success" > "$RESULTS_DIR/status_${n}_$i"
            else
                echo "failed" > "$RESULTS_DIR/status_${n}_$i"
            fi
        ) &
        
        # Better pacing for large numbers
        if [ $n -gt 500 ]; then
            if [ $((i % 20)) -eq 0 ]; then
                sleep 0.5
            fi
        elif [ $((i % 10)) -eq 0 ]; then
            sleep 0.2
        fi
    done
    
    # Wait proportionally to client count
    WAIT_TIME=$((n/20 + 10))
    echo "Waiting ${WAIT_TIME}s for connections..."
    sleep $WAIT_TIME
    
    # Count results
    SUCCESS_COUNT=$(grep -l "success" "$RESULTS_DIR"/status_${n}_* 2>/dev/null | wc -l || echo "0")
    FAILED_COUNT=$(grep -l "failed" "$RESULTS_DIR"/status_${n}_* 2>/dev/null | wc -l || echo "0")
    
    # Get RDMA stats
    RDMA_STATS=$(rdma resource show)
    QPS=$(echo "$RDMA_STATS" | grep -o "qp [0-9]*" | awk '{print $2}')
    CQS=$(echo "$RDMA_STATS" | grep -o "cq [0-9]*" | awk '{print $2}')
    MRS=$(echo "$RDMA_STATS" | grep -o "mr [0-9]*" | awk '{print $2}')
    
    echo "Results: Success=$SUCCESS_COUNT, Failed=$FAILED_COUNT, QPs=$QPS, CQs=$CQS, MRs=$MRS"
    echo "$n,$SUCCESS_COUNT,$FAILED_COUNT,$QPS,$CQS,$MRS" >> "$RESULTS_DIR/results.csv"
    echo "$RDMA_STATS" > "$RESULTS_DIR/rdma_stats_$n.txt"
    
    # Kill server
    kill -TERM $SPID 2>/dev/null || true
    sleep 1
    cleanup
    
    # Clean up status files
    rm -f "$RESULTS_DIR"/status_${n}_*
    
    # Determine success
    if [ "$SUCCESS_COUNT" -eq "$n" ]; then
        echo -e "${GREEN}✓ All $n clients connected successfully${NC}"
        return 0
    elif [ "$SUCCESS_COUNT" -gt $((n * 8 / 10)) ]; then
        echo -e "${YELLOW}⚠ High success rate: $SUCCESS_COUNT/$n ($(($SUCCESS_COUNT * 100 / n))%)${NC}"
        return 0
    elif [ "$SUCCESS_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}⚠ Partial success: $SUCCESS_COUNT/$n${NC}"
        return 1
    else
        echo -e "${RED}✗ Complete failure${NC}"
        return 1
    fi
}

# Main test sequence
echo "Requested,Success,Failed,QPs,CQs,MRs" > "$RESULTS_DIR/results.csv"

# Based on previous results, we know:
# - 500 clients: 100% success
# - 750 clients: ~583 connected
# Let's narrow down between 500-750

echo -e "${BLUE}Phase 1: Binary search between 500-750${NC}"
echo ""

# First, confirm 500 still works
test_clients 500
echo ""

# Test midpoint
test_clients 625
echo ""

# Based on 625 result, test either 550 or 700
if [ -f "$RESULTS_DIR/results.csv" ]; then
    LAST_SUCCESS=$(tail -1 "$RESULTS_DIR/results.csv" | cut -d',' -f2)
    LAST_REQUESTED=$(tail -1 "$RESULTS_DIR/results.csv" | cut -d',' -f1)
    
    if [ "$LAST_SUCCESS" -eq "$LAST_REQUESTED" ]; then
        # 625 worked, try higher
        test_clients 700
        echo ""
    else
        # 625 partially failed, try lower
        test_clients 550
        echo ""
        test_clients 575
        echo ""
        test_clients 600
        echo ""
    fi
fi

# Fine-tune around the breaking point
echo -e "${BLUE}Phase 2: Fine-tuning the exact limit${NC}"
echo ""

# Analyze results to find the breaking point
MAX_FULL_SUCCESS=0
MAX_PARTIAL_SUCCESS=0

while IFS=',' read -r requested success failed qps cqs mrs; do
    if [ "$requested" != "Requested" ]; then
        if [ "$success" -eq "$requested" ]; then
            if [ "$requested" -gt "$MAX_FULL_SUCCESS" ]; then
                MAX_FULL_SUCCESS=$requested
            fi
        elif [ "$success" -gt 0 ]; then
            if [ "$requested" -gt "$MAX_PARTIAL_SUCCESS" ]; then
                MAX_PARTIAL_SUCCESS=$requested
            fi
        fi
    fi
done < "$RESULTS_DIR/results.csv"

# Summary
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Final Results${NC}"  
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${GREEN}Maximum clients with 100% success: $MAX_FULL_SUCCESS${NC}"
echo -e "${YELLOW}Maximum clients tested (partial): $MAX_PARTIAL_SUCCESS${NC}"
echo ""
echo "Detailed results:"
cat "$RESULTS_DIR/results.csv" | column -t -s','
echo ""
echo "Current RDMA state:"
rdma resource show
echo ""
echo "Results saved in: $RESULTS_DIR"
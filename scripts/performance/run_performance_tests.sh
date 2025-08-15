#!/bin/bash

# RDMA Performance Testing Script
# Tests scaling from 10 to 10,000+ clients

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test configuration
TEST_RESULTS_DIR="performance_results_$(date +%Y%m%d_%H%M%S)"
SUMMARY_FILE="$TEST_RESULTS_DIR/summary.txt"

# Create results directory
mkdir -p "$TEST_RESULTS_DIR"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  RDMA Performance Testing Suite${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Function to check system resources
check_resources() {
    echo -e "${BLUE}=== System Resources ===${NC}"
    echo "CPU Cores: $(nproc)"
    free -h | grep Mem
    echo "File Descriptors: $(ulimit -n)"
    echo "Max Processes: $(ulimit -u)"
    echo ""
}

# Function to run a single test
run_test() {
    local num_clients=$1
    local test_name=$2
    local extra_args=$3
    
    echo -e "${YELLOW}Running test: $test_name${NC}"
    echo "Clients: $num_clients"
    echo "Timestamp: $(date)"
    echo ""
    
    # Check if we need to adjust server MAX_CLIENTS
    if [ $num_clients -gt 10 ]; then
        echo "Note: Server needs MAX_CLIENTS >= $num_clients"
    fi
    
    # Run the test
    OUTPUT_FILE="$TEST_RESULTS_DIR/test_${num_clients}_clients.txt"
    
    if ./build/performance_test -c $num_clients $extra_args > "$OUTPUT_FILE" 2>&1; then
        echo -e "${GREEN}✓ Test completed successfully${NC}"
        tail -n 20 "$OUTPUT_FILE"
    else
        echo -e "${RED}✗ Test failed${NC}"
        tail -n 10 "$OUTPUT_FILE"
    fi
    
    echo ""
    echo "Results saved to: $OUTPUT_FILE"
    echo "----------------------------------------"
    echo ""
    
    # Add to summary
    echo "=== $test_name ===" >> "$SUMMARY_FILE"
    echo "Clients: $num_clients" >> "$SUMMARY_FILE"
    grep -E "Successful:|Throughput:|Avg Latency:|Peak Memory:|Peak Threads:" "$OUTPUT_FILE" >> "$SUMMARY_FILE" 2>/dev/null || true
    echo "" >> "$SUMMARY_FILE"
    
    # Give system time to recover between tests
    sleep 5
}

# Function to compile performance test
compile_test() {
    echo -e "${BLUE}Compiling performance test...${NC}"
    
    # Add to Makefile if not exists
    if ! grep -q "performance_test" Makefile; then
        cat >> Makefile << 'EOF'

performance_test: src/performance_test.c src/tls_utils.c
	$(CC) $(CFLAGS) $^ -o build/$@ $(LDFLAGS)
EOF
    fi
    
    # Compile
    make performance_test || {
        # Manual compile if Makefile fails
        gcc -o build/performance_test src/performance_test.c src/tls_utils.c \
            -lssl -lcrypto -libverbs -lrdmacm -lpthread
    }
    
    echo -e "${GREEN}✓ Compilation successful${NC}"
    echo ""
}

# Function to prepare server for high client count
prepare_server() {
    local max_clients=$1
    
    echo -e "${BLUE}Preparing server for $max_clients clients...${NC}"
    
    # Create modified server with higher MAX_CLIENTS
    cp src/secure_rdma_server.c src/secure_rdma_server_perf.c
    sed -i "s/#define MAX_CLIENTS.*/#define MAX_CLIENTS $max_clients/" src/secure_rdma_server_perf.c
    
    # Compile modified server
    gcc -o build/secure_server_perf src/secure_rdma_server_perf.c src/tls_utils.c \
        -lssl -lcrypto -libverbs -lrdmacm -lpthread
    
    echo -e "${GREEN}✓ Server prepared${NC}"
    echo ""
}

# Main test execution
main() {
    check_resources
    compile_test
    
    echo -e "${GREEN}Starting Progressive Performance Tests${NC}"
    echo "Results directory: $TEST_RESULTS_DIR"
    echo ""
    
    # Phase 1: Baseline tests
    echo -e "${BLUE}=== Phase 1: Baseline Tests ===${NC}"
    run_test 10 "Baseline (10 clients)" ""
    
    # Phase 2: Scale to 100
    echo -e "${BLUE}=== Phase 2: Scale to 100 ===${NC}"
    prepare_server 100
    run_test 50 "Medium load (50 clients)" "-d 5"
    run_test 100 "High load (100 clients)" "-d 10"
    
    # Phase 3: Scale to 1000 (if resources permit)
    if [ $(ulimit -n) -ge 10000 ]; then
        echo -e "${BLUE}=== Phase 3: Scale to 1000 ===${NC}"
        prepare_server 1000
        run_test 500 "Very high load (500 clients)" "-d 20 -t 50"
        run_test 1000 "Extreme load (1000 clients)" "-d 50 -t 100"
    else
        echo -e "${YELLOW}Skipping 1000+ client tests (insufficient file descriptors)${NC}"
        echo "Current limit: $(ulimit -n)"
        echo "To test 1000+ clients, run: ulimit -n 100000"
    fi
    
    # Phase 4: Find breaking point
    echo -e "${BLUE}=== Phase 4: Finding Breaking Point ===${NC}"
    echo "Testing incremental loads to find system limits..."
    
    for clients in 10 25 50 100 200 500 1000 2000 5000; do
        # Check if we have enough resources
        REQUIRED_FDS=$((clients * 10))
        CURRENT_FDS=$(ulimit -n)
        
        if [ $REQUIRED_FDS -gt $CURRENT_FDS ]; then
            echo -e "${YELLOW}Stopping at $clients clients (needs $REQUIRED_FDS FDs, have $CURRENT_FDS)${NC}"
            break
        fi
        
        # Check available memory
        AVAILABLE_MEM=$(free -m | grep Mem | awk '{print $7}')
        REQUIRED_MEM=$((clients * 10))  # ~10MB per client
        
        if [ $REQUIRED_MEM -gt $AVAILABLE_MEM ]; then
            echo -e "${YELLOW}Stopping at $clients clients (needs ${REQUIRED_MEM}MB, have ${AVAILABLE_MEM}MB available)${NC}"
            break
        fi
        
        prepare_server $clients
        
        # Run test with appropriate delays for large client counts
        if [ $clients -ge 1000 ]; then
            DELAY=$((clients / 20))  # Spread connections over time
            THINK=100  # Longer think time for many clients
        elif [ $clients -ge 100 ]; then
            DELAY=10
            THINK=50
        else
            DELAY=0
            THINK=10
        fi
        
        run_test $clients "Load test ($clients clients)" "-d $DELAY -t $THINK -n 10"
        
        # Check if last test failed
        if [ $? -ne 0 ]; then
            echo -e "${RED}Breaking point found at $clients clients${NC}"
            break
        fi
    done
    
    # Generate final report
    echo -e "${GREEN}=== Final Performance Report ===${NC}"
    cat "$SUMMARY_FILE"
    
    # Analyze results
    echo -e "${BLUE}=== Performance Analysis ===${NC}"
    
    # Find maximum successful client count
    MAX_CLIENTS=$(grep "Successful:" "$TEST_RESULTS_DIR"/*.txt | \
                  grep "100.0%" | \
                  sed 's/.*test_\([0-9]*\)_clients.*/\1/' | \
                  sort -n | \
                  tail -1)
    
    if [ -n "$MAX_CLIENTS" ]; then
        echo "Maximum clients with 100% success: $MAX_CLIENTS"
    fi
    
    # Find point where performance degrades
    echo ""
    echo "Latency progression:"
    grep "Avg Latency:" "$TEST_RESULTS_DIR"/*.txt | \
         sed 's/.*test_\([0-9]*\)_clients.*Avg Latency: \(.*\) ms/\1 clients: \2 ms/'
    
    echo ""
    echo -e "${GREEN}Performance testing complete!${NC}"
    echo "All results saved in: $TEST_RESULTS_DIR"
}

# Run main function
main "$@"
#!/bin/bash

# Comprehensive RDMA Test Suite for AWS Soft-RoCE
# This script runs multiple tests to validate the secure RDMA implementation

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test results
PASSED=0
FAILED=0
TOTAL=0

# Log file
LOG_FILE="rdma_test_results_$(date +%Y%m%d_%H%M%S).log"

# Function to log
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# Function to run a test
run_test() {
    local test_name=$1
    local test_cmd=$2
    local expected=$3
    
    TOTAL=$((TOTAL + 1))
    log "${BLUE}[TEST $TOTAL] $test_name${NC}"
    
    if eval "$test_cmd" >> "$LOG_FILE" 2>&1; then
        if [ ! -z "$expected" ]; then
            if grep -q "$expected" "$LOG_FILE"; then
                log "${GREEN}  ✓ PASSED${NC}"
                PASSED=$((PASSED + 1))
            else
                log "${RED}  ✗ FAILED - Expected output not found${NC}"
                FAILED=$((FAILED + 1))
            fi
        else
            log "${GREEN}  ✓ PASSED${NC}"
            PASSED=$((PASSED + 1))
        fi
    else
        log "${RED}  ✗ FAILED - Command returned error${NC}"
        FAILED=$((FAILED + 1))
    fi
}

# Main test execution
main() {
    log "${CYAN}════════════════════════════════════════════════════════${NC}"
    log "${CYAN}     Secure RDMA Implementation Test Suite${NC}"
    log "${CYAN}     Testing with Soft-RoCE on AWS EC2${NC}"
    log "${CYAN}════════════════════════════════════════════════════════${NC}"
    log ""
    
    # 1. Environment Tests
    log "${YELLOW}=== Phase 1: Environment Verification ===${NC}"
    
    run_test "Check RDMA kernel modules" "lsmod | grep -E 'rdma_rxe|ib_core'" ""
    run_test "Verify RDMA devices exist" "ibv_devices | grep -E 'rxe0|device'" ""
    run_test "Check RDMA device info" "ibv_devinfo -d rxe0" "active_mtu"
    run_test "Verify rdma-core installation" "which ibv_rc_pingpong" ""
    
    # 2. Build Tests
    log ""
    log "${YELLOW}=== Phase 2: Build Verification ===${NC}"
    
    run_test "Clean build environment" "make clean" ""
    run_test "Build secure server" "make secure_server" ""
    run_test "Build secure client" "make secure_client" ""
    run_test "Generate TLS certificates" "make generate-cert" ""
    run_test "Verify certificate validity" "openssl x509 -in server.crt -noout -dates" "notAfter"
    
    # 3. Basic Connectivity Tests
    log ""
    log "${YELLOW}=== Phase 3: Basic RDMA Connectivity ===${NC}"
    
    # Test with ibv_rc_pingpong first
    run_test "RDMA pingpong server start" "timeout 5 ibv_rc_pingpong -d rxe0 -g 0 > /tmp/pingpong_server.log 2>&1 &" ""
    sleep 2
    run_test "RDMA pingpong client connect" "timeout 3 ibv_rc_pingpong -d rxe0 -g 0 localhost" "bytes in"
    
    # 4. Secure RDMA Implementation Tests
    log ""
    log "${YELLOW}=== Phase 4: Secure RDMA Implementation ===${NC}"
    
    # Start server
    log "${BLUE}Starting secure RDMA server...${NC}"
    ./secure_server > server.log 2>&1 &
    SERVER_PID=$!
    sleep 3
    
    # Check server is running
    if ps -p $SERVER_PID > /dev/null; then
        log "${GREEN}  ✓ Server started (PID: $SERVER_PID)${NC}"
        
        # Test 1: Single client connection
        run_test "Single client TLS connection" \
            "echo -e 'quit' | timeout 10 ./secure_client 127.0.0.1 localhost 2>&1" \
            "TLS connection established"
        
        # Test 2: PSN exchange
        run_test "PSN exchange verification" \
            "grep -E 'PSN.*0x[0-9a-f]+' server.log" \
            "PSN"
        
        # Test 3: Send message
        log "${BLUE}Testing message exchange...${NC}"
        echo -e "send Test message from AWS\nquit" | timeout 10 ./secure_client 127.0.0.1 localhost > client1.log 2>&1 &
        CLIENT1_PID=$!
        sleep 2
        
        run_test "Client message send" "grep -E 'Test message' client1.log" ""
        
        # Test 4: Multiple concurrent clients
        log "${BLUE}Testing multiple concurrent clients...${NC}"
        for i in {2..5}; do
            (echo -e "send Client $i message\nquit" | ./secure_client 127.0.0.1 localhost > client$i.log 2>&1) &
            sleep 0.5
        done
        
        sleep 5
        run_test "Multi-client support" "grep -c 'Client.*TLS connection accepted' server.log | grep -E '[2-9]|[0-9]{2,}'" ""
        
        # Test 5: RDMA operations
        run_test "RDMA Write operation" \
            "echo -e 'write RDMA_WRITE_TEST\nquit' | timeout 10 ./secure_client 127.0.0.1 localhost 2>&1" \
            ""
        
        # Kill server
        kill $SERVER_PID 2>/dev/null || true
    else
        log "${RED}  ✗ Server failed to start${NC}"
        FAILED=$((FAILED + 5))
        TOTAL=$((TOTAL + 5))
    fi
    
    # 5. Performance Tests
    log ""
    log "${YELLOW}=== Phase 5: Performance Measurements ===${NC}"
    
    # Bandwidth test with ib_send_bw
    run_test "RDMA bandwidth test setup" "ib_send_bw -d rxe0 > /tmp/bw_server.log 2>&1 &" ""
    sleep 2
    run_test "RDMA bandwidth measurement" "timeout 10 ib_send_bw -d rxe0 localhost" "BW average"
    
    # Latency test with ib_send_lat
    run_test "RDMA latency test setup" "ib_send_lat -d rxe0 > /tmp/lat_server.log 2>&1 &" ""
    sleep 2
    run_test "RDMA latency measurement" "timeout 10 ib_send_lat -d rxe0 localhost" "latency"
    
    # 6. Security Tests
    log ""
    log "${YELLOW}=== Phase 6: Security Validation ===${NC}"
    
    # Check PSN randomness
    log "${BLUE}Testing PSN randomness...${NC}"
    ./secure_server > server_psn1.log 2>&1 &
    PID1=$!
    sleep 2
    kill $PID1 2>/dev/null || true
    
    ./secure_server > server_psn2.log 2>&1 &
    PID2=$!
    sleep 2
    kill $PID2 2>/dev/null || true
    
    PSN1=$(grep -oE "PSN: 0x[0-9a-f]+" server_psn1.log | head -1 | cut -d' ' -f2)
    PSN2=$(grep -oE "PSN: 0x[0-9a-f]+" server_psn2.log | head -1 | cut -d' ' -f2)
    
    if [ "$PSN1" != "$PSN2" ] && [ ! -z "$PSN1" ] && [ ! -z "$PSN2" ]; then
        log "${GREEN}  ✓ PSN values are random (PSN1: $PSN1, PSN2: $PSN2)${NC}"
        PASSED=$((PASSED + 1))
    else
        log "${RED}  ✗ PSN randomness check failed${NC}"
        FAILED=$((FAILED + 1))
    fi
    TOTAL=$((TOTAL + 1))
    
    # Check TLS version
    run_test "TLS version >= 1.2" \
        "echo | openssl s_client -connect localhost:4433 2>/dev/null | grep -E 'TLSv1.[23]'" \
        ""
    
    # 7. Stress Tests
    log ""
    log "${YELLOW}=== Phase 7: Stress Testing ===${NC}"
    
    # Start server for stress test
    ./secure_server > stress_server.log 2>&1 &
    STRESS_PID=$!
    sleep 3
    
    if ps -p $STRESS_PID > /dev/null; then
        # Rapid connect/disconnect
        log "${BLUE}Testing rapid connections...${NC}"
        for i in {1..20}; do
            (echo "quit" | timeout 2 ./secure_client 127.0.0.1 localhost > /dev/null 2>&1) &
        done
        wait
        
        run_test "Server stability after stress" "ps -p $STRESS_PID" ""
        
        kill $STRESS_PID 2>/dev/null || true
    fi
    
    # Summary
    log ""
    log "${CYAN}════════════════════════════════════════════════════════${NC}"
    log "${CYAN}                    TEST SUMMARY${NC}"
    log "${CYAN}════════════════════════════════════════════════════════${NC}"
    log "Total Tests: $TOTAL"
    log "${GREEN}Passed: $PASSED${NC}"
    log "${RED}Failed: $FAILED${NC}"
    
    if [ $FAILED -eq 0 ]; then
        log ""
        log "${GREEN}🎉 ALL TESTS PASSED! 🎉${NC}"
        log "${GREEN}Your secure RDMA implementation is working correctly!${NC}"
        exit 0
    else
        log ""
        log "${YELLOW}⚠️  Some tests failed. Check $LOG_FILE for details.${NC}"
        exit 1
    fi
}

# Check if we're on an EC2 instance with RDMA
if ! command -v ibv_devices &> /dev/null; then
    log "${RED}Error: RDMA tools not found. This script must run on an EC2 instance with Soft-RoCE configured.${NC}"
    log "Run deploy_aws_softrce.sh first to set up the environment."
    exit 1
fi

# Run main test suite
main
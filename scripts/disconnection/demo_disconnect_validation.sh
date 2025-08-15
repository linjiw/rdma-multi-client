#!/bin/bash

# Comprehensive Three-Way Handshake Disconnection Validation Demo
# This script validates and demonstrates the graceful disconnection protocol

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# Results tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Function to print section headers
print_header() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${BOLD}  $1${NC}${CYAN}${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Function to print test results
check_result() {
    local test_name=$1
    local condition=$2
    ((TOTAL_TESTS++))
    
    if [ $condition -eq 0 ]; then
        echo -e "${GREEN}  ✓${NC} $test_name"
        ((PASSED_TESTS++))
    else
        echo -e "${RED}  ✗${NC} $test_name"
        ((FAILED_TESTS++))
    fi
}

# Clean up function
cleanup() {
    sudo killall -9 secure_server secure_client 2>/dev/null || true
    sudo lsof -ti:4433,4791 | xargs -r sudo kill -9 2>/dev/null || true
    sleep 1
}

# Validate prerequisites
validate_prerequisites() {
    print_header "VALIDATING PREREQUISITES"
    
    # Check if binaries exist
    if [ -f "build/secure_server" ] && [ -f "build/secure_client" ]; then
        check_result "Binaries exist" 0
    else
        check_result "Binaries exist" 1
        echo -e "${RED}Please run 'make all' first${NC}"
        exit 1
    fi
    
    # Check for RDMA device
    if rdma link show 2>/dev/null | grep -q "rxe0"; then
        check_result "Soft-RoCE device available" 0
    else
        echo -e "${YELLOW}Setting up Soft-RoCE...${NC}"
        sudo modprobe rdma_rxe 2>/dev/null || true
        sudo rdma link add rxe0 type rxe netdev ens5 2>/dev/null || true
        if rdma link show 2>/dev/null | grep -q "rxe0"; then
            check_result "Soft-RoCE device configured" 0
        else
            check_result "Soft-RoCE device configured" 1
        fi
    fi
    
    # Check ports are free
    cleanup
    if ! sudo lsof -ti:4433,4791 2>/dev/null | grep -q .; then
        check_result "Ports 4433/4791 available" 0
    else
        check_result "Ports 4433/4791 available" 1
    fi
}

# Test 1: Basic Three-Way Handshake
test_basic_handshake() {
    print_header "TEST 1: BASIC THREE-WAY HANDSHAKE"
    
    echo -e "${YELLOW}Starting server...${NC}"
    # Use stdbuf to disable buffering and capture all output
    stdbuf -o0 -e0 ./build/secure_server > server_test1.log 2>&1 &
    SERVER_PID=$!
    sleep 2
    
    if ! ps -p $SERVER_PID > /dev/null; then
        echo -e "${RED}Server failed to start${NC}"
        cat server_test1.log
        return 1
    fi
    
    echo -e "${YELLOW}Connecting client and initiating disconnection...${NC}"
    (
        echo "send Test Message for Validation"
        sleep 1
        echo "quit"
    ) | ./build/secure_client 127.0.0.1 localhost > client_test1.log 2>&1
    
    # Wait a bit longer to ensure all server output is written
    sleep 4
    
    # Kill server gracefully to flush output
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    
    echo -e "\n${BOLD}Validation Points:${NC}"
    
    # Validate client-side protocol
    grep -q "INITIATING GRACEFUL DISCONNECTION" client_test1.log
    check_result "Client: Disconnection initiated" $?
    
    grep -q "\[1/3\] → Sent DISCONNECT_REQ" client_test1.log
    check_result "Client: Step 1 - DISCONNECT_REQ sent" $?
    
    grep -q "\[2/3\] ← Received DISCONNECT_ACK" client_test1.log
    check_result "Client: Step 2 - DISCONNECT_ACK received" $?
    
    grep -q "\[3/3\] → Sent DISCONNECT_FIN" client_test1.log
    check_result "Client: Step 3 - DISCONNECT_FIN sent" $?
    
    grep -q "GRACEFUL DISCONNECTION COMPLETE" client_test1.log
    check_result "Client: Disconnection completed" $?
    
    # Validate server-side protocol
    grep -q "GRACEFUL DISCONNECTION INITIATED" server_test1.log
    check_result "Server: Disconnection initiated" $?
    
    grep -q "Received DISCONNECT_REQ" server_test1.log
    check_result "Server: Step 1 - DISCONNECT_REQ received" $?
    
    grep -q "Sent DISCONNECT_ACK" server_test1.log
    check_result "Server: Step 2 - DISCONNECT_ACK sent" $?
    
    grep -q "Received DISCONNECT_FIN" server_test1.log
    check_result "Server: Step 3 - DISCONNECT_FIN received" $?
    
    grep -q "GRACEFUL DISCONNECTION COMPLETE" server_test1.log
    check_result "Server: Disconnection completed" $?
    
    # Clean up (server already killed above)
    sleep 1
}

# Test 2: Multiple Concurrent Disconnections
test_concurrent_disconnections() {
    print_header "TEST 2: CONCURRENT DISCONNECTIONS"
    
    echo -e "${YELLOW}Starting server...${NC}"
    stdbuf -o0 -e0 ./build/secure_server > server_test2.log 2>&1 &
    SERVER_PID=$!
    sleep 2
    
    echo -e "${YELLOW}Launching 3 clients concurrently...${NC}"
    
    for i in {1..3}; do
        (
            echo "send Client $i message"
            sleep $i
            echo "quit"
        ) | ./build/secure_client 127.0.0.1 localhost > client_test2_$i.log 2>&1 &
        CLIENT_PIDS[$i]=$!
        sleep 0.5
    done
    
    # Wait for all clients to complete
    for i in {1..3}; do
        wait ${CLIENT_PIDS[$i]} 2>/dev/null || true
    done
    
    # Wait longer for all disconnections to complete
    sleep 5
    
    # Kill server to flush output
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    
    echo -e "\n${BOLD}Validation Points:${NC}"
    
    # Check each client completed handshake
    for i in {1..3}; do
        if grep -q "GRACEFUL DISCONNECTION COMPLETE" client_test2_$i.log; then
            check_result "Client $i: Completed handshake" 0
        else
            check_result "Client $i: Completed handshake" 1
        fi
    done
    
    # Check server handled all disconnections
    DISCONNECT_COUNT=$(grep -c "GRACEFUL DISCONNECTION COMPLETE" server_test2.log)
    if [ "$DISCONNECT_COUNT" -eq 3 ]; then
        check_result "Server: Handled all 3 disconnections" 0
    else
        check_result "Server: Handled all 3 disconnections (got $DISCONNECT_COUNT)" 1
    fi
    
    # Clean up (server already killed above)
    sleep 1
}

# Test 3: Protocol Message Ordering
test_message_ordering() {
    print_header "TEST 3: PROTOCOL MESSAGE ORDERING"
    
    echo -e "${YELLOW}Starting server...${NC}"
    stdbuf -o0 -e0 ./build/secure_server > server_test3.log 2>&1 &
    SERVER_PID=$!
    sleep 2
    
    echo -e "${YELLOW}Testing message sequence...${NC}"
    
    (
        echo "send First normal message"
        sleep 0.5
        echo "send Second normal message"
        sleep 0.5
        echo "quit"
    ) | ./build/secure_client 127.0.0.1 localhost > client_test3.log 2>&1
    
    # Wait for completion and kill server to flush output
    sleep 4
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    
    echo -e "\n${BOLD}Validation Points:${NC}"
    
    # Extract message sequence from server log
    grep -E "Received:|DISCONNECT" server_test3.log > server_messages.txt
    
    # Validate ordering
    LINE_NUM=1
    NORMAL_MSG_COUNT=0
    DISCONNECT_STARTED=0
    
    while IFS= read -r line; do
        if echo "$line" | grep -q "Received: First normal message"; then
            ((NORMAL_MSG_COUNT++))
            if [ $DISCONNECT_STARTED -eq 0 ]; then
                check_result "Normal message 1 before disconnect" 0
            else
                check_result "Normal message 1 before disconnect" 1
            fi
        elif echo "$line" | grep -q "Received: Second normal message"; then
            ((NORMAL_MSG_COUNT++))
            if [ $DISCONNECT_STARTED -eq 0 ]; then
                check_result "Normal message 2 before disconnect" 0
            else
                check_result "Normal message 2 before disconnect" 1
            fi
        elif echo "$line" | grep -q "Received: \$\$DISCONNECT_REQ\$\$"; then
            DISCONNECT_STARTED=1
            if [ $NORMAL_MSG_COUNT -eq 2 ]; then
                check_result "DISCONNECT_REQ after normal messages" 0
            else
                check_result "DISCONNECT_REQ after normal messages" 1
            fi
        fi
    done < server_messages.txt
    
    # Clean up (server already killed above)
    rm -f server_messages.txt
    sleep 1
}

# Test 4: Resource Cleanup Validation
test_resource_cleanup() {
    print_header "TEST 4: RESOURCE CLEANUP VALIDATION"
    
    echo -e "${YELLOW}Checking initial RDMA resources...${NC}"
    INITIAL_QPS=$(rdma resource show | grep -o "qp [0-9]*" | awk '{print $2}')
    INITIAL_CQS=$(rdma resource show | grep -o "cq [0-9]*" | awk '{print $2}')
    echo "Initial: QPs=$INITIAL_QPS, CQs=$INITIAL_CQS"
    
    echo -e "${YELLOW}Starting server...${NC}"
    stdbuf -o0 -e0 ./build/secure_server > server_test4.log 2>&1 &
    SERVER_PID=$!
    sleep 2
    
    echo -e "${YELLOW}Connecting and disconnecting client...${NC}"
    (
        echo "send Resource test"
        sleep 1
        echo "quit"
    ) | ./build/secure_client 127.0.0.1 localhost > client_test4.log 2>&1
    
    # Wait for disconnection to complete
    sleep 4
    
    # Kill server to ensure cleanup
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    sleep 1
    
    echo -e "${YELLOW}Checking RDMA resources after disconnection...${NC}"
    AFTER_QPS=$(rdma resource show | grep -o "qp [0-9]*" | awk '{print $2}')
    AFTER_CQS=$(rdma resource show | grep -o "cq [0-9]*" | awk '{print $2}')
    echo "After: QPs=$AFTER_QPS, CQs=$AFTER_CQS"
    
    echo -e "\n${BOLD}Validation Points:${NC}"
    
    # Check if resources were properly cleaned up
    if [ "$INITIAL_QPS" -eq "$AFTER_QPS" ]; then
        check_result "QPs properly cleaned up" 0
    else
        check_result "QPs properly cleaned up (leaked $((AFTER_QPS - INITIAL_QPS)))" 1
    fi
    
    if [ "$INITIAL_CQS" -eq "$AFTER_CQS" ]; then
        check_result "CQs properly cleaned up" 0
    else
        check_result "CQs properly cleaned up (leaked $((AFTER_CQS - INITIAL_CQS)))" 1
    fi
    
    # Check cleanup messages
    grep -q "Graceful disconnection completed successfully" server_test4.log
    check_result "Server reported graceful cleanup" $?
    
    # Clean up (server already killed above)
    sleep 1
}

# Live Demo
live_demo() {
    print_header "LIVE DEMONSTRATION"
    
    echo -e "${YELLOW}This is a live, interactive demonstration of the three-way handshake.${NC}"
    echo -e "${YELLOW}Watch the protocol messages in real-time!${NC}\n"
    
    # Start server in a visible way
    echo -e "${CYAN}[Terminal 1 - SERVER]${NC}"
    echo -e "${YELLOW}Starting RDMA server...${NC}"
    
    # Use script to capture colored output
    script -q -c "./build/secure_server" server_demo.log &
    SERVER_PID=$!
    sleep 3
    
    echo -e "\n${CYAN}[Terminal 2 - CLIENT]${NC}"
    echo -e "${YELLOW}Starting RDMA client...${NC}"
    echo -e "${YELLOW}The client will:${NC}"
    echo -e "  1. Connect to server"
    echo -e "  2. Send a test message"
    echo -e "  3. Initiate graceful disconnection"
    echo -e "  4. Complete three-way handshake\n"
    
    sleep 2
    
    # Run client with visible output
    (
        echo "send DEMO: Testing three-way handshake disconnection"
        sleep 2
        echo "quit"
    ) | ./build/secure_client 127.0.0.1 localhost
    
    sleep 2
    
    # Kill server
    kill $SERVER_PID 2>/dev/null || true
    
    echo -e "\n${GREEN}Demo completed! Check the visual protocol indicators above.${NC}"
}

# Main execution
main() {
    clear
    echo -e "${BOLD}${MAGENTA}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║     THREE-WAY HANDSHAKE DISCONNECTION PROTOCOL VALIDATION       ║"
    echo "║                                                                  ║"
    echo "║  This comprehensive validation suite verifies the correctness   ║"
    echo "║  of the graceful disconnection protocol implementation.         ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Run all validations
    validate_prerequisites
    test_basic_handshake
    test_concurrent_disconnections
    test_message_ordering
    test_resource_cleanup
    
    # Print summary
    print_header "VALIDATION SUMMARY"
    
    echo -e "${BOLD}Test Results:${NC}"
    echo -e "  Total Tests: ${TOTAL_TESTS}"
    echo -e "  ${GREEN}Passed: ${PASSED_TESTS}${NC}"
    echo -e "  ${RED}Failed: ${FAILED_TESTS}${NC}"
    
    if [ $FAILED_TESTS -eq 0 ]; then
        echo -e "\n${GREEN}${BOLD}✓ ALL VALIDATIONS PASSED!${NC}"
        echo -e "${GREEN}The three-way handshake disconnection protocol is working correctly.${NC}"
    else
        echo -e "\n${RED}${BOLD}✗ SOME VALIDATIONS FAILED${NC}"
        echo -e "${RED}Please review the failures above.${NC}"
    fi
    
    # Skip interactive prompt during automated runs
    if [ -t 0 ]; then
        # Only ask if running interactively
        echo -e "\n${YELLOW}Would you like to see a live demonstration? (y/n)${NC}"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            live_demo
        fi
    fi
    
    # Cleanup
    cleanup
    rm -f server_test*.log client_test*.log server_demo.log
    
    echo -e "\n${CYAN}Validation complete. All temporary files cleaned up.${NC}"
}

# Run main
main
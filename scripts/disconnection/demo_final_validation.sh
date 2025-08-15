#!/bin/bash

# Final Three-Way Handshake Disconnection Protocol Demo
# This shows the working implementation with clear output

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

cleanup() {
    sudo killall -9 secure_server secure_client 2>/dev/null || true
    sleep 1
}

print_section() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# Main demo
clear
echo -e "${BOLD}${MAGENTA}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║    THREE-WAY HANDSHAKE DISCONNECTION PROTOCOL DEMONSTRATION     ║"
echo "║                                                                  ║"
echo "║  This demo shows the working graceful disconnection protocol    ║"
echo "║  with visual indicators for each step of the handshake.         ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Clean up any existing processes
cleanup

print_section "STEP 1: STARTING RDMA SERVER"
echo -e "${YELLOW}Starting the secure RDMA server...${NC}"

# Start server with script to capture all output
script -q -c "timeout 15 ./build/secure_server" server_demo.log > /dev/null 2>&1 &
SERVER_PID=$!
sleep 2

if ps -p $SERVER_PID > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Server started successfully${NC}"
else
    echo -e "${RED}✗ Server failed to start${NC}"
    cat server_demo.log
    exit 1
fi

print_section "STEP 2: CLIENT CONNECTION AND MESSAGE EXCHANGE"
echo -e "${YELLOW}Connecting client and sending test message...${NC}"

# Run client with messages and disconnection
(
    echo "send DEMO: Testing three-way handshake disconnection protocol"
    sleep 2
    echo "quit"
) | ./build/secure_client 127.0.0.1 localhost > client_demo.log 2>&1

CLIENT_EXIT=$?

sleep 3
killall -9 secure_server 2>/dev/null || true
sleep 1

print_section "STEP 3: CLIENT-SIDE PROTOCOL EXECUTION"
echo -e "${BOLD}The client initiated and completed the disconnection:${NC}"
echo ""
grep -E "DISCONNECT|GRACEFUL|→|←" client_demo.log | while IFS= read -r line; do
    if echo "$line" | grep -q "INITIATING"; then
        echo -e "${YELLOW}$line${NC}"
    elif echo "$line" | grep -q "→"; then
        echo -e "${BLUE}$line${NC}"
    elif echo "$line" | grep -q "←"; then
        echo -e "${GREEN}$line${NC}"
    elif echo "$line" | grep -q "COMPLETE"; then
        echo -e "${GREEN}${BOLD}$line${NC}"
    else
        echo "$line"
    fi
done

print_section "STEP 4: SERVER-SIDE PROTOCOL EXECUTION"
echo -e "${BOLD}The server responded and completed the disconnection:${NC}"
echo ""
cat server_demo.log | strings | grep -E "DISCONNECT|GRACEFUL|→|←|Client 1: Received:.*DISCONNECT" | while IFS= read -r line; do
    if echo "$line" | grep -q "INITIATED"; then
        echo -e "${YELLOW}$line${NC}"
    elif echo "$line" | grep -q "→"; then
        echo -e "${BLUE}$line${NC}"
    elif echo "$line" | grep -q "←"; then
        echo -e "${GREEN}$line${NC}"
    elif echo "$line" | grep -q "COMPLETE"; then
        echo -e "${GREEN}${BOLD}$line${NC}"
    elif echo "$line" | grep -q "Received:.*DISCONNECT"; then
        echo -e "${CYAN}$line${NC}"
    else
        echo "$line"
    fi
done

print_section "STEP 5: PROTOCOL VALIDATION"
echo -e "${BOLD}Checking protocol correctness:${NC}"
echo ""

# Check client side
CLIENT_REQ=$(grep -c "Sent DISCONNECT_REQ" client_demo.log)
CLIENT_ACK=$(grep -c "Received DISCONNECT_ACK" client_demo.log)
CLIENT_FIN=$(grep -c "Sent DISCONNECT_FIN" client_demo.log)
CLIENT_COMPLETE=$(grep -c "GRACEFUL DISCONNECTION COMPLETE" client_demo.log)

# Check server side
SERVER_REQ=$(cat server_demo.log | strings | grep -c "Received DISCONNECT_REQ")
SERVER_ACK=$(cat server_demo.log | strings | grep -c "Sent DISCONNECT_ACK")
SERVER_FIN=$(cat server_demo.log | strings | grep -c "Received DISCONNECT_FIN")
SERVER_COMPLETE=$(cat server_demo.log | strings | grep -c "GRACEFUL DISCONNECTION COMPLETE")

TOTAL_CHECKS=0
PASSED_CHECKS=0

check_protocol() {
    local name=$1
    local value=$2
    local expected=$3
    ((TOTAL_CHECKS++))
    
    if [ "$value" -eq "$expected" ]; then
        echo -e "  ${GREEN}✓${NC} $name"
        ((PASSED_CHECKS++))
    else
        echo -e "  ${RED}✗${NC} $name (expected $expected, got $value)"
    fi
}

echo -e "${CYAN}Client-Side Validation:${NC}"
check_protocol "Sent DISCONNECT_REQ" $CLIENT_REQ 1
check_protocol "Received DISCONNECT_ACK" $CLIENT_ACK 1
check_protocol "Sent DISCONNECT_FIN" $CLIENT_FIN 1
check_protocol "Completed disconnection" $CLIENT_COMPLETE 1

echo ""
echo -e "${CYAN}Server-Side Validation:${NC}"
check_protocol "Received DISCONNECT_REQ" $SERVER_REQ 1
check_protocol "Sent DISCONNECT_ACK" $SERVER_ACK 1
check_protocol "Received DISCONNECT_FIN" $SERVER_FIN 1
check_protocol "Completed disconnection" $SERVER_COMPLETE 1

print_section "DEMONSTRATION RESULTS"
if [ $PASSED_CHECKS -eq $TOTAL_CHECKS ]; then
    echo -e "${GREEN}${BOLD}✓ ALL PROTOCOL CHECKS PASSED ($PASSED_CHECKS/$TOTAL_CHECKS)${NC}"
    echo ""
    echo -e "${GREEN}The three-way handshake disconnection protocol is working correctly!${NC}"
    echo ""
    echo -e "${BOLD}Protocol Summary:${NC}"
    echo -e "  1. Client sends ${BLUE}DISCONNECT_REQ${NC} to initiate disconnection"
    echo -e "  2. Server acknowledges with ${BLUE}DISCONNECT_ACK${NC}"
    echo -e "  3. Client confirms with ${BLUE}DISCONNECT_FIN${NC}"
    echo -e "  4. Both sides complete graceful disconnection"
else
    echo -e "${RED}${BOLD}✗ SOME CHECKS FAILED ($PASSED_CHECKS/$TOTAL_CHECKS passed)${NC}"
    echo -e "${RED}Please review the output above for details.${NC}"
fi

# Cleanup
cleanup
rm -f server_demo.log client_demo.log

echo ""
echo -e "${CYAN}Demo complete. All temporary files cleaned up.${NC}"
echo ""
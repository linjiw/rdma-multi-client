#!/bin/bash

# Safe demo runner - doesn't call cleanup script to avoid recursion

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

DEMO_DIR="/home/ubuntu/rdma-project"
LOGS_DIR="$DEMO_DIR/demo_logs"

# Simple cleanup
echo -e "${YELLOW}Cleaning up any existing processes...${NC}"
pkill -f secure_server 2>/dev/null
pkill -f secure_client 2>/dev/null
sleep 2

# Create logs directory
mkdir -p $LOGS_DIR
rm -f $LOGS_DIR/*.log

echo -e "${WHITE}════════════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}      RDMA Pure IB Verbs Demo - 10 Client Alphabet Test      ${NC}"
echo -e "${WHITE}════════════════════════════════════════════════════════════${NC}"
echo ""

# Start server
echo -e "${YELLOW}Starting RDMA Server...${NC}"
cd $DEMO_DIR
./build/secure_server > $LOGS_DIR/server.log 2>&1 &
SERVER_PID=$!

sleep 3

if ! ps -p $SERVER_PID > /dev/null; then
    echo -e "${RED}Server failed to start${NC}"
    cat $LOGS_DIR/server.log | head -10
    exit 1
fi

echo -e "${GREEN}✓ Server started (PID: $SERVER_PID)${NC}"
echo ""

# Launch 10 clients
echo -e "${CYAN}Launching 10 clients with alphabet patterns:${NC}"
LETTERS=("a" "b" "c" "d" "e" "f" "g" "h" "i" "j")

for i in {1..10}; do
    LETTER=${LETTERS[$((i-1))]}
    MESSAGE=$(printf "%0.s$LETTER" {1..100})
    
    echo -e "  Client $i → Sending 100 × '$LETTER'"
    
    {
        echo "send Client_${i}_Data:${MESSAGE}"
        sleep 0.2
        echo "quit"
    } | ./build/secure_client 127.0.0.1 localhost > $LOGS_DIR/client_$i.log 2>&1 &
    
    sleep 0.3
done

# Wait for completion
echo ""
echo -e "${YELLOW}Waiting for transmissions...${NC}"
sleep 8

# Analysis
echo ""
echo -e "${WHITE}═══ RESULTS ═══${NC}"
echo ""

# PSN Values
echo -e "${CYAN}PSN Values:${NC}"
for i in {1..10}; do
    if [ -f $LOGS_DIR/client_$i.log ]; then
        PSN_LINE=$(grep "Local PSN:" $LOGS_DIR/client_$i.log 2>/dev/null | head -1)
        if [ ! -z "$PSN_LINE" ]; then
            LOCAL_PSN=$(echo $PSN_LINE | awk '{print $3}' | tr -d ',')
            SERVER_PSN=$(echo $PSN_LINE | awk '{print $6}')
            printf "  Client %2d: PSN ${GREEN}%-10s${NC} ↔ Server PSN ${MAGENTA}%-10s${NC}\n" $i "$LOCAL_PSN" "$SERVER_PSN"
        fi
    fi
done

echo ""

# Message verification
echo -e "${CYAN}Message Verification:${NC}"
SUCCESS=0
for i in {1..10}; do
    LETTER=${LETTERS[$((i-1))]}
    PATTERN=$(printf "%0.s$LETTER" {1..100})
    
    if grep -q "Client_${i}_Data:$PATTERN" $LOGS_DIR/server.log 2>/dev/null; then
        echo -e "  Client $i: ${GREEN}✓${NC} 100×'$LETTER' received"
        ((SUCCESS++))
    else
        echo -e "  Client $i: ${RED}✗${NC} Message not found"
    fi
done

echo ""
echo -e "${WHITE}Summary:${NC}"
echo "  • Clients connected: $SUCCESS/10"

# PSN uniqueness
UNIQUE_PSN=$(grep "Local PSN:" $LOGS_DIR/client_*.log 2>/dev/null | awk '{print $3}' | tr -d ',' | sort -u | wc -l)
TOTAL_PSN=$(grep "Local PSN:" $LOGS_DIR/client_*.log 2>/dev/null | wc -l)
echo "  • PSN uniqueness: $UNIQUE_PSN unique out of $TOTAL_PSN"

# Shared device
if grep -q "Opened shared RDMA device" $LOGS_DIR/server.log; then
    echo -e "  • Resource: ${GREEN}✓${NC} Shared device context"
fi

echo ""
echo -e "${GREEN}Demo complete!${NC}"
echo "Logs: $LOGS_DIR/"

# Cleanup
pkill -f secure_server 2>/dev/null
pkill -f secure_client 2>/dev/null
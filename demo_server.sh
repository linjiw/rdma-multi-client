#!/bin/bash

# Demo Server Wrapper - Enhanced display for demo
# Shows real-time connections and messages

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Clean up function
cleanup() {
    echo -e "\n${YELLOW}Shutting down demo server...${NC}"
    pkill -f secure_server
    exit 0
}

trap cleanup INT TERM

# Clear screen for demo
clear

# Header
echo -e "${WHITE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${WHITE}║         RDMA Pure IB Verbs Demo - Secure PSN Exchange         ║${NC}"
echo -e "${WHITE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${CYAN}Architecture:${NC}"
echo "• Pure IB Verbs (no RDMA CM)"
echo "• TLS-based PSN exchange (Port 4433)"
echo "• Shared device context optimization"
echo "• 10 concurrent client support"
echo ""

echo -e "${YELLOW}Starting RDMA Server...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Create named pipe for server output
PIPE=$(mktemp -u)
mkfifo $PIPE

# Start server with output processing
./build/secure_server 2>&1 > $PIPE &
SERVER_PID=$!

# Process server output
{
    while IFS= read -r line; do
        # Format different types of messages
        if [[ $line == *"Opened shared RDMA device"* ]]; then
            echo -e "${GREEN}✓ Device: ${line#*: }${NC}"
        elif [[ $line == *"TLS server listening"* ]]; then
            echo -e "${GREEN}✓ TLS Server Ready (Port 4433)${NC}"
        elif [[ $line == *"Client"*"TLS connection accepted"* ]]; then
            CLIENT_NUM=$(echo $line | grep -o "Client [0-9]*" | grep -o "[0-9]*")
            echo -e "${BLUE}→ Client $CLIENT_NUM: TLS handshake initiated${NC}"
        elif [[ $line == *"PSN Exchange"* ]]; then
            echo -e "${MAGENTA}  🔐 $line${NC}"
        elif [[ $line == *"QP created successfully"* ]]; then
            QP_NUM=$(echo $line | grep -o "QP num: [0-9]*" | grep -o "[0-9]*")
            CLIENT_NUM=$(echo $line | grep -o "Client [0-9]*" | grep -o "[0-9]*")
            echo -e "${GREEN}  ✓ Client $CLIENT_NUM: QP created (QPN: $QP_NUM)${NC}"
        elif [[ $line == *"Using shared RDMA device"* ]]; then
            echo -e "${CYAN}  ↳ $line${NC}"
        elif [[ $line == *"connection established"* ]]; then
            CLIENT_NUM=$(echo $line | grep -o "Client [0-9]*" | grep -o "[0-9]*")
            echo -e "${GREEN}✓ Client $CLIENT_NUM: RDMA connection ready${NC}"
        elif [[ $line == *"Received RDMA message"* ]]; then
            # Extract client and message
            if [[ $line == *"Client_"*"_Pattern:"* ]]; then
                CLIENT_NUM=$(echo $line | sed -n 's/.*Client_\([0-9]*\)_Pattern:.*/\1/p')
                MESSAGE=$(echo $line | sed -n 's/.*Pattern:\(.*\)/\1/p' | head -c 20)
                echo -e "${WHITE}📨 Client $CLIENT_NUM sent: ${MESSAGE}... (100 chars)${NC}"
            fi
        elif [[ $line == *"RDMA write completed"* ]]; then
            if [[ $line == *"RDMA_Write_"* ]]; then
                CLIENT_NUM=$(echo $line | sed -n 's/.*RDMA_Write_\([0-9]*\).*/\1/p')
                echo -e "${WHITE}📝 Client $CLIENT_NUM: RDMA write completed${NC}"
            fi
        elif [[ $line == *"Active clients:"* ]]; then
            ACTIVE=$(echo $line | grep -o "[0-9]*" | head -1)
            echo -e "${YELLOW}👥 Active connections: $ACTIVE/10${NC}"
        elif [[ $line == *"disconnected"* ]]; then
            CLIENT_NUM=$(echo $line | grep -o "Client [0-9]*" | grep -o "[0-9]*")
            echo -e "${YELLOW}← Client $CLIENT_NUM: Disconnected${NC}"
        fi
    done
} < $PIPE &

# Monitor server process
while ps -p $SERVER_PID > /dev/null; do
    sleep 1
done

# Cleanup
rm -f $PIPE
echo -e "\n${RED}Server stopped${NC}"
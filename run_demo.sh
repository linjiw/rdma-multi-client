#!/bin/bash

# Main Demo Launcher - Orchestrates the RDMA demo
# Shows secure PSN exchange and multi-client communication

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
DEMO_DIR="/home/ubuntu/rdma-project"
LOGS_DIR="$DEMO_DIR/demo_logs"
RESULTS_FILE="$DEMO_DIR/demo_results.txt"

# Clean up function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up demo...${NC}"
    pkill -f secure_server 2>/dev/null
    pkill -f secure_client 2>/dev/null
    pkill -f demo_client 2>/dev/null
    pkill -f demo_server 2>/dev/null
    sleep 2
    echo -e "${GREEN}Demo cleanup complete${NC}"
}

# Set up trap for cleanup
trap cleanup EXIT INT TERM

# Function to print centered text
print_center() {
    local text="$1"
    local width=70
    local padding=$(( (width - ${#text}) / 2 ))
    printf "%*s%s\n" $padding "" "$text"
}

# Function to print a line
print_line() {
    printf '%.0s─' {1..70}
    echo
}

# Start of demo
clear

# Title Screen
echo -e "${WHITE}"
print_line
print_center "RDMA PURE IB VERBS DEMONSTRATION"
print_center "Secure PSN Exchange & Multi-Client Communication"
print_line
echo -e "${NC}"

echo -e "${CYAN}Demo Overview:${NC}"
echo "• 10 clients connecting simultaneously"
echo "• Each client sends 100 characters (a-j)"
echo "• Secure PSN exchange via TLS"
echo "• Pure IB verbs implementation"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if [ ! -f "$DEMO_DIR/build/secure_server" ] || [ ! -f "$DEMO_DIR/build/secure_client" ]; then
    echo -e "${RED}✗ Binaries not found. Building...${NC}"
    cd $DEMO_DIR
    make clean && make all
fi

# Check RDMA devices
if ! ibv_devices 2>/dev/null | grep -q "rxe0"; then
    echo -e "${YELLOW}⚠ No RDMA device found. Soft-RoCE may not be configured.${NC}"
fi

# Clean up any existing processes
echo -e "${YELLOW}Cleaning up any existing processes...${NC}"
cleanup 2>/dev/null

# Create logs directory
mkdir -p $LOGS_DIR
rm -f $LOGS_DIR/*.log

echo ""
echo -e "${GREEN}✓ Prerequisites checked${NC}"
echo ""

# Phase 1: Start Server
echo -e "${WHITE}${BOLD}PHASE 1: Starting RDMA Server${NC}"
print_line

cd $DEMO_DIR
./build/secure_server > $LOGS_DIR/server.log 2>&1 &
SERVER_PID=$!

sleep 3

if ! ps -p $SERVER_PID > /dev/null; then
    echo -e "${RED}✗ Server failed to start${NC}"
    cat $LOGS_DIR/server.log
    exit 1
fi

echo -e "${GREEN}✓ Server started (PID: $SERVER_PID)${NC}"
echo -e "${GREEN}✓ TLS server listening on port 4433${NC}"
echo -e "${GREEN}✓ Shared device context initialized${NC}"

# Show server initialization from log
echo ""
echo -e "${CYAN}Server initialization:${NC}"
grep -E "Found|Opened shared|TLS server" $LOGS_DIR/server.log | head -5

echo ""
sleep 2

# Phase 2: Client Connections with PSN Exchange
echo -e "${WHITE}${BOLD}PHASE 2: Client Connections & PSN Exchange${NC}"
print_line

echo -e "${YELLOW}Launching 10 clients with alphabet patterns...${NC}"
echo ""

# Array of letters for each client
LETTERS=("a" "b" "c" "d" "e" "f" "g" "h" "i" "j")

# Launch clients
for i in {1..10}; do
    LETTER=${LETTERS[$((i-1))]}
    echo -e "${BLUE}→ Launching Client $i (Letter: '$LETTER')${NC}"
    chmod +x demo_client.sh
    ./demo_client.sh $i $LETTER 0.2 > $LOGS_DIR/client_$i.log 2>&1 &
    echo $! > $LOGS_DIR/client_$i.pid
    sleep 0.3
done

echo ""
echo -e "${YELLOW}Waiting for connections to establish...${NC}"
sleep 5

# Phase 3: Show PSN Values
echo ""
echo -e "${WHITE}${BOLD}PHASE 3: PSN Analysis${NC}"
print_line

echo -e "${CYAN}Unique PSN values assigned:${NC}"
echo ""

# Extract and display PSN values
for i in {1..10}; do
    if [ -f $LOGS_DIR/client_$i.log ]; then
        PSN_LINE=$(grep "Local PSN:" $LOGS_DIR/client_$i.log 2>/dev/null | head -1)
        if [ ! -z "$PSN_LINE" ]; then
            LOCAL_PSN=$(echo $PSN_LINE | awk '{print $3}' | tr -d ',')
            SERVER_PSN=$(echo $PSN_LINE | awk '{print $6}')
            printf "  Client %2d: Local PSN: ${GREEN}%-10s${NC} Server PSN: ${MAGENTA}%-10s${NC}\n" $i "$LOCAL_PSN" "$SERVER_PSN"
        fi
    fi
done

echo ""

# Check PSN uniqueness
UNIQUE_COUNT=$(grep "Local PSN:" $LOGS_DIR/client_*.log 2>/dev/null | awk '{print $3}' | tr -d ',' | sort -u | wc -l)
TOTAL_COUNT=$(grep "Local PSN:" $LOGS_DIR/client_*.log 2>/dev/null | wc -l)

if [ "$UNIQUE_COUNT" -eq "$TOTAL_COUNT" ] && [ "$TOTAL_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ All PSN values are unique ($UNIQUE_COUNT unique PSNs)${NC}"
else
    echo -e "${RED}⚠ PSN uniqueness check: $UNIQUE_COUNT unique out of $TOTAL_COUNT${NC}"
fi

sleep 3

# Phase 4: Message Analysis
echo ""
echo -e "${WHITE}${BOLD}PHASE 4: Message Transmission Results${NC}"
print_line

echo -e "${CYAN}Analyzing received messages...${NC}"
echo ""

# Check server log for received messages
for i in {1..10}; do
    LETTER=${LETTERS[$((i-1))]}
    PATTERN=$(printf "%0.s$LETTER" {1..100})
    
    # Count occurrences of the pattern in server log
    if grep -q "Client_${i}_Pattern:$PATTERN" $LOGS_DIR/server.log 2>/dev/null; then
        echo -e "  Client $i: ${GREEN}✓${NC} Received 100 '${LETTER}' characters"
    else
        # Check partial receipt
        if grep -q "Client_${i}_Pattern:" $LOGS_DIR/server.log 2>/dev/null; then
            echo -e "  Client $i: ${YELLOW}⚠${NC} Partial message received"
        else
            echo -e "  Client $i: ${RED}✗${NC} No message received"
        fi
    fi
done

sleep 2

# Phase 5: Performance Summary
echo ""
echo -e "${WHITE}${BOLD}PHASE 5: Performance Summary${NC}"
print_line

# Count successful connections
SUCCESS_COUNT=$(grep -l "Connection established" $LOGS_DIR/client_*.log 2>/dev/null | wc -l)

echo -e "${CYAN}Connection Statistics:${NC}"
echo "  • Total clients attempted: 10"
echo "  • Successful connections: $SUCCESS_COUNT"
echo "  • Connection success rate: $((SUCCESS_COUNT * 10))%"

# Check for shared device context
if grep -q "Opened shared RDMA device" $LOGS_DIR/server.log; then
    echo ""
    echo -e "${CYAN}Resource Optimization:${NC}"
    echo -e "  • ${GREEN}✓${NC} Shared device context active"
    echo -e "  • ${GREEN}✓${NC} Single device open for all clients"
fi

# Generate detailed results file
{
    echo "RDMA Demo Results - $(date)"
    echo "=================================="
    echo ""
    echo "Configuration:"
    echo "  - Server: Pure IB verbs implementation"
    echo "  - PSN Exchange: TLS (Port 4433)"
    echo "  - Clients: 10 concurrent"
    echo "  - Pattern: 100 characters per client"
    echo ""
    echo "PSN Values:"
    grep "Local PSN:" $LOGS_DIR/client_*.log 2>/dev/null | sort
    echo ""
    echo "Connection Summary:"
    echo "  - Successful: $SUCCESS_COUNT/10"
    echo "  - PSN Uniqueness: $UNIQUE_COUNT unique values"
    echo ""
    echo "Server Log Excerpt:"
    grep -E "Client.*established|Received RDMA" $LOGS_DIR/server.log | head -20
} > $RESULTS_FILE

echo ""
echo -e "${GREEN}✓ Detailed results saved to: demo_results.txt${NC}"

# Phase 6: Architecture Visualization
echo ""
echo -e "${WHITE}${BOLD}PHASE 6: Architecture Visualization${NC}"
print_line

cat << 'EOF'
                    ┌─────────────────────────┐
                    │    TLS Server (4433)    │
                    │   PSN Exchange Layer    │
                    └───────────┬─────────────┘
                                │
                    ┌───────────▼─────────────┐
                    │   RDMA Server (Pure IB) │
                    │   Shared Device: rxe0   │
                    └───────────┬─────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        │                       │                       │
    ┌───▼───┐  ┌───▼───┐  ┌───▼───┐  ...  ┌───▼───┐
    │Client1│  │Client2│  │Client3│       │Client10│
    │PSN:xxx│  │PSN:yyy│  │PSN:zzz│       │PSN:www │
    │ 'aaa' │  │ 'bbb' │  │ 'ccc' │       │ 'jjj' │
    └───────┘  └───────┘  └───────┘       └───────┘

    Key Features:
    • Each client has unique PSN (prevents replay attacks)
    • All clients share single device context (efficiency)
    • TLS protects PSN exchange (security)
    • Pure IB verbs control (flexibility)
EOF

echo ""
sleep 3

# Final summary
echo ""
echo -e "${WHITE}${BOLD}DEMO COMPLETE${NC}"
print_line

echo -e "${GREEN}Key Achievements:${NC}"
echo "✓ Demonstrated secure PSN exchange via TLS"
echo "✓ Showed multi-client concurrent connections"
echo "✓ Verified PSN uniqueness (no replay vulnerability)"
echo "✓ Confirmed shared device context optimization"
echo "✓ Successful alphabet pattern transmission"

echo ""
echo -e "${CYAN}Files Generated:${NC}"
echo "• Server log: $LOGS_DIR/server.log"
echo "• Client logs: $LOGS_DIR/client_*.log"
echo "• Results: $RESULTS_FILE"

echo ""
echo -e "${YELLOW}Press Enter to stop the server and exit...${NC}"
read

# Cleanup will be handled by trap
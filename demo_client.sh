#!/bin/bash

# Demo Client - Sends alphabet pattern via RDMA
# Usage: ./demo_client.sh <client_id> <letter> [delay]

CLIENT_ID=$1
LETTER=$2
DELAY=${3:-0}
SERVER_ADDR="127.0.0.1"
SERVER_NAME="localhost"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Array of colors for different clients
COLORS=("$RED" "$GREEN" "$YELLOW" "$BLUE" "$MAGENTA" "$CYAN" "$RED" "$GREEN" "$YELLOW" "$BLUE")
CLIENT_COLOR=${COLORS[$((CLIENT_ID - 1))]}

if [ -z "$CLIENT_ID" ] || [ -z "$LETTER" ]; then
    echo "Usage: $0 <client_id> <letter> [delay]"
    echo "Example: $0 1 a 0"
    exit 1
fi

# Generate 100 characters of the specified letter
MESSAGE=$(printf "%0.s$LETTER" {1..100})

# Add delay if specified
if [ $DELAY -gt 0 ]; then
    sleep $DELAY
fi

echo -e "${CLIENT_COLOR}[Client $CLIENT_ID]${NC} Starting connection (Letter: '$LETTER')"

# Create client commands
{
    echo "send Client_${CLIENT_ID}_Pattern:${MESSAGE}"
    sleep 0.5
    echo "write RDMA_Write_${CLIENT_ID}:${MESSAGE}"
    sleep 0.5
    echo "send Completion_${CLIENT_ID}_Done"
    sleep 0.5
    echo "quit"
} | ./build/secure_client $SERVER_ADDR $SERVER_NAME 2>&1 | while IFS= read -r line; do
    # Filter and format output
    if [[ $line == *"PSN"* ]]; then
        echo -e "${CLIENT_COLOR}[Client $CLIENT_ID]${NC} ${CYAN}$line${NC}"
    elif [[ $line == *"established"* ]]; then
        echo -e "${CLIENT_COLOR}[Client $CLIENT_ID]${NC} ${GREEN}✓ Connection established${NC}"
    elif [[ $line == *"sent successfully"* ]]; then
        echo -e "${CLIENT_COLOR}[Client $CLIENT_ID]${NC} ${GREEN}✓ Data sent${NC}"
    elif [[ $line == *"Error"* ]] || [[ $line == *"Failed"* ]]; then
        echo -e "${CLIENT_COLOR}[Client $CLIENT_ID]${NC} ${RED}✗ $line${NC}"
    fi
done

echo -e "${CLIENT_COLOR}[Client $CLIENT_ID]${NC} Completed"
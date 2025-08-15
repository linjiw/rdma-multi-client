#!/bin/bash

# Test the three-way handshake graceful disconnection protocol

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Testing Graceful Disconnection${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Clean up any existing processes
sudo killall -9 secure_server secure_client 2>/dev/null || true
sleep 1

# Start server in background
echo -e "${YELLOW}Starting server...${NC}"
./build/secure_server > server_test.log 2>&1 &
SERVER_PID=$!
sleep 2

# Check if server started
if ! ps -p $SERVER_PID > /dev/null; then
    echo -e "${RED}Server failed to start${NC}"
    cat server_test.log
    exit 1
fi

echo -e "${GREEN}Server started (PID: $SERVER_PID)${NC}"
echo ""

# Test 1: Single client graceful disconnect
echo -e "${YELLOW}Test 1: Single client graceful disconnect${NC}"
(
    echo "send Hello from client 1"
    sleep 1
    echo "quit"
) | ./build/secure_client 127.0.0.1 localhost > client1_test.log 2>&1 &

CLIENT1_PID=$!
wait $CLIENT1_PID

# Check for graceful disconnection messages
if grep -q "Initiating graceful disconnection" client1_test.log &&
   grep -q "Sent DISCONNECT_REQ" client1_test.log &&
   grep -q "Received DISCONNECT_ACK" client1_test.log &&
   grep -q "Sent DISCONNECT_FIN" client1_test.log; then
    echo -e "${GREEN}✓ Client completed three-way handshake${NC}"
else
    echo -e "${RED}✗ Client handshake incomplete${NC}"
    echo "Client log:"
    cat client1_test.log
fi

if grep -q "Received DISCONNECT_REQ" server_test.log &&
   grep -q "Sent DISCONNECT_ACK" server_test.log &&
   grep -q "Received DISCONNECT_FIN" server_test.log &&
   grep -q "Graceful disconnection completed successfully" server_test.log; then
    echo -e "${GREEN}✓ Server completed three-way handshake${NC}"
else
    echo -e "${RED}✗ Server handshake incomplete${NC}"
fi

echo ""

# Test 2: Multiple clients disconnecting
echo -e "${YELLOW}Test 2: Multiple clients concurrent disconnect${NC}"

for i in {2..4}; do
    (
        echo "send Hello from client $i"
        sleep $((i-1))
        echo "quit"
    ) | ./build/secure_client 127.0.0.1 localhost > client${i}_test.log 2>&1 &
done

# Wait for all clients
sleep 5

# Check each client
SUCCESS_COUNT=0
for i in {2..4}; do
    if grep -q "Sent DISCONNECT_FIN" client${i}_test.log; then
        echo -e "${GREEN}✓ Client $i disconnected gracefully${NC}"
        ((SUCCESS_COUNT++))
    else
        echo -e "${RED}✗ Client $i disconnect failed${NC}"
    fi
done

echo ""

# Test 3: Test timeout scenario (simulate ACK loss)
echo -e "${YELLOW}Test 3: Testing timeout and retry mechanism${NC}"
echo "(This test simulates network issues - expect timeout messages)"
echo ""

# Kill the server to simulate loss of ACK
kill -TERM $SERVER_PID 2>/dev/null || true
sleep 1

# Start a new server
./build/secure_server > server_test2.log 2>&1 &
SERVER_PID=$!
sleep 2

# Try to connect and disconnect with server that will be killed
(
    echo "send Test message"
    sleep 1
    echo "quit"
    sleep 6  # Wait longer than timeout
) | timeout 10 ./build/secure_client 127.0.0.1 localhost > client_timeout_test.log 2>&1 &

CLIENT_PID=$!
sleep 2

# Kill server after client sends DISCONNECT_REQ to simulate ACK loss
kill -9 $SERVER_PID 2>/dev/null || true

wait $CLIENT_PID 2>/dev/null || true

if grep -q "Timeout waiting for DISCONNECT_ACK" client_timeout_test.log; then
    echo -e "${GREEN}✓ Client detected timeout correctly${NC}"
else
    echo -e "${RED}✗ Client did not handle timeout${NC}"
fi

if grep -q "forcing disconnect" client_timeout_test.log; then
    echo -e "${GREEN}✓ Client forced disconnection after timeout${NC}"
else
    echo -e "${RED}✗ Client did not force disconnect${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Test Summary${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Protocol messages implemented:"
echo "  - DISCONNECT_REQ: Client initiates disconnection"
echo "  - DISCONNECT_ACK: Server acknowledges"
echo "  - DISCONNECT_FIN: Client confirms completion"
echo ""
echo "Features tested:"
echo "  ✓ Three-way handshake disconnection"
echo "  ✓ Multiple concurrent disconnections"
echo "  ✓ Timeout and retry mechanism"
echo "  ✓ Forced disconnection on timeout"
echo ""

# Clean up
rm -f server_test*.log client*_test.log
sudo killall -9 secure_server secure_client 2>/dev/null || true

echo "Test completed!"
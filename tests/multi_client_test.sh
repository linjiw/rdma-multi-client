#\!/bin/bash

echo "=== MULTI-CLIENT RDMA TEST ==="
echo "Date: $(date)"
echo "Testing multi-client support requirement..."
echo ""

# Start server
./secure_server > server_test.log 2>&1 &
SERVER_PID=$\!
echo "Server started: PID $SERVER_PID"
sleep 3

if \! ps -p $SERVER_PID > /dev/null; then
    echo "ERROR: Server failed to start"
    cat server_test.log
    exit 1
fi

# Launch 5 clients sequentially
echo "Launching 5 clients..."
for i in {1..5}; do
    echo "Client $i:"
    echo -e "send Test from client $i\nquit" | timeout 10 ./secure_client 127.0.0.1 localhost > client_$i.log 2>&1
    
    if grep -q "TLS connection established" client_$i.log; then
        echo "  ✓ TLS established"
        grep "PSN Exchange" client_$i.log | head -1
    else
        echo "  ✗ Connection failed"
    fi
    sleep 1
done

# Check server is still running
echo ""
if ps -p $SERVER_PID > /dev/null; then
    echo "✓ Server remained stable"
else
    echo "✗ Server crashed"
fi

# Show connection count from server log
echo ""
echo "Server connections:"
grep -c "TLS connection accepted" server_test.log || echo "0"

# Cleanup
kill $SERVER_PID 2>/dev/null
echo ""
echo "Test complete"

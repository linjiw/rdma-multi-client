#!/bin/bash

# Test RDMA-RAG webpage locally
echo "🚀 Testing RDMA-RAG webpage..."

# Start a simple HTTP server
cd docs
python3 -m http.server 8080 > /dev/null 2>&1 &
SERVER_PID=$!

echo "📄 Webpage started at: http://localhost:8080/rdma-rag.html"
echo "🌐 Main site at: http://localhost:8080/index.html"
echo ""
echo "🎯 Key features to test:"
echo "  ✓ Live speed comparison demo"
echo "  ✓ Interactive query testing"
echo "  ✓ Animated data flow visualization"
echo "  ✓ Performance metrics"
echo "  ✓ Use case demonstrations"
echo ""
echo "Press Ctrl+C to stop the server..."

# Wait for user interrupt
trap "echo ''; echo 'Stopping server...'; kill $SERVER_PID 2>/dev/null; exit 0" INT

# Keep the script running
while kill -0 $SERVER_PID 2>/dev/null; do
    sleep 1
done
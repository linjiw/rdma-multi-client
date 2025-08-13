#!/bin/bash

# Health check script - verifies demo can run successfully
# Returns 0 if ready, 1 if not

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0

echo "Demo Health Check"
echo "================="
echo ""

# 1. Check binaries exist
echo -n "1. Binaries built: "
if [ -f "build/secure_server" ] && [ -f "build/secure_client" ]; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC} Missing binaries"
    ERRORS=$((ERRORS + 1))
fi

# 2. Check ports are free
echo -n "2. Port 4433 free: "
if ! sudo lsof -i :4433 2>/dev/null | grep -q LISTEN; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC} Port in use"
    ERRORS=$((ERRORS + 1))
fi

echo -n "3. Port 4791 free: "
if ! sudo lsof -i :4791 2>/dev/null | grep -q LISTEN; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC} Port in use"
    ERRORS=$((ERRORS + 1))
fi

# 3. Check no existing processes
echo -n "4. No existing server: "
if ! pgrep -f secure_server > /dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC} Server already running"
    ERRORS=$((ERRORS + 1))
fi

echo -n "5. No existing clients: "
if ! pgrep -f secure_client > /dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC} Clients already running"
    ERRORS=$((ERRORS + 1))
fi

# 4. Check RDMA device
echo -n "6. RDMA device available: "
if ibv_devices 2>/dev/null | grep -q rxe0; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${YELLOW}⚠${NC} Soft-RoCE not configured"
fi

# 5. Check certificates
echo -n "7. TLS certificates: "
if [ -f "server.crt" ] && [ -f "server.key" ]; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${YELLOW}⚠${NC} Will be generated"
fi

# 6. Check demo scripts
echo -n "8. Demo scripts present: "
if [ -f "run_demo_auto.sh" ] && [ -f "demo_cleanup.sh" ]; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC} Missing demo scripts"
    ERRORS=$((ERRORS + 1))
fi

# Summary
echo ""
if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}✓ System ready for demo${NC}"
    exit 0
else
    echo -e "${RED}✗ $ERRORS issues found${NC}"
    echo ""
    echo "To fix:"
    echo "  1. Run: ./demo_cleanup.sh"
    echo "  2. Check for stuck processes: ps aux | grep secure"
    echo "  3. Free ports if needed: sudo lsof -i :4433"
    exit 1
fi
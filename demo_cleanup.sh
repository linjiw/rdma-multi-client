#!/bin/bash

# Comprehensive cleanup script for demo
# Ensures clean state before demo starts

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}═══════════════════════════════════════${NC}"
echo -e "${YELLOW}    Demo Environment Cleanup Utility    ${NC}"
echo -e "${YELLOW}═══════════════════════════════════════${NC}"
echo ""

# Function to kill processes safely
kill_processes() {
    local process_name=$1
    local pids=$(pgrep -f "$process_name" 2>/dev/null)
    
    if [ ! -z "$pids" ]; then
        echo -e "${YELLOW}Found ${process_name} processes: ${pids}${NC}"
        for pid in $pids; do
            kill $pid 2>/dev/null && echo -e "  ${GREEN}✓${NC} Killed PID $pid"
        done
        sleep 1
        
        # Force kill if still running
        remaining=$(pgrep -f "$process_name" 2>/dev/null)
        if [ ! -z "$remaining" ]; then
            for pid in $remaining; do
                kill -9 $pid 2>/dev/null && echo -e "  ${YELLOW}⚠${NC} Force killed PID $pid"
            done
        fi
    fi
}

# 1. Kill existing RDMA processes
echo -e "${YELLOW}1. Cleaning up existing processes...${NC}"
kill_processes "secure_server"
kill_processes "secure_client"
kill_processes "demo_client"
kill_processes "demo_server"
kill_processes "run_demo.sh"
kill_processes "test_multi_client"
kill_processes "test_thread_safety"

# 2. Check port availability
echo ""
echo -e "${YELLOW}2. Checking port availability...${NC}"

check_port() {
    local port=$1
    local port_user=$(sudo lsof -i :$port 2>/dev/null | grep LISTEN | awk '{print $2}')
    
    if [ ! -z "$port_user" ]; then
        echo -e "  ${YELLOW}Port $port in use by PID: $port_user${NC}"
        sudo kill $port_user 2>/dev/null && echo -e "  ${GREEN}✓${NC} Freed port $port"
        sleep 1
    else
        echo -e "  ${GREEN}✓${NC} Port $port is free"
    fi
}

check_port 4433  # TLS port
check_port 4791  # RDMA port

# 3. Clean up log files
echo ""
echo -e "${YELLOW}3. Cleaning up old logs...${NC}"

cleanup_logs() {
    local log_dir=$1
    if [ -d "$log_dir" ]; then
        local count=$(find "$log_dir" -type f -name "*.log" 2>/dev/null | wc -l)
        if [ $count -gt 0 ]; then
            rm -f "$log_dir"/*.log 2>/dev/null
            rm -f "$log_dir"/*.pid 2>/dev/null
            echo -e "  ${GREEN}✓${NC} Removed $count log files from $log_dir"
        fi
    fi
}

cleanup_logs "demo_logs"
cleanup_logs "client_logs"
cleanup_logs "thread_test_logs"

# Remove standalone log files
rm -f server.log test_server.log thread_server.log 2>/dev/null
rm -f test_client*.log 2>/dev/null
rm -f demo_results.txt test_results.txt thread_safety_report.txt 2>/dev/null

# 4. Check RDMA device status
echo ""
echo -e "${YELLOW}4. Checking RDMA device status...${NC}"

if command -v ibv_devices &> /dev/null; then
    device_count=$(ibv_devices 2>/dev/null | grep -c "rxe0")
    if [ $device_count -gt 0 ]; then
        echo -e "  ${GREEN}✓${NC} RDMA device rxe0 is available"
    else
        echo -e "  ${YELLOW}⚠${NC} RDMA device rxe0 not found"
        echo -e "  ${YELLOW}  Run: sudo rdma link add rxe0 type rxe netdev eth0${NC}"
    fi
else
    echo -e "  ${RED}✗${NC} ibverbs tools not found"
fi

# 5. Check build status
echo ""
echo -e "${YELLOW}5. Checking build status...${NC}"

if [ -f "build/secure_server" ] && [ -f "build/secure_client" ]; then
    echo -e "  ${GREEN}✓${NC} Binaries are built"
else
    echo -e "  ${YELLOW}⚠${NC} Binaries missing. Building..."
    make clean > /dev/null 2>&1
    make all > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} Build successful"
    else
        echo -e "  ${RED}✗${NC} Build failed"
        exit 1
    fi
fi

# 6. Check certificates
echo ""
echo -e "${YELLOW}6. Checking TLS certificates...${NC}"

if [ -f "server.crt" ] && [ -f "server.key" ]; then
    echo -e "  ${GREEN}✓${NC} TLS certificates present"
else
    echo -e "  ${YELLOW}⚠${NC} Generating TLS certificates..."
    make generate-cert > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} Certificates generated"
    else
        echo -e "  ${RED}✗${NC} Certificate generation failed"
    fi
fi

# 7. System resource check
echo ""
echo -e "${YELLOW}7. System resource check...${NC}"

# Check memory
available_mem=$(free -m | awk 'NR==2{printf "%.1f", $7/1024}')
echo -e "  Available memory: ${available_mem}GB"

# Check CPU load
load_avg=$(uptime | awk -F'load average:' '{print $2}')
echo -e "  Load average:${load_avg}"

# Final status
echo ""
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}    Environment Ready for Demo!         ${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo ""

# Return success
exit 0
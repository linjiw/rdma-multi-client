#!/bin/bash

# RDMA Experiment Monitoring Script
# Tracks and logs all aspects of the RDMA testing on AWS

set -e

# Configuration
EXPERIMENT_ID="rdma_exp_$(date +%Y%m%d_%H%M%S)"
RESULTS_DIR="experiment_results/$EXPERIMENT_ID"
METRICS_FILE="$RESULTS_DIR/metrics.json"
SUMMARY_FILE="$RESULTS_DIR/summary.md"

# Create results directory
mkdir -p "$RESULTS_DIR"

# Initialize JSON metrics
cat > "$METRICS_FILE" << EOF
{
  "experiment_id": "$EXPERIMENT_ID",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "environment": {},
  "performance": {},
  "security": {},
  "functionality": {}
}
EOF

# Function to update metrics
update_metric() {
    local category=$1
    local key=$2
    local value=$3
    
    python3 -c "
import json
with open('$METRICS_FILE', 'r') as f:
    data = json.load(f)
data['$category']['$key'] = '$value'
with open('$METRICS_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
}

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$RESULTS_DIR/experiment.log"
}

# 1. Collect Environment Information
collect_environment() {
    log "Collecting environment information..."
    
    # System info
    update_metric "environment" "kernel" "$(uname -r)"
    update_metric "environment" "os" "$(lsb_release -ds 2>/dev/null || echo 'Unknown')"
    update_metric "environment" "instance_type" "$(ec2-metadata --instance-type 2>/dev/null | cut -d' ' -f2 || echo 'local')"
    
    # RDMA info
    local rdma_devices=$(ibv_devices 2>/dev/null | grep -v "device" | wc -l)
    update_metric "environment" "rdma_devices" "$rdma_devices"
    
    # Network info
    local iface=$(ip route | grep default | awk '{print $5}' | head -1)
    update_metric "environment" "network_interface" "$iface"
    
    # Save detailed info
    ibv_devinfo > "$RESULTS_DIR/ibv_devinfo.txt" 2>&1 || true
    rdma link show > "$RESULTS_DIR/rdma_link.txt" 2>&1 || true
}

# 2. Run Functionality Tests
test_functionality() {
    log "Testing RDMA functionality..."
    
    # Test RDMA connectivity
    log "Testing basic RDMA connectivity with pingpong..."
    
    # Start server
    timeout 5 ibv_rc_pingpong > "$RESULTS_DIR/pingpong_server.log" 2>&1 &
    SERVER_PID=$!
    sleep 2
    
    # Run client
    if timeout 3 ibv_rc_pingpong localhost > "$RESULTS_DIR/pingpong_client.log" 2>&1; then
        update_metric "functionality" "rdma_pingpong" "passed"
        log "✓ RDMA pingpong test passed"
    else
        update_metric "functionality" "rdma_pingpong" "failed"
        log "✗ RDMA pingpong test failed"
    fi
    
    kill $SERVER_PID 2>/dev/null || true
    
    # Test secure RDMA
    log "Testing secure RDMA implementation..."
    
    ./secure_server > "$RESULTS_DIR/secure_server.log" 2>&1 &
    SERVER_PID=$!
    sleep 3
    
    if ps -p $SERVER_PID > /dev/null; then
        # Test TLS connection
        if echo "quit" | timeout 10 ./secure_client 127.0.0.1 localhost > "$RESULTS_DIR/secure_client.log" 2>&1; then
            update_metric "functionality" "tls_connection" "passed"
            log "✓ TLS connection test passed"
        else
            update_metric "functionality" "tls_connection" "failed"
            log "✗ TLS connection test failed"
        fi
        
        # Check PSN exchange
        if grep -q "PSN Exchange" "$RESULTS_DIR/secure_client.log"; then
            update_metric "functionality" "psn_exchange" "passed"
            log "✓ PSN exchange test passed"
        else
            update_metric "functionality" "psn_exchange" "failed"
            log "✗ PSN exchange test failed"
        fi
        
        kill $SERVER_PID 2>/dev/null || true
    else
        update_metric "functionality" "server_start" "failed"
        log "✗ Server failed to start"
    fi
}

# 3. Measure Performance
measure_performance() {
    log "Measuring RDMA performance..."
    
    # Bandwidth test
    log "Running bandwidth test..."
    ib_send_bw > "$RESULTS_DIR/bw_server.log" 2>&1 &
    BW_PID=$!
    sleep 2
    
    if timeout 30 ib_send_bw localhost > "$RESULTS_DIR/bw_client.log" 2>&1; then
        local bandwidth=$(grep "BW average" "$RESULTS_DIR/bw_client.log" | awk '{print $3}')
        update_metric "performance" "bandwidth_gbps" "$bandwidth"
        log "Bandwidth: $bandwidth Gb/sec"
    fi
    
    kill $BW_PID 2>/dev/null || true
    
    # Latency test
    log "Running latency test..."
    ib_send_lat > "$RESULTS_DIR/lat_server.log" 2>&1 &
    LAT_PID=$!
    sleep 2
    
    if timeout 30 ib_send_lat localhost > "$RESULTS_DIR/lat_client.log" 2>&1; then
        local latency=$(grep "latency" "$RESULTS_DIR/lat_client.log" | tail -1 | awk '{print $3}')
        update_metric "performance" "latency_us" "$latency"
        log "Latency: $latency μs"
    fi
    
    kill $LAT_PID 2>/dev/null || true
    
    # Connection establishment time
    log "Measuring connection establishment time..."
    local start_time=$(date +%s%N)
    echo "quit" | timeout 10 ./secure_client 127.0.0.1 localhost > /dev/null 2>&1
    local end_time=$(date +%s%N)
    local conn_time=$(( (end_time - start_time) / 1000000 ))
    update_metric "performance" "connection_time_ms" "$conn_time"
    log "Connection time: ${conn_time}ms"
}

# 4. Validate Security
validate_security() {
    log "Validating security features..."
    
    # Check PSN randomness
    log "Checking PSN randomness..."
    local psn_values=()
    
    for i in {1..5}; do
        ./secure_server > "/tmp/psn_test_$i.log" 2>&1 &
        PID=$!
        sleep 1
        kill $PID 2>/dev/null || true
        
        local psn=$(grep -oE "PSN: 0x[0-9a-f]+" "/tmp/psn_test_$i.log" | head -1 | cut -d' ' -f2)
        if [ ! -z "$psn" ]; then
            psn_values+=("$psn")
        fi
    done
    
    # Check for duplicates
    local unique_count=$(printf '%s\n' "${psn_values[@]}" | sort -u | wc -l)
    if [ $unique_count -eq ${#psn_values[@]} ]; then
        update_metric "security" "psn_randomness" "passed"
        log "✓ PSN randomness check passed (all values unique)"
    else
        update_metric "security" "psn_randomness" "failed"
        log "✗ PSN randomness check failed (duplicates found)"
    fi
    
    # Check TLS version
    log "Checking TLS configuration..."
    ./secure_server > /dev/null 2>&1 &
    SERVER_PID=$!
    sleep 3
    
    if echo | timeout 5 openssl s_client -connect localhost:4433 2>/dev/null | grep -q "TLSv1.[23]"; then
        update_metric "security" "tls_version" "TLS 1.2+"
        log "✓ TLS version check passed (TLS 1.2+)"
    else
        update_metric "security" "tls_version" "unknown"
        log "✗ TLS version check inconclusive"
    fi
    
    kill $SERVER_PID 2>/dev/null || true
}

# 5. Stress Test
stress_test() {
    log "Running stress tests..."
    
    # Start server
    ./secure_server > "$RESULTS_DIR/stress_server.log" 2>&1 &
    SERVER_PID=$!
    sleep 3
    
    if ps -p $SERVER_PID > /dev/null; then
        # Test concurrent connections
        log "Testing 10 concurrent clients..."
        local success_count=0
        
        for i in {1..10}; do
            (echo -e "send Client $i\nquit" | timeout 5 ./secure_client 127.0.0.1 localhost > "$RESULTS_DIR/stress_client_$i.log" 2>&1) &
        done
        
        wait
        
        for i in {1..10}; do
            if grep -q "Sent:" "$RESULTS_DIR/stress_client_$i.log"; then
                success_count=$((success_count + 1))
            fi
        done
        
        update_metric "functionality" "concurrent_clients" "$success_count/10"
        log "Concurrent clients: $success_count/10 successful"
        
        # Check server stability
        if ps -p $SERVER_PID > /dev/null; then
            update_metric "functionality" "server_stability" "passed"
            log "✓ Server remained stable after stress test"
        else
            update_metric "functionality" "server_stability" "failed"
            log "✗ Server crashed during stress test"
        fi
        
        kill $SERVER_PID 2>/dev/null || true
    fi
}

# 6. Generate Summary Report
generate_summary() {
    log "Generating summary report..."
    
    cat > "$SUMMARY_FILE" << EOF
# RDMA Experiment Summary
**Experiment ID:** $EXPERIMENT_ID  
**Date:** $(date)

## Environment
$(python3 -c "
import json
with open('$METRICS_FILE') as f:
    data = json.load(f)
    env = data['environment']
    for k, v in env.items():
        print(f'- **{k}:** {v}')
")

## Functionality Tests
$(python3 -c "
import json
with open('$METRICS_FILE') as f:
    data = json.load(f)
    func = data['functionality']
    for k, v in func.items():
        status = '✅' if 'pass' in str(v).lower() else '❌'
        print(f'{status} **{k}:** {v}')
")

## Performance Metrics
$(python3 -c "
import json
with open('$METRICS_FILE') as f:
    data = json.load(f)
    perf = data['performance']
    for k, v in perf.items():
        print(f'- **{k}:** {v}')
")

## Security Validation
$(python3 -c "
import json
with open('$METRICS_FILE') as f:
    data = json.load(f)
    sec = data['security']
    for k, v in sec.items():
        status = '✅' if 'pass' in str(v).lower() or 'TLS' in str(v) else '❌'
        print(f'{status} **{k}:** {v}')
")

## Logs
- [Server Log](secure_server.log)
- [Client Log](secure_client.log)
- [Experiment Log](experiment.log)
- [Metrics JSON](metrics.json)

## Conclusion
$(python3 -c "
import json
with open('$METRICS_FILE') as f:
    data = json.load(f)
    func = data['functionality']
    passed = sum(1 for v in func.values() if 'pass' in str(v).lower())
    total = len(func)
    if passed == total:
        print('✅ **All tests passed!** The secure RDMA implementation is working correctly with Soft-RoCE.')
    else:
        print(f'⚠️ **{passed}/{total} tests passed.** Review the logs for details on failures.')
")
EOF
    
    log "Summary report generated: $SUMMARY_FILE"
}

# Main execution
main() {
    log "Starting RDMA experiment monitoring..."
    log "Experiment ID: $EXPERIMENT_ID"
    
    # Check prerequisites
    if ! command -v ibv_devices &> /dev/null; then
        log "ERROR: RDMA tools not found. Please run on AWS instance with Soft-RoCE."
        exit 1
    fi
    
    if [ ! -f "secure_server" ] || [ ! -f "secure_client" ]; then
        log "Building secure RDMA implementation..."
        make clean && make all && make generate-cert
    fi
    
    # Run all tests
    collect_environment
    test_functionality
    measure_performance
    validate_security
    stress_test
    generate_summary
    
    # Display results
    echo
    echo "════════════════════════════════════════════════════════"
    cat "$SUMMARY_FILE"
    echo "════════════════════════════════════════════════════════"
    
    log "Experiment complete! Results saved in: $RESULTS_DIR"
}

# Run main
main
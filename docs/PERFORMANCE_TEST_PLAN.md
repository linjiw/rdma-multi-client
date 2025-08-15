# RDMA Performance Testing Plan

## Current System Analysis

### AWS Instance: t3.large
- **CPUs**: 2 vCPUs
- **Memory**: 7.7 GB total, 6.3 GB available
- **Network**: Up to 5 Gbps
- **Open Files Limit**: 1,048,576
- **Max Processes**: 30,775

### Current Implementation Limits
- **MAX_CLIENTS**: 10 (hardcoded in server)
- **Buffer Size**: 4096 bytes per client
- **Memory per Client**: ~16 KB (send + recv buffers + structures)
- **Thread per Client**: Yes (pthread model)

## Theoretical Capacity Calculation

### Memory Constraints
```
Available Memory: 6.3 GB = 6,300 MB
Per Client Memory:
- Buffers: 8 KB (2 × 4096)
- QP/CQ/PD structures: ~8 KB
- Thread stack: 8 MB (default)
- Total: ~8.016 MB per client

Theoretical Max Clients (Memory): 6,300 MB / 8.016 MB ≈ 785 clients
```

### Thread Constraints
```
Max User Processes: 30,775
Reserved for system: ~275
Available for clients: ~30,500
Theoretical Max Clients (Threads): 30,500
```

### RDMA Resource Constraints
```
Soft-RoCE limitations:
- Queue Pairs: Typically 1000s supported
- Completion Queues: Similar to QPs
- Memory Regions: Limited by kernel memory
```

### Network Constraints
```
5 Gbps = 625 MB/s
Per client bandwidth (1000 clients): 625 KB/s
Per client bandwidth (100 clients): 6.25 MB/s
```

## Testing Phases

### Phase 1: Baseline (10 clients) ✓
- Already tested and working
- Establishes performance baseline
- Verify all clients unique PSNs

### Phase 2: Scale to 100 clients
- Increase MAX_CLIENTS to 100
- Test concurrent connections
- Monitor resource usage

### Phase 3: Scale to 1000 clients
- Increase MAX_CLIENTS to 1000
- Implement connection pooling if needed
- Monitor for bottlenecks

### Phase 4: Scale to 10,000 clients
- Likely requires optimizations:
  - Epoll instead of threads
  - Memory pool management
  - Connection multiplexing

### Phase 5: Find Breaking Point
- Incrementally increase until failure
- Document failure mode
- Identify bottleneck

## Performance Metrics to Collect

1. **Connection Metrics**
   - Time to establish connection
   - PSN generation time
   - TLS handshake duration
   - QP setup time

2. **Throughput Metrics**
   - Messages per second
   - Bytes per second
   - Latency percentiles (p50, p95, p99)

3. **Resource Metrics**
   - CPU utilization
   - Memory usage
   - Thread count
   - File descriptor usage
   - Network bandwidth

4. **Failure Metrics**
   - Connection failures
   - Timeout rates
   - Error types

## Implementation Strategy

### Step 1: Make MAX_CLIENTS Configurable
- Convert to runtime parameter
- Dynamically allocate client array

### Step 2: Create Stress Test Tool
- Configurable client count
- Configurable message patterns
- Performance monitoring
- Results reporting

### Step 3: Optimize for Scale
- Thread pool instead of thread-per-client
- Epoll for I/O multiplexing
- Memory pooling
- Batch operations

### Step 4: Test and Measure
- Progressive load testing
- Resource monitoring
- Bottleneck identification

## Expected Bottlenecks

1. **Thread Creation** (>1000 clients)
   - Solution: Thread pool or epoll

2. **Memory Allocation** (>5000 clients)
   - Solution: Memory pools

3. **Context Switching** (>2000 threads)
   - Solution: Event-driven architecture

4. **RDMA Resources** (varies)
   - Solution: Resource sharing/multiplexing

## Test Execution Plan

```bash
# Test progression
./performance_test --clients 10     # Baseline
./performance_test --clients 100    # 10x scale
./performance_test --clients 500    # Intermediate
./performance_test --clients 1000   # 100x scale
./performance_test --clients 5000   # Push limits
./performance_test --clients 10000  # Find breaking point
```

## Success Criteria

- **10 clients**: < 1ms connection time, 100% success
- **100 clients**: < 10ms connection time, 100% success
- **1000 clients**: < 100ms connection time, >99% success
- **10000 clients**: Stable operation or graceful failure

## Risk Mitigation

1. **Gradual scaling** to prevent system crash
2. **Resource monitoring** to prevent OOM
3. **Timeout mechanisms** to prevent hangs
4. **Cleanup procedures** between tests
5. **Backup instance** for recovery
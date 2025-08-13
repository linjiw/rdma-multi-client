# Pure IB Verbs Implementation Design
**Version**: 1.0  
**Date**: August 12, 2025  
**Status**: Design Phase

## Executive Summary

This document outlines the design for implementing RDMA communication using pure InfiniBand verbs without RDMA Connection Manager (RDMA CM). This approach gives us complete control over the connection establishment process, including the ability to set custom PSN values for security.

## 1. Architecture Overview

### 1.1 Why Pure IB Verbs?

**Problems with RDMA CM:**
- `rdma_connect()` and `rdma_accept()` automatically transition QP to RTS state
- Cannot set custom PSN values after automatic transitions
- Event-driven model doesn't fit our TLS-first connection approach

**Benefits of Pure IB Verbs:**
- Complete control over QP state transitions
- Can set PSN at the appropriate transition points
- No dependency on RDMA CM event loop
- Direct device access and management

### 1.2 High-Level Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Application Layer                     │
├─────────────────────────────────────────────────────────┤
│                  TLS Connection (OpenSSL)                 │
│                    - PSN Exchange                         │
│                    - QP Info Exchange                     │
├─────────────────────────────────────────────────────────┤
│                   Pure IB Verbs Layer                     │
│  - ibv_open_device()                                     │
│  - ibv_alloc_pd()                                        │
│  - ibv_create_cq()                                       │
│  - ibv_create_qp()                                       │
│  - ibv_modify_qp() [INIT→RTR→RTS with custom PSN]       │
│  - ibv_reg_mr()                                          │
│  - ibv_post_send/recv()                                  │
└─────────────────────────────────────────────────────────┘
```

## 2. Connection Flow

### 2.1 Connection Establishment Sequence

```
Client                                          Server
------                                          ------
1. TLS Connect ────────────────────────────→ TLS Accept
2. Exchange PSN ←──────────────────────────→ Exchange PSN
3. Open IB Device                             Open IB Device
4. Create PD, CQ, QP                          Create PD, CQ, QP
5. Exchange QP Info over TLS:                 Exchange QP Info over TLS:
   - QP Number                                 - QP Number
   - LID (if IB)                              - LID (if IB)
   - GID (if RoCE)                            - GID (if RoCE)
   - PSN (already exchanged)                  - PSN (already exchanged)
6. QP→INIT (set port, pkey, access)          QP→INIT (set port, pkey, access)
7. QP→RTR (set remote QP info, remote PSN)   QP→RTR (set remote QP info, remote PSN)
8. QP→RTS (set local PSN, timeouts)          QP→RTS (set local PSN, timeouts)
9. Post Receive                               Post Receive
10. RDMA Operations ←─────────────────────→  RDMA Operations
```

### 2.2 Required Parameters Exchange

**Over TLS (Secure Channel):**
```c
struct rdma_conn_params {
    uint32_t qp_num;        // Queue Pair number
    uint16_t lid;           // Local ID (InfiniBand only)
    uint8_t  gid[16];       // Global ID (RoCE)
    uint32_t psn;           // Packet Sequence Number (secure)
    uint32_t rkey;          // Remote key for RDMA operations
    uint64_t remote_addr;   // Remote memory address
};
```

## 3. Implementation Details

### 3.1 Device and Context Management

```c
// Open RDMA device
struct ibv_device **dev_list = ibv_get_device_list(&num_devices);
struct ibv_context *ctx = ibv_open_device(dev_list[0]);
ibv_free_device_list(dev_list);

// Query device capabilities
struct ibv_device_attr dev_attr;
ibv_query_device(ctx, &dev_attr);

// Query port attributes
struct ibv_port_attr port_attr;
ibv_query_port(ctx, port_num, &port_attr);
```

### 3.2 QP Creation and Setup

```c
// Create Protection Domain
struct ibv_pd *pd = ibv_alloc_pd(ctx);

// Create Completion Queues
struct ibv_cq *send_cq = ibv_create_cq(ctx, cq_size, NULL, NULL, 0);
struct ibv_cq *recv_cq = ibv_create_cq(ctx, cq_size, NULL, NULL, 0);

// Create Queue Pair
struct ibv_qp_init_attr qp_init_attr = {
    .send_cq = send_cq,
    .recv_cq = recv_cq,
    .qp_type = IBV_QPT_RC,
    .cap = {
        .max_send_wr = 10,
        .max_recv_wr = 10,
        .max_send_sge = 1,
        .max_recv_sge = 1
    }
};
struct ibv_qp *qp = ibv_create_qp(pd, &qp_init_attr);
```

### 3.3 QP State Transitions with Custom PSN

```c
// INIT state
struct ibv_qp_attr attr = {
    .qp_state = IBV_QPS_INIT,
    .port_num = 1,
    .pkey_index = 0,
    .qp_access_flags = IBV_ACCESS_LOCAL_WRITE | 
                      IBV_ACCESS_REMOTE_READ | 
                      IBV_ACCESS_REMOTE_WRITE
};
ibv_modify_qp(qp, &attr, IBV_QP_STATE | IBV_QP_PKEY_INDEX | 
              IBV_QP_PORT | IBV_QP_ACCESS_FLAGS);

// RTR state with remote PSN
attr.qp_state = IBV_QPS_RTR;
attr.path_mtu = IBV_MTU_1024;
attr.dest_qp_num = remote_qp_num;
attr.rq_psn = remote_psn;  // Custom PSN from TLS exchange
attr.max_dest_rd_atomic = 1;
attr.min_rnr_timer = 12;
// Set ah_attr based on IB or RoCE
ibv_modify_qp(qp, &attr, ...);

// RTS state with local PSN
attr.qp_state = IBV_QPS_RTS;
attr.sq_psn = local_psn;  // Custom PSN for sending
attr.timeout = 14;
attr.retry_cnt = 7;
attr.rnr_retry = 7;
attr.max_rd_atomic = 1;
ibv_modify_qp(qp, &attr, ...);
```

## 4. Key Implementation Components

### 4.1 Server Implementation

1. **Initialization:**
   - Create TLS listener only (no RDMA CM listener)
   - Open IB device on startup

2. **Per-Client Handler:**
   - Accept TLS connection
   - Exchange PSN
   - Create dedicated QP for client
   - Exchange QP parameters over TLS
   - Transition QP with custom PSN
   - Handle RDMA operations

### 4.2 Client Implementation

1. **Connection:**
   - Connect via TLS
   - Exchange PSN
   - Open IB device
   - Create QP
   - Exchange QP parameters over TLS
   - Transition QP with custom PSN

2. **Operations:**
   - Post receives before sends
   - Handle completion events
   - Cleanup on disconnect

## 5. Critical Success Factors

### 5.1 Must Have
- ✅ Custom PSN control during QP transitions
- ✅ No dependency on RDMA CM events
- ✅ All parameters exchanged over secure TLS channel
- ✅ Support for both IB and RoCE

### 5.2 Implementation Checklist
- [ ] Device discovery and selection
- [ ] Context and PD creation
- [ ] CQ and QP creation
- [ ] Memory registration
- [ ] Parameter exchange protocol over TLS
- [ ] QP state transitions with custom PSN
- [ ] Error handling and cleanup
- [ ] Multi-client support
- [ ] Performance optimization

## 6. Potential Challenges

### 6.1 Address Resolution
Without RDMA CM, we need to:
- Manually determine if using IB or RoCE
- Handle GID for RoCE, LID for IB
- Query port attributes correctly

### 6.2 Synchronization
- Ensure both sides complete QP transitions before operations
- Handle race conditions in parameter exchange
- Implement proper handshaking

### 6.3 Resource Management
- Track all IB resources per client
- Proper cleanup on disconnect
- Handle partial failures

## 7. Testing Strategy

### 7.1 Unit Tests
- Device open/close
- QP creation and transitions
- PSN value verification

### 7.2 Integration Tests
- TLS + RDMA parameter exchange
- Single client connection
- Multi-client connections
- Disconnect and cleanup

### 7.3 Performance Tests
- Latency measurements
- Throughput tests
- Scalability with multiple clients

## 8. Migration Plan

### Phase 1: Core Implementation
1. Create minimal proof-of-concept
2. Test device open and QP creation
3. Verify state transitions with custom PSN

### Phase 2: Full Conversion
1. Convert server to pure IB verbs
2. Convert client to pure IB verbs
3. Implement complete parameter exchange

### Phase 3: Testing and Optimization
1. Comprehensive testing
2. Performance tuning
3. Documentation

## 9. Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2025-08-12 | Use pure IB verbs | Full control over PSN |
| 2025-08-12 | TLS for all parameter exchange | Security requirement |
| 2025-08-12 | Port 1 as default | Standard for first port |

## 10. References

- [IB Verbs Programming](https://www.rdmamojo.com/)
- [OFED Verbs API](https://www.openfabrics.org/)
- [Linux RDMA](https://github.com/linux-rdma)

---
**Document Status**: This is a living document that will be updated as implementation progresses.
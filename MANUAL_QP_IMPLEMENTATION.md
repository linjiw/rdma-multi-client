# Manual QP Management Implementation Report
**Date**: August 12, 2025

## Problem Statement
RDMA CM's `rdma_connect()` and `rdma_accept()` automatically transition QPs to RTS state, preventing us from setting custom PSN values for security. We need manual control over QP state transitions to implement secure PSN exchange.

## Implementation Completed

### Changes Made:

1. **Client (`secure_rdma_client.c`)**:
   - ✅ Removed `rdma_connect()` call
   - ✅ Added manual QP state transitions (INIT → RTR → RTS)
   - ✅ Set custom PSN values during transitions
   - ✅ Uses TLS-exchanged PSN values

2. **Server (`secure_rdma_server.c`)**:
   - ✅ Removed `rdma_accept()` call  
   - ✅ Added QP creation in `handle_rdma_connection()`
   - ✅ Added manual QP state transitions with custom PSN
   - ✅ Uses TLS-exchanged PSN values

## Current Issue

**The server RDMA listener thread waits for RDMA_CM_EVENT_CONNECT_REQUEST events, but these are only generated when a client calls `rdma_connect()`. Since we removed that call, the server never receives the connection request.**

## Root Cause Analysis

The current architecture has a fundamental dependency on RDMA CM's connection management:

```
Current Flow (Broken):
1. Client/Server: TLS PSN exchange ✅
2. Client: rdma_resolve_addr() ✅
3. Client: rdma_resolve_route() ✅
4. Client: Create QP ✅
5. Client: rdma_connect() ❌ (removed)
6. Server: Wait for CONNECT_REQUEST ⏳ (never arrives)
7. Server: Create QP ❌ (never reached)
8. Both: Exchange params ❌ (server stuck waiting)
```

## Solutions

### Option 1: Hybrid Approach (Recommended)
Use RDMA CM for address resolution only, not for connection establishment:

1. Client uses RDMA CM for address/route resolution
2. Server creates QP immediately after TLS connection (not waiting for RDMA CM events)
3. Both exchange ALL parameters via TLS (including GIDs, LIDs, QPNs)
4. Both manually transition QPs with custom PSNs
5. No RDMA CM connection events needed

### Option 2: Modified RDMA CM Usage
Still use rdma_connect/accept but modify PSN after connection:

1. Use rdma_connect/accept normally
2. After connection, use `ibv_modify_qp()` to update PSN
3. Risk: May not work if PSN is locked after RTS state

### Option 3: Pure IB Verbs
Completely bypass RDMA CM:

1. Manual address resolution
2. Manual route discovery
3. Full control but very complex

## Recommended Fix

Implement Option 1 - the server should not wait for RDMA CM events. Instead:

1. **Server**: After TLS PSN exchange, immediately:
   - Create CM ID (without waiting for events)
   - Create PD and QP
   - Send QP info over TLS
   - Receive client QP info over TLS
   - Manually transition QP with custom PSN

2. **Client**: After route resolution:
   - Create QP
   - Exchange QP info over TLS
   - Manually transition QP with custom PSN

This removes the dependency on RDMA CM connection events while maintaining the security of custom PSN values.

## Key Learning

**RDMA CM's connection management (rdma_connect/accept) is tightly coupled with QP state management. You cannot partially use it - either use the full connection flow or handle everything manually.**

## Next Steps

1. Remove RDMA listener thread from server
2. Create QPs immediately after TLS connection
3. Exchange all RDMA parameters over TLS
4. Test the implementation
5. Document the final working solution
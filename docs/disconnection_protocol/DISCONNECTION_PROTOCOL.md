# Three-Way Handshake Disconnection Protocol

## Current Issue
Currently, the client simply sends "quit" and immediately disconnects. This can lead to:
- Lost messages in transit
- Improper resource cleanup
- No confirmation of graceful shutdown
- Potential race conditions

## Proposed Three-Way Handshake Protocol

### Protocol Messages
```
DISCONNECT_REQ   - Client initiates disconnection
DISCONNECT_ACK   - Server acknowledges and prepares for disconnection  
DISCONNECT_FIN   - Client confirms and closes connection
```

### Sequence Diagram
```
Client                          Server
  |                               |
  |-------- DISCONNECT_REQ ------>|  (1) Client requests disconnect
  |                               |
  |<------- DISCONNECT_ACK --------|  (2) Server acknowledges, stops sending
  |                               |
  |-------- DISCONNECT_FIN ------>|  (3) Client confirms, both close
  |                               |
```

### Implementation Details

#### Phase 1: DISCONNECT_REQ (Client → Server)
- Client sends special message: "$$DISCONNECT_REQ$$"
- Client starts disconnect timer (5 seconds)
- Client stops accepting new user commands
- Client continues to process pending RDMA operations

#### Phase 2: DISCONNECT_ACK (Server → Client)
- Server receives DISCONNECT_REQ
- Server marks client as "disconnecting"
- Server flushes pending sends
- Server sends "$$DISCONNECT_ACK$$"
- Server stops accepting new messages from client
- Server starts cleanup timer (3 seconds)

#### Phase 3: DISCONNECT_FIN (Client → Server)
- Client receives DISCONNECT_ACK
- Client sends "$$DISCONNECT_FIN$$"
- Client waits for final completion (100ms)
- Client cleans up RDMA resources
- Server receives DISCONNECT_FIN
- Server completes cleanup

### Timeout Handling
- If client doesn't receive ACK within 5 seconds: Force disconnect
- If server doesn't receive FIN within 3 seconds after ACK: Force cleanup
- Each message can be retransmitted once if no response

### Key Design Decisions

1. **Why Three-Way Instead of Two-Way?**
   - Ensures both sides acknowledge disconnection
   - Prevents resource leaks
   - Handles network delays gracefully

2. **Special Message Format**
   - Using "$$MESSAGE$$" format to distinguish from user data
   - Easy to parse and unlikely to conflict with user messages

3. **Backward Compatibility**
   - If old client sends regular quit: Server handles gracefully
   - Protocol version can be negotiated during initial PSN exchange

4. **Resource Cleanup Order**
   1. Stop accepting new operations
   2. Complete pending RDMA operations
   3. Exchange disconnection handshake
   4. Destroy QP (transitions to ERROR state)
   5. Cleanup completion queues
   6. Deregister memory regions
   7. Close TLS connection

### Error Cases

1. **Client Crashes During Handshake**
   - Server timeout triggers forced cleanup

2. **Server Crashes During Handshake**
   - Client timeout triggers forced disconnect

3. **Network Partition**
   - Both sides timeout and cleanup independently

4. **Message Loss**
   - One retransmission attempt
   - Then forced disconnection

## Implementation Plan

1. Add disconnect state enum to client and server structures
2. Implement message parsing for protocol messages
3. Add state machine for disconnection flow
4. Implement timeout mechanisms
5. Test with multiple concurrent disconnections
6. Add metrics/logging for debugging